# T06 옛 클러스터 철거·외부 자원 정리

- 단계: P2 플랫폼 구축 (잠정, T05가 재분해)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §4.5, §10
- Blocked by: T05, T02(push), T01(열린 PR 닫기)
- 선행 결정: D-02 (확정: T05 뒤, 부트스트랩 직전), D-10, D-11, D-12, D-13 (옛 AIOps 줄만. 일부 확정(사용자 2026-10-18): aiops 저장소·App 제거, 실행은 T22), D-26, D-27, D-28 (확정(사용자 2026-10-18): 이 티켓의 GitHub 설정 변경은 `gh api`, T10에서 import), D-29 (확정(사용자 2026-10-18): `page`·`trip-mate-api` 삭제, 비앱 저장소 private 보관)
- 연결 AC: AC-P4, AC-X2
- 수행: 사람 (sudo, 콘솔, 삭제). 에이전트는 목록 작성과 대조

## 목표

옛 클러스터를 내리고, 새 Terraform과 충돌할 옛 외부 자원을 정리한다. 옛 자격을 폐기하고, NUC에 남은 옛 호스트 설정과 옛 데이터를 지운다.

## 선행 확인 (시작 조건)

다섯 항목이 모두 끝나야 할 일 2 이후를 시작한다.

1. 최신 계획, 설계 문서(`platform/design.md`), T05 결정, 티켓이 원격 `rebuild` 브랜치에 push돼 있다. D-12에서 OS 재설치를 고르면 이 NUC의 파일이 모두 사라진다.
2. NUC 로컬 보존 점검. D-12 결과와 무관하게 한다.
   - 옛 사본(`~/workspace/homelab`)의 push 안 된 브랜치와 워크트리를 `git bundle`로 묶어 NUC 밖에 둔다. 예: `git -C ~/workspace/homelab bundle create ~/homelab-local-$(date +%F).bundle --all` 뒤 그 파일을 NUC 밖으로 옮긴다.
   - 미커밋 변경은 번들에 들어가지 않는다. 어떻게 할지 사용자가 정한다.
   - 다음은 할 일 4(state 처리)와 자격 폐기가 끝날 때까지 지우지 않는다: 옛 사본의 `docs/runbooks/`, `.env.secrets`, `infra/{cloudflare,github,tailscale}/backend.hcl`, `infra/{cloudflare,github,tailscale}/terraform.tfvars`, 그리고 `~/.config/sops/age`.
   - AdGuard 라이브 설정을 비밀값을 빼고 내보내 T08 입력으로 둔다(사람, sudo). 파일은 `/var/lib/rancher/k3s-storage/internal/` 아래 AdGuard PVC(`…_edge_adguard-data`)의 `AdGuardHome.yaml`이다. 옛 저장소의 ConfigMap은 첫 부팅 시드라서 라이브 규칙·필터와 다를 수 있다. 사용자 비밀번호 해시와 API 키는 뺀다. LAN 기기 이름과 내부 재작성 규칙이 들어 있으므로 저장소에 커밋하지 않고, 저장소 밖이면서 NUC 밖인 비공개 위치에 둔다. 이 티켓에는 위치만 적는다.
   - D-12에서 OS 재설치를 고르면 다음도 보존한다: `~/.codex*`, `~/.claude*`, `~/.agents`, `~/.ssh`, `~/.config`, `~/.gnupg`, `~/workspace`의 원격 없는 저장소(`polyrelay` 등), `~/workspace/homelab-infra`.
3. 돌아갈 수 없는 지점 확인. T06이 끝나면 옛 홈랩으로 돌아갈 수 없다. 외부 자원이 지워지고, 클러스터 안의 SealedSecrets 봉인 키도 k3s와 함께 사라진다. 시작 전에 사용자가 이를 확인하고 [approvals.md](../approvals.md)에 남긴다.
4. healthchecks.io 체크 `homelab-watchdog`를 철거 전에 일시 정지한다. 철거하면 ping이 끊겨 down 알림이 간다.
5. T01의 열린 PR 닫기가 끝났다(명세 AC-P1). `gh pr list -R ukyi-app/homelab`에 열린 PR이 없다. 할 일 5에서 `gate`를 풀면 남은 PR을 검사 없이 병합할 수 있게 된다.

## 할 일

1. 아래 "정리 목록"과 "자격 폐기 표"를 채운다. 시크릿 값은 쓰지 않고 이름·ID만 쓴다.
   - 목록 입력: `gh api`로 실측한 GitHub 상태, `legacy`의 `policy/credential-expiry.json` 전체 행, 옛 Terraform root 선언(`legacy`의 `infra/cloudflare`, `infra/github`, `infra/tailscale`). D-27이 허용하면 로컬 런북(`token-inventory` 등)도 입력으로 쓰되 이름만 옮긴다.
   - 코드 밖 자원(Cloudflare Access 앱·정책 등)은 콘솔에서 다시 조회해 확인한다.
2. 옛 Argo CD를 멈추고, k3s와 NUC 잔여물을 지운다.
   - root 앱이 Application과 ApplicationSet을 selfHeal로 소유한다. 그래서 Application 단위로 자동 동기화를 끄는 것은 효과가 없다. 컨트롤러가 되돌린다.
   - 옛 사본의 kubeconfig(`~/workspace/homelab/infra/k3s-bootstrap/kubeconfig`, sudo 불필요)로 `argocd` 네임스페이스의 `argocd-application-controller`(StatefulSet)와 `argocd-applicationset-controller`(Deployment)를 0으로 줄인다. 두 컨트롤러의 파드가 없는지 확인한다.
   - application-controller를 먼저 줄인다. 옛 Argo CD는 자기 자신도 selfHeal로 관리하므로, application-controller가 살아 있으면 다른 컨트롤러의 축소를 되돌릴 수 있다(추측).
   - 그다음 D-12 방식으로 k3s를 제거한다. 이때 클러스터 안의 SealedSecrets 봉인 키가 사라진다(선행 확인 3).
   - AdGuard 설정 내보내기(선행 확인 2)가 끝났는지 확인하고 옛 데이터 경로를 지운다.
   - NUC 호스트 잔여물을 D-12 판정대로 지운다.
3. 외부 자원을 삭제한다. `prevent_destroy`가 걸린 버킷은 콘솔에서 지운다.
4. 옛 Terraform state를 처리한다.
   - github root: destroy하지 않는다. `github_repository.homelab`과 `github_repository.app_template`(`homelab-app-template`, D-21)을 state에서 제거한다. 둘 다 삭제 방지가 없어서 destroy하면 저장소가 지워진다.
   - 옛 state 객체(`homelab-tfstate`의 `cloudflare/prod`, `github/prod`, `tailscale/prod` 아래 `terraform.tfstate`)에는 평문 자격이 들어 있다. 비공개 위치로 옮겨 보관한 뒤 원래 키를 지운다.
   - 새 root는 옛 키를 쓰지 않는다. 같은 키를 쓰면 새 root가 옛 state를 읽어, plan이 옛 자원의 삭제를 제안한다.
   - cloudflare·tailscale root: D-11에 따라 폐기하거나 새 코드로 import한다.
5. 브랜치 보호·ruleset·webhook을 정리한다(사람 승인). 순서는 설계 문서 E1이다. 옛 보호를 지우기 전에 임시 보호를 먼저 건다. 그래야 T10에서 ruleset A~D가 생길 때까지 main이 열리지 않는다(T07부터 Argo CD가 main을 자동 동기화하고, Codex Connector는 contents write가 있다).
   1. 임시 ruleset `main-interim`을 `gh api`로 만든다. 대상 main, PR 필수, 승인 1, code owner 리뷰 필수, 새 push 때 승인 무효화, force push·삭제 금지, bypass는 저장소 관리자 역할(`pull_request` 모드)만.
   2. `main-interim`이 active인지 확인한다: `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .enforcement` → `active`, `gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[].type]'`에 `pull_request`. 같은 때 `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .current_user_can_bypass`(owner) → `pull_requests_only`를 기록한다(U08 셋째 조건).
   3. 확인한 뒤에만 옛 브랜치 보호 전체(`gate`, push 제한 포함)를 지운다: `gh api -X DELETE repos/ukyi-app/homelab/branches/main/protection`. 같은 경로가 404인지 본다. T10부터 Terraform guard 6이 이 404를 계속 확인하므로, 일부만 지우면(필수 검사·push 제한만) 보호 객체가 남아 T10의 guard가 실패한다. `gate`가 남으면 T07의 main 교체 PR이 끝없이 검사를 기다린다.
   4. `gh api -X PATCH repos/ukyi-app/homelab -F allow_auto_merge=false`.
   5. ruleset 2개와 webhook 647791528을 지운다: `gh api -X DELETE repos/ukyi-app/homelab/rulesets/19598965`, `gh api -X DELETE repos/ukyi-app/homelab/rulesets/23257797`, `gh api -X DELETE repos/ukyi-app/homelab/hooks/647791528`.
   6. 옛 aiops App(`ukyi-homelab-aiops`)이 homelab에 설치돼 있으면 homelab 설치만 해제한다(App 삭제는 T22). 남아 있으면 그 App의 승인 리뷰가 `main-interim`의 승인 1을 채울 수 있다(추측). 옛 main에는 `CODEOWNERS`가 없어 T07의 main 교체 전까지는 승인 1만 막기 때문이다.
   - 이 단계의 GitHub 설정 변경은 `gh api`로 한다. 새 Terraform github root(D-28)는 T10에서 생기고, 그때 이 단계 뒤에 남는 ruleset을 import한다(T05 할 일 11).
6. 자격 폐기 표대로 폐기한다. state 처리에 쓰는 자격은 할 일 4가 끝난 뒤 마지막에 폐기한다.
7. 선행 확인과 할 일 2~6의 모든 실행을 [approvals.md](../approvals.md)에 기록한다. 식별자만 쓰고 값은 쓰지 않는다.
8. T07의 main 병합 전에, 이 티켓의 정리 목록·자격 폐기 표 상태와 approvals.md를 `rebuild`에 커밋하고 push한다(사람 승인, 명세 §12). 이 티켓에는 이름·ID·상태만 있으므로 공개돼도 된다.

## 정리 목록 (할 일 1의 최소 범위)

2026-10-17 실측과 `legacy` 선언 기준이다. 실행할 때 다시 조회해 빠진 줄을 더한다.

### Cloudflare

- 터널 `homelab-prod`.
- DNS 레코드. 라이브 공개 이름은 `ukyi.app`, `www`, `argocd-webhook`, `files` 등이다.
- WAF 규칙 `homelab-waf-custom`, `homelab-waf-ratelimit`. 캐시 규칙 `homelab-cache-rules`.
- zone 설정 9개: HSTS(includeSubDomains, 180일), `always_use_https`, `min_tls_version` 1.2, `tls_1_3`, `opportunistic_encryption` off, `automatic_https_rewrites`, `browser_check`, `security_level` medium, `email_obfuscation`. 새 코드로 가져옴 / 유지 / 해제 중 하나로 정한다(D-11). zone이 남으므로 옛 state를 버려도 이 설정은 Cloudflare에 그대로 남는다.
- Access 앱·정책 등 코드 밖 자원. 콘솔에서 다시 조회해 확인한다.

### R2

- `homelab-pg-backups-prod`, `homelab-media-prod`: `prevent_destroy`가 걸려 있어 콘솔에서 지운다.
- `homelab-cache-backups-prod`.
- `homelab-tfstate`: D-11에 따라 유지(추천). 그 안의 옛 state 객체는 할 일 4에서 처리한다.

### Tailscale

- tagged 기기 `homelab-1`, `pg-rw-1`.
- operator 기기 `homelab-operator`. NUC에서는 ACL 때문에 보이지 않아 존재를 먼저 확인한다.
- OAuth 클라이언트 3종: owner 부트스트랩(Terraform 밖, 쓰기 스코프), CI 읽기 전용, operator.
- NUC 노드 키 만료 설정. 2026-10-17에는 만료가 해제돼 있다. OS를 재설치해 다시 등록하면 만료가 기본값(켜짐)으로 돌아오고 Tailscale IP가 바뀔 수 있다. 그러면 만료를 다시 해제하고 전역 nameserver의 NUC 주소를 고친다. T08의 Terraform(D-08)은 hostname으로 NUC를 찾아 새 IP를 쓰고, 만료 해제를 precondition으로 확인한다.
- ACL·DNS: 옛 root를 apply도 destroy도 하지 않는다. 새 코드(T08)가 덮어쓴다. DNS는 D-08(확정(사용자 2026-10-18))대로 Terraform `tailscale_dns_configuration`이 맡는다. 새 ACL은 `autogroup:self`와 ssh 규칙을 유지해야 NUC 원격 접속이 끊기지 않는다.

### GitHub

- App 4개:
  - `ukyi-homelab-reader`(4043034), `ukyi-homelab-writer`(4043080).
  - `ukyi-homelab-aiops`(4937062): 제거(D-13 일부 확정, 2026-10-18). 실행은 T22라 이 티켓의 줄 상태는 `보류(D-13, T22)`.
  - `ukyi-homelab-dispatch`(4178609): org 설치는 없다. 등록만 남았는지 확인한다.
- ChatGPT Codex Connector: D-26대로 처리한다.
- environment 4개: `homelab-main`(secret 19개), `aiops-authority-empty-0915`, `aiops-authority-empty-0916`, `aiops-reusable-public-0915`(secret 1개).
- "저장소 시크릿"은 실제로 environment `homelab-main`의 secret이다. 저장소 수준 secret은 0개다.
- 저장소 변수 2개: `HOMELAB_DOMAIN`, `HOMELAB_OWNER`.
- ruleset 2개: 19598965 `bump-poll-writer-only`, 23257797 `mutation-branches-writer-only`. 둘 다 브랜치 생성·갱신을 막고 writer App만 우회한다. writer App을 지우면 ruleset이 남아 있는 동안 그 접두사(`bump-poll/`, `bump/`, `create-app/`, `create-database/`, `create-cache/`, `update-secrets/`)의 브랜치는 아무도 만들 수 없다. 그래서 할 일 5에서 지운다.
- 저장소 webhook 647791528: push 이벤트를 `argocd-webhook.ukyi.app`으로 보낸다. 터널을 지운 뒤에는 전송이 계속 실패한다.
- 브랜치 보호(main): 필수 검사 `gate`, push 제한(users `ukkiee`, apps writer).
- GHCR 패키지 6개: `pg-tools`, `skopeo`, `page`, `trip-mate-api`, `files`, `aiops-autodeploy-canary`.
  - `page`, `trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29, [../approvals.md](../approvals.md)). `page` 패키지는 API 삭제가 거부돼(아래) 사람이 직접 지웠다.
  - 나머지 4개: 유지 / 삭제를 정한다. public 패키지는 한 버전이라도 다운로드가 5000회를 넘으면 API로 지울 수 없다(2026-10-18 `page`에서 HTTP 400). 그날 UI의 전체 다운로드는 `skopeo` 1.76k, `pg-tools` 973, `aiops-autodeploy-canary` 9.37k(private라 이 제한과 무관)였다.
- 앱 저장소 `ukyi-app/page`, `ukyi-app/trip-mate-api`: `삭제됨`(2026-10-18 결정·실행, D-29). 쓰지 않는 앱이다. 두 앱의 옛 자격은 자격 폐기 표에서 폐기한다.

### 외부 감시·알림

- healthchecks.io 체크 `homelab-watchdog`: 유지·재사용·삭제(D-10, D-11). 일시 정지는 선행 확인 4.
- Telegram 봇: D-10. 토큰은 자격 폐기 표에 있다.

### 옛 AIOps 저장소

- `ukyi-app/aiops`와 App `ukyi-homelab-aiops`: 제거(D-13 일부 확정, 2026-10-18. aiops는 쓰지 않는다). 실행은 T22라 줄 상태는 `보류(D-13, T22)`.
- `ukyi-app/aiops-autodeploy-canary`: 공개하지 않고 private로 보관(D-29, 삭제도 가능). 실행은 T22라 줄 상태는 `보류(D-13, T22)`.
- `mac-uptime-guard`(private, 옛 맥 미니용, 옛 Telegram 토큰 사용): 공개하지 않고 private로 보관(D-29). 줄 상태는 `보류(담당 T22)`.

### NUC 호스트 잔여물 (D-12)

옛 AIOps:

- 유닛: `aiops-ingress.service`, `aiops-worker.service`(static)·`aiops-worker.timer`, `homelab-aiops-nft.service`, `'var-lib-homelab\x2daiops.mount'`.
- mount 유닛 이름의 `\x2d`는 systemd 경로 이스케이프다. 셸에서는 작은따옴표로 감싸거나 `systemctl status /var/lib/homelab-aiops`처럼 경로로 지정한다. 이스케이프 없는 이름으로 조회하면 not-found가 나와 "이미 없음"으로 잘못 닫힌다. 2026-10-17에는 active이고, loop 이미지 위의 ext4다.
- 파일: `/var/lib/homelab-aiops.img`, `/opt/homelab-aiops`, `/etc/homelab-aiops`(AIOps App 개인 키), `/usr/local/libexec/homelab-aiops-ingress-firewall.py`, `/etc/nftables.d/homelab-aiops.nft`, drop-in(`aiops-ingress.service.d/*`, `aiops-worker.service.d/*`), `/etc/tmpfiles.d/homelab-aiops.conf`.
- 시스템 사용자 `aiops-*` 8개와 그룹 `aiops-state`. `aiops-proxy`의 CLIProxyAPI 저장소에 ChatGPT 구독 OAuth가 있다.

옛 `host-config.sh --apply`가 깐 것:

- 유닛: `files-data-backup.service`·`.timer`, `systemd-failed-sweep.service`·`.timer`, `unit-failure-notify@.service`. 셋 다 옛 사본(`~/workspace/homelab/scripts/`)의 스크립트를 실행하고, `files-data-backup`은 옛 사본의 kubeconfig도 쓴다.
- drop-in: `sshd_config.d/10-k3s-node.conf`, `journald.conf.d`, `tmpfiles.d`(NVMe ASPM).
- 노드 DNS 순환을 막는 설정: `resolved.conf.d/10-k3s-node.conf`, `10-netplan-wlo1.network.d`. `tailscale set --accept-dns=false`도 같은 목적이다(명세 §4.5). 새 설계가 대체할 때까지 남길지 D-12에서 판정한다. 대체 없이 지우면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 다시 생길 수 있다.
- 그 밖: `/etc/resolv.conf` 심링크, fstab의 swap 제거.

옛 `infra/k3s-bootstrap/motd`가 깐 것: `motd-refresh.service`·`.timer`, `/etc/update-motd.d/00-ukyi`.

### 옛 데이터 경로 (D-12)

- `/var/lib/rancher/k3s-storage`: 옛 PV 데이터(AdGuard 설정 포함). `k3s-uninstall.sh`는 `/var/lib/rancher/k3s`, `/var/lib/kubelet`, `/etc/rancher/k3s`만 지우고 이 경로를 남긴다.
- `/mnt/bulk`와 그 fstab 항목: 별도 1.8T 디스크, 옛 files 데이터(C-03 폐기 대상).
- `/var/backups/files-data`: `files-data-backup.timer`가 매일 쓴다.
- `/var/lib/homelab-aiops.img`: AIOps loop 이미지(옛 AIOps 줄과 같은 파일).

## 자격 폐기 표 (할 일 1·6)

새로 발급해도(D-20) 옛 자격은 따로 폐기하기 전까지 살아 있다. 각 줄을 `폐기 / 유지(이유) / 보류(결정 ID, 담당 티켓)` 중 하나로 정한다. 담당은 보통 T09다. 값은 쓰지 않는다.

철거 뒤에는 옛 자격을 쓰는 곳이 없으므로 기본은 이 티켓에서 폐기한다. 새 플랫폼이 이어 쓰는 자산의 자격(D-20에 따른 SOPS age 키)만 `보류(…, T09)`로 두고, T09가 새 자격을 등록하면서 닫는다.

**예외: 옛 healthchecks ping URL은 `보류(D-10, T08)`로 둔다.** 체크는 선행 확인 4에서 일시 정지돼 있다. T08이 새 외부 생존 감시를 연결하고 정상(초록)을 확인한 뒤 옛 체크를 지우거나 재사용 결과를 기록하며 이 줄을 닫는다. D-10이 healthchecks.io를 쓰지 않기로 정하면 T08 시작 때 바로 지운다.

**예외: 옛 Telegram 봇 토큰은 D-10 결정과 상관없이 이 티켓에서 폐기하지 않는다.** 저장소 밖의 `mac-uptime-guard`가 같은 토큰을 쓰기 때문에, 폐기하면 그쪽 알림이 아무 표시 없이 끊긴다. 줄은 `보류(D-10, T22)`로 둔다. D-10이 옛 봇을 다시 쓰기로 정하면 T09가 `mac-uptime-guard` 설정을 함께 바꾸고 이 줄을 닫는다. 새 봇을 쓰기로 정하면 T22가 `mac-uptime-guard`를 처리한 뒤 닫는다.

**순서:** state 처리에 쓰는 자격(`r2-terraform-state`, `cf-tf-root-token` 등)은 할 일 4가 끝난 뒤에 폐기한다. 먼저 폐기하면 할 일 4가 막힌다.

| 자격 | 무엇 | 주의 |
|---|---|---|
| `ghcr-pull-pat` | GHCR 읽기용 classic PAT, 무만료 | 새 구조에는 GHCR pull 자격이 없다(D-29) |
| `github-tf-root-pat` | github root용 PAT(Administration·Secrets 읽기·쓰기), 무만료 | |
| `github-tf-ci-pat` | CI 읽기용 PAT | |
| `tailscale-ci-oauth-client` | Tailscale CI 읽기 전용 OAuth 클라이언트 | owner 부트스트랩 OAuth와 별개 |
| `r2-terraform-state` | `homelab-tfstate` 접근 R2 키 | 할 일 4 뒤 |
| `ts-node-key-nuc` | NUC 노드 키(만료 해제) | 폐기하면 NUC가 tailnet에서 빠져 Tailscale 경로의 원격 접속이 끊긴다 |
| `argocd-github-webhook` | webhook 647791528의 secret | webhook 삭제(할 일 5)와 함께 |
| `github-dispatch-app` | App `ukyi-homelab-dispatch`(4178609) | 설치는 없다. 등록이 남았는지 확인 |
| `cf-tf-root-token` | Cloudflare 토큰 `homelab-terraform-cloudflare`(Account·Zone Edit) | 할 일 4 뒤 |
| `cf-certmanager-token` | Cloudflare 토큰 `homelab-certmanager-dns01` | 새 구조에는 대응 토큰이 없다(D-08) |
| `r2-backups-pg-cache` | 백업 버킷용 R2 키 `homelab-backups-pg-cache` | |
| 옛 App 키 | `ukyi-homelab-reader`, `ukyi-homelab-writer` | `ukyi-homelab-aiops` 키는 `보류(D-13, T22)`. T22가 App 제거(D-13 일부 확정)와 함께 폐기한다 |
| Tailscale 부트스트랩 OAuth | owner 로컬용, Terraform 밖, 쓰기 스코프 | |
| Tailscale operator OAuth | 옛 operator용(devices:core·auth_keys) | |
| Telegram 봇 토큰 | 옛 알림 봇 | `보류(D-10, T22)` 고정(위 예외). `mac-uptime-guard`도 이 봇을 쓴다 |
| healthchecks ping URL | `homelab-watchdog` 체크 | `보류(D-10, T08)` 고정(위 예외). D-11 |
| `trip-mate-api` Google OAuth client | `trip-mate-api` 로그인용 Google OAuth 클라이언트 | 앱 삭제로 폐기(D-29). Google Cloud 콘솔에서 지운다 |
| `trip-mate-api` OXR app id | `trip-mate-api`가 쓰던 OXR app id | 앱 삭제로 폐기(D-29). 발급처 계정에서 폐기한다 |
| `trip-mate-api` `BETTER_AUTH_SECRET` | `trip-mate-api`의 Better Auth 비밀값 | 앱 삭제로 폐기(D-29). 외부 발급처가 없는 값이라 저장된 사본이 남지 않았는지 확인하고 닫는다 |
| `page` admin token | `page` 관리자 토큰 | 앱 삭제로 폐기(D-29). 저장된 사본이 남지 않았는지 확인하고 닫는다 |
| SealedSecrets 봉인 키 | 클러스터 안의 키는 k3s 제거로 사라진다 | out-of-band 백업본이 있으면 그 처리도 정한다 |
| SOPS age 키 | `~/.config/sops/age` | 옛 SOPS 파일의 recipient와 맞으면 옛 공개 히스토리의 SOPS 파일을 풀 수 있다(일치 여부 미확인). D-20에 따라 보류(T09) 또는 할 일 4와 다른 자격 폐기 뒤 폐기 |

## 제약

- 저장소는 유지한다(C-01). Cloudflare zone, tailnet, `homelab-tfstate` 버킷은 D-11 결정대로 처리한다(추천은 유지).
- 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다. apply하면 Cloudflare 임시 DNS 폴백(C-05)이 사라진다. ACL·DNS는 새 코드(T08)가 덮어쓴다.
- 맥 `~/Documents/`의 옛 프롬프트 원본 사본은 지우지 않는다.
- 옛 사본(`~/workspace/homelab`)은 할 일 4, 자격 폐기, 호스트 유닛 제거가 끝날 때까지 옮기거나 지우지 않는다. 호스트 유닛이 그 안의 스크립트를 실행하고, state 처리에 쓰는 파일과 kubeconfig가 그 안에 있다.
- 이 시점부터 AdGuard가 없다. LAN은 공유기 보조 DNS, Tailscale 기기는 Cloudflare 임시 DNS로 동작한다.

## 완료 조건

정리 목록과 자격 폐기 표의 모든 줄이 `삭제됨 / 유지(이유) / import 예정 / 보류(결정 ID 또는 담당 티켓)` 중 하나다. 자격 폐기 표의 `폐기`는 실행을 마치면 `삭제됨`으로 적는다. 할 일 8의 커밋·push가 끝났다.

## 검증

- Cloudflare, R2, Tailscale, GitHub 목록을 다시 조회해 정리 목록과 대조한다.
- GitHub, Cloudflare, Tailscale의 자격 목록을 다시 조회해 자격 폐기 표와 대조한다.
- `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`가 성공한다. `systemctl is-active k3s`는 멈추기만 한 상태도 `inactive`로 통과시키므로 쓰지 않는다.
- `systemctl list-unit-files | grep -E 'aiops|files-data|systemd-failed-sweep|unit-failure|motd-refresh'`의 결과가 비어 있다. D-12에서 남기기로 한 유닛은 제외한다.
- 옛 데이터 경로(`/mnt/bulk`와 fstab 항목, `/var/backups/files-data`, `/var/lib/homelab-aiops.img`)가 D-12 판정대로 처리됐다.
- `gh api repos/ukyi-app/homelab --jq .archived`가 `false`다.
- `gh api repos/ukyi-app/homelab/rulesets --jq '[.[] | {name, enforcement}]'`가 `main-interim` 하나, `active`다. `gh api repos/ukyi-app/homelab/branches/main/protection`이 404다. `gh api repos/ukyi-app/homelab --jq .allow_auto_merge`가 `false`다. 옛 aiops App이 homelab에 설치돼 있지 않다(`gh api orgs/ukyi-app/installations`의 그 App `repository_selection`이 `all`이면 설치된 것이고, `selected`면 org 설정의 설치된 App 화면 Repository access에서 homelab이 없는지 본다).
- [approvals.md](../approvals.md)에 선행 확인 3의 사용자 확인과 이 티켓의 외부 변경이 모두 있다.
