#!/usr/bin/env bats
# Offline validation of the `prod` apps-namespace NetworkPolicies (Pass-5 Open Item #3).
# This component carries no secrets/CRDs, so it builds offline with plain kustomize.

DIR="${BATS_TEST_DIRNAME}"

build() { kustomize build "$DIR"; }

@test "kustomize build renders and lands every policy in namespace prod" {
  run build
  [ "$status" -eq 0 ]
  # all policies present
  for n in default-deny-all allow-dns-egress allow-egress-to-database \
           allow-ingress-from-gateway allow-ingress-metrics-from-observability \
           allow-intra-prod-http allow-ingress-kubelet-probes; do
    echo "$output" | grep -q "name: $n"
  done
  # the namespace transformer pinned them to prod (grep -v drops yq's inter-doc '---' separators)
  [ "$(build | yq 'select(.kind=="NetworkPolicy") | .metadata.namespace' | grep -v '^---' | sort -u)" = "prod" ]
}

@test "manifests are kubeconform-valid (strict)" {
  run bash -c "kustomize build \"$DIR\" | kubeconform -strict -summary"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Invalid: 0"* ]]
  [[ "$output" == *"Errors: 0"* ]]
}

@test "default-deny covers BOTH ingress and egress" {
  policy="$(build | yq 'select(.metadata.name=="default-deny-all")')"
  [ "$(echo "$policy" | yq '.spec.podSelector | length')" -eq 0 ]   # {} = all pods
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Egress
}

@test "egress allows DNS and database:5432 (no general internet egress by default)" {
  # DNS allow targets kube-system kube-dns on 53
  dns="$(build | yq 'select(.metadata.name=="allow-dns-egress")')"
  [[ "$dns" == *"kubernetes.io/metadata.name: kube-system"* ]]
  [[ "$dns" == *"k8s-app: kube-dns"* ]]
  [[ "$dns" == *"port: 53"* ]]
  # database egress is 5432 only, to the database namespace
  db="$(build | yq 'select(.metadata.name=="allow-egress-to-database")')"
  [[ "$db" == *"kubernetes.io/metadata.name: database"* ]]
  [[ "$db" == *"port: 5432"* ]]
}

@test "ingress allows are gateway:8080, observability:9090, and node probes" {
  gw="$(build | yq 'select(.metadata.name=="allow-ingress-from-gateway")')"
  [[ "$gw" == *"kubernetes.io/metadata.name: gateway"* ]]
  [[ "$gw" == *"port: 8080"* ]]
  obs="$(build | yq 'select(.metadata.name=="allow-ingress-metrics-from-observability")')"
  [[ "$obs" == *"kubernetes.io/metadata.name: observability"* ]]
  [[ "$obs" == *"port: 9090"* ]]
  probes="$(build | yq 'select(.metadata.name=="allow-ingress-kubelet-probes")')"
  [[ "$probes" == *"ipBlock"* ]]
  [[ "$probes" == *"10.42.0.0/16"* ]]
}

@test "intra-prod app-to-app on http 8080 is allowed (SSR->API server-side calls)" {
  p="$(build | yq 'select(.metadata.name=="allow-intra-prod-http")')"
  [[ "$p" == *"kubernetes.io/metadata.name: prod"* ]]
  [[ "$p" == *"port: 8080"* ]]
  echo "$p" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$p" | yq -e '.spec.policyTypes' | grep -q Egress
}
