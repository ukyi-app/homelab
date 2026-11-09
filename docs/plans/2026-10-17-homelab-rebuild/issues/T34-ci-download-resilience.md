# T34 CI 도구 내려받기의 GitHub 장애 내성

- 단계: P2 후속 (T21·T32 배포 중 관측)
- 상태: 완료 (2026-11-09. homelab #1206 `90e5e10`, main 범위 캐시 생성 확인)
- 명세: [../spec.md](../spec.md)
- Blocked by: T10
- 연결 AC: AC-P7 (배포 PR의 필수 검사 `ci`)
- 수행: 에이전트 (조사·구현은 Claude 작업자, 검토는 lead, 병합은 사람 확인)

## 목표

필수 검사 `ci`의 "Install pinned tools" 단계는 도구 열 개를 `curl -fsSL --retry 3`으로 익명 내려받는다(대부분 `github.com/.../releases/download`). 2026-11-09 GitHub 장애("Increased timeouts due to surge in anonymous users")에서 이 단계가 504로 세 번 실패해, 봇 배포 PR(homelab #1201)과 문서 PR(#1203)이 다운로드가 회복될 때까지 막혔다. `--retry 3`은 몇 초 안에 끝나 수십 분짜리 장애를 견디지 못한다.

장애 때도 `ci`가 통과하거나, 적어도 대부분의 실행이 외부 다운로드에 기대지 않게 한다. sha256 검증과 버전 고정(설계 C.4.6)은 그대로 둔다.

## 할 일

1. 1차 출처(GitHub 문서)로 방법을 비교하고 고른다. 후보: 도구 캐시(키는 `.tool-versions`와 sha256, 복원 뒤에도 sha256 검증), 인증 요청(`GITHUB_TOKEN`으로 릴리스 자산 받기, 익명 한도·장애를 피하는지), 재시도 간격 늘리기. 설계 C.4.10 허용 액션 목록, job별 최소 `permissions`, PR 트리거 `pull_request` 규칙 안에서.
2. `ci.yaml`을 고치고 함정은 옆 주석(한국어)으로 남긴다. 토큰을 쓰면 다른 호스트로 넘어가는 리디렉션에 따라가지 않는지 확인한다.
3. 로컬 `pre-commit run --all-files`·`bun run ci`, PR의 `ci` 통과. 캐시를 쓰면 적중·미스 두 경로를 PR 실행으로 확인한다.

## 완료 조건

- 고친 `ci`가 main과 PR에서 통과하고, 고른 방법과 이유가 `ci.yaml` 주석과 이 티켓 결과에 있다.
- sha256 불일치는 여전히 실패한다.

## 검증

필수 검사 `ci` 실행 기록(적중·미스), 설계 C.4.6·C.4.10.

## 결과 (2026-11-09)

- 고른 방법: 캐시 + 미스 때 인증 REST 다운로드 + 긴 재시도. 도구 압축 파일 캐시(key는 `.tool-versions`·`ci.yaml`), 복원 뒤에도 sha256을 다시 보고 다르면 지우고 받는다. GitHub 릴리스 자산은 `GITHUB_TOKEN`으로 tags API → assets API(`Accept: application/octet-stream`)로 받는다(익명 IP당 시간당 60 대신 저장소당 1,000). curl은 토큰을 리디렉션된 다른 호스트로 넘기지 않는다. Terraform provider·kubeconform 스키마도 캐시한다(`bun run ci`도 GitHub에서 익명으로 받는 것이 있어서).
- 버린 방법: 웹 주소에 토큰 붙이기(문서 근거 없음), `gh release download`(재시도 제어 없음), `--retry-all-errors`(404도 오래 재시도).
- `actions/cache` v6.1.0(최신, GitHub 소유라 허용 목록 안). 설계 C.4.10에 Actions 캐시 위협 줄과 출처 S236·S237.
- 확인: PR 첫 실행은 캐시 미스로 API 경로 10개를 받아 저장, 재실행은 10개 모두 캐시 사용. 병합 뒤 main push 실행이 main 범위 캐시(도구 302MB, provider·스키마 53MB)를 만들었다.
- 남은 위험: 장애와 캐시 미스가 겹치면(도구를 올리는 PR, 7일 미사용 삭제 뒤) 여전히 실패할 수 있다. 인증 경로도 `release-assets.githubusercontent.com`을 거친다. 스키마 캐시는 내용 검증 없이 범위 규칙에 기댄다. 저장소 캐시가 10GB를 넘으면 과금된다.
