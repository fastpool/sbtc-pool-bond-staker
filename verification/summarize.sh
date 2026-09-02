#!/usr/bin/env bash
# Collate the per-invariant runs into one table.
cd "$(dirname "$0")/results"
printf "%-42s %6s %8s %10s %11s %6s\n" INVARIANT HOLDS VIOLATED "NOT-PROVEN" UNFINISHED SKIP
total_h=0; total_v=0; total_n=0; total_u=0; total_s=0
for f in *.txt; do
  inv="${f%.txt}"
  h=$(grep -c "^  HOLDS" "$f"); v=$(grep -c "^  VIOLATED" "$f")
  n=$(grep -c "^  NOT PROVEN" "$f"); u=$(grep -c "^  UNFINISHED" "$f")
  s=$(grep -c "^  SKIP" "$f")
  printf "%-42s %6s %8s %10s %11s %6s\n" "$inv" "$h" "$v" "$n" "$u" "$s"
  total_h=$((total_h+h)); total_v=$((total_v+v)); total_n=$((total_n+n))
  total_u=$((total_u+u)); total_s=$((total_s+s))
done
printf "%-42s %6s %8s %10s %11s %6s\n" TOTAL "$total_h" "$total_v" "$total_n" "$total_u" "$total_s"
echo
echo "Violations:"
grep -h "^  VIOLATED" *.txt | sort -u || echo "  (none)"
