# ArgoCD Notifications — 배포 완료/저하 telegram 알림 (설계)

작성일: 2026-06-30 · 상태: 설계 승인됨(사용자) · 다음: writing-plans

## 1. 목표 / 동기

PR 머지 → ArgoCD 싱크 → 리소스가 **실제 Healthy로 수렴한 시점**에 telegram 알림을 보낸다.
현재 변이 워크플로(create-app/database/cache)는 **PR 생성 시점**에만 알림하고, 머지·싱크는
비동기라 "실질적 완료"(클러스터에 실제로 떴는지)를 통지하지 못한다. ArgoCD Notifications
컨트롤러(차트 번들, 현재 `enabled: false`)를 켜서 이 공백을 메운다.

## 2. 결정 (사용자 확정)

| 항목 | 결정 |
|---|---|
| 트리거 | **완료 + 저하** — `on-deployed`(싱크 OK + Healthy) + `on-health-degraded` |
| 구독 대상 | **앱 + 데이터서비스** — `apps` appset 전체 + platform의 `cnpg`·`data-conn`·`cache`만 |
| teardown | **범위 제외** — `on-deleted` prune 통지 비신뢰, PR 머지가 의도 신호 |
| sync-failed | **제외** — 기존 `ArgoCDOutOfSync`(15분+) 알림과 중복 |

## 3. 아키텍처 / 컴포넌트

1. **컨트롤러 ON** — `platform/argocd/bootstrap-values.yaml`의 `notifications.enabled: true`
   (argo-cd 차트 10.0.1 번들 서브차트; RBAC는 차트가 제공).
2. **SealedSecret `argocd-notifications-secret`** (argocd ns) — telegram 봇 토큰.
   기존과 동일 봇을 쓰되 **argocd ns + 이 이름으로 재봉인**(SealedSecret는 ns/name 스코프).
   `make seal-argocd-notify`(가칭) 타깃 추가 — `.env.secrets`의 TELEGRAM_BOT_TOKEN 봉인.
   ⚠️ **소유 충돌 회피(A.5 F1)**: argo-cd 차트 10.0.1은 `notifications.secret.create: true`(기본)로
   같은 이름 Secret을 생성한다 → **`notifications.secret.create: false`로 끄고 SealedSecret이
   단독 소유**(Helm/SealedSecrets 이중 소유 트랩 회피). 테스트로 싱크 후 토큰 키 존재를 단언.
3. **`argocd-notifications-cm`** — chart values(`notifications.notifiers`/`templates`/`triggers`)로 선언:
   - `service.telegram`: 봇 토큰은 secret 참조(`$telegram-token`).
   - **templates**: 기존 line1 계약 재사용 — `✅ <b>배포 완료</b> — {{app}} (Healthy)` /
     `🔴 <b>앱 저하</b> — {{app}} (Degraded)`. parse_mode HTML.
   - **triggers**: `on-deployed`(`oncePer: app.status.sync.revision`로 dedup),
     `on-health-degraded`.
4. **chatId 주입** — Alertmanager 패턴 미러(`alertmanager.yaml:118` init/sed): chatId는
   SealedSecret에 두고 컨트롤러 기동 전 placeholder를 치환 → **매니페스트 평문 노출 0**.
   (구현 후보: cm 내 `subscriptions` recipient를 `$telegram-chatid` 참조로, 또는 init sed.)
5. **netpol egress (컨트롤러 스코프 — A.5 F3)** — argocd-notifications-controller에
   **default-deny egress** + 검증된 런타임 의존만 명시 allow: DNS(kube-dns),
   telegram(`api.telegram.org` 외부 443), **apiserver(node subnet `192.168.139.0/24:6443` —
   ClusterIP egress 불가 트랩)**, argocd-repo-server(in-cluster). telegram+DNS만 열면
   컨트롤러의 Application watch/secret read가 끊겨 깨지고, 아무 것도 안 열면 fail-open이다.
   렌더 게이트 + 라이브 연결 테스트(정확한 flow)로 검증.

## 4. 구독 스코핑 (핵심 메커니즘)

- **`apps` appset**(`platform/argocd/root/appset.yaml`) template.metadata.annotations에
  구독 표식 추가 → 모든 앱 커버.
- **`data-conn`·`cache`** — platform-components appset이 생성한다(exclude 목록에 없음) →
  appset template에 **goTemplate 조건부**
  (`{{- if has (index .path.segments 1) (list "data-conn" "cache") }}`)로 이 둘만 표식 →
  관측/argocd/cert-manager 등은 **제외**(노이즈 억제). appset은 `goTemplate: true`.
- **`cnpg-data`** — ⚠️ **A.5 F2(검증완료)**: platform-components appset이 `platform/cnpg/*`를
  **exclude**하고, cnpg는 **수동 root Application**(`root/apps/cnpg-data.yaml`)으로 관리된다.
  appset 조건부로는 안 잡힘 → **`root/apps/cnpg-data.yaml`에 구독 어노테이션 직접 추가**.
  (DB 생성 완료 = cnpg-data Application Healthy.)

## 5. 메시지 포맷 (일관성)

3채널(GHA 액션·Alertmanager·in-cluster 스크립트)이 공유하는 line1 계약
`{글리프} <b>{제목}</b> — {상태}` 그대로 사용. 상태어휘: `배포 완료`(✅)/`앱 저하`(🔴).
→ 알림 톤 cross-channel 일관성 유지.

## 6. 테스트 전략 (TDD)

- `test_argocd_values.bats` 확장: `notifications.enabled: true` + templates/triggers 렌더 단언.
- 메시지 템플릿 계약 테스트(기존 telegram 게이트 패턴 미러 — 글리프·bold·한국어 제목).
- 구독 표식 검사 — appset 생성(data-conn/cache만, 나머지 platform 미표식) + 수동 root
  Application(cnpg-data 표식) **양쪽** 단언(yq).
- kustomize/helm 렌더 + kubeconform clean.
- netpol 존재 게이트(egress to telegram).
- **라이브 검증**: 실제 배포 1건 트리거 → telegram 수신 확인(restart count/시각/실수신까지).

## 7. 보안 / DR

- 토큰=SealedSecret(커밋·콜드스타트 선언적 복원), chatId 평문 노출 0.
- netpol로 egress 최소화(컨트롤러 스코프: DNS·telegram·apiserver·repo-server만 — §3.5).
- 컨트롤러 enable은 values 선언 → DR durable.

## 8. 비목표

- teardown 완료 알림(on-deleted) — 제외.
- sync-failed 트리거 — 기존 OutOfSync 알림과 중복이라 제외.
- 관측/argocd/cert-manager 등 나머지 platform 컴포넌트 구독 — 제외.

## 9. 주요 리스크 / 함정 (플랜에서 강화)

- **chatId 평문 노출** → sed/secret-ref 주입(검증된 AM 패턴).
- **Secret 이중 소유(A.5 F1)** → `notifications.secret.create: false` + SealedSecret 단독 소유.
- **netpol egress(A.5 F3)** → 컨트롤러는 telegram·DNS뿐 아니라 **apiserver(node subnet)·
  repo-server**도 필요. 컨트롤러 스코프 default-deny + 검증된 의존만 allow.
- **cnpg-data 수동 Application(A.5 F2)** → appset이 cnpg exclude → root/apps/cnpg-data.yaml 직접 어노테이트.
- **차트 10.0.1 notifications values 스키마** 매핑(notifiers/templates/triggers 위치) — 플랜에서
  실제 차트 values 스키마 확인.
- **SealedSecret ns/name 스코프** — argocd ns로 재봉인 필수(다른 ns 봉인본은 컨트롤러가 복호 불가).
- **on-deployed 노이즈** — `oncePer: revision` dedup 의존(steady-state 저빈도라 수용).
- **sync-wave** — 컨트롤러/secret/cm 배치 순서(secret이 컨트롤러보다 먼저).

## 10. 설계 적대 리뷰 (Phase A.5 — codex, design 렌즈)

verdict: `needs-attention` → HIGH 3건 전부 **Accept** 후 위 설계에 반영(2026-06-30).

| # | Finding | 결정 | 반영 |
|---|---|---|---|
| F1 | 차트가 `argocd-notifications-secret` 기본 생성 → SealedSecret 이중 소유 | Accept | §3.2 `secret.create: false` + SealedSecret 단독 소유 |
| F2 | cnpg는 appset exclude·수동 root Application → 조건부 구독 미적용(DB 누락) | Accept(검증완료) | §4 cnpg-data 직접 어노테이트 + 양쪽 테스트 |
| F3 | egress가 telegram+DNS만 → apiserver/repo-server 누락(깨짐) 또는 fail-open | Accept | §3.5 컨트롤러 스코프 default-deny egress(apiserver node-subnet 포함) |
