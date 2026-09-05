#!/usr/bin/env bash
# Does ABFT amortise? Its cost is two checksum PEs regardless of array size,
# so the overhead should fall as 2/P. Per-PE protection cannot do that.
# Compared against protecting every PE with the Phase-1 residue+SEC-DED scheme.
set -u
cd "$(dirname "$0")"
FILES="rtl/adders.v rtl/mpmac.v rtl/res3.v rtl/secded.v rtl/mpmac_prot.v rtl/pe_array.v"

cells () {
  yosys -p "read_verilog -sv $FILES; hierarchy -top $1 ${2:-}; proc; opt -full; flatten; techmap; opt -full; abc -g AND,OR,XOR; opt -full; stat" 2>/dev/null \
    | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}'
}

UNPROT=$(cells mpmac_unprot)
PROT=$(cells mpmac_prot)
echo "one unprotected PE : $UNPROT cells"
echo "one protected PE   : $PROT cells  (+$(( 100*(PROT-UNPROT)/UNPROT ))%, Phase-1 scheme)"
echo
printf '%-4s %10s %10s %10s %12s %14s\n' 'P' 'bare' 'ABFT' 'per-PE' 'ABFT over' 'per-PE over'
printf '%s\n' '---------------------------------------------------------------------------'
for P in 4 8 16; do
  A=$(cells pe_array "-chparam P $P")
  BARE=$(( UNPROT * P ))
  PER=$(( PROT * P ))
  printf '%-4s %10s %10s %10s %11s%% %13s%%\n' "$P" "$BARE" "$A" "$PER" \
         "$(( 100*(A-BARE)/BARE ))" "$(( 100*(PER-BARE)/BARE ))"
done
