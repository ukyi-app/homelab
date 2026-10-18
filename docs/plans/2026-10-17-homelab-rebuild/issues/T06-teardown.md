# T06 옛 클러스터 철거·외부 자원 정리

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 진행 중 (2026-10-18 할 일 1 실측 완료. 선행 확인 2·3·4는 사람 작업 대기)
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
2. NUC 로컬 보존 범위(T05 할 일 9). 대상은 명세 §4.5의 "NUC 로컬 전용 자료"다. D-12(확정(사용자 2026-10-18, T05))가 OS 유지라서 NUC 디스크의 자료는 철거 뒤에도 남는다. 그래서 아래 "따로 보존" 두 가지만 저장소 밖·NUC 밖에 옮기고, 나머지는 디스크에 그대로 둔다. 이 티켓이 지우는 로컬 자료는 SOPS age 키(cluster), `/mnt/bulk/homelab-backups`(선행 확인 3), 내보낸 뒤의 AdGuard PVC(H8)다.
   - **따로 보존: 옛 사본의 로컬 전용 git 작업.** D-12 결과와 무관하게 한다. 옛 사본(`~/workspace/homelab`)의 push 안 된 브랜치와 워크트리를 `git bundle`로 묶어 NUC 밖에 둔다. 예: `git -C ~/workspace/homelab bundle create ~/homelab-local-$(date +%F).bundle --all` 뒤 그 파일을 NUC 밖으로 옮긴다. 미커밋 변경은 번들에 들어가지 않는다. 어떻게 할지 사용자가 정한다. 2026-10-18 실측: 로컬 브랜치 20개 중 15개에 원격 추적 ref에 없는 커밋이 있고(합계 20개), 워크트리 10개(그중 3개 prunable), stash 0, 미커밋 파일 48개다. 마지막 fetch가 2026-09-23이라 원격 대비 판정은 바뀔 수 있다. gitignored인 `.scratch`(옛 사본 117G의 대부분)도 번들에 들어가지 않는다.
   - **따로 보존: AdGuard 라이브 설정.** 비밀값을 빼고 내보내 T08a 입력으로 둔다(사람, sudo). 이 파일이 있는 경로는 할 일 2에서 지운다(H8). 파일은 `/var/lib/rancher/k3s-storage/internal/` 아래 AdGuard PVC(`…_edge_adguard-data`)의 `AdGuardHome.yaml`이다. 옛 저장소의 ConfigMap은 첫 부팅 시드라서 라이브 규칙·필터와 다를 수 있다. 사용자 비밀번호 해시와 API 키는 뺀다. LAN 기기 이름과 내부 재작성 규칙이 들어 있으므로 저장소에 커밋하지 않고, 저장소 밖이면서 NUC 밖인 비공개 위치에 둔다. 이 티켓에는 위치만 적는다. 내보낼 때 사용자 규칙·허용 목록·추가 필터 목록의 개수를 세어 D-08 (b′)의 대가 크기로 기록한다(설계 C.3.6).
   - **그대로 두고 할 일 4와 자격 폐기가 끝날 때까지 지우지 않음:** 옛 사본의 `docs/runbooks/`, `.env.secrets`, `infra/{cloudflare,github,tailscale}/backend.hcl`, `infra/{cloudflare,github,tailscale}/terraform.tfvars`, `infra/tailscale/terraform.tfvars.pre-cutover.bak`, `infra/{cloudflare,github,tailscale}/.terraform/terraform.tfstate`(백엔드 설정 캐시, 0644, 자격 포함 추정). state 처리에 쓰는 자격 파일이거나 그 사본이다.
   - **보존하지 않음: SOPS age 키 `~/.config/sops/age`.** 새 구조에서 쓰지 않는다. 할 일 6의 다른 자격 폐기가 끝난 것을 확인한 뒤 지운다(D-20). 그 전에는 지우지 않는다.
   - **그대로 둠(따로 보존하지 않음):** 옛 인계·계획 문서 `~/workspace/homelab-infra/`(git 아님, 파일 77개: Markdown 41개와 macOS `._` 사이드카 36개), 원격 없는 다른 프로젝트(`~/workspace/polyrelay` 등), `~/.codex*`, `~/.claude*`, `~/.agents`, `~/.ssh`, `~/.config`, `~/.gnupg`. OS를 유지하므로 디스크에 남고, 이 티켓은 이 경로를 건드리지 않는다. OS 재설치 때만 필요했던 보존 목록이다.
   - **읽기 전용 점검:** 옛 런북(`~/workspace/homelab/docs/runbooks/`, `~/workspace/homelab-infra/`)은 D-27(확정(사용자 2026-10-18, T05))대로 할 일 1의 목록 작성에만 읽기 전용으로 쓴다. `~/workspace/homelab-infra/`에 저장소에 없는 운영 자산이 있는지도 이때 본다(설계 B.9). 값과 절차 원문은 저장소 문서에 옮기지 않고 이름만 옮긴다. 2026-10-18에 마쳤다(아래 "할 일 1 결과"). `~/workspace/homelab-infra/`에는 저장소에 없는 운영 자산이 없다(인계·계획 문서뿐). 그래서 설계 B.9 셋째 줄(`homelab-infra`)과 첫째 줄(자격 폐기 표 완전성, 로컬 런북 대조)은 이 결과로 닫는다.
3. 돌아갈 수 없는 지점 확인. T06이 끝나면 옛 홈랩으로 돌아갈 수 없다. 외부 자원이 지워지고, 클러스터 안의 SealedSecrets 봉인 키도 k3s와 함께 사라진다. `/mnt/bulk` 비우기(H8)는 확인된 유일한 봉인 키 디스크 백업(`homelab-backups/sealed-secrets`, 1개. `/mnt/bulk`의 나머지와 `/mnt/bulk-new` 내용은 sudo 확인 전)과 로컬 런북 암호화 사본(6개)도 함께 지운다(2026-10-18 실측). 런북 원본은 옛 사본에 그대로 남는다. 시작 전에 사용자가 이를 확인하고 [approvals.md](../approvals.md)에 남긴다.
4. healthchecks.io 체크 `homelab-watchdog`를 철거 전에 일시 정지한다. 철거하면 ping이 끊겨 down 알림이 간다. ping은 호스트가 아니라 클러스터 안 `deadmanswitch-relay`가 보낸다(`2d2054a:platform/victoria-stack/prod/deadmanswitch-relay.yaml`). 옛 relay가 1분마다 ping하고 일시 정지는 ping 한 번에 풀리므로, k3s 제거 바로 전에 멈추고 콘솔에서 paused를 본다. k3s를 지운 뒤에는 ping이 끊겨 정지가 유지되므로 한 번 더 확인한다. 라이브 체크 이름이 `homelab-watchdog`인지도 콘솔에서 본다. 옛 체크는 T08b가 새 체크의 초록을 확인한 뒤 지운다(D-10).
5. T01의 열린 PR 닫기가 끝났다(명세 AC-P1). `gh pr list -R ukyi-app/homelab`에 열린 PR이 없다. 할 일 5에서 `gate`를 풀면 남은 PR을 검사 없이 병합할 수 있게 된다.
6. 2026-10-18에 실행한 설계 0절 7항(`page`·`trip-mate-api` 삭제)과 8항(결정 5 하드닝)을 확인 명령으로 다시 본다. `gh api repos/ukyi-app/page`, `gh api repos/ukyi-app/trip-mate-api`, `gh api orgs/ukyi-app/packages/container/page`, `gh api orgs/ukyi-app/packages/container/trip-mate-api`가 모두 404다. `files`와 `homelab-app-template`의 `app-main` ruleset이 active다(`gh api repos/ukyi-app/<저장소>/rulesets --jq '[.[] | {name, enforcement}]'`).

## 할 일

1. 아래 "정리 목록"과 "자격 폐기 표"를 채운다. 시크릿 값은 쓰지 않고 이름·ID만 쓴다. 2026-10-18에 실측을 마쳤다(아래 "할 일 1 결과"). "콘솔 확인"과 "확인 불가" 줄은 사람이 확인한 뒤 닫는다.
   - 목록 입력: `gh api`로 실측한 GitHub 상태, `legacy`의 `policy/credential-expiry.json` 전체 행, 옛 Terraform root 선언(`legacy`의 `infra/cloudflare`, `infra/github`, `infra/tailscale`). 로컬 런북(`token-inventory` 등)과 `~/workspace/homelab-infra/`도 D-27(확정(사용자 2026-10-18, T05))대로 읽기 전용 입력으로 쓴다. 이름·ID만 옮기고 값과 절차 원문은 옮기지 않는다. 공개 근거만으로는 코드 밖 자격(콘솔에서 만든 토큰 등)이 빠질 수 있어서다(설계 B.9).
   - 코드 밖 자원(Cloudflare Access 앱·정책 등)은 콘솔에서 다시 조회해 확인한다.
2. 옛 Argo CD를 멈추고, k3s와 NUC 잔여물을 지운다.
   - root 앱이 Application과 ApplicationSet을 selfHeal로 소유한다. 그래서 Application 단위로 자동 동기화를 끄는 것은 효과가 없다. 컨트롤러가 되돌린다.
   - 옛 사본의 kubeconfig(`~/workspace/homelab/infra/k3s-bootstrap/kubeconfig`, sudo 불필요)로 `argocd` 네임스페이스의 `argocd-application-controller`(StatefulSet)와 `argocd-applicationset-controller`(Deployment)를 0으로 줄인다. 두 컨트롤러의 파드가 없는지 확인한다.
   - application-controller를 먼저 줄인다. 옛 Argo CD는 자기 자신도 selfHeal로 관리하므로, application-controller가 살아 있으면 다른 컨트롤러의 축소를 되돌릴 수 있다(추측).
   - 그다음 D-12(OS 유지) 방식으로 k3s를 제거한다(H9). 이때 클러스터 안의 SealedSecrets 봉인 키가 사라진다(선행 확인 3). `k3s-uninstall.sh`는 `/var/lib/rancher/k3s-storage`를 남기므로 옛 데이터 경로는 따로 지운다. 이 스크립트는 `/usr/local/bin`의 `kubectl`·`crictl`·`ctr` 심링크도 지운다(2026-10-18 확인). 사용자 셸의 kubectl은 mise 설치본이라 남지만, `sudo`(secure_path)로는 철거 뒤 `kubectl`·`crictl`·`ctr`를 쓸 수 없다.
   - AdGuard 설정 내보내기(선행 확인 2)가 끝났는지 확인하고 옛 데이터 경로를 지운다(H8).
   - NUC 호스트 잔여물 중 H1·H2·H3과, H7은 사용자 결정 범위만 지운다(아래 H7 줄. `/usr/local/share/ukyi-motd/`는 통째로 지우지 않는다). H3 유닛은 옛 사본을 옮기거나 지우기 전에 지운다. H4·H5 drop-in과 `accept-dns=false`는 남긴다(아래 "NUC 호스트 잔여물").
   - `homelab-aiops-nft.service`에는 ExecStop이 없어서, 서비스를 멈춰도 nft table이 남는다(2026-10-18 실측). `sudo nft list tables`로 table 이름을 확인하고 따로 지운다.
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
6. 자격 폐기 표대로 폐기한다(D-20). state 처리에 쓰는 자격은 할 일 4가 끝난 뒤 마지막에 폐기한다. 표의 다른 폐기가 모두 끝난 것을 확인한 뒤 SOPS age 개인 키 둘(`~/.config/sops/age`의 cluster 키, 비밀번호 관리자의 `homelab age recovery`)을 지운다(D-20).
7. 선행 확인과 할 일 2~6의 모든 실행을 [approvals.md](../approvals.md)에 기록한다. 식별자만 쓰고 값은 쓰지 않는다.
8. T07의 main 병합 전에, 이 티켓의 정리 목록·자격 폐기 표 상태와 approvals.md를 `rebuild`에 커밋하고 push한다(사람 승인, 명세 §12). 이 티켓에는 이름·ID·상태만 있으므로 공개돼도 된다.

## 정리 목록 (할 일 1의 최소 범위)

2026-10-17 실측과 `legacy` 선언 기준이다. 실행할 때 다시 조회해 빠진 줄을 더한다. 처리 방향은 D-11(확정(사용자 2026-10-18, T05), 설계 F D-11 표)이다: Cloudflare zone, tailnet, R2 `homelab-tfstate`만 이어 쓰고 나머지는 지운 뒤 새로 정의한다.

### Cloudflare

- 터널 `homelab-prod`: 삭제. 새 터널은 T08a가 정의한다.
- DNS 레코드: 삭제. 라이브 공개 이름은 `ukyi.app`, `www`, `argocd-webhook`, `files` 등이다. 새 레코드는 T08a가 정의한다.
- WAF 규칙 `homelab-waf-custom`, `homelab-waf-ratelimit`. 캐시 규칙 `homelab-cache-rules`: 삭제. 새 규칙은 T08a가 정의한다.
- zone `ukyi.app`: 유지(D-11).
- zone 설정 9개: HSTS(includeSubDomains, nosniff, 180일), `always_use_https`, `min_tls_version` 1.2, `tls_1_3`, `opportunistic_encryption` off, `automatic_https_rewrites`, `browser_check`, `security_level` medium, `email_obfuscation`. D-11대로 값을 유지한 채 T08a의 새 Terraform으로 가져온다(HSTS preload는 끔). 줄 상태는 `import 예정(D-11, T08a)`. zone이 남으므로 옛 state를 버려도 이 설정은 Cloudflare에 그대로 남는다.
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
- ACL·DNS: 옛 root를 apply도 destroy도 하지 않는다. 새 코드(T08a)가 덮어쓴다. DNS는 D-08(확정(사용자 2026-10-18))대로 Terraform `tailscale_dns_configuration`이 맡는다. 옛 "Override local DNS" 토글은 옛 코드 밖에서 콘솔로 켰다(`2d2054a:infra/tailscale/acl.tf:79-82`). CLI로는 상태가 보이지 않으므로 콘솔에서 확인한다. 새 ACL은 D-11 (a)(확정(사용자 2026-10-18, T05))다: NUC는 태그 없는 사용자 기기로 두고, 옛 `autogroup:self` 규칙과 ssh 규칙(`accept`, `autogroup:nonroot`·`root`)을 유지한다. 그래야 NUC 원격 접속이 끊기지 않는다. (c) `tag:nuc`로 바꿀지는 T08a가 U28 결과로 다시 본다.

### GitHub

- App 4개:
  - `ukyi-homelab-reader`(4043034), `ukyi-homelab-writer`(4043080): 삭제(D-11). writer는 ruleset 2개를 지운 뒤에 지운다(할 일 5).
  - `ukyi-homelab-aiops`(4937062): 제거(D-13 일부 확정, 2026-10-18). 실행은 T22라 이 티켓의 줄 상태는 `보류(D-13, T22)`.
  - `ukyi-homelab-dispatch`(4178609): org 설치는 없다. 등록만 남았는지 확인하고, 남았으면 삭제(D-11).
- ChatGPT Codex Connector: 유지(D-26, 확정(사용자 2026-10-18, T05)). 줄 상태는 `유지(D-26)`. 설계 0절 실측으로 org 전체 저장소에 actions·contents·issues·pull_requests·workflows write다. 유지 조건 넷은 설계 F D-26이다(어떤 ruleset bypass에도 넣지 않음 등). 설치 범위 축소는 확정(사용자 2026-10-18, T15): 선택 저장소로 줄이고 `homelab-bot-ops`를 뺀다. 사람 작업이고 T15에서 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 하기로 했으며, 2026-10-18 17:45에 완료했다(spec §11, D-16, [../approvals.md](../approvals.md)).
- environment 4개: `homelab-main`(secret 19개), `aiops-authority-empty-0915`, `aiops-authority-empty-0916`, `aiops-reusable-public-0915`(secret 1개). 삭제(D-11).
- "저장소 시크릿"은 실제로 environment `homelab-main`의 secret이다. 저장소 수준 secret은 0개다.
- 저장소 변수 2개: `HOMELAB_DOMAIN`, `HOMELAB_OWNER`. 삭제(D-11).
- 저장소 설정 `allow_auto_merge`: `true`(설계 0절 4항 실측). 할 일 5에서 `false`로 바꾼다. D-07(확정(사용자 2026-10-18, T05))도 GitHub auto-merge 허용을 끈다.
- ruleset 2개: 19598965 `bump-poll-writer-only`, 23257797 `mutation-branches-writer-only`. 둘 다 브랜치 생성·갱신을 막고 writer App만 우회한다. writer App을 지우면 ruleset이 남아 있는 동안 그 접두사(`bump-poll/`, `bump/`, `create-app/`, `create-database/`, `create-cache/`, `update-secrets/`)의 브랜치는 아무도 만들 수 없다. 그래서 할 일 5에서 지운다.
- 저장소 webhook 647791528: push 이벤트를 `argocd-webhook.ukyi.app`으로 보낸다. 터널을 지운 뒤에는 전송이 계속 실패한다. 삭제(할 일 5). 새 구조에는 Argo CD 공개 webhook이 없다.
- 브랜치 보호(main): 필수 검사 `gate`(strict), PR 필수(승인 0, code owner 리뷰 꺼짐), `enforce_admins=false`, push 제한(users `ukkiee`, apps writer, teams 없음), `block_creations=true`, force push·삭제 금지(2026-10-18 실측). 되돌릴 때는 이 설정으로 다시 만든다. 할 일 5에서 `main-interim`을 건 뒤 전체를 지운다.
- GHCR 패키지 6개: `pg-tools`, `skopeo`, `page`, `trip-mate-api`, `files`, `aiops-autodeploy-canary`.
  - `page`, `trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29, [../approvals.md](../approvals.md)). `page` 패키지는 API 삭제가 거부돼(아래) 사람이 직접 지웠다.
  - `pg-tools`, `skopeo`: 삭제(D-11, 소비자 없음). public 패키지는 한 버전이라도 다운로드가 5000회를 넘으면 API로 지울 수 없다(2026-10-18 `page`에서 HTTP 400). 그날 UI의 전체 다운로드는 `skopeo` 1.76k, `pg-tools` 973, `aiops-autodeploy-canary` 9.37k(private라 이 제한과 무관)였다. API가 거부하면 사람이 직접 지운다.
  - `files`: T22까지 유지(D-11). 줄 상태는 `유지(T22 재연결 대상)`.
  - `aiops-autodeploy-canary`: 저장소 처리와 함께 T22(D-11, D-29). 줄 상태는 `보류(D-29, T22)`.
- 앱 저장소 `ukyi-app/page`, `ukyi-app/trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29). 쓰지 않는 앱이다. 두 앱의 옛 자격은 자격 폐기 표에서 폐기한다.

### 외부 감시·알림

- healthchecks.io: 계정은 이어 쓰고 체크는 새로 만든다(D-10). 옛 체크 `homelab-watchdog`는 선행 확인 4에서 일시 정지하고, T08b가 새 체크의 초록을 확인한 뒤 지운다(D-11). 줄 상태는 `보류(D-10, T08b)`.
- Telegram 봇: homelab 알림용 새 봇은 T09가 만든다(D-10). 옛 봇과 토큰은 T22가 `mac-uptime-guard` 장치를 끌 때까지 그대로 둔다. 줄 상태는 `보류(D-10, T22)`. 토큰은 자격 폐기 표에 있다. 토큰 사본은 environment `homelab-main`, 클러스터 Secret 3개, `mac-uptime-guard`, NUC의 `~/workspace/mac-uptime-guard/config.env`, 옛 사본 `.scratch`의 입력 파일(토큰 모양 문자열, 추정)에 있다(2026-10-18 실측). T22가 토큰을 폐기하면 사본은 모두 무효가 된다.

### 옛 AIOps 저장소

- `ukyi-app/aiops`와 App `ukyi-homelab-aiops`: 제거(D-13 일부 확정, 2026-10-18. aiops는 쓰지 않는다). 실행은 T22라 줄 상태는 `보류(D-13, T22)`.
- `ukyi-app/aiops-autodeploy-canary`: 공개하지 않고 private로 보관(D-29, 삭제도 가능). 실행은 T22라 줄 상태는 `보류(D-29, T22)`.
- `mac-uptime-guard`(private, 옛 맥 미니용, 옛 Telegram 토큰 사용): 제거(D-29, 사용자 2026-10-18 17:46. 그 전에는 private 보관이었다). 실행은 T22다: 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤 저장소를 지운다. NUC에 원격 없는 로컬 클론(`~/workspace/mac-uptime-guard`)도 있다. 줄 상태는 `보류(담당 T22)`.

### NUC 호스트 잔여물 (D-12)

D-12(확정(사용자 2026-10-18, T05))는 OS를 유지하고 설계 B.4의 H1·H2·H3·H7·H8·H9를 지운다. H4·H5는 남기고 T07의 새 호스트 설정이 같은 이름으로 덮어쓴다. 줄마다 B.4의 ID를 단다. H7은 2026-10-19 사용자 결정으로 범위를 좁혔다(아래 H7 줄).

옛 AIOps:

- H1 유닛: `aiops-ingress.service`, `aiops-worker.service`(static)·`aiops-worker.timer`, `homelab-aiops-nft.service`, `'var-lib-homelab\x2daiops.mount'`. 순서는 timer·ingress 비활성 확인 → nft 서비스·table 제거 → mount 해제 → 이미지 파일 삭제다(설계 B.4).
- mount 유닛 이름의 `\x2d`는 systemd 경로 이스케이프다. 셸에서는 작은따옴표로 감싸거나 `systemctl status /var/lib/homelab-aiops`처럼 경로로 지정한다. 이스케이프 없는 이름으로 조회하면 not-found가 나와 "이미 없음"으로 잘못 닫힌다. 2026-10-17에는 active이고, loop 이미지 위의 ext4다.
- H2 파일: `/var/lib/homelab-aiops.img`, `/opt/homelab-aiops`, `/etc/homelab-aiops`(AIOps App 개인 키), `/usr/local/libexec/homelab-aiops-ingress-firewall.py`, `/etc/nftables.d/homelab-aiops.nft`, drop-in(`aiops-ingress.service.d/*`, `aiops-worker.service.d/*`), `/etc/tmpfiles.d/homelab-aiops.conf`. 파일은 이 티켓에서 지운다. `/etc/homelab-aiops`의 App 키 폐기는 옛 aiops App 삭제와 함께 T22에서 한다(D-29, 자격 폐기 표의 `보류(D-13, T22)`).
- H2 시스템 사용자 `aiops-*` 8개와 그룹 `aiops-state`, 사용자별 기본 그룹 8개. `aiops-proxy`의 CLIProxyAPI 저장소에 ChatGPT 구독 OAuth가 있다(자격 폐기 표).
- H2 추가(2026-10-18 실측, 설계 B.4 목록 밖): `/etc/sysusers.d/homelab-aiops.conf`(남기면 부팅 때 `aiops-*` 사용자가 다시 생길 수 있다, 추측), 마운트 지점 `/var/lib/homelab-aiops`(mount 해제 뒤), `/var/tmp`의 AIOps 작업 디렉터리 125개(`homelab-aiops-*` 124개, `aiops-cgroup-path-*` 1개), `/nonexistent`(root 0700, 2026-10-01. `aiops-*` 7명과 `nobody` 등 시스템 계정 5개가 홈 경로로 적은, 원래 없어야 하는 디렉터리다. 누가 만들었는지는 모른다(AIOps로 추측). 내용은 sudo로 보고 AIOps 것만이면 지움), `/etc/nftables.d` 디렉터리(root 0700, 안이 AIOps 파일뿐이면 함께 지움).

옛 `host-config.sh --apply`가 깐 것:

- H3 유닛(지움): `files-data-backup.service`·`.timer`, `systemd-failed-sweep.service`·`.timer`, `unit-failure-notify@.service`. 셋 다 옛 사본(`~/workspace/homelab/scripts/`)의 스크립트를 실행하고, `files-data-backup`은 옛 사본의 kubeconfig도 쓴다. 옛 사본을 옮기거나 지우기 전에 지운다.
- H4 drop-in(남김): `sshd_config.d/10-k3s-node.conf`, `journald.conf.d`, `tmpfiles.d`(NVMe ASPM). T07의 `host/etc/`가 같은 이름으로 덮어쓴다.
- H5 노드 DNS 순환을 막는 설정(남김): `resolved.conf.d/10-k3s-node.conf`, `10-netplan-wlo1.network.d`, `/etc/resolv.conf` 심링크. `tailscale set --accept-dns=false`도 같은 목적이다(명세 §4.5). 대체 없이 지우면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 다시 생길 수 있다. 그래서 이 티켓은 지우지 않고 T07의 새 호스트 설정이 같은 일을 맡는다.
- H6 fstab의 swap 제거: 2026-10-17 실측으로 swap 항목이 없다. 할 일 없음. T07 preflight가 스왑 없음을 확인한다.

H7 로그인 MOTD의 k3s 상태 표시. 2026-10-18 실측으로 범위를 고쳤고, 처리는 사용자가 정했다(2026-10-19).

- 고양이 아트 MOTD는 홈랩과 별개인 로컬 프로젝트 `~/workspace/ukyi-motd`(git 아님)가 2026-08-07에 깔았다. 그 설치는 Ubuntu 기본 MOTD 조각 6개의 실행 권한을 빼고, `50-landscape-sysinfo` 링크를 `/usr/local/share/ukyi-motd/backup/`으로 옮기고, `motd-news`를 껐다. 원본은 `backup/`에, 원복용 `uninstall.sh`는 `/usr/local/share/ukyi-motd/`(같은 것이 `~/workspace/ukyi-motd/`)에 있다.
- 옛 저장소(`2d2054a:infra/k3s-bootstrap/motd/`)가 깐 것은 `/usr/local/share/ukyi-motd/k3s-status.py`와 k3s 상태를 넣은 `/etc/update-motd.d/00-ukyi`(2026-09-21)다.
- `motd-refresh.service`·`.timer`와 drop-in `10-user.conf`(2026-08-26)는 저장소에 없고 출처를 확인하지 못했다. 옛 README는 "기존" 장치로 적었지만 2026-08-07 설치에는 없었다.
- **처리(사용자 결정 2026-10-19: 고양이 MOTD만 남김):** `motd-refresh.service`·`.timer`와 drop-in, `k3s-status.py`를 지우고, `/etc/update-motd.d/00-ukyi`를 2026-08-07 원본(`/usr/local/share/ukyi-motd/00-ukyi.prev`. `~/workspace/ukyi-motd/00-ukyi`와 같음)으로 되돌린다. Ubuntu 기본 MOTD는 꺼진 채로 두고, `/usr/local/share/ukyi-motd/`의 나머지(고양이 아트, `backup/`, `uninstall.sh`)는 남긴다. 설계 B.4 H7 행의 `/usr/local/share/ukyi-motd/` 전체 삭제는 이 결정으로 바뀐다.

### 옛 데이터 경로 (D-12, H8)

- `/var/lib/rancher/k3s-storage`: 옛 PV 데이터(AdGuard 설정 포함). `k3s-uninstall.sh`는 `/var/lib/rancher/k3s`, `/var/lib/kubelet`, `/etc/rancher/k3s`만 지우고 이 경로를 남긴다.
- `/mnt/bulk`와 그 fstab 항목: 별도 1.8T 디스크, 옛 files 데이터(C-03 폐기 대상). D-12대로 비우고 fstab 항목을 지운다. 새 구조에서는 쓰지 않는다. 2026-10-18 실측: ext4로 마운트돼 있고 2.2G를 쓴다. root 0710이라 목록은 sudo가 필요하다. 안에 `homelab-backups/`(SealedSecrets 봉인 키 백업 1개, 로컬 런북 암호화 사본 6개)가 있다(선행 확인 3).
- `/mnt/bulk-new`: 2026-08-26에 만든 root 0700 디렉터리. 루트 디스크 위의 일반 디렉터리이고(마운트 아님) fstab과 옛 코드에 없다. 옛 bulk 이전 때의 임시 경로로 보인다(추측, 로컬 런북). sudo로 내용을 보고 비었거나 옛 데이터면 지운다.
- `/var/backups/files-data`: `files-data-backup.timer`가 매일 쓴다.
- `/var/lib/homelab-aiops.img`: AIOps loop 이미지(옛 AIOps 줄과 같은 파일).
- 마운트 여부는 `findmnt -T`로 판정하지 않는다. 마운트 여부를 증명하지 못한다(설계 B.8 "E1 철거").

H9 `k3s.service`: 할 일 2에서 제거한다(D-02, D-12).

## 자격 폐기 표 (할 일 1·6)

새로 발급해도 옛 자격은 따로 폐기하기 전까지 살아 있다. 각 줄을 `폐기 / 유지(이유) / 보류(결정 ID, 담당 티켓)` 중 하나로 정한다. 실행 전에는 `폐기 예정`, 실행을 마치면 `삭제됨`으로 적는다. 에이전트가 볼 수 없어 `확인 불가`로 둔 줄은 사람이 확인한 뒤 셋 중 하나로 닫는다. 값은 쓰지 않는다.

D-20(확정(사용자 2026-10-18, T05))에 따라 새 플랫폼은 모든 값을 새로 발급하고(T09), 옛 자격은 이 티켓에서 폐기한다. 철거 뒤에는 옛 자격을 쓰는 곳이 없기 때문이다. 이 티켓에서 폐기하지 않는 줄은 넷이다: 아래 두 예외, 자격이 아니라 기기 등록인 `ts-node-key-nuc`(유지, D-12. 설계 C.3.2), T22가 App 제거와 함께 폐기하는 `ukyi-homelab-aiops` App 키(보류(D-13, T22)). 그래서 `보류(…, T09)`로 미리 정한 줄은 없다. 실행 중 그런 줄이 생기면 T09가 새 자격을 등록한 뒤 닫는다. SOPS age 개인 키(cluster·recovery 둘 다)도 보류하지 않고, 이 표의 다른 폐기가 끝난 것을 확인한 뒤 마지막에 지운다(할 일 6).

**예외: 옛 healthchecks ping URL은 `보류(D-10, T08b)`로 둔다.** 체크는 선행 확인 4에서 일시 정지돼 있다. D-10대로 healthchecks.io 계정은 이어 쓰고 체크는 새로 만든다. T08b가 새 외부 생존 감시를 연결하고 정상(초록)을 확인한 뒤 옛 체크를 지우며 이 줄을 닫는다.

**예외: 옛 Telegram 봇 토큰은 이 티켓에서 폐기하지 않는다.** 저장소 밖의 `mac-uptime-guard`가 같은 토큰을 쓰기 때문에, 폐기하면 그쪽 알림이 아무 표시 없이 끊긴다. 줄은 `보류(D-10, T22)`로 둔다. D-10은 homelab 알림용 새 봇(T09가 만듦)을 골랐다. 그래서 T22가 `mac-uptime-guard` 장치를 끈 뒤 옛 봇 토큰을 폐기하고 옛 봇을 지우며 이 줄을 닫는다. `mac-uptime-guard` 저장소는 그 뒤 지운다(D-29). 옛 봇 토큰을 재발급하는 대안은 고르지 않았으므로 T09가 이 줄을 닫는 일은 없다.

**순서:** state 처리에 쓰는 자격(`r2-terraform-state`, `cf-tf-root-token`, `github-tf-root-pat`)은 할 일 4가 끝난 뒤에 폐기한다. 먼저 폐기하면 할 일 4가 막힌다. `github-tf-root-pat`이 github root의 state 제거에 꼭 필요한지는 확인하지 못했다(추측으로 안전한 쪽에 둠).

**사본:** 자격을 폐기하면 아래 "사본" 칸의 위치에 남은 값은 모두 무효가 된다. 발급처가 없는 값(자기생성 비밀번호 등)은 그 값을 받던 앱·클러스터가 없어졌는지 확인하고 닫는다. 로컬 사본 파일(`.env.secrets`, `.env.local` 등)은 선행 확인 2대로 디스크에 남는다. 사본 위치는 2026-10-18 실측이다(할 일 1 결과).

| 자격 | 무엇 | 사본 (위치만) | 주의 | 상태 |
|---|---|---|---|---|
| `ghcr-pull-pat` | GHCR 읽기용 classic PAT, 무만료 | environment `homelab-main`(`GHCR_PULL_TOKEN`), 클러스터 SealedSecret 3개, `.env.secrets` | 새 구조에는 GHCR pull 자격이 없다(D-29). PAT 존재는 API로 볼 수 없어 owner 계정 설정에서 확인 | 폐기 예정 |
| `github-tf-root-pat` | github root용 fine-grained PAT `homelab-tf-github-root`(Administration·Secrets 읽기·쓰기), 무만료 | `.env.secrets` | 할 일 4 뒤(순서 문단) | 폐기 예정 |
| `github-tf-ci-pat` | CI 읽기용 fine-grained PAT `ukyi-app-tf-github-ci-readonly` | environment `homelab-main`(`TF_GITHUB_TOKEN`) | | 폐기 예정 |
| `tailscale-ci-oauth-client` | Tailscale CI 읽기 전용 OAuth 클라이언트(설명 `homelab ci drift-tailscale readonly 20260819`) | environment `homelab-main`(`TF_TAILSCALE_OAUTH_*`), 비밀번호 관리자 백업 | owner 부트스트랩 OAuth와 별개 | 폐기 예정 |
| `r2-terraform-state` | `homelab-tfstate` 접근 R2 키(토큰 `homelab-terraform-state-20260820`) | 옛 사본 `backend.hcl` 3개와 `.terraform/terraform.tfstate` 3개(자격 포함 추정), environment `homelab-main`(`R2_*`) | 할 일 4 뒤. 2026-08-20 회전 전 옛 토큰이 실제로 폐기됐는지 콘솔에서 확인 | 폐기 예정 |
| `ts-node-key-nuc` | NUC 노드 키(만료 해제) | 없음(기기 등록) | 폐기하면 NUC가 tailnet에서 빠져 Tailscale 경로의 원격 접속이 끊긴다. D-12가 OS 유지라 NUC는 지금 등록 그대로 tailnet에 남는다(설계 C.3.2). 2026-10-18 실측: 태그 없음, 만료 없음 | 유지(D-12) |
| `argocd-github-webhook` | webhook 647791528의 secret | 클러스터 `argocd-secret`, `.env.secrets` | webhook 삭제(할 일 5)와 함께. 새 구조에는 공개 webhook이 없다(60초 폴링) | 폐기 예정 |
| `github-dispatch-app` | App `ukyi-homelab-dispatch`(4178609) | 확인 불가(개인 키 개수는 App 설정 화면) | 2026-10-18 실측: 등록이 남아 있고 org 설치는 없다. 등록 삭제로 키도 무효 | 폐기 예정 |
| `cf-tf-root-token` | Cloudflare 토큰 `homelab-terraform-cloudflare`(Account·Zone Edit) | `.env.secrets`, environment `homelab-main`(`TF_CLOUDFLARE_TOKEN`) | 할 일 4 뒤 | 폐기 예정 |
| `cf-certmanager-token` | Cloudflare 토큰 `homelab-certmanager-dns01` | SOPS 파일(`2d2054a:platform/traefik/prod/cloudflare-api-token.enc.yaml`), `.env.secrets` | 새 구조에는 대응 토큰이 없다(D-08). 공개 히스토리의 SOPS 파일은 age 키로 풀린다 | 폐기 예정 |
| `r2-backups-pg-cache` | 백업 버킷용 R2 키 `homelab-backups-pg-cache` | SOPS 파일 2개(cnpg, cache), `.env.secrets` | 버킷 삭제(할 일 3)와 함께 | 폐기 예정 |
| 옛 App 키 | `ukyi-homelab-reader`, `ukyi-homelab-writer` | environment `homelab-main`(`HOMELAB_*_APP_PRIVATE_KEY`), 옛 사본 `.scratch`의 평문 PEM, 비밀번호 관리자 백업(있으면) | App 삭제(할 일 5.6)로 키도 무효 | 폐기 예정 |
| `ukyi-homelab-aiops` App 키 | App 4937062 개인 키 | `/etc/homelab-aiops`(H2), 옛 사본 `.scratch`의 평문 PEM | T22가 App 제거(D-13 일부 확정)와 함께 폐기한다. `/etc/homelab-aiops` 파일은 이 티켓의 H2 삭제로 지운다 | 보류(D-13, T22) |
| Tailscale 부트스트랩 OAuth | owner 로컬용, Terraform 밖, 쓰기 스코프 | `.env.secrets` | | 폐기 예정 |
| Tailscale operator OAuth | 옛 operator용(devices:core·auth_keys) | SOPS 파일(`platform/tailscale/prod/operator-oauth.enc.yaml`) | | 폐기 예정 |
| Cloudflare 터널 실행 토큰 | 터널 `homelab-prod`의 실행 토큰 | SOPS Secret `cloudflared-tunnel` | 터널 삭제(할 일 3)로 무효 | 폐기 예정 |
| Telegram 봇 토큰 | 옛 알림 봇 | 정리 목록 "Telegram 봇" 줄 | `mac-uptime-guard`도 이 봇을 쓴다. T22가 그 장치를 끈 뒤 폐기한다(위 예외) | 보류(D-10, T22) |
| healthchecks ping URL | `homelab-watchdog` 체크 | SOPS Secret 2개(`alerting-secrets`, `restore-drill-alerting`), `.env.secrets` | 옛 체크 삭제도 T08b(D-11)(위 예외) | 보류(D-10, T08b) |
| `trip-mate-api` Google OAuth client | `trip-mate-api` 로그인용 Google OAuth 클라이언트 | 후보: NUC 로컬 클론 `~/workspace/trip-mate-api/.env.local` | 앱 삭제로 폐기(D-29). Google Cloud 콘솔에서 지운다 | 폐기 예정 |
| `trip-mate-api` OXR app id | `trip-mate-api`가 쓰던 OXR app id | 후보: 같은 `.env.local` | 앱 삭제로 폐기(D-29). 발급처 계정에서 폐기한다 | 폐기 예정 |
| `trip-mate-api` `BETTER_AUTH_SECRET` | `trip-mate-api`의 Better Auth 비밀값 | 후보: 같은 `.env.local` | 앱 삭제로 폐기(D-29). 외부 발급처가 없는 값이라, 이 값을 받던 앱이 없어졌는지(저장소·배포 삭제) 확인하고 닫는다 | 폐기 예정 |
| `page` admin token | `page` 관리자 토큰 | 후보: NUC 로컬 클론 `~/workspace/page/.env.local` | 앱 삭제로 폐기(D-29). 외부 발급처가 없는 값이라, 이 값을 받던 앱이 없어졌는지 확인하고 닫는다 | 폐기 예정 |
| `files` 앱 자격 | `FILES_ADMIN_TOKEN`, 클라이언트 키 `keys.json` | SealedSecret `files-keys`, `.env.secrets` | 발급처 없음. T22 재연결 때 새 값(D-20). 외부 클라이언트가 옛 키를 가졌는지는 저장소로 알 수 없다 | 폐기 예정 |
| 클러스터 내부 자기생성 비밀번호 | Grafana·AdGuard·Argo CD 관리자, CNPG superuser·앱 역할, 앱 DB·Valkey 자격 | SealedSecret·SOPS 파일, `.env.secrets`, 비밀번호 관리자(있으면) | 발급처 없음. 받던 클러스터가 k3s 제거·H8로 사라지면 닫는다 | 폐기 예정 |
| AIOps 생산자 토큰 3개 | Argo CD 알림·관측 경로가 NUC `aiops-ingress`로 보내던 토큰 | 클러스터 Secret 3개(`argocd-notifications-secret`, 네임스페이스 둘의 `aiops-observation-auth`) | 발급처 없음. k3s 제거와 H1·H2 삭제로 양쪽이 사라진다 | 폐기 예정 |
| `aiops-proxy` ChatGPT 구독 OAuth | 옛 AIOps CLIProxyAPI의 구독 로그인 | NUC `aiops-proxy` 저장 공간(H2) | 파일은 H2 삭제로 지운다. OpenAI 계정 쪽 세션 해제는 사람이 한다. D-13 일부 확정은 aiops 저장소·App만 다루므로 D-20을 따른다 | 폐기 예정 |
| SealedSecrets 봉인 키 | 클러스터 안의 키는 k3s 제거로 사라진다 | `/mnt/bulk/homelab-backups/sealed-secrets`(1개, age로 암호화), 비밀번호 관리자 첨부(있으면) | 봉인본 10개(공개 히스토리 포함)를 풀 수 있는 키다. 디스크 사본은 H8 비우기로 지운다 | 폐기 예정 |
| SOPS age 키(cluster) | `~/.config/sops/age` | 클러스터 Secret `sops-age` | 옛 `.sops.yaml`의 recipient 2개(cluster, recovery)는 확인했다. 이 파일이 cluster recipient와 맞는지는 사람이 `age-keygen -y`로 대조한다. 맞으면 공개 히스토리의 SOPS 파일 9개를 풀 수 있다. 새 구조에서 쓰지 않는다. 할 일 4와 이 표의 다른 폐기가 끝난 것을 확인한 뒤 지운다(보류 아님) | 폐기 예정 |
| SOPS age 키(recovery) | 비밀번호 관리자 항목 `homelab age recovery` | 비밀번호 관리자만(디스크 사본 없음, 런북) | 옛 SOPS 파일 9개와 봉인 키 백업을 모두 풀 수 있다. cluster 키와 같은 때 마지막에 사람이 지운다 | 폐기 예정 |
| `HOMELAB_DISPATCH_PAT` | 앱 저장소가 쓰던 옛 dispatch PAT | 2026-09-03 기준 앱 저장소 secret 0개(런북) | GitHub에서 PAT 자체를 폐기했는지 기록이 없다 | 확인 불가(owner PAT 목록) |
| healthchecks.io 읽기 전용 API 키 | 옛 AIOps의 healthchecks 조회용 | 저장소에 없음 | 발급됐는지 모른다 | 확인 불가(healthchecks 프로젝트 설정) |
| Claude 구독 OAuth 토큰 | 옛 AIOps 계획의 인증 결정 | 저장소에 없음 | 계획 문서에만 있고 발급됐는지 모른다 | 확인 불가(사람) |

## 할 일 1 결과 (2026-10-18 실측)

읽기 전용으로 실측했다: `gh api` GET, `git show 2d2054a:…`(옛 코드 선언, `policy/credential-expiry.json` 11행), D-27대로 로컬 런북과 `~/workspace/homelab-infra/`(이름만), sudo 없는 NUC 조회(`systemctl`, `test -e`, `getent`, `findmnt <경로>`, `tailscale status`), 옛 Argo CD 워크로드 이름·replicas 조회(`kubectl get`만). 값, 이메일, tailnet 이름, Tailscale IP는 옮기지 않았다. Cloudflare·R2·Tailscale·healthchecks 콘솔은 에이전트가 볼 수 없어 "콘솔 확인"으로 남겼다.

**상태 규칙.** 실행 전 상태는 완료 조건의 네 상태로 이렇게 닫는다. `삭제 예정`·`폐기 예정`은 실행 뒤 `삭제됨`. `변경 예정`(`allow_auto_merge`)은 바꾼 뒤 `유지(false로 바꿈, D-07)`. `생성 예정`(`main-interim`)은 만든 뒤 `유지(T10까지, T10 import)`. `콘솔 확인`·`확인 불가`는 사람이 보고, 있으면 처리 방향대로 `삭제됨`, 없으면 `유지(없음 확인, 날짜)`. 아래 "실측으로 더한 줄"도 정리 목록에 들어가 완료 조건을 따른다. 정보 줄(H1 이스케이프 설명, `findmnt -T` 주의)은 상태 대상이 아니다. "기본값"이라고 쓴 유지는 지금 상태를 바꾸지 않는다는 뜻이고, 사용자가 다르게 정하면 고친다.

### 선행 확인 상태

| # | 상태 | 근거 |
|---|---|---|
| 1 | 완료 | 원격 `rebuild` = `902a86f`(2026-10-19 push). 이 할 일 1 결과까지 들어 있다. 할 일 2 전에 티켓을 더 고쳤으면 다시 push한다 |
| 2 | 사람 작업 대기 | 번들 없음(옛 사본 실측은 선행 확인 2). `k3s-storage/internal`이 root 0700이라 AdGuard PVC는 존재부터 sudo로 확인해야 한다. 로컬 런북·`homelab-infra` 점검은 완료 |
| 3 | 사람 작업 대기 | approvals 기록 없음. `/mnt/bulk`의 봉인 키 백업과 런북 암호화 사본도 함께 알린다 |
| 4 | 사람 작업 대기(k3s 제거 직전) | 콘솔은 에이전트가 볼 수 없다. ping은 클러스터 안에서 1분마다 나가고, 일시 정지는 ping 한 번에 풀린다 |
| 5 | 완료 | `gh pr list -R ukyi-app/homelab --state open` → 0개 |
| 6 | 완료 | 저장소·패키지 4개 모두 404. `app-main`: `files` 25327498 active, `homelab-app-template` 25327516 active |

### 정리 목록 상태

| 구역 | 줄 | 실측 | 상태 |
|---|---|---|---|
| Cloudflare | 터널 `homelab-prod` | 옛 선언 있음(`2d2054a:infra/cloudflare/tunnel.tf`) | 삭제 예정(D-11, 콘솔 확인) |
| Cloudflare | DNS 레코드 | 선언 CNAME 4개(apex, `www`, `argocd-webhook`, `files`) 모두 공개 해석됨. 코드 밖 레코드는 콘솔에서만 보인다 | 삭제 예정(D-11, 콘솔 확인) |
| Cloudflare | WAF 2개, 캐시 규칙 1개 | 선언 있음 | 삭제 예정(D-11, 콘솔 확인) |
| Cloudflare | zone `ukyi.app` | data source로만 참조 | 유지(D-11) |
| Cloudflare | zone 설정 9개 | 선언 9개(HSTS nosniff 포함) | import 예정(D-11, T08a) |
| Cloudflare | Access 앱·정책 | 옛 선언 0건 | 콘솔 확인(있으면 삭제 예정, D-11) |
| R2 | `homelab-pg-backups-prod`, `homelab-media-prod` | 선언 있음, `prevent_destroy` | 삭제 예정(D-11, 콘솔) |
| R2 | `homelab-cache-backups-prod` | 선언 있음 | 삭제 예정(D-11, 콘솔) |
| R2 | `homelab-tfstate` | Terraform 밖 수동 생성, 옛 root 3개의 백엔드 | 유지(D-11) |
| Tailscale | tailnet | NUC 접속 중 | 유지(D-11) |
| Tailscale | `homelab-1`, `pg-rw-1` | online, tagged | 삭제 예정(D-11) |
| Tailscale | `homelab-operator` | NUC에서 안 보임(ACL 때문일 수 있음) | 삭제 예정(D-11, 콘솔에서 존재 확인) |
| Tailscale | OAuth 클라이언트 3종 | Terraform 선언은 operator 1개, 나머지 둘은 Terraform 밖 | 삭제 예정(D-11·D-20, 콘솔) |
| Tailscale | NUC 노드 키 만료 | 태그 없음, 만료 없음 | 유지(D-12) |
| Tailscale | ACL·DNS | 전역 resolver 5개(NUC 1 + Cloudflare 4, C-05), 이 노드는 "Tailscale DNS: disabled" | 유지(옛 root 손대지 않음, T08a가 덮어씀) |
| GitHub | App reader(4043034), writer(4043080) | 등록·org 설치(`all`). writer는 새 저장소 `homelab-bot`·`homelab-bot-ops`에도 contents write가 닿는다 | 삭제 예정(D-11, 할 일 5.6) |
| GitHub | App aiops(4937062) | 등록·org 설치(`selected`). homelab 포함 여부는 API로 볼 수 없다 | 보류(D-13, T22). homelab 설치 여부는 사람 확인(할 일 5.7) |
| GitHub | App dispatch(4178609) | 등록 남음, org 설치 없음 | 삭제 예정(D-11, 할 일 5.6) |
| GitHub | Codex Connector | `selected`(선택 모드만 API로 확인, 저장소 목록은 사람 확인) | 유지(D-26) |
| GitHub | environment 4개 | `homelab-main` secret 19, `aiops-reusable-public-0915` 1, 나머지 둘 0. 변수 0 | 삭제 예정(D-11, 할 일 5.6) |
| GitHub | 저장소 수준 secret | Actions·Dependabot·Codespaces 모두 0 | 유지(정리할 것 없음) |
| GitHub | 저장소 변수 2개 | 그대로 | 삭제 예정(D-11, 할 일 5.6) |
| GitHub | `allow_auto_merge` | `true` | 변경 예정(할 일 5.4, D-07) |
| GitHub | ruleset 19598965, 23257797 | 둘 다 active, bypass는 writer App만 | 삭제 예정(할 일 5.5) |
| GitHub | webhook 647791528 | active, 마지막 응답 200 | 삭제 예정(할 일 5.5) |
| GitHub | 브랜치 보호(main) | 정리 목록 줄의 설정 그대로 | 삭제 예정(할 일 5.3) |
| GitHub | `main-interim` | 아직 없음 | 생성 예정(할 일 5.1. 만든 뒤 `유지(T10까지, T10 import)`) |
| GitHub | GHCR `page`, `trip-mate-api` | 404 | 삭제됨(D-29) |
| GitHub | GHCR `pg-tools`, `skopeo` | public | 삭제 예정(D-11. API가 거부하면 사람이 UI로) |
| GitHub | GHCR `files` | public | 유지(T22 재연결 대상) |
| GitHub | GHCR `aiops-autodeploy-canary` | private | 보류(D-29, T22) |
| GitHub | 저장소 `page`, `trip-mate-api` | 404 | 삭제됨(D-29) |
| 외부 감시·알림 | healthchecks `homelab-watchdog` | ping은 클러스터 안 `deadmanswitch-relay` | 보류(D-10, T08b) |
| 외부 감시·알림 | Telegram 봇 | 사본 위치는 정리 목록 줄 | 보류(D-10, T22) |
| 옛 AIOps | `aiops`와 App | private, secret 등 0. App은 GitHub 행 | 보류(D-13, T22) |
| 옛 AIOps | `aiops-autodeploy-canary` | private | 보류(D-29, T22) |
| 옛 AIOps | `mac-uptime-guard` | private, NUC 로컬 클론 있음 | 보류(담당 T22) |
| NUC | H1 유닛 | nft 서비스·mount active, ingress·worker inactive | 삭제 예정(D-12) |
| NUC | H2 파일·사용자·추가 잔여물 | `/etc/nftables.d/homelab-aiops.nft`만 확인 불가(상위 root 0700), 나머지 있음. 추가 잔여물은 H2 추가 줄 | 삭제 예정(D-12) |
| NUC | H3 유닛 | timer 둘 active, 옛 사본 스크립트 실행 | 삭제 예정(D-12, 옛 사본 이동 전) |
| NUC | H4 drop-in | 셋 다 있음 | 유지(D-12, T07이 덮어씀) |
| NUC | H5 노드 DNS | drop-in 있음, `/etc/resolv.conf`는 stub 아님, "Tailscale DNS: disabled" | 유지(D-12, T07이 맡음) |
| NUC | H6 swap | fstab swap 항목 0개 | 유지(할 일 없음) |
| NUC | H7 MOTD | motd-refresh timer active. 범위를 고쳤다(H7 줄) | 삭제 예정(D-12, 사용자 결정 2026-10-19: k3s 상태 표시만, 고양이 MOTD 유지) |
| NUC | H9 `k3s.service` | active·enabled. 옛 Argo CD 워크로드 6개 모두 replicas 1 | 삭제 예정(D-12) |
| 옛 데이터 | `/var/lib/rancher/k3s-storage` | 있음(아래는 root 0700) | 삭제 예정(H8, AdGuard 내보내기 뒤) |
| 옛 데이터 | `/mnt/bulk`와 fstab | 마운트됨, 2.2G 사용 | 삭제 예정(H8, 비운 뒤 fstab 항목 삭제) |
| 옛 데이터 | `/mnt/bulk-new` | root 0700 디렉터리, 내용 확인 불가 | 확인 불가(sudo로 보고 옛 데이터면 삭제 예정, H8) |
| 옛 데이터 | `/var/backups/files-data` | 있음 | 삭제 예정(H8, H3 뒤) |
| 옛 데이터 | `/var/lib/homelab-aiops.img` | loop로 마운트 중 | 삭제 예정(H8, mount 해제 뒤) |

### 실측으로 더한 줄

| 구역 | 줄 | 실측 | 상태 |
|---|---|---|---|
| GitHub | 저장소 `homelab`, `homelab-app-template`, `files` | public, archived 아님. 할 일 4는 앞의 둘을 옛 github state에서만 뺀다 | 유지(C-01, D-21, T22) |
| GitHub | 저장소 `homelab-bot`, `homelab-bot-ops` | 새 구조 저장소. secret 등 0 | 유지(새 구조, 정리 대상 아님) |
| GitHub | homelab 원격 브랜치 | `aiops/*` 12개, `renovate/*` 5개, `create-app/…` 1개 | 유지(T01: 원격 브랜치는 그대로 둠) |
| GitHub | org 수준 secret·변수·runner | 모두 0 | 유지(정리할 것 없음) |
| GitHub | org webhook | 조회 불가(`admin:org_hook` 범위 없음) | 콘솔 확인(있으면 삭제 예정, D-11) |
| GitHub | org fine-grained PAT 목록 | 조회 불가(GitHub App 토큰만 받는 API) | 콘솔 확인(자격 폐기 표의 PAT 줄과 대조) |
| NUC | `/usr/local/bin/kubectl`·`crictl`·`ctr` | `k3s` 심링크 | 삭제 예정(H9, `k3s-uninstall.sh`가 지움) |
| NUC | `/usr/local/bin/sops` | 일반 실행 파일 | 유지(기본값: 자격 아님, 새 구조와 충돌 없음. 지우기로 하면 할 일 6 뒤) |
| 옛 사본 | `.scratch`의 평문 자격(App PEM 3개, kubeconfig 사본 2개, 입력 파일) | 디렉터리 0700, 내용은 열지 않음 | 유지(기본값: 선행 확인 2대로 옛 사본은 디스크에 그대로 둠. reader·writer 키는 할 일 5.6, kubeconfig는 k3s 제거, aiops 키와 Telegram 토큰은 T22에 무효) |
| 옛 사본 | `.scratch`의 CLIProxyAPI fixture | 토큰 필드가 있는 파일 72개. README는 합성 fixture라 적음 | 확인 불가(사람이 합성인지 확인. 실제면 D-20대로 폐기) |
| 기타 | 로컬 클론 `~/workspace/page`, `~/workspace/trip-mate-api`(같은 범주: `~/workspace/example-app`, 원격 없는 `~/workspace/trip-mate`) | GitHub 저장소는 삭제됐거나 없음, `.env.local` 있음(열지 않음) | 유지(기본값: 로컬 자료. 안의 자격은 자격 폐기 표에서 폐기) |

### 사람이 콘솔에서 확인할 것

- GitHub: org 설정의 설치된 App에서 `ukyi-homelab-aiops`의 저장소 목록(homelab 포함 여부)과 Codex Connector의 선택 저장소 목록, dispatch App이 org 밖에 설치됐는지, 옛 App 키 지문과 `.scratch` PEM 대조, org의 다른 GitHub App·OAuth App, owner 계정과 org의 PAT 목록(`ghcr-pull-pat`, `github-tf-*-pat`, `HOMELAB_DISPATCH_PAT`), org webhook, 옛 App 4개의 개인 키 개수, GHCR `pg-tools`·`skopeo`의 버전별 다운로드 수.
- Cloudflare: zone 전체 DNS 레코드, Access 앱·정책, 터널 이름·개수, WAF·캐시 ruleset, zone 설정 라이브 값, API 토큰 목록(남은 4개 밖의 옛 토큰, media 버킷용 R2 토큰).
- R2: 버킷 4개와 `homelab-tfstate` 안 옛 state 키 3개.
- Tailscale: Machines의 `homelab-1`·`pg-rw-1`·`homelab-operator`, OAuth 클라이언트 개수·이름, "Override local DNS" 토글.
- healthchecks.io: 체크 전체 목록(이름), 연결된 통합, 읽기 전용 API 키, 선행 확인 4의 일시 정지.
- 비밀번호 관리자와 외장 매체: `homelab age recovery`, writer App 키 백업, 봉인 키 첨부, Tailscale CI OAuth 백업, 외장 SSD의 SOPS·App 키 사본.
- NUC sudo(할 일 2 전·중): `/etc/nftables.d`와 nft table 이름, AdGuard PVC, `/mnt/bulk`·`/mnt/bulk-new`·`/var/backups/files-data`·`/var/tmp/homelab-aiops-*`·`/nonexistent` 내용, `aiops-proxy` OAuth 저장 위치.
- 로컬 파일 키 이름만: `~/workspace/page`·`~/workspace/trip-mate-api`·`~/workspace/example-app`의 `.env.local`, 옛 사본 `infra/*/.terraform/terraform.tfstate` 3개, `~/workspace/mac-uptime-guard/config.env`, 옛 사본 `.env.secrets`. `~/.config/sops/age`의 공개키(`age-keygen -y`)와 옛 `.sops.yaml` cluster recipient 대조.
- 옛 사본 `.scratch`의 CLIProxyAPI fixture 72개가 합성 값인지.
- 번들 전에 옛 사본에서 fetch할지(원격 추적 ref가 2026-09-23 기준).
- OpenAI 계정: CLIProxyAPI 구독 세션 해제. 옛 AIOps 계획의 Claude 구독 토큰 발급 여부.
- Google Cloud·OXR: `trip-mate-api` 자격 폐기.

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

- 정리 목록과 자격 폐기 표의 모든 줄이 `삭제됨 / 유지(이유) / import 예정 / 보류(결정 ID 또는 담당 티켓)` 중 하나다. 자격 폐기 표의 `폐기`는 실행을 마치면 `삭제됨`으로 적는다. 실행 전 상태를 닫는 규칙은 "할 일 1 결과"의 상태 규칙이고, 정보 줄은 대상이 아니다.
- 자격 폐기 표의 옛 Telegram 봇 토큰 줄은 `보류(D-10, T22)`, 옛 healthchecks ping URL 줄은 `보류(D-10, T08b)`다. 두 줄은 폐기하지 않는다. `ts-node-key-nuc`는 `유지(D-12)`, `ukyi-homelab-aiops` App 키는 `보류(D-13, T22)`다.
- 설계 문서 0절 3항(옛 클러스터 정리), 4항(브랜치 보호와 ruleset 정리), 6항(옛 Terraform state 처리)이 "완료"다.
- main에 `main-interim`만 active이고, 옛 브랜치 보호는 404이며, `allow_auto_merge`는 `false`다.
- NUC에서 k3s와 H1·H2·H3의 유닛·파일이 없다. H7은 사용자 결정대로다: `motd-refresh` 유닛·drop-in과 `k3s-status.py`가 없고, `00-ukyi`는 2026-08-07 원본이다. H8 데이터 경로는 지웠고 `/mnt/bulk`는 비운 뒤 fstab 항목을 지웠다. H4·H5는 남아 있다.
- 할 일 8의 커밋·push가 끝났다.

## 검증

- Cloudflare, R2, Tailscale, GitHub 목록을 다시 조회해 정리 목록과 대조한다.
- GitHub, Cloudflare, Tailscale의 자격 목록을 다시 조회해 자격 폐기 표와 대조한다.
- `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`가 성공한다. `systemctl is-active k3s`는 멈추기만 한 상태도 `inactive`로 통과시키므로 쓰지 않는다.
- `systemctl list-unit-files | grep -E 'aiops|files-data|systemd-failed-sweep|unit-failure|motd-refresh'`의 결과가 비어 있다. D-12에서 남기기로 한 유닛은 제외한다.
- `systemctl status /var/lib/homelab-aiops`(경로로 조회)가 유닛 없음이고, `findmnt /var/lib/homelab-aiops`의 결과가 비어 있다.
- 재부팅 뒤 `getent passwd | grep '^aiops-'`와 `getent group aiops-state`가 비어 있고, `test ! -e /etc/sysusers.d/homelab-aiops.conf`가 성공하며, `sudo nft list tables`에 AIOps table이 없다.
- `cmp /etc/update-motd.d/00-ukyi ~/workspace/ukyi-motd/00-ukyi`가 성공하고 `test ! -e /usr/local/share/ukyi-motd/k3s-status.py`가 성공한다(H7 결정).
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
