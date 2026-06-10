#!/usr/bin/env bats

# East-west isolation posture (Pass-5 Open Item #3): default-deny + minimal allows on the `prod`
# (apps) and `database` (CNPG) namespaces. A compromised public app must NOT reach the database
# except via Postgres 5432; everything else is denied.
# LIVE: requires kubectl context = k3s VM with M3+M4 synced and the network-policies component
# applied. These assert real enforcement (kube-router), not just rendered manifests.

@test "the prod default-deny and database default-deny policies are applied" {
  run bash -c "kubectl -n prod get netpol default-deny-all -o name"
  [ "$status" -eq 0 ]
  run bash -c "kubectl -n database get netpol database-default-deny-ingress -o name"
  [ "$status" -eq 0 ]
}

@test "prod app pods are Ready under default-deny (kubelet probes survive the policy)" {
  # If the probe ipBlock were wrong, default-deny-ingress would crash-loop the apps.
  run bash -c "kubectl -n prod get pods -l app.kubernetes.io/name -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}{end}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"False"* ]]
}

@test "NEGATIVE: a pod outside prod/cnpg-system/observability CANNOT reach the database on 5432" {
  # Run an ephemeral client in the `default` namespace (not an allowed source) — the connect must
  # fail/time out because database-default-deny-ingress drops it.
  run bash -c "kubectl -n default run npd-neg-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'nc -w 5 -z pg-rw.database.svc.cluster.local 5432; echo rc=\$?'"
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"rc=143"* ]]   # refused/timed-out, never rc=0
}

@test "POSITIVE: a prod-namespace client CAN reach the database on 5432" {
  run bash -c "kubectl -n prod run npd-pos-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'nc -w 5 -z pg-rw.database.svc.cluster.local 5432; echo rc=\$?'"
  [[ "$output" == *"rc=0"* ]]
}

@test "NEGATIVE: prod egress to a non-database, non-DNS destination is denied by default" {
  # prod's egress default-deny allows only DNS, database:5432, and intra-prod:8080; external must fail.
  run bash -c "kubectl -n prod run npd-egr-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'nc -w 5 -z 1.1.1.1 443; echo rc=\$?'"
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"rc=143"* ]]
}
