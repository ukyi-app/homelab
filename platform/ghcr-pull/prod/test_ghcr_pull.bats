#!/usr/bin/env bats
# ghcr-pull(prod NS imagePullSecret) 배선 증인. @test 이름은 영어.
#
# 왜 새 파일인가: 이 컴포넌트에는 bats가 하나도 없었고, 이 디렉토리를 **실 트리에서** 재는 형제도
# 레포 전체에 없다(2026-09-04 전수 확인 — `tools/tests/test_seal-batch.bats`의 히트는 전부
# `$TMP/platform/ghcr-pull/...` 픽스처 경로이고, `scripts/sealed-guard.sh`는 봉인 여부만 본다).
# 그래서 형제에 얹을 자리가 없어 최소 @test 하나로 신설한다(감사 5라운드 티켓 51 carry-1의
# 마지막 수단 경로).
#
# 병(2026-09-04 실측): kustomization의 resources에서 ghcr-pull.sealed.yaml 한 줄을 지워도
# `scripts/sealed-guard.sh` rc 0 · `scripts/check-skeleton.sh` rc 0 · sealed-secrets/files/gates
# bats 70/70 전건 초록이었다. 이 컴포넌트의 resources는 그 한 줄뿐이라 렌더가 통째로 비고,
# prune:true인 Application이 prod NS의 ghcr-pull Secret을 지운다 — 그 뒤 재기동하는 모든 앱
# 파드가 private GHCR에서 ImagePullBackOff가 된다(패키지 가시성은 의도적으로 private 유지).
# ⚠️ 중간 단언은 `[ ]`만 — bash 3.2 [[ ]] 침묵 통과.
setup() { D="${BATS_TEST_DIRNAME}"; S="$D/ghcr-pull.sealed.yaml"; K="$D/kustomization.yaml"; }

@test "the imagePullSecret is sealed for prod and wired into the kustomization" {
  [ -f "$S" ]
  run yq '.kind' "$S"; [ "$output" = "SealedSecret" ]
  run yq '.spec.template.metadata.namespace // .metadata.namespace' "$S"; [ "$output" = "prod" ]
  run yq '.metadata.name' "$S"; [ "$output" = "ghcr-pull" ]
  # ⚠️ **파일 실재 ≠ 렌더 포함** — 원문 grep은 그 구별을 못 한다. 건수 바닥값·length==N도 쓰지
  #    않는다(resources는 정당하게 늘고 준다). 멤버십은 **정확 일치**로 잰다 — yq의 배열 contains는
  #    원소마다 부분문자열 판정이라 이름이 서로의 접미가 되는 자리에서 조용히 참이 된다(2026-09-04 실측).
  yq '.resources[]' "$K" | grep -qxF 'ghcr-pull.sealed.yaml' \
    || { echo "kustomization resources에 ghcr-pull.sealed.yaml이 없다 — 렌더에서 빠지면 프룬된다"; false; }
}
