// SPDX-License-Identifier: Apache-2.0
// Formal properties for the top level tt_um_mpbridge (properties P3 and P4).
// Included inside the module when FORMAL is defined. The properties of fifo2x8,
// cmd_ctrl and i2c_engine are checked again here, with the real engines driving
// them instead of free inputs.
//
// P3: MODE, BAUD_SEL and I2C_FAST are latched only while the controller and
//     every engine are idle, so changing the pins mid-transfer has no effect.
// P4: pin safety. The I2C pads are open-drain (never driven high), the spare
//     pads are never driven, the safe-idle modes drive nothing, the SPI master
//     pins are driven only in mode 000, MISO only while the slave is selected,
//     and the I2C pads only in the modes with an I2C device.

reg fv_past = 1'b0;
always @(posedge clk) fv_past <= 1'b1;
initial assume (!rst_n);

always @(*) begin
  // P4 (combinational, so also true during reset)
  assert (uio_out[7:4] == 4'b0000);  // I2C pads and spare pads never drive high
  assert (uio_oe[5:4] == 2'b00);     // spare pads are never driven
  if (off) begin
    assert (uio_oe == 8'h00);        // modes 100, 101 and 111: nothing driven
    assert (uo_out == 8'h00);
  end
  if (!dev_i2c) assert (uio_oe[7:6] == 2'b00);
  if (!dev_spi) assert ({uio_oe[3], uio_oe[1], uio_oe[0]} == 3'b000);
  if (uio_oe[2]) assert (host_spi && !spi_cs_n_in);
  assert (uo_out[3] == 1'b0);
end

always @(posedge clk) begin
  if (fv_past && rst_n && $past(rst_n)) begin
    // P3: the latched configuration changes only out of an all-idle cycle.
    if (!$past(all_idle)) assert (mode == $past(mode) && baud == $past(baud) && i2c_fast == $past(i2c_fast));
    // P4: an I2C engine that is not selected, or idle, has let go of both pads.
    if (!$past(dev_i2c) || $past(i2c_idle)) assert (!i2c_scl_low && !i2c_sda_low);
  end
end

// Reachability: each bridge mode is latched, the SPI slave drives MISO, and the
// configuration is held while something is busy.
always @(posedge clk) begin
  if (fv_past && rst_n) begin
    cover (mode == M_UART_I2C);
    cover (mode == M_UART_SPI && uio_oe[3]);
    cover (mode == M_SPI_I2C && uio_oe[2]);
    cover (!all_idle && mode == M_SPI_UART);
  end
end
