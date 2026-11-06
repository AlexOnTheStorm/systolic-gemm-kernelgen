`timescale 1ns / 1ps
// =====================================================================
//  systolic_sva — the PE contract as SVA properties.
//  Bound to EVERY pe instance via `bind` (at the bottom of the file),
//  so it checks the whole grid at once.
//
//  What is checked (cycle-level contract of the 3-stage MAC PIPELINE in pe.sv):
//    1. stage1 (AREG/BREG): a_r/b_r  == prev(a_in)/prev(b_in)       when en
//    2. stage2 (MREG):      prod_r   == prev(a_r) * prev(b_r)       when en
//    3. stage3 (PREG):      acc      == prev(acc) + prev(prod_r)    when en
//    4. passthrough:        a_out/b_out == prev(a_in)/prev(b_in)    when en
//    5. clear:              acc/pass-through/whole pipeline == 0    on the next cycle
//    6. hold:               with !en && !clear EVERY stage holds (a_r/b_r, prod_r,
//                           acc, a_out/b_out) — not only acc: a PE that kept loading
//                           operands during a pause would otherwise pass this contract
//
//  The per-stage formulation (rather than end-to-end acc==f($past(a_in,3))) is
//  DELIBERATE: each property is a single-register relation gated by the current en,
//  so it holds regardless of history (it does not break at a clear/fill boundary).
//  It also documents the pipeline. a_r/b_r/prod_r are INTERNAL pe signals;
//  bind `.*` sees them in the pe scope and connects them by name.
//
//  The --assert flag in the Makefile enables these properties in simulation.
//  $past / |=> / disable iff are supported by the simulator.
// =====================================================================
module pe_sva #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input logic                            clk,
    input logic                            rst_n,
    input logic                            clear,
    input logic                            en,
    input logic signed [DATA_WIDTH-1:0]    a_in,
    input logic signed [DATA_WIDTH-1:0]    b_in,
    input logic signed [DATA_WIDTH-1:0]    a_out,
    input logic signed [DATA_WIDTH-1:0]    b_out,
    input logic signed [ACC_WIDTH-1:0]     acc,
    input logic signed [DATA_WIDTH-1:0]    a_r,     // internal stage1 (AREG)
    input logic signed [DATA_WIDTH-1:0]    b_r,     // internal stage1 (BREG)
    input logic signed [2*DATA_WIDTH-1:0]  prod_r   // internal stage2 (MREG)
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // 1. stage1 — operands latched (clear has priority over en, as in the RTL)
  a_op_a : assert property ( (en && !clear) |=> a_r == $past(a_in) );
  a_op_b : assert property ( (en && !clear) |=> b_r == $past(b_in) );

  // 2. stage2 — product = operands of the previous cycle (MREG)
  a_mult : assert property
      ( (en && !clear) |=> prod_r == ($past(a_r) * $past(b_r)) );

  // 3. stage3 — accumulate the product register (PREG), 1-cycle loop
  a_mac : assert property
      ( (en && !clear) |=> acc == $past(acc) + ACC_WIDTH'($past(prod_r)) );

  // 4. registered pass-through of activation and operand (holds the systolic skew)
  a_pass_a : assert property ( (en && !clear) |=> a_out == $past(a_in) );
  a_pass_b : assert property ( (en && !clear) |=> b_out == $past(b_in) );

  // 5. clear flushes the whole pipeline on the next cycle
  a_clear : assert property
      ( clear |=> (acc == '0 && a_out == '0 && b_out == '0 &&
                   a_r == '0 && b_r == '0 && prod_r == '0) );

  // 6. without en and without clear the whole pipeline holds. Checking acc alone is
  //    not enough: a mutant that latches a_in into a_r during a pause keeps acc
  //    frozen and still passes, then corrupts the sum after en returns.
  a_hold : assert property
      ( (!en && !clear) |=> (acc   == $past(acc)   && prod_r == $past(prod_r) &&
                             a_r   == $past(a_r)   && b_r    == $past(b_r)    &&
                             a_out == $past(a_out) && b_out  == $past(b_out)) );

endmodule

// bind the contract to every PE. `.*` also connects the internal a_r/b_r/prod_r
// (visible in the pe scope); DATA_WIDTH/ACC_WIDTH are taken from the pe itself.
bind pe pe_sva #(
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH (ACC_WIDTH)
) u_pe_sva (.*);
