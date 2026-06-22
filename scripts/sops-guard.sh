#!/usr/bin/env bash
# *.enc.yaml이 실제로 SOPS 암호화됐는지 구조적으로 검증한다.
# 부분문자열 grep(데코이 우회 가능)이 아니라:
#  1) sops 메타데이터 블록(.sops.mac + .sops.lastmodified)이 존재하고
#  2) data/stringData 리프가 전부 ENC[...] 형태(평문 리프 0건)인지 확인.
# 실 age 키 복호는 필요 없다(yq만 있으면 게이트 러너에서 동작).
set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "sops-guard: yq가 필요하다(설치 후 재시도)." >&2
  exit 2
fi

# canonical age recipient(공개키) — .sops.yaml _recipients 앵커. recipient '개수'가 아니라 '신원'을 강제해
# recovery 키 스왑/드롭(개수는 2 유지)이 게이트를 통과하는 갭을 닫는다(DR 복호 불능 방지). 정렬해 집합 비교.
SOPS_YAML="$(git rev-parse --show-toplevel 2>/dev/null)/.sops.yaml"
[ -f "$SOPS_YAML" ] || SOPS_YAML=".sops.yaml"
CANON=""
[ -f "$SOPS_YAML" ] && CANON="$(yq '._recipients[]' "$SOPS_YAML" 2>/dev/null | sort)"

rc=0
for f in "$@"; do
  case "$f" in
    *.enc.yaml)
      reason=""
      if ! yq -e '.sops.mac' "$f" >/dev/null 2>&1; then
        reason="no sops.mac"
      elif ! yq -e '.sops.lastmodified' "$f" >/dev/null 2>&1; then
        reason="no sops.lastmodified"
      else
        # data/stringData 리프 중 ENC[AES256_GCM,...] prefix가 아닌 평문 리프 개수.
        # ⚠️ codex pass1 F4: 리터럴 "ENC[*]" 정확일치는 실제 ENC[AES256_GCM,...]를 평문으로 오판 →
        #    추적된 모든 enc.yaml을 오차단(gate 자체가 실패)한다. mikefarah yq엔 startswith가 없어
        #    test() 정규식으로 prefix 검사. `\\[`는 yq가 `\[`(리터럴 `[`)로 unescape한다.
        leaks=$(yq '[(.data // {})[], (.stringData // {})[]] | map(select(test("^ENC\\[") | not)) | length' "$f" 2>/dev/null || echo 99)
        [ "$leaks" = "0" ] || reason="$leaks plaintext data/stringData leaf(s)"
      fi
      # recipient 신원 검증 — 구조가 정상이고 canonical을 알 때만(정렬 집합 정확 일치).
      if [ -z "$reason" ] && [ -n "$CANON" ]; then
        got="$(yq '.sops.age[].recipient' "$f" 2>/dev/null | sort)"
        [ "$got" = "$CANON" ] || reason="recipient 신원이 .sops.yaml canonical(cluster+recovery)과 불일치(스왑/recovery 드롭)"
      fi
      if [ -n "$reason" ]; then
        echo "BLOCKED: $f is *.enc.yaml but NOT properly sops-encrypted ($reason)." >&2
        echo "         Run: sops --encrypt --in-place \"$f\"" >&2
        rc=1
      fi
      ;;
  esac
done
exit $rc
