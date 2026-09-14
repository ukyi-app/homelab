#!/usr/bin/env bash
# AIOps 전용 설치. 일반 host-config와 분리하며 timer·인입·Codex 실행을 활성화하지 않는다.
set -euo pipefail
# 고정 실행 코드·의존성은 역할 UID도 읽는다. 인증·설정은 아래의 명시적 0600/0700으로 제한한다.
umask 0022
repo="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-}"
case "$action" in
  --prepare)
    exec bun "$repo/tools/aiops.ts" host-plan --state-dir "$repo/.scratch/aiops-install/state" --output "${2:-$repo/.scratch/aiops-install/plan}"
    ;;
  --install) ;;
  *) printf '%s\n' 'usage: aiops-install.sh --prepare [output] | --install <config.json> <bun> <codex> <conftest>' >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'root required' >&2; exit 1; }
[ "$#" -eq 5 ] || exit 2
config="$(realpath "$2")"; bun_binary="$(realpath "$3")"; codex_binary="$(realpath "$4")"; conftest_binary="$(realpath "$5")"
for binary in "$bun_binary" "$codex_binary" "$conftest_binary"; do [ -x "$binary" ] || exit 1; done
[ "$("$codex_binary" --version)" = 'codex-cli 0.154.0' ] || { printf '%s\n' 'Codex pin mismatch' >&2; exit 1; }
git -C "$repo" diff --quiet
git -C "$repo" diff --cached --quiet
# 설치 실행 코드가 커밋에 없으면 archive가 조용히 누락하므로 파일 존재도 검사한다.
git -C "$repo" cat-file -e HEAD:tools/aiops-stage.ts
revision="$(git -C "$repo" rev-parse HEAD)"
release="/opt/homelab-aiops/$revision"
"$bun_binary" "$repo/tools/aiops-install-config.ts" check "$config" >/dev/null
if [ -e "$release" ]; then
  printf '%s\n' 'release already exists; verify the existing installation before replacing it' >&2; exit 1
fi
install -d -m 0755 "$release" "$release/bin"
git -C "$repo" archive HEAD | tar -x -C "$release"
install -m 0755 "$bun_binary" "$release/bin/bun"
install -m 0755 "$codex_binary" "$release/bin/codex"
install -m 0755 "$conftest_binary" "$release/bin/conftest"
# 잠금 파일로 설치하고 패키지 lifecycle script는 실행하지 않는다.
(cd "$release" && "$release/bin/bun" install --frozen-lockfile --ignore-scripts)
install -d -m 0755 /opt/homelab-aiops
ln -s "$release" /opt/homelab-aiops/current.new
mv -T /opt/homelab-aiops/current.new /opt/homelab-aiops/current
plan="$(mktemp -d /tmp/aiops-install.XXXXXX)"
trap 'rm -rf "$plan"' EXIT
"$release/bin/bun" "$release/tools/aiops.ts" host-plan --state-dir "$plan/state" --output "$plan/plan" >/dev/null
install -m 0644 "$plan/plan/sysusers.conf" /etc/sysusers.d/homelab-aiops.conf
systemd-sysusers /etc/sysusers.d/homelab-aiops.conf
# 전용 512 MiB 파일시스템이 SQLite/WAL·원문·작업 파일의 합계 상한이다. 기존 파일은 포맷하지 않는다.
image=/var/lib/homelab-aiops.img
if [ ! -e "$image" ]; then
  (umask 0077; truncate -s 512M "$image")
  mkfs.ext4 -q -F "$image"
fi
install -d -m 0711 /var/lib/homelab-aiops
mount_unit="$(systemd-escape --path --suffix=mount /var/lib/homelab-aiops)"
cat > "/etc/systemd/system/$mount_unit" <<'UNIT'
[Unit]
Description=Homelab AIOps bounded persistent storage
Before=aiops-worker.service aiops-ingress.service

[Mount]
What=/var/lib/homelab-aiops.img
Where=/var/lib/homelab-aiops
Type=ext4
Options=loop,nosuid,nodev

[Install]
WantedBy=local-fs.target
UNIT
systemctl daemon-reload
systemctl enable --now "$mount_unit"
install -m 0644 "$plan/plan/tmpfiles.conf" /etc/tmpfiles.d/homelab-aiops.conf
systemd-tmpfiles --create /etc/tmpfiles.d/homelab-aiops.conf
if [ ! -e /var/lib/homelab-aiops/repository ]; then
  git -C "$repo" clone --bare --no-hardlinks "$repo" /var/lib/homelab-aiops/repository
  chmod -R a+rX /var/lib/homelab-aiops/repository
fi
install -m 0600 "$config" /etc/homelab-aiops/config.json
"$release/bin/bun" "$release/tools/aiops-install-config.ts" write /etc/homelab-aiops/config.json "$revision" "$release" >/dev/null
for unit in aiops-worker.service aiops-worker.timer aiops-ingress.service; do
  install -m 0644 "$plan/plan/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
printf '%s\n' 'installed; worker and ingress remain disabled. Complete role credentials and acceptance before activation.'
