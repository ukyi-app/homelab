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
  # CHART_VERSION(bootstrap helm 설치)과 argocd-app.yaml targetRevision(self-manage Application)은
  # 같은 차트를 두 번 핀한다 — 갈리면 DR 콜드스타트에서 selfHeal이 방금 설치한 차트를 되돌린다.
  [ "$(tr -d '[:space:]' < platform/argocd/CHART_VERSION)" = "$(yq '.spec.sources[0].targetRevision' platform/argocd/argocd-app.yaml)" ]
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

@test "reconciliation timeout is tightened to 30s as the polling backstop behind the /api/webhook route" {
  # 웹훅(extras/httproute-webhook.yaml — /api/webhook만 web-public)이 즉시 refresh의 1차 경로이고,
  # 30s 폴링은 웹훅 유실·서명 실패·터널 다운 시의 백스톱이다. "웹훅을 쓰지 않는다"는 #190 이후 거짓.
  run yq '.configs.cm."timeout.reconciliation"' "$V"; [ "$output" = "30s" ]
}

@test "chart NetworkPolicy stays enabled (the only ingress isolation of the argocd namespace)" {
  # 자체 netpol(network-policies-prod)은 prod ns 전용이라 argocd ns를 덮지 않는다. 차트 netpol 4개가
  # repo-server 8081(KSOPS age 키·인증 없는 GenerateManifest)을 argocd 컴포넌트로 좁히는 유일한 정책이다.
  # 12cd8f8이 "자체 netpol이 관리한다"는 거짓 전제로 껐던 자리 — 다음 차트 hop이 같은 이유로 다시 끄지 못하게 잠근다.
  run yq '.global.networkPolicy.create' "$V"; [ "$output" = "true" ]
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
  has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "miss: $2"; false; }; }
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
  printf '%s' "$output" | grep -qF -- 'Egress' || { echo "default-deny egress 없음"; false; }
  # ⚠️ 텍스트 needle 금지 — yq는 **주석을 보존**하고 이 블록의 주석이 '192.168.0.0/16'과 '6443'을
  #    문자 그대로 담고 있다. 예전 `grep -qF` 루프는 그래서 죽은 단언이었다(뮤테이션 실증:
  #    except에서 192.168.0.0/16을 지워 사설대역 lateral 차단을 무력화해도, port를 6443→16443으로
  #    오타내도 **통과**했다). 값이 아니라 구조를 본다.
  NODE_SUBNET='192.168.117.0/24' # 노드 InternalIP 서브넷 — versions.env와의 등식은 infra/k3s-bootstrap/tests/test_01-versions.bats가 잠근다
  # (1) apiserver 레인 — CIDR과 TCP/6443이 **같은 egress 규칙 안에** 있어야 한다(별개 규칙이면 무의미).
  yq -e '.extraObjects[] | select(.metadata.name=="argocd-notifications-allow-egress") | .spec.egress[]
         | select(.to[].ipBlock.cidr == "'"$NODE_SUBNET"'")
         | select(.ports[] | (.port == 6443 and .protocol == "TCP")) | .ports' "$v" >/dev/null \
    || { echo "allow-egress: ipBlock=$NODE_SUBNET + TCP/6443 규칙 없음"; false; }
  # (2) telegram 레인 — 0.0.0.0/0 + TCP/443, except는 사설 3대역 **정확히**(과부족 둘 다 잡는다).
  ex="$(yq -e '.extraObjects[] | select(.metadata.name=="argocd-notifications-allow-egress") | .spec.egress[]
               | select(.to[].ipBlock.cidr == "0.0.0.0/0")
               | select(.ports[] | (.port == 443 and .protocol == "TCP"))
               | .to[].ipBlock.except | sort | join(",")' "$v")" \
    || { echo "allow-egress: 0.0.0.0/0 + TCP/443 규칙 없음"; false; }
  printf '%s' "$ex" | grep -qxF '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16' \
    || { echo "allow-egress except 집합 불일치: got=[$ex]"; false; }
}

@test "application-controller is scraped by pod-annotations (R6 argocd_app_info source)" {
  V="platform/argocd/bootstrap-values.yaml"
  run yq '.controller.podAnnotations."prometheus.io/scrape"' "$V"; [ "$output" = "true" ]
  run yq '.controller.podAnnotations."prometheus.io/port"' "$V"; [ "$output" = "8082" ]
}

@test "on-deployed oncePer gates on the actual sync-job revision, not observed HEAD (#224 noise regression guard)" {
  v=platform/argocd/bootstrap-values.yaml
  run yq '.notifications.triggers."trigger.on-deployed"' "$v"
  printf '%s' "$output" | grep -qF -- 'operationState.syncResult != nil'      # #224 nil 가드(when)
  printf '%s' "$output" | grep -qF -- 'operationState.syncResult.revision'    # oncePer가 실 sync 작업 revision(sync.revision 아님)
}
