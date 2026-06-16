#!/usr/bin/env bash
# 단일 테스트 수집·실행기 (required GATE). Makefile ci 와 ci.yaml gate 가 공통 호출 → 이중 SSOT 제거.
# **모델: gate = 모든 CI-safe test_*.bats** (정적 infra 가드 포함 — required 게이트라야 실제로 보호된다).
# 스코프 = git-tracked test_*.bats − platform/charts/*(chart-test 별도 harness) − tests/.ci-exclude.
#   - platform/charts/* 만 prune(차트 fixtures 필요한 별도 harness, make chart-test).
#   - **infra/는 prune하지 않는다** — k3s-bootstrap(hermetic, bats+yq)은 CI-safe라 gate에서 보호.
#     단 terraform 의존 infra 테스트(cloudflare test_apps_data·tf_validate·tf_reconcile)는 .ci-exclude(아래).
#   - .ci-exclude = not-CI-safe 단일 레지스트리(라이브/도커/age/terraform): posture·dev-postgres·sops·cnpg KSOPS·
#     tf_validate/tf_reconcile/cloudflare-apps-data(terraform 의존, iac.yaml advisory)·bootstrap(live). 사유+실행처 주석.
# **bash 3.2(macOS 기본) 호환 필수** — mapfile(bash4+)·set -u 빈배열 확장 금지. (AGENTS.md bash3.2 함정)
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 제외 목록을 공백 구분 문자열로 (배열/ mapfile 미사용 — bash 3.2 안전)
EXCL=" "
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  EXCL="$EXCL$line "
done < tests/.ci-exclude
is_excluded() { case "$EXCL" in *" $1 "*) return 0;; *) return 1;; esac; }

SELECTED=()
while IFS= read -r f; do
  case "$f" in
    platform/charts/*) continue;;   # chart-test 별도 harness (infra/는 prune 안 함 — CI-safe면 gate)
  esac
  is_excluded "$f" || SELECTED+=("$f")
done < <(git ls-files '*test_*.bats' | sort)

if [ "${1:-}" = "--list" ]; then printf '%s\n' "${SELECTED[@]}"; exit 0; fi
[ "${#SELECTED[@]}" -gt 0 ] && bats "${SELECTED[@]}"
