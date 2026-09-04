# Out-of-context synthesis: protected vs unprotected vs TMR.
# LUT-only (-max_dsp 0) so the comparison is architecture against architecture;
# generic-cell counting cannot price a flip-flop or a carry chain.
set part xc7a100tcsg324-1
set designs [list mpmac_unprot mpmac_prot mpmac_tmr]
set fh [open "ooc_results.txt" w]
puts $fh [format "%-14s %7s %7s %8s %11s %11s" design LUT FF CARRY4 "WNS_r2r" "WNS_all"]
foreach top $designs {
  read_verilog -sv [list ../rtl/adders.v ../rtl/mpmac.v ../rtl/res3.v \
                         ../rtl/secded.v ../rtl/mpmac_prot.v]
  synth_design -top $top -part $part -mode out_of_context \
               -flatten_hierarchy full -max_dsp 0
  create_clock -name clk -period 10.000 [get_ports clk]
  set lut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
  set ff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
  set cy  [llength [get_cells -hier -filter {REF_NAME == CARRY4}]]
  set p1  [get_timing_paths -from [all_registers] -to [all_registers] -delay_type max -max_paths 1]
  set w1  [expr {[llength $p1] ? [get_property SLACK $p1] : "n/a"}]
  set_input_delay  -clock clk 0.000 [filter [all_inputs] {NAME != "clk"}]
  set_output_delay -clock clk 0.000 [all_outputs]
  set p2  [get_timing_paths -delay_type max -max_paths 1]
  set w2  [expr {[llength $p2] ? [get_property SLACK $p2] : "n/a"}]
  puts $fh [format "%-14s %7d %7d %8d %11s %11s" $top $lut $ff $cy $w1 $w2]
  flush $fh
  close_design
}
close $fh
