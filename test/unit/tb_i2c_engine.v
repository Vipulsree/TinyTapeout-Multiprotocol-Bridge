`default_nettype none
`timescale 1ns / 1ps

// i2c_engine on an open-drain bus with pull-ups, behind the same synchroniser
// (2-sample glitch filter) and divider as in project.v. The test plays cmd_ctrl.
module tb_i2c_engine (
    input wire clk,
    input wire rst_n,
    input wire ctl,
    input wire tgt,
    input wire addr_lsb,
    input wire fast,
    input wire ext_scl_pull,  // external controller or stretching device
    input wire ext_sda_pull,
    // host role
    input wire [7:0] h_tx_data,
    input wire can_read,
    input wire can_write,
    // device role
    input wire d_start,
    input wire [1:0] d_op,
    input wire [2:0] d_len,
    input wire [6:0] d_addr,
    input wire d_abort,
    input wire [7:0] d_wr_data
);
  wire scl_low, sda_low;
  wire scl = ~(scl_low | ext_scl_pull);
  wire sda = ~(sda_low | ext_sda_pull);

  wire [1:0] q, rise, fall;
  sync2_edge #(
      .N     (2),
      .INIT  (2'b11),
      .FILTER(2'b11)
  ) u_sync (
      .clk  (clk),
      .rst_n(rst_n),
      .d    ({sda, scl}),
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
      .div_m1(fast ? 6'd16 : 6'd62),
      .tick  (tick)
  );

  wire [7:0] rx_data;
  wire h_rx_valid, h_frame_start, h_frame_rd, h_frame_end, h_tx_take;
  wire d_wr_pop, d_rd_push, d_done, d_nack, idle;

  i2c_engine dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .ctl          (ctl),
      .tgt          (tgt),
      .addr_lsb     (addr_lsb),
      .scl          (q[0]),
      .sda          (q[1]),
      .scl_rise     (rise[0]),
      .scl_fall     (fall[0]),
      .sda_rise     (rise[1]),
      .sda_fall     (fall[1]),
      .scl_low      (scl_low),
      .sda_low      (sda_low),
      .tick_en      (tick_en),
      .tick         (tick),
      .rx_data      (rx_data),
      .h_rx_valid   (h_rx_valid),
      .h_frame_start(h_frame_start),
      .h_frame_rd   (h_frame_rd),
      .h_frame_end  (h_frame_end),
      .h_tx_data    (h_tx_data),
      .h_tx_take    (h_tx_take),
      .can_read     (can_read),
      .can_write    (can_write),
      .d_start      (d_start),
      .d_op         (d_op),
      .d_len        (d_len),
      .d_addr       (d_addr),
      .d_abort      (d_abort),
      .d_wr_data    (d_wr_data),
      .d_wr_pop     (d_wr_pop),
      .d_rd_push    (d_rd_push),
      .d_done       (d_done),
      .d_nack       (d_nack),
      .idle         (idle)
  );
endmodule
