// Protected multi-precision MAC.
//
// Reuses the verified product network from mpmac.v (mp_frontend + seg_add48)
// and adds two independent protection layers:
//
//   residue mod 3   concurrent DETECTION across the whole multiply-accumulate
//   Hamming SEC-DED CORRECTION of the 48-bit accumulator file
//
// The check, in exactly the form the hardware computes it:
//
//   U_next = U_acc + U_p - c*2^w                   (lane add, w even)
//   U_p    = V_p + s_p        (mod 3)              (V_p = a*b, s_p = sign bit)
//   =>  r(U_next) = r(U_acc) + r_a*r_b + s_p - c   (mod 3)
//
// Everything on the right is a residue-tree output, a sign bit, or a carry
// wire. Dropping the s_p or c terms makes the checker fire on every negative
// product or every accumulator wrap; model/protect.py catches that if you do.
//
// Residues are computed ONCE at 12-bit (accumulator) and 4-bit (operand)
// granularity and combined per mode, because 2^12 = 2^4 = 1 (mod 3) -- so a
// wide lane's residue is just the sum of its narrow residues. One set of trees
// serves all three modes instead of three sets.
`timescale 1ns/1ps

`define PMODE_M16 2'd0
`define PMODE_M8  2'd1
`define PMODE_M4  2'd2

// (a * b) mod 3 for a,b in 0..2
module mod3_mul (input wire [1:0] a, input wire [1:0] b, output wire [1:0] p);
  assign p = (a == 2'd0 || b == 2'd0) ? 2'd0 :
             (a == 2'd1)              ? b    :
             (b == 2'd1)              ? a    : 2'd1;   // 2*2 = 4 = 1
endmodule

// ---------------------------------------------------------------------------
// Combinational product network: the placement + reduction half of
// mpmac_shared, stopped before the accumulate so the accumulator can be
// protected separately. Proved equivalent to mpmac_shared via mpmac_unprot.
// ---------------------------------------------------------------------------
module mpmac_prod (
  input  wire [15:0] a,
  input  wire [15:0] b,
  input  wire [1:0]  mode,
  input  wire        sgn,
  output wire [47:0] prod
);
  wire [159:0] pp;
  mp_frontend fe (.a(a), .b(b), .mode(mode), .sgn(sgn), .pp(pp));

  wire [47:0] term [0:15];
  genvar i, j;
  generate
    for (i = 0; i < 4; i = i + 1) begin : trow
      for (j = 0; j < 4; j = j + 1) begin : tcol
        localparam integer K   = 4*i + j;
        localparam integer L8  = i / 2;
        localparam integer OK8 = ((i/2) == (j/2)) ? 1 : 0;
        localparam integer OK4 = (i == j) ? 1 : 0;
        localparam integer SH8 = (OK8 != 0) ? (4*(i + j - 4*L8)) : 0;

        wire [9:0]  p    = pp[K*10 +: 10];
        wire        sbit = p[9];
        wire [47:0] t16  = {{38{sbit}}, p} << (4*(i+j));
        wire [23:0] v8   = {{14{sbit}}, p} << SH8;
        wire [47:0] t8   = (OK8 != 0) ? ({24'd0, v8} << (24*L8)) : 48'd0;
        wire [11:0] v4   = {{2{sbit}}, p};
        wire [47:0] t4   = (OK4 != 0) ? ({36'd0, v4} << (12*i)) : 48'd0;

        assign term[K] = (mode == `PMODE_M16) ? t16 :
                         (mode == `PMODE_M8 ) ? t8  : t4;
      end
    end
  endgenerate

  wire [47:0] l1 [0:7];
  wire [47:0] l2 [0:3];
  wire [47:0] l3 [0:1];
  genvar k;
  generate
    for (k = 0; k < 8; k = k + 1) begin : lev1
      seg_add48 u (.x(term[2*k]), .y(term[2*k+1]), .mode(mode), .s(l1[k]));
    end
    for (k = 0; k < 4; k = k + 1) begin : lev2
      seg_add48 u (.x(l1[2*k]), .y(l1[2*k+1]), .mode(mode), .s(l2[k]));
    end
    for (k = 0; k < 2; k = k + 1) begin : lev3
      seg_add48 u (.x(l2[2*k]), .y(l2[2*k+1]), .mode(mode), .s(l3[k]));
    end
  endgenerate
  seg_add48 u4 (.x(l3[0]), .y(l3[1]), .mode(mode), .s(prod));
endmodule

// ---------------------------------------------------------------------------
// Lane accumulate, exposing the per-lane carry-out that the residue check
// needs. Carries cannot cross a lane boundary in any mode.
// ---------------------------------------------------------------------------
module lane_acc (
  input  wire [47:0] accin,
  input  wire [47:0] prod,
  input  wire [1:0]  mode,
  output wire [47:0] accout,
  output wire [3:0]  carry
);
  wire [48:0] s16 = {1'b0, accin}         + {1'b0, prod};
  wire [24:0] s8a = {1'b0, accin[23:0]}   + {1'b0, prod[23:0]};
  wire [24:0] s8b = {1'b0, accin[47:24]}  + {1'b0, prod[47:24]};
  wire [12:0] s4a = {1'b0, accin[11:0]}   + {1'b0, prod[11:0]};
  wire [12:0] s4b = {1'b0, accin[23:12]}  + {1'b0, prod[23:12]};
  wire [12:0] s4c = {1'b0, accin[35:24]}  + {1'b0, prod[35:24]};
  wire [12:0] s4d = {1'b0, accin[47:36]}  + {1'b0, prod[47:36]};

  assign accout = (mode == `PMODE_M16) ? s16[47:0] :
                  (mode == `PMODE_M8 ) ? {s8b[23:0], s8a[23:0]}
                                       : {s4d[11:0], s4c[11:0], s4b[11:0], s4a[11:0]};
  assign carry  = (mode == `PMODE_M16) ? {3'b000, s16[48]} :
                  (mode == `PMODE_M8 ) ? {2'b00, s8b[24], s8a[24]}
                                       : {s4d[12], s4c[12], s4b[12], s4a[12]};
endmodule

// ---------------------------------------------------------------------------
// Residue-mod-3 checker.
//
// Residues are built once at the narrowest granularity and combined upward:
// 2^4 = 2^12 = 1 (mod 3), so a wide lane's residue is the sum of its narrow
// residues. One set of trees serves every mode.
// ---------------------------------------------------------------------------
module res_check (
  input  wire [15:0] a,
  input  wire [15:0] b,
  input  wire [1:0]  mode,
  input  wire        sgn,
  input  wire [47:0] accin,
  input  wire [47:0] accout,
  input  wire [47:0] prod,
  input  wire [3:0]  carry,
  output wire        mismatch
);
  // --- narrow residues -----------------------------------------------------
  wire [1:0] ra4  [0:3], rb4  [0:3];      // 4-bit operand digits
  wire [1:0] rin  [0:3], rout [0:3];      // 12-bit accumulator blocks
  genvar k;
  generate
    for (k = 0; k < 4; k = k + 1) begin : narrow
      res3 #(4)  ua (.x(a     [4*k  +: 4 ]), .r(ra4 [k]));
      res3 #(4)  ub (.x(b     [4*k  +: 4 ]), .r(rb4 [k]));
      res3 #(12) ui (.x(accin [12*k +: 12]), .r(rin [k]));
      res3 #(12) uo (.x(accout[12*k +: 12]), .r(rout[k]));
    end
  endgenerate

  // --- combine upward ------------------------------------------------------
  wire [1:0] ra8 [0:1], rb8 [0:1], ri8 [0:1], ro8 [0:1];
  wire [1:0] ra16, rb16, ri16, ro16;
  generate
    for (k = 0; k < 2; k = k + 1) begin : pair
      mod3_add pa (.a(ra4 [2*k]), .b(ra4 [2*k+1]), .s(ra8[k]));
      mod3_add pb (.a(rb4 [2*k]), .b(rb4 [2*k+1]), .s(rb8[k]));
      mod3_add pi (.a(rin [2*k]), .b(rin [2*k+1]), .s(ri8[k]));
      mod3_add po (.a(rout[2*k]), .b(rout[2*k+1]), .s(ro8[k]));
    end
  endgenerate
  mod3_add qa (.a(ra8[0]), .b(ra8[1]), .s(ra16));
  mod3_add qb (.a(rb8[0]), .b(rb8[1]), .s(rb16));
  mod3_add qi (.a(ri8[0]), .b(ri8[1]), .s(ri16));
  mod3_add qo (.a(ro8[0]), .b(ro8[1]), .s(ro16));

  // --- per-lane operand selection -----------------------------------------
  wire [1:0] rA [0:3], rB [0:3], rI [0:3], rO [0:3];
  wire       sA [0:3], sB [0:3], sP [0:3], cY [0:3], act [0:3];
  generate
    for (k = 0; k < 4; k = k + 1) begin : lanesel
      // lanes 2,3 are inactive in M8 and masked by act[], so the k&1 index
      // is only ever read where it is meaningful
      assign rA[k]  = (mode == `PMODE_M4) ? ra4[k] :
                      (mode == `PMODE_M8) ? ra8[k & 1]
                                          : ((k == 0) ? ra16 : 2'd0);
      assign rB[k]  = (mode == `PMODE_M4) ? rb4[k] :
                      (mode == `PMODE_M8) ? rb8[k & 1]
                                          : ((k == 0) ? rb16 : 2'd0);
      assign rI[k]  = (mode == `PMODE_M4) ? rin[k] :
                      (mode == `PMODE_M8) ? ri8[k & 1]
                                          : ((k == 0) ? ri16 : 2'd0);
      assign rO[k]  = (mode == `PMODE_M4) ? rout[k] :
                      (mode == `PMODE_M8) ? ro8[k & 1]
                                          : ((k == 0) ? ro16 : 2'd0);
      // sign bit of each operand lane, and of the placed product lane
      assign sA[k]  = sgn & ((mode == `PMODE_M4) ? a[4*k+3] :
                             (mode == `PMODE_M8) ? a[8*(k&1)+7] : a[15]);
      assign sB[k]  = sgn & ((mode == `PMODE_M4) ? b[4*k+3] :
                             (mode == `PMODE_M8) ? b[8*(k&1)+7] : b[15]);
      assign sP[k]  = (mode == `PMODE_M4) ? prod[12*k+11] :
                      (mode == `PMODE_M8) ? prod[24*(k&1)+23] : prod[47];
      assign cY[k]  = carry[k];
      assign act[k] = (mode == `PMODE_M4) ? 1'b1 :
                      (mode == `PMODE_M8) ? (k < 2) : (k == 0);
    end
  endgenerate

  // --- the check: r(next) == r(acc) + r_a*r_b + s_p - c  (mod 3) ----------
  wire [3:0] bad;
  generate
    for (k = 0; k < 4; k = k + 1) begin : chk
      // operand residues corrected for sign: v = u - s (mod 3), 2^w = 1
      wire [1:0] rAv, rBv, mul, t1, t2, exp;
      mod3_add sa (.a(rA[k]), .b(sA[k] ? 2'd2 : 2'd0), .s(rAv));
      mod3_add sb (.a(rB[k]), .b(sB[k] ? 2'd2 : 2'd0), .s(rBv));
      mod3_mul mm (.a(rAv), .b(rBv), .p(mul));
      mod3_add a1 (.a(rI[k]), .b(mul),                 .s(t1));
      mod3_add a2 (.a(t1),    .b(sP[k] ? 2'd1 : 2'd0), .s(t2));
      mod3_add a3 (.a(t2),    .b(cY[k] ? 2'd2 : 2'd0), .s(exp));  // -c = +2
      assign bad[k] = act[k] & (exp != rO[k]);
    end
  endgenerate
  assign mismatch = |bad;
endmodule

// ---------------------------------------------------------------------------
// Unprotected baseline. Same ports, same saboteurs, no checking -- so the
// campaign and the synthesis comparison see identical interfaces.
//
// Saboteur placement mirrors the fault model:
//   inj_a/inj_b  corrupt the operands AFTER residue generation, i.e. a fault
//                inside the datapath, not corrupted input
//   inj_prod     a combinational node in the product network
//   inj_acc      the accumulator data bits
//   inj_ecc      the stored check/parity bits (ignored here)
// ---------------------------------------------------------------------------
module mpmac_unprot (
  input  wire        clk, rst, en, sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a, b,
  input  wire [15:0] inj_a, inj_b,
  input  wire [47:0] inj_prod, inj_acc,
  input  wire [6:0]  inj_ecc,
  output wire [47:0] acc,
  output wire        detected, corrected, ded
);
  wire _unused = &{1'b0, inj_ecc};
  reg  [47:0] q;
  wire [47:0] prod_raw, prod, nxt;
  wire [3:0]  carry;

  mpmac_prod pr (.a(a ^ inj_a), .b(b ^ inj_b), .mode(mode), .sgn(sgn), .prod(prod_raw));
  assign prod = prod_raw ^ inj_prod;
  lane_acc la (.accin(q), .prod(prod), .mode(mode), .accout(nxt), .carry(carry));

  always @(posedge clk) begin
    if (rst)     q <= 48'd0;
    else if (en) q <= nxt ^ inj_acc;
  end
  assign acc = q;
  assign detected = 1'b0;
  assign corrected = 1'b0;
  assign ded = 1'b0;
endmodule

// ---------------------------------------------------------------------------
// Protected: residue mod 3 detects, SEC-DED corrects the accumulator.
//
// The accumulator is stored as data + ECC. Every cycle the stored word is
// decoded (repairing a single flip anywhere in the 55 stored bits) before it
// is used, so a transient never accumulates into the running total.
// ---------------------------------------------------------------------------
module mpmac_prot (
  input  wire        clk, rst, en, sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a, b,
  input  wire [15:0] inj_a, inj_b,
  input  wire [47:0] inj_prod, inj_acc,
  input  wire [6:0]  inj_ecc,
  output wire [47:0] acc,
  output wire        detected,   // residue mismatch: the arithmetic is wrong
  output wire        corrected,  // SEC-DED repaired a stored bit
  output wire        ded         // two stored bits wrong: detected, unrepairable
);
  reg  [47:0] q;
  reg  [5:0]  qchk;
  reg         qpar;

  // repair the stored word before use
  wire [47:0] q_fix;
  secded48_dec dec (.din(q), .chk(qchk), .par(qpar),
                    .dout(q_fix), .corrected(corrected), .ded(ded));

  wire [47:0] prod_raw, prod, nxt;
  wire [3:0]  carry;
  mpmac_prod pr (.a(a ^ inj_a), .b(b ^ inj_b), .mode(mode), .sgn(sgn), .prod(prod_raw));
  assign prod = prod_raw ^ inj_prod;
  lane_acc la (.accin(q_fix), .prod(prod), .mode(mode), .accout(nxt), .carry(carry));

  // residues are taken from the CLEAN operands, so a fault injected into the
  // datapath copy is visible to the checker
  res_check rc (.a(a), .b(b), .mode(mode), .sgn(sgn),
                .accin(q_fix), .accout(nxt), .prod(prod), .carry(carry),
                .mismatch(detected));

  wire [5:0] nchk;
  wire       npar;
  secded48_enc enc (.din(nxt), .chk(nchk), .par(npar));

  always @(posedge clk) begin
    if (rst) begin
      q <= 48'd0; qchk <= 6'd0; qpar <= 1'b0;
    end else if (en) begin
      q    <= nxt  ^ inj_acc;
      qchk <= nchk ^ inj_ecc[5:0];
      qpar <= npar ^ inj_ecc[6];
    end
  end
  assign acc = q_fix;
endmodule

// ---------------------------------------------------------------------------
// TMR reference point. Not a proposal -- it anchors the top of the overhead
// axis at the ~200% that DeSyRe-style work exists to avoid.
//
// inj_copy selects which of the three copies the saboteur reaches, so a
// campaign can hit any one of them. That also keeps the copies structurally
// distinct: with the saboteur wired to copy 0 only, the other two are
// identical logic cones and Yosys' opt_merge folds them into one, reporting
// TMR at ~110% overhead instead of ~200%. The measurement artefact looks
// exactly like a good result, which is what makes it worth guarding against.
// ---------------------------------------------------------------------------
module mpmac_tmr (
  input  wire        clk, rst, en, sgn,
  input  wire [1:0]  mode,
  input  wire [15:0] a, b,
  input  wire [15:0] inj_a, inj_b,
  input  wire [47:0] inj_prod, inj_acc,
  input  wire [6:0]  inj_ecc,
  input  wire [1:0]  inj_copy,
  output wire [47:0] acc,
  output wire        detected, corrected, ded
);
  wire _unused = &{1'b0, inj_ecc};
  wire [47:0] q [0:2];

  genvar k;
  generate
    for (k = 0; k < 3; k = k + 1) begin : copy
      wire sel = (inj_copy == k[1:0]);
      mpmac_unprot c (
        .clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode), .a(a), .b(b),
        .inj_a   (inj_a    & {16{sel}}),
        .inj_b   (inj_b    & {16{sel}}),
        .inj_prod(inj_prod & {48{sel}}),
        .inj_acc (inj_acc  & {48{sel}}),
        .inj_ecc (7'd0),
        .acc(q[k]), .detected(), .corrected(), .ded());
    end
  endgenerate

  assign acc       = (q[0] & q[1]) | (q[1] & q[2]) | (q[0] & q[2]);  // majority
  assign detected  = |((q[0] ^ q[1]) | (q[1] ^ q[2]));               // disagreement
  assign corrected = detected;                                        // repairs as it detects
  assign ded       = 1'b0;
endmodule
