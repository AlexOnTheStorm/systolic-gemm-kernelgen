`timescale 1ns / 1ps
// =====================================================================
//  pe — one processing element of the systolic array (output-stationary).
//
//  Role: this is ONE MAC. The C = A·B array is built from a grid of these PEs,
//  where each PE(i,j) accumulates exactly one output element C[i][j].
//
//  Contract (output-stationary dataflow):
//    - Activation a flows LEFT-TO-RIGHT: a_in -> (register) -> a_out.
//    - Weight/operand b flows TOP-TO-BOTTOM: b_in -> (register) -> b_out.
//    - Every cycle with en:  acc <= acc + a_in * b_in   (signed MAC).
//    - The pass-through is REGISTERED: a reaches the right neighbour in 1 cycle,
//      b reaches the neighbour below in 1 cycle. This is what creates the systolic
//      "wavefront": PE(i,j) sees a valid pair (A[i][k],B[k][j]) on cycle
//      t = k + i + j (see the systolic skew in systolic_array.sv).
//    - Outside the valid window the inputs are driven with ZEROS, so zero products
//      do not corrupt acc. That is why the MAC can run unconditionally (no gating on k).
//    - clear (1 cycle, while idle) zeroes acc and the pass-through registers —
//      the start of a new matmul.
//
//  Precision: the input is DATA_WIDTH-bit SIGNED (INT8 by default), the accumulator
//  is ACC_WIDTH-bit signed (INT32). The product of two INT8 values is 16 bits; for K up
//  to ~65536 the sum fits in INT32 without overflow (the bound is checked in SVA and
//  in the model).
//
//  MAC PIPELINE (for f_max): multiplication and accumulation are SPLIT across cycles,
//  so each cycle does EITHER a multiply OR an add, not both — the frequency is then
//  bounded by one DSP48E2 rather than by a long mult+add cloud.
//    stage1 (AREG/BREG): a_r <= a_in ; b_r <= b_in
//    stage2 (MREG):      prod_r <= a_r * b_r
//    stage3 (PREG):      acc <= acc + prod_r          ← recurrence (1 cycle)
//  Result: the product of the inputs of cycle t lands in acc on cycle t+3 → LATENCY=3
//  (was 1). This is the classic latency↔f_max trade: +2 drain cycles for the DSP's
//  "native" frequency. IMPORTANT: the sum does NOT change — the same products simply
//  land in acc 2 cycles later; the array's systolic skew is unchanged.
//  The accumulator loop acc<=acc+… CANNOT be pipelined (1-cycle feedback), but the
//  multiplier is moved OUT of it (MREG) → only a fast adder remains in the loop.
// =====================================================================
module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          clear,   // zero acc (start of a new matmul)
    input  logic                          en,      // advance the pipeline by one cycle
    input  logic signed [DATA_WIDTH-1:0]  a_in,    // from the left neighbour (or the left edge)
    input  logic signed [DATA_WIDTH-1:0]  b_in,    // from the upper neighbour (or the top edge)
    output logic signed [DATA_WIDTH-1:0]  a_out,   // to the right neighbour
    output logic signed [DATA_WIDTH-1:0]  b_out,   // to the neighbour below
    output logic signed [ACC_WIDTH-1:0]   acc      // accumulated C[i][j]
);

  // MAC pipeline registers. The pass-through (a_out/b_out) uses SEPARATE registers:
  // they feed the neighbours and hold the systolic skew (1 cycle/hop), while
  // a_r/b_r/prod_r feed the local multiplier. Vivado packs a_r/b_r into
  // AREG/BREG, prod_r into MREG and acc into PREG of a single DSP48E2.
  //
  // (* use_dsp = "yes" *): WITHOUT this attribute Vivado sees a small INT8×INT8
  // multiply and maps it to LUTs (DSP48 = 27×18; spending a whole block on 8×8 looks
  // "wasteful") → synthesis gives DSP=0, ~100 LUT/PE. The attribute forces the MAC into
  // a DSP48E2 → 1 DSP per PE. This VALIDATES the P2 resource proxy (PE≈DSP) by synthesis.
  // (⚠️ the attribute name is vendor-specific, Xilinx/AMD; see UG901 "USE_DSP".)
  logic signed [DATA_WIDTH-1:0]   a_r, b_r;   // stage1: operands (AREG/BREG)
  (* use_dsp = "yes" *)
  logic signed [2*DATA_WIDTH-1:0] prod_r;     // stage2: product (MREG)

  // SYNCHRONOUS reset (no `negedge rst_n` in the sensitivity list): the internal
  // registers of the DSP48E2 support ONLY a synchronous reset. With an asynchronous one
  // Vivado could not pack a_r/b_r/prod_r/acc into AREG/BREG/MREG/PREG and would leave
  // them in the fabric → the DSP would run combinationally (~2 ns, ~500 MHz). Synchronous
  // reset → the registers move INTO the DSP → native frequency. `clear` keeps it correct.
  always_ff @(posedge clk) begin
    if (!rst_n) begin                       // SYNCHRONOUS (inside @(posedge clk))
      a_out <= '0; b_out <= '0;
      a_r   <= '0; b_r   <= '0; prod_r <= '0;
      acc   <= '0;
    end else if (clear) begin               // start of a new matmul: flush the whole pipeline
      a_out <= '0; b_out <= '0;
      a_r   <= '0; b_r   <= '0; prod_r <= '0;
      acc   <= '0;
    end else if (en) begin
      a_out  <= a_in;                        // pass-through right (skew, 1 cycle)
      b_out  <= b_in;                        // pass-through down  (skew, 1 cycle)
      a_r    <= a_in;                        // stage1: operand A register
      b_r    <= b_in;                        // stage1: operand B register
      prod_r <= a_r * b_r;                   // stage2: signed product (MREG)
      acc    <= acc + ACC_WIDTH'(prod_r);    // stage3: accumulate (PREG), 1-cycle loop
    end
  end

endmodule
