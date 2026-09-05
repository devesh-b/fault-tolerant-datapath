// A PE array with algorithm-based fault tolerance.
//
// P processing elements compute a matrix-vector product y = W.x, one output
// each, sharing a broadcast operand. Two extra PEs carry checksum rows:
//
//   wc0[j] = sum_p     W[p][j]        -> yc0 = sum_p y[p]
//   wc1[j] = sum_p (p+1) W[p][j]      -> yc1 = sum_p (p+1) y[p]
//
// Both identities hold exactly in mod-2^48 arithmetic, so the syndromes
//
//   d0 = yc0 - sum_p y[p]      d1 = yc1 - sum_p (p+1) y[p]
//
// are zero iff every PE agreed with the checksum. A single faulty PE q with
// error e gives d0 = -e and d1 = -(q+1)e, so d1/d0 locates it and d0 corrects
// it. This is Huang-Abraham ABFT, the structure FT-CNN (Zhao et al.) applies
// per convolution layer, applied here per PE array.
//
// The point of doing it at ARRAY level rather than per PE: the cost is two
// extra PEs regardless of P, so it amortises. Per-PE protection does not.
//
// Constraint worth stating: the checksum weights must be representable in the
// same 16 bits as the data. sum_p (p+1) W[p][j] bounds the usable weight
// precision, and that bound tightens as P grows -- 12 bits at P=4, 10 at P=8,
// 8 at P=16. ABFT buys cheap redundancy and pays for it in dynamic range.
`timescale 1ns/1ps

module pe_array #(
  parameter integer P = 4                  // processing elements
) (
  input  wire            clk, rst, en, sgn,
  input  wire [1:0]      mode,
  input  wire [15:0]     x,                // broadcast operand
  input  wire [16*P-1:0] w,                // per-PE weight
  input  wire [15:0]     wc0, wc1,         // checksum-row weights
  input  wire [$clog2(P>1?P:2)-1:0] inj_pe, // which PE the saboteur reaches
  input  wire [47:0]     inj_acc,
  output wire [48*P-1:0] y,
  output wire [47:0]     yc0, yc1,
  output wire [47:0]     d0, d1,           // syndromes; both zero == agreement
  output wire            error
);
  wire [47:0] yv [0:P-1];
  genvar p;
  generate
    for (p = 0; p < P; p = p + 1) begin : pe
      wire hit = (inj_pe == p[$clog2(P>1?P:2)-1:0]);
      mpmac_unprot u (
        .clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
        .a(w[16*p +: 16]), .b(x),
        .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0),
        .inj_acc(hit ? inj_acc : 48'd0), .inj_ecc(7'd0),
        .acc(yv[p]), .detected(), .corrected(), .ded());
      assign y[48*p +: 48] = yv[p];
    end
  endgenerate

  // checksum PEs -- never injected, they are the reference
  mpmac_unprot c0 (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
    .a(wc0), .b(x), .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0),
    .inj_acc(48'd0), .inj_ecc(7'd0), .acc(yc0), .detected(), .corrected(), .ded());
  mpmac_unprot c1 (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
    .a(wc1), .b(x), .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0),
    .inj_acc(48'd0), .inj_ecc(7'd0), .acc(yc1), .detected(), .corrected(), .ded());

  // syndromes, in the same mod-2^48 arithmetic the accumulators use
  reg [47:0] s0, s1;
  integer k;
  always @* begin
    s0 = 48'd0; s1 = 48'd0;
    for (k = 0; k < P; k = k + 1) begin
      s0 = s0 + yv[k];
      s1 = s1 + $unsigned(k + 1) * yv[k];
    end
  end
  assign d0 = yc0 - s0;
  assign d1 = yc1 - s1;
  assign error = (d0 != 48'd0) || (d1 != 48'd0);
endmodule
