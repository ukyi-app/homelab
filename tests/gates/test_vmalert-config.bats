#!/usr/bin/env bats
# vmalert가 GitOps로 동기화된 룰 변경을 자동 반영하도록 강제한다.
# configCheckInterval이 없으면 vmalert는 mount된 룰 파일 변경을 감시하지 않아, ArgoCD가 ConfigMap을
# 갱신해도 메모리상 옛 룰을 계속 평가한다(수동 rollout restart/-/reload 전까지 silent staleness).
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VMALERT="$ROOT/platform/victoria-stack/prod/vmalert.yaml"
}

@test "vmalert auto-reloads rule files on change (configCheckInterval set)" {
  grep -q 'configCheckInterval' "$VMALERT"
}

@test "vmagent auto-reloads scrape config on change (promscrape.configCheckInterval set)" {
  # 없으면 scrape config(ConfigMap) 변경이 rollout restart 전까지 반영 안 됨(silent staleness).
  grep -q 'promscrape.configCheckInterval' "$ROOT/platform/victoria-stack/prod/vmagent.yaml"
}

@test "pod-annotations scrape honors target labels (KSM namespace/pod not clobbered to observability)" {
  # honor_labels 없으면 kube_* 메트릭 namespace가 전부 observability가 돼 namespace 필터/조인이 깨진다
  # (PostgresClusterDown 오발화·PodOOMKilled join 고장의 라이브 검증된 원인).
  grep -q 'honor_labels: true' "$ROOT/platform/victoria-stack/prod/vmagent-scrape-config.yaml"
}

@test "crown-jewel DB liveness + non-OOM crashloop alerts are defined" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: PostgresClusterDown' "$C"          # 단일 인스턴스 pg 생존 페이징
  grep -q 'cnpg_collector_up' "$C"                    # pg-1에서 직접 scrape돼 라벨 정확(KSM clobbering 회피)
  grep -q 'absent(cnpg_collector_up' "$C"             # 스크레이프 단절 fail-closed 가드
  run grep -q 'max(kube_pod_status_ready' "$C"; [ "$status" -ne 0 ]  # expr 회귀 금지(주석 언급은 허용)
  grep -q 'alert: PodCrashLooping' "$C"
  # PodCrashLooping은 블랙리스트(namespace!~)여야 신규 PSA ns(cache·sealed-secrets)를 자동 포함 —
  # 화이트리스트 회귀 금지(restarts_total에 namespace!~ 사용 확인).
  grep -qE 'kube_pod_container_status_restarts_total\{namespace!~' "$C"
}

@test "fourth backup (pgdump hedge) has a staleness alert like the other three" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: PgDumpHedgeStale' "$R"
  grep -q 'pg-dump-hedge-r2' "$R"
  grep -q 'kube_job_status_completion_time' "$R"
}

@test "disk-fill alerts carry a disk label so a critical inhibits the matching warning" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  # bulk-ssd 알림은 제거됨(virtiofs 집계라 측정 불가 — 죽은 알림). 잔존 금지.
  run grep -q 'disk: bulk-ssd' "$R"; [ "$status" -ne 0 ]
  # standard 디스크는 warning(StandardSSDWarning/Trend)+critical(StandardSSDFilling)이 같은 disk 라벨을
  # 공유해 disk-scoped inhibit(critical→warning)가 동작해야 한다.
  [ "$(grep -c 'disk: standard' "$R")" -ge 2 ]
  grep -q 'severity: critical, disk: standard' "$R"
  grep -q 'severity: warning, disk: standard' "$R"
}

@test "PVC saturation is monitored at the backing filesystem, not kubelet_volume_stats (hostPath PVs)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  # hostPath PV라 kubelet_volume_stats_*가 원천 부재 — 그 메트릭 의존 룰 금지(불가능한 접근 재도입 차단).
  # expr 형태(메트릭 접미사 '_')만 매치 — 주석의 설명 언급은 허용(core.yaml 선례와 동일).
  run grep -q 'kubelet_volume_stats_' "$R"; [ "$status" -ne 0 ]
  # 루트 fs 3티어: 조기 warning + critical + predict_linear 추세.
  grep -q 'alert: StandardSSDWarning' "$R"
  grep -q 'alert: StandardSSDFilling' "$R"
  grep -q 'alert: StandardSSDFillingTrend' "$R"
  grep -q 'predict_linear(node_filesystem_avail_bytes' "$R"
  # mountpoint는 정확일치 '/'(shm/tmpfs/virtiofs 노이즈 배제) — 옛 정규식 회귀 금지.
  grep -q 'node_filesystem_avail_bytes{mountpoint="/"}' "$R"
}

@test "WAL volume saturation uses the live CNPG WAL-size collector, not deprecated backup metrics" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: WALVolumeFilling' "$R"
  # WAL 볼륨 충전율: CNPG가 직접 export하는 size/volume_size(라이브). disk:pgwal로 분리해 루트 critical이 inhibit 안 함.
  grep -q 'cnpg_collector_pg_wal{value="size"}' "$R"
  grep -q 'cnpg_collector_pg_wal{value="volume_size"}' "$R"
  grep -q 'disk: pgwal' "$R"
  # deprecated 백업/아카이브 in-tree 메트릭(plugin 환경 0/부재) 재도입 금지(인시던트 #13/#14).
  run grep -qE 'cnpg_collector_last_(available_backup|archived|failed_archive)' "$R"; [ "$status" -ne 0 ]
}

@test "observability self-monitoring alerts defined and 4 components self-scraped" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: LogIngestionStalled' "$C"        # vector→VL 침묵 실패 감지
  grep -q 'vl_rows_ingested_total' "$C"
  grep -q 'alert: VmagentRemoteWriteDropping' "$C"  # 메트릭 유실
  grep -q 'alert: VmalertUnhealthy' "$C"            # 알림 엔진 자체 에러
  grep -q 'alert: KubeJobFailed' "$C"               # 전용 staleness 없는 Job 실패(cache-backup 등)
  # self-scrape 주석 — 위 self-metric이 TSDB에 들어가려면 4개 컴포넌트가 scrape돼야 한다.
  for comp in vmsingle vmagent vmalert victorialogs; do
    grep -q 'prometheus.io/scrape: "true"' "$ROOT/platform/victoria-stack/prod/$comp.yaml"
  done
}

@test "cert-manager TLS expiry alerts defined and wired into vmalert" {
  R="$ROOT/platform/victoria-stack/prod/rules/r5-cert-tls.yaml"
  V="$ROOT/platform/victoria-stack/prod/vmalert.yaml"
  # 4 룰: wildcard critical + 전 cert catch-all + NotReady + absent fail-closed.
  grep -q 'alert: CertWildcardExpiringSoon' "$R"
  grep -q 'alert: CertExpiringSoon' "$R"
  grep -q 'alert: CertManagerCertNotReady' "$R"
  grep -q 'alert: CertMetricsAbsent' "$R"
  # ready_status는 condition="True"==0만이 올바른 not-ready(False/Unknown==0은 비활성 시리즈라 상시 발화 함정).
  grep -q 'certmanager_certificate_ready_status{condition="True"} == 0' "$R"
  # fail-closed: 메트릭 전손 시 silent 무발화 방지.
  grep -q 'absent(certmanager_certificate_expiration_timestamp_seconds)' "$R"
  # 임계가 renewBefore 버퍼 안쪽이라 정상 자동갱신 무발화: wildcard 14일(<LE 30일)·catch-all 7일(<selfsigned 15일).
  grep -q '< 1209600' "$R"   # 14d
  grep -q '< 604800' "$R"    # 7d
  # vmalert Deployment에 r5 배선(--rule + volumeMount + volume) — 없으면 룰이 로드 안 됨.
  grep -q -- '--rule=/rules/r5/\*.yaml' "$V"
  grep -q 'name: rules-r5, mountPath: /rules/r5' "$V"
  grep -q 'name: rules-r5, configMap: { name: vmalert-rules-r5 }' "$V"
}

@test "vmagent buffer saturation has a leading warning + graceful drop cap" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  V="$ROOT/platform/victoria-stack/prod/vmagent.yaml"
  grep -q 'alert: VmagentBufferFilling' "$C"                      # leading 경고(드롭 전)
  grep -qE 'vmagent_remotewrite_pending_data_bytes|vm_persistentqueue_bytes_pending' "$C"  # 버퍼 메트릭
  grep -q 'maxDiskUsagePerURL' "$V"                               # eviction 대신 graceful drop
}

@test "relay single-down has an in-band signal via AM webhook failure (faster than off-node deadman)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: DeadmanswitchRelayUnreachable' "$C"
  grep -q 'alertmanager_notifications_failed_total{integration="webhook"}' "$C"
}

@test "vector sink backpressure has a partial-degradation alert (PR-B, uses PR-A exposed vector_utilization)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: VectorBackpressure' "$C"
  grep -q 'vector_utilization' "$C"   # vector internal_metrics로 노출된 메트릭
}

@test "node pressure and pod eviction alerts are defined (single-node starvation/disk coverage)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: NodePressure' "$C"                          # kubelet Memory/Disk/PIDPressure condition
  grep -q 'alert: PodEvicted' "$C"                            # 노드 압박 eviction(사후)
  grep -q 'kube_node_status_condition' "$C"                   # NodePressure 메트릭(라이브 확인)
  grep -q 'kube_pod_status_reason{reason="Evicted"}' "$C"     # PodEvicted 메트릭(honor_labels로 실제 ns)
}

@test "leading OOM alert uses working_set not max_usage (reclaimable page-cache trap)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: ContainerMemoryNearLimit' "$C"
  grep -q 'container_memory_working_set_bytes' "$C"
  # max_usage는 reclaimable page cache를 포함해 hostPath 로그파드에서 limit까지 차는 오발화 함정 — 회귀 금지.
  run grep -q 'container_memory_max_usage_bytes' "$C"; [ "$status" -ne 0 ]
}
