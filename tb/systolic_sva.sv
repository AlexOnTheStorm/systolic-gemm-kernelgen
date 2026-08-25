`timescale 1ns / 1ps
// =====================================================================
//  systolic_sva — формальный контракт PE в виде SVA-свойств.
//  Привязывается к КАЖДОМУ экземпляру pe через `bind` (внизу файла),
//  поэтому проверяет всю сетку разом. Идиома — как в ex6_fifo_sva.
//
//  Что доказываем (потактовый контракт ПАЙПЛАЙНА MAC из pe.sv, 3 ступени):
//    1. stage1 (AREG/BREG): a_r/b_r  == prev(a_in)/prev(b_in)       при en
//    2. stage2 (MREG):      prod_r   == prev(a_r) * prev(b_r)       при en
//    3. stage3 (PREG):      acc      == prev(acc) + prev(prod_r)    при en
//    4. passthrough:        a_out/b_out == prev(a_in)/prev(b_in)    при en
//    5. clear:              acc/пасс-through/весь конвейер == 0     на след. такте
//    6. hold:               при !en && !clear acc держится
//
//  Ступенчатая формулировка (а не end-to-end acc==f($past(a_in,3))) НАМЕРЕННО:
//  каждое свойство — одно-регистровая связь, gated по текущему en, поэтому
//  корректна независимо от истории (не ломается на границе clear/заполнения).
//  Это же наглядно документирует конвейер. a_r/b_r/prod_r — ВНУТРЕННИЕ сигналы
//  pe; bind `.*` видит их в области pe и подключает по имени.
//
//  Флаг --assert в Makefile включает проверку этих свойств в симуляции.
//  Конструкции $past / |=> / disable iff поддерживаются симулятором.
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
    input logic signed [DATA_WIDTH-1:0]    a_r,     // внутр. stage1 (AREG)
    input logic signed [DATA_WIDTH-1:0]    b_r,     // внутр. stage1 (BREG)
    input logic signed [2*DATA_WIDTH-1:0]  prod_r   // внутр. stage2 (MREG)
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // 1. stage1 — операнды защёлкнулись (clear имеет приоритет над en, как в RTL)
  a_op_a : assert property ( (en && !clear) |=> a_r == $past(a_in) );
  a_op_b : assert property ( (en && !clear) |=> b_r == $past(b_in) );

  // 2. stage2 — произведение = операнды прошлого такта (MREG)
  a_mult : assert property
      ( (en && !clear) |=> prod_r == ($past(a_r) * $past(b_r)) );

  // 3. stage3 — накопление на регистре произведения (PREG), петля 1 такт
  a_mac : assert property
      ( (en && !clear) |=> acc == $past(acc) + ACC_WIDTH'($past(prod_r)) );

  // 4. регистровый passthrough активации и операнда (держит систолический skew)
  a_pass_a : assert property ( (en && !clear) |=> a_out == $past(a_in) );
  a_pass_b : assert property ( (en && !clear) |=> b_out == $past(b_in) );

  // 5. clear флашит весь конвейер на следующем такте
  a_clear : assert property
      ( clear |=> (acc == '0 && a_out == '0 && b_out == '0 &&
                   a_r == '0 && b_r == '0 && prod_r == '0) );

  // 6. без en и без clear состояние держится
  a_hold : assert property ( (!en && !clear) |=> acc == $past(acc) );

endmodule

// привязать контракт к каждому PE. `.*` подключает и внутренние a_r/b_r/prod_r
// (видны в области pe), и параметры DATA_WIDTH/ACC_WIDTH берутся из самого pe.
bind pe pe_sva #(
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH (ACC_WIDTH)
) u_pe_sva (.*);
