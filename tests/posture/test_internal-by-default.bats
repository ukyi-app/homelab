#!/usr/bin/env bats

# 기본 내부(internal-by-default) 자세 (설계 §6): ArgoCD, Grafana, AdGuard UI는
# 절대 공개적으로 접근 가능하면 안 된다. LoadBalancer는 Traefik 하나뿐이고, 공개
# egress는 cloudflared 하나뿐이다. 공개 접근은 오직 Gateway homelab/gateway의
# 'web-public' 리스너에 붙은 HTTPRoute로만 부여된다 — 이 서비스들은 그것을 가져선 안 된다.
# LIVE: kubectl 컨텍스트 = M3가 sync된 k3s VM 필요.
#
# ⚠️ 아래 두 공개면 단언은 **부정 카운트=0** 형태다. 셀렉터가 도메인을 잃으면(Gateway 리스너 개명,
# HTTPRoute CRD 그룹 이동, parentRef 드리프트, 네임스페이스 RBAC 축소) "위반 0"과 "아무것도 안 봤다"가
# 같은 초록이 된다. 그래서 판정 전에 (a) 열거 바닥값과 (b) 술어 유효성 양성 대조를 둔다.
# 실측: **플랫폼 소유** web-public rule 2건(argocd/argocd-webhook · files/files-public) —
# 그중 argocd 백엔드 1건 · grafana 백엔드 0건(영구). 앱 rule 수는 여기 적지 않는다: 인-레포 앱은
# 0개일 수 있고(apps/README.md), 산문에 그 수를 적으면 철거와 함께 죽은 수치가 된다 —
# 실제로 그랬다(`prod/page`·`prod/trip-mate-api` 철거 후에도 "4건 = 2 + 앱 2건"으로 남아 있었다).
# ⚠️ 앱 rule은 분모에 넣지 않는다 — 공유 차트의 `route.public` 기본값이 false라 앱은 teardown 없이도
# 0이 될 수 있다(이 파일이 단언하는 internal-by-default가 곧 앱의 기본 상태다). 바닥값이 앱 개수에
# 결합되면 "앱을 전부 내부로 돌렸다"가 "열거 붕괴"와 같은 red가 된다(적대 검토 실측 — 라이브 셰임으로
# 재현). 붕괴는 0으로 떨어지는 사건이라 플랫폼 2건만으로도 전부 잡힌다.
WEB_PUBLIC_RULES_MIN=2   # 레포에 고정된 플랫폼 소유 2건이 불변식. 앱 rule은 그 위 헤드룸. 래칫 아님

# web-public 리스너에 붙은 전체 rule 수(열거 바닥값의 분모).
web_public_rules() { jq '[.items[]|select(any(.spec.parentRefs[]?;.sectionName=="web-public"))|.spec.rules[]?]|length'; }

@test "servicelb LoadBalancer Services are exactly traefik + adguard-dns" {
  # adguard-dns LB는 R7 설계상 필수(LAN DHCP option 6 대상 — lan-dns 런북): servicelb가
  # VM 노드 IP에 :53을 게시한다. 그 외 servicelb LoadBalancer가 늘어나면 공개면 확장이므로 실패해야 한다.
  # ⚠️ tailscale operator가 만든 LB(loadBalancerClass=tailscale, pg-rw-tailscale·traefik-ts)는
  # tailnet 전용(공개면 아님)이라 제외한다 — servicelb(class 미지정) LB만 공개면 후보다.
  run bash -c "kubectl get svc -A -o json | jq -r '[.items[] | select(.spec.type==\"LoadBalancer\") | select((.spec.loadBalancerClass // \"\") != \"tailscale\") | \"\(.metadata.namespace)/\(.metadata.name)\"] | sort | join(\" \")'"
  [ "$status" -eq 0 ]
  [ "$output" = "edge/adguard-dns gateway/traefik" ]
}

@test "ArgoCD server is public only via the /api/webhook allowlist" {
  # HTTPRoute backendRefs는 .spec.rules[].backendRefs에 있다(.spec.backendRefs는 부재 — 옛 vacuous 버그).
  # web-public 리스너의 argocd-* 백엔드는 오직 argocd-webhook 라우트의 /api/webhook prefix만 허용한다.
  # matches 생략 시 Gateway API 기본값은 PathPrefix '/'(전면 노출)이므로 위반으로 센다.
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  routes="$output"
  # (a) 열거 바닥값 — 셀렉터가 web-public 도메인을 잃으면 아래 count는 언제나 0이다.
  scanned="$(web_public_rules <<<"$routes")"
  [ "$scanned" -ge "$WEB_PUBLIC_RULES_MIN" ]
  # (b) 양성 대조 — argocd 백엔드 rule이 실제로 1건(=argocd-webhook) 보여야 술어가 살아 있다는 증거다.
  argocd_rules="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("argocd")))
    ] | length' <<<"$routes")"
  [ "$argocd_rules" -eq 1 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("argocd")))
      | (if (.matches // [] | length)==0 then ["/"] else (.matches | map(.path.value // "/")) end) as $paths
      | select(any($paths[]; . != "/api/webhook"))
    ] | length' <<<"$routes")"
  [ "$count" = "0" ]   # /api/webhook 이외 경로로 argocd를 web-public에 노출하는 rule 0
}

@test "Grafana has no public HTTPRoute" {
  # ⚠️ 이 단언은 라이브에서 단 한 번도 실질 평가된 적이 없다 — grafana rule이 영구 0이라
  # 술어가 죽어도(백엔드 이름 규약 변경, 셀렉터 오타) 언제나 0/0 초록이다. 바닥값만으로는 부족하고
  # **술어 자신이 어딘가에서는 매치한다**는 양성 대조가 필요하다.
  run kubectl get httproute -A -o json
  [ "$status" -eq 0 ]
  routes="$output"
  scanned="$(web_public_rules <<<"$routes")"
  [ "$scanned" -ge "$WEB_PUBLIC_RULES_MIN" ]
  # 양성 대조 — 같은 셀렉터(backendRefs 이름 접두 "grafana")가 리스너 무관하게 ≥1건 매치해야 한다.
  # grafana는 web-internal-tls에 붙어 있다(internal-by-default의 의도된 상태).
  grafana_any="$(jq '[
      .items[]
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("grafana")))
    ] | length' <<<"$routes")"
  [ "$grafana_any" -ge 1 ]
  count="$(jq '[
      .items[]
      | select(any(.spec.parentRefs[]?; .sectionName=="web-public"))
      | .spec.rules[]?
      | select(any(.backendRefs[]?; (.name // "") | startswith("grafana")))
    ] | length' <<<"$routes")"
  [ "$count" = "0" ]   # grafana 백엔드는 web-public 리스너에 절대 없어야 한다(내부 전용)
}

@test "AdGuard UI is ClusterIP (Tailscale-only), never LoadBalancer" {
  run bash -c "kubectl -n edge get svc adguard-ui -o jsonpath='{.spec.type}'"
  [ "$output" = "ClusterIP" ]
}

@test "admin services are never a cloudflared backend (ConfigMap fallback surface, not the routing authority)" {
  # exact-tests-4: 라우팅 권위는 infra/cloudflare/tunnel.tf:10 config_src="cloudflare"의 원격
  # (API) config다 — 이 ConfigMap의 ingress 블록은 config_src가 "local"로 반전될 때의 폴백일
  # 뿐이라 관측만으로 상한을 못 재고(존재 ≥1 + 3이름 부재 denylist라 다른 backend 추가는
  # 무증인), 새 backend 추가에 대한 정확 집합 상한은 권위 쪽 infra/_tests/test_tf_static.bats
  # 「cloudflared tunnel ingress backends are exactly …」가 진다(gate-safe, terraform 비의존).
  run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -c 'traefik.gateway.svc.cluster.local'"
  [ "$output" -ge 1 ]
  run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -Ec 'argocd|grafana|adguard'"
  [ "$output" = "0" ]
}
