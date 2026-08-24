`timescale 1ns / 1ps
// =====================================================================
//  gemm_kernel — обёртка systolic_array в Vitis RTL-kernel (P4).
//  Делает массив вызываемым с хоста через XRT: читает A,B из глобальной
//  памяти (HBM/DDR) по AXI4-master, гоняет через систолику, пишет C обратно.
//
//  Интерфейс Vitis RTL-kernel (обязательный контракт, см. UG1393/UG1702):
//    - s_axi_control : AXI4-Lite slave — управляющие регистры (ap_ctrl_hs) +
//                      скалярные аргументы (адреса буферов, K).
//    - m_axi_gmem    : AXI4 master — доступ к глобальной памяти устройства.
//    - ap_clk/ap_rst_n : тактовая и сброс от платформы.
//
//  ⚠️  ЧЕСТНО: это REFERENCE-СКЕЛЕТ и цель bring-up. AXI4-Lite slave и AXI4
//  master boilerplate в реальном потоке генерирует Vitis RTL Kernel Wizard
//  (`vitis --new_kernel` / Package IP), а тут показана ИНТЕГРАЦИЯ вычислителя
//  и управляющий FSM. Крайние случаи AXI-handshake (burst, backpressure,
//  выравнивание) — ровно то, что ты ловишь на ILA в облаке (docs/flow_walkthrough.md).
//  Для CI/симуляции корректность самой математики уже доказана в P1/P2.
//
//  Регистровая карта (смещения в s_axi_control), стандарт ap_ctrl_hs:
//    0x00 AP_CTRL      [0]=ap_start [1]=ap_done [2]=ap_idle [3]=ap_ready
//    0x10 a_addr (64)  адрес A в global memory
//    0x1C b_addr (64)  адрес B
//    0x28 c_addr (64)  адрес C
//    0x34 K      (32)  общая размерность
// =====================================================================
module gemm_kernel #(
    parameter int ARRAY_M    = 8,
    parameter int ARRAY_N    = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int AXI_DW     = 512,   // ширина данных AXI master (HBM burst)
    parameter int AXI_AW     = 64
) (
    input  logic                 ap_clk,
    input  logic                 ap_rst_n,

    // --- AXI4-Lite control (упрощённо: только нужные регистры) ---
    input  logic                 s_axil_awvalid,
    output logic                 s_axil_awready,
    input  logic [11:0]          s_axil_awaddr,
    input  logic                 s_axil_wvalid,
    output logic                 s_axil_wready,
    input  logic [31:0]          s_axil_wdata,
    output logic                 s_axil_bvalid,
    input  logic                 s_axil_bready,
    input  logic                 s_axil_arvalid,
    output logic                 s_axil_arready,
    input  logic [11:0]          s_axil_araddr,
    output logic                 s_axil_rvalid,
    input  logic                 s_axil_rready,
    output logic [31:0]          s_axil_rdata,

    // --- AXI4 master gmem (упрощённо: раздельные read/write каналы) ---
    output logic                 m_axi_arvalid,
    input  logic                 m_axi_arready,
    output logic [AXI_AW-1:0]    m_axi_araddr,
    output logic [7:0]           m_axi_arlen,
    input  logic                 m_axi_rvalid,
    output logic                 m_axi_rready,
    input  logic [AXI_DW-1:0]    m_axi_rdata,
    input  logic                 m_axi_rlast,
    output logic                 m_axi_awvalid,
    input  logic                 m_axi_awready,
    output logic [AXI_AW-1:0]    m_axi_awaddr,
    output logic [7:0]           m_axi_awlen,
    output logic                 m_axi_wvalid,
    input  logic                 m_axi_wready,
    output logic [AXI_DW-1:0]    m_axi_wdata,
    output logic                 m_axi_wlast,
    input  logic                 m_axi_bvalid,
    output logic                 m_axi_bready
);

  // --- управляющие регистры (заполняются AXI-Lite декодером ниже) ---
  logic          ap_start, ap_done, ap_idle;
  logic [AXI_AW-1:0] a_addr, b_addr, c_addr;
  logic [31:0]   k_dim;

  // ===================================================================
  //  Управляющий FSM: IDLE -> LOAD_A -> LOAD_B -> COMPUTE -> STORE_C -> DONE
  //  (в реальном bring-up LOAD/STORE — это AXI-master burst-транзакции;
  //   COMPUTE подаёт систолический skew в массив, как в tb/test_systolic.py,
  //   только из внутренних буферов, а не из cocotb.)
  // ===================================================================
  typedef enum logic [2:0] {S_IDLE, S_LOAD_A, S_LOAD_B, S_COMPUTE, S_STORE_C, S_DONE} state_t;
  state_t state;

  // сигналы управления массивом
  logic                              arr_clear, arr_en;
  logic [ARRAY_M*DATA_WIDTH-1:0]     arr_a_in;
  logic [ARRAY_N*DATA_WIDTH-1:0]     arr_b_in;
  logic [ARRAY_M*ARRAY_N*ACC_WIDTH-1:0] arr_c_out;

  systolic_array #(
      .ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N),
      .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
  ) u_array (
      .clk       (ap_clk),
      .rst_n     (ap_rst_n),
      .clear     (arr_clear),
      .en        (arr_en),
      .a_in_flat (arr_a_in),
      .b_in_flat (arr_b_in),
      .c_out_flat(arr_c_out)
  );

  // -------------------------------------------------------------------
  //  Управляющий FSM (скелет). Датапат LOAD/STORE помечен как bring-up:
  //  здесь показан каркас переходов и рукопожатие ap_ctrl_hs; конкретные
  //  AXI burst-адреса/счётчики доводятся на железе с ILA.
  // -------------------------------------------------------------------
  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n) begin
      state     <= S_IDLE;
      ap_done   <= 1'b0;
      ap_idle   <= 1'b1;
      arr_clear <= 1'b0;
      arr_en    <= 1'b0;
    end else begin
      arr_clear <= 1'b0;
      case (state)
        S_IDLE: begin
          ap_idle <= 1'b1;
          ap_done <= 1'b0;
          if (ap_start) begin
            ap_idle   <= 1'b0;
            arr_clear <= 1'b1;         // обнулить acc перед новым GEMM
            state     <= S_LOAD_A;
          end
        end
        // TODO(bring-up): AXI-master чтение A-тайла в буфер (m_axi ar/r каналы)
        S_LOAD_A:  state <= S_LOAD_B;
        // TODO(bring-up): AXI-master чтение B-тайла
        S_LOAD_B:  begin arr_en <= 1'b1; state <= S_COMPUTE; end
        // COMPUTE: подать skew из буферов A/B в arr_a_in/arr_b_in (K+M+N тактов)
        S_COMPUTE: state <= S_STORE_C;
        // TODO(bring-up): AXI-master запись arr_c_out обратно в c_addr
        S_STORE_C: begin arr_en <= 1'b0; state <= S_DONE; end
        S_DONE: begin
          ap_done <= 1'b1;             // хост опрашивает ap_done через AXI-Lite
          state   <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------------
  //  Минимальный AXI4-Lite декодер регистров (ap_ctrl_hs + аргументы).
  //  В реальном потоке — из Kernel Wizard; здесь компактный референс.
  // -------------------------------------------------------------------
  assign s_axil_awready = 1'b1;
  assign s_axil_wready  = 1'b1;
  assign s_axil_arready = 1'b1;

  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n) begin
      ap_start <= 1'b0; a_addr <= '0; b_addr <= '0; c_addr <= '0; k_dim <= '0;
      s_axil_bvalid <= 1'b0; s_axil_rvalid <= 1'b0; s_axil_rdata <= '0;
    end else begin
      // запись регистров
      if (s_axil_awvalid && s_axil_wvalid) begin
        unique case (s_axil_awaddr)
          12'h00: ap_start          <= s_axil_wdata[0];
          12'h10: a_addr[31:0]      <= s_axil_wdata;
          12'h14: a_addr[63:32]     <= s_axil_wdata;
          12'h1C: b_addr[31:0]      <= s_axil_wdata;
          12'h20: b_addr[63:32]     <= s_axil_wdata;
          12'h28: c_addr[31:0]      <= s_axil_wdata;
          12'h2C: c_addr[63:32]     <= s_axil_wdata;
          12'h34: k_dim             <= s_axil_wdata;
          default: ;  // прочие смещения игнор
        endcase
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
      // ap_start самоочищается после старта
      if (state != S_IDLE) ap_start <= 1'b0;

      // чтение статуса (ap_done/ap_idle по 0x00)
      if (s_axil_arvalid) begin
        s_axil_rdata  <= (s_axil_araddr == 12'h00)
                         ? {28'b0, 1'b0, ap_idle, ap_done, 1'b0} : 32'b0;
        s_axil_rvalid <= 1'b1;
      end else if (s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  // AXI master по умолчанию неактивен в скелете (доводится на bring-up)
  assign m_axi_arvalid = 1'b0;  assign m_axi_araddr = '0;  assign m_axi_arlen = '0;
  assign m_axi_rready  = 1'b1;
  assign m_axi_awvalid = 1'b0;  assign m_axi_awaddr = '0;  assign m_axi_awlen = '0;
  assign m_axi_wvalid  = 1'b0;  assign m_axi_wdata  = '0;  assign m_axi_wlast = 1'b0;
  assign m_axi_bready  = 1'b1;

endmodule
