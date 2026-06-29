# 플랫폼 하드닝 설계 — 프로비저닝·풀러 결함 재발 방지

**목표**: 첫 실앱 `page` 온보딩에서 드러난 프로비저닝/풀러 결함이 신규 앱에서 재발하지 않도록 homelab 앱 플랫폼을 하드닝한다.

**배경**: `page`(첫 실 DB 앱)를 온보딩하며 4개 간극이 드러났다.
1. data-conn 렌더 테스트 취약 — 이미 #138로 해결(일회성).
2. `kind: service` 폐기 → create-app 검증이 명확히 거부(정상 동작, template 노후만 잔존).
3. **CNPG managed role 비밀번호 미적용** — 신규 DB앱 롤이 conn 시크릿 비번으로 인증 실패(재발성 높음).
4. **PgBouncer가 `statement_timeout` startup 파라미터 거부** — 풀러 경유 런타임 쿼리 전부 실패 → 이미 #145(풀러 `ignore_startup_parameters`)로 **해결**.

본 설계는 재발성이 높은 **#3**와, 이를 포함한 미래 결함을 상시 포착할 **검증(카나리)**, 그리고 신규 앱을 정설계로 만드는 **템플릿 하드닝** 3개 워크스트림을 다룬다.

---

## 핵심 제약 (설계를 규정함)

- **CI(GitHub 러너)는 인클러스터 풀러(`pg-pooler-rw`)에 네트워크로 도달할 수 없다.** 따라서 "conn 자격증명이 풀러로 실제 인증되는가"는 CI 게이트로 검증 불가 — 검증은 **반드시 클러스터 안**(상시 카나리 또는 Job)에서 이뤄져야 한다. (page가 크래시루프로 알림을 발생시킨 것 자체가 인클러스터 검증이 동작한 사례다.)
- 검증 형태는 **상시 카나리 앱**으로 확정(일회성 Job 대비 회귀를 상시 포착).

---

## WS1 — #3 CNPG managed role 비밀번호 적용 보장 (per-app 소스 픽스)

### 원인 (라이브 확정)
- CNPG가 managed role `<app>`을 그 `passwordSecret`(`db-<app>-owner`)가 materialize되기 **전에** reconcile → 비밀번호 미적용. `cluster.status.managedRolesStatus.passwordStatus.<app>`에 `resourceVersion`이 기록되지 않음.
- 그 뒤 **secret의 resourceVersion이 바뀌기 전까지 CNPG는 비밀번호를 재적용하지 않는다.** (page에서는 운영자가 owner Secret을 annotate하자 resourceVersion이 바뀌며 CNPG가 비로소 재적용 → self-heal됨.)
- 즉 SealedSecret 복호화(sealed-secrets 컨트롤러, 비동기)와 CNPG 롤 reconcile 사이의 **순서/타이밍 레이스**.

### 픽스 — ArgoCD sync-wave 순서
- `provision-db.ts`가 생성하는 `db-<app>-owner`/`db-<app>-ro` SealedSecret에 **cluster.yaml의 managed-role 패치보다 앞선 sync-wave** 어노테이션을 부여.
- ArgoCD가 SealedSecret을 먼저 동기화하고 healthy(= sealed-secrets가 평문 Secret 생성)된 뒤 cluster 패치를 적용 → CNPG가 롤을 reconcile할 때 Secret 존재가 보장됨.
- `platform/cnpg/prod/test_sync_wave_ordering.bats`에 단언 추가: `db-<app>-owner/ro` secret의 wave < cluster(또는 managed-role) wave.

### 검토한 대안
- **(a) sync-wave 순서 (채택)** — GitOps-native, per-app 자동, 기존 sync-wave 패턴과 일관.
- (b) 검증만 + 수동 재동기화 — 레이스가 잔존(매 신규 앱마다 사람이 nudge).
- (c) provision/Job이 직접 `ALTER ROLE` — CNPG managed-role 소유권과 충돌(다음 reconcile에서 흔들림).

### 잔여 위험 / 구현 시 확인
- **ArgoCD가 SealedSecret을 "Secret 생성 후에만" healthy로 판정하는지** 검증 필요(sealed-secrets health check). 만약 SealedSecret이 Secret 생성 전에 healthy로 잡히면 wave만으로 부족 → WS2 카나리가 포착하고, 보강책으로 "passwordStatus에 resourceVersion이 생길 때까지 대기 후 없으면 owner Secret을 idempotent하게 nudge"하는 인클러스터 단계를 추가한다.

---

## WS2 — 상시 카나리 앱 (인클러스터 골든패스 검증)

### 목적
풀러·conn 포맷·CNPG 롤·sealed-secrets·admin secret을 잇는 **골든패스**가 깨지면 즉시 신호. 새 앱이 prod에서 처음 깨지는 것을 막고, CI가 닿지 못하는 인클러스터 경로를 상시 감시한다.

### 형태
- 현재 DB를 쓰지 않는 픽스처 `example-api`를 **DB 백업 카나리**로 전환(또는 전용 `canary` 앱 신설).
- 자체 `create-database`로 카나리 DB + conn 핸들 보유.
- 런타임은 **풀러 경유** conn(`*_DATABASE_URL`)으로 연결.
- 부팅 시 self-migrate(직결) + `/health`(또는 별도 readiness)에서 **풀러 왕복 `SELECT 1`** 수행 → 풀러 경로가 깨지면 readiness 실패 → 알림.
- admin secret 보유(전 온보딩 단계 재현).
- 표준 앱 경로(create-app)로 배포, `active`.

### 효과
- #4 같은 풀러 회귀, conn 키 변경, CNPG 비번 문제 등을 **상시** 포착(page가 크래시로 알린 것과 동일 메커니즘을 의도적으로 상비).
- 신규 앱 온보딩이 "검증된 경로"를 물려받음.

### 구현 시 확인
- `/health`가 DB 왕복을 하면 DB 일시 장애 시 readiness가 빠져 알림이 과민할 수 있음 → liveness는 정적, readiness/별도 probe에서만 DB 왕복하도록 분리(앱이 죽지 않고 not-ready로 신호).

---

## WS3 — 템플릿 하드닝 (homelab-app-template)

신규 앱이 처음부터 풀러 호환·현행 규약을 따르도록 한다.

- **DB 클라이언트 풀러 안전 기본값**: `statement_timeout` 등 서버 GUC를 libpq **startup 파라미터로 보내지 않는다**. 타임아웃은 클라이언트측 `query_timeout` + 앱 레벨 read deadline로 보호하고, 서버측 강제가 필요하면 role 기본값(`ALTER ROLE ... SET`)으로 둔다. → 신규 앱 #4-클래스 원천 차단.
- **현행 kind enum**: `.app-config.yml`이 `web`/`worker`/`site`만 쓰도록(폐기된 `service` 제거) → #2 방지.
- **DB 백업 health**: 템플릿 `/health`(readiness)에 DB 왕복 포함 → 새 앱이 DB 경로를 부팅 시 fail-fast/명시 신호.
- (선택) `page`의 `src/core/database/db.ts`도 동일 정리 — 현재는 풀러 `ignore_startup_parameters`로 동작하므로 기능 영향 없음, 코드 청결화 목적.

---

## 테스트 / 검증 전략

- **WS1**: `test_sync_wave_ordering.bats`에 wave 순서 단언 추가. 실증은 WS2 카나리(및 신규 앱) 온보딩 시 비번 인증 성공으로 확인.
- **WS2**: 카나리 배포 후 `/health`(readiness) DB 왕복 그린 확인. 의도적 회귀(예: 풀러 `ignore_startup_parameters` 제거)로 카나리 readiness 실패 → 알림 발생을 검증(리허설).
- **WS3**: 템플릿으로 스캐폴드한 샘플을 풀러 환경에 연결해 statement_timeout 미전송·연결 성공 확인. kind enum 검증은 create-app 검증이 이미 커버.

## 안전 / 롤백

- 워크스트림별 **독립 PR**(homelab main 보호 → 전부 PR).
- WS2 카나리는 **신규 앱**(기존 워크로드 영향 0).
- WS3 템플릿 변경은 **신규 스캐폴드만** 영향(기존 앱 무영향).
- WS1 sync-wave는 **어노테이션**이라 되돌리기 쉬움.

## 비범위 (YAGNI)

- #4(풀러) — #145로 완료.
- `page` 재배포 — 이미 정상 동작 중(롤 비번 self-heal + 풀러 픽스 적용).
- **CI에서 라이브 conn 검증** — GitHub 러너가 인클러스터 풀러에 도달 불가하므로 추구하지 않음. 인클러스터 카나리로 대체.

## 작업 위치

- 설계/계획/워크트리: `~/workspace/homelab`(주 레포). 워크트리: `hardening/platform-recurrence`.
- 관련 경로: `tools/provision-db.ts`, `platform/cnpg/prod/{cluster.yaml,pooler.yaml,databases/,test_sync_wave_ordering.bats}`, create-database/_create-app 워크플로, homelab-app-template, (선택) `page` `src/core/database/db.ts`.
