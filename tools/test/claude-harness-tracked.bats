#!/usr/bin/env bats
# .claude/ 선택적 un-ignore — 하네스 자산(settings/hooks/agents/commands/skills)은
# 추적, 런타임/로컬 설정/크레덴셜은 계속 무시. .gitignore 규칙 회귀 고정.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "claude harness assets are tracked (not gitignored)" {
  run git -C "$ROOT" check-ignore -q .claude/settings.json
  [ "$status" -eq 1 ]
  run git -C "$ROOT" check-ignore -q .claude/hooks/manifest-guard.sh
  [ "$status" -eq 1 ]
  run git -C "$ROOT" check-ignore -q .claude/skills/argo/SKILL.md
  [ "$status" -eq 1 ]
  run git -C "$ROOT" check-ignore -q .claude/commands/x.md
  [ "$status" -eq 1 ]
}

@test "claude runtime and local settings stay gitignored" {
  run git -C "$ROOT" check-ignore -q .claude/settings.local.json
  [ "$status" -eq 0 ]
  run git -C "$ROOT" check-ignore -q .claude/.credentials.json
  [ "$status" -eq 0 ]
  run git -C "$ROOT" check-ignore -q .claude/projects
  [ "$status" -eq 0 ]
}
