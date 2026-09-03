#!/usr/bin/env bats
# argocd-extras 가드. PR1: SealedSecret(patch-mode). PR2(Task 9)에서 HTTPRoute 단언 추가.
# (@test 이름 영어. 중간 단언 [ ]/단순 명령, 최종 명령 status만 신뢰.)
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
#    yq 자리는 비대상이다 — rc가 아니라 `$output`으로 판정하고, yq의 rc는 키 부재를 값 false와 구별하지 않는다.

D="$BATS_TEST_DIRNAME"
S="$D/argocd-accounts.sealed.yaml"

@test "kustomize build succeeds and renders exactly two SealedSecrets (argocd-secret patch + notifications)" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: SealedSecret')" -eq 2 ]
}

@test "SealedSecret patch-merges into argocd-secret with patch annotation in template metadata" {
  run yq '.metadata.name' "$S"; [ "$output" = "argocd-secret" ]
  run yq '.metadata.namespace' "$S"; [ "$output" = "argocd" ]
  run yq '.spec.template.metadata.name' "$S"; [ "$output" = "argocd-secret" ]
  run yq '.spec.template.metadata.namespace' "$S"; [ "$output" = "argocd" ]
  run yq '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$S"; [ "$output" = "true" ]
  run yq '.spec.encryptedData."accounts.ukkiee.password"' "$S"; [ "$output" != "null" ]
  # GitHub 웹훅 서명 검증용 시크릿도 같은 patch-mode SealedSecret으로 argocd-secret에 머지된다.
  run yq '.spec.encryptedData."webhook.github.secret"' "$S"; [ "$output" != "null" ]
}

@test "no passwordMtime is sealed (avoids RFC3339 settings-load failure)" {
  run yq '.spec.encryptedData."accounts.ukkiee.passwordMtime"' "$S"; [ "$output" = "null" ]
}

@test "argocd-notifications-secret is wired and sealed for argocd ns (independent ownership, not patch-mode)" {
  N="$D/argocd-notifications-secret.sealed.yaml"
  grep -q 'argocd-notifications-secret.sealed.yaml' "$D/kustomization.yaml" || { echo "kustomization 미등록"; false; }
  run yq 'select(.kind=="SealedSecret") | .metadata.name' "$N"
  [ "$output" = "argocd-notifications-secret" ] || { echo "name=$output"; false; }
  run yq 'select(.kind=="SealedSecret") | .metadata.namespace' "$N"
  [ "$output" = "argocd" ] || { echo "ns=$output"; false; }
  # 봇 토큰만 봉인($telegram-token → webhook URL 확장). chatId는 봉인하지 않는다(비-credential·webhook body 리터럴).
  run yq '.spec.encryptedData."telegram-token"' "$N"; [ "$output" != "null" ] || { echo "telegram-token 미봉인"; false; }
  run yq '.spec.encryptedData."telegram-chat-id"' "$N"; [ "$output" = "null" ] || { echo "chatId는 봉인 대상 아님(webhook body 리터럴): $output"; false; }
  # 독립 소유 — patch-mode 금지(argocd-accounts와 달리 기존 Secret 머지가 아니라 신규 생성).
  run yq '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$N"
  [ "$output" = "null" ] || { echo "patch 어노테이션이 있으면 안 됨: $output"; false; }
}

@test "kustomization has no KSOPS generator (plain SealedSecret CR)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 kustomization.yaml을 리네임하면 grep이 rc 2로
  #    죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -q 'generators:' "$D/kustomization.yaml"; [ "$status" -eq 1 ]
}

@test "notify-smoke source builds, container is app, and is NOT synced by argocd-extras" {
  kustomize build "$D/smoke" >/dev/null || { echo "smoke build 실패"; false; }
  run yq '.metadata.name' "$D/smoke/deployment.yaml"
  [ "$output" = "notify-smoke" ] || { echo "name=$output"; false; }
  grep -q 'name: app' "$D/smoke/deployment.yaml" || { echo "container 이름 app 아님"; false; }
  # 상주화 방지: argocd-extras가 smoke를 resources로 싱크하면 안 된다(canary는 Task 6에서 별도 Application만).
  run yq '.resources[]' "$D/kustomization.yaml"
  if printf '%s' "$output" | grep -q 'smoke'; then echo "extras가 smoke 포함 — 상주화 위험"; false; fi
}

@test "kustomize build renders exactly two HTTPRoutes (internal UI + public webhook)" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: HTTPRoute')" -eq 2 ]
}

@test "HTTPRoute exposes argocd UI on web-internal-tls to argocd-server:80" {
  H="$D/httproute.yaml"
  run grep -q 'argocd.home.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-internal-tls' "$H"; [ "$status" -eq 0 ]
  run grep -q 'name: argocd-server' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'port: 80' "$H"; [ "$status" -eq 0 ]
  run grep -q 'kind: Gateway' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'weight: 1' "$H"; [ "$status" -eq 0 ]
  # ⚠️ 리스너 집합 **상한**. 위 grep은 web-internal-tls의 존재만 본다 — UI 라우트에 web-public
  #    parentRef를 하나 더 붙이면 argocd UI 전면이 Cloudflare 터널로 나가는데 그 편집이 무증인이었다.
  run yq '[.spec.parentRefs[].sectionName] | sort | join(",")' "$H"
  [ "$output" = "web-internal-tls" ] || { echo "UI 리스너=$output"; false; }
}

@test "webhook HTTPRoute exposes ONLY /api/webhook on web-public (UI stays internal)" {
  H="$D/httproute-webhook.yaml"
  run grep -q 'argocd-webhook.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-public' "$H"; [ "$status" -eq 0 ]
  run grep -q 'value: /api/webhook' "$H"; [ "$status" -eq 0 ]
  run grep -q 'name: argocd-server' "$H"; [ "$status" -eq 0 ]
  # ⚠️ 루트 부재가 아니라 **경로 집합 자체**를 고정한다. 여기 있던 `value: /$` 부재 단언은
  #    루트 한 형태만 봐서 `- path: { type: PathPrefix, value: /api }` 한 줄이면 9/9 초록이었다
  #    (실측). PathPrefix라 `/api`는 /api/v1/session·/api/v1/applications를 전부 포함하고,
  #    argocd-server는 server.insecure=true(평문 HTTP)로 도는 데다 이 라우트가 argocd의 유일한
  #    공개 표면이다(reserved-hosts.json + gateway.yaml `*.ukyi.app` web-public 리스너와 교차).
  # ⚠️ `(.matches // [{}])[] | .path.value // "/"`가 load-bearing이다. 원안 `[.spec.rules[].matches[]
  #    .path.value]`는 **matches 없는 rule을 통째로 건너뛴다** — Gateway API 기본이 PathPrefix `/`
  #    (전면 노출)인데 그 rule이 있어도 `/api/webhook`을 내 초록이다(픽스처 실측: 강화식은
  #    `/,/api/webhook`으로 red, 원안은 green). 헤더 :6 규약대로 rc가 아니라 `$output`으로 판정한다.
  run yq '[.spec.rules[] | (.matches // [{}])[] | .path.value // "/"] | sort | join(",")' "$H"
  [ "$output" = "/api/webhook" ] || { echo "web-public 경로 집합=$output"; false; }
}
