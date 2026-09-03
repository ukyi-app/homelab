#!/usr/bin/env bats
# observability 외부 egress 격리 회귀 가드(alertmanager·relay, NETPOL-4 minimal). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 networkpolicy.yaml 단일 파일이라
#    그것으로 닫힌다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "alertmanager and relay default-deny-egress baselines exist" {
  run grep -q 'alertmanager-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'deadmanswitch-relay-default-deny-egress' "$P"; [ "$status" -eq 0 ]
}

@test "workloads selected by app.kubernetes.io/name (live label parity)" {
  run grep -q 'app.kubernetes.io/name: alertmanager' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: deadmanswitch-relay' "$P"; [ "$status" -eq 0 ]
}

@test "alertmanager reaches the relay deadman webhook on 9095 (internal hop not dropped)" {
  run grep -q 'port: 9095' "$P"; [ "$status" -eq 0 ]
}

@test "external egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  # ⚠️ **텍스트 needle 금지 — 이름은 전칭인데 판정이 존재였다.** 예전 본문은 네 리터럴이 파일
  #    어딘가에 한 번이라도 나오는지만 물어서, 다음 두 뮤테이션이 6/6 초록이었다(2026-09-03 격리
  #    트리 실측): ① 0.0.0.0/0 ipBlock 4개 중 3개에서 `except`를 지운다(alertmanager 하나만 남아도
  #    리터럴 넷은 전부 살아 있다) ② except 3대역을 형제 allow ipBlock으로 옮겨 극성을 뒤집는다.
  #    게다가 이 파일 :13·:49·:112·:139 주석이 같은 문자열을 담고 있어, 원문 grep은 규칙이 통째로
  #    비어도 살아남는 종류다(형제 test_pvc_du_exporter.bats:27-30이 같은 자기-주석 함정을 기록).
  #    선례: platform/argocd/test_argocd_values.bats:145-156이 같은 병을 진단하고 yq 구조 등호로 고쳤다.
  #    ⇒ 원문이 아니라 **파싱값**으로, 그리고 0.0.0.0/0 ipBlock **전수**로 판정한다.
  # 멀티독이라 `ea`(eval-all)로 배열에 모은다 — 문서 사이 `---`가 stdout에 섞이면 줄 단위 판정이
  # 오염된다. `// ["MISSING"]`이 except **부재**를 값으로 바꿔 과부족을 둘 다 red로 만든다.
  Q='[select(.kind=="NetworkPolicy")|.spec.egress[]?|.to[]?|select(.ipBlock.cidr=="0.0.0.0/0")|(.ipBlock.except // ["MISSING"])|sort|join(",")]|.[]'
  out="$(yq ea "$Q" "$P")"
  n="$(printf '%s\n' "$out" | grep -c .)"    # 열거 붕괴 바닥값 — 0건이면 grep rc 1로 red
  [ "$n" -ge 4 ]                             # alertmanager·relay·digest-exporter·gha-liveness-exporter
  ok="$(printf '%s\n' "$out" | grep -cxF -- '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16')"
  printf '%s' "$ok" | grep -qxF -- "$n"      # 전수 일치 — 하나라도 어긋나면 red
}

@test "every egress peer across the file is a named namespace, never a cluster-wide selector" {
  # 이름 집합 손 로스터 대신 전칭 피어 — 정책 이름을 안 세면 신규 광역 정책도, 기존 allow의
  # to: 확장(namespaceSelector:{})도 둘 다 잡는다(2026-09-03 실측: vmagent-allow-egress-everywhere
  # 신설이 이 파일의 다른 @test 전건 초록이었다). `// "ANY"`가 빈 selector를 값으로 바꿔 fail-closed.
  peers="$(yq ea '[select(.kind=="NetworkPolicy")|.spec.egress[]?|.to[]?|select(has("namespaceSelector"))|(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] // "ANY")]|.[]' "$P")"
  printf '%s\n' "$peers" | grep -qxF -- kube-system
  run grep -qxF -- ANY <<EOF
$peers
EOF
  [ "$status" -eq 1 ]
}

@test "metrics east-west plane is intentionally untouched (no ns-wide default-deny)" {
  # vmagent가 전 ns를 scrape(role:pod SD)라 ns-wide deny는 near-allow-all → 외부 egress만 워크로드별 격리.
  # ⚠️ 이 @test는 부재 단언 하나뿐이라 형제 증인이 없다 — 예전 `-ne 0`에서는 networkpolicy.yaml을
  #    리네임해도 초록이었다 — 2026-08-29 격리 트리 실측에서 이 파일의 부재 단언 두 @test만
  #    살아남았다.
  run grep -q 'podSelector: {}' "$P"; [ "$status" -eq 1 ]
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 위 @test와 같다 — 부재 단언 단독이라 대상 부재에 홀로 초록이었다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}
