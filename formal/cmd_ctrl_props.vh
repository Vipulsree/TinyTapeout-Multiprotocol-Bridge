// SPDX-License-Identifier: Apache-2.0
// Formal properties for cmd_ctrl (property P2). Included inside the module when
// FORMAL is defined. Every input is free: the properties hold for any host and
// device behaviour, so nothing is assumed about the engines.
//
// P2: the controller only moves along IDLE -> HEADER -> WRITE -> EXEC -> RESPOND
// and always has a way back to IDLE: a framed host that ends its frame early
// drops the partial command, a UART host's response ends in IDLE once the last
// byte is taken, and a framed host leaves RESPOND when its read-out frame ends.

reg fv_past = 1'b0;
always @(posedge clk) fv_past <= 1'b1;
initial assume (!rst_n);

always @(posedge clk) begin
  if (rst_n) begin
    assert (st <= S_RESPOND);  // only the five encoded states
    // The length field is loaded before the controller leaves IDLE (it has no reset).
    if (st != S_IDLE) assert (d_len == 3'd1 || d_len == 3'd2);
    // Payload or response bytes outstanding: never more than the FIFO holds.
    assert (rem <= 3'd2);
    if (st == S_WRITE) assert (rem != 3'd0);
    if (exec_first) assert (st == S_EXEC);
    if (d_start) assert (st == S_EXEC && !exec_first);  // a transaction starts only from EXEC
    if (h_tx_valid) assert (st == S_RESPOND);
    if (busy) assert (st == S_EXEC || st == S_RESPOND);
  end

  if (fv_past && rst_n && $past(rst_n)) begin
    // The state only moves forward along the chain, or back to IDLE.
    case ($past(st))
      S_IDLE:    assert (st == S_IDLE || st == S_HEADER);
      S_HEADER:  assert (st == S_HEADER || st == S_IDLE || st == S_WRITE || st == S_EXEC);
      S_WRITE:   assert (st == S_WRITE || st == S_IDLE || st == S_EXEC);
      S_EXEC:    assert (st == S_EXEC || st == S_RESPOND);
      default:   assert (st == S_RESPOND || st == S_IDLE);
    endcase

    // P2: a frame that ends before the command is complete drops it.
    if ($past(h_frame_end) && ($past(st) == S_HEADER || $past(st) == S_WRITE)) assert (st == S_IDLE);
    // P2: a UART host's response is over once every byte has been taken.
    if ($past(st) == S_RESPOND && $past(host_uart) && $past(rem) == 3'd0) assert (st == S_IDLE);
    // P2: a framed host ends the response with the end of its read-out frame.
    if ($past(st) == S_RESPOND && !$past(host_uart) && !$past(h_frame_start) && $past(reading) &&
        $past(h_frame_end))
      assert (st == S_IDLE);

    // d_start is a one-cycle pulse, and EXEC is left only by d_done or by a
    // command that needs no device.
    if ($past(d_start)) assert (!d_start);
    if ($past(st) == S_EXEC && st == S_RESPOND) assert ($past(d_done) || $past(exec_first));

    // An error flag, once set, stays until the header of the next command.
    if ($past(err) && !err) assert ($past(st) == S_HEADER);
  end
end

// Reachability: a status command reaches RESPOND without a device, a two-byte
// write reaches WRITE, and a device transaction is started.
`ifndef FV_TOP  // too deep to reach through the pins: unit runs only
always @(posedge clk) begin
  if (fv_past && rst_n) begin
    cover (st == S_RESPOND && rsp_status);
    cover (st == S_WRITE && rem == 3'd2);
    cover (d_start);
    cover ($past(st) == S_RESPOND && st == S_IDLE);
  end
end
`endif
