# AGENTS.md

NUC 한 대의 k3s 홈랩을 Git으로 운영하는 공개(public) 저장소다. main에 들어간 커밋은 Argo CD가 곧 클러스터에 적용한다.

## 먼저 읽을 것

- 문서 지도 `docs/plans/2026-10-17-homelab-rebuild/README.md`: 어떤 문서가 무엇의 기준인지, 읽는 순서.
- 계획 명세 `docs/plans/2026-10-17-homelab-rebuild/spec.md`: 결정(§5), 인수 조건, 티켓 목록(§8), 계획 문서를 고칠 때의 규칙(§12).
- 티켓을 맡았으면: 그 티켓(`issues/`) → `platform/design.md` E.1의 같은 단계 → 티켓이 가리키는 설계 절.

## 배치와 소유

배치는 설계 C.1, 누가 무엇을 바꾸는지는 설계 C.2 표가 기준이다. 아직 없는 디렉터리는 뒤 티켓이 만든다.

- `host/`: 호스트 설정. 사람이 `sudo host/install.sh`로 적용한다. Argo CD 밖이다.
- `platform/`: 플랫폼 구성 요소. Argo CD가 main에서 적용한다. 클러스터별 값은 `platform/root/values-<클러스터>.yaml`.
- `apps/<app>/`, `data/<app>/`: 앱 배포와 데이터 선언. 자동 생성 파일은 `apps/<app>/image.yaml` 하나다(배포 App 소유, 사람은 롤백 때만).
- `infra/`: Terraform root. owner가 로컬에서 apply한다. CI는 plan·apply하지 않는다.

## 변경 규칙

- main은 PR로만 바꾼다. 필수 검사는 `ci` 하나다. 사람 PR은 owner가 검토한 뒤 병합하고, 자동 병합은 배포 App의 digest PR뿐이다(설계 C.4.7).
- 로컬 확인은 `mise install` 뒤 `pre-commit run --all-files`와 `bun run ci`. 필수 검사 `ci`는 같은 `bun run ci`를 부른다(검사 내용은 `tools/ci/`).
- 로컬 도구(`mise install`, `pre-commit`, `bun run ci`, `tools/*.sh`)는 직접 만든 브랜치에서만 돌린다. 남이 만든 PR(fork, 외부 기여자, 봇)은 체크아웃하지 않고 GitHub diff와 CI 결과로 검토한다. 훅 설정과 검사 코드가 그 PR의 트리에서 와 로컬 자격으로 돌기 때문이다(`docs/runbooks-public/github.md` 2절).
- 이 저장소를 가리키는 Argo CD 참조(`repoURL`)의 revision은 `main`이다(공유 차트만 태그). 브랜치 이름이 남은 채 병합하면 Argo CD가 지워진 브랜치를 따라간다.
- 버전은 고정한다: 도구는 `.tool-versions`, k3s는 `host/versions.env`, 외부 차트는 정확한 semver, 이미지는 digest. `.tool-versions`를 바꾸면 `ci.yaml`의 sha256도 같은 커밋에서 바꾼다.
- 워크플로의 `uses:`는 40자 커밋 SHA와 버전 주석으로 고정하고, 설계 C.4.10의 허용 목록 안 액션만 쓴다. `permissions`는 job마다 최소로, PR 트리거는 `pull_request`를 쓴다.
- 함정과 이유는 그 설정 옆 주석으로 남긴다(설계 B.8). 주석은 한국어로, 이유와 함정만.
- 외부 변경(GitHub 설정, 계정, 삭제, 병합, 배포)은 사람 승인을 받은 뒤 하고 `docs/plans/2026-10-17-homelab-rebuild/approvals.md`에 기록한다.
- 파괴 명령(k3s 제거, 데이터 경로 삭제, `terraform destroy`, 저장소·ruleset 삭제)은 명령을 적어 사람에게 넘긴다. 에이전트가 직접 실행하지 않는다.

## 공개 저장소에 두는 것

- 시크릿 값은 Infisical에만 있다. 저장소에는 참조(키 이름)만 두고 `kind: Secret` 매니페스트는 두지 않는다. 자격은 `infisical run`으로 환경변수에 넣고 파일로 만들지 않는다.
- tailnet 이름(MagicDNS 이름), Tailscale IP, 개인 이메일, 복구 자산 목록, 토큰 인벤토리, 로컬 런북은 저장소 밖에 둔다(D-23). 필요하면 실행 때 얻는다(예: `install.sh`가 `tailscale status --json`으로 MagicDNS 이름을 읽는다).
- gitleaks가 CI(작업 트리)와 pre-commit(staged)에서 본다. 기본 룰에 tailnet 이름·Tailscale IP 룰을 더했다(히스토리는 보지 않는다). 면제를 더할 때는 `.gitleaks.toml` 주석의 규칙을 따른다.

## Code Review Rules

- Write all review finding titles and descriptions in Korean.
- Write review summaries and explanations in Korean.
- Keep code identifiers, file paths, commands, and quoted code unchanged.
- 리뷰 요약과 모든 리뷰 코멘트(지적 제목·본문·설명)는 한국어로 쓴다.
- P0~P3 우선순위 표시와 그 형식은 그대로 둔다.
