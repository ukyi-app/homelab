#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# 구 단일 디스패처 전용 테스트(삭제됨)의 단언을 4 디스패처로 일반화.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)
#
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 워크플로 **파일**이라 그것으로 닫힌다.
#    반면 루프 구동 자리(DISPATCHERS·글롭)는 반복 0회가 어떤 rc로도 안 보이므로, setup의 열거
#    바닥값과 각 @test의 양성 대조가 한 쌍으로 닫는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  # 디스패처 목록 동적 파생 — 하드코딩 열거는 신규 디스패처를 조용히 빠뜨린다(fail-open, arch-meta finding).
  # 규칙: workflow_dispatch 보유 + 동명 reusable(uses: ./.github/workflows/_<self>.yaml) 참조.
  DISPATCHERS=""; DISPATCHER_N=0
  for f in "$WF"/*.yaml; do
    base="$(basename "$f" .yaml)"
    case "$base" in _*) continue;; esac
    grep -q 'workflow_dispatch:' "$f" || continue
    grep -q "uses: ./.github/workflows/_${base}.yaml" "$f" || continue
    DISPATCHERS="$DISPATCHERS $base"; DISPATCHER_N=$((DISPATCHER_N + 1))
  done
  # 열거 바닥값 — WF가 리네임되면 글롭이 리터럴로 남아 파생이 0건이 되고, 아래 루프 구동 @test들이
  # 반복 0회로 조용히 초록이 된다. setup에 두어 **개별 @test 실행에서도** 닫는다.
  # 5는 이 파일이 이미 소유한 레인 수다(아래 known five 열거 · bun 디스패처 붕괴 하한 · LANES 행 수)
  # — 손으로 관리하는 새 수치가 아니다.
  [ -d "$WF" ]
  [ -n "$DISPATCHERS" ]
  [ "$DISPATCHER_N" -ge 5 ]
}

@test "every dispatcher serializes via homelab-mutation group with queue max" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"; [ -f "$f" ]
    grep -q "group: homelab-mutation" "$f"
    grep -q "queue: max" "$f"
    grep -q "cancel-in-progress: false" "$f"
  done
}

@test "no workflow combines queue:max with cancel-in-progress:true" {
  hits=0
  for f in "$WF"/*.yaml; do
    if grep -q "queue: max" "$f"; then
      hits=$((hits + 1))
      run grep -q "cancel-in-progress: true" "$f"; [ "$status" -eq 1 ]
    fi
  done
  # 양성 대조 — 루프 조건(`queue: max`)이 어디선가 참이었다. 조건이 전수 거짓이면 반복 0회라
  # 위 단언이 한 번도 평가되지 않는데 그것은 rc에 안 보인다(setup의 열거 바닥값과 한 쌍).
  [ "$hits" -ge 1 ]
}

@test "create-app dispatcher grants packages:read on the reusable call job" {
  grep -q "packages: read" "$WF/create-app.yaml"
}

@test "each dispatcher validates with fixed action then routes to its reusable" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q "validate-mutation.ts --action $d" "$f"
    grep -q "needs: validate" "$f"
    grep -q "uses: ./.github/workflows/_$d.yaml" "$f"
  done
}

@test "each dispatcher triggers only on workflow_dispatch (homelab-initiated boundary)" {
  # 양성 대조 — 같은 술어가 같은 트리 어딘가에서는 매치한다(push/schedule 구동 워크플로가 실재).
  # 술어 쪽이 부패하면 디스패처 전수 무매치가 정당한 결과처럼 보이는데, 이 줄이 먼저 red다.
  run grep -rlE "repository_dispatch|pull_request:|push:|schedule:" "$WF"
  [ "$status" -eq 0 ]
  for d in $DISPATCHERS; do
    run grep -E "repository_dispatch|pull_request:|push:|schedule:" "$WF/$d.yaml"
    [ "$status" -eq 1 ]
  done
}

@test "each dispatcher references inputs only via env or with: (no run inline interpolation)" {
  for d in $DISPATCHERS; do
    bad=$(grep -n 'github.event.inputs' "$WF/$d.yaml" \
      | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(sha|spec|app|confirm):)' || true)
    [ -z "$bad" ]
  done
}

@test "each dispatcher declares only its contract inputs" {
  # create-app/update-secrets는 app만(repo=ukyi-app/<app>·sha는 reusable이 main HEAD에서 해석 — 입력 없음).
  grep -q "app:" "$WF/create-app.yaml";     run grep -q "app_repo:" "$WF/create-app.yaml";     [ "$status" -eq 1 ]
  grep -q "app:" "$WF/update-secrets.yaml"; run grep -q "app_repo:" "$WF/update-secrets.yaml"; [ "$status" -eq 1 ]
  grep -q "spec:" "$WF/create-database.yaml"
  grep -q "spec:" "$WF/create-cache.yaml"
}

@test "create-app and update-secrets no longer reference app_repo anywhere (org is structurally ukyi-app)" {
  # 단일 결정 단언(bats는 마지막 명령만 평가) — 4 파일 어디에도 app_repo가 없어야 한다.
  # 형제 양성 단언이 없어 `-eq 1`이 파일 실재의 유일한 증인이다(넷 중 하나만 사라져도 rc 2).
  run grep -l "app_repo" "$WF/create-app.yaml" "$WF/_create-app.yaml" "$WF/update-secrets.yaml" "$WF/_update-secrets.yaml"
  [ "$status" -eq 1 ]
}

@test "each dispatcher notify fires on cancelled as well as failure" {
  for d in $DISPATCHERS; do
    run grep -nE "if:\s*failure\(\)\s*\|\|\s*cancelled\(\)" "$WF/$d.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "dynamic DISPATCHERS derivation is non-empty and includes the known five" {
  [ -n "$DISPATCHERS" ]
  for d in create-app update-secrets create-database create-cache teardown-app; do
    case " $DISPATCHERS " in *" $d "*) : ;; *) false ;; esac
  done
}

@test "each dispatcher notify delegates to the mutation-notify composite" {
  # 양성 대조 — job.status 직접 참조 술어가 같은 트리 어딘가(reusable·이벤트 구동 워크플로)에서는
  # 매치한다. 표기가 바뀌어 술어가 죽으면 디스패처 전수 무매치가 정당해 보이는데, 이 줄이 먼저 red다.
  run grep -rlE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$WF"
  [ "$status" -eq 0 ]
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q 'uses: ./.github/actions/mutation-notify' "$f"
    run grep -nE 'results:[[:space:]]*\$\{\{[[:space:]]*toJSON\(needs\)' "$f"; [ "$status" -eq 0 ]
    # norm 로직은 composite로 이동 — 디스패처엔 job.status 직접 참조가 없어야 한다
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$f"; [ "$status" -eq 1 ]
  done
}

@test "mutation-notify composite normalizes cancelled over failure and labels the mutation source" {
  a="$ROOT/.github/actions/mutation-notify/action.yml"
  [ -f "$a" ]
  grep -q 'status=cancelled' "$a"
  grep -q 'source: 변이' "$a"
}

@test "dispatcher rejects a reserved db name before the executor" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"postgres\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a cache -ro suffix name" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-cache --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a db -ro suffix name (F8)" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}

@test "teardown-app dispatcher declares only app and confirm inputs (no app_repo)" {
  grep -q "app:" "$WF/teardown-app.yaml"
  grep -q "confirm:" "$WF/teardown-app.yaml"
  run grep -q "app_repo:" "$WF/teardown-app.yaml"; [ "$status" -eq 1 ]
}

@test "teardown-app reusable uses writer token only (no reader, no GHCR)" {
  grep -q "HOMELAB_WRITER_APP_ID" "$WF/_teardown-app.yaml"
  run grep -q "HOMELAB_READER_APP_ID" "$WF/_teardown-app.yaml"; [ "$status" -eq 1 ]
}

@test "teardown-app reusable enforces confirm at its boundary (workflow_call input + re-validate)" {
  grep -q "confirm:" "$WF/_teardown-app.yaml"                                  # workflow_call에 confirm 입력
  grep -q "validate-mutation.ts --action teardown-app" "$WF/_teardown-app.yaml" # teardown 前 재검증(defense-in-depth)
}

@test "teardown-app reusable does NOT auto-merge (destruction = manual merge)" {
  # 주석 제외 후 실행 라인만 검사 — 워크플로 주석에 'auto-merge-or-fail' 설명 문구가 있어 그대로 grep하면 오탐
  # ⚠️ 파이프 종단 grep이라 rc로는 못 닫는다 — 대상이 사라지면 앞 grep만 rc 2로 죽고 뒤 grep은 빈
  #    stdin에 무매치 rc 1을 내므로 `-eq 1` 전환조차 통과한다(SSOT ③-b · 2026-08-29 이 파일로 실측).
  #    파괴 경계의 불변식이 대상 리네임에 침묵 초록이면 안 되므로 실재를 먼저 못 박는다.
  [ -f "$WF/_teardown-app.yaml" ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -q 'auto-merge-or-fail'"; [ "$status" -ne 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -qE 'gh pr merge.*--auto'"; [ "$status" -ne 0 ]
}

@test "every mutation reusable routes its PR through the pr-first-commit composite" {
  for wf in _create-app _create-database _create-cache _update-secrets _teardown-app; do
    grep -q 'uses: ./.github/actions/pr-first-commit' "$WF/$wf.yaml"
  done
}

@test "auto-merge policy is preserved per reusable (db/cache/secrets=true, app/teardown=false)" {
  for wf in _create-database _create-cache _update-secrets; do
    grep -qE "auto-merge:[[:space:]]*'true'" "$WF/$wf.yaml"
  done
  for wf in _create-app _teardown-app; do
    grep -qE "auto-merge:[[:space:]]*'false'" "$WF/$wf.yaml"
  done
}

@test "the bot commit identity lives only in the pr-first-commit composite (no 5x literal copies)" {
  a="$ROOT/.github/actions/pr-first-commit/action.yml"
  grep -q 'ukyi-homelab-writer\[bot\]' "$a"
  # 다중 피연산자 — 다섯 중 하나라도 리네임되면 rc 2다. 위 양성 단언은 composite 파일이라
  # 이 다섯의 실재를 증언하지 않는다.
  run grep -l '293311924+ukyi-homelab-writer' "$WF"/_create-app.yaml "$WF"/_create-database.yaml "$WF"/_create-cache.yaml "$WF"/_update-secrets.yaml "$WF"/_teardown-app.yaml
  [ "$status" -eq 1 ]
}

@test "reusables carry no inline RESOURCE_NAME_RE copy (identity.ts SSOT via validate-mutation)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' "$WF/$wf.yaml"; [ "$status" -eq 1 ]
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}

@test "every mutation reusable re-validates via validate-mutation at its boundary (symmetric defense-in-depth)" {
  for wf in _create-app _update-secrets _create-database _create-cache _teardown-app; do
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}

@test "every workflow_dispatch entrypoint is actor-guarded or explicitly allowlisted" {
  # 동적 열거(P2-1): 하드코딩 목록이 아니라 dispatch 보유 전수를 스캔 — 신규 워크플로 자동 편입(fail-open 차단).
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const dir = process.argv[1] + "/.github/workflows";
    const ALLOW = new Set(["bump-poll.yaml"]); // 자체 fail-closed 검증기 — 디스패치 자격의 의도된 유일 표적
    const bad = [];
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ya?ml$/.test(f)) continue;
      const src = fs.readFileSync(dir + "/" + f, "utf8");
      const doc = y.parse(src);
      const on = doc?.on ?? doc?.[true];   // 일부 YAML 파서의 on→true 키 함정 방어
      const hasDispatch = !!on && typeof on === "object" && Object.prototype.hasOwnProperty.call(on, "workflow_dispatch");
      if (!hasDispatch || ALLOW.has(f)) continue;
      // 재료 3개의 **존재**만 보면 술어가 틀려도 초록이다(실측: `=`→`!=`가 통과했다) — 위 개수
      // 등식과 아래 실행 증인이 그 축을 닫는다. 여기서는 거부 문구를 **닫힌 열거**로 못박는다:
      // 오늘 두 변종이 있고(수동 진입 / 변이), 세 번째는 규약 결정이지 조용히 늘 것이 아니다.
      const REJECT = ["workflow_dispatch는 owner(", "변이 디스패처는 owner("];
      const guarded = src.includes("vars.HOMELAB_OWNER") && src.includes("github.actor")
        && src.includes("HOMELAB_OWNER 미설정") && REJECT.some((m) => src.includes(m));
      if (!guarded) bad.push(f + ": workflow_dispatch 진입점에 actor 가드 부재(허용목록 아님)");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$ROOT"
  [ "$status" -eq 0 ]
}

@test "bump-poll stays allowlisted WITHOUT the actor guard (intended dispatch target)" {
  # 이 @test에는 형제 단언이 없다 — `-ne 0`이면 bump-poll.yaml 리네임에도 홀로 초록으로 남는다.
  run grep -q 'HOMELAB_OWNER' "$WF/bump-poll.yaml"; [ "$status" -eq 1 ]
}

@test "reusable branch: lines match the lane rows' neutral patterns (TS-YAML parity)" {
  # 레인 신원 parity 축 1(cli-deepening 심화 2): YAML 쪽 branch: 개명은 어떤 테스트도 red가
  # 아니었다 — 이 가드가 그 방향을 CI로 당긴다. 값은 YAML 파서로 읽는다(따옴표·주석 재포맷에
  # 흔들리지 않고, 축 2와 같은 venue). key 표현식은 레인별 **열거 매핑**(가드 소유 — 설계 심화 2
  # "정규화 매핑은 가드 쪽")으로 기대 문자열을 조립해 정확 대조한다 — 포괄 ${{…}}→{key} 붕괴는
  # 오타 표현식(inputs.applicaton)도 green으로 접는 fail-open이다(리뷰 실측). 경로는 $ROOT 절대
  # (cwd 의존은 venue가 갈리면 로컬이 CI를 예고하지 못한다). 5는 레인 수 손 앵커다.
  run bun -e '
    const root = process.argv[1];
    const { parse } = require("yaml");
    const { readFileSync } = require("node:fs");
    const { LANES, fillLanePattern } = await import(root + "/tools/lib/catalog-rows.ts");
    const KEY_EXPR = {
      "create-database": "steps.spec.outputs.name",
      "create-cache": "steps.spec.outputs.name",
      "create-app": "steps.img.outputs.app",
      "update-secrets": "inputs.app",
      "teardown-app": "inputs.app",
    };
    const collect = (node, out) => {
      if (Array.isArray(node)) { for (const v of node) collect(v, out); return; }
      if (node && typeof node === "object") {
        for (const k of Object.keys(node)) {
          if (k === "branch" && typeof node[k] === "string") out.push(node[k]);
          else collect(node[k], out);
        }
      }
    };
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      const doc = parse(readFileSync(root + "/.github/workflows/" + row.reusable, "utf8"));
      const got = [];
      collect(doc, got);
      if (got.length !== 1) { bad.push(row.reusable + ": branch 값 " + got.length + "개(정확히 1 기대)"); continue; }
      const want = fillLanePattern(row.branchPattern, { key: "${{ " + KEY_EXPR[row.action] + " }}", runId: "${{ github.run_id }}" });
      const normed = got[0].replace(/\s+/g, " ").trim();
      if (normed !== want) { bad.push(row.reusable + ": " + normed + " != " + want); continue; }
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "dispatcher workflow_dispatch inputs equal the lane row inputs plus correlation" {
  # 레인 신원 parity 축 2: 디스패치 입력 이름의 양끝(행 ↔ 디스패처 YAML) 집합 동치.
  # 경로는 $ROOT 절대(venue 비의존). 5는 레인 수 손 앵커.
  run bun -e '
    const root = process.argv[1];
    const { parse } = require("yaml");
    const { readFileSync } = require("node:fs");
    const { LANES } = await import(root + "/tools/lib/catalog-rows.ts");
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      const doc = parse(readFileSync(root + "/.github/workflows/" + row.workflow, "utf8"));
      const on = doc?.on ?? doc?.[true]; // YAML 1.1 on→true 키 함정 방어
      const got = Object.keys(on?.workflow_dispatch?.inputs ?? {}).sort();
      const want = [...row.inputs, "correlation"].sort();
      if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(row.workflow + ": " + JSON.stringify(got) + " != " + JSON.stringify(want));
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "lane row inputs match validate-mutation CONTRACT: pass-through equality and the spec layer pin" {
  # 레인 신원 parity 축 3(Q7 참조·대조 — validate-mutation은 무변경 서버 끝 선언으로 남는다).
  # 패스스루 레인은 행 inputs == required. 조립 레인(create-database/create-cache)은 디스패처가
  # 입력을 spec으로 조립하므로 검증기는 조립 후 계층을 본다(설계 게이트 r1 아티팩트의 검증 노트가
  # 수용한 계층 구분 — design.md 본문이 아니라 design-r1.json notes가 출처인 구현 결정이다).
  # 그 경계의 양쪽을 각각 핀한다: ① required == ["spec"], ② validateSpec 허용 필드 리터럴 핀
  # (db) / 행 inputs 동치(cache), ③ 행 inputs 전부를 디스패처 조립이 실제로 소비.
  # CONTRACT/OPTIONAL 키는 전량 리터럴 핀 — 개수 핀만으로는 회귀 앵커 행 개명이 통과한다.
  run bun -e '
    const root = process.argv[1];
    const { readFileSync } = require("node:fs");
    const { LANES } = await import(root + "/tools/lib/catalog-rows.ts");
    const src = readFileSync(root + "/tools/validate-mutation.ts", "utf8");
    const block = (name) => {
      const i = src.indexOf("const " + name);
      const j = src.indexOf("};", i);
      if (i < 0 || j < 0) { console.error(name + " 블록 없음"); process.exit(1); }
      return src.slice(i, j);
    };
    const rows = (text) => {
      const out = {};
      for (const m of text.matchAll(/^\s*"?([a-z-]+)"?:\s*\[([^\]]*)\]/gm)) {
        out[m[1]] = m[2].split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter((s) => s !== "");
      }
      return out;
    };
    const contract = rows(block("CONTRACT"));
    const optional = rows(block("OPTIONAL"));
    const wantContractKeys = ["activate-app", "audit", "create-app", "create-cache", "create-database", "teardown-app", "teardown-resource", "update-secrets"];
    const wantOptionalKeys = ["create-app", "create-cache", "create-database", "teardown-app", "update-secrets"];
    if (JSON.stringify(Object.keys(contract).sort()) !== JSON.stringify(wantContractKeys)) { console.error("CONTRACT 키 전량 핀 어긋남: " + Object.keys(contract).sort().join(",")); process.exit(1); }
    if (JSON.stringify(Object.keys(optional).sort()) !== JSON.stringify(wantOptionalKeys)) { console.error("OPTIONAL 키 전량 핀 어긋남: " + Object.keys(optional).sort().join(",")); process.exit(1); }
    const am = src.match(/const allowed = action === "create-database" \? \[([^\]]*)\] : \[([^\]]*)\]/);
    if (!am) { console.error("validateSpec allowed 추출 실패"); process.exit(1); }
    const list = (s) => s.split(",").map((x) => x.trim().replace(/^"|"$/g, "")).filter((x) => x !== "");
    if (JSON.stringify(list(am[1])) !== JSON.stringify(["name", "owner", "extensions"])) { console.error("db spec 허용 필드 핀 어긋남: " + am[1]); process.exit(1); }
    if (JSON.stringify(list(am[2]).sort()) !== JSON.stringify([...LANES["create-cache"].inputs].sort())) { console.error("cache spec 허용 필드가 행 inputs와 다르다: " + am[2]); process.exit(1); }
    const bad = [];
    let n = 0;
    for (const row of Object.values(LANES)) {
      if ((optional[row.action] ?? []).join(",") !== "correlation") bad.push(row.action + ": OPTIONAL != [correlation]");
      const required = contract[row.action] ?? [];
      if (row.action === "create-database" || row.action === "create-cache") {
        if (JSON.stringify(required) !== JSON.stringify(["spec"])) bad.push(row.action + ": spec 계층 핀 어긋남 — " + JSON.stringify(required));
        const wf = readFileSync(root + "/.github/workflows/" + row.workflow, "utf8");
        for (const i of row.inputs) if (wf.indexOf("inputs." + i) < 0) bad.push(row.workflow + ": 조립이 inputs." + i + "를 소비하지 않는다");
      } else if (JSON.stringify([...required].sort()) !== JSON.stringify([...row.inputs].sort())) {
        bad.push(row.action + ": " + JSON.stringify(required) + " != " + JSON.stringify(row.inputs));
      }
      n++;
    }
    if (n !== 5 || bad.length) { console.error(bad.join("\n") || ("레인 수 " + n + " != 5")); process.exit(1); }
    console.log("ok:" + n);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "each dispatcher declares an optional correlation input echoed into run-name (web-UI compat by definition)" {
  # 하위호환의 정의상 증명: required 아님 + 기본값 빈 문자열 + run-name은 빈값에서 바이트 동일(조건부 에코).
  run bun -e '
    const y = require("yaml"), fs = require("fs");
    const wf = process.argv[1];
    const dispatchers = process.argv.slice(2);
    if (dispatchers.length < 5) { console.error("dispatcher 열거 붕괴: " + dispatchers.length); process.exit(1); }
    const bad = [];
    for (const d of dispatchers) {
      const src = fs.readFileSync(wf + "/" + d + ".yaml", "utf8");
      const doc = y.parse(src);
      const on = doc?.on ?? doc?.[true];   // 일부 YAML 파서의 on→true 키 함정 방어
      const inp = on?.workflow_dispatch?.inputs?.correlation;
      if (!inp) { bad.push(d + ": correlation 입력 부재"); continue; }
      if (inp.required === true) bad.push(d + ": correlation이 required — 웹 UI 하위호환 위반");
      if (inp.default !== "") bad.push(d + ": correlation 기본값이 빈 문자열이 아니다");
      const rn = String(doc["run-name"] ?? "");
      if (!rn.includes("inputs.correlation != '\''") || !rn.includes("format(")) bad.push(d + ": run-name이 correlation을 조건부 에코하지 않는다");
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$WF" $DISPATCHERS
  [ "$status" -eq 0 ]
}

@test "the actor predicate copies are counted (a deleted or flipped copy is red)" {
  # 아래 로스터 판정은 술어의 **텍스트 존재**만 본다 — 그래서 `=`를 `!=`로 뒤집어도 초록이었다
  # (2026-08 실측). 이 등식이 그 우회의 절반을 닫는다: 사본이 사라지거나 비교가 뒤집히면 수가 어긋난다.
  # 나머지 절반은 아래 **실행 증인**이 닫는다 — 개수만으로는 "뒤집고 하나 더 추가"를 못 잡는다.
  # 수치는 콜사이트가 소유한다(CONTEXT.md 「열거 바닥값」) — 도메인이 줄지 않는 한 손대지 않는다.
  pred="$(grep -rhoF '[ "$ACTOR" = "$OWNER" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$pred" -ge 15 ]
  # 빈 owner fail-closed(vacuous 방지)는 술어와 **같은 수**로 존재해야 한다 — 한쪽만 남으면
  # 변수 미설정이 곧 통과가 된다.
  # 빈 owner fail-closed는 **모든** 가드 스텝에 있어야 한다(dispatch 가드 + replay 전용 가드).
  empty="$(grep -rhoF '[ -n "$OWNER" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$empty" -ge 15 ]
  # 정본 본문은 축이 셋이고 **셋 다 같은 수**여야 한다. 하나만 빠져도 그 축이 조용히 다시 열린다.
  #   ① 재실행 축   — 이벤트를 보지 않는다(github.run_attempt).
  #   ② 트리거 축   — 종전 `if:` 한정을 본문으로 옮긴 것. `if:`로 두면 재실행에서 스텝이 skip된다.
  #   ③ dispatch 축 — actor와 개시자 둘 다 owner여야 한다(actor는 재실행에서 보존된다).
  replay="$(grep -rhoF '[ "$ATTEMPT" = "1" ] ||' "$WF"/*.yaml | wc -l | tr -d ' ')"
  gate="$(grep -rhoF '[ "$EVENT" = "workflow_dispatch" ] || exit 0' "$WF"/*.yaml | wc -l | tr -d ' ')"
  init="$(grep -rhoF '재실행 개시자=$TRIGGERING 거부' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$replay" -ge 15 ]
  # 재실행 절은 dispatch 가드 15 + 이벤트 구동 잡의 replay 전용 가드에 붙는다. 등식으로 못을 박아야
  # 한쪽에서 사라진 것이 다른 쪽 증가로 가려지지 않는다.
  evt="$(grep -rhoF 'replay 가드 (이벤트 구동 잡' "$WF"/*.yaml | wc -l | tr -d ' ')"
  [ "$evt" -ge 2 ]
  [ "$replay" -eq "$((pred + evt))" ]
  [ "$empty" -eq "$replay" ]
  [ "$pred" -eq "$gate" ]
  [ "$pred" -eq "$init" ]
  # 가드 스텝에 `if:`가 남아 있으면 안 된다 — 그것이 재실행 축을 무력화하는 정확한 형태다.
  [ "$(grep -rhcF "if: github.event_name == 'workflow_dispatch'" "$WF"/*.yaml | paste -sd+ - | bc)" -eq 0 ]
  # env 바인딩도 같은 수 — 술어만 있고 바인딩이 없으면 빈 문자열 비교로 **전 디스패치가 잠긴다**.
  # ATTEMPT/TRIGGERING은 **모든** 가드 스텝이 바인딩한다 — replay 총계와 등식이어야 한다.
  # (`-ge pred`로 두면 replay 전용 가드 2건이 여유가 되어 dispatch 가드 하나의 누락을 가린다.)
  for k in 'ATTEMPT: ${{ github.run_attempt }}' 'TRIGGERING: ${{ github.triggering_actor }}'; do
    b="$(grep -rhoF "$k" "$WF"/*.yaml | wc -l | tr -d ' ')"
    [ "$b" -eq "$replay" ]
  done
  # EVENT는 트리거 축을 가진 dispatch 가드만 바인딩한다.
  [ "$(grep -rhoF 'EVENT: ${{ github.event_name }}' "$WF"/*.yaml | wc -l | tr -d ' ')" -ge "$pred" ]
}

@test "every actor guard predicate actually executes and decides correctly (the predicate gets a witness)" {
  # 이 술어는 지금까지 **한 번도 실행된 적이 없었다** — 로스터는 텍스트만 봤고, 그래서 `=`를
  # `!=`로 뒤집어도 게이트가 초록이었다(2026-08 실측). owner 전용 변이 경계의 술어가 무증인이었다.
  # ⚠️ **생산 텍스트를 생산과 같은 셸 모드로 돌린다** — 렌더한 사본이 아니다. GHA의 기본 셸은
  #    `bash -e {0}`라 pipefail이 없다(함정 원장) → `bash -e`가 충실한 모드다.
  run bash -c '
    set -euo pipefail
    root="$1"; n=0; bad=""
    for f in "$root"/.github/workflows/*.yaml; do
      cnt="$(yq -r "[.jobs[]?.steps[]? | select((.run // \"\") | contains(\"ATTEMPT\"))] | length" "$f" 2>/dev/null || echo 0)"
      [ "${cnt:-0}" -gt 0 ] || continue
      i=0
      while [ "$i" -lt "$cnt" ]; do
        body="$(yq -r "[.jobs[]?.steps[]? | select((.run // \"\") | contains(\"ATTEMPT\"))][$i].run" "$f")"
        n=$((n+1)); w="$(basename "$f")#$i"
        # ── 재실행 축 (17사본 **공통**) — 이벤트를 보지 않는다 ──
        # `if:`로 dispatch에 한정한 가드는 push/schedule run의 재실행에서 **스텝 자체가 skip**되므로
        # (skip은 실패가 아니다) 아래 dispatch 축 케이스가 닿지 못한다. github.run_attempt은 재실행이
        # 보존할 수 없는 유일한 값이고, attempt>=2의 개시자는 언제나 actions:write를 든 주체다 —
        # 그래서 이 축에는 열거할 트리거가 없다.
        EVENT="workflow_dispatch" ATTEMPT="1" OWNER="" ACTOR="x" TRIGGERING="x" \
          bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:empty-owner-passed"
        EVENT="schedule" ATTEMPT="2" OWNER="alice" ACTOR="alice" TRIGGERING="mallory" \
          bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:replay-passed"
        # 대조군 — 최초 실행(attempt=1)의 비-dispatch 트리거는 무영향이어야 한다(종전 의미론 보존).
        EVENT="schedule" ATTEMPT="1" OWNER="alice" ACTOR="anyone" TRIGGERING="anyone" \
          bash -e -c "$body" >/dev/null 2>&1 || bad="$bad $w:first-schedule-rejected"
        # ── dispatch 축 — actor 가드를 가진 사본에만 적용한다(이벤트 구동 잡의 replay 전용 가드는 비대상) ──
        # GitHub은 재실행에서 github.actor를 **최초 트리거 신원으로 보존**하고 triggering_actor만
        # 개시자로 바꾼다 — actor만 보는 가드는 owner의 과거 디스패치 재실행으로 통과한다.
        case "$body" in *ACTOR*)
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="mallory" TRIGGERING="mallory" \
            bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:mismatch-passed"
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="alice" TRIGGERING="mallory" \
            bash -e -c "$body" >/dev/null 2>&1 && bad="$bad $w:rerun-passed"
          EVENT="workflow_dispatch" ATTEMPT="1" OWNER="alice" ACTOR="alice" TRIGGERING="alice" \
            bash -e -c "$body" >/dev/null 2>&1 || bad="$bad $w:match-rejected"
        esac
        i=$((i+1))
      done
    done
    # 열거 바닥값 — 추출이 붕괴하면 0사본을 돌리고도 초록이 된다. 수치는 콜사이트 소유.
    [ "$n" -ge 17 ] || { echo "ROSTER-COLLAPSE n=$n"; exit 1; }
    [ -z "$bad" ] || { echo "PREDICATE-WRONG:$bad"; exit 1; }
    echo "EXECUTED=$n"
  ' _ "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'EXECUTED='
}
