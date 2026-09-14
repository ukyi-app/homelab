#!/usr/bin/env bats
# 실제 bare Git 그래프와 API fixture로 쓰기 경계를 검사한다. 원본 checkout·원격 서버는 변경하지 않는다.
setup() {
  export WRITEBACK_MODULE="$BATS_TEST_DIRNAME/../lib/ci-writeback.ts"
  export CASE_DIR="$BATS_TEST_TMPDIR"
  cat > "$BATS_TEST_TMPDIR/probe.ts" <<'TS'
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync,readFileSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
const {ObjectGit,sweepCandidates,verifyBuild,BUILD_WORKFLOW_ID}=await import(process.env.WRITEBACK_MODULE!);
const dir=process.env.CASE_DIR!;
const safe={PATH:process.env.PATH,HOME:dir,GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1',GIT_TERMINAL_PROMPT:'0',GIT_AUTHOR_NAME:'fixture',GIT_COMMITTER_NAME:'fixture',GIT_AUTHOR_EMAIL:'fixture@example.invalid',GIT_COMMITTER_EMAIL:'fixture@example.invalid'};
function g(cwd:string,...args:string[]){const r=spawnSync('git',['-C',cwd,...args],{env:safe,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function fixture(conflict=false){
 const remote=join(dir,'remote.git'),work=join(dir,'work');mkdirSync(work);
 g(dir,'init','--bare','--initial-branch=main',remote);g(work,'init','--initial-branch=main');g(work,'remote','add','origin',remote);
 writeFileSync(join(work,'conflict.txt'),'base\n');g(work,'add','.');g(work,'commit','-m','base');const base=g(work,'rev-parse','HEAD');
 g(work,'checkout','-b','create-cache/good');writeFileSync(join(work,'head.txt'),'legitimate head\n');writeFileSync(join(work,'.gitattributes'),'*.txt filter=evil merge=evil\n');
 if(conflict)writeFileSync(join(work,'conflict.txt'),'head\n');g(work,'add','.');g(work,'commit','-m','head');const head=g(work,'rev-parse','HEAD');
 g(work,'checkout','main');writeFileSync(join(work,'main.txt'),'trusted main\n');if(conflict)writeFileSync(join(work,'conflict.txt'),'main\n');g(work,'add','.');g(work,'commit','-m','main');const main=g(work,'rev-parse','HEAD');
 g(work,'checkout','-b','aiops/inject',base);writeFileSync(join(work,'evil.txt'),'attacker base bytes\n');g(work,'add','.');g(work,'commit','-m','evil');const evil=g(work,'rev-parse','HEAD');g(work,'push','origin','--all');
 return {remote,work,base,head,main,evil};
}
const candidate=(head:string,headRefName='create-cache/good')=>({number:10,headRefName,headRefOid:head});
const repository={id:1265054638,full_name:'ukyi-app/homelab'};
function apiFixture(head:string,attempt=1){
 const run={id:123,run_attempt:attempt,workflow_id:BUILD_WORKFLOW_ID,path:'.github/workflows/build.yaml',repository,head_repository:repository,status:'completed',conclusion:'success',event:'push',head_branch:'main',head_sha:head,actor:{login:'ukyi-homelab-writer[bot]'},triggering_actor:{login:attempt>1?'OwNeR':'ukyi-homelab-writer[bot]'},run_started_at:'2026-09-14T00:00:00Z',updated_at:'2026-09-14T00:02:00Z'};
 const event=structuredClone({repository,workflow_run:run});
 const artifact={id:77,name:'built-pg-tools',expired:false,created_at:'2026-09-14T00:01:00Z',workflow_run:{id:123,repository_id:1265054638,head_repository_id:1265054638,head_sha:head}};
 const data={run,attempt:structuredClone(run),workflow:{id:BUILD_WORKFLOW_ID,path:'.github/workflows/build.yaml',state:'active'},artifacts:[artifact]};
 const calls:string[]=[];
 const get=async(path:string)=>{calls.push(path);if(path===`/actions/workflows/${BUILD_WORKFLOW_ID}`)return data.workflow;if(path==='/actions/runs/123')return data.run;if(path===`/actions/runs/123/attempts/${attempt}`)return data.attempt;if(path==='/actions/runs/123/artifacts?per_page=100&page=1')return {total_count:data.artifacts.length,artifacts:data.artifacts};throw Error('unexpected API '+path)};
 return {event,data,get,calls};
}
TS
}
probe() {
  cat >> "$BATS_TEST_TMPDIR/probe.ts"
  run bun "$BATS_TEST_TMPDIR/probe.ts"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "sweep merges pinned main after a PR base edit and preserves both parents" {
  probe <<'TS'
const f=fixture(),git=new ObjectGit('fake-token',f.remote);
try {
 const selected={...candidate(f.head),baseRefName:'main'};selected.baseRefName='aiops/inject';
 sweepCandidates([selected],git);
 const result=g(f.remote,'rev-parse','refs/heads/create-cache/good');
 assert.deepEqual(g(f.remote,'show','-s','--format=%P',result).split(' '),[f.head,f.main]);
 assert.equal(g(f.remote,'show',result+':main.txt'),'trusted main');assert.equal(g(f.remote,'show',result+':head.txt'),'legitimate head');
 assert.ok(!g(f.remote,'ls-tree','-r','--name-only',result).includes('evil.txt'));
 assert.equal(g(f.remote,'rev-parse','main'),f.main);assert.equal(g(f.remote,'rev-parse','aiops/inject'),f.evil);
 sweepCandidates([candidate(result)],git);assert.equal(g(f.remote,'rev-parse','refs/heads/create-cache/good'),result);
}finally{git.close()}
TS
}

@test "sweep compare-and-swap refuses a head changed after object merge without overwriting it" {
  probe <<'TS'
const f=fixture();g(f.work,'checkout','create-cache/good');writeFileSync(join(f.work,'concurrent.txt'),'concurrent writer\n');g(f.work,'add','.');g(f.work,'commit','-m','concurrent');const moved=g(f.work,'rev-parse','HEAD');
class RacingGit extends ObjectGit {push(ref:string,head:string,commit:string){g(f.work,'push','origin',`${moved}:${ref}`);super.push(ref,head,commit)}}
const git=new RacingGit('fake-token',f.remote);
try{assert.throws(()=>sweepCandidates([candidate(f.head)],git),/sweep 실패/);assert.equal(g(f.remote,'rev-parse','refs/heads/create-cache/good'),moved)}finally{git.close()}
TS
}

@test "sweep refuses a head moved before fetch and reports merge conflicts without a push" {
  probe <<'TS'
const f=fixture(true),git=new ObjectGit('fake-token',f.remote);
try{assert.throws(()=>sweepCandidates([candidate(f.head)],git),/sweep 실패/);assert.equal(g(f.remote,'rev-parse','refs/heads/create-cache/good'),f.head);assert.throws(()=>sweepCandidates([candidate(f.base)],git),/sweep 실패/);assert.equal(g(f.remote,'rev-parse','refs/heads/create-cache/good'),f.head)}finally{git.close()}
TS
}

@test "sweep never writes main aiops bump-poll or malformed refs" {
  probe <<'TS'
const f=fixture(),git=new ObjectGit('fake-token',f.remote);
try{for(const ref of ['main','aiops/inject','bump-poll/app/demo','create-cache/../main','create-cache//bad','create-cache/good\nmain'])assert.throws(()=>sweepCandidates([candidate(f.head,ref)],git));assert.equal(g(f.remote,'rev-parse','main'),f.main);assert.equal(g(f.remote,'rev-parse','aiops/inject'),f.evil);assert.equal(g(f.remote,'rev-parse','create-cache/good'),f.head)}finally{git.close()}
TS
}

@test "object merge ignores hostile Git config hooks filters drivers and never logs credentials" {
  probe <<'TS'
const f=fixture(),marker=join(dir,'executed'),hooks=join(dir,'hooks');mkdirSync(hooks);writeFileSync(join(hooks,'pre-push'),`#!/bin/sh\ntouch '${marker}'\n`,{mode:0o755});
const config=join(dir,'hostile.gitconfig');writeFileSync(config,`[core]\n hooksPath = ${hooks}\n[filter "evil"]\n clean = touch ${marker}\n smudge = touch ${marker}\n[merge "evil"]\n driver = touch ${marker}\n[credential]\n helper = !touch ${marker}\n`);
const ledger=join(dir,'commands.jsonl'),token='fake-secret-never-in-argv';
Object.assign(process.env,{GIT_CONFIG_GLOBAL:config,GIT_CONFIG_SYSTEM:config,GIT_CONFIG_COUNT:'1',GIT_CONFIG_KEY_0:'core.hooksPath',GIT_CONFIG_VALUE_0:hooks,GIT_DIR:join(f.work,'.git'),GIT_EXEC_PATH:'/invalid-inherited-exec-path',GIT_TEMPLATE_DIR:hooks,HOMELAB_EXEC_LEDGER:ledger});
const git=new ObjectGit(token,f.remote);try{sweepCandidates([candidate(f.head)],git);assert.equal(existsSync(marker),false);const log=readFileSync(ledger,'utf8');assert.ok(!log.includes(token));assert.ok(!log.includes(Buffer.from('x-access-token:'+token).toString('base64')));for(const line of log.trim().split('\n'))assert.ok(!JSON.parse(line).args.some((a:string)=>['checkout','merge','reset','clean'].includes(a)));}finally{git.close()}
TS
}

@test "build provenance accepts current main past main and owner reruns with pinned artifact IDs" {
  probe <<'TS'
const f=fixture();for(const [head,attempt] of [[f.main,1],[f.base,1],[f.base,2]] as const){const a=apiFixture(head,attempt),git=new ObjectGit('fake',f.remote);try{const receipt=await verifyBuild(a.event,'owner',a.get,git);assert.equal(receipt.head_sha,head);assert.equal(receipt.artifact_ids,'77');assert.equal(receipt.run_attempt,attempt);assert.ok(a.calls.includes(`/actions/runs/123/attempts/${attempt}`));}finally{git.close()}}
TS
}

@test "build provenance rejects unreachable tag-main code despite matching workflow name and absent ref suffix" {
  probe <<'TS'
const f=fixture(),a=apiFixture(f.evil),git=new ObjectGit('fake',f.remote);try{await assert.rejects(verifyBuild(a.event,'owner',a.get,git),/ancestry|ancestor/)}finally{git.close()}
TS
}

@test "build provenance requires API repository workflow run attempt SHA event status and path identity" {
  probe <<'TS'
const head='a'.repeat(40),git={fetchMain:()=>head,ancestor:()=>true};
for(const patch of [{id:124},{run_attempt:2},{head_sha:'b'.repeat(40)},{workflow_id:99},{path:'.github/workflows/evil.yaml'},{path:'.github/workflows/build.yaml@refs/tags/main'},{event:'pull_request'},{status:'in_progress'},{conclusion:'failure'},{head_branch:'aiops/incident-1'},{repository:{...repository,id:99}},{head_repository:{...repository,id:99}}]){const a=apiFixture(head);Object.assign(a.data.run,patch);await assert.rejects(verifyBuild(a.event,'owner',a.get,git));}
for(const patch of [{id:99},{path:'.github/workflows/evil.yaml'},{state:'disabled_manually'}]){const a=apiFixture(head);Object.assign(a.data.workflow,patch);await assert.rejects(verifyBuild(a.event,'owner',a.get,git));}
const a=apiFixture(head,2);a.data.run.triggering_actor.login='aiops[bot]';await assert.rejects(verifyBuild(a.event,'owner',a.get,git),/개시자/);
await assert.rejects(verifyBuild(apiFixture(head).event,'owner',async()=>{throw Error('HTTP 403')},git),/HTTP 403/);
TS
}

@test "build provenance rejects stale attempts expired or foreign artifacts and racing reruns" {
  probe <<'TS'
const head='a'.repeat(40),git={fetchMain:()=>head,ancestor:()=>true};
for(const patch of [{expired:true},{created_at:'2026-09-13T23:59:59Z'},{created_at:'2026-09-14T00:03:00Z'},{workflow_run:{id:123,repository_id:1265054638,head_repository_id:1265054638,head_sha:'b'.repeat(40)}},{workflow_run:{id:124,repository_id:1265054638,head_repository_id:1265054638,head_sha:head}}]){const a=apiFixture(head);Object.assign(a.data.artifacts[0],patch);await assert.rejects(verifyBuild(a.event,'owner',a.get,git));}
const a=apiFixture(head);let latest=0;const get=async(p:string)=>{const value=await a.get(p);return p==='/actions/runs/123'&&++latest===2?{...a.data.run,run_attempt:2}:value};await assert.rejects(verifyBuild(a.event,'owner',get,git),/attempt/);
const empty=apiFixture(head);empty.data.artifacts=[];assert.equal((await verifyBuild(empty.event,'owner',empty.get,git)).artifact_ids,'');
TS
}

@test "actual workflows call trusted helpers before writer issuance and consume immutable artifacts" {
  probe <<'TS'
const {parse}=await import(join(process.env.WRITEBACK_MODULE!,'../../../node_modules/yaml/dist/index.js'));
const root=join(process.env.WRITEBACK_MODULE!,'../../..');
const bump=parse(readFileSync(join(root,'.github/workflows/bump.yaml'),'utf8')).jobs.writeback.steps;
const writer=bump.findIndex((s:any)=>s.id==='token'),provenance=bump.findIndex((s:any)=>s.id==='provenance');assert.ok(provenance>0&&provenance<writer);
const checks=bump.filter((s:any)=>s.run==='bun tools/lib/ci-writeback.ts verify-build');assert.equal(checks.length,2);for(const s of checks){assert.equal(s.env.GH_TOKEN,'${{ github.token }}');assert.ok(bump.indexOf(s)<writer)}
const download=bump.find((s:any)=>s.uses?.startsWith('actions/download-artifact@'));assert.equal(download.with['artifact-ids'],'${{ steps.provenance.outputs.artifact_ids }}');assert.equal(download.with.pattern,undefined);assert.ok(bump.indexOf(download)<writer);
for(const s of bump.filter((s:any)=>s.uses?.startsWith('actions/checkout@'))){assert.equal(s.with.ref,'${{ github.workflow_sha }}');assert.equal(s.with['persist-credentials'],false)}
const sweep=parse(readFileSync(join(root,'.github/workflows/pr-sweeper.yaml'),'utf8')).jobs.sweep.steps;assert.ok(sweep.find((s:any)=>s.id==='aiops_check').run.includes('bun tools/lib/ci-writeback.ts sweep'));assert.ok(!sweep.some((s:any)=>/gh (?:api .*\/update-branch|pr update-branch)/.test((s.run??'').split('\n').filter((l:string)=>!/^\s*#/.test(l)).join('\n'))));
TS
}

@test "public verify-build CLI emits pinned outputs and rejects artifact replacement before writer issuance" {
  probe <<'TS'
const f=fixture(),a=apiFixture(f.main),eventPath=join(dir,'event.json'),dataPath=join(dir,'api.json');
writeFileSync(eventPath,JSON.stringify(a.event));writeFileSync(dataPath,JSON.stringify(a.data));
const execPath=join(process.env.WRITEBACK_MODULE!,'../exec.ts'),preload=join(dir,'preload.ts');
// 네트워크 transport만 로컬 bare remote/API로 치환한다. CLI·Git 병합 경계는 실제 구현을 실행한다.
writeFileSync(preload,`
import {mock} from 'bun:test';
import {readFileSync} from 'node:fs';
import {isolatedSpawnSync as real} from ${JSON.stringify(execPath)};
const runGit=real;
mock.module(${JSON.stringify(execPath)},()=>({isolatedSpawnSync:(cmd,args,opts)=>runGit(cmd,['-c','protocol.file.allow=always',...args.map(a=>a==='https://github.com/ukyi-app/homelab.git'?${JSON.stringify(f.remote)}:a)],opts)}));
globalThis.fetch=async(url,init)=>{
 if(init.method!=='GET'||init.redirect!=='error')throw Error('unsafe request');
 const data=JSON.parse(readFileSync(${JSON.stringify(dataPath)},'utf8'));
 const p=String(url).replace('https://api.github.com/repos/ukyi-app/homelab','');
 if(p==='/actions/workflows/293145411')return Response.json(data.workflow);
 if(p==='/actions/runs/123')return Response.json(data.run);
 if(p==='/actions/runs/123/attempts/1')return Response.json(data.attempt);
 if(p==='/actions/runs/123/artifacts?per_page=100&page=1')return Response.json({total_count:data.artifacts.length,artifacts:data.artifacts});
 throw Error('unexpected request');
};
`);
const output=join(dir,'output'),denied=join(dir,'denied');
const env={...safe,GITHUB_EVENT_NAME:'workflow_run',GITHUB_REPOSITORY:'ukyi-app/homelab',GITHUB_REPOSITORY_ID:'1265054638',GITHUB_REF:'refs/heads/main',GITHUB_EVENT_PATH:eventPath,GITHUB_OUTPUT:output,HOMELAB_OWNER:'owner',GH_TOKEN:'fake-never-print-token'};
const invoke=(extra={})=>spawnSync('bun',['--preload',preload,process.env.WRITEBACK_MODULE!,'verify-build'],{env:{...env,...extra},encoding:'utf8',timeout:30_000});
const good=invoke();assert.equal(good.status,0,good.stderr);assert.match(readFileSync(output,'utf8'),/^artifact_ids=77$/m);assert.ok(!good.stdout.includes(env.GH_TOKEN));assert.ok(!good.stderr.includes(env.GH_TOKEN));
const bad=invoke({EXPECTED_ARTIFACT_IDS:'88',GITHUB_OUTPUT:denied});assert.notEqual(bad.status,0);assert.match(bad.stderr,/artifact IDs/);assert.equal(existsSync(denied),false);
TS
}
