// Tie-off wrappers presenting the plain mpmac interface, so the protected and
// unprotected datapaths can be run against the arith track's golden-model
// testbench unchanged (1,467,310 self-checked vectors). Fault-free behaviour
// must be identical to the unprotected design; anything else means the
// protection changed the answer, which is worse than no protection.
`timescale 1ns/1ps

module dut_unprot (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  mpmac_unprot u (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
    .a(a), .b(b), .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0),
    .inj_acc(48'd0), .inj_ecc(7'd0), .acc(acc),
    .detected(), .corrected(), .ded());
endmodule

module dut_prot (
  input wire clk, rst, en, sgn, input wire [1:0] mode,
  input wire [15:0] a, b, output wire [47:0] acc);
  wire det, cor, ded;
  mpmac_prot u (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode),
    .a(a), .b(b), .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0),
    .inj_acc(48'd0), .inj_ecc(7'd0), .acc(acc),
    .detected(det), .corrected(cor), .ded(ded));
  // With no faults injected, none of these may ever fire. A false alarm here
  // is the failure mode that makes a checker useless in practice.
  always @(posedge clk) if (!rst) begin
    if (det) $display("FAIL: residue false alarm at time %0t", $time);
    if (cor) $display("FAIL: SEC-DED corrected a fault-free word at %0t", $time);
    if (ded) $display("FAIL: SEC-DED double-error on a fault-free word at %0t", $time);
  end
endmodule
