#!/usr/bin/env bats
# digest-exporter **producer 행위** 게이트 — 정적 grep이 아니라 ConfigMap의 run.sh를 **실제로 실행**한다.
#
# 왜 실행 seam인가: 합성 replay는 룰만 증명하고 producer를 증명하지 않는다. 하트비트를 빈-digest 검사
# **안쪽**에 두거나 skopeo 실패 시 조기 종료하게 만들면, 문법 검사(sh -n)·레지스트리 완전성·발화 e2e·
# 라이브 전건성공 확인을 **전부 통과하면서** US1이 조용히 깨진다("push 경로 생존" 하트비트가 GHCR 장애에
# 동반 소실 → DigestExporterStale이 GHCR 장애를 push 사망으로 오귀속). 스크립트를 실행하는 것만이
# 하트비트 의미론("push 경로 생존" ≠ "수집 성공")을 증명한다.
#
# 하네스: PATH stub으로 skopeo/curl을 가로챈다.
#   - skopeo stub  = **argv 순서를 단언**한다(글로벌 `--command-timeout`이 서브커맨드 `inspect` **앞**).
#     그 배치가 tests/gates/skopeo-timeout-smoke.sh가 핀된 실물 이미지에서 **실제로 증명한** 배치다
#     (실측상 뒤 배치도 동작하지만 그건 cobra 플래그 상속이라는 구현 세부다 — 증명된 배치를 고정한다).
#     ⚠️ 진짜 타임아웃 **강제**는 stub으로 증명 불가하다(stub이 skopeo를 대체하므로 stub 자신을 테스트할
#     뿐) — 그건 위 스모크의 몫이고, 여기 stub은 **루프 의미론**(스킵·하트비트 발행)만 본다.
#   - curl stub    = push 페이로드(stdin)와 argv를 캡처한다.
# (@test 이름 영어 — 한글이면 디렉토리 단위 실행 시 인코딩 깨짐. 중간 단언은 run + [ ] — bash 3.2 함정)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  D="$ROOT/platform/victoria-stack/prod/digest-exporter.yaml"
  STUB="$BATS_TEST_TMPDIR/stub"
  OUTDIR="$BATS_TEST_TMPDIR/out"
  mkdir -p "$STUB" "$OUTDIR"

  # ── ConfigMap에서 run.sh 바이트 추출(픽스처 복제 금지 — 드리프트 0) ──
  yq 'select(.kind=="ConfigMap") | .data["run.sh"]' "$D" > "$BATS_TEST_TMPDIR/run.sh"
  [ -s "$BATS_TEST_TMPDIR/run.sh" ]

  # ── skopeo stub: argv 순서 단언 + 성공/실패 시뮬레이션 ──
  # STUB_FAIL_APPS(공백 구분 앱 이름)에 속한 앱은 skopeo가 실패한 것처럼 exit 1.
  cat > "$STUB/skopeo" <<'SKOPEO'
#!/bin/sh
echo "$*" >> "$OUTDIR/skopeo.argv"
# ★ argv 순서 계약: 글로벌 옵션 --command-timeout=<t> 는 서브커맨드 inspect **앞**에 와야 한다.
case "$1" in
  --command-timeout=*) : ;;
  *) echo "ARGV ORDER VIOLATION: argv[1]='$1' (expected --command-timeout=<t> before the subcommand)" >> "$OUTDIR/skopeo.err"; exit 3 ;;
esac
[ -n "${1#--command-timeout=}" ] || { echo "EMPTY TIMEOUT VALUE" >> "$OUTDIR/skopeo.err"; exit 3; }
[ "$2" = "inspect" ] || { echo "ARGV ORDER VIOLATION: argv[2]='$2' (expected 'inspect')" >> "$OUTDIR/skopeo.err"; exit 3; }
# 마지막 인자 = docker://<ref> → 앱 이름 추출(ref 안의 이미지명 = 앱 이름 규약)
for a in "$@"; do last="$a"; done
ref="${last#docker://}"
name="${ref##*/}"; name="${name%%:*}"
for f in ${STUB_FAIL_APPS:-}; do
  if [ "$f" = "$name" ]; then echo "stub: skopeo failed for $name" >&2; exit 1; fi
done
printf '{"Digest": "sha256:%040dabc", "Name": "%s"}\n' 1 "$ref"
SKOPEO

  # ── curl stub: push 페이로드(stdin) + argv 캡처 ──
  cat > "$STUB/curl" <<'CURL'
#!/bin/sh
echo "$*" >> "$OUTDIR/curl.argv"
cat > "$OUTDIR/payload.txt"
CURL
  chmod +x "$STUB/skopeo" "$STUB/curl"
}

# run.sh를 stub PATH로 실행한다. $1=APPS, 나머지는 env로 넘어온다.
run_producer() {
  OUTDIR="$OUTDIR" STUB_FAIL_APPS="${STUB_FAIL_APPS:-}" APPS="$1" \
    SKOPEO_TIMEOUT="${SKOPEO_TIMEOUT:-3s}" CURL_MAX_TIME="${CURL_MAX_TIME:-7}" \
    PATH="$STUB:$PATH" sh "$BATS_TEST_TMPDIR/run.sh"
}

# 페이로드에서 **bare 게이지**(라벨 0)의 값을 뽑는다 — 부재/라벨 부착이면 빈 문자열이라 단언이 RED가 된다.
# (grep -c는 0매치에서 exit 1이라 bats의 set -e에 걸린다 → sed로 값 자체를 뽑아 비교한다.)
gauge() { sed -n "s/^$1 \([0-9][0-9]*\)\$/\1/p" "$OUTDIR/payload.txt"; }

@test "producer passes skopeo the global --command-timeout BEFORE the inspect subcommand" {
  run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa"
  [ "$status" -eq 0 ]
  [ ! -f "$OUTDIR/skopeo.err" ] || { echo "argv order violations:"; cat "$OUTDIR/skopeo.err"; false; }
  run grep -q -- '--command-timeout=3s inspect' "$OUTDIR/skopeo.argv"
  [ "$status" -eq 0 ]
}

@test "producer emits the bare heartbeat series when every app scrapes successfully" {
  run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  # 하트비트 = 라벨 0(bare) + epoch 초 값. 라벨이 붙으면 absent/or 브랜치의 라벨셋이 갈려 for: pending이 리셋된다.
  run grep -qE '^digest_exporter_last_success_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
  # 전건 성공 → 앱마다 digest 라인
  [ "$(grep -c '^ghcr_latest_digest{' "$OUTDIR/payload.txt")" -eq 2 ]
}

# ── 수집 카운트(US2) — 하트비트와 **직교하는 축**이다 ────────────────────────────────────────────────
# 하트비트는 "push 경로 생존"만 증명한다. push는 살아 있는데 앱 일부/전부의 skopeo 조회가 실패하는
# **부분 고장**은 `[ -z "$DIGEST" ] && continue`로 조용히 스킵될 뿐이라 여전히 무성이다.
# → configured(루프 반복 수) vs scraped(digest 획득 성공 수)를 함께 push하고 DigestExporterScrapeIncomplete가
#   그 격차를 페이징한다. 카운터 증가 **위치**가 의미론 전부다: scraped를 빈-digest 검사 **앞**에 두면
#   scraped == configured로 오보고되어 문법·레지스트리·replay·라이브 전건성공 확인을 전부 통과하면서
#   US2가 조용히 깨진다. 아래 4입력이 그 위치를 못박는다(값을 **정확히** 단언 — 존재만 보지 않는다).
# ⚠️ 두 게이지 모두 **bare**(라벨 0)여야 한다 — 룰이 on()/ignoring() 없이 1:1 스칼라 비교를 하므로
#    한쪽에만 라벨이 붙으면 매치가 통째로 사라져(빈 벡터) 알림이 조용히 죽는다.

@test "producer counts every configured app as scraped when all skopeo lookups succeed" {
  run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  [ "$(gauge digest_exporter_apps_configured)" = "2" ]
  [ "$(gauge digest_exporter_apps_scraped)" = "2" ]
}

@test "producer counts only the successful scrapes when some skopeo lookups fail" {
  STUB_FAIL_APPS="trip-mate-api" run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  # ★ 이 레그가 카운터 위치를 못박는다 — scraped 증가가 빈-digest 검사 앞에 있으면 여기서 2가 나온다.
  [ "$(gauge digest_exporter_apps_configured)" = "2" ]
  [ "$(gauge digest_exporter_apps_scraped)" = "1" ]
}

@test "producer reports zero scraped apps while still emitting the heartbeat when every scrape fails" {
  STUB_FAIL_APPS="page trip-mate-api" run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  [ "$(gauge digest_exporter_apps_configured)" = "2" ]
  [ "$(gauge digest_exporter_apps_scraped)" = "0" ]
  # GHCR 전면 장애에도 push 경로는 살아 있다 → 하트비트는 나가고(Stale 오귀속 방지) 카운트가 고장을 말한다.
  run grep -qE '^digest_exporter_last_success_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

@test "producer reports zero configured and zero scraped apps when APPS is empty" {
  # zero-app(마지막 앱 teardown) = **의도된 침묵**(owner 결정 ④): 0 < 0이 거짓이라 알림이 안 운다.
  # 그 침묵이 성립하려면 두 게이지가 실제로 0으로 **발행**돼야 한다(미발행이면 빈 벡터라 우연히 조용할 뿐).
  run run_producer ""
  [ "$status" -eq 0 ]
  [ "$(gauge digest_exporter_apps_configured)" = "0" ]
  [ "$(gauge digest_exporter_apps_scraped)" = "0" ]
}

@test "producer still emits the heartbeat when every skopeo scrape fails (push-path liveness, not scrape success)" {
  # ★ 이 레그가 하트비트 의미론의 핵심이다 — GHCR 전면 장애(자격 만료·레지스트리 다운)에도 push 경로는
  #   살아 있으므로 하트비트는 나가야 한다. 나가지 않으면 DigestExporterStale이 GHCR 장애를 "push 사망"으로
  #   오귀속한다(수집 실패는 별개 알림의 소관 — 역할 분리).
  STUB_FAIL_APPS="page trip-mate-api" run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  run grep -qE '^digest_exporter_last_success_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
  # digest 라인은 하나도 없어야 한다(빈 DIGEST → continue)
  run grep -q '^ghcr_latest_digest{' "$OUTDIR/payload.txt"
  [ "$status" -ne 0 ]
}

@test "producer emits the heartbeat alongside partial scrape results" {
  STUB_FAIL_APPS="trip-mate-api" run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa trip-mate-api=ghcr.io/ukyi-app/trip-mate-api:sha-bbb"
  [ "$status" -eq 0 ]
  run grep -qE '^digest_exporter_last_success_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ghcr_latest_digest{' "$OUTDIR/payload.txt")" -eq 1 ]
  run grep -q '^ghcr_latest_digest{app="page"' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

@test "producer emits the heartbeat with zero apps configured (APPS empty)" {
  run run_producer ""
  [ "$status" -eq 0 ]
  run grep -qE '^digest_exporter_last_success_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

@test "producer bounds the push with curl --max-time (env-overridable)" {
  run run_producer "page=ghcr.io/ukyi-app/page:sha-aaa"
  [ "$status" -eq 0 ]
  run grep -q -- '--max-time 7' "$OUTDIR/curl.argv"
  [ "$status" -eq 0 ]
  run grep -q -- '--data-binary @-' "$OUTDIR/curl.argv"
  [ "$status" -eq 0 ]
}
