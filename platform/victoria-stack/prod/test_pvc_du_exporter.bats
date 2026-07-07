#!/usr/bin/env bats
# per-PVC 용량 가시화 du exporter(메타갭 ③ W1-A)의 계약을 강제한다.
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)

f=platform/victoria-stack/prod/pvc-du-exporter.yaml

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  F="$ROOT/$f"
}

@test "du exporter is a daily CronJob pushing pvc_dir_size_bytes to vmsingle" {
  grep -q 'kind: CronJob' "$F"
  grep -q 'pvc_dir_size_bytes' "$F"
  grep -q 'api/v1/import/prometheus' "$F"
}

@test "du exporter mounts BOTH provisioner roots read-only (versions.env is the path SSOT)" {
  # 경로 SSOT = infra/k3s-bootstrap/versions.env (F9/F15):
  #   INTERNAL_STORAGE_PATH=/var/lib/rancher/k3s-storage/internal, bulk=/mnt/mac/Volumes/homelab/k3s-bulk(라이브 실측)
  grep -q 'readOnly: true' "$F"
  grep -q '/var/lib/rancher/k3s-storage/internal' "$F"
  grep -q '/mnt/mac/Volumes/homelab/k3s-bulk' "$F"
  grep -q 'storage-bulk' "$F"
}

@test "du exporter never references the stale pre-dual-provisioner path" {
  # 구경로(/var/lib/rancher/k3s/storage) 회귀 시 W3 bulk 신호가 침묵 — 부정 단언
  run grep -q '/var/lib/rancher/k3s/storage' "$F"
  [ "$status" -ne 0 ]
}

@test "du exporter fails loud per-tier on empty scan and emits tier capacity metrics" {
  # F9/F20: 카운트는 티어별 — 전역 카운트는 bulk 경로가 틀려도 internal만으로 녹색이 된다.
  grep -q 'N_internal' "$F"
  grep -q 'N_bulk' "$F"
  grep -qE 'N_internal.*-ge 1' "$F"
  grep -qE 'N_bulk.*-ge 1' "$F"
  # bulk staleness/저용량 판정의 원천 = 티어 용량 메트릭(W3 선행 신호)
  grep -q 'storage_tier_avail_bytes' "$F"
  grep -q 'storage_tier_size_bytes' "$F"
  grep -q 'pvc_du_last_success_timestamp' "$F"
}

@test "du exporter enforces the F8 isolation contract (all four guards, not just readOnly)" {
  # 전-PVC 읽기 도달성의 유출 반경을 강제 가드로 봉인 — 4개 전부 grep.
  grep -q 'automountServiceAccountToken: false' "$F"          # (1) API 토큰 미동반
  grep -q 'name: pvc-du-exporter-default-deny-egress' "$F"    # (2) 전용 default-deny egress netpol
  grep -q 'app.kubernetes.io/name: pvc-du-exporter' "$F"      #     netpol 파드셀렉터
  grep -qE 'cpu: 200m' "$F"                                   # (3) resources limits
  grep -qE 'memory: 64Mi' "$F"
  # (4) readOnly 마운트는 위 테스트에서 확인
}

@test "du exporter reads all PVC dirs via root + DAC_READ_SEARCH (drop-ALL), no write path" {
  # 0700 PVC 디렉토리(pg 등)를 non-root로는 못 읽는다 — 읽기-전용 우회 capability로만 순회(라이브 검증됨).
  grep -q 'runAsUser: 0' "$F"
  grep -qE 'drop: \[ *ALL *\]' "$F"
  grep -q 'DAC_READ_SEARCH' "$F"
  grep -q 'readOnlyRootFilesystem: true' "$F"
  grep -q 'allowPrivilegeEscalation: false' "$F"
}

@test "du exporter egress is internal-only (DNS + vmsingle, no internet exfil path)" {
  # F8: 유출 경로 봉쇄 — 이 잡은 전-PVC를 읽으므로 인터넷 egress 금지(digest-exporter와 달리 ghcr 불요).
  grep -q 'app.kubernetes.io/name: vmsingle' "$F"   # vmsingle:8428 허용
  grep -q 'k8s-app: kube-dns' "$F"                  # DNS 허용
  run grep -q '0.0.0.0/0' "$F"                      # 인터넷 egress 부정 단언
  [ "$status" -ne 0 ]
}

@test "du exporter image is a repo digest-pinned image (no fresh third-party)" {
  grep -qE 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@sha256:' "$F"
}

@test "du exporter is wired into kustomization" {
  grep -q 'pvc-du-exporter.yaml' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
}
