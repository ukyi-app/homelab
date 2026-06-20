# 테마6 설계: 관측성 부분열화 신호

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+observability-degradation-signals` (브랜치 `worktree-feat+observability-degradation-signals`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마6 ("관측성 부분열화 신호", 중/저·M)

## 1. 배경 / 문제

관측 스택(victoria-stack)이 **전면 장애는 잡지만 부분열화(degradation)는 조용히 진행**하는 신호 갭 3개. 전부 라이브 grounding:

| # | 발견 | 라이브 근거 |
|---|---|---|
| 1 | vmagent remoteWrite 버퍼(`/tmpdata` emptyDir **512Mi**, **`--remoteWrite.maxDiskUsagePerURL` 미설정**) 포화·휘발 무감시 — vmsingle 도달불가 시 큐가 512Mi까지 차 **kubelet이 pod evict→버퍼(emptyDir) 전량 유실**. 기존 `VmagentRemoteWriteDropping`은 `packets_dropped/errors` **증가 후**(too-late)에만 | `vmagent.yaml:40-49,66`(args에 maxDiskUsage 없음)·`core.yaml` VmagentRemoteWriteDropping |
| 2 | Vector backpressure 부분드롭 불가시 — **vector 미scrape**(`prometheus.io/scrape` annotation 0, 포트 미노출). `LogIngestionStalled`은 full-stop(`vl_rows_ingested_total==0`)만 잡고, 부분 드롭(buffer fill·sink 정체)은 안 잡힘 | `vector.yaml`(annotation·port 0)·`core.yaml` LogIngestionStalled |
| 3 | relay 단독다운 in-band 신호 부재 — `deadmanswitch-relay`는 busybox nc라 `/metrics` 없음·미scrape. `TargetDown`(up==0)이 relay 미커버 → 다운 시 **off-node deadman(healthchecks.io) 윈도 뒤에야** 인지 | relay annotation 0·AM `deadmanswitch` receiver `webhook: http://deadmanswitch-relay:9095/ping`(alertmanager.yaml:77-79) |

(AM 단독다운은 AM이 자기 전달 경로라 in-band 불가 — off-node deadman만이 근본. relay는 AM이 up이라 in-band 가능.)

## 2. 목표 / 비목표

### 목표
- vmagent 버퍼 포화의 **leading 경고**(eviction 전) + **eviction→전량유실을 graceful drop으로**(maxDiskUsagePerURL).
- **vector 메트릭 노출**(internal_metrics→prometheus_exporter→scrape) + backpressure/부분드롭 **경고**.
- relay 단독다운의 **in-band 신호**(AM webhook 전송실패 메트릭, off-node보다 빠름).
- 전부 **warning 티어**(critical paging 아님 — 부분열화는 조기 경고가 목적).

### 비목표
- AM 단독다운 in-band(근본 불가 — off-node deadman이 SSOT) — 작업 없음.
- emptyDir→PVC 전환(휘발 근본제거)은 범위 밖 — maxDiskUsagePerURL로 eviction만 막고 휘발은 설계 수용(단일운영자 홈랩, 메트릭은 재시작 후 재수집).
- vector 로그 파이프라인 로직 변경(소스/sink) — 메트릭 노출만 가산.
- 알림 라우팅/AM 변경 — core.yaml 룰 + vector 노출만.

## 3. 설계: 3 신호 (core.yaml warning 티어 + vector 노출)

### 수정 1 — vmagent 버퍼: leading 경고 + graceful drop (D1)
- `vmagent.yaml` args에 **`--remoteWrite.maxDiskUsagePerURL=<512Mi 미만, 예 450MiB>`** 추가 → 큐가 그 캡 도달 시 oldest drop(기존 `VmagentRemoteWriteDropping`이 신호), **emptyDir 512Mi eviction+전량유실 회피**.
- `core.yaml`에 **`VmagentBufferFilling`**(warning) — vmagent 버퍼 메트릭이 캡의 일정 비율(예 70%) 초과 지속 시. ★메트릭명은 **라이브 vmagent:8429/metrics로 정확 확인**(후보 `vmagent_remotewrite_pending_data_bytes` 또는 `vm_persistentqueue_bytes_pending` — 버전별 상이, 부재 메트릭 알림은 죽은 알림[인시던트 #13/#14]).
- 2티어: `VmagentBufferFilling`(leading, 채워짐) + 기존 `VmagentRemoteWriteDropping`(실제 드롭).

### 수정 2 — vector 메트릭 노출 + backpressure 경고
- `vector.yaml` ConfigMap config에 `sources.internal: { type: internal_metrics }` + `sinks.prometheus: { type: prometheus_exporter, inputs: [internal], address: "0.0.0.0:9598" }`.
- DaemonSet: `ports: [{ name: metrics, containerPort: 9598 }]` + pod template annotation `prometheus.io/scrape: "true"`, `prometheus.io/port: "9598"`(vmagent pod-annotations job이 scrape).
- **`VectorBackpressure`**(warning) — vector 부분드롭/정체 신호. ★vector 0.41 internal_metrics가 실제 emit하는 backpressure 메트릭(`vector_component_discarded_events_total`(드롭)/`vector_buffer_byte_size`÷`vector_buffer_max_byte_size`(충전율)/`vector_component_errors_total`(sink 에러)) 중 버퍼 동작(block vs drop)에 맞는 것을 **노출 deploy 후 라이브 확인**. ★**노출은 deploy 후에야 메트릭 존재** → **이 알림은 별도 후속 PR(PR-B)**: 이 PR(PR-A)은 노출만, 배포·라이브 관측으로 실측 메트릭 확정 후 PR-B에서 알림 추가(부재 메트릭 알림=죽은 알림 방지, Pass1 F2 escalation).
- vector config는 **컨테이너 `vector validate` 필수 gate**(render는 vector 의미오류 미차단, Pass1 F1).

### 수정 3 — relay in-band: AM webhook 전송실패 경고
- `core.yaml`에 **`DeadmanswitchRelayUnreachable`**(warning) — `increase(alertmanager_notifications_failed_total{integration="webhook"}[15m]) > 0`. AM(up)이 relay `:9095/ping` webhook 전송에 실패 = relay 다운/도달불가. AM→Telegram으로 전달 가능(off-node 윈도보다 빠름). AM은 이미 scrape(9093)라 메트릭 실재.

## 4. 라이브 위험 — **있음** (victoria-stack ArgoCD 싱크)

- core.yaml 룰 변경 → vmalert가 `configCheckInterval`로 reload(기존 가드). vector.yaml 변경 → DaemonSet rollout(config reload).
- **위험**: ①룰 expr 오류(PromQL 타이포) → vmalert load 실패 → 기존 `VmalertUnhealthy`가 라이브 백스톱. ②**부재 메트릭 알림**(메트릭명 오류) → 조용히 무력(인시던트 #13/#14 클래스) — **메트릭 실재 검증이 핵심**. ③vector config 오류 → vector 시작 실패 → 로그 수집 중단 → 기존 `LogIngestionStalled`가 백스톱(단 로그 유실). ④warning 티어라 오발화는 저해(critical paging 아님).
- **검증**: (a) `tests/gates/test_vmalert-config.bats` 구조 검증(alert명·metric·fail-closed) 확장 · (b) `make chart-test`/`make render COMP=victoria-stack` 렌더(YAML·kustomize) · (c) **메트릭 실재 라이브 검증**(observability 스킬: `kubectl -n observability exec deploy/vmagent -- wget -qO- vmagent:8429/metrics | grep <metric>` — 기존 메트릭은 머지 전, vector는 노출 deploy 후) · (d) **vector config 컨테이너 `vector validate` 필수 gate**(배포 버전 0.41.1, `alertmanager-render-e2e` 선례 — render는 vector 의미오류 미차단, Pass1 F1).

## 5. 핵심 함정 (재발 주의)

- **부재 메트릭 알림 = 죽은 알림**(인시던트 #13/#14, test_vmalert-config가 deprecated cnpg 메트릭 재도입 금지로 강제). 신규 알림 3종의 메트릭이 **실제 TSDB에 존재**하는지 라이브 확인 필수.
- vector internal_metrics 노출은 deploy 후에야 메트릭 존재 — 알림 expr이 표준명을 써도 **라벨/동작은 노출 후 확인**(block 버퍼면 discarded=0일 수 있음 → buffer 충전율로).
- distroless 질의 함정: vmsingle/VL은 셸 없음 → vmagent/vmalert 파드에서 service DNS로 질의(observability 스킬).
- bats grep 검증은 expr 형태(메트릭 접미사)로 — 주석 언급은 허용(core.yaml 선례).

## 6. 결정사항

- **D1 (vmagent finding 스코프)** → **alert + `--remoteWrite.maxDiskUsagePerURL` 하드닝**(사용자 결정 2026-06-20). leading 경고 알림 + maxDiskUsagePerURL로 eviction+전량유실 대신 graceful drop. 둘 다 가산.
- **D2 (vector 알림 PR 구조, Pass1 F2 escalation)** → **2-PR 분리**: PR-A=vmagent 버퍼 + vector 메트릭 노출 + relay in-band(전부 머지 전 메트릭 검증 가능). PR-B=VectorBackpressure 알림(PR-A 배포+라이브 관측으로 실측 메트릭 확정 후). 노출 deploy 전엔 vector 메트릭 부재라 단일 PR서 알림 검증 불가 → 죽은 알림 방지(2-PR 하드닝 패턴, homepage 선례). 최초 단일PR 승인 → Pass1 F2로 정정.
- **A.5 생략**(사용자 결정) — 룰 expr/메트릭은 Phase C + 라이브 검증이 안전망.

## 7. 범위 밖 (명시)

- AM 단독다운 in-band(근본 불가) · emptyDir→PVC(휘발 근본제거) · vector 로그 로직 · AM 라우팅.
- 새 critical paging 알림(부분열화는 warning 티어).
