#!/usr/bin/env bash
# PreToolUse 가드 — Edit|Write|MultiEdit가 위험 경로를 건드리면 차단(exit 2)한다.
# 글로벌 rtk 훅은 matcher가 Bash라 이 훅(Edit|Write|MultiEdit)과 레이어가 분리돼 공존한다.
# 고확신 경로 패턴만 차단한다(오탐 0 우선) — 콘텐츠 의존 함정(Application zero-value,
# NetworkPolicy pod-CIDR 등)은 CI/bats가 이미 잡으므로 여기서 다루지 않는다.
# DR 함정: sops 복호/재암호는 Bash 경로라 이 훅이 막지 않는다 — 재구축 복구 흐름은 무영향.
#
# ⚠️ **종료코드 의미가 다른 계층이다.** PreToolUse는 0=허용 · 2=차단(stderr가 Claude에 전달) ·
#    **그 외 비-0=비차단 에러**(사용자에게 stderr만 보이고 도구는 그대로 실행된다).
#    따라서 이 훅에서 fail-closed는 **exit 2뿐**이다. 다른 가드의 exit 1(검증 실패)이나
#    exit 4(skip 신호)를 여기 복사하면 경고만 찍히고 편집은 통과한다 = 여전히 fail-open.
# ⚠️ 그래서 `set -e`도 쓰지 않는다. 무엇이든 -e로 죽으면 rc=1(=비차단)이라 조용히 통과한다.
#    실측: jq 부재/실패 시 이 훅이 rc=0으로 *.enc.yaml 편집을 그대로 허용했다 — AGENTS.md 최상위
#    금칙(직접 편집 1회로 SOPS MAC 파괴 → DR 자산 복호 불능)의 **유일한 자동 차단선**인데도.
set -uo pipefail

# 외부 명령 의존 0. 옛 `input="$(cat)"`도 같은 클래스였다 — cat이 PATH에 없으면 rc=1(비차단)이다.
# `read -d ''`는 NUL까지 읽으므로 페이로드 전체를 한 번에 받고 EOF에서 rc=1을 낸다(정상 경로).
input=""
IFS= read -r -d '' input || true
[ -z "$input" ] && exit 0   # 페이로드 없음 = 이 훅의 도메인 밖(오탐 0)

# 1순위 jq, 실패하면 bash 내장 파싱으로 폴백한다. blanket `command -v jq || exit 2` 프리플라이트는
# 채택하지 않는다 — jq 없는 환경에서 모든 편집을 막아 세션을 못 쓰게 만든다(훅 자기 주석의 오탐 0 원칙).
fp=""
if command -v jq >/dev/null 2>&1; then
  fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" || fp=""
fi
if [ -z "$fp" ]; then
  # bash 3.2 안전 관용구 — 정규식은 변수에 담고 따옴표 없이 매치한다.
  re='"file_path"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ "$input" =~ $re ]]; then fp="${BASH_REMATCH[1]}"; fi
fi

# 열거 바닥값 — 페이로드에 file_path 키가 **있는데** 값을 못 뽑았으면 파서가 죽은 것이다.
# matcher가 Edit|Write|MultiEdit 전용이라 이 세 도구는 항상 file_path를 갖는다 → fp 공백은
# 실제로는 언제나 파서 붕괴다. 옛 코드는 그걸 `[ -z "$fp" ] && exit 0`으로 "허용"이라 읽었다.
if [ -z "$fp" ]; then
  case "$input" in
    *'"file_path"'*)
      echo "차단: 훅이 tool_input.file_path를 파싱하지 못했다(jq 부재/실패 또는 페이로드 형식 변경)." >&2
      echo "→ 파서가 죽은 채 통과시키면 *.enc.yaml 직접 편집 차단선이 조용히 사라진다. jq 설치 또는 페이로드 확인." >&2
      exit 2
      ;;
  esac
  exit 0   # file_path 키 자체가 없다 = 도메인 밖(Bash 등) — 허용
fi

case "$fp" in
  *.enc.yaml)
    echo "차단: '$fp' 는 SOPS 암호화 파일이다. 직접 편집은 평문 메타데이터까지 MAC에 묶여 복호 불능이 된다." >&2
    echo "→ 'sops $fp' (또는 make secret-edit FILE=$fp)로 복호화→편집→재암호화하라." >&2
    exit 2
    ;;
esac

case "$fp" in
  */prod/charts/*)
    echo "차단: '$fp' 는 kustomize --enable-helm 차트 풀 캐시(untracked 벤더)다. 수정은 렌더 시 덮어쓰인다." >&2
    echo "→ 값 변경은 상위 values.yaml / HelmChartInflationGenerator에서 하라." >&2
    exit 2
    ;;
esac

# AGENTS.md 「벤더 파일 수정 금지」 나머지 2종 — charts/ 캐시(위)와 같은 급의 고확신 경로 차단.
case "$fp" in
  */cnpg/barman-plugin/manifest.yaml)
    echo "차단: '$fp' 는 barman-plugin 벤더 매니페스트다(AGENTS.md 벤더 파일 수정 금지)." >&2
    echo "→ 값 변경은 같은 디렉토리의 kustomization.yaml patch에서 하라." >&2
    exit 2
    ;;
esac

case "$fp" in
  */traefik/prod/gateway-api-crds.yaml)
    echo "차단: '$fp' 는 gateway-api CRD 벤더 매니페스트다(AGENTS.md 벤더 파일 수정 금지)." >&2
    echo "→ CRD 갱신은 상류 릴리스 재다운로드로 하라." >&2
    exit 2
    ;;
esac

exit 0
