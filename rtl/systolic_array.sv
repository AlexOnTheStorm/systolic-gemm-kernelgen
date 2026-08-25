`timescale 1ns / 1ps
// =====================================================================
//  systolic_array — параметризованный ARRAY_M × ARRAY_N массив PE.
//  Считает тайл C[ARRAY_M × ARRAY_N] = A_tile · B_tile,
//  где A_tile: ARRAY_M × K,  B_tile: K × ARRAY_N (K — потоковая ось).
//
//  Топология (output-stationary):
//    - a течёт по строкам слева-направо, b — по столбцам сверху-вниз.
//    - PE(i,j) держит C[i][j].  Каждый пасс-through регистровый → волновой
//      фронт: пара (A[i][k], B[k][j]) встречается в PE(i,j) на такте k+i+j.
//
//  Систолический SKEW (делает окружение/TB, не массив):
//    - в строку i активацию A[i][k] подают на ЛЕВЫЙ край на такте k+i;
//    - в столбец j операнд B[k][j] подают на ВЕРХНИЙ край на такте k+j;
//    - вне окна — нули. Волновой фронт добегает за (K-1)+(M-1)+(N-1)+1 тактов,
//      ПЛЮС латентность конвейера MAC внутри PE (сейчас +2 такта: MREG+операнды,
//      см. pe.sv) → полный дренаж = (K+M+N-2) + 2. Skew подачи от этого НЕ
//      зависит (пайплайн только сдвигает, когда произведение ляжет в acc).
//
//  Интерфейс — ПЛОСКИЕ шины (удобно для cocotb и для AXIS-обёртки):
//    a_in_flat  = { row[M-1], ..., row[1], row[0] }  каждый DATA_WIDTH бит;
//    b_in_flat  = { col[N-1], ..., col[1], col[0] };
//    c_out_flat[(i*N+j)] = acc(i,j), каждый ACC_WIDTH бит.
//
//  Стиль: lowRISC (IEEE 1800-2017, 4-state logic, один модуль/файл,
//  lower_snake_case, generate именованы). См. docs/style_notes.md.
// =====================================================================
module systolic_array #(
    parameter int ARRAY_M    = 4,   // строк PE (= строк выходного тайла)
    parameter int ARRAY_N    = 4,   // столбцов PE (= столбцов выходного тайла)
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                clear,   // обнулить все acc
    input  logic                                en,      // продвинуть массив на такт
    input  logic [ARRAY_M*DATA_WIDTH-1:0]       a_in_flat,  // левый край, по строкам
    input  logic [ARRAY_N*DATA_WIDTH-1:0]       b_in_flat,  // верхний край, по столбцам
    output logic [ARRAY_M*ARRAY_N*ACC_WIDTH-1:0] c_out_flat  // все acc(i,j)
);

  // --- внутренние сети wire между PE ---
  //  a_h[i][j]  — активация, входящая в PE(i,j) (j=0 — левый край).
  //  b_v[i][j]  — операнд,   входящий в PE(i,j) (i=0 — верхний край).
  logic signed [DATA_WIDTH-1:0] a_h [ARRAY_M][ARRAY_N+1];
  logic signed [DATA_WIDTH-1:0] b_v [ARRAY_M+1][ARRAY_N];
  logic signed [ACC_WIDTH-1:0]  acc [ARRAY_M][ARRAY_N];

  genvar i, j;
  generate
    // левый край: распаковать a_in_flat в a_h[i][0]
    for (i = 0; i < ARRAY_M; i++) begin : g_a_edge
      assign a_h[i][0] = signed'(a_in_flat[i*DATA_WIDTH +: DATA_WIDTH]);
    end
    // верхний край: распаковать b_in_flat в b_v[0][j]
    for (j = 0; j < ARRAY_N; j++) begin : g_b_edge
      assign b_v[0][j] = signed'(b_in_flat[j*DATA_WIDTH +: DATA_WIDTH]);
    end

    // сетка PE
    for (i = 0; i < ARRAY_M; i++) begin : g_row
      for (j = 0; j < ARRAY_N; j++) begin : g_col
        pe #(
            .DATA_WIDTH(DATA_WIDTH),
            .ACC_WIDTH (ACC_WIDTH)
        ) u_pe (
            .clk   (clk),
            .rst_n (rst_n),
            .clear (clear),
            .en    (en),
            .a_in  (a_h[i][j]),
            .b_in  (b_v[i][j]),
            .a_out (a_h[i][j+1]),  // вправо
            .b_out (b_v[i+1][j]),  // вниз
            .acc   (acc[i][j])
        );
        // упаковать acc(i,j) в выходную шину
        assign c_out_flat[(i*ARRAY_N + j)*ACC_WIDTH +: ACC_WIDTH] = acc[i][j];
      end
    end
  endgenerate

endmodule
