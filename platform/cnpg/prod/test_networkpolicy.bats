#!/usr/bin/env bats
# Offline validation of the database-tier NetworkPolicies (Pass-5 Open Item #3).
# The full `kustomize build platform/cnpg/prod` depends on M2 seeds (see test_kustomize_build.bats),
# so this suite validates the standalone networkpolicy.yaml — always offline-checkable.

NP="${BATS_TEST_DIRNAME}/networkpolicy.yaml"
KUST="${BATS_TEST_DIRNAME}/kustomization.yaml"

@test "networkpolicy.yaml exists, is valid YAML, and is wired into the kustomization" {
  [ -f "$NP" ]
  run yq -e '.' "$NP"; [ "$status" -eq 0 ]
  grep -qE '^\s*-\s*networkpolicy\.yaml' "$KUST"
}

@test "every doc is a NetworkPolicy in namespace database, kubeconform-valid" {
  [ "$(yq 'select(.kind=="NetworkPolicy") | .metadata.namespace' "$NP" | grep -v '^---' | sort -u)" = "database" ]
  run bash -c "kubeconform -strict -summary '$NP'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Invalid: 0"* ]]
  [[ "$output" == *"Errors: 0"* ]]
}

@test "ingress is default-denied (the database accepts no unsolicited ingress)" {
  d="$(yq 'select(.metadata.name=="database-default-deny-ingress")' "$NP")"
  [ "$(echo "$d" | yq '.spec.podSelector | length')" -eq 0 ]
  echo "$d" | yq -e '.spec.policyTypes' | grep -q Ingress
}

@test "only prod:5432, cnpg-system, observability:9187, and intra may reach the database" {
  prod="$(yq 'select(.metadata.name=="database-allow-ingress-from-prod")' "$NP")"
  [[ "$prod" == *"kubernetes.io/metadata.name: prod"* ]]
  [[ "$prod" == *"port: 5432"* ]]
  yq 'select(.metadata.name=="database-allow-ingress-from-cnpg-system")' "$NP" | grep -q 'cnpg-system'
  obs="$(yq 'select(.metadata.name=="database-allow-ingress-metrics-from-observability")' "$NP")"
  [[ "$obs" == *"observability"* ]]
  [[ "$obs" == *"port: 9187"* ]]
  yq 'select(.metadata.name=="database-allow-ingress-intra")' "$NP" | grep -q 'podSelector'
}

@test "egress is intentionally NOT default-denied (CNPG needs API/R2/replication egress)" {
  # No policy in this file restricts Egress — that is a deliberate, documented scoping decision.
  run bash -c "yq 'select(.spec.policyTypes[] == \"Egress\")' '$NP'"
  [ -z "$output" ]
}

@test "kubelet probe ingress is allowed from the cluster CIDR so CNPG pods stay Ready" {
  p="$(yq 'select(.metadata.name=="database-allow-ingress-kubelet-probes")' "$NP")"
  [[ "$p" == *"10.42.0.0/16"* ]]
  [[ "$p" == *"port: 8000"* ]]
}
