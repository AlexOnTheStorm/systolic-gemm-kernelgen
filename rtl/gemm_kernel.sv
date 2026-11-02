`timescale 1ns / 1ps
// =====================================================================
//  gemm_kernel — systolic_array as a callable Vitis RTL kernel (P4).
//  FULL datapath (not a skeleton): AXI4-Lite control + AXI4-master DMA +
//  on-chip buffers + systolic feed + result collection.
//
//  Computes ONE tile: C[M×N] = A[M×K] · B[K×N], where M=ARRAY_M, N=ARRAY_N,
//  K = k_dim (runtime, ≤ K_MAX). The host places A, B, C in global memory.
//
//  MEMORY LAYOUT (reference design — simple and verifiable):
//    each element = one 32-bit word (INT8 A/B sign-extended in the low byte,
//    C is a full INT32). Dense INT8 packing is a bandwidth optimization (TODO).
//    A: M*K words row-major; B: K*N; C: M*N. AXI single-beat transfers.
//
//  ap_ctrl_hs control contract (0x00): [0]=ap_start [1]=ap_done [2]=ap_idle.
//  Arguments: 0x10 a_addr, 0x1C b_addr, 0x28 c_addr, 0x34 k_dim.
//
//  ✅ Verified IN SIMULATION (tb/test_kernel.py, AXI memory model) —
//     bring-up on F2 is left with integration/timing, not logic debugging.
// =====================================================================
module gemm_kernel #(
    parameter int ARRAY_M    = 4,
    parameter int ARRAY_N    = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int K_MAX      = 32,
    parameter int ADDR_W     = 64,
    parameter int AXI_DW     = 32
) (
    input  logic                 ap_clk,
    input  logic                 ap_rst_n,

    // --- AXI4-Lite control (simplified: always-ready, single transactions) ---
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

    // --- AXI4 master gmem (single beat, len=0) ---
    output logic                 m_axi_arvalid,
    input  logic                 m_axi_arready,
    output logic [ADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]           m_axi_arlen,
    input  logic                 m_axi_rvalid,
    output logic                 m_axi_rready,
    input  logic [AXI_DW-1:0]    m_axi_rdata,
    input  logic                 m_axi_rlast,
    output logic                 m_axi_awvalid,
    input  logic                 m_axi_awready,
    output logic [ADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]           m_axi_awlen,
    output logic                 m_axi_wvalid,
    input  logic                 m_axi_wready,
    output logic [AXI_DW-1:0]    m_axi_wdata,
    output logic                 m_axi_wlast,
    input  logic                 m_axi_bvalid,
    output logic                 m_axi_bready
);

  // position counters are compared/indexed at different widths —
  // functionally safe (values stay in range), but Verilator is strict about width.
  // The correctness gate is the golden comparison in tb/test_kernel.py, not lint.
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */

  localparam int KW = $clog2(K_MAX);

  // ---- argument registers + control ----
  logic               ap_start, ap_done, ap_idle;
  logic [ADDR_W-1:0]  a_addr, b_addr, c_addr;
  logic [31:0]        k_dim;

  // ---- on-chip tile buffers ----
  logic signed [DATA_WIDTH-1:0] a_buf [ARRAY_M][K_MAX];
  logic signed [DATA_WIDTH-1:0] b_buf [K_MAX][ARRAY_N];

  // ---- array ----
  logic                                 arr_clear, arr_en;
  logic [ARRAY_M*DATA_WIDTH-1:0]        arr_a_in;
  logic [ARRAY_N*DATA_WIDTH-1:0]        arr_b_in;
  logic [ARRAY_M*ARRAY_N*ACC_WIDTH-1:0] arr_c_out;

  systolic_array #(
      .ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N),
      .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
  ) u_array (
      .clk(ap_clk), .rst_n(ap_rst_n), .clear(arr_clear), .en(arr_en),
      .a_in_flat(arr_a_in), .b_in_flat(arr_b_in), .c_out_flat(arr_c_out)
  );

  // ===================================================================
  //  Main FSM: IDLE → read A → read B → COMPUTE → write C → DONE
  // ===================================================================
  typedef enum logic [3:0] {
      S_IDLE, S_A_AR, S_A_R, S_B_AR, S_B_R,
      S_COMPUTE, S_C_AW, S_C_W, S_C_B, S_DONE
  } state_t;
  state_t state;

  // position counters (no dividers — nested counters)
  logic [$clog2(ARRAY_M+1)-1:0] mm;
  logic [KW:0]                  kk;
  logic [$clog2(ARRAY_N+1)-1:0] nn;
  logic [ADDR_W-1:0]            rd_addr, wr_addr;
  logic [15:0]                  cyc;              // feed cycle counter

  // Feed/drain duration: (K+M+N-2) wavefront + margin. The 16'd8 margin covers
  // the MAC pipeline latency (pe.sv, +2 cycles: operands+MREG) — arr_en is held
  // long enough for the last product to reach acc before the array stops
  // (otherwise an in-flight result would "freeze" inside the pipeline).
  wire [15:0] feed_cycles = k_dim[15:0] + ARRAY_M[15:0] + ARRAY_N[15:0] + 16'd8;

  // --- systolic feed from the buffers (combinational) ---
  always_comb begin
    arr_a_in = '0;
    arr_b_in = '0;
    for (int i = 0; i < ARRAY_M; i++) begin
      if (cyc >= i[15:0]) begin
        automatic int unsigned k = cyc - i[15:0];
        if (k < k_dim)
          arr_a_in[i*DATA_WIDTH +: DATA_WIDTH] = a_buf[i][k[KW-1:0]];
      end
    end
    for (int j = 0; j < ARRAY_N; j++) begin
      if (cyc >= j[15:0]) begin
        automatic int unsigned k = cyc - j[15:0];
        if (k < k_dim)
          arr_b_in[j*DATA_WIDTH +: DATA_WIDTH] = b_buf[k[KW-1:0]][j];
      end
    end
  end

  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n) begin
      state <= S_IDLE; ap_idle <= 1'b1;
      arr_clear <= 1'b0; arr_en <= 1'b0;
      mm <= '0; kk <= '0; nn <= '0; cyc <= '0; rd_addr <= '0; wr_addr <= '0;
      m_axi_arvalid <= 1'b0; m_axi_rready <= 1'b0;
      m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0; m_axi_bready <= 1'b0;
    end else begin
      arr_clear <= 1'b0;
      case (state)
        // -----------------------------------------------------------
        S_IDLE: begin
          ap_idle <= 1'b1; arr_en <= 1'b0;
          if (ap_start) begin
            ap_idle   <= 1'b0;
            arr_clear <= 1'b1;                 // zero acc
            mm <= '0; kk <= '0;
            rd_addr <= a_addr;
            m_axi_arvalid <= 1'b1; m_axi_araddr <= a_addr; m_axi_arlen <= '0;
            state <= S_A_AR;
          end
        end
        // ---- read A: M*K words (row-major A[mm][kk]) ----
        S_A_AR: if (m_axi_arready) begin
                  m_axi_arvalid <= 1'b0; m_axi_rready <= 1'b1; state <= S_A_R;
                end
        S_A_R:  if (m_axi_rvalid) begin
                  a_buf[mm][kk[KW-1:0]] <= m_axi_rdata[DATA_WIDTH-1:0];
                  m_axi_rready <= 1'b0;
                  rd_addr <= rd_addr + 4;
                  // advance (mm,kk) within K=k_dim
                  if (kk + 1 == k_dim) begin
                    kk <= '0;
                    if (mm + 1 == ARRAY_M) begin       // A done → read B
                      mm <= '0; kk <= '0; rd_addr <= b_addr;
                      m_axi_arvalid <= 1'b1; m_axi_araddr <= b_addr;
                      state <= S_B_AR;
                    end else begin
                      mm <= mm + 1;
                      m_axi_arvalid <= 1'b1; m_axi_araddr <= rd_addr + 4;
                      state <= S_A_AR;
                    end
                  end else begin
                    kk <= kk + 1;
                    m_axi_arvalid <= 1'b1; m_axi_araddr <= rd_addr + 4;
                    state <= S_A_AR;
                  end
                end
        // ---- read B: K*N words (row-major B[kk][nn]) ----
        S_B_AR: if (m_axi_arready) begin
                  m_axi_arvalid <= 1'b0; m_axi_rready <= 1'b1; state <= S_B_R;
                end
        S_B_R:  if (m_axi_rvalid) begin
                  b_buf[kk[KW-1:0]][nn] <= m_axi_rdata[DATA_WIDTH-1:0];
                  m_axi_rready <= 1'b0;
                  rd_addr <= rd_addr + 4;
                  if (nn + 1 == ARRAY_N) begin
                    nn <= '0;
                    if (kk + 1 == k_dim) begin          // B done → COMPUTE
                      kk <= '0; cyc <= '0; arr_en <= 1'b1; state <= S_COMPUTE;
                    end else begin
                      kk <= kk + 1;
                      m_axi_arvalid <= 1'b1; m_axi_araddr <= rd_addr + 4;
                      state <= S_B_AR;
                    end
                  end else begin
                    nn <= nn + 1;
                    m_axi_arvalid <= 1'b1; m_axi_araddr <= rd_addr + 4;
                    state <= S_B_AR;
                  end
                end
        // ---- COMPUTE: drive the skewed feed for feed_cycles cycles ----
        S_COMPUTE: begin
          cyc <= cyc + 1;
          if (cyc + 1 >= feed_cycles) begin
            arr_en <= 1'b0;
            mm <= '0; nn <= '0; wr_addr <= c_addr;
            m_axi_awvalid <= 1'b1; m_axi_awaddr <= c_addr; m_axi_awlen <= '0;
            state <= S_C_AW;
          end
        end
        // ---- write C: M*N INT32 words (C[mm][nn]) ----
        S_C_AW: if (m_axi_awready) begin
                  m_axi_awvalid <= 1'b0;
                  m_axi_wvalid  <= 1'b1; m_axi_wlast <= 1'b1;
                  state <= S_C_W;
                end
        S_C_W:  if (m_axi_wready) begin
                  m_axi_wvalid <= 1'b0; m_axi_wlast <= 1'b0;
                  m_axi_bready <= 1'b1; state <= S_C_B;
                end
        S_C_B:  if (m_axi_bvalid) begin
                  m_axi_bready <= 1'b0;
                  wr_addr <= wr_addr + 4;
                  if (nn + 1 == ARRAY_N) begin
                    nn <= '0;
                    if (mm + 1 == ARRAY_M) begin
                      state <= S_DONE;
                    end else begin
                      mm <= mm + 1;
                      m_axi_awvalid <= 1'b1; m_axi_awaddr <= wr_addr + 4;
                      state <= S_C_AW;
                    end
                  end else begin
                    nn <= nn + 1;
                    m_axi_awvalid <= 1'b1; m_axi_awaddr <= wr_addr + 4;
                    state <= S_C_AW;
                  end
                end
        // -----------------------------------------------------------
        S_DONE: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // ap_done (ap_ctrl_hs): STICKY — set on completion, cleared when the host READS
  // the status. Otherwise a 1-cycle pulse slips past the host's polling.
  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n)                                        ap_done <= 1'b0;
    else if (state == S_DONE)                             ap_done <= 1'b1;
    else if (s_axil_arvalid && s_axil_araddr == 12'h00)   ap_done <= 1'b0;
  end

  // write data: word C[mm][nn] from arr_c_out
  assign m_axi_wdata = arr_c_out[(mm*ARRAY_N + nn)*ACC_WIDTH +: ACC_WIDTH];

  // ===================================================================
  //  AXI4-Lite control: argument writes, status reads
  // ===================================================================
  assign s_axil_awready = 1'b1;
  assign s_axil_wready  = 1'b1;
  assign s_axil_arready = 1'b1;

  always_ff @(posedge ap_clk or negedge ap_rst_n) begin
    if (!ap_rst_n) begin
      ap_start <= 1'b0; a_addr <= '0; b_addr <= '0; c_addr <= '0; k_dim <= '0;
      s_axil_bvalid <= 1'b0; s_axil_rvalid <= 1'b0; s_axil_rdata <= '0;
    end else begin
      if (s_axil_awvalid && s_axil_wvalid) begin
        unique case (s_axil_awaddr)
          12'h00: ap_start      <= s_axil_wdata[0];
          12'h10: a_addr[31:0]  <= s_axil_wdata;
          12'h14: a_addr[63:32] <= s_axil_wdata;
          12'h1C: b_addr[31:0]  <= s_axil_wdata;
          12'h20: b_addr[63:32] <= s_axil_wdata;
          12'h28: c_addr[31:0]  <= s_axil_wdata;
          12'h2C: c_addr[63:32] <= s_axil_wdata;
          12'h34: k_dim         <= s_axil_wdata;
          default: ;
        endcase
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
      // ap_start self-clears once the FSM has left IDLE
      if (state != S_IDLE) ap_start <= 1'b0;

      if (s_axil_arvalid) begin
        s_axil_rdata  <= (s_axil_araddr == 12'h00)
                         ? {29'b0, ap_idle, ap_done, 1'b0} : 32'b0;
        s_axil_rvalid <= 1'b1;
      end else if (s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */
endmodule
