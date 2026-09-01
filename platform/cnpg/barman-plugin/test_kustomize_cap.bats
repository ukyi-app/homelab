#!/usr/bin/env bats
# barman-plugin 오버레이 증인. @test 이름은 영어.
#
# ⚠️ 이 파일이 필요한 이유: `tools/check-resource-limits.ts`는 이 디렉토리를 **못 본다** —
#    `tools/lib/repo-walk.ts`가 벤더 경로를 스캔 범위에서 빼기 때문이다. 즉 Deployment 쪽 캡은
#    저 게이트로 회귀 검출이 안 된다. 렌더 결과를 직접 단언하는 이 파일이 유일한 증인이다.
#    (사이드카 쪽 캡은 ObjectStore라 check-resource-limits가 잡는다 — 그쪽은 이중으로 덮인다.)
#
# ⚠️ 중간 단언은 `[ ]`만 쓴다(bash 3.2에서 중간 `[[ ]]`는 침묵 통과한다).

setup() {
  DIR="$BATS_TEST_DIRNAME"
  command -v kustomize >/dev/null || skip "kustomize 미설치"
  RENDER="$BATS_TEST_TMPDIR/rendered.yaml"
  kustomize build "$DIR" > "$RENDER" 2>"$BATS_TEST_TMPDIR/err" || {
    cat "$BATS_TEST_TMPDIR/err" >&2
    return 1
  }
}

@test "overlay renders and injects a memory limit on the barman-cloud Deployment" {
  run yq 'select(.kind == "Deployment" and .metadata.name == "barman-cloud")
          | .spec.template.spec.containers[] | select(.name == "barman-cloud") | .resources.limits.memory' "$RENDER"
  [ "$status" -eq 0 ]
  [ "$output" = "48Mi" ]
}

@test "the injected block carries cpu and memory requests too" {
  # ⚠️ `[a, b] | join(",")`은 쓰지 않는다 — select가 비매치 문서마다 빈 줄을 내 join이 무너진다.
  run yq 'select(.kind == "Deployment" and .metadata.name == "barman-cloud")
          | .spec.template.spec.containers[] | select(.name == "barman-cloud") | .resources.requests.cpu' "$RENDER"
  [ "$status" -eq 0 ]
  [ "$output" = "10m" ]

  run yq 'select(.kind == "Deployment" and .metadata.name == "barman-cloud")
          | .spec.template.spec.containers[] | select(.name == "barman-cloud") | .resources.requests.memory' "$RENDER"
  [ "$status" -eq 0 ]
  [ "$output" = "24Mi" ]
}

# ⚠️ 이 @test가 이 파일의 존재 이유다 — core/v1 `Container.args`는 patchMergeKey 없는 atomic
#    []string이라, patch가 args를 건드리는 순간 리스트가 **통째로 교체**되어 `operator` 서브커맨드와
#    TLS 경로가 사라지고 Deployment가 기동 불가가 된다(실측). resources는 정상 주입되므로 위 두
#    @test는 그 사고를 원리적으로 못 잡는다.
@test "the vendor args list survives the patch intact" {
  run yq 'select(.kind == "Deployment" and .metadata.name == "barman-cloud")
          | .spec.template.spec.containers[] | select(.name == "barman-cloud") | .args | length' "$RENDER"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]

  for a in operator --server-cert --server-key --client-cert --server-address --leader-elect; do
    run yq "select(.kind == \"Deployment\" and .metadata.name == \"barman-cloud\")
            | .spec.template.spec.containers[] | select(.name == \"barman-cloud\")
            | .args | map(select(. == \"$a\" or (. | test(\"^${a}=\")))) | length" "$RENDER"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
  done
}

@test "the overlay does not add or drop any vendor document" {
  vendor="$(grep -c '^---$' "$DIR/manifest.yaml")"
  rendered="$(grep -c '^---$' "$RENDER")"
  [ "$vendor" = "$rendered" ]
}

@test "the vendor manifest keeps resources empty (patch must not be inlined into it)" {
  # 캡이 벤더 파일로 새어 들어가면 「벤더 파일 수정 금지」가 조용히 깨지고 re-vendor에서 유실된다.
  run grep -qE '^\s+resources: \{\}\s*$' "$DIR/manifest.yaml"
  [ "$status" -eq 0 ]
}
