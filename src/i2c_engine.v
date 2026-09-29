/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// I2C engine: controller (device side, modes 001 / 011) and target (host side,
// modes 100 / 101) on one shift register and bit counter. Only one role is
// active per mode. Both lines are open-drain: the engine only ever pulls low.
//
// Controller: every START, STOP and bit is one symbol of four quarter periods
// (clkdiv ticks):  A  SCL low, SDA changes | B  SCL released; waits while a
// device stretches it | C  SCL high | D  SCL pulled low.  SDA is sampled at the
// B -> C tick, so a stretched clock never shortens the high time. The line
// drivers are registered, one clock behind the phase counter.
//
// Target: address 7'b010110x (0x2C / 0x2D), LSB from I2C_ADDR_LSB. It ACKs its
// address for a write only while can_write, for a read only while can_read, and
// NACKs otherwise (it never stretches the clock). SDA changes only after SCL falls.
module i2c_engine (
    input wire clk,
    input wire rst_n,
    input wire ctl,       // controller role
    input wire tgt,       // target role
    input wire addr_lsb,  // target address LSB

    // Synchronised, glitch-filtered bus
    input wire scl,
    input wire sda,
    input wire scl_rise,
    input wire scl_fall,
    input wire sda_rise,
    input wire sda_fall,

    // Open-drain pull-downs
    output wire scl_low,
    output wire sda_low,

    // clkdiv (quarter-period ticks)
    output wire tick_en,
    input  wire tick,

    // Host role (target)
    output wire [7:0] rx_data,        // received byte, with h_rx_valid or d_rd_push
    output wire       h_rx_valid,
    output wire       h_frame_start,  // own address ACKed
    output wire       h_frame_rd,     // with h_frame_start: R/W bit
    output wire       h_frame_end,    // STOP after an ACKed address
    input  wire [7:0] h_tx_data,
    output wire       h_tx_take,
    input  wire       can_read,
    input  wire       can_write,

    // Device role (controller)
    input  wire       d_start,
    input  wire [1:0] d_op,
    input  wire [2:0] d_len,
    input  wire [6:0] d_addr,
    input  wire       d_abort,
    input  wire [7:0] d_wr_data,
    output wire       d_wr_pop,
    output wire       d_rd_push,
    output reg        d_done,
    output reg        d_nack,

    output wire idle
);

  localparam [1:0] OP_READ = 2'd1, OP_WRRD = 2'd2;

  reg [7:0] sh;
  reg [3:0] bcnt;  // bits of the current byte, 8 = ACK slot

  // ================================================================ controller
  localparam [2:0] C_IDLE = 3'd0, C_START = 3'd1, C_ADDR = 3'd2, C_WR = 3'd3, C_RD = 3'd4,
                   C_STOP = 3'd5;
  localparam [1:0] PA = 2'd0, PB = 2'd1, PC = 2'd2, PD = 2'd3;

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

  // ================================================================ target
  localparam [2:0] T_IDLE = 3'd0, T_ADDR = 3'd1, T_WR = 3'd2, T_ACK = 3'd3, T_RD = 3'd4,
                   T_RACK = 3'd5, T_WAIT = 3'd6;

  reg [2:0] t_st;
  reg       t_sda;   // pulling SDA low
  reg       t_rw;    // current transfer is a read
  reg       t_ours;  // own address ACKed since the last STOP
  reg       t_mack;  // controller ACKed the byte we sent

  wire t_start = tgt & sda_fall & scl;  // START or repeated START
  wire t_stop  = tgt & sda_rise & scl;
  wire t_rx    = (t_st == T_ADDR) | (t_st == T_WR);
  wire t_byte  = tgt & ~t_start & ~t_stop & t_rx & scl_fall & (bcnt == 4'd8);
  wire t_match = (sh[7:1] == {6'b010110, addr_lsb}) & (sh[0] ? can_read : can_write);
  wire t_load  = tgt & ~t_start & ~t_stop & scl_fall &
                 (((t_st == T_ACK) & t_rw) | ((t_st == T_RACK) & t_mack));

  assign h_frame_start = t_byte & (t_st == T_ADDR) & t_match;
  assign h_frame_rd    = sh[0];
  assign h_rx_valid    = t_byte & (t_st == T_WR);
  assign h_frame_end   = t_stop & t_ours;
  assign h_tx_take     = t_load;

  // ================================================================ shift register
  // Data only, so no reset: every use follows a load. Controller and target
  // never run together, so the two halves below never compete.
  wire c_shreg = ctl & ~d_abort & ~d_start & c_symend;  // controller symbol boundary
  wire t_shreg = tgt & ~t_start & ~t_stop;

  always @(posedge clk) begin
    if (c_shreg) begin
      if (c_st == C_START) sh <= {d_addr, c_rnw};
      else if (c_bytes && !c_ackbit) sh <= {sh[6:0], samp};
      else if (c_bytes && !samp && ((c_st == C_ADDR && !c_rnw) || (c_st == C_WR && !c_last)))
        sh <= d_wr_data;  // next byte to write
    end else if (t_shreg) begin
      if (t_load) sh <= h_tx_data;  // next byte to send
      else if (t_rx && scl_rise && bcnt != 4'd8) sh <= {sh[6:0], sda};
      else if (t_st == T_RD && scl_fall && bcnt != 4'd8) sh <= {sh[6:0], 1'b0};
    end
  end

  // ================================================================ control
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
      t_st      <= T_IDLE;
      t_sda     <= 1'b0;
      t_rw      <= 1'b0;
      t_ours    <= 1'b0;
      t_mack    <= 1'b0;
    end else begin
      d_done  <= 1'b0;
      d_nack  <= 1'b0;
      c_scl_q <= c_scl_low;
      c_sda_q <= c_sda_low;

      // -------------------------------------------------------- controller
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

      // -------------------------------------------------------- target
      if (!tgt) begin
        t_st   <= T_IDLE;
        t_sda  <= 1'b0;
        t_ours <= 1'b0;
      end else if (t_start) begin
        t_st  <= T_ADDR;
        bcnt  <= 4'd0;
        t_sda <= 1'b0;
      end else if (t_stop) begin
        t_st   <= T_IDLE;
        t_sda  <= 1'b0;
        t_ours <= 1'b0;
      end else begin
        case (t_st)
          T_ADDR, T_WR:
          if (scl_rise && bcnt != 4'd8) begin
            bcnt <= bcnt + 4'd1;
          end else if (t_byte) begin
            if (t_st == T_WR || t_match) begin  // ACK
              t_sda <= 1'b1;
              t_st  <= T_ACK;
              if (t_st == T_ADDR) begin
                t_rw   <= sh[0];
                t_ours <= 1'b1;
              end
            end else begin
              t_st <= T_WAIT;  // not us, or not ready: NACK
            end
          end
          T_ACK:
          if (scl_fall) begin  // end of the ACK clock
            bcnt  <= 4'd0;
            t_sda <= 1'b0;
            t_st  <= t_rw ? T_RD : T_WR;
          end
          T_RD:
          if (scl_rise) begin
            bcnt <= bcnt + 4'd1;
          end else if (scl_fall) begin
            if (bcnt == 4'd8) begin  // release SDA for the controller's ACK
              t_sda <= 1'b0;
              t_st  <= T_RACK;
            end else begin
              t_sda <= ~sh[6];
            end
          end
          T_RACK:
          if (scl_rise) t_mack <= ~sda;
          else if (scl_fall) begin
            bcnt <= 4'd0;
            t_st <= t_mack ? T_RD : T_WAIT;
          end
          default: ;  // T_IDLE, T_WAIT: wait for START or STOP
        endcase
        if (t_load) t_sda <= ~h_tx_data[7];  // next byte's MSB on SDA
      end
    end
  end

  // ================================================================ outputs
  assign rx_data = (ctl ? {sh[6:0], samp} : sh);
  assign scl_low = c_scl_q;
  assign sda_low = c_sda_q | (tgt & t_sda);
  assign idle    = (c_st == C_IDLE) & (t_st == T_IDLE);

endmodule
