#!/usr/bin/env bats
# cache-url — 로컬/GUI Valkey 연결 URL을 .env.local에 기록. 출력 키는 #141 이후 **namespaced**
# (`<NAME>_REDIS_RO_URL`/`<NAME>_REDIS_URL` — 클러스터 envFrom과 같은 키) + RO/RW 모드 +
# port-forward 기본(Valkey tailscale 노출 deferred). dry-run만 검증(CI-safe). ⚠️ 중간 단언은 [ ]만.
# 라이브 레인(kubectl 인라인 stub + 빈 KUBECONFIG)은 host 술어·URL 치환·자격 파일 무결성을 밟는다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

# 라이브 경로 픽스처 — db-url 스위트와 같은 관용구(kubectl stub이 $1을 base64로, 빈 KUBECONFIG).
live_fixture() {
  LT="$BATS_TEST_TMPDIR/live"; mkdir -p "$LT/bin"
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$b64" > "$LT/bin/kubectl"
  chmod +x "$LT/bin/kubectl"
  : > "$LT/kubeconfig"
}
run_live() { run env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" bun "$ROOT/tools/cache-url.ts" --name sessions "$@"; }

@test "cache-url --dry-run (default RO) writes namespaced SESSIONS_REDIS_RO_URL, port-forward localhost, no tailscale required" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  # prod conn 키와 일치(<NAME>_REDIS_RO_URL) — 마지막 chained 줄로 판별.
  echo "$output" | grep -qE "127.0.0.1|port-forward" \
    && echo "$output" | grep -qE "출력하지 않음|stdout" \
    && echo "$output" | grep -q "SESSIONS_REDIS_RO_URL"
}

@test "cache-url default mode reads the read-only conn cache-<name>-ro-conn" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cache-sessions-ro-conn"
}

@test "cache-url --rw reads cache-<name>-conn (default user) and writes namespaced SESSIONS_REDIS_URL" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --rw --dry-run
  [ "$status" -eq 0 ]
  # default(RW) conn(ro-conn 아님) + prod 키 일치(<NAME>_REDIS_URL) — 마지막 줄로 판별.
  echo "$output" | grep -q "cache-sessions-conn" \
    && ! echo "$output" | grep -ow "cache-sessions-ro-conn" \
    && echo "$output" | grep -q "SESSIONS_REDIS_URL"
}

@test "cache-url provides no destructive surface (read-only tool)" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --flushall
  [ "$status" -ne 0 ]   # 알 수 없는 플래그 fail-closed
  # ⚠️ 중첩 사각 — 위 `run bun`은 cache-url.ts가 사라져도 비-0이라, 이 줄까지 `-ne 0`이면 도구 파일
  #    부재에 두 단언이 함께 통과했다(db-url과 같은 짝). 단일 파일 피연산자라 `-eq 1`이 닫는다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -iE "FLUSHALL|flushdb|del " "$ROOT/tools/cache-url.ts"
  [ "$status" -eq 1 ]
}

@test "cache-url without KUBECONFIG signals skip via the helper (exit 4, marker, no write)" {
  # db-url과 대칭.
  T="$(mktemp -d)"
  run env -u KUBECONFIG bun "$ROOT/tools/cache-url.ts" --name sessions --env-local "$T/.env.local"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: cache-url: "
  [ ! -f "$T/.env.local" ]
  rm -rf "$T"
}

@test "cache-url live path writes the namespaced env key, substitutes the port-forward host, and never prints plaintext" {
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "cmVkaXM6Ly91Om5AY2FjaGUtc2Vzc2lvbnM6NjM3OQ=="
STUB
  chmod +x "$T/bin/kubectl"
  : > "$T/kubeconfig"   # 라이브 경로 픽스처 — 클러스터 도메인 실재(없으면 skip variant가 선행한다)
  run env PATH="$T/bin:$PATH" KUBECONFIG="$T/kubeconfig" bun "$ROOT/tools/cache-url.ts" --name sessions --env-local "$T/.env.local"
  [ "$status" -eq 0 ]
  grep -q '^SESSIONS_REDIS_RO_URL=redis://u:n@127.0.0.1:6379$' "$T/.env.local"   # 기본 host(127.0.0.1) 치환 + namespaced 키
  [ "$(printf '%s' "$output" | grep -c 'redis://')" -eq 0 ]    # 평문 URL stdout 비노출
  rm -rf "$T"
}

# ── host 술어 · URL 치환 · 자격 파일 무결성 — db-url과 대칭 ─────────────────────────────────────

@test "a host carrying a newline is a usage error (exit 2) and no credential file is written (line injection)" {
  live_fixture 'redis://u:n@cache-sessions:6379'
  run_live --host $'127.0.0.1\nINJECTED_KEY=evil' --env-local "$LT/.env.local"
  [ "$status" -eq 2 ]
  [ ! -e "$LT/.env.local" ]
}

@test "the CACHE_LOCAL_HOST env fallback is validated too: a newline is a failure (exit 1), not a write" {
  live_fixture 'redis://u:n@cache-sessions:6379'
  run env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" CACHE_LOCAL_HOST=$'a\nb' bun "$ROOT/tools/cache-url.ts" --name sessions --env-local "$LT/.env.local"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "host 형식"
  [ ! -e "$LT/.env.local" ]
}

@test "a raw @ inside the password survives the host substitution as %40 (the first-@ regex truncated it to 'p')" {
  # cache 생산자(provision-cache)는 비밀번호를 URL 인코딩하지 않는다 — 오늘은 base64url 불변식만 지키지만,
  # 치환은 그 불변식에 기대지 않고 userinfo를 보존해야 한다(URL host setter).
  live_fixture 'redis://ro:p@h@cache-sessions:6379'
  run_live --host 127.0.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 0 ]
  grep -q '^SESSIONS_REDIS_RO_URL=redis://ro:p%40h@127.0.0.1:6379$' "$LT/.env.local"
}

@test "a conn value that is not a URL is a failure (exit 1) with no file and no plaintext echo" {
  live_fixture 'garbage'
  run_live --host 127.0.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 1 ]
  [ ! -e "$LT/.env.local" ]
  [ "$(printf '%s' "$output" | grep -c 'garbage')" -eq 0 ]
}

@test "a freshly created credential file is mode 0600 (cache lane)" {
  live_fixture 'redis://u:n@cache-sessions:6379'
  run_live --host 127.0.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$LT/.env.local" 2>/dev/null || stat -f %Lp "$LT/.env.local")" = "600" ]
}

@test "legitimate cache hosts pass the predicate: loopback, bracketed IPv6, MagicDNS (floor 3)" {
  live_fixture 'redis://u:n@cache-sessions:6379'
  n=0
  for h in 127.0.0.1 '[::1]' cache.tail1234.ts.net; do
    rm -f "$LT/.env.local"
    run_live --host "$h" --env-local "$LT/.env.local"
    [ "$status" -eq 0 ]
    grep -qF "@${h}:6379" "$LT/.env.local"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
}

@test "the dry-run plan pins the default port-forward host field (display parity with the engine)" {
  # host 필드는 껍데기의 표시 전용 재계산 — 엔진 기본값(127.0.0.1)과 갈리면 여기서 red(리뷰 지적).
  run bun tools/cache-url.ts --name t --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.host')" = "127.0.0.1:6379" ]
}

@test "a missing secret key (empty jsonpath output, rc 0) is a failure, not a blank credential write" {
  # db-url과 대칭 — 빈 출력·rc 0을 성공으로 접으면 `SESSIONS_REDIS_RO_URL=`(빈 값)이 파일에 남는다.
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$T/bin/kubectl"
  : > "$T/kubeconfig"   # 라이브 경로 픽스처 — 클러스터 도메인 실재(없으면 skip variant가 선행한다)
  run env PATH="$T/bin:$PATH" KUBECONFIG="$T/kubeconfig" bun "$ROOT/tools/cache-url.ts" --name sessions --env-local "$T/.env.local"
  [ "$status" -eq 1 ]
  [ ! -f "$T/.env.local" ]
  echo "$output" | grep -q "비어 있거나 없다"
  rm -rf "$T"
}
