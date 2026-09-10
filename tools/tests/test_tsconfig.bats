#!/usr/bin/env bats
# tsconfig은 erasableSyntaxOnly를 강제해 app-shared .mts가 node strip-types와 양립하게 한다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "tsconfig enforces erasable-syntax + noEmit + ts-extension imports" {
  [ -f tsconfig.json ]
  run jq -r '.compilerOptions.erasableSyntaxOnly' tsconfig.json
  [ "$output" = "true" ]
  run jq -r '.compilerOptions.noEmit' tsconfig.json
  [ "$output" = "true" ]
  run jq -r '.compilerOptions.allowImportingTsExtensions' tsconfig.json
  [ "$output" = "true" ]
}

@test "typecheck passes on TypeScript sources" {
  run bun run typecheck
  [ "$status" -eq 0 ]
}
