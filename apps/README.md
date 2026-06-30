# apps/ — 배포-전용 앱 설정

ArgoCD appset(`platform/argocd/root/appset.yaml`)이 `apps/*/deploy/prod`를 싱크한다.
**여기엔 배포 설정만** 둔다 — 앱 소스 코드는 외부 레포(`ukyi-app/<app>`, 템플릿 `ukyi-app/homelab-app-template`)에 산다.

## 배포 앱 계약 (`apps/<name>/deploy/prod/`)

`tools/app-deploy-schema.json`이 SSOT. 필수 3산출물(`make verify`의 `scripts/check-app-deploy.sh`가 강제):

| 파일 | 역할 |
|---|---|
| `values.yaml` | 공유 Helm 차트(`platform/charts/app`) values 오버라이드 (없으면 ArgoCD가 빈 매니페스트로 실패) |
| `.bindings.json` | db/redis 바인딩 + autoDeploy SSOT (poll-ghcr가 권위로 읽음) |
| `source-repo` | 외부 앱 레포 바인딩(`ukyi-app/<app>`) — poll-ghcr가 이 파일 있는 앱만 update-image 폴링(`tools/poll-ghcr.ts`; 누락=폴링 밖, fail-closed) |

생성/변이는 owner가 homelab에서 액션별 변이 디스패처(create-app/update-secrets/create-database/create-cache)로만. teardown은 owner-local `make teardown-*`. 직접 만들지 않는다.

## 빌드-전용 ops 이미지는 여기 두지 않는다

CronJob 등이 참조하는 빌드-전용 이미지(예: `pg-tools`)는 **`ops/<name>/`**(Dockerfile만, `deploy/` 없음 — GHCR로
이미지만 발행). `apps/`는 ArgoCD가 워크로드로 싱크하는 배포 앱 전용이다. `build.yaml`은 `ops/**`만 빌드한다.

> 현재 인레포 배포 앱 1개(page) — 계약 가드가 필수 산출물을 강제한다.
