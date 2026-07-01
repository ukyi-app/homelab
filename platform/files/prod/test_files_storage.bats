#!/usr/bin/env bats
# files-data PVC 회귀 가드. @test 이름은 영어(디렉토리 실행 시 한글 인코딩 깨짐 — 검증된 버그).
PVC="$BATS_TEST_DIRNAME/pvc.yaml"

@test "pvc uses bulk-ssd storageClass explicitly" {
  run yq '.spec.storageClassName' "$PVC"
  [ "$output" = "bulk-ssd" ]
}

@test "pvc is ReadWriteOnce" {
  run yq '.spec.accessModes[0]' "$PVC"
  [ "$output" = "ReadWriteOnce" ]
}

@test "pvc carries Prune=false to resist accidental prune" {
  run yq '.metadata.annotations."argocd.argoproj.io/sync-options"' "$PVC"
  [ "$output" = "Prune=false" ]
}
