`default_nettype none
`timescale 1ns / 1ps

// uart_trx behind the same synchroniser as in project.v. The test plays cmd_ctrl.
module tb_uart_trx (
    input wire clk,
    input wire rst_n,
    input wire [1:0] baud,
    input wire host,
    input wire dev,
    input wire loop,
    input wire rx_pin,  // driven by the UART model
    input wire [7:0] h_tx_data,
    input wire h_tx_valid,
    input wire d_start,
    input wire [1:0] d_op,
    input wire [2:0] d_len,
    input wire d_abort,
    input wire [7:0] d_wr_data
);
  wire q, rise, fall;
  sync2_edge #(
      .N     (1),
      .INIT  (1'b1),
      .FILTER(1'b0)
  ) u_sync (
      .clk  (clk),
      .rst_n(rst_n),
      .d    (rx_pin),
      .q    (q),
      .rise (rise),
      .fall (fall)
  );

  wire tx;
  wire [7:0] h_rx_data, d_rd_data;
  wire h_rx_valid, h_tx_take, d_wr_pop, d_rd_push, d_done, frame_err, idle;

  uart_trx dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .baud      (baud),
      .host      (host),
      .dev       (dev),
      .loop      (loop),
      .rx        (q),
      .rx_fall   (fall),
      .tx        (tx),
      .h_rx_data (h_rx_data),
      .h_rx_valid(h_rx_valid),
      .h_tx_data (h_tx_data),
      .h_tx_valid(h_tx_valid),
      .h_tx_take (h_tx_take),
      .d_start   (d_start),
      .d_op      (d_op),
      .d_len     (d_len),
      .d_abort   (d_abort),
      .d_wr_data (d_wr_data),
      .d_wr_pop  (d_wr_pop),
      .d_rd_data (d_rd_data),
      .d_rd_push (d_rd_push),
      .d_done    (d_done),
      .frame_err (frame_err),
      .idle      (idle)
  );

  wire _unused = &{rise, 1'b0};
endmodule
