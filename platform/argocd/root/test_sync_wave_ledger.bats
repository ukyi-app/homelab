#!/usr/bin/env bats
# sync-wave 원장 드리프트 가드 — root 3계층(argocd-app/root-app/apps/*)의 모든 sync-wave 값이
# SYNC-WAVES.md 표에 행으로 존재하는지. manifest엔 있으나 표에 없는 값 = wave 교착 1차 신호(AGENTS.md).
# 순수 텍스트 검사(라이브 무관). + 부호는 양변에서 정규화(manifest "2" == 표 "+2").
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LEDGER="$ROOT/platform/argocd/root/SYNC-WAVES.md"
}

@test "every sync-wave value in root app definitions has a row in SYNC-WAVES.md" {
  local files mwaves lwaves w missing=""
  files="$(ls "$ROOT"/platform/argocd/argocd-app.yaml "$ROOT"/platform/argocd/root/root-app.yaml "$ROOT"/platform/argocd/root/apps/*.yaml)"
  mwaves="$(grep -hoE 'sync-wave: "[+-]?[0-9]+"' $files | grep -oE '[+-]?[0-9]+' | sed 's/^+//' | sort -u)"
  lwaves="$(grep -E '^\|[[:space:]]*[+-]?[0-9]+[[:space:]]*\|' "$LEDGER" | sed -E 's/^\|[[:space:]]*([+-]?[0-9]+)[[:space:]]*\|.*/\1/' | sed 's/^+//' | sort -u)"
  [ -n "$mwaves" ]
  for w in $mwaves; do
    echo "$lwaves" | grep -qxF -- "$w" || missing="$missing $w"
  done
  [ -z "$missing" ] || { echo "SYNC-WAVES.md 원장에 누락된 wave:$missing (manifest엔 있으나 표에 없음)"; false; }
}
