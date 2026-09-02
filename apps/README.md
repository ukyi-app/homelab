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

생성/변이는 owner가 homelab에서 액션별 변이 디스패처(create-app/update-secrets/create-database/create-cache)로만. teardown은 앱과 리소스가 갈린다 — `teardown-app`은 디스패처(`teardown-app.yaml`)와 owner-local `make teardown-app`이 공존하고, `teardown-resource`는 owner-local `make teardown-resource` 전용이다. 직접 만들지 않는다.

## 빌드-전용 ops 이미지는 여기 두지 않는다

CronJob 등이 참조하는 빌드-전용 이미지(예: `pg-tools`)는 **`ops/<name>/`**(Dockerfile만, `deploy/` 없음 — GHCR로
이미지만 발행). `apps/`는 ArgoCD가 워크로드로 싱크하는 배포 앱 전용이다. `build.yaml`은 `ops/**`만 빌드한다.

> 현재 인레포 배포 앱 **0개** — `page`(#455)·`trip-mate-api`를 철거했다. 이 디렉토리는 빈 채로 남는다
> (`check-skeleton`이 `apps` 존재를 요구하고 git은 빈 디렉토리를 추적하지 않으므로 이 README가 그 자리를 지킨다).
> 앱 개수에 걸린 바닥값 4개(`--floor check-app-deploy=<n>`·`--floor check-app-netpol:manifests=<n>`·`--floor check-image-pins:apps=<n>`·`--floor audit-orphans:registry=<n>`)를
> 그에 맞춰 0으로 낮춰 뒀다 — **새 앱을 온보딩하면 1로 되돌릴 것**(각 소스의 ⚠️ 주석에 표시).
