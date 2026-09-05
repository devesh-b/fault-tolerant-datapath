// On-demand reliability: a small fault-free controller managing a fault-prone
// datapath. This is the DeSyRe thesis in miniature -- rather than hardening
// everything to the worst case, keep a tiny island trustworthy and let it
// decide how much protection the rest needs right now.
//
// Three protection levels, escalated on measured fault density:
//
//   L0  commit every result. Fastest. Residue still reports, but nothing acts
//       on it, so escapes reach the accumulator.
//   L1  retry on detection. Costs a cycle only when the checker fires, so it
//       is nearly free at low fault density. Catches transients that residue
//       can see -- which is everything additive.
// The controller's FLOOR defaults to L1, not L0, and that is a result rather
// than a default: L1 costs almost nothing (retries fire only on a detection,
// which is rare) while cutting silent corruption ~6x, so running at L0 is never
// worth it. Adaptivity only earns its machinery deciding between L1 and L2.
//
//   L2  execute twice and compare, always. Costs 2x throughput unconditionally
//       and catches faults residue CANNOT see, because two independent
//       evaluations of a transient disagree whether or not the error happens
//       to be divisible by 3. This is what buys back the ~31% operand-side
//       escape that Phase 1 cannot.
//
// The escalation structure is the same shape as FT-CNN's multischeme workflow
// (cheap always-on detector, escalate only on a hit), applied at the
// arithmetic-unit level instead of per convolution layer.
//
// The controller is assumed fault-free. That is DeSyRe's premise, not a
// dodge -- and it is only defensible because the island is small, which
// sweep_ondemand.sh measures rather than asserts.
`timescale 1ns/1ps

module fault_monitor #(
  parameter integer WIN   = 256, // observation window, cycles
  parameter integer HI    = 4,   // detections per window that force escalation
  parameter integer LO    = 1,   // detections per window that permit relaxing
  parameter integer COOL  = 4,   // consecutive clean windows before relaxing
  parameter integer FLOOR = 1,   // lowest level the controller may relax to
  parameter integer FORCE = 0    // 0 = adaptive; 1..3 pins the level to FORCE-1
) (
  input  wire       clk,
  input  wire       rst,
  input  wire       det_event,
  output wire [1:0] level
);
  reg [1:0]  lvl;
  reg [15:0] win_cnt;
  reg [15:0] det_cnt;
  reg [15:0] clean;              // consecutive windows at or below LO

  // A pinned level lets a testbench exercise L1 or L2 without first having to
  // induce the fault density that would reach them. Adaptive in normal use.
  assign level = (FORCE != 0) ? (FORCE[1:0] - 2'd1) : lvl;

  always @(posedge clk) begin
    if (rst) begin
      win_cnt <= 16'd0; det_cnt <= 16'd0; lvl <= FLOOR[1:0]; clean <= 16'd0;
    end else begin
      if (win_cnt == WIN[15:0] - 16'd1) begin
        win_cnt <= 16'd0;
        det_cnt <= 16'd0;
        // Escalate on the first bad window; relax only after COOL consecutive
        // clean ones. Without that asymmetry the level random-walks: at a fault
        // rate where roughly half of windows are clean, escalate-then-relax
        // cancels out and the controller never reaches the level it needs.
        if (det_cnt >= HI[15:0]) begin
          clean <= 16'd0;
          if (lvl != 2'd2) lvl <= lvl + 2'd1;
        end else if (det_cnt <= LO[15:0]) begin
          if (clean >= COOL[15:0] - 16'd1) begin
            clean <= 16'd0;
            if (lvl != FLOOR[1:0]) lvl <= lvl - 2'd1;
          end else begin
            clean <= clean + 16'd1;
          end
        end
      end else begin
        win_cnt <= win_cnt + 16'd1;
        if (det_event) det_cnt <= det_cnt + 16'd1;
      end
    end
  end
endmodule

module mpmac_ondemand #(
  parameter integer WIN   = 256,
  parameter integer HI    = 4,
  parameter integer LO    = 1,
  parameter integer COOL  = 4,
  parameter integer FLOOR = 1,
  parameter integer FORCE = 0
) (
  input  wire        clk, rst,
  input  wire        req,          // an operation is offered this cycle
  input  wire        sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a, b,
  input  wire [15:0] inj_a, inj_b,
  input  wire [47:0] inj_prod, inj_acc,
  input  wire [6:0]  inj_ecc,
  output wire [47:0] acc,
  output wire        taken,        // an operation was latched (registered strobe)
  output wire        done,         // a result was committed; acc is now updated
  output wire [1:0]  level,
  output wire        detected, corrected, ded
);
  // ---- held operation ------------------------------------------------------
  reg [15:0] ra, rb;
  reg [1:0]  rmode;
  reg        rsgn, have;
  reg        pass2;                // level 2: second evaluation pending
  reg [47:0] shadow;               // level 2: first evaluation's result

  // ---- ECC-protected accumulator ------------------------------------------
  reg  [47:0] q;
  reg  [5:0]  qchk;
  reg         qpar;
  wire [47:0] q_fix;
  secded48_dec dec (.din(q), .chk(qchk), .par(qpar),
                    .dout(q_fix), .corrected(corrected), .ded(ded));

  // ---- datapath, evaluated from the HELD operation ------------------------
  wire [47:0] prod_raw, prod, nxt;
  wire [3:0]  carry;
  mpmac_prod pr (.a(ra ^ inj_a), .b(rb ^ inj_b), .mode(rmode), .sgn(rsgn),
                 .prod(prod_raw));
  assign prod = prod_raw ^ inj_prod;
  lane_acc la (.accin(q_fix), .prod(prod), .mode(rmode), .accout(nxt), .carry(carry));
  res_check rc (.a(ra), .b(rb), .mode(rmode), .sgn(rsgn),
                .accin(q_fix), .accout(nxt), .prod(prod), .carry(carry),
                .mismatch(detected));

  wire [5:0] nchk;
  wire       npar;
  secded48_enc enc (.din(nxt), .chk(nchk), .par(npar));

  // ---- the fault-free island ----------------------------------------------
  wire det_now = have & detected;
  fault_monitor #(WIN, HI, LO, COOL, FLOOR, FORCE) mon (.clk(clk), .rst(rst),
                                           .det_event(det_now), .level(level));

  // ---- commit policy -------------------------------------------------------
  // L0: always commit. L1: commit unless the checker fired.
  // L2: first pass records, second pass commits only if the two agree.
  wire l2_second  = (level == 2'd2) & pass2;
  wire l2_agree   = l2_second & (nxt == shadow) & ~detected;
  wire commit     = have & ((level == 2'd0) ? 1'b1 :
                            (level == 2'd1) ? ~detected : l2_agree);
  wire latch_now  = (commit | ~have) & req;

  // Registered strobes. The combinational commit/latch conditions are only
  // valid in the cycle before the edge that acts on them; a consumer sampling
  // after the edge would see them already re-evaluated against the new state.
  reg taken_r, done_r;
  assign taken = taken_r;
  assign done  = done_r;

  always @(posedge clk) begin
    if (rst) begin
      q <= 48'd0; qchk <= 6'd0; qpar <= 1'b0;
      ra <= 16'd0; rb <= 16'd0; rmode <= 2'd0; rsgn <= 1'b0;
      have <= 1'b0; pass2 <= 1'b0; shadow <= 48'd0;
      taken_r <= 1'b0; done_r <= 1'b0;
    end else begin
      taken_r <= latch_now;
      done_r  <= commit;
      if (commit) begin
        q     <= nxt  ^ inj_acc;
        qchk  <= nchk ^ inj_ecc[5:0];
        qpar  <= npar ^ inj_ecc[6];
        have  <= 1'b0;
        pass2 <= 1'b0;
      end else if (have) begin
        // not committing: either retrying, or taking the second L2 pass
        if (level == 2'd2 && !pass2) begin
          shadow <= nxt;
          pass2  <= 1'b1;
        end else begin
          pass2 <= 1'b0;          // disagreement or detection -> start over
        end
      end

      // accept a new operation when the pipe is free
      if (latch_now) begin
        ra <= a; rb <= b; rmode <= mode; rsgn <= sgn;
        have <= 1'b1; pass2 <= 1'b0;
      end else if (commit) begin
        have <= 1'b0;
      end
    end
  end

  assign acc = q_fix;
endmodule
