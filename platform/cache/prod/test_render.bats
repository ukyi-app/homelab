#!/usr/bin/env bats
# `cache`(Valkey) 컴포넌트의 CI-safe 정적 검증 — 원본 yaml을 직접 읽는다(kustomize build 불요).
# 전체 KSOPS 렌더(cache-r2-creds 복호)는 age 키 의존이라 test_ksops_render.bats(.ci-exclude)가 담당한다.
# 주의: macOS bash 3.2에서 mid-test `[[ ]]`/`! cmd` 실패는 bats가 못 잡는다 —
# 단언은 전부 grep 파이프라인/`[ ]`/카운트 비교로 쓴다.

DIR="${BATS_TEST_DIRNAME}"
ROOT="$(cd "$DIR/../../.." && pwd)"
NP="$DIR/networkpolicy.yaml"
CJ="$DIR/backup-cronjob.yaml"

@test "cache namespace is default-deny in BOTH directions with no pod-CIDR ipBlock" {
  policy="$(yq 'select(.metadata.name=="cache-default-deny-all")' "$NP")"
  [ "$(echo "$policy" | yq '.spec.podSelector | length')" -eq 0 ]   # {} = 모든 pod
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Egress
  # ⚠️ 10.42.0.0/16(pod CIDR)을 ipBlock cidr로 쓰면 "전체 파드 허용" — default-deny 무력화(라이브 검증 함정).
  #    실제 cidr: 값만 검사(경고 주석의 10.42 언급은 제외).
  [ "$(grep -cE 'cidr:.*10\.42\.0\.0/16' "$NP")" -eq 0 ]
}

@test "ingress allows are prod:6379, intra-ns backup:6379, and node probes only" {
  p="$(yq 'select(.metadata.name=="cache-allow-ingress-from-prod")' "$NP")"
  echo "$p" | grep -q "kubernetes.io/metadata.name: prod"
  echo "$p" | grep -q "port: 6379"
  b="$(yq 'select(.metadata.name=="cache-allow-ingress-backup")' "$NP")"
  echo "$b" | grep -q "cache-backup"
  echo "$b" | grep -q "port: 6379"
  probes="$(yq 'select(.metadata.name=="cache-allow-ingress-kubelet-probes")' "$NP")"
  echo "$probes" | grep -q "cidr: 10.42.0.1/32"   # 노드(cni0)만
}

@test "egress is DNS for all pods plus a backup-job-scoped allowance" {
  dns="$(yq 'select(.metadata.name=="cache-allow-dns-egress")' "$NP")"
  echo "$dns" | grep -q "kubernetes.io/metadata.name: kube-system"
  echo "$dns" | grep -q "k8s-app: kube-dns"
  echo "$dns" | grep -q "port: 53"
  be="$(yq 'select(.metadata.name=="cache-allow-backup-egress")' "$NP")"
  echo "$be" | grep -q "app.kubernetes.io/name: cache-backup"   # podSelector 스코프 — NS 전체가 아니다
}

@test "backup chain declares cronjob with a dedicated service account and minimal rbac" {
  grep -q "kind: CronJob" "$CJ"
  grep -q "serviceAccountName: cache-backup" "$CJ"
  grep -q "kind: Role" "$DIR/backup-rbac.yaml"
  grep -q "kind: RoleBinding" "$DIR/backup-rbac.yaml"
}

@test "backup r2-creds secret is optional so a no-cache cluster no-ops instead of failing" {
  # 캐시 인스턴스 0개면 cache-r2-creds 봉인이 없어도 upload 컨테이너가 CreateContainerConfigError로
  # 못 뜨지 않게 optional 유지(KubeJobFailed 노이즈 방지). cache-r2-creds가 시드된 지금도 방어적 유지.
  opt="$(yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name=="upload") | .envFrom[] | select(.secretRef.name=="cache-r2-creds") | .secretRef.optional' "$CJ")"
  [ "$opt" = "true" ]
}

@test "backup upload round-trips the RDB: re-reads the uploaded copy and re-checks sha256, not just size" {
  # size>0만으론 전송 중 절삭/비트플립을 못 잡는다 — rclone cat으로 되읽어 로컬 원본 sha256과 재대조해야 한다.
  up="$(yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name=="upload") | .args[0]' "$CJ")"
  echo "$up" | grep -q 'rclone cat'    # 업로드 사본 되읽기(GetObject)
  echo "$up" | grep -q 'sha256sum'     # 되읽은 사본 재해싱
  echo "$up" | grep -q 'REMOTE_SHA'    # 로컬 원본과 대조할 원격 해시
  echo "$up" | grep -q 'exit 1'        # 불일치 시 fail-loud
}

@test "cache-r2-creds is KSOPS-wired: secret-generator lists the enc file and kustomization loads it" {
  grep -q "cache-r2-creds.enc.yaml" "$DIR/secret-generator.yaml"
  grep -q "secret-generator.yaml" "$DIR/kustomization.yaml"
  # 고정 이름 유지(CronJob envFrom가 cache-r2-creds를 참조 — 해시 접미사 금지)
  grep -q "disableNameSuffixHash: true" "$DIR/kustomization.yaml"
}

@test "cache-r2-creds enc file targets ns cache with the rclone R2 key schema (encrypted)" {
  F="$DIR/cache-r2-creds.enc.yaml"
  run yq '.metadata.name' "$F"; [ "$output" = "cache-r2-creds" ]
  run yq '.metadata.namespace' "$F"; [ "$output" = "cache" ]
  # 값은 SOPS 암호화(ENC[]) — 키 이름만 검증(rclone이 읽는 정본 스키마)
  grep -q "RCLONE_CONFIG_R2_ENDPOINT" "$F"
  grep -q "RCLONE_CONFIG_R2_ACCESS_KEY_ID" "$F"
  grep -q "sops:" "$F"  # 암호화됨
}

@test "prod namespace opens egress to cache:6379 and namespaces owns the cache namespace" {
  grep -q "allow-egress-to-cache" "$ROOT/platform/network-policies/prod/networkpolicies.yaml"
  grep -q "name: cache" "$ROOT/platform/namespaces/prod/namespaces.yaml"
}
