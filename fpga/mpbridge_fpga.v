/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// tt_um_mpbridge on any FPGA board, for the dry run when the Tiny Tapeout FPGA
// breakout is not at hand (docs/fpga_dry_run.md, option B).
//
// The design expects 25 MHz: the UART baud rates and the SPI and I2C rates are
// counted in clock cycles, and a UART tolerates only about 2% of error. CLK_DIV
// divides the board clock:
//   1  the board clock is 25 MHz and is used as it is
//   2  50 MHz board   4  100 MHz board
// With any other clock the UART modes (000, 001, 110 and the UART device of 010)
// will not work at the standard baud rates.
//
// The uio pins are three-state pads built from uio_out and uio_oe, as the Tiny
// Tapeout mux does. Both I2C lines need pull-ups (external resistors or the
// FPGA's pad pull-ups in the constraints file).
module mpbridge_fpga #(
    parameter integer CLK_DIV = 1
) (
    input  wire       clk_board,
    input  wire       rst_n,      // active low
    input  wire [2:0] mode,       // ui_in[2:0]
    input  wire       uart_rx,    // ui_in[3], from the host's (or device's) TX
    input  wire [1:0] baud_sel,   // ui_in[5:4]: 00 9600, 01 19200, 10 57600, 11 115200
    input  wire       i2c_fast,   // ui_in[7]: 0 = 99.2 kHz, 1 = 367.6 kHz
    output wire [7:0] status,     // uo_out: state[2:0], 0, UART_TX, IRQ, BUSY, ERR
    inout  wire       spi_cs_n,   // uio[0]
    inout  wire       spi_mosi,   // uio[1]
    inout  wire       spi_miso,   // uio[2]
    inout  wire       spi_sck,    // uio[3]
    inout  wire       i2c_scl,    // uio[6]
    inout  wire       i2c_sda     // uio[7]
);

  // ----------------------------------------------------------- clock
  wire clk;
  generate
    if (CLK_DIV <= 1) begin : g_direct
      assign clk = clk_board;
    end else begin : g_div
      // Toggle flip-flop chain; fine for a dry run (the tools put it on a clock net).
      reg [7:0] div = 8'd0;
      always @(posedge clk_board) div <= div + 8'd1;
      assign clk = (CLK_DIV == 2) ? div[0] : (CLK_DIV == 4) ? div[1] : div[2];
    end
  endgenerate

  // ----------------------------------------------------------- design
  wire [7:0] uio_out, uio_oe;
  wire [7:0] uio_in = {i2c_sda, i2c_scl, 2'b00, spi_sck, spi_miso, spi_mosi, spi_cs_n};

  tt_um_mpbridge u_bridge (
      .ui_in  ({i2c_fast, 1'b0, baud_sel, uart_rx, mode}),
      .uo_out (status),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // ----------------------------------------------------------- pads
  assign spi_cs_n = uio_oe[0] ? uio_out[0] : 1'bz;  // driven in mode 000 (SPI master)
  assign spi_mosi = uio_oe[1] ? uio_out[1] : 1'bz;
  assign spi_miso = uio_oe[2] ? uio_out[2] : 1'bz;  // driven in modes 010 / 011 while CS_N is low
  assign spi_sck  = uio_oe[3] ? uio_out[3] : 1'bz;
  assign i2c_scl  = uio_oe[6] ? uio_out[6] : 1'bz;  // uio_out[7:6] is always 0: open-drain
  assign i2c_sda  = uio_oe[7] ? uio_out[7] : 1'bz;

endmodule
