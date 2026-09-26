`default_nettype none
`timescale 1ns / 1ps

/* Testbench wrapper for tt_um_mpbridge.
   Adds what the real board provides around the pins:
   - I2C SCL/SDA as open-drain wires with pull-ups (uio[6], uio[7]);
     an external I2C device pulls them low through i2c_scl_pull / i2c_sda_pull.
   - Bidirectional pins loop the design's own output back to its input when it
     drives them, otherwise the test drives them through uio_in_drv.
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
  reg [7:0] ui_in;
  reg [7:0] uio_in_drv;     // test-driven level for pins the design is not driving
  reg i2c_scl_pull;         // external device pulls SCL low
  reg i2c_sda_pull;         // external device pulls SDA low
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  wire [7:0] uio_in;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  // Open-drain I2C bus with pull-ups
  wire i2c_scl = ~((uio_oe[6] & ~uio_out[6]) | i2c_scl_pull);
  wire i2c_sda = ~((uio_oe[7] & ~uio_out[7]) | i2c_sda_pull);
  // Must never happen: the design driving an I2C pin high (push-pull)
  wire i2c_push_pull_violation = (uio_oe[6] & uio_out[6]) | (uio_oe[7] & uio_out[7]);

  assign uio_in = {i2c_sda, i2c_scl,
                   (uio_oe[5:0] & uio_out[5:0]) | (~uio_oe[5:0] & uio_in_drv[5:0])};

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
