/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Transaction controller for the six-mode bridge.
// Parses the 2-byte header (CMD, ADDR), owns the FIFO and runs
//   IDLE -> HEADER -> WRITE -> EXEC -> RESPOND
// for every host/device pairing. The handshake contract with the host and
// device engines is documented in docs/architecture.md.
//
// CMD[7:6] op: 00 write, 01 read, 10 write 1 byte then read, 11 status
// CMD[3:2] SPI_DIV (SPI device only), CMD[1:0] LEN-1, ADDR[6:0] I2C address.
// Status byte: [7] NACK, [6] UART framing error, [5] FIFO overflow,
//              [4] timeout, [3] reserved (0), [2:0] FIFO count.
//
// Timeouts (one shared 21-bit counter, restarted by any handshake):
//  - HEADER / WRITE / read-out: the host went silent -> drop to IDLE, set timeout.
//  - EXEC: the device transaction ran too long -> pulse d_abort, respond with
//    timeout set. For a UART device write-then-read the limit is the reply
//    window instead: expiry ends the reply normally, without an error.
module cmd_ctrl (
    input wire clk,
    input wire rst_n,

    // Latched mode, decoded
    input wire host_uart,  // host is a UART peer: no frames, the response streams out
    input wire dev_uart,   // device is a UART peer: RX bytes are buffered while idle

    // Host engine -> controller
    input wire [7:0] h_rx_data,
    input wire       h_rx_valid,     // one-cycle pulse per byte from the host
    input wire       h_frame_start,  // framed hosts: SPI CS fell, or I2C address matched
    input wire       h_frame_rd,     // with h_frame_start: 1 = read-out frame (SPI: always 1)
    input wire       h_frame_end,    // framed hosts: SPI CS rose, or I2C STOP

    // Controller -> host engine (response)
    output wire [7:0] h_tx_data,  // current response byte; 0x00 once the response is used up
    output wire       h_tx_valid, // response bytes remain
    input  wire       h_tx_take,  // host engine consumed h_tx_data

    // Controller -> device engine
    output reg        d_start,    // one-cycle pulse: run the device transaction
    output reg  [1:0] d_op,
    output reg  [2:0] d_len,      // 1..4
    output reg  [6:0] d_addr,
    output reg  [1:0] d_spi_div,
    input  wire       d_done,     // one-cycle pulse: device transaction finished
    input  wire       d_nack,     // one-cycle pulse: I2C device did not acknowledge
    output reg        d_abort,    // one-cycle pulse: stop the transaction and release the bus

    // FIFO access for the device engine
    output wire [7:0] d_wr_data,   // next write byte (FIFO head)
    output wire       d_wr_avail,
    input  wire       d_wr_pop,
    input  wire [7:0] d_rd_data,
    input  wire       d_rd_push,   // read byte, or a buffered UART RX byte

    input wire frame_err,  // UART framing error pulse (either role)

    // Timeout limits in clock cycles: powers of two (0 disables), chosen per mode in project.v
    input wire [20:0] to_host_limit,  // silence allowed from the host mid-command or mid-read-out
    input wire [20:0] to_dev_limit,   // silence allowed from the device during EXEC

    // Status
    output wire [2:0] state,      // DBG_STATE: 0 IDLE, 1 HEADER, 2 WRITE, 3 EXEC, 4 RESPOND
    output wire       idle,
    output wire       can_read,   // a response is waiting (I2C target ACKs a read)
    output wire       can_write,  // not running a device transaction (I2C target ACKs a write)
    output wire       irq,
    output wire       busy,
    output wire       err
);

  localparam [2:0] S_IDLE = 3'd0, S_HEADER = 3'd1, S_WRITE = 3'd2, S_EXEC = 3'd3, S_RESPOND = 3'd4;
  localparam [1:0] OP_WRITE = 2'd0, OP_READ = 2'd1, OP_WRRD = 2'd2, OP_STATUS = 2'd3;

  reg [2:0] st;
  reg [2:0] rem;         // payload bytes still expected, or response bytes still to send
  reg       exec_first;  // first cycle in EXEC
  reg       rsp_status;  // response is the status byte rather than FIFO data
  reg       reading;     // framed host has opened its read-out frame
  reg f_nack, f_frame, f_ovf, f_timeout;

  // ---------------------------------------------------------------- FIFO
  wire       fifo_full, fifo_empty;
  wire [2:0] fifo_count;
  wire [7:0] fifo_rdata;

  wire hdr_done = (st == S_HEADER) & h_rx_valid & ~h_frame_end;
  wire host_push = (st == S_WRITE) & h_rx_valid & ~h_frame_end;
  wire dev_ok = (st == S_EXEC) |
                (dev_uart & ((st == S_IDLE) | (st == S_HEADER) | (st == S_RESPOND)));
  wire dev_push = d_rd_push & dev_ok;
  wire fifo_push = host_push | dev_push;
  wire [7:0] fifo_wdata = host_push ? h_rx_data : d_rd_data;
  // Framed hosts consume response bytes only inside a read-out frame: the SPI
  // slave also loads a byte at the end of the command frame, which must not count.
  wire rsp_live = host_uart | reading | (h_frame_start & h_frame_rd);
  wire rsp_take = (st == S_RESPOND) & h_tx_take & rsp_live;
  wire rsp_pop = rsp_take & ~rsp_status & (rem != 3'd0);
  wire fifo_pop = d_wr_pop | rsp_pop;
  // Keep buffered UART RX bytes for a read or status; otherwise start clean.
  wire keep_fifo = dev_uart & ((d_op == OP_READ) | (d_op == OP_STATUS));
  wire fifo_clr = hdr_done & ~keep_fifo;
  wire ovf_evt = fifo_push & fifo_full & ~fifo_pop;

  fifo4x8 u_fifo (
      .clk  (clk),
      .rst_n(rst_n),
      .clr  (fifo_clr),
      .push (fifo_push),
      .wdata(fifo_wdata),
      .pop  (fifo_pop),
      .rdata(fifo_rdata),
      .full (fifo_full),
      .empty(fifo_empty),
      .count(fifo_count)
  );

  wire [7:0] status_byte = {f_nack, f_frame, f_ovf, f_timeout, 1'b0, fifo_count};

  // Decoded from the stored CMD byte
  wire [2:0] pay_len = (d_op == OP_WRITE) ? d_len : (d_op == OP_WRRD) ? 3'd1 : 3'd0;
  wire skip_dev = (d_op == OP_STATUS) | (dev_uart & (d_op == OP_READ));
  wire rsp_is_status = (d_op == OP_WRITE) | (d_op == OP_STATUS);
  wire reply_window = dev_uart & (d_op == OP_WRRD);  // EXEC expiry is a normal end

  // ---------------------------------------------------------------- timeout
  wire to_run = (st == S_HEADER) | (st == S_WRITE) | (st == S_EXEC) |
                ((st == S_RESPOND) & (host_uart | reading));
  wire to_kick = h_rx_valid | h_tx_take | h_frame_start | d_wr_pop | d_rd_push | d_done | exec_first;
  wire to_exp;

  timeout20 #(
      .W(21)
  ) u_timeout (
      .clk    (clk),
      .rst_n  (rst_n),
      .run    (to_run),
      .kick   (to_kick),
      .limit  ((st == S_EXEC) ? to_dev_limit : to_host_limit),
      .expired(to_exp)
  );

  // ---------------------------------------------------------------- command fields
  // Data only, so no reset: engines read them only after d_start. (d_op keeps
  // its reset because the controller's own decode reads it.)
  always @(posedge clk) begin
    if (st == S_IDLE && h_rx_valid) begin
      d_spi_div <= h_rx_data[3:2];
      d_len     <= {1'b0, h_rx_data[1:0]} + 3'd1;
    end
    if (hdr_done) d_addr <= h_rx_data[6:0];  // a timeout never coincides with a byte
  end

  // ---------------------------------------------------------------- FSM
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= S_IDLE;
      rem        <= 3'd0;
      exec_first <= 1'b0;
      rsp_status <= 1'b0;
      reading    <= 1'b0;
      d_start    <= 1'b0;
      d_abort    <= 1'b0;
      d_op       <= OP_WRITE;
      f_nack     <= 1'b0;
      f_frame    <= 1'b0;
      f_ovf      <= 1'b0;
      f_timeout  <= 1'b0;
    end else begin
      d_start <= 1'b0;
      d_abort <= 1'b0;

      case (st)
        S_IDLE:
        if (h_rx_valid) begin
          d_op <= h_rx_data[7:6];
          st   <= S_HEADER;
        end

        S_HEADER:
        if (h_frame_end) st <= S_IDLE;  // frame ended before the header was complete
        else if (to_exp) begin          // host went silent mid-header
          st        <= S_IDLE;
          f_timeout <= 1'b1;
        end else if (h_rx_valid) begin
          if (d_op != OP_STATUS) begin
            f_nack    <= 1'b0;
            f_frame   <= 1'b0;
            f_ovf     <= 1'b0;
            f_timeout <= 1'b0;
          end
          if (pay_len == 3'd0) begin
            st         <= S_EXEC;
            exec_first <= 1'b1;
          end else begin
            rem <= pay_len;
            st  <= S_WRITE;
          end
        end

        S_WRITE:
        if (h_frame_end) st <= S_IDLE;  // frame ended before the payload was complete
        else if (to_exp) begin          // host went silent mid-payload
          st        <= S_IDLE;
          f_timeout <= 1'b1;
        end else if (h_rx_valid) begin
          rem <= rem - 3'd1;
          if (rem == 3'd1) begin
            st         <= S_EXEC;
            exec_first <= 1'b1;
          end
        end

        S_EXEC: begin
          exec_first <= 1'b0;
          if (exec_first) begin
            if (skip_dev) begin
              st         <= S_RESPOND;
              rsp_status <= rsp_is_status;
              rem        <= rsp_is_status ? 3'd1 : d_len;
              reading    <= 1'b0;
            end else begin
              d_start <= 1'b1;
            end
          end else if (d_done || to_exp) begin
            st         <= S_RESPOND;
            rsp_status <= rsp_is_status;
            rem        <= rsp_is_status ? 3'd1 : d_len;
            reading    <= 1'b0;
            if (to_exp) begin
              d_abort <= 1'b1;
              if (!reply_window) f_timeout <= 1'b1;
            end
          end
        end

        S_RESPOND: begin
          if (rsp_take && rem != 3'd0) rem <= rem - 3'd1;
          if (to_exp) begin  // host stopped reading (or the UART host engine stalled)
            st        <= S_IDLE;
            f_timeout <= 1'b1;
          end else if (host_uart) begin
            if (rem == 3'd0) st <= S_IDLE;
          end else if (h_frame_start) begin
            if (h_frame_rd) reading <= 1'b1;
            else st <= S_IDLE;  // I2C host started a new write: drop the response
          end else if (reading && h_frame_end) begin
            st <= S_IDLE;
          end
        end

        default: st <= S_IDLE;
      endcase

      // Error flags: a set event wins over the clear at HEADER.
      if (d_nack) f_nack <= 1'b1;
      if (frame_err) f_frame <= 1'b1;
      if (ovf_evt) f_ovf <= 1'b1;
    end
  end

  // ---------------------------------------------------------------- outputs
  assign state      = st;
  assign idle       = (st == S_IDLE);
  assign can_read   = (st == S_RESPOND);
  assign can_write  = (st != S_EXEC);
  assign irq        = (st == S_RESPOND) | (dev_uart & (st == S_IDLE) & ~fifo_empty);
  assign busy       = (st == S_EXEC) | (host_uart & (st == S_RESPOND));
  assign err        = f_nack | f_frame | f_ovf | f_timeout;
  assign h_tx_valid = (st == S_RESPOND) & (rem != 3'd0);
  assign h_tx_data  = h_tx_valid ? (rsp_status ? status_byte : fifo_rdata) : 8'h00;
  assign d_wr_data  = fifo_rdata;
  assign d_wr_avail = ~fifo_empty;

endmodule
