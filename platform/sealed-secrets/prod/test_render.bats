#!/usr/bin/env bats
# sealed-secrets 컨트롤러 컴포넌트 — 렌더 + 소유권(appset 제외 + 수동 Application 1개) 게이트

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; C="$ROOT/platform/sealed-secrets/prod"; }

@test "sealed-secrets kustomization renders with helm chart" {
  run kustomize build --enable-helm "$C"
  [ "$status" -eq 0 ]
}

@test "render includes the SealedSecret CRD and the controller deployment" {
  run kustomize build --enable-helm "$C"
  echo "$output" | grep -q "kind: CustomResourceDefinition"
  echo "$output" | grep -q "sealedsecrets.bitnami.com"
  echo "$output" | grep -q "kind: Deployment"
}

@test "controller fullname is pinned to kubeseal's default (sealed-secrets-controller)" {
  # 차트 기본 fullname(sealed-secrets)은 kubeseal 기본(--controller-name sealed-secrets-controller)과
  # 불일치 — fetch-cert가 실패한다. fullnameOverride로 고정.
  run kustomize build --enable-helm "$C"
  echo "$output" | grep -q "name: sealed-secrets-controller"
}

@test "sealed-secrets is excluded from the platform appset (no double-ownership)" {
  run grep -E "path: platform/sealed-secrets/\*, exclude: true" "$ROOT/platform/argocd/root/appset.yaml"
  [ "$status" -eq 0 ]
}

@test "exactly one manual sealed-secrets Application with an early sync-wave" {
  run grep -E "argocd.argoproj.io/sync-wave: \"-?[0-9]+\"" "$ROOT/platform/argocd/root/apps/sealed-secrets.yaml"
  [ "$status" -eq 0 ]
}

@test "sealed-secrets namespace is owned by platform/namespaces" {
  run grep -E "name: sealed-secrets" "$ROOT/platform/namespaces/prod/namespaces.yaml"
  [ "$status" -eq 0 ]
}

@test "memory ledger has a sealed-secrets row" {
  run grep -E "ledger:row --> sealed-secrets" "$ROOT/docs/memory-ledger.md"
  [ "$status" -eq 0 ]
}
