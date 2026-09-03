#!/usr/bin/env bats
# per-PVC 용량 가시화 du exporter(메타갭 ③ W1-A)의 계약을 강제한다.
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일(매니페스트 또는 캡처 픽스처)이라
#    그것으로 닫힌다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a

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
  # 경로 SSOT = infra/k3s-bootstrap/versions.env (F9/F15). 리터럴로 박지 않고 **거기서 파생**한다 —
  # 예전엔 두 값을 리터럴로 적어 두 곳이 갈라져도 이 @test가 초록이었다(bulk 경로 이식이 그 증거).
  source "$ROOT/infra/k3s-bootstrap/versions.env"
  [ -n "$INTERNAL_STORAGE_PATH" ]
  [ -n "$BULK_STORAGE_PATH" ]
  grep -q 'readOnly: true' "$F"
  # ⚠️ 파일 전체 `grep -qF "$BULK_STORAGE_PATH"`는 **자기 주석에 걸린다** — 경로 SSOT를 설명하는
  #    주석이 같은 값을 담고 있어서, hostPath를 옛 경로로 되돌려도 초록이었다(뮤테이션으로 실측).
  #    구조로 단언한다. `V=$(yq …)` 후 `grep -qxF`인 이유는 `[ "$a" = "$b" ]`가 bats 중간에서
  #    errexit 면제로 침묵 통과하기 때문이다(check-bats-style).
  vb="$(yq -e 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="storage-bulk") | .hostPath.path' "$F")"
  printf '%s' "$vb" | grep -qxF -- "$BULK_STORAGE_PATH"
  vi="$(yq -e 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="storage-internal") | .hostPath.path' "$F")"
  printf '%s' "$vi" | grep -qxF -- "$INTERNAL_STORAGE_PATH"
}

@test "du exporter carries no OrbStack/virtiofs binding (bare metal has no /mnt/mac)" {
  grep -q 'hostPath' "$F"                    # 양성 대조 — 대상이 실재하고 grep이 동작한다
  run grep -nE '^[^#]*(/mnt/mac|virtiofs)' "$F"
  [ "$status" -eq 1 ]
}

@test "du exporter never references the stale pre-dual-provisioner path" {
  # 구경로(/var/lib/rancher/k3s/storage) 회귀 시 W3 bulk 신호가 침묵 — 부정 단언
  # ⚠️ 이 @test는 부재 단언 하나뿐이라 형제 증인이 없다 — 예전 `-ne 0`에서는 pvc-du-exporter.yaml을
  #    리네임해도 초록이었다(2026-08-29 격리 트리 실측: 12개 중 생존 2건 — 이 @test와, 피연산자가
  #    kustomization.yaml인 @test 10. 매니페스트를 읽는 나머지 열 중에서는 이 @test가 유일했다).
  run grep -q '/var/lib/rancher/k3s/storage' "$F"
  [ "$status" -eq 1 ]
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

@test "the du heartbeat is the LAST line of the pushed payload (truncation must be fail-closed)" {
  # ADR-0003 「살릴 것 하나」 — 형제 2곳(backup-files-data.sh · adguard rewrite-reconciler)과 동형 계약.
  # /api/v1/import/prometheus는 스트리밍 인입이라 절단되면 읽은 접두부만 적재된다. 하트비트가 앞줄이면
  # "하트비트만 적재 + 티어/PVC 용량 유실"이 가능해 절단이 무성이 되고, PvcDuExporterStale이 초록인 채
  # storage_tier_*·pvc_dir_size_bytes만 조용히 사라진다(BulkStorageLow의 원천이 그 값이다). 마지막에
  # 두면 절단은 언제나 하트비트부터 잃으므로 stale 알림이 그 사실을 페이징한다.
  # 판정은 **위치**다: 하트비트 append가 BODY append 전건 중 마지막이고, push는 그 뒤다.
  hb=$(grep -nF 'BODY="${BODY}pvc_du_last_success_timestamp' "$F" | cut -d: -f1)
  last=$(grep -nF 'BODY="${BODY}' "$F" | tail -n1 | cut -d: -f1)
  push=$(grep -nF 'printf "%b" "$BODY"' "$F" | cut -d: -f1)
  [ -n "$hb" ]
  [ -n "$last" ]
  [ -n "$push" ]
  # 양성 대조 — append가 하트비트 하나뿐이면 "마지막"은 공허하게 참이다(실측 2026-09-03: 6줄).
  [ "$(grep -cF 'BODY="${BODY}' "$F")" -ge 4 ]
  [ "$hb" -eq "$last" ]
  [ "$hb" -lt "$push" ]
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
  [ "$status" -eq 1 ]
}

@test "du exporter image is a repo digest-pinned image (no fresh third-party)" {
  grep -qE 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@sha256:' "$F"
}

@test "du exporter is wired into kustomization" {
  # ⚠️ 원문 grep은 주석 한 줄(`  # 임시 비활성 - pvc-du-exporter.yaml …`)에도 초록이다 — resources
  #    시퀀스에서 빠져 CronJob이 클러스터에서 사라져도 이 파일이 12/12 초록이었다(2026-09-03 격리
  #    트리 실측). 나머지 11개 @test는 전부 pvc-du-exporter.yaml **원문**만 읽으므로, 이 한 줄이
  #    "컴포넌트가 실재한다"의 유일한 증인이다.
  #    선례: test_relay.bats:68-80이 같은 실패 모양을 실측하고 yq 파싱으로 옮겼다 — 그 주석이 바로
  #    이 자리를 선례로 지목하는데 처방은 역수입되지 않았다. 여기서 닫는다.
  # ⚠️ 이 갭이 여는 것은 "무성 소실"이 아니라 **CI 회귀 채널**이다 — 라이브는
  #    r4-storage-backup.yaml의 PvcDuExporterStale(`absent(last_over_time(…[3d]))` 가지)이
  #    prune 후 약 48.5h 안에 warning으로 페이징한다. 그래도 CI 채널을 여는 값이 2줄이라 고친다.
  # ⚠️ `command -v yq >/dev/null || skip`를 여기 새로 들이지 않는다 — 이 파일은 :31·:33·:103에서
  #    yq를 무조건 쓰므로, 이 자리만 skip을 두면 yq 부재가 이 @test만 조용히 빼는 두 번째
  #    fail-open이 된다(그 자리는 skip이 아니라 red여야 한다).
  run yq '.resources | contains(["pvc-du-exporter.yaml"])' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
  printf '%s' "$output" | grep -qxF -- 'true'
  # dangling 참조 금지(양성 대조 — kustomize build를 깨는 배선을 초록으로 넘기지 않는다).
  # `contains` 단독의 로스터 붕괴는 tests/gates/의 컷오버 가드가 앵커 2개로 이미 덮으므로
  # 여기서 앵커를 중복 고정하지 않는다(정당한 resources 증가마다 두 자리가 드리프트한다).
  [ -f "$F" ]
}

@test "du exporter mounts kubelet pods read-only and documents the widened F8 surface" {
  # 세 번째 루트(meta-observability 01) — emptyDir du는 cadvisor에 파드별 fs 시리즈가 없어(라이브
  # 실측) du만 남는다. 이 루트는 타 파드 projected SA 토큰 도달 표면이라 F8 계약 주석에 수용·완화가
  # 명시돼야 한다(readOnly·egress vmsingle뿐·자기 SA 비마운트·숫자만 push).
  vk="$(yq -e 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="kubelet-pods") | .hostPath.path' "$F")"
  printf '%s' "$vk" | grep -qxF -- "/var/lib/kubelet/pods"
  ro="$(yq -e 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] | select(.name=="kubelet-pods") | .readOnly' "$F")"
  printf '%s' "$ro" | grep -qxF -- "true"
  # F8 주석이 표면·활성화 요인·잔여를 **이름으로** 수용한다 — 문구가 지워지면 red(01 리뷰 H3).
  grep -q 'projected' "$F"
  grep -q 'secret/configmap' "$F"
  grep -q '읽기 개방의 활성화 요인' "$F"
  grep -q 'exfil' "$F"
  grep -q '실사용 가능' "$F"   # apiserver 도달 실측(netpol 미차단)의 명시 수용
}

@test "grafana fingerprint scan: one match pushes, zero is silent, collision dies (executed)" {
  # 정적 grep이 아니라 **실행** 증인 — 스크립트를 추출해 경로만 픽스처로 치환하고 curl을 캡처
  # 스텁으로 바꿔 세 시나리오를 실제로 돌린다(jobfailed 하네스의 파생·실행 관례).
  # GNU coreutils 전제(df --output·du -B1 — 컨테이너와 동일 환경) — 없으면 정직하게 skip.
  df -B1 --output=size,avail / >/dev/null 2>&1 || skip "GNU coreutils 전용 실행 증인"
  FX="$BATS_TEST_TMPDIR"
  yq -e 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].args[0]' "$F" > "$FX/script.sh"
  # 접두 보존형 치환(sed 구분자 # — 경로에 |가 와도 안전) + 치환 착지 앵커: 마운트 경로가
  # 리네임되면 sed가 no-op이 되어 **실 경로**를 읽는다 — 조용한 no-op을 여기서 죽인다(01 리뷰 M5).
  sed -i "s#/storage-#$FX/storage-#g; s#/kubelet-pods#$FX/kp#g" "$FX/script.sh"
  grep -qF "$FX/kp/" "$FX/script.sh"
  grep -qF "$FX/storage-internal" "$FX/script.sh"
  mkdir -p "$FX/bin" "$FX/storage-internal/pvc-a_ns1_data" "$FX/storage-bulk/pvc-b_ns2_files"
  printf 'x' > "$FX/storage-internal/pvc-a_ns1_data/f"; printf 'x' > "$FX/storage-bulk/pvc-b_ns2_files/f"
  printf '%s\n' '#!/usr/bin/env bash' 'cat > "$CAPTURE"' > "$FX/bin/curl"; chmod +x "$FX/bin/curl"
  # 시나리오 1: 지문 1건 + **노이즈 혼재**(01 리뷰 M6 — 프로덕션 실모양: alertmanager도 data
  # emptyDir을 갖는다): 비지문 data 볼륨·서브디렉토리 지문(미매치여야)을 섞고, 값까지 결박한다
  # (kubelet과 같은 블록 회계 -sB1 — [0-9][0-9]*는 빈 값 방어, digest-exporter gauge 관례).
  mkdir -p "$FX/kp/uid1/volumes/kubernetes.io~empty-dir/data"
  printf 'db' > "$FX/kp/uid1/volumes/kubernetes.io~empty-dir/data/grafana.db"
  mkdir -p "$FX/kp/uid9/volumes/kubernetes.io~empty-dir/data"
  head -c 40960 /dev/zero > "$FX/kp/uid9/volumes/kubernetes.io~empty-dir/data/nflog"
  mkdir -p "$FX/kp/uid8/volumes/kubernetes.io~empty-dir/data/sub"
  printf 'db' > "$FX/kp/uid8/volumes/kubernetes.io~empty-dir/data/sub/grafana.db"
  CAPTURE="$FX/cap1" PATH="$FX/bin:$PATH" run bash "$FX/script.sh"
  [ "$status" -eq 0 ]
  v="$(sed -n 's/^grafana_data_dir_size_bytes \([0-9][0-9]*\)$/\1/p' "$FX/cap1")"
  [ -n "$v" ]
  want="$(du -sB1 "$FX/kp/uid1/volumes/kubernetes.io~empty-dir/data" | cut -f1)"
  [ "$v" = "$want" ]
  grep -q '^grafana_du_fingerprint_matches 1$' "$FX/cap1"
  # 시나리오 2: 지문 0건 → 크기 미방출·matches=0은 방출(지문 붕괴 무성 방지 — 01 리뷰 H2)
  rm -rf "${FX:?}/kp"; mkdir -p "$FX/kp"
  CAPTURE="$FX/cap2" PATH="$FX/bin:$PATH" run bash "$FX/script.sh"
  [ "$status" -eq 0 ]
  # ⚠️ 피연산자가 매니페스트가 아니라 **스텁이 쓴 캡처 파일**이다 — `-ne 0`이면 push가 통째로
  #    죽어 cap2가 없는 경우도 "크기 미방출"로 읽혀 이 줄이 통과했다. 다음 줄(matches 0) 덕에
  #    @test 자체는 red였지만 진단이 한 줄 밀려 엉뚱한 곳을 가리켰다 — 2026-08-29 실측: 지문 0건일
  #    때 push를 건너뛰는 회귀를 심으면 전환 전엔 다음 줄이 rc 2로 죽고, 전환 후엔 여기가 red다.
  run grep -q 'grafana_data_dir_size_bytes' "$FX/cap2"
  [ "$status" -eq 1 ]
  grep -q '^grafana_du_fingerprint_matches 0$' "$FX/cap2"
  # 시나리오 3: 지문 2건 → **push는 나가고**(1차 신호·하트비트 보존 — 01 리뷰 M1) 그 뒤 fail-loud.
  # 이 단언 쌍이 그 설계 결정을 락한다 — 순서를 되돌리면 여기가 red로 반대한다(L4).
  mkdir -p "$FX/kp/uid1/volumes/kubernetes.io~empty-dir/data" "$FX/kp/uid2/volumes/kubernetes.io~empty-dir/data"
  printf 'db' > "$FX/kp/uid1/volumes/kubernetes.io~empty-dir/data/grafana.db"
  printf 'db' > "$FX/kp/uid2/volumes/kubernetes.io~empty-dir/data/grafana.db"
  CAPTURE="$FX/cap3" PATH="$FX/bin:$PATH" run bash "$FX/script.sh"
  [ "$status" -ne 0 ]   # 부재 단언이 아니라 스크립트의 fail-loud rc — `-eq 1`로 좁히지 않는다(bash rc는 그 스크립트의 규약)
  echo "$output" | grep -q '지문'
  grep -q 'pvc_du_last_success_timestamp' "$FX/cap3"
  grep -q '^grafana_du_fingerprint_matches 2$' "$FX/cap3"
}
