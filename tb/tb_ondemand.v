// Fault-free correctness of the on-demand unit, at every protection level.
//
// Adaptivity must not change the answer. Whatever the controller decides, a
// committed result has to equal what a plain MAC would have produced -- a
// protection scheme that quietly alters arithmetic is worse than none.
//
// Levels are reached without injecting anything by choosing the monitor's
// thresholds: HI=0 makes every window escalate, so the L2 instance climbs to
// double-execute-and-compare and stays there.
`timescale 1ns/1ps

module tb_ondemand;
  localparam M16 = 2'd0, M8 = 2'd1, M4 = 2'd2;

  reg clk = 0, rst = 1, req = 0, sgn = 0;
  reg [1:0] mode = 0;
  reg [15:0] a = 0, b = 0;
  wire [47:0] acc0, acc2;
  wire tk0, dn0, tk2, dn2;
  wire [1:0] lvl0, lvl2;

  // pinned to L0: commit every result, no retry
  mpmac_ondemand #(.FORCE(1)) u0 (
    .clk(clk), .rst(rst), .req(req), .sgn(sgn), .mode(mode), .a(a), .b(b),
    .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0), .inj_acc(48'd0), .inj_ecc(7'd0),
    .acc(acc0), .taken(tk0), .done(dn0), .level(lvl0), .detected(), .corrected(), .ded());

  // pinned to L2: double-execute-and-compare on every operation
  mpmac_ondemand #(.FORCE(3)) u2 (
    .clk(clk), .rst(rst), .req(req), .sgn(sgn), .mode(mode), .a(a), .b(b),
    .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0), .inj_acc(48'd0), .inj_ecc(7'd0),
    .acc(acc2), .taken(tk2), .done(dn2), .level(lvl2), .detected(), .corrected(), .ded());

  always #5 clk = ~clk;

  reg [47:0] exp;
  integer ops = 0, errors = 0, cyc0 = 0, cyc2 = 0;

  function [47:0] golden;
    input [47:0] cur; input [15:0] ga, gb; input [1:0] gm; input gs;
    reg [47:0] xa, xb; reg [23:0] ya, yb; reg [11:0] za, zb; reg [47:0] r;
    integer L;
    begin
      case (gm)
        M16: begin
          xa = gs ? {{32{ga[15]}}, ga} : {32'b0, ga};
          xb = gs ? {{32{gb[15]}}, gb} : {32'b0, gb};
          golden = cur + (xa * xb);
        end
        M8: begin
          r = 48'd0;
          for (L = 0; L < 2; L = L + 1) begin
            ya = gs ? {{16{ga[8*L+7]}}, ga[8*L +: 8]} : {16'b0, ga[8*L +: 8]};
            yb = gs ? {{16{gb[8*L+7]}}, gb[8*L +: 8]} : {16'b0, gb[8*L +: 8]};
            r[24*L +: 24] = cur[24*L +: 24] + (ya * yb);
          end
          golden = r;
        end
        default: begin
          r = 48'd0;
          for (L = 0; L < 4; L = L + 1) begin
            za = gs ? {{8{ga[4*L+3]}}, ga[4*L +: 4]} : {8'b0, ga[4*L +: 4]};
            zb = gs ? {{8{gb[4*L+3]}}, gb[4*L +: 4]} : {8'b0, gb[4*L +: 4]};
            r[12*L +: 12] = cur[12*L +: 12] + (za * zb);
          end
          golden = r;
        end
      endcase
    end
  endfunction

  // Offer one operation, drop req as soon as each unit has latched it, and
  // wait for the commit strobe. Holding req high past the latch would let the
  // unit take the same operands twice and accumulate them twice.
  task automatic issue;
    input [15:0] ta, tb_; input [1:0] tm; input ts;
    reg t0, t2, d0, d2;
    begin
      a = ta; b = tb_; mode = tm; sgn = ts;
      t0 = 0; t2 = 0; d0 = 0; d2 = 0;
      req = 1;
      while (!(d0 && d2)) begin
        @(posedge clk); #1;
        if (tk0) t0 = 1;
        if (tk2) t2 = 1;
        if (t0 && t2) req = 0;
        if (dn0) d0 = 1;
        if (dn2) d2 = 1;
        if (!d0) cyc0 = cyc0 + 1;
        if (!d2) cyc2 = cyc2 + 1;
      end
      req = 0;
      exp = golden(exp, ta, tb_, tm, ts);
      ops = ops + 1;
      if (acc0 !== exp) begin
        errors = errors + 1;
        if (errors < 6) $display("FAIL L0 op%0d mode=%0d sgn=%0d: acc=%h exp=%h", ops, tm, ts, acc0, exp);
      end
      if (acc2 !== exp) begin
        errors = errors + 1;
        if (errors < 6) $display("FAIL L2 op%0d mode=%0d sgn=%0d: acc=%h exp=%h", ops, tm, ts, acc2, exp);
      end
    end
  endtask

  integer i, m, s;
  reg [15:0] ra, rb;
  initial begin
    @(posedge clk); #1; rst = 0; exp = 48'd0;
    for (s = 0; s <= 1; s = s + 1)
      for (m = 0; m < 3; m = m + 1)
        for (i = 0; i < 4000; i = i + 1) begin
          ra = $random; rb = $random;
          issue(ra, rb, m[1:0], s[0]);
        end
    $display("");
    $display("ops committed      : %0d", ops);
    $display("final level  L0-unit: %0d   L2-unit: %0d", lvl0, lvl2);
    $display("cycles waiting L0=%0d  L2=%0d  (L2 should be about 2x)", cyc0, cyc2);
    $display("errors             : %0d", errors);
    if (errors == 0 && lvl0 == 2'd0 && lvl2 == 2'd2) $display("PASS");
    else $display("FAIL");
    $finish;
  end
endmodule
