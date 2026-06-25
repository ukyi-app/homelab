#!/usr/bin/env bats
# 접속 계층 보안 게이트 (PR-C) — admin superuser 롤(C1) + tailscale→pg netpol(C2) + pg-rw tailscale LB(C3).
# 소스 매니페스트를 yq/grep으로 직접 검증(CI-safe, KSOPS 불요 → required gate 보호). 전체 KSOPS 렌더 +
# kubeconform은 test_kustomize_build.bats(.ci-exclude, 로컬)가 커버. ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).
DIR="${BATS_TEST_DIRNAME}"

# ── C1: GUI/로컬 직결 admin superuser 롤 ──────────────────────────────────────
@test "cluster.yaml defines ukkiee managed role with full SSA-explicit fields" {
  # ★존재 가드 먼저(vacuous-truth 방지): select가 빈 스트림이면 [bools]|all=[]|all=true로 false-green이 된다.
  #   ukkiee 롤이 정확히 1개인지 length==1로 단언 — 삭제/개명 시 RED.
  run yq -e '[(.spec.managed.roles[] | select(.name=="ukkiee"))] | length == 1' "$DIR/cluster.yaml"
  [ "$status" -eq 0 ]
  # 필드 값(yq `and` 연쇄 함정 → [bools]|all). 존재 가드가 위에서 보장하므로 여긴 비-vacuous.
  run yq -e '.spec.managed.roles[] | select(.name=="ukkiee") | [(.superuser==true), (.login==true), (.ensure=="present"), (.inherit==true), (.connectionLimit==-1)] | all' "$DIR/cluster.yaml"
  [ "$status" -eq 0 ]
}

@test "ukkiee references the pg-admin-credentials passwordSecret" {
  run yq -e 'select(.kind=="Cluster").spec.managed.roles[] | select(.name=="ukkiee") | .passwordSecret.name=="pg-admin-credentials"' "$DIR/cluster.yaml"
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
  run grep -q 'ukkiee' "$DIR/pg-admin-credentials.enc.yaml"
  [ "$status" -ne 0 ]                                    # 평문 username/password 노출 0
}

# ── C2: tailscale → pg(5432) ingress (default-deny 유지) ──────────────────────
# ★멀티독 함정: networkpolicy.yaml은 7-doc. `select(...)|[bools]|all`은 비매칭 doc마다 []|all=true를 내고
#   yq -e는 멀티독 스트림에서 하나라도 true면 exit 0이라 규칙 삭제/포트변경/네임스페이스확대가 false-green이 된다.
#   → yq ea로 매칭 doc만 [select]로 모아 length==1 존재 가드 + .[0] 단일값 필드 단언(yq `and` 함정도 회피).
@test "cnpg netpol allows ingress from the tailscale namespace on 5432 (non-vacuous)" {
  SEL='[select(.kind=="NetworkPolicy" and .metadata.name=="cnpg-allow-tailscale")]'
  run yq ea -e "$SEL | length == 1" "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
  run yq ea -e "$SEL | .[0].spec.ingress[0].from[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"] == \"tailscale\"" "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
  run yq ea -e "$SEL | .[0].spec.ingress[0].ports[0].port == 5432" "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
}

@test "database default-deny-ingress baseline is preserved (crown-jewel, non-vacuous)" {
  SEL='[select(.kind=="NetworkPolicy" and .metadata.name=="database-default-deny-ingress")]'
  run yq ea -e "$SEL | length == 1" "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
  run yq ea -e "$SEL | .[0].spec.policyTypes[0] == \"Ingress\"" "$DIR/networkpolicy.yaml"
  [ "$status" -eq 0 ]
}

# ── C3: pg-rw tailscale LoadBalancer ─────────────────────────────────────────
@test "pg-rw-tailscale is a tailscale LoadBalancer exposing 5432 with a stable hostname" {
  run yq -e '[(.spec.type=="LoadBalancer"), (.spec.loadBalancerClass=="tailscale"), (.metadata.annotations["tailscale.com/hostname"]=="pg-rw"), (.spec.ports[0].port==5432), (.spec.ports[0].targetPort==5432)] | all' "$DIR/pg-rw-tailscale-service.yaml"
  [ "$status" -eq 0 ]
}

@test "pg-rw-tailscale selects the CNPG cluster pods (primary on single-instance)" {
  run yq -e '.spec.selector["cnpg.io/cluster"]=="pg"' "$DIR/pg-rw-tailscale-service.yaml"
  [ "$status" -eq 0 ]
}
