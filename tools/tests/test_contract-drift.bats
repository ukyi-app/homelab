#!/usr/bin/env bats
# 동봉 계약 매니페스트·정규화 로직 가드 (CI-safe — 라이브 raw fetch는 contract-drift.yaml 워크플로 전용).
# ⚠️ 중간 부정 단언은 run+[ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; M="tools/vendored-contract.json"; }

@test "vendored-contract manifest is valid JSON with existing local sources" {
  jq -e '.vendored | length > 0' "$M"
  for s in $(jq -r '.vendored[].source' "$M"); do
    [ -f "$s" ] || { echo "누락 source: $s"; return 1; }
  done
}

@test "vendored-contract excludes files repo (Rust — no vendored seal tooling)" {
  # ⚠️ 이 레인에서 `jq`는 원칙상 비대상이었다(rc 어휘가 grep과 달라 일괄 전환이 위험하다). 이 자리만
  #    예외인 이유: `jq -e`는 **술어 결과와 대상 부재를 서로 다른 rc로 가른다**.
  #    2026-08-29 실측(jq 1.8.1): 무매치(null)=**1** · 매치=0 · 파일 부재=**2** · 빈 파일=4 ·
  #    파싱 오류/스키마 밖(`.vendored` 부재)=5. 즉 `-eq 1`이 받는 것은 "index가 null" 하나뿐이다.
  #    예전 `-ne 0`은 $M 리네임(rc 2)도 "files repo 없음"으로 읽었고, 이 @test에는 형제 양성 단언이
  #    없다 — :7의 매니페스트 실재 단언은 **다른 @test**라 `bats -f` 단일 실행에서 증인이 못 된다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run jq -e '[.vendored[].targets[].repo] | index("files")' "$M"
  [ "$status" -eq 1 ]
}

@test "cert targets require exact normalization (public sealing cert must be byte-identical)" {
  n=$(jq -r '[.vendored[] | select(.source|endswith(".pem")) | .targets[] | select(.normalize!="exact")] | length' "$M")
  [ "$n" -eq 0 ]
}

@test "drift checker self-test passes (offline normalize unit — ts formatter-insensitive: ws/;/,, pem exact)" {
  run bun tools/contract-drift-check.ts --self-test
  [ "$status" -eq 0 ]
}
