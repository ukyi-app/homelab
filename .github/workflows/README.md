# 워크플로와 자동 병합 조건

이 저장소의 main은 Argo CD가 곧 클러스터에 적용한다. 그래서 사람 검토 없이 main에 들어가는 길을 하나만 두고, 그 조건을 여기 공개한다(설계 C.4.7, D-07, AC-P8).

## 워크플로

| 파일 | 트리거 | 하는 일 |
|---|---|---|
| `ci.yaml` | `pull_request`, main push | 필수 검사 `ci`. 로컬과 같은 `bun run ci`(검사 내용은 `tools/ci/`) |
| `app-build.yaml` | `workflow_call`(앱 저장소가 태그 `app-build-vX.Y.Z`로 호출) | 앱 시험 → 기본 브랜치 push면 GHCR push → attestation → 배포 PR `deploy/<앱>` |
| `deploy-merge.yaml` | `workflow_run`(ci 완료)만 | 아래 조건 9개를 main의 코드로 검사하고, 모두 참이면 `ukyi-homelab-merge` App이 squash 병합 |

## 사람 승인 없이 병합되는 PR의 조건

아래가 **모두** 참일 때만 병합한다. 하나라도 거짓이면 PR은 열린 채 남고 사람이 판단한다. 검사 코드는 `tools/deploy-merge/conditions.ts`, 조건마다 음성 시험은 `tools/deploy-merge/fixtures/`다.

1. PR 작성자가 `ukyi-homelab-deploy[bot]`이다(로그인 문자열이 아니라 숫자 사용자 ID로 비교).
2. head 저장소가 `ukyi-app/homelab`이고 head 브랜치가 `deploy/<앱>`이며 `apps/<앱>/`가 main에 있다.
3. 바뀐 파일이 정확히 `apps/<앱>/image.yaml` 하나다.
4. 바뀐 키가 `digest`와 `revision`뿐이다(`repository` 그대로, `hold: false`).
5. `repository@digest`가 GHCR에 있고, 그 이미지의 `org.opencontainers.image.revision` 라벨이 `revision`과 같고 `org.opencontainers.image.source`가 `https://github.com/ukyi-app/<앱>`이다. 그리고 그 digest의 build provenance attestation이 있다: 서명 워크플로가 `ukyi-app/homelab/.github/workflows/app-build.yaml@refs/tags/app-build-v*`, 원본 저장소가 `ukyi-app/<앱>`, 원본 ref가 `refs/heads/main`, 원본 커밋이 `revision`이고 GitHub 호스트 runner에서 만들어졌다(`gh attestation verify ... --deny-self-hosted-runners`).
6. `revision`이 앱 저장소 기본 브랜치에 있고 main의 배포 revision 대비 compare `ahead`다.
7. 그 head SHA의 `ci`(`.github/workflows/ci.yaml`)가 성공했다.
8. PR이 Draft가 아니고 `hold` 라벨이 없다.
9. 앱 저장소 `ukyi-app/<앱>`이 public이고, 그 main에 `app-main` 규칙(PR 필수, 승인 1 이상, code owner 리뷰, 새 push 때 승인 무효화, force push·삭제 금지, main 갱신은 bypass 신원만(Restrict updates, fetch and merge 예외 없음))이 active로 보이며, main에 유효한 `CODEOWNERS`가 있다(`codeowners/errors`가 빈 배열이고 규칙이 `* @<owner 계정>` 한 줄). 규칙은 GitHub이 적용하는 파일(`.github/`, 루트, `docs/` 순서의 첫 파일)에서 읽고, 앞 후보가 404일 때만 다음 후보로 넘어간다. 앞 후보 조회가 그 밖의 오류면 이 조건은 거짓이다.

병합은 검사한 head SHA를 고정해 `PUT /repos/ukyi-app/homelab/pulls/{n}/merge`(squash)로 한다. 검사와 병합 사이에 새 커밋이 들어오면 GitHub이 거부한다. GitHub auto-merge(`allow_auto_merge`)는 꺼져 있다.

그 밖의 PR(사람, Renovate, 봇 변경 PR, Codex Connector가 만든 변경)은 모두 code owner가 검토한 뒤 사람이 병합한다. owner가 만든 PR은 검토한 SHA를 고정해 관리자 bypass로 병합한다: `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`.

## 서버가 강제하는 것

워크플로 코드는 바뀔 수 있으므로 위 조건은 서버 쪽 장치와 함께 선다. 선언은 `infra/github`(Terraform)이다.

- ruleset A `main-checks`: main에 필수 검사 `ci`. bypass 없음.
- ruleset B `main-review`: main은 PR로만, 승인 1, code owner 리뷰, 새 push 때 승인 무효화, 마지막 push 승인. bypass는 저장소 관리자(`pull_request` 모드)와 `ukyi-homelab-merge` App뿐.
- ruleset C `deploy-branches`: `deploy/**`를 만들고 바꾸는 것은 `ukyi-homelab-deploy` App뿐.
- ruleset D1·D2: 버전 태그(`app-chart-v*`, `data-chart-v*`, `app-build-v*`)는 관리자만 만들고 아무도 옮기거나 지우지 못한다.
- 앱 저장소와 `homelab-app-template`의 `app-main`.
- 병합 키 `HOMELAB_MERGE_KEY`는 environment `automerge`(배포 브랜치 main)의 secret이고 `deploy-merge`의 merge job만 쓴다. 배포 키는 Infisical OIDC identity가 앱 main push의 태그 고정 `app-build`에만 준다.

ci의 workflow-guard(`tools/ci/workflow-guard.ts`)는 실수를 잡는다: `automerge` environment와 병합 키는 `deploy-merge.yaml`의 merge job만, `deploy-merge` 트리거는 `workflow_run`만, environment를 선언한 워크플로는 `workflow_run`만, `secrets: inherit`·다른 저장소 reusable 호출·동적 secrets 참조·`pull_request_target`·self-hosted runner 금지, `uses`는 40자 SHA와 버전 주석. 이 검사 자체를 고치는 PR은 고친 코드로 돌므로, 악의적인 변경은 사람 검토(ruleset B)가 막는다.
