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
}

@test "no passwordMtime is sealed (avoids RFC3339 settings-load failure)" {
  run yq '.spec.encryptedData."accounts.ukkiee.passwordMtime"' "$S"; [ "$output" = "null" ]
}

@test "kustomization has no KSOPS generator (plain SealedSecret CR)" {
  run grep -q 'generators:' "$D/kustomization.yaml"; [ "$status" -ne 0 ]
}

@test "kustomize build also renders exactly one HTTPRoute" {
  run kustomize build "$D"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^kind: HTTPRoute')" -eq 1 ]
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
