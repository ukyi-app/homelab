# T06 옛 클러스터 철거·외부 자원 정리

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §4.5, §10
- 설계: [../platform/design.md](../platform/design.md) E.1 E1, E.2 E1 행, B.4, B.8 "E1 철거", F D-10·D-11·D-12·D-20
- Blocked by: T05, T02(push), T01(열린 PR 닫기)
- 선행 결정: D-02 (확정: T05 뒤, 부트스트랩 직전), D-10 (확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io 새 체크. 옛 봇 토큰은 T22까지, 옛 ping URL은 T08b까지 보류), D-11 (확정(사용자 2026-10-18, T05): zone·tailnet·`homelab-tfstate`만 이어 쓰고 나머지는 삭제, zone 설정 9개는 T08a의 새 Terraform으로, Tailscale ACL은 (a)), D-12 (확정(사용자 2026-10-18, T05): OS 유지, k3s 제거, 호스트 정리 H1·H2·H3·H7·H8·H9), D-13 (옛 AIOps 줄만. 일부 확정(사용자 2026-10-18): aiops 저장소·App 제거, 실행은 T22), D-20 (확정(사용자 2026-10-18, T05): 옛 자격은 이 티켓에서 폐기, 예외 두 줄), D-26 (확정(사용자 2026-10-18, T05): Codex Connector 유지, 조건 넷), D-27 (확정(사용자 2026-10-18, T05): 로컬 전용 자료는 목록 작성에만 읽기 전용), D-28 (확정(사용자 2026-10-18): 이 티켓의 GitHub 설정 변경은 `gh api`, T10에서 import), D-29 (확정(사용자 2026-10-18): `page`·`trip-mate-api` 삭제, 비앱 저장소 private 보관)
- 연결 AC: AC-P4, AC-X2
- 수행: 사람 (sudo, 콘솔, 삭제). 에이전트는 목록 작성과 대조

## 목표

옛 클러스터를 내리고, 새 Terraform과 충돌할 옛 외부 자원을 정리한다. 옛 자격을 폐기하고, NUC에 남은 옛 호스트 설정과 옛 데이터를 지운다.

이 티켓이 만드는 것은 새 플랫폼이 아니다. 정리 목록·자격 폐기 표의 상태, [approvals.md](../approvals.md) 기록, GitHub 임시 ruleset `main-interim`(T10까지 main 보호. `gh api`로 만들고 T10이 Terraform으로 import)이다.

## 선행 확인 (시작 조건)

여섯 항목이 모두 끝나야 할 일 2 이후를 시작한다.

1. 최신 계획, 설계 문서(`platform/design.md`), T05 결정, 티켓이 원격 `rebuild` 브랜치에 push돼 있다.
2. NUC 로컬 보존 범위(T05 할 일 9). 대상은 명세 §4.5의 "NUC 로컬 전용 자료"다. D-12(확정(사용자 2026-10-18, T05))가 OS 유지라서 NUC 디스크의 자료는 철거 뒤에도 남는다. 그래서 아래 "따로 보존" 두 가지만 저장소 밖·NUC 밖에 옮기고, 나머지는 디스크에 그대로 둔다. 이 티켓이 지우는 것은 SOPS age 키 하나다.
   - **따로 보존: 옛 사본의 로컬 전용 git 작업.** D-12 결과와 무관하게 한다. 옛 사본(`~/workspace/homelab`)의 push 안 된 브랜치와 워크트리를 `git bundle`로 묶어 NUC 밖에 둔다. 예: `git -C ~/workspace/homelab bundle create ~/homelab-local-$(date +%F).bundle --all` 뒤 그 파일을 NUC 밖으로 옮긴다. 미커밋 변경은 번들에 들어가지 않는다. 어떻게 할지 사용자가 정한다.
   - **따로 보존: AdGuard 라이브 설정.** 비밀값을 빼고 내보내 T08a 입력으로 둔다(사람, sudo). 이 파일이 있는 경로는 할 일 2에서 지운다(H8). 파일은 `/var/lib/rancher/k3s-storage/internal/` 아래 AdGuard PVC(`…_edge_adguard-data`)의 `AdGuardHome.yaml`이다. 옛 저장소의 ConfigMap은 첫 부팅 시드라서 라이브 규칙·필터와 다를 수 있다. 사용자 비밀번호 해시와 API 키는 뺀다. LAN 기기 이름과 내부 재작성 규칙이 들어 있으므로 저장소에 커밋하지 않고, 저장소 밖이면서 NUC 밖인 비공개 위치에 둔다. 이 티켓에는 위치만 적는다. 내보낼 때 사용자 규칙·허용 목록·추가 필터 목록의 개수를 세어 D-08 (b′)의 대가 크기로 기록한다(설계 C.3.6).
   - **그대로 두고 할 일 4와 자격 폐기가 끝날 때까지 지우지 않음:** 옛 사본의 `docs/runbooks/`, `.env.secrets`, `infra/{cloudflare,github,tailscale}/backend.hcl`, `infra/{cloudflare,github,tailscale}/terraform.tfvars`. state 처리에 쓰는 자격 파일이다.
   - **보존하지 않음: SOPS age 키 `~/.config/sops/age`.** 새 구조에서 쓰지 않는다. 할 일 6의 다른 자격 폐기가 끝난 것을 확인한 뒤 지운다(D-20). 그 전에는 지우지 않는다.
   - **그대로 둠(따로 보존하지 않음):** 옛 운영 런북 `~/workspace/homelab-infra/`, 원격 없는 다른 프로젝트(`~/workspace/polyrelay` 등), `~/.codex*`, `~/.claude*`, `~/.agents`, `~/.ssh`, `~/.config`, `~/.gnupg`. OS를 유지하므로 디스크에 남고, 이 티켓은 이 경로를 건드리지 않는다. OS 재설치 때만 필요했던 보존 목록이다.
   - **읽기 전용 점검:** 옛 런북(`~/workspace/homelab/docs/runbooks/`, `~/workspace/homelab-infra/`)은 D-27(확정(사용자 2026-10-18, T05))대로 할 일 1의 목록 작성에만 읽기 전용으로 쓴다. `~/workspace/homelab-infra/`에 저장소에 없는 운영 자산이 있는지도 이때 본다(설계 B.9). 값과 절차 원문은 저장소 문서에 옮기지 않고 이름만 옮긴다.
3. 돌아갈 수 없는 지점 확인. T06이 끝나면 옛 홈랩으로 돌아갈 수 없다. 외부 자원이 지워지고, 클러스터 안의 SealedSecrets 봉인 키도 k3s와 함께 사라진다. 시작 전에 사용자가 이를 확인하고 [approvals.md](../approvals.md)에 남긴다.
4. healthchecks.io 체크 `homelab-watchdog`를 철거 전에 일시 정지한다. 철거하면 ping이 끊겨 down 알림이 간다. 옛 체크는 T08b가 새 체크의 초록을 확인한 뒤 지운다(D-10).
5. T01의 열린 PR 닫기가 끝났다(명세 AC-P1). `gh pr list -R ukyi-app/homelab`에 열린 PR이 없다. 할 일 5에서 `gate`를 풀면 남은 PR을 검사 없이 병합할 수 있게 된다.
6. 2026-10-18에 실행한 설계 0절 7항(`page`·`trip-mate-api` 삭제)과 8항(결정 5 하드닝)을 확인 명령으로 다시 본다. `gh api repos/ukyi-app/page`, `gh api repos/ukyi-app/trip-mate-api`, `gh api orgs/ukyi-app/packages/container/page`, `gh api orgs/ukyi-app/packages/container/trip-mate-api`가 모두 404다. `files`와 `homelab-app-template`의 `app-main` ruleset이 active다(`gh api repos/ukyi-app/<저장소>/rulesets --jq '[.[] | {name, enforcement}]'`).

## 할 일

1. 아래 "정리 목록"과 "자격 폐기 표"를 채운다. 시크릿 값은 쓰지 않고 이름·ID만 쓴다.
   - 목록 입력: `gh api`로 실측한 GitHub 상태, `legacy`의 `policy/credential-expiry.json` 전체 행, 옛 Terraform root 선언(`legacy`의 `infra/cloudflare`, `infra/github`, `infra/tailscale`). 로컬 런북(`token-inventory` 등)과 `~/workspace/homelab-infra/`도 D-27(확정(사용자 2026-10-18, T05))대로 읽기 전용 입력으로 쓴다. 이름·ID만 옮기고 값과 절차 원문은 옮기지 않는다. 공개 근거만으로는 코드 밖 자격(콘솔에서 만든 토큰 등)이 빠질 수 있어서다(설계 B.9).
   - 코드 밖 자원(Cloudflare Access 앱·정책 등)은 콘솔에서 다시 조회해 확인한다.
2. 옛 Argo CD를 멈추고, k3s와 NUC 잔여물을 지운다.
   - root 앱이 Application과 ApplicationSet을 selfHeal로 소유한다. 그래서 Application 단위로 자동 동기화를 끄는 것은 효과가 없다. 컨트롤러가 되돌린다.
   - 옛 사본의 kubeconfig(`~/workspace/homelab/infra/k3s-bootstrap/kubeconfig`, sudo 불필요)로 `argocd` 네임스페이스의 `argocd-application-controller`(StatefulSet)와 `argocd-applicationset-controller`(Deployment)를 0으로 줄인다. 두 컨트롤러의 파드가 없는지 확인한다.
   - application-controller를 먼저 줄인다. 옛 Argo CD는 자기 자신도 selfHeal로 관리하므로, application-controller가 살아 있으면 다른 컨트롤러의 축소를 되돌릴 수 있다(추측).
   - 그다음 D-12(OS 유지) 방식으로 k3s를 제거한다(H9). 이때 클러스터 안의 SealedSecrets 봉인 키가 사라진다(선행 확인 3). `k3s-uninstall.sh`는 `/var/lib/rancher/k3s-storage`를 남기므로 옛 데이터 경로는 따로 지운다.
   - AdGuard 설정 내보내기(선행 확인 2)가 끝났는지 확인하고 옛 데이터 경로를 지운다(H8).
   - NUC 호스트 잔여물 중 H1·H2·H3·H7을 지운다. H3 유닛은 옛 사본을 옮기거나 지우기 전에 지운다. H4·H5 drop-in과 `accept-dns=false`는 남긴다(아래 "NUC 호스트 잔여물").
3. 외부 자원을 삭제한다(D-11). `prevent_destroy`가 걸린 버킷은 콘솔에서 지운다. GitHub 쪽(environment, 저장소 변수, 옛 App, ruleset, webhook)은 할 일 5의 순서로 한다.
4. 옛 Terraform state를 처리한다.
   - 옛 state를 다룰 때 Terraform 코어와 provider는 그 state를 마지막으로 쓴 버전 이상을 쓴다(설계 B.8 "E1 철거").
   - github root: destroy하지 않는다. `github_repository.homelab`과 `github_repository.app_template`(`homelab-app-template`, D-21)을 state에서 제거한다. 둘 다 삭제 방지가 없어서 destroy하면 저장소가 지워진다.
   - 옛 state 객체(`homelab-tfstate`의 `cloudflare/prod`, `github/prod`, `tailscale/prod` 아래 `terraform.tfstate`)에는 평문 자격이 들어 있다. 비공개 위치로 옮겨 보관한 뒤 원래 키를 지운다.
   - 새 root는 옛 키를 쓰지 않는다. 같은 키를 쓰면 새 root가 옛 state를 읽어, plan이 옛 자원의 삭제를 제안한다. 새 키 접두는 `v2/`다(D-11).
   - cloudflare·tailscale root: 옛 state는 이어 쓰지 않는다(D-11). 이어 쓰는 zone 설정 9개는 T08a가 새 Terraform으로 가져온다. 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다(제약).
5. 브랜치 보호·ruleset·webhook을 정리한다(사람 승인). 순서는 설계 문서 E1이다. 옛 보호를 지우기 전에 임시 보호를 먼저 건다. 그래야 T10에서 ruleset A~D가 생길 때까지 main이 열리지 않는다(T07부터 Argo CD가 main을 자동 동기화하고, Codex Connector는 contents write가 있다).
   1. 임시 ruleset `main-interim`을 `gh api`로 만든다. 대상 main, PR 필수, 승인 1, code owner 리뷰 필수, 새 push 때 승인 무효화, force push·삭제 금지, bypass는 저장소 관리자 역할(`pull_request` 모드)만.
   2. `main-interim`이 active인지 확인한다: `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .enforcement` → `active`, `gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[].type]'`에 `pull_request`. 같은 때 `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .current_user_can_bypass`(owner) → `pull_requests_only`를 기록한다(U08 셋째 조건).
   3. 확인한 뒤에만 옛 브랜치 보호 전체(`gate`, push 제한 포함)를 지운다: `gh api -X DELETE repos/ukyi-app/homelab/branches/main/protection`. 같은 경로가 404인지 본다. T10부터 Terraform guard 6이 이 404를 계속 확인하므로, 일부만 지우면(필수 검사·push 제한만) 보호 객체가 남아 T10의 guard가 실패한다. `gate`가 남으면 T07의 main 교체 PR이 끝없이 검사를 기다린다.
   4. `gh api -X PATCH repos/ukyi-app/homelab -F allow_auto_merge=false`.
   5. ruleset 2개와 webhook 647791528을 지운다: `gh api -X DELETE repos/ukyi-app/homelab/rulesets/19598965`, `gh api -X DELETE repos/ukyi-app/homelab/rulesets/23257797`, `gh api -X DELETE repos/ukyi-app/homelab/hooks/647791528`. 새 구조는 공개 webhook을 두지 않고 Argo CD가 60초마다 폴링한다(확정(사용자 2026-10-18, T05)).
   6. ruleset을 지운 뒤에 environment 4개, 저장소 변수 2개, 옛 App `ukyi-homelab-reader`·`ukyi-homelab-writer`·`ukyi-homelab-dispatch`(등록이 남았으면)를 지운다(D-11). writer App을 ruleset보다 먼저 지우면 그 접두사 브랜치를 아무도 만들 수 없다(설계 B.8 "E1 철거").
   7. 옛 aiops App(`ukyi-homelab-aiops`)이 homelab에 설치돼 있으면 homelab 설치만 해제한다(App 삭제는 T22). 남아 있으면 그 App의 승인 리뷰가 `main-interim`의 승인 1을 채울 수 있다(추측). 옛 main에는 `CODEOWNERS`가 없어 T07의 main 교체 전까지는 승인 1만 막기 때문이다.
   - 이 단계의 GitHub 설정 변경은 `gh api`로 한다. 새 Terraform github root(D-28)는 T10에서 생기고, 그때 이 단계 뒤에 남는 ruleset을 import한다(T05 할 일 11).
   - `main-interim`은 T10이 ruleset B가 걸린 것을 확인한 뒤에만 끈다.
6. 자격 폐기 표대로 폐기한다(D-20). state 처리에 쓰는 자격은 할 일 4가 끝난 뒤 마지막에 폐기한다. 표의 다른 폐기가 모두 끝난 것을 확인한 뒤 SOPS age 개인 키(`~/.config/sops/age`)를 지운다(D-20).
7. 선행 확인과 할 일 2~6의 모든 실행을 [approvals.md](../approvals.md)에 기록한다. 식별자만 쓰고 값은 쓰지 않는다.
8. T07의 main 병합 전에, 이 티켓의 정리 목록·자격 폐기 표 상태와 approvals.md를 `rebuild`에 커밋하고 push한다(사람 승인, 명세 §12). 이 티켓에는 이름·ID·상태만 있으므로 공개돼도 된다.

## 정리 목록 (할 일 1의 최소 범위)

2026-10-17 실측과 `legacy` 선언 기준이다. 실행할 때 다시 조회해 빠진 줄을 더한다. 처리 방향은 D-11(확정(사용자 2026-10-18, T05), 설계 F D-11 표)이다: Cloudflare zone, tailnet, R2 `homelab-tfstate`만 이어 쓰고 나머지는 지운 뒤 새로 정의한다.

### Cloudflare

- 터널 `homelab-prod`: 삭제. 새 터널은 T08a가 정의한다.
- DNS 레코드: 삭제. 라이브 공개 이름은 `ukyi.app`, `www`, `argocd-webhook`, `files` 등이다. 새 레코드는 T08a가 정의한다.
- WAF 규칙 `homelab-waf-custom`, `homelab-waf-ratelimit`. 캐시 규칙 `homelab-cache-rules`: 삭제. 새 규칙은 T08a가 정의한다.
- zone `ukyi.app`: 유지(D-11).
- zone 설정 9개: HSTS(includeSubDomains, 180일), `always_use_https`, `min_tls_version` 1.2, `tls_1_3`, `opportunistic_encryption` off, `automatic_https_rewrites`, `browser_check`, `security_level` medium, `email_obfuscation`. D-11대로 값을 유지한 채 T08a의 새 Terraform으로 가져온다(HSTS preload는 끔). 줄 상태는 `import 예정(D-11, T08a)`. zone이 남으므로 옛 state를 버려도 이 설정은 Cloudflare에 그대로 남는다.
- Access 앱·정책 등 코드 밖 자원. 콘솔에서 다시 조회해 확인한다.

### R2

- `homelab-pg-backups-prod`, `homelab-media-prod`: 삭제. `prevent_destroy`가 걸려 있어 콘솔에서 지운다.
- `homelab-cache-backups-prod`: 삭제.
- `homelab-tfstate`: 유지(D-11). 새 root는 키 접두 `v2/`를 쓴다. 그 안의 옛 state 객체는 할 일 4에서 처리한다.

### Tailscale

- tailnet: 유지(D-11).
- tagged 기기 `homelab-1`, `pg-rw-1`: 삭제.
- operator 기기 `homelab-operator`: 삭제. NUC에서는 ACL 때문에 보이지 않아 존재를 먼저 확인한다.
- OAuth 클라이언트 3종: 삭제. owner 부트스트랩(Terraform 밖, 쓰기 스코프), CI 읽기 전용, operator.
- NUC 노드 키 만료 설정. 2026-10-17에는 만료가 해제돼 있다. D-12가 OS 유지라 NUC는 다시 등록하지 않고 지금 등록 그대로 남는다(설계 C.3.2). OS를 다시 설치하게 되면 만료가 기본값(켜짐)으로 돌아오고 Tailscale IP가 바뀔 수 있다. 그러면 만료를 다시 해제하고 전역 nameserver의 NUC 주소를 고친다. T08a의 Terraform(D-08)은 hostname으로 NUC를 찾아 새 IP를 쓰고, 만료 해제를 precondition으로 확인한다.
- ACL·DNS: 옛 root를 apply도 destroy도 하지 않는다. 새 코드(T08a)가 덮어쓴다. DNS는 D-08(확정(사용자 2026-10-18))대로 Terraform `tailscale_dns_configuration`이 맡는다. 새 ACL은 D-11 (a)(확정(사용자 2026-10-18, T05))다: NUC는 태그 없는 사용자 기기로 두고, 옛 `autogroup:self` 규칙과 ssh 규칙(`accept`, `autogroup:nonroot`·`root`)을 유지한다. 그래야 NUC 원격 접속이 끊기지 않는다. (c) `tag:nuc`로 바꿀지는 T08a가 U28 결과로 다시 본다.

### GitHub

- App 4개:
  - `ukyi-homelab-reader`(4043034), `ukyi-homelab-writer`(4043080): 삭제(D-11). writer는 ruleset 2개를 지운 뒤에 지운다(할 일 5).
  - `ukyi-homelab-aiops`(4937062): 제거(D-13 일부 확정, 2026-10-18). 실행은 T22라 이 티켓의 줄 상태는 `보류(D-13, T22)`.
  - `ukyi-homelab-dispatch`(4178609): org 설치는 없다. 등록만 남았는지 확인하고, 남았으면 삭제(D-11).
- ChatGPT Codex Connector: 유지(D-26, 확정(사용자 2026-10-18, T05)). 줄 상태는 `유지(D-26)`. 설계 0절 실측으로 org 전체 저장소에 actions·contents·issues·pull_requests·workflows write다. 유지 조건 넷은 설계 F D-26이다(어떤 ruleset bypass에도 넣지 않음 등). 설치 범위 축소는 D-16(T15)과 함께 본다.
- environment 4개: `homelab-main`(secret 19개), `aiops-authority-empty-0915`, `aiops-authority-empty-0916`, `aiops-reusable-public-0915`(secret 1개). 삭제(D-11).
- "저장소 시크릿"은 실제로 environment `homelab-main`의 secret이다. 저장소 수준 secret은 0개다.
- 저장소 변수 2개: `HOMELAB_DOMAIN`, `HOMELAB_OWNER`. 삭제(D-11).
- 저장소 설정 `allow_auto_merge`: `true`(설계 0절 4항 실측). 할 일 5에서 `false`로 바꾼다. D-07(확정(사용자 2026-10-18, T05))도 GitHub auto-merge 허용을 끈다.
- ruleset 2개: 19598965 `bump-poll-writer-only`, 23257797 `mutation-branches-writer-only`. 둘 다 브랜치 생성·갱신을 막고 writer App만 우회한다. writer App을 지우면 ruleset이 남아 있는 동안 그 접두사(`bump-poll/`, `bump/`, `create-app/`, `create-database/`, `create-cache/`, `update-secrets/`)의 브랜치는 아무도 만들 수 없다. 그래서 할 일 5에서 지운다.
- 저장소 webhook 647791528: push 이벤트를 `argocd-webhook.ukyi.app`으로 보낸다. 터널을 지운 뒤에는 전송이 계속 실패한다. 삭제(할 일 5). 새 구조에는 Argo CD 공개 webhook이 없다.
- 브랜치 보호(main): 필수 검사 `gate`, push 제한(users `ukkiee`, apps writer). 할 일 5에서 `main-interim`을 건 뒤 전체를 지운다.
- GHCR 패키지 6개: `pg-tools`, `skopeo`, `page`, `trip-mate-api`, `files`, `aiops-autodeploy-canary`.
  - `page`, `trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29, [../approvals.md](../approvals.md)). `page` 패키지는 API 삭제가 거부돼(아래) 사람이 직접 지웠다.
  - `pg-tools`, `skopeo`: 삭제(D-11, 소비자 없음). public 패키지는 한 버전이라도 다운로드가 5000회를 넘으면 API로 지울 수 없다(2026-10-18 `page`에서 HTTP 400). 그날 UI의 전체 다운로드는 `skopeo` 1.76k, `pg-tools` 973, `aiops-autodeploy-canary` 9.37k(private라 이 제한과 무관)였다. API가 거부하면 사람이 직접 지운다.
  - `files`: T22까지 유지(D-11). 줄 상태는 `유지(T22 재연결 대상)`.
  - `aiops-autodeploy-canary`: 저장소 처리와 함께 T22(D-11). 줄 상태는 `보류(D-13, T22)`.
- 앱 저장소 `ukyi-app/page`, `ukyi-app/trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29). 쓰지 않는 앱이다. 두 앱의 옛 자격은 자격 폐기 표에서 폐기한다.

### 외부 감시·알림

- healthchecks.io: 계정은 이어 쓰고 체크는 새로 만든다(D-10). 옛 체크 `homelab-watchdog`는 선행 확인 4에서 일시 정지하고, T08b가 새 체크의 초록을 확인한 뒤 지운다(D-11). 줄 상태는 `보류(D-10, T08b)`.
- Telegram 봇: homelab 알림용 새 봇은 T09가 만든다(D-10). 옛 봇과 토큰은 `mac-uptime-guard`를 처리하는 T22까지 그대로 둔다. 줄 상태는 `보류(D-10, T22)`. 토큰은 자격 폐기 표에 있다.

### 옛 AIOps 저장소

- `ukyi-app/aiops`와 App `ukyi-homelab-aiops`: 제거(D-13 일부 확정, 2026-10-18. aiops는 쓰지 않는다). 실행은 T22라 줄 상태는 `보류(D-13, T22)`.
- `ukyi-app/aiops-autodeploy-canary`: 공개하지 않고 private로 보관(D-29, 삭제도 가능). 실행은 T22라 줄 상태는 `보류(D-13, T22)`.
- `mac-uptime-guard`(private, 옛 맥 미니용, 옛 Telegram 토큰 사용): 공개하지 않고 private로 보관(D-29). 줄 상태는 `보류(담당 T22)`.

### NUC 호스트 잔여물 (D-12)

D-12(확정(사용자 2026-10-18, T05))는 OS를 유지하고 설계 B.4의 H1·H2·H3·H7·H8·H9를 지운다. H4·H5는 남기고 T07의 새 호스트 설정이 같은 이름으로 덮어쓴다. 줄마다 B.4의 ID를 단다.

옛 AIOps:

- H1 유닛: `aiops-ingress.service`, `aiops-worker.service`(static)·`aiops-worker.timer`, `homelab-aiops-nft.service`, `'var-lib-homelab\x2daiops.mount'`. 순서는 timer·ingress 비활성 확인 → nft 서비스·table 제거 → mount 해제 → 이미지 파일 삭제다(설계 B.4).
- mount 유닛 이름의 `\x2d`는 systemd 경로 이스케이프다. 셸에서는 작은따옴표로 감싸거나 `systemctl status /var/lib/homelab-aiops`처럼 경로로 지정한다. 이스케이프 없는 이름으로 조회하면 not-found가 나와 "이미 없음"으로 잘못 닫힌다. 2026-10-17에는 active이고, loop 이미지 위의 ext4다.
- H2 파일: `/var/lib/homelab-aiops.img`, `/opt/homelab-aiops`, `/etc/homelab-aiops`(AIOps App 개인 키), `/usr/local/libexec/homelab-aiops-ingress-firewall.py`, `/etc/nftables.d/homelab-aiops.nft`, drop-in(`aiops-ingress.service.d/*`, `aiops-worker.service.d/*`), `/etc/tmpfiles.d/homelab-aiops.conf`. 파일은 이 티켓에서 지운다. `/etc/homelab-aiops`의 App 키 폐기는 옛 aiops App 삭제와 함께 T22에서 한다(D-29, 자격 폐기 표의 `보류(D-13, T22)`).
- H2 시스템 사용자 `aiops-*` 8개와 그룹 `aiops-state`. `aiops-proxy`의 CLIProxyAPI 저장소에 ChatGPT 구독 OAuth가 있다.

옛 `host-config.sh --apply`가 깐 것:

- H3 유닛(지움): `files-data-backup.service`·`.timer`, `systemd-failed-sweep.service`·`.timer`, `unit-failure-notify@.service`. 셋 다 옛 사본(`~/workspace/homelab/scripts/`)의 스크립트를 실행하고, `files-data-backup`은 옛 사본의 kubeconfig도 쓴다. 옛 사본을 옮기거나 지우기 전에 지운다.
- H4 drop-in(남김): `sshd_config.d/10-k3s-node.conf`, `journald.conf.d`, `tmpfiles.d`(NVMe ASPM). T07의 `host/etc/`가 같은 이름으로 덮어쓴다.
- H5 노드 DNS 순환을 막는 설정(남김): `resolved.conf.d/10-k3s-node.conf`, `10-netplan-wlo1.network.d`, `/etc/resolv.conf` 심링크. `tailscale set --accept-dns=false`도 같은 목적이다(명세 §4.5). 대체 없이 지우면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 다시 생길 수 있다. 그래서 이 티켓은 지우지 않고 T07의 새 호스트 설정이 같은 일을 맡는다.
- H6 fstab의 swap 제거: 2026-10-17 실측으로 swap 항목이 없다. 할 일 없음. T07 preflight가 스왑 없음을 확인한다.

H7 옛 `infra/k3s-bootstrap/motd`가 깐 것(지움): `motd-refresh.service`·`.timer`, `/etc/update-motd.d/00-ukyi`, `/usr/local/share/ukyi-motd/`. `motd-refresh`에는 저장소에 없는 drop-in `10-user.conf`가 있다(설계 B.4 실측). 함께 지운다.

### 옛 데이터 경로 (D-12, H8)

- `/var/lib/rancher/k3s-storage`: 옛 PV 데이터(AdGuard 설정 포함). `k3s-uninstall.sh`는 `/var/lib/rancher/k3s`, `/var/lib/kubelet`, `/etc/rancher/k3s`만 지우고 이 경로를 남긴다.
- `/mnt/bulk`와 그 fstab 항목: 별도 1.8T 디스크, 옛 files 데이터(C-03 폐기 대상). D-12대로 비우고 fstab 항목을 지운다. 새 구조에서는 쓰지 않는다.
- `/var/backups/files-data`: `files-data-backup.timer`가 매일 쓴다.
- `/var/lib/homelab-aiops.img`: AIOps loop 이미지(옛 AIOps 줄과 같은 파일).
- 마운트 여부는 `findmnt -T`로 판정하지 않는다. 마운트 여부를 증명하지 못한다(설계 B.8 "E1 철거").

H9 `k3s.service`: 할 일 2에서 제거한다(D-02, D-12).

## 자격 폐기 표 (할 일 1·6)

새로 발급해도 옛 자격은 따로 폐기하기 전까지 살아 있다. 각 줄을 `폐기 / 유지(이유) / 보류(결정 ID, 담당 티켓)` 중 하나로 정한다. 값은 쓰지 않는다.

D-20(확정(사용자 2026-10-18, T05))에 따라 새 플랫폼은 모든 값을 새로 발급하고(T09), 옛 자격은 이 티켓에서 폐기한다. 철거 뒤에는 옛 자격을 쓰는 곳이 없기 때문이다. 예외는 아래 두 줄뿐이다. 그래서 `보류(…, T09)`로 미리 정한 줄은 없다. 실행 중 그런 줄이 생기면 T09가 새 자격을 등록한 뒤 닫는다. SOPS age 개인 키도 보류하지 않고, 이 표의 다른 폐기가 끝난 것을 확인한 뒤 마지막에 지운다(할 일 6).

**예외: 옛 healthchecks ping URL은 `보류(D-10, T08b)`로 둔다.** 체크는 선행 확인 4에서 일시 정지돼 있다. D-10대로 healthchecks.io 계정은 이어 쓰고 체크는 새로 만든다. T08b가 새 외부 생존 감시를 연결하고 정상(초록)을 확인한 뒤 옛 체크를 지우며 이 줄을 닫는다.

**예외: 옛 Telegram 봇 토큰은 이 티켓에서 폐기하지 않는다.** 저장소 밖의 `mac-uptime-guard`가 같은 토큰을 쓰기 때문에, 폐기하면 그쪽 알림이 아무 표시 없이 끊긴다. 줄은 `보류(D-10, T22)`로 둔다. D-10은 homelab 알림용 새 봇(T09가 만듦)을 골랐다. 그래서 T22가 `mac-uptime-guard`를 처리한 뒤 옛 봇 토큰을 폐기하고 옛 봇을 지우며 이 줄을 닫는다. 옛 봇 토큰을 재발급하는 대안은 고르지 않았으므로 T09가 이 줄을 닫는 일은 없다.

**순서:** state 처리에 쓰는 자격(`r2-terraform-state`, `cf-tf-root-token` 등)은 할 일 4가 끝난 뒤에 폐기한다. 먼저 폐기하면 할 일 4가 막힌다.

| 자격 | 무엇 | 주의 |
|---|---|---|
| `ghcr-pull-pat` | GHCR 읽기용 classic PAT, 무만료 | 새 구조에는 GHCR pull 자격이 없다(D-29) |
| `github-tf-root-pat` | github root용 PAT(Administration·Secrets 읽기·쓰기), 무만료 | |
| `github-tf-ci-pat` | CI 읽기용 PAT | |
| `tailscale-ci-oauth-client` | Tailscale CI 읽기 전용 OAuth 클라이언트 | owner 부트스트랩 OAuth와 별개 |
| `r2-terraform-state` | `homelab-tfstate` 접근 R2 키 | 할 일 4 뒤 |
| `ts-node-key-nuc` | NUC 노드 키(만료 해제) | 폐기하면 NUC가 tailnet에서 빠져 Tailscale 경로의 원격 접속이 끊긴다. D-12가 OS 유지라 NUC는 지금 등록 그대로 tailnet에 남는다(설계 C.3.2) |
| `argocd-github-webhook` | webhook 647791528의 secret | webhook 삭제(할 일 5)와 함께. 새 구조에는 공개 webhook이 없다(60초 폴링) |
| `github-dispatch-app` | App `ukyi-homelab-dispatch`(4178609) | 설치는 없다. 등록이 남았는지 확인 |
| `cf-tf-root-token` | Cloudflare 토큰 `homelab-terraform-cloudflare`(Account·Zone Edit) | 할 일 4 뒤 |
| `cf-certmanager-token` | Cloudflare 토큰 `homelab-certmanager-dns01` | 새 구조에는 대응 토큰이 없다(D-08) |
| `r2-backups-pg-cache` | 백업 버킷용 R2 키 `homelab-backups-pg-cache` | |
| 옛 App 키 | `ukyi-homelab-reader`, `ukyi-homelab-writer` | `ukyi-homelab-aiops` 키는 `보류(D-13, T22)`. T22가 App 제거(D-13 일부 확정)와 함께 폐기한다 |
| Tailscale 부트스트랩 OAuth | owner 로컬용, Terraform 밖, 쓰기 스코프 | |
| Tailscale operator OAuth | 옛 operator용(devices:core·auth_keys) | |
| Telegram 봇 토큰 | 옛 알림 봇 | `보류(D-10, T22)` 고정(위 예외). `mac-uptime-guard`도 이 봇을 쓴다 |
| healthchecks ping URL | `homelab-watchdog` 체크 | `보류(D-10, T08b)` 고정(위 예외). 옛 체크 삭제도 T08b(D-11) |
| `trip-mate-api` Google OAuth client | `trip-mate-api` 로그인용 Google OAuth 클라이언트 | 앱 삭제로 폐기(D-29). Google Cloud 콘솔에서 지운다 |
| `trip-mate-api` OXR app id | `trip-mate-api`가 쓰던 OXR app id | 앱 삭제로 폐기(D-29). 발급처 계정에서 폐기한다 |
| `trip-mate-api` `BETTER_AUTH_SECRET` | `trip-mate-api`의 Better Auth 비밀값 | 앱 삭제로 폐기(D-29). 외부 발급처가 없는 값이라 저장된 사본이 남지 않았는지 확인하고 닫는다 |
| `page` admin token | `page` 관리자 토큰 | 앱 삭제로 폐기(D-29). 저장된 사본이 남지 않았는지 확인하고 닫는다 |
| SealedSecrets 봉인 키 | 클러스터 안의 키는 k3s 제거로 사라진다 | out-of-band 백업본이 있으면 그 처리도 정한다 |
| SOPS age 키 | `~/.config/sops/age` | 옛 SOPS 파일의 recipient와 맞으면 옛 공개 히스토리의 SOPS 파일을 풀 수 있다(일치 여부 미확인). 새 구조에서 쓰지 않는다. D-20대로 할 일 4와 이 표의 다른 폐기가 끝난 것을 확인한 뒤 지운다(보류 아님) |

## 필요한 자격

이 티켓은 새 자격을 쓰지 않는다. 모두 기존 계정과 옛 자격이라 준비하는 앞 티켓이 없다.

- 옛 사본의 kubeconfig(`~/workspace/homelab/infra/k3s-bootstrap/kubeconfig`): 할 일 2의 컨트롤러 축소.
- 옛 Terraform 자격(옛 사본의 `.env.secrets`, `backend.hcl`, `terraform.tfvars`): 할 일 4의 state 처리. 이 티켓에서만 쓰고 할 일 6에서 폐기한다.
- GitHub owner 계정(`gh` 로그인, 저장소 관리자): 할 일 1의 실측, 할 일 5의 보호·ruleset·App 정리.
- Cloudflare·R2·Tailscale·healthchecks.io 콘솔 로그인: 할 일 1의 재조회, 할 일 3의 삭제, 선행 확인 4의 일시 정지.
- 자격 폐기 표의 발급처 콘솔(Google Cloud, OXR 등): 할 일 6.
- NUC sudo: 할 일 2, 선행 확인 2의 AdGuard 내보내기.

## 제약

- 저장소는 유지한다(C-01). Cloudflare zone, tailnet, `homelab-tfstate` 버킷도 유지한다(D-11).
- 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다. apply하면 Cloudflare 임시 DNS 폴백(C-05)이 사라진다. ACL·DNS는 새 코드(T08a)가 덮어쓴다.
- 노드 DNS drop-in(H5)과 `accept-dns=false`, sshd·journald·tmpfiles drop-in(H4)은 지우지 않는다. T07의 새 호스트 설정이 같은 이름으로 덮어쓴다(D-12).
- 파괴 명령은 확인 env가 있어야 도는 별도 파일로 두고, 에이전트는 파괴 명령을 실행하지 않는다. 옛 감사에서 에이전트가 파괴 한 줄을 실증하려고 실행해 라이브 클러스터를 파괴한 일이 있다(설계 B.8 "E1 철거").
- 맥 `~/Documents/`의 옛 프롬프트 원본 사본은 지우지 않는다.
- 옛 사본(`~/workspace/homelab`)은 할 일 4, 자격 폐기, 호스트 유닛 제거가 끝날 때까지 옮기거나 지우지 않는다. 호스트 유닛이 그 안의 스크립트를 실행하고, state 처리에 쓰는 파일과 kubeconfig가 그 안에 있다.
- 이 시점부터 AdGuard가 없다. LAN은 공유기 보조 DNS, Tailscale 기기는 Cloudflare 임시 DNS로 동작한다.

## 완료 조건

- 정리 목록과 자격 폐기 표의 모든 줄이 `삭제됨 / 유지(이유) / import 예정 / 보류(결정 ID 또는 담당 티켓)` 중 하나다. 자격 폐기 표의 `폐기`는 실행을 마치면 `삭제됨`으로 적는다.
- 자격 폐기 표의 옛 Telegram 봇 토큰 줄은 `보류(D-10, T22)`, 옛 healthchecks ping URL 줄은 `보류(D-10, T08b)`다. 두 줄은 폐기하지 않는다.
- 설계 문서 0절 3항(옛 클러스터 정리), 4항(브랜치 보호와 ruleset 정리), 6항(옛 Terraform state 처리)이 "완료"다.
- main에 `main-interim`만 active이고, 옛 브랜치 보호는 404이며, `allow_auto_merge`는 `false`다.
- NUC에서 k3s와 H1·H2·H3·H7의 유닛·파일이 없다. H8 데이터 경로는 지웠고 `/mnt/bulk`는 비운 뒤 fstab 항목을 지웠다. H4·H5는 남아 있다.
- 할 일 8의 커밋·push가 끝났다.

## 검증

- Cloudflare, R2, Tailscale, GitHub 목록을 다시 조회해 정리 목록과 대조한다.
- GitHub, Cloudflare, Tailscale의 자격 목록을 다시 조회해 자격 폐기 표와 대조한다.
- `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`가 성공한다. `systemctl is-active k3s`는 멈추기만 한 상태도 `inactive`로 통과시키므로 쓰지 않는다.
- `systemctl list-unit-files | grep -E 'aiops|files-data|systemd-failed-sweep|unit-failure|motd-refresh'`의 결과가 비어 있다. D-12에서 남기기로 한 유닛은 제외한다.
- `systemctl status /var/lib/homelab-aiops`(경로로 조회)가 유닛 없음이고, `findmnt /var/lib/homelab-aiops`의 결과가 비어 있다.
- 옛 데이터 경로가 D-12 판정대로 처리됐다: `/mnt/bulk`는 비었고 `/etc/fstab`에 그 항목이 없다. `/var/backups/files-data`, `/var/lib/homelab-aiops.img`는 없다.
- `gh api repos/ukyi-app/homelab --jq .archived`가 `false`다.
- `gh api repos/ukyi-app/homelab/rulesets --jq '[.[] | {name, enforcement}]'`가 `main-interim` 하나, `active`다. `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .current_user_can_bypass`(owner)가 `pull_requests_only`다(U08 셋째 조건). `gh api repos/ukyi-app/homelab/branches/main/protection`이 404다. `gh api repos/ukyi-app/homelab --jq .allow_auto_merge`가 `false`다. 옛 aiops App이 homelab에 설치돼 있지 않다(`gh api orgs/ukyi-app/installations`의 그 App `repository_selection`이 `all`이면 설치된 것이고, `selected`면 org 설정의 설치된 App 화면 Repository access에서 homelab이 없는지 본다).
- `gh api repos/ukyi-app/page`와 `gh api repos/ukyi-app/trip-mate-api`가 404다(설계 0절 7항).
- `tailscale dns status`가 C-05 그대로이고, 이 노드는 "Tailscale DNS: disabled"다(H5 유지).
- [approvals.md](../approvals.md)에 선행 확인 3의 사용자 확인과 이 티켓의 외부 변경이 모두 있다.

## 되돌리는 방법

- 컨트롤러 축소까지는 replicas를 되돌리면 옛 Argo CD가 돌아온다.
- k3s 제거와 외부 자원·자격 삭제는 되돌릴 수 없다. 그래서 선행 확인 3에서 사람이 확인하고 [approvals.md](../approvals.md)에 남긴다.
- 옛 브랜치 보호·ruleset 해제는 정리 목록에 남긴 옛 설정으로 다시 만들 수 있다.
- 임시 ruleset `main-interim`은 되돌리지 않고 T10까지 둔다.
- 되돌리기 실행도 [approvals.md](../approvals.md)에 기록한다.
