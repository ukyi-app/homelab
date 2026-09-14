#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  checkout="$BATS_TEST_DIRNAME/../.."
  fixture="$BATS_TEST_TMPDIR/homelab"
  mkdir -p "$fixture/infra/k3s-bootstrap"
  cp "$checkout/infra/k3s-bootstrap/aiops-install.sh" "$fixture/infra/k3s-bootstrap/"
  python3 - "$fixture" <<'PY'
import hashlib,io,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);archive=root/'runtime.tar';sha='1'*40
with tarfile.open(archive,'w',format=tarfile.PAX_FORMAT,pax_headers={'comment':sha}) as bundle:
 data=b'#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n'
 item=tarfile.TarInfo('scripts/aiops-install.sh');item.size=len(data);item.mode=0o755
 bundle.addfile(item,io.BytesIO(data))
(root/'infra/k3s-bootstrap/aiops-runtime.json').write_text(json.dumps({'version':1,'repository':'ukyi-app/aiops','revision':sha,'archiveSha256':hashlib.sha256(archive.read_bytes()).hexdigest()}))
PY
}

@test "the homelab pin selects runtime code independently from target configuration" {
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --install "$fixture/runtime.tar" target.json bun codex conftest
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = --install ]
  [ "${lines[1]}" = target.json ]
  [ "${lines[3]}" = 1111111111111111111111111111111111111111 ]
  [ "${lines[5]}" = bun ]
}

@test "unreviewed archive bytes or an unpinned release cannot execute installer code" {
  printf altered >> "$fixture/runtime.tar"
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --prepare "$fixture/runtime.tar"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq 'digest mismatch'
  python3 - "$fixture/infra/k3s-bootstrap/aiops-runtime.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text());d['revision']=None;p.write_text(json.dumps(d))
PY
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --prepare "$fixture/runtime.tar"
  [ "$status" -ne 0 ]
  [[ "$output" == *'not pinned'* ]]
}

@test "an archive cannot claim another runtime revision" {
  python3 - "$fixture/infra/k3s-bootstrap/aiops-runtime.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text());d['revision']='2'*40;p.write_text(json.dumps(d))
PY
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --prepare "$fixture/runtime.tar"
  [ "$status" -ne 0 ]
  [[ "$output" == *'revision mismatch'* ]]
}

@test "archive paths cannot escape the temporary extraction directory" {
  python3 - "$fixture" <<'PY'
import hashlib,io,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);archive=root/'runtime.tar';sha='1'*40
with tarfile.open(archive,'w',format=tarfile.PAX_FORMAT,pax_headers={'comment':sha}) as bundle:
 item=tarfile.TarInfo('../escaped');item.size=1;bundle.addfile(item,io.BytesIO(b'x'))
pin=root/'infra/k3s-bootstrap/aiops-runtime.json';value=json.loads(pin.read_text());value['archiveSha256']=hashlib.sha256(archive.read_bytes()).hexdigest();pin.write_text(json.dumps(value))
PY
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --prepare "$fixture/runtime.tar"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unsafe AIOps runtime archive entry'* ]]
}

@test "explicit migration retry and rollback reach only the pinned installer" {
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --install "$fixture/runtime.tar" target.json bun codex conftest --migrate-target-origin '/old checkout' --retry-transaction transaction-id
  [ "$status" -eq 0 ]
  [ "${lines[8]}" = --migrate-target-origin ]
  [ "${lines[9]}" = '/old checkout' ]
  [ "${lines[10]}" = --retry-transaction ]
  [ "${lines[11]}" = transaction-id ]
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --rollback "$fixture/runtime.tar" transaction-id
  [ "$status" -eq 0 ]
  [ "$output" = $'--rollback\ntransaction-id' ]
  run bash "$fixture/infra/k3s-bootstrap/aiops-install.sh" --install "$fixture/runtime.tar" target.json bun codex conftest --arbitrary-command value
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
