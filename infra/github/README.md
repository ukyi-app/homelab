# infra/github

**역할** — GitHub terraform 루트: CI Actions 시크릿(`secrets.tf`) + branch protection(`repo.tf`, required check `contexts=["gate"]`) + `bump-poll/**` ref를 writer App 전용으로 예약하는 repository ruleset(`rulesets.tf`) 관리. App Platform 신뢰 앵커.

**적용 방식** — **owner 로컬 apply 전용 신뢰 앵커**. CI 무인 apply는 광범위 admin PAT를 CI에 저장해야 해 보안 모델 위반 → 금지. CI는 `tf-reconcile`에서 **plan-only 드리프트 알림**만(신규 `TF_GITHUB_*` 시크릿 있을 때만, 없으면 preflight skip).

**라이브 디버그** — terraform plan 로그(owner 로컬). App 인증 경계는 런북 `docs/runbooks/app-platform.md`.

**함정 SSOT** — docs/traps-detail.md: github/tailscale 루트=신뢰 앵커라 CI 무인 apply 금지(plan-only). required check는 `gate` 단일. fine-grained PAT 능력은 실제 push 테스트로만 확인(repo GET `permissions`는 역할만 표시). provider lock 첫 커밋은 라이브 state writer 버전 이상으로 핀.

## AIOps CI 자격 전환 (AIOPS-T02-0914)

PR의 기본 `iac-validate`·`gate`는 운영 자격 없이 실행한다. 인증 Cloudflare plan은 owner가
`reviewed-plan.yaml`을 **main에서** PR 번호와 검토한 40자리 head SHA로 요청한다.
실행 코드는 dispatch 당시 main의 workflow SHA, 후보는 별도 checkout의 정확 head SHA다.
요청·자격 사용 직전·결과 귀속 시 PR의 head/repo/base와 actor/triggering_actor를 검사하며,
head 변경·재실행은 새 검토 요청을 요구한다. 결과 job은 후보를 실행하지 않은 별도 runner에서
검토 SHA를 재조회하고 JSON 수령증과 실행 링크를 보존한다. 결과는 그 SHA에만 유효하다.
plan도 provider/data source를 실행하므로 **검토한 Terraform 코드의 실행 승인**이다.
Cloudflare plan에 GitHub/Tailscale/Telegram/App 자격은 공급하지 않는다. 정시 main drift와
승인된 main의 기존 Cloudflare apply는 유지한다. GitHub/Tailscale apply는 계속 owner-local이다.

`homelab-main` Environment는 `branch_pattern = "main"` 한 개만 허용한다. tag main,
`refs/pull/*/merge`, `aiops/*`는 허용하지 않는다. 실제 실행 job(reusable 포함)에 환경과
개별 main/replay 검사를 둔다. 외부 앱의 `reusable-app-build.yaml/deploy-trigger`는 caller가
명시 전달하는 휴면 dispatch 자격 계약이며 homelab의 17개 공급과 별개다. caller 환경을
homelab Terraform으로 관리하지 않는다. 이 계약을 다시 켤 때 caller의 공급 경계도 검증한다.

main 쓰기는 `github_branch_protection.main.restrict_pushes`에서 owner와 기존 writer App만
명시 허용한다. 2026-09-14 read-only API 확인: `ukkiee`(52371529,
`MDQ6VXNlcjUyMzcxNTI5`), writer App(4043080, `A_kwHOEWo9us4APbFI`). AIOps App와
github-actions는 목록에 없다. `permissions: read`는 GITHUB_TOKEN의 상한이 아니며,
후보가 `contents/checks/statuses/actions/pull-requests: write`를 요청해도 서버의 main 쓰기
제한을 통과하는 근거가 되지 않는다. `gate` 하나·strict·리뷰 수 0은 유지한다.
기존 `enforce_admins=false`로 owner의 수동 admin 우회가 남으며, GitHub의 관리자/maintain
역할 예외와 admin의 보호 설정 수정 권한도 잔여다. 새 OrganizationAdmin 역할 전체를 bypass로
추가하지 않았다. 자동화에 admin/owner 자격을 공급하지 않는다. 향후 관리자/maintain 추가는
허용 주체 재감사 대상이다. 후보 workflow가 낸 green은 후보 코드의 신뢰 증거가 아니다.

`pr-sweeper`는 main 기반·same-repo·non-Draft·기존 writer bot이 연 PR만 선택하고
검증한 head SHA와 한 번 고정한 main Git 객체만 병합한다. 후보를 checkout하지 않고
head ref의 정확한 이전 SHA를 lease로 지정해 push한다. 조회 뒤 PR base가 바뀌어도 새 base는
병합 입력이 되지 않는다. 대상 ref는 별도 writer-only 생성/갱신 ruleset으로 보호한다.
이 규칙이 없으면 API의 PR author가 writer여도 AIOps의 contents:write가 head를 바꿀 수 있다.
`bump-poll/**`의 기존 writer-only 규칙과 autoDeploy 승인/회수 로직은 유지한다.
`workflow_run` writeback은 실제 build workflow ID·run·attempt·repository/SHA와 보호 main
계보를 읽기 권한으로 검증한 뒤 writer를 발급한다. 산출물은 검증한 불변 artifact ID만
다운로드하고 발급 직전에 재검증한다. 모든 운영 job은 부분 재실행도 owner만 허용한다. 로그인 비교는 GitHub에 맞춰 모든 actor 가드에서 대소문자를 정규화한다.

### owner-local 전환 순서

1. 이름/가시성만 조사해 repository 17개와 조직 공급의 실제 목록을 확정한다. 현재 조직 목록
   조회는 `admin:org` 부족 HTTP 403이므로 **미검증**이다. 없다고 가정하지 않는다.
2. Environment·branch 정책·main/ref 제한을 검토한 owner-local plan으로 먼저 준비한다.
   기존 허용 주체의 양성 동작과 운영 비밀 없는 canary를 검사한다. 새 환경 이름을 선언하는
   후보 workflow가 기존 환경 자격을 상속하지 못하는 경우도 포함한다.
3. `.env.secrets`의 로컬 공급에서 17개를 환경으로 복제하고 workflow 배선을 반영한다.
   Telegram은 새 environment resource가 소유한다. `removed { destroy = false }`는 이전
   repository resource의 state 관리만 해제하므로 이 단계에서 원본은 삭제하지 않는다.
4. main schedule/dispatch/reusable·알림·autoDeploy 양성 확인 후 원본 repository/organization
   공급을 owner가 회수한다. 조직 secret의 selected repositories/all 가시성까지 재조회한다.
   원본을 남겨 둔 기간에는 PR 자격 차단이 **완료되지 않았다**.
5. branch/tag/PR canary 음성, 강화 GITHUB_TOKEN/AIOps의 main push·merge·간접 변이 음성,
   기존 writer·owner 양성, SHA 변경 및 partial rerun 음성을 실제 서버에서 확인한다.
   거부 사유가 인증 실패인지 보호 정책 거부인지 구분하고 run/SHA를 증거로 기록한다.

전환 실패 시 AIOps 쓰기는 비활성으로 유지하고 환경의 누락 공급/정책/호출부를 복구한다.
원본 공급 회수 전에는 그 공급으로 기존 main 운영을 복구할 수 있다. 회수 후에는 운영
시크릿을 PR에 다시 노출하는 원복 대신 보호 환경의 로컬 공급을 복원한다.
GitHub plan-only 자격은 새 Environment/배포 정책/환경 secret을 읽을 수 있어야 한다.
부족하면 HTTP 404나 허위 drift가 생길 수 있으므로 API 읽기와 실제 `No changes`를 함께
확인한다. Administration write를 CI에 추가하는 방식으로 해결하지 않는다.

### 로컬 검증과 남은 서버 증거

`tests/ci-authority.tftest.hcl`은 mock provider로 HCL의 실제 resolved plan을 검사한다.
실제 secret/state/backend를 읽지 않는 임시 디렉토리에서 `init -backend=false`·`validate`·
`test`를 실행한다. `tools/tests/test_reviewed-plan.bats`는 SHA/actor/API 입력과 실제 job
가드의 음성·양성 대조를 실행한다. 기존 CI 회귀는 PR plan 제거·시크릿 환경 배선·수동
preview/기존 apply destroy 정책을 확인한다. **이 로컬 결과는 GitHub 서버 거부 증거가 아니다.**

미검증: 실제 Environment 생성/복제/회수, 조직 공급 가시성, branch/tag/PR canary,
강화된 GITHUB_TOKEN의 main 쓰기 거부, writer의 auto-merge 양성, 읽기 전용 TF 자격의
새 대상 조회, 실제 reviewed plan 실행. 본 변경에서 GitHub mutation/TF apply/커밋/푸시는
수행하지 않는다.

근거: [GitHub Environment 정책](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[provider 6.12.1의 branch protection](https://raw.githubusercontent.com/integrations/terraform-provider-github/v6.12.1/website/docs/r/branch_protection.html.markdown),
[branch/tag 개별 정책](https://raw.githubusercontent.com/integrations/terraform-provider-github/v6.12.1/website/docs/r/repository_environment_deployment_policy.html.markdown).
