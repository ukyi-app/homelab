# GitHub 보호 설정 운영 (`infra/github`)

GitHub 보호 설정(ruleset, environment `automerge`, Actions 권한)은 Terraform root `infra/github`가 선언하고, owner가 로컬에서 래퍼 `tools/tf-github.sh`로만 적용한다(설계 C.3.9, D-28). T12부터 `homelab github plan·apply·verify`가 같은 규칙으로 감싼다. CI는 자격 없이 `terraform test`(mock)만 하고 plan하지 않는다.

- 외부 변경(apply, `gh api` 쓰기)은 사람 승인 뒤에 하고 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 남긴다.
- 래퍼는 작업 사본이 아니라 github.com에서 새로 clone한 main으로 돈다(작업 사본의 git 설정·remote·hook을 쓰지 않는다). 그래서 바꾼 HCL은 PR 병합 뒤에야 plan에 나온다. PR 단계의 미리보기는 CI의 mock 시험뿐이다.
- 값(토큰, R2 키)은 출력하지 않는다. 계정 식별자·endpoint는 저장소 밖 작업 기록에 둔다(D-23).

## 0. 준비

[infra/README.md](../../infra/README.md) 1·2절과 같다(mise, `infisical login`, 백업 폴더). 래퍼가 백업 폴더 검사를 스스로 한 번 더 한다.

```bash
export HOMELAB_ADMIN_PROJECT_ID=<homelab-admin project ID>   # 없으면 래퍼가 묻는다
export R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com  # 없으면 래퍼가 묻는다
# GITHUB_TOKEN이 없으면 gh auth token을 쓴다. classic·OAuth 토큰은 repo·admin:org가 있고 delete_repo가 없어야 한다.
# gh 기본 로그인 범위(repo, read:org, gist)에는 admin:org가 없다: gh auth refresh -h github.com -s admin:org
tools/tf-github.sh verify
```

래퍼는 자격을 읽기 전에 github.com의 main을 새로 clone하고 그 사본의 래퍼로 다시 실행한다. 다만 처음 실행되는 것은 지금 작업 사본의 래퍼다. 작업 사본을 AI·자동화도 편집하므로, 그 부분까지 믿지 않으려면 새 clone에서 시작한다:

```bash
# env -i: 환경 기반 git 설정(GIT_CONFIG_COUNT/KEY/VALUE의 insteadOf 등)까지 끊는다. https만 연다.
d=$(mktemp -d) && mkdir -p "$d/home" && \
  env -i PATH="$PATH" HOME="$d/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.https.allow=always \
    clone -q --depth 1 --branch main https://github.com/ukyi-app/homelab.git "$d/h" && \
  (cd "$d/h" && tools/tf-github.sh verify); rm -rf "$d"
```

종료 코드: 0 선언과 같음, 2 차이, 1 guard 실패나 오류. guard 메시지 앞의 번호가 설계 C.3.9 guard 번호다.

## 1. 첫 apply (E5, 두 단계)

T08a의 R2 잠금 시험(U02) 뒤에 한다. 그 전에 사람이 할 일(T10 티켓 "수행"의 사람 작업): App 둘을 만들어 ID를 `infra/github/variables.tf` default에 숫자로 적는 PR, 템플릿·`files`의 private vulnerability reporting 켜기, 저장소 설정 `gh api` 확인.

**1단계 PR(이 root가 처음 들어가는 PR):** `main-interim`을 active 그대로 import하고 ruleset A~D, environment, Actions 권한을 만든다. `ci` ruleset은 제자리에서 `main-checks`로 이름이 바뀐다. app-main 셋(템플릿, `files`, `homelab-bot`)도 import한다.

```bash
tools/tf-github.sh plan     # import 5건, 생성(main-review, deploy-branches, release-tags-lock·create, environment·policy, Actions 권한 둘)
tools/tf-github.sh apply    # state 백업 → 잠금 plan → yes → apply → verify
```

apply 뒤 확인하고 기록한다:

```bash
gh api repos/ukyi-app/homelab/rulesets --jq '.[] | [.id, .name, .enforcement] | @tsv'
gh api repos/ukyi-app/homelab/rulesets/<main-review id> --jq .enforcement            # active
gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[] | .type] | sort'        # pull_request 포함
```

그다음 병합 키 Sync를 만든다(environment가 생긴 뒤, 2단계 전). 범위는 Repository Environment `ukyi-app/homelab` / `automerge`다. Repository나 Organization 범위로 만들면 guard 9가 멈춘다.

**2단계 PR:** `infra/github/rulesets.tf`의 `main_interim` enforcement를 `disabled`로 바꾸고, `imports.tf`와 `tests/guards.tftest.hcl`의 import용 `override_resource` 셋을 지운다. 병합 뒤 `tools/tf-github.sh apply`. `main-interim`은 지우지 않고 되돌릴 때 쓴다.

## 2. 평소 운영

- 보호를 바꿀 때: HCL PR(CI의 fmt·validate·mock 시험) → 검토 → 관리자 bypass 병합(`gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`) → `tools/tf-github.sh plan`으로 diff 확인 → 예상과 같으면 `apply`, 다르면 고치는 PR.
- 월 1회와 콘솔에서 무언가를 바꾼 뒤 `tools/tf-github.sh verify`.
- 월 1회 bypass 기록을 PR 작성자와 대조한다. 기본값 `day`로 부르면 놓친다.

  ```bash
  # --paginate: per_page 상한이 100이라 한 달 기록이 100건을 넘으면 첫 페이지만 나온다.
  gh api --paginate 'repos/ukyi-app/homelab/rulesets/rule-suites?time_period=month&per_page=100' \
    --jq '.[] | select(.result == "bypass") | [.pushed_at, .actor_name, .ref, .after_sha[0:12]] | @tsv'
  ```

- 새 앱: `infra/github/app-repos.json` PR 병합 → 저장소 생성(템플릿에서 `gh repo create --public --template`) → `app-main`을 뺀 하드닝 → `tools/tf-github.sh apply`가 `app-main`을 만든다. 목록 밖 public 저장소가 있는 동안 guard 8이 모든 plan을 멈춘다.
- ruleset은 지우지 말고 `disabled`로만 끈다. 정답은 git의 HCL이다.

## 3. apply가 실패했을 때

provider 6.13.0은 갱신 apply가 한 번 실패하면 그 ruleset의 드리프트가 영구히 안 보인다(#3519). 래퍼가 그 plan의 ruleset을 `state rm` 뒤 다시 import한다. 그다음 원인을 고치고 `plan`부터 다시 한다. state가 꼬였으면 래퍼가 남긴 백업(`TF_STATE_BACKUP_DIR`)과 비교한다.

**재편입 실패**(같은 장애로 import가 실패): 래퍼는 state를 되돌리지 않고 남은 `terraform import '<주소>' '<저장소>:<id>'` 목록을 출력하고 멈춘다. 되돌릴 state가 바로 #3519로 낡은 계획값을 담은 것이기 때문이다. 이 상태에서 plan하면 기존 ruleset을 새로 만들려 한다(같은 이름 둘은 guard 3이 잡는다). 장애가 끝나면 그 import부터 마치고(래퍼 사본과 같은 준비로) `verify`가 exit 0인지 본 뒤에만 다른 작업을 한다.

## 4. 비상 경로: guard 하나가 모든 apply를 막을 때

예: 관리 ruleset을 콘솔에서 지웠는데, 템플릿 `CODEOWNERS` 오류나 목록에 없는 새 public 저장소가 함께 있어 재생성 apply도 guard에서 멈춘다.

1. 먼저 `main-interim`을 다시 active로 해 main이 열리지 않게 한다(지워진 것이 main 보호면).

   ```bash
   gh api -X PUT repos/ukyi-app/homelab/rulesets/25372131 -f enforcement=active
   ```

2. 그 ruleset만 다시 만든다. `-target`은 의존 그래프 밖 guard를 건너뛴다. 래퍼에는 이 옵션이 없어, 래퍼가 하는 준비(토큰 확인, 임시 사본, 환경 정리)를 같은 셸에서 손으로 하고 `terraform apply -target=github_repository_ruleset.<이름>`을 그 사본에서 돈다. 승인과 명령을 approvals.md에 남긴다.
3. 바로 뒤에 전체 `tools/tf-github.sh verify`로 나머지 guard를 본다. 막던 원인(CODEOWNERS, 목록 밖 저장소)을 고친 뒤 exit 0을 확인한다.
4. 1번에서 켠 `main-interim`을 HCL 선언(2단계 뒤 `disabled`)으로 되돌린다(`apply`).

homelab ruleset이 지워진 동안은 2번까지 보호 공백이 있다. 자동 병합 조건 9는 앱 저장소의 `app-main`만 보므로 이 공백을 막지 못한다.

## 5. 되돌리기

- ruleset: HCL에서 enforcement를 `disabled`로 바꿔 apply한다. 급하면 `gh api -X PUT repos/ukyi-app/homelab/rulesets/<id> -f enforcement=disabled` 뒤 HCL을 맞춘다. 그 전에 `main-interim`을 active로 한다.
- App: 설치를 해제한다. 워크플로: revert PR.

## 6. GHCR 패키지 공개(앱마다, U39 결과에 따라)

앱 이미지는 public만이다(D-29). `GITHUB_TOKEN`으로 만든 첫 패키지가 저장소 가시성을 물려받는지는 문서끼리 어긋난다. T10에서 `homelab-probe` 첫 push로 확인한다.

```bash
gh api orgs/ukyi-app/packages/container/<앱> --jq .visibility
curl -s -o /dev/null -w '%{http_code}\n' 'https://ghcr.io/token?scope=repository:ukyi-app/<앱>:pull'   # 200
```

private이면 첫 push 뒤 패키지 설정 화면에서 Public으로 바꾼다. 되돌릴 수 없다(public 패키지는 다시 private이 안 된다). 바꾼 것을 approvals.md에 남긴다. 상속이 확인되면 이 절은 확인 명령만 남긴다.
