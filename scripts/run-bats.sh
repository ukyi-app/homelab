#!/usr/bin/env bash
# 단일 테스트 수집·실행기 (required GATE). Makefile ci 와 ci.yaml gate 가 공통 호출 → 이중 SSOT 제거.
# **모델: gate = 모든 CI-safe test_*.bats** (정적 infra 가드 포함 — required 게이트라야 실제로 보호된다).
# 스코프 = git-tracked test_*.bats − platform/charts/*(chart-test 별도 harness) − tests/.ci-exclude.
#   - platform/charts/* 만 prune(차트 fixtures 필요한 별도 harness, make chart-test).
#   - **infra/는 prune하지 않는다** — k3s-bootstrap(hermetic, bats+yq)은 CI-safe라 gate에서 보호.
#     단 terraform 의존 infra 테스트(cloudflare test_apps_data·tf_validate)는 .ci-exclude(아래).
#     test_tf_reconcile은 terraform 비의존(워크플로 grep뿐)이라 gate가 수집한다.
#   - .ci-exclude = not-CI-safe 단일 레지스트리(라이브/도커/age/terraform): posture·dev-postgres·sops·cnpg KSOPS·
#     tf_validate/cloudflare-apps-data(terraform 의존, iac.yaml advisory)·bootstrap(live). 사유+실행처 주석.
# **bash 3.2(macOS 기본) 호환 필수** — mapfile(bash4+)·set -u 빈배열 확장 금지. (AGENTS.md bash3.2 함정)
set -e
# 콜레이션 고정 — 이 파일은 이미 "`make ci`와 `ci.yaml gate`의 단일 SSOT"인데 **로케일만 SSOT 밖**이라
# 두 venue가 서로 다른 술어를 평가했다(실측 2026-08-20: sync-wave 원장 가드가 오너의 en_US에서
# fail-open, 러너에서만 red). 게이트에 로케일 콜레이션이 필요한 정렬은 하나도 없다.
# C.UTF-8 = 바이트 콜레이션 + UTF-8 ctype(한국어 진단 출력 보존). 없는 libc(BSD)에서는 C로 폴백.
# ⚠️ **이 고정은 `scripts/check-locale-collation.sh`의 대체가 아니다** — 고정하면 개별 결함의
#    뮤테이션 감도가 죽는다(실측: `Makefile`의 `LC_ALL=C sort`를 되돌려도 C.UTF-8에서는 초록).
#    고정은 두 venue를 맞추고, "다음 파일에서 또 난다"는 그 정적 스캐너가 막는다.
if locale -a 2>/dev/null | grep -qiE '^C\.(UTF-8|utf8)$'; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── fd 0 격리 ───────────────────────────────────────────────────────────────────
# bats는 stdin을 전혀 만지지 않는다(1.14.0 libexec 전체에 `0<`/`</dev/null` 0건 — 실측). 그래서 @test 안의
# 스텁이 피연산자 없이 `cat`을 부르면 **bats를 부른 셸의 stdin**에서 EOF를 기다리며 영구 블록한다.
# 실패도 출력도 없이 멈추므로 red가 아니라 hang이다(실측 2026-08-20: never-EOF stdin을 물린
# `bats -f rehearse tests/test_sealed-secrets-restore.bats`가 `1..1`에서 정지, rc=124.
# 같은 명령에 `</dev/null`을 주면 1초에 `ok`. 이전 세션은 이 모양으로 1시간 39분을 태웠다).
# ⚠️ CI가 이걸 안 밟는 것은 이 러너의 성질이 아니다 — ci.yaml:245가 이 러너를 `&`로 띄우기 때문이다
#    (비대화형 bash의 async 명령은 fd 0이 /dev/null). `make ci`는 포그라운드라 호출자 fd 0을 그대로
#    물려받는다. 즉 venue가 갈리는 자리이므로 **러너가 스스로 끊는다**.
# 아래 수집 루프는 각자 자기 리다이렉트(`< tests/.ci-exclude`, `< <(git ls-files …)`)를 쓰므로 무영향.
exec 0</dev/null

# ⚠️ **per-@test 타임아웃(`BATS_TEST_TIMEOUT`) 백스톱은 걸지 않는다.** 잔여 블로킹을 열거 없이
#    fail-loud시키는 유일한 기전이라 매력적이지만, 이 레포와 **양립 불가**다: 값이 설정돼 있으면
#    **실패하는 중첩 bats를 부르는 @test가 거짓 타임아웃**을 낸다(실측 2026-08-20 최소 재현 —
#    안쪽 bats가 통과하면 1초, 같은 구조에서 안쪽이 실패하면 타임아웃을 꽉 채우고 죽는다.
#    `tests/gates/test_guard-skip-signalling.bats`의 "reports failure (not skip)…"가 실제로 그랬다:
#    백스톱 없이는 0초 통과, `BATS_TEST_TIMEOUT=40`이면 40초 후 red. 진단은 `echo '}'`라는
#    도달 불가능한 자리를 가리킨다). 이 레포는 **fail-closed를 단언하는 게이트가 다수**라
#    그런 자리가 우연이 아니라 구조적으로 존재한다 ⇒ 보험이 통과하던 게이트를 깨뜨리는 순손실이다.
#    잔여 블로킹은 위 fd 0 격리와 스텁의 argv 규약(docs/traps-detail.md)이 실질적으로 덮는다.

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
done < <(git ls-files '*test_*.bats' | LC_ALL=C sort)

if [ "${1:-}" = "--list" ]; then printf '%s\n' "${SELECTED[@]}"; exit 0; fi
[ "${#SELECTED[@]}" -gt 0 ] && bats "${SELECTED[@]}"
