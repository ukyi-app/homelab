#!/usr/bin/env bats
# files 데이터 내구성 posture (H2/M14): bulk-ssd SC와 files-data PV가 둘 다 라이브에서 Retain인지.
# git 승격(B5.1)이 라이브에 실제 반영됐고 인플레이스 마이그레이션(SC delete+recreate)이 완료됐는지 확인한다.
# LIVE: KUBECONFIG = files-prod가 sync된 k3s VM 필요. @test 이름은 영어.

@test "bulk-ssd StorageClass is Retain live (git-live drift guard)" {
  run bash -c "kubectl get sc bulk-ssd -o jsonpath='{.reclaimPolicy}'"
  [ "$status" -eq 0 ]
  [ "$output" = "Retain" ]
}

@test "the bound files-data PV carries Retain (existing PV migrated, not only new ones)" {
  # SC를 Retain으로 바꿔도 이미 프로비저닝된 PV는 provision 시점 정책을 보유한다 — 라이브 patch 여부를 직접 확인.
  pv="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="files-data")]}{.metadata.name}{"\n"}{end}' | head -1)"
  [ -n "$pv" ]
  run bash -c "kubectl get pv '$pv' -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'"
  [ "$status" -eq 0 ]
  [ "$output" = "Retain" ]
}
