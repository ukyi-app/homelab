#!/usr/bin/env bash
# homelab은 실행기 release만 핀한다. 실제 설치 구현은 검증된 aiops archive에 있다.
set -euo pipefail
umask 0022
homelab_root="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-}"
case "$action" in
  --prepare) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2 ;;
  --install)
    [ "$#" -ge 6 ] || exit 2
    options=("${@:7}")
    for ((index=0; index<${#options[@]}; index+=2)); do
      case "${options[index]}" in --migrate-target-origin|--retry-transaction) ;; *) exit 2 ;; esac
      [ -n "${options[index+1]:-}" ] || exit 2
    done
    ;;
  --rollback) [ "$#" -eq 3 ] || exit 2 ;;
  *) printf '%s\n' 'usage: aiops-install.sh --prepare <runtime.tar> [output] | --install <runtime.tar> <config.json> <bun> <codex> <conftest> [--migrate-target-origin <expected-old-url>] [--retry-transaction <id>] | --rollback <runtime.tar> <id>' >&2; exit 2 ;;
esac
temporary="$(mktemp -d /tmp/homelab-aiops-runtime.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT
# 검증 후 원본 파일이 바뀌어도 실행 바이트는 바뀌지 않는다. root 설치 시 사본도 root 소유다.
python3 - "$2" "$temporary/runtime.tar" <<'PYTHON'
import os,pathlib,stat,sys
fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
with os.fdopen(fd,'rb') as source:
 if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
  raise SystemExit('runtime archive must be a regular file')
 data=source.read(32*1024*1024+1)
 if len(data)>32*1024*1024:
  raise SystemExit('runtime archive exceeds 32MiB')
 pathlib.Path(sys.argv[2]).write_bytes(data)
os.chmod(sys.argv[2],0o444)
PYTHON
archive="$temporary/runtime.tar"
pin="$homelab_root/infra/k3s-bootstrap/aiops-runtime.json"
# archive를 실행하거나 풀기 전에 homelab이 승인한 바이트와 일치하는지 검사한다.
release_identity="$(python3 - "$pin" "$archive" <<'PYTHON'
import hashlib,json,pathlib,re,sys,tarfile
pin=json.loads(pathlib.Path(sys.argv[1]).read_text())
if set(pin)!={'version','repository','revision','archiveSha256'} or pin['version']!=1 or pin['repository']!='ukyi-app/aiops':
 raise SystemExit('invalid AIOps runtime pin')
if not re.fullmatch('[0-9a-f]{40}',str(pin['revision'])) or not re.fullmatch('[0-9a-f]{64}',str(pin['archiveSha256'])):
 raise SystemExit('AIOps runtime release is not pinned; keep installation disabled')
archive=pathlib.Path(sys.argv[2])
if archive.is_symlink() or not archive.is_file() or archive.stat().st_size>32*1024*1024:
 raise SystemExit('invalid AIOps runtime archive')
with archive.open('rb') as file:
 if hashlib.file_digest(file,'sha256').hexdigest()!=pin['archiveSha256']:
  raise SystemExit('AIOps runtime archive digest mismatch')
with tarfile.open(archive,'r:') as bundle:
 if bundle.pax_headers.get('comment')!=pin['revision']:
  raise SystemExit('AIOps runtime archive revision mismatch')
print(pin['revision']+' '+pin['archiveSha256'])
PYTHON
)"
runtime_revision="${release_identity%% *}"
archive_sha256="${release_identity##* }"
mkdir "$temporary/source"
python3 - "$archive" "$temporary/source" <<'PYTHON'
import pathlib,sys,tarfile
with tarfile.open(sys.argv[1],'r:') as bundle:
 for entry in bundle.getmembers():
  path=pathlib.PurePosixPath(entry.name)
  if path.is_absolute() or '..' in path.parts or not (entry.isfile() or entry.isdir()):
   raise SystemExit('unsafe AIOps runtime archive entry')
 bundle.extractall(sys.argv[2],filter='data')
PYTHON
installer="$temporary/source/scripts/aiops-install.sh"
[ -f "$installer" ] || { printf '%s\n' 'AIOps release installer missing' >&2; exit 1; }
if [ "$action" = --prepare ]; then
  bash "$installer" --prepare "${3:-$homelab_root/.scratch/aiops-install/plan}"
elif [ "$action" = --rollback ]; then
  bash "$installer" --rollback "$3"
else
  bash "$installer" --install "$3" "$archive" "$runtime_revision" "$archive_sha256" "$4" "$5" "$6" "${options[@]}"
fi
