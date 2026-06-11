#!/usr/bin/env bats

# 동서(east-west) 격리 자세 (Pass-5 Open Item #3): `prod`(앱)와 `database`(CNPG)
# 네임스페이스에 default-deny + 최소 allow. 공개 앱이 침해되더라도 Postgres 5432를
# 통한 경로 외에는 데이터베이스에 닿을 수 없어야 하며, 나머지는 전부 거부된다.
# LIVE: kubectl 컨텍스트 = M3+M4가 sync되고 network-policies 컴포넌트가 적용된 k3s VM 필요.
# 렌더된 매니페스트가 아니라 실제 적용(kube-router)을 검증한다.

@test "the prod default-deny and database default-deny policies are applied" {
  run bash -c "kubectl -n prod get netpol default-deny-all -o name"
  [ "$status" -eq 0 ]
  run bash -c "kubectl -n database get netpol database-default-deny-ingress -o name"
  [ "$status" -eq 0 ]
}

@test "prod app pods are Ready under default-deny (kubelet probes survive the policy)" {
  # 프로브 ipBlock이 잘못돼 있다면 default-deny-ingress 때문에 앱이 crash-loop에 빠진다.
  run bash -c "kubectl -n prod get pods -l app.kubernetes.io/name -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}{end}'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"False"* ]]
}

# ⚠️ 모든 nc는 `sleep 8` 후 실행한다: kube-router는 새 파드의 POD-FW 룰을 파드 생성 후
# 수 초 지나서 설치하므로, 파드의 첫 명령으로 즉시 연결하면 강제 공백(미설치 창)을 통과해
# NEGATIVE 테스트가 거짓 실패한다 (라이브 검증 2026-06-11 — nft 카운터로 확인).

@test "NEGATIVE: a pod outside prod/cnpg-system/observability CANNOT reach the database on 5432" {
  # 허용 소스가 아닌 `default` 네임스페이스에서 임시 클라이언트를 띄운다 — database-default-deny-ingress가
  # 드롭하므로 연결은 실패하거나 타임아웃돼야 한다.
  run bash -c "kubectl -n default run npd-neg-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'sleep 8; nc -w 5 -z pg-rw.database.svc.cluster.local 5432; echo rc=\$?'"
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"rc=143"* ]]   # 거부/타임아웃이어야 하며 rc=0은 절대 안 된다
}

@test "POSITIVE: a prod-namespace client CAN reach the database on 5432" {
  run bash -c "kubectl -n prod run npd-pos-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'sleep 8; nc -w 5 -z pg-rw.database.svc.cluster.local 5432; echo rc=\$?'"
  [[ "$output" == *"rc=0"* ]]
}

@test "NEGATIVE: prod egress to a non-database, non-DNS destination is denied by default" {
  # prod의 egress default-deny는 DNS, database:5432, prod 내부:8080만 허용한다. 외부는 실패해야 한다.
  run bash -c "kubectl -n prod run npd-egr-\$RANDOM --image=busybox:1.36 --restart=Never --rm -i --quiet \
    --command -- sh -c 'sleep 8; nc -w 5 -z 1.1.1.1 443; echo rc=\$?'"
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"rc=143"* ]]
}
