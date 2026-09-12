#!/usr/bin/env bats
# 진단/검증 산출물 → 고정 fork Draft PR 게시 API 경계.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  printf 'fixture\n' > "$REPO/README.md"
  git -C "$REPO" init -q
  git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  REVISION="$(git -C "$REPO" rev-parse HEAD)"
  seed_incident
  printf '{"collectedAt":"2026-09-12T00:10:00Z","items":[{"id":"state-1","kind":"state","target":"monitoring/vmalert","observedAt":"2026-09-12T00:01:00Z","data":{"reason":"FailedScheduling"}}]}' > "$BATS_TEST_TMPDIR/evidence.json"
  aiops collect --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --input "$BATS_TEST_TMPDIR/evidence.json" >/dev/null
  ENGINE="$BATS_TEST_TMPDIR/engine"
  cat > "$ENGINE" <<'PY'
#!/usr/bin/python3
import sys,json
args=sys.argv[1:]
out=args[args.index('--output-last-message')+1]
evidence=json.load(open('evidence.json'))
report=dict(baseRevision=evidence['revision'],outcome='diagnosed',summary='스케줄링 실패 후보',causes=[dict(hypothesis='자원 부족',evidenceIds=['state-1'],counterEvidence=[],nextChecks=['노드 가용 메모리 확인'])],missingEvidence=[],patch=None)
json.dump(report,open(out,'w'))
print(json.dumps(dict(type='turn.completed',usage=dict(input_tokens=100,output_tokens=30,cached_input_tokens=0))))
PY
  chmod +x "$ENGINE"
}


teardown() { if [ -n "${server:-}" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; }

@test "notification retry does not rerun diagnosis and keeps the incident firing" {
  aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay >/dev/null
  cat > "$BATS_TEST_TMPDIR/api.py" <<'PYTHON'
import http.server,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(dict(path=self.path,body=body))+'\n')
  self.send_response(503 if (root/'fail').exists() else 200);self.end_headers();self.wfile.write(b'{"ok":true,"result":{"message_id":1}}')
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True);server.serve_forever()
PYTHON
  python3 "$BATS_TEST_TMPDIR/api.py" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/port" &
  server=$!
  for attempt in $(seq 1 60); do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.02; done
  printf local-telegram-token > "$BATS_TEST_TMPDIR/telegram-token"
  jq -n --arg base "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")/" --arg token "$BATS_TEST_TMPDIR/telegram-token" '{mode:"replay",telegram:{apiUrl:$base,tokenFile:$token,chatId:"-123"}}' > "$BATS_TEST_TMPDIR/config.json"
  touch "$BATS_TEST_TMPDIR/fail"
  run aiops publish --incident "$INCIDENT" --repo "$REPO" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.publication.telegram.status == "failed"' <<< "$output"
  rm "$BATS_TEST_TMPDIR/fail"
  run aiops publish --incident "$INCIDENT" --repo "$REPO" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.publication.telegram.status == "sent" and .incident.status == "firing"' <<< "$output"
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '([.budget.days[]] | add) == 1' <<< "$output"
  jq -s -e 'length == 2 and all(.[]; (.body.text | contains("스케줄링 실패 후보")) and (.body | has("parse_mode") | not))' "$BATS_TEST_TMPDIR/requests.jsonl"
}

@test "lost Draft PR response reconciles one fork PR with separate credentials" {
  sed -i "s/patch=None/patch='diff --git a\/README.md b\/README.md\\\\n--- a\/README.md\\\\n+++ b\/README.md\\\\n@@ -1 +1 @@\\\\n-fixture\\\\n+fixed\\\\n'/" "$ENGINE"
  aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay >/dev/null
  aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" > "$BATS_TEST_TMPDIR/validated.json"
  cat > "$BATS_TEST_TMPDIR/publisher-api.py" <<'PY'
import http.server,json,pathlib,sys,hashlib,base64
root=pathlib.Path(sys.argv[1]);incident=json.loads((root/'validated.json').read_text())['incident'];validation=incident['validation'];prs=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,value,code=200):self.send_response(code);self.end_headers();self.wfile.write(json.dumps(value).encode())
 def do_GET(self):
  path=self.path.split('?')[0]
  if path=='/repos/ukyi-app/homelab':return self.send(dict(id=42))
  if path=='/repos/aiops-bot/homelab':return self.send(dict(id=43,fork=True,parent=dict(id=42)))
  if path=='/repos/ukyi-app/homelab/git/ref/heads/main':return self.send(dict(object=dict(sha=validation['baseline']['revision'])))
  if '/pulls' in path:
   if (root/'lookup-fail').exists():return self.send({},503)
   return self.send(prs)
  return self.send({},404)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(dict(path=self.path,authorization=self.headers.get('Authorization'),body=body))+'\n')
  if self.path.endswith('/git/blobs'):
   data=base64.b64decode(body['content']);return self.send(dict(sha=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()))
  if self.path.endswith('/git/trees'):return self.send(dict(sha=validation['candidate']['treeHash']))
  if self.path.endswith('/git/commits'):return self.send(dict(sha='c'*40,tree=dict(sha=validation['candidate']['treeHash'])))
  if self.path.endswith('/git/refs'):return self.send(dict(object=dict(sha='c'*40)))
  if self.path.endswith('/pulls'):
   prs.append(dict(number=1,html_url='https://github.com/ukyi-app/homelab/pull/1',draft=True,body=body['body'],head=dict(ref=body['head'].split(':',1)[1],repo=dict(id=43)),base=dict(ref='main')))
   self.close_connection=True;return
  if self.path.endswith('/sendMessage'):return self.send(dict(ok=True,result=dict(message_id=1)))
  return self.send({},404)
server=http.server.HTTPServer(('127.0.0.1',0),Handler);print(server.server_address[1],flush=True);server.serve_forever()
PY
  python3 "$BATS_TEST_TMPDIR/publisher-api.py" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/port" &
  server=$!
  for attempt in $(seq 1 60); do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.02; done
  printf fork-only > "$BATS_TEST_TMPDIR/fork-token"
  printf pr-only > "$BATS_TEST_TMPDIR/pr-token"
  printf telegram-only > "$BATS_TEST_TMPDIR/telegram-token"
  jq -n --arg base "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")/" --arg dir "$BATS_TEST_TMPDIR" '{mode:"replay",publication:{apiUrl:$base,upstream:"ukyi-app/homelab",upstreamId:42,fork:"aiops-bot/homelab",forkId:43,base:"main",forkTokenFile:($dir+"/fork-token"),prTokenFile:($dir+"/pr-token")},telegram:{apiUrl:$base,tokenFile:($dir+"/telegram-token"),chatId:"-123"}}' > "$BATS_TEST_TMPDIR/config.json"
  run aiops publish --incident "$INCIDENT" --repo "$REPO" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.publication.pr.status == "uncertain"' <<< "$output"
  touch "$BATS_TEST_TMPDIR/lookup-fail"
  run aiops publish --incident "$INCIDENT" --repo "$REPO" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.publication.pr.status == "uncertain"' <<< "$output"
  rm "$BATS_TEST_TMPDIR/lookup-fail"
  run aiops publish --incident "$INCIDENT" --repo "$REPO" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.publication.pr.status == "draft" and .incident.publication.pr.number == 1' <<< "$output"
  jq -s -e '[.[] | select(.path | endswith("/pulls"))] | length == 1 and .[0].authorization == "Bearer pr-only" and .[0].body.draft == true and .[0].body.maintainer_can_modify == false' "$BATS_TEST_TMPDIR/requests.jsonl"
  jq -s -e 'all(.[] | select(.path | contains("/git/")); .authorization == "Bearer fork-only")' "$BATS_TEST_TMPDIR/requests.jsonl"
}
