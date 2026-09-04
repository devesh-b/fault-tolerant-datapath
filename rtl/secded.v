// Hamming SEC-DED over the 48-bit accumulator file.
//
//   48 data + 6 Hamming check + 1 overall parity = 55 bits stored.
//
// Check bit c covers every codeword position whose index has bit c set;
// positions that are powers of two hold the check bits, the rest hold data.
// A single flip makes the syndrome equal the 1-based position that flipped,
// which is the whole trick - the syndrome names the bit.
//
// The overall parity bit is what separates "one error" from "two". On decode
// it MUST be taken over the received codeword (data XOR stored check bits XOR
// stored parity), never over check bits recomputed from corrupted data:
// recomputing folds the error into both terms, so a single flip at a position
// with an odd bit-count cancels itself and is misreported as a double error.
// model/protect.py fails exactly that way if you get it wrong.
`timescale 1ns/1ps

module secded48_enc (
  input  wire [47:0] din,
  output wire [5:0]  chk,
  output wire        par
);
  function [47:0] mask_for;
    input integer c;
    integer p, cnt;
    begin
      mask_for = 48'd0;
      cnt = 0;
      for (p = 1; p <= 54; p = p + 1)
        if ((p & (p - 1)) != 0) begin          // data position
          if (((p >> c) & 1) != 0) mask_for[cnt] = 1'b1;
          cnt = cnt + 1;
        end
    end
  endfunction

  genvar c;
  generate
    for (c = 0; c < 6; c = c + 1) begin : ck
      assign chk[c] = ^(din & mask_for(c));
    end
  endgenerate
  assign par = (^din) ^ (^chk);
endmodule

module secded48_dec (
  input  wire [47:0] din,
  input  wire [5:0]  chk,
  input  wire        par,
  output wire [47:0] dout,
  output wire        corrected,      // one error, repaired
  output wire        ded             // two errors, detected and NOT repairable
);
  // returns the 1-based codeword position of data bit d (max 54, so 6 bits).
  // Declared 6-bit rather than integer because a bit-select on a function call
  // is SystemVerilog-only and Yosys will not parse it.
  function [5:0] pos_of;
    input integer d;
    integer p, cnt;
    begin
      cnt = 0; pos_of = 6'd0;
      for (p = 1; p <= 54; p = p + 1)
        if ((p & (p - 1)) != 0) begin
          if (cnt == d) pos_of = p[5:0];
          cnt = cnt + 1;
        end
    end
  endfunction

  wire [5:0] exp_chk;
  secded48_enc enc (.din(din), .chk(exp_chk), .par());

  wire [5:0] syn = chk ^ exp_chk;
  wire       p   = par ^ (^din) ^ (^chk);      // received codeword, not recomputed

  wire [47:0] flip;
  genvar d;
  generate
    for (d = 0; d < 48; d = d + 1) begin : fx
      assign flip[d] = p & (syn == pos_of(d));
    end
  endgenerate

  assign dout      = din ^ flip;
  assign corrected = p;                        // syn==0 -> the parity bit itself
  assign ded       = (|syn) & ~p;
endmodule
