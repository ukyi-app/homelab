#!/usr/bin/env bats
# homelab mcp — stdio MCP 서버의 JSON-RPC 계약(파괴 제외 전 동사 노출·동기 바운디드·명시 경로).
# 계약: initialize → tools/list(teardown 부재) → tools/call 결과가 CLI --json과 같은 계약 오브젝트.
#   - --wait류 장기 대기 미노출(어떤 tool 스키마에도 wait/pollMs/deadlineMs 없음).
#   - 디렉토리 추론 없음: secrets=repoPath, init=parentDir 명시 입력(서버 cwd 무관 — 같은 결과).
#   - 무상태: 동시 호출 각자 핸들 독립, 재시작 후 재호출 정상. usage 오류=JSON-RPC invalid params(-32602).
# 하네스: JSON-RPC 라인을 stdin으로 파이프, stdout 응답을 jq로 검사(PATH stub — 라이브 무의존).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_kubectl_stub
  make_kubeseal_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"; echo "apiVersion: v1" > "$KC"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
}

# JSON-RPC 라인들을 stdin으로 파이프하고 stdout(응답)을 $output에 담는다. 서버는 EOF에 exit 0.
mcp_rpc() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c 'printf "%s\n" "$@" | "$0" tools/homelab.ts mcp' "$BUN" "$@"
}

@test "initialize returns serverInfo and tools capability" {
  mcp_rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==1) | .result.serverInfo.name')" = "homelab" ]
  [ "$(echo "$output" | jq -rc 'select(.id==1) | .result.capabilities | has("tools")')" = "true" ]
  [ "$(echo "$output" | jq -rc 'select(.id==1) | .result.protocolVersion')" = "2024-11-05" ]
}

@test "tools/list exposes non-destructive verbs and NEVER teardown" {
  mcp_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  names="$(echo "$output" | jq -rc 'select(.id==2) | .result.tools[].name' | LC_ALL=C sort | tr '\n' ' ')"
  # 노출 대상 9종 전부(파괴 제외).
  for t in doctor status db_create db_url cache_create cache_url app_create app_secrets app_init; do
    echo "$names" | grep -qw "$t"
  done
  # teardown은 어떤 형태로도 부재(파괴는 CLI 전용).
  [ "$(echo "$output" | jq -rc 'select(.id==2) | .result.tools[] | select(.name | test("teardown")) | .name' | wc -l | tr -d ' ')" = "0" ]
  # 바닥값: 정확히 9개(신규 파괴 동사가 조용히 새면 red).
  [ "$(echo "$output" | jq -rc 'select(.id==2) | .result.tools | length')" = "9" ]
}

@test "no tool exposes a long-wait option (--wait/pollMs/deadlineMs absent from every schema)" {
  mcp_rpc '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  # 어떤 tool inputSchema properties에도 wait/pollMs/deadlineMs 키가 없다(동기 바운디드).
  bad="$(echo "$output" | jq -rc 'select(.id==3) | .result.tools[] | .inputSchema.properties // {} | keys[] | select(. == "wait" or . == "pollMs" or . == "deadlineMs")')"
  [ -z "$bad" ]
}

@test "a tool call returns the same contract envelope as CLI --json (doctor)" {
  mcp_rpc '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"doctor","arguments":{}}}'
  [ "$status" -eq 0 ]
  env="$(echo "$output" | jq -rc 'select(.id==4) | .result.content[0].text')"
  [ "$(echo "$env" | jq -r '.schema')" = "homelab-cli/1" ]
  [ "$(echo "$env" | jq -r '.verb')" = "doctor" ]
  # 성공 variant는 isError=false(x-contract.mcp normalVariants).
  [ "$(echo "$output" | jq -rc 'select(.id==4) | .result.isError')" = "false" ]
  # envelope이 스키마 계약을 만족한다(CLI --json과 한 벌).
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(process.argv[1]);
    const errs = schemaErrors(env, sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$env"
  echo "$output" | grep -q "^valid$"
}

@test "a mutation tool call returns the run handle promptly (pending) without blocking on conclusion" {
  # identifyOnly(release r1 a2=b3): MCP 변이는 run을 식별하면 conclusion(최대 20분) 폴링 없이 pending +
  # run 핸들을 즉시 반환한다 — 진행은 status(run URL) 재조회로. 단일 스레드 서버가 블로킹되지 않게.
  mcp_rpc '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"db_create","arguments":{"name":"mydb","ext":["pg_trgm"]}}}'
  [ "$status" -eq 0 ]
  env="$(echo "$output" | jq -rc 'select(.id==5) | .result.content[0].text')"
  [ "$(echo "$env" | jq -r '.verb')" = "db create" ]
  [ "$(echo "$env" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$env" | jq -r '.result.run.id')" = "501" ]
  echo "$env" | jq -r '.result.pendingReason' | grep -q "status 핸들"
  # conclusion을 기다리지 않았다: run conclusion 추적(actions/runs/<id>) 호출이 없다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" = "0" ]
  # pending은 MCP에서 에러가 아니다(x-contract.mcp normalVariants).
  [ "$(echo "$output" | jq -rc 'select(.id==5) | .result.isError')" = "false" ]
  # 디스패치 argv에 correlation 수령증(자기 run 특정), auto-merge 관련 gh pr 호출 0.
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run create-database.yaml -R ukyi-app/homelab \
    -f "name=mydb" -f "ext_pg_trgm=true" -f "ext_pgcrypto=false" -f "ext_citext=false" -f "ext_vector=false" -f "ext_postgis=false" -f "ext_extra=" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh pr)" = "0" ]
}

@test "a usage error maps to JSON-RPC invalid params (-32602), not an envelope" {
  mcp_rpc '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"db_create","arguments":{"name":"Bad_Name"}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==6) | .error.code')" = "-32602" ]
  # 오류는 result(content)를 내지 않는다.
  [ "$(echo "$output" | jq -rc 'select(.id==6) | has("result")')" = "false" ]
}

@test "an unknown tool (including any destructive verb) is refused as invalid params" {
  mcp_rpc '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"app_teardown","arguments":{"app":"myapp","confirm":"myapp"}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==7) | .error.code')" = "-32602" ]
  echo "$output" | jq -rc 'select(.id==7) | .error.message' | grep -q "app_teardown"
  # 파괴 디스패치가 일어나지 않았다(gh workflow run teardown-app 0건).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run teardown-app.yaml)" = "0" ]
}

@test "each operation is addressable by its own handle (two mutations, two distinct handles)" {
  # ⚠️ stdio 서버는 요청을 직렬로(동기·바운디드) 처리한다 — 이 테스트는 병렬성이 아니라 각 오퍼레이션이
  # 자기 run/PR 핸들로 독립 식별·조회됨을 단언한다(스펙 "각자 핸들로 독립 조회"). 무상태라 서버 세션 상태 없음.
  mcp_rpc \
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"db_create","arguments":{"name":"mydb"}}}' \
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"cache_create","arguments":{"name":"mycache"}}}'
  [ "$status" -eq 0 ]
  run1="$(echo "$output" | jq -rc 'select(.id==8) | .result.content[0].text | fromjson | .result.run.id')"
  run2="$(echo "$output" | jq -rc 'select(.id==9) | .result.content[0].text | fromjson | .result.run.id')"
  # 서로 다른 오퍼레이션의 run 핸들이 독립적으로 나온다(db=501·cache=601).
  [ "$run1" = "501" ]
  [ "$run2" = "601" ]
  # 각 핸들은 status 핸들 조회로 독립 확인 가능(같은 계약).
  mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"status\",\"arguments\":{\"run\":\"https://github.com/ukyi-app/homelab/actions/runs/501\"}}}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==10) | .result.content[0].text | fromjson | .result.mode')" = "run" ]
}

@test "explicit-path tools work identically from a different server cwd (no cwd inference)" {
  # 서버를 /tmp에서 띄워도 status 목록(그린필드)은 같다 — status root는 import.meta 기준(cwd 무관).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" bash -c \
    'cd /tmp && printf "%s\n" "$@" | "$0" '"$ROOT"'/tools/homelab.ts mcp' "$BUN" \
    '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"status","arguments":{}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==11) | .result.content[0].text | fromjson | .result.mode')" = "list" ]
  # secrets/init 스키마가 명시 경로를 요구한다(cwd 추론 없음).
  mcp_rpc '{"jsonrpc":"2.0","id":12,"method":"tools/list"}'
  [ "$(echo "$output" | jq -rc 'select(.id==12) | .result.tools[] | select(.name=="app_secrets") | .inputSchema.required | index("repoPath") != null')" = "true" ]
  [ "$(echo "$output" | jq -rc 'select(.id==12) | .result.tools[] | select(.name=="app_init") | .inputSchema.required | index("parentDir") != null')" = "true" ]
}

@test "the server is stateless: a fresh process handles the same calls after restart" {
  mcp_rpc '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"doctor","arguments":{}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==13) | .result.content[0].text | fromjson | .verb')" = "doctor" ]
  # 완전히 새 프로세스(재시작) — 같은 호출이 동일하게 동작한다.
  mcp_rpc '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"doctor","arguments":{}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==14) | .result.content[0].text | fromjson | .verb')" = "doctor" ]
}

@test "the url tool requires an explicit envDir and returns a schema-valid envelope without leaking the value (dry-run)" {
  ED="$BATS_TEST_TMPDIR/envdir"; mkdir -p "$ED"
  mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"dryRun\":true}}}"
  [ "$status" -eq 0 ]
  # release r1 a5: url tool도 다른 tool과 같은 envelope 계약을 낸다(raw text 아님).
  env="$(echo "$output" | jq -rc 'select(.id==15) | .result.content[0].text')"
  [ "$(echo "$env" | jq -r '.schema')" = "homelab-cli/1" ]
  [ "$(echo "$env" | jq -r '.verb')" = "db url" ]
  [ "$(echo "$env" | jq -r '.variant')" = "success" ]
  [ "$(echo "$env" | jq -r '.result.mode')" = "readonly" ]
  [ "$(echo "$env" | jq -r '.result.envKey')" = "MYDB_RO_DATABASE_URL" ]
  [ "$(echo "$env" | jq -r '.result.dryRun')" = "true" ]
  [ "$(echo "$env" | jq -r '.result.wrote')" = "false" ]
  [ "$(echo "$output" | jq -rc 'select(.id==15) | .result.isError')" = "false" ]
  # envelope이 스키마 계약을 만족한다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const errs = schemaErrors(JSON.parse(process.argv[1]), sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$env"
  echo "$output" | grep -q "^valid$"
  # release r1 a4=b2: envDir은 required — 생략하면 -32602(서버 cwd에 자격 기록 금지).
  mcp_rpc '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"db_url","arguments":{"name":"mydb","dryRun":true}}}'
  [ "$(echo "$output" | jq -rc 'select(.id==16) | .error.code')" = "-32602" ]
  echo "$output" | jq -rc 'select(.id==16) | .error.message' | grep -q "envDir"
  # url tool 스키마에 wait류 없음(동기 바운디드) + envDir required.
  mcp_rpc '{"jsonrpc":"2.0","id":17,"method":"tools/list"}'
  [ "$(echo "$output" | jq -rc 'select(.id==17) | .result.tools[] | select(.name=="db_url") | .inputSchema.required | index("envDir") != null')" = "true" ]
}

@test "omitting OR type-invalidating a required explicit path is refused server-side (no cwd fallback mutation)" {
  # 명시 경로(repoPath/parentDir)를 생략하거나(undefined) null/wrong-type/빈 문자열로 주면 서버가
  # -32602로 거부한다 — release r1 a3=b1: 존재만 검사하면 null/숫자가 통과해 str()에서 undefined로 접히고
  # cwd 폴백으로 서버 디렉토리에 변이가 나간다(신뢰 경계 우회). 타입 인식 검증이 이를 fail-closed로 막는다.
  mcp_rpc \
    '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"app_secrets","arguments":{"app":"myapp"}}}' \
    '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"app_init","arguments":{"app":"myapp","archetype":"api"}}}' \
    '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"app_secrets","arguments":{"app":"myapp","repoPath":null}}}' \
    '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"app_secrets","arguments":{"app":"myapp","repoPath":123}}}' \
    '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"app_init","arguments":{"app":"myapp","archetype":"api","parentDir":""}}}'
  [ "$status" -eq 0 ]
  # undefined·null·number·empty-string 전부 -32602.
  for i in 17 18 19 20 21; do
    [ "$(echo "$output" | jq -rc "select(.id==$i) | .error.code")" = "-32602" ]
  done
  echo "$output" | jq -rc 'select(.id==17) | .error.message' | grep -q "repoPath"
  echo "$output" | jq -rc 'select(.id==18) | .error.message' | grep -q "parentDir"
  # 어떤 변이도 서버 cwd(homelab 레포)를 대상으로 나가지 않았다 — 디스패치 argv 0건.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run update-secrets.yaml)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
}

@test "type-invalid OPTIONAL args are refused too (a string dryRun must not fold to a real write)" {
  # release r2-b1: required만 검사하면 optional dryRun:'true'(문자열)가 bool()에서 false로 접혀
  # 실제 자격 파일 쓰기(subprocess)를 실행한다. 전체 inputSchema 검증이 이를 -32602로 막는다.
  ED="$BATS_TEST_TMPDIR/ed2"; mkdir -p "$ED"
  mcp_rpc \
    "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"dryRun\":\"true\"}}}" \
    '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"db_create","arguments":{"name":"mydb","bogus":1}}}' \
    '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"cache_create","arguments":{"name":123}}}'
  [ "$status" -eq 0 ]
  # dryRun 문자열·미지 키·숫자 name 전부 -32602.
  for i in 30 31 32; do [ "$(echo "$output" | jq -rc "select(.id==$i) | .error.code")" = "-32602" ]; done
  # dryRun='true' 거부로 실제 쓰기 subprocess가 돌지 않았다(.env.local 미생성).
  [ ! -e "$ED/.env.local" ]
}

@test "the cache_url success envelope is schema-valid (plan host does not leak into urlResult)" {
  # release r2-a5: cache-url 계획은 host를 담는데 urlResult(additionalProperties:false)엔 없다 —
  # 구판은 자식 계획 JSON의 화이트리스트 복사로 지켰던 성질 — 지금은 엔진의 타입 결과
  # (UrlResult ↔ urlResult 1:1)가 host류 계획 전용 필드의 유입을 컴파일 타임에 차단한다(티켓 08).
  ED="$BATS_TEST_TMPDIR/ed3"; mkdir -p "$ED"
  mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"cache_url\",\"arguments\":{\"name\":\"mycache\",\"envDir\":\"$ED\",\"dryRun\":true}}}"
  [ "$status" -eq 0 ]
  env="$(echo "$output" | jq -rc 'select(.id==33) | .result.content[0].text')"
  [ "$(echo "$env" | jq -r '.verb')" = "cache url" ]
  [ "$(echo "$env" | jq -r '.variant')" = "success" ]
  # host는 결과에 새지 않는다(urlResult에 없음).
  [ "$(echo "$env" | jq -r '.result.host')" = "null" ]
  [ "$(echo "$env" | jq -r '.result.envKey')" = "MYCACHE_REDIS_RO_URL" ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const errs = schemaErrors(JSON.parse(process.argv[1]), sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$env"
  echo "$output" | grep -q "^valid$"
}

@test "an MCP mutation bounds run-appearance to a short deadline (no 20-minute block on a missing run)" {
  # release r2-a2/b3: identifyOnly라도 run '출현' 대기(step2)는 공유 deadline까지 폴링한다 — MCP는
  # 짧은 deadline(env 주입)으로 바운드하고, run 미출현이면 pending을 즉시 반환한다(status 재조회로 재개).
  # 매칭 run이 없는 스텁: 디스패처는 접수하나 nonce 에코 run이 목록에 없음 → 짧은 deadline에 pending.
  printf '[]\n' > "$FIX/db-runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    HOMELAB_MCP_DEADLINE_MS=150 HOMELAB_MCP_POLL_MS=20 \
    bash -c 'printf "%s\n" "$@" | "$0" tools/homelab.ts mcp' "$BUN" \
    '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"db_create","arguments":{"name":"mydb"}}}'
  [ "$status" -eq 0 ]
  env="$(echo "$output" | jq -rc 'select(.id==34) | .result.content[0].text')"
  [ "$(echo "$env" | jq -r '.variant')" = "pending" ]
  # run 미출현 pending(디스패치는 접수됨) — 20분이 아니라 짧은 deadline에 반환됐다.
  echo "$env" | jq -r '.result.pendingReason' | grep -q "run 미출현"
  [ "$(echo "$output" | jq -rc 'select(.id==34) | .result.isError')" = "false" ]
}

@test "a malformed (non-object) JSON-RPC line yields -32600 and does NOT kill the server" {
  # 유효 JSON이지만 오브젝트가 아닌 원시값 한 줄(42). in 연산자 TypeError로 서버가 죽으면 뒤 요청이 유실된다.
  mcp_rpc \
    '42' \
    '{"jsonrpc":"2.0","id":19,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  # 불량 라인은 Invalid Request(-32600), 그리고 뒤이은 tools/list는 정상 응답한다(서버 생존).
  [ "$(echo "$output" | jq -rc 'select(.error.code==-32600) | .error.code' | head -1)" = "-32600" ]
  [ "$(echo "$output" | jq -rc 'select(.id==19) | .result.tools | length')" = "9" ]
}

@test "the MCP tool set is exactly the non-destructive verbs (totality guard, floor asserts it exists)" {
  # verbs 카탈로그에서 파생한 노출 집합과 tools/list가 정확히 일치한다(파괴 누락·과노출 동시 차단).
  run bun -e '
    import { VERBS } from "./tools/lib/verbs.ts";
    const exposed = VERBS.filter((v) => v.destructive !== true).map((v) => v.path.join("_")).sort();
    const destructive = VERBS.filter((v) => v.destructive === true).map((v) => v.path.join("_"));
    if (destructive.length < 1) { console.error("파괴 동사가 하나도 없다 — teardown 표시 유실?"); process.exit(1); }
    console.log("exposed:" + exposed.join(",") + " destructive:" + destructive.join(","));
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "destructive:app_teardown"
  echo "$output" | grep -q "exposed:app_create,app_init,app_secrets,cache_create,cache_url,db_create,db_url,doctor,status"
}
