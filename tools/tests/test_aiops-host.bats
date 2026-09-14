#!/usr/bin/env bats
# 설치 계획은 호스트를 변경하지 않는 공개 경계다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }

@test "host plan separates roles and leaves activation gated" {
  run aiops host-plan --output "$BATS_TEST_TMPDIR/install"
  [ "$status" -eq 0 ]
  jq -e '.activation == "disabled" and (.roles | length) == 6 and .limits.wholeAttemptSeconds == 1200 and .limits.diskMiB == 512' <<< "$output"
  [ -f "$BATS_TEST_TMPDIR/install/aiops-worker.service" ]
  [ -f "$BATS_TEST_TMPDIR/install/config.example.json" ]
  run aiops readiness --config "$BATS_TEST_TMPDIR/install/config.example.json"
  [ "$status" -eq 1 ]
  jq -e '.ready == false and (.pending | index("subscription-authentication")) != null and (.pending | index("observation-criteria")) != null' <<< "$output"
}

@test "preflight commands create group writable SQLite before the collector starts" {
  run aiops host-plan --output "$BATS_TEST_TMPDIR/install"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$AIOPS_STATE/incidents.sqlite")" = 660 ]
  [ "$(stat -c %a "$AIOPS_STATE")" = 700 ]
  jq -e '.collection.kubectl == "/usr/local/bin/kubectl"' "$BATS_TEST_TMPDIR/install/config.example.json"
  run aiops readiness --config "$BATS_TEST_TMPDIR/install/config.example.json"
  [ "$status" -eq 1 ]
  jq -e '.commissioning.ready == false and (.commissioning.pending | index("acceptance-isolation")) != null and (.commissioning.pending | index("acceptance-diagnosticCases")) == null' <<< "$output"
}

@test "host probe scripts remain readable across UIDs under the CLI umask" {
  run bun tools/tests/helpers/aiops-host-permissions.mjs probe
  [ "$status" -eq 0 ]
}

@test "worker role can traverse job directories without exposing its input" {
  run bun tools/tests/helpers/aiops-host-permissions.mjs worker
  [ "$status" -eq 0 ]
}

@test "installer dependencies remain readable when the caller has a private umask" {
  aiops host-plan --output "$BATS_TEST_TMPDIR/install" >/dev/null
  mkdir "$BATS_TEST_TMPDIR/dependencies"
  cp package.json bun.lock "$BATS_TEST_TMPDIR/dependencies/"
  cat > "$BATS_TEST_TMPDIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'codex-cli 0.154.0'
SH
  chmod +x "$BATS_TEST_TMPDIR/codex"
  # 첫 설치 쓰기를 임시 의존성 설치로 대체하고 종료한다. 호스트 경로에는 쓰지 않는다.
  cat > "$BATS_TEST_TMPDIR/installer-env" <<'SH'
id() { printf '0\n'; }
git() {
  case "$3" in
    diff) return 0 ;;
    rev-parse) printf '%040d\n' 1 ;;
    *) command git "$@" ;;
  esac
}
install() {
  (
    cd "$BATS_TEST_TMPDIR/dependencies" || exit 1
    bun install --frozen-lockfile --ignore-scripts >/dev/null
    stat -c 'dependency-mode=%a' node_modules node_modules/yaml
  )
  exit 77
}

SH
  run env BASH_ENV="$BATS_TEST_TMPDIR/installer-env" bash -c 'umask 0077; exec bash infra/k3s-bootstrap/aiops-install.sh --install "$@"' _ "$BATS_TEST_TMPDIR/install/config.example.json" "$(command -v bun)" "$BATS_TEST_TMPDIR/codex" /usr/bin/true
  [ "$status" -eq 77 ]
  printf '%s\n' "$output" | grep -q '^dependency-mode=755$'
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/dependencies/node_modules")" = 755 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/dependencies/node_modules/yaml")" = 755 ]
}

@test "installer creates missing system configuration directories before writing accounts" {
  export AIOPS_TEST_REPO="$PWD" AIOPS_TEST_BUN
  AIOPS_TEST_BUN="$(command -v bun)"
  mkdir -p "$BATS_TEST_TMPDIR/root/infra/k3s-bootstrap"
  # 호스트 루트 경로만 임시 루트로 옮긴다. 설치 순서와 install/mkdir/mv는 실제 셸을 거친다.
  python3 - "$BATS_TEST_TMPDIR" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])/'root'
text=Path('infra/k3s-bootstrap/aiops-install.sh').read_text()
for prefix in ['/opt/homelab-aiops','/etc/sysusers.d','/etc/tmpfiles.d','/etc/systemd/system']:
    text=text.replace(prefix,str(root)+prefix)
(root/'infra/k3s-bootstrap/aiops-install.sh').write_text(text)
PY
  cat > "$BATS_TEST_TMPDIR/bun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == install ]] && exit 0
[[ "$2" == check ]] && exit 0
shift
exec "$AIOPS_TEST_BUN" "$AIOPS_TEST_REPO/tools/aiops.ts" "$@"
SH
  cat > "$BATS_TEST_TMPDIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'codex-cli 0.154.0'
SH
  chmod +x "$BATS_TEST_TMPDIR/bun" "$BATS_TEST_TMPDIR/codex"
  printf '{}\n' > "$BATS_TEST_TMPDIR/config.json"
  cat > "$BATS_TEST_TMPDIR/installer-env" <<'SH'
id() { printf '0\n'; }
git() {
  case "$3" in
    diff|cat-file) return 0 ;;
    rev-parse) printf '%040d\n' 1 ;;
    archive) tar -cf - --files-from /dev/null ;;
    *) return 90 ;;
  esac
}
systemd-sysusers() {
  test -s "$1" || exit 91
  printf 'account-config-mode=%s\n' "$(stat -c %a "$1")"
  # 실제 계정·파일시스템 생성 경계 직전에 종료한다.
  exit 77
}
SH
  run env BASH_ENV="$BATS_TEST_TMPDIR/installer-env" bash "$BATS_TEST_TMPDIR/root/infra/k3s-bootstrap/aiops-install.sh" --install "$BATS_TEST_TMPDIR/config.json" "$BATS_TEST_TMPDIR/bun" "$BATS_TEST_TMPDIR/codex" /usr/bin/true
  [ "$status" -eq 77 ]
  printf '%s\n' "$output" | grep -q '^account-config-mode=644$'
  [ ! -L "$BATS_TEST_TMPDIR/root/opt/homelab-aiops/current" ]
  for directory in sysusers.d tmpfiles.d systemd/system; do
    [ "$(stat -c %a "$BATS_TEST_TMPDIR/root/etc/$directory")" = 755 ]
  done
}
