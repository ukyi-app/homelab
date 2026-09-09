# apps/ — 배포-전용 앱 설정

ArgoCD appset(`platform/argocd/root/appset.yaml`)이 `apps/*/deploy/prod`를 싱크한다.
**여기엔 배포 설정만** 둔다 — 앱 소스 코드는 외부 레포(`ukyi-app/<app>`, 템플릿 `ukyi-app/homelab-app-template`)에 산다.

## 배포 앱 계약 (`apps/<name>/deploy/prod/`)

`tools/app-deploy-schema.json`이 SSOT. 필수 4산출물(`make verify`의 `scripts/check-app-deploy.sh`가 강제):

| 파일 | 역할 |
|---|---|
| `values.yaml` | 공유 Helm 차트(`platform/charts/app`) values 오버라이드 (없으면 ArgoCD가 빈 매니페스트로 실패) |
| `.bindings.json` | **autoDeploy SSOT** (poll-ghcr가 권위로 읽음). **기본 `false` = 승인 PR** — 자동 배포는 앱 레포가 `.app-config.yml`의 `deploy.autoDeploy: true`로 명시 opt-in한 경우뿐이다. db/redis 바인딩은 담지 않는다 — 리소스 연결은 `values.yaml`의 `envFrom`에 conn secretRef(`db-<name>-conn`·`cache-<name>-conn`)를 넣는 손 편집 PR이고, 현재 배선은 `homelab status <app>`의 `conns`로 읽는다 |
| `source-repo` | 외부 앱 레포 바인딩(`ukyi-app/<app>`) — poll-ghcr가 이 파일 있는 앱만 update-image 폴링(`tools/poll-ghcr.ts`; 누락=폴링 밖, fail-closed) |
| `kustomization.yaml` | appset source #3가 kustomize 렌더(namespace: prod + 봉인본 resources) — 없으면 ArgoCD kustomize build 실패 |

생성/변이는 owner가 homelab에서 액션별 변이 디스패처(create-app/update-secrets/create-database/create-cache)로만. teardown은 앱과 리소스가 갈린다 — `teardown-app`은 디스패처(`teardown-app.yaml`)와 owner-local `make teardown-app`이 공존하고, `teardown-resource`는 owner-local `make teardown-resource` 전용이다. 직접 만들지 않는다.

## 빌드-전용 ops 이미지는 여기 두지 않는다

CronJob 등이 참조하는 빌드-전용 이미지(예: `pg-tools`)는 **`ops/<name>/`**(Dockerfile만, `deploy/` 없음 — GHCR로
이미지만 발행). `apps/`는 ArgoCD가 워크로드로 싱크하는 배포 앱 전용이다. `build.yaml`은 `ops/**`만 빌드한다.

> 현재 인레포 배포 앱 **0개** — `page`는 2026-09-08 재온보딩(#691) 뒤 같은 날 철거 드릴(#698)로 다시 철거됐다.
> 앱 개수 바닥값 5곳(`check-app-deploy` · `check-app-netpol:manifests` · `check-image-pins:apps` ·
> `audit-orphans` registry·apps)은 그 수(0)에 맞춰져 있다 — **앱을 다시 온보딩하면 1로 올릴 것**(각 소스의 주석에 표시).
>
> **앱 개수가 0↔1을 넘을 때의 손 단계**(2026-09-08 온보딩 드릴 #691에서 실측, 철거 드릴 #698에서 역방향 재실측 — 디스패처가 하지 않는 것만):
> 1. 위 바닥값 5곳 1↔0.
> 2. `apps/<app>/deploy/prod/values.yaml` `envFrom`에 conn secretRef 손 배선(create-app PR 안에서 해도 된다). ⚠️ 이 파일은 도구 소유라
>    **손 주석은 다음 라운드트립(update-secrets·bump)에서 사라지고 그 자체가 PR 1건이 된다** — 주석은 파일 상단이 아니라 이 README에 둔다.
> (`db create`의 pgdump 헤지 DBS 등록은 자동이라 손 단계가 아니다. `tools/tests/test_repo-walk.bats`의 image-ownership 루트 로스터는
> 손 단계였다가 **파생**이 됐다 — 기대 집합이 `apps/*/deploy/prod/values.yaml`의 디스크 실재(git 추적
> 여부와 무관하게 셸 글롭이 본다)에서 나오므로 0↔1에 무감하다. `tools/vendored-contract.json`의 동봉 계약 target 2행도
> 손 단계였다가 **#7xx부터 create-app/teardown-app이 쓴다** — 커널 `tools/lib/vendored-targets.ts`가 넣고 뺀다.)
