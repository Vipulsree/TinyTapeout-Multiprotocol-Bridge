/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Track A: six-mode UART / SPI / I2C bridge in one Tiny Tapeout tile.
// Pin map and protocol: docs/info.md and docs/architecture.md.
//
// Status (week 2): mode latch, pin directions, synchronisers and the
// transaction controller are in place. The UART, SPI and I2C engines are
// tied off below and arrive in weeks 4-6 (see README).
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

  wire       ctrl_idle;
  reg  [2:0] mode;
  reg  [1:0] baud;  // BAUD_SEL: 00 9600, 01 19200, 10 57600, 11 115200

  // MODE and BAUD_SEL are latched only when the controller is idle, so changing
  // the pins mid-transfer cannot corrupt a transaction.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode <= M_OFF;
      baud <= 2'b11;
    end else if (ctrl_idle) begin
      mode <= ui_in[2:0];
      baud <= ui_in[5:4];
    end
  end

  wire host_uart = (mode == M_UART_SPI) | (mode == M_UART_I2C) | (mode == M_LOOP);
  wire host_spi  = (mode == M_SPI_UART) | (mode == M_SPI_I2C);
  wire host_i2c  = (mode == M_I2C_UART) | (mode == M_I2C_SPI);
  wire dev_spi   = (mode == M_UART_SPI) | (mode == M_I2C_SPI);
  wire dev_i2c   = (mode == M_UART_I2C) | (mode == M_SPI_I2C);
  wire dev_uart  = (mode == M_SPI_UART) | (mode == M_I2C_UART);
  wire off       = (mode == M_OFF);

  // ------------------------------------------------------------------ timeouts
  // Every limit is a 20-bit count of 25 MHz clocks (max 1,048,575 = 41.9 ms);
  // 0 disables that timeout. Change the values here: UART limits follow the
  // baud rate, bus limits follow the worst-case transaction time.
  localparam integer UART_DIV_9600   = 2604;  // clocks per UART bit (also used by uart_trx)
  localparam integer UART_DIV_19200  = 1302;
  localparam integer UART_DIV_57600  = 434;
  localparam integer UART_DIV_115200 = 217;
  localparam integer CHAR_BITS = 10;          // 8N1 character: start + 8 data + stop

  // UART host: a half-received command is dropped after this many idle characters
  // (keep chars x 26,040 below 1,048,576 at 9600 baud, i.e. at most 40).
  localparam integer TO_HOST_UART_CHARS = 16;
  // UART device: write-then-read reply window, in idle characters.
  localparam integer TO_DEV_UART_CHARS = 8;
  // SPI / I2C hosts and the I2C device: 35 ms, the SMBus tTIMEOUT maximum,
  // which also bounds how long an I2C device may stretch the clock.
  localparam [19:0] TO_BUS = 20'd875_000;
  // SPI device: a 5-byte transfer at SCK = 25 MHz / 64 takes 2,560 clocks.
  localparam [19:0] TO_SPI_DEV = 20'd65_535;

  localparam [19:0] TO_HOST_UART_0 = UART_DIV_9600   * CHAR_BITS * TO_HOST_UART_CHARS;  // 416,640
  localparam [19:0] TO_HOST_UART_1 = UART_DIV_19200  * CHAR_BITS * TO_HOST_UART_CHARS;  // 208,320
  localparam [19:0] TO_HOST_UART_2 = UART_DIV_57600  * CHAR_BITS * TO_HOST_UART_CHARS;  //  69,440
  localparam [19:0] TO_HOST_UART_3 = UART_DIV_115200 * CHAR_BITS * TO_HOST_UART_CHARS;  //  34,720
  localparam [19:0] TO_DEV_UART_0  = UART_DIV_9600   * CHAR_BITS * TO_DEV_UART_CHARS;   // 208,320
  localparam [19:0] TO_DEV_UART_1  = UART_DIV_19200  * CHAR_BITS * TO_DEV_UART_CHARS;   // 104,160
  localparam [19:0] TO_DEV_UART_2  = UART_DIV_57600  * CHAR_BITS * TO_DEV_UART_CHARS;   //  34,720
  localparam [19:0] TO_DEV_UART_3  = UART_DIV_115200 * CHAR_BITS * TO_DEV_UART_CHARS;   //  17,360

  wire [19:0] to_host_uart = (baud == 2'b00) ? TO_HOST_UART_0 : (baud == 2'b01) ? TO_HOST_UART_1 :
                             (baud == 2'b10) ? TO_HOST_UART_2 : TO_HOST_UART_3;
  wire [19:0] to_dev_uart  = (baud == 2'b00) ? TO_DEV_UART_0 : (baud == 2'b01) ? TO_DEV_UART_1 :
                             (baud == 2'b10) ? TO_DEV_UART_2 : TO_DEV_UART_3;
  wire [19:0] to_host_limit = host_uart ? to_host_uart : TO_BUS;
  wire [19:0] to_dev_limit  = dev_uart ? to_dev_uart : dev_spi ? TO_SPI_DEV : TO_BUS;

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

  // ----------------------------------------------------------- engines (stubs)
  // uart_trx   (M1, weeks 4-5): UART_TX idles high until then.
  // spi_ms     (M2, weeks 4-5): master outputs idle, slave MISO low.
  // i2c_engine (M2, week 6):    SCL/SDA released.
  wire       uart_tx      = 1'b1;
  wire       spi_cs_n_o   = 1'b1;
  wire       spi_mosi_o   = 1'b0;
  wire       spi_miso_o   = 1'b0;
  wire       spi_sck_o    = 1'b0;
  wire       i2c_scl_low  = 1'b0;
  wire       i2c_sda_low  = 1'b0;

  wire [7:0] h_rx_data    = 8'h00;
  wire       h_rx_valid   = 1'b0;
  wire       h_frame_start = 1'b0;
  wire       h_frame_rd   = 1'b0;
  wire       h_frame_end  = 1'b0;
  wire       h_tx_take    = 1'b0;
  wire       d_done       = 1'b0;
  wire       d_nack       = 1'b0;
  wire       d_wr_pop     = 1'b0;
  wire [7:0] d_rd_data    = 8'h00;
  wire       d_rd_push    = 1'b0;
  wire       frame_err    = 1'b0;

  // ----------------------------------------------------------- controller
  wire [7:0] h_tx_data, d_wr_data;
  wire       h_tx_valid, d_wr_avail, d_start;
  wire [1:0] d_op, d_spi_div;
  wire [2:0] d_len, state;
  wire [6:0] d_addr;
  wire       d_abort;
  wire       can_read, can_write, irq, busy, err;

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
      .d_abort      (d_abort),
      .d_wr_data    (d_wr_data),
      .d_wr_avail   (d_wr_avail),
      .d_wr_pop     (d_wr_pop),
      .d_rd_data    (d_rd_data),
      .d_rd_push    (d_rd_push),
      .frame_err    (frame_err),
      .to_host_limit(to_host_limit),
      .to_dev_limit (to_dev_limit),
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

  // Inputs not used until the engines land (keeps the linter quiet).
  wire _unused = &{ena, ui_in[7:6], pin_q[6:2], pin_q[0], pin_rise, pin_fall, h_tx_data, h_tx_valid,
                   d_start, d_op, d_len, d_addr, d_spi_div, d_abort, d_wr_data, d_wr_avail, can_read,
                   can_write, 1'b0};

endmodule
