#!/usr/bin/env bats
# 실제 생산자 결과 작성기 → artifact 파일 → 수집 → 사건 조회.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }
teardown() { if [ -n "${server:-}" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; }

@test "the observation writer reports same-SHA warning and silent healthy without Telegram" {
  for drift in true false; do
    AIOPS_PRODUCER='tf-reconcile.yaml/reconcile' AIOPS_TARGET=cloudflare AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"drift\":{\"outcome\":\"success\",\"outputs\":{\"drift\":\"$drift\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/$drift.json"
  done
  jq -e '.status == "warning" and .completed == true and .target == "cloudflare"' "$BATS_TEST_TMPDIR/true.json"
  jq -e '.status == "healthy" and .completed == true and .revision == "1111111111111111111111111111111111111111"' "$BATS_TEST_TMPDIR/false.json"
}

@test "DNS transient and credential expiry remain distinct from a completed healthy check" {
  for transient in 0 1; do
    AIOPS_PRODUCER='dns-drift.yaml/check' AIOPS_TARGET=public-dns AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"check\":{\"outcome\":\"success\",\"outputs\":{\"count\":\"0\",\"transient\":\"$transient\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/dns-$transient.json"
  done
  jq -e '.status == "healthy" and .completed == true' "$BATS_TEST_TMPDIR/dns-0.json"
  jq -e '.status == "unobservable" and .completed == false' "$BATS_TEST_TMPDIR/dns-1.json"
  AIOPS_PRODUCER='credential-expiry.yaml/check' AIOPS_TARGET=credential-ledger AIOPS_JOB_RESULT=success \
    AIOPS_STEPS='{"exp":{"outcome":"success","outputs":{"rc":"1","body":"must-not-export"}}}' \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
    bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/expiry.json"
  jq -e '.status == "warning" and .completed == true and (has("body") | not)' "$BATS_TEST_TMPDIR/expiry.json"
}

@test "every notification producer writes an independent observation including delegated notifications" {
  run bun -e '
    import {parse} from "yaml";import{readdirSync,readFileSync}from"node:fs";
    let count=0;const producers:string[]=[];
    for(const file of readdirSync(".github/workflows").filter(f=>f.endsWith(".yaml"))){
      const workflow=parse(readFileSync(".github/workflows/"+file,"utf8"));
      for(const [id,job]of Object.entries(workflow.jobs??{})){
        const steps=(job as any).steps??[];
        if(!steps.some((s:any)=>/(?:telegram|mutation)-notify/.test(s.uses??"")))continue;
        count++;
        producers.push(file+"/"+id);
        const observation=steps.find((s:any)=>s.uses==="./.github/actions/aiops-observation");
        if(!observation||observation.if!=="always()"||observation.with?.producer!==file+"/"+id)throw Error(file+"/"+id+": missing independent observation");
        if(steps.some((s:any)=>/mutation-notify/.test(s.uses??"")) && (job as any).if!=="always()")throw Error("delegated normal path missing");
      }
    }
    const catalog=JSON.parse(readFileSync(".github/actions/aiops-observation/producers.json","utf8"));
    if(count<25 || JSON.stringify(producers.sort())!==JSON.stringify(Object.keys(catalog).sort()))throw Error("producer inventory mismatch");console.log(count);
  '
  [ "$status" -eq 0 ]
}

@test "DNS partial results preserve independent healthy and unobservable targets" {
  printf '[{"name":"ok","host":"ok.example.test","public":true,"active":true},{"name":"unknown","host":"unknown.example.test","public":true,"active":true}]' > "$BATS_TEST_TMPDIR/apps.json"
  bun tools/dns-drift-check.ts --apps "$BATS_TEST_TMPDIR/apps.json" --floor reserved=0 --fixture '{"ok.example.test":["192.0.2.1"],"unknown.example.test":"TRANSIENT"}' > "$BATS_TEST_TMPDIR/dns.json"
  AIOPS_PRODUCER='dns-drift.yaml/check' AIOPS_TARGET=public-dns AIOPS_JOB_RESULT=success \
    AIOPS_STEPS="$(jq -c '{check:{outcome:"success",outputs:{count:"0",transient:"1",observations:(.observations | tojson)}}}' "$BATS_TEST_TMPDIR/dns.json")" \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
    bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/partial.json"
  jq -e '.observations | any(.target == "ok.example.test" and .status == "healthy" and .completed == true)' "$BATS_TEST_TMPDIR/partial.json"
  jq -e '.observations | any(.target == "unknown.example.test" and .status == "unobservable" and .completed == false)' "$BATS_TEST_TMPDIR/partial.json"
}

@test "verified artifacts recover same SHA on a newer attempt and ignore older replay" {
  cat > "$BATS_TEST_TMPDIR/api.py" <<'PY'
import http.server,json,sys,pathlib,urllib.parse
root=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  routes=json.loads((root/'routes.json').read_text())
  value=routes.get(urllib.parse.urlsplit(self.path).path)
  if value is None:self.send_error(404);return
  self.send_response(200);self.end_headers()
  self.wfile.write((root/value['file']).read_bytes() if 'file' in value else json.dumps(value).encode())
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True);server.serve_forever()
PY
  python3 "$BATS_TEST_TMPDIR/api.py" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/port" &
  server=$!
  for attempt in $(seq 1 60); do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.02; done
  printf local-github-read-token > "$BATS_TEST_TMPDIR/token"
  jq -n --arg url "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")/" --arg token "$BATS_TEST_TMPDIR/token" '{mode:"replay",github:{apiUrl:$url,repository:"ukyi-app/homelab",repositoryId:42,readTokenFile:$token}}' > "$BATS_TEST_TMPDIR/config.json"
  for attempt in 1 2 1; do
    drift=true; [ "$attempt" -ne 2 ] || drift=false
    AIOPS_PRODUCER='tf-reconcile.yaml/reconcile' AIOPS_TARGET=cloudflare AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"drift\":{\"outcome\":\"success\",\"outputs\":{\"drift\":\"$drift\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT="$attempt" GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/observation.json"
    python3 - "$BATS_TEST_TMPDIR" "$attempt" <<'PY'
import json,sys,pathlib,zipfile,datetime
root=pathlib.Path(sys.argv[1]);attempt=int(sys.argv[2]);sha='1'*40;now=datetime.datetime.now(datetime.timezone.utc).isoformat()
run=dict(id=100,run_attempt=attempt,head_sha=sha,workflow_id=7,event='schedule',head_repository=dict(id=42),head_branch='main',status='completed',conclusion='success',created_at='2026-09-12T00:00:00Z',updated_at=now,path='.github/workflows/tf-reconcile.yaml')
artifact=dict(id=9,name=f'aiops-reconcile-{attempt}-abc',expired=False,workflow_run=dict(id=100,head_sha=sha,repository_id=42,head_repository_id=42))
routes={'/repos/ukyi-app/homelab':dict(id=42),'/repos/ukyi-app/homelab/actions/runs':dict(workflow_runs=[run]),'/repos/ukyi-app/homelab/actions/runs/100':run,'/repos/ukyi-app/homelab/actions/workflows/7':dict(id=7,path='.github/workflows/tf-reconcile.yaml'),'/repos/ukyi-app/homelab/actions/runs/100/artifacts':dict(artifacts=[artifact]),'/repos/ukyi-app/homelab/actions/artifacts/9/zip':dict(file='artifact.zip')}
(root/'routes.json').write_text(json.dumps(routes))
with zipfile.ZipFile(root/'artifact.zip','w') as archive:archive.write(root/'observation.json','observation.json')
PY
    run aiops poll-gha --config "$BATS_TEST_TMPDIR/config.json"
    [ "$status" -eq 1 ]
    jq -e '.source.status == "unobservable" and .source.reason == "missing-verified-artifacts"' <<< "$output"
    run aiops list
    [ "$status" -eq 0 ]
    if [ "$attempt" -eq 2 ]; then jq -e '.incidents[0].status == "resolved"' <<< "$output"; fi
  done
  jq -e '.incidents[0].status == "resolved" and .incidents[0].observationCount == 2' <<< "$output"
}

@test "history scan resumes after failure and finds an older run new attempt beyond the latest page" {
  cat > "$BATS_TEST_TMPDIR/history-api.py" <<'PY'
import http.server,json,sys,pathlib,urllib.parse,zipfile,io,datetime
root=pathlib.Path(sys.argv[1]);sha='1'*40
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,value,code=200):self.send_response(code);self.end_headers();self.wfile.write(json.dumps(value).encode())
 def do_GET(self):
  parsed=urllib.parse.urlsplit(self.path);path=parsed.path;query=urllib.parse.parse_qs(parsed.query)
  observation=json.loads((root/'observation.json').read_text());attempt=observation['attempt']
  now=datetime.datetime.now(datetime.timezone.utc).isoformat()
  run=dict(id=100,run_attempt=attempt,head_sha=sha,workflow_id=7,event='schedule',head_repository=dict(id=42),head_branch='main',status='completed',created_at='2026-09-12T00:00:00Z',updated_at=now)
  if path=='/repos/ukyi-app/homelab':return self.send(dict(id=42))
  if path.endswith('/actions/runs'):
   if (root/'empty').exists():return self.send(dict(total_count=0,workflow_runs=[]))
   if query.get('page')==['2']:
    if (root/'fail-page2').exists():return self.send({},503)
    return self.send(dict(total_count=101,workflow_runs=[run]))
   return self.send(dict(total_count=101,workflow_runs=[dict(run,id=200+i,status='in_progress') for i in range(100)]))
  if path.endswith('/actions/runs/100'):return self.send(run)
  if path.endswith('/actions/workflows/7'):return self.send(dict(id=7,path='.github/workflows/audit.yaml'))
  if path.endswith('/actions/runs/100/artifacts'):return self.send(dict(total_count=1,artifacts=[dict(id=9,name=f'aiops-audit-{attempt}-abc',expired=False,workflow_run=dict(id=100,head_sha=sha,repository_id=42,head_repository_id=42))]))
  if path.endswith('/actions/artifacts/9/zip'):
   archive=io.BytesIO()
   with zipfile.ZipFile(archive,'w') as z:z.writestr('observation.json',json.dumps(observation))
   self.send_response(200);self.end_headers();self.wfile.write(archive.getvalue());return
  self.send({},404)
server=http.server.HTTPServer(('127.0.0.1',0),Handler);print(server.server_address[1],flush=True);server.serve_forever()
PY
  python3 "$BATS_TEST_TMPDIR/history-api.py" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/port" &
  server=$!
  for attempt in $(seq 1 60); do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.02; done
  printf local-github-read-token > "$BATS_TEST_TMPDIR/token"
  jq -n --arg url "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")/" --arg token "$BATS_TEST_TMPDIR/token" '{mode:"replay",github:{apiUrl:$url,repository:"ukyi-app/homelab",repositoryId:42,readTokenFile:$token}}' > "$BATS_TEST_TMPDIR/config.json"
  for attempt in 1 2; do
    count=1; [ "$attempt" -ne 2 ] || count=0
    AIOPS_PRODUCER='audit.yaml/audit' AIOPS_TARGET=registry AIOPS_JOB_RESULT=success \
      AIOPS_STEPS="{\"audit\":{\"outcome\":\"success\",\"outputs\":{\"alerting\":\"$count\"}}}" \
      GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT="$attempt" GITHUB_SHA=1111111111111111111111111111111111111111 \
      GITHUB_REPOSITORY=ukyi-app/homelab AIOPS_REVISION=1111111111111111111111111111111111111111 \
      bun tools/aiops-observation.ts --output "$BATS_TEST_TMPDIR/observation.json"
    if [ "$attempt" -eq 1 ]; then
      touch "$BATS_TEST_TMPDIR/fail-page2"
      run aiops poll-gha --config "$BATS_TEST_TMPDIR/config.json"
      [ "$status" -eq 1 ]
      jq -e '.source.status == "unobservable" and (.source.lastSuccess // null) == null' <<< "$output"
      rm "$BATS_TEST_TMPDIR/fail-page2"
    fi
    run aiops poll-gha --config "$BATS_TEST_TMPDIR/config.json"
    [ "$status" -eq 0 ]
    run aiops list
    [ "$status" -eq 0 ]
    expected=firing; [ "$attempt" -ne 2 ] || expected=resolved
    jq -e --arg expected "$expected" '.incidents | length == 1 and .[0].status == $expected' <<< "$output"
  done
  fresh="$BATS_TEST_TMPDIR/fresh-state"
  touch "$BATS_TEST_TMPDIR/empty"
  AIOPS_STATE="$fresh" run aiops poll-gha --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 1 ]
  jq -e '.source.reason == "no-verified-observations" and (.source.lastSuccess // null) == null' <<< "$output"
}
