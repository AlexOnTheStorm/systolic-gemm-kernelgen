`timescale 1ns / 1ps
// =====================================================================
//  pe — один processing element систолического массива (output-stationary).
//
//  Роль: это ОДИН MAC. Массив C = A·B строится из сетки таких PE, где
//  каждый PE(i,j) накапливает ровно один выходной элемент C[i][j].
//
//  Контракт (output-stationary dataflow):
//    - Активация a течёт СЛЕВА-НАПРАВО: a_in -> (регистр) -> a_out.
//    - Вес/операнд b течёт СВЕРХУ-ВНИЗ:  b_in -> (регистр) -> b_out.
//    - Каждый такт при en:  acc <= acc + a_in * b_in   (знаковый MAC).
//    - Пасс-through РЕГИСТРОВЫЙ: a доезжает до соседа справа за 1 такт,
//      b — до соседа снизу за 1 такт. Именно это создаёт систолический
//      «волновой фронт»: PE(i,j) видит валидную пару (A[i][k],B[k][j])
//      на такте t = k + i + j (см. систолический skew в systolic_array.sv).
//    - Вне валидного окна на входах ПОДАЮТСЯ НУЛИ → нулевые произведения
//      не портят acc. Поэтому MAC можно делать безусловно (не гейтить по k).
//    - clear (1 такт, в простое) обнуляет acc и пасс-through регистры —
//      старт нового matmul.
//
//  Точность: вход DATA_WIDTH-бит ЗНАКОВЫЙ (INT8 по умолчанию),
//  аккумулятор ACC_WIDTH-бит знаковый (INT32). Произведение двух INT8 —
//  это 16 бит; при K до ~65536 сумма влезает в INT32 без переполнения
//  (граница проверяется в SVA и в модели).
// =====================================================================
module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          clear,   // обнулить acc (старт нового matmul)
    input  logic                          en,      // продвинуть конвейер на такт
    input  logic signed [DATA_WIDTH-1:0]  a_in,    // от левого соседа (или с левого края)
    input  logic signed [DATA_WIDTH-1:0]  b_in,    // от верхнего соседа (или с верхнего края)
    output logic signed [DATA_WIDTH-1:0]  a_out,   // к правому соседу
    output logic signed [DATA_WIDTH-1:0]  b_out,   // к нижнему соседу
    output logic signed [ACC_WIDTH-1:0]   acc      // накопленный C[i][j]
);

  // произведение двух знаковых DATA_WIDTH-операндов = знаковое 2*DATA_WIDTH.
  //
  // (* use_dsp = "yes" *): БЕЗ этого атрибута Vivado видит маленькое INT8×INT8
  // умножение и раскладывает его в LUT (DSP48 = 27×18, для 8×8 «жалко» занимать
  // целый блок) → синтез даёт DSP=0, ~100 LUT/PE. Атрибут форсирует умножитель
  // (а с ним и MAC-паттерн acc<=acc+a*b) в DSP48E2 → 1 DSP на PE. Это ВАЛИДИРУЕТ
  // ресурс-прокси P2 (PE≈DSP) синтезом. (⚠️ имя атрибута — вендор-специфично,
  // Xilinx/AMD; см. UG901 «USE_DSP».)
  (* use_dsp = "yes" *)
  logic signed [2*DATA_WIDTH-1:0] prod;
  assign prod = a_in * b_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (clear) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (en) begin
      a_out <= a_in;                      // активация едет вправо (1 такт)
      b_out <= b_in;                      // операнд едет вниз      (1 такт)
      acc   <= acc + ACC_WIDTH'(prod);    // знаковое расширение произведения
    end
  end

endmodule
