// Residue mod 3 of a binary vector.
//
// 4^k = 1 (mod 3), so the residue of a binary number is just the sum of its
// 2-bit groups, taken mod 3. No division, no wide arithmetic - a small tree of
// 2-bit adders. This is the whole reason mod 3 is the cheap modulus to check
// against: mod 3 costs a tree, most other moduli cost a divider.
`timescale 1ns/1ps

// (a + b) mod 3, for a,b already in 0..2
module mod3_add (input wire [1:0] a, input wire [1:0] b, output wire [1:0] s);
  wire [2:0] t = {1'b0, a} + {1'b0, b};     // 0..4
  wire [2:0] d = t - 3'd3;                  // valid only when t >= 3
  assign s = (t >= 3'd3) ? d[1:0] : t[1:0];
endmodule

module res3 #(parameter integer W = 48) (
  input  wire [W-1:0] x,
  output wire [1:0]   r
);
  localparam integer N  = W / 2;                       // 2-bit groups
  localparam integer P  = (N <= 1) ? 1 : (N <= 2) ? 2 : (N <= 4) ? 4 :
                          (N <= 8) ? 8 : (N <= 16) ? 16 : 32;   // pad to pow2
  localparam integer LG = (P == 1) ? 0 : (P == 2) ? 1 : (P == 4) ? 2 :
                          (P == 8) ? 3 : (P == 16) ? 4 : 5;

  // Dependency analysis in the simulator is per-array, not per-element, so a
  // reduction tree held in one array reads as circular even though level l
  // only ever feeds level l+1. The logic is acyclic by construction.
  /* verilator lint_off UNOPTFLAT */
  wire [1:0] lvl [0:LG][0:P-1];
  /* verilator lint_on UNOPTFLAT */

  genvar i, l;
  generate
    // leaves: a 2-bit group is its own residue, except 3 -> 0
    for (i = 0; i < P; i = i + 1) begin : leaf
      if (i < N) assign lvl[0][i] = (x[2*i +: 2] == 2'd3) ? 2'd0 : x[2*i +: 2];
      else       assign lvl[0][i] = 2'd0;
    end
    // pairwise mod-3 reduction, log2(P) levels deep
    for (l = 0; l < LG; l = l + 1) begin : level
      for (i = 0; i < (P >> (l + 1)); i = i + 1) begin : node
        mod3_add u (.a(lvl[l][2*i]), .b(lvl[l][2*i + 1]), .s(lvl[l+1][i]));
      end
    end
  endgenerate
  assign r = lvl[LG][0];
endmodule
