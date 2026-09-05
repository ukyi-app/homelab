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
  # ⚠️ 백엔드/매치 집합 상한 — 위는 리스너(parentRefs)만 잰다. 두 번째 rule로 `/api`
  #    PathPrefix → 다른 Service backendRef를 더해도 이 파일의 grafana @test 전건이 통과했다
  #    (2026-09-04 실측: 격리 사본에 그 rule을 추가해도 3/3 ok — victoria-stack/prod에는 이
  #    파일 외에 httproute-grafana.yaml을 여는 bats가 없다). 내부 라우트라 위협은 공개 노출이
  #    아니라 **백엔드 바꿔치기·경로 우회**다(처방 형제: platform/files/prod/test_files_route.bats,
  #    착지형 46c799c). `(.matches // [{}])`가 load-bearing — matches 없는 rule은 Gateway API
  #    기본값 PathPrefix `/` + 전 method로 집합에 들어간다.
  run yq '[.spec.rules[].backendRefs[] | .name + ":" + (.port|tostring)] | sort | join(",")' "$V"
  [ "$output" = "grafana:3000" ] || { echo "grafana 백엔드 집합=$output"; false; }
  run yq '[.spec.rules[] | (.matches // [{}])[] | (.path.value // "/") + "|" + (.method // "ANY")] | sort | join(",")' "$V"
  [ "$output" = "/|ANY" ] || { echo "grafana 매치 집합=$output"; false; }
}
