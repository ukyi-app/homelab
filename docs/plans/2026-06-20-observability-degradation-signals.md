# 관측성 부분열화 신호 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** victoria-stack 부분열화 신호 3갭을 닫는다 — vmagent 버퍼 leading 경고+graceful drop, vector 메트릭 노출+backpressure 경고, relay 단독다운 in-band 신호.

**Architecture:** `platform/victoria-stack/prod/`의 `rules/core.yaml`(warning 룰 가산)·`vmagent.yaml`(maxDiskUsagePerURL)·`vector.yaml`(메트릭 노출). **★라이브(victoria-stack ArgoCD 싱크)** — 룰은 vmalert configCheckInterval reload, vector는 rollout. **2-PR**: PR-A=vmagent 버퍼+vector 노출+relay(메트릭 머지 전 검증 가능), PR-B=VectorBackpressure 알림(노출 deploy+라이브 관측 후, Pass1 F2).

**Tech Stack:** VictoriaMetrics vmagent/vmalert v1.103, Vector 0.41(internal_metrics), Alertmanager, bats(grep 구조 검증), docker(vector validate). 룰=PromQL.

**설계 출처:** `docs/plans/2026-06-20-observability-degradation-signals-design.md`(커밋 `e842a21`+정정 `ab5755d`). D1=vmagent alert+maxDiskUsagePerURL, D2=vector 알림 PR-B 분리(F2)·vector validate gate 필수(F1).

---

## 작업 전 공통 규칙 (모든 Task)

- **★부재 메트릭 알림 = 죽은 알림**(인시던트 #13/#14). 신규 알림의 메트릭이 **실제 TSDB에 존재**하는지 라이브 확인(아래 Task 5). 기존 메트릭(vmagent 버퍼·AM webhook)은 머지 전, vector는 노출 deploy 후.
- **라이브 질의**(observability 스킬): distroless(vmsingle/VL)는 셸 없음 → `kubectl -n observability exec deploy/vmagent -- wget -qO- 'http://vmsingle:8428/api/v1/query?query=<...>'` 또는 `... vmagent:8429/metrics | grep <metric>`. `eval "$(make kubeconfig)"`.
- **bats `@test` 이름 영어**·중간 단언 `[ ]`·grep 단순명령. 룰 grep은 expr 형태(메트릭 접미사)로 — 주석 언급 허용(core.yaml 선례).
- **룰은 `infra` group**(core.yaml의 기존 self-monitoring 룰 옆)에 가산. warning 티어.
- **커밋**: 한국어 conventional, AI 마커 금지. type=feat/fix/refactor/docs/style/test/chore. (알림/노출 추가=`feat:`, maxDiskUsage 하드닝=`fix:`/`feat:`.)
- **렌더 검증**: `make render COMP=victoria-stack`(`SOPS_AGE_KEY_FILE` 설정 후) 또는 `make chart-test`로 kustomize YAML 유효 확인.

---

## Task 1: vmagent 버퍼 — maxDiskUsagePerURL + VmagentBufferFilling

큐가 emptyDir 512Mi까지 차 eviction+전량유실하던 것을 graceful drop으로 + 채워짐 leading 경고.

**Files:**
- Modify: `platform/victoria-stack/prod/vmagent.yaml:40-49` (args)
- Modify: `platform/victoria-stack/prod/rules/core.yaml` (infra group에 룰 가산)
- Modify: `tests/gates/test_vmalert-config.bats` (self-monitoring 테스트 확장)

**Step 1: 실패 테스트 작성** — `test_vmalert-config.bats`의 self-monitoring @test(L82~)에 추가하거나 신규 @test:
```bash
@test "vmagent buffer saturation has a leading warning + graceful drop cap" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  V="$ROOT/platform/victoria-stack/prod/vmagent.yaml"
  grep -q 'alert: VmagentBufferFilling' "$C"                      # leading 경고(드롭 전)
  grep -qE 'vmagent_remotewrite_pending_data_bytes|vm_persistentqueue_bytes_pending' "$C"  # 버퍼 메트릭(실재명 Step3서 확정)
  grep -q 'maxDiskUsagePerURL' "$V"                               # eviction 대신 graceful drop
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_vmalert-config.bats` → FAIL.

**Step 3: 메트릭 실재 확인(라이브) + vmagent arg** — `vmagent.yaml` args에 추가:
```yaml
            - --remoteWrite.maxDiskUsagePerURL=450MiB   # 512Mi emptyDir 미만 — 큐가 차면 oldest drop(eviction+전량유실 회피)
```
> ★**라이브로 버퍼 메트릭 정확명 확인**(부재 메트릭 알림 금지): `kubectl -n observability exec deploy/vmagent -- wget -qO- localhost:8429/metrics | grep -E 'pending_data_bytes|persistentqueue.*pending'`. v1.103의 실제 명(`vmagent_remotewrite_pending_data_bytes` 유력)으로 룰 expr 고정.

**Step 4: VmagentBufferFilling 룰** — `core.yaml` infra group, VmagentRemoteWriteDropping 근처. ★**커버리지 경계 주석 필수**(self-defeating 한계 — AlertmanagerTelegramFailing 선례, F5):
```yaml
          # vmagent 버퍼 채워짐(leading) — vmsingle이 **느림/backpressure**(write가 천천히 통과)일 때 큐가
          # maxDiskUsagePerURL 캡에 근접. 드롭 전 조기 경고(드롭은 VmagentRemoteWriteDropping = 2티어).
          # ⚠️ 커버리지 경계(F5): 이 메트릭(vmagent self-metric)도 remoteWrite로 vmsingle에 들어가 vmalert가
          #    질의한다 — vmsingle **write가 전면 실패**하면 pending 메트릭도 vmagent 큐에 갇혀 vmsingle에 못 도달,
          #    이 알림은 그 케이스엔 침묵한다(vmsingle 전면다운 = TargetDown{job~vmsingle}+deadman이 커버).
          #    즉 "vmsingle 느림/부분열화"에 leading하고 "write 전면다운"엔 무력(의도적 경계). emptyDir라 재시작 시 큐 휘발.
          - alert: VmagentBufferFilling
            expr: sum(vmagent_remotewrite_pending_data_bytes) > 330000000   # ≈315Mi(450Mi 캡의 70%) — Step3 메트릭명 확정 후
            for: 10m
            labels: { severity: warning }
            annotations:
              summary: "vmagent remoteWrite 버퍼 채워짐(vmsingle 느림/backpressure — 드롭 임박)"
              description: "vmagent 디스크 큐가 maxDiskUsagePerURL 캡에 근접 — vmsingle write가 느려져(backpressure) 적체 중. 곧 oldest drop(VmagentRemoteWriteDropping)으로 메트릭 유실. vmsingle 부하/디스크를 확인하세요. ⚠️ vmsingle write 전면다운 시엔 이 메트릭도 버퍼에 갇혀 미발화(그 케이스는 TargetDown(vmsingle)+deadman) — 이 알림은 부분열화(느림)용입니다. emptyDir 버퍼라 vmagent 재시작 시 큐 휘발."
```

**Step 5: 통과 확인** — `bats tests/gates/test_vmalert-config.bats` PASS + `make render COMP=victoria-stack`(또는 chart-test) 렌더 성공.

**Step 6: 커밋**
```bash
git add platform/victoria-stack/prod/vmagent.yaml platform/victoria-stack/prod/rules/core.yaml tests/gates/test_vmalert-config.bats
git commit -m "feat: vmagent 버퍼 leading 경고 + maxDiskUsagePerURL graceful drop

- 큐가 emptyDir 512Mi까지 차 eviction+전량유실하던 것을 450MiB 캡 oldest drop으로
- VmagentBufferFilling(warning): 드롭 전 leading 신호(기존 드롭 알림과 2티어)"
```

---

## Task 2: vector 메트릭 노출 (internal_metrics → prometheus_exporter → scrape)

vector backpressure가 불가시였던 근본 — 메트릭 자체가 scrape 안 됨. 노출 + scrape annotation.

**Files:**
- Modify: `platform/victoria-stack/prod/vector.yaml` (ConfigMap config + DaemonSet port/annotation)
- Create: `tests/gates/vector-validate.sh` (컨테이너 vector validate, F1)
- Modify: `.github/workflows/ci.yaml` (gate에 vector-validate 배선)
- Test: `tests/gates/test_vector-metrics.bats` (신규)

**Step 1: 실패 테스트 작성** — **yq 경로 단언**(grep은 annotation 위치 무관 통과 → DaemonSet object에 둬도 false-pass, F4). 멀티독 vector.yaml에서 DaemonSet/ConfigMap select:
```bash
#!/usr/bin/env bats
# vector 메트릭 노출 — internal_metrics→prometheus_exporter→scrape. ★annotation은 POD TEMPLATE(F4). ⚠️ 중간 단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; V="$ROOT/platform/victoria-stack/prod/vector.yaml"
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
}

@test "vector config exposes internal_metrics source + prometheus_exporter sink" {
  run yq -e 'select(.kind=="ConfigMap" and .metadata.name=="vector-config") | .data."vector.yaml"' "$V"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'type: internal_metrics'
  printf '%s' "$output" | grep -q 'type: prometheus_exporter'
}

@test "scrape annotation is on the POD TEMPLATE (.spec.template.metadata), NOT the DaemonSet object (F4)" {
  D='select(.kind=="DaemonSet" and .metadata.name=="vector")'
  run yq -e "$D | .spec.template.metadata.annotations.\"prometheus.io/scrape\" == \"true\"" "$V"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  run yq -e "$D | .spec.template.metadata.annotations.\"prometheus.io/port\" == \"9598\"" "$V"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  # DaemonSet object .metadata에 scrape가 가면 안 됨(잘못된 위치 회귀 차단)
  run yq -e "$D | .metadata.annotations.\"prometheus.io/scrape\"" "$V"
  [ "$status" -ne 0 ]
}

@test "vector container exposes the 9598 metrics port" {
  run yq -e 'select(.kind=="DaemonSet" and .metadata.name=="vector") | .spec.template.spec.containers[] | select(.name=="vector").ports[] | select(.containerPort==9598)' "$V"
  [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** — `bats tests/gates/test_vector-metrics.bats` → FAIL.

**Step 3: vector config에 메트릭 노출** — `vector.yaml` ConfigMap의 `vector.yaml` 블록:
```yaml
    sources:
      k8s:
        type: kubernetes_logs
      internal:                       # 추가: vector 자기 메트릭
        type: internal_metrics
    # transforms.parse 유지 ...
    sinks:
      # vlogs 유지 ...
      prometheus:                     # 추가: /metrics:9598 노출
        type: prometheus_exporter
        inputs: [internal]
        address: "0.0.0.0:9598"
```

**Step 4: DaemonSet 포트 + annotation** — ★**annotation은 POD TEMPLATE**(`.spec.template.metadata.annotations`)에 — DaemonSet object `.metadata`가 아니다(vmagent는 **pod** annotation을 discovery, F4). vector DaemonSet `spec.template`:
```yaml
spec:
  # selector 유지 ...
  template:
    metadata:
      labels: { app.kubernetes.io/name: vector }
      annotations:                    # 추가 — 여기(.spec.template.metadata)가 POD 레벨
        prometheus.io/scrape: "true"
        prometheus.io/port: "9598"
    spec:
      # serviceAccountName/securityContext(runAsUser:0) 유지 ...
      containers:
        - name: vector
          ports: [{ name: metrics, containerPort: 9598 }]   # 추가
```
> ★`.spec.template.metadata`(POD)와 DaemonSet `.metadata`(object) 혼동 금지 — object에 두면 pod가 annotation을 안 받아 vmagent 미scrape(메트릭 0). ★`readOnlyRootFilesystem: true`·`drop: ["ALL"]`는 9598 리슨에 무관(추가 권한 불요). prometheus_exporter는 메모리 내 — emptyDir 불요.

**Step 5: vector config 컨테이너 validate gate 필수 (F1)** — render는 vector 의미오류를 못 잡으므로 **배포 버전으로 `vector validate`**(alertmanager-render-e2e 선례 — containerized 게이트):
- `tests/gates/vector-validate.sh`(신규):
  ```bash
  #!/usr/bin/env bash
  # vector config semantic 검증(컨테이너, 배포 버전) — kustomize render는 vector 의미오류 미차단. set -e.
  set -euo pipefail
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  VEC="$ROOT/platform/victoria-stack/prod/vector.yaml"
  VER="$(grep -oE 'timberio/vector:[0-9.]+' "$VEC" | head -1 | cut -d: -f2)"   # DaemonSet 이미지 버전과 동일(드리프트 0)
  [ -n "$VER" ] || { echo "vector 버전 추출 실패"; exit 1; }
  TMP="$(mktemp -d)"
  yq 'select(.kind=="ConfigMap" and .metadata.name=="vector-config") | .data."vector.yaml"' "$VEC" > "$TMP/vector.yaml"
  [ -s "$TMP/vector.yaml" ] || { echo "vector config 추출 실패"; exit 1; }
  docker run --rm -v "$TMP/vector.yaml:/etc/vector/vector.yaml:ro" \
    "timberio/vector:${VER}-distroless-libc" validate --no-environment /etc/vector/vector.yaml
  ```
  > 이미지 entrypoint가 `vector`라 `validate` subcommand 실행(distroless 셸 불요). 러너 arm64 — vector 멀티아치 이미지.
- ci.yaml `gate` 잡에 스텝 추가(alertmanager-render-e2e 근처): `- run: bash tests/gates/vector-validate.sh`.
- `tests/gates/test_vector-metrics.bats`에 게이트 배선 단언:
  ```bash
  @test "vector config validation runs in the required gate (containerized vector validate)" {
    [ -x "$ROOT/tests/gates/vector-validate.sh" ]
    run grep -F 'vector-validate.sh' "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
    run awk '/^  gate:/{g=1} /^  [a-z]/ && !/^  gate:/{g=0} g && /vector-validate/{print}' "$ROOT/.github/workflows/ci.yaml"; [ -n "$output" ]
  }
  ```

**Step 6: 통과 확인** — `bats tests/gates/test_vector-metrics.bats` PASS + `make render COMP=victoria-stack` 렌더 성공 + `bash tests/gates/vector-validate.sh`(docker — 로컬/CI) **exit 0 필수**.

**Step 7: 커밋**
```bash
git add platform/victoria-stack/prod/vector.yaml tests/gates/test_vector-metrics.bats \
        tests/gates/vector-validate.sh .github/workflows/ci.yaml
git commit -m "feat: vector 자기 메트릭 노출 + 컨테이너 vector validate 게이트

- internal_metrics→prometheus_exporter:9598→scrape (backpressure 불가시 근본 해소)
- vector config 의미검증을 required gate에(render 미차단, alertmanager-render-e2e 선례)"
```

---

## Task 3 — [PR-B · 별도 후속 · PR-A 미실행]: VectorBackpressure 경고

> ★★**이 Task는 PR-B**(별도 후속). **executing-plans는 PR-A(Task 1·2·4·5)만 실행하고 이 Task는 건너뛴다.** PR-A 배포 후 vector 메트릭이 라이브에 흐르면, **실제 backpressure 메트릭/동작(block 버퍼면 discarded=0)을 관측해 expr을 확정한 뒤** 추가한다. 노출 deploy 전엔 vector 메트릭 부재 → 단일 PR서 알림 검증 불가 → 죽은 알림(#13/#14) 방지(Pass1 F2 escalation, 2-PR 하드닝).

vector 부분드롭/정체 — LogIngestionStalled(full-stop)가 못 잡는 것.

**Files:**
- Modify: `platform/victoria-stack/prod/rules/core.yaml`
- Modify: `tests/gates/test_vmalert-config.bats`

**Step 1: 실패 테스트 작성**:
```bash
@test "vector backpressure/partial-drop has a warning (beyond full-stop LogIngestionStalled)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: VectorBackpressure' "$C"
  grep -qE 'vector_component_discarded_events_total|vector_buffer_|vector_component_errors_total' "$C"  # 노출 후 실재명 확정
}
```

**Step 2: 실패 확인** — FAIL.

**Step 3: 룰 추가** — `core.yaml` infra group(LogIngestionStalled 근처). ★**메트릭은 Task 2 노출 deploy 후 라이브 확인**(vector 버퍼 동작이 block이면 discarded=0 — 그땐 buffer 충전율로):
```yaml
          # vector 부분드롭/정체(backpressure) — LogIngestionStalled은 full-stop(vl 0행)만 잡는다.
          # ★메트릭은 vector 노출(internal_metrics) 후 라이브 확인 — block 버퍼면 discarded=0이라 buffer 충전율로 전환.
          - alert: VectorBackpressure
            expr: increase(vector_component_discarded_events_total[15m]) > 0
            for: 15m
            labels: { severity: warning }
            annotations:
              summary: "Vector 이벤트 드롭/backpressure"
              description: "vector가 이벤트를 드롭하거나 sink(VictoriaLogs) 정체로 backpressure 중 — 부분 로그 유실 가능. LogIngestionStalled(전면 정지)가 아닌 부분열화입니다. VL/vector 버퍼를 확인하세요."
```

**Step 4: 통과 확인** — `bats tests/gates/test_vmalert-config.bats` PASS + 렌더 성공.

**Step 5: 커밋**
```bash
git add platform/victoria-stack/prod/rules/core.yaml tests/gates/test_vmalert-config.bats
git commit -m "feat: VectorBackpressure 경고(부분드롭 — LogIngestionStalled가 못 잡는 부분열화)"
```

---

## Task 4: DeadmanswitchRelayUnreachable in-band 경고 (core.yaml)

relay 단독다운을 off-node deadman 윈도 전에 in-band로 — AM webhook 전송실패 메트릭.

**Files:**
- Modify: `platform/victoria-stack/prod/rules/core.yaml`
- Modify: `tests/gates/test_vmalert-config.bats`

**Step 1: 실패 테스트 작성**:
```bash
@test "relay single-down has an in-band signal via AM webhook failure (faster than off-node deadman)" {
  C="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  grep -q 'alert: DeadmanswitchRelayUnreachable' "$C"
  grep -q 'alertmanager_notifications_failed_total{integration="webhook"}' "$C"
}
```

**Step 2: 실패 확인** — FAIL.

**Step 3: 룰 추가** — `core.yaml` infra group(AlertmanagerTelegramFailing 근처):
```yaml
          # deadmanswitch-relay 단독다운 in-band — relay는 busybox nc라 /metrics 없음·미scrape이나,
          # AM이 Watchdog를 relay:9095/ping webhook으로 보내므로 relay 다운 시 AM webhook 전송이 실패한다.
          # AM은 up이라 이 알림을 Telegram으로 전달 가능 — off-node deadman(healthchecks.io) 윈도보다 빠르다.
          - alert: DeadmanswitchRelayUnreachable
            expr: increase(alertmanager_notifications_failed_total{integration="webhook"}[15m]) > 0
            for: 5m
            labels: { severity: warning }
            annotations:
              summary: "deadmanswitch-relay 도달 불가(AM webhook 전송 실패)"
              description: "Alertmanager가 deadmanswitch-relay(:9095/ping) webhook 전송에 실패합니다 — relay 다운/네트워크 가능. off-node deadman이 페이징하기 전 in-band 조기 신호입니다(relay가 healthchecks.io ping을 못 보내면 곧 off-node도 발화)."
```

**Step 4: 통과 확인** — `bats tests/gates/test_vmalert-config.bats` PASS + 렌더 성공. + ★**라이브 메트릭 실재 확인**(AM 이미 scrape): `kubectl -n observability exec deploy/vmagent -- wget -qO- 'http://vmsingle:8428/api/v1/query?query=alertmanager_notifications_failed_total'` — `integration="webhook"` 시리즈 존재 확인.

**Step 5: 커밋**
```bash
git add platform/victoria-stack/prod/rules/core.yaml tests/gates/test_vmalert-config.bats
git commit -m "feat: DeadmanswitchRelayUnreachable in-band 경고(AM webhook 전송실패=relay 다운)"
```

---

## Task 5: 전체 검증 + 라이브 메트릭 실재 확인

**Files:** 없음(검증만 — 라이브 검증은 머지 전/후 owner)

**Step 1: 룰/렌더 게이트** — `bats tests/gates/test_vmalert-config.bats tests/gates/test_vector-metrics.bats` 0 failures + `make render COMP=victoria-stack`(SOPS_AGE_KEY_FILE) 렌더 성공 + `make chart-test`(공유차트 무관하나 게이트 패리티).

**Step 2: 메트릭 실재 검증 — 하드 블로커 (★부재 메트릭=죽은 알림 #13/#14, Pass2 F3)** — `eval "$(make kubeconfig)"` 후. **vmalert는 vmsingle(TSDB)를 질의하므로 검증도 vmsingle로**(vmagent /metrics 노출 ≠ TSDB 질의가능 — scrape 단절 시 vmagent는 노출해도 vmalert는 못 본다). `|| echo` 회피 금지 — 시리즈 부재면 **STOP·룰 수정·머지 금지**:
```bash
q() { kubectl -n observability exec deploy/vmagent -- wget -qO- "http://vmsingle:8428/api/v1/query?query=$1"; }
# (Task 1 Step3에서 vmagent:8429/metrics로 '정확한 메트릭명'을 먼저 확정 → 그 명으로 vmsingle 질의)
# 1) vmagent 버퍼 시리즈가 vmsingle에 질의되는지(빈 result 아님) 하드 확인 — 단 이는 healthy/slow 질의가능 증명일 뿐,
#    vmsingle write 전면다운 시 미발화는 의도적 경계(룰 주석·TargetDown(vmsingle)+deadman 커버, F5):
q 'vmagent_remotewrite_pending_data_bytes' | grep -q '"result":\[{' \
  || { echo "STOP: vmagent 버퍼 시리즈가 vmsingle에 없음 — Task1 메트릭명/scrape 점검, 룰 수정 전 머지 금지"; exit 1; }
# 2) AM webhook 실패 카운터(deadmanswitch receiver 설정 시 0으로 초기화돼 존재해야) — 정확 라벨까지:
q 'alertmanager_notifications_failed_total{integration="webhook"}' | grep -q '"result":\[{' \
  || { echo "STOP: alertmanager_notifications_failed_total{integration=\"webhook\"} 부재 — 라벨 상이(receiver명)이거나 AM 미전송. Task4 expr를 실제 라벨로 수정하거나 controlled relay-failure로 시리즈 생성 후 재확인. 머지 금지"; exit 1; }
```
- **PR-A 머지 후(노출 증명 — 하드, F4)**: vector exposure가 실제 작동하는지 — **항상-존재 vector 내부 메트릭이 vmsingle에 질의되는지**(annotation pod-template 위치·9598·scrape 성립 증명):
  ```bash
  q 'vector_uptime_seconds' | grep -q '"result":\[{' \
    || { echo "STOP: vector 메트릭이 vmsingle에 없음 — annotation이 pod template(.spec.template.metadata)인지·9598 포트·vmagent scrape 점검. PR-B 진행 금지"; exit 1; }
  ```
  (`vector_uptime_seconds`는 backpressure 무관 항상 존재 — scrape 성립만 증명. 실제명은 노출 후 `q`로 확인.)
- **PR-B 준비(backpressure 메트릭 확정)**: 노출 증명 후 같은 `q`로 backpressure 메트릭 **실재+동작** 확정 → Task 3 expr 고정(block 버퍼면 discarded=0 → `vector_buffer_byte_size`/`vector_buffer_max_byte_size` 충전율로). **vmsingle에서 질의 안 되면 알림 추가 금지**.

**Step 3: vmalert 룰 로드 확인(머지 후)** — `kubectl -n observability exec deploy/vmalert -- wget -qO- localhost:8880/api/v1/rules | grep -E 'VmagentBufferFilling|DeadmanswitchRelayUnreachable'` — **PR-A 2 룰** 로드 + VmalertUnhealthy 미발화(expr 오류 없음). (VectorBackpressure는 PR-B.)

**Step 4: PR 준비** — `git log --oneline origin/main..HEAD` 요약. ★**라이브 변경**(victoria-stack 싱크) — 머지 후 ArgoCD 싱크 + vmalert reload·vector rollout 관찰. 알림 오발화/룰 에러 모니터(VmalertUnhealthy). PR/머지 owner.

---

## 실행 순서 메모

- **PR-A 실행 순서: Task 1(vmagent) → 2(vector 노출+validate) → 4(relay) → 5(검증)**. **Task 3(VectorBackpressure)은 PR-B** — executing-plans는 PR-A만 실행하고 Task 3은 건너뛴다(Pass1 F2: 노출 deploy+라이브 관측 후 별도 PR). PR-A 메트릭(vmagent 버퍼·AM webhook)은 머지 전 검증 가능.
- **★라이브(victoria-stack ArgoCD 싱크)** — 룰 expr 오류는 VmalertUnhealthy, vector config 오류는 LogIngestionStalled가 백스톱. **부재 메트릭 알림(죽은 알림) 방지가 핵심** — Task 5 메트릭 실재 검증 필수.
- vector 알림 메트릭은 노출 deploy 후에야 확인 가능 — 표준명으로 작성하되 머지 후 라이브 검증으로 확정(block 버퍼면 buffer 충전율로 전환).

---

## Adversarial review dispositions

hardened-planning 4-pass codex 적대 리뷰. **5발견(F1~F5) 전부 Accept·반영**. 각 게이트 AskUserQuestion 승인. Pass 3에서 nominal cap(3) 도달, 사용자 승인으로 Pass 4 1회 추가, Pass 4 후 **확정**(Pass 5 미실행). **F2는 사용자 승인 설계 변경**(단일 PR→2-PR: vector 알림 PR-B 분리).

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1 | vector config 검증 optional → 라이브 롤아웃 전 semantic 오류 미차단 | high | **Accepted** — 컨테이너 `vector validate` mandatory gate(alertmanager-render-e2e 선례) |
| 1 | F2 | VectorBackpressure를 메트릭 증명 전 같은 PR에 → 죽은 알림(자기모순) | high | **Accepted(설계 escalation)** — vector 알림을 PR-B로 분리(노출 deploy+관측 후), PR-A=vmagent+노출+relay |
| 2 | F3 | 메트릭 실재 검증이 vmagent /metrics(TSDB 아님)+webhook non-blocking → 죽은 알림 머지 가능 | high | **Accepted** — vmsingle(TSDB) 질의 + 하드 블로커(exit 1)·STOP |
| 3 | F4 | vector scrape annotation이 pod-template 아닌 object에 갈 수 있음(grep 위치무관) | high | **Accepted** — `.spec.template.metadata.annotations` 명시 + yq 경로 단언 + PR-A 노출 증명(vmsingle vector-metric) |
| 4 | F5 | VmagentBufferFilling이 vmsingle write-outage 시 자기 메트릭도 버퍼에 갇혀 침묵(self-defeating) | high | **Accepted(경계 문서화)** — slow/backpressure엔 leading 유효(테마 부분열화), write-전면다운 경계는 룰 주석+TargetDown+deadman(AlertmanagerTelegramFailing 선례) |

**최종 패스(4) verdict:** `needs-attention`(F5) — 반영. 사용자 합의로 Pass 4에서 확정. ★★핵심 교훈: **관측 자기관측은 self-reference 함정 투성이** — ①가드/알림이 자기가 감시하는 경로(remoteWrite·TSDB)를 통과하면 그 경로 장애 시 침묵(F5 vmagent 버퍼·기존 Watchdog/AM 선례) → **커버리지 경계 명시** ②메트릭 검증은 **vmalert가 질의하는 vmsingle(TSDB)에서**(노출≠질의가능, F3) ③노출 미증명 알림=죽은 알림 → 노출 deploy+관측 후 알림(2-PR, F2) ④annotation은 pod-template 정확 경로(F4). executing-plans의 `make ci`(test_vmalert-config·vector-validate·렌더) + Task5 라이브 하드체크가 잔여 포착.

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+observability-degradation-signals`).
- **Run continuously:** 라우틴 리뷰로 멈추지 말 것. 진짜 블로커에서만 정지. **PR-A 실행: Task 1 → 2 → 4 → 5.** ★**Task 3(VectorBackpressure)은 PR-B — 실행하지 않는다**(PR-A 배포+vector 메트릭 라이브 관측 후 별도 PR, F2).
- **★라이브(victoria-stack ArgoCD 싱크)** — 머지=라이브 반영. **부재 메트릭=죽은 알림(#13/#14) 방지**: Task 5 vmsingle 하드 메트릭 검증이 핵심(STOP 조건 준수, exit 1면 머지 금지). vector config는 컨테이너 `vector validate` 게이트 필수.
- **Commits — 직접 적용; `Skill(commit)` 미사용**:
  - **한국어**·**AI 마커 금지**. Format `<type>(<scope>): 한국어 설명`. Type만 `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. (알림/노출=`feat:`, maxDiskUsage=`fix:`/`feat:`.) Task별 자체 커밋.
  - **Where:** 현재 feature 워크트리(`worktree-feat+observability-degradation-signals`) 직접 커밋.
- **Push/PR:** owner 판단. ★라이브 변경이라 **머지 전 Task 5 라이브 메트릭 검증**(기존 메트릭=vmsingle 하드체크) + 머지 후 ArgoCD 싱크·vmalert reload·vector rollout 관찰(VmalertUnhealthy 모니터). PR-B는 PR-A 배포+관측 후 별도.
