// Fault-injection campaign.
//
// Two copies of the datapath run in lockstep on identical stimulus: one clean
// (the golden reference), one with a single transient bit flip injected at a
// random site, bit and cycle. Every trial lands in exactly one bucket:
//
//   masked     output correct, no flag        the fault died on its own
//   corrected  output correct, checker fired  protection repaired it
//   detected   output wrong,   checker fired  SAFE failure -- a system can retry
//   escaped    output wrong,   no flag        SILENT DATA CORRUPTION
//
// Only the last one is a real failure. Reporting a single "coverage" number
// hides the masked/detected distinction, which is exactly the distinction
// IEC 61508 cares about, so all four are reported separately.
//
// Injection sites mirror the fault model in README.md:
//   ACC   accumulator data bits          predicted 0% escape (2^k mod 3 != 0)
//   ECC   stored check/parity bits       protected design only
//   OPA   operand register, post-residue predicted ~33% escape
//   PROD  combinational node in the array predicted ~33% escape
`timescale 1ns/1ps

module tb_campaign;

  localparam TRIALS = 4000;
  localparam CYCLES = 8;

  reg clk = 0, rst = 1, en = 0, sgn = 0;
  reg [1:0] mode = 0;
  reg [15:0] a = 0, b = 0;
  reg [15:0] inj_a = 0, inj_b = 0;
  reg [47:0] inj_prod = 0, inj_acc = 0;
  reg [6:0]  inj_ecc = 0;

  wire [47:0] acc_g, acc_d;
  wire det_g, cor_g, ded_g, det_d, cor_d, ded_d;

`ifndef DUT
 `define DUT mpmac_prot
`endif
  // golden: same design, never injected
  `DUT gold (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode), .a(a), .b(b),
             .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0), .inj_acc(48'd0),
             .inj_ecc(7'd0), .acc(acc_g),
             .detected(det_g), .corrected(cor_g), .ded(ded_g));
  // device under test: injected
  `DUT dut  (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode), .a(a), .b(b),
             .inj_a(inj_a), .inj_b(inj_b), .inj_prod(inj_prod), .inj_acc(inj_acc),
             .inj_ecc(inj_ecc), .acc(acc_d),
             .detected(det_d), .corrected(cor_d), .ded(ded_d));

  always #5 clk = ~clk;

  integer site, trial, cyc, inj_cyc, bitpos, s;
  integer n_masked [0:3], n_corr [0:3], n_det [0:3], n_esc [0:3], n_tot [0:3];
  integer lat_sum [0:3], lat_n [0:3];
  reg flagged, corr_seen; integer flag_cyc;
  reg [8*5:1] sname [0:3];

  task clear_inj; begin
    inj_a = 0; inj_b = 0; inj_prod = 0; inj_acc = 0; inj_ecc = 0;
  end endtask

  initial begin
    sname[0] = "ACC"; sname[1] = "ECC"; sname[2] = "OPA"; sname[3] = "PROD";
    for (s = 0; s < 4; s = s + 1) begin
      n_masked[s]=0; n_corr[s]=0; n_det[s]=0; n_esc[s]=0; n_tot[s]=0;
      lat_sum[s]=0; lat_n[s]=0;
    end

    for (site = 0; site < 4; site = site + 1) begin
      for (trial = 0; trial < TRIALS; trial = trial + 1) begin
        // --- reset both copies ---
        clear_inj; en = 0; rst = 1; @(posedge clk); #1; rst = 0;
        mode = $random; if (mode == 2'd3) mode = 2'd2;
        sgn  = $random;
        inj_cyc = {$random} % CYCLES;
        flagged = 0; corr_seen = 0; flag_cyc = -1;

        for (cyc = 0; cyc < CYCLES; cyc = cyc + 1) begin
          a = $random; b = $random; en = 1;
          clear_inj;
          if (cyc == inj_cyc) begin
            case (site)
              0: begin bitpos = {$random} % 48; inj_acc  = 48'd1 << bitpos; end
              1: begin bitpos = {$random} % 7;  inj_ecc  = 7'd1  << bitpos; end
              2: begin bitpos = {$random} % 16; inj_a    = 16'd1 << bitpos; end
              3: begin bitpos = {$random} % 48; inj_prod = 48'd1 << bitpos; end
            endcase
          end
          @(posedge clk); #1;
          if (det_d || ded_d) begin
            if (!flagged) flag_cyc = cyc;
            flagged = 1;
          end
          if (cor_d) begin
            if (!flagged && flag_cyc < 0) flag_cyc = cyc;
            corr_seen = 1;
          end
        end
        en = 0; clear_inj;

        // --- classify ---
        n_tot[site] = n_tot[site] + 1;
        if (acc_d === acc_g) begin
          if (flagged || corr_seen) begin
            n_corr[site] = n_corr[site] + 1;
            if (flag_cyc >= inj_cyc) begin
              lat_sum[site] = lat_sum[site] + (flag_cyc - inj_cyc);
              lat_n[site]   = lat_n[site] + 1;
            end
          end else n_masked[site] = n_masked[site] + 1;
        end else begin
          if (flagged || corr_seen) begin
            n_det[site] = n_det[site] + 1;
            if (flag_cyc >= inj_cyc) begin
              lat_sum[site] = lat_sum[site] + (flag_cyc - inj_cyc);
              lat_n[site]   = lat_n[site] + 1;
            end
          end else n_esc[site] = n_esc[site] + 1;
        end
      end
    end

    $display("");
    $display("site   trials  masked  corrected  detected  ESCAPED(SDC)   escape%%   mean lat");
    $display("-----------------------------------------------------------------------------");
    for (s = 0; s < 4; s = s + 1)
      $display("%0s%0s %6d  %6d  %9d  %8d  %12d   %6.2f%%   %s",
               sname[s], (s==0)?"  ":(s==1)?"  ":(s==2)?"  ":" ",
               n_tot[s], n_masked[s], n_corr[s], n_det[s], n_esc[s],
               100.0*n_esc[s]/n_tot[s],
               (lat_n[s] > 0) ? "see below" : "n/a");
    $display("");
    for (s = 0; s < 4; s = s + 1)
      if (lat_n[s] > 0)
        $display("mean flag latency %0s : %.2f cycles (%0d flagged)",
                 sname[s], 1.0*lat_sum[s]/lat_n[s], lat_n[s]);
    $display("");
    $display("CAMPAIGN DONE");
    $finish;
  end
endmodule
