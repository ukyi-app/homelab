#!/usr/bin/env bats
# cert-manager ns egress 격리 회귀 가드(NETPOL-4). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
# ⚠️ lateral guard는 yq 구조 질의다 — yq 부재 처리는 형제 platform/cloudflared/prod/test_cloudflared_seccomp.bats:3-9
#    그대로(CI 부재=FAIL로 dead-green 방지, 로컬=skip).
setup() {
  P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
}

@test "default-deny-egress baseline exists" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'cert-manager-default-deny-egress' "$P"; [ "$status" -eq 0 ]
}

@test "dns egress to coredns on 53 is declared" {
  run grep -q 'k8s-app: kube-dns' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "apiserver egress is scoped to node-subnet on 6443 (kube-router DNAT, F5)" {
  run grep -q '192.168.117.0/24' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 6443' "$P"; [ "$status" -eq 0 ]
}

@test "external egress on 443 (ACME + Cloudflare API) is declared" {
  run grep -q 'port: 443' "$P"; [ "$status" -eq 0 ]
}

@test "external egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  # ⚠️ 재는 것은 리터럴의 **존재**가 아니라 **YAML 위치(극성)**다. 여기 있던 판정은 세 사설 대역
  #    문자열이 파일 어딘가에 있는지만 물어서, `except:` 리스트를 지우고 같은 문자열을 형제 allow
  #    ipBlock으로 옮기면(=「제외」→「명시 허용」) 6/6 ok였다(실측). 이 ns는 파일 헤더가 적었듯
  #    클러스터 전역 Secret RBAC를 쥔 측면이동 고가치 표적이라 극성이 곧 경계다.
  # ⚠️ 첫 등호가 **전수 열거**다 — 파일의 ipBlock cidr 집합 전체를 고정하므로 :18-21이 리터럴로만
  #    재던 apiserver 대역의 넓이도 함께 못박히고, 신규 사설 ipBlock allow 추가도 같은 줄이 잡는다.
  # ⚠️ `yq -e`는 쓰지 않는다(값 false → exit 1 함정). 관용구 출처: platform/argocd/test_argocd_values.bats:148-156.
  c="$(yq -N '[.spec.egress[]?.to[]?.ipBlock.cidr | select(.)] | .[]' "$P" | paste -sd, -)"
  [ "$c" = "192.168.117.0/24,0.0.0.0/0" ] || { echo "ipBlock cidr 집합=$c"; false; }
  e="$(yq -N '[.spec.egress[]?.to[]?.ipBlock | select(.cidr == "0.0.0.0/0") | .except // [] | .[]] | .[]' "$P" | paste -sd, -)"
  [ "$e" = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" ] || { echo "except 집합=$e"; false; }
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이
  #    rc 2로 죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}
