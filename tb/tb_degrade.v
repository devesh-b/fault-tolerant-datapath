// Graceful degradation: what each protection level buys, and what it costs,
// as the fault density rises.
//
// Faults arrive in TIME, not per operation -- one bit flip somewhere in the
// unit on a randomly chosen cycle, at a chosen rate. That matters because a
// stalled or retrying unit is exposed for longer, so a scheme that buys
// coverage with cycles pays for it twice. Measuring per-cycle rather than
// per-op is what makes that visible.
//
// SDC is counted as EVENTS, not as corrupted trials. An accumulator ratchets:
// once a silent corruption lands, every later result is wrong too, so a
// per-trial pass/fail saturates at 100% and stops discriminating between
// schemes. After each event the reference is resynchronised to the observed
// accumulator so measurement continues from the new state.
//
// Build once per level:  -DFORCE_LEVEL=1 (L0) 2 (L1) 3 (L2) 0 (adaptive)
`timescale 1ns/1ps

`ifndef FORCE_LEVEL
 `define FORCE_LEVEL 0
`endif
`ifndef MON_WIN
 `define MON_WIN 32
`endif
`ifndef MON_HI
 `define MON_HI 1
`endif
`ifndef MON_FLOOR
 `define MON_FLOOR 1
`endif

module tb_degrade;
  localparam OPS    = 500;    // operations per trial
  localparam TRIALS = 100;    // trials per fault rate

  reg clk = 0, rst = 1, req = 0, sgn = 0;
  reg [1:0] mode = 0;
  reg [15:0] a = 0, b = 0;
  reg [15:0] inj_a = 0, inj_b = 0;
  reg [47:0] inj_prod = 0, inj_acc = 0;
  reg [6:0]  inj_ecc = 0;
  wire [47:0] acc;
  wire tk, dn;
  wire [1:0] lvl;

  mpmac_ondemand #(.WIN(`MON_WIN), .HI(`MON_HI), .LO(0), .COOL(4), .FLOOR(`MON_FLOOR), .FORCE(`FORCE_LEVEL)) dut (
    .clk(clk), .rst(rst), .req(req), .sgn(sgn), .mode(mode), .a(a), .b(b),
    .inj_a(inj_a), .inj_b(inj_b), .inj_prod(inj_prod), .inj_acc(inj_acc),
    .inj_ecc(inj_ecc), .acc(acc), .taken(tk), .done(dn), .level(lvl),
    .detected(), .corrected(), .ded());

  always #5 clk = ~clk;

  reg [47:0] exp;
  integer rate, trial, op, cycles, sdc, tot_cycles, lvl_sum, lvl_n;
  integer RATES [0:5];

  function [47:0] golden;
    input [47:0] cur; input [15:0] ga, gb; input [1:0] gm; input gs;
    reg [47:0] xa, xb; reg [23:0] ya, yb; reg [11:0] za, zb; reg [47:0] r;
    integer L;
    begin
      case (gm)
        2'd0: begin
          xa = gs ? {{32{ga[15]}}, ga} : {32'b0, ga};
          xb = gs ? {{32{gb[15]}}, gb} : {32'b0, gb};
          golden = cur + (xa * xb);
        end
        2'd1: begin
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

  task clear_inj; begin
    inj_a = 0; inj_b = 0; inj_prod = 0; inj_acc = 0; inj_ecc = 0;
  end endtask

  // one bit flip, uniformly over the four sites, for exactly one cycle
  task fire_fault;
    integer site, bit_;
    begin
      site = {$random} % 4;
      case (site)
        0: begin bit_ = {$random} % 48; inj_acc  = 48'd1 << bit_; end
        1: begin bit_ = {$random} % 7;  inj_ecc  = 7'd1  << bit_; end
        2: begin bit_ = {$random} % 16; inj_a    = 16'd1 << bit_; end
        3: begin bit_ = {$random} % 48; inj_prod = 48'd1 << bit_; end
      endcase
    end
  endtask

  reg [15:0] ra, rb;
  reg [1:0]  rm;
  reg        rs, took, dun;
  integer    i;

  initial begin
    RATES[0] = 0;      // no faults
    RATES[1] = 3000;   // 1 fault per N cycles
    RATES[2] = 1000;
    RATES[3] = 300;
    RATES[4] = 100;
    RATES[5] = 30;

    $display("level=%0d  (0=adaptive, 1=L0, 2=L1, 3=L2)", `FORCE_LEVEL);
    $display("fault_rate   SDC_events   per_1k_ops   cycles/op   mean_level");
    $display("---------------------------------------------------------------");

    for (rate = 0; rate < 6; rate = rate + 1) begin
      sdc = 0; tot_cycles = 0; lvl_sum = 0; lvl_n = 0;

      for (trial = 0; trial < TRIALS; trial = trial + 1) begin
        // reset
        req = 0; clear_inj; rst = 1; @(posedge clk); #1; rst = 0;
        exp = 48'd0; cycles = 0;

        for (op = 0; op < OPS; op = op + 1) begin
          ra = $random; rb = $random; rm = {$random} % 3; rs = $random;
          a = ra; b = rb; mode = rm; sgn = rs; req = 1;
          took = 0; dun = 0;
          while (!dun) begin
            clear_inj;
            if (RATES[rate] != 0 && (({$random} % RATES[rate]) == 0)) fire_fault;
            @(posedge clk); #1;
            cycles = cycles + 1;
            if (tk) took = 1;
            if (took) req = 0;
            if (dn) dun = 1;
            lvl_sum = lvl_sum + lvl; lvl_n = lvl_n + 1;
          end
          req = 0;
          exp = golden(exp, ra, rb, rm, rs);
          if (acc !== exp) begin
            sdc = sdc + 1;     // a silent corruption event
            exp = acc;         // resync and keep measuring
          end
        end
        clear_inj;
        tot_cycles = tot_cycles + cycles;
      end

      if (RATES[rate] == 0)
        $display("   none      %7d   %8.3f   %8.3f     %.2f",
                 sdc, 1000.0*sdc/(TRIALS*OPS), 1.0*tot_cycles/(TRIALS*OPS), 1.0*lvl_sum/lvl_n);
      else
        $display("  1/%-6d   %7d   %8.3f   %8.3f     %.2f",
                 RATES[rate], sdc, 1000.0*sdc/(TRIALS*OPS), 1.0*tot_cycles/(TRIALS*OPS), 1.0*lvl_sum/lvl_n);
    end
    $display("");
    $finish;
  end
endmodule
