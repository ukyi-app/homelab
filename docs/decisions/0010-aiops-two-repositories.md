# 0010 — AIOps 실행기를 조직 레포로 분리하고 homelab 내부 Draft PR을 사용한다

- 상태: 수용(accepted, 설계 결정) — 2026-09-14 사용자 “진행”
- 대체: [ADR-0009](0009-aiops-fork-pr-boundary.md)의 운영 fork 경계
- 유지: ADR-0008의 진단·초안 권한, ADR-0002의 owner-local apply, ADR-0003의 단일 `gate`

## 결정

`ukyi-app/homelab`은 운영 선언과 기준 정책을, `ukyi-app/aiops`는 실행기·검증기·게시기와
설치 코드를 소유한다. NUC는 aiops의 고정 커밋을 설치하고 별도 homelab 기준 커밋을 읽는다.
모델의 수정 대상은 homelab 전체 파일이며 aiops와 앱 소스로 넓히지 않는다. 원장 상한과
검증 정책은 후보가 아닌 homelab 기준에서 읽는다.

게시기는 homelab의 사건별 내부 브랜치에서 Draft PR을 만든다. 운영용 fork는 사용하지 않는다.
조직 소유는 관리 단위이며 자격 경계가 아니다. 전용 GitHub App을 homelab 한 레포에 설치하고,
root가 보호하는 발급기가 repository ID와 역할별 권한을 명시한 설치 토큰을 발급한다.
모델·검증기는 GitHub 쓰기 자격을 받지 않는다. 게시기는 merge·ready·auto-merge·dispatch를 하지 않는다.

## 내부 PR을 허용하는 선행 조건

PR이 읽을 수 있는 repository/organization 범위의 운영 자격을 회수하고 서버에서 branch 유형
`main`만 허용하는 Environment로 옮긴다. PR 코드가 workflow의 권한을 높여 요청할 수 있으므로
`permissions: read`, Draft, 브랜치 접두어, workflow 조건만으로 안전하다고 판정하지 않는다.
서버의 main 반영 주체는 owner와 기존 운영 writer로 제한하며 AIOps App과 GitHub Actions를 제외한다.
기존 자동 배포는 유지하고 재실행·범용 PR 처리기를 통한 간접 변이도 검증한다.

일반 PR 검증에는 운영 자격을 제공하지 않는다. 인증 Terraform plan은 owner가 검토한 정확한
PR head SHA를 main의 고정 workflow로 요청한다. 실행 전과 결과 귀속 시 head가 바뀌면 거부한다.
승인된 main의 apply와 정시 drift plan은 유지한다. 후보가 수정한 CI의 초록 결과는 독립 검증
증거가 아니며 NUC의 고정 기준 검증을 대체하지 않는다.

## 선택의 비용과 이행

전용 fork는 GitHub의 기본 자격 분리 경계를 제공하지만 별도 작업 레포 관리가 필요하다.
사용자는 두 조직 레포를 선택했고, 내부 PR을 쓰기 위해 기존 CI의 자격 공급과 main 권한을
함께 개편하는 비용을 수용했다. 조직으로 옮기는 것만으로 fork와 같은 격리가 생기지는 않는다.

서버 권한의 실제 거부/허용 증거를 확보하기 전에는 같은 레포 게시를 활성화하지 않는다.
NUC 계정·구독 인증·512MiB 상태·이전 release를 보존한 비활성 전환과 롤백을 먼저 검증한다.
기존 개인 fork의 삭제는 별도 확인이 필요한 정리 작업이다. 이 결정이 운영 수용 완료를 뜻하지 않는다.

근거: [Environment 정책](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[GITHUB_TOKEN 권한](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token),
[설치 토큰의 범위](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app),
[브랜치 보호](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
