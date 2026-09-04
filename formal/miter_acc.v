// The protected datapath swaps mpmac_shared's final seg_add48 accumulate for
// lane_acc, which additionally exposes the per-lane carry the residue check
// needs. The product network above it is the same code, so the whole proof
// obligation is this one block: does lane_acc add exactly the way seg_add48
// does, in every mode?
//
// Combinational, depth 1, closes in a second -- where proving it on the whole
// sequential MAC did not close in ten minutes. Picking the granularity is the
// difference between a proof and a timeout.
module miter_acc (input [47:0] x, y, input [1:0] mode);
  wire [47:0] s_seg, s_lane;
  wire [3:0]  carry_unused;
  seg_add48 u0 (.x(x), .y(y), .mode(mode), .s(s_seg));
  lane_acc  u1 (.accin(x), .prod(y), .mode(mode), .accout(s_lane), .carry(carry_unused));
  always @* assert (s_seg == s_lane);
endmodule
