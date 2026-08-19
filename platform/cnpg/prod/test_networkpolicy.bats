#!/usr/bin/env bats
# database 계층 NetworkPolicy의 오프라인 검증.
# 전체 `kustomize build platform/cnpg/prod`는 M2 시드에 의존하므로(test_kustomize_build.bats 참조),
# 이 스위트는 독립 파일인 networkpolicy.yaml을 검증한다 — 언제나 오프라인 검증 가능.

NP="${BATS_TEST_DIRNAME}/networkpolicy.yaml"
KUST="${BATS_TEST_DIRNAME}/kustomization.yaml"

@test "networkpolicy.yaml exists, is valid YAML, and is wired into the kustomization" {
  [ -f "$NP" ]
  run yq -e '.' "$NP"; [ "$status" -eq 0 ]
  grep -qE '^\s*-\s*networkpolicy\.yaml' "$KUST"
}

@test "every doc is a NetworkPolicy in namespace database, kubeconform-valid" {
  [ "$(yq 'select(.kind=="NetworkPolicy") | .metadata.namespace' "$NP" | grep -v '^---' | LC_ALL=C sort -u)" = "database" ]
  run bash -c "kubeconform -strict -summary '$NP'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "Invalid: 0"
  [[ "$output" == *"Errors: 0"* ]]
}

@test "ingress is default-denied (the database accepts no unsolicited ingress)" {
  d="$(yq 'select(.metadata.name=="database-default-deny-ingress")' "$NP")"
  [ "$(echo "$d" | yq '.spec.podSelector | length')" -eq 0 ]
  echo "$d" | yq -e '.spec.policyTypes' | grep -q Ingress
}

@test "only prod:5432, cnpg-system, observability:9187, and intra may reach the database" {
  prod="$(yq 'select(.metadata.name=="database-allow-ingress-from-prod")' "$NP")"
  printf '%s' "$prod" | grep -qF -- "kubernetes.io/metadata.name: prod"
  printf '%s' "$prod" | grep -qF -- "port: 5432"
  yq 'select(.metadata.name=="database-allow-ingress-from-cnpg-system")' "$NP" | grep -q 'cnpg-system'
  obs="$(yq 'select(.metadata.name=="database-allow-ingress-metrics-from-observability")' "$NP")"
  printf '%s' "$obs" | grep -qF -- "observability"
  printf '%s' "$obs" | grep -qF -- "port: 9187"
  yq 'select(.metadata.name=="database-allow-ingress-intra")' "$NP" | grep -q 'podSelector'
}

@test "egress is intentionally NOT default-denied (CNPG needs API/R2/replication egress)" {
  # 이 파일의 어떤 policy도 Egress를 제한하지 않는다 — 의도적이며 문서화된 범위 결정.
  run bash -c "yq 'select(.spec.policyTypes[] == \"Egress\")' '$NP'"
  [ -z "$output" ]
}

@test "kubelet probe ingress is node-only (pod-CIDR-wide ipBlock would defeat default-deny)" {
  p="$(yq 'select(.metadata.name=="database-allow-ingress-kubelet-probes")' "$NP")"
  printf '%s' "$p" | grep -qF -- "cidr: 10.42.0.1/32"   # 노드(cni0)만 — /16은 전 파드에 5432 개방
  case "$p" in *"cidr: 10.42.0.0/16"*) false ;; *) true ;; esac
  printf '%s' "$p" | grep -qF -- "port: 8000"
  [[ "$p" != *"port: 5432"* ]]           # probe 정책에 5432가 되살아나면 안 된다
}
