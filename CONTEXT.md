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
