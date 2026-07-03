#!/usr/bin/env bats

@test "argocd bootstrap values disable HA and tune processors" {
  run grep -q 'redis-ha:' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -qE 'statusProcessors:\s*"?4"?' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -qE 'operationProcessors:\s*"?2"?' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
}

@test "repo-server wires KSOPS: sops-age mount + SOPS_AGE_KEY_FILE + exec build options" {
  run grep -q 'sops-age' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -q '/home/argocd/.config/sops/age/keys.txt' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -q -- '--enable-alpha-plugins --enable-exec --enable-helm' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
}

@test "argocd chart version is pinned (semver, not a range)" {
  run grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' platform/argocd/CHART_VERSION
  [ "$status" -eq 0 ]
}

V="platform/argocd/bootstrap-values.yaml"

@test "ukkiee account is enabled with login capability in configs.cm" {
  run yq '.configs.cm."accounts.ukkiee"' "$V"; [ "$output" = "login" ]
}

@test "ukkiee gets admin via a collision-resistant p-policy; default is readonly" {
  run yq '.configs.rbac."policy.default"' "$V"; [ "$output" = "role:readonly" ]
  run yq '.configs.rbac."policy.csv"' "$V"; [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'p, ukkiee, [*], [*], [*], allow'
}

@test "built-in admin is disabled (ukkiee is the sole admin path)" {
  run yq '.configs.cm."admin.enabled"' "$V"; [ "$output" = "false" ]
}

@test "configs.secret has only the patch annotation, no data-bearing fields (two-writer invariant)" {
  # 차트가 argocd-secret에 patch 어노테이션을 부여해야 sealed-secrets가 머지 가능(DR-durable)
  run yq '.configs.secret.annotations."sealedsecrets.bitnami.com/patch"' "$V"; [ "$output" = "true" ]
  # data 필드는 없어야 — 있으면 차트가 data 블록을 렌더해 SSA가 머지 키를 prune (annotations 단일 키만 허용)
  run yq '.configs.secret | keys | length' "$V"; [ "$output" = "1" ]
  run yq '.configs.secret.argocdServerAdminPassword' "$V"; [ "$output" = "null" ]
  run yq '.configs.secret.extra' "$V"; [ "$output" = "null" ]
}

@test "server.insecure stays true (TLS terminated upstream)" {
  run yq '.configs.params."server.insecure"' "$V"; [ "$output" = "true" ]
}

@test "reconciliation timeout is tightened to 30s for faster deploy convergence (internal ArgoCD = no webhook)" {
  # ArgoCD 내부 전용이라 GitHub 웹훅 대신 폴링 주기 단축으로 배포 지연을 줄인다(노출 없이).
  run yq '.configs.cm."timeout.reconciliation"' "$V"; [ "$output" = "30s" ]
}

@test "notifications controller is enabled, owns no secret, and has resource limits" {
  run yq '.notifications.enabled' platform/argocd/bootstrap-values.yaml
  [ "$output" = "true" ] || { echo "enabled != true: $output"; false; }
  run yq '.notifications.secret.create' platform/argocd/bootstrap-values.yaml
  [ "$output" = "false" ] || { echo "secret.create != false: $output"; false; }
  # 상주 워크로드 자원 limit 필수(원장 블라인드스팟 트랩 — 원격 차트라 source-scanner 미포착)
  run yq '.notifications.resources.limits.memory' platform/argocd/bootstrap-values.yaml
  [ "$output" != "null" ] || { echo "notifications.resources.limits.memory 미설정"; false; }
}

@test "notifications cm has native telegram service, Markdown line1 templates, deployed+degraded triggers, central selector subscription" {
  has() { printf '%s' "$1" | grep -qF "$2" || { echo "miss: $2"; false; }; }
  v=platform/argocd/bootstrap-values.yaml
  # native telegram service — 토큰만($telegram-token, tgbotapi에 직접 전달·URL 미로깅 → webhook의 토큰 로그 유출 회피).
  run yq '.notifications.notifiers."service.telegram"' "$v"
  has "$output" 'token: $telegram-token'
  # Markdown line1(native는 parseMode Markdown 강제): 글리프 + *제목*
  run yq '.notifications.templates."template.app-deployed"' "$v"
  has "$output" '✅ *배포 완료*'
  run yq '.notifications.templates."template.app-degraded"' "$v"
  has "$output" '🔴 *앱 저하*'
  run yq '.notifications.triggers."trigger.on-deployed"' "$v"
  has "$output" 'Healthy'; has "$output" 'oncePer'
  run yq '.notifications.triggers."trigger.on-health-degraded"' "$v"
  has "$output" 'Degraded'
  run yq '.notifications.subscriptions | tag' "$v"
  [ "$output" = "!!seq" ] || { echo "subscriptions must be a YAML list, got $output"; false; }
  run yq '.notifications.subscriptions[0].selector' "$v"
  has "$output" 'notify.homelab/telegram'
  run yq '.notifications.subscriptions[0].triggers | tag' "$v"
  [ "$output" = "!!seq" ] || { echo "triggers must be a list, got $output"; false; }
  # recipient = telegram:<음수 그룹 chatId>(native는 '-' 접두 음수 그룹만; 양수 DM은 @channel 오해석). $secret 확장 없음(리터럴).
  run yq '.notifications.subscriptions[0].recipients[0]' "$v"
  printf '%s' "$output" | grep -qE '^telegram:-[0-9]+$' || { echo "recipient must be telegram:<negative chatId>, got $output"; false; }
}

@test "notifications netpol is in chart extraObjects, syncs before controller, default-deny + allows" {
  v=platform/argocd/bootstrap-values.yaml
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-default-deny-egress") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$v"
  [ "$output" = "-1" ] || { echo "default-deny sync-wave != -1: $output"; false; }
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-default-deny-egress") | .spec.policyTypes[]' "$v"
  printf '%s' "$output" | grep -qF 'Egress' || { echo "default-deny egress 없음"; false; }
  run yq '.extraObjects[] | select(.metadata.name=="argocd-notifications-allow-egress")' "$v"
  # trap-safe: 누락을 플래그로 모아 최종 단언이 권위를 갖게(bats 중간 false 침묵통과 회피).
  miss=0
  for n in '0.0.0.0/0' '192.168.0.0/16' '192.168.139.0/24' '6443'; do
    printf '%s' "$output" | grep -qF "$n" || { echo "miss in netpol: $n"; miss=1; }
  done
  [ "$miss" -eq 0 ] || { echo "allow-egress netpol missing required needles"; false; }
}

@test "application-controller is scraped by pod-annotations (R6 argocd_app_info source)" {
  V="platform/argocd/bootstrap-values.yaml"
  run yq '.controller.podAnnotations."prometheus.io/scrape"' "$V"; [ "$output" = "true" ]
  run yq '.controller.podAnnotations."prometheus.io/port"' "$V"; [ "$output" = "8082" ]
}

@test "on-deployed oncePer gates on the actual sync-job revision, not observed HEAD (#224 noise regression guard)" {
  v=platform/argocd/bootstrap-values.yaml
  run yq '.notifications.triggers."trigger.on-deployed"' "$v"
  printf '%s' "$output" | grep -qF 'operationState.syncResult != nil'      # #224 nil 가드(when)
  printf '%s' "$output" | grep -qF 'operationState.syncResult.revision'    # oncePer가 실 sync 작업 revision(sync.revision 아님)
}
