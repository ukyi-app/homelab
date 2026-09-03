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
  # ⚠️ 상한 — ipBlock을 아예 안 갖는 광역 정책 한 건이 :46 cidr 등호의 도메인 밖이다(실측: 신규
  #    `podSelector:{}`+`namespaceSelector:{}` 추가 후 6/6 ok). 관용구 출처:
  #    platform/network-policies/prod/test_netpol.bats:29(397b001). **정책 추가 축만** 닫는다 —
  #    기존 to[]에 피어를 더하는 확장은 이름 집합 불변이라 여전히 무증인이다(실측 6/6 ok).
  [ "$(yq ea '[select(.kind=="NetworkPolicy")|.metadata.name]|sort|join(",")' "$P")" = \
    "cloudflared-allow-dns-egress,cloudflared-allow-egress-cloudflare-edge,cloudflared-allow-egress-to-gateway,cloudflared-default-deny-egress" ]
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
  # ⚠️ `yq -e`는 쓰지 않는다(값 false → exit 1 함정). 관용구 출처: platform/argocd/test_argocd_values.bats:145-156.
  c="$(yq -N '[.spec.egress[]?.to[]?.ipBlock.cidr | select(.)] | .[]' "$P" | paste -sd, -)"
  [ "$c" = "0.0.0.0/0" ] || { echo "ipBlock cidr 집합=$c"; false; }
  # except는 0.0.0.0/0 ipBlock **마다 개별로** 전수 판정한다(형제 티켓 41이 victoria-stack·adguard에
  # 착지한 형태와 동형). `// ["MISSING"]`이 except 부재를 값으로 바꿔 과부족 둘 다 red다.
  # ⚠️ 부정 카운트(`bad=$(… grep -vcxF …); [ "$bad" -eq 0 ]`)는 쓰지 않는다 — 전건 일치면 `grep -v`가
  #    아무 줄도 못 골라 rc 1이고 bats errexit가 그 **assignment에서** 죽어 **올바른 매니페스트가 red**다
  #    (티켓 41 실측). 극성을 뒤집어 일치 **카운트 등식**으로 판정한다(정상 경로 rc 0·0건은 fail-closed).
  Q='[select(.kind=="NetworkPolicy")|.spec.egress[]?|.to[]?|select(.ipBlock.cidr=="0.0.0.0/0")|(.ipBlock.except // ["MISSING"])|sort|join(",")]|.[]'
  out="$(yq ea "$Q" "$P")"
  n="$(printf '%s\n' "$out" | grep -c .)"    # 열거 붕괴 바닥값 — 0건이면 grep rc 1로 red
  [ "$n" -ge 1 ]                             # cloudflared-allow-egress-cloudflare-edge
  ok="$(printf '%s\n' "$out" | grep -cxF -- '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16')"
  printf '%s' "$ok" | grep -qxF -- "$n"      # 전수 일치 — 규칙이 늘어도 새 0.0.0.0/0 ipBlock이 함께 판정된다
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이
  #    rc 2로 죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}
