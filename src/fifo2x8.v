/*
 * Copyright (c) 2026 VLSI PD Tapeout team
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// 2 x 8-bit first-word-fall-through FIFO (4 bytes until the area cut).
// Holds the request payload, then is reused for the response (half-duplex).
// A push while full is dropped (the caller flags overflow); a pop while empty
// is ignored. rdata reads 0x00 when empty, which gives the "pad with 0x00" rule.
module fifo2x8 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clr,    // synchronous clear, wins over push/pop
    input  wire       push,
    input  wire [7:0] wdata,
    input  wire       pop,
    output wire [7:0] rdata,  // head byte
    output wire       full,
    output wire       empty,
    output wire [1:0] count   // 0..2
);

  reg [7:0] mem[0:1];  // no reset: saves area; never read while empty
  reg       wp, rp;
  reg [1:0] cnt;

  wire do_pop  = pop & (cnt != 2'd0);
  wire do_push = push & ((cnt != 2'd2) | do_pop);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp  <= 1'b0;
      rp  <= 1'b0;
      cnt <= 2'd0;
    end else if (clr) begin
      wp  <= 1'b0;
      rp  <= 1'b0;
      cnt <= 2'd0;
    end else begin
      if (do_push) wp <= ~wp;
      if (do_pop) rp <= ~rp;
      cnt <= cnt + {1'b0, do_push} - {1'b0, do_pop};
    end
  end

  always @(posedge clk) begin
    if (do_push && !clr) mem[wp] <= wdata;
  end

  assign empty = (cnt == 2'd0);
  assign full  = (cnt == 2'd2);
  assign count = cnt;
  assign rdata = empty ? 8'h00 : mem[rp];

endmodule
