#!/usr/bin/env bats
# bun 단일 패키지 — packageManager bun 핀 + 플랫폼 게이트 스크립트 노출 + bun 타입 의존.
# (pnpm workspace는 제거됨 — JS 워크스페이스 멤버 0, 차트는 Helm)
# ⚠️ 중간 단언은 [ ]/case만 — bash 3.2 [[ ]] 침묵 통과.

@test "package.json pins bun and exposes the platform gates" {
  run jq -r '.packageManager' package.json
  case "$output" in bun@*) : ;; *) false ;; esac
  run jq -r '.scripts | keys | join(",")' package.json
  case "$output" in *verify:ledger*) : ;; *) false ;; esac
  case "$output" in *verify:skeleton*) : ;; *) false ;; esac
  case "$output" in *typecheck*) : ;; *) false ;; esac
}

@test "bun type deps present (types:[bun] needs @types/bun)" {
  run jq -r '.devDependencies | keys | join(",")' package.json
  case "$output" in *@types/bun*) : ;; *) false ;; esac
  case "$output" in *typescript*) : ;; *) false ;; esac
}

@test "no pnpm workspace or lockfile remains" {
  [ ! -f pnpm-workspace.yaml ]
  [ ! -f pnpm-lock.yaml ]
}

@test "bun lockfile is text format and committed" {
  [ -f bun.lock ]
  run git ls-files --error-unmatch bun.lock
  [ "$status" -eq 0 ]
}
