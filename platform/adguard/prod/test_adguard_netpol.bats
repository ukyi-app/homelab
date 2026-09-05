#!/usr/bin/env bats
# adguard edge egress 격리 회귀 가드(업스트림 DNS만). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "default-deny-egress baseline exists (workload-scoped)" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'adguard-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app: adguard' "$P"; [ "$status" -eq 0 ]
}

@test "upstream DNS egress on 443 (DoH) and 53 (bootstrap) is declared" {
  run grep -q 'port: 443' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "internet egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  # ⚠️ **텍스트 needle 금지 — 이름은 전칭인데 판정이 존재였다.** 예전 본문은 네 리터럴의 존재만
  #    물어서 다음 두 뮤테이션이 5/5 초록이었다(2026-09-03 격리 트리 실측): ① except 없는 두 번째
  #    allow-egress 정책을 덧붙인다 ② except 3대역을 형제 allow ipBlock으로 옮겨 극성을 뒤집는다
  #    (문자열은 그대로 남는다). :13·:27 주석도 같은 문자열을 담아 원문 grep을 혼자 만족시킨다.
  #    선례: platform/argocd/test_argocd_values.bats:145-156(같은 병의 진단·처방).
  #    ⇒ 원문이 아니라 **파싱값**으로, 0.0.0.0/0 ipBlock **전수**로 판정한다.
  # 멀티독이라 `ea`(eval-all)로 모은다. `// ["MISSING"]`이 except 부재를 값으로 바꿔 과부족 둘 다 red.
  Q='[select(.kind=="NetworkPolicy")|.spec.egress[]?|.to[]?|select(.ipBlock.cidr=="0.0.0.0/0")|(.ipBlock.except // ["MISSING"])|sort|join(",")]|.[]'
  out="$(yq ea "$Q" "$P")"
  n="$(printf '%s\n' "$out" | grep -c .)"    # 열거 붕괴 바닥값 — 0건이면 grep rc 1로 red
  [ "$n" -ge 1 ]                             # adguard-allow-egress-upstream-dns
  ok="$(printf '%s\n' "$out" | grep -cxF -- '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16')"
  printf '%s' "$ok" | grep -qxF -- "$n"      # 전수 일치 — 정책이 늘어도 새 ipBlock이 함께 판정된다
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이 rc 2로
  #    죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}

@test "policy restricts egress only, never ingress (DNS serving deferral)" {
  # adguard는 DNS 서버라 ingress(:53)를 잘못 좁히면 LAN/tailscale DNS 전면 장애 → egress만 격리.
  run grep -q 'Egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'Ingress' "$P"; [ "$status" -eq 1 ]
}

@test "the rendered NetworkPolicy set has an upper bound (names + ipBlock cidrs)" {
  # 파일 스코프 전칭 둘(위 @test)은 컴포넌트 안의 원소를 잰다 — kustomization에 새 netpol 파일을
  # 등록하는 세 번째 경로는 파일 스코프 밖이라 무증인이었다(2026-09-03 실측: extra-netpol.yaml
  # 신설 + kustomization 등록 → 65/65 초록 + 렌더에 podSelector:{} 광역 egress 실재).
  # adguard/prod는 KSOPS generator가 없어(SealedSecret만) age 키 없이 build가 CI-safe하게 돈다.
  R="$(kustomize build "$BATS_TEST_DIRNAME")"
  [ "$(printf '%s\n' "$R" | yq 'select(.kind=="NetworkPolicy")|.metadata.name' | grep -v '^---$' | LC_ALL=C sort | paste -sd,)" = \
    "adguard-allow-egress-upstream-dns,adguard-default-deny-egress,rewrite-reconciler-allow-egress,rewrite-reconciler-default-deny-egress" ]
  [ "$(printf '%s\n' "$R" | yq '[.. | select(has("ipBlock")) | .ipBlock.cidr] | .[]' | LC_ALL=C sort | paste -sd,)" = "0.0.0.0/0,192.168.117.0/24" ]
}

@test "workload manifests are wired into the kustomization (prune would delete them otherwise)" {
  # 위 netpol 렌더 상한은 NetworkPolicy 종류만 잡는다 — pvc·adguardhome(첫 부팅 시드)·deployment·
  # service는 그 축 밖이라 kustomization에서 지워도 무증인이었다(2026-09-04 실측: 4파일 동시
  # 제거해도 default-deny-egress 등 파일 스코프 전칭 @test는 65/65 초록). 멤버십이라 상한이 아니고
  # (정당한 추가에 손 갱신 없음), `[ -f ]`는 dangling 양성 대조다(cnpg 명명 규약: test_scheduled_backup.bats:28
  # 계열, 관용구 출처: test_rewrite_reconciler.bats:255-263).
  K="${BATS_TEST_DIRNAME}/kustomization.yaml"
  run yq '.resources | contains(["pvc.yaml","adguardhome.yaml","deployment.yaml","service.yaml","networkpolicy.yaml"])' "$K"
  printf '%s' "$output" | grep -qxF -- 'true'
  for r in pvc adguardhome deployment service networkpolicy; do [ -f "${BATS_TEST_DIRNAME}/$r.yaml" ]; done
}

@test "adguard kustomization pins namespace edge" {
  # appset.yaml:50-51 — destination.namespace 없음: 각 컴포넌트 kustomization의 `namespace:`가
  # 유일한 권위다. 이 값을 바꿔도(2026-09-05 실측: edge→default) 이 디렉토리 전 @test가
  # 초록이었다 — PSA baseline·setcap 전제가 이 값에 있는데 증인이 없었다. AppProject
  # destinations는 `namespace: "*"`(projects.yaml)라 런타임 방벽도 없다.
  [ "$(yq '.namespace' "${BATS_TEST_DIRNAME}/kustomization.yaml")" = "edge" ]
}

@test "adguard-dns LoadBalancer exposes exactly 53/UDP + 53/TCP" {
  # posture-2(58)의 라이브 셀렉터(tests/posture/test_internal-by-default.bats)는 Service
  # **이름** 집합만 재고 포트 축이 없다 — adguard-dns에 포트를 더해도(예: 관리 UI 3000)
  # 이름-only 술어는 불변으로 초록이었다. posture는 owner 라이브 전용이라 PR을 못 막으므로
  # 게이트-세이프 정적 witness를 여기 1순위로 둔다(58 va.corrected_fix ①).
  S="${BATS_TEST_DIRNAME}/service.yaml"
  run yq ea 'select(.metadata.name=="adguard-dns") | [.spec.ports[]|"\(.protocol)/\(.port)"] | sort | join(",")' "$S"
  printf '%s' "$output" | grep -qxF -- 'TCP/53,UDP/53'
}
