# 테마7 설계: 인프라/부트스트랩 드리프트 + 데이터 최소권한

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+infra-drift-least-privilege` (브랜치 `worktree-feat+infra-drift-least-privilege`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마7 ("인프라/부트스트랩 드리프트+데이터 최소권한", 중/저·M)

## 1. 배경 / 문제 (5발견, 전부 라이브 grounding) — 위험도 혼재

| # | 발견 | 라이브 근거 | 위험 |
|---|---|---|---|
| 1 | `infra/_backend/backend.tf`가 **거짓 SSOT** — terraform backend는 root 안에 있어야 해 공유 불가, 각 root(cloudflare/github/tailscale)가 backend.tf **사본** 보유(cloudflare/backend.tf 주석이 "_backend/backend.tf의 사본"임을 명시), 드리프트 무가드 | `infra/{_backend,cloudflare,github,tailscale}/backend.tf` 4개 거의 동일(주석만 차이) | CI/local |
| 2 | `orb-create.sh:22` 머신 존재 시 cloud-init **skip**(idempotent) → `cloud-init.yaml` 편집 미적용. `host-up.sh:4` "각 단계 멱등=재실행 안전"이 이 트랩을 가림(편집→host-up→적용된 줄 오인) | `orb-create.sh:22,26`·`host-up.sh:4` | owner-local 스크립트 |
| 3 | `allow-egress-to-database`(podSelector `{}`=전 prod pod) → database **namespace 전체** 5432 허용(pooler `pg-pooler-rw`/cluster `pg-rw` pod 한정 아님 → prod pod가 primary를 직접 우회 가능) | `networkpolicies.yaml:43-52`(to=namespaceSelector만) | ★**HIGH 라이브**(narrowing 라벨 미스→DB 전면 차단=outage) |
| 4 | (gap) `storageclass-standard` **Retain**(DB 데이터 보호 의도) → PVC 삭제 시 PV가 `Released`로 잔존+hostPath 디스크 데이터 누수, 고아 PV 무감시/무정리 | `storageclass-standard.yaml:10`·hostPath PV | 저(누수 느림) |
| 5 | (gap) cloudflared deployment securityContext에 **`seccompProfile` 없음** — homepage/adguard/cnpg 등 표준(`seccompProfile: RuntimeDefault`)과 비대칭 | `cloudflared/prod/deployment.yaml:34-39`(seccomp 부재) vs homepage:25 | 저 라이브 |

## 2. 목표 / 비목표

### 목표
- 거짓 SSOT(_backend)를 **드리프트 가드**로 진실화(사본 일치 강제). cloud-init "멱등=변경무시" 트랩을 **명시 경고**.
- prod→database egress를 **pooler/cluster pod로 최소화**(라이브 라벨검증+posture e2e로 안전하게).
- 고아 Released PV **감사**(누수 가시화). cloudflared **seccomp 표준 정합**.

### 비목표
- `storageclass-standard` Retain 변경(DB 보호 의도 — 유지) · emptyDir/PVC 모델 변경.
- terraform backend 통합(불가 — root별 필수). 부트스트랩 cloud-init 로직 재작성(경고만).
- netpol을 넘는 mTLS/추가 보안 계층. cloudflared 기능 변경(seccomp만).

## 3. 설계: 5 수정

### 수정 1 — backend 드리프트 가드 (CI/local)
- bats(`tests/` 또는 `infra/_tests/`): 3 root(`cloudflare/github/tailscale`)의 `backend.tf`에서 `terraform { backend "s3" {...} }` 블록(주석 제외)이 **서로 + `_backend/backend.tf`와 일치**하는지. 불일치=fail(거짓 SSOT 드리프트 차단).
- `_backend/backend.tf` 주석에 "이 파일은 **template** — 각 root가 사본을 두며 `test_backend-drift`가 일치를 강제한다" 명시.

### 수정 2 — orb-create cloud-init skip 경고 (owner-local)
- `orb-create.sh:22` skip 분기에 경고: "⚠️ cloud-init.yaml 편집은 **기존 머신에 적용되지 않는다** — 재생성(orb delete <m> + 재실행) 또는 머신 내 수동 적용 필요." + cloud-init.yaml mtime이 머신 생성 이후면(`orb info`/생성마커 비교 가능 시) 강조.
- `host-up.sh`의 "멱등=안전" 주석에 cloud-init 예외 한 줄(편집 반영은 재생성 필요).

### 수정 3 — prod→database egress 최소화 (★HIGH 라이브 — 강한 게이트)
- `allow-egress-to-database`의 `to`에 **podSelector 추가** — pooler(`pg-pooler-rw`) + cnpg 클러스터 pod만. CNPG 자동생성 라벨(예 `cnpg.io/poolerName`·`cnpg.io/cluster`)이라 ★**라이브 `kubectl -n database get pods --show-labels`로 정확 라벨 확인 후** 작성(미스시 DB 전면 차단).
- 정적: `test_netpol.bats`가 podSelector 좁힘을 단언(기존 namespace+5432 + 신규 pod 한정). 라이브: **`make verify-posture`(test_networking-e2e)로 앱→DB 연결 정상·비대상 차단** 확인 — 머지 전 필수(outage 방지).

### 수정 4 — storage 고아 Released PV 감사 (D2: 스크립트/런북)
- 감사 스크립트(`scripts/audit-orphan-pv.sh` 또는 기존 audit 확장): `kubectl get pv`에서 `status.phase==Released` PV 나열(고아=PVC 삭제+Retain 잔존) + hostPath 경로 표시 → owner가 수동 reclaim. 런북(`docs/runbooks/` 로컬)에 절차.
- Retain 정책은 **유지**(DB 보호) — 누수는 가시화+수동 정리로 관리(단일운영자, 알림은 D2서 제외).

### 수정 5 — cloudflared seccompProfile 정합 (저 라이브)
- `cloudflared/prod/deployment.yaml` securityContext(pod 또는 container)에 `seccompProfile: { type: RuntimeDefault }` 추가. cloudflared는 hardened(nonroot·drop ALL·RO rootfs)라 RuntimeDefault 안전(userspace 터널, 특수 syscall 없음).
- 정적: cloudflared seccomp bats 단언(타 컴포넌트와 정합). 렌더 후 `make render`/chart-test.

## 4. 라이브 위험 / 검증

- **위험도**: 1·2=무(CI/owner-local), 5=저(seccomp RuntimeDefault), 4=저(감사만, Retain 불변), **3=HIGH**(netpol — 라벨 미스→DB outage).
- **검증**: 정적 bats(backend 드리프트·netpol podSelector·cloudflared seccomp, run-bats 게이트) + `make render`/chart-test(kustomize) + **발견3은 라이브 `--show-labels` + `make verify-posture`(연결성 e2e) 머지 전 필수**(D1=단일 PR이나 netpol 강한 게이트).
- ★**netpol 함정**(AGENTS.md): podSelector 좁히기는 라벨 미스 시 차단 — 라이브 라벨 확인 없이 머지 금지. kube-router 룰 설치 갭(`sleep 8` 후 연결)·selfHeal app은 임시 patch 원복.
- bats `@test` 영어·중간 단언 `[ ]`·bash 3.2 호환.

## 5. 결정사항

- **D1 (발견3 netpol 위험)** → **단일 PR, netpol 강한 게이트**(사용자 결정). 5발견 한 PR이되 netpol은 라이브 라벨검증+posture e2e 머지 전 필수(라벨 미스=outage라 게이트가 안전망). 격리 대신 강한 검증.
- **D2 (발견4 storage 범위)** → **감사 스크립트/런북**(사용자 결정). 고아 Released PV 감사+수동 reclaim 런북. 알림(core.yaml)은 제외(theme6 결, 누수 느림·단일운영자).
- **A.5 생략**(설계 단순·라이브 검증이 netpol 안전망).

## 6. 범위 밖 (명시)

- Retain 정책 변경·terraform backend 통합·cloud-init 로직 재작성·storage 알림·cloudflared 기능 변경·netpol 외 보안 계층.
