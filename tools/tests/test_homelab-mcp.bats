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
# mcp_rpc_at <entry> <lines...> — 진입 스크립트를 인자로 받는 형태(사본 트리 실행용). mcp_rpc는 현 트리 기본.
mcp_rpc_at() {
  local entry="$1"; shift
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c 'entry="$1"; shift; printf "%s\n" "$@" | "$0" "$entry" mcp' "$BUN" "$entry" "$@"
}
mcp_rpc() { mcp_rpc_at tools/homelab.ts "$@"; }

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
  # 실행 축(티켓 02): 경로 값을 준 tool을 **다른 cwd**에서 돌려도 결과가 같다(절대 경로) — 그리고 상대 경로는
  # 어느 cwd에서도 -32602라 서버 cwd 아래에 아무것도 만들지 않는다. 종전에는 required 여부만 재고 실행하지 않았다.
  ED="$BATS_TEST_TMPDIR/ed6"; mkdir -p "$ED"; SRV="$BATS_TEST_TMPDIR/srv"; mkdir -p "$SRV"
  REQ="{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"dryRun\":true}}}"
  mcp_rpc "$REQ"
  here="$(echo "$output" | jq -rc 'select(.id==13) | .result.content[0].text')"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" bash -c 'cd "$1" && printf "%s\n" "$3" | "$0" "$2" mcp' "$BUN" "$SRV" "$ROOT/tools/homelab.ts" "$REQ"
  [ "$status" -eq 0 ]
  there="$(echo "$output" | jq -rc 'select(.id==13) | .result.content[0].text')"
  [ -n "$here" ]
  [ "$here" = "$there" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" bash -c 'cd "$1" && printf "%s\n" "$3" "$4" | "$0" "$2" mcp' "$BUN" "$SRV" "$ROOT/tools/homelab.ts" \
    '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"db_url","arguments":{"name":"mydb","envDir":".","host":"100.99.0.1"}}}' \
    '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"app_init","arguments":{"app":"myapp","archetype":"api","parentDir":"apps"}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==14) | .error.code')" = "-32602" ]
  [ "$(echo "$output" | jq -rc 'select(.id==15) | .error.code')" = "-32602" ]
  [ ! -e "$SRV/.env.local" ]
  [ ! -e "$SRV/apps" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
}

# ── 경로 입력의 절대성·앱 레포 판정 fail-closed(homelab-cli-r2 티켓 02) ──────────────────────────
# owner 결정(2026-09-07): MCP app_secrets는 앱 레포만 받는다(존재하지 않거나 앱 레포가 아닌 명시 repoPath는
# 레포 밖이 아니라 **거부** — dispatch-only 폴백은 CLI 암묵 cwd 전용, 결과 스키마 enum은 유지). 틸드(~)는 서버가
# 확장하지 않고 안내 문구와 함께 거부한다(서버 HOME을 기준점으로 삼는 것 자체가 '서버 추론'이다).

mcp_rpc_in() {
  # 서버를 $1(cwd)에서 띄운다 — 상대 경로의 부수효과가 어디에 떨어지는지 재는 축.
  local dir="$1"; shift
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c 'dir="$1"; entry="$2"; shift 2; cd "$dir" && printf "%s\n" "$@" | "$0" "$entry" mcp' "$BUN" "$dir" "$ROOT/tools/homelab.ts" "$@"
}

@test "path-named string properties across the MCP tool schemas carry the absolute-path pattern and a description (roster, floor 4)" {
  mcp_rpc '{"jsonrpc":"2.0","id":70,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  # 손 열거 금지 — 이름이 Dir/Path로 끝나는 string 속성을 스키마에서 **전부** 뽑아 pattern ^/ 과 description을 잰다.
  # 다섯 번째 경로 필드가 술어 없이 추가되면 이 루프가 red다.
  rows="$(echo "$output" | jq -rc 'select(.id==70) | .result.tools[] | .name as $t | (.inputSchema.properties // {}) | to_entries[] | select(.key | test("(Dir|Path)$")) | select(.value.type=="string") | [$t, .key, (.value.pattern // "-"), ((.value.description // "") | length)] | @tsv')"
  n=0; bad=0
  while IFS=$'\t' read -r tool prop pat dlen; do
    [ -n "$tool" ] || continue
    n=$((n+1))
    [ "$pat" = "^/" ] || bad=$((bad+1))
    [ "${dlen:-0}" -gt 0 ] || bad=$((bad+1))
  done <<<"$rows"
  [ "$bad" -eq 0 ]
  # 바닥값: 오늘의 경로 속성은 repoPath·parentDir·envDir×2 = 4개(열거 붕괴 차단).
  [ "$n" -ge 4 ]
  # dispatchSecrets(경로지만 Dir/Path 접미가 아니다 — 죽은 옵션, 티켓 29)는 minLength·description만 맞춘다.
  [ "$(echo "$output" | jq -rc 'select(.id==70) | .result.tools[] | select(.name=="app_init") | .inputSchema.properties.dispatchSecrets.minLength')" = "1" ]
  # 계약 주석 한 구절 — mcp.ts가 '레포 밖이 아니라 거부'를 선언한다(산문 SSOT 갱신 증인).
  [ "$(grep -c "레포 밖이 아니라 거부" tools/lib/mcp.ts)" -ge 1 ]
}

@test "relative and tilde paths (. apps ~/apps) are refused as invalid params before any side effect, and the tilde message carries guidance" {
  SRV="$BATS_TEST_TMPDIR/srv2"; mkdir -p "$SRV"
  n=0
  for p in . apps '~/apps'; do
    mcp_rpc_in "$SRV" \
      "{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"tools/call\",\"params\":{\"name\":\"app_init\",\"arguments\":{\"app\":\"myapp\",\"archetype\":\"api\",\"parentDir\":\"$p\"}}}" \
      "{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"tools/call\",\"params\":{\"name\":\"app_secrets\",\"arguments\":{\"app\":\"myapp\",\"repoPath\":\"$p\"}}}" \
      "{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$p\",\"host\":\"100.99.0.1\"}}}"
    [ "$status" -eq 0 ]
    for i in 71 72 73; do
      [ "$(echo "$output" | jq -rc "select(.id==$i) | .error.code")" = "-32602" ]
      n=$((n+1))
    done
  done
  [ "$n" -eq 9 ]
  # 틸드 거부 문구는 안내를 담는다 — 절대 경로 예시 + '~'는 확장되지 않는다.
  echo "$output" | jq -rc 'select(.id==72) | .error.message' | grep -q "절대 경로"
  echo "$output" | jq -rc 'select(.id==72) | .error.message' | grep -q -- "~"
  # 부수효과 0 — 레포 생성·디스패치 argv 없음, 서버 cwd 아래에 자격 파일·apps·리터럴 ~ 디렉토리 없음.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ ! -e "$SRV/.env.local" ]
  [ ! -e "$SRV/apps" ]
  [ ! -e "$SRV/~" ]
  # 양성 대조 — 절대 envDir은 같은 tool을 지나 정상 착지한다(가드가 tool을 통째로 막지 않는다).
  ED="$BATS_TEST_TMPDIR/ed7"; mkdir -p "$ED"
  mcp_rpc_in "$SRV" "{\"jsonrpc\":\"2.0\",\"id\":74,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"host\":\"100.99.0.1\"}}}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==74) | .result.content[0].text | fromjson | .variant')" = "success" ]
  [ -f "$ED/.env.local" ]
}

@test "an explicit repoPath that is missing, a git repo without the app marker, or a plain directory is refused before dispatch; a real app repo dispatches (chain)" {
  OTHER="$BATS_TEST_TMPDIR/other-repo"; git init -q "$OTHER"
  PLAIN="$BATS_TEST_TMPDIR/plain"; mkdir -p "$PLAIN"
  n=0
  for p in "$BATS_TEST_TMPDIR/nope" "$OTHER" "$PLAIN"; do
    mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":75,\"method\":\"tools/call\",\"params\":{\"name\":\"app_secrets\",\"arguments\":{\"app\":\"myapp\",\"repoPath\":\"$p\"}}}"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -rc 'select(.id==75) | .result.isError')" = "true" ]
    env75="$(echo "$output" | jq -rc 'select(.id==75) | .result.content[0].text')"
    [ "$(echo "$env75" | jq -r '.variant')" = "failure" ]
    echo "$env75" | jq -r '.result.error' | grep -q "거부"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  # 거부 envelope도 계약(mutationRefused)에 적합하다.
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const errs = schemaErrors(JSON.parse(process.argv[1]), sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$env75"
  [ "$output" = "valid" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run update-secrets.yaml)" = "0" ]
  # 양성 대조 — 마커 + canonical remote 앱 레포는 chain으로 디스패치 1건(identifyOnly → pending 핸들).
  make_app_repo_fixture myapp
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    bash -c 'printf "%s\n" "$@" | "$0" tools/homelab.ts mcp' "$BUN" \
    "{\"jsonrpc\":\"2.0\",\"id\":76,\"method\":\"tools/call\",\"params\":{\"name\":\"app_secrets\",\"arguments\":{\"app\":\"myapp\",\"repoPath\":\"$APP_WORK\"}}}"
  [ "$status" -eq 0 ]
  env76="$(echo "$output" | jq -rc 'select(.id==76) | .result.content[0].text')"
  [ "$(echo "$env76" | jq -r '.result.chain.mode')" = "chain" ]
  [ "$(echo "$env76" | jq -r '.result.chain.pushed')" = "true" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run update-secrets.yaml)" = "1" ]
}

@test "a missing git binary on the server PATH refuses app_secrets (errKind not-found) instead of degrading to dispatch-only" {
  make_app_repo_fixture myapp
  NOGIT="$BATS_TEST_TMPDIR/stub-nogit"; mkdir -p "$NOGIT"
  for t in bun bash base64 cat gh kubectl kubeseal; do ln -s "$STUB/$t" "$NOGIT/$t"; done
  run --separate-stderr env PATH="$NOGIT" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    bash -c 'printf "%s\n" "$@" | "$0" tools/homelab.ts mcp' "$BUN" \
    "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{\"name\":\"app_secrets\",\"arguments\":{\"app\":\"myapp\",\"repoPath\":\"$APP_WORK\"}}}"
  [ "$status" -eq 0 ]
  env77="$(echo "$output" | jq -rc 'select(.id==77) | .result.content[0].text')"
  [ "$(echo "$env77" | jq -r '.variant')" = "failure" ]
  echo "$env77" | jq -r '.result.error' | grep -q "git"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
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
  # skip variant(kernel-followups 06): KUBECONFIG 없는 서버의 라이브 조회는 isError가 아니라
  # 구조화된 skip이다(x-contract.mcp.normalVariants) — 에이전트는 variant·wrote로 읽는다(마커는
  # 종료코드 채널의 보조물이라 MCP엔 없다). 기록이 없어야 한다.
  run --separate-stderr env PATH="$STUB" TS_DB_HOST=h HOMELAB_CORRELATION="$NONCE" \
    bash -c 'printf "%s\n" "$@" | "$0" tools/homelab.ts mcp' "$BUN" \
    "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\"}}}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==18) | .result.isError')" = "false" ]
  senv="$(echo "$output" | jq -rc 'select(.id==18) | .result.content[0].text')"
  [ "$(echo "$senv" | jq -r '.variant')" = "skip" ]
  [ "$(echo "$senv" | jq -r '.exitCode')" = "4" ]
  [ "$(echo "$senv" | jq -r '.result.wrote')" = "false" ]
  [ ! -f "$ED/.env.local" ]

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

@test "the app_init archetype enum is exactly platform ARCHETYPES (derivation parity, hand-pinned floor)" {
  # 두 입력 표면(init 엔진의 ARCHETYPES ↔ MCP inputSchema enum)이 순서까지 일치한다(cli-deepening 심화 6).
  run bun -e '
    const { ARCHETYPES } = await import(process.argv[1] + "/tools/lib/platform.ts");
    console.log(ARCHETYPES.join(","));
  ' "$ROOT"
  [ "$status" -eq 0 ]
  want="$output"
  # 손 앵커(floor) — SSOT가 비거나 축소돼도 동치 비교가 vacuous green이 되지 않게 4종을 리터럴로 핀한다.
  [ "$want" = "api,fullstack,site,worker" ]
  mcp_rpc '{"jsonrpc":"2.0","id":40,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  got="$(echo "$output" | jq -rc 'select(.id==40) | .result.tools[] | select(.name=="app_init") | .inputSchema.properties.archetype.enum | join(",")')"
  [ "$got" = "$want" ]
  # 리터럴 사본 소멸 — mcp.ts 소스에 아키타입 이름이 남아 있지 않다(파생의 정적 증거). 부정 카운트라
  # 같은 술어가 SSOT(platform.ts)에서는 매치함을 양성 대조로 함께 단언한다(검출기 생존 증명).
  [ "$(grep -c '"fullstack"' tools/lib/platform.ts)" -ge 1 ]
  [ "$(grep -c '"fullstack"' tools/lib/mcp.ts)" = "0" ]
}

@test "an archetype added to the SSOT alone is accepted by MCP (mutation discriminability, mcp.ts untouched)" {
  # 대조군(현 트리): 미지 아키타입은 입력 검증에서 -32602(엔진에 닿지 않는다).
  ARGS='{"app":"myapp","archetype":"hexagon","parentDir":"'"$BATS_TEST_TMPDIR"'","dispatchSecrets":"'"$BATS_TEST_TMPDIR"'/nonexistent"}'
  mcp_rpc '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"app_init","arguments":'"$ARGS"'}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==41) | .error.code')" = "-32602" ]
  # 사본 트리(lib + 진입점 + 생성기 + 계약 JSON): cp 그대로이고 platform.ts의 ARCHETYPES 줄 끝에만 "hexagon"을
  # 덧붙인다(mcp.ts·생성기는 축자 사본 — 변이 파일은 sed로 생성한 그 하나뿐). node_modules는 심링크로 공유한다 — 없으면 bun이 lockfile 밖 auto-install로
  # 통과해 venue 의존 초록이 된다. sed 치환 불발은 vacuous라 grep으로 증명한다.
  T="$BATS_TEST_TMPDIR/ext"; mkdir -p "$T/tools"
  cp -R tools/lib "$T/tools/lib"; cp tools/homelab.ts tools/generate-result-schema.ts tools/*.json "$T/tools/"
  ln -s "$ROOT/node_modules" "$T/node_modules"
  sed 's|^\(export const ARCHETYPES = \[.*\)\] as const;|\1, "hexagon"] as const;|' tools/lib/platform.ts > "$T/tools/lib/platform.ts"
  grep -q '^export const ARCHETYPES = .*"hexagon"\] as const;' "$T/tools/lib/platform.ts"
  # 결과 계약도 같은 SSOT에서 재생성한다 — 입력 표면(MCP enum)과 결과 표면(initFailure enum)이 함께 확장돼야
  # "아키타입 추가 시 자동 수용"이 envelope까지 성립한다.
  run bun "$T/tools/generate-result-schema.ts" --write
  [ "$status" -eq 0 ]
  # dispatchSecrets 부재 경로 → 엔진이 preflight에서 부수효과 0으로 실패한다(결정적·스텁 무관) — 여기서
  # 단언하는 것은 체인 결과가 아니라 "입력 표면이 hexagon을 통과시켜 엔진까지 닿았다"는 사실이다.
  mcp_rpc_at "$T/tools/homelab.ts" \
    '{"jsonrpc":"2.0","id":42,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"app_init","arguments":'"$ARGS"'}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==42) | .result.tools[] | select(.name=="app_init") | .inputSchema.properties.archetype.enum | index("hexagon") != null')" = "true" ]
  [ "$(echo "$output" | jq -rc 'select(.id==43) | has("error")')" = "false" ]
  env43="$(echo "$output" | jq -rc 'select(.id==43) | .result.content[0].text')"
  [ "$(echo "$env43" | jq -r '.verb')" = "app init" ]
  [ "$(echo "$env43" | jq -r '.variant')" = "failure" ]
  # lib-a-1 — mcpIsError가 실패 variant를 실제로 에러로 매핑하는지 여기서 처음 확인한다(이 파일의
  # isError 단언 6곳은 전부 "false"뿐이었다 — 실패 경로를 실제로 유발하는 이 픽스처가 유일한 자리).
  [ "$(echo "$output" | jq -rc 'select(.id==43) | .result.isError')" = "true" ]
  [ "$(echo "$env43" | jq -r '.result.checkpoint')" = "preflight" ]
  [ "$(echo "$env43" | jq -r '.result.archetype')" = "hexagon" ]
  # hexagon envelope이 재생성된 결과 계약(사본 트리)에 적합하다 — 두 표면이 한 SSOT에서 함께 확장됐다는 증명.
  run bun -e '
    const root = process.argv[2];
    const { schemaErrors } = await import(root + "/tools/lib/schema-check.ts");
    const { readFileSync } = await import("node:fs");
    const sch = JSON.parse(readFileSync(root + "/tools/cli-result-schema.json", "utf8"));
    const errs = schemaErrors(JSON.parse(process.argv[1]), sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$env43" "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
  # 부수효과 0 — 레포 생성 호출이 원장에 없다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
}

@test "a url tool host carrying a newline is refused as invalid params before any cluster read (shared host predicate)" {
  # 티켓 03 — host 술어는 dbUrlInputError 한 곳(CLI usage·MCP -32602·bin)이 소유한다. 개행 host는 .env 행 주입이다.
  ED="$BATS_TEST_TMPDIR/ed4"; mkdir -p "$ED"
  mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":60,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"host\":\"100.99.0.1\\nINJECTED=evil\"}}}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==60) | .error.code')" = "-32602" ]
  [ ! -e "$ED/.env.local" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
  # 양성 대조 — 정당한 host는 같은 술어를 지나 자격 파일을 기록한다(가드가 url tool을 통째로 막지 않는다).
  mcp_rpc "{\"jsonrpc\":\"2.0\",\"id\":61,\"method\":\"tools/call\",\"params\":{\"name\":\"db_url\",\"arguments\":{\"name\":\"mydb\",\"envDir\":\"$ED\",\"host\":\"100.99.0.1\"}}}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==61) | .result.content[0].text | fromjson | .variant')" = "success" ]
  grep -q '^MYDB_RO_DATABASE_URL=postgres://u:p@100.99.0.1:5432/db$' "$ED/.env.local"
}

@test "a traversal-shaped status app is refused as invalid params (CLI and MCP share one predicate)" {
  # MCP 표면은 LLM 에이전트 입력을 그대로 받는다 — inputSchema에 pattern을 덧붙이는 대신(두 번째
  # 진실 금지) statusInputError 한 곳이 두 표면을 함께 닫는다는 것을 실제로 밟는다.
  mcp_rpc '{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"status","arguments":{"app":"../x"}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==50) | .error.code')" = "-32602" ]
  # 대조군 — 유효한 이름은 같은 술어를 지나 envelope으로 응답한다(가드가 status를 통째로 막지 않는다).
  mcp_rpc '{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"status","arguments":{"app":"page"}}}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -rc 'select(.id==51) | has("error")')" = "false" ]
}

# ── 대기 데드라인 인용의 정합(homelab-cli-r2 티켓 10) ────────────────────────────────────────

@test "the deadline quoted in mcp.ts is derived from WAIT_DEFAULTS, never a stale hand copy" {
  # MCP는 CLI 기본 deadline을 물려받지 않고 짧은 값을 명시한다 — 그 이유를 적은 주석이 상수와
  # 어긋나면 운영자가 서버 블로킹 상한을 잘못 읽는다. 손 앵커가 아니라 상수에서 유도해 대조한다.
  mins="$(bun -e 'import { WAIT_DEFAULTS } from "./tools/lib/mutation.ts"; console.log(WAIT_DEFAULTS.deadlineMs / 60000);')"
  [ -n "$mins" ]   # 바닥값 — 빈 문자열이면 아래 grep이 전부 매치해 공허해진다
  [ "$(grep -c "WAIT_DEFAULTS.deadlineMs = ${mins}분" tools/lib/mcp.ts)" = "1" ]
  # 양성 대조(검출기 생존) — 어긋난 값은 같은 grep에서 0건이다.
  [ "$(grep -c "WAIT_DEFAULTS.deadlineMs = $((mins + 1))분" tools/lib/mcp.ts)" = "0" ]
}
