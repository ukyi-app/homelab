#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; cd "$ROOT" || exit 1
  # 🔴 root/apps 열거의 SSOT — 형제 파일 root/test_projects.bats의 setup()과 **같은 관용구**다.
  #    root-app이 `directory.recurse: true`(root-app.yaml:17, 아래 첫 @test가 직접 단언한다)라
  #    **하위 디렉토리**의 Application도 그대로 싱크되는데, 이 파일의 레인들은 1단계 글롭
  #    `apps/*.yaml`이었다. 실측 2026-09-03: `apps/platform/evil.yaml`(retry 없음 + 원장에 없는
  #    sync-wave)을 두면 이 파일과 형제 test_sync_wave_ledger.bats가 7 ok / 0 not ok 전건 초록이었다.
  # `find`가 아니라 `git ls-files`인 이유: ArgoCD가 싱크하는 것은 tracked 파일뿐이라 분모가 배포
  #    진실과 일치하고, 레포 커널(`scan_enumerate … git ls-files`)과 어휘가 같다.
  APPFILES="$(git ls-files -- platform/argocd/root/apps | grep '\.yaml$' | LC_ALL=C sort)"
  local n
  n="$(printf '%s\n' "$APPFILES" | grep -c . || true)"
  # 열거 붕괴 바닥값 — setup() 실패는 전 @test를 red로 만들어 fail-closed다. 값은 **붕괴 경계**이지
  # 현재 도메인 크기(8)가 아니다: 스냅샷을 굳히면 Application을 정당하게 철거할 때마다 red가 난다
  # (실측 2026-09-03: 착지 전 아래 retry 레인의 `-ge 8`이 정확히 그랬다 — 2개를 철거한 6건 트리에서
  #  「열거가 6건으로 붕괴했다」로 거짓 red. 같은 판정이 scripts/check-argocd-revision.sh:47-50).
  [ "$n" -ge 6 ] || { echo "root/apps 열거가 ${n}건으로 붕괴했다(기대 >=6)"; false; }
}

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
  # 재귀 열거 SSOT — setup() 참조(1단계 글롭 금지). 하위 디렉토리에 Application이 아닌 yaml(혹은
  # 파싱 불가 파일)을 두면 root-app이 그대로 싱크하므로 여기서 전수로 막는다.
  local f
  for f in $APPFILES; do
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
  # 재귀 열거 SSOT — setup() 참조. 열거 붕괴 바닥값도 setup()이 진다(여기에 두면 그 값이 도메인
  # 크기로 굳어 정당한 철거가 red가 됐다 — 위 setup() 주석의 실측).
  local f n=0
  for f in $APPFILES; do
    run yq -e '.spec.syncPolicy.retry.limit == 5' "$f"
    [ "$status" -eq 0 ] || { echo "retry.limit != 5: $f"; false; }
    n=$((n + 1))
  done
  # 루프가 실제로 돌았다는 증인 — setup() 바닥값과 이 카운터가 어긋나면 확장이 조용히 깨진 것이다.
  [ "$n" -ge 6 ] || { echo "retry 루프가 ${n}회만 돌았다(기대 >=6)"; false; }
}

@test "argocd-extras Application targets the right path/namespace with SSA + CreateNamespace=false" {
  A="platform/argocd/root/apps/argocd-extras.yaml"
  run yq '.spec.source.path' "$A"; [ "$output" = "platform/argocd/extras" ]
  run yq '.spec.destination.namespace' "$A"; [ "$output" = "argocd" ]
  run grep -q 'ServerSideApply=true' "$A"; [ "$status" -eq 0 ]
  run grep -q 'CreateNamespace=false' "$A"; [ "$status" -eq 0 ]
}
