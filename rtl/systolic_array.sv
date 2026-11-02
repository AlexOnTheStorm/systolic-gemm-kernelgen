`timescale 1ns / 1ps
// =====================================================================
//  systolic_array — parameterized ARRAY_M × ARRAY_N array of PEs.
//  Computes the tile C[ARRAY_M × ARRAY_N] = A_tile · B_tile,
//  where A_tile: ARRAY_M × K,  B_tile: K × ARRAY_N (K is the streaming axis).
//
//  Topology (output-stationary):
//    - a flows along rows left-to-right, b flows down columns top-to-bottom.
//    - PE(i,j) holds C[i][j]. Every pass-through is registered → a wavefront:
//      the pair (A[i][k], B[k][j]) meets in PE(i,j) on cycle k+i+j.
//
//  Systolic SKEW (applied by the surrounding logic/TB, not by the array):
//    - into row i, activation A[i][k] is driven at the LEFT edge on cycle k+i;
//    - into column j, operand B[k][j] is driven at the TOP edge on cycle k+j;
//    - zeros outside the window. The wavefront completes in (K-1)+(M-1)+(N-1)+1 cycles,
//      PLUS the MAC pipeline latency inside the PE (currently +2 cycles: MREG+operands,
//      see pe.sv) → full drain = (K+M+N-2) + 2. The feed skew does NOT depend on this
//      (the pipeline only shifts when a product lands in acc).
//
//  Interface: FLAT buses (convenient for cocotb and for an AXIS wrapper):
//    a_in_flat  = { row[M-1], ..., row[1], row[0] }  each DATA_WIDTH bits;
//    b_in_flat  = { col[N-1], ..., col[1], col[0] };
//    c_out_flat[(i*N+j)] = acc(i,j), each ACC_WIDTH bits.
//
//  Style: lowRISC (IEEE 1800-2017, 4-state logic, one module per file,
//  lower_snake_case, named generate blocks). See docs/style_notes.md.
// =====================================================================
module systolic_array #(
    parameter int ARRAY_M    = 4,   // PE rows (= rows of the output tile)
    parameter int ARRAY_N    = 4,   // PE columns (= columns of the output tile)
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                clear,   // zero all acc
    input  logic                                en,      // advance the array by one cycle
    input  logic [ARRAY_M*DATA_WIDTH-1:0]       a_in_flat,  // left edge, per row
    input  logic [ARRAY_N*DATA_WIDTH-1:0]       b_in_flat,  // top edge, per column
    output logic [ARRAY_M*ARRAY_N*ACC_WIDTH-1:0] c_out_flat  // all acc(i,j)
);

  // --- internal nets between PEs ---
  //  a_h[i][j]  — activation entering PE(i,j) (j=0 is the left edge).
  //  b_v[i][j]  — operand entering PE(i,j)    (i=0 is the top edge).
  logic signed [DATA_WIDTH-1:0] a_h [ARRAY_M][ARRAY_N+1];
  logic signed [DATA_WIDTH-1:0] b_v [ARRAY_M+1][ARRAY_N];
  logic signed [ACC_WIDTH-1:0]  acc [ARRAY_M][ARRAY_N];

  genvar i, j;
  generate
    // left edge: unpack a_in_flat into a_h[i][0]
    for (i = 0; i < ARRAY_M; i++) begin : g_a_edge
      assign a_h[i][0] = signed'(a_in_flat[i*DATA_WIDTH +: DATA_WIDTH]);
    end
    // top edge: unpack b_in_flat into b_v[0][j]
    for (j = 0; j < ARRAY_N; j++) begin : g_b_edge
      assign b_v[0][j] = signed'(b_in_flat[j*DATA_WIDTH +: DATA_WIDTH]);
    end

    // PE grid
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
            .a_out (a_h[i][j+1]),  // to the right
            .b_out (b_v[i+1][j]),  // down
            .acc   (acc[i][j])
        );
        // pack acc(i,j) into the output bus
        assign c_out_flat[(i*ARRAY_N + j)*ACC_WIDTH +: ACC_WIDTH] = acc[i][j];
      end
    end
  endgenerate

endmodule
