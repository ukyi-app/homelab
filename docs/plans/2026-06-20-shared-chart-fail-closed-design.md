# 공유 차트 fail-closed 하드닝 (테마2 / plan 2)

> 2026-06-19 심층 검토(10차원 적대 감사) 8테마 로드맵 중 **2번째 plan**. [[테마1=ArgoCD 권한경계]] 후속.
> 대상=`platform/charts/app`(모든 앱이 쓰는 SSOT 차트). 후속=테마3~8.

## 문제 (감사 발견)

전-앱 SSOT 차트인데 정작 **fail-open**이라, 오타·escape hatch 1건의 폭발 반경이 N앱에 퍼진다.

1. **extraManifests 무검증 백도어** — `deployment.yaml:93-98`의 `range .Values.extraManifests`가 toYaml로
   임의 객체를 방출하고 schema에 항목 자체가 없다. privileged/hostPID Pod까지 그대로 렌더 → 차트의
   restricted-PSA 하드닝 SSOT를 전면 우회(라이브 검증). "의식적 리뷰 게이트(§13)"라 표방하나 실제는 백도어.
2. **schema fail-open** — `values.schema.json`에 `additionalProperties:false`가 없어 `securtyContext`·`prooobes`
   같은 보안키 오타가 침묵 무시→기본값으로 조용히 뜬다. env·envFrom·probes·ports·securityContext·
   podSecurityContext·metrics·extraManifests·imagePullSecrets·nameOverride 등이 schema에 **아예 미등재**(절반).
3. **caddy 미구현 + static 프로브 깨짐** — `static.server` enum에 `caddy`가 있으나 `deployment.yaml:41-46`은
   `sws`에서만 args 방출 → caddy면 설정 없이 깨진 서버 배포. 또 `app.isServed`(=service+static)라 static이
   httpGet `/healthz`·`/readyz`(서비스용 기본)로 프로브되는데 SWS는 `--health`로 `/health`만 → 영구 NotReady.
4. **worker 가짜 포트/metrics** — `deployment.yaml:47-49`가 http(8080)를 항상 방출하고 `:19-23`이 worker에도
   `prometheus.io/scrape`+metrics(9090) annotation을 단다. worker는 Service도 HTTPRoute도 없고 /metrics를
   서빙 안 하는데 vmagent가 긁어 up=0 가짜실패 + netpol 8080 표면 확대.
5. **/bin/true·/bin/sleep 의존** — worker liveness `exec:[/bin/true]`(`:76`), 전 kind preStop
   `exec:[/bin/sleep,N]`(`:82`)가 셸/coreutils 바이너리 존재를 가정. distroless(Rust static-musl/scratch)면
   worker liveness 영구 CrashLoop·preStop 무효 — 차트가 표방하는 'polyglot' 보편성과 정면 충돌.
6. **(갭) SA 토큰 자동마운트** — pod spec에 `automountServiceAccountToken` 미설정(default true) → 차트가
   RBAC를 0 부여하는데도 모든 앱 파드가 `default` SA 토큰을 자동마운트(컴프로마이즈 시 API 표면).
7. **(갭) Deployment strategy 미지정** — default RollingUpdate(maxUnavailable 25%). 단일노드 + RWO PVC 앱이면
   두 파드가 ReadWriteOnce 볼륨을 동시에 못 잡아 롤아웃 교착(adguard만 `Recreate`로 회피, 차트엔 미반영).

## 제약

기존 기능·동작 비파괴. **차트는 N배 증폭기**라 회귀가 전 앱에 퍼진다. ★최대 동작파괴 위험=②
`additionalProperties:false`(현 values 키 전수등재 누락 시 기존앱 reject). **인레포 앱 0개라 라이브
워크로드가 차트를 전혀 사용 안 함** → 순수 chart-test 정적 검증, **라이브 위험 0, 단일 PR**.

## 설계

### 그룹 1 — 스키마 fail-closed (최대 동작파괴 위험)

- **② additionalProperties:false**를 **최상위 + 구조적 object**(image·route·db·homepage·probes·static·ports·
  metrics·gateway)에 추가. **k8s passthrough(podSecurityContext·securityContext·resources)는 제외** — 임의
  유효 k8s 필드 오버라이드를 허용해야 하므로(좁히면 정상 사용이 reject).
- **전 top키 전수등재**: 현재 미등재 `imagePullSecrets·env·envFrom·probes·podSecurityContext·securityContext·
  terminationGracePeriodSeconds·preStopSleepSeconds·ports·metrics·nameOverride` + 신규 `strategy·
  automountServiceAccountToken·livenessProbe`를 properties에 등재.
- **① extraManifests 제거**: values.yaml·deployment.yaml(range 블록)·schema 전부에서 삭제. 추가 매니페스트는
  appset source#3(`apps/<name>/deploy/prod` kustomization)로 — SealedSecret이 이미 그 경로다. ⚠️ **정직하게**:
  테마2 성과는 escape hatch "닫음"이 아니라 **차트가 무검증 toYaml로 임의 객체를 방출하던 백도어를 차트에서
  제거**(fail-closed)한 것이다. source#3 자체의 kind 경계(임의 kind 차단)는 [[테마1]] apps AppProject
  namespaceResourceWhitelist가 머지된 뒤에야 적용된다(현 origin/main은 project:default라 미적용); PSA는 Pod에만.
  extraManifests를 남기면 additionalProperties:false가 reject하므로 제거가 정합.
- **동작보존 핵심**: 3 fixture(service/static/worker)가 쓰는 키를 전수 커버해야 reject 0. 0앱 환경에선
  fixture가 키 SSOT다. 회귀: 미지 top키 1개라도 주면 거부 + 3 fixture 전부 통과.

### 그룹 2 — 워크로드 정합성

- **③ caddy 제거 + static 프로브**: `static.server` enum을 `sws` 단일로(미구현 caddy 제거, YAGNI). kind=static의
  liveness/readiness httpGet path를 SWS 실제 경로 `/health`로 분기(현 served-default `/healthz`·`/readyz` 재사용
  제거). fixture `static.yaml` 프로브가 실제 통과하는 경로 고정.
- **④ worker 포트/metrics 정합**: `http` containerPort를 **isServed 가드** 안으로(worker는 8080 미방출 →
  netpol intra-prod 8080 표면 축소). metrics 포트 + `prometheus.io/scrape` annotation을 **`metrics.enabled AND
  isServed`**로(worker 가짜 metrics 제거 — up=0 노이즈 제거). worker가 진짜 metrics를 서빙하는 케이스는 후속
  (YAGNI, 현재 0앱).
- **⑤ liveness·preStop 바이너리 독립**: `livenessProbe: {}` raw override 값 추가 — 설정 시 그 spec을
  liveness로(worker/served 공통), 미설정 시 현 기본(served=httpGet, worker=exec /bin/true). `preStopSleepSeconds:
  0`이면 preStop 블록 자체를 생략(distroless 앱은 0 + terminationGracePeriod+readiness drain). 기본값 불변
  (동작보존). distroless 가이드 주석.

### 그룹 3 — 방어 갭

- **⑥ SA 토큰**: pod spec에 `automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}`. 기본
  **false**(앱은 차트가 RBAC 0 부여라 k8s API 불요). API 쓰는 앱만 values로 opt-in true. 회귀: 기본 토큰
  미마운트, opt-in true면 마운트.
- **⑦ strategy**: `strategy` 값 추가, 기본 **`Recreate`**(단일노드 RWO 교착 회피, adguard 패턴) / 멀티레플리카
  stateless는 `{type: RollingUpdate}` opt-in. ⚠️ k8s 기본(RollingUpdate)에서 바뀌는 유일한 **동작 default
  변경** — 단일레플리카 배포 시 짧은 다운타임 생기나 홈랩 허용 + RWO 안전 우선. 0앱이라 무영향.

## 테스트·검증 (chart-test, CI-safe)

- `tests/render.sh` + 3 fixture(service/worker/static) `kustomize`/helm 렌더 + kubeconform.
- 신규 bats 회귀: 미지 top키 거부 · extraManifests 부재(템플릿/스키마) · caddy enum 부재 · static 프로브
  `/health` · worker http/metrics 포트·scrape annotation 부재 · service는 metrics 유지 · SA토큰 기본 false ·
  strategy 기본 Recreate · livenessProbe override 동작 · preStopSleepSeconds:0이면 preStop 생략.
- 기존 7 bats(test_deployment/route/migrate/schema/image-digest/db-consume/wave0) **전부 통과 유지**.

## 동작 비파괴·롤백

- ①extraManifests 제거·④worker포트·③caddy는 0앱이라 무영향(라이브 미사용). ②schema는 fixture 전수통과로
  보장. ⑤liveness/preStop·⑥SA토큰은 기본값 불변 또는 0앱 무영향.
- ⑦strategy만 default 변경(Recreate) — 0앱이라 라이브 무영향, 향후 앱은 명시 opt-in 가능.
- 단일 PR이라 롤백=revert 1회. 차트 변경은 라이브 워크로드 0이라 즉시 가역.

## 범위 밖 (후속 plan)

테마3(tools CLI lib SSOT)~8. 테마2 내에서도 worker 진짜 metrics opt-in·caddy 재도입은 필요 시 후속.
