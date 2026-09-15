#!/usr/bin/env bats
# 검토 SHA plan·main 자격 경계. 운영 자격/API 없이 실제 판정과 workflow 본문을 실행한다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  export REVIEW_MODULE="$ROOT/tools/lib/reviewed-plan.ts"
  cat > "$BATS_TEST_TMPDIR/probe.ts" <<'TS'
import assert from 'node:assert/strict';
import {validateRequest,validatePullRequest,checkReviewedHead} from process.env.REVIEW_MODULE;
const env={GITHUB_EVENT_NAME:'workflow_dispatch',GITHUB_REPOSITORY:'ukyi-app/homelab',GITHUB_REPOSITORY_ID:'1265054638',GITHUB_REF:'refs/heads/main',GITHUB_REF_TYPE:'branch',GITHUB_WORKFLOW_REF:'ukyi-app/homelab/.github/workflows/reviewed-plan.yaml@refs/heads/main',GITHUB_WORKFLOW_SHA:'a'.repeat(40),GITHUB_SHA:'a'.repeat(40),HOMELAB_OWNER:'owner',GITHUB_ACTOR:'owner',GITHUB_TRIGGERING_ACTOR:'owner',GITHUB_RUN_ATTEMPT:'1',GITHUB_RUN_ID:'123',REVIEWED_PR:'42',REVIEWED_HEAD_SHA:'b'.repeat(40),GH_TOKEN:'fake-test-token'};
const repo={id:1265054638,full_name:'ukyi-app/homelab'};
const pr={number:42,state:'open',merged:false,draft:true,base:{repo,ref:'main'},head:{repo,sha:'b'.repeat(40)}};
TS
  # 동적 import 경로는 Bun의 정적 import 구문이 아니므로 명시적인 await import를 쓴다.
  python - "$BATS_TEST_TMPDIR/probe.ts" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace("import {validateRequest,validatePullRequest,checkReviewedHead} from process.env.REVIEW_MODULE;", "const {validateRequest,validatePullRequest,checkReviewedHead}=await import(process.env.REVIEW_MODULE!);"))
PY
}
probe() {
  cat >> "$BATS_TEST_TMPDIR/probe.ts"
  run bun "$BATS_TEST_TMPDIR/probe.ts"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "reviewed request accepts exact same-repo draft head and returns immutable attribution" {
  probe <<'TS'
const r=validatePullRequest(env,pr);assert.equal(r.head_sha,'b'.repeat(40));assert.equal(r.pr,42);assert.equal(r.workflow_sha,'a'.repeat(40));assert.equal(r.actor,'owner');assert.equal(validateRequest({...env,GITHUB_ACTOR:'OwNeR',GITHUB_TRIGGERING_ACTOR:'OWNER',HOMELAB_OWNER:'oWnEr'}).pr,42);
TS
}

@test "reviewed request rejects non-owner actor triggering actor and every rerun" {
  probe <<'TS'
for(const patch of [{GITHUB_ACTOR:'aiops[bot]'},{GITHUB_TRIGGERING_ACTOR:'github-actions[bot]'},{HOMELAB_OWNER:''},{GITHUB_RUN_ATTEMPT:'2'},{GITHUB_RUN_ATTEMPT:'0'},{GITHUB_RUN_ATTEMPT:'NaN'}]) assert.throws(()=>validateRequest({...env,...patch}));
TS
}

@test "reviewed request rejects PR event branch tag foreign repo and untrusted workflow code" {
  probe <<'TS'
for(const patch of [{GITHUB_EVENT_NAME:'pull_request'},{GITHUB_EVENT_NAME:'pull_request_target'},{GITHUB_REF:'refs/pull/42/merge'},{GITHUB_REF:'refs/heads/aiops/incident-42'},{GITHUB_REF:'refs/tags/main',GITHUB_REF_TYPE:'tag'},{GITHUB_REF_TYPE:'tag'},{GITHUB_REPOSITORY:'attacker/homelab'},{GITHUB_REPOSITORY_ID:'99'},{GITHUB_WORKFLOW_REF:env.GITHUB_WORKFLOW_REF.replace('@refs/heads/main','@refs/heads/aiops/a')},{GITHUB_SHA:'c'.repeat(40)},{GITHUB_WORKFLOW_SHA:'main'}]) assert.throws(()=>validateRequest({...env,...patch}));
TS
}

@test "reviewed inputs reject abbreviated SHA coercion and command injection" {
  probe <<'TS'
for(const value of ['1e2','0','-1',' 42','42;id','9007199254740992','']) assert.throws(()=>validateRequest({...env,REVIEWED_PR:value}));
for(const value of ['abcdef0','main','B'.repeat(40),'$(id)','b'.repeat(40)+'\n','']) assert.throws(()=>validateRequest({...env,REVIEWED_HEAD_SHA:value}));
TS
}

@test "reviewed PR rejects moved head closed merged wrong base and repository identity drift" {
  probe <<'TS'
for(const patch of [{number:43},{state:'closed'},{merged:true},{head:{...pr.head,sha:'c'.repeat(40)}},{head:{...pr.head,repo:{...repo,id:77}}},{head:{...pr.head,repo:{...repo,full_name:'attacker/homelab'}}},{head:{...pr.head,repo:null}},{base:{...pr.base,ref:'release'}},{base:{...pr.base,repo:{...repo,id:77}}}]) assert.throws(()=>validatePullRequest(env,{...pr,...patch}));
for(const value of [null,[],{},'bad']) assert.throws(()=>validatePullRequest(env,value));
TS
}

@test "fresh API checks fail if head changes between authorization execution and attribution" {
  probe <<'TS'
let calls=0;
const api=async(url,init)=>{assert.equal(url,'https://api.github.com/repos/ukyi-app/homelab/pulls/42');assert.equal(init.method,'GET');assert.equal(init.redirect,'error');calls++;return Response.json(calls===1?pr:{...pr,head:{...pr.head,sha:'c'.repeat(40)}})};
await checkReviewedHead(env,api);await assert.rejects(checkReviewedHead(env,api),/head/);await assert.rejects(checkReviewedHead(env,api),/head/);assert.equal(calls,3);
TS
}

@test "API failures malformed data and missing authorization fail closed" {
  probe <<'TS'
for(const status of [403,404,500]) await assert.rejects(checkReviewedHead(env,async()=>new Response('untrusted-body',{status})),/HTTP/);
await assert.rejects(checkReviewedHead(env,async()=>Response.json({})));await assert.rejects(checkReviewedHead({...env,GH_TOKEN:''}));
let calls=0;await assert.rejects(checkReviewedHead({...env,GITHUB_ACTOR:'aiops'},async()=>{calls++;return Response.json(pr)}));assert.equal(calls,0);
TS
}

@test "plan uses trusted main code exact candidate SHA and an independent credential-free attribution job" {
  run bun -e '
    import assert from "node:assert/strict";import {parse} from "yaml";import {readFileSync} from "fs";
    const w=parse(readFileSync(".github/workflows/reviewed-plan.yaml","utf8"));
    assert.deepEqual(Object.keys(w.on),["workflow_dispatch"]);assert.deepEqual(w.permissions,{contents:"read","pull-requests":"read"});
    assert.equal(w.jobs.plan.environment,"homelab-main");assert.equal(w.jobs.authorize.environment,undefined);assert.equal(w.jobs.result.environment,undefined);
    for(const id of ["authorize","plan","result"]){const j=w.jobs[id];assert.equal(j.steps[0].with.ref,"${{ github.workflow_sha }}");assert.equal(j.steps[0].with["persist-credentials"],false);}
    const c=w.jobs.plan.steps.find(s=>s.with?.path==="candidate");assert.equal(c.with.repository,"ukyi-app/homelab");assert.equal(c.with.ref,"${{ needs.authorize.outputs.head_sha }}");assert.equal(c.with["persist-credentials"],false);
    const idx=w.jobs.plan.steps.findIndex(s=>s.run?.includes("reviewed-plan.ts pre-plan"));assert.ok(idx>0);assert.ok(JSON.stringify(w.jobs.plan.steps[idx+1]).includes("secrets.TF_CLOUDFLARE_TOKEN"));
    for(const id of ["authorize","result"])assert.ok(!JSON.stringify(w.jobs[id]).includes("secrets."));
    assert.ok(w.jobs.result.steps.some(s=>s.run==="bun tools/lib/reviewed-plan.ts result"));assert.ok(w.jobs.result.steps.some(s=>s.with?.path==="reviewed-plan-receipt.json"));
    assert.ok(!JSON.stringify(w).includes("terraform apply"));assert.ok(!JSON.stringify(w.jobs.result).includes("path\":\"candidate"));
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "every homelab operating secret consumer including reusable jobs has main environment and its own replay guard" {
  run bun -e '
    import assert from "node:assert/strict";import {parse} from "yaml";import {readdirSync,readFileSync} from "fs";
    let n=0;
    for(const f of readdirSync(".github/workflows").filter(f=>f.endsWith(".yaml"))){const w=parse(readFileSync(".github/workflows/"+f,"utf8"));
      for(const [id,j] of Object.entries(w.jobs)){if(!/\$\{\{\s*secrets\.(?!GITHUB_TOKEN\b)/.test(JSON.stringify(j)))continue;
        if(f==="reusable-app-build.yaml"){assert.equal(id,"deploy-trigger");assert.deepEqual(Object.keys(w.on),["workflow_call"]);continue;}
        // 공개 표식 전용 수용 job은 운영 자격 소비자가 아니다. 다른 secret이 추가되면 예외를 거부한다.
        if(f==="ci-authority-probe.yaml"){
          assert.equal(id,"protected-environment");assert.equal(j.environment,"homelab-main");assert.equal(j.needs,"authorize");
          assert.deepEqual([...JSON.stringify(j).matchAll(/secrets\.([A-Z_0-9]+)/g)].map(m=>m[1]),["AIOPS_CI_PUBLIC_CANARY_0915"]);
          assert.deepEqual(w.permissions,{});continue;
        }
        n++;assert.equal(j.environment,"homelab-main",f+"/"+id);
        if(f!=="reviewed-plan.yaml"){
          assert.equal(j.steps[0].id,"authority");assert.ok(j.steps[0].run?.includes("$TRIGGERING"),f+"/"+id);assert.ok(j.steps[0].run.includes("refs/heads/main"));
          for(const s of j.steps.filter(s=>/\/actions\/(telegram-notify|mutation-notify)$/.test(s.uses??"")))assert.ok(/steps\.authority\.outcome == .success./.test(s.if??""),f+" notify authority");
        }
      }
    }assert.ok(n>=30);
    const i=parse(readFileSync(".github/workflows/iac.yaml","utf8"));assert.equal(i.jobs["iac-plan"],undefined);assert.equal(i.jobs.accounting,undefined);assert.ok(!JSON.stringify(i.jobs["iac-validate"]).includes("secrets."));assert.equal(i.jobs["iac-validate"].environment,undefined);
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "actual privileged job guards reject PR tag foreign repo aiops dispatch and partial reruns while allowing existing events" {
  run bun -e '
    import assert from "node:assert/strict";import {parse} from "yaml";import {readdirSync,readFileSync} from "fs";import {spawnSync} from "child_process";
    let n=0;for(const f of readdirSync(".github/workflows").filter(f=>f.endsWith(".yaml"))){const w=parse(readFileSync(".github/workflows/"+f,"utf8"));for(const j of Object.values(w.jobs)){
      const s=j.steps?.find(s=>s.name?.startsWith("main 운영 자격 경계"));if(!s)continue;n++;
      const env={PATH:process.env.PATH,REF:"refs/heads/main",REPOSITORY_ID:"1265054638",EVENT:"workflow_dispatch",ATTEMPT:"1",ACTOR:"owner",TRIGGERING:"owner",OWNER:"owner"};
      const run=p=>spawnSync("bash",["-e", "-c",s.run],{env:{...env,...p},stdio:"pipe"}).status;
      assert.equal(run({}),0,f);assert.equal(run({ACTOR:"OWNER",TRIGGERING:"oWnEr",OWNER:"Owner"}),0,f);
      for(const p of [{REF:"refs/pull/1/merge"},{REF:"refs/heads/aiops/a"},{REF:"refs/tags/main"},{REPOSITORY_ID:"99"},{OWNER:""},{ACTOR:"aiops[bot]",TRIGGERING:"aiops[bot]"},{EVENT:"pull_request_target"},{EVENT:"schedule",ATTEMPT:"2",TRIGGERING:"aiops[bot]"},{ATTEMPT:"2",TRIGGERING:"aiops[bot]"}])assert.notEqual(run(p),0,f+JSON.stringify(p));
      for(const EVENT of ["schedule","push","workflow_run"])assert.equal(run({EVENT,ACTOR:"trusted-writer[bot]",TRIGGERING:"trusted-writer[bot]"}),0,f);
      assert.equal(run({ATTEMPT:"2"}),0,f);
      if(f==="bump-poll.yaml")assert.equal(run({ACTOR:"ukyi-homelab-dispatch[bot]",TRIGGERING:"ukyi-homelab-dispatch[bot]"}),0,f);
    }}assert.ok(n>=30);
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "result CLI persists a receipt for the reviewed SHA and emits none after head moves" {
  cat >> "$BATS_TEST_TMPDIR/probe.ts" <<'TS'
Object.assign(process.env,env);
globalThis.fetch=async()=>Response.json(process.env.MOVED==='true'?{...pr,head:{...pr.head,sha:'c'.repeat(40)}}:pr);
TS
  # CLI 모듈을 preload에서 먼저 import하면 main 본문이 env 설치보다 먼저 실행된다.
  sed '/const {validateRequest,validatePullRequest,checkReviewedHead}=await import/d' "$BATS_TEST_TMPDIR/probe.ts" > "$BATS_TEST_TMPDIR/cli-preload.ts"
  mkdir "$BATS_TEST_TMPDIR/result" "$BATS_TEST_TMPDIR/moved"
  cd "$BATS_TEST_TMPDIR/result" || exit 1
  run env PLAN_RESULT=success GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" bun --preload "$BATS_TEST_TMPDIR/cli-preload.ts" "$REVIEW_MODULE" result
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .head_sha reviewed-plan-receipt.json)" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
  [ "$(jq -r .plan_result reviewed-plan-receipt.json)" = success ]
  [ "$(jq -r .workflow_sha reviewed-plan-receipt.json)" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
  cd "$BATS_TEST_TMPDIR/moved" || exit 1
  run env MOVED=true PLAN_RESULT=success GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/moved-summary" bun --preload "$BATS_TEST_TMPDIR/cli-preload.ts" "$REVIEW_MODULE" result
  [ "$status" -ne 0 ]
  [ ! -e reviewed-plan-receipt.json ]
  [ ! -e "$BATS_TEST_TMPDIR/moved-summary" ]
}

@test "hostile PR requesting write permissions still has no operating credential lane in trusted workflows" {
  # 후보 YAML의 permissions는 공격자가 바꿀 수 있다. 아래는 로컬 정책 대조이며 서버 거부 실측은 아니다.
  run bun -e '
    import assert from "node:assert/strict";import {parse} from "yaml";import {readFileSync} from "fs";import {spawnSync} from "child_process";
    const hostile=parse(`on: pull_request\npermissions:\n  contents: write\n  checks: write\n  statuses: write\n  actions: write\n  pull-requests: write\njobs:\n  attack:\n    environment: homelab-main\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo attempt\n`);
    assert.ok(Object.values(hostile.permissions).every(x=>x==="write"));
    const w=parse(readFileSync(".github/workflows/_create-app.yaml","utf8"));const body=w.jobs.create.steps[0].run;
    const p=spawnSync("bash",["-e","-c",body],{env:{PATH:process.env.PATH,REF:"refs/pull/42/merge",REPOSITORY_ID:"1265054638",EVENT:"pull_request",ATTEMPT:"1",ACTOR:"aiops[bot]",TRIGGERING:"aiops[bot]",OWNER:"owner"}});
    assert.notEqual(p.status,0);
    const hcl=readFileSync("infra/github/repo.tf","utf8");assert.match(hcl,/push_allowances\s*=\s*\["MDQ6VXNlcjUyMzcxNTI5", "A_kwHOEWo9us4APbFI"\]/);
    assert.equal(hostile.jobs.attack.environment,w.jobs.create.environment);
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
