#!/usr/bin/env bash
# Is the fault-free island actually small? DeSyRe's premise is that you can
# afford to harden a controller precisely because it is tiny next to the
# datapath it manages. That is a measurement, not an assumption.
set -u
cd "$(dirname "$0")"
FILES="rtl/adders.v rtl/mpmac.v rtl/res3.v rtl/secded.v rtl/mpmac_prot.v rtl/mpmac_ondemand.v"

printf '%-18s | %-21s | %-21s | %s\n' 'module' 'as-written cells/depth' 'after ABC cells/depth' 'FF bits'
printf '%s\n' '--------------------------------------------------------------------------------------'
for top in fault_monitor mpmac_unprot mpmac_prot mpmac_ondemand; do
  base="read_verilog -sv $FILES; hierarchy -top $top; proc; opt -full; flatten; techmap; opt -full"
  raw=$(yosys -p "$base; ltp; stat" 2>/dev/null)
  opt=$(yosys -p "$base; abc -g AND,OR,XOR; opt -full; ltp; stat" 2>/dev/null)
  rc=$(echo "$raw" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  rd=$(echo "$raw" | grep -oE 'length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  ac=$(echo "$opt" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  ad=$(echo "$opt" | grep -oE 'length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  ff=$(echo "$opt" | grep -oE '[0-9]+ +\$_S?DFF[A-Z0-9_]*_' | awk '{s+=$1} END {print s+0}')
  printf '%-18s | %9s / %-9s | %9s / %-9s | %s\n' "$top" "${rc:-?}" "${rd:-?}" "${ac:-?}" "${ad:-?}" "${ff:-?}"
done
