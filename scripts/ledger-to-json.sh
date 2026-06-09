#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-docs/memory-ledger.md}"
budget=$(grep -oE 'LIMIT_BUDGET_MIB=[0-9]+' "$FILE" | head -1 | cut -d= -f2)
# Only true table rows (contain a pipe) AND carry the row marker, so a prose
# mention of the marker can never inject a malformed row.
rows=$(grep 'ledger:row' "$FILE" | grep '|' | awk -F'|' '
  {
    gsub(/<!--.*-->/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2);
    req=$4; lim=$5; gsub(/[^0-9]/,"",req); gsub(/[^0-9]/,"",lim);
    printf "%s{\"component\":\"%s\",\"req\":%s,\"limit\":%s}", (NR>1?",":""), $2, req, lim
  }')
printf '{"budget":%s,"rows":[%s]}\n' "$budget" "$rows"
