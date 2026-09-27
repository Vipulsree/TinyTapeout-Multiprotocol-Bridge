/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// 8N1 UART engine (LSB first, as every UART sends). The receiver and the
// transmitter have their own bit timers, so RX and TX may overlap (loopback
// echo, or a UART device that answers during our stop bit).
//
// Roles, from the latched mode (at most one is set):
//   host : the UART peer is the host. RX bytes go to cmd_ctrl and the response
//          streams out on TX (modes 000, 001).
//   dev  : the UART peer is the device. Runs d_start transactions and hands every
//          RX byte to cmd_ctrl, which buffers it while idle (modes 010, 100).
//   loop : mode 110 self-test. Every RX byte is echoed on TX; cmd_ctrl sees nothing.
//
// The transmitter accepts the next byte during the stop bit of the current one
// and starts it straight after, so back-to-back bytes (and the echo of a host
// sending back-to-back) never lose a byte to a stop-bit race.
module uart_trx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] baud,     // BAUD_SEL: 00 9600, 01 19200, 10 57600, 11 115200
    input  wire       host,
    input  wire       dev,
    input  wire       loop,
    input  wire       rx,       // synchronised UART_RX level
    input  wire       rx_fall,  // one-cycle pulse: UART_RX fell
    output reg        tx,       // UART_TX pin level (idles high), registered: glitch-free

    // Host role
    output wire [7:0] h_rx_data,
    output wire       h_rx_valid,
    input  wire [7:0] h_tx_data,
    input  wire       h_tx_valid,
    output wire       h_tx_take,

    // Device role
    input  wire       d_start,
    input  wire [1:0] d_op,
    input  wire [2:0] d_len,
    input  wire       d_abort,
    input  wire [7:0] d_wr_data,
    output wire       d_wr_pop,
    output wire [7:0] d_rd_data,
    output wire       d_rd_push,
    output reg        d_done,

    output wire frame_err,  // one-cycle pulse: a stop bit was 0 (any role)
    output wire idle        // nothing on the wire and no device transaction running
);

  localparam [1:0] OP_WRITE = 2'd0, OP_WRRD = 2'd2;

  // Clocks per bit - 1 at 25 MHz: 2604 / 1302 / 434 / 217 clocks per bit.
  wire [11:0] div_m1 = (baud == 2'b00) ? 12'd2603 : (baud == 2'b01) ? 12'd1301 :
                       (baud == 2'b10) ? 12'd433 : 12'd216;

  // ---------------------------------------------------------------- receiver
  reg        r_busy;
  reg [ 3:0] r_bit;  // 0 start, 1-8 data, 9 stop
  reg [11:0] r_cnt;
  reg [ 7:0] r_sh;

  wire r_en     = host | dev | loop;
  wire r_sample = r_busy & (r_cnt == 12'd0);
  wire r_stop   = r_sample & (r_bit == 4'd9);
  wire r_valid  = r_stop & rx;
  assign frame_err = r_stop & ~rx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_busy <= 1'b0;
      r_bit  <= 4'd0;
      r_cnt  <= 12'd0;
      r_sh   <= 8'h00;
    end else if (!r_busy) begin
      if (r_en && rx_fall) begin  // start bit: sample every bit in its middle
        r_busy <= 1'b1;
        r_bit  <= 4'd0;
        r_cnt  <= {1'b0, div_m1[11:1]};
      end
    end else if (!r_sample) begin
      r_cnt <= r_cnt - 12'd1;
    end else begin
      r_cnt <= div_m1;
      r_bit <= r_bit + 4'd1;
      if (r_bit == 4'd0) begin
        if (rx) r_busy <= 1'b0;  // glitch, not a start bit
      end else if (r_bit == 4'd9) begin
        r_busy <= 1'b0;
      end else begin
        r_sh <= {rx, r_sh[7:1]};
      end
    end
  end

  // ---------------------------------------------------------------- transmitter
  reg        t_busy;
  reg [ 3:0] t_bit;   // 0 start, 1-8 data, 9 stop
  reg [11:0] t_cnt;
  reg [ 7:0] t_sh;
  reg        t_pend;  // next byte already loaded during the stop bit

  reg       dv_on;   // device transaction running
  reg [2:0] dv_ntx;  // bytes still to transmit
  reg [2:0] dv_nrx;  // reply bytes still expected

  wire t_last  = t_busy & (t_bit == 4'd9);
  wire t_ready = ~t_busy | (t_last & ~t_pend);
  wire t_go    = (loop & r_valid) | (host & h_tx_valid) | (dev & dv_on & (dv_ntx != 3'd0));
  wire t_load  = t_ready & t_go;
  wire t_tick  = t_busy & (t_cnt == 12'd0);
  wire [7:0] t_data = loop ? r_sh : dev ? d_wr_data : h_tx_data;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_busy <= 1'b0;
      t_bit  <= 4'd0;
      t_cnt  <= 12'd0;
      t_sh   <= 8'h00;
      t_pend <= 1'b0;
      tx     <= 1'b1;
    end else begin
      tx <= ~t_busy | (t_bit == 4'd9) | ((t_bit != 4'd0) & t_sh[0]);
      if (t_load) t_sh <= t_data;
      if (!t_busy) begin
        if (t_load) begin
          t_busy <= 1'b1;
          t_bit  <= 4'd0;
          t_cnt  <= div_m1;
        end
      end else begin
        if (t_load) t_pend <= 1'b1;
        if (!t_tick) begin
          t_cnt <= t_cnt - 12'd1;
        end else begin
          t_cnt <= div_m1;
          if (t_last) begin  // end of the stop bit: next byte or idle
            t_bit  <= 4'd0;
            t_pend <= 1'b0;
            t_busy <= t_pend | t_load;
          end else begin
            t_bit <= t_bit + 4'd1;
            if (t_bit != 4'd0) t_sh <= {1'b0, t_sh[7:1]};
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- device sequencer
  // Write: send d_len bytes. Write-then-read: send 1 byte, then count d_len reply
  // bytes (a shorter reply is ended by the controller's reply window, d_abort).
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dv_on  <= 1'b0;
      dv_ntx <= 3'd0;
      dv_nrx <= 3'd0;
      d_done <= 1'b0;
    end else begin
      d_done <= 1'b0;
      if (!dev || d_abort) begin
        dv_on <= 1'b0;
      end else if (d_start) begin
        dv_on  <= 1'b1;
        dv_ntx <= (d_op == OP_WRITE) ? d_len : (d_op == OP_WRRD) ? 3'd1 : 3'd0;
        dv_nrx <= (d_op == OP_WRITE) ? 3'd0 : d_len;
      end else if (dv_on) begin
        if (t_load) dv_ntx <= dv_ntx - 3'd1;
        if (r_valid && dv_nrx != 3'd0) dv_nrx <= dv_nrx - 3'd1;
        if (dv_ntx == 3'd0 && dv_nrx == 3'd0 && !t_busy) begin
          dv_on  <= 1'b0;
          d_done <= 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------- role outputs
  assign h_rx_data  = r_sh;
  assign h_rx_valid = host & r_valid;
  assign h_tx_take  = host & t_load;
  assign d_rd_data  = r_sh;
  assign d_rd_push  = dev & r_valid;
  assign d_wr_pop   = dev & t_load;
  assign idle       = ~r_busy & ~t_busy & ~dv_on;

endmodule
