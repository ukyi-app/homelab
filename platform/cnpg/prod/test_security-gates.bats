#!/usr/bin/env bats
# 접속 계층 보안 게이트 (PR-C) — admin superuser 롤(C1) + tailscale→pg netpol(C2) + pg-rw tailscale LB(C3).
# 소스 매니페스트를 yq/grep으로 직접 검증(CI-safe, KSOPS 불요 → required gate 보호). 전체 KSOPS 렌더 +
# kubeconform은 test_kustomize_build.bats(.ci-exclude, 로컬)가 커버. ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
DIR="${BATS_TEST_DIRNAME}"

# ── C1: GUI/로컬 직결 admin superuser 롤 ──────────────────────────────────────
@test "cluster.yaml defines app_admin managed role with full SSA-explicit fields" {
  # yq `and` 연산자는 bool 연쇄에서 false를 반환하는 함정 → [bools]|all로 검사(검증된 패턴).
  run yq -e 'select(.kind=="Cluster").spec.managed.roles[] | select(.name=="app_admin") | [(.superuser==true), (.login==true), (.ensure=="present"), (.inherit==true), (.connectionLimit==-1)] | all' "$DIR/cluster.yaml"
  [ "$status" -eq 0 ]
}

@test "app_admin references the pg-admin-credentials passwordSecret" {
  run yq -e 'select(.kind=="Cluster").spec.managed.roles[] | select(.name=="app_admin") | .passwordSecret.name=="pg-admin-credentials"' "$DIR/cluster.yaml"
  [ "$status" -eq 0 ]
}

@test "managed.roles is a non-empty SSA-atomic list (provision-db appends owner/ro)" {
  run yq -e 'select(.kind=="Cluster").spec.managed.roles | length >= 1' "$DIR/cluster.yaml"
  [ "$status" -eq 0 ]
}

@test "pg-admin-credentials secret is encrypted at rest (SOPS, no plaintext creds)" {
  run grep -c 'ENC\[AES256_GCM' "$DIR/pg-admin-credentials.enc.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]                                    # username + password 암호화
  run grep -q 'app_admin' "$DIR/pg-admin-credentials.enc.yaml"
  [ "$status" -ne 0 ]                                    # 평문 username/password 노출 0
}

# ── C2: tailscale → pg(5432) ingress (default-deny 유지) ──────────────────────
@test "cnpg netpol allows ingress from the tailscale namespace on 5432" {
  run yq -e 'select(.kind=="NetworkPolicy" and .metadata.name=="cnpg-allow-tailscale") | [(.spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]=="tailscale"), (.spec.ingress[0].ports[0].port==5432)] | all' "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
}

@test "database default-deny-ingress baseline is preserved (crown-jewel)" {
  run yq -e 'select(.kind=="NetworkPolicy" and .metadata.name=="database-default-deny-ingress") | .spec.policyTypes[0]=="Ingress"' "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
}
