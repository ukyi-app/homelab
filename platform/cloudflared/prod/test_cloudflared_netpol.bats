#!/usr/bin/env bats
# cloudflared edge egress 격리 회귀 가드(터널 종단점 lateral 방지). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
# ⚠️ lateral guard는 yq 구조 질의다 — yq 부재 처리는 형제 test_cloudflared_seccomp.bats:3-9 그대로
#    (CI 부재=FAIL로 dead-green 방지, 로컬=skip).
setup() {
  P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
}

@test "default-deny-egress baseline exists (workload-scoped)" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'cloudflared-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app: cloudflared' "$P"; [ "$status" -eq 0 ]
}

@test "dns egress to coredns on 53 is declared" {
  run grep -q 'k8s-app: kube-dns' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "tunnel egress to gateway traefik on 8000 is declared" {
  run grep -q 'kubernetes.io/metadata.name: gateway' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 8000' "$P"; [ "$status" -eq 0 ]
}

@test "cloudflare edge egress on 7844 and 443 is declared" {
  run grep -q 'port: 7844' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 443' "$P"; [ "$status" -eq 0 ]
}

@test "internet egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  # ⚠️ 재는 것은 리터럴의 **존재**가 아니라 **YAML 위치(극성)**다. 여기 있던 판정은 세 사설 대역
  #    문자열이 파일 어딘가에 있는지만 물어서, `except:` 리스트를 지우고 같은 문자열을 형제 allow
  #    ipBlock으로 옮기면(=「제외」→「명시 허용」, 내부 평면 lateral 전면 허용) 6/6 ok였다(실측).
  #    같은 클래스가 tailscale·cert-manager-netpol에도 있어 세 사본을 한 커밋에서 함께 닫았다.
  # ⚠️ 첫 등호가 **전수 열거**다 — 파일의 ipBlock cidr 집합 전체를 고정하므로 신규 사설 ipBlock
  #    allow 추가도 같은 줄이 잡는다(부정 카운트 음성 대조가 불필요한 이유).
  # ⚠️ `yq -e`는 쓰지 않는다(값 false → exit 1 함정). 관용구 출처: platform/argocd/test_argocd_values.bats:148-156.
  c="$(yq -N '[.spec.egress[]?.to[]?.ipBlock.cidr | select(.)] | .[]' "$P" | paste -sd, -)"
  [ "$c" = "0.0.0.0/0" ] || { echo "ipBlock cidr 집합=$c"; false; }
  e="$(yq -N '[.spec.egress[]?.to[]?.ipBlock | select(.cidr == "0.0.0.0/0") | .except // [] | .[]] | .[]' "$P" | paste -sd, -)"
  [ "$e" = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" ] || { echo "except 집합=$e"; false; }
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이
  #    rc 2로 죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}
