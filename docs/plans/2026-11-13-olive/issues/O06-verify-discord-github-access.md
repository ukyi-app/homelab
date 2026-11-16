# O06 검증: Discord 채널 독자와 GitHub main 보호

- 단계: 0 끄기와 검증
- 상태: 읽기 확인 완료(2026-11-16, Discord 독자는 관리자 답으로 확인). 4-1 쓰기 시험과 writer 설치의 저장소 목록 확인(관리자 화면)은 대기
- 명세: `spec.md` §6 불변 조건 4·5, §7, §9.4, §11
- Blocked by: 없음
- 연결 AC: AC-03
- 결정(관리자): D-07(PR 자동 게시, 병합은 관리자)
- 수행: 사람(Discord·GitHub 설정 화면) + 에이전트(읽기 전용 API 조회와 정리)
- 저장소·PR: 이 계획 문서 PR(결과만, 사람·채널 ID 없음)
- 파일 소유: 이 티켓의 "결과" 절
- 설계 계약: 보안 조사 4.2·6·11절(아래 요약)

## 목표

두 가지를 확인한다. (1) 올리브가 글을 쓸 Discord 채널·스레드를 관리자 말고 누가 읽을 수 있는지. (2) GitHub main 보호가 코딩 App의 직접 갱신·병합·우회를 실제로 막는지.

## 알려진 사실

- [확인] 병합 REST API는 contents 쓰기 권한을 요구한다. 브랜치·커밋 작성에도 같은 권한이 쓰인다. 그래서 "토큰은 주고 병합은 말로 금지"는 막는 것이 아니다.
- [확인] 지금 writer는 merge·일반 DELETE 경로가 없고, ref 갱신을 `bot/change/...`로 제한하며 `force:false`를 강제한다.
- [미확인] 실제 Discord 채널·스레드 독자 범위, GitHub ruleset의 bypass 목록과 배포 App 자동 병합 예외가 코딩 App에 열려 있지 않은지.

## 할 일

1. Discord: 관리자는 2026-11-14에 그 서버를 혼자 본다고 답했다(`discord.md` §7). 서버의 구성원·봇 목록과 올리브가 쓸 채널의 읽기 권한을 한 번 읽어 그 전제를 확인한다. 관리자 혼자가 아니면, 민감한 상태 답을 보낼 곳(DM 또는 비공개 채널)을 정한다.
2. GitHub: homelab과 봇 저장소의 main ruleset을 읽는다(읽기 API 또는 설정 화면). 확인할 것: PR 필수, 필수 검사, 사람 리뷰, stale 승인 무효, force·삭제 금지, bypass 목록에 코딩 App·리뷰 App이 없음, 자동 병합 예외가 배포 App에만 있음.
3. 코딩 App·리뷰 App의 설치 권한 목록을 적는다(administration, actions, workflows, secrets 쓰기가 없어야 한다).
4. 보호 경로를 건드리는 같은 저장소 브랜치 PR에서 CI가 PR 안의 워크플로 정의로 도는지(D-07의 이유) 지금 설정으로 확인한다.
4-1. 쓰기 App을 조직의 모든 저장소로 넓히기 전에(D-24) 확인한다. 시험 저장소 `homelab-smoke`에서만 한다.
   - 설치 토큰을 저장소 하나와 필요한 권한만으로 좁혀 발급받을 수 있는지, 좁힌 토큰으로 다른 저장소에 쓰면 거절되는지.
   - workflows 권한이 없는 App이 `.github/workflows/` 아래 파일을 바꾸는 커밋을 push하면 거절되는지.
   - 특정 App이 어떤 브랜치도 만들거나 고치거나 지우지 못하게 하는 규칙을 걸 수 있는지(D-25의 자기 저장소와 D-43의 템플릿·`homelab-bot-ops` 차단에 쓴다). 관리자와 배포 App은 그대로 써야 한다. 이 규칙이 막는 것은 브랜치 쓰기까지다. PR 만들기 자체와 읽기는 서버 규칙이 막지 못하고 [확인, 공식 문서], "모든 저장소" 설치에서는 저장소 하나만 설치에서 뺄 수 없다(`spec.md` §11.1). 그래서 같은 시험에서 이미 있는 브랜치를 가리키는 PR 만들기 요청이 서버에서 어떻게 되는지도 적어 둔다. 결과와 상관없이 그 저장소의 PR 요청은 현관 코드가 거절한다(O15).
   - 특정 App이 `bot/` 밖의 브랜치만 만들거나 바꾸지 못하게 하는 규칙을 걸 수 있는지(D-19의 지식 저장소에 반드시 쓰고, 되면 다른 대상 저장소에도 건다). 지금의 `bot/` 규칙은 "`bot/` 아래는 App만"이지 "App은 `bot/` 아래만"이 아니다. Renovate·배포 App처럼 다른 접두를 쓰는 신원이 막히지 않아야 한다.
   - 조직의 비공개 저장소 목록과, Team으로 올리기 전에는 그 저장소들에 규칙이 없다는 것(B-13).
5. 빈틈이 있으면 고칠 안을 적고 관리자 승인을 받는다(GitHub 설정 변경은 외부 변경).

## 완료 조건

- [x] Discord 독자 범위와 민감 답을 보낼 곳이 정해졌다. (2026-11-16 관리자 답: 관리자와 올리브만 읽음, 지금 채널 유지. 에이전트가 화면을 직접 본 것은 아니다)
- [x] main 보호 확인 목록의 각 줄이 됨/안 됨으로 채워졌다. (결과 1. 봇 저장소의 필수 검사가 "안 됨"이다)
- [ ] 4-1의 다섯 항목이 됨/안 됨으로 채워졌다. 안 되는 것이 있으면 `spec.md` §11.1을 같은 변경에서 고쳤다. (앞의 넷은 쓰기 시험 전이라 "못 봄"이다. 다섯째는 읽기로 채웠다)
- [ ] 빈틈이 있으면 고칠 안과 승인 기록이 있다. (고칠 안은 결과 7에 있다. 승인 기록은 아직 없다)

## 검증

- 경계: 설정 읽기. 이 티켓에서 설정을 바꾸지 않는다(바꾸려면 관리자 승인 뒤 별도 실행).
- 잡는 실패: 코딩 App이 main을 갱신·병합할 수 있는 상태. 못 잡는 범위: 관리자 계정 탈취.

## 결과

**읽기 확인은 끝났다. 두 저장소의 main에서 코딩·리뷰 App의 bypass는 없고 직접 갱신도 막혀 있다. 빈틈은 둘이다: 봇 저장소 main에 필수 검사가 없고, 조직이 Free 요금제라 비공개 저장소에는 보호 규칙을 쓸 수 없다. 4-1의 쓰기 시험은 아직 돌리지 않았다.**

**사실 갱신(2026-11-16 저녁):** [확인] 같은 날 19:12~19:15 KST의 읽기 재확인(GET만)에서 조직 요금제는 `team`이었고, 비공개 저장소 1개의 ruleset 조회는 200·규칙 0개, 기본 브랜치 유효 규칙도 0개였다. 위와 5절의 Free·403은 오전의 결과이고 지금 값이 아니다. 그래서 지금 남은 빈틈은 "비공개 저장소에 보호 규칙을 쓸 수 없다"가 아니라 "보호 규칙이 아직 없다"이다. 4-1 쓰기 시험은 준비만 했다. 관리자 결정(2026-11-16 20:45쯤): 4-1은 시험 래퍼부터 만든다(A 좁힌 토큰, B workflows 권한 없는 push 범위. 외부 변경 없음). C·D(임시 ruleset)는 그 결과를 본 뒤 정한다.

- 확인일: 2026-11-16. 에이전트가 한 GitHub 요청은 모두 읽기(GET)다. 설정·규칙·Git 상태를 바꾸지 않았고 토큰을 발급하지 않았다.
- 여기서 코딩 App은 올리브 현관의 `ukyi-writer`, 리뷰 App은 `ukyi-review`다. 관리자의 개발 도구인 `chatgpt-codex-connector`와 구분한다.
- 판정의 뜻: "됨"은 읽기로 확인한 설정이나 공식 문서의 동작 [확인], "안 됨"은 필요한 설정이 없음 [확인], "못 봄"은 실측하지 않았거나 권한이 모자라 미확인 [미확인]이다. "됨"을 App 자격으로 공격·차단을 실측했다는 뜻으로 읽으면 안 된다.
- 설치 ID, 사람·조직 ID, 비공개 저장소의 이름은 적지 않았다. GitHub 설정은 본 때의 값이고 뒤에 바뀔 수 있다.

### 1. main 보호 확인 목록

#### `ukyi-app/homelab`

| 항목 | 판정 | 근거 |
|---|---|---|
| PR 필수 | 됨 | active `main-review`, 대상 `refs/heads/main`, `pull_request` 규칙. `update` 규칙도 있어 PR 승인만 채운 App이 main을 갱신하는 길을 막는다. main의 유효 규칙 조회에도 둘 다 나온다 |
| 필수 검사 | 됨 | 별도 active `main-checks`가 `ci`(GitHub Actions 출처)를 요구한다. bypass는 비어 있다. 최신 base 요구(strict)는 false다 |
| 사람 리뷰 | 됨(예외 있음) | 승인 1, code owner 리뷰, 마지막 push 승인 true. 루트 `CODEOWNERS`가 모든 경로를 관리자 한 사람에게 맡기고 오류가 0개다. 관리자와 병합 App(`ukyi-merge`)은 `pull_request` bypass로 리뷰 규칙을 우회할 수 있다. 그래서 모든 병합마다 서버가 사람의 승인 이벤트를 강제한다는 뜻은 아니다 |
| stale 승인 무효 | 됨 | `dismiss_stale_reviews_on_push: true` |
| force push 금지 | 됨 | `non_fast_forward`가 유효하다. main의 bypass는 PR 전용이고 직접 force push용 `always`가 없다 |
| 삭제 금지 | 됨 | `deletion`이 유효하다. main 삭제를 허용하는 bypass가 없다 |
| 코딩·리뷰 App의 bypass 없음 | 됨 | `main-review`의 bypass는 저장소 관리자 역할과 `ukyi-merge`(둘 다 `pull_request`)뿐이다. `ukyi-writer`, `ukyi-review`, `ukyi-deploy`, Codex Connector, Renovate는 main bypass에 없다. 비활성인 `main-interim`은 근거로 세지 않았다 |
| 자동 병합은 배포 App의 PR뿐 | 됨(구성과 코드로 확인) | GitHub의 `allow_auto_merge`는 false다. `deploy/` 브랜치의 생성·갱신은 `ukyi-deploy`만 bypass한다. 실제 병합 신원은 별도의 `ukyi-merge`이고, main의 `deploy-merge.yaml`과 조건 코드가 아홉 조건을 검사한다. ruleset 자체는 병합 App을 digest PR에만 묶지 못한다. 그 제한은 main의 병합 코드와 키의 경계가 맡는다 |
| 옛 브랜치 보호와 겹치지 않음 | 됨 | 옛 방식의 보호 조회는 404(`Branch not protected`)다. 저장소 admin 권한과 ruleset의 유효 규칙을 함께 봤으므로 이 404를 "main이 무보호"로 읽지 않는다 |

자동 병합의 추가 읽기 근거: `automerge` environment는 `main` 브랜치만 허용한다. homelab의 repository secret과 조직의 Actions secret은 각각 0개다(개수만 봤다). 자격 보관 정책, App 개인키의 보관 상태, 실제 병합 요청은 이번 범위 밖이라 자격 경계 전체를 실증한 것은 아니다.

#### `ukyi-app/homelab-bot`

| 항목 | 판정 | 근거 |
|---|---|---|
| PR 필수 | 됨 | active `app-main`, 대상은 기본 브랜치(지금 `main`). `pull_request`와 `update`가 유효하다 |
| 필수 검사 | **안 됨** | 유효 규칙에 `required_status_checks`가 없고 `app-main` 선언에도 없다. PR에서 `build` 워크플로가 도는 것과 병합 때 그 성공을 강제하는 것은 다르다 |
| 사람 리뷰 | 됨(관리자 예외) | 승인 1, code owner 리뷰 true. `.github/CODEOWNERS`가 모든 경로를 관리자 한 사람에게 맡기고 오류가 0개다. 관리자의 `pull_request` bypass가 있고 마지막 push 승인 요구는 false다. App의 승인만으로 main을 갱신하지 못하게 하는 것은 `update` 규칙과 App bypass가 없다는 점이다 |
| stale 승인 무효 | 됨 | `dismiss_stale_reviews_on_push: true` |
| force push 금지 | 됨 | `non_fast_forward`가 유효하다 |
| 삭제 금지 | 됨 | `deletion`이 유효하다 |
| 코딩·리뷰 App의 bypass 없음 | 됨 | bypass는 저장소 관리자 역할의 `pull_request` 하나뿐이다. App bypass는 없다 |
| 자동 병합 예외 없음 | 됨 | `allow_auto_merge`는 false이고 App의 main bypass가 없다. 현관 이미지의 homelab digest PR 자동 병합과 이 저장소의 코드 PR 병합은 별개다 |
| 옛 브랜치 보호와 겹치지 않음 | 됨 | 옛 방식의 보호 조회는 404이고, 저장소 admin 권한과 active ruleset을 함께 봤다 |

근거가 된 조회: 각 저장소의 ruleset 목록(상위 규칙 포함)과 상세, main의 유효 규칙, 옛 방식의 브랜치 보호, 저장소 설정, CODEOWNERS 내용과 오류([ruleset 조회 API](https://docs.github.com/en/rest/repos/rules)). 두 저장소에 상위 규칙이 더 얹힌 것은 없었다. bypass 칸이 실제 응답에 들어 있었으므로 권한 때문에 빠진 목록을 빈 목록으로 잘못 읽지 않았다.

### 2. 선언과 실제의 차이

**관리 대상 칸에서 어긋남은 없다.** `infra/github`의 선언 네 파일(`locals.tf`, `rulesets.tf`, `guards.tf`, `app-repos.json`)은 로컬과 GitHub main이 바이트 단위로 같았다. Terraform plan·apply와 저장소의 검사 코드는 돌리지 않았다.

- homelab의 ruleset은 선언대로 일곱 개다: `main-interim`(disabled), `main-checks`, `main-review`, `deploy-branches`, `release-tags-lock`, `release-tags-create`, `bot-branches`(active). 대상, ref 조건, 규칙 종류, PR·검사 매개변수, bypass 신원과 모드가 선언과 같다.
- homelab-bot은 선언대로 `app-main` 하나다. `homelab-smoke`는 선언대로 `app-main`과 `bot-branches`가 active다. `writer_repos`(`homelab`, `homelab-smoke`)와 맞는다.
- homelab의 설정(공개, auto-merge 꺼짐, squash만 허용, 병합 뒤 브랜치 삭제, PR 생성은 협업자만)은 guard의 기대와 같다. homelab-bot도 공개이고 PR 생성은 협업자만이다.
- **목표와의 간격:** 봇 저장소의 필수 검사 부재는 선언과 실제가 함께 가진 빈틈이다. D-24·D-25·D-43에 필요한 조직 전체 설치, 자기 저장소 차단, `bot/` 밖 차단은 아직 선언되지 않았다. `bot-branches`는 "`bot/` 안은 writer만"이지 "writer는 `bot/` 안에서만"을 보장하지 않는다.
- guard 아홉 개를 실행한 결과가 아니다. 이 티켓에 해당하는 ruleset·설정·CODEOWNERS·병합 경계만 읽었다.

### 3. 조직의 App과 설치 권한

조직의 설치 목록 조회는 성공했고 설치 여섯 개가 나왔다. 아래는 권한 전체다.

| App | 설치 범위 | 권한 | 판정 |
|---|---|---|---|
| `ukyi-writer`(코딩) | 고른 저장소만 | contents 쓰기, pull_requests 쓰기, metadata 읽기 | 됨: administration·actions·workflows·secrets 항목이 없다 |
| `ukyi-review`(리뷰) | 모든 저장소 | checks·issues·contents·metadata 읽기, pull_requests 쓰기 | 됨: 같은 네 항목이 없다 |
| `ukyi-deploy` | 고른 저장소만 | contents 쓰기, pull_requests 쓰기, metadata 읽기 | |
| `ukyi-merge` | 고른 저장소만 | checks·actions 읽기, contents 쓰기, metadata 읽기, pull_requests 쓰기 | |
| `renovate` | 고른 저장소만 | checks·issues·contents·statuses·workflows·pull_requests 쓰기, members·metadata·packages·administration·vulnerability_alerts 읽기 | |
| `chatgpt-codex-connector` | 고른 저장소만 | issues·actions·contents·workflows·pull_requests 쓰기, checks·metadata·statuses 읽기 | |

- Codex Connector와 Renovate에는 workflows 쓰기가 실제로 있다. 둘은 올리브의 코딩 App과 별개의 신원이다. "조직의 모든 App에 workflows 쓰기가 없다"고 요약하면 틀린다. Codex Connector의 자격을 올리브 현관의 writer 자격으로 다시 쓰면 금지 권한 조건을 만족하지 못한다.
- **못 봄: 고른 저장소의 정확한 목록.** writer와 review의 설치 저장소 목록 조회는 에이전트의 자격 유형으로 403이 났다. "고른 저장소만"인지 "모든 저장소"인지와 권한은 위 조회로 확인했다. writer의 설치가 정확히 `homelab-smoke` 하나라는 계획의 진술(`spec.md` §11.1)은 이번에 다시 증명하지 못했다. 관리자가 조직의 Installed GitHub Apps 화면에서 writer의 Repository access를 확인한다(남은 일).

### 4. 같은 저장소 PR에서 어떤 CI 정의가 도는가

**됨: PR의 변경이 반영된 워크플로 정의와 코드가 병합 전에 돈다 [확인, 공식 문서와 지금 설정].** 기준은 PR의 head만이 아니라 `pull_request` 이벤트의 합성 merge ref(`refs/pull/<번호>/merge`)다. GitHub은 그 이벤트의 commit·ref에 있는 workflow를 고른다([워크플로 버전 선택](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/workflows-and-actions/workflows#workflow-triggers), [pull_request의 merge ref](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)). 지금 `ci`는 `pull_request`를 받고 기본 checkout을 쓰므로 PR이 바꾼 `.github/workflows/ci.yaml`, `tools/ci/`, 실행 대상 코드가 CI에 반영된다. main 보호는 그 전에 도는 PR 코드를 믿을 수 있는 코드로 만들어 주지 않는다.

- 지금 homelab의 `ci`는 `contents: read`, checkout의 `persist-credentials: false`이고 repository·조직의 Actions secret은 0개다. 병합 키를 쓰는 `deploy-merge`는 `workflow_run`만 받고 main의 코드를 checkout하며 `automerge` environment는 main만 허용한다([workflow_run](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)). **지금 PR의 CI에 병합 키가 전달된다는 증거는 없다.**
- 다만 PR 안에서 바뀌는 CI의 workflow 검사는 게시 전의 보안 경계가 될 수 없다. D-07의 "보호 경로는 올리기 전에 확인"은 계속 필요하다.
- homelab-bot의 `build.yaml`도 `pull_request`를 받고 `app-build-v1.0.1` 태그의 공용 workflow를 부른다. 태그에 고정된 공용 workflow와 PR이 바꿀 수 있는 부르는 쪽·checkout 코드를 구분해야 한다.
- PR을 만들거나 CI를 돌려 보는 실험은 하지 않았다.

### 5. 4-1의 다섯 항목

| # | 항목 | 판정 | 지금 아는 것 |
|---|---|---|---|
| 1 | 저장소 하나·필요한 권한만으로 좁힌 설치 토큰, 좁힌 토큰으로 다른 저장소에 쓰면 거절 | 못 봄 | 공식 API는 저장소·권한 축소를 지원한다 [확인, 공식 문서]. 토큰을 발급하거나 써 보지 않았다. 설치가 저장소 하나뿐이면 다른 저장소의 거절은 "설치 범위" 때문일 수 있어 토큰 축소의 독립된 증거가 아니다 |
| 2 | workflows 권한 없는 App의 워크플로 변경 push 거절 | 못 봄 | writer에 workflows 권한이 없다는 것만 확인했다. 실제 Git push와 REST 파일 갱신의 거절은 시험에서 따로 본다 |
| 3 | 특정 App의 모든 브랜치 만들기·고치기·지우기 차단 | 못 봄 | 생성·갱신·삭제 규칙을 모든 신원에 걸고 필요한 신원만 bypass로 허용하는 초안을 썼다. 걸어 보지 않았다. 브랜치 규칙은 PR API와 읽기까지 막는 장치가 아니다 |
| 4 | writer가 `bot/` 밖에 쓰지 못하게 | 못 봄 | 지금 `bot-branches`만으로는 안 된다 [확인]. 전체 브랜치에서 `bot/` 패턴만 뺀 별도 제한 규칙을 초안으로 썼다 |
| 5 | 비공개 저장소 목록과 Team 전의 규칙 유무 | 요금제와 개수는 됨, 보호 사용은 안 됨, 저장된 규칙 수는 못 봄 | 조직 요금제는 `free`이고 비공개 저장소는 1개다(끝 페이지까지 센 개수와 조직의 private 개수가 같았다). 그 저장소의 ruleset 조회와 기본 브랜치 보호 조회는 둘 다 403이고 요금제를 올리거나 공개로 바꾸라는 응답이었다. **지금 비공개 저장소에 보호 기능을 쓸 수 없다는 것은 확인했다.** "API로 규칙 0개를 읽었다"고는 적을 수 없다([요금제별 지원](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#who-can-use-this-feature)) |

- 더 있는 한계 [확인, 공식 문서]: "모든 저장소" 설치에서는 저장소 하나만 설치에서 뺄 수 없다. 요청마다 토큰을 좁히는 것은 App 키를 쥔 현관 자체가 뚫린 경우까지 막지 못한다. D-43이 받아들인 전제이고, 실측 없이 더 강한 보장으로 바꾸지 않는다.
- 쓰기 시험의 절차서는 써 두었다(저장소 밖 검증 기록. 요청 본문, 기대 응답, 담당, 되돌림 포함). 아직 실행하지 않은 제안이다.

시험의 뼈대(쓰기 대상은 `homelab-smoke`의 시험 브랜치·시험 PR·임시 ruleset뿐이고 main 갱신·병합·배포는 없다):

| 시험 | 무엇을 보나 | 선행 조건과 주의 |
|---|---|---|
| A | 저장소 하나와 권한으로 좁힌 설치 토큰. 권한을 읽기로 줄인 토큰의 쓰기 거절, 다른 저장소로 좁힌 토큰의 `homelab-smoke` 쓰기 거절 | "다른 저장소 배제"는 같은 writer 설치에 저장소가 둘 이상 있어야 볼 수 있다. 하나뿐이면 보류하고 별도 승인을 받는다. 운영 저장소에는 거절될 요청도 보내지 않는다 |
| B | workflows 권한 없는 writer의 워크플로 파일 push(Git 전송과 REST를 따로) | 같은 커밋을 관리자 자격으로 올리는 정상 대조는 writer의 실패를 적은 뒤에만 한다 |
| C | 임시 ruleset으로 writer의 모든 브랜치 생성·갱신·삭제 차단. 관리자·배포 App·Renovate 등의 정상 대조 | 임시 규칙은 기존 규칙과 겹쳐 적용된다. 설치나 자격이 없는 신원의 대조는 "못 봄"으로 남긴다 |
| C-PR | C가 걸린 상태에서 이미 있는 브랜치를 가리키는 PR 만들기 | [추론, 공식 문서에서] 만들어질 것으로 본다. 결과와 상관없이 그 저장소의 PR 요청은 현관이 거절한다(O15) |
| D | 임시 ruleset으로 writer를 `bot/` 안에만 가두기. 한 단계·여러 단계 이름, 비슷한 접두, 다른 신원의 정상 대조 | C의 규칙과 동시에 켜지 않는다 |
| E | 요금제와 비공개 저장소의 보호(읽기 재확인) | 쓰기 없음 |

- 되돌림은 관리자가 한다: 임시 규칙 끄기·지우기, 시험 브랜치와 시험 PR 정리, 발급한 토큰 회수, 기존 규칙과 main이 시험 전과 같은지 대조. 삭제 요청은 에이전트가 실행하지 않는다.
- 문서로 가능한 구성도 실측 전에는 "됨"으로 바꾸지 않는다.

### 6. Discord 독자

**됨(관리자의 화면 확인 답에 따름).** 2026-11-16에 관리자가 "확인 완료: 관리자와 올리브만 읽음, 현재 채널 유지"라고 답했다. 에이전트가 Discord 화면을 직접 본 것은 아니다. 독자 이름과 채널 ID는 모으지 않았다.

관리자에게 낸 확인표:

1. 서버의 구성원·봇 목록에 관리자 말고 다른 사람, 올리브 말고 다른 봇이 있는가.
2. 올리브가 쓸 채널·스레드를 관리자와 올리브 말고 볼 수 있는 주체가 있는가(역할·카테고리 상속, 개별 덮어쓰기, Administrator 우회 포함).
3. 다른 독자가 있으면 민감한 상태 답은 비공개 채널이나 DM으로, 없으면 지금 채널 그대로. 공개 검사는 어느 쪽이든 유지한다.

민감한 진단 답도 지금 채널에 쓰고 공개 검사는 유지한다(`discord.md` §7, O08 9번).

### 7. 빈틈과 고칠 안(관리자 승인 전)

아래는 제안이고 승인받은 실행 지시가 아니다. 이 티켓에서 선언과 설정을 고치지 않았다.

- **봇 저장소의 필수 검사:** bypass 없는 별도 checks ruleset을 더해 실제 검사 이름과 GitHub Actions 출처를 요구하는 안을 권한다. 지금 main과 최근 PR head의 실제 check-run 이름은 `build / test`(GitHub Actions, 성공)였다. `build / push`와 `build / deploy-pr`는 최근 PR에서 skipped라 PR 필수 검사로 삼지 않는다. 리뷰 규칙의 관리자 bypass와 검사 규칙을 나눠야 관리자가 검토해 병합할 때도 검사 성공이 요구된다.
- **설치를 넓히기 전의 보호:** B-13대로 Team 전환과 비공개 저장소의 보호를 먼저 끝내고, 막는 저장소의 브랜치 차단, 현관의 PR 요청 거절, 지식 저장소의 `bot/` 밖 차단을 확인한 뒤에 D-24의 설치를 넓힌다. 기존 `bot/` 규칙을 막는 저장소에 그대로 늘리면 관리자의 `bot/` 브랜치 작업도 막힐 수 있다. 허용 목록은 기존 배포·Renovate·개발 App의 권한이 보존되는지 실측해야 한다.
- **새 저장소의 공백:** "모든 저장소" 설치는 새 저장소에도 바로 닿지만, 저장소별 Terraform 규칙은 apply 전까지 없을 수 있다. O15에서 "새 저장소 생성 → 보호 확인 → 현관의 게시 허용" 순서와 조직 차원의 기본 보호가 되는지를 검토한다. 현관의 거절은 App 키가 탈취됐을 때의 서버 보호를 대신하지 못한다.
- **workflows 거절 뒤의 처리:** 시험 B에서 거절이 확인되면, 확인 카드의 승인만으로는 writer가 워크플로 파일을 게시할 수 없다. 그런 변경은 관리자의 개발 세션으로 넘기고, 카드 처리를 위해 writer에 workflows 권한을 더하지 않는 방향으로 O15를 구체화한다.
- **PR 실행 경계:** `.github/`와 CI·자동 병합 정책 코드는 게시 전 확인 대상으로 둔다. Codex Connector의 넓은 권한을 올리브 writer의 자격과 섞지 않는다.

### 8. 남은 일

| 남은 것 | 누가 | 상태 |
|---|---|---|
| 4-1 쓰기 시험(시험 저장소에 시험 브랜치·시험 PR·임시 규칙을 거는 외부 변경) | 관리자 승인 뒤 지정한 실행자 | 관리자가 2026-11-16에 진행하기로 정했다. 실행자, 시각, 외부 변경의 범위는 따로 승인받는다. 추가 설치가 필요한 대조(다른 저장소 배제, 다른 App의 정상 대조)는 별도 승인 전까지 보류한다. 아직 실행하지 않았다 |
| writer 설치의 저장소 목록 확인 | 관리자(GitHub 화면) | 대기 |
| 빈틈의 고칠 안(봇 저장소의 필수 검사 등) | 관리자 결정 | 대기. 어느 티켓이 맡을지도 정해지지 않았다. 봇 저장소의 필수 검사(`build / test`, GitHub Actions 출처)는 관리자가 O15에서 다른 ruleset 변경과 함께 하기로 정했다(2026-11-16) |
| 4-1 결과에 따른 `spec.md` §11.1과 O15의 갱신 | 시험 뒤 | 실패하면 실제 결과에 맞춰 변경안을 만들고 관리자 승인을 받는다 |

### 이 결과로 고친 곳

- `spec.md` §9.4(보낼 곳), §11.1(지금 App 권한과 설치 범위의 확인 범위, 4-1 대기).
- `discord.md` §7(독자 확인), O08 9번, O15 1번(새 저장소의 공백, workflows 거절 뒤의 처리).
