#!/usr/bin/env bash
set -euo pipefail

for i in $(seq 1 500); do
  P1=$((RANDOM % 5 + 1))
  P2=$((RANDOM % 15 + 1))
  P3=$((RANDOM % 15 + 1))
  P4=$((RANDOM % 15 + 1))
  P5=$((RANDOM % 5 + 1))
  W=$((RANDOM % 10 + 1))

  echo "Run $i: P1=$P1 P2=$P2 P3=$P3 P4=$P4 P5=$P5 W=$W"

  ./test_image_1_coop "$P1" "$P2" "$P3" "$P4" "$P5" "$W"
done
