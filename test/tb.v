`default_nettype none
`timescale 1ns / 1ps

/* Testbench wrapper for tt_um_mpbridge.
   Adds what the real board provides around the pins:
   - UART_RX (ui_in[3]) comes from uart_rx, so a UART model can drive it while
     the test sets the configuration pins through ui_cfg.
   - SPI pins: where the design drives a pin (uio_oe = 1) its own output is looped
     back; otherwise the test's SPI model drives it through spi_*_drv.
   - I2C SCL/SDA as open-drain wires with pull-ups (uio[6], uio[7]);
     an external I2C device pulls them low through i2c_scl_pull / i2c_sda_pull.
*/
module tb ();

  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_cfg;         // MODE, BAUD_SEL, I2C_ADDR_LSB, I2C_FAST (bit 3 is ignored)
  reg uart_rx;              // UART_RX, driven by the test's UART model
  reg spi_cs_n_drv;         // SPI levels from the test's models, used where the design does not drive
  reg spi_mosi_drv;
  reg spi_miso_drv;
  reg spi_sck_drv;
  reg i2c_scl_pull;         // external device pulls SCL low
  reg i2c_sda_pull;         // external device pulls SDA low
  wire [7:0] ui_in = {ui_cfg[7:4], uart_rx, ui_cfg[2:0]};
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  wire [7:0] uio_in;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  // Resolved SPI lines: the design's output where it drives, the model's elsewhere
  wire [3:0] spi_drv = {spi_sck_drv, spi_miso_drv, spi_mosi_drv, spi_cs_n_drv};
  wire [3:0] spi = (uio_oe[3:0] & uio_out[3:0]) | (~uio_oe[3:0] & spi_drv);
  wire spi_cs_n = spi[0];
  wire spi_mosi = spi[1];
  wire spi_miso = spi[2];
  wire spi_sck  = spi[3];

  // Open-drain I2C bus with pull-ups
  wire i2c_scl = ~((uio_oe[6] & ~uio_out[6]) | i2c_scl_pull);
  wire i2c_sda = ~((uio_oe[7] & ~uio_out[7]) | i2c_sda_pull);
  // Must never happen: the design driving an I2C pin high (push-pull)
  wire i2c_push_pull_violation = (uio_oe[6] & uio_out[6]) | (uio_oe[7] & uio_out[7]);

  wire uart_tx = uo_out[4];
  wire irq     = uo_out[5];
  wire busy    = uo_out[6];
  wire err     = uo_out[7];

  assign uio_in = {i2c_sda, i2c_scl, 2'b00, spi};

  tt_um_mpbridge user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
