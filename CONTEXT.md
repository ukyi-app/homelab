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
