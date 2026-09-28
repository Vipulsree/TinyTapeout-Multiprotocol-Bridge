/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// General-purpose inactivity timeout.
// Counts clock cycles while `run` is high; any `kick` restarts the count.
// `expired` pulses for one cycle when the count reaches `limit`, which must be
// a power of two (exactly one bit set); a limit of 0 disables the timeout.
// Counting up from zero, the first count with that bit set is the limit itself,
// so one AND-OR of the counter with the limit replaces a full comparator.
// W = 21 reaches 2^20 clocks = 41.9 ms at 25 MHz.
module timeout20 #(
    parameter integer W = 21
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         run,      // count while high; the count clears while low
    input  wire         kick,     // activity seen: restart from zero
    input  wire [W-1:0] limit,    // timeout in clock cycles: a power of two, or 0 = never
    output wire         expired   // one-cycle pulse
);

  reg [W-1:0] cnt;

  assign expired = run & ~kick & (|(cnt & limit));

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cnt <= {W{1'b0}};
    else if (!run || kick || expired) cnt <= {W{1'b0}};
    else cnt <= cnt + 1'b1;
  end

endmodule
