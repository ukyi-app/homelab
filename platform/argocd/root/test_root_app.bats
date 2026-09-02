#!/usr/bin/env bats

@test "root app recurses platform/argocd/root, uses project default, auto-syncs" {
  run grep -q 'path: platform/argocd/root' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'recurse: true' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'project: default' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'selfHeal: true' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
}

@test "argocd self-manage app uses the single bootstrap values file + project default" {
  run grep -q 'project: default' platform/argocd/argocd-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'platform/argocd/bootstrap-values.yaml' platform/argocd/argocd-app.yaml
  [ "$status" -eq 0 ]
}

@test "every root/apps yaml is valid and is an Application" {
  for f in platform/argocd/root/apps/*.yaml; do
    run yq e 'true' "$f"; [ "$status" -eq 0 ]
    run yq '.kind' "$f"; [ "$output" = "Application" ]
  done
}

@test "every root/apps Application retries transient sync failures (retry.limit == 5)" {
  # 🔴 retry가 없는 Application은 **콜드스타트 레이스에서 그대로 고착한다.** 예: cnpg-barman-plugin(-2)은
  #    cert-manager(-3)의 CRD/webhook에 cross-Application 의존인데 root는 순서만 정하고 health를
  #    기다리지 않는다 — dry-run이 CRD보다 빠르면 SyncFailed고, 자가복구가 없으면 사람이 명시 sync를
  #    할 때까지 Missing이다. 분류기(“외부 CRD를 쓰는 앱”)를 두지 않고 **전수 균일 규칙**으로 잠근다:
  #    transient 실패에 retry를 주는 것은 어느 Application에도 해가 없고, 예외 목록이 없어야 드리프트가
  #    바로 red가 된다. cf. docs/traps-detail.md 「ArgoCD retry 소진 후 명시 sync」
  local f n=0
  for f in "$BATS_TEST_DIRNAME"/apps/*.yaml; do
    run yq -e '.spec.syncPolicy.retry.limit == 5' "$f"
    [ "$status" -eq 0 ] || { echo "retry.limit != 5: $f"; false; }
    n=$((n + 1))
  done
  # 열거 붕괴 바닥값 — glob이 비면 루프가 0회라 위 단언이 어떤 rc로도 안 보인다(vacuous green).
  [ "$n" -ge 8 ] || { echo "root/apps 열거가 ${n}건으로 붕괴했다(기대 >=8)"; false; }
}

@test "argocd-extras Application targets the right path/namespace with SSA + CreateNamespace=false" {
  A="platform/argocd/root/apps/argocd-extras.yaml"
  run yq '.spec.source.path' "$A"; [ "$output" = "platform/argocd/extras" ]
  run yq '.spec.destination.namespace' "$A"; [ "$output" = "argocd" ]
  run grep -q 'ServerSideApply=true' "$A"; [ "$status" -eq 0 ]
  run grep -q 'CreateNamespace=false' "$A"; [ "$status" -eq 0 ]
}
