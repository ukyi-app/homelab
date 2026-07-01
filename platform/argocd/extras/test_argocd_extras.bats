#!/usr/bin/env bats
# argocd-extras 가드. PR1: SealedSecret(patch-mode). PR2(Task 9)에서 HTTPRoute 단언 추가.
# (@test 이름 영어. 중간 단언 [ ]/단순 명령, 최종 명령 status만 신뢰.)

D="$BATS_TEST_DIRNAME"
S="$D/argocd-accounts.sealed.yaml"

@test "kustomize build succeeds and renders exactly one SealedSecret" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: SealedSecret')" -eq 1 ]
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

@test "kustomization has no KSOPS generator (plain SealedSecret CR)" {
  run grep -q 'generators:' "$D/kustomization.yaml"; [ "$status" -ne 0 ]
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
}

@test "webhook HTTPRoute exposes ONLY /api/webhook on web-public (UI stays internal)" {
  H="$D/httproute-webhook.yaml"
  run grep -q 'argocd-webhook.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-public' "$H"; [ "$status" -eq 0 ]
  run grep -q 'value: /api/webhook' "$H"; [ "$status" -eq 0 ]
  run grep -q 'name: argocd-server' "$H"; [ "$status" -eq 0 ]
  # 루트 PathPrefix(/)는 web-public에 절대 노출하지 않는다 — /api/webhook만.
  run grep -qE 'value: /$' "$H"; [ "$status" -ne 0 ]
}
