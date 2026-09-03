#!/usr/bin/env bash
# *.sealed.yaml이 실제로 **봉인**됐는지 구조적으로 검증한다 — sops-guard.sh가 *.enc.yaml에 하는 일의
# 봉인본 판. 실 복호 키는 필요 없다(yq만 있으면 게이트 러너·pre-commit에서 동작).
#
# 병(2026-09-03 실측): 가장 개연적인 오봉인 두 형태를 **어떤 기존 게이트도 잡지 않았다**.
#   ① 봉인 전 평문 Secret을 `<x>.sealed.yaml` 이름으로 커밋(kind: Secret + stringData 평문)
#   ② 봉인은 했는데 평문 리프가 `spec.template.stringData`에 잔류
# 커버리지 갭의 근거: sops-guard는 `*.enc.yaml`만 본다(케이스문이 봉인본을 그냥 통과시킨다) ·
# `.pre-commit-config.yaml`의 훅 files 정규식도 `\.enc\.yaml$`뿐 · `tools/lib/sealed-contract.ts`의
# 봉인 계약은 create-app/update-secrets 콜사이트에서만 돌고 · `scripts/check-app-deploy.sh`의 봉인
# 검사는 `apps/*/deploy/prod/`로 스코프가 좁아 platform/ 봉인본 19개가 통째로 무커버였다.
# `.gitleaks.toml`의 봉인본 면제는 `generic-api-key` 하나로 좁혀졌지만 ①②는 정확히 그 룰에 걸리는
# 형태라 스코프를 좁혀도 여전히 면제된다 — 룰이 아니라 **구조 가드**의 영역이다.
#
# 검사(파일당, 문서당 — 다중 문서 YAML은 문서별 합산):
#   ① kind == SealedSecret
#   ② spec.encryptedData가 **비어 있지 않은 맵**
#   ③ 평문 리프 0건 — `.data` · `.stringData` · `.spec.template.data` · `.spec.template.stringData`
#   ④ encryptedData 값이 전부 kubeseal 암호문 표기(`^Ag[A-Za-z0-9+/=]+$`)
# ④는 ①②③을 통과한 "형식만 맞춘" 위조(평문을 encryptedData에 그대로 넣기)를 막는다.
#
# 두 도메인의 바닥값이 서로 다른 붕괴를 잡는다: 파일 수는 글롭·열거 붕괴를, 키 총수는 "파일은 다
# 있는데 내용이 통째로 비었다"를 잡는다(파일 수 축은 그걸 원리적으로 못 본다).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init sealed-guard
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(sops-guard와 동형).
take_floors "sealed-guard:files sealed-guard:keys" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"

if ! command -v yq >/dev/null 2>&1; then
  echo "sealed-guard: yq가 필요하다(설치 후 재시도)." >&2
  exit 2
fi

# 바닥값 기본값 — 콜사이트 소유(커널은 수치를 모른다). 실측 2026-09-03: 추적 19파일 · 키 27개.
# 래칫이 아니다: 정당한 축소를 red로 만들지 않을 만큼 낮게, 붕괴(→0)는 반드시 잡을 만큼 높게.
FILE_FLOOR=12
KEY_FLOOR=18

# 스코프 1비트 — 인자 모드(pre-commit·픽스처)인가, 자기 도메인을 스스로 여는 기본 모드인가.
# ⚠️ 기본 모드는 아래에서 `set -- $tracked`로 argv를 채우므로 **그 뒤의 `$#`로는 두 모드를 못 가른다**.
SCOPE_NARROWED=0
if [ "$#" -gt 0 ]; then
  SCOPE_NARROWED=1
  # --floor를 **명시하면** 인자/픽스처 모드에도 적용한다(명시 플래그의 조용한 no-op 금지 — sops-guard 동형).
  if floor_set sealed-guard:files; then
    scan_floor sealed-guard:files "$#" "$(floor_of sealed-guard:files "$FILE_FLOOR")" || exit 1
  else
    scan_signal sealed-guard:files "$#"   # 인자(pre-commit·픽스처) 모드도 신호는 낸다 — fixture↔real 판별자
  fi
else
  cd "$ROOT"   # git ls-files는 cwd 상대다
  tracked="$(scan_enumerate sealed-guard:files git ls-files '*.sealed.yaml')" || exit 1
  scan_floor sealed-guard:files "$(scan_count "$tracked")" "$(floor_of sealed-guard:files "$FILE_FLOOR")" || exit 1
  # shellcheck disable=SC2086  # 경로에 공백 없음(레포 규약) — 위치 인자로 재주입
  set -- $tracked
fi

# 문서별 결과를 합산한다 — 다중 문서 YAML에서 yq는 문서마다 한 줄을 낸다.
sum_lines() { awk '{ s += $1 } END { print s + 0 }'; }

rc=0
keys_total=0
for f in "$@"; do
  case "$f" in
    *.sealed.yaml) ;;
    *) continue ;;
  esac
  reason=""
  # 파싱 실패는 **판정 불가**다 — 아래 집계가 전부 0이 되어 "위반 없음"으로 읽히는 자리라 먼저 막는다.
  if ! yq '.' "$f" >/dev/null 2>&1; then
    reason="YAML 파싱 실패(판정 불가는 통과가 아니다)"
  else
    n_notsealed="$(yq '[select(.kind != "SealedSecret")] | length' "$f" | sum_lines)"
    n_encbad="$(yq '[select((.spec.encryptedData | tag) != "!!map" or (.spec.encryptedData | length) == 0)] | length' "$f" | sum_lines)"
    n_plain="$(yq '[(.data // {} | keys | .[]), (.stringData // {} | keys | .[]), (.spec.template.data // {} | keys | .[]), (.spec.template.stringData // {} | keys | .[])] | length' "$f" | sum_lines)"
    n_keys="$(yq '[.spec.encryptedData // {} | keys | .[]] | length' "$f" | sum_lines)"
    # ⚠️ `test()`는 문자열에만 정의된다 — tag 검사를 **먼저** 두어 비-문자열 값에서 yq가 죽는 것을 막는다.
    n_badval="$(yq '[.spec.encryptedData // {} | .[] | select((tag == "!!str") and test("^Ag[A-Za-z0-9+/=]+$") | not)] | length' "$f" | sum_lines)"
    keys_total=$((keys_total + n_keys))
    if [ "$n_notsealed" -ne 0 ]; then
      reason="kind가 SealedSecret이 아니다(봉인 전 평문 Secret을 봉인본 이름으로 커밋한 형태)"
    elif [ "$n_encbad" -ne 0 ]; then
      reason="spec.encryptedData가 비어 있거나 맵이 아니다(봉인된 값이 하나도 없다)"
    elif [ "$n_plain" -ne 0 ]; then
      reason="$n_plain plaintext leaf(s) in data/stringData/template.data/template.stringData"
    elif [ "$n_badval" -ne 0 ]; then
      reason="$n_badval encryptedData value(s) not in kubeseal ciphertext form (^Ag…)"
    fi
  fi
  if [ -n "$reason" ]; then
    echo "BLOCKED: $f is *.sealed.yaml but NOT properly sealed ($reason)." >&2
    echo "         Run: kubeseal --format yaml --cert tools/sealed-secrets-cert.pem < <평문 Secret> > \"$f\"" >&2
    rc=1
  fi
done

# 키 총수 도메인 — 파일 수 축이 원리적으로 못 보는 붕괴("파일은 다 있는데 내용이 비었다")를 문다.
# 판정 결과(rc)와 무관하게 방출한다: rc=1은 "위반을 찾았다"이지 "평가하지 못했다"가 아니다.
if [ "$SCOPE_NARROWED" -eq 1 ] && ! floor_set sealed-guard:keys; then
  scan_signal sealed-guard:keys "$keys_total"
else
  scan_floor sealed-guard:keys "$keys_total" "$(floor_of sealed-guard:keys "$KEY_FLOOR")" || rc=1
fi
exit $rc
