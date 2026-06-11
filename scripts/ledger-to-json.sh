#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-docs/memory-ledger.md}"
budget=$(grep -oE 'LIMIT_BUDGET_MIB=[0-9]+' "$FILE" | head -1 | cut -d= -f2)
# 파이프(|)를 포함한 진짜 표 행이면서 row 마커까지 가진 줄만 집계한다 —
# 본문 산문에서 마커를 언급해도 기형 행이 주입될 수 없게.
rows=$(grep 'ledger:row' "$FILE" | grep '|' | awk -F'|' '
  {
    gsub(/<!--.*-->/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2);
    req=$4; lim=$5; gsub(/[^0-9]/,"",req); gsub(/[^0-9]/,"",lim);
    printf "%s{\"component\":\"%s\",\"req\":%s,\"limit\":%s}", (NR>1?",":""), $2, req, lim
  }')
printf '{"budget":%s,"rows":[%s]}\n' "$budget" "$rows"
