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
