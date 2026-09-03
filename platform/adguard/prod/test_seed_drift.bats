#!/usr/bin/env bats
# adguard **시드 대조 스텝**(ADR-0007 결정 2) — 정적 grep이 아니라 CronJob args를 **실제로 실행**한다.
#
# 왜 실행 seam인가: 이 스텝의 계약 전부가 실행 시점 분기다 — 관측 실패와 드리프트를 가르는 tri-state,
# rewrite 스텝과의 실패 격리, 밀리초↔기간문자열 단위 환산, `rewrites` 제외. 정적 grep은 그 어느 것도
# 증명하지 못한다(형제 test_rewrite_reconciler.bats가 정적 표면을 이미 덮는다 — 여기는 행위 축이다).
# 하네스는 tests/gates/test_digest-exporter-producer.bats의 관용구를 따른다: 매니페스트에서 스크립트
# 바이트를 뽑아(픽스처 복제 금지 — 드리프트 0) PATH 스텁으로 curl을 가로챈다.
#
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩). 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다
#    (cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③). 각 부재 단언 앞에 그 파일이
#    비어 있지 않다는 바닥값을 둔다(파일 자체가 없으면 rc 2라 -eq 1이 red가 된다).
# ⚠️ 스텁의 `cat`은 push URL 분기에서만 피연산자 없이 쓰인다 — 그 자리는 스크립트가 파이프로 부르므로
#    fd 0이 파이프다. 그래도 스크립트 실행부는 `< /dev/null`로 한 번 더 끊는다(bats fd 0 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  F="$ROOT/platform/adguard/prod/rewrite-reconciler.yaml"
  STUB="$BATS_TEST_TMPDIR/stub"
  OUTDIR="$BATS_TEST_TMPDIR/out"
  FIXDIR="$BATS_TEST_TMPDIR/fix"
  SADIR="$BATS_TEST_TMPDIR/sa"
  mkdir -p "$STUB" "$OUTDIR" "$FIXDIR" "$SADIR"
  printf 'stub-token' > "$SADIR/token"
  printf 'stub-ca' > "$SADIR/ca.crt"

  # ── CronJob args[0] 바이트 추출 ──
  yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].args[0]' "$F" \
    > "$BATS_TEST_TMPDIR/run.sh"
  [ -s "$BATS_TEST_TMPDIR/run.sh" ]

  write_fixtures
  write_stub
}

# ── 픽스처 ────────────────────────────────────────────────────────────────────────────────────
# 시드는 **합성**이다(레포 시드 복제가 아니다). 두 이유: ① 라이브 응답 픽스처를 레포 시드에서
# 파생시키면 양변이 같은 소스라 파서가 망가져도 대조가 같아지는 공허한 초록이 된다 ② 정당한 시드
# 편집(ADR-0007이 처방하는 바로 그 행위)이 CI를 red로 만들면 안 된다.
# 레포 실 시드의 **모양**은 아래 별도 @test가 따로 본다.
write_seed() {
  cat > "$FIXDIR/AdGuardHome.yaml" <<'SEED'
http:
  address: 0.0.0.0:3000
dns:
  bind_hosts: ["0.0.0.0"]
  port: 53
  upstream_dns:
    - https://dns.example.net/dns-query   # 꼬리 주석 — 파서가 걷어내야 한다
    - https://dns2.example.net/dns-query
  bootstrap_dns: ["1.1.1.1"]
  upstream_mode: load_balance
  # 사고 처방 두 값 — 이 둘은 드리프트의 처방이 반대다(라이브를 되돌린다).
  use_private_ptr_resolvers: false
  ratelimit: 100   # 꼬리 주석 — 파서가 걷어내야 한다
  ratelimit_whitelist:
    - 192.168.117.1
filtering:
  rewrites:
    - domain: "*.home.example.test"
      answer: "100.64.0.1"
  protection_enabled: true
querylog:
  enabled: true
  file_enabled: true
  interval: 14d
  size_memory: 1000
statistics:
  enabled: true
  interval: 1d
schema_version: 27
SEED
}

# 라이브 응답 픽스처 — 2026-09-03 라이브(v0.107.79) 실측 **모양**을 옮긴 것이다(값만 합성 시드에 맞춤).
# ⚠️ dns_info의 `upstream_mode`가 빈 문자열인 것이 실측이다(기본값 load_balance를 ""로 돌려준다) —
#    그래서 그 키는 대조 섹션이 아니다. 이 픽스처가 그 사실의 증인이다.
write_fixtures() {
  write_seed
  printf '%s' '{"status":{"loadBalancer":{"ingress":[{"ip":"100.67.173.106"}]}}}' > "$FIXDIR/svc.json"
  printf '%s' '[{"domain":"*.home.ukyi.app","answer":"100.67.173.106"}]' > "$FIXDIR/rewrite-list.json"
  printf '%s' '{"upstream_dns":["https://dns.example.net/dns-query","https://dns2.example.net/dns-query"],"upstream_dns_file":"","bootstrap_dns":["1.1.1.1"],"upstream_mode":"","ratelimit":100,"use_private_ptr_resolvers":false}' > "$FIXDIR/dns_info.json"
  printf '%s' '{"ignored":[],"interval":1209600000,"enabled":true,"ignored_enabled":false,"anonymize_client_ip":false}' > "$FIXDIR/querylog_config.json"
  printf '%s' '{"ignored":[],"interval":86400000,"enabled":true}' > "$FIXDIR/stats_config.json"
}

# ── curl 스텁: URL 디스패치 + push 페이로드 캡처 ────────────────────────────────────────────────
# STUB_FAIL_URLS(공백 구분 부분문자열)에 걸리는 URL은 curl이 실패한 것처럼 exit 22.
write_stub() {
  cat > "$STUB/curl" <<'CURL'
#!/bin/sh
url=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
done
echo "$url" >> "$OUTDIR/curl.urls"
for f in ${STUB_FAIL_URLS:-}; do
  case "$url" in
    *"$f"*) echo "stub: curl failed for $url" >&2; exit 22 ;;
  esac
done
case "$url" in
  */api/v1/import/prometheus) cat >> "$OUTDIR/payload.txt" ;;
  */api/v1/namespaces/gateway/services/traefik-ts) cat "$FIXDIR/svc.json" ;;
  */control/rewrite/list) cat "$FIXDIR/rewrite-list.json" ;;
  */control/rewrite/add) echo '{}' ;;
  */control/rewrite/update) echo '{}' ;;
  */control/dns_info) cat "$FIXDIR/dns_info.json" ;;
  */control/querylog/config) cat "$FIXDIR/querylog_config.json" ;;
  */control/stats/config) cat "$FIXDIR/stats_config.json" ;;
  *) : ;;
esac
CURL
  chmod +x "$STUB/curl"
}

# 추출한 CronJob 스크립트를 스텁 PATH로 실행한다. SEED_FILE 기본값은 합성 시드.
run_script() {
  OUTDIR="$OUTDIR" FIXDIR="$FIXDIR" STUB_FAIL_URLS="${STUB_FAIL_URLS:-}" \
    SA="$SADIR" SEED_FILE="${SEED_FILE:-$FIXDIR/AdGuardHome.yaml}" \
    ADGUARD_USER=stub ADGUARD_PASSWORD=stub \
    PATH="$STUB:$PATH" bash "$BATS_TEST_TMPDIR/run.sh" < /dev/null
}

# 페이로드에서 섹션 게이지 값을 뽑는다 — 부재면 빈 문자열이라 비교가 red가 된다.
drift() { sed -n "s/^adguard_seed_drift{section=\"$1\"} \([0-9][0-9]*\)\$/\1/p" "$OUTDIR/payload.txt"; }
# 방출된 섹션 라벨 전수(정렬).
sections() { sed -n 's/^adguard_seed_drift{section="\([^"]*\)"} [0-9][0-9]*$/\1/p' "$OUTDIR/payload.txt" | LC_ALL=C sort; }

@test "seed check emits zero for every section when the seed matches the live API" {
  run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  [ "$(drift dns.upstream_dns)" = "0" ]
  [ "$(drift dns.ratelimit)" = "0" ]
  [ "$(drift dns.use_private_ptr_resolvers)" = "0" ]
  [ "$(drift querylog.enabled)" = "0" ]
  [ "$(drift querylog.interval)" = "0" ]
  [ "$(drift statistics.interval)" = "0" ]
  # 하트비트는 bare(라벨 0) epoch 초 — 라벨이 붙으면 absent/or 브랜치의 라벨셋이 갈려 for:가 리셋된다.
  run grep -qE '^adguard_seed_drift_checked_timestamp_seconds [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

@test "the compared section set is exactly the six API-verifiable ones (enumeration floor)" {
  # 섹션이 조용히 줄면(파서 회귀) 위 @test들은 남은 섹션만 보고도 초록이다 — 전수를 못 박는다.
  run run_script
  [ "$status" -eq 0 ]
  [ "$(sections)" = "$(printf 'dns.ratelimit\ndns.upstream_dns\ndns.use_private_ptr_resolvers\nquerylog.enabled\nquerylog.interval\nstatistics.interval')" ]
}

@test "a live ratelimit regression drifts only its own section (prescription is reversed)" {
  # 사고 실측값 그대로 — 2026-08-18 ratelimit 20에서 40건 중 20건이 무응답이었다.
  # ⚠️ 이 섹션의 처방은 "시드를 라이브에 맞춰라"가 **아니다**(r4 AdGuardSeedDrift description 참조).
  printf '%s' '{"upstream_dns":["https://dns.example.net/dns-query","https://dns2.example.net/dns-query"],"upstream_dns_file":"","upstream_mode":"","ratelimit":20,"use_private_ptr_resolvers":false}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift dns.ratelimit)" = "1" ]
  [ "$(drift dns.use_private_ptr_resolvers)" = "0" ]
  [ "$(drift dns.upstream_dns)" = "0" ]
}

@test "a live private-PTR regression drifts only its own section (prescription is reversed)" {
  # true는 AdGuard 기본값이고, 그 상태에서 에러 로그의 78%가 PTR 실패였다(2026-08-18 실측).
  printf '%s' '{"upstream_dns":["https://dns.example.net/dns-query","https://dns2.example.net/dns-query"],"upstream_dns_file":"","upstream_mode":"","ratelimit":100,"use_private_ptr_resolvers":true}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift dns.use_private_ptr_resolvers)" = "1" ]
  [ "$(drift dns.ratelimit)" = "0" ]
  [ "$(drift dns.upstream_dns)" = "0" ]
}

@test "a dns_info without the two incident keys pushes nothing (extraction failure is not a zero)" {
  # 키가 사라진 응답(엔드포인트 개편)을 "0 = 일치"로 접으면 사고 회귀가 조용히 무증인이 된다.
  printf '%s' '{"upstream_dns":["https://dns.example.net/dns-query","https://dns2.example.net/dns-query"],"upstream_dns_file":"","upstream_mode":""}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  run grep -q '^adguard_seed_drift{' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
}

@test "one differing upstream line drifts only its own section" {
  printf '%s' '{"upstream_dns":["https://dns.example.net/dns-query","https://dns9.example.net/dns-query"],"upstream_dns_file":"","upstream_mode":"","ratelimit":100,"use_private_ptr_resolvers":false}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift dns.upstream_dns)" = "1" ]
  [ "$(drift querylog.enabled)" = "0" ]
  [ "$(drift querylog.interval)" = "0" ]
  [ "$(drift statistics.interval)" = "0" ]
}

@test "upstream order is part of the comparison (a reorder is drift, not a wash)" {
  printf '%s' '{"upstream_dns":["https://dns2.example.net/dns-query","https://dns.example.net/dns-query"],"upstream_dns_file":"","upstream_mode":"","ratelimit":100,"use_private_ptr_resolvers":false}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift dns.upstream_dns)" = "1" ]
}

@test "querylog interval compares the seed duration against the live milliseconds" {
  # 시드 14d ↔ 라이브 1209600000ms가 같다는 판정(위 @test)의 뒷면 — 30d(2592000000)면 그 섹션만 1.
  printf '%s' '{"ignored":[],"interval":2592000000,"enabled":true}' > "$FIXDIR/querylog_config.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift querylog.interval)" = "1" ]
  [ "$(drift querylog.enabled)" = "0" ]
  [ "$(drift dns.upstream_dns)" = "0" ]
  [ "$(drift statistics.interval)" = "0" ]
}

@test "statistics interval drifts on its own when the live retention changes" {
  printf '%s' '{"ignored":[],"interval":604800000,"enabled":true}' > "$FIXDIR/stats_config.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift statistics.interval)" = "1" ]
  [ "$(drift querylog.interval)" = "0" ]
}

@test "querylog enabled drifts on its own when the live toggle flips" {
  printf '%s' '{"ignored":[],"interval":1209600000,"enabled":false,"ignored_enabled":true}' > "$FIXDIR/querylog_config.json"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(drift querylog.enabled)" = "1" ]
  [ "$(drift querylog.interval)" = "0" ]
}

@test "the rewrites block is never compared (the reconciler itself owns the live value)" {
  # 픽스처의 시드 rewrite(*.home.example.test → 100.64.0.1)는 라이브 목록(*.home.ukyi.app →
  # 100.67.173.106)과 도메인·answer가 **전부** 다르다. 그런데도 드리프트는 0이어야 한다 —
  # 그 블록은 첫 부팅 시드이고 라이브 권위는 이 리컨실러 자신이라 갈리는 것이 정상이기 때문이다.
  run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  run grep -q 'section="rewrites"' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
  run grep -q 'section="filtering.rewrites"' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
  [ "$(drift dns.upstream_dns)" = "0" ]
}

@test "an unreachable AdGuard API pushes no gauge and no heartbeat (observation failure is not drift)" {
  STUB_FAIL_URLS="/control/dns_info" run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  run grep -q '^adguard_seed_drift{' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
  run grep -q '^adguard_seed_drift_checked_timestamp_seconds ' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
}

@test "a changed live API shape pushes nothing rather than reporting a phantom drift" {
  # 200인데 키가 사라진 경우(엔드포인트 개편) — 추출 0을 "라이브 upstream 없음 = 드리프트"로 읽으면
  # 업그레이드마다 오보가 난다. tri-state의 세 번째 값(관측 실패)으로 접어야 한다.
  printf '%s' '{}' > "$FIXDIR/dns_info.json"
  run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  run grep -q '^adguard_seed_drift{' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
  run grep -q '^adguard_seed_drift_checked_timestamp_seconds ' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
}

@test "a missing seed mount pushes nothing rather than reporting a phantom drift" {
  SEED_FILE="$BATS_TEST_TMPDIR/nope.yaml" run run_script
  [ "$status" -eq 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  run grep -q '^adguard_seed_drift{' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
}

# ── 실패 격리(양방향) ──────────────────────────────────────────────────────────────────────────

@test "a failing seed check leaves the rewrite convergence and its heartbeat intact" {
  STUB_FAIL_URLS="/control/dns_info" run run_script
  [ "$status" -eq 0 ]                       # 대조 실패가 잡 종료코드를 오염시키지 않는다
  run grep -qE '^adguard_rewrite_reconcile_timestamp [0-9]{10}$' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

@test "a failing rewrite step still leaves the seed comparison already pushed" {
  # traefik-ts svc 조회가 죽으면 rewrite 스텝은 exit 1이다. 대조 스텝은 그 **앞**에 있으므로
  # 게이지·하트비트가 이미 나가 있어야 한다 — 순서가 뒤집히면 이 단언이 red다.
  STUB_FAIL_URLS="/api/v1/namespaces/gateway/services/traefik-ts" run run_script
  [ "$status" -ne 0 ]
  [ -s "$OUTDIR/payload.txt" ]
  [ "$(drift dns.upstream_dns)" = "0" ]
  run grep -q '^adguard_seed_drift_checked_timestamp_seconds ' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
  # rewrite 하트비트는 반대로 **없어야** 한다(read-back 전에 죽었다) — 두 축이 독립임을 못 박는다.
  run grep -q '^adguard_rewrite_reconcile_timestamp ' "$OUTDIR/payload.txt"
  [ "$status" -eq 1 ]
}

# ── 실 시드 파일의 모양 ────────────────────────────────────────────────────────────────────────

@test "the parser reaches every section of the real in-repo seed ConfigMap" {
  # 값이 아니라 **모양**의 증인이다(들여쓰기·꼬리 주석·블록 스칼라 해제 후 컬럼). 여섯 섹션 중 하나라도
  # 시드 쪽 추출이 비면 스크립트는 파싱 실패로 접어 아무것도 push하지 않으므로, 게이지 6줄의 존재가
  # 곧 "여섯 추출이 전부 성공했다"이다. 값 단언은 합성 픽스처가 진다(정당한 시드 편집 ≠ CI red).
  # ⚠️ `dns.ratelimit`이 실 시드의 **들여쓴 주석**(`ratelimit_subnet_len_ipv4 기본값이 24라…`)에 걸리지
  #    않는다는 것도 여기서 증명된다 — 걸리면 판독값이 숫자가 아니라 파싱 실패로 접힌다.
  yq 'select(.kind=="ConfigMap") | .data["AdGuardHome.yaml"]' "$ROOT/platform/adguard/prod/adguardhome.yaml" \
    > "$BATS_TEST_TMPDIR/real-seed.yaml"
  [ -s "$BATS_TEST_TMPDIR/real-seed.yaml" ]
  SEED_FILE="$BATS_TEST_TMPDIR/real-seed.yaml" run run_script
  [ "$status" -eq 0 ]
  [ "$(sections)" = "$(printf 'dns.ratelimit\ndns.upstream_dns\ndns.use_private_ptr_resolvers\nquerylog.enabled\nquerylog.interval\nstatistics.interval')" ]
  run grep -q '^adguard_seed_drift_checked_timestamp_seconds ' "$OUTDIR/payload.txt"
  [ "$status" -eq 0 ]
}

# ── 매니페스트 배선(실행 seam이 못 보는 축) ─────────────────────────────────────────────────────

@test "the seed ConfigMap is mounted read-only into the reconciler pod" {
  # 실행 하네스는 SEED_FILE을 주입하므로 **마운트 자체**는 정적으로만 볼 수 있다.
  grep -q 'name: adguard-config' "$F"
  grep -qE 'mountPath: /seed' "$F"
  grep -A2 -- 'mountPath: /seed' "$F" | grep -q 'readOnly: true'
}

@test "the seed comparison keeps its own bounded curl grade (deadline budget is a constant)" {
  # 기존 READ 등급(최악 50s/호출)을 쓰면 4호출이 150s 데드라인을 깬다 — 재시도 없는 짧은 등급이
  # 예산을 상수로 묶는다. 산술 증인은 test_rewrite_reconciler.bats가 진다.
  grep -q 'CURL_SEED=' "$F"
  grep -E 'CURL_SEED=' "$F" | grep -q -- '--max-time 3'
  run bash -c 'grep -E "CURL_SEED=" "$1" | grep -E -- "--retry"' _ "$F"
  [ "$status" -ne 0 ]
}
