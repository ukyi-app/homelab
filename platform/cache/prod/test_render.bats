#!/usr/bin/env bats
# `cache`(Valkey) 컴포넌트의 오프라인 렌더 검증 — secret/CRD 의존 없이 일반 kustomize로 빌드된다.
# (인스턴스 디렉토리는 provision-cache.mjs가 추가 — 0개 상태에서도 정적 골격이 렌더돼야 한다.)
# 주의: macOS bash 3.2에서 mid-test `[[ ]]`/`! cmd` 실패는 bats가 못 잡는다 —
# 단언은 전부 grep 파이프라인/`[ ]`/카운트 비교로 쓴다.

DIR="${BATS_TEST_DIRNAME}"
ROOT="$(cd "$DIR/../../.." && pwd)"

build() { kustomize build "$DIR"; }

@test "kustomize build renders the cache component entirely in namespace cache" {
  run build
  [ "$status" -eq 0 ]
  [ "$(build | yq '.metadata.namespace' | grep -v '^---' | sort -u)" = "cache" ]
}

@test "manifests are kubeconform-valid (strict)" {
  run bash -c "kustomize build \"$DIR\" | kubeconform -strict -ignore-missing-schemas -summary"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "Invalid: 0"
  echo "$output" | grep -qF "Errors: 0"
}

@test "cache namespace is default-deny in BOTH directions with no pod-CIDR ipBlock" {
  policy="$(build | yq 'select(.metadata.name=="cache-default-deny-all")')"
  [ "$(echo "$policy" | yq '.spec.podSelector | length')" -eq 0 ]   # {} = 모든 pod
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Egress
  # ⚠️ 10.42.0.0/16(pod CIDR)은 "전체 파드 허용" — default-deny 무력화 (라이브 검증 함정)
  [ "$(build | grep -c "10.42.0.0/16")" -eq 0 ]
}

@test "ingress allows are prod:6379, intra-ns backup:6379, and node probes only" {
  p="$(build | yq 'select(.metadata.name=="cache-allow-ingress-from-prod")')"
  echo "$p" | grep -q "kubernetes.io/metadata.name: prod"
  echo "$p" | grep -q "port: 6379"
  b="$(build | yq 'select(.metadata.name=="cache-allow-ingress-backup")')"
  echo "$b" | grep -q "cache-backup"
  echo "$b" | grep -q "port: 6379"
  probes="$(build | yq 'select(.metadata.name=="cache-allow-ingress-kubelet-probes")')"
  echo "$probes" | grep -q "cidr: 10.42.0.1/32"   # 노드(cni0)만
}

@test "egress is DNS for all pods plus a backup-job-scoped allowance" {
  dns="$(build | yq 'select(.metadata.name=="cache-allow-dns-egress")')"
  echo "$dns" | grep -q "kubernetes.io/metadata.name: kube-system"
  echo "$dns" | grep -q "k8s-app: kube-dns"
  echo "$dns" | grep -q "port: 53"
  be="$(build | yq 'select(.metadata.name=="cache-allow-backup-egress")')"
  echo "$be" | grep -q "app.kubernetes.io/name: cache-backup"   # podSelector 스코프 — NS 전체가 아니다
}

@test "backup chain renders cronjob with a dedicated service account and minimal rbac" {
  run build
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "kind: CronJob"
  echo "$output" | grep -q "serviceAccountName: cache-backup"
  echo "$output" | grep -q "kind: Role"
  echo "$output" | grep -q "kind: RoleBinding"
}

@test "backup r2-creds secret is optional so a no-cache cluster no-ops instead of failing" {
  # 캐시 인스턴스 0개면 cache-r2-creds 봉인이 없는 게 정상 — optional이 아니면 upload 컨테이너가
  # CreateContainerConfigError로 영영 못 떠 Job이 DeadlineExceeded로 매일 실패(KubeJobFailed 노이즈).
  opt="$(build | yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name=="upload") | .envFrom[] | select(.secretRef.name=="cache-r2-creds") | .secretRef.optional')"
  [ "$opt" = "true" ]
}

@test "prod namespace opens egress to cache:6379 and namespaces owns the cache namespace" {
  grep -q "allow-egress-to-cache" "$ROOT/platform/network-policies/prod/networkpolicies.yaml"
  grep -q "name: cache" "$ROOT/platform/namespaces/prod/namespaces.yaml"
}
