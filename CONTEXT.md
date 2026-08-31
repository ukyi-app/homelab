# homelab

k3s 단일 노드 홈랩 GitOps 모노레포의 도메인 용어집. 구현 세부가 아니라 언어의
SSOT다 — 코드·문서·리뷰에서 아래 용어를 그대로 쓴다.

## Language

### 배포 핀 (deployment pin)

**배포 핀**:
클러스터에 배포될 컨테이너 이미지를 불변으로 고정하는 tag+digest 참조.
_Avoid_: 이미지 버전, 이미지 태그(단독 — tag만으로는 핀이 아니다)

**apps 레인**:
외부 앱 레포(`ukyi-app/*`)에서 빌드되는 앱의 배포 핀 레인. 핀이
`apps/<app>/deploy/prod/values.yaml`의 `image.tag`/`image.digest` 분리 키로
표현된다.
_Avoid_: 앱 경로, values 레인

**베스포크 레인**:
`platform/<comp>/prod` 베스포크 컴포넌트의 배포 핀 레인. 핀이 descriptor가
가리키는 manifest 속 인라인 핀 스칼라로 표현된다.
_Avoid_: 컴포넌트 레인, platform 레인

**인라인 핀 (inline pin)**:
`<repo>:<tag>@<digest>` 형태의 단일 스칼라 배포 핀 표기(베스포크 레인 전용).
_Avoid_: 이미지 문자열, 풀 레퍼런스

**descriptor**:
베스포크 레인에서 인라인 핀의 위치(대상 파일·YAML 경로)와 autoDeploy 승인
정책을 담는 `.image-pin.json` 파일.
_Avoid_: 핀 설정, 핀 메타데이터

**autoDeploy**:
새 이미지의 자동 배포 승인 플래그. 정확히 `true`일 때만 자동이고 false·누락·
파싱 불가는 전부 수동 승인(fail-closed) — apps 레인(`.bindings.json`)과
베스포크 레인(descriptor)이 같은 해석을 공유한다.
_Avoid_: 자동 머지 플래그

**bump 계획 (bump plan)**:
배포 핀 갱신 한 사이클의 계약 산출물(apps 레인·베스포크 레인 공통) — 판별 union
plan 항목(Change/Noop/Refusal)·target 신원(kind: app|bespoke)·레인(`bump`/`propose-pr`)·
브랜치/커밋 문구/writer 신원 명명 규약. 계약은 `tools/lib/bump-plan.ts`가 소유하고
생산자(poll-ghcr)와 소비자(run-bump-plan·ensure-bump-pr)가 공유한다. target 신원은
프로세스 경계를 관통한다: 브랜치가 kind를 인코딩하고(`bump-poll/<kind>/<name>-<tag>`,
구형 무한정 이름은 app 해석 — 동명 bespoke 실재 시 fail-closed), CLI는 `--kind/--name`
쌍으로만 신원을 받는다.
_Avoid_: 폴링 결과, 갱신 목록

### 가드 (guards)

**가드 커널 (guard kernel)**:
가드 한 번의 실행이 반드시 지나는 순서 — 열거 → 바닥값 판정 → SCAN 방출 → 검사 →
종료코드 — 를 소유하는 골격. 셸 adapter는 `scripts/lib/scan-floor.sh`(+`guard.sh`),
TS adapter는 `tools/lib/scan-floor.ts`의 `guardMain`.
_Avoid_: 가드 프레임워크, 공용 가드 유틸

**정책 원장 (policy ledger)**:
`policy/` 아래 기계가 읽는 가드 정책 파일. 리더 `tools/lib/policy-ledger.ts`는
fail-closed 로딩·컨테이너 shape·항목 검증**만** 소유하고, 미선언/죽은-선언 양방향
대조는 **각 가드 콜사이트가 소유**한다(대조 의미론이 소비자마다 다르다 — 공통
interface는 공통형이 실증될 때).
_Avoid_: 설정 파일, allowlist(단독 — 원장의 한 형태일 뿐이다)

**판정 어휘 (verdict vocabulary)**:
발화 e2e 하네스의 `fault`/`contract`/`fail`/`pass` 4함수. `(preflight)` 라벨과 로컬 집계는
하네스-로컬 정책이라 공용 lib으로 올리지 않는다 — 그 라벨이 진단의 절반이다.
_Avoid_: 에러 헬퍼

### 봉인 계약 (sealed contract)

**봉인 계약**:
SealedSecret이 앱 배포에 편입되기 위해 만족해야 하는 규약 — `kind: SealedSecret` ·
`namespace: prod` · `name: <app>-secrets` · `encryptedData` 비었음 금지 · 키 UPPER_SNAKE ·
**strict scope**(아래). 커널 `tools/lib/sealed-contract.ts`의 `readSealed`가 판정·문구·checksum·
바이트를 소유한다.
_Avoid_: 시크릿 검증, sealed 스키마

**strict scope**:
봉인본이 **그 이름·그 네임스페이스에서만** 복호화된다는 성질. kubeseal 기본값이며,
`sealedsecrets.bitnami.com/namespace-wide`·`cluster-wide` 어노테이션이 이를 넓힌다 — 봉인 계약은
그 어노테이션(truthy)을 **거부**한다(`readSealed` 6번째 조항 + `check-app-deploy.sh` 게이트, 두 adapter).
`namespace: prod` 등호는 strict scope를 함의하지 않는다(등호만으론 scope 확대 어노테이션을 못 잡는다 —
design-r1 R-2). patch(`sealedsecrets.bitnami.com/patch`)는 scope가 아니라 통과.
_Avoid_: prod 스코프, 네임스페이스 검증

**봉인 원본 바이트**:
디스크에 기록되고 checksum이 계산되는 바로 그 바이트. 커널이 `checksum`과 함께 한 값으로
내어 "해시한 것 ≠ 디스크에 쓴 것"이 구조적으로 불가능하다(#299 클래스 소멸).
_Avoid_: 봉인본 내용

**checksum/secrets**:
선언적 회전 트리거 pod annotation = `sha256(봉인 원본 바이트)` 앞 16자. 봉인본이 갱신되면
이 값이 바뀌어 ArgoCD가 Deployment를 롤링한다(envFrom 변경은 재시작 필요라 선언적으로).
_Avoid_: 시크릿 해시

**배선 (wiring)**:
봉인본을 `values.envFrom`(secretRef `<app>-secrets`)과 `kustomization.resources`가 참조하게
만드는 것. `check-app-deploy.sh`가 all-or-none 불변식으로 부분 상태를 fail-closed로 막는다.
_Avoid_: 연결, 등록

### 앱 플랫폼 조작 (app platform operations)

**변이 디스패처 (mutation dispatcher)**:
owner 전용 workflow_dispatch 진입점 워크플로. actor 가드·계약표 검증을 통과한 변이를
reusable 워크플로에 위임해 결과를 PR로 낸다. 전역 직렬화 그룹(homelab-mutation)에 속한다.
_Avoid_: 변이 워크플로(reusable과 구분 안 됨), 수동 트리거

**앱 표면 (app surface)**:
앱 하나가 이 레포에 남기는 배포 파일 집합(values·bindings·봉인본·kustomization·
source-repo·activation 마커 등). create가 쓰는 집합과 teardown이 지우는 집합은 같아야
하며, `tools/lib/app-surface.ts`가 그 집합과 경로 구성을 선언한다.
_Avoid_: 앱 디렉토리, 배포 파일들

**아키타입 (archetype)**:
앱 템플릿 스캐폴더가 생성하는 앱의 형태 — fullstack / api / site / worker.
kind(web/worker/site)는 아키타입에서 유도되는 파생값이다(fullstack·api→web).
_Avoid_: 앱 종류(kind와 혼동), 템플릿 타입

**레인 신원 (lane identity)**:
변이 디스패처 한 레인을 식별하는 규약 묶음 — 디스패치 입력 이름 · PR 브랜치 문법 ·
수렴 Application 집합 · 표면 경로. 생성하는 쪽(디스패치)과 파싱하는 쪽(관측)이
같은 신원을 공유해야 레인이 성립한다.
_Avoid_: 브랜치 규약(신원의 한 조각만 가리킴), 레인 설정

**산출물 레이아웃 (artifact layout)**:
리소스 종류와 이름에서 결정되는 산출물 집합의 명명·배치 — 파일 경로 ·
kustomization 엔트리 · conn 핸들 · env 키 · 원장 행 · tombstone 키, 그리고 각
항목의 처분 범위(purge-제거 / 공유-잔존 / 수동-이연). 생성·철거·감사·관측이
같은 레이아웃을 읽는다.
_Avoid_: 파일 목록, 명명 규칙(처분 범위가 빠진 부분 개념)

**canonical 클론**:
origin이 정확히 canonical 앱 레포(`ukyi-app/<app>`)를 가리키는 로컬 클론.
마커 기록·push·디스패치 같은 앱 동사가 오귀속 없이 작동하기 위한 전제 판정이다.
_Avoid_: 우리 레포, 앱 클론(판정 없는 서술)

### 가드 규약 (guard contract)

**스캔 신호 (scan signal)**:
가드가 자기 도메인을 몇 건 평가했는지 알리는 `SCAN: <라벨>: <n>` 마커. 가드가 CI에서
**도는 사실**과 그 호출이 **실제 도메인에 닿은 사실**을 가르는 유일한 기계 입력이며,
`SKIP:`(도메인이 정당하게 없어 평가하지 않음)과 배타 채널이다.
_Avoid_: 스캔 마커, 실행 로그

**열거 바닥값 (enumeration floor)**:
열거가 붕괴해 0건을 검사하고도 초록이 되는 것을 막는 하한. **수치는 커널이 아니라
콜사이트가 소유한다** — "글롭이 깨져 0건"과 "정당하게 0건"을 가르는 도메인 지식은
콜사이트에만 있다.
_Avoid_: 최소 스캔 수, 래칫(바닥값은 도메인이 줄지 않는 한 손대지 않는다)

**가드 adapter**:
한 가드 규약을 특정 실행 환경에서 만족시키는 구현. 셸(`scripts/lib/scan-floor.sh`)과
TypeScript(`tools/lib/scan-floor.ts`)가 같은 스캔 신호 규약의 두 adapter다.
_Avoid_: 레인(배포 핀 도메인 전용 — apps 레인·베스포크 레인과 충돌한다)

**코드 표면 (code surface)**:
가드 검출기가 "무엇이 코드 줄인가"를 판정하는 규칙 집합 — 파일 경계 리셋 순서 · 행두/블록/꼬리
주석 표기 · heredoc 상태 기계 · 표면 종류(sh/bats/make/ts/yaml). awk는 규칙을 적힌 **순서로**
평가하므로 이 규칙들의 순서가 곧 판정이고, 틀리면 red가 아니라 침묵이다. 판정은 각 검출기가
소유하고, 관용구가 형제 사이에서 갈라지지 않는지는 형태 대조 게이트가 강제한다(문구는 바꿔 쓸 수
있지만 awk 토큰은 못 바꾼다).
_Avoid_: 파서, 전처리기(실제보다 넓다 — 표면은 줄을 코드/비코드로 가르기만 한다)

**표면 붕괴 (surface collapse)**:
미종료 heredoc이나 미종료 블록 주석 때문에 파일의 그 지점 이후가 검출기에게 통째로 투명해진 상태.
**열거 붕괴와 다른 축이다** — 파일은 정상적으로 열렸으므로 `READFILES`도 스캔 신호도 정상값을 낸다.
파일 수 축 회계로는 원리적으로 관측할 수 없다(`docs/traps-detail.md:1500`).
_Avoid_: 열거 붕괴(파일 수 축), 오탐·미탐(붕괴는 판정이 아니라 판정 불가다)

**가드 스코프 (guard scope)**:
한 가드 실행이 **실 트리 전체를 보는가, 호출자가 좁힌 대상을 보는가**라는 실행 단위 1비트.
좁히는 방법은 둘 — 파일 인자를 주거나, `--root <dir>`로 픽스처 트리를 지목하거나.
바닥값 면제 말고도 소비자가 있다(`check-argocd-revision`의 `[fixture]` 문구).
_Avoid_: 레인(배포 핀 도메인 전용), 픽스처 모드(호출자 관점만 담아 파일 인자 모드를 빠뜨린다)

**바닥값 면제 (floor exemption)**:
가드 스코프가 좁혀졌을 때 열거 바닥값을 적용하지 않고 스캔 신호만 내는 정책. **라벨 단위**이며
한 실행이 면제 라벨과 비면제 라벨을 함께 낼 수 있다. `--floor <라벨>=<n>` 명시는 면제를
**되살린다** — 명시 플래그가 조용한 no-op이 되면 안 되기 때문이다.
_Avoid_: 픽스처 예외(면제는 파일 인자 모드에도 걸린다), 바닥값 끄기(끄는 것이 아니라 신호로 갈아타는
것이다 — 마커는 반드시 나간다)

**가드 진입 경계 (guard entry boundary)**:
가드 파일에서 부작용(플래그 파싱·원장 읽기·열거·`guardMain`·종료)이 사는 유일한 자리 —
`if (import.meta.main) { … }`. 그 밖의 최상위는 선언과 export뿐이라, 가드를 import해도 실행되지 않고
순수 판정만 꺼내 쓸 수 있다. 착지: `tools/check-workflow-readiness.ts:593` ·
`tools/check-image-ownership.ts:363` · `tools/check-guard-authority.ts`.
_Avoid_: main 함수, 엔트리포인트(「권위 있는 실행 경로」와 혼동된다)

**린트 컨텍스트 (lint context)**:
가드의 순수 판정 함수가 파일시스템 없이 돌기 위해 필요한 정책 **사실**의 읽기 전용 묶음.
원장 파일 자체가 아니라 원장에서 읽어낸 값이고, **바닥값 수치와 대조 의미론은 담지 않는다** —
그 둘은 콜사이트가 소유한다(「열거 바닥값」·「정책 원장」). 테스트는 리터럴 컨텍스트로 판정을 직접 부른다.
_Avoid_: 설정 객체, 옵션 백, 원장(원장은 `policy/` 아래의 파일이다 — 컨텍스트는 그 파일에서 나온 값이다)

### 설계 진단 (design diagnosis)

**처방 도달 (prescription reach)**:
한 자리에서 **실증된 처방**이 같은 클래스의 인접 표면에 닿았는지를 가리키는 성질. 진단은
"중복이 있다"가 아니라 **"형제 자리에 이미 있는 처방이 여기엔 없다"**이며, 그래서 근거는
처방의 실증 이력과 형제의 실재이지 유사성이 아니다. 도달 실패는 조용하다 — 처방을 받은
자리가 초록이므로 회계가 정상값을 낸다. **셋이 다 서야 후보다**: ① 처방이 어딘가에서
실증됐다(라이브 사고·재현·명시 결정 중 하나로) · ② 형제 표면이 **같은 실패에 노출**돼 있다 ·
③ 그 비대칭에 **근거가 적혀 있지 않다**. 세 조건이 없으면 다음 리뷰가 이 용어를 "비슷한 코드를
합치자"로 오독한다 — ADR 0003·0004·0005가 기각한 축은 전부 중복은 실재하나 ①이 서지 않은
자리였다. 이 용어 자체가 두 번 실증된 뒤에 승격됐다(`tests/gates/lib/host-port.sh` ·
`tests/gates/lib/heredoc-marker.sh`의 헤더가 같은 명제를 각자 산문으로 다시 논증한다).
_Avoid_: 중복 제거, DRY(중복이 문제가 아니라 처방이 닿지 않은 것이 문제다), 리팩터링,
공통화(처방을 **옮기는** 것이지 코드를 모으는 것이 아니다)
