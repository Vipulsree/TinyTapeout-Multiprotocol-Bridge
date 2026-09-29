/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// I2C engine: controller on the device side (modes 001 / 011). Both lines are
// open-drain: the engine only ever pulls low. (The I2C target role for modes
// 100 / 101 was removed to fit the 1x1 tile; see docs/architecture.md.)
//
// Every START, STOP and bit is one symbol of four quarter periods (clkdiv
// ticks):  A  SCL low, SDA changes | B  SCL released; waits while a device
// stretches it | C  SCL high | D  SCL pulled low.  SDA is sampled at the
// B -> C tick, so a stretched clock never shortens the high time. The line
// drivers are registered, one clock behind the phase counter.
module i2c_engine (
    input wire clk,
    input wire rst_n,
    input wire ctl,  // controller role selected

    // Synchronised, glitch-filtered bus
    input wire scl,
    input wire sda,

    // Open-drain pull-downs
    output wire scl_low,
    output wire sda_low,

    // clkdiv (quarter-period ticks)
    output wire tick_en,
    input  wire tick,

    // cmd_ctrl (device role)
    input  wire       d_start,
    input  wire [1:0] d_op,
    input  wire [2:0] d_len,
    input  wire [6:0] d_addr,
    input  wire       d_abort,
    input  wire [7:0] d_wr_data,
    output wire       d_wr_pop,
    output wire [7:0] rx_data,   // byte read, with d_rd_push
    output wire       d_rd_push,
    output reg        d_done,
    output reg        d_nack,

    output wire idle
);

  localparam [1:0] OP_READ = 2'd1, OP_WRRD = 2'd2;
  localparam [2:0] C_IDLE = 3'd0, C_START = 3'd1, C_ADDR = 3'd2, C_WR = 3'd3, C_RD = 3'd4,
                   C_STOP = 3'd5;
  localparam [1:0] PA = 2'd0, PB = 2'd1, PC = 2'd2, PD = 2'd3;

  reg [7:0] sh;
  reg [3:0] bcnt;       // bits of the current byte, 8 = ACK slot
  reg [2:0] c_st;
  reg [1:0] ph;
  reg [2:0] c_cnt;      // bytes left in this phase, including the current one
  reg       c_started;  // bus owned: START sent, STOP not yet
  reg       c_second;   // write-then-read: now in the read phase after Sr
  reg       c_nack;
  reg       c_abort;    // d_abort: finish with STOP, ignore stretching, no d_done
  reg       samp;       // SDA sampled at the B -> C tick
  reg       c_scl_q;    // registered line drivers: the decode below glitches between
  reg       c_sda_q;    // states, and a glitch on SCL or SDA is a clock edge or a START

  wire c_on     = ctl & (c_st != C_IDLE);
  wire c_hold   = (ph == PB) & ~scl & ~c_abort;  // a device is stretching SCL
  wire c_tick   = c_on & tick;
  wire c_symend = c_tick & (ph == PD);
  wire c_ackbit = (bcnt == 4'd8);
  wire c_last   = (c_cnt == 3'd1);
  wire c_rnw    = (d_op == OP_READ) | c_second;
  wire c_bytes  = (c_st == C_ADDR) | (c_st == C_WR) | (c_st == C_RD);
  wire c_acked  = c_bytes & c_symend & c_ackbit & ~samp;

  // Level the controller puts on SDA in a data symbol (1 = released):
  // reads release the data bits and ACK every byte but the last.
  wire c_bit = (c_st == C_RD) ? ~(c_ackbit & ~c_last) : (c_ackbit | sh[7]);

  wire c_scl_low = c_on & (((ph == PA) & ((c_st != C_START) | c_started)) |
                           ((ph == PD) & (c_st != C_STOP)));
  wire c_sda_low = c_on & ((c_st == C_START) ? ph[1] :           // C, D
                           (c_st == C_STOP)  ? ~ph[1] : ~c_bit);  // A, B

  assign tick_en   = c_on & ~c_hold;
  assign d_wr_pop  = c_acked & (((c_st == C_ADDR) & ~c_rnw) | ((c_st == C_WR) & ~c_last));
  assign d_rd_push = c_symend & (c_st == C_RD) & (bcnt == 4'd7);

  // ---------------------------------------------------------------- shift register
  // Data only, so no reset: every use follows a load.
  wire c_shreg = ctl & ~d_abort & ~d_start & c_symend;  // symbol boundary

  always @(posedge clk) begin
    if (c_shreg) begin
      if (c_st == C_START) sh <= {d_addr, c_rnw};
      else if (c_bytes && !c_ackbit) sh <= {sh[6:0], samp};
      else if (c_bytes && !samp && ((c_st == C_ADDR && !c_rnw) || (c_st == C_WR && !c_last)))
        sh <= d_wr_data;  // next byte to write
    end
  end

  // ---------------------------------------------------------------- control
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bcnt      <= 4'd0;
      c_st      <= C_IDLE;
      ph        <= PA;
      c_cnt     <= 3'd0;
      c_started <= 1'b0;
      c_second  <= 1'b0;
      c_nack    <= 1'b0;
      c_abort   <= 1'b0;
      samp      <= 1'b1;
      c_scl_q   <= 1'b0;
      c_sda_q   <= 1'b0;
      d_done    <= 1'b0;
      d_nack    <= 1'b0;
    end else begin
      d_done  <= 1'b0;
      d_nack  <= 1'b0;
      c_scl_q <= c_scl_low;
      c_sda_q <= c_sda_low;

      if (!ctl) begin
        c_st      <= C_IDLE;
        c_started <= 1'b0;
      end else if (d_abort) begin
        if (c_st != C_IDLE) begin
          c_st    <= C_STOP;
          ph      <= PA;
          c_abort <= 1'b1;
        end
      end else if (d_start) begin
        c_st      <= C_START;
        ph        <= PA;
        c_cnt     <= (d_op == OP_WRRD) ? 3'd1 : d_len;
        c_started <= 1'b0;
        c_second  <= 1'b0;
        c_nack    <= 1'b0;
        c_abort   <= 1'b0;
      end else if (c_tick) begin
        ph <= ph + 2'd1;
        if (ph == PB) samp <= sda;
        if (ph == PD) begin
          case (c_st)
            C_START: begin
              c_started <= 1'b1;
              c_st      <= C_ADDR;
              bcnt      <= 4'd0;
            end
            C_ADDR, C_WR, C_RD:
            if (!c_ackbit) begin
              bcnt <= bcnt + 4'd1;
            end else begin
              bcnt <= 4'd0;
              if (c_st != C_RD && samp) begin  // address or data NACKed
                c_nack <= 1'b1;
                c_st   <= C_STOP;
              end else if (c_st == C_ADDR) begin
                c_st <= c_rnw ? C_RD : C_WR;
              end else if (!c_last) begin
                c_cnt <= c_cnt - 3'd1;
              end else if (c_st == C_WR && d_op == OP_WRRD && !c_second) begin
                c_second <= 1'b1;  // repeated START, then the read phase
                c_cnt    <= d_len;
                c_st     <= C_START;
              end else begin
                c_st <= C_STOP;
              end
            end
            C_STOP: begin
              c_st      <= C_IDLE;
              c_started <= 1'b0;
              if (!c_abort) begin
                d_done <= 1'b1;
                d_nack <= c_nack;
              end
            end
            default: c_st <= C_IDLE;
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------- outputs
  assign rx_data = {sh[6:0], samp};
  assign scl_low = c_scl_q;
  assign sda_low = c_sda_q;
  assign idle    = ~c_on;

endmodule
