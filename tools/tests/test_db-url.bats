#!/usr/bin/env bats
# db-url — 로컬/GUI DB 연결 URL을 .env.local(admin은 .env.admin.local)에 기록. 출력 키는
# **namespaced**(`<NAME>_RO_DATABASE_URL`/`<NAME>_DATABASE_URL`/`<NAME>_DATABASE_ADMIN_URL` — 클러스터
# envFrom과 같은 키. bare DATABASE_URL은 dev.ts 모드 1 전용이다) + 모드 분리(RO/RW/admin) +
# 채널 분리(F2). dry-run만 검증(CI-safe, kubectl 불요). ⚠️ 중간 단언은 [ ]만.
# 라이브 레인(kubectl 인라인 stub + 빈 KUBECONFIG)은 host 술어·URL 치환·자격 파일 무결성을 밟는다.
bats_require_minimum_version 1.5.0
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

# 라이브 경로 픽스처 — kubectl stub이 $1(평문 conn 값)을 base64로 내고, 빈 KUBECONFIG로 클러스터 도메인을
# 실재시킨다. 산출물은 $LT 아래(.env.local 등) — BATS_TEST_TMPDIR라 정리는 bats 몫.
live_fixture() {
  LT="$BATS_TEST_TMPDIR/live"; mkdir -p "$LT/bin"
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$b64" > "$LT/bin/kubectl"
  chmod +x "$LT/bin/kubectl"
  : > "$LT/kubeconfig"
}
run_live() { run env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" bun "$ROOT/tools/db-url.ts" --name orders "$@"; }

@test "db-url --dry-run (default RO) writes namespaced ORDERS_RO_DATABASE_URL and forbids stdout plaintext" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  # 마지막 chained 줄로 판별(bats 중간단언 침묵통과 회피). prod conn 키와 일치(<NAME>_RO_DATABASE_URL).
  echo "$output" | grep -qE "출력하지 않음|stdout" && echo "$output" | grep -q "ORDERS_RO_DATABASE_URL"
}

@test "db-url default mode reads the read-only conn db-<name>-ro-conn" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-orders-ro-conn"
}

@test "db-url --rw reads the owner conn db-<name>-conn and writes namespaced ORDERS_DATABASE_URL" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --dry-run
  [ "$status" -eq 0 ]
  # owner conn(ro-conn 아님) + prod owner 키 일치(<NAME>_DATABASE_URL) — 마지막 줄로 판별.
  echo "$output" | grep -q "db-orders-conn" \
    && ! echo "$output" | grep -ow "db-orders-ro-conn" \
    && echo "$output" | grep -q "ORDERS_DATABASE_URL"
}

@test "db-url --admin and --rw are mutually exclusive (exit 2)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --admin --dry-run
  [ "$status" -eq 2 ]
}

@test "db-url --admin uses namespaced ORDERS_DATABASE_ADMIN_URL + .env.admin.local, never the app runtime key (F2 channel separation)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --dry-run
  [ "$status" -eq 0 ]
  # admin 키(<NAME>_DATABASE_ADMIN_URL) + admin 파일 + 자격 secret, 그리고 앱 런타임 키
  # (<NAME>_DATABASE_URL)는 절대 안 씀 — 마지막 chained 줄로 판별(F2 채널 분리).
  echo "$output" | grep -q "ORDERS_DATABASE_ADMIN_URL" \
    && echo "$output" | grep -q "env.admin.local" \
    && echo "$output" | grep -q "pg-admin-credentials" \
    && ! echo "$output" | grep -ow "ORDERS_DATABASE_URL"
}

@test "db-url --admin rejects --env-local override to a non-admin file (F2 channel separation)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --env-local .env.local --dry-run
  [ "$status" -eq 2 ]
  # 명시적으로 .env.admin.local을 주는 것은 허용(기본과 동일)
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --env-local .env.admin.local --dry-run
  [ "$status" -eq 0 ]
}

@test "db-url provides no reset/drop/teardown surface (read-only tool)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --reset
  [ "$status" -ne 0 ]   # 알 수 없는 플래그 fail-closed
  # ⚠️ 중첩 사각 — 위 `run bun`은 db-url.ts가 사라져도 비-0이다. 이 줄까지 `-ne 0`이면 두 단언이
  #    **함께** rc 비-0으로 통과해, 도구 파일 부재에 "파괴 표면 없음"이 초록으로 증명됐다.
  #    단일 파일 피연산자라 `-eq 1`이 그 rc 2를 red로 가른다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -iE "DROP TABLE|db:reset|compose down" "$ROOT/tools/db-url.ts"
  [ "$status" -eq 1 ]
}

@test "db-url without KUBECONFIG signals skip via the helper (exit 4, marker, no write)" {
  # skip variant의 bin 대응 — 성공 문구/exit 0으로 위장하면 "기록했다"는 거짓말이다.
  T="$(mktemp -d)"
  run env -u KUBECONFIG TS_DB_HOST=h bun "$ROOT/tools/db-url.ts" --name orders --env-local "$T/.env.local"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: db-url: "
  [ ! -f "$T/.env.local" ]
  rm -rf "$T"
}

@test "db-url live path writes the namespaced env key, substitutes the tailscale host, and never prints plaintext" {
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "cG9zdGdyZXM6Ly91Om5AcGctcncucHJvZDo1NDMyL29yZGVycw=="
STUB
  chmod +x "$T/bin/kubectl"
  : > "$T/kubeconfig"   # 라이브 경로 픽스처 — 클러스터 도메인 실재(없으면 skip variant가 선행한다)
  run env PATH="$T/bin:$PATH" KUBECONFIG="$T/kubeconfig" bun "$ROOT/tools/db-url.ts" --name orders --host 100.99.0.1 --env-local "$T/.env.local"
  [ "$status" -eq 0 ]
  grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:n@100.99.0.1:5432/orders$' "$T/.env.local"   # host 치환 + namespaced 키
  [ "$(printf '%s' "$output" | grep -c 'postgres://')" -eq 0 ]    # 평문 URL stdout 비노출(카운트 패턴)
  rm -rf "$T"
}

# ── host 술어 · URL 치환 · 자격 파일 무결성 ──────────────────────────────────────────────────
# host는 무검증으로 URL·.env 행에 보간됐다 — 개행 하나로 .env.local에 임의 행이 주입되고 success가 났다(실측).
# 술어는 화이트리스트가 아니라 URL 구조를 깨는 문자 거부라 MagicDNS·밑줄·후행점 FQDN·IPv6 대괄호는 통과한다.

@test "a host carrying a newline is a usage error (exit 2) and no credential file is written (line injection)" {
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  run_live --host $'100.99.0.1\nINJECTED_KEY=evil' --env-local "$LT/.env.local"
  [ "$status" -eq 2 ]
  [ ! -e "$LT/.env.local" ]
}

@test "hosts that break URL structure or carry replace-metacharacters are usage errors (exit 2, floor 7)" {
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  n=0
  for h in 'X$&Y' 'evil@' 'h/x' 'h:5432' 'h?x' 'h#x' 'a b'; do
    run_live --host "$h" --env-local "$LT/.env.local"
    [ "$status" -eq 2 ]
    n=$((n+1))
  done
  [ "$n" -eq 7 ]
  [ ! -e "$LT/.env.local" ]
}

@test "the TS_DB_HOST env fallback is validated too: a newline is a failure (exit 1), not a write" {
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  run env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" TS_DB_HOST=$'a\nb' bun "$ROOT/tools/db-url.ts" --name orders --env-local "$LT/.env.local"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "host 형식"
  [ ! -e "$LT/.env.local" ]
}

@test "the host substitution preserves userinfo (encoded @ in the password) — URL host setter, not a first-@ regex" {
  live_fixture 'postgres://u:p%40x@pg-rw.prod:5432/orders'
  run_live --host 100.99.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 0 ]
  grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:p%40x@100.99.0.1:5432/orders$' "$LT/.env.local"
}

@test "a conn value that is not a URL (garbage, or a raw / inside userinfo) is a failure (exit 1) with no file" {
  live_fixture 'garbage'
  run_live --host 100.99.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 1 ]
  [ ! -e "$LT/.env.local" ]
  # 평문 값은 오류 문구에도 실리지 않는다.
  [ "$(printf '%s' "$output" | grep -c 'garbage')" -eq 0 ]
  live_fixture 'postgres://u:p/x@pg-rw.prod:5432/orders'
  run_live --host 100.99.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 1 ]
  [ ! -e "$LT/.env.local" ]
}

@test "a freshly created credential file is mode 0600; an existing file keeps its own mode and other keys" {
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  run_live --host 100.99.0.1 --env-local "$LT/.env.local"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$LT/.env.local" 2>/dev/null || stat -f %Lp "$LT/.env.local")" = "600" ]
  # 기존 파일(0644·다른 키 보유)은 퍼미션을 건드리지 않고 같은 키 행만 교체한다.
  printf 'OTHER=1\nORDERS_RO_DATABASE_URL=stale\n' > "$LT/existing.env"; chmod 644 "$LT/existing.env"
  run_live --host 100.99.0.1 --env-local "$LT/existing.env"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$LT/existing.env" 2>/dev/null || stat -f %Lp "$LT/existing.env")" = "644" ]
  grep -q '^OTHER=1$' "$LT/existing.env"
  [ "$(grep -c '^ORDERS_RO_DATABASE_URL=' "$LT/existing.env")" -eq 1 ]
  grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:n@100.99.0.1:5432/orders$' "$LT/existing.env"
}

@test "legitimate hosts pass the predicate: tailscale IP, loopback, MagicDNS, bracketed IPv6, underscore, trailing-dot FQDN (floor 6)" {
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  n=0
  for h in 100.99.0.1 127.0.0.1 nuc-db.tail1234.ts.net '[fd7a:115c:a1e0::1]' my_host db.example.; do
    rm -f "$LT/.env.local"
    run_live --host "$h" --env-local "$LT/.env.local"
    [ "$status" -eq 0 ]
    grep -qF "@${h}:5432/orders" "$LT/.env.local"
    n=$((n+1))
  done
  [ "$n" -eq 6 ]
}

@test "a malformed name is a usage error (exit 2, usage line — shell preserves the legacy contract)" {
  run --separate-stderr bun tools/db-url.ts --name BAD --dry-run
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "^usage: db-url"
}

@test "a missing secret key (empty jsonpath output, rc 0) is a failure, not a blank credential write" {
  # kubectl jsonpath는 키 부재를 빈 출력·rc 0으로 접는다 — rc만 보면 `ORDERS_RO_DATABASE_URL=`(빈 값)이
  # success/wrote:true로 기록된다(헤더 계약 "깨진 조회 = failure"가 거짓이 되는 자리).
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$T/bin/kubectl"
  : > "$T/kubeconfig"   # 라이브 경로 픽스처 — 클러스터 도메인 실재(없으면 skip variant가 선행한다)
  run env PATH="$T/bin:$PATH" KUBECONFIG="$T/kubeconfig" bun "$ROOT/tools/db-url.ts" --name orders --host 100.99.0.1 --env-local "$T/.env.local"
  [ "$status" -eq 1 ]
  [ ! -f "$T/.env.local" ]
  echo "$output" | grep -q "비어 있거나 없다"
  rm -rf "$T"
}

# ── namespaced 키 문서·env 파일 위생 ───────────────────────────────────────────────────────
# 출력 키는 prod conn 핸들과 같은 namespaced 키다. 문서만 canonical에 멈춰 있었다.

@test "the README states the five namespaced env keys (positive greps, floor 5)" {
  # 부재 grep 단독은 표기 변경에 우회된다(「canonical」만 지우면 초록) — 존재를 센다.
  n=0
  for k in '<NAME>_RO_DATABASE_URL' '<NAME>_DATABASE_URL' '<NAME>_DATABASE_ADMIN_URL' '<NAME>_REDIS_RO_URL' '<NAME>_REDIS_URL'; do
    grep -qF -- "$k" "$ROOT/tools/README.md"
    n=$((n+1))
  done
  # 열거 바닥값 — 루프가 0바퀴 돌면 위 단언이 하나도 실행되지 않고 통과한다.
  [ "$n" -eq 5 ]
  # 키 이름이 코드와 같은 규약에서 왔는지 — 레이아웃 커널의 실제 산출과 대조한다(손 사본 방지).
  run bun -e '
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    const db = layoutFor("db", "orders"), c = layoutFor("cache", "sessions");
    const want = [db.envKeys.ro, db.envKeys.rw, c.envKeys.ro, c.envKeys.rw].join(",");
    if (want !== "ORDERS_RO_DATABASE_URL,ORDERS_DATABASE_URL,SESSIONS_REDIS_RO_URL,SESSIONS_REDIS_URL") {
      console.error("레이아웃 커널 키 드리프트: " + want); process.exit(1);
    }
    console.log("KEYS_OK");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^KEYS_OK$"
}

@test "an existing env file keeps its comments and blank lines, and the stale credential survives nowhere (export/spaced forms too)" {
  # 중복 제거가 `KEY=` 접두 정확 일치뿐이라 `export KEY=`·`KEY =` 행이 남았다 —
  # 어느 값이 이기는지가 로더 구현에 달렸다. 판정은 '키 행 1개'가 아니라 **'옛 자격이 0회'**다.
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  printf '# 로컬 개발용\n\nOTHER=1\nexport ORDERS_RO_DATABASE_URL=postgres://old:old@stale:5432/orders\n\nORDERS_RO_DATABASE_URL = postgres://old2:old2@stale:5432/orders\n# 꼬리 주석\n' > "$LT/pre.env"
  run_live --host 100.99.0.1 --env-local "$LT/pre.env"
  [ "$status" -eq 0 ]
  # ① 옛 자격 문자열이 파일에 0회(두 표기 모두 지워졌다).
  [ "$(grep -c 'stale:5432' "$LT/pre.env")" -eq 0 ]
  # ② 새 행은 정확히 1개.
  [ "$(grep -c '^ORDERS_RO_DATABASE_URL=' "$LT/pre.env")" -eq 1 ]
  grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:n@100.99.0.1:5432/orders$' "$LT/pre.env"
  # ③ 사용자의 구조(주석 2줄·빈 줄·다른 키)는 보존된다.
  grep -q '^# 로컬 개발용$' "$LT/pre.env"
  grep -q '^# 꼬리 주석$' "$LT/pre.env"
  grep -q '^OTHER=1$' "$LT/pre.env"
  [ "$(grep -c '^$' "$LT/pre.env")" -eq 2 ]
}

@test "writing outside .gitignore warns in the note; a repo that ignores .env.* does not (and no git means silence)" {
  # 대상이 gitignore 밖이어도 아무 신호가 없었다 — `--env-local local.env`나 앱 레포의
  # .gitignore는 이 레포 통제 밖이다. 경고는 note에만 싣고 variant는 success를 유지한다(관측 편의).
  # 봉투(note)를 읽어야 하므로 통합 CLI(--json)를 쓴다 — bin 껍데기는 성공 시 한 줄만 낸다.
  live_fixture 'postgres://u:n@pg-rw.prod:5432/orders'
  R="$LT/norepo-ignore"; mkdir -p "$R"
  git -c init.defaultBranch=main init -q "$R"
  run --separate-stderr env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" bun "$ROOT/tools/homelab.ts" db url orders --host 100.99.0.1 --env-local "$R/.env.local" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.wrote == true'
  echo "$output" | jq -r '.result.note' | grep -q "경고"
  echo "$output" | jq -r '.result.note' | grep -q "gitignore"
  # 같은 픽스처에 .gitignore를 넣으면 경고가 사라진다(위 존재 단언이 이 부재 단언의 양성 대조다).
  printf '.env.*\n' > "$R/.gitignore"
  rm -f "$R/.env.local"
  run --separate-stderr env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" bun "$ROOT/tools/homelab.ts" db url orders --host 100.99.0.1 --env-local "$R/.env.local" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.wrote == true'
  [ "$(echo "$output" | jq -r '.result.note // ""' | grep -c "경고")" -eq 0 ]
  # git 밖(레포 아님)은 침묵 — 판정 자체를 못 하므로 경고도 못 한다.
  N="$LT/plain"; mkdir -p "$N"
  run --separate-stderr env PATH="$LT/bin:$PATH" KUBECONFIG="$LT/kubeconfig" bun "$ROOT/tools/homelab.ts" db url orders --host 100.99.0.1 --env-local "$N/.env.local" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.note // ""' | grep -c "경고")" -eq 0 ]
}

@test "db --dry-run reports an unresolved host in the note while staying a success variant" {
  # dry-run이 host 해석 앞에서 success를 내 「계획은 통과, 라이브는 --host 필요」가 됐다.
  # 계획은 클러스터 무의존이라 success를 유지하되, 미해석 사실은 note가 말한다.
  # ⚠️ TS_DB_HOST는 명시적으로 걷어낸다 — 러너 셸에 남아 있으면 vacuous green이다.
  run --separate-stderr env -u TS_DB_HOST bun "$ROOT/tools/homelab.ts" db url orders --dry-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.variant == "success"'
  echo "$output" | jq -r '.result.note' | grep -q "host 미해석"
  # 양성 대조 — host가 있으면 그 문구가 없다(같은 검출기·같은 명령).
  run --separate-stderr env TS_DB_HOST=pg-rw.example.ts.net bun "$ROOT/tools/homelab.ts" db url orders --dry-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.variant == "success"'
  [ "$(echo "$output" | jq -r '.result.note' | grep -c "host 미해석")" -eq 0 ]
  # bin 껍데기의 계획 JSON도 같은 note를 나른다(두 표면이 같은 엔진을 소비한다).
  run env -u TS_DB_HOST bun "$ROOT/tools/db-url.ts" --name orders --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.note' | grep -q "host 미해석"
}

@test "the host-absent error names every transport that can supply it (CLI flag, MCP arg, env)" {
  # MCP에서 도달 가능한 오류가 CLI 플래그(--host)만 지시했다 — MCP 인자는 host다.
  run env -u TS_DB_HOST -u KUBECONFIG bun "$ROOT/tools/db-url.ts" --name orders --env-local "$BATS_TEST_TMPDIR/none.env"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "host 입력"
  echo "$output" | grep -q -- "--host"
  echo "$output" | grep -q "MCP host"
  echo "$output" | grep -q "TS_DB_HOST"
  [ ! -e "$BATS_TEST_TMPDIR/none.env" ]
}
