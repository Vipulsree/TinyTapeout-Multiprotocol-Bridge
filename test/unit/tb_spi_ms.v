`default_nettype none
`timescale 1ns / 1ps

// spi_ms behind the same synchroniser and divider as in project.v. In master
// mode the SPI device model watches cs_n / sck / mosi and drives miso_drv; in
// slave mode the SPI host model drives the *_drv inputs and watches miso.
module tb_spi_ms (
    input wire clk,
    input wire rst_n,
    input wire master,
    input wire slave,
    input wire [1:0] spi_div,
    input wire cs_n_drv,
    input wire sck_drv,
    input wire mosi_drv,
    input wire miso_drv,
    input wire [7:0] h_tx_data,
    input wire d_start,
    input wire [1:0] d_op,
    input wire [2:0] d_len,
    input wire d_abort,
    input wire [7:0] d_wr_data
);
  wire cs_n_o, sck_o, mosi_o, miso_o;
  wire cs_n = master ? cs_n_o : cs_n_drv;
  wire sck  = master ? sck_o : sck_drv;
  wire mosi = master ? mosi_o : mosi_drv;
  wire miso = master ? miso_drv : miso_o;

  wire [3:0] q, rise, fall;
  sync2_edge #(
      .N     (4),
      .INIT  (4'b0001),
      .FILTER(4'b0000)
  ) u_sync (
      .clk  (clk),
      .rst_n(rst_n),
      .d    ({miso, mosi, sck, cs_n}),
      .q    (q),
      .rise (rise),
      .fall (fall)
  );

  wire tick_en, tick;
  clkdiv #(
      .W(6)
  ) u_div (
      .clk   (clk),
      .rst_n (rst_n),
      .en    (tick_en),
      .div_m1((6'd4 << spi_div) - 6'd1),
      .tick  (tick)
  );

  wire [7:0] rx_data;
  wire h_rx_valid, h_frame_start, h_frame_end, h_tx_take;
  wire d_wr_pop, d_rd_push, d_done, idle;

  spi_ms dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .master       (master),
      .slave        (slave),
      .cs_n         (q[0]),
      .cs_fall      (fall[0]),
      .cs_rise      (rise[0]),
      .sck_rise     (rise[1]),
      .sck_fall     (fall[1]),
      .mosi         (q[2]),
      .miso         (q[3]),
      .cs_n_o       (cs_n_o),
      .sck_o        (sck_o),
      .mosi_o       (mosi_o),
      .miso_o       (miso_o),
      .tick_en      (tick_en),
      .tick         (tick),
      .rx_data      (rx_data),
      .h_rx_valid   (h_rx_valid),
      .h_frame_start(h_frame_start),
      .h_frame_end  (h_frame_end),
      .h_tx_data    (h_tx_data),
      .h_tx_take    (h_tx_take),
      .d_start      (d_start),
      .d_op         (d_op),
      .d_len        (d_len),
      .d_abort      (d_abort),
      .d_wr_data    (d_wr_data),
      .d_wr_pop     (d_wr_pop),
      .d_rd_push    (d_rd_push),
      .d_done       (d_done),
      .idle         (idle)
  );

  wire _unused = &{q[1], rise[3:2], fall[3:2], 1'b0};
endmodule
