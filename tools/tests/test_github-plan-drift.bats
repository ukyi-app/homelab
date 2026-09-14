#!/usr/bin/env bats
# 실제 CI의 private App 누락과 REST 대조, 실패 전파를 합성 입력으로 검증한다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DRIFT_MODULE="$ROOT/tools/lib/github-plan-drift.ts"
  cat > "$BATS_TEST_TMPDIR/fixture.ts" <<'TS'
import assert from "node:assert/strict";
export const owner="MDQ6VXNlcjUyMzcxNTI5", app="A_kwHOEWo9us4APbFI";
const policy={id:"BPR_fixture",repository_id:"R_kgDOS2czrg",pattern:"main",enforce_admins:false,allows_deletions:false,allows_force_pushes:false,required_status_checks:[{strict:true,contexts:["gate"]}],restrict_pushes:[{blocks_creations:true,push_allowances:[owner,app]}]};
export const plan={format_version:"1.2",errored:false,resource_changes:[{address:"github_branch_protection.main",mode:"managed",type:"github_branch_protection",name:"main",provider_name:"registry.terraform.io/integrations/github",change:{actions:["update"],before:{...structuredClone(policy),restrict_pushes:[{blocks_creations:true,push_allowances:[owner]}]},after:structuredClone(policy),after_unknown:{}}}]};
export const rest={restrictions:{users:[{id:52371529,node_id:owner,login:"ukkiee"}],apps:[{id:4043080,node_id:app,slug:"ukyi-homelab-writer"}],teams:[]}};
export {assert};
TS
  cat > "$BATS_TEST_TMPDIR/probe.ts" <<'TS'
import {assert,plan,rest,owner,app} from "./fixture.ts";
const {classifyGithubPlan,checkGithubPlan}=await import(process.env.DRIFT_MODULE!);
TS
}

probe() {
  cat >> "$BATS_TEST_TMPDIR/probe.ts"
  run bun "$BATS_TEST_TMPDIR/probe.ts"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "private App omission is healthy after REST actor validation" {
  probe <<'TS'
assert.deepEqual(classifyGithubPlan(plan,rest),{drift:false,privateAppReadMismatch:true});
plan.resource_changes[0].change.after.restrict_pushes[0].push_allowances.reverse();
assert.equal(classifyGithubPlan(plan,rest).drift,false);
TS
}

@test "removed additional wrong or duplicate REST actors remain drift" {
  probe <<'TS'
for(const mutate of [r=>r.restrictions.apps=[],r=>r.restrictions.users=[],r=>r.restrictions.teams=[{id:1}],r=>r.restrictions.apps.push({id:4937062,node_id:"A_other"}),r=>r.restrictions.users.push(r.restrictions.users[0]),r=>r.restrictions.apps[0].id=4937062,r=>r.restrictions.apps[0].node_id=owner]){const r=structuredClone(rest);mutate(r);assert.equal(classifyGithubPlan(plan,r).drift,true);}
TS
}

@test "no-op plans also check REST for actors invisible to GraphQL" {
  probe <<'TS'
const c=plan.resource_changes[0].change;c.actions=["no-op"];c.before=structuredClone(c.after);
assert.deepEqual(classifyGithubPlan(plan,rest),{drift:false,privateAppReadMismatch:false});
rest.restrictions.apps.push({id:4937062,node_id:"A_other",slug:"other"});
assert.equal(classifyGithubPlan(plan,rest).drift,true);
TS
}

@test "every other protection change and unknown value remains drift" {
  probe <<'TS'
for(const mutate of [c=>c.after.enforce_admins=true,c=>c.after.allows_force_pushes=true,c=>c.after.required_status_checks[0].strict=false,c=>c.after.restrict_pushes[0].blocks_creations=false,c=>c.after.restrict_pushes[0].push_allowances.push("A_other"),c=>c.before.restrict_pushes[0].push_allowances=[],c=>c.after_unknown={new_field:true},c=>c.actions=["delete","create"]]){const p=structuredClone(plan);mutate(p.resource_changes[0].change);assert.equal(classifyGithubPlan(p,rest).drift,true);}
TS
}

@test "another resource change cannot be hidden by the App visibility mismatch" {
  probe <<'TS'
for(const actions of [["update"],["delete"],["forget"],["create"]]){const p=structuredClone(plan);p.resource_changes.push({address:"github_repository_ruleset.other",mode:"managed",type:"github_repository_ruleset",name:"other",provider_name:"registry.terraform.io/integrations/github",change:{actions,before:{name:"old"},after:{name:"new"},after_unknown:{}}});assert.equal(classifyGithubPlan(p,rest).drift,true);}
TS
}

@test "missing incomplete duplicate and wrong-target plans fail closed" {
  probe <<'TS'
for(const p of [{},null,{...plan,errored:true},{...plan,resource_changes:[]},{...plan,resource_changes:[...plan.resource_changes,...plan.resource_changes]}])assert.throws(()=>classifyGithubPlan(p,rest));
for(const value of ["R_other",null]){const p=structuredClone(plan);p.resource_changes[0].change.after.repository_id=value;assert.throws(()=>classifyGithubPlan(p,rest));}
for(const r of [{},null,{restrictions:null},{restrictions:{...rest.restrictions,apps:null}}])assert.throws(()=>classifyGithubPlan(plan,r));
TS
}

@test "fixed REST GET uses the CI token and cannot follow a redirect" {
  probe <<'TS'
let calls=0;const api=async(url,init)=>{calls++;assert.equal(url,"https://api.github.com/repos/ukyi-app/homelab/branches/main/protection");assert.equal(init.method,"GET");assert.equal(init.redirect,"error");assert.equal(init.headers.Authorization,"Bearer fixture-token");return Response.json(rest)};
assert.equal((await checkGithubPlan(plan,"fixture-token",api)).drift,false);assert.equal(calls,1);
await assert.rejects(checkGithubPlan(plan,"",api));assert.equal(calls,1);
TS
}

@test "REST HTTP malformed body and network failure cannot report healthy" {
  probe <<'TS'
for(const status of [301,401,403,404,429,500])await assert.rejects(checkGithubPlan(plan,"fixture",async()=>new Response("secret-fixture",{status})));
for(const body of ["not-json","{}","x".repeat(300000)])await assert.rejects(checkGithubPlan(plan,"fixture",async()=>new Response(body)));
await assert.rejects(checkGithubPlan(plan,"fixture",async()=>{throw new Error("secret-fixture")}));
TS
}

@test "no-op unknown attributes remain observable instead of claiming healthy" {
  probe <<'TS'
const c=plan.resource_changes[0].change;c.actions=["no-op"];c.before=structuredClone(c.after);c.after_unknown={computed:[{nested:true}]};
assert.equal(classifyGithubPlan(plan,rest).drift,true);
TS
}

@test "real classifier CLI returns distinct healthy drift and failure without printing secrets" {
  cat > "$BATS_TEST_TMPDIR/preload.ts" <<'TS'
import {rest} from "./fixture.ts";
if(process.env.REST_DRIFT)rest.restrictions.apps=[];
globalThis.fetch=async()=>process.env.REST_FAIL?new Response("secret-fixture",{status:403}):Response.json(rest);
TS
  bun -e 'const {plan}=await import(process.argv[1]);console.log(JSON.stringify(plan))' "$BATS_TEST_TMPDIR/fixture.ts" > "$BATS_TEST_TMPDIR/plan.json"
  run bash -c 'TF_VAR_github_token=secret-fixture bun --preload "$1/preload.ts" "$DRIFT_MODULE" < "$1/plan.json"' _ "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = '{"drift":false,"privateAppReadMismatch":true}' ]
  run bash -c 'REST_DRIFT=1 TF_VAR_github_token=secret-fixture bun --preload "$1/preload.ts" "$DRIFT_MODULE" < "$1/plan.json"' _ "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  [ "$output" = '{"drift":true,"privateAppReadMismatch":false}' ]
  run bash -c 'REST_FAIL=1 TF_VAR_github_token=secret-fixture bun --preload "$1/preload.ts" "$DRIFT_MODULE" < "$1/plan.json"' _ "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ "$output" = '{"error":"rest-read-failed-403"}' ]
}

workflow_fixture() {
  export REAL_BUN
  REAL_BUN="$(command -v bun)"
  export TF_FIXTURE="$BATS_TEST_TMPDIR/plan.json" API_PRELOAD="$BATS_TEST_TMPDIR/preload.ts"
  bun -e 'const {plan}=await import(process.argv[1]);console.log(JSON.stringify(plan))' "$BATS_TEST_TMPDIR/fixture.ts" > "$TF_FIXTURE"
  cat > "$API_PRELOAD" <<'TS'
import {rest} from "./fixture.ts";
if(process.env.REST_DRIFT)rest.restrictions.apps=[];
globalThis.fetch=async()=>Response.json(rest);
TS
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/terraform" <<'SH'
#!/usr/bin/env bash
case "$2" in
  plan) exit "${TF_PLAN_RC:-2}" ;;
  show) cat "$TF_FIXTURE"; exit "${TF_SHOW_RC:-0}" ;;
  *) exit 91 ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/bun" <<'SH'
#!/usr/bin/env bash
exec "$REAL_BUN" --preload "$API_PRELOAD" "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/terraform" "$BATS_TEST_TMPDIR/bin/bun"
  cd "$ROOT" || exit 1
  bun -e 'import {parse} from "yaml";import {readFileSync} from "fs";const w=parse(readFileSync(".github/workflows/tf-reconcile.yaml","utf8"));const s=w.jobs["drift-github"].steps.find(s=>s.id==="drift");if(s.shell!=="bash")throw Error("pipefail shell required");process.stdout.write(s.run)' > "$BATS_TEST_TMPDIR/workflow.sh"
}

@test "actual workflow reports compensated visibility and genuine drift separately" {
  workflow_fixture
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/healthy" TF_VAR_github_token=fixture bash -e -o pipefail "$BATS_TEST_TMPDIR/workflow.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fx 'drift=false' "$BATS_TEST_TMPDIR/healthy"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" REST_DRIFT=1 GITHUB_OUTPUT="$BATS_TEST_TMPDIR/drift" TF_VAR_github_token=fixture bash -e -o pipefail "$BATS_TEST_TMPDIR/workflow.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fx 'drift=true' "$BATS_TEST_TMPDIR/drift"
}

@test "actual workflow preserves terraform plan and partial show failures" {
  workflow_fixture
  for pair in TF_PLAN_RC=1 TF_SHOW_RC=1; do
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$pair" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/$pair" TF_VAR_github_token=fixture bash -e -o pipefail "$BATS_TEST_TMPDIR/workflow.sh"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ "$(cat "$BATS_TEST_TMPDIR/$pair")" = 'executed=true' ]
  done
}

@test "actual workflow preserves show failure when classifier simultaneously reports drift" {
  workflow_fixture
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TF_SHOW_RC=1 REST_DRIFT=1 GITHUB_OUTPUT="$BATS_TEST_TMPDIR/failed" TF_VAR_github_token=fixture bash -e -o pipefail "$BATS_TEST_TMPDIR/workflow.sh"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/failed")" = 'executed=true' ]
}
