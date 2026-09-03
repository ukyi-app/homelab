#!/usr/bin/env bats
# homepage 자동발견 annotation 가드(argocd/adguard/grafana HTTPRoute). @test 이름은 영어.
setup() {
  A="${BATS_TEST_DIRNAME}/../../argocd/extras/httproute.yaml"
  G="${BATS_TEST_DIRNAME}/../../adguard/prod/httproute.yaml"
  V="${BATS_TEST_DIRNAME}/../../victoria-stack/prod/httproute-grafana.yaml"
}

@test "argocd route discoverable with correct server pod-selector (F9)" {
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/enabled\"' '$A'"; [ "$output" = "true" ]
  # =argocd 단독 금지 — server pod에 매치되는 argocd-server를 반드시 포함
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/pod-selector\"' '$A' | grep -q 'argocd-server'"; [ "$status" -eq 0 ]
}

@test "adguard route has the adguard pod-selector (F9)" {
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/enabled\"' '$G'"; [ "$output" = "true" ]
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/pod-selector\"' '$G'"; [ "$output" = "app=adguard" ]
}

@test "grafana route has the grafana pod-selector (F9)" {
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/enabled\"' '$V'"; [ "$output" = "true" ]
  run bash -c "yq e '.metadata.annotations.\"gethomepage.dev/pod-selector\"' '$V'"; [ "$output" = "app.kubernetes.io/name=grafana" ]
  # 리스너 집합 상한 — 위 두 줄은 annotation만 잰다. web-public parentRef를 더해도(2026-09-03 실측)
  # 전건 초록이었다 — Grafana는 관측 스택의 전 대시보드·데이터소스 UI라 공개 표면 전환은
  # 정적 무증인이면 안 된다(실제 인터넷 도달에는 reserved-hosts.json/apps.json 추가가 별도로 필요).
  run yq '[.spec.parentRefs[].sectionName] | sort | join(",")' "$V"
  [ "$output" = "web-internal-tls" ] || { echo "grafana 리스너=$output"; false; }
}
