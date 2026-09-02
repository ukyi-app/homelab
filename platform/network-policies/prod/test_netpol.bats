#!/usr/bin/env bats
# `prod` 앱 namespace NetworkPolicy의 오프라인 검증.
# 이 컴포넌트는 secret/CRD가 없어 일반 kustomize만으로 오프라인 빌드된다.

DIR="${BATS_TEST_DIRNAME}"

build() { kustomize build "$DIR"; }

@test "kustomize build renders and lands every policy in namespace prod" {
  run build
  [ "$status" -eq 0 ]
  # 모든 policy가 존재
  for n in default-deny-all allow-dns-egress allow-egress-to-database \
           allow-egress-to-cache allow-ingress-from-gateway \
           allow-ingress-metrics-from-observability \
           allow-intra-prod-http allow-ingress-kubelet-probes; do
    echo "$output" | grep -q "name: $n"
  done
  # namespace 트랜스포머가 prod로 고정 (grep -v는 yq의 문서 간 '---' 구분자를 제거)
  [ "$(build | yq 'select(.kind=="NetworkPolicy") | .metadata.namespace' | grep -v '^---' | LC_ALL=C sort -u)" = "prod" ]
}

@test "manifests are kubeconform-valid (strict)" {
  # 🔴 이 레인은 '스키마에 맞다'가 아니라 '읽을 것이 없었다'를 초록으로 보고했다. 판정 셋
  #    (rc·`Invalid: 0`·`Errors: 0`)이 **전부 0건 입력에서 참**이고, `bash -c "A | B"`는 pipefail을
  #    물려받지 않아 A(kustomize build)의 실패도 삼킨다. 실측 2026-09-03: `resources: []`(0 리소스
  #    렌더)와 경로 오타(build rc 1) 두 뮤테이션 모두 파이프 rc 0 · 같은 요약이라 이 파일이
  #    1 ok / 7 not ok가 됐고, 살아남은 유일한 ok가 정확히 이 레인이었다.
  # (1) pipefail로 렌더 실패를 rc에 전파하고 (2) 판정을 **비공허 양성 대조**로 접는다.
  #     선례: cb212de(platform/charts/app 렌더 하네스) — 같은 결함·같은 처방.
  # ⚠️ grep은 파이프 **밖**이라 SIGPIPE 거짓 FAIL 함정과 무관하다
  #    (cf. docs/traps-detail.md 「`grep -q`의 조기 종료가 pipefail 아래에서 writer를 SIGPIPE로 죽인다」).
  run bash -c "set -o pipefail; kustomize build \"$DIR\" | kubeconform -strict -summary"
  [ "$status" -eq 0 ]
  # 대문자 V라 "Invalid: N"과 충돌하지 않는다 — 검사 건수 >0과 유효성 판정을 한 줄에 접는다.
  printf '%s' "$output" | grep -qE 'Valid: [1-9][0-9]*, Invalid: 0'
  [[ "$output" == *"Errors: 0"* ]]
}

@test "default-deny covers BOTH ingress and egress" {
  policy="$(build | yq 'select(.metadata.name=="default-deny-all")')"
  [ "$(echo "$policy" | yq '.spec.podSelector | length')" -eq 0 ]   # {} = 모든 pod
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Egress
}

@test "egress allows DNS and database:5432 (no general internet egress by default)" {
  # DNS allow는 kube-system kube-dns의 53 포트를 대상으로 한다
  dns="$(build | yq 'select(.metadata.name=="allow-dns-egress")')"
  printf '%s' "$dns" | grep -qF -- "kubernetes.io/metadata.name: kube-system"
  printf '%s' "$dns" | grep -qF -- "k8s-app: kube-dns"
  printf '%s' "$dns" | grep -qF -- "port: 53"
  # database egress는 database namespace로 5432만 허용
  db="$(build | yq 'select(.metadata.name=="allow-egress-to-database")')"
  printf '%s' "$db" | grep -qF -- "kubernetes.io/metadata.name: database"
  [[ "$db" == *"port: 5432"* ]]
}

@test "database egress is structurally narrowed — every database peer has podSelector, no namespace-only peer" {
  TMP="$BATS_TEST_TMPDIR/db-egress.yaml"
  build | yq 'select(.metadata.name=="allow-egress-to-database")' > "$TMP"
  # database namespace를 가리키는데 podSelector 없는 피어(=namespace 전체) 0개여야(F1b — substring은 잔존 broad 통과)
  run yq '[.spec.egress[].to[] | select(.namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "database" and (has("podSelector") | not))] | length' "$TMP"
  [ "$output" = "0" ]
  # podSelector로 좁힌 피어 ≥1
  run yq '[.spec.egress[].to[] | select(has("podSelector"))] | length' "$TMP"
  [ "$output" -ge 1 ]
  # ★F4: pooler+cluster 정확 셀렉터 둘 다(오타 통과 방지). CNPG 자동생성 라벨(poolerName·cluster).
  run grep -q 'cnpg.io/poolerName: pg-pooler-rw' "$TMP"; [ "$status" -eq 0 ]   # pooler(앱 런타임 경로, PgBouncer)
  run grep -q 'cnpg.io/cluster: pg' "$TMP"; [ "$status" -eq 0 ]                # cluster(pg-rw→primary)
  run grep -q 'port: 5432' "$TMP"; [ "$status" -eq 0 ]
}

@test "egress to the cache tier is valkey 6379 only (namespaceSelector, no ipBlock)" {
  # grep 파이프라인 단언 — mid-test `[[ ]]` 실패는 bash 3.2에서 bats가 못 잡는다
  c="$(build | yq 'select(.metadata.name=="allow-egress-to-cache")')"
  echo "$c" | grep -q "kubernetes.io/metadata.name: cache"
  echo "$c" | grep -q "port: 6379"
  [ "$(echo "$c" | grep -c "ipBlock")" -eq 0 ]   # 피어는 namespaceSelector로만 — pod CIDR 함정 금지
}

@test "ingress allows are gateway:8080, observability:9090, and node probes" {
  gw="$(build | yq 'select(.metadata.name=="allow-ingress-from-gateway")')"
  printf '%s' "$gw" | grep -qF -- "kubernetes.io/metadata.name: gateway"
  printf '%s' "$gw" | grep -qF -- "port: 8080"
  obs="$(build | yq 'select(.metadata.name=="allow-ingress-metrics-from-observability")')"
  printf '%s' "$obs" | grep -qF -- "kubernetes.io/metadata.name: observability"
  printf '%s' "$obs" | grep -qF -- "port: 9090"
  probes="$(build | yq 'select(.metadata.name=="allow-ingress-kubelet-probes")')"
  printf '%s' "$probes" | grep -qF -- "ipBlock"
  printf '%s' "$probes" | grep -qF -- "cidr: 10.42.0.1/32"   # 노드(cni0)만 — /16은 default-deny 무력화
  [[ "$probes" != *"cidr: 10.42.0.0/16"* ]]
}

@test "intra-prod app-to-app on http 8080 is allowed (SSR->API server-side calls)" {
  p="$(build | yq 'select(.metadata.name=="allow-intra-prod-http")')"
  printf '%s' "$p" | grep -qF -- "kubernetes.io/metadata.name: prod"
  printf '%s' "$p" | grep -qF -- "port: 8080"
  echo "$p" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$p" | yq -e '.spec.policyTypes' | grep -q Egress
}
