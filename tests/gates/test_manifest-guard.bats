#!/usr/bin/env bats
# PreToolUse manifest-guard — Edit|Write|MultiEdit가 위험 경로를 건드리면 exit 2로 차단.
# 고확신 경로 패턴만(enc.yaml SOPS MAC 파괴 방지 + 벤더 차트 캐시). 콘텐츠 검사는 CI/bats 담당.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/.claude/hooks/manifest-guard.sh"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "blocks direct Edit of a SOPS *.enc.yaml file" {
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/repo/platform/cnpg/prod/r2-creds.enc.yaml"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "sops"
}

@test "blocks Write into the vendor helm chart-pull cache" {
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/repo/platform/cnpg/prod/charts/cluster/values.yaml"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
}

@test "allows editing a normal tracked manifest" {
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/repo/platform/cnpg/prod/cluster.yaml"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 0 ]
}

@test "allows tool input that carries no file_path" {
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"sops -d x.enc.yaml"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 0 ]
}

@test "allows empty stdin (fail-open, never crashes the tool call)" {
  run bash "$HOOK" < /dev/null
  [ "$status" -eq 0 ]
}

@test "never echoes secret-looking file content back" {
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/repo/x.enc.yaml","new_string":"super-sensitive-zzz"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
  ! echo "$output" | grep -q "super-sensitive-zzz"
}
