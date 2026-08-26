#!/usr/bin/env bash
# *.enc.yaml이 실제로 SOPS 암호화됐는지 구조적으로 검증한다.
# 부분문자열 grep(데코이 우회 가능)이 아니라:
#  1) sops 메타데이터 블록(.sops.mac + .sops.lastmodified)이 존재하고
#  2) data/stringData 리프가 전부 ENC[...] 형태(평문 리프 0건)인지 확인.
# 실 age 키 복호는 필요 없다(yq만 있으면 게이트 러너에서 동작).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init sops-guard
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "sops-guard" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"

if ! command -v yq >/dev/null 2>&1; then
  echo "sops-guard: yq가 필요하다(설치 후 재시도)." >&2
  exit 2
fi

# canonical age recipient(공개키) — .sops.yaml _recipients 앵커. recipient '개수'가 아니라 '신원'을 강제해
# recovery 키 스왑/드롭(개수는 2 유지)이 게이트를 통과하는 갭을 닫는다(DR 복호 불능 방지). 정렬해 집합 비교.
# shellcheck source=scripts/lib/sops-recipients.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sops-recipients.sh"
CANON="$(sops_canonical_recipients)"

# 인자 0개 = 아무것도 평가하지 않고 exit 0이었다. 호출자 3곳(.pre-commit-config · Makefile ·
# ci.yaml의 `xargs -r`)이 전부 "0 파일=성공"으로 읽었고, 글롭이 깨지면 required 스텝이 조용히 초록이었다.
# 이제 무인자면 **자기 도메인을 스스로 열거**하고 바닥값을 건다(현재 추적 9건 — 래칫 아님).
if [ "$#" -gt 0 ]; then
  # --floor를 **명시하면** 인자/픽스처 모드에도 적용한다(floor_set — 명시 플래그의 조용한 no-op 금지).
  if floor_set sops-guard; then
    scan_floor sops-guard "$#" "$(floor_of sops-guard 6)" || exit 1
  else
    scan_signal sops-guard "$#"   # 인자(pre-commit·픽스처) 모드도 신호는 낸다 — 06의 fixture↔real 판별자
  fi
fi
if [ "$#" -eq 0 ]; then
  cd "$ROOT"   # git ls-files는 cwd 상대다
  tracked="$(scan_enumerate sops-guard git ls-files '*.enc.yaml')" || exit 1
  scan_floor sops-guard "$(scan_count "$tracked")" "$(floor_of sops-guard 6)" || exit 1
  # shellcheck disable=SC2086  # 경로에 공백 없음(레포 규약) — 위치 인자로 재주입
  set -- $tracked
fi

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
        got="$(sops_file_recipients "$f")"
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
