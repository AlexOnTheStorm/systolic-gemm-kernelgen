`timescale 1ns / 1ps
// =====================================================================
//  systolic_sva — формальный контракт PE в виде SVA-свойств.
//  Привязывается к КАЖДОМУ экземпляру pe через `bind` (внизу файла),
//  поэтому проверяет всю сетку разом. Идиома — как в ex6_fifo_sva.
//
//  Что доказываем (потактовый контракт из pe.sv):
//    1. MAC:        acc     == prev(acc) + prev(a_in)*prev(b_in)   при en
//    2. passthrough a_out/b_out == prev(a_in)/prev(b_in)           при en
//    3. clear:      acc/a_out/b_out == 0 на следующем такте
//    4. hold:       при !en && !clear acc держится
//
//  Флаг --assert в Makefile включает проверку этих свойств в симуляции.
//  Конструкции $past / |=> / disable iff поддерживаются симулятором.
// =====================================================================
module pe_sva #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input logic                          clk,
    input logic                          rst_n,
    input logic                          clear,
    input logic                          en,
    input logic signed [DATA_WIDTH-1:0]  a_in,
    input logic signed [DATA_WIDTH-1:0]  b_in,
    input logic signed [DATA_WIDTH-1:0]  a_out,
    input logic signed [DATA_WIDTH-1:0]  b_out,
    input logic signed [ACC_WIDTH-1:0]   acc
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // 1. MAC точно совпадает с моделью (clear имеет приоритет над en, как в RTL)
  a_mac : assert property
      ( (en && !clear) |=> acc == $past(acc) + ACC_WIDTH'($past(a_in) * $past(b_in)) );

  // 2. регистровый passthrough активации и операнда
  a_pass_a : assert property ( (en && !clear) |=> a_out == $past(a_in) );
  a_pass_b : assert property ( (en && !clear) |=> b_out == $past(b_in) );

  // 3. clear обнуляет всё на следующем такте
  a_clear : assert property ( clear |=> (acc == '0 && a_out == '0 && b_out == '0) );

  // 4. без en и без clear состояние держится
  a_hold : assert property ( (!en && !clear) |=> acc == $past(acc) );

endmodule

// привязать контракт к каждому PE (параметры берутся из самого pe)
bind pe pe_sva #(
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH (ACC_WIDTH)
) u_pe_sva (.*);
