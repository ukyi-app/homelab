#!/usr/bin/env bats
# basebackup PVC 워밍 훅 가드 (2026-08-14 배경 감사 + 적대 검증에서 나온 것).
#
# `bulk-ssd`는 volumeBindingMode: WaitForFirstConsumer라 **파드가 스케줄되기 전에는 Bound되지 않는다.**
# `pg-basebackup-local`을 마운트하는 유일한 워크로드는 하루 1회 CronJob이므로, 워밍 훅이 없으면
# sync 시점에 PVC가 Pending → ArgoCD PVC health가 Progressing → **Sync phase 마지막 wave가 끝나지
# 않아 PostSync hook(ensure-role-password)이 실행되지 않는다**(owner/ro 비번 적용이 최대 ~24시간 지연).
# ⚠️ 라이브에서는 원리적으로 안 보인다 — PVC가 이미 Bound다. 콜드스타트/DR 전용 결함이다.
# ⚠️ StorageClass의 volumeBindingMode를 Immediate로 바꾸는 우회는 안 된다 — local-path 계열은
#    "no node was specified"로 실패한다(storageclass-standard.yaml 주석의 실측).
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글이 인코딩 깨짐. 중간 단언은 [ ]/단순 명령만.)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  W="$BATS_TEST_DIRNAME/basebackup-pvc-warmup.yaml"
  P="$BATS_TEST_DIRNAME/basebackup-pvc.yaml"
  K="$BATS_TEST_DIRNAME/kustomization.yaml"
}

@test "the warmup Job is a Sync hook that is removed once it succeeds" {
  h="$(yq '.metadata.annotations."argocd.argoproj.io/hook"' "$W")"
  printf '%s' "$h" | grep -qxF -- 'Sync'
  d="$(yq '.metadata.annotations."argocd.argoproj.io/hook-delete-policy"' "$W")"
  printf '%s' "$d" | grep -qxF -- 'HookSucceeded'
  # kustomization이 실제로 포함해야 렌더에 들어간다.
  run grep -q 'basebackup-pvc-warmup.yaml' "$K"
  [ "$status" -eq 0 ]
}

@test "the warmup Job mounts the very PVC whose binding it is meant to trigger" {
  c="$(yq '.spec.template.spec.volumes[] | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName' "$W")"
  n="$(yq '.metadata.name' "$P")"
  [ -n "$n" ]
  printf '%s' "$c" | grep -qxF -- "$n"
  # 마운트가 목적이므로 컨테이너에 volumeMount가 실제로 걸려 있어야 한다(볼륨 선언만으로는 스케줄러가
  # 바인딩을 트리거하지 않는다).
  m="$(yq '[.spec.template.spec.containers[].volumeMounts[]? | select(.name == "backup")] | length' "$W")"
  printf '%s' "$m" | grep -qxF -- '1'
}

@test "the warmup Job never writes to the volume (it only needs to be scheduled)" {
  ro="$(yq '.spec.template.spec.containers[] | select(.name == "warmup") | .volumeMounts[] | select(.name == "backup") | .readOnly' "$W")"
  printf '%s' "$ro" | grep -qxF -- 'true'
}

@test "the warmup Job shares the same wave as the PVC (a later wave would not unblock it)" {
  # 둘 다 annotation 없음 = ArgoCD 기본 wave 0. 한쪽에만 wave가 생기면 순서가 갈린다.
  wj="$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave" // "0"' "$W")"
  wp="$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave" // "0"' "$P")"
  [ -n "$wj" ]
  printf '%s' "$wj" | grep -qxF -- "$wp"
}

@test "the PVC still uses the WaitForFirstConsumer class this hook exists for" {
  # 이 전제가 사라지면(예: SC 교체) 훅의 존재 이유를 다시 볼 것 — 조용히 남는 것을 막는다.
  sc="$(yq '.spec.storageClassName' "$P")"
  printf '%s' "$sc" | grep -qxF -- 'bulk-ssd'
  run grep -q 'volumeBindingMode: WaitForFirstConsumer' "$ROOT/infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml"
  [ "$status" -eq 0 ]
}
