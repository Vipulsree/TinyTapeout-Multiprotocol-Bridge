/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// SPI engine, mode 0 (CPOL = 0, CPHA = 0), MSB first. Master and slave share one
// 8-bit shift register and bit counter; only one role is active per mode.
//
// master (device side, modes 000 / 101): drives CS_N, SCK and MOSI for d_start
//   transactions; SCK half-periods come from clkdiv ticks. MOSI changes on the
//   SCK falling edge. MISO is sampled late, at the falling edge, through the
//   synchroniser, which leaves the whole SCK period for the slave's output delay.
// slave (host side, modes 010 / 011): follows the synchronised CS_N / SCK / MOSI.
//   MOSI is sampled on SCK rise, MISO changes after SCK falls. SCK <= 2 MHz.
module spi_ms (
    input wire clk,
    input wire rst_n,
    input wire master,
    input wire slave,

    // Synchronised pins
    input wire cs_n,      // slave select level
    input wire cs_fall,
    input wire cs_rise,
    input wire sck_rise,
    input wire sck_fall,
    input wire mosi,
    input wire miso,

    // Pin drivers
    output wire cs_n_o,
    output reg  sck_o,
    output wire mosi_o,
    output reg  miso_o,

    // clkdiv (half-period ticks)
    output wire tick_en,
    input  wire tick,

    // Host role (slave)
    output wire [7:0] rx_data,        // received byte, with h_rx_valid or d_rd_push
    output wire       h_rx_valid,
    output wire       h_frame_start,  // CS_N fell
    output wire       h_frame_end,    // CS_N rose
    input  wire [7:0] h_tx_data,
    output wire       h_tx_take,

    // Device role (master)
    input  wire       d_start,
    input  wire [1:0] d_op,
    input  wire [2:0] d_len,
    input  wire       d_abort,
    input  wire [7:0] d_wr_data,
    output wire       d_wr_pop,
    output wire       d_rd_push,
    output reg        d_done,

    output wire idle
);

  localparam [1:0] OP_WRITE = 2'd0, OP_READ = 2'd1, OP_WRRD = 2'd2;

  reg [7:0] sh;
  reg [2:0] bcnt;

  // ---------------------------------------------------------------- master
  reg       m_on;     // CS_N low
  reg       m_end;    // last byte done: wait half a period, then raise CS_N
  reg       m_first;  // current byte is the first of the transaction
  reg [2:0] m_left;   // bytes left, including the current one (1..5)

  wire m_tick     = master & m_on & tick;
  wire m_byte_end = m_tick & sck_o & (bcnt == 3'd7);  // 8th falling edge
  wire m_more     = m_left != 3'd1;
  // Write: every byte comes from the FIFO. Write-then-read: only the first.
  wire m_pop_next = (d_op == OP_WRITE);
  wire m_push     = (d_op == OP_READ) | ((d_op == OP_WRRD) & ~m_first);

  assign tick_en   = master & m_on;
  assign cs_n_o    = ~m_on;
  assign mosi_o    = m_on & sh[7];
  assign d_rd_push = m_byte_end & m_push;
  assign d_wr_pop  = (master & d_start & (d_op != OP_READ)) | (m_byte_end & m_more & m_pop_next);

  // ---------------------------------------------------------------- slave
  reg  s_load;  // byte complete: load the next response byte at the next SCK fall
  wire s_sel = slave & ~cs_n;

  assign h_frame_start = slave & cs_fall;
  assign h_frame_end   = slave & cs_rise;
  assign h_rx_valid    = s_sel & sck_rise & (bcnt == 3'd7);
  assign h_tx_take     = h_frame_start | (s_sel & sck_fall & s_load);

  // Byte as it completes: master on its 8th falling edge, slave on its 8th rising edge.
  assign rx_data = {sh[6:0], master ? miso : mosi};

  // ---------------------------------------------------------------- shared datapath
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sh      <= 8'h00;
      bcnt    <= 3'd0;
      m_on    <= 1'b0;
      m_end   <= 1'b0;
      m_first <= 1'b0;
      m_left  <= 3'd0;
      sck_o   <= 1'b0;
      miso_o  <= 1'b0;
      s_load  <= 1'b0;
      d_done  <= 1'b0;
    end else begin
      d_done <= 1'b0;

      if (master) begin
        if (d_abort) begin
          m_on  <= 1'b0;
          m_end <= 1'b0;
          sck_o <= 1'b0;
        end else if (d_start) begin
          m_on    <= 1'b1;
          m_end   <= 1'b0;
          m_first <= 1'b1;
          m_left  <= (d_op == OP_WRRD) ? d_len + 3'd1 : d_len;
          bcnt    <= 3'd0;
          sh      <= (d_op == OP_READ) ? 8'h00 : d_wr_data;
        end else if (m_tick) begin
          if (m_end) begin
            m_on   <= 1'b0;
            m_end  <= 1'b0;
            d_done <= 1'b1;
          end else if (!sck_o) begin
            sck_o <= 1'b1;
          end else begin  // falling edge: sample MISO, present the next MOSI bit
            sck_o <= 1'b0;
            bcnt  <= bcnt + 3'd1;
            sh    <= {sh[6:0], miso};
            if (bcnt == 3'd7) begin
              m_first <= 1'b0;
              m_left  <= m_left - 3'd1;
              if (!m_more) m_end <= 1'b1;
              else sh <= m_pop_next ? d_wr_data : 8'h00;
            end
          end
        end
      end else begin
        m_on  <= 1'b0;
        m_end <= 1'b0;
        sck_o <= 1'b0;
      end

      if (slave) begin
        if (cs_fall || cs_rise) begin
          bcnt   <= 3'd0;
          s_load <= 1'b0;
        end
        if (h_frame_start) begin  // first response byte goes out before the first SCK
          sh     <= h_tx_data;
          miso_o <= h_tx_data[7];
        end else if (s_sel && sck_rise) begin
          sh   <= {sh[6:0], mosi};
          bcnt <= bcnt + 3'd1;
          if (bcnt == 3'd7) s_load <= 1'b1;
        end else if (s_sel && sck_fall) begin
          if (s_load) begin
            s_load <= 1'b0;
            sh     <= h_tx_data;
            miso_o <= h_tx_data[7];
          end else begin
            miso_o <= sh[7];
          end
        end
      end
    end
  end

  assign idle = ~m_on & (~slave | cs_n);

endmodule
