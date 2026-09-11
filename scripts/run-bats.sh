#!/usr/bin/env bash
# 단일 테스트 수집·실행기 (required GATE). justfile ci 와 ci.yaml gate 가 공통 호출 → 이중 SSOT 제거.
# **모델: gate = 모든 CI-safe test_*.bats** (정적 infra 가드 포함 — required 게이트라야 실제로 보호된다).
# 스코프 = git-tracked test_*.bats − platform/charts/*(chart-test 별도 harness) − tests/.ci-exclude.
# 실행 = 병렬 레인(파일 단위 --jobs) 뒤 직렬 레인(tests/.gate-serial) — 아래 「레인 분할」. `--plan`이 그 분할을 보여 준다.
#   - platform/charts/* 만 prune(차트 fixtures 필요한 별도 harness, just chart-test).
#   - **infra/는 prune하지 않는다** — k3s-bootstrap(hermetic, bats+yq)은 CI-safe라 gate에서 보호.
#     단 terraform 의존 infra 테스트(cloudflare test_apps_data·tf_validate)는 .ci-exclude(아래).
#     test_tf_reconcile은 terraform 비의존(워크플로 grep뿐)이라 gate가 수집한다.
#   - .ci-exclude = not-CI-safe 단일 레지스트리(라이브/도커/age/terraform): posture·dev-postgres·sops·cnpg KSOPS·
#     tf_validate/cloudflare-apps-data(terraform 의존, iac.yaml advisory)·bootstrap(live). 사유+실행처 주석.
# **bash 3.2(macOS 기본) 호환 필수** — mapfile(bash4+)·set -u 빈배열 확장 금지. (AGENTS.md bash3.2 함정)
set -e
# 콜레이션 고정 — 이 파일은 이미 "`just ci`와 `ci.yaml gate`의 단일 SSOT"인데 **로케일만 SSOT 밖**이라
# 두 venue가 서로 다른 술어를 평가했다(실측 2026-08-20: sync-wave 원장 가드가 오너의 en_US에서
# fail-open, 러너에서만 red). 게이트에 로케일 콜레이션이 필요한 정렬은 하나도 없다.
# C.UTF-8 = 바이트 콜레이션 + UTF-8 ctype(한국어 진단 출력 보존). 없는 libc(BSD)에서는 C로 폴백.
# ⚠️ **이 고정은 `scripts/check-locale-collation.sh`의 대체가 아니다** — 고정하면 개별 결함의
#    뮤테이션 감도가 죽는다(실측: `justfile`의 `LC_ALL=C sort`를 되돌려도 C.UTF-8에서는 초록).
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
#    (비대화형 bash의 async 명령은 fd 0이 /dev/null). `just ci`는 포그라운드라 호출자 fd 0을 그대로
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

# ── 레인 분할: 병렬 레인(파일 단위 --jobs) + 직렬 레인(tests/.gate-serial) ──────────────────────────
# 수집 집합은 위 SELECTED 하나다(도메인 회계·`--list`는 불변). 레인은 **실행 순서**만 가른다.
#   병렬 레인 — 나머지 전부를 `bats --jobs N --no-parallelize-within-files`로 돈다. .bats 파일마다 별도
#     프로세스이고 파일 안은 원래대로 직렬이다. 실측(2026-09-09, 14코어 NUC): 직렬 486s → 90s. gate
#     러너(4 vCPU)에서는 직렬 bats 574s가 게이트 12분의 8할이었다.
#   직렬 레인 — `tests/.gate-serial` 등재 파일을 병렬 레인이 **끝난 뒤 혼자** 돈다. 등재 기준은 하나:
#     그 스위트가 실 체크아웃(추적 파일·untracked 생성·.git/index)을 잠깐 바꾼다. 병렬로 돌리면 그
#     창을 밟은 다른 프로세스의 가드(check-skeleton·check-doc-index·`just ci-guard-tracked`…)가 거짓
#     red를 낸다(실측: 14 jobs 8회 중 8회 재현). 레지스트리 계약은 check-bats-accounting.sh (2b)가 강제한다.
# ⚠️ 등재 항목이 수집 집합 밖이면 여기서 죽는다(exit 2) — 오타·이동·.ci-exclude 중복 등재로 직렬 레인이
#    조용히 비는 것을 막는다. `--list`보다 앞에 두어 회계 가드의 `--list` 호출도 같은 검사를 지난다.
SERIAL=" "
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  SERIAL="$SERIAL$line "
done < tests/.gate-serial
is_serial() { case "$SERIAL" in *" $1 "*) return 0;; *) return 1;; esac; }
PAR=(); SER=()
for f in "${SELECTED[@]}"; do
  if is_serial "$f"; then SER+=("$f"); else PAR+=("$f"); fi
done
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  found=1
  for f in "${SER[@]}"; do if [ "$f" = "$line" ]; then found=0; break; fi; done
  if [ "$found" -ne 0 ]; then
    echo "run-bats: tests/.gate-serial 항목이 수집 집합에 없다(경로 오타·이동·.ci-exclude 등재?): $line" >&2
    exit 2
  fi
done < tests/.gate-serial

if [ "${1:-}" = "--list" ]; then printf '%s\n' "${SELECTED[@]}"; exit 0; fi

# ── 병렬도 ──────────────────────────────────────────────────────────────────────
# RUNBATS_JOBS=<n>으로 고정한다(1이면 전부 직렬 — 예전 형태 그대로). 기본은 논리 코어 수.
# 이 env는 속도 손잡이지 off-switch가 아니다 — 어떤 값이어도 수집 집합과 판정은 같다.
if [ -n "${RUNBATS_JOBS:-}" ]; then JOBS="$RUNBATS_JOBS"
else JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"; fi
case "$JOBS" in ''|*[!0-9]*|0) echo "run-bats: RUNBATS_JOBS는 1 이상의 정수여야 한다: '${JOBS}'" >&2; exit 2;; esac
if [ "$JOBS" -gt 1 ]; then
  # bats --jobs는 GNU parallel을 요구한다(moreutils의 parallel은 다른 프로그램 — --version 첫 줄로 가른다).
  pver="$(parallel --version 2>/dev/null || true)"
  case "$pver" in
    "GNU parallel"*) : ;;
    *)
      # ⚠️ CI에서는 직렬로 폴백하지 않는다 — 게이트 시간이 조용히 6배가 되고 아무도 로그를 안 읽는다.
      #    gate 러너 이미지(ubuntu-24.04-arm)는 GNU parallel을 apt 패키지로 갖고 있다(2026-09-09 실측 20231122).
      if [ -n "${CI:-}" ]; then echo "run-bats: GNU parallel 부재 — CI 러너 이미지 회귀. 직렬 폴백 금지." >&2; exit 2; fi
      echo "run-bats: GNU parallel 없음 → 직렬 실행(느림). 설치: brew install parallel / apt install parallel" >&2
      JOBS=1 ;;
  esac
  # 인용(citation) 안내를 끈다 — bats가 붙이는 플래그에 없고, $PARALLEL은 GNU parallel의 기본 옵션 env다.
  export PARALLEL="${PARALLEL:+$PARALLEL }--will-cite"
fi
if [ "${1:-}" = "--plan" ]; then
  printf 'jobs=%s\nparallel=%s\nserial=%s\n' "$JOBS" "${#PAR[@]}" "${#SER[@]}"
  for f in "${SER[@]}"; do printf 'serial-file=%s\n' "$f"; done
  exit 0
fi

# ── 프로세스 간 공유 자원 차단 ──────────────────────────────────────────────────
# GHA 스텝 출력 파일은 스텝당 하나를 그 스텝의 모든 프로세스가 공유한다. 테스트가 실 도구
# (check-workflow-readiness.ts 등)를 부르면 그 도구가 `$GITHUB_OUTPUT`에 heredoc 블록을 append하는데,
# 병렬 레인에서는 여러 프로세스가 같은 파일에 끼어 써 러너가 스텝 종료 시 파싱하다 죽을 수 있다.
# 테스트 산출물은 게이트 출력이 아니다 — 러너 안에서는 넷 다 끊는다.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_PATH
# bun 런타임 트랜스파일 캐시 위치를 실행 단위로 고정한다. 기본 위치는 $XDG_CACHE_HOME → $HOME 순으로
# 파생되는데, 테스트가 HOME을 갈아 끼우면 그때마다 콜드 캐시가 그 tmp에 생긴다. 한 곳에 모으면 CLI
# 스위트 전체가 따뜻한 캐시를 공유하고 위치가 환경 변수에 끌려다니지 않는다(bun은 이 env를 최우선으로 읽는다).
BUN_TCACHE="$(mktemp -d "${TMPDIR:-/tmp}/homelab-bun-tcache.XXXXXX")"
export BUN_RUNTIME_TRANSPILER_CACHE_PATH="$BUN_TCACHE"
trap 'rm -rf "$BUN_TCACHE"' EXIT

# ⚠️ `--print-output-on-failure` — 실패한 @test의 `$output`을 TAP에 그대로 싣는다. gate의 「무거운 스위트
#    동시 실행」 스텝에서만 재현되는 flake(test_02-host-preflight의 happy-path 레인 2회, 2026-09-01·09-02)가
#    "line 47: [ "$status" -eq 0 ] failed" 한 줄만 남기고 죽어 원인을 잡을 수 없었다 — 이 플래그가 없으면
#    재발해도 재실행 말고는 할 것이 없다. 통과한 @test에는 아무 영향이 없다(bats-core 1.5+).
run_lane() { # $1 = jobs, 나머지 = 파일들
  lane_jobs="$1"; shift
  if [ "$lane_jobs" -gt 1 ]; then
    bats --jobs "$lane_jobs" --no-parallelize-within-files --print-output-on-failure "$@"
  else
    bats --print-output-on-failure "$@"
  fi
}
# 두 레인은 실패해도 끝까지 돈다(한 레인의 red가 다른 레인의 진단을 삼키지 않게) — rc는 OR.
# 아래 세 줄의 `# run-bats:exec` 표식은 tests/gates/test_run-bats.bats가 프리앰블만 잘라 실행할 때의 이음새다.
rc=0
if [ "${#PAR[@]}" -gt 0 ]; then
  echo "# run-bats: 병렬 레인 ${#PAR[@]}파일 · jobs=${JOBS}"
  run_lane "$JOBS" "${PAR[@]}" || rc=$?   # run-bats:exec
fi
if [ "${#SER[@]}" -gt 0 ]; then
  echo "# run-bats: 직렬 레인 ${#SER[@]}파일 (tests/.gate-serial)"
  run_lane 1 "${SER[@]}" || rc=$?   # run-bats:exec
fi
exit "$rc"   # run-bats:exec
