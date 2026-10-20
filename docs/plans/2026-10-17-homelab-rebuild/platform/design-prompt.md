# 홈랩 신규 구축: 플랫폼·CI/CD·데이터·시크릿 설계

> **문서 역할:** 플랫폼 설계 에이전트(T04)에게 그대로 주는 설계 프롬프트다. 설계 결과는 [design.md](design.md)에 쓴다(T04 산출물, 2026-10-18 작성). 계획의 상태·결정·순서·인수 조건은 [spec.md](../spec.md)가 기준이다.
>
> **이력:** 2026-10-17. 사용자가 옛 홈랩 개선용으로 쓴 원본 프롬프트를 신규 구축 기준으로 다시 쓰고, T03 보강(봇을 위한 여지, 옛 함정 기록, 시나리오 16·17, 결정 D-10~D-12, D-18, D-20~D-22)과 2026-10-17 심층 감사(공개 범위, 확인 경로, 교훈 표 단위, 자동 병합 주체 조건, 격리 공간 범위 등)를 반영한 문서다. 원본에만 있던 지시 중 지금도 유효한 것(금지 목록의 DB·시크릿 변경, 권한 공유 기본값, 옛 결정을 바꿀 때의 이유)도 옮겼다. 옛 `docs/cicd-simplification-prompt.md`와 `docs/archive/cicd-simplification-prompt.orig.md`를 대체한다. 2026-10-18에 spec §12대로 확정 결정을 각 자리에 채웠다: 대화에서 확정된 D-04·D-08·D-13(일부)·D-28·D-29, T05에서 확정된 D-05~D-07·D-09~D-12·D-18·D-20~D-22·D-25~D-27, 설계 기본값(ESO, 공개 DNS, Argo CD 폴링, 백업 보존, 격리 작업 공간). 같은 날 T14에서 확정된 D-13의 나머지(봇 저장소 이름, 산출물 위치, 봇 문서의 최종 위치)도 채웠다. 같은 날 T15에서 확정된 D-14~D-17·D-24도 채웠다(§2 봇을 위한 여지, §5, §10-F). 2026-10-20 대화에서 확정된 D-30(내부 UI 짧은 주소)도 §10-F에 채웠다.
>
> **문서 관리:** spec·티켓·봇 문서가 이 문서를 § 번호와 §9 시나리오 번호로 참조한다. 새 내용은 해당 절 안이나 끝에 덧붙이고, 기존 번호는 다시 매기지 않는다.

너는 Kubernetes·GitOps·개발자 경험에 전문성이 있는 시니어 플랫폼 엔지니어다.

기존 홈랩을 대체할 새 홈랩을 처음부터 설계해라. 작은 앱을 쉽게 추가·배포·관리할 수 있어야 하고, 사람이 쓰기 쉬우며, 코딩 에이전트도 적은 맥락만으로 정확하게 작업할 수 있어야 한다.

옛 홈랩은 기능은 많았지만 절차·검사·예외가 과하게 쌓였다. 새 홈랩의 목표는 같은 위험을 더 적은 장치로 막는 **작은 플랫폼**이다.

**함께 읽을 문서:** `docs/plans/2026-10-17-homelab-rebuild/spec.md`의 §1(현재 상태), §4.5(현실 제약), §5(결정), §7(인수 조건 중 AC-P2, AC-P8, AC-P12), §10(위험과 제약). 그리고 티켓 `issues/T04-platform-design.md`(완료 조건). 이 문서와 spec의 사실·결정이 어긋나면 spec이 맞다.

**결과물:** 조사·설계 문서 하나다. 경로는 절대 경로 `/home/ukyi/homelab/docs/plans/2026-10-17-homelab-rebuild/platform/design.md`다(작업 트리 `/home/ukyi/homelab`. 옛 사본 `~/workspace/homelab`에는 쓰지 않는다). §10의 0절, A~F, G절 순서로 쓴다.

**공개 범위:** `homelab`은 public이라 design.md는 공개된다(D-23, 확정). 시크릿 값과 운영 민감 정보(복구 자산 세부, 토큰 목록, 로컬 런북 내용)는 쓰지 않는다.

**작업 범위:** 읽기 전용 조사(옛 저장소 읽기, §1 확인 경로 안의 상태 확인, 공식 문서 조회)와 설계 문서 작성까지다. 다음은 각각 사람의 별도 승인 뒤의 일이다.

- 저장소 변경, PR 생성, 배포, Terraform apply.
- DB 변경, 시크릿 변경, 계정·토큰 발급.
- 외부 자원 삭제.
- 옛 클러스터·옛 Argo CD·Cloudflare·Tailscale 설정 변경. 옛 클러스터는 아직 가동 중이고(spec §1), Tailscale 전역 DNS에는 손으로 넣은 임시 폴백이 있다(§1 5항).

시크릿의 실제 값은 조회하거나 출력하지 않는다.

---

## 0. 전제와 결정 상태 (2026-10-17, 2026-10-18 결정 반영)

결정 상태의 기준은 spec.md §5다. 어긋나면 spec이 맞다.

- **확정(C-xx, spec §5.1로 옮긴 D-xx):** 사용자가 정한 결정이다. 설계의 고정값으로 쓴다.
- **추천, 미정:** 아직 정하지 않은 추천안이다. 설계의 출발점으로만 쓴다. 조사 결과 다른 선택이 낫다면 §10-A에 조정 권고로 적고, 사용자 결정이 필요하면 §10-F에 올린다.
- **사실:** 실측한 현재 상태다. 설계가 따를 제약으로 쓴다.

| 항목 | 내용 | 상태 |
|---|---|---|
| 방식 | **신규 구축.** 옛 홈랩과의 호환·데이터 이전 의무 없음 | 확정 (C-01, C-02, C-03) |
| 저장소 | `ukyi-app/homelab`을 그대로 쓰고 내용을 교체. 옛 코드는 참고용으로만 읽는다(읽는 곳은 §3). 저장소 히스토리는 유지한다(D-03, 확정: `legacy` 태그 + 교체 커밋). rebuild → main은 squash 병합이라 옛 main은 새 main의 조상으로 남고, rebuild 중간 커밋은 PR 기록에 남는다(D-25) | 확정 (C-01). 병합 방식: D-25 확정(사용자 2026-10-18, T05) |
| GitHub 요금제·공개 범위 | org `ukyi-app`은 Free 플랜, `homelab`은 public. Free에서 브랜치 보호·ruleset은 public 저장소에서만 동작한다. 앱 저장소는 public만 허용하고, 앱이 아닌 저장소는 공개하지 않는다 | 사실 (2026-10-17 실측). public 유지 확정 (D-23). 저장소 공개 정책: D-29 확정(사용자 2026-10-18) |
| 데이터 | 옛 PostgreSQL·Valkey 데이터, R2 `homelab-pg-backups-prod`·`homelab-cache-backups-prod`·`homelab-media-prod`, files 서비스 데이터 **모두 폐기** | 확정 (C-02, C-03) |
| 하드웨어 | 같은 NUC 한 대(`nuc-15-pro`, LAN `192.168.117.15`), k3s 새로 설치. 옛 클러스터와 동시에 돌릴 수 없어 구축 기간에는 홈랩 서비스가 멈춘다. 철거 방식은 OS 유지 + k3s 제거 + 호스트 정리다(설계 문서 F D-12) | 확정 (C-07 단일 서버. 철거 방식은 D-12 확정(사용자 2026-10-18, T05). 사실은 spec §1·§4.5) |
| 이어 쓰는 외부 자산 | Cloudflare zone(apex 도메인), Tailscale tailnet, R2 state 버킷 `homelab-tfstate`(새 state 키 접두 `v2/`), GitHub org `ukyi-app`, 저장소 `homelab-app-template`(내용 교체). healthchecks.io는 계정만 재사용하고 체크는 새로 만든다(옛 `homelab-watchdog`는 새 체크가 초록이 된 뒤 삭제). Telegram은 homelab 알림용 새 봇을 쓰고, 옛 봇·토큰은 `mac-uptime-guard`를 처리하는 T22까지 그대로 둔다. 나머지 옛 외부 자원은 새로 정의하고, 하나뿐인 설정(Tailscale ACL·DNS)은 덮어쓴다. zone 설정 9개는 새 Terraform으로 가져온다 | zone·tailnet·`homelab-tfstate`·나머지 처리: D-11 확정(사용자 2026-10-18, T05). `ukyi-app` org: 확정 (C-01). `homelab-app-template` 재사용: D-21 확정(사용자 2026-10-18, T05). healthchecks.io 계정 재사용·새 체크, Telegram 새 봇: D-10·D-11 확정(사용자 2026-10-18, T05) |
| 시크릿 | 원본은 Infisical(§7). 값은 새로 발급해 Infisical에 등록하고, 옛 SOPS 파일과 SealedSecrets의 값은 가져오지 않는다. 옛 자격은 T06에서 폐기한다(옛 Telegram 봇 토큰은 T22, 옛 healthchecks ping URL은 T08b까지 보류). Kubernetes 전달 계층은 ESO v2.13.x다 | Infisical 원본: 확정 (C-07). 새로 발급·옛 값 미사용: D-20 확정(사용자 2026-10-18, T05). ESO: 확정(사용자 2026-10-18, T05) |
| 첫 실제 앱 | 홈랩 Discord AI 봇. 봇 코드 저장소는 `ukyi-app/homelab-bot`(public)이고, 앱 이름도 `homelab-bot`이다. 봇 문서는 그 저장소의 `docs/ai-bot/prompts/`에 있는 `00-start.md`~`04-audit-handoff.md`(이 문서에서는 `00`~`04`)다. 2026-10-18에 봇 저장소 생성·하드닝 뒤 homelab `bot/`에서 PR로 옮겼다(T14). 봇 기능 설계는 범위 밖(§2) | 확정 (D-01). 봇 저장소 이름과 봇 문서 위치: D-13 확정(사용자 2026-10-18, T14) |

이 표 밖에서 "기본값"이나 "기본 후보"로 적은 것(CLI 언어, 갱신 방식, 인증 방식 등)은 그 자리에 확정 표시가 없으면 추천, 미정이다. 바꾸면 §10-A에 적고, 사용자 결정이 필요하면 §10-F에 올린다.

다른 확정 결정은 해당 절에 있다: C-04 공유기 DNS 유지(§4), C-05 Tailscale 전역 DNS 임시 폴백(§1 5항), C-06 옛 저장소 Actions 비활성화(§1 1항), C-07 플랫폼 원칙(§2 유지할 전제, §6 CNPG), C-08 봇 V1~V3 운영 읽기 전용(§2 봇을 위한 여지). 2026-10-18에 확정된 D-04~D-13, D-18, D-20~D-22, D-25~D-29와 2026-10-20에 확정된 D-30은 해당 절과 §10-F에 확정 값을 적었고, 세부는 설계 문서 F다. D-13은 §0 첫 실제 앱 줄, §3 조사 항목 9, §5, §10-F D-11·D-29 줄에 있다. T15에서 확정된 D-14~D-17·D-24는 §2 "봇을 위한 여지" 표, §5, §10-F에 있다.

---

## 1. 구축 전 정리 상태 확인

아래 정리는 사람이 수행한다. 너는 각 항목의 현재 상태를 읽기 전용으로 확인해 `완료 / 미완료 / 확인 불가`로 보고한다(design.md 0절). 확인은 이 절 끝의 "확인 경로" 안에서만 한다. 미완료 항목은 설계를 막지 않고, §10-E 구축 계획의 선행 조건이 된다.

항목 안의 상태 서술은 2026-10-17 기준이다. 같은 날 실측한 상태표는 spec §1에 있다. 보고에는 지금 직접 확인한 상태를 쓴다.

1. **옛 저장소 GitHub Actions 비활성화.** 옛 `tf-reconcile`·`iac`는 Cloudflare root를 무인 apply해서, 손으로 바꾼 Cloudflare 설정을 옛 코드대로 되돌렸다(일정은 30분마다, 실측은 몇 시간 간격). GitHub·Tailscale root는 plan만 돌려 드리프트를 Telegram으로 알렸다. 자동 병합과 Renovate(Actions 일정으로 도는 self-hosted 방식) 등 다른 옛 자동화도 Actions 위에서 돌았다. 2026-10-17에 저장소 Actions를 비활성화해 모두 멈췄다(C-06). 되살릴 때는 `enabled=true`, `allowed_actions=all`이다. main을 교체하기 전에 되살리면 옛 자동화가 다시 돈다.
2. **옛 코드를 `legacy` 태그로 보관.** 2026-10-17 기준 아직 만들지 않았다(T01). 완료 기준은 annotated `legacy` 태그가 가리키는 커밋(`legacy^{}`)이 동결 당시 main SHA(`2d2054a`)와 같은 것이다(spec AC-P1).
3. **옛 클러스터 정리.** 옛 Argo CD는 이 저장소 main을 `prune`·`selfHeal` 자동 동기화로 따라가므로, main을 교체하기 전에 멈춰야 한다. root 앱이 Application과 ApplicationSet을 selfHeal로 소유해서, Application 단위로 auto-sync를 끄면 되돌려진다. 정지는 컨트롤러 축소(`argocd-application-controller`와 `argocd-applicationset-controller`를 0으로) 또는 k3s 제거로 한다(T06, 사람 작업). 2026-10-17 기준 옛 클러스터는 가동 중이다(NUC `nuc-15-pro`에서 k3s active). 그래서 새 작업은 `rebuild` 브랜치에 두고, main은 철거 뒤에 바꾼다. 철거 시점은 T05 결정 뒤, 부트스트랩 직전이다(D-02, 확정). 철거 방식은 OS 유지 + k3s 제거 + 호스트 정리다(D-12 확정(사용자 2026-10-18, T05), 설계 문서 F D-12).
4. **브랜치 보호와 ruleset 정리.** 필수 검사 `gate`만이 아니라 main push 제한(writer App)과 writer 전용 ruleset 2개도 정리 대상이다. ruleset은 `bump-poll-writer-only`(`bump-poll/**`)와 `mutation-branches-writer-only`(`bump/**`·`create-app/**`·`create-database/**`·`create-cache/**`·`update-secrets/**`)다. main 교체 PR에서 `gate` 워크플로가 사라지면 그 검사는 끝없이 대기한다. 두 ruleset은 writer App만 우회할 수 있어서, writer App을 지우면 그 접두사 브랜치는 아무도 만들 수 없다. 새 CLI·CI가 옛 접두사를 다시 쓰면 push가 거부된다.
5. **Tailscale DNS 폴백.** tailnet 전역 nameserver가 NUC의 Tailscale IP(AdGuard)뿐이고 Override DNS servers가 켜져 있으면, AdGuard가 없는 동안 Tailscale을 켠 기기는 이름 해석이 끊긴다. 2026-10-17에 Cloudflare Public DNS를 전역 nameserver에 손으로 추가했다(C-05). 이 설정은 옛 `infra/tailscale` 코드와 다르므로, 옛 tailscale root를 apply하면 폴백이 사라진다. 지금은 병렬 질의(§4 DNS) 때문에 Tailscale 기기의 광고 차단과 `*.home.ukyi.app` 내부 이름이 불안정하다. 철거 기간에는 감수한다. D-08 확정(사용자 2026-10-18)으로 T08a에서 전역 nameserver를 NUC(AdGuard Home)와 AdGuard 공용 DNS 2개로 바꾸고 C-05의 Cloudflare 항목을 지운다(§4 DNS).
6. **옛 Terraform state 처리.** 옛 github root의 `github_repository.homelab`과 `github_repository.app_template`(`homelab-app-template`) 둘 다 삭제 방지가 없어서, 그 root를 destroy하면 두 저장소가 지워진다. 옛 state에는 평문 자격도 들어 있다. state는 destroy 대신 폐기하거나 새 코드로 import한다. 새 root는 옛 state 키(`<root>/prod/terraform.tfstate`)를 쓰지 않는다(새 키 접두는 `v2/`, D-11). 같은 키를 쓰면 옛 state를 물려받아 plan이 옛 자원 삭제를 제안한다. GitHub 잔여는 옛 코드가 아니라 `gh api` 실측 목록(App, environment, webhook, ruleset, GHCR)을 기준으로 한다. webhook처럼 옛 코드에 선언되지 않은 설정도 있다. Cloudflare에 남은 터널·DNS·WAF·캐시 규칙은 새 Terraform에서 import하거나 수동 삭제해야 이름·phase 충돌이 없다(D-11 확정(사용자 2026-10-18, T05): E1에서 삭제하고 E4a에서 새로 정의). `homelab-pg-backups-prod`와 `homelab-media-prod`는 `prevent_destroy`가 걸려 있어 수동으로 지운다. 정리 목록 초안은 `docs/plans/2026-10-17-homelab-rebuild/issues/T06-teardown.md`에 있다.

**확인 경로:** 이 머신에 있는 자격 안에서만 확인한다. 옛 클러스터는 설계 기간 내내 돌아야 하므로(D-02) 클러스터 자격을 쓰지 않는다.

- **허용:** `gh api` GET. `systemctl is-active`·`list-unit-files`·`cat`. `tailscale status`, `tailscale dns status`(sudo 없이 전역 resolver 목록을 보여 준다). `git -C ~/workspace/homelab show 2d2054a:<path>`.
- **금지:** `terraform init`·`plan`·`state pull`. 옛 작업 트리의 `.env.secrets`·`backend.hcl`·`terraform.tfvars` 읽기. `sops -d`와 age 키 사용. `sudo`. 옛 토큰으로 Cloudflare·R2·Tailscale API 호출. 옛 사본의 kubeconfig(옛 클러스터 관리자 자격) 사용.
- **그 밖:** 위 경로로 볼 수 없는 것은 "확인 불가(자격 없음)"로 둔다. 대신 2d2054a 코드의 선언 상태, spec §1의 2026-10-17 실측(옛 Argo CD Application 22개가 main을 따라감), T06 상태를 근거로 적는다.

**완료 기준:** 여섯 항목 모두 상태와 확인 근거(명령·API 응답·화면)가 있다. 근거는 공개 범위(머리말)를 지켜 적는다.

---

## 2. 목표와 원칙

### 유지할 전제

사용자가 쓴 원본 프롬프트(옛 홈랩 개선용)의 전제를 신규 구축에 맞게 옮겼다(spec C-07의 근거). 원본의 ApplicationSet·공유 Helm 차트 재사용 전제는 §3에서 다룬다.

- k3s + Argo CD GitOps.
- 앱 소스는 `ukyi-app/<app>` 형태의 작은 독립 저장소, 운영 설정은 `ukyi-app/homelab` 중심.
- GitHub Actions·GHCR·Git 기반 배포.
- CLI로 앱 등록·배포·상태 확인·DB 및 Valkey 연결.
- 일상 시크릿의 원본은 Infisical Cloud 한곳. Kubernetes 전달 계층은 External Secrets Operator(ESO)를 우선 검토한다(비교 방법은 §7).
- 단일 물리 서버다. 실제로 제공하지 못하는 고가용성은 설계 전제로 두지 않는다.

### 봇을 위한 여지

봇 기능은 만들지 않되, 나중에 붙일 자리는 지금 설계한다. 봇 V1~V3은 운영에 대해 읽기 전용이므로(C-08), 아래 자리도 그 경계 안에서 설계한다. 설계 문서에는 표의 모든 자리마다 위치, 권한 범위, 준비 확인 방법을 적는다(spec AC-P12. 자리별 AC는 표 아래).

| 자리 | 플랫폼이 제공할 것 | 봇 쪽 요구 |
|---|---|---|
| 리뷰 전용 GitHub App | 저장소별로 리뷰 전용 App을 추가 설치할 수 있다. 리뷰 방식은 D-16 확정(사용자 2026-10-18, T15): 전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버(`01` 기본안) | PR_REVIEW (`01`) |
| 읽기 전용 접근 | 관측 데이터(메트릭·로그·알림), 클러스터 상태, Argo CD 배포 상태(동기화·건강 상태, 배포된 revision과 이미지)를 서비스 계정·RBAC로 읽는다 | R04~R06, R15 (`01`) |
| 병합 조건 공개 | 사람 승인 없이 병합되는 PR의 조건이 문서에 명시돼 있다. 조건에는 내용뿐 아니라 작성 주체(배포 갱신 App)와 브랜치를 넣는다. 문서만이 아니라 실제 강제 장치(보호 규칙이나 병합 워크플로의 주체 검사)를 설계한다. 봇의 PR 리뷰는 참고용이라, 리뷰보다 먼저 병합되는 경로가 있으면 그 범위가 보여야 한다. 범위는 D-07 확정(사용자 2026-10-18, T05): 배포 App이 앱 기본 브랜치 빌드에서 만든, 한 앱 `image.yaml`의 digest·revision만 바뀐 PR만 자동 병합하고 서버에서 강제한다(§5, 설계 문서 C.4.7) | `00` §6, V2-10 |
| 봇 변경 PR 작성 자격 | 봇 CHANGE_PR이 `bot/` 브랜치를 push하고 PR을 만드는 신원의 자리. 신원은 D-24 확정(사용자 2026-10-18, T15): 봇 전용 쓰기 GitHub App(Contents write + Pull requests write + Metadata read, Workflows·Actions·Administration·Issues 없음, webhook 끔, 선택 저장소 설치, 작업마다 저장소 하나로 좁힌 1시간 토큰). 병합 API처럼 Contents write로 열리는 경로는 봇 게시 서버의 허용 목록이 막고, 봇은 `.github/workflows` 변경 PR을 만들지 않는다. 이 신원의 PR이 자동 병합되지 않게 하는 조건, main과 배포 브랜치 쓰기 차단, 저장소별 설치 구조를 제공한다 | CHANGE_PR (`01` §7), R13 (`01`) |
| 공개 HTTPS webhook 수신 경로 | GitHub webhook 같은 외부 이벤트를 받는 공개 경로. 공개 범위는 정한 경로로 한정하고, 출처 제한 방법을 정한다 | PR_REVIEW (`01`) |
| 경보 외부 수신자 | Alertmanager의 외부 webhook 수신자로 경보를 봇에 넘긴다. 관측 스택은 Alertmanager를 포함한 옛 계열 최소 구성이다(D-09 확정(사용자 2026-10-18, T05)) | R07 (`01`), V2-04 (`02`) |
| 격리 작업 실행 공간 | Codex 작업자가 운영·게시 자격(kubeconfig, GitHub 쓰기 키, Discord 토큰, SSH, 호스트 소켓)과 운영 네트워크(LAN, 클러스터 내부, Kubernetes API, tailnet, Infisical)에 닿지 못하는 실행 공간. 모델 자격만 작업 단위 별도 시크릿 범위로 받고, egress는 허용 목록(모델 API, 코드 저장소 읽기, 패키지 레지스트리)으로 제한한다. 같은 봇 앱 안에서도 게시 서버와 작업자의 시크릿 범위를 나눈다. worktree는 보안 샌드박스가 아니다(`00` §6). 기본 방식은 설계 문서 C.8 기본값으로 확정(사용자 2026-10-18, T05)이다. D-15 확정(사용자 2026-10-18, T15): 작업자는 ns `sandbox`의 상주 파드(동시성 1), 라벨 `homelab-bot`, 포트는 앱·작업자 8080과 경보 수신 8081. 코드 읽기는 `codeload.github.com` 압축본만이고, 작업자 egress에서 `github.com`·`api.github.com`·gist를 빼며 작업자에는 GitHub 자격이 없다. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft. 모델 자격은 D-14 확정(사용자 2026-10-18, T15): 봇 전용 ChatGPT 구독 계정의 작업자 전용 CODEX_HOME이고, 갱신된 인증 파일을 되쓰는 작업자 전용 영속 쓰기 공간을 둔다(설계 문서 C.8 변경, T08b·T16b) | F03, R10, R13 (`01`) |
| 비AI 알림 경로 | 봇과 독립된 알림 경로. 봇이 죽어도 경보가 사람에게 온다. 채널은 homelab 알림용 Telegram 새 봇이다(D-10 확정(사용자 2026-10-18, T05)). 옛 Telegram 봇·토큰은 `mac-uptime-guard`를 처리하는 T22까지 그대로 둔다 | F06 (`01`), OPS-02 (`04`) |
| 외부 생존 감시 | NUC 밖에서 홈랩 전체 중단을 감지하고, NUC를 거치지 않는 경로로 사람에게 알린다. healthchecks.io 데드맨 스위치(Alertmanager Watchdog → ping, 설계 문서 C.3.7)를 쓴다. 계정은 재사용하고 체크는 새로 만들며, 옛 `homelab-watchdog`는 새 체크가 초록이 된 뒤 지운다(D-10·D-11 확정(사용자 2026-10-18, T05)) | `04` §2 "운영 복구" |

자리별 AC는 spec §4.4를 따른다. 비AI 알림 경로와 외부 생존 감시는 AC-P11, 병합 조건 공개와 봇 변경 PR 작성 자격(자동 병합 차단)은 AC-P8, 나머지 다섯 자리는 AC-P12다.

시나리오 15·16·17(§9)이 일부 자리를 검증한다. 나머지는 설계 대조와 경로·계정의 존재 확인으로 본다. 실제 사용 검증은 봇을 구현할 때 한다.

### 범위 밖

- AI 봇·AIOps 기능 설계. 옛 AIOps에서 얻은 권한·격리 교훈은 §3에서 읽는다.
- Docker Compose·Dokploy·Coolify 등으로 배포 기반 교체.
- 자체 Kubernetes Operator, 신규 운영 API, 범용 플랫폼 프레임워크.

### 단순함은 파일 수보다 작업 경로로 판단한다

- 앱 하나를 등록할 때 사람이 수정하는 지점이 적은가?
- 같은 정보를 여러 곳에 입력하지 않아도 되는가?
- 최초 등록과 반복 배포의 차이가 명확한가?
- 재실행해도 기존 데이터와 자격증명이 유지되는가?
- 실패했을 때 원인과 다음 행동을 알 수 있는가?
- 앱을 삭제해도 데이터를 실수로 잃지 않는가?
- 특수한 내부 규칙을 기억하지 않아도 되는가?
- 빈 NUC에서 문서만 보고 다시 세울 수 있는가?

사람이 편집하는 원본과 자동 생성 결과물을 명확히 구분한다. CLI는 표준 리소스 생성과 기존 도구 호출을 잇는 얇은 계층으로 둔다. GitHub·Argo CD·CNPG·ESO가 이미 제공하는 기능은 그 기능을 쓴다. 안전 검증은 실제 사고를 막는 것만 두고, 검증 체계 자체를 유지하기 위한 추상화와 수동 원장(ledger)은 두지 않는다.

---

## 3. 옛 저장소에서 교훈 뽑기

옛 저장소는 참고 자료다. 2026-10-07 main 기준으로 워크플로 25개(디렉터리 파일 26개, README 포함), bats 시험 파일 313개, AIOps 관련 파일 58개가 있었다(spec §4.5). 핵심 질문은 두 가지다. 각 장치가 막으려던 **실제 사고**는 무엇이었나? 새 구조에서 같은 위험을 더 싸게 막을 수 있나?

**읽는 곳:** 로컬 사본 `~/workspace/homelab`에서 커밋 `2d2054a`(2026-10-07 fetch한 `origin/main`)를 고정해 읽는다(`git -C ~/workspace/homelab show 2d2054a:<path>`, `git ls-tree 2d2054a`). `legacy` 태그가 생기면 같은 커밋인지 확인한다. 로컬 사본의 작업 트리는 옛 작업 브랜치이고 커밋 안 된 변경이 남아 있으므로 읽지 않는다. git 밖 로컬 런북(`~/workspace/homelab/docs/runbooks/`, `~/workspace/homelab-infra/`)도 읽지 않는다(2026-06-11 사용자 결정으로 public 저장소 밖에 둔 자료. D-27 확정(사용자 2026-10-18, T05): T04는 읽지 않고, T06 목록 작성에만 읽기 전용으로 쓰며 값·절차 원문은 저장소 문서에 옮기지 않는다).

조사할 것:

1. 신규 앱 등록부터 첫 배포까지의 명령과 수동 편집.
2. 반복 배포에서 이미지가 선택되고 병합되는 과정, 자동 병합 경로.
3. 앱 저장소와 homelab에 중복 선언된 설정과 각 설정의 실제 소유자.
4. DB·계정·Valkey 생성과 앱 연결.
5. 시크릿의 생성·전달·변경·복구.
6. 앱 삭제가 DB·PVC·시크릿에 미치는 영향.
7. 전역 검사·드리프트 감지·수동 원장이 막으려던 사고.
8. 기반 구성(네트워크, AdGuard, Tailscale, Cloudflare 터널, 관측, 백업)의 운영 함정. 주석과 아래 "교훈 입력"에 실측으로 기록된 함정을 우선 수집한다.
9. 옛 공통 워크플로·차트·GitHub App에 기대는 org 안의 다른 저장소. 2026-10-17 실측 의존은 이렇다. `files`·`page`·`trip-mate-api`·`aiops-autodeploy-canary`는 `reusable-app-build.yaml@main`을 호출한다. `homelab-app-template`은 자기 CI가 매주 homelab main의 `tools/app-config-schema.json`을 받아 오고, scaffold가 새 앱에 reusable@main 호출을 심는다. 옛 AIOps 실행기 저장소 `ukyi-app/aiops`는 의존이 없다. org에는 `mac-uptime-guard`(private, homelab 의존 없음)도 있다. main을 교체하면 옛 공통 워크플로를 호출하거나 main의 파일을 받아 오는 빌드가 깨진다. 결과는 §10-E의 재연결 단계와, D-11이 아니라 D-13·D-29(aiops 두 저장소와 `ukyi-homelab-aiops` App), D-21(`homelab-app-template`), T22(앱 저장소)의 입력이 된다. 처리는 확정이다: `aiops` 저장소와 `ukyi-homelab-aiops` App, `mac-uptime-guard`는 제거하고, `aiops-autodeploy-canary`는 공개하지 않고 private으로 보관한다(D-13·D-29 확정(사용자 2026-10-18), 실행 T22. `mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤 지운다). `page`·`trip-mate-api`는 저장소와 GHCR 패키지를 삭제해(2026-10-18) 재연결 대상은 `files`다. `homelab-app-template`은 저장소·이름을 재사용하고 내용을 교체한다(D-21 확정(사용자 2026-10-18, T05)).

**교훈 입력:** 옛 저장소의 아래 기록을 함께 읽는다. 각 장치가 막으려던 사고의 근거로 쓴다.

- `docs/traps.md`, `docs/traps-detail.md`: 함정 기록.
- `docs/decisions/`, `docs/adr/`: 설계 결정과 그 이유.
- `docs/bespoke-component-checklist.md`: 실제 운영에서 확인된 함정에 대응하는 점검 목록.
- `docs/memory-ledger.md`: 메모리 한도 관련 기록.
- `docs/runbooks-public/`: 운영 절차.
- `CONTEXT.md`: 옛 도메인 용어집.
- 옛 AIOps 기록: `docs/aiops.md`, `docs/reviews/aiops-codex/`, AIOps 관련 ADR(`docs/decisions/0008~0010`. `docs/adr/`에는 0001~0007만 있다). AIOps 기능은 범위 밖이다. CI/CD·권한·격리 경계(Draft PR 경계 포함)와 호스트 잔여물에 영향을 주는 부분만 표에 넣는다. 그 교훈은 §2 "봇을 위한 여지"의 자리를 설계할 때(§10-C) 반영한다.

ADR과 주석은 설계 의도와 함정을 알려주는 근거로 쓰고, 새 설계를 묶는 규칙으로 쓰지 않는다. 옛 결정과 다르게 가면 바뀐 조건과 이유를 적는다. 원본 프롬프트는 옛 ApplicationSet과 공유 Helm 차트(`platform/charts/app`)의 재사용을 우선했다. 표에서 이 둘의 판정 이유를 분명히 적는다.

**완료 기준:** 옛 구성 요소마다 `가져옴 / 단순화해서 가져옴 / 버림` 중 하나와 근거 파일 경로, 판정 이유를 단 표.

**행 단위:** 아래 디렉터리의 1단계 항목(`git ls-tree 2d2054a <dir>/`)을 한 행으로 한다. 목적이 같은 항목은 묶음 행으로 써도 되고, 그때는 포함 경로 glob을 적는다. `tests/gates`(그 아래 1단계 127개)는 막으려던 사고별로 묶는다. 예상 규모는 약 200행이다.

표는 아래를 모두 덮는다.

- **디렉터리:** `infra/`, `platform/`, `apps/`, `tools/`, `ops/`, `policy/`, `scripts/`, `tests/`, `docs/`, 그리고 `.github/` 전체(`workflows/`, `actions/`, `actionlint.yaml` 포함). `tests/` 아래 전역 검사(`tests/gates`, `tests/posture`)는 조사 항목 7의 핵심 대상이다.
- **루트 파일:** 설정 파일만이 아니라 루트의 모든 파일 16개. `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `README.md`, `CONTEXT.md`, `package.json`, `bun.lock`, `bunfig.toml`, `tsconfig.json`, `.env.secrets.example`, `.gitignore`, `.sops.yaml`, `.pre-commit-config.yaml`, `.gitleaks.toml`, `renovate.json`, `justfile`.
- **`.claude/`(에이전트 훅·스킬):** 표에 넣을지 판단하고, 그 판단과 이유를 표에 적는다.
- **호스트 수준 구성:** 저장소 안의 `infra/k3s-bootstrap/`의 `host-config.sh`, `host-config/`, `motd/`와, 저장소 밖 NUC에 남은 옛 구성. 철거 방식은 OS 유지라서(D-12 확정(사용자 2026-10-18, T05)) 아래가 모두 남으므로, 각각 철거 범위에 넣을지 판정한다. 확정된 범위는 설계 문서 B.4의 H1·H2·H3·H7·H8·H9 철거다. H4·H5 drop-in은 남겨 E2가 덮어쓰고, `/mnt/bulk`는 비우고 fstab 항목을 지운다(설계 문서 F D-12).
  - `host-config.sh --apply`가 바꾼 것 전체(유닛, drop-in, `accept-dns`, `resolv.conf`, fstab)와 motd 유닛.
  - 옛 사본 경로(`~/workspace/homelab/scripts/`)를 실행하는 유닛: `files-data-backup`, `systemd-failed-sweep`, `unit-failure-notify@`. 옛 사본을 옮기거나 지우면 이 유닛이 실패한다.
  - 옛 AIOps 잔여물. 유닛 4종(`aiops-ingress.service`, `aiops-worker.service`·`.timer`, `homelab-aiops-nft.service`, `var-lib-homelab\x2daiops.mount`)과 nft 규칙, 그리고 유닛 밖의 `/opt/homelab-aiops`, `/etc/homelab-aiops`, 시스템 사용자 8개 등(전체 목록은 T06). mount 유닛 이름의 `\x2d`는 systemd 경로 이스케이프다. 셸에서는 작은따옴표로 감싸거나 `systemctl status /var/lib/homelab-aiops`처럼 경로로 지정한다. 이스케이프하지 않은 이름으로 조회하면 not-found가 나와 이미 없다고 오판한다. 이 mount는 2026-10-17에 active다.
  - 옛 데이터 경로: `/var/lib/rancher/k3s-storage`, `/mnt/bulk`, `/var/backups/files-data`.

---

## 4. 기반 플랫폼

CI/CD가 올라갈 바닥이다. 필요한 최소 구성만 고르고, 각 구성 요소에 선택·버전 고정 방식·부트스트랩 순서·준비 상태 확인 방법을 정한다.

- **호스트·k3s:** 빈 NUC에서 재현되는 부트스트랩 절차, k3s 버전 고정, 호스트 설정의 Git 관리. 하드웨어 사실: 디스크는 루트 LV 913G와 별도 1.8T `/mnt/bulk`(옛 files 데이터)이고, 네트워크는 무선 `wlo1`이다.
- **Argo CD:** 최초 설치와 이후 자기 관리(self-manage)의 경계. 공개 webhook은 두지 않고 60초 폴링으로 한다(`timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 0`. 확정(사용자 2026-10-18, T05), 설계 문서 A.4 3번).
- **외부 공개:** Cloudflare 터널과 인그레스. §2의 공개 HTTPS webhook 수신 경로를 포함한다. `ukyi.app` zone에 HSTS(includeSubDomains, 180일)가 걸려 있어서, 한 번 접속한 브라우저는 `*.home.ukyi.app` 내부 UI도 HTTPS로만 연다. 그래서 내부 UI도 처음부터 유효한 인증서의 HTTPS여야 한다. 부트스트랩 중 평문 HTTP나 자체 서명 인증서는 브라우저가 열어 주지 않는다. zone 설정 9개(HSTS 포함)는 새 Terraform으로 가져온다(D-11 확정(사용자 2026-10-18, T05)). 공개 DNS는 와일드카드 레코드 하나로 하고, 원격 관리 터널에서 안 되면 host별 Terraform 레코드로 한다(확정(사용자 2026-10-18, T05), 설계 문서 C.3.4).
- **내부 접근:** Tailscale. 새 ACL은 옛 ACL의 `autogroup:self`와 ssh 규칙을 유지한다. 빠지면 default-deny ACL이 운영자의 원격 Tailscale SSH 경로를 끊는다(옛 `infra/tailscale/acl.tf` 주석).
- **DNS(AdGuard):** 공유기는 주 DNS `192.168.117.15`(NUC), 보조 `1.1.1.1`로 설정돼 있고, 이 설정은 바꾸지 않는다(C-04). 새 AdGuard도 같은 LAN IP의 `:53`으로 서빙해 공유기 설정을 그대로 쓰는 것이 기본값이다. Tailscale은 모든 DNS를 대신 처리할 때 등록된 nameserver에 동시에 묻고 가장 빠른 답을 쓴다(Tailscale DNS 문서). 그래서 AdGuard와 공용 DNS를 함께 두면 Tailscale 기기의 광고 차단과 내부 이름 재작성이 안정적으로 동작하지 않는다. 폴백과 차단 중 무엇을 우선할지 정한다. D-08 확정(사용자 2026-10-18): Override local DNS를 켜고 전역 nameserver를 NUC Tailscale IP(AdGuard Home)와 AdGuard 공용 DNS 2개로 두는 (b′)다. 내부 UI는 `<서비스>.<tailnet>.ts.net`이라 내부 이름 재작성을 두지 않는다(spec §5.1, 설계 문서 F D-08). NUC를 Tailscale에 다시 등록하면 Tailscale IP가 바뀔 수 있으니 nameserver 설정과 함께 관리한다. 재등록하면 노드 키 만료가 기본값(켜짐)으로 돌아오므로 해제한다. NUC가 전역 nameserver 노드라서, 키가 만료되면 tailnet 전역 이름 해석이 멈춘다(옛 `infra/tailscale/acl.tf` 주석). 노드 자신의 DNS 함정은 두 갈래다. Tailscale 쪽: k3s 노드 자신은 tailnet 전역 nameserver를 받지 않게 한다(옛 `infra/tailscale/acl.tf` 주석에 기록된 실측 함정). LAN 쪽: 공유기 주 DNS가 노드 위 AdGuard라서, 노드가 DHCP DNS를 쓰면 노드 → 공유기 → AdGuard 순환이 생긴다. 콜드스타트 때 AdGuard가 아직 없으면 이름 해석이 막히고 이미지 pull까지 막힌다(옛 resolved drop-in 주석의 실측 함정). 옛 host-config는 resolved drop-in(공용 DNS 직접 사용)과 `tailscale set --accept-dns=false`로 둘 다 막았다.
- **관측:** 메트릭·로그·알림의 최소 구성. D-09 확정(사용자 2026-10-18, T05): VictoriaMetrics single, vmalert, Alertmanager, Grafana, VictoriaLogs single + vector, node-exporter, kube-state-metrics. vmagent와 보조 수집기 4개는 두지 않고, 핵심 룰 15개 안팎과 단위 시험을 둔다(설계 문서 F D-09). 나중에 봇이 읽을 대상이다. §2의 읽기 전용 접근, 경보 외부 수신자, 비AI 알림 경로(D-10 확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io 새 체크), 외부 생존 감시를 여기서 함께 설계한다.
- **백업:** PostgreSQL → R2. 버킷은 `homelab-backups` 하나, 보존은 PostgreSQL·Valkey 14일이다(확정(사용자 2026-10-18, T05), 설계 문서 C.3.8).

---

## 5. CI/CD

### 기본 흐름

앱 코드 반영
→ 테스트
→ 이미지 빌드·GHCR 게시
→ 해당 빌드의 이미지 digest로 homelab 배포 PR 생성
→ 검사·병합
→ Argo CD 배포
→ 의도한 revision과 이미지가 정상 실행되는지 확인

앱 저장소는 코드·Dockerfile·테스트·짧은 공통 워크플로 호출 중심으로 둔다.

### 반드시 다룰 것

- 앱마다 긴 CI 파일과 배포 스크립트를 복사하지 않는 방법.
- 빌드 결과와 배포 이미지의 연결. 태그 대신 정확한 이미지 digest를 쓴다.
- 늦게 끝난 과거 빌드가 최신 배포를 덮어쓰지 않는 방법.
- 앱별 이미지 변경의 단일 갱신 주체.
- 공통 차트·워크플로 변경의 영향 범위와 버전 관리.
- 앱 이미지 변경과 플랫폼 변경 각각에 맞는 검사 범위.
- 이미지 롤백과 DB 복원의 구분.
- **자동 병합 범위:** 사람 승인 없이 병합되는 PR의 조건을 명시한다(D-07 확정(사용자 2026-10-18, T05): 배포 App이 앱 기본 브랜치 빌드에서 만든, 한 앱 `image.yaml`의 digest·revision만 바뀐 PR만 자동 병합한다. 서버 강제는 설계 문서 C.4.7의 조건 9개, ruleset A~D, `app-main`, `workflow_run` 병합 워크플로, App 2개, 키별 Infisical 프로젝트다. GitHub auto-merge 허용은 끄고, 나머지는 사람 검토 후 병합한다). 조건은 작성 주체(배포 갱신 App), 브랜치, 내용(예: 한 앱의 이미지 digest만 바뀐 배포 PR)을 모두 포함하고, 문서뿐 아니라 서버 쪽 강제 장치(보호 규칙이나 병합 워크플로의 주체 검사)로 지킨다. 배포 PR은 앱 저장소 기본 브랜치의 빌드에서만 만들고, PR과 비기본 브랜치 CI에는 저장소 간 쓰기 키를 주지 않는다. 봇 변경 PR 신원(D-24 확정(사용자 2026-10-18, T15): 봇 전용 쓰기 GitHub App)의 PR은 내용이 digest만 바뀌어도 자동 병합되지 않는다(spec AC-P8).

### 갱신 방식과 인증

앱 CI에서 homelab에 PR을 만드는 방식과 Argo CD Image Updater의 PR 방식을 비교하고, 저장소 간 쓰기 자격과 유지보수 부담까지 고려해 하나를 고른다. 기본 후보는 "빌드 완료 후 PR 생성"이다. 설계는 이 방식을 골랐고(설계 문서 C.4.2), D-07 확정(사용자 2026-10-18, T05)이 이 흐름을 전제로 한다.

인증 격리는 확인으로 판단한다. 기본 `GITHUB_TOKEN`의 범위, 저장소 간 쓰기용 GitHub App의 권한과 설치 범위, 브랜치 보호, 허용 변경 경로를 확인한다. 옛 reader/writer GitHub App은 자동 병합 경로와 엮여 있었으므로, 최소 권한의 새 App을 기본값으로 둔다.

새 보호 구성(필수 검사, main push 제한, ruleset)은 새 App ID 기준으로 정의한다. 보호 설정은 Terraform root `infra/github`로 관리한다(D-28 확정(사용자 2026-10-18), 설계 문서 F D-28). 옛 구성은 옛 writer App만 main push와 특정 접두사 브랜치를 허용했다(§1 4항). org가 Free 플랜이라 브랜치 보호와 ruleset은 public 저장소에서만 동작한다. 그래서 서버 쪽 강제의 전제는 저장소 공개 범위(D-23)와 봇 저장소 가시성(D-13 확정(사용자 2026-10-18): `ukyi-app/homelab-bot`, public)이다. 앱 저장소는 public만 허용한다(D-29 확정(사용자 2026-10-18)). 공개 저장소의 Actions 위협(fork PR, `pull_request_target`, self-hosted runner, GHCR 패키지 공개 여부)을 점검한다. 이미 org 전체 저장소에 쓰기 권한(contents, workflows, pull_requests 등)으로 설치돼 PR을 열면 자동 리뷰를 다는 ChatGPT Codex Connector를 권한 경계 설계의 입력으로 둔다(D-26 확정(사용자 2026-10-18, T05): 유지하고 설계 문서 F D-26의 조건 넷을 건다. 설치 범위는 D-16 확정(사용자 2026-10-18, T15)으로 선택 저장소로 줄이고 private `homelab-bot-ops`는 빼며, 봇이 리뷰하는 저장소에서는 Codex 자동 리뷰를 끈다). main push 허용 목록에는 없지만 다른 브랜치와 워크플로에는 쓸 수 있다.

저장소 간 쓰기용 App 키의 원본은 Infisical이다(C-07, §7). 설계는 이 키를 GitHub Actions 실행에 전달하는 방식(예: Infisical의 GitHub 동기화, 실행 시 조회)을 고른다. GitHub Secrets를 원본으로 두는 안을 권한다면 C-07의 예외이므로 §10-F에 이유와 함께 올린다. 이 답은 spec §8.2의 미확정 간선 T09 → T10(시크릿 체계를 CI/CD보다 먼저 지을지)을 T05에서 확정하는 근거가 된다. 전달 방식은 D-04 확정(사용자 2026-10-18)이다: 배포 키는 Infisical OIDC Auth로 실행 때 조회하고, 병합 키는 Secret Sync로 homelab environment `automerge`에 사본 하나를 둔다(설계 문서 C.4.8, F D-04). 간선은 T05가 2026-10-18에 정했다: 착수 T07 → T10, 완료 T09 → T10, `infra/github` 첫 apply는 T08a 뒤(spec §8.2, 설계 문서 C.4.8).

일반 앱 빌드에는 운영 DB 비밀번호나 운영 API 키를 전달하지 않는 것이 기본값이다.

---

## 6. PostgreSQL·Valkey

사용자는 "이 앱에 DB가 필요하다" 또는 "이 앱에 캐시가 필요하다" 수준으로 요청하고, 생성 이후의 수동 Secret 연결은 최소화하고 싶다. 앱 배포와 데이터 리소스의 수명은 분리한다.

### PostgreSQL

CloudNativePG(CNPG)를 쓴다(C-07). 작은 앱은 공유 인스턴스 안에 앱 전용 DB·계정을 두는 것을 기본 후보로 하고, 중요한 데이터·독립 복원·버전/자원 격리가 필요한 앱은 전용 CNPG 인스턴스를 선택지로 둔다. 둘을 운영 편의성, 장애 범위, 특정 앱만 복원하는 절차로 비교한다(D-05 확정(사용자 2026-10-18, T05): 공유 인스턴스 + 앱별 DB·역할(봇 포함). 전용 Cluster는 설계 문서 C.5.2의 조건 넷 중 하나라도 걸릴 때만 둔다. Cluster `pg`는 자동 동기화로 두고, 빈 NUC 복구는 root apply 전 복구 PR → 복구 확인 → 정리 PR이다(설계 문서 C.6.4, F D-05)).

DB·계정은 CNPG의 선언형 기능으로 관리한다. 설치할 CNPG 버전을 정하고, DB·역할 선언 기능의 지원 여부를 그 버전의 공식 문서로 확인한다. 확인되지 않은 기능은 미검증으로 표시한다.

DB 추가에 포함될 것:

- DB와 필요한 계정.
- Infisical의 자격증명.
- CNPG가 사용할 Kubernetes Secret.
- 앱이 사용할 Secret과 연결 설정.
- 필요한 네트워크 접근.
- 백업·복원 대상 포함.

자격증명 원본은 하나로 두고, 사용 위치별 사본은 자동으로 전달한다.

DB·계정 생성과 앱의 테이블 마이그레이션을 구분한다. 앱 시작 시 self-migration과 migration Job을 비교하되, 재실행 안전성·동시 실행·이전 버전 호환성·PgBouncer 사용 여부를 고려한다. 결과는 D-22 확정(사용자 2026-10-18, T05)이다: Argo CD Sync 단계 hook Job(`BeforeHookCreation`, ExternalSecret 다음 wave) + `pg-rw` 직결, 앱은 시작 때 스키마 버전 확인만 한다. expand/contract는 필수이고, 이미 self-migration인 앱은 replicas 1에서 선택으로 허용한다(설계 문서 F D-22).

앱 삭제와 데이터 폐기는 별개다. 데이터 폐기는 명시적인 별도 작업으로만 일어난다.

### Valkey

세 가지 선택으로 시작한다: 없음 / 재생성 가능한 캐시 / 작업 큐 등 영속 상태.

캐시용과 영속용의 기본값을 구분한다.

- 메모리 제한과 eviction 정책.
- 인증과 접근 허용 범위.
- PVC·RDB·AOF 필요 여부.
- 외부 백업과 복원 절차.
- 데이터 유실 허용 범위(영속용은 D-06 확정(사용자 2026-10-18, T05): AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 재시작 손실 약 1초, 디스크 유실 최대 24시간).
- 앱 삭제 시 보존 정책.

필요한 앱에만 만들고, 단일 인스턴스로 시작한다. Sentinel·Cluster·별도 Operator는 실제 필요가 생긴 뒤의 선택지다. 공식 Valkey Helm 차트와 옛 구현을 비교해 유지보수가 적은 쪽을 고른다.

---

## 7. 시크릿 중앙 관리

핵심 요구: **"실제 시크릿 값을 등록·조회·수정하는 곳은 Infisical 한곳이고, 앱과 실행 환경에는 자동으로 전달된다."**

우선 검토할 구조:

Infisical Cloud → ESO → Kubernetes Secret → 앱·CNPG·Valkey

로컬 개발은 Infisical CLI로 개발용 값을 공급하는 방식을 검토한다.

### 원본과 사본

- 앱·DB·Valkey·외부 API 자격증명의 원본은 Infisical에 둔다.
- Git에는 Secret 참조·동기화 선언·비밀이 아닌 설정만 둔다.
- Kubernetes Secret은 실행용 사본이다. 사람은 원본만 편집한다.
- 하나의 Secret은 하나의 컨트롤러가 관리한다.
- 같은 값을 Infisical·GitHub Secrets·암호화 YAML에서 중복 관리하지 않는다.
- 시스템이 자동 발급·갱신하는 인증서와 토큰은 그 시스템에 둔다.

### 인증과 권한

- 플랫폼 시크릿과 앱 시크릿을 구분하고, 개발·운영 환경을 분리하고, 앱에는 자신의 시크릿만 전달한다.
- 프로젝트·폴더·머신 계정의 실제 권한 경계와 현재 요금제·머신 계정 제한·유료 기능을 공식 정보로 확인한다(D-04 확정(사용자 2026-10-18): Infisical Cloud Free, identity 4/5. ESO는 Universal Auth, 배포 키는 OIDC. 설계 문서 F D-04).
- 비용을 줄이기 위해 권한을 과도하게 공유하지 않는다. 비용과 권한 분리가 충돌하면 §10-F에 올린다.
- 집 안의 비공개 k3s를 전제로 인증 방식을 고른다. Kubernetes API를 인터넷에 공개하지 않는 방식이 기본값이다. Universal Auth를 우선 검토하고, 다른 방식이 더 적합하면 지원 조건과 운영 부담을 근거로 설명한다.

### 최초 연결과 재해 복구

ESO가 Infisical에 처음 접속하기 위한 자격증명과 필수 복구 자산만 별도 암호화 보관한다(SOPS+age 등에서 선택). 일반 앱 시크릿은 Infisical에만 둔다.

Infisical 장애·계정 잠김·클러스터 유실 상황에서 필요한 복구 자산과 순서를 명시한다. 이 목록은 빈 NUC 재구축(§9 시나리오 13)의 입력이다. 저장소가 public이면 복구 자산 목록은 저장소 밖에 두고(D-23), design.md에는 자산의 종류와 복구 순서만 쓴다.

이 머신에는 SOPS age 개인 키가 있다. 옛 공개 히스토리에는 SOPS 암호화 파일이 남아 있어서, 이 키가 그 recipient와 맞으면 옛 값을 풀 수 있다(일치 여부는 확인하지 않았다. 확인도 §1의 금지 경로다). 이 키는 새 구조에서 쓰지 않으므로 T06 자격 폐기 완료를 확인한 뒤 삭제한다(D-20 확정(사용자 2026-10-18, T05)).

### 값 변경과 비밀번호 회전

다음은 서로 다른 단계이고, 자동으로 원자적으로 처리되지 않는다.

1. Infisical 원본 변경.
2. Kubernetes Secret 갱신.
3. 실제 DB·Valkey 자격증명 적용.
4. 앱의 새 자격증명 사용.

규칙:

- 최초 생성은 한 번만 하고, 이후에는 기존 값을 재사용한다. 일반 재배포·재실행은 비밀번호를 바꾸지 않는다.
- 필수 키 누락이나 템플릿 오류는 명확한 실패로 끝난다.
- Secret이 갱신돼도 환경변수는 Pod 재시작 전까지 그대로다. 반영 순서를 설계한다.
- 일반 API 키 갱신과 DB·Valkey 비밀번호 회전의 절차를 구분한다.
- 무조건적인 자동 재시작보다 안전한 반영 순서를 우선한다.
- Infisical 연결이 실패하면 기존 유효 Secret이 유지되는 방식을 명시한다.

ESO와 Infisical 전용 Operator를 비교 검증하되 기본 후보는 ESO다. 비교 결과 전달 계층은 ESO v2.13.x로 확정(사용자 2026-10-18, T05)이다(설계 문서 C.6.1, F "Kubernetes 시크릿 전달 계층"). 원본 프롬프트가 가리키던 "이전 대화에서 언급된 버그·버전·제약"은 원문이 남아 있지 않으므로 전제로 두지 않는다. 두 도구의 알려진 버그·버전 제약·적용 조건은 공식 문서·릴리스 노트·공식 GitHub로 새로 확인한다.

---

## 8. CLI와 운영 경험

옛 Bun·TypeScript CLI(`tools/`)는 참고하고, 새 CLI는 얇게 다시 만든다. 언어는 Bun·TypeScript가 기본값이다.

원하는 사용자 경험:

- 앱 템플릿 생성과 최초 등록.
- 앱에 PostgreSQL 또는 Valkey 추가.
- 실행 전 변경 계획 확인.
- 변경 PR 생성과 승인 상태 안내.
- 빌드·배포·DB·시크릿 준비 상태 확인.
- 로그 조회.
- 이전 이미지로 돌아가는 변경 계획.
- 명시적인 비밀번호 회전.
- 앱 삭제와 데이터 폐기의 분리.

명령 이름을 제안하고, 아직 없는 명령은 목표 UX로 표시한다.

`plan`은 읽기 전용이다. 계획 확인 중에는 비밀번호 생성, Infisical 쓰기, DB 생성 같은 부수효과가 일어나지 않는다.

Git과 Infisical 등 여러 시스템의 변경은 하나의 원자적 트랜잭션이 아니다. 일부만 완료된 경우 재실행으로 안전하게 이어갈 수 있어야 한다.

결과는 사람이 읽기 쉬운 출력과 구조화된 JSON을 함께 지원한다. 비밀값 없이 진행 상태·실패 원인·다음 행동을 보여 준다.

배포 상태는 새 저장소를 만들지 않고 GitHub의 실행·PR 기록과 Argo CD 상태를 재사용한다.

---

## 9. 검증 기준

다음 시나리오의 기대 결과와 검증 방법을 설계한다.

1. DB 없는 작은 웹앱을 새 저장소에서 처음 배포한다.
2. 기존 앱에 PostgreSQL을 추가한다.
3. 기존 앱에 캐시용 Valkey를 추가한다.
4. 영속 작업용 Valkey의 백업과 복원을 확인한다.
5. 동일한 등록 명령을 재실행해도 데이터·비밀번호가 바뀌지 않는다.
6. 필수 시크릿이 없으면 잘못된 값 적용 없이 명확하게 실패한다.
7. Infisical 장애·인증 만료 중 기존 서비스와 신규 배포의 동작을 확인한다.
8. DB 비밀번호 변경 후 실제 앱 접속까지 확인한다.
9. 앱을 삭제해도 DB·영속 데이터는 보존된다.
10. 공유 PostgreSQL에서 특정 앱만 복원한다.
11. 빌드 완료 순서가 바뀌어도 과거 이미지로 배포되지 않는다.
12. NUC 재부팅 후 의존 서비스가 정상적으로 준비된다.
13. 빈 NUC에서 문서 절차만으로 플랫폼을 재구축하고 테스트 앱까지 배포된다.
14. AdGuard가 멈췄을 때 LAN 기기와 Tailscale 기기의 이름 해석이 설계대로 동작한다.
15. 자동 병합 조건 밖의 PR(예: 공통 차트 변경)은 사람 승인 후에만 병합된다.
16. 봇이 없거나 멈춘 상태에서도 테스트 경보가 비AI 알림 경로로 사람에게 도착한다.
17. NUC 전체가 멈추면(전원 또는 네트워크 차단) 외부 생존 감시가 이를 감지해 알린다.

서로 다른 Argo CD Application 사이의 의존 순서는 sync-wave만으로 보장되지 않는다. 실제 준비 상태와 접속 가능 여부를 완료 조건에 넣는다.

시험하지 않은 항목은 "설계상 기대"로, 실행한 항목은 "실제 검증 완료"로 구분한다.

---

## 10. 결과물

결과는 다음 순서로 작성한다.

### 0. 구축 전 정리 상태

§1 여섯 항목마다 상태(`완료 / 미완료 / 확인 불가`)와 근거를 적는다. 근거는 실행한 명령과 결과 요약이다. 확인 불가 항목은 대신 쓴 근거(2d2054a 코드의 선언 상태, T06 상태)를 적는다. 미완료 항목은 E의 선행 조건으로 옮긴다.

### A. 최종 추천

이 환경에 가장 적합한 구조와 선택 이유. §0의 확정 줄(C-xx와 확정 D-xx), 추천 줄(미정), 조사 후 조정한 권고를 구분한다.

### B. 옛 구성 교훈

§3 완료 기준의 표. 가져오는 장치마다 새 구조에서 맡는 자리를 적는다.

### C. 목표 구조

기반 플랫폼, 앱 코드부터 배포까지의 흐름, DB·Valkey 추가 흐름, 시크릿 전달 흐름을 각각 간단히 표현한다. 설정·데이터·자격증명의 소유자를 명확히 한다. §2 "봇을 위한 여지"의 자리마다 위치, 권한 범위, 준비 확인 방법을 표시한다. §4~§8의 상세 설계(구성 요소별 선택·버전 고정·부트스트랩 순서·준비 상태 확인, 비교 결과, CLI 명령)는 C의 하위 절로 쓴다.

### D. 대표 운영 시나리오

"새 앱에 PostgreSQL과 Valkey를 연결해 배포하기"를 사용자 관점에서 처음부터 끝까지 설명한다. 사용자의 행동과 자동 처리되는 작업을 구분하고, 실제 값 대신 가짜 값과 참조만 쓴다.

### E. 단계별 구축 계획

순서: §1 미완료 항목(옛 클러스터 철거 포함, 철거 시점은 D-02 확정: T05 뒤, 부트스트랩 직전) → 호스트·k3s 부트스트랩 → 기반 플랫폼 → 테스트 앱 → 첫 실제 앱(AI 봇, D-01 확정). main 교체는 옛 클러스터 철거 뒤에 한다(§1 3항). 기존 앱 저장소 재연결(대상은 사용자 선택)은 테스트 앱 검증 뒤 준비하고, 실제 배포는 봇의 첫 배포 뒤에 한다.

각 단계에 만들 것, 옛 저장소에서 가져올 것, 선행 조건, 완료 기준, 검증 방법, 되돌리는 방법을 넣는다. 단계마다 필요한 외부 계정·자격과 그것을 준비하는 사람 작업을 선행 조건으로 적는다. 이 계획은 구축 티켓(T06~T13)을 다시 나누는 기준이 된다.

### F. 결정이 필요한 사항

사용자 결정이 필요한 항목만, 각각 권장 기본값과 함께 정리한다. spec §5.3에 추천 기본값이 있으면 그것을 출발점으로 삼고, 조사 결과로 바꾸면 이유를 적는다. 최소한 다음을 다룬다. 아래 항목은 모두 확정됐다(2026-10-18: D-04·D-08·D-28·D-29는 대화, 마지막 봇 결정 줄은 T15, 나머지는 T05. 2026-10-20: D-30은 대화). 각 줄 끝의 확정 값이 기준이고, 세부는 설계 문서 F다.

- Infisical 요금제와 머신 계정 구성(D-04). 확정(사용자 2026-10-18): Free, identity 4/5. 병합 키는 Secret Sync → environment `automerge`이고, D-07이 자동 병합으로 정해져 병합 키와 Sync는 유지된다.
- 공유 PostgreSQL과 전용 인스턴스의 기준(D-05). 확정(사용자 2026-10-18, T05): 공유 인스턴스 + 앱별 DB·역할(봇 포함). 전용 Cluster는 설계 문서 C.5.2의 조건 넷 중 하나라도 걸릴 때만.
- 영속 Valkey의 데이터 유실 허용 범위(D-06). 확정(사용자 2026-10-18, T05): AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 재시작 손실 약 1초, 디스크 유실 최대 24시간.
- 자동 병합 범위(D-07). 확정(사용자 2026-10-18, T05): 배포 App이 앱 기본 브랜치 빌드에서 만든, 한 앱 `image.yaml`의 digest·revision만 바뀐 PR만 자동 병합하고 서버에서 강제한다. GitHub auto-merge 허용은 끄고, 나머지는 사람 검토 후 병합한다.
- AdGuard 재구축 방식과 Tailscale DNS 폴백(D-08). 확정(사용자 2026-10-18): 내부 UI는 `*.ts.net`, Tailscale DNS는 (b′).
- 관측 스택 구성(D-09). 확정(사용자 2026-10-18, T05): 옛 계열 최소 구성(vmagent와 보조 수집기 4개 없음, 핵심 룰 15개 안팎 + 단위 시험).
- 비AI 알림 채널과 외부 생존 감시(D-10). 옛 Telegram 봇과 healthchecks.io 데드맨 스위치의 재사용 여부를 포함한다. 확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io(계정 재사용, 체크 새로). 옛 봇·토큰은 T22까지 그대로 두고, 옛 토큰 재발급 대안은 고르지 않았다.
- 옛 외부 자원(Cloudflare, R2, Tailscale, GitHub 설정, healthchecks.io)의 import 또는 삭제(D-11). §1 6항의 자원과 Cloudflare zone 설정(HSTS 포함)을 포함한다. org 저장소 처리는 D-11이 아니라 D-13·D-21·T22가 맡는다(§3 조사 항목 9). 확정(사용자 2026-10-18, T05): 설계 문서 F D-11 표대로(zone·tailnet·R2 state 버킷만 이어 쓰고 나머지는 새로, state 키 접두 `v2/`, zone 설정 9개는 새 Terraform). Tailscale ACL은 (c)다: NUC는 `tag:nuc` 태그 기기이고, SSH·kubectl은 운영자(`autogroup:owner`·`autogroup:admin`)만, AdGuard DNS는 member에게 열며, NUC → 사람 기기 규칙은 두지 않는다. ssh는 accept(nonroot와 root)다. (이력: 2026-10-18~2026-10-20에는 (a)(태그 없는 사용자 기기, self 규칙)였고, 2026-10-20 E4a의 U28 결과로 사용자가 (c)로 바꿨다.)
- 철거 방식과 빈 NUC 검증 방식(D-12). 철거 범위에 §3의 호스트 수준 잔여 구성과 옛 데이터 경로를 넣을지, 시나리오 13을 어떤 환경에서 실행할지를 포함한다. 확정(사용자 2026-10-18, T05): OS 유지 + k3s 제거 + 호스트 정리(설계 문서 B.4의 H1·H2·H3·H7·H8·H9. H4·H5 drop-in은 남기고 E2가 덮어씀), `/mnt/bulk`는 비우고 fstab 항목 삭제. 빈 NUC 검증은 VM(E8 격리 조건 여섯, VM 호스트는 tailnet 밖).
- 시크릿 새로 발급·옛 값 미사용(D-20), `homelab-app-template` 재사용(D-21). §0의 시크릿·이어 쓰는 외부 자산 줄이다. 둘 다 확정(사용자 2026-10-18, T05): 모든 값을 새로 발급하고 옛 자격은 T06에서 폐기한다(옛 Telegram 봇 토큰은 T22, 옛 healthchecks ping URL은 T08b까지 보류). SOPS age 개인 키는 T06 자격 폐기 완료 확인 뒤 삭제한다. `homelab-app-template`은 저장소·이름을 재사용하고 내용을 교체한다(설계 문서 F D-21).
- 새 플랫폼의 의존성 업데이트 방식(D-18). 옛 저장소는 Renovate를 썼고, 봇 V1 필수 기능 7이 "Renovate 작성 PR"을 리뷰 범위에 넣는다(`00` §3). 확정(사용자 2026-10-18, T05): 호스팅형 Renovate App을 저장소별로 설치하고 자동 병합은 모두 끈다.
- 앱 DB 마이그레이션 방식(D-22). §6의 앱 시작 시 self-migration과 migration Job 비교 결과다. 확정(사용자 2026-10-18, T05): Argo CD Sync 단계 hook Job + `pg-rw` 직결, expand/contract 필수(§6).
- Kubernetes 시크릿 전달 계층. spec C-07은 "Infisical이 원본, 전달 계층은 ESO 우선 검토"다(§2, 사용자 원본 프롬프트와 같음). §7 비교에서 ESO가 아닌 쪽을 권하면 이 항목에 이유와 함께 올린다. 확정(사용자 2026-10-18, T05): ESO v2.13.x.
- rebuild → main 병합 방식(D-25). 저장소는 squash 병합만 허용하고 병합 뒤 브랜치를 자동 삭제한다(spec §1). 확정(사용자 2026-10-18, T05): squash 병합. 옛 main은 새 main의 조상으로 남아 히스토리가 유지되고, rebuild 중간 커밋은 PR 기록에 남는다(§0 저장소 줄의 D-03 문구도 맞췄다).
- ChatGPT Codex Connector App 처리(D-26). §5 인증 격리 점검 결과를 근거로 유지·설치 범위 축소·제거 중 하나를 권한다. 봇 PR 리뷰와의 관계는 D-16(T15)이다. 확정(사용자 2026-10-18, T05): 유지 + 설계 문서 F D-26의 조건 넷. 설치 범위는 D-16 확정(사용자 2026-10-18, T15): 선택 저장소로 줄이고 `homelab-bot-ops`는 빼며(2026-10-18 17:45 사람이 실행), 봇이 리뷰하는 저장소의 Codex 자동 리뷰는 저장소별 Codex 설정에서 끈다(수동 `@codex review`는 남김).
- NUC 로컬 전용 자료를 T06 입력으로 쓸지(D-27). T04는 이 자료를 읽지 않으므로, 교훈 표나 정리 목록에서 이 자료 없이는 판정할 수 없는 곳만 표시한다. 확정(사용자 2026-10-18, T05): T06 목록 작성에만 읽기 전용으로 쓰고, 값·절차 원문은 저장소 문서에 옮기지 않는다.
- GitHub 보호 설정 관리 방식(D-28). 2026-10-18에 새로 생긴 결정이다. 확정(사용자 2026-10-18): Terraform root `infra/github`(저장소·시크릿 리소스 없음, guard, owner 로컬 래퍼만, CI는 plan 없음). 세부는 설계 문서 F D-28.
- 저장소 공개 정책(D-29). 2026-10-18에 새로 생긴 결정이다. 확정(사용자 2026-10-18): 앱 저장소는 public만 허용하고, 앱이 아닌 저장소는 공개하지 않는다. 비앱 저장소는 `aiops`·`mac-uptime-guard` 제거, `aiops-autodeploy-canary` private 보관이다(실행 T22). 봇 코드 저장소 `ukyi-app/homelab-bot`은 public이고, 운영 산출물은 봇 저장소에 두지 않는다(개발 산출물은 private 저장소 `ukyi-app/homelab-bot-ops`, 봇이 실행 중 읽는 값은 Infisical `/apps/homelab-bot/`. D-13 확정(사용자 2026-10-18, T14)). `page`·`trip-mate-api`는 저장소와 GHCR 패키지를 삭제했다. 세부는 설계 문서 F D-29.
- 내부 UI 짧은 주소(D-30). 2026-10-20에 새로 생긴 결정이다. 확정(사용자 2026-10-20): D-08의 `*.ts.net`은 그대로 두고 tailnet 전용 리다이렉터 `go`(`go/<이름>` → `https://<이름>.<tailnet>.ts.net`, HTTP 80만, 인증서·DNS 쓰기 자격·공개 DNS 없음)를 둔다. `*.lab.ukyi.app` 등은 검토 후 제외. 세부는 설계 문서 F D-30, 실행은 T08c.
- 설계 기본값(설계 문서 F "추가 확인"). 확정(사용자 2026-10-18, T05): 공개 DNS는 와일드카드 레코드 하나(원격 관리 터널에서 안 되면 host별 Terraform 레코드), Argo CD 공개 webhook은 두지 않고 60초 폴링, 백업 보존은 PostgreSQL·Valkey 14일과 R2 버킷 `homelab-backups` 하나, 격리 작업 공간 기본 방식은 설계 문서 C.8 기본값(라벨·포트와 코드 읽기 호스트 좁히기는 D-15 확정(사용자 2026-10-18, T15): 라벨 `homelab-bot`, 앱·작업자 8080, 경보 수신 8081, 코드 읽기는 `codeload.github.com`만. 작업자 전용 영속 쓰기 공간은 D-14).
- 봇 결정(D-14~D-17, D-24). 플랫폼 설계 범위 밖이라 T04가 다루지 않았고 T15가 정했다. 확정(사용자 2026-10-18, T15): D-14 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME(개인 CODEX_HOME 사용·복사 금지, 한도·인증 만료 때 자동 전환 없이 대기, 작업 직렬 1개, 작업자 전용 영속 쓰기 공간). D-15 위 격리 작업 공간 값. D-16 기본안(전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버)과 Codex Connector 설치 범위 축소. D-17 봇 전용 개인 Discord 서버. D-24 봇 전용 쓰기 GitHub App. 세부는 spec §5.1이다.

사소한 선택은 합리적인 기본값과 가정을 명시하고 계속 진행한다.

### G. 검증 시나리오

§9 시나리오 1~17마다 기대 결과, 검증 방법, 담당 구축 단계(E의 단계), `실제 검증 완료 / 설계상 기대` 구분을 적는다.

---

## 11. 조사·작성 기준

- 기술적 기능·버전·인증·삭제 정책·요금제는 공식 문서와 공식 GitHub를 우선한다.
- 커뮤니티 사례는 운영 경험을 보완하는 근거로 쓴다.
- 결론은 둘 이상의 근거로 확정한다. 이전 답변이나 단일 GitHub 이슈는 확인할 단서로 쓴다.
- 확인된 사실, 설계 제안, 미검증 가정을 구분한다.
- 보안 기능과 백업은 단순화 대상이 아니다. 단순함은 절차와 중복을 줄여서 얻는다.
- 대안 나열보다 이 홈랩에 적용할 최종 권고를 분명히 한다.
- 코드나 설정 예시에는 바로 적용 가능한 예시인지, 추가 구현이 필요한 목표 예시인지 표시한다.

최종 성공 기준:

**"빈 NUC에서 문서만 보고 홈랩을 다시 세울 수 있고, 작은 앱을 추가하고 DB·Valkey·시크릿을 연결할 때 내부 예외를 기억할 필요가 없고, 재실행은 안전하며, 일상적인 시크릿 원본은 Infisical 한곳에서 관리하고, 앱을 삭제해도 데이터는 의도한 정책대로 보존되는가?"**
