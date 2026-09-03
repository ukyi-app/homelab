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
  # ⚠️ 위 줄의 `select(.kind=="NetworkPolicy")`는 비-NetworkPolicy doc을 **열거 밖**에 둔다 —
  #    kube-system ConfigMap doc을 이 파일에 밀어 넣어도 초록이었다(실측). @test 이름이 약속한
  #    "every doc"을 지키려면 그 여집합을 직접 세야 한다. `ea`로 전 doc을 한 배열에 모으므로
  #    멀티독 `yq -e` 함정(하나만 true면 exit 0) 비대상이다.
  [ "$(yq ea '[select(.kind!="NetworkPolicy")] | length' "$NP")" -eq 0 ]
  run bash -c "kubeconform -strict -summary '$NP'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "Invalid: 0"
  [[ "$output" == *"Errors: 0"* ]]
}

@test "ingress is default-denied (the database accepts no unsolicited ingress)" {
  d="$(yq 'select(.metadata.name=="database-default-deny-ingress")' "$NP")"
  [ "$(echo "$d" | yq '.spec.podSelector | length')" -eq 0 ]
  echo "$d" | yq -e '.spec.policyTypes' | grep -q Ingress
  # ⚠️ **무엇을 다시 여는가**를 함께 재야 한다 — NetworkPolicy 규약상 from/ports 없는 규칙
  #    (`ingress: [{}]`) 한 줄이면 default-deny가 전면 허용으로 뒤집힌다. 위 두 줄은 podSelector와
  #    policyTypes만 봐서 그 뒤집기가 초록으로 통과했다(실측). 키 부재는 `null | length` = 0이라
  #    현행 형태(ingress 키 없음)를 그대로 유지하고 allow-all만 red가 된다.
  [ "$(echo "$d" | yq '.spec.ingress | length')" -eq 0 ]
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
  # ⚠️ 위 단언들은 전부 **존재**만 재고 이름이 약속한 **배타**를 재지 않는다 — 파일 끝에
  #    `namespaceSelector: {}`(전 ns 허용) 정책을 하나 더해도 14/14 초록이었다(실측).
  #    정책 집합 상한을 로스터 등식으로 고정해 추가·삭제 양방향을 red로 만든다.
  #    `yq` 내장 sort는 Go 문자열 비교라 로케일 무관이고(LC_ALL 불필요), `ea`로 doc을 한 배열에
  #    모으므로 `select`가 비매칭 doc마다 `---`를 뱉는 함정도 비켜간다.
  EXP='cnpg-allow-tailscale database-allow-ingress-from-cnpg-system database-allow-ingress-from-prod database-allow-ingress-intra database-allow-ingress-kubelet-probes database-allow-ingress-metrics-from-observability database-default-deny-ingress'
  [ "$(yq ea '[select(.kind=="NetworkPolicy") | .metadata.name] | sort | join(" ")' "$NP")" = "$EXP" ]
  # ⚠️ 정책 **개수**를 고정해도 리스트 **내부 확장**은 남는다 — 기존 doc의 from에
  #    `- namespaceSelector: {}` 한 줄이면 전 네임스페이스가 그 포트에 닿는데, 형제
  #    test_security-gates.bats:45-48의 `.[0].spec.ingress[0].from[0]` 단언은 **첫 원소**만 봐서
  #    cnpg-allow-tailscale·database-allow-ingress-from-prod 어느 쪽에 붙여도 14/14 초록이었다(실측).
  #    doc-국소 길이 바닥값은 7-doc 중 하나만 닫으므로, doc 무관 peer/port **총 열거**를 센다 —
  #    신규 doc까지 자동 편입되고, 정당한 peer 추가는 아래 상수 갱신을 강제한다(fail-closed).
  #    상수는 로스터가 아니라 이 파일 안의 닫힌 불변식이라 하드코딩 소비처 함정 비대상이다.
  #    `ea` + 수집 배열이라 멀티독 `yq -e` 함정도, 「값이 false면 exit 1」도 비켜간다(length는 null이 없다).
  # 정정(finding impact): 이 확장이 새로 여는 것은 prod가 아니라 **비-prod** ns다 —
  #    prod→database:5432는 database-allow-ingress-from-prod로 설계상 이미 허용된다. 라이브 사후
  #    증인 tests/posture/test_network-policy.bats:80-85는 owner-local이라 머지-전 게이트가 아니다.
  run yq ea -e '[select(.kind=="NetworkPolicy") | .spec.ingress[]?.from[]?] | length == 6' "$NP"
  [ "$status" -eq 0 ]
  run yq ea -e '[select(.kind=="NetworkPolicy") | .spec.ingress[]?.ports[]?] | length == 4' "$NP"
  [ "$status" -eq 0 ]
}

@test "egress is intentionally NOT default-denied (CNPG needs API/R2/replication egress)" {
  # 이 파일의 어떤 policy도 Egress를 제한하지 않는다 — 의도적이며 문서화된 범위 결정.
  run bash -c "yq 'select(.spec.policyTypes[] == \"Egress\")' '$NP'"
  [ -z "$output" ]
}

@test "every manifest in this dir is wired into the kustomization (prune deletes what is not)" {
  # 형제 4개 배선 @test(basebackup·restore-drill·scheduled-backup·pgdump-hedge)가 DR 생산자만
  # 닫았고, 그 백업의 목적지(object-store)·RBAC(restore-drill-rbac)·PVC(basebackup-pvc)·논리 DB
  # (databases/)는 이 루프가 닫는다. 손 로스터 대신 글롭 파생 — (N+1)번째 매니페스트가 자동 편입된다
  # (로스터 기각 선례: tests/gates/test_vmalert-config.bats의 배선-0 신규 파일 무증인 실측).
  D="$BATS_TEST_DIRNAME"; n=0
  for f in "$D"/*.yaml; do
    b="$(basename "$f")"
    case "$b" in kustomization.yaml|secret-generator.yaml|*.enc.yaml) continue;; esac
    yq '.resources[]' "$KUST" | grep -qxF "$b" \
      || { echo "미배선: $b — 렌더에서 빠지면 라이브가 프룬된다"; false; }
    n=$((n + 1))
  done
  [ "$n" -ge 15 ]            # 글롭 붕괴 방지(현재 15). 상한 아님 — 신규 매니페스트는 자동 포함
  [ -d "$D/databases" ]      # 피연산자 실재 앵커
  yq '.resources[]' "$KUST" | grep -qxF 'databases/'
}

@test "kubelet probe ingress is node-only (pod-CIDR-wide ipBlock would defeat default-deny)" {
  p="$(yq 'select(.metadata.name=="database-allow-ingress-kubelet-probes")' "$NP")"
  printf '%s' "$p" | grep -qF -- "cidr: 10.42.0.1/32"   # 노드(cni0)만 — /16은 전 파드에 5432 개방
  case "$p" in *"cidr: 10.42.0.0/16"*) false ;; *) true ;; esac
  printf '%s' "$p" | grep -qF -- "port: 8000"
  [[ "$p" != *"port: 5432"* ]]           # probe 정책에 5432가 되살아나면 안 된다
}
