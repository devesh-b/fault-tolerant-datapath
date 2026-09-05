// Containment, measured on the datapath rather than argued from the model.
//
// One bit flip lands uniformly in the 48-bit accumulator file. In M16 that file
// is one lane, in M8 two, in M4 four. Narrow lanes corrupt a smaller FRACTION
// of the output vector but perturb the lane they hit by proportionally more.
// This measures the product of those two effects on the real design.
//
// Damage is reported against the whole output vector: the perturbation of the
// corrupted lane in units of that lane's full scale, divided by the number of
// lanes the vector carries.
`timescale 1ns/1ps

module tb_damage;
  localparam TRIALS = 20000;

  reg clk = 0, rst = 1, en = 0, sgn = 0;
  reg [1:0] mode = 0;
  reg [15:0] a = 0, b = 0;
  reg [47:0] inj_acc = 0;
  wire [47:0] acc_g, acc_d;

  mpmac_unprot gold (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode), .a(a), .b(b),
    .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0), .inj_acc(48'd0), .inj_ecc(7'd0),
    .acc(acc_g), .detected(), .corrected(), .ded());
  mpmac_unprot dut  (.clk(clk), .rst(rst), .en(en), .sgn(sgn), .mode(mode), .a(a), .b(b),
    .inj_a(16'd0), .inj_b(16'd0), .inj_prod(48'd0), .inj_acc(inj_acc), .inj_ecc(7'd0),
    .acc(acc_d), .detected(), .corrected(), .ded());

  always #5 clk = ~clk;

  integer m, t, bitpos, lanes, w, L, hit;
  real lane_sum, vec_sum, d, fullscale;
  reg [47:0] diff;
  reg [8*4:1] mname;

  initial begin
    $display("mode  lane_w  lanes  output_corrupted  damage_to_lane  damage_to_vector");
    $display("--------------------------------------------------------------------------");
    for (m = 0; m < 3; m = m + 1) begin
      case (m)
        0: begin lanes = 1; w = 48; mname = "M16"; end
        1: begin lanes = 2; w = 24; mname = "M8"; end
        default: begin lanes = 4; w = 12; mname = "M4"; end
      endcase
      lane_sum = 0.0; vec_sum = 0.0;
      fullscale = 2.0 ** (w - 1);

      for (t = 0; t < TRIALS; t = t + 1) begin
        en = 0; inj_acc = 0; rst = 1; @(posedge clk); #1; rst = 0;
        mode = m[1:0]; sgn = 1'b1; en = 1;
        // a couple of clean accumulate cycles so the file is not all zero
        a = $random; b = $random; @(posedge clk); #1;
        a = $random; b = $random; @(posedge clk); #1;
        // one flip, uniformly over the whole 48-bit file
        bitpos  = {$random} % 48;
        inj_acc = 48'd1 << bitpos;
        a = $random; b = $random; @(posedge clk); #1;
        inj_acc = 0;
        en = 0;

        diff = acc_d ^ acc_g;                 // exactly the flipped bit
        hit  = bitpos / w;                    // which lane took it
        d    = (2.0 ** (bitpos % w)) / fullscale;
        lane_sum = lane_sum + d;
        vec_sum  = vec_sum + d / lanes;
        if (diff == 48'd0) $display("  note: flip at %0d produced no difference", bitpos);
      end

      $display("%-5s %6d %6d %15.0f%% %15.4f %17.4f",
               mname, w, lanes, 100.0/lanes, lane_sum/TRIALS, vec_sum/TRIALS);
    end
    $display("");
    $display("DAMAGE DONE");
    $finish;
  end
endmodule
