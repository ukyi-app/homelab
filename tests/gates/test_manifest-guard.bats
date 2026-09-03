#!/usr/bin/env bats
# PreToolUse manifest-guard — Edit|Write|MultiEdit가 위험 경로를 건드리면 exit 2로 차단.
# 고확신 경로 패턴만(enc.yaml SOPS MAC 파괴 방지 + 벤더 차트 캐시). 콘텐츠 검사는 CI/bats 담당.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/.claude/hooks/manifest-guard.sh"
  TMP="$(mktemp -d)"
  # jq 부재 PATH(빈 디렉토리) / jq는 있지만 실패하는 PATH. bash는 절대경로로 부른다.
  mkdir -p "$TMP/nojq" "$TMP/badjq"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/badjq/jq"; chmod +x "$TMP/badjq/jq"
  ENC='{"tool_name":"Edit","tool_input":{"file_path":"/repo/platform/cnpg/prod/r2-creds.enc.yaml"}}'
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

# ⚠️ 이 계층은 종료코드 의미가 다르다: 0=허용 · 2=차단 · **그 외 비-0=비차단**(도구가 그대로 실행된다).
# 그래서 파서가 죽었을 때 다른 가드처럼 exit 1/4를 내면 경고만 찍히고 편집이 통과한다 = fail-open.
# 아래 넷은 그 fail-open 경로를 라이브 재현한 것들이다(전부 기존 rc=0이었다).

@test "blocks a SOPS enc.yaml edit even when jq is absent (fail-closed via builtin fallback)" {
  printf '%s' "$ENC" > "$TMP/in.json"
  run env PATH="$TMP/nojq" /bin/bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
}

@test "blocks a SOPS enc.yaml edit when jq exists but fails" {
  printf '%s' "$ENC" > "$TMP/in.json"
  run env PATH="$TMP/badjq:$PATH" /bin/bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
}

@test "still allows a normal manifest when jq is absent (no blanket jq preflight, false positives 0)" {
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/repo/platform/cnpg/prod/cluster.yaml"}}' > "$TMP/in.json"
  run env PATH="$TMP/nojq" /bin/bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 0 ]
}

@test "blocks when the payload carries file_path but the parser cannot extract it" {
  # matcher가 Edit|Write|MultiEdit 전용이라 이 세 도구는 항상 file_path를 갖는다 →
  # 키가 있는데 값이 안 나오면 그건 언제나 파서 붕괴다. 허용으로 읽으면 안 된다.
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
  out="$output"
  run grep -q "파싱하지 못했다" <<<"$out"
  [ "$status" -eq 0 ]
}

@test "never echoes secret-looking file content back" {
  printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/repo/x.enc.yaml","new_string":"super-sensitive-zzz"}}' > "$TMP/in.json"
  run bash "$HOOK" < "$TMP/in.json"
  [ "$status" -eq 2 ]
  ! echo "$output" | grep -q "super-sensitive-zzz"
}

@test "the guard is actually registered as a PreToolUse hook (wiring, not just semantics)" {
  # ⚠️ 위 레인들은 훅 **본체**의 fail-closed 의미론만 증언한다 — 그 훅이 실제로 PreToolUse에
  #    매달려 있는지는 어디에도 증인이 없었다(실측: .claude/settings.json을 `{"hooks":{}}`로
  #    비워도 이 파일 10/10 · test_claude-harness-tracked 2/2가 그대로 초록이었다).
  #    이 훅은 AGENTS.md 최상위 금칙(*.enc.yaml 직접 편집 1회 → SOPS MAC 파괴 → DR 자산 복호
  #    불능)의 **유일한 자동 차단선**이고, 에이전트가 settings.json을 편집하는 경로가 실재한다
  #    (update-config 스킬). matcher 오타 하나·hooks 블록 삭제로 그 차단선이 통째로 사라진다.
  S="$ROOT/.claude/settings.json"
  [ -f "$S" ]
  run jq -e '.hooks.PreToolUse[]
               | select(.matcher == "Edit|Write|MultiEdit")
               | .hooks[]
               | select(.command | endswith("/.claude/hooks/manifest-guard.sh"))' "$S"
  [ "$status" -eq 0 ]   # jq -e: 결과 없음=4 · null/false=1 — 등록이 있어야 정확히 0
  [ -f "$HOOK" ]        # 등록이 가리키는 대상이 실재하는가(경로만 맞고 파일이 없으면 무음 통과)
}
