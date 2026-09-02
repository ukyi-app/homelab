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

@test "vmagent verifies the apiserver cert on kubelet scrapes (SA token is not handed to an unverified peer)" {
  # 두 kubelet 잡은 apiserver 프록시(kubernetes.default.svc:443)로 SA 베어러 토큰을 보낸다. 검증이
  # 꺼져 있으면 그 이름으로 응답하는 무엇에든 nodes/proxy 권한 토큰이 전달된다. 노드 CA는 같은
  # projected 볼륨의 ca.crt로 이미 파드 안에 있어 비용 0의 하드닝이다.
  F="$ROOT/platform/victoria-stack/prod/vmagent-scrape-config.yaml"
  # ⚠️ 판정은 **파싱한 tls_config**에만 한다 — 파일 전체 grep은 그 자리의 재도입 금지 주석이
  #    부재 단언을 만족시킨다(「규약을 설명한 파일이 그 규약에서 면제된다」 클래스).
  T="$BATS_TEST_TMPDIR/vmagent-tls.txt"
  yq -e '.data["scrape.yml"]' "$F" | yq '.scrape_configs[] | select(.scheme == "https") | .tls_config' - > "$T"
  [ -s "$T" ]
  # 로스터 등식 — https 잡 전건이 CA를 지정해야 한다(하드코딩 2가 아니라 레포에서 센다).
  jobs="$(yq -e '.data["scrape.yml"]' "$F" | yq '[.scrape_configs[] | select(.scheme == "https")] | length' -)"
  [ "$jobs" -ge 2 ]
  ca="$(grep -c 'ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt' "$T")"
  [ "$ca" -eq "$jobs" ]
  run grep -q 'insecure_skip_verify' "$T"; [ "$status" -eq 1 ]
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
  # ⚠️ 부재 단언은 `-ne 0`이 아니라 `-eq 1`이다 — grep은 대상 파일 부재/읽기불가에 rc **2**를 내는데
  #    `-ne 0`은 그것을 무매치와 구별하지 않는다(경로가 사라지면 통과 = vacuous green). 무매치는 정확히 rc 1.
  #    이 파일의 아래 부재 단언 전부가 같은 사유다.
  run grep -q 'max(kube_pod_status_ready' "$C"; [ "$status" -eq 1 ]  # expr 회귀 금지(주석 언급은 허용)
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
  run grep -q 'disk: bulk-ssd' "$R"; [ "$status" -eq 1 ]
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
  run grep -q 'kubelet_volume_stats_' "$R"; [ "$status" -eq 1 ]
  # 루트 fs 3티어: 조기 warning + critical + predict_linear 추세.
  grep -q 'alert: StandardSSDWarning' "$R"
  grep -q 'alert: StandardSSDFilling' "$R"
  grep -q 'alert: StandardSSDFillingTrend' "$R"
  grep -q 'predict_linear(node_filesystem_avail_bytes' "$R"
  # mountpoint는 정확일치 '/'(shm/tmpfs/virtiofs 노이즈 배제) — 옛 정규식 회귀 금지.
  grep -q 'node_filesystem_avail_bytes{mountpoint="/"}' "$R"
}

@test "root-fs pressure stays single-sourced through StandardSSD* (no duplicate threshold/trend rules)" {
  # 메타갭 ③ Task 1(W1-A): 루트 fs('/') 포화는 StandardSSD* 3룰(early warning/critical/trend)이 단일
  # 소스다. 같은 장애 모드에 중복 페이지를 만드는 신규 룰(NodeRootFs*/RootDisk* 등) 신설을 회귀 차단(F16).
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  run grep -cE 'alert: (NodeRootFs|RootDisk|RootFsFull|NodeDiskFull|DiskFull)' "$R"
  [ "$output" = "0" ] || [ "$status" -eq 1 ]
  # 기존 3룰 존치(계약 검토 결론 = contract-complete: 2단 절대임계 + predict_linear 추세, 단일 series).
  grep -q 'alert: StandardSSDWarning' "$R"
  grep -q 'alert: StandardSSDFilling' "$R"
  grep -q 'alert: StandardSSDFillingTrend' "$R"
  # ⚠️ 설계 결정: StandardSSD*에는 per-rule absent() 가드를 두지 않는다. 스크레이프 전손(node-exporter
  # 다운)의 fail-closed는 core.yaml의 TargetDown(up==0, critical)이 담당한다 — per-rule absent()를 붙이면
  # 메트릭 부재를 "SSD 여유 부족" critical로 오귀속(잘못된 원인 페이지)하고 TargetDown과 중복된다.
  grep -q 'alert: TargetDown' "$C"
  grep -q 'up == 0' "$C"
}

@test "WAL volume saturation uses the live CNPG WAL-size collector, not deprecated backup metrics" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: WALVolumeFilling' "$R"
  # WAL 볼륨 충전율: CNPG가 직접 export하는 size/volume_size(라이브). disk:pgwal로 분리해 루트 critical이 inhibit 안 함.
  grep -q 'cnpg_collector_pg_wal{value="size"}' "$R"
  grep -q 'cnpg_collector_pg_wal{value="volume_size"}' "$R"
  grep -q 'disk: pgwal' "$R"
  # deprecated 백업/아카이브 in-tree 메트릭(plugin 환경 0/부재) 재도입 금지(인시던트 #13/#14).
  run grep -qE 'cnpg_collector_last_(available_backup|archived|failed_archive)' "$R"; [ "$status" -eq 1 ]
}

@test "observability self-monitoring alerts defined and 4 components self-scraped" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: LogIngestionStalled' "$C"        # vector→VL 침묵 실패 감지
  grep -q 'vl_rows_ingested_total' "$C"
  grep -q 'alert: VmagentRemoteWriteDropping' "$C"  # 메트릭 유실
  grep -q 'alert: VmalertUnhealthy' "$C"            # 알림 엔진 자체 에러
  grep -q 'alert: KubeJobFailed' "$C"               # 전용 staleness 없는 Job 실패(files ns 등)
  # 블랙리스트(namespace!~)여야 신규 ns(files 등)를 자동 포함 — 화이트리스트 회귀 금지(:108 교훈, PodCrashLooping과 동일).
  grep -qE 'kube_job_failed\{condition="true", namespace!~' "$C"
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
  # ⚠️ 억제 절 판정은 **expr만** 뽑아 본다 — 파일 전체를 grep하면 룰 위 주석에 적힌 함수 이름이
  #    단언을 만족시킨다(이 파일 아래 ContainerMemoryNearLimit @test와 같은 규율).
  E="$BATS_TEST_TMPDIR/podevicted-expr.txt"
  yq -e '.data["core.yaml"]' "$C" | yq '.groups[].rules[] | select(.alert=="PodEvicted") | .expr' > "$E"
  [ -s "$E" ]
  # 억제 절이 없으면 Evicted 파드 **오브젝트**가 남아 있는 한 영구 발화한다(사람이 지울 때까지).
  grep -q 'changes_prometheus(' "$E"
  # `changes()`는 VM에서 **시리즈 탄생을 변화로 세어** KSM instance churn 때 잔존 Evicted가 2h 재발화한다.
  run grep -q 'changes(' "$E"; [ "$status" -eq 1 ]
}

@test "leading OOM alert measures unreclaimable memory, not working_set (page-cache contamination)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: ContainerMemoryNearLimit' "$C"
  # ⚠️ **expr만** 뽑아 본다 — 파일 전체를 grep하면 주석에 적힌 메트릭 이름이 단언을 만족시킨다
  #    (이 레포의 「규약을 설명한 파일이 그 규약에서 면제된다」 클래스). 아래 부재 단언 둘이 특히 그렇다.
  E="$BATS_TEST_TMPDIR/nearlimit-expr.txt"
  yq -e '.data["core.yaml"]' "$C" | yq '.groups[].rules[] | select(.alert=="ContainerMemoryNearLimit") | .expr' > "$E"
  [ -s "$E" ]
  grep -q 'container_memory_usage_bytes' "$E"
  grep -q 'container_memory_total_inactive_file_bytes' "$E"
  grep -q 'container_memory_total_active_file_bytes' "$E"
  # ⚠️ 이 알림은 **회수 불가 메모리**(anon+shmem+slab)를 재야 한다. 금지된 분자가 셋이다:
  #  - working_set = memory.current − inactive_file 이라 active_file(활성 clean page cache)을 싣는다.
  #    라이브 위양성(2026-08-31 glances: anon은 20일 불변인데 clean 캐시 charge만으로 88.3% 발화,
  #    같은 시점 cgroup memory.events는 max=0·oom_kill=0으로 limit에 닿은 적조차 없었다).
  #  - max_usage는 캐시를 통째로 싣는 더 나쁜 판이다.
  #  - **cache 차감**은 반대편 오답이다 — cgroup v2의 memory.stat:file은 tmpfs·shared memory를 포함하고
  #    이 호스트는 swap이 0이라 그 몫이 회수 불가인데도 빠진다(라이브 database/pg-1: shmem 38Mi가
  #    사라져 7.6% → 3.9%). 파일 LRU 두 축만 빼야 shmem이 남는다.
  #    발화 축의 증인은 tests/gates/vmalert-memory-nearlimit-firing-e2e.sh(L1·L2·L2b)다 — 여기는 정적 앵커.
  run grep -q 'container_memory_working_set_bytes' "$E"; [ "$status" -eq 1 ]
  run grep -q 'container_memory_max_usage_bytes' "$E"; [ "$status" -eq 1 ]
  run grep -q 'container_memory_cache' "$E"; [ "$status" -eq 1 ]
}

@test "R6 ArgoCDOutOfSync has an absent() fail-closed guard like the other R-rules" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  grep -q 'alert: ArgoCDOutOfSync' "$R"
  grep -q 'absent(argocd_app_info)' "$R"   # scrape 재단절 시 silent 무발화 방지
}

@test "R6 ArgoCDOutOfSync matches Unknown too — the only channel for a missed post-cutover repin" {
  # ⚠️ sync_status는 Synced / OutOfSync / **Unknown** 셋이다. `="OutOfSync"`는 Unknown을 놓치는데,
  #    Unknown이야말로 "repoURL/targetRevision을 resolve하지 못했다"의 주된 표면이다 — 컷오버로
  #    핀을 main으로 넘긴 뒤 `nuc-migration`을 지우면 재지정을 놓친 객체가 바로 그 상태가 된다.
  #    특히 `Application/argocd`는 어떤 Application의 source path에도 없어 root sync로 자동
  #    수렴하지 않으므로(감사 13) 이 룰이 그 누락을 알려주는 유일한 채널이다.
  # ⚠️ 이 @test가 없으면 매처를 되돌려도 전 게이트가 초록이다 — drift e2e의 L6는 이 알림을
  #    대조군으로 쓰지만 `absent(argocd_app_info)` 가지로 발화하므로 sync_status 매처를 한 번도
  #    태우지 않는다(리플레이 픽스처에 argocd_app_info 시리즈가 없다). 무증인 상태를 여기서 막는다.
  # ⚠️ 음성 단언은 **주석을 제외한 줄**에만 건다. 이 룰 파일의 주석이 전환 이유를 설명하느라
  #    옛 매처 문자열을 그대로 인용하고 있어, 파일 전체 grep으로 짜면 그 설명이 가드를 깨뜨린다
  #    (실제로 밟았다 — 배포되는 것은 expr이지 주석이 아니다).
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  run bash -c "grep -vE '^[[:space:]]*#' '$R' | grep -cF 'sync_status!~\"Synced\"'"
  [ "$output" = "1" ]
  run bash -c "grep -vE '^[[:space:]]*#' '$R' | grep -cF 'sync_status=\"OutOfSync\"'"
  [ "$output" = "0" ]
}

@test "the homepage ArgoCD widget asks the same question as the alert (matcher parity)" {
  # ⚠️ 알림만 넓히고 대시보드를 두면, 사람이 컷오버 중에 실제로 들여다보는 화면이 Unknown에
  #    눈이 먼 채로 남는다. 두 자리가 갈리면 다음에 매처를 옮길 때 어느 쪽이 SSOT인지 알 수 없다.
  S="$ROOT/platform/homepage/prod/config/services.yaml"
  run bash -c "grep -vE '^[[:space:]]*#' '$S' | grep -cF 'sync_status!~\"Synced\"'"
  [ "$output" = "1" ]
  run bash -c "grep -vE '^[[:space:]]*#' '$S' | grep -cF 'sync_status=\"OutOfSync\"'"
  [ "$output" = "0" ]
}

@test "workload-unavailable alert covers subscription-less platform components (files/adguard/homepage gap)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: WorkloadUnavailable' "$C"
  grep -q 'kube_deployment_status_condition{condition="Available", status="false"' "$C"
  # 블랙리스트(namespace!~)여야 files(files ns)·adguard(edge)·homepage(homepage) 자동 포함
  grep -qE 'kube_deployment_status_condition\{condition="Available", status="false", namespace!~' "$C"
  # 형제 축: StatefulSet은 KSM이 Available 조건을 안 내므로 ready < desired로 같은 클래스를 잰다.
  # ⚠️ 이 룰은 재시작 없는 0-ready만 본다 — ts-* proxy STS에 probe가 없어 tailnet 단절은 별건이다.
  grep -q 'alert: StatefulSetUnavailable' "$C"
  grep -q 'kube_statefulset_status_replicas_ready' "$C"
}

@test "cache backup has a staleness alert like the four pg backups (fail-open asymmetry fixed)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: CacheBackupStale' "$R"
  grep -q 'job_name=~"cache-backup' "$R"
  grep -q 'absent(kube_job_status_completion_time{job_name=~"cache-backup' "$R"   # fail-closed 가드
}

@test "files off-SSD backup freshness + bulk-ssd capacity alerts are defined (host push)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  grep -q 'alert: FilesBackupStale' "$R"     # 오프-SSD 백업 신선도(백업 필수화 강제)
  grep -q 'alert: FilesBulkSSDLow' "$R"       # bulk-ssd 용량 임계
  # 주간/일간 단발 push라 bare absent()는 영구 오발화 — last_over_time 윈도로 판정(restore-drill 패턴).
  grep -q 'last_over_time(files_backup_last_success_timestamp' "$R"
}

@test "per-PVC du exporter has staleness + in-cluster bulk capacity alerts (push metric windows)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  # 메타갭 ③ Task 2(W1-A): du exporter 생존 + bulk 용량(W3 선행 신호, F18/F20).
  grep -q 'alert: PvcDuExporterStale' "$R"
  grep -q 'alert: BulkStorageLow' "$R"
  # 일 1회 단발 push라 last_over_time 윈도 + absent fail-closed(instant staleness 함정, restore-drill 패턴).
  grep -q 'last_over_time(pvc_du_last_success_timestamp\[3d\])' "$R"
  grep -q 'absent(last_over_time(pvc_du_last_success_timestamp' "$R"
  grep -q 'storage_tier_avail_bytes{tier="bulk"}' "$R"
  grep -q 'last_over_time(storage_tier_avail_bytes{tier="bulk"}\[3d\])' "$R"
  grep -q 'absent(last_over_time(storage_tier_avail_bytes{tier="bulk"}' "$R"
}

@test "adguard rewrite reconciler has staleness + drift-fixed notify alerts (push metric, notify via AM not pod)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  A="$ROOT/platform/victoria-stack/prod/alertmanager.yaml"
  # 메타갭 ① Task 7(W2-A): 리컨실러 생존(staleness) + 실제 수렴 시 통지(F13 — 발송은 alertmanager 경유).
  grep -q 'alert: AdguardRewriteReconcilerStale' "$R"
  grep -q 'alert: AdguardRewriteDriftFixed' "$R"
  # 10분 push라 last_over_time 윈도 + absent fail-closed(push-metric staleness 함정).
  grep -q 'last_over_time(adguard_rewrite_reconcile_timestamp\[2h\])' "$R"
  grep -q 'absent(last_over_time(adguard_rewrite_reconcile_timestamp' "$R"
  # F19: fix 통지는 fix 타임스탬프 > 0 가드(no-op 0 샘플이 직전 fix를 지우지 않음).
  grep -q 'adguard_rewrite_last_fix_timestamp\[2h\]) > 0' "$R"
  # alertmanager 타이틀 매핑(신규 알림 한국어).
  grep -q 'AdguardRewriteReconcilerStale' "$A"
  grep -q 'AdguardRewriteDriftFixed' "$A"
}

@test "LAN DNS liveness has a dedicated critical alert (R7 made AdGuard the whole house's resolver)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: LanDnsPathDown' "$C"
  # ⚠️ 메트릭 선택이 본질이다. kube_endpoint_address 계열은 백엔드 0에서 **시리즈가 사라져**
  #    vmagent --promscrape.noStaleMarkers와 겹쳐 최대 5분 지연된다. replicas_ready는 값이 반전할 뿐
  #    시리즈가 남아 staleness를 타지 않는다 — 회귀하면 탐지가 조용히 5분 늦어진다.
  grep -qE 'kube_deployment_status_replicas_ready\{namespace="edge", ?deployment="adguard"\}' "$C"
  grep -q 'absent(kube_deployment_status_replicas_ready' "$C"    # 소멸/스크레이프 단절 fail-closed
  # 일상 롤아웃(실측 약 5초)에 발화하면 알림 피로가 된다 — for가 그보다 충분히 길어야 한다.
  grep -A9 'alert: LanDnsPathDown' "$C" | grep -q 'for: 60s'
  grep -A12 'alert: LanDnsPathDown' "$C" | grep -q 'severity: critical'
}

@test "every CRITICAL alert has a Telegram title mapping (silent-degradation class guard)" {
  # 🔴 alertmanager.yaml 머리말이 스스로 경고한 실패 모드인데 가드가 없었다(2026-08-18 신설):
  #    "재기동을 빠뜨리면 새 알림이 **제목 매핑 없이** alertname 그대로 텔레그램에 나간다 —
  #     red가 아니라 조용한 열화."
  # ⚠️ 범위는 **critical만**이다. warning은 36건 중 16건만 매핑돼 있어 전건 강제는 없는 규약을
  #    만들어내는 것이 된다. critical은 신설 당시 9건 중 8건이 매핑돼 있었고 빠진 하나가
  #    FilesBackupStale이었다(2026-10-01 자동 재무장 시 제목 없이 페이징될 뻔했다 — 같은 커밋에서 보충).
  AM="$ROOT/platform/victoria-stack/prod/alertmanager.yaml"
  [ -f "$AM" ]
  # 룰 파일에서 (alertname, severity) 쌍을 뽑는다 — alert 줄을 만나면 이름을 기억하고,
  # 다음 alert 줄 전에 나오는 첫 severity를 그 알림의 것으로 본다.
  pairs="$(awk '
    /^[[:space:]]*-[[:space:]]*alert:[[:space:]]*[A-Za-z0-9_]+/ {
      name=$0; sub(/.*alert:[[:space:]]*/, "", name); sub(/[^A-Za-z0-9_].*/, "", name); sev=""; next
    }
    name != "" && /severity:[[:space:]]*[a-z]+/ {
      if (sev == "") { s=$0; sub(/.*severity:[[:space:]]*/, "", s); sub(/[^a-z].*/, "", s); sev=s; print name, sev; name="" }
    }
  ' "$ROOT"/platform/victoria-stack/prod/rules/*.yaml)"
  [ -n "$pairs" ]
  missing=""
  while IFS=' ' read -r n sev; do
    [ "$sev" = "critical" ] || continue
    grep -qF "eq \$name \"$n\"" "$AM" || missing="${missing} ${n}"
  done <<EOF
$pairs
EOF
  if [ -n "$missing" ]; then echo "critical 알림의 텔레그램 제목 매핑 누락:$missing"; return 1; fi
}

@test "vmalert wires the r7 meta rules file (rule glob, mount, volume — three places)" {
  # r5 선례와 같은 3점 배선 — 하나라도 빠지면 룰이 조용히 미적재(silent staleness의 사촌).
  V="$ROOT/platform/victoria-stack/prod/vmalert.yaml"
  grep -q -- '--rule=/rules/r7/\*.yaml' "$V"
  grep -q 'name: rules-r7, mountPath: /rules/r7' "$V"
  grep -q 'name: rules-r7, configMap: { name: vmalert-rules-r7 }' "$V"
  grep -qE '^  - rules/r7-meta\.yaml$' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
}

@test "meta alerts exclude Watchdog and themselves from the flapping selector (self-reference loop)" {
  # ALERTS_FOR_STATE를 읽는 메타 룰이 자기 자신·상시 firing Watchdog를 세면 양성 피드백/상시
  # 노이즈다(homepage 위젯의 Watchdog 제외 선례). 셀렉터에 네 이름 전부가 있어야 한다.
  R="$ROOT/platform/victoria-stack/prod/rules/r7-meta.yaml"
  ex="$(grep -A8 'alert: AlertRuleFlapping' "$R" | grep -oE 'alertname!~"[^"]*"')"
  [ -n "$ex" ]
  for n in Watchdog AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged; do
    printf '%s' "$ex" | grep -q "$n"
  done
}

@test "every meta alert carries a Telegram title mapping (quality bar of this pass)" {
  # 이름 하드코딩 금지(리뷰 M6) — r7 전량을 룰 파일에서 파생하고, 같은 패스의 r4 신규 2종은
  # 명시로 얹는다(r4 전량 파생은 기존 미매핑 warning 16종을 소급 강제해 별개 결정이 된다 — 유보).
  AM="$ROOT/platform/victoria-stack/prod/alertmanager.yaml"
  R7="$ROOT/platform/victoria-stack/prod/rules/r7-meta.yaml"
  alerts="$(yq -e '.data["r7.yaml"]' "$R7" | yq '.groups[].rules[].alert')"
  [ "$(printf '%s\n' "$alerts" | grep -c .)" -ge 3 ]
  for n in $alerts GrafanaPluginBudgetLow GrafanaDuFingerprintLost; do
    grep -qF "eq \$name \"$n\"" "$AM"
  done
}
