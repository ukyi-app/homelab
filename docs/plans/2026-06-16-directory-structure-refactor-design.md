# 디렉토리 구조 정합화 — 설계

- **날짜**: 2026-06-16
- **상태**: 승인됨 (brainstorming → hardened-planning Phase A 산출물)
- **범위**: 홈랩 GitOps 모노레포 전 영역의 디렉토리 구조·테스트 조직·네이밍 정합화
- **후속**: 이 설계 → `writing-plans`로 bite-sized TDD 플랜 전개 → codex adversarial review

---

## 1. 동기 & 근거

9-에이전트 구조 감사(5 영역 측량 + 4 차원 비평, `dirstructure-audit` workflow)가 HIGH 4 / MEDIUM ~12 /
LOW ~15을 6개 테마로 확인했다. 핵심 통증은 **위치가 아니라 메커니즘·규약·발견성**에 있다:

1. **테스트 조직** — 테스트가 8~17곳 산재, `test/`(단수)·`tests/`(복수)·`_test/` 4중 분열,
   `find platform -name test_*.bats` 글롭이 **load-bearing**(접두 누락 시 조용히 게이트 밖),
   CI 수집이 Makefile+ci.yaml에 6글롭 손-미러(이중 SSOT, `make-ci-parity.bats`가 목발),
   `infra/k3s-bootstrap/test/`(11)·`tests/posture/`가 **어떤 CI에도 미배선(죽은 커버리지)**.
2. **platform 레이아웃** — victoria-stack만 `<comp>/prod/` 규약 위반(20+ manifest가 컴포넌트 루트에
   flat, `prod/`엔 잔재 1파일), 수동 Application `source.path` 불일치.
3. **scripts/ ↔ tools/ 경계** — 분리 기준이 '관심사'가 아닌 '언어'(.sh/.mjs), AGENTS.md 지도에
   `scripts/` 행 자체가 없음.
4. **발견성** — platform 12 + infra 6 컴포넌트 README 0(기존 SYNC-WAVES.md·NOTES.md도 미링크),
   `docs/runbooks/` 전체 gitignored인데 README/CONTRIBUTING이 ~15회 위임 → fresh clone 온보딩 0단계부터
   깨진 링크, README/AGENTS 지도가 실제와 드리프트.
5. **apps/ 계약 위반** — `apps/pg-tools`는 deploy/prod 없는 빌드-전용 ops 이미지인데 "이 레포엔 배포
   설정만 둔다" 계약을 깨는 유일한 인-레포 예시. 게다가 `build.yaml`(인-레포 빌더) 전체가 `apps/`를
   "인-레포 빌드컨텍스트"로 전제하나 matrix 점유자는 pg-tools 하나뿐.
6. **네이밍 미세 불일치** — `.github` `.yml`(11)/`.yaml`(6) 혼용, SealedSecret `auth-sealed.yaml`
   outlier, reusable 워크플로 `_`/`reusable-` 2규칙, .mjs 셰뱅/exec 비트 불일치.

### 관통 제약 (설계의 척추)

**ArgoCD가 디렉토리 경로로 싱크한다** (`platform/*/prod`, `apps/*/deploy/prod`). 그래서:
- platform/apps 경로 변경은 고위험 → **render-parity 게이트**(이동 전/후 `kustomize build` 출력 동일)로 감싼다.
- 테스트/스크립트/문서는 ArgoCD가 안 보므로 이동해도 sync 무영향. **단** Makefile/CI 하드코딩 경로는 깨진다.
- **비대칭 위험**: 테스트 *재배치/리네임*은 victoria-stack과 달리 render로 검증이 안 돼, 글롭에서 누락되면
  **테스트가 안 돌고 → CI green → 아무도 모르는 조용한 커버리지 손실**을 낳는다. 이게 가장 위험한 실패 모드.

---

## 2. 확정된 결정 (forks)

| # | 결정 | 근거 |
|---|---|---|
| D1 | **전면 재구성** (victoria-stack 표준화 + 모든 HIGH/MEDIUM 구조 해소 포함, 라이브 sync 회귀 리스크 감수) | 사용자 선택 |
| D2 | 테스트 조직 = **명문화 + 디렉토리/파일-구동 단일 러너** + **`tests/gates/` 타깃 이동** | 통증이 메커니즘에 집중. 물리 대량이동의 조용한-손실 위험 회피하면서 규약·메커니즘 일관성 확보 |
| D3 | 테스트 네이밍 = **전 디렉토리·파일 단일 규약 rename** (D2 러너가 안전 전제) | 사용자 선택. 단복수·접두 분열 제거 |
| D4 | pg-tools = **`ops/pg-tools`로 이동** + `build.yaml` 경로 `apps`→`ops` 치환 (파일명 유지) | apps/(배포-전용)와 build.yaml(ops 빌더) 둘 다 정직화, platform/ ArgoCD-순수 유지 |
| D5 | W2(victoria-stack) 검증 = **render-parity + 라이브 sync(Healthy+Synced) 확인** | 단일 노드 라이브 클러스터 — 회귀를 구현 시점에 잡는다 |

### 테스트 네이밍 단일 규약 (D3 구체화)

- **모든 bats 파일 = `test_*.bats`** (예외 없음). 셀프-도큐멘팅 + 코로케이션 시 manifest와 시각 분리 +
  코로케이션·전용 디렉토리 통합.
- **전용 테스트 디렉토리 = 복수 `tests/`** (루트 `tests/`와 정합). `tools/test/`→`tools/tests/`,
  `infra/k3s-bootstrap/test/`→`infra/k3s-bootstrap/tests/`. `infra/_test/`는 underscore가 "infra 보조
  디렉토리(terraform 루트 아님)" 신호라 의미 유지 위해 `infra/_tests/`로 복수화(underscore 보존).
- **귀결(핵심 단순화)**: 수집이 `**/test_*.bats` 단일 글롭(− 데이터 기반 제외)으로 떨어진다 — 디렉토리
  열거·접두 분기·단복수 문제가 한 번에 소멸. 헬퍼(`test_helper.bash`)·픽스처(`fixtures/*.json`)는 글롭에
  자연 배제.
- **접두는 이제 '문서화 + 가드된' 규약**(현재의 '미문서·조용히 실패'와 대비). `test_` 안 붙은 `*.bats`가
  레포에 존재하면 verify가 실패하는 가드를 추가.

---

## 3. 워크스트림

> 각 워크스트림은 독립 PR(PR-first + auto-merge 규약). 각 변경은 TDD(가드/테스트 먼저).

### W0 — 단일 테스트 러너 (선행 필수, 中위험)
모든 테스트 변경의 안전 전제. 먼저 깔아야 W1/W3의 rename·이동이 누락 없이 안전해진다.
- `scripts/run-bats.sh` 신설: `**/test_*.bats`를 수집하고 **라이브/도커 의존 제외를 데이터 1곳**
  (`tests/.ci-exclude`, 사유 주석 포함)으로 관리. Makefile `ci`·`chart-test`와 `ci.yaml` gate가
  **동일 러너 호출** → `make ci` ≡ CI gate를 증명적으로 보장.
- `find platform -name test_*.bats` 등 **load-bearing 글롭 제거** → 파일-구동 수집으로 대체.
- **TDD/가드**: (a) 러너 수집집합 == 기존 6글롭 수집집합 단언(현 `make-ci-parity.bats`를 러너-동치 가드로
  대체), (b) 수집 목록 스냅샷 테스트(누락 가시화), (c) 죽은 커버리지(k3s-bootstrap offline, posture) 포함하도록 확장.

### W1 — 테스트 조직 정합 (中, W0 위에서만)
- **`tests/gates/` 타깃 이동**: `tools/test/`의 전역 정적 게이트 ~31개(ci-gate·dispatcher·workflow-yaml·
  telegram-*·manifest-guard 등) → `tests/gates/`. `tools/tests/`엔 `tools/*.mjs` 단위 테스트만 잔류 →
  '이름-의미 불일치' 해소.
- **D3 네이밍 rename 적용**: 전 디렉토리 `tests/` 복수화, 전 파일 `test_*.bats` 접두 통일.
  (러너가 파일-구동이라 안전; 정확한 rename 인벤토리는 Phase B에서 열거.)
- **죽은 커버리지 배선**: k3s-bootstrap offline 테스트를 `iac.yaml`(또는 ci) 글롭에 포함,
  `tests/posture/`용 `make verify-posture`(라이브 KUBECONFIG 가드형) 타깃 신설 + AGENTS.md 핵심명령 등재.
- **계층 정합**: `infra/_tests/`의 platform/argocd 검증 bats(argocd_values·root_app) → `platform/argocd/`로
  이동(렌더 무관, iac.yaml 경로 동기). `infra/_tests/`엔 진짜 infra(tf_validate·tf_reconcile)만.

### W2 — platform 레이아웃 표준화 (高, render-parity 게이트)
- **victoria-stack `flat → prod/`**: 20+ manifest + `kustomization.yaml` + `rules/` + `secret-generator`를
  `platform/victoria-stack/prod/`로 이동. `prod/alerting.enc.yaml` 흡수 → 상대참조 `./prod/` → `./` 단순화.
  `root/apps/victoria-stack.yaml`의 `source.path` `platform/victoria-stack`→`platform/victoria-stack/prod`.
  appset exclude 글롭(`platform/victoria-stack/*`)이 prod/ 포함하는지 재확인.
- **수동 Application source.path 통일**: 위 정착의 부수효과로 `root/apps/*`가 모두 `platform/<comp>/prod`로 수렴.
- **enc.yaml 주의**: SOPS MAC은 경로 무관(내용+메타데이터)이라 **`git mv`(내용 무변경)만** — `*.enc.yaml`
  직접 수정 금지 규약 준수.
- **안전망(D5)**: 이동 전/후 `kustomize build --enable-helm --enable-alpha-plugins --enable-exec` 출력
  **정렬 후 바이트 동일**(render-parity) 단언 → 그 뒤 라이브 `KUBECONFIG`로 victoria-stack Application
  **Healthy + Synced** 확인.

### W3 — apps/ 계약 정합 (中)
- **pg-tools → `ops/pg-tools`** (D4): `git mv apps/pg-tools ops/pg-tools`. `build.yaml` 경로 치환
  (트리거 `apps/**`→`ops/**`, `context: apps/${app}`→`ops/${app}`, 필터 `^apps/${APP}/`→`^ops/${APP}/`),
  `tools/tests/test_pg_tools.bats`·`test_ci_build.bats` 경로/단언, appset L60 주석, Dockerfile/README/
  ledger 주석 갱신. CronJob 이미지 **태그** 참조는 경로 무관 → 무변경. build.yaml **파일명 유지**(bump.yaml
  `workflow_run` 리스크 회피).
- **deploy/prod 계약 SSOT**: `tools/app-deploy-schema.json` 신설(현재 계약이 create-app.mjs에 암묵) +
  verify 게이트(현 check-skeleton는 디렉토리 존재만 검사).
- **문서**: `apps/README.md`('배포-전용 앱 = deploy/prod 보유, 인-레포 빌드 ops 이미지는 ops/'),
  `ops/pg-tools/README.md` 정체성 명시.

### W4 — 발견성 (低, 순수 가산·고가치)
- **컴포넌트 README**: platform 12 + infra 6에 5~10줄 README(역할 / 싱크 Application·sync-wave / 라이브
  디버그 스킬·런북 / 함정 SSOT AGENTS.md 줄). 기존 `SYNC-WAVES.md`·`NOTES.md`를 상대링크로 끌어올림.
- **지도 드리프트 수정**: README/AGENTS 디렉토리 표에서 'edge'를 실제 디렉토리(adguard·cloudflared·
  tailscale)로 풀고, cache·data-conn·sealed-secrets·namespaces 추가. `check-skeleton.sh`에 "platform 하위
  디렉토리 = 지도에 등장" 단언 추가(drift fail-closed).
- **runbook 깨진 링크**: gitignored 유지하되 (a) 추적되는 toolchain 최소 공개본(설치 도구·핀 버전)으로
  온보딩 0단계 자기완결화 + (b) 각 런북 추적 스텁(`<제목> — 로컬 전용, owner 보유. 공개 요약: …`) 또는
  README/CONTRIBUTING에 'runbooks gitignored' 경고.
- **인덱스**: `tools/README.md`·`scripts/README.md`에 스크립트별 1줄 표(직접실행 vs 워크플로전용 / 호출
  make타깃·reusable / 입력 계약; `app-config-schema.json` vs `homelab-app-schema.json` 구분).

### W5 — scripts/ ↔ tools/ 경계 명문화 (低)
- AGENTS.md 디렉토리 지도에 **`scripts/` 행 추가** + 경계 규칙: `tools/`=앱플랫폼 DX(Node CLI,
  create-app/provision/poll-ghcr/activate), `scripts/`=클러스터/DR 운영 셸(bootstrap/dr-drill/seed-secrets/
  reset-pg). 현 배치 유지(이동 X — 우연히 합리적인 배치를 규칙으로 박제).
- `infra/k3s-bootstrap/*.sh`(substrate) vs `scripts/*.sh`(cluster-up 이후 운영) 경계 1줄 명문화.

### W6 — 네이밍 미세 정합 (低, 일괄)
- `.github/workflows` `.yml`→`.yaml` 통일(레포 표준 .yaml). **예외**: `reusable-app-build.yaml`=cross-repo
  공개 계약(이미 .yaml, 불변). `_*` 워크플로 rename 시 `dispatch-mutation.yml`의 `uses:` 내부참조 동기 수정.
- SealedSecret `platform/adguard/prod/auth-sealed.yaml` → `adguard-auth.sealed.yaml`(`*.sealed.yaml` 글롭
  정합). kustomization·`seal-adguard-auth.sh`·test 경로 동기.
- `.mjs` 셰뱅/exec 비트 정책 통일(항상 `node` 호출 → 셰뱅 제거, 또는 +x). `sealing-key-dr-gate.sh` +x 정합.
- `_*` reusable(내부) vs `reusable-`(cross-repo) 규약, schema 네이밍(`*-schema.json` vs `values.schema.json`
  =Helm 고정) **문서화**.

### W7 — CI 게이트 중복 정리 (低)
- 메모리 원장 게이트가 `ci.yaml`(required `gate`)·`verify.yml`(비필수) 양쪽 중복 실행 → 역할 분리(권위
  게이트는 ci.yaml 한 곳, verify.yml은 고유 책임으로 좁힘) + 어느 워크플로가 무엇을 권위 게이트하는지 1줄 주석.
- (W0 단일 러너가 Makefile↔ci.yaml 6글롭 미러 중복을 구조적으로 해소.)

---

## 4. 시퀀싱 & 의존

```
W0 (러너)  ─────►  W1 (테스트 이동·rename)        # 러너 먼저 = 누락 0 (안전 전제)
W2 (victoria-stack)  ── 독립 전용 PR             # 최고위험 격리, render-parity + 라이브 게이트
W3 · W4 · W5 · W6 · W7  ── 병렬 가능             # 대부분 저위험/문서 가산
```
- **W0 → W1**은 엄격한 순서(러너가 없으면 rename이 조용한 손실 위험).
- **W2**는 위험 성격이 달라(시끄럽게 실패) 전용 PR로 격리, render-parity가 1차 게이트.
- W3~W7은 서로 독립 — 발견성(W4)은 위험 0이라 먼저 머지해도 무방.

## 5. 검증 모델
- **오프라인(전 워크스트림)**: `make verify` + `make chart-test` + 단일 러너 전체 green. 경로 변경 워크스트림은
  `kustomize build` **render-parity**(정렬 후 동일) 추가.
- **라이브(W2 한정, D5)**: `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` →
  victoria-stack Application `Healthy + Synced` 확인. 회귀 시 즉시 롤백(전용 PR이라 격리).

## 6. 명시적 제외 (감사가 '의도적/고정'으로 판정 — 건드리지 않음)
- **cnpg 3-peer**(`operator/`·`barman-plugin/`·`prod/`) = 역할 분리(Helm/벤더/데이터플레인), 통합 X.
- **`values.schema.json`** = Helm 차트 install 자동 검증 고정 파일명, rename 금지.
- **`reusable-app-build.yaml`** = 외부 앱 레포 cross-repo 계약, rename 금지.
- **namespace SSOT 분산**(cnpg·victoria-stack 자체 namespace.yaml) = appset `destination.namespace` 부재
  함정 회피 — 본 리팩터에서 일원화 보류(별도 검토).
- **공유 bats 헬퍼 통합** = 코로케이션 상대 load 경로 깊이차로 일괄 적용 불가, 대량 diff 위험 → P3,
  신규만 점진(본 리팩터 제외).
- **edge 3종 디렉토리 그룹화** = appset `platform/*/prod` 고정 depth 글롭을 깨므로 보류(문서로 도메인 표현).

## 7. Phase B(writing-plans)로 넘길 정밀화 항목
- 각 이동/리네임의 **정확한 참조 인벤토리**(파일:라인) — Makefile·ci.yaml·iac.yaml·verify.yml·bats·
  kustomization·appset. (전용 enumeration workflow로 grep 후 bite-sized 스텝화.)
- victoria-stack 이동의 kustomization `resources:` 상대경로 22개 + `rules/` + secret-generator 정확 매핑.
- 전 bats 파일의 현재 접두 유무 → `test_*.bats` rename 인벤토리.
- `tests/.ci-exclude` 초기 목록(라이브/도커 의존 파일 식별).
