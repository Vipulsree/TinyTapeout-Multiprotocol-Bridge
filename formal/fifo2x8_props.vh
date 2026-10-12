// SPDX-License-Identifier: Apache-2.0
// Formal properties for fifo2x8 (property P1). Included inside the module when
// FORMAL is defined (read_verilog -formal); see formal/README.md.
//
// P1: the count never exceeds 2 and never underflows. On top of that the FIFO is
// checked against a 2-entry reference queue, so bytes come out in the order they
// went in and an empty FIFO reads 0x00.

reg fv_past = 1'b0;
always @(posedge clk) fv_past <= 1'b1;
initial assume (!rst_n);

// ---------------------------------------------------------------- reference model
// fv_q0 is the head. A push while full is dropped unless a pop frees a slot in the
// same cycle; a pop while empty is ignored; clr wins.
reg [7:0] fv_q0, fv_q1;
reg [1:0] fv_n;

wire       fv_pop  = pop & (fv_n != 2'd0);
wire       fv_push = push & ((fv_n != 2'd2) | fv_pop);
wire [1:0] fv_n_popped = fv_n - {1'b0, fv_pop};

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) fv_n <= 2'd0;
  else if (clr) fv_n <= 2'd0;
  else fv_n <= fv_n_popped + {1'b0, fv_push};
end

always @(posedge clk) begin
  if (rst_n && !clr) begin
    if (fv_pop) fv_q0 <= fv_q1;
    if (fv_push) begin
      if (fv_n_popped == 2'd0) fv_q0 <= wdata;
      else fv_q1 <= wdata;
    end
  end
end

// Stored bytes, oldest first
wire [7:0] fv_s0 = mem[rp];
wire [7:0] fv_s1 = mem[~rp];

always @(posedge clk) begin
  if (rst_n) begin
    // P1: the count stays in 0..2
    assert (cnt <= 2'd2);
    // pointers and count agree (count 0 and count 2 both have wp == rp)
    assert (cnt[0] == (wp ^ rp));
    assert (full == (cnt == 2'd2));
    assert (empty == (cnt == 2'd0));

    // same contents as the reference model
    assert (cnt == fv_n);
    if (fv_n > 2'd0) assert (fv_s0 == fv_q0);
    if (fv_n > 2'd1) assert (fv_s1 == fv_q1);
    assert (rdata == ((fv_n == 2'd0) ? 8'h00 : fv_q0));
  end

  if (fv_past && rst_n && $past(rst_n)) begin
    if ($past(clr)) assert (cnt == 2'd0);
    else begin
      // P1: no underflow, no overflow
      if ($past(cnt) == 2'd0 && !$past(push)) assert (cnt == 2'd0 && rp == $past(rp));
      if ($past(cnt) == 2'd2 && !$past(pop)) assert (cnt == 2'd2 && wp == $past(wp));
      // the count moves by one at most
      assert (cnt == $past(cnt) || cnt == $past(cnt) + 2'd1 || cnt + 2'd1 == $past(cnt));
    end
  end
end

// Reachability: the FIFO fills, drains, and takes a push while full with a pop.
`ifndef FV_TOP  // too deep to reach through the pins: unit runs only
always @(posedge clk) begin
  if (fv_past && rst_n && $past(rst_n) && !$past(clr)) begin
    cover (cnt == 2'd2);
    cover ($past(cnt) == 2'd1 && cnt == 2'd0);
    cover ($past(cnt) == 2'd2 && $past(push) && $past(pop) && cnt == 2'd2);
  end
end
`endif
