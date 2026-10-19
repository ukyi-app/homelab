# homelab

NUC 한 대에서 도는 k3s 홈랩의 원본 저장소다. Git이 원본이고, Argo CD가 main을 클러스터에 맞춘다.
클러스터는 손으로 바꾸지 않는다. main은 PR과 필수 검사 `ci`를 거쳐서만 바뀐다.

## 문서

- 문서 지도: [docs/plans/2026-10-17-homelab-rebuild/README.md](docs/plans/2026-10-17-homelab-rebuild/README.md). 무엇이 어디 있고 어떤 순서로 읽는지.
- 계획 명세: [docs/plans/2026-10-17-homelab-rebuild/spec.md](docs/plans/2026-10-17-homelab-rebuild/spec.md). 결정, 인수 조건, 티켓 목록.
- 플랫폼 설계: [docs/plans/2026-10-17-homelab-rebuild/platform/design.md](docs/plans/2026-10-17-homelab-rebuild/platform/design.md). 저장소 배치는 C.1, 누가 무엇을 바꾸는지는 C.2.
- 에이전트 작업 규칙: [AGENTS.md](AGENTS.md).

## 도구

버전은 `.tool-versions` 한 곳에 있다. `mise install`로 맞춘다.
커밋 전 검사는 `pre-commit run --all-files`(매 커밋마다 돌리려면 `pre-commit install`). CI가 보는 것은 `.github/workflows/ci.yaml`에 있다.
