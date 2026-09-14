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
git() { if [[ " $* " == *" diff "* ]]; then return 0; fi; command git "$@"; }
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
