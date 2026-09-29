/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Track A: six-mode UART / SPI / I2C bridge in one Tiny Tapeout tile.
// Pin map and protocol: docs/info.md and docs/architecture.md.
//
// cmd_ctrl runs every transaction; the mode picks which engine is the host
// side and which is the device side. Each engine ignores its inputs and
// outputs zero pulses when its role is not selected.
module tt_um_mpbridge (
    input  wire [7:0] ui_in,    // MODE[2:0], UART_RX, BAUD_SEL[1:0], I2C_ADDR_LSB, I2C_FAST
    output wire [7:0] uo_out,   // DBG_STATE[3:0], UART_TX, IRQ, BUSY, ERR
    input  wire [7:0] uio_in,   // SPI CS_N/MOSI/MISO/SCK, I2C SCL/SDA
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,   // 1 = output
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // 25 MHz
    input  wire       rst_n     // active-low reset
);

  // ------------------------------------------------------------------ mode
  localparam [2:0] M_UART_SPI = 3'b000, M_UART_I2C = 3'b001, M_SPI_UART = 3'b010,
                   M_SPI_I2C  = 3'b011, M_I2C_UART = 3'b100, M_I2C_SPI  = 3'b101,
                   M_LOOP     = 3'b110, M_OFF      = 3'b111;

  wire       ctrl_idle, uart_idle, spi_idle, i2c_idle;
  reg  [2:0] mode;
  reg  [1:0] baud;      // BAUD_SEL: 00 9600, 01 19200, 10 57600, 11 115200
  reg        i2c_lsb;   // I2C target address LSB
  reg        i2c_fast;  // I2C controller: 0 = 100 kHz, 1 = 400 kHz

  // The configuration pins are latched only while the controller and every
  // engine are idle (no SPI frame, I2C transfer or UART byte in flight), so
  // changing them mid-transfer cannot corrupt a transaction.
  wire all_idle = ctrl_idle & uart_idle & spi_idle & i2c_idle;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode     <= M_OFF;
      baud     <= 2'b11;
      i2c_lsb  <= 1'b0;
      i2c_fast <= 1'b0;
    end else if (all_idle) begin
      mode     <= ui_in[2:0];
      baud     <= ui_in[5:4];
      i2c_lsb  <= ui_in[6];
      i2c_fast <= ui_in[7];
    end
  end

  wire host_uart = (mode == M_UART_SPI) | (mode == M_UART_I2C) | (mode == M_LOOP);
  wire host_spi  = (mode == M_SPI_UART) | (mode == M_SPI_I2C);
  wire host_i2c  = (mode == M_I2C_UART) | (mode == M_I2C_SPI);
  wire dev_spi   = (mode == M_UART_SPI) | (mode == M_I2C_SPI);
  wire dev_i2c   = (mode == M_UART_I2C) | (mode == M_SPI_I2C);
  wire dev_uart  = (mode == M_SPI_UART) | (mode == M_I2C_UART);
  wire loop      = (mode == M_LOOP);
  wire off       = (mode == M_OFF);

  // ----------------------------------------------------------- synchronisers
  // bit: 0 UART_RX, 1 SPI_CS_N, 2 SPI_MOSI, 3 SPI_MISO, 4 SPI_SCK, 5 I2C_SCL, 6 I2C_SDA
  wire [6:0] pin_raw = {uio_in[7], uio_in[6], uio_in[3], uio_in[2], uio_in[1], uio_in[0], ui_in[3]};
  wire [6:0] pin_q, pin_rise, pin_fall;

  sync2_edge #(
      .N     (7),
      .INIT  (7'b110_1111),  // SCK idles low (SPI mode 0); everything else idles high
      .FILTER(7'b110_0000)   // 2-sample glitch filter on I2C SCL/SDA
  ) u_sync (
      .clk  (clk),
      .rst_n(rst_n),
      .d    (pin_raw),
      .q    (pin_q),
      .rise (pin_rise),
      .fall (pin_fall)
  );

  wire spi_cs_n_in = pin_q[1];

  // ----------------------------------------------------------- controller <-> engines
  wire [7:0] h_tx_data, d_wr_data;
  wire       h_tx_valid, d_wr_avail, d_start;
  wire [1:0] d_op, d_spi_div;
  wire [2:0] d_len, state;
  wire [6:0] d_addr;
  // No timeouts (removed to fit the tile): nothing ever aborts a device
  // transaction, so the engines' abort inputs are tied off.
  wire       d_abort = 1'b0;
  wire       can_read, can_write, irq, busy, err;

  // ----------------------------------------------------------- UART engine
  wire       uart_tx;
  wire [7:0] u_rx_data;
  wire       u_h_rx_valid, u_h_tx_take, u_d_wr_pop, u_d_rd_push, u_d_done, u_frame_err;

  uart_trx u_uart (
      .clk       (clk),
      .rst_n     (rst_n),
      .baud      (baud),
      .host      (host_uart & ~loop),
      .dev       (dev_uart),
      .loop      (loop),
      .rx        (pin_q[0]),
      .rx_fall   (pin_fall[0]),
      .tx        (uart_tx),
      .h_rx_data (u_rx_data),
      .h_rx_valid(u_h_rx_valid),
      .h_tx_data (h_tx_data),
      .h_tx_valid(h_tx_valid),
      .h_tx_take (u_h_tx_take),
      .d_start   (d_start),
      .d_op      (d_op),
      .d_len     (d_len),
      .d_abort   (d_abort),
      .d_wr_data (d_wr_data),
      .d_wr_pop  (u_d_wr_pop),
      .d_rd_data (),             // same byte as h_rx_data
      .d_rd_push (u_d_rd_push),
      .d_done    (u_d_done),
      .frame_err (u_frame_err),
      .idle      (uart_idle)
  );

  // ----------------------------------------------------------- serial clock divider
  // One divider serves whichever of SPI master or I2C controller is the device.
  // SPI: half-period ticks, (4 << SPI_DIV) clocks. I2C: quarter-period ticks,
  // 63 clocks (99.2 kHz) or 17 clocks (367.6 kHz).
  wire       spi_tick_en, i2c_tick_en, div_tick;
  wire [5:0] spi_div_m1 = (6'd4 << d_spi_div) - 6'd1;
  wire [5:0] i2c_div_m1 = i2c_fast ? 6'd16 : 6'd62;

  clkdiv #(
      .W(6)
  ) u_div (
      .clk   (clk),
      .rst_n (rst_n),
      .en    (dev_spi ? spi_tick_en : i2c_tick_en),
      .div_m1(dev_spi ? spi_div_m1 : i2c_div_m1),
      .tick  (div_tick)
  );

  // ----------------------------------------------------------- SPI engine
  wire       spi_cs_n_o, spi_mosi_o, spi_miso_o, spi_sck_o;
  wire [7:0] s_rx_data;
  wire       s_h_rx_valid, s_h_frame_start, s_h_frame_end, s_h_tx_take;
  wire       s_d_wr_pop, s_d_rd_push, s_d_done;

  spi_ms u_spi (
      .clk          (clk),
      .rst_n        (rst_n),
      .master       (dev_spi),
      .slave        (host_spi),
      .cs_n         (spi_cs_n_in),
      .cs_fall      (pin_fall[1]),
      .cs_rise      (pin_rise[1]),
      .sck_rise     (pin_rise[4]),
      .sck_fall     (pin_fall[4]),
      .mosi         (pin_q[2]),
      .miso         (pin_q[3]),
      .cs_n_o       (spi_cs_n_o),
      .sck_o        (spi_sck_o),
      .mosi_o       (spi_mosi_o),
      .miso_o       (spi_miso_o),
      .tick_en      (spi_tick_en),
      .tick         (div_tick),
      .rx_data      (s_rx_data),
      .h_rx_valid   (s_h_rx_valid),
      .h_frame_start(s_h_frame_start),
      .h_frame_end  (s_h_frame_end),
      .h_tx_data    (h_tx_data),
      .h_tx_take    (s_h_tx_take),
      .d_start      (d_start & dev_spi),
      .d_op         (d_op),
      .d_len        (d_len),
      .d_abort      (d_abort),
      .d_wr_data    (d_wr_data),
      .d_wr_pop     (s_d_wr_pop),
      .d_rd_push    (s_d_rd_push),
      .d_done       (s_d_done),
      .idle         (spi_idle)
  );

  // ----------------------------------------------------------- I2C engine
  wire       i2c_scl_low, i2c_sda_low;
  wire [7:0] i_rx_data;
  wire       i_h_rx_valid, i_h_frame_start, i_h_frame_rd, i_h_frame_end, i_h_tx_take;
  wire       i_d_wr_pop, i_d_rd_push, i_d_done, i_d_nack;

  i2c_engine u_i2c (
      .clk          (clk),
      .rst_n        (rst_n),
      .ctl          (dev_i2c),
      .tgt          (host_i2c),
      .addr_lsb     (i2c_lsb),
      .scl          (pin_q[5]),
      .sda          (pin_q[6]),
      .scl_rise     (pin_rise[5]),
      .scl_fall     (pin_fall[5]),
      .sda_rise     (pin_rise[6]),
      .sda_fall     (pin_fall[6]),
      .scl_low      (i2c_scl_low),
      .sda_low      (i2c_sda_low),
      .tick_en      (i2c_tick_en),
      .tick         (div_tick),
      .rx_data      (i_rx_data),
      .h_rx_valid   (i_h_rx_valid),
      .h_frame_start(i_h_frame_start),
      .h_frame_rd   (i_h_frame_rd),
      .h_frame_end  (i_h_frame_end),
      .h_tx_data    (h_tx_data),
      .h_tx_take    (i_h_tx_take),
      .can_read     (can_read),
      .can_write    (can_write),
      .d_start      (d_start & dev_i2c),
      .d_op         (d_op),
      .d_len        (d_len),
      .d_addr       (d_addr),
      .d_abort      (d_abort),
      .d_wr_data    (d_wr_data),
      .d_wr_pop     (i_d_wr_pop),
      .d_rd_push    (i_d_rd_push),
      .d_done       (i_d_done),
      .d_nack       (i_d_nack),
      .idle         (i2c_idle)
  );

  // ----------------------------------------------------------- engine -> controller
  // Pulses are already gated by role inside each engine, so they can be ORed.
  wire [7:0] h_rx_data     = host_spi ? s_rx_data : host_i2c ? i_rx_data : u_rx_data;
  wire       h_rx_valid    = u_h_rx_valid | s_h_rx_valid | i_h_rx_valid;
  wire       h_frame_start = s_h_frame_start | i_h_frame_start;
  wire       h_frame_rd    = host_spi | i_h_frame_rd;  // SPI frames are always read-out frames
  wire       h_frame_end   = s_h_frame_end | i_h_frame_end;
  wire       h_tx_take     = u_h_tx_take | s_h_tx_take | i_h_tx_take;
  wire [7:0] d_rd_data     = dev_spi ? s_rx_data : dev_i2c ? i_rx_data : u_rx_data;
  wire       d_rd_push     = u_d_rd_push | s_d_rd_push | i_d_rd_push;
  wire       d_wr_pop      = u_d_wr_pop | s_d_wr_pop | i_d_wr_pop;
  wire       d_done        = u_d_done | s_d_done | i_d_done;
  wire       d_nack        = i_d_nack;
  wire       frame_err     = u_frame_err;

  // ----------------------------------------------------------- controller

  cmd_ctrl u_ctrl (
      .clk          (clk),
      .rst_n        (rst_n),
      .host_uart    (host_uart),
      .dev_uart     (dev_uart),
      .h_rx_data    (h_rx_data),
      .h_rx_valid   (h_rx_valid),
      .h_frame_start(h_frame_start),
      .h_frame_rd   (h_frame_rd),
      .h_frame_end  (h_frame_end),
      .h_tx_data    (h_tx_data),
      .h_tx_valid   (h_tx_valid),
      .h_tx_take    (h_tx_take),
      .d_start      (d_start),
      .d_op         (d_op),
      .d_len        (d_len),
      .d_addr       (d_addr),
      .d_spi_div    (d_spi_div),
      .d_done       (d_done),
      .d_nack       (d_nack),
      .d_wr_data    (d_wr_data),
      .d_wr_avail   (d_wr_avail),
      .d_wr_pop     (d_wr_pop),
      .d_rd_data    (d_rd_data),
      .d_rd_push    (d_rd_push),
      .frame_err    (frame_err),
      .state        (state),
      .idle         (ctrl_idle),
      .can_read     (can_read),
      .can_write    (can_write),
      .irq          (irq),
      .busy         (busy),
      .err          (err)
  );

  // ----------------------------------------------------------- pins
  wire i2c_on       = dev_i2c | host_i2c;
  wire spi_selected = host_spi & ~spi_cs_n_in;  // slave drives MISO only while selected

  assign uo_out = off ? 8'h00 : {err, busy, irq, uart_tx, 1'b0, state};

  // uio: 0 CS_N, 1 MOSI, 2 MISO, 3 SCK, 4-5 spare, 6 SCL, 7 SDA (open-drain: out = 0)
  assign uio_out = {4'b0000, spi_sck_o, spi_miso_o, spi_mosi_o, spi_cs_n_o};
  assign uio_oe  = off ? 8'h00 : {i2c_on & i2c_sda_low, i2c_on & i2c_scl_low, 2'b00,
                                  dev_spi, spi_selected, dev_spi, dev_spi};

  // Not needed: ena, the raw SPI pins (the engines use the synchronised
  // copies), and edges nothing looks at.
  wire _unused = &{ena, pin_q[4], pin_rise[3:2], pin_rise[0], pin_fall[3:2], d_wr_avail, 1'b0};

endmodule
