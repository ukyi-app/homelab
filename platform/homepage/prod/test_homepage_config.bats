#!/usr/bin/env bats
# homepage config(configMapGenerator 소스 파일) 가드. @test 이름은 영어(한글 인코딩 깨짐).
setup() { C="${BATS_TEST_DIRNAME}/config"; }

@test "kubernetes integration runs in cluster mode with gateway discovery" {
  run grep -q 'mode: cluster' "$C/kubernetes.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gateway: true' "$C/kubernetes.yaml"; [ "$status" -eq 0 ]
}

@test "infra widgets query victoriametrics, not metrics-server" {
  run grep -q 'type: prometheusmetric' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'vmsingle.observability.svc.cluster.local:8428' "$C/services.yaml"; [ "$status" -eq 0 ]
}

@test "settings declare the dashboard title as ukyi" {
  run grep -qE '^title:[[:space:]]*ukyi$' "$C/settings.yaml"; [ "$status" -eq 0 ]
}

@test "settings apply header/target/search/background tweaks" {
  run grep -qE '^headerStyle:[[:space:]]*underlined' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -qE '^target:[[:space:]]*_blank' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'searchDescriptions: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q '/images/background.jpg' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hideVersion: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'statusStyle: dot' "$C/settings.yaml"; [ "$status" -eq 0 ]
}

@test "layout groups carry icons and quicklaunch hides internet search" {
  run grep -q 'icon: mdi-server-network' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hideInternetSearch: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
}

@test "widgets add the logo and h23 time format" {
  run grep -qE '^[[:space:]]*-[[:space:]]*logo:' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q '/images/logo.png' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hourCycle: h23' "$C/widgets.yaml"; [ "$status" -eq 0 ]
  run grep -q 'timeStyle: short' "$C/widgets.yaml"; [ "$status" -eq 0 ]
}

@test "bookmarks expose github and instagram profiles" {
  run grep -q 'https://github.com/ukkiee' "$C/bookmarks.yaml"; [ "$status" -eq 0 ]
  run grep -q 'https://instagram.com/ukyi_' "$C/bookmarks.yaml"; [ "$status" -eq 0 ]
}

@test "infra group includes the glances host widget" {
  run grep -q 'type: glances' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'glances.observability.svc.cluster.local:61208' "$C/services.yaml"; [ "$status" -eq 0 ]
}

@test "infra exposes operational metrics (disk/cert/backup/alerts/wal/sync)" {
  run grep -q 'node_filesystem_avail_bytes' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'certmanager_certificate_expiration' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'barman_cloud' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'ALERTS{alertstate="firing"' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'cnpg_collector_pg_wal' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'argocd_app_info' "$C/services.yaml"; [ "$status" -eq 0 ]
}

@test "infra includes a glances host memory tile" {
  run grep -q 'metric: memory' "$C/services.yaml"; [ "$status" -eq 0 ]
}
