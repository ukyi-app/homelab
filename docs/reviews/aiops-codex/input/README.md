# AIOps 구현 전 리뷰 입력

이 사본은 로컬 `.scratch/aiops-codex/` 계획을 적대적 리뷰할 수 있도록 고정한 입력이다.
요구는 [spec.md](spec.md), 동작은 [design.md](design.md), 작업 순서는
[implementation.md](implementation.md), 근거는 [research.md](research.md)에 있다.

`source-manifest.json`에 원본과 리뷰 사본의 SHA-256을 기록했다. 본문은 유지하고, homelab
절대 파일 링크를 frozen repo 기준 상대 경로로 바꿨다. Polyrelay 조사 링크는
[후속 연결 범위](deferred-polyrelay.md)로 연결했다. Polyrelay 자체 구현은 리뷰 대상이 아니다.

리뷰는 이 사본과 frozen repository만 읽는다. 원본 `.scratch`, 개인 홈, 시크릿, 운영 클러스터,
외부 Polyrelay 작업트리는 조회하지 않는다. 파일 수정이나 실제 실행·송신도 수행하지 않는다.
아직 구현 전이므로 구현의 부재를 버그로 보고하지 말고, 이 계획을 따라 구현할 때 생길
구체적인 장애·권한 문제·검증 누락을 본문의 위치에 근거해 보고한다.

사용자는 `codex exec`로 파일럿을 먼저 진행하고 Polyrelay는 후속 연결하기로 결정했다.
이번 요청은 최종 구현 착수 전에 계획을 적대적으로 검토하는 것이다.
