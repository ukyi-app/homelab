# 설계: 홈랩 자원·게이트·문서 하드닝 (단일 PR)

작성일: 2026-06-22
근거: 2026-06-22 13차원 적대적 심층 감사(51개 에이전트, 37개 발견 confirmed/partial,
0 refuted) + 완전성 비평. 라이브 18/18 Synced·Healthy 상태에서 발견된 시스템적 갭을,
**인-레포 앱 0개 윈도우(비용 0)**가 닫히기 전에 수정한다.

## 목표

메모리 단일축 편향을 자원 축으로 일반화하고, false-green 게이트를 negative-path까지
강화하며, 문서↔라이브 드리프트를 정정한다. 가장 값진 발견은 13개 차원이 아니라
완전성 비평가가 잡은 **"CPU·비메모리 자원 고갈에 가드·원장·알림 전무"**(메모리 OOM
포스트모템 전체가 한 축에만 정렬)다.

## 확정된 설계 결정 (사용자 승인)

| 결정 | 선택 | 근거 |
|---|---|---|
| CPU 축 깊이 | 가드+스키마+알림 (**LimitRange 제외, CPU 원장 제외**) | CPU는 compressible(throttle, kill 아님) → hard budget 불필요. LimitRange는 단일노드 정당 burst 제약 |
| M1 NetworkPolicy | **A. 화이트리스트 + 앱 자체 netpol** | 문서된 설계 일치·최소 변경·단일 오너라 광범위 netpol 위험 낮음 |
| 차트 하드닝 | **C. 스키마 + conftest 렌더 검사** | conftest 이미 레포 사용 중(ledger.rego)·스키마는 빠른 피드백, conftest는 라이브 admission 패리티 |
| PR 구조 | **단일 PR 일괄** (한 feature 브랜치) | |

## 범위 밖 (YAGNI / 명시적 연기)

- `LimitRange`/`ResourceQuota`, **CPU 원장 컬럼** (위 결정)
- M1 옵션 B/C (차트 렌더·중앙 netpol — 멀티테넌시 생기면 이행)
- teardown-app ledger-totals SSOT 우회 정규식, teardown-resource ensure non-global
  `.replace`, app-config 스키마 이름 패턴 (코드 위생·잠복 — 별도 후속)
- homepage netpol vmsingle podSelector 비대칭, purge dangling-role gate화 (info — 별도 후속)

## 워크스트림

### W1 — 자원 축 가드 + 알림 (최우선 테마)

- **가드 rename+확장**: `scripts/check-memory-limits.sh` → `scripts/check-resource-limits.sh`.
  상주 워크로드(Deployment/DaemonSet/StatefulSet) main 컨테이너가 `limits.memory`
  **AND** `limits.cpu` 둘 다 보유(또는 allowlist)하도록 강제. 참조 동반 갱신:
  `Makefile`(verify 타겟·help 주석), `tests/test_memory_limits.bats` →
  `tests/test_resource_limits.bats`, `tests/.ci-exclude`/`scripts/run-bats.sh` 수집·
  `scripts/check-bats-accounting.sh` 도메인, traps 등재(W5).
  - 기존 15개 플랫폼 매니페스트는 이미 cpu limit 보유(critic 확인) → TDD로 선검증, red 시 보강.
- **scan 건수 floor**: `count >= N` 하한 추가 → grep 셀렉터 붕괴 시 0건 침묵통과(false-green)
  차단. positive bats가 `count>0`(또는 ≥ 하한)을 단언.
- **스키마**: `platform/charts/app/values.schema.json`의 `resources.limits.cpu`에 required +
  `minLength:1` (memory 패턴 대칭). `values.yaml` 기본 `cpu: ""` 검토.
- **노드 압박/eviction 알림**: `platform/victoria-stack/prod/rules/core.yaml`에
  `kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"}`
  + `kube_pod_status_reason="Evicted"` 알림 추가. **메트릭 존재를 라이브 vmagent 질의로 선확인**
  (kube-state-metrics scrape 확인).
- **알림 게이트 커버**: `tests/gates/test_vmalert-config.bats`에 신규 알림 + 기존 무커버 알림
  (ContainerMemoryNearLimit·PodOOMKilled·TargetDown·NodeMemoryHigh) grep 가드 추가
  (working_set vs max_usage 회귀 부정단언 포함).

### W2 — AppProject + PSA (admission 경계)

- **M1**: `platform/argocd/root/projects.yaml` apps `namespaceResourceWhitelist`에
  `{group: networking.k8s.io, kind: NetworkPolicy}` 추가 + `test_projects.bats` 동반 단언.
  (NetworkPolicy는 namespace-scoped·prod ns 한정이라 권한경계 안 넓힘.)
- **PSA 라벨**: `cnpg-system`·`cert-manager`에 **enforce=baseline + warn/audit=restricted**.
  restricted enforce는 helm 차트 미준수(seccompProfile·drop ALL 등) 시 라이브 operator
  거부 위험 → baseline floor가 안전. CreateNamespace 생성이라 명시 Namespace 매니페스트
  추가(cnpg/victoria 패턴) 또는 helm values + `test_psa.bats` 카운트 갱신.

### W3 — 공유 차트 하드닝 (스키마 + conftest)

- **스키마 조이기**: `values.schema.json`의 securityContext/podSecurityContext에서
  `privileged:true`/`runAsUser:0`/`allowPrivilegeEscalation:true`/`readOnlyRootFilesystem:false`
  약화 거부 + `image.tag` mutable(`latest`/`main`/`master`/`stable`/`edge`) 거부.
- **conftest 렌더 검사**: `platform/charts/app/tests/render.sh`(chart-test)에 PSA-restricted
  rego(`policy/`) 추가 — 3 kind(service/worker/static) 렌더 Pod/Job을 PSA restricted
  기준으로 검증(라이브 admission 패리티). conftest는 이미 레포 사용 중.
- **worker liveness 안전 기본**: `templates/deployment.yaml` worker 기본 liveness
  `/bin/true`(distroless CrashLoop) → 기본 비활성 또는 override-필수 강한 가드 + test 갱신.
- **migrate Job memory 분리**: `templates/migrate-job.yaml` memory를 cpu처럼 독립 오버라이드
  (또는 `max(앱limit, 128Mi)` 하한) — tight 런타임 limit이 migration OOM 유발 방지.

### W4 — 게이트 false-green / 온보딩 정합

- **verify-secrets recipient 신원**: `scripts/verify-secrets.sh`를 개수→`.sops.yaml` canonical
  2-recipient(cluster+recovery) set 비교로 강화(age 키 불필요·CI-safe). **+ 실제 gate가 도는
  경로에 배선**(현재 sops-guard.sh가 gate, verify-secrets는 미배선 → ci.yaml/gate에 연결).
  + 비-canonical recipient 픽스처 FAIL 테스트.
- **apps.json 구조검증 required 승격**: terraform 비의존 검증(JSON 배열 타입·host 전역
  유일성·apex/www/home 예약어 충돌)을 jq-only로 분리해 run-bats(required gate)에 포함
  (현재는 advisory iac-validate에만 있어 required gate 우회).
- **create-app SealedSecret 키 교차검증**: `tools/create-app.ts`에 `spec.encryptedData` 키
  집합 ↔ `config.secrets`(toEnvKey 변환) 정확 일치 검증(평문 키만, 시크릿 노출 0) —
  envFrom 후순위 섀도잉/누락 차단. + bats 케이스.
- **secret-cert-check skip 코드 구분**: fetch 실패 시 exit 0(green)→exit 2(skip)로 구분
  (자동화가 "검증됨"/"검증 못함" 혼동 방지, owner-local). echo 문구를 실제 검증 수준으로 축소.

### W5 — 문서/원장 드리프트 정정

- ledger observability 행 `2688→2624`/req `1344→1312`, 산문 합계줄 `8232→8168`
  (`docs/memory-ledger.md:17,23`)
- whoami 상주 행 추가(gateway, req16/limit32) · tailscale proxy를
  `policy/memory-limit-allowlist.txt` '범위 밖' 섹션에 등재 + local-helm(traefik/argocd/
  sealed-secrets/tailscale-operator)도 등재(블라인드스팟 가시화)
- `AGENTS.md` ts 개수 17→실제값(또는 드리프트 빈도 낮추는 정성표현)
- `Makefile` verify help 주석에 자원 limit 추가
- **traps 등재**: `docs/traps-detail.md`에 자원-limit 블라인드스팟 섹션
  (`> 가드: scripts/check-resource-limits.sh, tests/test_resource_limits.bats`) +
  `docs/traps.md` 한 줄 + AGENTS.md 한줄 인덱스 → verify-traps 역방향 tie가 추적
- 내장 SSD 용량 `512GB→224G` 정정 (`infra/k3s-bootstrap/versions.env`·`cloud-init.yaml`·
  `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`), bulk `1TB→1.9T`
- 산문 합계줄 ↔ 행 합계 교차 가드 한 줄 추가 (`tools/lib/ledger-totals.ts` 재사용)

## 라이브 영향 & 안전성

ArgoCD가 main을 싱크하므로 머지 시 라이브 반영. 영향 분류:

- **위험(주의 필요)**: PSA enforce 라벨(W2) → **baseline로 한정**해 기존 cnpg-operator/
  cert-manager 거부 회피. 라이브 파드가 baseline 준수임을 선확인(verifier가 runAsNonRoot 확인).
- **Additive(안전)**: AppProject 허용 kind 추가(W2 M1), 신규 알림(W1) — 기존 동작 불변.
- **CI-only(앱 0개라 라이브 무영향)**: 차트 스키마/템플릿/conftest(W3), 자원 가드(W1) —
  단, 기존 15개 플랫폼 매니페스트가 cpu limit 보유라 가드 확장 시 즉시 red 안 됨(TDD 선검증).
- **문서/주석(라이브 무영향)**: W5 전부, Makefile help.

## 테스트 전략

- 각 가드 변경은 **TDD**: red(위반 픽스처 FAIL) → green(정상 통과) → scan-floor/negative-path 단언.
- 차트: `make chart-test`(3 kind 렌더 + kubeconform + 신규 conftest PSA).
- `make verify`/`make ci`(gate 미러)로 전 게이트 GREEN 확인.
- 알림 메트릭은 라이브 vmagent 질의로 존재 선확인(KUBECONFIG는 메인 체크아웃에서, 워크트리는
  gitignored라 부재 — export 시 sealed-secrets server-dry-run hang 주의).
- **함정 주의**(세션 누적): bats `@test` 이름 영어(한글 침묵스킵), bash3.2 중간단언 침묵통과,
  yq 버전차(CI v4.44↔로컬), 로컬 green≠CI green라 gate watch 필수, rename 시 run-bats
  accounting/.ci-exclude 동반, auto-merge 비활성 → gate watch 후 수동 머지.
