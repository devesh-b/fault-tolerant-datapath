// ABFT on a PE array: detect, locate and correct a faulty PE from two
// checksum rows, and measure what that is worth numerically.
//
// A single faulty PE q with accumulated error e gives syndromes
//   d0 = -e          d1 = -(q+1)e
// so q is the unique index with d1 == (q+1)*d0, and y[q] += d0 repairs it.
// Location is done by testing the P candidates rather than dividing: in
// mod-2^48 arithmetic e need not be invertible, so d1/d0 is not always defined
// while the comparison always is.
//
// Weights are restricted to 11-bit signed so the checksum rows stay
// representable in 16 bits -- the real constraint ABFT imposes, and the reason
// the usable weight precision falls as the array grows.
`timescale 1ns/1ps

`ifndef P_PE
 `define P_PE 4
`endif

module tb_abft;
  localparam P      = `P_PE;
  localparam L      = 32;        // dot-product length
  localparam TRIALS = 3000;

  reg clk = 0, rst = 1, en = 0;
  reg [15:0] x = 0;
  reg [16*P-1:0] w = 0;
  reg [15:0] wc0 = 0, wc1 = 0;
  reg [$clog2(P>1?P:2)-1:0] inj_pe = 0;
  reg [47:0] inj_acc = 0;

  wire [48*P-1:0] y;
  wire [47:0] yc0, yc1, d0, d1;
  wire error;

  pe_array #(P) dut (
    .clk(clk), .rst(rst), .en(en), .sgn(1'b1), .mode(2'd0),
    .x(x), .w(w), .wc0(wc0), .wc1(wc1),
    .inj_pe(inj_pe), .inj_acc(inj_acc),
    .y(y), .yc0(yc0), .yc1(yc1), .d0(d0), .d1(d1), .error(error));

  always #5 clk = ~clk;

  reg  signed [15:0] wv [0:P-1];
  reg  signed [47:0] gy [0:P-1];       // golden per-PE accumulator
  reg         [47:0] cy [0:P-1];       // corrected observation
  integer t, l, p, q, cand, found;
  integer detected, located, corrected_ok, undetected, trials_faulted;
  integer nmatch, ambig, mis_by_bit [0:47], hit_by_bit [0:47], bb, injbit;
  real    err_raw, err_abft, err_retry, scale;
  integer retries;
  reg signed [47:0] diff;

  initial begin
    detected = 0; located = 0; corrected_ok = 0; undetected = 0; trials_faulted = 0;
    ambig = 0;
    for (bb = 0; bb < 48; bb = bb + 1) begin mis_by_bit[bb] = 0; hit_by_bit[bb] = 0; end
    err_raw = 0.0; err_abft = 0.0; err_retry = 0.0; retries = 0;
    scale = 2.0 ** 47;

    for (t = 0; t < TRIALS; t = t + 1) begin
      // ---- fresh weights, 11-bit signed so the checksum rows fit 16 bits ----
      wc0 = 16'sd0; wc1 = 16'sd0;
      for (p = 0; p < P; p = p + 1) begin
        wv[p] = $signed({{5{1'b0}}, $random}) % 2048;
        w[16*p +: 16] = wv[p];
        wc0 = wc0 + wv[p];
        wc1 = wc1 + (p + 1) * wv[p];
        gy[p] = 48'sd0;
      end

      en = 0; inj_acc = 0; rst = 1; @(posedge clk); #1; rst = 0;
      inj_pe = {$random} % P;
      q = inj_pe;
      // one transient, at a random cycle, in a random accumulator bit
      l = {$random} % L;
      injbit = {$random} % 48;      // its own variable: p is a loop index below

      for (integer c = 0; c < L; c = c + 1) begin
        x = $random;
        en = 1;
        inj_acc = (c == l) ? (48'd1 << injbit) : 48'd0;
        @(posedge clk); #1;
        for (integer k = 0; k < P; k = k + 1)
          gy[k] = gy[k] + $signed(wv[k]) * $signed(x);
      end
      en = 0; inj_acc = 0;
      trials_faulted = trials_faulted + 1;

      // ---- ABFT: detect, locate, correct --------------------------------
      for (p = 0; p < P; p = p + 1) cy[p] = y[48*p +: 48];
      if (error) begin
        detected = detected + 1;
        found = -1; nmatch = 0;
        for (cand = 0; cand < P; cand = cand + 1)
          if (d1 == ($unsigned(cand + 1) * d0)) begin
            nmatch = nmatch + 1;
            if (found < 0) found = cand;
          end
        if (nmatch > 1) ambig = ambig + 1;
        // Ambiguity is not a tuning problem, it is missing information: with
        // e = 2^47, (cand+1)*d0 mod 2^48 is the same for every odd cand+1, so
        // no comparison against these two syndromes can separate the
        // candidates. The escape is temporal, not algebraic -- re-run and take
        // the clean result. That costs a second pass, but only on a detection.
        retries = retries + 1;
        hit_by_bit[injbit] = hit_by_bit[injbit] + 1;
        if (found == q) located = located + 1;
        else            mis_by_bit[injbit] = mis_by_bit[injbit] + 1;
        if (found >= 0) cy[found] = cy[found] + d0;
      end else if (y[48*q +: 48] !== gy[q]) begin
        undetected = undetected + 1;
      end

      // ---- numerical damage, before and after ---------------------------
      for (p = 0; p < P; p = p + 1) begin
        diff = $signed(y[48*p +: 48]) - gy[p];
        err_raw = err_raw + (diff < 0 ? -1.0*diff : 1.0*diff) / scale / P;
        diff = $signed(cy[p]) - gy[p];
        err_abft = err_abft + (diff < 0 ? -1.0*diff : 1.0*diff) / scale / P;
        // detect-then-re-execute: the transient is gone on the second pass, so
        // the recomputed result is the golden one
        err_retry = err_retry + (error ? 0.0 :
                    ((diff < 0 ? -1.0*diff : 1.0*diff) / scale / P));
      end
      if (cy[q] === gy[q]) corrected_ok = corrected_ok + 1;
    end

    $display("PE array with ABFT, P = %0d, dot-product length %0d, %0d trials",
             P, L, TRIALS);
    $display("  faults injected      : %0d", trials_faulted);
    $display("  detected             : %0d  (%.2f%%)", detected, 100.0*detected/trials_faulted);
    $display("  located correctly    : %0d  (%.2f%% of detected)",
             located, detected ? 100.0*located/detected : 0.0);
    $display("  PE restored exactly  : %0d  (%.2f%%)",
             corrected_ok, 100.0*corrected_ok/trials_faulted);
    $display("  UNDETECTED corruption: %0d", undetected);
    $display("  mean |error| per output, unprotected : %.6e", err_raw/trials_faulted);
    $display("  mean |error| per output, after ABFT  : %.6e", err_abft/trials_faulted);
    $display("  mean |error| per output, detect+rerun : %.6e", err_retry/trials_faulted);
    $display("  re-executions triggered              : %0d  (%.2f%% of trials)",
             retries, 100.0*retries/trials_faulted);
    $display("  location ambiguous (>1 candidate matched): %0d  (%.2f%%)",
             ambig, 100.0*ambig/trials_faulted);
    $display("");
    $display("  mislocation by injected accumulator bit:");
    $display("    bit  injected  mislocated");
    for (bb = 0; bb < 48; bb = bb + 1)
      if (mis_by_bit[bb] > 0)
        $display("    %3d  %8d  %10d", bb, hit_by_bit[bb], mis_by_bit[bb]);
    $display("ABFT DONE");
    $finish;
  end
endmodule
