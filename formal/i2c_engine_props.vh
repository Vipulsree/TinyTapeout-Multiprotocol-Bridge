// SPDX-License-Identifier: Apache-2.0
// Formal properties for i2c_engine (property P5). Included inside the module
// when FORMAL is defined. Every input is free.
//
// P5: basic safety of the I2C controller, and the START / STOP timing rule:
// phases B and C of a START or STOP symbol last two ticks, which is what gives
// the half-period START hold, repeated-START set-up and STOP set-up times.

reg fv_past = 1'b0;
always @(posedge clk) fv_past <= 1'b1;
initial assume (!rst_n);

wire fv_startstop = (c_st == C_START) | (c_st == C_STOP);
wire fv_mid       = (ph == PB) | (ph == PC);
// A tick that the control block acts on (it is not overridden by ctl, abort or start).
wire fv_step      = ctl & ~d_abort & ~d_start & c_tick;

always @(posedge clk) begin
  if (rst_n) begin
    assert (c_st <= C_STOP);  // only the six encoded states
    assert (bcnt <= 4'd8);    // 8 data bits, then the ACK slot
    if (d_nack) assert (d_done);
    if (d_done) assert (c_st == C_IDLE);
    if (d_wr_pop) assert (c_st == C_ADDR || c_st == C_WR);
    if (d_rd_push) assert (c_st == C_RD);
    if (tick_en) assert (c_st != C_IDLE);
    // The half flag is set inside phase B or C and cleared by the tick that leaves
    // it; a start or an abort may leave it set in phase A, where the tick clears it.
    if (c_half) assert (ph != PD);
  end

  if (fv_past && rst_n && $past(rst_n)) begin
    // An idle or unselected engine lets go of both lines (the drivers are one clock behind).
    if ($past(c_st) == C_IDLE || !$past(ctl)) assert (!scl_low && !sda_low);
    // d_done is a one-cycle pulse.
    if ($past(d_done)) assert (!d_done);
    // An abort always leads to STOP, never to d_done.
    if ($past(ctl) && $past(d_abort) && $past(c_st) != C_IDLE) assert (c_st == C_STOP && c_abort);
    if (d_done) assert (!$past(c_abort));

    // P5: in a START or STOP symbol the first tick of phase B or C keeps the phase...
    if ($past(fv_step) && $past(fv_startstop) && $past(fv_mid) && !$past(c_half))
      assert (ph == $past(ph) && c_half && c_st == $past(c_st));
    // A START or STOP symbol always enters phase B and phase C with the flag
    // clear, so each of the two phases really lasts two ticks.
    if (fv_startstop && fv_mid && ph != $past(ph)) assert (!c_half);
    // ...and the second one moves on. Bit symbols move on at every tick.
    if ($past(fv_step) && $past(fv_startstop) && $past(fv_mid) && $past(c_half))
      assert (ph == $past(ph) + 2'd1 && !c_half);
    if ($past(fv_step) && !$past(fv_startstop)) assert (ph == $past(ph) + 2'd1);
    // The phase only moves with a tick, a start or an abort.
    if (!$past(c_tick) && !$past(d_start) && !$past(d_abort)) assert (ph == $past(ph));
  end
end

// Reachability (a whole transaction is many ticks; the cocotb suite covers
// those): the address goes out, the second tick of a START phase is reached,
// and an abort reaches STOP.
`ifndef FV_TOP  // too deep to reach through the pins: unit runs only
always @(posedge clk) begin
  if (fv_past && rst_n && $past(rst_n)) begin
    cover (c_st == C_ADDR && bcnt == 4'd2);
    cover (c_st == C_START && ph == PC && c_half);
    cover (c_st == C_STOP && c_abort && ph == PC);
  end
end
`endif
