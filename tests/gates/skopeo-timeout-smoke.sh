#!/usr/bin/env bash
# skopeo **실물 타임아웃** 스모크 — digest-exporter가 의존하는 `--command-timeout`이 **핀된 skopeo 이미지에서
# 실제로 강제되는지**를 증명한다(docker).
#
# 왜 이 게이트가 필요한가: digest-exporter의 지연 상한(그리고 그 위에 선 DigestExporterStale의 `for: 15m`
# 부트스트랩 안전성)은 **"skopeo가 앱당 정확히 SKOPEO_TIMEOUT 안에 끊긴다"** 는 전제 위에 서 있다
# (인-데드라인 부등식: POD_START + N×SKOPEO_TIMEOUT + CURL_MAX_TIME + EXEC_SLACK < activeDeadlineSeconds).
# 그런데 그 전제는 **PATH stub으로 증명할 수 없다** — stub은 skopeo 바이너리를 **대체**하므로 stub 자신을
# 테스트할 뿐이다(tests/gates/test_digest-exporter-producer.bats는 루프 의미론·argv 순서만 본다).
# → 여기서 **핀된 실물 이미지**를 **제어된 블랙홀**에 대고 직접 태운다.
#
# 블랙홀 설계: 호스트에 **TCP sink**(tests/gates/tcp-blackhole-sink.py — accept만 하고 바이트를 하나도 보내지
# 않고 닫지도 않는 소켓 서버)를 띄우고, 컨테이너에서 host-gateway로 그리로 붙는다. TCP 3-way handshake는
# **성공**하고 그 다음 TLS ServerHello에서 **영원히 매달린다** → 네트워크 블랙홀(GHCR 장애·중간 방화벽 침묵
# 드롭)의 정확한 재현이다.
#   ⚠️ host-gateway 매핑은 이 레포의 검증된 패턴이다(tests/gates/alertmanager-render-e2e.sh — AM→호스트 mock).
#   (sink가 **독립 파일**인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
#    CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = tests/gates/mock-telegram.py.)
#
# 증명 3단(단순 "종료했다"로는 부족 — 다른 이유로 즉시 죽어도 통과한다):
#   S1 짧은 타임아웃(T_SHORT)  → T_SHORT 근처에서 종료(하한 단언 = 진짜로 기다렸다, 즉시 실패가 아니다)
#   S2 긴 타임아웃(T_LONG)     → T_LONG 근처에서 종료 **그리고 S1보다 확실히 오래 걸린다**
#      ↳ 경과가 플래그 **값을 따라간다**는 것이 "타임아웃이 실제로 지배한다"의 유일한 증거다.
#   S3 argv 배치 특성화(characterization): 같은 플래그를 `inspect` **뒤**에 둬도 상한이 **여전히 강제되는가**.
#      ⚠️ **계획의 전제를 실측이 뒤집었다**(2026-07-13, 이 게이트의 첫 실행): 계획(PRD r9/N-4)은 "글로벌
#         옵션을 서브커맨드 뒤에 두면 **무효**"라고 적었으나, 핀된 v1.22.2에서 **두 배치 모두 타임아웃을
#         강제한다**(실측: 뒤 배치도 3s→3s · 9s→10s로 플래그 값을 따라간다). `--command-timeout`은 cobra
#         **persistent flag**라 서브커맨드가 상속하기 때문이다.
#      → 그래도 run.sh는 **글로벌 배치(inspect 앞)를 유지**한다: (a) 그게 우리가 S1/S2로 **실제 증명한**
#         배치이고, (b) 뒤 배치의 수용은 cobra의 플래그 상속이라는 **구현 세부**에 기대는 것이라 CLI 재구성
#         한 번으로 사라질 수 있다. 정적 게이트가 순서를 못박는 이유는 "뒤에 두면 무효라서"가 아니라
#         **"우리가 증명한 배치에서 벗어나지 않기 위해서"** 다.
#      → S3가 실제로 막는 위험 상태는 하나다: 뒤 배치가 **에러 없이 수용되는데 상한은 안 걸리는** 경우
#         (= 스크레이프가 무제한이 되는데 아무도 모른다). 그 상태가 되면 이 레그가 FAIL한다.
#
# 이미지는 platform/victoria-stack/prod/digest-exporter.yaml의 **digest 핀에서 파생**한다(하드코딩 금지) —
# 이미지를 bump하면 이 게이트가 자동으로 새 이미지를 시험한다(구 이미지에 대한 낡은 증명 방지).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="$ROOT/platform/victoria-stack/prod/digest-exporter.yaml"
SINK="$ROOT/tests/gates/tcp-blackhole-sink.py"

fault() { echo "HARNESS FAULT: $*" >&2; exit 2; }

# 예산 상수·파생은 SSOT lib이 소유한다(세 게이트가 같은 부등식을 독립 판정한다 — 리터럴 복제 금지).
# shellcheck source=tests/gates/lib/digest-exporter-budget.sh
. "$ROOT/tests/gates/lib/digest-exporter-budget.sh"

# ── 1) 핀된 skopeo 이미지 + 계약 타임아웃을 매니페스트에서 파생 ──────────────────────────────────────
IMAGE="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].image' "$EXPORTER" | head -1)"
[ -n "$IMAGE" ] || fault "digest-exporter.yaml에서 skopeo 이미지를 파생하지 못했다"
case "$IMAGE" in *@sha256:*) : ;; *) fault "skopeo 이미지가 digest 핀이 아니다: $IMAGE" ;; esac

# fail-closed: 파생 실패는 여기서 죽는다(빈 값을 그대로 쓰면 스모크가 아무것도 증명하지 못한다).
deb_load "$EXPORTER" || fault "digest-exporter 예산 파생 실패(위 stderr 참조) — 계약 타임아웃 값을 모른 채로는 스모크가 무의미하다."
SKOPEO_T="$DEB_SKOPEO_TIMEOUT_S"

# 게이트 wall-clock을 아끼려고 **작은 값**으로 시험한다 — 증명 대상은 "플래그 값이 경과를 지배한다"는
# 메커니즘이지 특정 상수가 아니다(프로덕션 값 ${SKOPEO_T}s도 같은 코드 경로를 탄다).
T_SHORT=3
T_LONG=9
SLACK=8   # 컨테이너 기동 + TLS 셋업 오버헤드 여유(이미지는 미리 pull해 타이밍에서 제외한다)
PORT=18443

TMP="$(mktemp -d)"
SINK_PID=""
cleanup() {
  if [ -n "$SINK_PID" ]; then
    kill "$SINK_PID" 2>/dev/null || true
    wait "$SINK_PID" 2>/dev/null || true   # 셸의 "Terminated" 잡 알림을 흡수(로그 노이즈 제거)
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── 2) 블랙홀: accept 후 **아무것도 보내지 않는** TCP sink(호스트) ──────────────────────────────────
[ -f "$SINK" ] || fault "TCP sink 스크립트가 없다: $SINK"
python3 "$SINK" "$PORT" 2>"$TMP/sink.log" &
SINK_PID=$!
for _ in $(seq 40); do
  grep -q 'listening' "$TMP/sink.log" 2>/dev/null && break
  sleep 0.25
done
grep -q 'listening' "$TMP/sink.log" || fault "TCP sink가 기동하지 못했다: $(cat "$TMP/sink.log")"

# 이미지 pull을 타이밍에서 제외(pull 시간이 경과에 섞이면 하한/상한 단언이 무의미해진다).
docker pull -q "$IMAGE" >/dev/null 2>&1 || fault "skopeo 이미지 pull 실패: $IMAGE"

# $1=타임아웃(초) $2=placement(global|after-subcommand) → 경과 초를 stdout으로
run_skopeo() {
  local t="$1" placement="$2" start end
  start="$(date +%s)"
  if [ "$placement" = "global" ]; then
    docker run --rm --add-host=host.docker.internal:host-gateway "$IMAGE" \
      --command-timeout="${t}s" inspect --no-tags --tls-verify=false \
      "docker://host.docker.internal:${PORT}/blackhole/img:latest" >/dev/null 2>"$TMP/err.$t.$placement" || true
  else
    # 음성 대조: 글로벌 옵션을 서브커맨드 **뒤**에 둔다(run.sh가 절대 하면 안 되는 배치)
    docker run --rm --add-host=host.docker.internal:host-gateway "$IMAGE" \
      inspect --command-timeout="${t}s" --no-tags --tls-verify=false \
      "docker://host.docker.internal:${PORT}/blackhole/img:latest" >/dev/null 2>"$TMP/err.$t.$placement" || true
  fi
  end="$(date +%s)"
  echo $(( end - start ))
}

FAILED=0
fail() { echo "FAIL $*" >&2; FAILED=$(( FAILED + 1 )); }
pass() { echo "PASS $*"; }

echo "[params] image=$IMAGE  (run.sh 계약값 SKOPEO_TIMEOUT=${SKOPEO_T}s — 여기선 ${T_SHORT}s/${T_LONG}s로 메커니즘을 시험)"
echo "[blackhole] host TCP sink :$PORT — accept 후 무응답(TLS ServerHello에서 영구 대기) → 진짜 네트워크 블랙홀"

# ── S1: 짧은 타임아웃 → 그 근처에서 끊긴다(하한 = 진짜로 기다렸다) ─────────────────────────────────
E_SHORT="$(run_skopeo "$T_SHORT" global)"
echo "  [S1] --command-timeout=${T_SHORT}s (global, before 'inspect') → 경과 ${E_SHORT}s (허용 ${T_SHORT}..$(( T_SHORT + SLACK ))s)"
if [ "$E_SHORT" -ge "$T_SHORT" ] && [ "$E_SHORT" -le $(( T_SHORT + SLACK )) ]; then
  pass "S1 pinned skopeo honored --command-timeout=${T_SHORT}s against a hanging TLS blackhole (took ${E_SHORT}s)"
elif [ "$E_SHORT" -lt "$T_SHORT" ]; then
  fail "S1 skopeo returned in ${E_SHORT}s — FASTER than the ${T_SHORT}s timeout it was given. It did not actually wait on the blackhole, so this run proves nothing about --command-timeout (the sink may be refusing/resetting connections instead of hanging). Check the TCP sink: $(head -3 "$TMP/err.${T_SHORT}.global" 2>/dev/null | tr '\n' ' ')"
else
  fail "S1 skopeo took ${E_SHORT}s despite --command-timeout=${T_SHORT}s (allowed up to $(( T_SHORT + SLACK ))s) — the pinned image does NOT enforce the timeout. digest-exporter's whole delay bound collapses: a hung GHCR scrape would run until activeDeadlineSeconds kills the Job BEFORE it can push, so the heartbeat never goes out and a GHCR outage gets mis-attributed to a dead push path (DigestExporterStale instead of a scrape failure). stderr: $(head -3 "$TMP/err.${T_SHORT}.global" 2>/dev/null | tr '\n' ' ')"
fi

# ── S2: 긴 타임아웃 → 경과가 **플래그 값을 따라간다**(메커니즘의 유일한 증거) ─────────────────────
E_LONG="$(run_skopeo "$T_LONG" global)"
echo "  [S2] --command-timeout=${T_LONG}s (global) → 경과 ${E_LONG}s (허용 ${T_LONG}..$(( T_LONG + SLACK ))s, 그리고 > S1)"
if [ "$E_LONG" -ge "$T_LONG" ] && [ "$E_LONG" -le $(( T_LONG + SLACK )) ] && [ "$E_LONG" -gt "$E_SHORT" ]; then
  pass "S2 elapsed tracks the flag value (${T_SHORT}s → ${E_SHORT}s, ${T_LONG}s → ${E_LONG}s) — the timeout, not some unrelated fast failure, governs when skopeo gives up"
else
  fail "S2 elapsed did NOT track the flag value (${T_SHORT}s → ${E_SHORT}s, ${T_LONG}s → ${E_LONG}s; expected the ${T_LONG}s run to land in ${T_LONG}..$(( T_LONG + SLACK ))s AND exceed the ${T_SHORT}s run). Whatever ended these runs, it was not --command-timeout — the per-app scrape bound is unenforced and the in-deadline budget in digest-exporter.yaml is fiction. stderr: $(head -3 "$TMP/err.${T_LONG}.global" 2>/dev/null | tr '\n' ' ')"
fi

# ── S3(특성화): 서브커맨드 **뒤** 배치가 상한을 무제한으로 만들지는 않는가 ────────────────────────
# ⚠️ 실측이 계획을 뒤집은 지점이다(헤더 참조). 핀된 v1.22.2는 뒤 배치도 **정상 수용하고 상한도 강제한다**
#   (cobra persistent flag 상속). 따라서 이 레그의 판정은 "거부되는가"가 **아니라**
#   **"무제한이 되지 않는가"** 다 — 위험한 상태는 오직 하나, **에러 없이 수용됐는데 안 끊기는** 경우다.
#   (run.sh는 그와 무관하게 S1/S2로 증명된 글로벌 배치를 유지한다 — 정적 게이트가 그 배치를 못박는다.)
E_AFTER="$(run_skopeo "$T_SHORT" after-subcommand)"
ERR_AFTER="$(head -3 "$TMP/err.${T_SHORT}.after-subcommand" 2>/dev/null | tr '\n' ' ')"
echo "  [S3] inspect --command-timeout=${T_SHORT}s (뒤 배치) → 경과 ${E_AFTER}s · stderr: ${ERR_AFTER:-<none>}"
if [ "$E_AFTER" -le $(( T_SHORT + SLACK )) ]; then
  # 끊긴다(수용+강제) 또는 즉시 거부된다(unknown flag) — 둘 다 "무제한"이 아니므로 안전하다.
  pass "S3 the after-subcommand placement does not leave the scrape unbounded (exited in ${E_AFTER}s ≤ ${T_SHORT}s + ${SLACK}s slack). Measured on this pinned build: the flag IS honored there too (cobra persistent-flag inheritance), contrary to the plan's premise — recorded in the header. run.sh nonetheless keeps the global placement, which is the one S1/S2 actually prove."
else
  fail "S3 the after-subcommand placement is ACCEPTED but the timeout is NOT enforced (elapsed ${E_AFTER}s > ${T_SHORT}s + ${SLACK}s slack) — a mis-ordered flag now silently leaves the GHCR scrape UNBOUNDED. This is the dangerous state: a hung scrape would burn the whole activeDeadlineSeconds and the Job would die BEFORE pushing, so no heartbeat goes out and a GHCR outage gets mis-attributed to a dead push path. The argv-order contract in run.sh (--command-timeout BEFORE 'inspect') is now load-bearing for correctness, not just for hygiene — do NOT relax the static gate in tests/gates/test_digest-exporter.bats. stderr: ${ERR_AFTER:-<none>}"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "skopeo-timeout-smoke: ${FAILED} check(s) FAILED" >&2
  exit 1
fi
echo "skopeo-timeout-smoke OK (핀된 ${IMAGE} 가 --command-timeout을 실제로 강제한다 — 블랙홀에 대고 경과가 플래그 값을 따라가고(S1/S2), 어떤 argv 배치도 스크레이프를 무제한으로 두지 않는다(S3))"
