# 설계: homelab-app-template 개선 — Bun/Hono/React 대화형 스캐폴더 + kind 리네임

- 작성일: 2026-06-29
- 상태: 승인됨 (brainstorming HARD-GATE 통과) + Phase A.5 설계 리뷰 반영(§7.1 추가, high 발견 1건 ACCEPT)
- 대상 레포(교차):
  - `ukyi-app/homelab` (로컬 `~/workspace/homelab`) — 계약·공유차트·create-app·테스트·문서·라이브 example-api
  - `ukyi-app/homelab-app-template` (로컬 `~/workspace/homelab-app-template`) — 템플릿 새 구조·스캐폴더·아키타입
- 설계/계획 문서 위치: **homelab `docs/plans/`** (정규 위치; 계약·차트가 여기 있고 리스크 큰 변경이 homelab 측)

## 1. 동기·목표

현재 `homelab-app-template`은 거의 빈 스텁이다(`.app-config.yml`(`kind: service`) + TODO 뿐인 `Dockerfile` + 빈 `src/.gitkeep` + `release.yaml`). 또한 템플릿 `.app-config.yml`이 계약(`app-config-schema.json`, `additionalProperties:false`)과 드리프트되어 있다(`db/redis/migrate/secrets`는 스키마 밖).

목표:

1. `kind`를 직관적 어휘 **`web` / `worker` / `site`** 로 전면(rename-everywhere) 교체.
2. 템플릿을 **Bun + Hono(서버) + React/Vite(프론트)** 가 "바로 배포되는" 실동작 스캐폴드로.
3. 스캐폴드를 **`bun run scaffold`** 대화형 CLI(`pnpm create vite` 스타일)로, 실행 후 **자가삭제**.
4. 템플릿↔계약 **드리프트 가드** CI 추가.

## 2. 결정된 사항 (brainstorming)

| # | 결정 | 선택 |
|---|---|---|
| 구조 모델 | 아키타입(CLI 전용) → 최소 infra `kind`. 아키타입은 계약에 영속 안 됨 | **A** |
| kind 네이밍 | `web`(서빙) / `worker`(백그라운드) / `site`(정적 SWS) | **세트 1** |
| 스캐폴더 배포 | GitHub 템플릿 유지 + `bun run scaffold` 실행 스크립트 + 자가삭제 | **모델 B** |
| 앱 런타임 | **Bun** (Hono on `Bun.serve`), `bun build --compile` → distroless/base. site만 SWS | Bun |
| 실행 명령 | `bun run scaffold` (`init`/`create`는 `bun init`/`bun create`와 충돌) | scaffold |
| 리네임 범위 | 스키마+create-app+공유차트+fixtures+bats+라이브 example-api 전부 | **rename-everywhere** |

## 3. 어휘 모델 (구조 A)

아키타입은 **스캐폴더 CLI에만** 존재하고(배포엔 토폴로지만 필요), `.app-config.yml`·create-app·차트는 리네임된 infra `kind`만 본다.

| 스캐폴더 아키타입 | 생성 코드 | → `kind` | 차트 토폴로지 |
|---|---|---|---|
| Full-stack (Hono+React) | Hono가 `/api/*` + 빌드된 React SPA 서빙 (한 컨테이너) | `web` | Deployment+Service+HTTPRoute :8080 |
| API (Hono only) | Hono API 서버 | `web` | 〃 |
| Site (React SPA) | Vite 빌드 → SWS 서빙 | `site` | 〃 (SWS, `/health`) |
| Worker (백그라운드) | Bun 루프/컨슈머 | `worker` | Deployment만 |

- `web`이 fullstack/api 두 아키타입을 받는 것은 의도된 설계(차트 토폴로지 동일, 차이는 생성 코드뿐).
- **fullstack을 기본 추천 아키타입**으로 둔다(목표 #2).
- 아키타입은 스캐폴드 시점에만 의미 → 계약 필드로 영속화하지 않음(변경 범위 최소).

## 4. 템플릿 레포 새 구조

```
homelab-app-template/
├─ scaffold/                    # 스캐폴더 머신러리 (bun run scaffold 실행 후 자가삭제)
│  ├─ scaffold.ts               # @clack/prompts 대화형 진입점
│  ├─ archetypes/
│  │  ├─ fullstack/   # src/(Hono) + web/(Vite React) + Dockerfile + app-config.tmpl.yml + package 조각
│  │  ├─ api/         # src/(Hono) + Dockerfile + app-config.tmpl.yml + package 조각
│  │  ├─ site/        # web/(Vite React) + Dockerfile(SWS) + app-config.tmpl.yml + package 조각
│  │  └─ worker/      # src/(Bun loop) + Dockerfile + app-config.tmpl.yml + package 조각
│  └─ common/                   # 공통 파일(.gitignore, tsconfig.json, .github/, README 본문, .dockerignore)
├─ package.json                 # "scaffold": "bun run scaffold/scaffold.ts" + devDep @clack/prompts
├─ README.md                    # "이 레포로 시작: bun install && bun run scaffold"
└─ .github/workflows/
   ├─ release.yaml              # 기존(빌드; 템플릿 자기빌드 가드 if: repo != template 유지)
   └─ template-ci.yaml          # 신규: 각 아키타입 비대화형 스캐폴드 → 빌드/스키마 검증
```

- 스캐폴드 전 템플릿 레포에는 **빌드 가능한 루트 앱이 없음**(아키타입은 `scaffold/archetypes/` 안) → `release.yaml`의 자기빌드 가드(`if: github.repository != 'ukyi-app/homelab-app-template'`)와 정합.
- 자가삭제 후 결과 앱 레포에는 `scaffold/`·`@clack/prompts`가 남지 않는다.

## 5. 아키타입별 런타임·Dockerfile

### 5.1 fullstack / api / worker (Bun)

멀티스테이지:

- builder: `oven/bun:<핀>` — `bun install`; fullstack은 `vite build`로 `web/dist` 생성; `bun build --compile --target=bun-linux-arm64 src/index.ts --outfile app`.
- runtime: **`gcr.io/distroless/base-debian12:nonroot`** (arm64). 바이너리 `app` + (fullstack)`web/dist` 복사, `USER nonroot`, `EXPOSE 8080`, `ENTRYPOINT ["./app"]`.

근거: 현 `distroless/static`은 Bun 컴파일 바이너리(비-static, glibc 의존)에 부적합 → `base-debian` 필요. (계획에서 실제 arm64 크로스컴파일 + base-debian 실행을 검증.)

### 5.2 site (SWS)

- builder: `oven/bun:<핀>` — `vite build`로 `web/dist`.
- runtime: **`ghcr.io/static-web-server/static-web-server:<핀>-scratch`** (arm64). `COPY web/dist /public`.
- **이미지 ENTRYPOINT = SWS 바이너리** (차트가 `args:`만 주입하고 `command:`는 안 줌 — `deployment.yaml` L45-50 검증). pod `securityContext`(runAsNonRoot/UID)는 차트가 강제.

(계획에서 SWS scratch 이미지의 nonroot/readOnlyRootFilesystem/arm64 양립을 렌더+라이브 검증.)

## 6. 런타임 계약 (생성 앱이 충족)

차트가 강제·기대하는 계약(`deployment.yaml`/`service.yaml`/`values.yaml` 기준):

- **web/api**: `:8080` Hono(`Bun.serve`), `/healthz`(liveness)·`/readyz`(readiness) 구현 + 생성된 `.app-config.yml`의 `probes`에 동일 경로 명시(분리 시맨틱; readyz는 의존성 확인 자리). metrics 켜면 `:9090 /metrics` 별도 listener.
- **fullstack**: 위 + Hono `serveStatic`으로 `web/dist` 서빙(SPA fallback → `index.html`). API는 `/api/*` prefix.
- **site**: SWS가 `/health` 제공(앱 코드 불필요). 프로브는 차트가 `/health`로 고정.
- **worker**: 리슨 없음, 기본 liveness 없음(distroless `/bin/true` CrashLoop 방지 — 차트 동작).
- 공통: arm64 distroless non-root, `/tmp`만 쓰기(차트 emptyDir 마운트). `preStopSleepSeconds` 미설정(distroless에 `/bin/sleep` 부재).
- metrics(:9090 포트·scrape 어노테이션)는 **`kind: web` + `metrics.enabled`** 일 때만 차트가 배선(site/worker 제외).

> 기존 불일치 메모: README 계약은 `/healthz,/readyz`인데 차트 기본 프로브 경로는 `/health`(values.yaml). 본 설계는 **생성 앱이 `.app-config.yml probes`를 명시**해 자기일관성을 갖게 한다(차트 기본값은 건드리지 않음 — 범위 밖).

## 7. homelab 측 변경 (rename-everywhere)

단일 PR로 원자적 변경:

- `tools/app-config-schema.json`: `kind` enum → `["web","worker","site"]`, description 갱신(static→site, service→web).
- `tools/create-app.ts`: `served = kind !== "worker"`(불변); `if (kind === "site") values.static = { server: "sws" }`(was `"static"`); kind 문자열 참조 비즈룰(worker route 금지 등) 갱신.
- `platform/charts/app/values.schema.json`: `kind` enum 갱신.
- `platform/charts/app/templates/_helpers.tpl`: `app.isServed`(worker 비교 — 이름 불변), 관련 주석.
- `platform/charts/app/templates/deployment.yaml`: `eq .Values.kind "static"`→`"site"`(args·프로브 블록), `eq .Values.kind "service"`→`"web"`(metrics 포트·scrape 어노테이션 조건).
- `platform/charts/app/templates/service.yaml`: `eq .Values.kind "service"`→`"web"`(metrics 포트).
- `platform/charts/app/tests/fixtures/`: `service.yaml`→`web.yaml`, `static.yaml`→`site.yaml`(+내부 `kind:` 값); `render.sh` 루프 `for k in web worker site`.
- `platform/charts/app/tests/*.bats`: kind 문자열 참조(test_static/test_worker_ports/test_route 등) 갱신. **@test 이름은 영어 유지**(CJK 침묵스킵 함정).
- `tools/tests/test_create-app.bats`·`test_app-config.bats`: kind 문자열·매핑 케이스 갱신.
- `apps/example-api/deploy/prod/values.yaml`: `kind: service`→`web` (**라이브 1개**; 같은 PR·기능상 no-op 싱크).

### 7.1 외부 앱 레포 마이그레이션 (Phase A.5 설계 리뷰 반영, high)

rename-everywhere는 **외부 앱 레포가 소유한 `.app-config.yml`** 까지 완결돼야 한다. 외부 `ukyi-app/<app>/.app-config.yml`이 여전히 `service`/`static`을 내면, 이를 스키마로 재검증·재소비하는 homelab 흐름이 fail-closed될 수 있다(§7은 인레포 `apps/example-api/values.yaml`만 다룸). 따라서:

1. **기존 외부 앱 열거·검증**: `apps/`(인레포 배포 config)·`infra/cloudflare/apps.json`(앱 레지스트리)·org 레포를 교차 확인해 **현존 외부 앱 전체를 경험적으로 식별**(현재 가설: example-api 단일). 가설이 깨지면(앱 다수) 계획에서 각 앱을 마이그레이션 대상에 포함.
2. **same-window 마이그레이션**: 각 외부 앱의 `.app-config.yml` `kind`를 신값으로 갱신(example-api: `service`→`web`). homelab 스키마 컷오버와 **같은 윈도우**에 수행(외부 레포는 별도 PR/시점 조율).
3. **재검증 경로 식별**: 외부 `.app-config.yml`을 스키마로 재검증·재소비하는 homelab 흐름(`create-app`/`bump-poll`/`update-secrets`/`create-database`/`create-cache`)을 코드로 확인해 **기존 앱이 재검증되는 지점**을 문서화하고, 안전한 컷오버 순서를 정의(재검증 흐름이 없으면 윈도우 무해; 있으면 외부 config를 먼저/같은 윈도우에 마이그레이션).
4. **actionable fail-loud**: 스키마/create-app이 구 `kind`(service/static)를 받으면 **명시적 안내 에러**(예: "kind: service는 더 이상 지원되지 않음 → web으로 변경")로 거부하도록 보장하고, 이를 검증하는 테스트 추가. 침묵 실패 방지.
5. **영구 compat 브리지 미채택**: 블라스트 반경이 owner 소유 앱 소수(현 1개)라 same-window 마이그레이션으로 충분 — 스키마에 dual-vocab을 영구 잔존시키지 않는다(rename-everywhere 종착지 유지).

## 8. 대화형 스캐폴더 동작 (`bun run scaffold`)

- UI: `@clack/prompts`(create-vite류). 프롬프트(한국어):
  1. 앱 이름 (기본=레포 디렉토리명, `^[a-z0-9-]+$` 검증)
  2. 아키타입 선택 (fullstack/api/site/worker, 기본 fullstack)
  3. 공개 노출? (`route.public`: 내부 `<app>.home.ukyi.app` / 공개 `<app>.ukyi.app`)
  4. metrics(:9090) 활성? (web만 의미, 기본 off)
  5. autoDeploy? (기본 on)
- 비대화형 모드(CI·테스트용): 동일 선택을 flag/env로 주입(예: `--archetype api --name foo --yes`).
- 동작:
  1. 선택 아키타입 `scaffold/archetypes/<a>/*` + `scaffold/common/*`을 레포 루트로 전개.
  2. `.app-config.yml` 렌더(kind=아키타입 매핑, resources 아키타입별 기본값, route, metrics, deploy).
  3. `package.json` name·scripts를 앱용으로 치환(스캐폴드 스크립트·`@clack/prompts` 제거).
  4. README를 앱 README로 교체.
  5. **자가삭제**: `scaffold/` 디렉토리 삭제.
  6. 안내 출력(다음 단계: `git add -A && git commit && git push` → owner가 homelab `create-app`).
- 멱등/안전: 이미 스캐폴드된 레포(루트에 `src/` 또는 `web/` 존재 + `scaffold/` 부재)에서 재실행 시 거부.

## 9. 아키타입별 `.app-config.yml` 기본값 (resources)

- web/api/worker(Bun): `requests {cpu:50m, memory:64Mi} / limits {cpu:500m, memory:128Mi}` (현 기본 유지).
- site(SWS): `requests {cpu:10m, memory:16Mi} / limits {cpu:100m, memory:32Mi}` (fixture 기준 경량).
- web/api: `probes.liveness.path:/healthz`, `probes.readiness.path:/readyz`. site/worker: probes 생략(차트 처리).
- metrics.enabled: 스캐폴더 응답 기반(web만).

## 10. CI·드리프트 가드

- **템플릿 `template-ci.yaml`(신규)**: 매트릭스 [fullstack, api, site, worker] —
  - 임시 디렉토리에서 비대화형 `bun run scaffold --archetype <a> --name ci-<a> --yes` 실행.
  - 산출 `.app-config.yml`을 **homelab `tools/app-config-schema.json`@main**(원격 fetch)으로 검증 → 템플릿↔계약 드리프트 차단(현재 CI 미강제 갭).
  - 앱 빌드 검증: `bun install` + (web/api/worker)`bun build`/(fullstack·site)`vite build` + `tsc --noEmit`.
  - (선택) `docker build`/hadolint로 Dockerfile lint.
- 기존 `release.yaml` 자기빌드 가드 유지.

## 11. 문서 갱신

- 템플릿 `README.md`: `bun install && bun run scaffold` 흐름·계약 요약.
- homelab `AGENTS.md`/온보딩 문서: "3 kind(service/worker/static)" → `web/worker/site`; 앱 온보딩 흐름에 스캐폴더 단계 추가.
- 드리프트된 템플릿 `.app-config.yml`(현 db/redis/migrate/secrets) 문제는 새 구조가 자연 해소.

## 12. 교차 레포 실행·검증 전략

- **homelab**(워크트리·PR): 단일 PR(스키마+create-app+차트+fixtures+bats+example-api+문서) → `make verify`·`make chart-test`(web/worker/site 렌더)·`tsc`·gate GREEN → 머지 → ArgoCD example-api **no-op 싱크** 라이브 확인.
- **template**(별도 브랜치/PR): 새 구조·스캐폴더·아키타입·`template-ci.yaml` → CI로 4 아키타입 스캐폴드·빌드 검증.
- **E2E**(owner-local, 절차만): 머지 후 fullstack 아키타입으로 실제 앱 레포 생성 → `bun run scaffold` → push → owner가 homelab `create-app` → 배포 Healthy 확인.

## 13. 리스크·미해결

- **공유 차트 SSOT + 라이브 example-api** 동시 변경 — 같은 PR·원자적·기능 no-op이나 ArgoCD diff 발생(신중 검증). sync-wave 영향 없음(템플릿 로직만, 출력 동일).
- **외부 앱 config 미마이그레이션 시 fail-closed**(Phase A.5 high) — 외부 `.app-config.yml`이 구 `kind`를 내면 재검증 흐름이 깨질 수 있음. **§7.1로 완화**: 외부 앱 열거·same-window 마이그레이션·재검증 경로 식별·actionable 에러+테스트.
- **SWS scratch 이미지의 nonroot/readOnlyRootFs/arm64** 양립 — 계획에서 렌더+라이브 검증.
- **Bun `--compile` arm64 크로스빌드** + distroless/base(glibc) 호환 — 계획에서 실제 빌드·실행 검증.
- 아키타입 **4종 전부** 구현 — site는 기존 kind 재사용이라 경량. (게이트에서 3종 축소 가능했으나 4종 유지 확정.)
- `@clack/prompts` 추가 dep — 자가삭제로 최종 앱엔 미잔존.
- 템플릿↔homelab 스키마 원격 fetch 의존(template-ci) — homelab 스키마 경로/브랜치 변경 시 깨질 수 있음(계획에서 경로 핀·실패 메시지 명시).

## 14. 비범위 (YAGNI)

- `create-` npm 패키지 발행(모델 A/C 기각).
- 차트 기본 프로브 경로(`/health`) 변경.
- 멀티아키(amd64) 빌드 — homelab은 arm64 단일 노드.
- 아키타입 간 공유 모노레포 구조(각 아키타입은 독립 단일 패키지).
