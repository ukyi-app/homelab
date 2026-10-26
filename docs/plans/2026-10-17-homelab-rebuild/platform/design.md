# 홈랩 신규 구축 플랫폼 설계

| 항목 | 내용 |
|---|---|
| 작성일 | 2026-10-17 |
| 상태 | T04 산출물. T05 결정(사용자 2026-10-18)을 반영했다. F의 결정 게이트와 "추가 확인"은 모두 확정이다. T14 결정 D-13(봇 저장소 `homelab-bot`, 운영 산출물 위치, 사용자 2026-10-18)을 C.6·C.8·E9·F D-29에 반영했다. T15 결정 D-14~D-17·D-24(봇 모델 인증, 작업자 격리, PR 리뷰, Discord, 봇 쓰기 App. 확정(사용자 2026-10-18, T15))를 C.8·E.0·E4b·E9·F "봇 결정(T15)"에 반영했다. 결정이 바뀌면 해당 줄과 그 결정을 쓰는 절을 함께 고친다 |
| 기준 커밋 | 옛 저장소 `2d2054a`(`2d2054aa294b3862de1b1af6eada88fb15e656e6`). annotated `legacy` 태그가 가리키는 커밋과 같다(0절 2항) |
| 지시와 기준 | [design-prompt.md](design-prompt.md) 전체가 지시다. 상태·결정·순서의 기준은 [spec.md](../spec.md)다. 둘이 어긋나면 spec을 따른다 |
| 수행 범위 | 읽기 전용 조사(옛 저장소 `2d2054a`, design-prompt §1 확인 경로, 공식 문서)와 이 문서 작성. 저장소·외부 상태는 바꾸지 않았다 |
| 공개 범위 | 이 문서는 public 저장소에 들어간다(D-23). 시크릿 값, 복구 자산 목록, 토큰 목록, 로컬 런북 내용, tailnet 이름, Tailscale IP는 적지 않는다 |

**표기 규칙**

- **사실:** 근거를 단 확인 내용이다. 근거 형식은 셋이다. 옛 저장소는 `2d2054a:<경로>:<줄>`, 실측은 실행한 명령(다른 저장소 파일은 `<저장소>@<SHA>:<경로>:<줄>`과 확인 명령), 공식 문서는 `[Sxx]`(부록 출처 목록, 확인 날짜는 부록 2)다. 결론은 근거 둘 이상으로 세우고, 근거가 하나뿐이면 "단일 근거"라고 적는다.
- **제안:** 이 문서의 설계 권고다. F절의 결정 게이트와 "추가 확인"은 확정(사용자 2026-10-18, T05)이다.
- **미검증:** 확인하지 못한 가정이다. 확인할 구축 단계(E절)를 함께 적는다.
- **추측:** 사실에서 끌어낸 판단이다. 직접 확인하지 않았다.
- **검증 상태:** 시험을 실행한 항목은 "실제 검증 완료", 실행하지 않은 항목은 "설계상 기대"다. 이 문서 작성 시점에는 모든 시나리오가 "설계상 기대"다.
- **예시 표시:** 코드·설정 예시마다 "바로 적용 가능" 또는 "목표 예시(추가 구현 필요)"를 단다.
- 표의 열 이름이 사실 또는 제안을 가리키면 그 열 전체가 그 종류다. 열 안의 다른 종류는 `[제안]`, `[미검증]`, `[추측]`으로 따로 표시한다.

**문서 지도:** [0. 구축 전 정리 상태](#0-구축-전-정리-상태) · [A. 최종 추천](#a-최종-추천) · [B. 옛 구성 교훈](#b-옛-구성-교훈) · [C. 목표 구조](#c-목표-구조) · [D. 대표 운영 시나리오](#d-대표-운영-시나리오-새-앱에-postgresql과-valkey를-연결해-배포하기) · [E. 단계별 구축 계획](#e-단계별-구축-계획) · [F. 결정이 필요한 사항](#f-결정이-필요한-사항) · [G. 검증 시나리오](#g-검증-시나리오) · [부록](#부록)

---

## 0. 구축 전 정리 상태

2026-10-17 22시대(KST)에 design-prompt §1 확인 경로 안에서 직접 확인했다. 금지 경로(terraform, 자격 파일, sops, sudo, 옛 토큰 API, 옛 kubeconfig)는 쓰지 않았다. 볼 수 없는 것은 "확인 불가(자격 없음)"로 두고 대신 쓴 근거를 적었다.

| # | 항목 | 상태 | 근거 (명령 → 결과 요약) | E절로 넘기는 선행 조건 |
|---|---|---|---|---|
| 1 | 옛 저장소 GitHub Actions 비활성화 | **완료** | `gh api repos/ukyi-app/homelab/actions/permissions` → `enabled:false`. `gh api 'repos/ukyi-app/homelab/actions/runs?per_page=1'` → 마지막 실행은 `tf-reconcile` schedule 2026-10-17T08:54:14Z, 그 뒤 실행 없음 | 유지한다. Actions는 E2에서 main 교체 뒤에만 다시 켠다. main 교체 전에 켜면 옛 워크플로 25개가 그대로 다시 돈다(옛 `tf-reconcile`은 Cloudflare 무인 apply) |
| 2 | 옛 코드를 `legacy` 태그로 보관 | **완료** | `gh api repos/ukyi-app/homelab/git/ref/tags/legacy` → object type `tag`. 그 태그 객체 → `commit 2d2054aa294b…`, tagger 2026-10-17T12:47:30Z(annotated). `gh api .../git/ref/heads/main` → `2d2054aa294b…`. design-prompt §1의 "아직 만들지 않았다"는 T01(2026-10-17)로 해소됐다 | 없음 (AC-P1의 태그 조건 충족) |
| 3 | 옛 클러스터 정리 | **완료** (2026-10-19 T06 할 일 2: 2a로 Argo CD 컨트롤러 0, 2c로 k3s 제거, 2d로 옛 데이터 삭제. approvals 2026-10-19 11:43·13:20·13:21) | `systemctl is-active k3s` → `active`, `systemctl is-enabled k3s` → `enabled`. 저장소 webhook의 최근 전송 2건(태그 push 12:47:33Z, `rebuild` push 12:48:33Z)이 HTTP 200(`gh api repos/ukyi-app/homelab/hooks/<id>/deliveries`, 시각·상태 코드만 조회). 대신 쓴 근거: `2d2054a:platform/argocd/root/root-app.yaml:14`(`refs/heads/main`), `:22`(prune·selfHeal), `2d2054a:platform/argocd/argocd-app.yaml:21,28,29`(자기 관리도 같음), spec §1 실측(Application 22개가 main을 따라감). T06은 "대기" | **E1(T06):** 컨트롤러 2개를 0으로 줄인 뒤 D-12 방식으로 k3s 제거. 시점은 D-02(T05 뒤, E2 직전). main 교체는 그 뒤 |
| 4 | 브랜치 보호와 ruleset 정리 | **완료** (2026-10-19 T06 할 일 5: 옛 브랜치 보호·ruleset 2개·webhook 삭제, `main-interim` active, `allow_auto_merge=false`. approvals 2026-10-19 13:24~13:27) | `gh api repos/ukyi-app/homelab/branches/main/protection` → 필수 검사 `gate`(strict), 필요 승인 0, `enforce_admins=false`, push 허용 user 1명과 App `ukyi-homelab-writer`. `gh api repos/ukyi-app/homelab/rulesets` → `bump-poll-writer-only`, `mutation-branches-writer-only` 둘 다 `active`. 함께 확인: `gh api repos/ukyi-app/homelab` → `allow_auto_merge:true`(spec §1 표에 없는 줄) | **E1(T06 할 일 5):** `gate`와 push 제한 해제, ruleset 2개 삭제. writer App을 먼저 지우면 그 접두사 브랜치를 아무도 못 만든다. 보호를 푸는 같은 단계에 임시 ruleset을 먼저 걸고 `allow_auto_merge`도 끈다(E1 표). 정식 ruleset A~D는 E5에서 이 임시 설정을 바꿔 넣는다(C.4.7) |
| 5 | Tailscale DNS 폴백 | **완료** (임시 폴백 C-05 적용 상태) | `tailscale dns status` → 전역 resolver는 NUC의 Tailscale IP 1개와 Cloudflare 4개(`1.1.1.1`, `1.0.0.1`, IPv6 2개), MagicDNS 켜짐, split DNS는 `ts.net.`만. 이 노드는 "Tailscale DNS: disabled"(= `accept-dns=false`). Override 토글은 CLI 출력에 없어 확인 불가. 대신 쓴 근거: `2d2054a:infra/tailscale/acl.tf:79-82`(Override는 콘솔에서 켬), `:75-77`(nameserver 변수 하나) | **E4a(T08a):** D-08(확정(사용자 2026-10-18), (b′))대로 Cloudflare 4개를 지우고 AdGuard 공용 DNS 2개를 넣을 때까지 유지(C.3.6). 그 전까지 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다(apply하면 폴백이 사라짐) |
| 6 | 옛 Terraform state 처리 | **완료** (2026-10-19 T06 할 일 4: 세 state 보관(`~/t06-tfstate-archive`), github state에서 저장소 2개 `state rm`, R2 옛 키 3개 삭제. approvals 2026-10-19 14:07·14:08) | state 조회는 금지 경로다. 대신 쓴 근거: 백엔드 버킷 `homelab-tfstate`(`2d2054a:infra/cloudflare/backend.tf:13`), 키 `${ROOT}/prod/terraform.tfstate`(`2d2054a:.github/actions/tf-r2-init/action.yml:37`). `github_repository.homelab`과 `github_repository.app_template`에 `lifecycle` 블록이 없다(`2d2054a:infra/github/repo.tf:1`, `:28`). `prevent_destroy = true`는 `2d2054a:infra/cloudflare/r2.tf:12`(pg 백업), `:66`(media) 두 곳뿐 | **E1(T06 할 일 4):** github root destroy 금지, 두 저장소를 state에서 제거, 옛 state 객체를 비공개 위치로 옮긴 뒤 원래 키 삭제. 새 root는 옛 키를 쓰지 않는다(C.3.9) |
| 7 | `page`·`trip-mate-api` 삭제 | **완료** (2026-10-18 결정·실행, F D-29) | 두 앱은 쓰지 않으므로 저장소와 GHCR 패키지를 삭제했다. 자동 권한 검사가 에이전트 실행을 막아 사람이 실행했다. `page` 패키지는 다운로드 5000회를 넘은 버전이 있는 public 패키지라 API 삭제가 HTTP 400으로 거부돼 사람이 직접 지웠다 | **2026-10-18 실행, `gh api` GET으로 확인:** `gh api repos/ukyi-app/page`와 `gh api repos/ukyi-app/trip-mate-api` → 404, `gh api orgs/ukyi-app/packages/container/page`와 `gh api orgs/ukyi-app/packages/container/trip-mate-api` → 404. 두 앱의 옛 자격(trip-mate-api의 Google OAuth client, OXR app id, `BETTER_AUTH_SECRET`, page admin token)은 T06 자격 폐기 표에 넣어 E1에서 폐기한다. 남는 앱 저장소는 `files`와 `homelab-app-template`이다 |
| 8 | 앱 저장소 main 보호(지금 하드닝, 사용자 결정 5) | **완료** (2026-10-18 결정·실행, F D-29) | 실측(2026-10-18 `gh api` GET): public 앱 저장소의 main 보호·ruleset 0개, fork PR 승인 `first_time_contributors`(org·저장소), secret scanning·push protection은 `homelab`만 켜짐. Codex Connector는 org 전체에 contents·workflows write라 하드닝 전에는 이 저장소들의 main에 쓸 수 있었다. 자동 권한 검사가 에이전트 실행을 막아 사람이 스크립트로 실행했다 | **E1 전(사람 작업):** `files`와 `homelab-app-template`에 `.github/CODEOWNERS`(`* @<owner 계정>`)와 `app-main` ruleset(C.4.7과 같은 규칙, bypass는 저장소 관리자 역할 `pull_request` 모드), secret scanning·push protection, 저장소와 org의 fork PR 승인 `all_external_contributors`. E5보다 앞서 `app-main`을 거는 것이고 E5에서 Terraform이 import한다. **2026-10-18 실행, `gh api` GET으로 확인:** 위 설정이 두 저장소와 org에 모두 걸렸고 CODEOWNERS 오류 0. U08 셋째 조건의 첫 실측인 `current_user_can_bypass`는 두 저장소 모두 `pull_requests_only` |

**함께 확인한 설계 입력** (사실, 2026-10-17 21:50~22:05 KST 조사 세션의 `gh api` GET·`systemctl`·`tailscale` 실측)

- `homelab`의 열린 PR은 0개다. 다른 4개 저장소에 열린 renovate PR은 29개다(5 + 10 + 10 + 4). spec §4.5는 25개라고 적었고, 차이 4는 `aiops-autodeploy-canary`의 4개와 같다(추측: 그 저장소를 빼고 셌다). `page`·`trip-mate-api`를 지워(7항, 2026-10-18) 그 둘의 20개가 함께 사라졌고, `homelab-app-template` 5개와 `aiops-autodeploy-canary` 4개, 합계 9개가 남았다(2026-10-18 `gh pr list` 재조회). D-18 입력.
- ChatGPT Codex Connector는 org 전체 저장소에 actions write, contents write, issues write, pull_requests write, workflows write, checks·statuses read 권한과 이벤트 12종으로 설치돼 있다(`gh api orgs/ukyi-app/installations`). spec §4.5 서술보다 넓다(actions, issues). D-26 입력.
- Free 플랜 제약을 API가 직접 보여 준다. private 저장소의 보호·ruleset 조회는 403 "Upgrade to GitHub Pro or make this repository public", org ruleset 조회는 403 "Upgrade to GitHub Team"이다. 서버 쪽 강제는 public 저장소의 저장소 단위 보호·ruleset만 쓸 수 있다.
- org Actions: 기본 `GITHUB_TOKEN` 권한 read, 워크플로의 PR 승인 불가, fork PR 승인 정책 `first_time_contributors`, self-hosted runner 0개.
- `page`, `trip-mate-api`, `files`, `aiops-autodeploy-canary`는 `reusable-app-build.yaml@main`을 호출한다(`page`·`trip-mate-api`는 2026-10-18에 삭제했다, 7항). `homelab-app-template`은 매주 homelab main의 `tools/app-config-schema.json`을 받아 오고(`ukyi-app/homelab-app-template@f1b4256:.github/workflows/template-ci.yaml:19` 매주 월 schedule, `:264-267` 스키마 받기와 실패 시 `exit 1`), scaffold가 새 앱에 reusable@main 호출을 심는다. 앱 저장소 3개와 template에 옛 SealedSecrets 공개 인증서·봉인본 사본이 있다: 공개 인증서는 `ukyi-app/page@3fb7220`, `ukyi-app/trip-mate-api@a7165de`, `ukyi-app/aiops-autodeploy-canary@46c4f89`의 `tools/sealed-secrets-cert.pem`과 `ukyi-app/homelab-app-template@f1b4256:scaffold/common/tools/sealed-secrets-cert.pem`(넷이 같은 내용), 봉인본은 `ukyi-app/page@3fb7220:deploy/page-secrets.sealed.yaml`과 `ukyi-app/trip-mate-api@a7165de:deploy/trip-mate-api-secrets.sealed.yaml`이다. SHA는 각 저장소 기본 브랜치 `main`의 HEAD다. 확인 명령(2026-10-18, 경로 존재만 보고 내용은 읽지 않음): `gh api repos/ukyi-app/<저장소>/commits/main --jq .sha`, `gh api 'repos/ukyi-app/<저장소>/contents/<경로>?ref=<SHA>' --jq '.type, .sha'`. template-ci 줄 번호는 조사 세션에 읽은 사본과 그 SHA의 blob이 같아 그대로 쓴다. 철거로 봉인 키가 사라지면 쓸 수 없다(추측). `page`·`trip-mate-api`의 사본은 두 저장소 삭제와 함께 사라졌고(7항, 2026-10-18), 남는 사본은 private으로 보관할 `aiops-autodeploy-canary`(D-29)와 D-21 내용 교체 때 지울 template의 것이다.
- NUC에는 옛 host-config drop-in(resolved, networkd `wlo1`, sshd, journald, tmpfiles)이 남아 있고, `files-data-backup.timer`, `systemd-failed-sweep.timer`, `motd-refresh.timer`가 active, AIOps의 nft 서비스와 `'var-lib-homelab\x2daiops.mount'`가 active다. `aiops-ingress.service`와 `aiops-worker.timer`는 이미 disabled다.

미완료·확인 불가 항목(3, 4, 6)은 E1의 선행 조건과 완료 조건으로 옮겼다(E.2 표). 1·2·5는 E2와 E4가 지킬 제약으로 옮겼다. 실행 대기였던 7·8항은 2026-10-18에 실행했고, E1 선행 조건에서 확인 명령으로 다시 본다.

---

## A. 최종 추천

### A.1 한 문장과 전체 그림

**같은 NUC에 k3s와 Argo CD를 고정 버전으로 세우고, 시크릿은 Infisical → ESO, 데이터는 CNPG 공유 클러스터와 공식 Valkey 차트, 앱 배포는 "앱 기본 브랜치 빌드 → digest PR → main 코드의 병합 워크플로가 검사 후 병합 → Argo CD" 한 경로로 만든다. 외부 공개는 Cloudflare 터널 하나, 내부 UI는 Tailscale operator가 발급하는 `*.ts.net` HTTPS 이름으로 옮겨 AdGuard rewrite·Cloudflare DNS 토큰·내부 인증서 의존을 끊는다.** [제안]

```text
앱 저장소 ukyi-app/<app> ── push(main) ──▶ app-build.yaml@<태그> (homelab 공통 워크플로)
                                              ├─ 테스트 → 이미지 빌드 → GHCR push (digest)
                                              └─ Infisical(OIDC)에서 deploy App 키 → homelab에 PR
                                                 브랜치 deploy/<app>, 파일 apps/<app>/image.yaml
homelab ── ci(유일한 필수 검사) ──▶ deploy-merge(workflow_run, main의 코드)가 작성자·브랜치·내용·출처·순서 검사
        ──▶ merge App이 검사한 head SHA로 squash 병합 (그 밖의 PR은 사람만 병합)
            병합 키는 environment automerge의 secret(Infisical Secret Sync 사본, D-04)
NUC k3s ── Argo CD(main 60초 폴링)
          ├─ app-<app> 네임스페이스: Deployment·Service·Ingress·NetworkPolicy·ExternalSecret
          ├─ data: CNPG 클러스터 pg(Database·DatabaseRole) ── Barman Cloud Plugin ──▶ R2
          ├─ ESO ◀── Infisical Cloud (Universal Auth)
          ├─ 공개: Cloudflare(*.ukyi.app) ──▶ cloudflared ──▶ Traefik(Ingress)
          ├─ 내부: Tailscale operator Ingress ──▶ <서비스>.<tailnet>.ts.net (Argo CD·Grafana·AdGuard UI)
          ├─ AdGuard: LAN 192.168.117.15:53(공유기 주 DNS), tailnet 전역 nameserver(AdGuard 공용 DNS와 병렬, D-08)
          └─ 관측: VictoriaMetrics·VictoriaLogs·vmalert·Alertmanager·Grafana ──▶ Telegram, healthchecks.io
```

### A.2 고정값으로 쓴 확정 결정

| ID | 결정 (spec §5.1) | 이 설계에서 쓰는 곳 |
|---|---|---|
| C-01 | 저장소 `ukyi-app/homelab` 재사용, 내용 교체 | C.1 저장소 배치, E2 main 교체 |
| C-02, C-03 | DB·캐시 백업, media 버킷, files 데이터 폐기 | 옛 R2 버킷 삭제(D-11), 새 백업 버킷(C.3.8), `/mnt/bulk` 비움(D-12) |
| C-04 | 공유기 DNS 유지(주 `.15`, 보조 `1.1.1.1`) | AdGuard를 같은 LAN IP `:53`으로 서빙(C.3.6) |
| C-05 | Tailscale 전역 DNS에 Cloudflare 임시 추가 | E4a까지 유지, D-08 (b′)로 대체(Cloudflare 4개를 지우고 AdGuard 공용 DNS 2개를 넣음, C.3.6) |
| C-06 | 옛 저장소 Actions 비활성화 | E2의 main 교체 뒤 재활성 |
| C-07 | k3s + Argo CD, 앱 저장소 분리, Infisical Cloud 원본(전달 계층 ESO 우선 검토), CNPG, 단일 서버 | 전체 구조. 고가용성 장치는 두지 않는다 |
| C-08 | 봇 V1 7기능 필수, V1~V3 운영 읽기 전용 | C.8 봇 자리의 권한 범위 |
| D-01 | 플랫폼 먼저, 봇이 첫 실제 앱 | E절 순서(테스트 앱 → 봇 → 기존 앱) |
| D-02 | 철거는 T05 뒤, 부트스트랩 직전 | E1 시점 |
| D-03 | 히스토리 유지(`legacy` 태그 + 교체 커밋. rebuild → main은 squash, D-25) | E2 main 교체 PR |
| D-23 | `homelab` public 유지, 운영 민감 문서는 저장소 밖 | 서버 쪽 강제의 전제(C.4.7), 복구 자산 목록 위치(C.6.4) |

### A.3 결정 게이트에 대한 이 문서의 권장과 확정

자세한 선택지와 이유는 F절이다. "관계" 열은 처음에 spec §5.3 추천과 비교한 것이었고, 지금은 확정 상태를 적는다. D-04, D-08과 새 결정 D-28·D-29는 사용자가 2026-10-18에 따로 확정했다. 새 결정 D-30은 2026-10-20에 따로 확정했다. 나머지 결정과 시크릿 전달 계층은 같은 날 사용자가 T05 질문에 답해 이 문서의 권장대로 확정했다(확정(사용자 2026-10-18, T05)). spec 추천과의 관계(일치·구체화·제안·조정)는 F절 각 결정의 "spec 대비"에 남겼다. F절에 결정·이유·대가·검토 후 제외한 안이 있다.

| ID | spec §5.3 추천 | 이 문서의 권장 기본값 (요지) | 관계 |
|---|---|---|---|
| D-04 | 조사 결과로 정함, 개발·운영 분리 유지 | Infisical Cloud Free. identity 4/5(사람, 운영 ESO `eso-homelab`, VM 검증 ESO `eso-homelab-dev`, 배포 키 OIDC `gha-homelab-deploy`). 병합 App 키는 identity를 쓰지 않는다: 원본 프로젝트 `homelab-ci-merge`에서 Infisical Secret Sync로 homelab environment `automerge`에 사본 하나(sync 1/10, 연결은 homelab 하나로 좁힌 fine-grained PAT). 프로젝트 5개(`homelab` prod, `homelab-dev` dev, 사람 전용 `homelab-admin`, `homelab-ci-deploy`, `homelab-ci-merge`). Free에는 경로 RBAC가 없어 읽는 주체가 다른 값마다 프로젝트를 나눈다. 값 덮어쓰기 복구 수단이 없으므로 CLI는 기존 값을 덮어쓰지 않는다. D-07이 자동 병합을 두기로 확정돼 병합 키와 sync는 유지된다 | **확정(사용자 2026-10-18)** |
| D-05 | 공유 인스턴스 + 앱별 DB (봇 포함) | 같음. 앱 하나 복원은 임시 클러스터 PITR + 논리 덤프(C.5.7). 전용 클러스터 기준 4개. 빈 NUC 복구는 root apply 전 복구 PR → 복구 확인 → 정리 PR(C.6.4) | **확정(사용자 2026-10-18, T05)** |
| D-06 | P1 제안을 따름 | AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 프로세스·노드 재시작 손실 약 1초, 디스크 유실 손실 최대 24시간 | **확정(사용자 2026-10-18, T05)** |
| D-07 | 배포 App이 기본 브랜치 빌드에서 만든 한 앱 digest PR만 자동 병합, 서버 강제 | 같음. 강제는 ruleset A~D(D는 배포 키 identity가 묶이는 `app-build-v*` 등 버전 태그를 지키는 둘: 갱신·삭제 금지 D1, 생성 제한 D2) + main 코드의 `workflow_run` 병합 워크플로 + App 2개(갱신·병합)와 키마다 나눈 Infisical 프로젝트(배포 키는 OIDC identity, 병합 키는 environment `automerge` sync 사본, D-04) + 앱 저장소·템플릿 저장소 main ruleset + 이미지 출처 확인(build provenance attestation). 앱 저장소는 public만 허용하고(D-29) 자동 병합은 `app-main`이 active인 앱만(조건 9, fail-safe). GitHub auto-merge 허용은 끈다 | **확정(사용자 2026-10-18, T05)** |
| D-08 | (a)(b)(c) 비교 | 내부 UI는 Tailscale operator Ingress의 `*.ts.net`(UI마다 단독 프록시. `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01 Cloudflare 토큰, traefik-ts 없음). Tailscale DNS는 (b′): Override 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS), C-05의 Cloudflare 4개 삭제, MagicDNS·HTTPS 켬. Tailscale을 켠 기기는 집 안팎에서 차단되고 NUC 장애 때도 공용 서버가 차단하며 답한다. 대가(AdGuard Home 전용 규칙은 일부 질의에만, 공용 경로 평문 UDP, 조용한 이탈 감시 필요, 로컬 전용 이름 안 풀림, 같은 도메인 광고는 못 막음)는 F D-08. 설정은 Terraform `tailscale_dns_configuration` | **확정(사용자 2026-10-18)** |
| D-09 | 옛 VictoriaMetrics·VictoriaLogs·Alertmanager·Grafana 최소 구성 | 같은 계열. vmagent와 보조 수집기 4개를 빼고, 룰은 핵심 15개 안팎을 단위 시험과 함께 | **확정(사용자 2026-10-18, T05)** |
| D-10 | 봇과 독립 채널, 옛 Telegram 봇·healthchecks.io 재사용 가능 | homelab 알림용 Telegram 봇을 새로 만든다. 옛 봇과 토큰은 그것을 쓰는 `mac-uptime-guard`를 T22에서 처리할 때까지 그대로 둔다(재발급하면 그 알림이 조용히 끊긴다). healthchecks.io 계정은 재사용하고 체크는 새로 만든다. Watchdog → healthchecks를 relay 없이 직접 연결 시도(미검증) | **확정(사용자 2026-10-18, T05)** |
| D-11 | zone·tailnet·state 버킷만 이어 쓰고 나머지 새로 정의 | 같음. 터널 새로 만듦, DNS는 와일드카드 + apex, zone 설정 9개는 새 코드로 가져옴, state 키 접두 `v2/`. Tailscale ACL은 (c)(2026-10-20 U28 결과로 (a)에서 바꿈): NUC를 `tag:nuc`로 태그하고 사람 기기 → NUC는 포트별, NUC → 사람 기기는 없음. ssh는 `accept`(nonroot + root) 그대로, `check`로 좁히는 (b)는 고르지 않았다 | **확정(사용자 2026-10-18, T05). ACL은 2026-10-20 (c)로 변경(사용자)** |
| D-12 | k3s 제거 + 호스트 정리, OS 유지, 옛 데이터 경로 삭제, 빈 NUC 검증은 VM | 같음. B.4의 H1·H2·H3·H7·H8·H9를 철거한다. 노드 DNS drop-in(H5)과 sshd·journald·tmpfiles drop-in(H4)은 남기고 E2가 같은 이름으로 덮어쓴다. `/mnt/bulk`는 비우고 fstab 항목을 지운다. 검증 VM은 클러스터별 값 파일(호스트 `host/clusters/vm.env`, 클러스터 `values-vm.yaml`)로 운영과 다른 노드 값·Infisical 프로젝트·R2 버킷·serverName·Tailscale 이름 접두·터널·체크를 쓰고, 운영 공개 URL과 운영 Tailscale 기기는 건드리지 않는다. VM 호스트는 tailnet에 넣지 않는다(E8) | **확정(사용자 2026-10-18, T05)** |
| D-18 | 설계 결과를 따름 | 호스팅형 Renovate App(저장소별 설치, 자동 병합 금지). homelab Actions와 분리 | **확정(사용자 2026-10-18, T05)** |
| D-20 | 재사용 안 함, 새로 발급 | 같음. SOPS age 개인 키는 T06 자격 폐기 완료 확인 뒤 지운다(새 구조는 SOPS를 쓰지 않음) | **확정(사용자 2026-10-18, T05)** |
| D-21 | 저장소 재사용, 내용 교체 | 같음. 템플릿은 SealedSecrets 사본과 main 의존을 모두 빼고 공통 워크플로를 태그로 호출 | **확정(사용자 2026-10-18, T05)** |
| D-22 | 비교 결과를 따름 | Argo CD Sync 단계 hook Job(`BeforeHookCreation`) + `pg-rw` 직결. 앱은 시작 때 스키마 버전 확인만 | **확정(사용자 2026-10-18, T05)** |
| D-25 | squash 병합 | 같음 | **확정(사용자 2026-10-18, T05)** |
| D-26 | 유지, 설치 범위는 D-16과 함께 | 유지. 조건 다섯: homelab·앱 저장소의 어떤 bypass 목록에도 넣지 않음, 시크릿을 쓰는 `workflow_dispatch` 워크플로를 두지 않고 environment secret을 쓰는 워크플로는 트리거를 `workflow_run`만 둠(D-04로 넓힘), 배포 키는 앱 main push의 태그 고정 `app-build` OIDC claim으로만 꺼내고 병합 키는 environment `automerge`(배포 브랜치 main) secret을 `deploy-merge`의 merge job만 씀(ci의 workflow-guard가 확인), 앱 저장소(public만, D-29)와 템플릿 main에 `app-main`을 걸고 자동 배포는 그 ruleset이 active일 때만, homelab·앱 저장소에 Codex 클라우드 작업 환경을 두지 않음(2026-10-22 더함, U37). Codex PR은 owner 계정으로 찍혀 승인 관문이 없어 owner 검토가 유일한 관문(C.4.7) | **확정(사용자 2026-10-18, T05)** |
| D-27 | T06 목록 작성에 읽기 전용으로 쓰고 값은 옮기지 않음, T04는 읽지 않음 | 같음. 로컬 자료 없이 판정 못 한 곳은 B.9 | **확정(사용자 2026-10-18, T05)** |
| D-28 | 없음(2026-10-18 새 결정) | GitHub 보호 설정을 Terraform root `infra/github`로 관리(T1). 리소스는 ruleset, environment(+ 배포 정책), Actions 권한 둘만이고 저장소·시크릿 리소스는 없다. 저장소 설정과 fork PR 승인 정책은 `gh api`로 맞추고 guard(`github_rest_api` 데이터 소스 postcondition)가 확인한다. 실행은 owner 로컬 래퍼만(fetch한 `origin/main`의 임시 worktree에서만, 토큰 종류별 확인, apply 실패 뒤 재import), CI는 plan 없이 fmt·validate·mock test. state는 R2 `v2/github/terraform.tfstate` + `use_lockfile` | **확정(사용자 2026-10-18)** |
| D-29 | 없음(2026-10-18 새 결정) | 앱 저장소는 public만 허용한다. private 앱 경로(`app new --private`, attest 건너뛰기, 사람 병합 분기, GHCR pull 자격)를 두지 않고 조건 9는 fail-safe로 남긴다. public 앱 저장소 기본 설정(fork PR 승인 `all_external_contributors`, secret scanning·push protection, private vulnerability reporting, U38 대책의 PR 생성 `collaborators_only`(2026-10-22))을 켜고 guard가 확인한다. 봇 코드 저장소 `ukyi-app/homelab-bot`도 public(운영 산출물은 봇 저장소에 두지 않음, D-13). `aiops`·`mac-uptime-guard`는 삭제(`mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤), `aiops-autodeploy-canary`는 private 보관(T22). `page`·`trip-mate-api`는 저장소·패키지 삭제(2026-10-18 실행). `files`·`homelab-app-template` 하드닝을 E5보다 먼저 한다(결정 5, 2026-10-18 실행) | **확정(사용자 2026-10-18)** |
| D-30 | 없음(2026-10-20 새 결정) | 내부 UI 짧은 주소는 tailnet 전용 리다이렉터 `go`(`go/<이름>` → `https://<이름>.<tailnet>.ts.net`, HTTP 80만, 인증서·DNS 쓰기 자격·공개 DNS 없음). D-08의 `*.ts.net`은 그대로. `*.lab.ukyi.app` 등은 검토 후 제외 | **확정(사용자 2026-10-20)** |
| 전달 계층 | ESO 우선 검토(C-07) | ESO v2.13.x 유지. Infisical Operator는 문서상 Kubernetes 1.33까지라 맞지 않음(단일 근거). ESO 선택은 소스로 확인한 기존 Secret 유지 동작으로도 선다 | **확정(사용자 2026-10-18, T05)** |

### A.4 조사 후 조정한 권고

spec·design-prompt가 깔고 있던 전제와 다르게 가는 것이다. 각 항목의 근거는 C절 해당 위치에 있다.

| # | 조정 | 이유 | 대가와 위험 | 위치 |
|---|---|---|---|---|
| 1 | 내부 UI 이름을 `*.home.ukyi.app`에서 Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`으로 바꾼다 (D-08, 확정(사용자 2026-10-18)) | operator Ingress는 MagicDNS 이름과 유효 TLS 인증서를 자동으로 붙인다[S114][S115]. 그래서 내부 와일드카드 인증서(`ukyi.app` 아래 이름은 `.app` 최상위 도메인의 브라우저 HSTS preload로 늘 HTTPS 전용이라 내부 UI에도 유효 인증서가 필요했다[S210]), cert-manager DNS-01과 그 Cloudflare 토큰, AdGuard rewrite, rewrite 리컨실러(`2d2054a:platform/adguard/` 리컨실러 CronJob), traefik-ts L4 프록시가 함께 빠진다. 인증서가 깨질 원인 사슬이 짧아지고, 내부 이름이 AdGuard·Tailscale 전역 DNS 설정과 무관해진다 | HTTPS 인증서를 켜면 기기 이름과 tailnet DNS 이름이 공개 CT 로그에 실린다[S120]. 그래서 공개해도 되는 기기 이름만 쓴다. tailnet에 없는 LAN 기기는 내부 UI에 못 닿는다(옛 구성도 rewrite 대상이 tailnet IP라 같았다, `2d2054a:tests/posture/test_networking-e2e.bats:82`). 인증서를 받지 못하면 막히는 것은 옛 구성과 같다: ts.net 프록시는 TLS 핸드셰이크를 실패시켜 넘어갈 수 없다[S211]. 두 방식 모두 수명의 2/3에서 갱신을 시작해 실패가 이어져도 약 30일 여유가 있고[S211][S212], 비상 경로는 `kubectl port-forward`다 | C.3.5 |
| 2 | Tailscale DNS를 Override 켬 + 전역 nameserver [NUC의 AdGuard Home, AdGuard 공용 DNS `94.140.14.14`·`94.140.15.15`]로 한다 (D-08 (b′), 확정(사용자 2026-10-18)) | Tailscale은 전역 nameserver에 동시에 묻고 처음 온 정상 응답을 쓴다[S110][S186]. 그래서 차단하지 않는 서버(C-05의 Cloudflare)를 섞으면 그 서버가 먼저 답한 질의는 차단이 빠진다. AdGuard 공용 DNS는 AdGuard Home 기본값과 같은 AdGuard DNS filter로 차단하므로[S189][S190] Tailscale을 켠 기기는 집 안팎 어디서든 차단되고, NUC·AdGuard가 멈춰도 공용 서버가 차단하며 답한다. 옛 구성의 "NUC 하나가 tailnet 전체 DNS를 죽임"이 사라진다. 내부 UI는 1번으로 MagicDNS라 nameserver와 무관하다 | AdGuard Home의 사용자 규칙·허용 목록·추가 목록은 AdGuard Home이 먼저 답한 질의에만 적용된다. 공용 경로는 평문 UDP다: AdGuard사가 질의를 받고, 53번을 가로채는 망에서는 그 망이 먼저 답해 차단이 빠지거나 위조될 수 있다(tailscaled는 DNSSEC을 검증하지 않음[S186]). AdGuard Home이 tailnet에서 조용히 빠져도 증상이 없어 감시가 필요하다(C.3.7). Override를 켜면 회사·호텔 내부 이름처럼 로컬 DNS로만 풀리는 이름이 Tailscale을 켠 동안 안 풀린다[S110]. DNS 차단은 같은 도메인 광고(유튜브 등)를 못 막고, 브라우저 보안 DNS·안드로이드 개인 DNS는 이 경로를 우회한다 | C.3.6, F D-08 |
| 3 | Argo CD 공개 webhook을 두지 않고 60초 폴링(`timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 0`)으로 바꾼다 (확정(사용자 2026-10-18, T05). 사용자가 설명을 듣고 골랐다) | 공개 경로가 하나 준다. webhook 효과는 refresh 하나뿐이다[S72] | main 병합에서 배포 시작까지 최대 약 1분 늦어진다. jitter를 0으로 두지 않으면 기본 60초가 더해져 간격이 60~120초가 된다[S209] | C.3.3 |
| 4 | GitHub 보호 설정을 Terraform root `infra/github`로 관리하되 저장소·시크릿 리소스를 두지 않고, 관리 밖 설정은 guard가 plan을 멈추게 한다 (D-28, 확정(사용자 2026-10-18)) | 옛 GitHub provider는 권한 부족을 허위 드리프트로 위장했고(`2d2054a:infra/github/provider.tf:6-10`, `2d2054a:docs/traps-detail.md:69-76`), `github_repository` destroy가 저장소를 지울 수 있었다(spec §10 2항). 저장소·시크릿 리소스를 두지 않고, owner admin 토큰으로만 로컬 실행하고, App ID를 숫자 리터럴로 두면 옛 사고(저장소 삭제, state 평문 시크릿, 허위 드리프트, `data.github_app` 404)가 구조적으로 빠진다. plan이 필드 단위 미리보기를 주고, Cloudflare·Tailscale root와 도구·state·래퍼를 함께 쓴다. 원안(JSON + `gh api` 스크립트)은 검토 후 제외했다(F D-28) | provider 버그가 들어온다: v6.13.0의 #3519는 갱신 apply가 한 번 실패하면 그 ruleset 드리프트를 숨기고 수정은 미출시다[S192] (래퍼가 실패 뒤 재import). fork PR 승인 정책은 provider가 지원하지 않아 `gh api`가 한 곳 남는다[S191]. CI는 plan하지 않는다(admin 없는 토큰이면 허위 드리프트). owner 토큰과 R2 키가 provider 프로세스에 들어간다(래퍼의 `origin/main` 임시 worktree 실행과 provider 핀으로 줄임) | C.3.9, F D-28 |
| 5 | 공개 DNS를 앱마다 등록하지 않고 와일드카드 레코드 하나와 터널 규칙 하나로 둔다 (확정(사용자 2026-10-18, T05)) | 앱 공개가 Terraform 경로를 타지 않아 옛 `apps.json` 원장, 무인 apply, DNS 드리프트 감시가 필요 없다. 어느 이름이 공개되는지는 Git의 Ingress가 정한다 | **미검증:** 원격 관리 터널에서 와일드카드 hostname 지원. 공식 문서는 로컬 설정 ingress의 `*.example.com` 매칭만 명시한다[S134]. 안 되면 공개 host마다 Terraform 레코드를 둔다(사람 apply) | C.3.4 |
| 6 | 저장소의 GitHub auto-merge 허용을 끈다 (`allow_auto_merge=false`. D-07, 확정(사용자 2026-10-18, T05)) | auto-merge는 쓰기 권한자가 켜고 작성자 조건이 없다[S88]. 자동 병합 주체를 merge App 하나로 좁힌다 | 없음 | C.4.7 |
| 7 | 배포 갱신 App과 병합 App을 나누고, 두 키를 서로 다른 Infisical 프로젝트에 둔다. 배포 키는 OIDC identity로 실행 때 꺼내고, 병합 키는 Secret Sync로 homelab environment `automerge`에 사본 하나를 둔다 (D-04, 확정(사용자 2026-10-18)) | 갱신 App의 키는 앱 CI에서 쓰인다. 그 App이 병합 권한(bypass)까지 가지면 키 유출이 곧 검사 우회다. App만 나누고 두 키를 한 프로젝트·identity에 두면 Free에는 경로 RBAC가 없어 앱 CI가 병합 키도 꺼낼 수 있다. 병합 키를 sync로 옮기면 identity 한 자리가 빈다(4/5) | App 하나, Infisical 프로젝트 하나, sync 하나(1/10)가 는다. 병합 키 사본이 GitHub environment에 하나 생겨(C.6.2의 유일한 예외) 경계가 "main에서 `automerge`를 선언한 job"이 되므로 ci의 workflow-guard와 사람 검토가 지킨다(C.4.6) | C.4.7, C.4.8 |
| 8 | Gateway API를 빼고 Kubernetes Ingress 하나로 공개 라우팅을 한다 | 1번으로 내부 TLS 리스너가 사라져 공개 HTTP 리스너 하나만 남는다. CRD 순서 교착(`2d2054a:platform/traefik/prod/kustomization.yaml:19-39`)과 SSA atomic 리스트 함정(`2d2054a:docs/traps-detail.md:105-108`)의 대상이 없어진다 | 나중에 Gateway API가 필요하면 다시 들인다 | C.3.4 |
| 9 | cert-manager를 남기되 용도를 클러스터 안 인증서로 줄인다 | Barman Cloud Plugin이 TLS에 cert-manager를 권장한다[S33]. 공개 TLS는 Cloudflare, 내부 TLS는 Tailscale이 맡는다 | 구성 요소 수는 같고 외부 토큰 하나가 빠진다 | C.3.1 |

### A.5 단순함 점검 (design-prompt §2 체크리스트)

| 질문 | 이 설계의 답 [제안] |
|---|---|
| 앱 하나를 등록할 때 사람이 수정하는 지점이 적은가 | CLI 명령 2개(`homelab app new`, `homelab app add`)와 PR 검토 후 병합 2회다(`app new`가 여는 `infra/github/app-repos.json` PR과 `app add` 등록 PR. 자기 PR은 승인할 수 없어 관리자 bypass로 병합, C.4.7). 손으로 고치는 파일은 없다. 공개 host는 명령 인자다 |
| 같은 정보를 여러 곳에 입력하지 않아도 되는가 | 배포 설정은 `apps/<app>/values.yaml` 한 곳, 배포 이미지는 `apps/<app>/image.yaml` 한 곳(자동 생성), 시크릿 값은 Infisical 한 곳이다. 앱 저장소에는 배포 설정을 두지 않는다 |
| 최초 등록과 반복 배포의 차이가 명확한가 | 최초 등록은 사람이 검토 후 병합하는 PR(`homelab app add`)이다. 반복 배포는 배포 App이 만드는 `deploy/<app>` PR이다(자동 병합은 main ruleset `app-main`이 active인 앱만. 앱 저장소는 public만, D-29). 등록 안 된 앱의 빌드는 PR을 만들지 않는다 |
| 재실행해도 기존 데이터와 자격증명이 유지되는가 | CLI는 단계마다 현재 상태를 읽고 빠진 단계만 한다. 비밀번호는 Infisical에 값이 없을 때만 만든다. 일반 재배포는 비밀번호를 바꾸지 않는다 |
| 실패했을 때 원인과 다음 행동을 알 수 있는가 | `homelab status`가 빌드·PR·Argo CD·DB·시크릿 준비 상태를 단계별로 보여 주고 다음 명령을 적는다. 배포 실패는 Argo CD 상태 경보로 Telegram에 온다 |
| 앱을 삭제해도 데이터를 실수로 잃지 않는가 | 앱(`apps/`)과 데이터(`data/`)가 다른 Application이다. Database·DatabaseRole은 reclaim `retain`, 영속 PVC는 `Prune=false,Delete=false`다. 폐기는 `homelab data purge`로만 일어난다 |
| 특수한 내부 규칙을 기억하지 않아도 되는가 | 네임스페이스 접두 `app-`, 브랜치 `deploy/`, 파일 위치는 도구가 만든다. 사람이 기억할 규칙은 "데이터 폐기는 `data purge`로만" 하나다 |
| 빈 NUC에서 문서만 보고 다시 세울 수 있는가 | `docs/runbooks-public/bootstrap.md`(플랫폼)와 `restore.md`(root apply 전 DB 복구 PR부터, C.6.4), 저장소 밖 복구 자산으로 세운다. 시나리오 13이 VM에서 DB 복구까지 이를 검증한다 |

### A.6 옛 구성과 비교한 장치 수

| 범주 | 옛 구성 (사실) | 새 구성 [제안] |
|---|---|---|
| homelab 워크플로 | 25개(`git ls-tree 2d2054a .github/workflows/`, README 제외) | 3개: `ci`, `app-build`(공통 reusable), `deploy-merge` |
| 저장소 간 쓰기 App | reader, writer, dispatch(등록만 남음) | `ukyi-homelab-deploy`(갱신), `ukyi-homelab-merge`(병합). 봇 App은 봇 단계에서 따로 |
| 시크릿 전달 채널 | SOPS 9파일 + SealedSecret 10파일, 두 채널 | ESO 한 채널 |
| 수동 원장 | 자격 만료, secret 분류, CI 패리티, 워크플로 준비상태, 이미지 소유권, 메모리, 함정 3종, sync-wave, CI 제외 목록 | 없음 |
| bats 시험 | 313파일, `@test` 3,598개 | 없음. 표준 도구와 직접 쓴 검사 10개 안팎(C.4.6) |
| 앱 공개 등록 | `apps.json` → Terraform CI apply → DNS, 드리프트 감시 2종 | `apps/<app>/values.yaml`의 host 한 줄 |
| 내부 인입 | operator L4 프록시 + Traefik 내부 TLS 리스너 + cert-manager DNS-01 + AdGuard rewrite + 리컨실러 | operator Ingress(서비스마다 하나) |
| 배포 이미지 갱신 주체 | 4개(bump-poll, repin-ops-image, Renovate, 무소유) | 앱 이미지는 배포 App 하나, 그 밖은 Renovate 하나 |

---

## B. 옛 구성 교훈

### B.0 읽는 법

- **행 단위:** design-prompt §3 완료 기준을 따른다. 나열 디렉터리의 1단계 항목(`git ls-tree 2d2054a <dir>/`) 하나가 한 행이다. 목적이 같은 항목은 묶음 행으로 쓰고 "경로(glob)" 열에 포함 경로를 glob으로 적었다. `tests/gates`(그 아래 1단계 127개)는 막으려던 사고별로 묶었다. 조사 메모 세 묶음의 행을 줄이지 않고 합쳤다(저장소 표 122행 + 호스트 9행, 합계 131행. B.10).
- **근거 표기:** B절 표의 `경로:줄`은 모두 커밋 `2d2054a`의 파일이다(`git -C /home/ukyi/homelab show 2d2054a:<경로>`). 줄여 쓴 형식은 셋이다. `TD:<줄>`은 `docs/traps-detail.md:<줄>`, `ADR <번호>`는 `docs/decisions/<번호>-*.md`, `:<줄>`은 같은 칸 앞 파일의 줄이다. 실측은 명령을 적었다.
- **열의 종류:** "무엇이었나"와 "막으려던 실제 사고" 열은 사실이다. "판정", "판정 이유", "새 구조에서 맡는 자리" 열은 이 문서의 제안이다. 판정은 셋 중 하나다: **가져옴**(그대로), **단순화해서 가져옴**(목적은 유지하고 장치를 줄임), **버림**.
- **자리 표기:** "새 구조에서 맡는 자리"의 `C.x.y`는 이 문서 C절의 하위 절이다. 버린 장치에서 남길 교훈은 B.8 함정 목록으로 옮겼다.
- **묶음 사이 중복:** 세 묶음은 서로 다른 디렉터리를 맡아 1단계 항목이 겹치는 행은 없다(B.10). 같은 주제가 두 묶음에 걸친 곳(예: 저장소의 `infra/k3s-bootstrap/**`와 그것이 NUC에 남긴 유닛, `.claude/hooks`와 그 검사 `L20`)은 판정을 하나로 맞추고 서로 가리키게 했다. 조사 메모와 판정이 달라진 행은 "판정 조정"이라고 적었다.

### B.1 `infra/` · `platform/` · `apps/` · `ops/` (27행)

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| P01 | `infra/_backend/**` | 세 Terraform root가 복사해 쓰는 R2 S3 backend 템플릿. 버킷 `homelab-tfstate`, 키 `<root>/prod/terraform.tfstate` | state 잠금이 없어 CI apply와 owner 로컬 apply가 경합할 수 있었고, 직렬화는 CI 동시성 그룹뿐이었다(`infra/_backend/backend.tf:7-11`, TD:431-434). 키 형식 `infra/_backend/backend.hcl.example:18` | 단순화해서 가져옴 | state 버킷은 이어 쓴다(D-11). 사본·템플릿 일치 검사는 root 몇 개에 과하다. 옛 키를 쓰면 옛 state를 물려받아 plan이 옛 자원 삭제를 제안한다(design-prompt §1 6항) | C.3.9: root마다 backend 블록, 키 `v2/<root>/terraform.tfstate`. 잠금은 `use_lockfile`(R2 조건부 쓰기는 문서·소스로 확인, 동시 실행 시험만 E4a, U02) |
| P02 | `infra/_tests/**` | Terraform bats 4개(무인 apply 안전 불변식 16개, R2 `prevent_destroy`, `tf-validate`, `bootstrap` 멱등) | 30분 무인 apply가 destroy를 내거나 신뢰 앵커 root를 apply하는 사고, advisory 잡에만 있던 검사를 필수 검사가 건너뛴 사고(`infra/_tests/test_tf_reconcile.bats:2-14`, `infra/_tests/test_tf_static.bats:2-6`) | 버림 | 새 구조는 무인 apply를 두지 않아 불변식 대상이 없다. 교훈 하나만 남긴다: 병합을 막아야 하는 검사는 필수 검사 안에 둔다 | C.4.6: CI의 `terraform fmt -check`·`validate`(자격 없이) |
| P03 | `infra/cloudflare/**` | Cloudflare root. 원격 관리 터널, 공개 DNS 3종(apex·www, `reserved-hosts.json`, `apps.json`), zone 설정 9개(HSTS 포함), WAF·rate-limit, 캐시 규칙, R2 버킷 3개. CI가 push마다 apply, 30분마다 수렴 | 손으로 바꾼 설정을 CI가 되돌림(`infra/cloudflare/README.md:5`, design-prompt §1 1항). Free 플랜 제약(정규식 불가, rate-limit 10초)은 plan이 아니라 apply에서 400(`waf.tf:11-14`, `:40-46`, `cache.tf:7-8`). HSTS includeSubDomains 180일(`zone_settings.tf:61-75`). R2 lifecycle `prefix = ""`가 버킷 전체를 14일에 지워 "옛 prefix 보존" 계획이 거짓이 됨(`r2.tf:16-21`, ADR 0006:81-92). 앱 DNS와 플랫폼 DNS를 한 레지스트리에 두면 앱 철거 회수에 플랫폼 host가 휩쓸림(`dns.tf:11-18`, TD:493-497) | 단순화해서 가져옴 | 터널·DNS·zone 하드닝은 외부 공개의 바닥이다. 앱별 DNS 합류와 무인 수렴은 앱 등록을 무겁게 하고 사람 변경을 되돌린 원인이다. media·cache 백업 버킷은 폐기 대상(C-02, C-03) | C.3.4, C.3.9: 새 root(owner 로컬 apply). 와일드카드 레코드 + apex, zone 설정 9개 코드화(D-11), WAF 규칙, 백업 버킷 1개 |
| P04 | `infra/github/**` | GitHub root. 저장소 설정(public, squash만, auto-merge 허용), `homelab-app-template` 저장소, main 보호(필수 검사 `gate`, strict, 리뷰 0, push는 owner + writer App, `enforce_admins=false`), writer 전용 ruleset 2개, `homelab-main` environment | 워크플로 커밋은 서명이 없어 소유권 검사는 인증이 아니라 인터록(`infra/github/rulesets.tf:3-8`, `main-authority.tf:1-2`). fine-grained PAT가 `GET /apps/{slug}`를 404로 막아 data source가 죽고 plan이 조용히 무변경(TD:69-76, `rulesets.tf:16-22`). 읽기 토큰은 merge 설정이 null이라 영구 허위 드리프트(`provider.tf:6-10`). Free는 private 저장소에 보호 규칙이 없음(`repo.tf:3-6`). `github_repository` 두 개에 삭제 방지가 없음(`repo.tf:1`, `:28`). `enforce_admins=false`라 owner는 필수 검사까지 우회(`repo.tf:58-65`) | 단순화해서 가져옴 | AC-P8의 서버 쪽 강제를 맡을 자리라 필요하다. Terraform은 유지하되 provider 함정을 구조로 피한다: 저장소·시크릿 리소스 없음, owner admin 토큰으로만 로컬 실행, App ID 숫자 리터럴, 관리 밖 설정은 guard가 plan을 멈춤(A.4 4번, D-28) | C.3.9, C.4.7: Terraform root `infra/github`(state `v2/github`, owner 로컬 래퍼). 새 App 기준 ruleset A~D(D는 D1·D2 둘)와 E1 임시 ruleset, 앱 저장소 공통 main ruleset, environment `automerge`, Actions 권한, guard |
| P05 | `infra/k3s-bootstrap/**` | 호스트·k3s 부트스트랩 셸 계층(`host-up.sh` 진입). `versions.env` 핀, `k3s-install.sh`, `host-config.sh` + `host-config/` drop-in·유닛, `host-preflight.sh`, local-path·StorageClass, `verify-cluster.sh`, 클러스터 정체성 검사, motd, AIOps 설치기, bats 14개 | 노드 DNS 순환 세 갈래: CNI portmap DNAT가 노드의 :53 질의를 AdGuard 파드로 끌어감(`infra/k3s-bootstrap/host-preflight.sh:12-21`), 노드 → 공유기 → AdGuard 교착(`host-config/etc/systemd/resolved.conf.d/10-k3s-node.conf:23-31`), tailscale `~.`가 노드 질의를 MagicDNS로 가져감(TD:1139-1164). `--tls-san`·`--node-name`·`--node-ip`는 설치 때만 정할 수 있음(`versions.env:77-78`, `:89-91`). 타임존이 틀리면 CronJob이 9시간 밀림(`:121-124`). 저장 경로가 k3s 디렉터리 밖이라 `k3s-uninstall.sh` 뒤에도 남음(`:134`) | 단순화해서 가져옴 | 빈 NUC 재구축(시나리오 13)과 노드 DNS 방어는 그대로 필요하다. bulk 국면 장치, AIOps, motd, files 유닛, versions 리더, bats는 폐기된 데이터·범위 밖 기능용이다 | C.3.2 `host/`: 핀 파일, k3s `config.yaml`, drop-in 트리, preflight·verify. 하위 항목 판정은 C.3.2 표 |
| P06 | `infra/tailscale/**` | Tailscale root. ACL(태그 소유, member → `autogroup:self:*`, member → `tag:k8s:80,443`, admin → `tag:k8s:5432`, ssh 규칙), 전역 nameserver(NUC 하나), operator OAuth client | `autogroup:self` 규칙이 빠지면 default-deny가 운영자 원격 SSH를 끊음(`infra/tailscale/acl.tf:8-10`). nameserver 노드 키가 만료되면 tailnet 전역 이름 해석이 멈추고, 재등록하면 만료가 다시 켜짐(`:61-74`). 노드 자신이 전역 nameserver를 받으면 이름 해석이 클러스터를 경유(`:57-60`). nameserver 값이 gitignored tfvars에 있어 diff에 안 보임(`:53-56`). Override 토글은 provider 경쟁 때문에 IaC 밖(`:79-82`). 읽기 OAuth 범위 부족이 "1 to add" 허위 드리프트(`variables.tf:23-32`). 옛 root를 apply하면 C-05 폴백이 사라짐(spec §10 12항) | 단순화해서 가져옴 | ACL·DNS는 하나뿐인 tailnet 설정이라 새 코드가 덮어쓴다(D-11). self·ssh 규칙은 유지한다. CI plan 드리프트 감시는 버린다 | C.3.5, C.3.6: 새 root(owner 로컬). DNS 설정도 `tailscale_dns_configuration`으로 코드화한다(NUC가 없을 때 ACL apply를 막지 않게 별도 root `infra/tailscale-dns`, `prevent_destroy`, count 없음). Override 켬, 전역 nameserver는 NUC AdGuard Home + AdGuard 공용 2개(D-08 확정) |
| P07 | `platform/adguard/**` | AdGuard Home(ns `edge`). LoadBalancer Service를 servicelb가 노드 LAN IP :53으로 노출, 시드 ConfigMap(`cp -n` 첫 부팅 전용), UI 인증 주입 init, `*.home` rewrite를 맞추는 리컨실러 CronJob, egress 격리 | 빈 PVC에서 root init이 만든 파일을 non-root init이 못 열어 Init:CrashLoop(`platform/adguard/prod/deployment.yaml:13-24`, TD:193-203). setcap 바이너리라 `allowPrivilegeEscalation:false`면 EPERM(`deployment.yaml:111-115`). ConfigMap 수정이 라이브에 안 닿음(`adguardhome.yaml:1-3`, TD:285-287). 프록시 재등록 때 rewrite가 죽은 IP를 가리킴(TD:289-294). LAN 전체가 공유기 IP 하나로 들어와 기본 ratelimit 20에서 질의 실패(`adguardhome.yaml:33-45`). 사설 PTR이 CoreDNS로 가 로그 오염(`:19-32`). liveness 재시작이 LAN 유일 리졸버를 끊음(`deployment.yaml:96-101`) | 단순화해서 가져옴 | C-04로 같은 IP :53 서빙이 필수다. "라이브가 원본, Git은 첫 부팅 시드"(ADR 0007)와 실측 설정값을 가져온다. rewrite와 리컨실러는 내부 이름을 `*.ts.net`으로 옮겨 필요 없다(A.4 1번) | C.3.6 `platform/adguard` |
| P08 | `platform/argocd/**` | 자기 관리 Application(차트 argo-cd 10.0.1, wave -10), root app-of-apps, ApplicationSet 2개, AppProject 2개, 수동 Application 8개, sync-wave 원장, extras(로컬 계정·알림 SealedSecret, webhook HTTPRoute), bootstrap values(KSOPS, 알림, netpol) | Application 사이에는 순서가 없음(`platform/argocd/root/SYNC-WAVES.md:7-15`). appset 앱이 CRD보다 먼저 와 "resource mapping not found"로 Missing 고착(`root/appset.yaml:58-71`). 앞 wave 리소스가 뒤 wave 컨트롤러 health를 기다려 17시간 교착(TD:9-26). root → appset → Application selfHeal 사슬이라 Application 단위로 끌 수 없음(TD:216-234). 자기 관리 App과 root가 부트스트랩에서만 생겨 핀 이동이 한쪽만 됨(`scripts/bootstrap.sh:33-44`). webhook 방식 Telegram 알림이 토큰을 DEBUG 로그로 유출(`bootstrap-values.yaml:137-139`). sync 실패는 상태 어디에도 안 잡힘(`:215-225`) | 단순화해서 가져옴 | C-07의 중심이다. 자기 관리, 명시 revision, SSA, retry, admin 끔, 읽기 기본 정책 같은 실측 결정은 가져온다. KSOPS exec 플러그인, SealedSecret, `platform-components` appset, AIOps 알림은 버린다(B.5) | C.3.3: 공식 install.yaml(v3.5.5) + Kustomize 자기 관리, root가 argocd Application까지 소유, Application health 사용자 정의 |
| P09 | `platform/cache/**` | 앱별 Valkey 계층(ns `cache`). 공용 백업 CronJob(인스턴스 발견 → BGSAVE → RDB 네트워크 풀 → R2), RBAC, netpol. 인스턴스는 `tools/provision-cache.ts`가 생성(PVC 1Gi, `allkeys-lru`, `appendonly no`, Recreate) | RWO PVC + RollingUpdate 교착(`tools/provision-cache.ts:105`). appset에 `destination.namespace`가 없어 CreateNamespace 무효(`platform/cache/prod/kustomization.yaml:3-5`). 철거 전 백업 신선도를 안 보면 유실(`backup-cronjob.yaml:3-4`). 자격을 argv로 넘기면 ps에 노출(`:60`) | 단순화해서 가져옴 | 앱별 단일 인스턴스와 캐시 기본값은 design-prompt §6과 같다. 공용 발견형 백업, ACL SealedSecret, 메모리 원장은 버리고 공식 차트로 간다 | C.5.6: 공식 `valkey` 차트 0.12.0을 데이터 차트의 subchart로. 백업은 영속용만 |
| P10 | `platform/cert-manager-netpol/**` | cert-manager ns egress 기본 거부 + 최소 허용(apiserver 노드 서브넷:6443, CoreDNS, 외부 443·53)을 별도 Application으로 | 전 클러스터 Secret 권한을 가진 컨트롤러의 측면 이동 위험. 원격 차트에 netpol 옵션이 없어 따로 뺐다(`platform/cert-manager-netpol/prod/kustomization.yaml:3-6`, `networkpolicy.yaml:1-13`) | 단순화해서 가져옴 | 보안 통제는 단순화 대상이 아니다. 정책 하나를 위한 별도 Application은 필요 없다 | C.3.1: cert-manager Application 안의 정책. 용도는 클러스터 안 인증서뿐이라 외부 egress를 더 좁힌다 |
| P11 | `platform/charts/**` | 공유 Helm 차트 `platform/charts/app`(0.1.0, git 경로 main 참조). kind web·worker·site, 닫힌 schema, digest 우선, 리소스 4값 필수, PSA restricted 기본, SA 토큰 미마운트, Recreate 기본 | selector 라벨이 가변값이면 Deployment selector 불변으로 영구 sync 실패(`platform/charts/app/templates/_helpers.tpl:20-24`). `app.kubernetes.io/instance`는 Argo CD v3가 자식을 트리에서 숨김(`:9-12`). toYaml로 임의 객체를 내던 백도어(`values.yaml:88-92`). RWO + RollingUpdate 교착(`:74-77`). 닫힌 schema를 넓히지 않아 베스포크 컴포넌트가 4개로 늘어남(ADR 0004:15-17) | 단순화해서 가져옴 | 앱마다 매니페스트를 복사하지 않게 하는 가장 싼 장치다. 그러나 git 경로 main 참조라 차트 변경이 모든 앱에 한 번에 적용됐다(`platform/argocd/root/appset.yaml:111-117`, `Chart.yaml:5`). 태그로 버전을 고정한다 | C.4.5: `platform/charts/app`과 `platform/charts/app-data`, 앱별 버전 고정. 판정 상세는 B.5 |
| P12 | `platform/cloudflared/**` | 터널 커넥터 Deployment(ns `edge`, catch-all → Traefik :80), 터널 토큰 SOPS | 같은 토큰으로 커넥터 둘이 붙으면 공개 요청을 두 클러스터에 비결정적으로 나눔(`platform/argocd/root/appset.yaml:29-34`). Secret 변경은 파드 재시작 전까지 반영 안 됨(TD:89-90). ingress가 Terraform 원격 설정(`infra/cloudflare/tunnel.tf:16-28`)과 ConfigMap(`platform/cloudflared/prod/configmap.yaml:12-13`) 두 곳에 있었음 | 단순화해서 가져옴 | 외부 공개 경로와 공개 webhook 수신의 바닥이다. 토큰은 ESO로, ingress 규칙은 Terraform 한 곳으로 | C.3.4: 새 터널, 고정 버전 이미지 |
| P13 | `platform/cnpg/**` | CNPG operator(차트 0.28.3 = 1.29.1), barman-cloud plugin, 공유 Cluster `pg`(인스턴스 1, PG 18.4), ObjectStore(보존 14d), ScheduledBackup, 로컬 basebackup, pg_dump 헤지, 주간 복원 드릴, ensure-role-password 훅, Pooler, tailnet LB | KSOPS Secret에 wave가 안 붙어 Cluster가 자격보다 먼저 올라가 교착(`platform/cnpg/prod/kustomization.yaml:46-56`). plugins·managed roles 서버 기본값 미기재로 영구 OutOfSync(`cluster.yaml:84-86`, `:108-110`, TD:105-124). recovery 블록을 남기면 볼륨 유실 때 낡은 데이터로 조용히 복구(`cluster.yaml:50-62`). 두 primary가 같은 R2 prefix에 아카이브하면 타임라인이 섞임(ADR 0006:17-19). ScheduledBackup은 UTC, CronJob은 KST(`scheduled-backup.yaml:7-11`). role 삭제 뒤 passwordStatus 잔존(TD:2498-2528). tailnet LB selector가 Pooler까지 잡음(`pg-rw-tailscale-service.yaml:6-12`) | 단순화해서 가져옴 | CNPG는 확정(C-07). 공유 클러스터 + 앱별 DB + R2 barman 백업 뼈대는 유지한다. 로컬 basebackup, AIOps 연결, SOPS 시드는 버린다. 헤지·드릴·훅은 새 버전 기능으로 다시 정한다 | C.5.3: CNPG 1.30.1 + Barman Cloud Plugin v0.15.1, `Database`·`DatabaseRole` CRD |
| P14 | `platform/data-conn/**` | 앱이 쓰는 DB·캐시 연결 SealedSecret 모음(ns `prod`)과 철거 기록 `.tombstones.json` | SealedSecret은 봉인 때 ns에 묶여 다른 ns에 두면 영구 복호화 실패(`platform/data-conn/prod/kustomization.yaml:6-8`). 마지막 리소스를 지우자 auto-sync가 prune을 거부해 라이브에 Secret 6개가 남음(`:12-14`, TD:2441-2462) | 버림 | 연결 자격 원본은 Infisical, 전달은 ESO가 앱 ns에 바로 만든다 | C.6.2: 앱 ns의 ExternalSecret. 교훈(비워질 수 있는 Application의 `allowEmpty`)은 C.5.5 |
| P15 | `platform/files/**` | 자체 파일 저장 앱. bulk PVC 100Gi(Retain, Prune=false), 내부·공개 리스너, 이미지 bump 레인 | 재생성 불가 사용자 데이터의 오삭제와 매체 유실(`platform/files/prod/pvc.yaml:1-16`) | 버림 | files 데이터는 폐기(C-03). 재연결 대상이면 T22에서 표준 앱 경로로 | 교훈만 C.5.5(데이터 PVC는 Retain + Prune=false + 오프사이트 백업) |
| P16 | `platform/ghcr-pull/**` | prod ns의 private GHCR pull용 dockerconfigjson SealedSecret | org 패키지는 첫 push 때 private이고 가시성 변경은 UI 전용(TD:65-67, `platform/ghcr-pull/README.md:3-6`). 같은 토큰이 봉인 3곳에 흩어져 회전 때 일부가 낡음(ADR 0001:58-66) | 버림 | 판정 조정(D-29): 앱 저장소와 GHCR 패키지는 public만 둔다. 익명 pull이 되므로 pull 자격(classic PAT, dockerconfigjson Secret)이 필요 없다 | 없음. 공유 차트는 `imagePullSecrets`를 내지 않고, `homelab app add`가 익명 pull이 안 되는 패키지를 거부한다(C.7). 교훈(패키지 가시성은 UI에서만 바꾸고 public은 되돌릴 수 없다)은 B.8 E5, C.4.10 |
| P17 | `platform/homepage/**` | gethomepage 대시보드, HTTPRoute 자동 발견용 읽기 ClusterRole | config를 RO로 마운트해 EROFS, apiserver egress를 ClusterIP로 적어 막힘(TD:1824-1838) | 버림 | 요구사항에 없고 Argo CD·Grafana UI로 대체된다 | 없음. apiserver egress 교훈은 B.8 |
| P18 | `platform/namespaces/**` | appset 대상 ns 11개를 PSA 라벨과 `Prune=false`로 일괄 소유하는 수동 Application(wave -9) | appset에 `destination.namespace`가 없어 CreateNamespace 무효(`platform/namespaces/prod/namespaces.yaml:1-7`, TD:57-59). PSA baseline도 hostPath·hostPID 금지라 node-exporter·vector는 privileged ns 필요(TD:236-239). tailscale 프록시는 privileged 필수(`namespaces.yaml:116-131`). 다른 주체가 만든 ns에는 PSA 라벨이 없음(`:146-152`) | 단순화해서 가져옴 | ns와 PSA 라벨을 한 곳에서 선언하는 일은 싸고 효과가 크다. 앱 ns는 앱 ApplicationSet이 `managedNamespaceMetadata`로 만든다[S67] | C.3.3: 플랫폼 ns 목록(이른 wave, `Prune=false`) |
| P19 | `platform/network-policies/**` | prod ns 기본 거부 ingress·egress + 허용(DNS, gateway → :8080, 관측 → :9090, DB:5432, cache:6379, kubelet probe). kube-router가 강제 | ipBlock에 pod CIDR을 넣으면 기본 거부가 무력화(TD:252-256). kube-router가 새 파드 규칙을 수 초 늦게 설치(TD:258-261). apiserver egress는 노드 서브넷:6443이어야 하고, 반대로 netpol로 노드 IP:6443을 막지 못함(TD:263-274). DB egress는 의도적으로 열어 둠(`platform/network-policies/prod/NOTES.md:30-36`) | 단순화해서 가져옴 | 침해된 앱이 데이터 계층에 닿는 범위를 줄이는 기본 방어라 유지한다. 앱 ns마다 같은 세트를 공유 차트가 낸다 | C.4.5 공유 차트의 netpol, C.8 격리 공간(파드 netns 방화벽으로 노드 로컬 경로 차단) |
| P20 | `platform/sealed-secrets/**` | Bitnami Sealed Secrets 컨트롤러(키 자동 회전 정지, netpol) | 컨트롤러가 죽으면 봉인본은 sealing key 백업 없이 못 풂, 부트스트랩 시크릿을 넣으면 "클러스터를 세우려면 클러스터가 필요"한 순환(ADR 0001:15-18). 키 회전이 백업·인증서를 조용히 낡게 함(`platform/sealed-secrets/prod/values-sealed-secrets.yaml:4-20`). patch-mode `managed`는 cascade delete(TD:384-392). `crds/` CRD가 렌더에서 빠짐(TD:380-382) | 버림 | 일상 시크릿 원본은 Infisical, 전달은 ESO(C-07). 같은 값을 암호화 YAML로 중복 관리하지 않는다 | 없음. 부트스트랩 자격만 저장소 밖 별도 보관(C.6.4) |
| P21 | `platform/tailscale/**` | Tailscale operator(차트 1.102.2, privileged ns), `traefik-ts` tailnet LoadBalancer(L4 → Traefik :8443), 프록시 메모리 캡 ProxyClass, OAuth SOPS | L7 Serve로 종단하면 `*.home` SNI를 못 받아 인증서 불일치(`platform/tailscale/prod/traefik-ingress.yaml:1-5`). hostname이 충돌하면 `-N` 접미가 붙고 IP가 바뀌어 AdGuard rewrite가 낡음(`:12-17`, TD:289-294). 프록시 파드 무제한 메모리(`proxyclass.yaml:1-4`). operator Ingress reconcile은 메타데이터만 바뀐 변경을 무시(TD:296-298). 전역 namespace 트랜스포머가 cross-ns Service를 망가뜨림(`kustomization.yaml:3-7`) | 단순화해서 가져옴 | tailnet 전용 내부 인입 기능은 유지한다. 판정 조정(조사 메모의 hostPort 대안 대신): L4 프록시 + Traefik 내부 TLS + rewrite 대신 operator Ingress(`*.ts.net`, 자동 인증서)로 바꾼다(A.4 1번). ProxyClass 메모리 캡은 가져온다 | C.3.5 |
| P22 | `platform/traefik/**` | Traefik(Helm) + Gateway API CRD v1.5.1 + Gateway(공개 `*.ukyi.app`, 내부, 내부 TLS :8443) + cert-manager DNS-01 와일드카드 인증서(Cloudflare 토큰) + whoami 스모크 | CRD wave 0·Gateway wave -8로 "resource mapping not found", 이어서 Gateway가 컨트롤러 health를 기다려 17시간 교착(`platform/traefik/prod/kustomization.yaml:19-39`). HTTPRoute parentRefs·backendRefs 서버 기본값 미기재로 영구 OutOfSync(TD:105-108). `serviceAccount.name` 지정 시 SA 미생성(TD:54-55). DNS-01 self-check가 클러스터 DNS 경로에서 SERVFAIL(`platform/argocd/root/apps/cert-manager.yaml:23-28`). HSTS 때문에 내부 UI도 유효 인증서 필요(spec §4.5. 원인은 Cloudflare 헤더가 아니라 `.app` 최상위 도메인의 브라우저 HSTS preload[S210]) | 단순화해서 가져옴 | 내부 TLS가 Tailscale로 옮겨 공개 HTTP 라우팅만 남는다. Gateway API, 내부 리스너, DNS-01을 빼고 Ingress 하나로 간다(A.4 8번) | C.3.4: Traefik(Argo CD 관리) + Ingress class `traefik` |
| P23 | `platform/victoria-stack/**` | 관측 스택(ns `observability`): vmsingle(30d), vmagent, VictoriaLogs(14d), vector, vmalert(룰 62개), Alertmanager(Telegram, Watchdog → relay → healthchecks.io, AIOps webhook), Grafana, node-exporter, KSM, 보조 수집기 4개 | vector·VictoriaLogs OOM 결합 루프(TD:126-160). vmalert는 `configCheckInterval` 없으면 룰 변경 무시(TD:1783-1794). Alertmanager ConfigMap 변경이 롤아웃 안 됨(TD:338-349). busybox nc `-q` 부재로 relay가 dead-man을 무력화(`platform/victoria-stack/prod/deadmanswitch-relay.yaml:9-16`, TD:305-309). 두 클러스터가 같은 체크를 ping하면 거짓 초록(`kustomization.yaml:32-38`). vector는 root여야 로그를 읽음(TD:300-303). Telegram 자동 HTML escape(`alertmanager-config/alertmanager.yml:45-48`). 재부팅 IP churn 오발화(TD:507-525) | 단순화해서 가져옴 | D-09의 출발점이다. 비AI 알림·외부 생존 감시(AC-P11)와 봇 수신 자리의 선례가 이미 있다. 보조 수집기 4개와 CI·메타·기판 룰은 옛 자동화를 감시하던 것이라 버린다 | C.3.7 |
| P24 | `apps/README.md` | 배포 전용 앱 디렉터리 계약(필수 4산출물, `autoDeploy` 기본 false, 앱 수 0↔1 손 단계) | 도구 소유 `values.yaml`의 손 주석이 다음 왕복에서 사라짐(`apps/README.md:30-31`). 앱 수가 0↔1을 넘을 때 열거 바닥값 4곳을 손으로 고침(`:24-29`) | 버림 | 새 앱 계약으로 대체한다. 바닥값을 손으로 고치는 규칙은 design-prompt §2 기준에 어긋난다 | C.1: 새 `apps/README.md`(사람 파일과 자동 파일 구분) |
| P25 | `apps/aiops-autodeploy-canary/**` | 옛 AIOps 자동 배포 검증용 site 앱(values digest 핀, `autoDeploy` true) | AIOps 자동 배포 경로 검증용(범위 밖). 그 저장소는 `reusable-app-build.yaml@main`을 호출해 main 교체 때 빌드가 깨짐(design-prompt §3 9항) | 버림 | AIOps는 범위 밖이다. `aiops-autodeploy-canary` 저장소는 공개하지 않고 private으로 보관한다(삭제도 가능, D-29, T22) | 없음 |
| P26 | `ops/pg-tools/**` | 자체 ops 이미지(debian + postgresql-client-18 + kubectl·rclone 핀). 소비자 6곳 | 부동 채널 kubectl 재빌드가 복원 드릴을 두 번 죽임(`ops/pg-tools/README.md:18-21`, `Dockerfile:15-21`). pg_dump는 서버보다 낮은 major를 거부해 PG 업그레이드는 이미지 3개 동시(TD:485-491). `ARG TARGETARCH` 기본값이 플랫폼 인자를 이겨 아키텍처가 섞인 이미지(`Dockerfile:8-13`) | 버림 | 자체 이미지의 빌드·재핀 체인이 따로 필요했다. 작업마다 공식 이미지를 쓴다(CNPG PostgreSQL 이미지의 `pg_dump`, Valkey 이미지의 `valkey-cli`, rclone 공식 이미지) | C.5.7 복원 Job, C.5.6 Valkey 백업 Job. 교훈(클라이언트 major = 서버 major)은 B.8 |
| P27 | `ops/skopeo/**` | digest·GHA 생존 exporter용 skopeo 이미지 | 상류가 릴리스 태그를 재푸시하고 GC해 핀이 404, 브랜치와 무관하게 모든 PR gate가 red(6일 3회)(`ops/skopeo/Dockerfile:5-12`). busybox date가 ISO8601을 거부해 신선도 판정이 조용히 깨짐(`:17-23`) | 버림 | 소비자 exporter 둘을 버린다 | 교훈: 라이브 레지스트리 조회를 필수 검사에 넣지 않는다(C.4.6) |

### B.2 `tools/` · `scripts/` · `tests/` · `policy/` (50행)

옛 규모(사실, `git ls-tree -r 2d2054a`와 `@test` 줄 집계): 저장소 전체 파일 929개, bats 313개, `@test` 3,598개. 이 묶음은 약 8만 2천 줄, `@test` 2,766개다. `tools/` 본체 20,266줄, `tools/tests` 26,668줄, `tests/` 27,783줄. required gate 한 번에 2,672 ok(2026-09-03 기록, `tests/gates/test_rbac-verbs.bats:11`).

**A. CLI와 앱 등록 (조사 항목 1, 3)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L01 | `tools/homelab.ts` `tools/cli-result-schema.json` `tools/generate-result-schema.ts` | 통합 CLI `homelab`(doctor, status, db·cache create, app init·create·secrets·teardown, mcp)과 `--json` 결과 계약(envelope, 종료코드 0~4), 계약 생성기 | 변이가 전부 `gh workflow run`으로 디스패처를 깨우는 래퍼였다(`tools/README.md:155-159`). 그래서 Ctrl-C 뒤 재실행이 같은 레인 PR을 둘 만드는 창(약 30초, `:538-545`), 타임아웃 뒤 재시도가 run 두 개를 만드는 문제(`:264-272`), 멀티소스 Application의 `sync.revision`이 비어 `--wait` 영구 대기(`:594-599`), 지운 worktree에서 `bun link`해 전역 명령이 끊김(`:211-217`)이 생겼다 | 단순화해서 가져옴 | 목표 UX(doctor, status, 사람용 + JSON, 비밀값 없는 진행 표시)는 design-prompt §8과 같다. CLI가 로컬 자격으로 PR을 직접 만들면 nonce·중복 디스패치 검사·run 특정이 필요 없다 | C.7: 새 CLI. 변이는 "파일 생성 → 브랜치 → PR"까지. 변이 호출은 재시도하지 않고 재조회만 |
| L02 | `tools/lib/` | 41파일 6,917줄 공유 커널(argv 파싱, 변이 엔진, 레인 PR 조회, Argo CD revision 해석, exec seam, MCP, 원장 편집기) | 같은 플래그를 두 번 받으면 `--confirm x --confirm myapp`이 파괴 확인을 통과(`tools/README.md:442-445`). owner 변수와 login의 대소문자 차이로 모든 변이가 잠김(TD:2128-2139) | 단순화해서 가져옴 | 쓸 만한 것은 이름 정규식, 외부 명령 실행 seam(argv 기록으로 부수효과 시험), Argo CD revision 해석 정도다. 나머지는 디스패처·원장·SealedSecret 구조 때문에 생긴 것이다 | C.7: CLI 안의 작은 모듈 몇 개. 중복 플래그 거부 |
| L03 | `tools/create-app.ts` `tools/update-secrets.ts` `tools/validate-mutation.ts` | 앱 등록 생성기(앱 저장소 `.app-config.yml` 검증 → 4파일 + `apps.json` + 메모리 원장 + exporter 목록 + 동봉 계약 행), 봉인본 복사·envFrom 배선, 디스패처 입력 검증기 | 앱 하나 등록에 표면 8곳을 써야 했다(`tools/README.md:305-310`). 그중 한 곳이 워크플로 add-paths 밖이라 모든 단계가 성공했는데 변경이 커밋에서 빠짐(2026-08-18, `tests/gates/test_staged-completeness.bats:5-7`). owner 입력까지 비신뢰로 취급(`tools/validate-mutation.ts:2-3`, TD:96-98). 임의 sha 배포를 막으려 앱 main HEAD를 직접 해석(`:14-15`) | 단순화해서 가져옴 | 위험(부분 표면, 비신뢰 입력, 임의 sha)은 실재한다. 등록 표면을 `apps/<app>/` 한 곳으로 모으면 부분 표면 위험이 줄고 검증은 스키마 하나면 된다 | C.7 `homelab app add`: `apps/<app>/` 하나만 만드는 PR. 첫 이미지는 앱 main HEAD 빌드의 digest |
| L04 | `tools/app-config-schema.json` `tools/app-deploy-schema.json` `scripts/check-app-deploy.sh` | 앱 저장소 자기선언 계약(v2), homelab 배포 디렉터리 4파일 계약, 그 가드 | `source-repo`가 빠지면 그 앱이 폴링에서 영영 빠짐(`scripts/check-app-deploy.sh:4`). 봉인본·envFrom·kustomization·checksum 중 일부만 있으면 Secret prune 뒤 재시작 때 죽음(`:6-13`). 사실(`gh api` GET 2026-10-17): `homelab-app-template`의 `template-ci.yaml`이 매주(19줄) homelab main의 이 스키마를 받는다(266줄) | 단순화해서 가져옴 | 앱 설정 스키마 하나는 필요하다. 앱 저장소와 homelab에 같은 선언을 두 벌 두지 않는다. 봉인 배선 불변식은 대상이 없다. main 교체 순간 템플릿 CI가 깨진다 | C.4.5: 공유 차트의 `values.schema.json`(닫힌 schema). 템플릿의 main 의존은 E10(T22)과 D-21에서 끊는다 |
| L05 | `tools/activate-app.ts` `tools/audit-orphans.ts` `tools/dns-drift-check.ts` | 공개 노출 재승인 게이트, `apps.json`·매니페스트·원장 교차 드리프트 리포트, 공개 host 실제 해석 검사 | 옛 revision이 Healthy인 동안 미승인 hostname이 먼저 노출됨(`tools/activate-app.ts:1-7`). active인데 매니페스트가 없어 빈 백엔드가 공개됨(`tools/audit-orphans.ts:5`). apply 실패로 DNS가 안 생겼는데 아무도 모름(`tools/dns-drift-check.ts:1-2`) | 버림 | 셋 다 "등록 원장과 DNS가 앱 디렉터리와 따로 산다"는 구조에서 생긴 드리프트를 사후에 잡았다. 공개 여부를 앱 values 한 곳에서 정하고 DNS를 와일드카드로 두면 교차 원장이 없다 | 공개 경로 생존은 선택 항목인 외부 HTTP 확인(C.3.7). 공개 여부 변경은 사람 승인 PR에서만 |

**B. 배포 갱신과 자동 병합 (조사 항목 2)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L06 | `tools/poll-ghcr.ts` `tools/ensure-bump-pr.ts` `tools/run-bump-plan.ts` `tools/bump-tag.ts` `tests/gates/{test_bump-poll-callsite,test_bump_poll_ruleset,test_pr-sweeper}.bats` | GHCR 폴링 bump 경로: 10분 크론 플래너 → 항목별 worktree 러너 → 원격 변이 단일 실행기(1,886줄) → `values.yaml` tag·digest. 호출부 계약, writer 전용 ruleset 고정, BEHIND PR 스위퍼 검사 | 빌드 완료 순서가 git 순서와 어긋나 과거 이미지가 배포되는 것(`tools/poll-ghcr.ts:6-9`: 앱 main 커밋 순서가 권위, 배포 SHA의 descendant만 후보). 승인 없는 배포(`:11-12`). 포크가 같은 브랜치명으로 폴링 오염, 낡은 GraphQL 뷰가 실재 PR을 숨김, `gh pr update-branch` 뒤 소유권 증명 영구 실패(`tools/README.md:366-392`). 워크플로 커밋 미서명이라 강제는 ruleset뿐(TD:582-589). strict + 비동기 auto-merge면 두 번째 PR이 BEHIND로 멈춤(`tests/gates/test_pr-sweeper.bats:2-3`). 10분 크론이 실측 60~90분 지연(`.github/workflows/reusable-app-build.yaml:131`) | 단순화해서 가져옴 | 폴링·소유권 증명·무장 회수는 "앱 CI에 쓰기 자격을 주지 않고 homelab이 끌어온다"는 선택의 비용이었다. 빌드 직후 digest PR이면 폴링이 없다. 불변식 둘만 가져온다: 새 이미지 커밋이 현재 배포 커밋의 descendant일 때만, 자동 병합은 배포 App이 만든 예약 브랜치 PR만 | C.4.3, C.4.7: 공통 워크플로가 기본 브랜치 빌드 뒤 `deploy/<app>` PR. descendant 검사는 PR 생성 때와 병합 직전 두 번(compare API) |
| L07 | `scripts/auto-merge-or-fail.sh` `tests/gates/{test_automerge-fallback,test_branch_protection,test_auth}.bats` | auto-merge 무장 + 이미 CLEAN인 PR만 직접 병합하는 폴백, main 보호 고정 검사, PAT 0건·App 토큰 경로 검사 | `gh pr merge --auto`가 이미 clean인 PR에 에러를 내서 폴백이 필요했고, 폴백이 gate를 우회하지 않게 CLEAN일 때만 병합(`scripts/auto-merge-or-fail.sh:2-5`, `:17-28`, TD:403-404). `required_status_checks`를 주석 처리해 빈 블록을 만들어도 grep 검사가 4/4 통과(2026-09-03, `tests/gates/test_branch_protection.bats:11-16`). `enforce_admins=false`는 의도된 owner 우회(ADR 0003:26-28). writer 토큰을 받기 전에 빌드 출처를 먼저 검증(`tests/gates/test_auth.bats:23-30`) | 가져옴 | 자동 병합이 필수 검사를 건너뛰지 않게 하는 장치는 그대로 필요하다(AC-P8). 다만 보호 규칙은 코드 grep이 아니라 실제 설정을 `gh api`로 읽어 검증한다 | C.4.7: `deploy-merge` 워크플로가 검사한 head SHA로만 병합, 필수 검사는 bypass 없는 ruleset. 보호 확인은 시나리오 15에서 `gh api` GET |
| L08 | `tests/gates/{test_pr-first-commit,test_staged-completeness,test_workflow-pipefail,test_apprepo-gitignore}.bats` | PR 생성 경로의 완전성: 쓰기 상한 밖 변경 감지, GHA 기본 셸 pipefail 부재, 비신뢰 체크아웃 커밋 금지 | 도구가 상한 밖 파일에 써서 모든 단계가 성공했는데 일부가 커밋에서 빠짐(2026-08-18, `tests/gates/test_staged-completeness.bats:5-7`). tee 파이프에서 좌변 실패가 묻혀 부분 산출물이 PR로 샐 위험(`tests/gates/test_workflow-pipefail.bats:2-4`, TD:458). `git add -A`가 비신뢰 파일을 쓸어 담을 위험(`tests/gates/test_apprepo-gitignore.bats:2-3`) | 단순화해서 가져옴 | 부분 PR 위험은 PR을 만드는 주체가 있는 한 남는다. 생성 경로를 한 파일로 줄이면 드물어지고, pipefail은 기본 셸 한 줄로 막는다 | C.4.3, C.7: 워크플로 `defaults.run.shell: bash`, 명시 경로만 add, 생성 뒤 남은 변경이 없는지 확인 |
| L09 | `tests/gates/{test_digest-exporter,test_digest-exporter-producer}.bats` `tests/gates/skopeo-timeout-smoke.sh` `tests/gates/tcp-blackhole-sink.py` | 배포 digest와 GHCR 최신의 차이를 재는 exporter와 그 생산자·skopeo 타임아웃 검사 | ImageDigestDrift 알림이 push 메트릭 rollup 누락으로 라이브 60일간 발화 0(`tests/gates/vmalert-drift-firing-e2e.sh:3-5`). exporter가 private GHCR 자격, 라벨, egress, 앱 목록 parity를 모두 맞춰야 함(`tests/gates/test_digest-exporter.bats:2-3`). skopeo 타임아웃이 실제로 강제되는지 따로 증명해야 함(`tests/gates/skopeo-timeout-smoke.sh:2-3`) | 버림 | 앱 CI가 배포 PR을 직접 만들면 "새 이미지가 있는데 배포 안 됨"은 열린 PR로 보인다 | C.7 `homelab status`: 열린 배포 PR과 Argo CD 배포 이미지를 함께 보여 준다(새 상태 저장소 없음) |

**C. 데이터와 삭제 (조사 항목 4, 6)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L10 | `tools/provision-db.ts` `tools/provision-cache.ts` `tools/verify-db-marker.ts` | 공유 CNPG 안 논리 DB + owner·ro role + 비밀번호·연결 SealedSecret 4개 + 헤지 목록. 앱별 Valkey + 연결 2개 + 메모리 원장 행. 역할 비밀번호 준비 마커 검증 | owner를 공유하면 한쪽 철거·회전이 다른 DB를 깸(owner == name, `tools/provision-db.ts:14`). 헤지 목록 등록을 빠뜨리면 필수 검사가 늘 red라 auto-merge가 영원히 대기(PR #689, `:10-11`). 비밀번호는 디스크·로그에 남기지 않음(`:17-18`). CNPG가 DROP된 role의 passwordStatus를 유지해 거짓 통과, 마커 고아 2건(`tools/README.md:953-957`). `db create --wait` 약 15분, 첫 실행 46분(`:71-73`) | 단순화해서 가져옴 | 앱별 DB·role 1:1, 비밀번호 한 번만 생성, 백업 대상 자동 포함은 그대로 필요하다. 대부분은 CNPG `Database`·`DatabaseRole` 선언과 ESO로 대체된다[S30][S31] | C.5.1, C.7 `homelab db add`·`cache add`: `data/<app>/values.yaml` PR. 준비 확인은 CNPG status + 실제 접속 |
| L11 | `tools/teardown-app.ts` `tools/teardown-resource.ts` `scripts/teardown.sh` | 앱 표면만 지우는 앱 철거(DB·캐시 비접촉), DB·캐시 철거 상태 머신(retain 기본, purge 4단계 각 별도 커밋), fresh main 전용 래퍼 | 자동 refcount가 없어 사용 중인 DB를 지울 수 있음(ADR 0005:23). 그래서 모든 모드에 `--refs-verified` 강제(`tools/README.md:334-339`). `ensure: absent`와 role 제거를 한 revision에 넣으면 cannotReconcile, 공유 클러스터에서 PVC를 지우면 전체 손실, DROP된 DB 하나가 헤지 잡 전체를 실패시킴(`tools/teardown-resource.ts:8-18`). stale main과 무관 커밋이 철거 PR에 섞임(`scripts/teardown.sh:2-5`) | 단순화해서 가져옴 | "앱 삭제와 데이터 폐기 분리"는 design-prompt §6과 시나리오 9 그대로다. 수동 증거 id 대신 데이터 선언을 다른 Application으로 분리해 앱 삭제가 데이터에 닿을 수 없게 한다 | C.5.5, C.7: `homelab app remove`(앱 PR)와 `homelab data purge`(단계 PR 둘) |
| L12 | `scripts/audit-orphan-pv.sh` `tests/gates/test_audit-orphan-pv.bats` | 고아 스토리지 감사(Released PV + 아무 파드도 마운트하지 않는 Bound PVC) | 옛 판은 `phase == Released`만 봐서 `--cascade=orphan` Bound 고아 1.12GiB가 21일 누수되는 동안 "고아 없음"(2026-07-29, `scripts/audit-orphan-pv.sh:6-13`) | 단순화해서 가져옴 | 앱 삭제 뒤 데이터를 일부러 남기는 정책에서 "주인 없는 보존 데이터 목록"은 사용자에게 바로 필요하다. 판정 기준(소비 여부)은 그대로 쓴다 | C.7 `homelab data list`. 주기 알림은 두지 않는다 |
| L13 | `tests/gates/test_cache-backup.bats` | Valkey 백업 CronJob 매니페스트 정적 검사 | R2 Object R&W 토큰은 HeadBucket이 안 돼 rclone `no_check_bucket` 필수, CronJob은 노드 TZ로 발화, 백업 신선도가 purge의 근거(`tests/gates/test_cache-backup.bats:2-4`, TD:61-63, TD:246) | 단순화해서 가져옴 | 영속 Valkey 백업을 두면 같은 함정이 있다. 값을 고정하는 검사보다 복원 시험이 확실하다 | C.5.6 백업 Job 설정 주석, 시나리오 4 |
| L14 | `scripts/check-pg-servername.sh` `scripts/reset-pg-r2-archive.sh` `tests/test_reset-pg-r2-archive.bats` `tests/gates/test_pg-servername.bats` | CNPG 아카이브 serverName 분리 가드, 옛 아카이브와 충돌할 때 그 prefix만 지우는 도구 | serverName 한 줄이 R2 prefix를 정하고, 두 primary가 같은 값이면 타임라인이 섞이며 R2 버저닝이 없어 되돌릴 수 없음(`scripts/check-pg-servername.sh:5-8`). serverName 하드코딩·ambient KUBECONFIG로 다른 클러스터 prefix를 지울 위험(`scripts/reset-pg-r2-archive.sh:9-10`, `:23-27`) | 단순화해서 가져옴 | 옛 버킷은 폐기(C-02)라 지금은 충돌이 없지만, 빈 NUC 재구축 때마다 같은 위험이 다시 생긴다 | C.5.3: serverName에 클러스터 세대를 넣는 규칙(`pg-<YYYYMMDD>`), 재구축 절차에 "새 serverName" 한 줄. 지우는 도구는 두지 않는다 |

**D. 시크릿과 자격 (조사 항목 5)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L15 | `tools/seal-secret.mts` `tools/seal-batch.ts` `tools/sealed-secrets-cert.pem` `tools/env-example.mts` `tools/contract-drift-check.ts` `tools/vendored-contract.json` `scripts/backup-sealed-secrets-key.sh` `scripts/secret-cert-check.sh` `tests/test_sealed-secrets-restore.bats` `tests/gates/{test_secret-cert-check,test_setup-toolchain-kubeseal}.bats` `tests/gates/app-shared-node-smoke.sh` | SealedSecrets 도구 사슬: 앱 `.env` → kubeseal 봉인, 공개 cert, `.env.example` 생성, 앱 저장소 사본 드리프트 감시, sealing key 백업과 cert 일치 검사 | sealing key 없이는 봉인본을 못 풂(`scripts/backup-sealed-secrets-key.sh:4`). 재구축 직후 새 키가 21일간 어느 백업에도 없었음(`scripts/dr-drill.sh:10-13`, `tests/posture/test_dr-assets.bats:2-5`). 커밋된 cert가 낡으면 새 봉인본을 못 풂(`scripts/secret-cert-check.sh:2-4`). 재봉인마다 암호문이 달라 새 커밋·PR·롤링(`tools/README.md:185-187`). 앱 저장소마다 사본(`tools/README.md:938-947`) | 버림 | Infisical + ESO(C-07)로 봉인 도구·키 백업·cert 동기화·사본 감시가 한꺼번에 사라진다. 교훈 하나: 복구 키는 "백업이 있다"가 아니라 "현재 키와 일치한다"를 재야 한다 | C.6: Infisical + ESO. 복구 자산 신선도 확인은 C.6.4 |
| L16 | `scripts/{sops-guard,verify-secrets,sealed-guard}.sh` `tests/{test_sops-guard,test_sops-recipient,test_sops-roundtrip}.bats` `tests/fixtures/` `tests/gates/{test_gate-secret-guard,test_sealed-guard,test_verify-secrets}.bats` | 커밋된 암호화 파일 구조 검사(SOPS MAC, `ENC[` 리프, recipient 신원, 봉인본 평문 리프), 실 age 키 왕복, gitleaks·sops-guard의 필수 검사 편입 | 평문 Secret을 `.sealed.yaml` 이름으로 커밋하거나 평문 리프가 남는 두 형태를 기존 게이트가 못 잡았다(2026-09-03, `scripts/sealed-guard.sh:5-11`). recovery 키를 바꿔치기해도 recipient "개수"만 보면 통과(`tests/test_sops-recipient.bats:2-3`). verify 워크플로는 required가 아니라 gate 안으로 옮겨야 했음(`tests/gates/test_gate-secret-guard.bats:2-3`) | 단순화해서 가져옴 | public 저장소에서 평문 시크릿 커밋은 가장 비싼 사고다. ESO로 가면 Git에 Secret을 둘 이유가 없어 "`kind: Secret` 0건 + gitleaks"로 대부분 막는다. 새 구조는 저장소에 SOPS 파일을 두지 않는다 | C.4.6: CI 필수 검사의 gitleaks + `kind: Secret` 금지 |
| L17 | `tests/gates/{test_iac-credential-gitignore,test_claude-harness-tracked}.bats` | 자격 파일의 접미사 사본이 `.gitignore`를 빠져나가지 못하게 하는 검사, `.claude/` 선택적 추적 규칙 고정 | 같은 사고가 두 번: 2026-08-17 `terraform.tfvars.pre-cutover.bak`이 `*.tfvars`에 안 걸림, 2026-08-19 `backend.hcl` rename 뒤 `git add -A`가 R2 state 자격을 스테이징(public, 커밋 직전 발견)(`tests/gates/test_iac-credential-gitignore.bats:4-11`). `git check-ignore`가 추적 파일을 건너뛰어 초판 가드가 공허 통과(`:15-19`) | 가져옴 | public 저장소와 로컬 자격 파일 조합은 그대로 남을 수 있다. 싸고 효과가 크다 | `.gitignore` 접미사 사본 패턴 + gitleaks pre-commit(R41, R42). 새 구조는 Terraform 자격도 `infisical run`으로 주입해 로컬 자격 파일 자체를 줄인다(C.3.9) |
| L18 | `scripts/{check-credential-expiry,check-gh-secret-coverage,verify-credential-inventory}.sh` `policy/{credential-expiry,gh-secret-var-classification}.json` `tests/gates/{test_credential_expiry,test_gh-secret-coverage,test_credential-inventory}.bats` | 자격 만료 원장(11행)과 주간 경고, GH secret 20개·variable 2개 분류 원장과 전단사 가드, 로컬 런북 인벤토리 대조 | R2 state 자격이 2026-08-18 트랜스크립트에 유출됐는데 원장에 두 달간 없었고 부재를 잡는 가드가 0건(`policy/gh-secret-var-classification.json:5`, `scripts/check-gh-secret-coverage.sh:4-6`). 원장과 런북이 대조되지 않아 2행 누락(`scripts/verify-credential-inventory.sh:4-8`). 바닥값이 세 곳에서 2·3·4(`scripts/check-credential-expiry.sh:7-12`). 실측(jq, 2026-10-17): 11행 전부 `expires` 2099-12-31이라 경고는 원리상 한 번도 울릴 수 없다 | 버림 | 수동 원장은 design-prompt §2가 두지 말라는 대상이고, 만료 감시는 아무것도 지키지 않았다. 원본을 Infisical 한 곳으로 모으고 GitHub Secrets 사용을 없애는 쪽이 싸다 | C.6.2: 원본 Infisical. 자격 목록은 저장소 밖(D-23). 옛 무만료 자격 11개 폐기는 E1(T06 자격 폐기 표) |
| L19 | `scripts/seed-secrets.sh` `tests/test_seed-secrets-metadata.bats` `tests/gates/test_make-secret-targets.bats` | 플랫폼 시드 시크릿 생성기: terraform output + `.env.secrets` → SOPS 파일 7개 | terraform output이 비면 `jq -r`가 문자열 `null`을 내 그대로 암호화·커밋되고 장애가 인증 실패로 위장(`scripts/seed-secrets.sh:24-30`). pg 앱 비밀번호는 한 번만 생성(재생성하면 복원 DB와 어긋남, `:126-149`). 클러스터에는 DNS 편집 전용 같은 좁은 토큰(`:13-17`). ns 이동 뒤 재시드가 옛 ns에 재생성(`tests/test_seed-secrets-metadata.bats:2-7`) | 단순화해서 가져옴 | SOPS 시드는 Infisical로 대체된다. 원칙 셋은 가져온다: 값 부재는 실패, 한 번 만든 비밀번호는 재생성 금지, 클러스터 토큰은 최소 범위 | C.6.5 생성 규칙, C.6.2 ExternalSecret의 키 명시. 토큰별 범위는 저장소 밖 |
| L20 | `tests/gates/{test_manifest-guard,test_debug-skills}.bats` | 에이전트 PreToolUse 훅 검사(`*.enc.yaml`·벤더 파일 편집 차단), 디버그 스킬이 없는 just 타깃을 가리키는지 검사 | 에이전트가 SOPS 파일을 Edit로 고치면 MAC이 깨짐(`tests/gates/test_manifest-guard.bats:3`). 훅은 exit 2만 차단, 그 밖은 fail-open(TD:809). 벤더 파일 3종 중 1종만 막던 갭(`:36`) | 버림 (판정 조정: 조사 메모는 단순화해서 가져옴) | `.claude/` 훅과 스킬을 버리므로(R44, R45) 그 검사도 대상이 없다. "PreToolUse는 exit 2만 차단" 교훈은 B.8에 남긴다 | 없음 |

**E. 부트스트랩, 철거, DR, 백업 (조사 항목 8)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L21 | `scripts/bootstrap.sh` `tests/test_bootstrap.bats` | 멱등 부트스트랩 46줄: argocd NS → `sops-age` Secret → Argo CD helm → 자기 관리 App + root App apply | helm 실패가 grep 파이프라인과 "실패 무시"에 삼켜져 exit 0으로 "bootstrap complete"를 찍던 라이브 버그(`scripts/bootstrap.sh:24`, `tests/test_bootstrap.bats:5-8`). root 앱은 하강만 해서 자기 관리 App을 못 잡고, 하나만 다시 apply하면 죽은 브랜치를 따라감(`scripts/bootstrap.sh:34-42`) | 단순화해서 가져옴 | 작은 멱등 스크립트, 버전 고정, 실패 즉시 중단은 그대로 좋다. `sops-age` 대신 ESO 최초 접속 자격 하나를 넣는다. 자기 관리 App은 root가 소유하게 해 쌍 함정을 없앤다 | C.3.3, `docs/runbooks-public/bootstrap.md`: `set -euo pipefail`, 파이프로 실패를 삼키지 않음 |
| L22 | `scripts/destroy-node.sh` `tests/test_destroy-node.bats` | 노드 파괴 프리미티브: 확인 env + bulk 국면 게이트 + bind 소스 실측 + `k3s-uninstall.sh` + `/var/lib/rancher` 삭제 + 삭제 확인 | 감사 중 에이전트 3개가 파괴 한 줄이 조용히 통과하는지 실증하려고 실제로 실행해 라이브 클러스터를 파괴(2026-08-16, `scripts/destroy-node.sh:8-11`). `k3s-uninstall.sh`는 `k3s-storage/internal`을 남겨, 재구축 뒤 옛 PV 위에서 살아난 워크로드를 "git에서 복귀"로 오독(`:117-120`). bind 소스가 경로 문자열로는 안 보임(`:27-31`). 파싱 실패를 빈 문자열로 접어 파괴까지 완주(2026-08-29, `:58-65`) | 가져옴 | T06 철거가 바로 이 작업이고 spec §10 14항(옛 데이터 부활)의 원인이 여기 기록돼 있다 | E1: 철거 절차는 확인 env가 필요한 별도 파일, k3s 제거 뒤 옛 데이터 경로까지 지우고 부재 확인. E2 시작 조건 |
| L23 | `scripts/{dr-drill,sealing-key-dr-gate}.sh` `tests/test_dr-drill.bats` `tests/gates/test_restore-runbook.bats` | 풀 DR 드릴(복구 가능성 증명 → 노드 파괴 → 재구축 → sealing key 복원 → 전 Application Healthy → R2 DB 복구·canary 대조), DR 런북 결합 가드 | 증명되지 않은 복구로 라이브 노드를 파괴하는 것(`scripts/dr-drill.sh:6-8`). kubeconfig 전환이 첫 kubectl보다 늦으면 남의 아카이브로 증명한 뒤 이 노드를 파괴(`:56-60`). ns만 재설치하는 것은 DR이 아님(`:14`). gitignored 런북의 bats 3건은 한 번도 수집되지 않은 죽은 가드(`tests/gates/test_restore-runbook.bats:4-6`) | 단순화해서 가져옴 | 시나리오 13·10의 검증 형태로 쓸 만하다. VM에서 검증하면(D-12) 파괴 게이트와 bulk 로직이 필요 없다. 복구 순서(git → 최초 자격 → 플랫폼 → DB 복원 → 데이터 대조)는 그대로다 | G 시나리오 13·10, C.6.4 복구 순서. 복구 자산 세부는 저장소 밖 |
| L24 | `scripts/backup-files-data.sh` `tests/gates/{test_backup-files-data,test_files-backup-phase-a}.bats` | files 사용자 데이터를 다른 물리 디스크로 rsync하는 백업과 국면 A 억제 가드 | 같은 디스크의 다른 파티션을 통과시키지 않으려 물리 디스크까지 추적(`scripts/backup-files-data.sh:11-22`). 실측(`systemctl cat`·`is-enabled`, 2026-10-17): `files-data-backup.service`가 옛 사본 경로의 이 스크립트와 옛 kubeconfig를 쓰고 timer는 active·enabled | 버림 | files 데이터는 폐기(C-03). 유닛이 옛 사본에 의존하므로 옛 사본을 옮기기 전에 유닛부터 지운다 | E1 정리 목록(H3 행) |
| L25 | `scripts/backup-local-asset.sh` `tests/test_backup-local-asset.bats` | gitignored 런북을 age로 암호화해 git 밖 매체에 백업 + 신선도 검사 | 로컬 전용 런북은 단일 디스크 단일 사본(`scripts/backup-local-asset.sh:3-4`). 거부하면서 거부 대상 디렉터리를 만들어 빈 디렉터리 8개가 쌓임(`:18-21`) | 버림 | 저장소 밖 자료의 보관은 복구 자산 절차가 정한다. 전용 스크립트는 과하다 | C.6.4: 복구 자산은 NUC 밖 두 곳. D-12가 OS 유지로 확정(사용자 2026-10-18, T05)돼 OS 재설치 전 사전 보존 분기는 쓰이지 않는다 |
| L26 | `scripts/netpol-rehearsal.sh` `tests/test_netpol-rehearsal.bats` | NetworkPolicy 후보를 selfHeal 끄고 라이브에 적용해 보는 리허설 | selfHeal이 라이브 실험을 되돌려 병합 전 검증이 넓은 정책을 시험하게 됨(`scripts/netpol-rehearsal.sh:2-4`, TD:216). 잘못된 클러스터에서 돌면 그쪽 정책을 갈아엎음(`:11-15`) | 버림 | 라이브를 잠깐 바꾸는 리허설은 단일 노드에서 위험이 크다. 정책을 공유 차트가 만들면 렌더 검사 + 배포 뒤 접속 확인으로 충분하다(추측: 앱 수가 적어 정책 변형이 드묾) | C.4.5 차트 정책, 시나리오 1의 접속 확인 |

**F. 정적 매니페스트·이미지·권한·CI 공급망 검사**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L27 | `tools/check-image-ownership.ts` `tools/repin-ops-image.ts` `scripts/check-image-pins.sh` `policy/{image-ownership.json,image-pin-allowlist.txt}` `tests/test_pg-image-pin.bats` `tests/gates/{test_image_pins,test_image-ownership,test_pgtools-digest,test_ops-repin}.bats` `tests/gates/image-pin-liveness.sh` | 이미지 digest 핀 형식 게이트, 이미지별 갱신 주체 회계(무소유 11건), ops 이미지 일괄 재핀, PG 3-이미지 정합, 핀 생존 검사 | 접두만 재서 `sha256:deadbeef`가 핀으로 통과(`scripts/check-image-pins.sh:9-11`). 한 이미지가 두 digest로 갈렸는데 둘 다 통과(2026-07-28, `tools/README.md:846-849`). 재핀 대상 하드코딩으로 2곳이 낡은 digest(`:433-438`). 상류 태그 재푸시로 핀이 404, 모든 PR gate red(2026-08-18, `tests/gates/image-pin-liveness.sh:4-5`) | 단순화해서 가져옴 | 태그 대신 digest는 design-prompt §5 요구이고 형식 검사는 싸다. 갱신 주체를 "앱 이미지 = 배포 App, 그 밖 = Renovate" 둘로 고정하면 회계 원장이 필요 없다 | C.4.4, C.4.6: digest 형식 검사 1개(`sha256:` + 64자). 생존 검사와 소유권 원장은 두지 않음 |
| L28 | `tools/check-resource-limits.ts` `policy/memory-limit-allowlist.txt` `tests/test_resource_limits.bats` | 상주 워크로드 cpu·memory request + memory limit + `GOMEMLIMIT ≤ limit×0.95` 강제, 면제 목록 | vector OOM(PR #85) 포스트모템(`policy/memory-limit-allowlist.txt:1`). 파일 프리필터를 함께 넓히지 않아 kind 추가가 공허 통과(`docs/traps.md:114`) | 단순화해서 가져옴 | 단일 노드에서 한 파드의 무제한 메모리는 전체 장애다. 앱은 공유 차트 기본값으로, 플랫폼은 렌더 결과 검사 하나로 막는다 | C.4.5 차트 기본 requests·limits, C.4.6 렌더 검사(limit 누락 거부, 대상 0건이면 실패) |
| L29 | `scripts/check-app-netpol.sh` `tests/test_app_netpol.bats` | 앱 NetworkPolicy가 차트 인스턴스 라벨로 범위를 한정하는지 검사 | 가드가 차트가 내지 않는 키를 강제해, 가드를 따른 정책이 아무 파드도 고르지 못함(2026-09-03, `scripts/check-app-netpol.sh:9-11`). 공유 ns에서 빈 셀렉터는 무관 앱에 영향(`:2-3`) | 단순화해서 가져옴 | 앱이 정책을 직접 쓰지 않고 공유 차트가 만들면 셀렉터 불일치가 구조적으로 없다. 앱마다 ns를 나누면 빈 셀렉터 위험도 줄어든다 | C.4.5 차트 정책 템플릿과 렌더 시험 |
| L30 | `tests/gates/test_rbac-verbs.bats` | 손으로 쓴 Role·ClusterRole의 verb가 읽기 집합 안인지, roleRef 우회가 없는지 | 관측 ClusterRole에 전역 `delete`를 더해도 required gate가 2,672 ok로 통과(2026-09-03, `tests/gates/test_rbac-verbs.bats:8-12`). roleRef를 cluster-admin으로 바꿔도 통과(`:4-6`) | 가져옴 | 봇 V1~V3은 운영 읽기 전용(C-08)이고 봇용 읽기 계정은 플랫폼이 만든다. 읽기 전용 약속을 매니페스트에서 지키는 가장 싼 장치다 | C.4.6: 라벨 `homelab.ukyi.app/readonly`가 붙은 Role의 verb 허용 목록(get, list, watch) + roleRef 검사. C.8 준비 확인에 `kubectl auth can-i` 음성 확인 |
| L31 | `scripts/check-argocd-revision.sh` `tests/gates/{test_argocd-revision,test_dual-run-excludes,test_make-ops-targets}.bats` | 자기 저장소를 가리키는 Argo CD 참조(15곳)의 revision 일치 + main 고정, 병행 운용 divergence 감지, 운영 타깃의 클러스터 정체성 프리플라이트 | 마이그레이션 브랜치 revision을 남긴 채 main에 병합하면 라이브 Argo CD가 죽은 브랜치를 따라감(Application 23개 동시 표류). ApplicationSet git 생성기는 키가 `revision`이라 빠뜨리기 쉬움(`scripts/check-argocd-revision.sh:6-10`). 두 클러스터가 같은 터널 토큰과 healthchecks 체크를 오염(2026-08-17, `tests/gates/test_dual-run-excludes.bats:2-11`) | 가져옴 | 지금 상황이 정확히 이 모양이다(새 작업은 `rebuild`). rebuild를 main에 병합할 때 revision이 `rebuild`로 남으면 같은 사고가 난다. 검사 비용이 매우 싸다 | C.4.6: CI 검사 "자기 저장소 참조는 모두 `main`(차트는 태그)". 옛·새 환경이 같은 외부 자원을 동시에 쓰지 않게 E1·E4 순서와 VM 격리(D-12) |
| L32 | `tests/test_backend-drift.bats` `tests/gates/{test_iac-destroy-guard,test_cloudflare-entitlement}.bats` | Terraform backend 사본 일치, iac apply의 destroy 가드, Cloudflare Free entitlement 정적 검사 | backend 사본이 갈리면 거짓 SSOT(`tests/test_backend-drift.bats:2-3`). Free에서 안 되는 값은 apply 때 400으로만 드러남(`tests/gates/test_cloudflare-entitlement.bats:2-4`). merge → apply 경로는 destroy 가드를 거쳐야 했음(`tests/gates/test_iac-destroy-guard.bats:2-3`) | 단순화해서 가져옴 | 새 root는 옛 키를 쓰지 않아야 하고 Free 제약은 그대로다. 무인 apply가 없으면 destroy 가드는 사람의 plan 확인으로 대체된다 | C.3.9: `terraform fmt`·`validate`(CI)와 사람이 보는 plan. GitHub root는 래퍼가 plan의 delete를 `--allow-destroy` 없이 막는다. Free 제약은 코드 주석 |
| L33 | `tests/gates/{test_action-pinning,test_actionlint-gate,test_app-token-sha-ssot,test_ci-toolchain-pin,test_gitleaks-version-extract,test_setup-bun,test_setup-toolchain-composite,test_toolchain-checksums,test_workflow-yaml,test_renovate,test_ci-build}.bats` | CI 공급망·툴체인 고정: 액션 SHA 핀, actionlint 핀, App 토큰 액션 SHA 단일화, 툴체인 버전·SHA256, bun 핀, YAML 파싱, Renovate 불변식, arm64·QEMU 순서 | 무핀 helm(latest)이 major 변경으로 유일한 필수 검사를 막는 시한폭탄(`tests/gates/test_ci-toolchain-pin.bats:2-3`). App 토큰 액션 핀이 갈리면 개인 키를 변조 액션에 넘김(`tests/gates/test_app-token-sha-ssot.bats:2-3`, TD:406-409). 따옴표 없는 스텝 이름의 콜론으로 이미지 갱신 경로 전체 불능(`tests/gates/test_workflow-yaml.bats:2-4`). TLS만 믿으면 미러 침해 때 변조 바이너리(`tests/gates/test_toolchain-checksums.bats:2-3`). QEMU amd64 leg의 bun이 release를 6시간 태움(`docs/traps.md:107`) | 단순화해서 가져옴 | 공급망 핀은 public 저장소에서 계속 필요하다. bats 11개로 지키던 것을 actionlint + "`uses`는 40자 SHA" 검사 + 툴체인 설치 한 곳으로 줄인다 | C.4.6: actionlint, 액션 SHA 핀 검사, 툴체인 설치 스텝(버전·sha256), 모든 job에 `timeout-minutes` |

**G. 관측·알림 검사**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L34 | `tests/gates/{alertmanager-render-e2e.sh,mock-telegram.py,test_alertmanager-template.bats,test_telegram-alert-korean.bats,test_telegram-callsites.bats,test_telegram-notify.bats,test_telegram-source-enum.bats,test_build-notify.bats,test_restore-drill-notify.bats}` | Alertmanager Telegram 템플릿 컨테이너 렌더 e2e, Telegram 호출처 계약, 알림 문구 한국어화, 빌드·복원 드릴 알림 | amtool은 inline Go 템플릿을 컴파일하지 않아 렌더 e2e가 유일한 증거(`tests/gates/alertmanager-render-e2e.sh:4`). Telegram 자동 HTML escape 위에 이중 escape 금지(`docs/traps.md:41`). enum 밖 source로 exit 2 침묵(`tests/gates/test_telegram-source-enum.bats:3`). 손 로스터가 5번째 룰 파일을 빠뜨림(`tests/gates/test_telegram-alert-korean.bats:5`) | 단순화해서 가져옴 | 비AI 알림이 실제로 사람에게 닿는지는 시나리오 16이 요구한다. 템플릿을 기본값 + 짧은 제목으로 두면 렌더 e2e 대신 시험 경보 1회로 확인된다 | C.3.7 비AI 알림, 시나리오 16 |
| L35 | `tests/gates/vmalert-*` `tests/gates/fixtures/` `tests/gates/lib/` `tests/gates/{test_vmalert-config,test_vmalert-e2e-port-allocation,test_vmalert-e2e-replay-timing,test_vme-scenario,test_host-ports,test_cronjob-flapping}.bats` `scripts/check-host-ports.sh` `tools/fixture-memory-ratios.ts` | vmalert 룰이 "실제로 발화하는가"를 replay로 증명하는 e2e 9계열(19파일)과 하네스, 포트·지연 계약, reload 설정 검사, CronJob 실패 집계 검사 | 문법은 맞는데 라이브 발화 0인 룰이 두 번(ImageDigestDrift 60일, 원인은 push 주기 > 룩백, `tests/gates/vmalert-drift-firing-e2e.sh:3-5`, TD:526). `configCheckInterval`이 없으면 옛 룰 평가(`tests/gates/test_vmalert-config.bats:3`). `failedJobsHistoryLimit`가 N 미만이면 "N회 실패" 알림을 못 셈(`tests/gates/test_cronjob-flapping.bats:5`). 메모리 알림 분자가 working_set이라 캐시를 압력으로 셈(`tests/gates/vmalert-memory-nearlimit-firing-e2e.sh:5`) | 단순화해서 가져옴 | "죽은 알림"은 실제 위험이지만 9계열 e2e는 룰을 많이 직접 쓴 비용이다. 룰을 최소로 두고 표준 단위 시험으로 발화를 확인한다 | C.3.7 룰 단위 시험(`vmalert-tool unittest`) [미검증: 도구 형식, E4에서 확인], C.4.6 |
| L36 | `tools/check-alert-rules.ts` `tests/test_alert_rules.bats` `policy/{alert-instance-stability-allowlist.txt,alert-instance-stability-denylist.txt,alert-supply-monotonicity.json}` | vmalert 룰 eval-time 안티패턴 정적 lint(모드 A~D)와 면제·강제 목록 | 재부팅 IP churn으로 오탐 4회 재발(PR #327), push 주기 > 룩백으로 죽은 알림 2건(PR #339, #341)(`tests/test_alert_rules.bats:2-5`). GitHub API가 낡은 스냅샷을 200으로 돌려줘 역행 샘플로 오발화(TD:1355) | 버림 | 1,219줄 lint와 정책 3파일은 룰을 많이 쓴 결과다. 룰 수 축소와 단위 시험(L35)으로 더 싸게 막는다 | B.8 룰 작성 규칙(push 메트릭은 `*_over_time`, instance 라벨은 재부팅에 바뀜) |
| L37 | `tools/check-workflow-readiness.ts` `policy/workflow-readiness.json` `tests/gates/{test_workflow-readiness,test_gha-liveness-exporter}.bats` | 자격 부재로 job이 통째로 skip됐는데 run은 초록인 경로의 회계, 스케줄 워크플로 run 소실 하트비트 exporter | 스텝 레벨로 게이트된 job은 스텝이 전부 skip돼도 success라 tf-reconcile 드리프트 감시 2개가 한 번도 실행되지 않은 채 30분마다 초록(2026-07-27, `policy/workflow-readiness.json:7-9`). GitHub 60일 스케줄 자동 비활성화(`tests/gates/test_gha-liveness-exporter.bats:4-5`) | 단순화해서 가져옴 | 스케줄 자동화가 조용히 멈추는 위험은 남는다(C-06이 실례). 새 구조는 스케줄 워크플로를 두지 않고, 필수 자격이 없으면 skip이 아니라 실패하게 쓴다. 주기 작업(백업)은 실패 경보로 본다 | C.4.6 워크플로 작성 규칙, C.3.7 백업 신선도 경보 |
| L38 | `tools/check-disk-caps.ts` `tests/gates/{test_disk-caps,test_vector-metrics,test_grafana-dashboards}.bats` `tests/gates/vector-validate.sh` | 관측 스택 설정 정합: 자기 데이터 상한 ≤ 볼륨, vector 메트릭·설정 검증, Grafana 대시보드 지표 검사 | VictoriaLogs가 15GB / 10Gi = 139.7%였는데 전 게이트 초록, GB와 Gi를 접미사로만 보면 반대로 읽힘(`tools/README.md:887-890`). 대시보드 검증 0건(`tests/gates/test_grafana-dashboards.bats:2`) | 버림 | 옛 관측 스택 전용 검사다. 보존 용량 < PVC 같은 값은 values에 직접 적고 단위 함정은 주석으로 남긴다 | C.3.7 values 주석 |

**H. 호스트 신호**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L39 | `scripts/{notify-unit-failure,sweep-systemd-failures}.sh` `tests/gates/{test_unit-failure-notify,test_systemd-failed-sweep}.bats` | 호스트 systemd 실패 신호: `OnFailure=` textfile 기록, 5분 타이머 전역 failed 스윕 + 하트비트 | 호스트 oneshot이 실패해도 울 채널이 0개(`scripts/notify-unit-failure.sh:5-8`). 로드된 서비스 64건 중 `OnFailure=` 3건(`scripts/sweep-systemd-failures.sh:4-7`). `Restart=always` 유닛(k3s)은 failed에 안 들어가는 사각(`:13-17`). 실측(2026-10-17): 두 유닛이 옛 사본 경로의 `scripts/`를 실행하고 스윕 timer는 active·enabled | 단순화해서 가져옴 | 단일 서버에서 호스트 축 장애 신호는 필요하다(시나리오 12). node-exporter의 systemd 수집 한 가지로 줄이고, k3s 같은 `Restart=always` 유닛은 외부 생존 감시가 맡는다 | C.3.7 호스트 축 + 외부 생존 감시. 옛 유닛은 E1에서 옛 사본보다 먼저 지움(H3 행) |

**I. 검사 체계 자체 (조사 항목 7)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L40 | `scripts/{run-bats,check-bats-accounting,check-bats-fd0,check-bats-style,check-locale-collation,check-sigpipe-writers,check-skeleton}.sh` `tests/.ci-exclude` `tests/.gate-serial` `tests/gates/{test_absence-assertion-witness,test_bats-accounting,test_bats-fd0,test_bats-naming,test_bats-style,test_check-skeleton-cjk,test_check-skeleton-floors,test_check-skeleton-gate,test_locale-collation,test_run-bats,test_shell-bash32-traps,test_sigpipe-writers}.bats` | bats 단일 수집·병렬 실행기와 그 위생 가드(도메인 배정, CI 제외 상한, 직렬 레인, fd 0, 단언 스타일, 로케일, SIGPIPE, 스켈레톤, CJK 이름, bash 3.2) | gate 208건 중 81건을 CI 제외로 옮겨도 모든 가드가 초록(2026-07-30, `scripts/check-bats-accounting.sh:11-14`). bats 중간 `[[ ]]`·`!` 단언이 거짓인데 ok(`scripts/check-bats-style.sh:2-8`). en_US `sort -u`가 `-1`과 `1`을 같다고 봄(`scripts/check-locale-collation.sh:4-12`). 스텁 `cat`이 stdin에서 영구 대기(`scripts/check-bats-fd0.sh:4-9`). `grep -q`가 SIGPIPE로 거짓 FAIL(`scripts/check-sigpipe-writers.sh:5-10`). 한글 @test 이름 침묵 스킵(TD:1810). 병렬 실행이 남의 가드를 red로(`tests/.gate-serial:3-4`) | 버림 | 전부 "검사 3,598개를 bats로 유지"한 선택의 2차 비용이다. 표준 도구 위주로 검사를 줄이면 대상이 없다. 원칙 둘만 남긴다: "검사 대상 0건이면 실패", "로컬과 CI가 같은 명령" | C.4.6: CI 진입점 하나. 셸 함정은 B.8 |
| L41 | `scripts/{check-floor-vocab,check-scan-producers,check-skip-signalling}.sh` `scripts/lib/` `tools/check-guard-authority.ts` `tests/gates/{test_floor-vocab,test_guard-sh,test_guard-skip-signalling,test_scan-floor,test_guard-authority}.bats` | 가드의 가드: 열거 붕괴 바닥값 커널, skip 신호 규약, 어휘 재유입 거부, 가드 실행 경로 계산 | 프로세스 치환이 열거자 실패를 전파하지 않아 "0건 검사, 위반 0"(`scripts/lib/scan-floor.sh:6-9`). 아무것도 평가 못 한 가드가 "통과"와 같은 exit 0(`tests/gates/test_guard-skip-signalling.bats:5`). 등재됐는데 CI에서 한 번도 안 도는 가드(`tests/gates/test_guard-authority.bats:4`) | 버림 | 직접 쓴 가드가 수십 개라 생긴 문제다. 가드를 몇 개로 줄이면 실제로 돌았는지 CI 로그에서 바로 보인다 | 없음. 원칙은 L40에 흡수 |
| L42 | `tools/check-ci-parity.ts` `policy/ci-parity.json` `tests/test_makefile.bats` `tests/gates/{test_make-ci-parity,test_ci-gate,test_ci-blocking-comment,test_make-help,test_make-runbooks}.bats` | `just ci`와 CI `gate` 스텝의 패리티 원장(26스텝), gate 구조 검사, just 목록 검사 | gate 스텝 19건 중 8건이 `just ci`에 없었는데 하드코딩 검사는 초록(`tools/README.md:879-882`). `ci.yaml` `run:` 3줄을 주석 처리해도 3/3 초록(`tests/gates/test_ci-gate.bats:4-5`) | 단순화해서 가져옴 | 로컬에서 CI를 재현하는 가치는 있다. CI가 로컬과 같은 단일 명령을 그대로 부르면 패리티 원장이 필요 없다. 필수 검사 하나 원칙은 유지 | C.4.6: 필수 검사 `ci` 하나가 `bun run ci` 하나를 실행 |
| L43 | `scripts/{check-doc-index,verify-traps,verify-runbook-index}.sh` `tools/README.md` `scripts/README.md` `tests/gates/{test_check-doc-index,test_traps-sync,test_verify-traps,test_verify-runbook-index}.bats` | 손으로 쓴 인덱스와 드리프트 가드: tools·scripts README(1,011줄·266줄), 함정 원장 3종 대조, 런북 인덱스 대조 | scripts README의 "CI 게이트" 절 26개 중 12곳이 틀리고 4곳이 비었음(2026-08-29, `scripts/README.md:8-12`). 함정 원장 9행이 근거 없이 enforced를 주장(`docs/traps.md:12-14`). "손으로 적은 사본은 반드시 드리프트한다"(`tools/README.md:7-8`) | 버림 | 문서를 가드로 지키는 비용이 문서의 가치보다 컸다. CLI `--help`와 짧은 README, 함정은 설정 옆 주석으로 둔다 | C.7 `--help`, B.8이 함정 목록을 이어받음 |
| L44 | `tools/ledger-to-json.ts` `scripts/verify-ledger.sh` `policy/ledger.rego` `tests/test_ledger.bats` `tests/gates/test_verify-ledger-ssot.bats` | 메모리 원장 표 → JSON → conftest(합계 ≤ 10240Mi) | 행 파서가 0행을 내면 예산 검사가 통째로 공허(`policy/ledger.rego:6-14`). 서브쿼리 step이 커서 peak를 과소평가하고 그 위에서 깎은 limit 둘이 회귀(`docs/traps.md:111`). 앱 수 0↔1 경계 손 조정(`apps/README.md:28-29`) | 버림 | 손으로 쓰는 원장은 두지 않는다. 노드 메모리 초과는 차트 기본 limit(L28)과 노드 메모리 경보로 막는다 | C.4.5 차트 기본값, C.3.7 노드 메모리 경보 |

**J. 라이브 posture 검사**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L45 | `tests/posture/{test_internal-by-default,test_network-policy,test_networking-e2e}.bats` | 라이브 노출·격리 확인(owner 수동): LoadBalancer는 둘뿐, Argo CD는 webhook 경로만 공개, 관리 UI 비공개, default-deny와 5432 경로, 내부 이름 해석 | 셀렉터가 도메인을 잃으면 "위반 0"과 "아무것도 안 봄"이 같은 초록(`tests/posture/test_internal-by-default.bats:9-15`). restricted ns 프로브 파드 securityContext 필요(`tests/posture/test_network-policy.bats:9-15`). AdGuard가 `*.home`을 Traefik 프록시의 Tailscale IP로 해석하는 LAN 경로(`tests/posture/test_networking-e2e.bats:82`) | 단순화해서 가져옴 | "관리 UI 비공개", "DB는 정해진 ns에서만"은 보안 기능이라 단순화 대상이 아니다. 다만 수동 스위트는 돌린 적 없는 검증이 되기 쉬웠다(L46). 구축 단계 완료 기준으로 옮긴다 | E 완료 기준과 G 시나리오 1, 14, 15의 검증 명령. 외부에서 관리 UI가 안 열리는지 확인 |
| L46 | `tests/posture/test_dr-assets.bats` | DR 자산 신선도: 커밋 cert와 라이브 cert, sealing key 백업과 라이브 키, 런북 백업 | 세 검증이 owner 수동 호출뿐이라 21일간 cert 불일치, 키 백업 낡음, 런북 백업 낡음에 신호가 없었다(2026-09-03, `tests/posture/test_dr-assets.bats:2-5`) | 단순화해서 가져옴 | 대상은 사라지지만 "복구 자산 신선도를 수동 호출로만 재면 아무도 안 잰다"는 교훈은 Infisical 접속 자격에도 그대로다 | C.6.4: 분기 1회 사람 일정 + 시나리오 13 실행 때 자산으로 실제 복구 |
| L47 | `tests/posture/test_storage-reclaim.bats` | bulk StorageClass와 files PV가 라이브에서 Retain인지 | SC를 Retain으로 바꿔도 이미 만든 PV는 생성 시점 정책을 가져 라이브 patch가 따로 필요(`tests/posture/test_storage-reclaim.bats:13`) | 단순화해서 가져옴 | "이미 만든 PV는 SC 변경을 따르지 않는다"는 사실은 CNPG·영속 Valkey PVC 보존(시나리오 9)에 그대로다 | C.5.5: 데이터용 SC는 처음부터 Retain. 시나리오 9 |

**K. 로컬 개발, AIOps, 옛 도구 시험**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| L48 | `tools/{dev.ts,db-url.ts,cache-url.ts}` `tools/dev-postgres/` | 로컬 개발: docker Postgres, 클러스터 DB·캐시 접속 URL을 `.env.local`에 기록 | 접두 없는 `5432:5432`가 NUC LAN 전체에 dev DB를 엶(`tools/dev-postgres/compose.yaml:10-14`). 로컬과 클러스터의 변수명이 달라짐(`tools/README.md:984-988`). Valkey tailnet 상시 노출은 보류, port-forward 기본(`:1007-1008`) | 단순화해서 가져옴 | design-prompt §7은 로컬 개발에 Infisical CLI로 개발용 값을 주라고 한다. 운영 DB 자격을 로컬 파일에 쓰는 모드는 줄인다 | D-21 템플릿의 로컬 compose(`127.0.0.1:` 접두) + `infisical run --env=dev`. 운영 DB 조회는 port-forward |
| L49 | `tools/{aiops-observation.ts,aiops-producers-v1.json}` | AIOps 파일럿의 관측 기록기와 생산자 계약 | 검사 코드 출처와 제안 revision 분리(`tools/README.md:826-829`). AIOps 실패가 deadman으로 발화(`tests/gates/vmalert-webhook-firing-e2e.sh:3`) | 버림 | AIOps는 범위 밖. 격리 교훈만 봇 자리에 쓴다 | C.8 격리 공간·경보 외부 수신자 |
| L50 | `tools/tests/` | 옛 tools의 단위·계약 시험 118파일(bats 86, `@test` 1,371). PATH 스텁 + argv 원장으로 외부 명령 호출을 단언 | 원장 기법이 막은 것: 변이 명령의 숨은 호출, 평문이 argv에 실리는 것(`tools/README.md:256-258`), gh jq 필터 드리프트(`:236-240`) | 단순화해서 가져옴 | 시험 자체는 옛 도구와 함께 버린다. 기법 하나는 새 CLI에 맞다: `plan`의 부수효과 0을 외부 명령 argv 기록으로 증명(AC-P13) | C.7: `plan` 실행 중 쓰기 명령 0건 단언 시험 |

### B.3 `docs/` · `.github/` · 루트 파일 · `.claude/` (45행)

`.claude/`를 표에 넣을지: **넣는다.** 옛 저장소는 에이전트가 운영 자격 근처에서 작업했고, `.claude/hooks/`가 SOPS 파일 직접 편집을 막는 유일한 자동 차단선이었다(`.claude/hooks/manifest-guard.sh:12-14`). 새 구조도 에이전트 작업을 전제로 하므로(design-prompt 서두) 가져갈지 판단이 필요하다.

**`docs/` (9행)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| R01 | `docs/traps.md` | 가드로 강제된 함정만 추적하는 원장(약 95행)과 그 대조 스크립트 | 가드 파일이 지워지거나 이름이 바뀌었는데 함정이 다시 물리는 드리프트. 도입 때 9행이 근거 없이 enforced를 주장(`docs/traps.md:11-12`), 인덱스 4줄 불일치(`:15-16`) | 버림 | 막은 것은 문서와 가드의 불일치이지 운영 사고가 아니다. 수동 원장은 두지 않는다 | 없음. 함정 설명은 설정 옆 주석과 B.8 |
| R02 | `docs/traps-detail.md` | 라이브에서 검증된 함정 121개의 SSOT(2,528줄) | 각 절이 실측 사고다. 예: 콜드스타트 sync-wave 교착 17시간(TD:9), selfHeal이 라이브 실험을 약 5초 만에 되돌림(TD:216), 노드 이름 해석이 tailnet 경유로 클러스터에 의존(TD:1139), QEMU amd64 bun으로 릴리스 6시간 타임아웃(TD:1948) | 단순화해서 가져옴 | 함정 내용의 상당수는 새 스택에도 그대로다. SSOT·인덱스·원장 삼중 구조와 검사 체계 자체의 함정 약 30개는 대상이 없다 | B.8(새 스택에 남는 것만), 구현 때 해당 설정 옆 주석 |
| R03 | `docs/bespoke-component-checklist.md` | 공유 차트 밖 컴포넌트를 손복제할 때의 최소셋(ns·PSA·Prune, securityContext, netpol, 공개 host, 이미지 핀, 원장·알림) | 항목마다 라이브 함정에 대응(`docs/bespoke-component-checklist.md:5`). 예: RWO PVC는 Recreate(`:15-16`), 공개 노출 레지스트리(`:25-26`, TD:493) | 단순화해서 가져옴 | 사람이 체크리스트를 기억하는 방식이 문제였다(4번 손복제, ADR 0004:42-43). 보안 기본값은 실제 사고 방지라 기본값으로 옮긴다 | C.4.5 공유 차트 기본값, C.3.3 플랫폼 ns 기본값. 원장·핀 레인 항목은 버림 |
| R04 | `docs/memory-ledger.md` | 메모리 limit 합계 10240Mi 예산 원장(conftest 게이트) | 노드 OOM 전에 예산 경계에서 실패시키기(`docs/memory-ledger.md:1-4`). 근거가 삭제된 VM 12GiB라 NUC 할당 가능량 61052MiB와 약 5배 어긋났는데 신호가 없었다(`:6-12`). 실제 방어선은 경보였다고 스스로 적음(`:14-15`) | 버림 | 손으로 맞추는 원장이 실제 노드와 어긋난 채 방치됐다 | C.4.5 차트 기본 limit, C.3.7 노드 메모리·OOMKilled 경보 |
| R05 | `docs/decisions/` | 채택한 설계 결정 10개(0001 시크릿 하이브리드 ~ 0010 AIOps 두 저장소)와 README | 결정마다 기각 대안을 남겨 재론을 막음(`docs/decisions/README.md:3-4`). 예: CI가 신뢰 앵커를 apply하면 CI 침해 때 보호를 끌 수 있다(ADR 0002:15-20). PR 코드가 workflow 권한을 높여 요청할 수 있어 Draft·permissions·접두어만으로 안전하다고 판정하지 않는다(ADR 0010:21-23) | 단순화해서 가져옴 | 짧은 결정 기록 형식은 쓸모가 있다. 판정은 결정마다 다르다(B.6). 0002·0003·0010은 새 설계 입력이다 | 새 결정은 spec §5와 이 문서에 남긴다. 별도 ADR 디렉터리는 당분간 두지 않는다 |
| R06 | `docs/adr/` | 아키텍처 리뷰의 기각·유보 기록 7개(verb descriptor, dominance classifier 등) | 같은 후보의 재제안 방지. 예: owner 가드가 실제로 지배하는지 정적으로 증명하려던 시도 5번이 모두 "열거 밖을 안전으로 읽어" 실패(`docs/adr/0002-dominance-classifier-rejected.md:1-20`) | 버림 | 기각 대상이 전부 옛 CLI·가드 체계 내부 구조다 | B.8에 교훈 하나(트리거 열거·`permissions:` 선언으로 특권을 판정하지 않는다) |
| R07 | `docs/agents/` | 에이전트 스킬용 설정 3개(도메인 문서 위치, 로컬 이슈 트래커, triage 라벨) | 사고 방지 장치가 아니라 작업 규약(`docs/agents/issue-tracker.md:3-11`) | 버림 | 새 저장소는 계획·티켓을 `docs/plans/`에 둔다 | 새 `AGENTS.md`(R33) |
| R08 | `docs/aiops.md`, `docs/reviews/` | 옛 AIOps 설치·수용 문서(209줄)와 설계·구현 리뷰 기록(30파일) | 운영 자격 분리와 초안 실행 격리. 역할 5종 분리와 root 발급기(`docs/aiops.md:60-72`, `:91-93`), 운영 시크릿을 main 전용 Environment로 이전(`:96-98`), NUC를 self-hosted runner로 등록하지 않음(`docs/reviews/aiops-codex/input/design.md:267-268`), Draft PR도 CI와 IaC plan을 운영 자격으로 실행하던 사실(`docs/reviews/aiops-codex/input/research.md:282-284`) | 버림 | AIOps 기능은 범위 밖이다. 권한·격리·Draft PR 경계 교훈만 B.8로 옮긴다 | C.8 봇 자리(격리 작업 공간, 봇 변경 PR 자격) |
| R09 | `docs/runbooks-public/` | 공개 런북 2개: `github-ruleset-verify.md`(ruleset 라이브 검증), `toolchain-setup.md` | ruleset CI 가드는 best-effort라 "gate green이 강제 보증이 아니다"(`docs/runbooks-public/github-ruleset-verify.md:7-11`). 거부 코드는 GH013이고 owner·admin에도 암묵 bypass가 없다(TD:582). 도구 핀 사본 문서 드리프트(`docs/runbooks-public/toolchain-setup.md:7-12`) | 단순화해서 가져옴 | 서버 쪽 강제를 실제 거부로 확인하는 절차는 AC-P8과 시나리오 15에 그대로 필요하다. 도구 문서는 "CI 핀의 사본을 문서에 두지 않는다" 교훈만 | G 시나리오 15(허용 주체 성공, 비허용 주체 GH013 거부, bypass 목록 대조). 새 `docs/runbooks-public/`에 bootstrap·restore 문서 |

**`.github/workflows/` (17행, 파일 26개)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| R10 | `.github/workflows/ci.yaml` | `pull_request`·main push, `contents: read`. job `gate` 하나(유일한 필수 검사, 45분, 스텝 약 30개) | 병합 가능 여부를 한 줄로 답하기(ADR 0003:11-21). fork PR 비신뢰 코드의 권한 제한(`.github/workflows/ci.yaml:10-11`). gate가 멈추면 자동 배포까지 멈춤(`:38-40`). 상류 재푸시 GC로 6일에 3번 전 PR red(TD:1840) | 단순화해서 가져옴 | 단일 필수 검사, 최소 권한, 전 job timeout, 명시 bash, 로케일 고정은 싸고 실제 사고를 막았다. 스텝 대부분은 원장·회계·메타 가드다. 외부 상태를 조회하는 검사는 필수 검사에 넣지 않는다 | C.4.6: 새 `ci.yaml`(필수 검사 `ci` 하나) |
| R11 | `.github/workflows/{create-app,_create-app,teardown-app,_teardown-app}.yaml` | 앱 생성·철거 디스패처 + reusable. env `homelab-main`, 직렬화 `homelab-mutation`. reader App이 앱 저장소를 읽고 writer App이 PR. 자동 병합 안 함 | 앱 저장소에 homelab 쓰기 자격 0(`.github/workflows/create-app.yaml:1-3`). 사람 병합 = 첫 배포·공개 승인(`_create-app.yaml:4`). actor만 보던 가드 15사본이 재실행으로 우회 가능(TD:2053, `create-app.yaml:53-57`). 파괴는 confirm + 수동 병합(`_teardown-app.yaml:2`) | 버림 | 디스패처·직렬화 큐·actor 가드 사본은 "Actions 안에서 owner 변이"를 하려고 필요했다. CLI가 사람의 로컬 자격으로 PR을 만들면 층 전체가 필요 없다. 앱 등록은 사람 병합, 파괴는 명시 확인이라는 성질은 유지 | C.7 `app add`·`app remove` |
| R12 | `.github/workflows/{create-database,_create-database,create-cache,_create-cache}.yaml` | DB·캐시 프로비전. 비밀번호를 만들어 즉시 봉인, PR 생성 뒤 **auto-merge 무장**(`_create-database.yaml:125-134`, `_create-cache.yaml:121-130`) | 비신뢰 입력은 env 경유만(`_create-database.yaml:2`), 비밀번호가 로그·PR에 안 나오게(`:3-4`). 자동 병합 근거는 "gate 통과가 리뷰 게이트"였고 AIOps 조사가 "필요한 리뷰 수 0이라 PR-first는 사람 검토 보장이 아니다"라고 지적(`docs/reviews/aiops-codex/input/research.md:49-51`) | 버림 | CNPG 선언형 DB·역할과 Infisical·ESO로 바뀐다. 데이터 리소스 PR의 자동 병합은 D-07(digest PR만)과 충돌한다 | C.7 `db add`·`cache add`(사람 병합) |
| R13 | `.github/workflows/{update-secrets,_update-secrets}.yaml` | 앱 시크릿 갱신: 앱 저장소 봉인본을 읽어 PR, **auto-merge**, checksum 롤링(`_update-secrets.yaml:119-129`, `:3-5`) | envFrom 시크릿 변경은 재시작이 있어야 반영(TD:89). 같은 봉인본 재실행은 같은 해시로 멱등(`:5`) | 버림 | Infisical 원본으로 바뀐다. "Secret 갱신은 환경변수 반영이 아니다" 교훈은 반영 순서 설계에 쓴다 | C.6.5 |
| R14 | `.github/workflows/bump-poll.yaml` | 10분 cron + 수동. GHCR을 폴링해 앱 이미지 bump. reader·writer App, `autoDeploy:true`면 자동 병합, 무장 회수 job. 첫 스텝이 main·저장소 ID·재실행 개시자를 검사(`.github/workflows/bump-poll.yaml:64-72`) | 늦게 끝난 빌드가 최신 배포를 덮음(main 도달 + 배포 SHA의 자손 + digest 검증, `AGENTS.md:217-221`). `autoDeploy`를 끈 뒤에도 남은 무장이 승인 없이 병합(`tools/ensure-bump-pr.ts:129-136`). 같은 커밋에 11분 사이 PR 3개, 좀비 2개(`bump-poll.yaml:276`). 회수 job이 reader 자격에 묶여 skip(`:21-29`) | 단순화해서 가져옴 | 막은 위험(과거 이미지 역행, 승인 우회, 봇 브랜치 위조)은 그대로다. 폴링과 두 App, 회수 job, 직렬화 큐가 복잡함의 핵심이었다. 빌드 직후 digest PR이면 빠진다 | C.4.2, C.4.3, C.4.7: `app-build`의 배포 PR 단계 + `deploy-merge` |
| R15 | `.github/workflows/{build,bump}.yaml` | build: ops 이미지 멀티아치 빌드. bump: build 완료 `workflow_run`에서 writer App으로 PR + **auto-merge**(`.github/workflows/bump.yaml:203-223`) | fork·PR 아티팩트로 write-back PR을 조종하는 것 방지(main, 같은 저장소, 성공만, `bump.yaml:27-33`). digest가 5곳에 인라인돼 부분 갱신 skew(TD:485). 새 기본 브랜치 첫 push는 paths diff가 없어 트리거 스킵(`.github/workflows/build.yaml:9-10`) | 버림 | 플랫폼 자체 ops 이미지를 만들지 않는다. 다른 run의 아티팩트를 받아 PR을 만드는 경로는 공격면이었다 | 없음. 교훈(같은 이미지를 여러 곳에 인라인 핀하지 않음, `workflow_run`은 head 저장소·브랜치 확인)은 B.8 |
| R16 | `.github/workflows/reusable-app-build.yaml` | 외부 앱 저장소가 `@main`으로 호출하는 공개 빌드 계약. PR은 build-only, push면 멀티아치 + GHCR. 권한 미선언, `deploy-trigger`는 늘 skip(`:11-13`), timeout 30분, `provenance: false` | PR에 품질 게이트가 없어 의존성 범프가 병합 뒤 깨짐(`.github/workflows/reusable-app-build.yaml:16-19`). release 6시간 타임아웃(`:58-65`, TD:1948). attestation이 인덱스 digest를 비결정적으로 만들어 배포 회전(`:97-107`). PR 의존성 실행 전 GHCR 로그인은 자격 노출(`:82-85`) | 단순화해서 가져옴 | "앱마다 긴 CI를 복사하지 않는다"의 기존 해법이고 실측 교훈이 많다. `@main` 대신 태그로 호출한다(main 교체 때 4개 저장소가 즉시 깨지는 문제). NUC가 amd64라 amd64 단일 빌드 | C.4.5 `app-build.yaml`(태그 고정). 배포 PR은 기본 브랜치 push에서만 |
| R17 | `.github/workflows/pr-sweeper.yaml` | 30분 cron. writer 봇 PR 중 무장 + BEHIND인 것에 main을 병합해 깨움 | strict 보호 + 비동기 auto-merge에서 두 번째 봇 PR이 BEHIND로 영원히 멈춤(`.github/workflows/pr-sweeper.yaml:1-4`). 충돌로 굳은 무장 잔류(`:138-140`) | 버림 | strict와 자동 병합의 조합이 만든 2차 장치다. 배포 PR은 서로 다른 파일만 바꾸므로 필수 검사의 최신 브랜치 요구(strict)를 끈다 | C.4.7: ruleset A의 strict 끔 |
| R18 | `.github/workflows/renovate.yaml` | 주 1회 cron. self-hosted Renovate가 writer App 토큰으로 org 전체 autodiscover. 자동 병합 없음 | 의존성 PR이 필수 검사를 타려면 `GITHUB_TOKEN`이 아닌 App 토큰 필요(`.github/workflows/renovate.yaml:3-4`). `owner` 없이 토큰을 발급하면 현재 저장소만 발견(`:141-143`, TD:406). github-actions 매니저는 workflows 권한이 없어 꺼 둠(`:5-7`) | 단순화해서 가져옴 | Renovate는 유지 가치가 있고 봇 V1 기능 7의 입력이다(D-18). 그러나 org 전체 갱신을 homelab Actions와 writer 키에 묶어 Actions를 끄자 다른 저장소도 멈췄다(spec §4.5) | F D-18: 호스팅형 Renovate App(저장소별 설치). 자동 병합 금지 유지 |
| R19 | `.github/workflows/iac.yaml` | PR은 자격 없는 validate·mock 시험, main push는 env `homelab-main`에서 Cloudflare plan → **무인 apply** | 커밋된 상태만 apply(`.github/workflows/iac.yaml:9-10`). 예전 PR plan은 PR 코드를 checkout한 뒤 운영 자격을 썼고 Draft도 제외하지 않았다(`docs/reviews/aiops-codex/input/research.md:282-284`) | 단순화해서 가져옴 | PR에 운영 자격을 주지 않는 validate는 가져온다. main push 자동 apply는 손 변경을 되돌린 경로였다. 앱 공개가 Terraform을 타지 않으면 CI apply 이유가 없다 | C.4.6 CI의 fmt·validate. apply는 owner 로컬(`infisical run -- terraform apply`) |
| R20 | `.github/workflows/tf-reconcile.yaml` | 30분 cron. Cloudflare drift면 destroy 가드 뒤 **무인 apply**, github·tailscale은 plan-only 드리프트 알림 | push apply 취소 수렴(`.github/workflows/tf-reconcile.yaml:1-3`), delete·replace 무인 apply 차단(`:168-194`). 그러나 drift job은 시크릿 부재로 스텝이 전부 skip인데 success라 한 번도 실행되지 않은 채 초록(TD:828). 권한 부족이 "삭제됨"으로 보여 알림대로 apply하면 OAuth 클라이언트 중복 생성(TD:1323) | 버림 | 무인 apply가 사람이 콘솔에서 고친 설정을 되돌렸고 드리프트 감시는 실제로 돌지 않았다. 대상이 드물게 바뀐다 | 없음. 주기 plan을 다시 두면 "자격이 없으면 실패"로 |
| R21 | `.github/workflows/{reviewed-plan,ci-authority-probe}.yaml` | AIOps 대비 권한 장치. owner가 검토한 정확한 PR head SHA로 인증 plan, Environment의 main 전용 정책을 공개 표식으로 검사 | 같은 저장소 Draft PR이 workflow를 바꿔 운영 자격을 요청할 수 있다(ADR 0010:21-28). 재실행·head 변경은 새 요청 필요(`.github/workflows/README.md:44-48`) | 버림 | 운영 자격이 필요한 plan을 owner 로컬로 하면 PR 경로에 자격이 없다. 개념 하나만 남긴다: CI 운영 자격은 main 전용 Environment에만 | C.4.8: 병합 App 키는 main 전용 environment에서만 조회 |
| R22 | `.github/workflows/audit.yaml` | 매일 cron. registry·매니페스트·바인딩·원장 사이 정적 드리프트 감사(정보성) | 미완 purge, 참조 없는 리소스 같은 드리프트(`.github/workflows/audit.yaml:1-3`) | 버림 | 감사 대상(`apps.json`, `.bindings.json`, 원장, tombstone)이 없다 | 없음 |
| R23 | `.github/workflows/dns-drift.yaml` | 6시간 cron. 공개 host의 라이브 DNS 해석 확인 | apply 실패로 active인데 DNS가 없는 경우(`.github/workflows/dns-drift.yaml:1-2`) | 버림 | apps.json → Terraform → DNS 경로가 없어진다 | C.7 `status`, 선택 항목인 외부 HTTP 확인(C.3.7) |
| R24 | `.github/workflows/credential-expiry.yaml` | 주 1회 cron. 만료일 원장으로 Telegram 경고 | 자격 만료로 인한 조용한 정지(`.github/workflows/credential-expiry.yaml:1-4`). 실제 원장은 무만료 11개(spec §4.5) | 버림 | 공개 저장소에 자격 인벤토리를 두는 형태라 D-23과 맞지 않고, 손 원장이다 | C.6.4: 자격 원본은 Infisical, 만료가 있는 자격(Universal Auth client secret 등)은 복구 자산 점검 일정에서 확인 |
| R25 | `.github/workflows/contract-drift.yaml` | 주 1회 cron + PR. 봉인 도구·공개 cert 사본이 앱 저장소·템플릿과 같은지 확인 | 앱 저장소의 봉인 도구·cert가 낡아 봉인 실패, 철거된 앱 행이 남아 알림 부풂(`.github/workflows/contract-drift.yaml:1-6`) | 버림 | 사본 계약 자체를 없앤다 | 없음. 앱 저장소·템플릿의 사본 제거는 E10(T22)·D-21 |
| R26 | `.github/workflows/README.md` | 워크플로 인덱스(수동·자동 구분, 직렬화 규약, Environment 공급 규칙) | 무엇이 사람 버튼이고 무엇이 자동인지 혼동. 모든 job에 timeout 필수(`.github/workflows/README.md:7`). `secrets: inherit` 대신 이름만 연결하고, 빈 값 전달 시 값이 도달하지 않음(`:79-84`) | 단순화해서 가져옴 | AC-P8은 자동 병합 조건을 문서로 요구한다. 워크플로가 셋뿐이면 이 README가 그 문서 자리로 맞다 | C.4.7: 새 `.github/workflows/README.md`(트리거·권한·자동 병합 조건) |

**`.github/actions/` · `.github/actionlint.yaml` (6행, 1단계 10개)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| R27 | `.github/actions/pr-first-commit/` | writer App 토큰으로 브랜치 → 커밋 → PR → 선택적 auto-merge. 변이 reusable 5개가 공유 | 5사본 시퀀스 드리프트(`.github/actions/pr-first-commit/action.yml:1-3`). `gh pr merge --auto`는 clean PR에 에러(TD:403), CLEAN일 때만 직접 squash(`scripts/auto-merge-or-fail.sh:2-28`) | 버림 | 변이 reusable과 함께 사라진다. 배포 PR 생성 단계는 짧다 | 교훈: 병합은 필수 검사를 충족한 상태에서만(C.4.7) |
| R28 | `.github/actions/{tf-destroy-guard,tf-r2-init}/` | plan의 delete·replace를 세어 무인 apply 차단, R2 backend 작성 + `init -lockfile=readonly` | 무인 apply의 대량 삭제(`.github/actions/tf-destroy-guard/action.yml:1-3`). state key를 입력으로 받던 시절 짝이 어긋나도 init이 성공해 한 root가 다른 root의 state를 관리할 수 있었다(`.github/actions/tf-r2-init/action.yml:19-23`). actionlint는 composite의 env를 검사하지 않음(`:13`) | 버림 | 무인 apply를 버린다. state key 교훈은 남긴다 | C.3.9 root별 고정 키(새 접두 `v2/`) |
| R29 | `.github/actions/{setup-toolchain,setup-bun}/` | 도구 버전 핀 composite, 모든 다운로드 sha256 검증, bun 1.4.2 핀 | apt arm64 미러 SPOF로 실장애(`.github/workflows/iac.yaml:33-34`). TLS만 믿으면 미러 침해 때 변조(`.github/actions/setup-toolchain/action.yml:2-3`). Renovate가 이 파일에 닿지 못해 수동 회전(`:4-9`). bun 버전 선언 3곳(`.github/actions/setup-bun/action.yml:2-7`) | 단순화해서 가져옴 | 버전 핀 + 체크섬은 싸고 공급망 사고를 막는다. 도구 수를 줄이고 버전을 Renovate가 읽을 수 있는 위치에 둔다 | C.4.6 CI 도구 설치 스텝(버전 + sha256, `.tool-versions` 한 파일) |
| R30 | `.github/actions/{telegram-notify,mutation-notify}/` | CI 실패·변이 결과 Telegram 송신 | 비신뢰 입력 인라인 보간 금지(`.github/actions/telegram-notify/action.yml:4`). CI 쪽 Telegram 토큰이 낡으면 조용한 알림 공백(ADR 0001:71-72) | 버림 | CI 실패는 GitHub 기본 알림으로 충분하다. 운영 경보의 비AI 경로는 Alertmanager가 맡는다. 같은 토큰을 CI에 두면 자격이 흩어진다 | C.3.7. CI에는 알림 자격을 두지 않는다 |
| R31 | `.github/actions/{aiops-observation,aiops-provenance}/` | AIOps 관측 artifact, 검사 코드 출처 SHA 고정 | 제안 커밋 SHA를 main 출처로 보내던 결함(`.github/actions/aiops-provenance/action.yml:9-11`) | 버림 | 범위 밖 | 없음 |
| R32 | `.github/actionlint.yaml` | actionlint 설정. `concurrency.queue` 오탐 1건만 무시 | actionlint v1.7.12가 `queue: max`를 모름(`.github/actionlint.yaml:1-3`) | 버림 | `queue: max` 직렬화를 쓰지 않으면 예외가 필요 없다 | 없음(기본 설정) |

**루트 파일 (11행, 파일 16개)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| R33 | `{AGENTS.md,CLAUDE.md}` | 에이전트·개발자 가이드(지도, 명령, 컨벤션, 함정 한 줄 인덱스 121줄, 멀티 저장소 앱 흐름). `CLAUDE.md`는 `@AGENTS.md` 한 줄 | `*.enc.yaml` 직접 수정 금지(`AGENTS.md:52-53`). App 설치 범위가 org 전체라 "앱 저장소 전용"은 토큰 발급 파라미터로만 성립(`:199-203`) | 단순화해서 가져옴 | 짧은 에이전트 가이드는 "적은 맥락으로 정확하게"에 필요하다. 함정 인덱스와 장치 설명 대부분은 맥락 낭비다 | 새 `AGENTS.md`(지도, 명령, 변경 규칙, 금지 사항) + `CLAUDE.md`(`@AGENTS.md`). E2에서 만든다 |
| R34 | `README.md` | 저장소 소개, 아키텍처, 디렉터리, 명령 | "SSOT는 git, 클러스터 수동 변경 0, 모든 main 변경은 PR + 게이트"(`README.md:3-6`) | 단순화해서 가져옴 | 원칙은 그대로, 내용은 새 구조로 | 새 `README.md`(E2) |
| R35 | `CONTRIBUTING.md` | 황금률 5개와 가드 규약(330줄) | 평문 시크릿 금지, env는 경로에, 앱 이미지 계약(`/health`, 8080, non-root)(`CONTRIBUTING.md:6-25`). 나머지는 가드 체계 자체의 규약 | 단순화해서 가져옴 | 시크릿 금지, 검증 우선, 앱 이미지 계약은 유지 가치가 있다 | `AGENTS.md`에 흡수, 앱 이미지 계약은 D-21 템플릿 |
| R36 | `CONTEXT.md` | 옛 도메인 용어집 | 용어 혼동 방지. "수렴 클래스"는 Argo CD가 수렴시키지 않는 값(첫 부팅 시드, 1회 SQL)에 이름을 붙였다(`CONTEXT.md:259`, ADR 0007:13-17) | 버림 | 용어 대부분이 옛 장치 이름이다 | 개념만: C.2 소유자 표에서 Git 원본과 라이브 원본을 자산별로 선언 |
| R37 | `{package.json,bun.lock,bunfig.toml,tsconfig.json}` | Bun 1.4.2 워크스페이스, `homelab` bin, frozen lockfile, strict TS | 비결정적 설치 방지(`bunfig.toml:1-3`). 런타임 버전 선언 3곳 불일치(`.github/actions/setup-bun/action.yml:2-7`) | 단순화해서 가져옴 | 새 CLI 기본 언어가 Bun·TypeScript다. 잠금 파일, frozen 설치, strict는 그대로 두고 스크립트와 의존성은 새로 | C.7 `cli/` 패키지 설정. bun 버전은 `.tool-versions` 한 곳 |
| R38 | `justfile` | 명령 진입점 40여 개 | 로컬에서 필수 검사 재현(`justfile:158`, ADR 0003). make 함정 때문에 just로 옮김(TD:629, TD:947) | 단순화해서 가져옴 | 진입점 하나는 사람과 에이전트에 도움이 된다. CLI와 레시피가 같은 일을 두 번 감싸면 중복이다 | `package.json` scripts(`ci`, `render`)로 대체하고 justfile은 두지 않는다. 운영 동사는 CLI |
| R39 | `.env.secrets.example` | 로컬 `.env.secrets` 템플릿(155줄). 자격 10여 종의 발급 절차·권한·소비처 | 같은 Cloudflare 토큰이 로컬과 GitHub secret 두 곳에 있어 재발급 때 둘 다 고쳐야 함(`.env.secrets.example:22`). 자격 하나가 여러 평면에 흩어져 회전 때 일부가 낡음(ADR 0001:58-72) | 버림 | 원본이 Infisical로 바뀐다. 자격 목록·발급 절차를 공개 저장소에 두는 형태는 D-23과 맞지 않는다 | C.3.9: Terraform도 `infisical run`으로 자격 주입. 발급 절차는 저장소 밖 |
| R40 | `.sops.yaml` | SOPS 생성 규칙. age recipient 2개(cluster, recovery), 경로별 + catch-all | 컨트롤러 없이 age 키만으로 복호되는 DR 앵커(ADR 0001:15-18). 경로 밖 `*.enc.yaml`도 암호화 보장(`.sops.yaml:40-46`) | 버림 (판정 조정: 조사 메모는 조건부 단순화) | 새 구조는 저장소에 암호화 파일을 두지 않는다. 부트스트랩 자격은 저장소 밖 복구 자산으로 보관한다(C.6.4) | 없음. "복호 앵커는 컨트롤러 밖에 둔다"는 원칙만 C.6.4 |
| R41 | `.gitignore` | 시크릿·키·Terraform·kubeconfig·런북·`.claude` 런타임 무시. 실사고로 추가된 패턴 포함 | `terraform.tfvars.pre-cutover.bak`가 `*.tfvars`에 안 걸려 커밋될 뻔(`.gitignore:19-24`). `backend.hcl` rename 뒤 `git add -A`가 R2 state 자격 3개를 스테이징(`:26-32`). `*_override.tf`로 신뢰 앵커 우회 방지(`:36-39`). 디렉터리 매치가 하위 부정을 무력화(`:63-66`) | 단순화해서 가져옴 | 패턴마다 실제 사고에서 나왔고 비용이 0이다 | 새 `.gitignore`: 접미사 사본(`*.tfvars*`, `backend.hcl*`, `.env*`), override, kubeconfig. E2 |
| R42 | `{.pre-commit-config.yaml,.gitleaks.toml}` | pre-commit(sops-guard, sealed-guard, gitleaks v8.30.1), gitleaks 기본 룰 + 오탐 2곳 룰 범위 면제 | gitleaks 올림에서 오탐 9건(`.gitleaks.toml:2-4`). 파일명만으로 면제하면 평문 Secret을 `*.sealed.yaml` 이름으로 커밋해도 무성(`:11-12`). 오봉인은 구조 문제라 sealed-guard가 덮음(`:13-16`) | 단순화해서 가져옴 | 공개 저장소에서 gitleaks를 필수 검사와 pre-commit 양쪽에 거는 것은 싸고 필요하다. 면제는 경로 + 룰 범위로만 | C.4.6 CI gitleaks + pre-commit 훅. sops·sealed 가드는 대상 없음 |
| R43 | `renovate.json` | 월요일 0~6시, `pinDigests`, 인프라 매니저 자동 병합 금지, github-actions 매니저 비활성, 자기 저장소 git-refs 제외, custom regex 매니저 | 단일 노드라 인프라 의존 자동 병합 금지(`renovate.json:129-132`). 자기 main을 커밋으로 핀하면 연속 sync가 깨짐(`:144-148`). 차트 내부 이미지는 Renovate가 볼 수 없음(TD:867) | 단순화해서 가져옴 | `pinDigests`, 자동 병합 금지, 자기 참조 제외는 유지. regex 매니저는 새 파일 배치에 맞게 다시 쓴다 | F D-18 뒤 새 `renovate.json`. Renovate PR은 자동 병합 조건 밖 |

**`.claude/` (2행, 1단계 3개)**

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| R44 | `.claude/settings.json`, `.claude/hooks/` | PreToolUse 훅(Edit, Write, MultiEdit)이 위험 경로(`*.enc.yaml` 등) 편집을 exit 2로 차단 | `*.enc.yaml`을 한 번 직접 편집하면 SOPS MAC이 깨져 DR 자산을 복호할 수 없다(`.claude/hooks/manifest-guard.sh:12-14`). exit 1은 비차단이라 fail-open이고, jq가 없을 때 rc=0으로 편집을 허용한 실측(`:8-14`, TD:809) | 버림 | 보호 대상(`*.enc.yaml`, SealedSecret)이 새 구조에 없다. 에이전트 훅은 사람과 CI 경로를 막지 못한다. 실제 차단선은 CI 필수 검사(gitleaks, `kind: Secret` 금지)와 서버 쪽 ruleset이다 | 없음. 교훈(PreToolUse의 fail-closed는 exit 2뿐)은 B.8 |
| R45 | `.claude/skills/` | argo, observability 스킬(읽기 전용 진단 절차, just 타깃) | 라이브에 직접 apply해 드리프트·교착(`.claude/skills/argo/SKILL.md:8`), distroless 파드 안 질의 불가(`.claude/skills/observability/SKILL.md:10-12`) | 버림 | 옛 just 타깃, kubeconfig 경로, victoria-stack에 묶였다. 새 스택이 선 뒤 필요하면 새로 쓴다 | 없음. 교훈은 B.8 |

### B.4 호스트 수준 구성 (NUC, 저장소 밖, 9행)

저장소 안의 `infra/k3s-bootstrap/host-config.sh`·`host-config/`·`motd/`는 P05 행이 맡고, 여기서는 그것들이 NUC에 남긴 결과물을 판정한다. D-12가 OS 유지로 확정(사용자 2026-10-18, T05)돼 아래가 모두 남으므로 각각 철거 범위에 넣을지 판정한다. D-12의 철거 범위는 H1·H2·H3·H7·H8·H9다.

**실측 대조** (사실, 2026-10-17, sudo 없이 `systemctl is-active`·`is-enabled`·`list-unit-files`·`cat`, `tailscale dns status`)

| 대상 | is-active | 유닛 파일 | 비고 |
|---|---|---|---|
| `aiops-ingress.service` / `aiops-worker.service` / `aiops-worker.timer` | inactive / inactive / inactive | disabled / static / disabled | drop-in 2개 남음 |
| `homelab-aiops-nft.service` | active(exited) | enabled | ExecStart `/usr/local/libexec/homelab-aiops-ingress-firewall.py apply` |
| `'var-lib-homelab\x2daiops.mount'` | active(mounted) | enabled | loop 이미지 `/var/lib/homelab-aiops.img`. **함정 실측:** 이스케이프 없는 `var-lib-homelab-aiops.mount`로 물으면 `inactive`, 목록 0개가 나와 "이미 없음"으로 오판한다. 작은따옴표 이름이나 `systemctl status /var/lib/homelab-aiops`로 확인한다 |
| `files-data-backup.service` / `.timer` | inactive / **active** | static / enabled | 옛 사본 `~/workspace/homelab/scripts/backup-files-data.sh`와 옛 kubeconfig 사용 |
| `systemd-failed-sweep.service` / `.timer` | inactive / **active** | static / enabled | 옛 사본 스크립트, 5분 주기 |
| `unit-failure-notify@.service` | 템플릿 | static | 옛 사본 스크립트, 인스턴스 4개 loaded |
| `motd-refresh.service` / `.timer` | inactive / **active** | static / enabled | 저장소에 없는 drop-in `10-user.conf`가 있음 |
| `k3s.service` | **active** | enabled | 옛 클러스터 |
| Tailscale DNS 수용 | 해당 없음 | 해당 없음 | "Tailscale DNS: disabled" → `accept-dns=false` 유효 |

확인 불가(허용 경로 밖): nft table 내용, `/opt/homelab-aiops`·`/etc/homelab-aiops` 내용, 시스템 사용자 `aiops-*` 8개, drop-in 파일 내용, fstab 상세. 이것들은 T06 목록과 `2d2054a` 코드 선언을 근거로 판정했다. 파일 이름의 존재는 조사 세션에서 확인했다(0절).

| ID | 경로(glob) | 무엇이었나 | 막으려던 실제 사고 (근거) | 판정 | 판정 이유 | 새 구조에서 맡는 자리 |
|---|---|---|---|---|---|---|
| H1 | NUC: `aiops-ingress.service`, `aiops-worker.{service,timer}`, `homelab-aiops-nft.service`, `'var-lib-homelab\x2daiops.mount'` | 옛 AIOps 파일럿의 호스트 유닛 | 진단 실행기를 클러스터 밖 systemd 작업으로 격리. 역할별 UID, cgroup 한도, 512MiB 전용 파일시스템, 사설 인입 nft 규칙(`docs/aiops.md:79-82`, `:122-131`) | 버림 (철거 범위에 넣음) | 기능이 범위 밖이다. 비활성이어도 mount와 nft 서비스는 active다(실측). nft table과 인입 포트가 새 네트워크와 부딪칠 수 있다(spec §10 11항, 추측) | E1: timer·ingress 비활성 확인 → nft 서비스·table 제거 → mount 해제 → 이미지 파일 삭제. 확인은 이스케이프 이름이나 경로로 |
| H2 | NUC: `/opt/homelab-aiops`, `/etc/homelab-aiops`, `/usr/local/libexec/homelab-aiops-ingress-firewall.py`, `/etc/nftables.d/homelab-aiops.nft`, `aiops-*.service.d/*`, `/etc/tmpfiles.d/homelab-aiops.conf`, 사용자 `aiops-*` 8개와 그룹 `aiops-state` | AIOps 설치물, 설정, App 개인 키, nft 규칙, drop-in, 시스템 사용자 | App 개인 키는 root 0600(`docs/aiops.md:88`), 역할 분리 사용자(`:60-66`), 구독 OAuth는 `aiops-proxy`의 별도 UID(`:71`) | 버림 (철거 범위에 넣음. App 키 폐기는 옛 aiops App 제거와 함께, D-29) | 개인 키와 OAuth가 남은 계정은 폐기되지 않은 자격이다(spec §10 16항 계열) | E1 정리 목록. `/etc/homelab-aiops`의 App 키 폐기는 옛 aiops App 삭제와 함께(D-29, 실행 T22) |
| H3 | NUC: `files-data-backup.{service,timer}`, `systemd-failed-sweep.{service,timer}`, `unit-failure-notify@.service` | 옛 host-config가 깐 유닛. 옛 사본 `~/workspace/homelab/scripts/`를 root로 실행(실측 ExecStart) | files 일일 백업, 실패 스윕(5분), 유닛 실패 통지. `Restart=always` 유닛은 failed가 되지 않아 스윕이 k3s 크래시루프를 못 봄(TD:1611). 유닛에 인라인한 push는 완전성 가드 밖(TD:1468) | 버림 (철거 범위에 넣음) | 옛 사본을 옮기거나 지우면 실패한다(spec §4.5). files 데이터 폐기로 대상이 없다 | E1: 옛 사본 정리 전에 제거. 호스트 실패 감시는 C.3.7(node-exporter systemd 수집) |
| H4 | NUC: `/etc/ssh/sshd_config.d/10-k3s-node.conf`, `/etc/systemd/journald.conf.d/10-k3s-node.conf`, `/etc/tmpfiles.d/10-k3s-node.conf` | SSH 하드닝, 저널 상한 512M, NVMe ASPM L1 끄기 drop-in | sshd는 먼저 읽힌 값이 이겨 `60-`으로 지으면 `50-cloud-init.conf`에 조용히 진다(TD:1104). NVMe correctable 에러 폭주는 열화가 아니라 ASPM L1 유휴 전이(TD:162). journald 상한 미설정이면 4G로 유도(`infra/k3s-bootstrap/host-config/etc/systemd/journald.conf.d/10-k3s-node.conf:3-11`) | 단순화해서 가져옴 | 호스트 설정의 Git 관리는 design-prompt §4 요구다. 셋 다 실측 근거가 있고 작다. OS 유지면 남겨 두고 E2의 새 호스트 설정이 같은 이름으로 덮어쓴다 | C.3.2 `host/etc/` (파일 목록을 명시, 확장자 화이트리스트 열거 없이) |
| H5 | NUC: `/etc/systemd/resolved.conf.d/10-k3s-node.conf`, `/etc/systemd/network/10-netplan-wlo1.network.d/10-k3s-node.conf`, `/etc/resolv.conf`, `tailscale set --accept-dns=false` | 노드 자신의 이름 해석을 공용 DNS로 고정하고 tailnet DNS를 받지 않음(`infra/k3s-bootstrap/host-config.sh:210-224`) | 노드 → 공유기 → 노드 위 AdGuard 순환으로 콜드스타트 때 이름 해석과 이미지 pull이 막힘(spec §4.5). tailscale `~.` 때문에 노드 이름 해석이 클러스터에 의존(TD:1139). networkd reconfigure가 DHCP 리스를 2초 잃음(TD:2404) | 가져옴 | 대체 없이 지우면 순환이 다시 생긴다(spec §4.5). 실측: `Tailscale DNS: disabled` | C.3.2·C.3.6: 새 호스트 설정이 같은 일을 맡는다. E1에서는 지우지 않는다. NUC를 Tailscale에 다시 등록하면 `accept-dns=false`를 다시 건다 |
| H6 | NUC: `/etc/fstab` swap 제거 | host-config가 `swapoff -a`와 fstab swap 항목 제거(`infra/k3s-bootstrap/host-config.sh:191-207`). 실측: fstab에 swap 항목 없음 | 스왑은 OOM으로 죽어야 할 파드를 느리게만 만들어 fail-loud 경계를 무르게 함(`:192-195`) | 단순화해서 가져옴 | "OOM은 빨리 드러나야 한다"는 요지는 그대로 맞다 | C.3.2: preflight가 스왑 없음을 확인 |
| H7 | NUC: `motd-refresh.{service,timer}`, `/etc/update-motd.d/00-ukyi`, `/usr/local/share/ukyi-motd/` | 로그인 MOTD에 k3s 상태 표시, 1분 갱신 | 운영 편의이지 사고 방지가 아니다. 저장소 README는 두 파일만 손으로 설치한다고 적었고(`infra/k3s-bootstrap/motd/README.md:5`, `:33-41`), 실측으로 저장소에 없는 drop-in이 있다 | 버림 (철거 범위에 넣음) | 옛 클러스터 상태를 보여 주는 장치라 철거 뒤 의미가 없다. 1분 timer가 새 클러스터에서 오류를 낼 수 있다(추측) | E1. **범위 조정(사용자 2026-10-19, T06 실측):** 고양이 MOTD는 홈랩과 별개인 로컬 설치(2026-08-07)라 남긴다. `motd-refresh` 유닛·drop-in과 `k3s-status.py`만 지우고 `00-ukyi`를 2026-08-07 원본으로 되돌린다(T06 H7 줄) |
| H8 | NUC: `/var/lib/rancher/k3s-storage`, `/mnt/bulk`, `/var/backups/files-data`, `/var/lib/homelab-aiops.img` | 옛 PV 데이터(AdGuard 라이브 설정 포함), files 데이터 디스크와 fstab 항목, files 백업, AIOps loop 이미지 | `k3s-uninstall.sh`는 `k3s-storage`를 남겨 새 k3s에 옛 데이터가 섞일 수 있다(spec §10 14항, `scripts/destroy-node.sh:117-120`). `findmnt -T`로 마운트 여부를 판정하면 반대 답(TD:1166) | 버림 (철거 범위에 넣음, AdGuard 설정 내보내기 뒤) | 데이터 폐기는 확정(C-02, C-03). AdGuard 라이브 설정은 시드와 다를 수 있어 먼저 내보낸다(ADR 0007:26-29) | E1. `/mnt/bulk`는 비우고 fstab 항목을 지운 뒤 새 구조에서 쓰지 않는다(D-12) |
| H9 | NUC: `k3s.service` | 가동 중인 옛 k3s | 옛 Argo CD가 main을 prune·selfHeal로 따라간다(spec §1) | 버림 (철거) | D-02: T05 뒤, E2 직전 | E1 |

### B.5 원본 프롬프트의 재사용 전제 판정 (공유 차트, ApplicationSet)

원본 프롬프트는 옛 ApplicationSet과 공유 Helm 차트(`platform/charts/app`)의 재사용을 우선했다(design-prompt §3). 두 판정의 이유와 바뀐 조건이다.

| 대상 | 판정 | 옛 구성의 사실 | 바뀐 조건과 이유 [제안] |
|---|---|---|---|
| 공유 차트 `platform/charts/app` | **단순화해서 가져옴** | 앱 하나는 values 한 파일만 가졌다(`platform/argocd/root/appset.yaml:1-4`). 닫힌 schema(`platform/charts/app/values.schema.json:4`), digest 우선(`_helpers.tpl:30-39`), 안전 기본값(`values.yaml:57-77`). 비용: git 경로 `refs/heads/main` 참조라 차트 변경이 모든 앱에 한 번에 적용(`appset.yaml:111-117`, `Chart.yaml:5`). values는 도구 소유라 손 주석이 사라짐(`apps/README.md:30-31`). 닫힌 schema를 넓히지 않아 베스포크 4개와 그 체크리스트가 생김(`docs/bespoke-component-checklist.md:1-39`) | 재사용 가치(복사 방지, 안전 기본값 일괄 적용)는 그대로다. 바꾸는 것: 차트에 git 태그 버전을 붙이고 앱 values가 버전을 고정한다. 차트 변경의 영향은 "그 버전으로 올린 앱"으로 줄고, 버전 올림 PR은 자동 병합 조건 밖이다. 넓히는 것: ExternalSecret 참조, DB·캐시 연결 env, 마이그레이션 Job, 공개 Ingress, 내부 Tailscale Ingress를 선택 항목으로 둔다. 데이터 리소스는 별도 차트 `app-data`로 뺀다(앱 삭제와 수명 분리). values 파일은 사람 소유이고 도구는 처음 한 번만 쓴다 |
| ApplicationSet `apps` | **단순화해서 가져옴** | `apps/*/deploy/prod`를 찾아 차트 + values + 앱 kustomize 다중 source, destination ns `prod` 고정(`appset.yaml:84-138`) | 앱은 수가 늘고 구조가 같아 "디렉터리 하나 = 배포 등록"이 사람의 수정 지점을 줄인다. 바꾸는 것: 앱마다 ns(`app-<이름>`)와 `managedNamespaceMetadata`, 차트 버전 고정, 앱 kustomize source 제거(차트 밖 매니페스트 금지), retry 유지. 같은 형태의 `data` ApplicationSet을 하나 더 둔다 |
| ApplicationSet `platform-components` | **버림** | `platform/*/prod` 디렉터리 생성기, 제외 6개, 공통 syncPolicy(`appset.yaml:14-28`, `:75-82`) | Application 사이 순서가 없고(`SYNC-WAVES.md:7-15`), `destination.namespace`가 없어 CreateNamespace가 무효였고(TD:57-59), syncPolicy를 컴포넌트별로 다르게 못 뒀다(TD:2451-2453). 순서가 필요한 것은 결국 제외 목록과 수동 Application 8개로 빠졌다. 플랫폼 구성 요소는 10여 개이고 순서가 중요해 root 아래 명시 Application(각자 wave, retry, ns)이 더 싸다 |

앱 Application이 플랫폼 구성 요소(CRD, CNPG)보다 먼저 와도 retry로 수렴한다는 옛 실측(`appset.yaml:69-71`)을 전제로 쓴다. 이것은 순서 보장이 아니라 수렴 보장이다. 그래서 완료 조건에는 실제 준비 상태와 접속 확인을 넣는다(G절).

### B.6 옛 결정 기록 판정 (`docs/decisions/`, `docs/adr/`)

| 결정 | 요지 | 판정 | 새 설계 입력 |
|---|---|---|---|
| decisions/0001 | 시크릿 하이브리드(SOPS + SealedSecrets), 부트스트랩 순환 회피 | 버림(C-07) | 부트스트랩 자격은 컨트롤러 없이 꺼낼 수 있는 곳(저장소 밖)에 둔다. 한 자격을 여러 평면에 두지 않는다(ADR 0001:58-72) |
| decisions/0002 | github·tailscale root는 owner 로컬 apply, CI는 plan-only | 가져옴 | 새 GitHub 보호와 Tailscale ACL·DNS는 CI가 적용하지 않는다(ADR 0002:15-20). GitHub root는 CI plan도 하지 않는다(허위 드리프트, D-28). C.3.9 |
| decisions/0003 | 필수 검사는 `gate` 하나 | 가져옴 | 필수 검사 `ci` 하나. 관리자 우회는 남는 위험으로 문서화(ADR 0003:26-30) |
| decisions/0004 | 골든패스를 넓히지 않고 베스포크 유지(소비자 1개면 추상화 안 함) | 단순화해서 가져옴 | "소비자 1개면 공유 차트를 넓히지 않는다". 플랫폼 구성 요소는 공식 차트를 쓴다 |
| decisions/0005 | 데이터 연결을 일반 SealedSecret URL로, refcount 상실과 과권한 자격 감수 | 버림 | CNPG 선언형 + ESO로 앱별 자격을 자동 전달해 두 위험(사용 중 DB 삭제, superuser 봉인)을 다시 막는다. C.5 |
| decisions/0006 | 복구 원본 제거, 아카이브 prefix 고정 | 버림(C-02) | 두 primary가 같은 R2 prefix에 쓰지 않게 serverName에 세대를 넣고, lifecycle 범위를 prefix로 한정한다(ADR 0006:17-19, `:81-88`) |
| decisions/0007 | Argo CD가 수렴시키지 않는 값은 자산별 원본을 선언 | 단순화해서 가져옴 | AdGuard 설정의 원본을 선언한다(C.2, D-08) |
| decisions/0008 | AIOps 첫 권한 경계는 진단과 수정 초안 | 버림(범위 밖) | 봇 V1~V3 읽기 전용(C-08)과 같은 방향 |
| decisions/0009 | 초안은 전용 fork에서 Draft PR | 버림(0010이 대체) | B.8 |
| decisions/0010 | 운영 자격을 main 전용 Environment로, main 반영 주체 서버 제한, Draft만으로 안전 판정 금지 | 단순화해서 가져옴 | AC-P8과 봇 변경 PR 신원(D-24) 설계. C.4.7, C.8 |
| adr/0001~0007 | 옛 CLI·가드 체계 구조 후보의 기각·유보 | 버림 | adr/0002의 "트리거 열거·`permissions:` 선언으로 특권을 판정하지 않는다"만 B.8 |

### B.7 조사 항목 1~9 요약

| # | 옛 구성 (사실, 근거 행) | 새 구조 [제안] |
|---|---|---|
| 1 신규 앱 등록·첫 배포 | 공식 순서 8단계(`tools/README.md:46-55`): `bun link` → doctor → `app init` → 앱 저장소에서 `.env` 봉인·push → (DB면) `db create --wait` → `app create --wait`(PR, 사람 병합) → status. 디스패처 → reusable → 도구 → PR → gate(약 11분) → 병합 → Argo CD. 한 번 등록이 표면 8곳을 바꿨고(`tools/README.md:305-310`), DB 연결은 `values.yaml` envFrom 손 편집이 유일한 경로였다(`:63-66`). 실측 `db create` 약 15분, 첫 실행 46분(`:71-76`). L01, L03, R11 | `homelab app new`(템플릿에서 저장소) → 앱 main push(첫 이미지) → `homelab app add`(PR 1개, 사람 승인) → Argo CD. DB가 필요하면 `homelab db add`가 같은 방식의 PR 하나로 데이터 선언과 앱 연결을 함께 쓴다. D절 |
| 2 반복 배포·자동 병합 | GHCR 10분 폴링(실측 60~90분 지연), `autoDeploy`면 writer App이 무장, 아니면 승인 PR. 자동 병합되던 PR은 5종(앱 bump, ops 이미지, DB 생성, 캐시 생성, 시크릿 갱신)이었고 서버는 "누가"(push 허용 목록, writer 전용 ruleset)만 강제했다. 필요 리뷰 0, `enforce_admins=false`(실측). L06, L07, R12~R14 | 빌드 직후 digest PR. 자동 병합은 한 종류(배포 App의 한 앱 digest PR)뿐이고 서버가 "누가·어느 브랜치"를, main 코드의 병합 워크플로가 "무엇을·출처·순서"를 검사한다. C.4 |
| 3 중복 선언과 소유자 | kind·resources·route는 앱 `.app-config.yml`과 homelab values 두 곳(권위는 homelab), `autoDeploy` 두 곳, 공개 host는 values와 `apps.json` 두 곳, DB 연결은 봉인본 + 손 배선, Telegram 토큰은 4평면(`docs/decisions/0001-secret-management-hybrid.md:62-72`). P11, L04, R39 | 배포 설정은 homelab `apps/<app>/values.yaml` 한 곳, 시크릿 값은 Infisical 한 곳, 앱 저장소는 코드·Dockerfile·짧은 워크플로 호출만. C.2 소유자 표 |
| 4 DB·Valkey 생성과 연결 | 논리 DB + owner·ro role + 봉인 4개 + 헤지 목록(`tools/provision-db.ts:4-21`). Valkey는 앱별 Deployment·PVC·ACL 봉인 + 메모리 원장(`tools/provision-cache.ts:1-12`). 연결은 손 envFrom. 앱은 부팅 때 self-migrate(`tools/README.md:26-38`). L10, P09, P13 | `Database`·`DatabaseRole` CR + ESO 사본 둘(DB ns의 basic-auth, 앱 ns의 URL) + 공식 Valkey 차트. 연결은 차트가 env로 자동 배선. 마이그레이션은 Sync hook Job(D-22). C.5 |
| 5 시크릿 생성·전달·변경·복구 | 두 채널(SOPS 9파일, SealedSecret 10파일). 생성은 `seed-secrets.sh`, 복구 앵커는 age 키와 sealing key 백업. 회전은 모든 평면을 다시 만듦. 재구축 직후 새 sealing key가 21일 무백업. L15, L19, P20, R40 | Infisical 원본 → ESO 사본. 부트스트랩 자격 하나만 저장소 밖 복구 자산. 회전 4단계를 CLI가 순서대로. C.6 |
| 6 앱 삭제의 영향 | 앱 철거는 앱 표면만 지우고 DB·캐시는 비접촉. 데이터 철거는 retain 기본 + purge 4단계 + 증거 id. 마지막 리소스 prune 거부, passwordStatus 잔존, Retain PV 잔존(TD:1098-1099). L11, L12, P14 | 앱과 데이터를 다른 Application으로. reclaim `retain` + `Prune=false,Delete=false`. 폐기는 `data purge` 단계 PR. C.5.5 |
| 7 전역 검사·드리프트·원장 | 수동 원장 9종, 드리프트 감지 8종, 메타 가드 5종. 반복된 모양: "손 사본 → 드리프트 → 가드 → 가드가 공허 통과 → 가드의 가드". 실제 사고에 근거한 검사는 11종(자동 병합 gate 우회, 부분 PR, 평문 시크릿, 죽은 브랜치 추종, 과거 이미지, RBAC 무력화, 무핀 툴체인, 죽은 알림, 스케줄 소실, 메모리 고갈, 옛 PV 부활). L40~L44, R01, R22~R25 | 실제 사고 근거가 있는 검사 10개 안팎만, 표준 도구 우선, 대상 0건이면 실패, 로컬과 CI 같은 명령. 수동 원장 0. 서버 쪽 강제는 `gh api`로 실제 설정 대조. C.4.6 |
| 8 기반 구성 운영 함정 | B.8 | B.8의 대응 열 |
| 9 옛 공통 자산에 기대는 저장소 | `page`·`trip-mate-api`·`files`·`aiops-autodeploy-canary`가 reusable@main 호출, template은 main 스키마 주간 받기 + scaffold 심기 + 봉인 도구 사본. `aiops`·`mac-uptime-guard`는 의존 없음(0절). R16, L04, L15 | 새 공통 워크플로는 태그로 호출하고 스키마는 차트 안에 둔다(앱 저장소가 homelab main을 읽지 않음). 재연결은 E10(T22. 남는 앱 저장소는 `files`이고 `page`·`trip-mate-api`는 2026-10-18 삭제, D-29), template은 D-21, `aiops` 저장소·App과 `mac-uptime-guard`는 삭제하고 `aiops-autodeploy-canary`는 private 보관(D-29, T22) |

### B.8 새 구조에 남는 실측 함정

세 조사 묶음의 함정 목록(옛 `docs/traps-detail.md` 121절, 주석, ADR)에서 새 구조에도 남는 것만 중복 없이 모았다. 버린 장치(SealedSecrets, KSOPS, bats, make, Gateway API 등)에만 해당하는 함정은 뺐다. 구현하는 사람은 해당 단계에서 이 줄을 설정 옆 주석으로 옮긴다. 근거 표기는 B.0과 같다.

**E1 철거**

| 함정 | 근거 | 대응 |
|---|---|---|
| `k3s-uninstall.sh`는 `/var/lib/rancher/k3s`만 지우고 `k3s-storage`(옛 PV 데이터)를 남긴다. 그 위에 새 k3s를 깔면 옛 워크로드가 옛 데이터로 살아나 "Git에서 복귀"로 오독한다 | `scripts/destroy-node.sh:117-120`, [S54] | 옛 데이터 경로까지 지우고 부재를 `sudo test ! -e`로 확인. E2 시작 조건 |
| 감사 중 에이전트가 파괴 한 줄을 실증하려고 실제로 실행해 라이브 클러스터를 파괴했다. 파싱 실패를 빈 문자열로 접는 관용구가 파괴까지 완주시켰다 | `scripts/destroy-node.sh:8-11`, `:58-65` | 파괴 명령은 확인 env가 있어야 도는 별도 파일. 에이전트는 파괴 명령을 실행하지 않는다 |
| bind 마운트 소스는 경로 문자열로 안 보이고 `findmnt -T`는 마운트 여부를 증명하지 못한다 | `scripts/destroy-node.sh:27-31`, TD:1166 | `findmnt -n -o SOURCE`의 `[subpath]`로 판정 |
| mount 유닛 이름의 `\x2d`를 이스케이프하지 않고 물으면 `inactive`, 목록 0개가 나와 "이미 없음"으로 오판한다 | 실측(B.4) | 작은따옴표 이름이나 경로로 확인 |
| 옛 사본 경로를 실행하는 유닛이 셋 있다. 옛 사본을 먼저 옮기면 매일·5분마다 실패한다 | 실측(B.4 H3) | 유닛을 먼저 지우고 옛 사본은 마지막 |
| writer App을 먼저 지우면 writer 전용 ruleset 접두사 브랜치를 아무도 못 만든다. `gate`가 남으면 main 교체 PR이 영원히 기다린다 | design-prompt §1 4항, `infra/github/repo.tf:52` | ruleset·보호 해제를 App 삭제보다 먼저(T06 할 일 5) |
| 옛 github root를 destroy하면 저장소 두 개가 지워진다. 새 root가 옛 state 키를 쓰면 plan이 옛 자원 삭제를 제안한다. `removed { destroy = false }`는 state 관리만 풀고 원격 자원은 남긴다 | spec §10 2항, `infra/github/secrets.tf:1-15` | destroy 금지, state에서 제거, 새 키 접두 `v2/` |
| provider lock과 Terraform 코어는 state를 마지막으로 쓴 버전 이상이어야 한다 | TD:416-421, TD:1340-1353 | 옛 state를 다룰 때(T06 할 일 4) 같은 버전 이상 사용 |
| 두 클러스터가 같은 터널 토큰이나 같은 healthchecks 체크를 쓰면 공개 요청이 비결정적으로 나뉘고 감시가 거짓 초록이 된다 | `platform/argocd/root/appset.yaml:29-34`, `platform/victoria-stack/prod/kustomization.yaml:32-38`, `tests/gates/test_dual-run-excludes.bats:2-11` | 새 터널·새 체크. 시나리오 13의 VM은 별도 터널·체크·자격·백업 버킷·serverName·Tailscale 이름 접두(E8 VM 격리, D-12) |

**E2 호스트·k3s·Argo CD**

| 함정 | 근거 | 대응 |
|---|---|---|
| 노드 DNS 순환 세 갈래: CNI portmap DNAT가 노드의 :53 질의를 AdGuard 파드로 끌어감, 노드 → 공유기 → AdGuard 교착, tailscale `~.`가 노드 질의를 MagicDNS로 | `infra/k3s-bootstrap/host-preflight.sh:12-21`, `host-config/etc/systemd/resolved.conf.d/10-k3s-node.conf:23-31`, TD:1139-1164 | resolved 스텁 끔 + `DNS=1.1.1.1 9.9.9.9`, 링크 `UseDNS=false`, `tailscale set --accept-dns=false`, preflight로 확인 |
| `FallbackDNS=`는 `DNS=`가 있으면 쓰이지 않는다. 공유기를 1순위로 두면 AdGuard 장애마다 질의당 약 5초 지연 | `resolved.conf.d/10-k3s-node.conf:32-44` | 폴백은 `DNS=`의 두 번째 항목 |
| networkd drop-in은 설치만으로 적용되지 않고 `networkctl reconfigure`가 필요하며, 그때 노드 IPv4가 약 2초 사라진다. drop-in 파일명이 `wlo1`에 묶여 유선으로 옮기면 조용히 무효 | `infra/k3s-bootstrap/host-config.sh:243-262`, TD:2404-2439, `host-config/etc/systemd/network/10-netplan-wlo1.network.d/10-k3s-node.conf:19-22` | 적용 스크립트가 reconfigure 뒤 IP 복귀를 기다림. 인터페이스 이름을 핀 파일 변수로 |
| `--node-name`·`--node-ip`는 설치 때만 정할 수 있고, 노드명을 바꾸면 hostPath PV nodeAffinity가 깨진다. 노드 IP는 공유기 DHCP 예약이 전제다. `--tls-san`은 설치 뒤에도 바꿀 수 있다: config를 바꾸고 재시작하면 서빙 인증서에 더해지고, 기존 SAN은 지워지지 않는다(옛 주석 "사후 추가는 serving cert 삭제 후 재생성"은 고정 k3s에서 틀림, 2026-10-26 확인) | `infra/k3s-bootstrap/versions.env:66-91`, k3s v1.36.5+k3s1 `pkg/cluster/https.go:52-80`, dynamiclistener e4a1908ede0d `listener.go:288-298`·`factory/gen.go:65-120, 195-241` | 값은 클러스터별 `host/clusters/<이름>.env`에 두고 `host/k3s-config.yaml`로 렌더(C.3.2), preflight가 IP 예약 상태 확인(사람 체크). `install.sh --k3s`는 node-name·node-ip만 기존 config와 같은지 고정하고, tls-san 차이는 출력한 뒤 재시작으로 반영한다. 뺀 이름은 인증서에 남는다 |
| CronJob은 노드 TZ, CNPG ScheduledBackup은 operator TZ(UTC). Ubuntu 26.04에는 `/etc/timezone`이 없다 | TD:246-250, TD:1121-1137 | `timedatectl`로 Asia/Seoul, 백업 일정은 UTC로 표기 |
| sshd_config.d는 먼저 읽힌 값이 이긴다 | TD:1104-1119 | 하드닝 파일은 `10-` 접두 |
| NVMe ASPM L1이 유휴 때 correctable 에러를 폭주시킨다(열화로 오독) | TD:162-191 | tmpfiles drop-in 유지 |
| 핀 파일은 재구축 목표값이라 bump를 병합해도 라이브는 안 바뀐다 | `infra/k3s-bootstrap/versions.env:5-9` | k3s 업그레이드는 사람 작업(E2 문서), Renovate PR은 그 입력 |
| local-path는 WaitForFirstConsumer가 필수, hostPath PV에는 fsGroup이 적용되지 않고 `kubelet_volume_stats`가 없다. SC의 reclaim을 바꿔도 이미 만든 PV는 안 바뀐다 | `infra/k3s-bootstrap/storage/storageclass-standard.yaml:11-15`, TD:193-203, `platform/victoria-stack/prod/rules/r4-storage-backup.yaml:11`, `tests/posture/test_storage-reclaim.bats:13` | 데이터용 SC `local-retain`(Retain, WaitForFirstConsumer)를 처음부터. 쓰는 컨테이너 uid 일치. 디스크 경보는 node-exporter 파일시스템 지표로 |
| kubeconfig에는 cluster-admin 토큰이 있다. 두 클러스터 kubeconfig가 경로·포트·노드명까지 같아 잘못 export하면 반대편을 조작한다 | `infra/k3s-bootstrap/.gitignore:1-4`, `infra/k3s-bootstrap/assert-cluster-identity.sh:4-11` | context 이름에 클러스터를 각인(`homelab`, `homelab-vm`), 파괴 명령 전 노드 이름 확인 |
| `Restart=always` 유닛(k3s)은 failed가 되지 않아 systemd 실패 감시가 크래시루프를 못 본다 | TD:1611-1631 | k3s 생존은 외부 생존 감시(Watchdog)가 본다 |
| Argo CD sync-wave는 한 Application 안에서만 강제되고 Application 사이 순서는 없다. health를 세워 주는 컨트롤러가 더 앞 wave가 아니면 교착(콜드스타트에서만 드러남, 17시간) | `platform/argocd/root/SYNC-WAVES.md:7-22`, TD:9-26 | Application health 사용자 정의[S69] + 규칙 "음수 wave 리소스를 Healthy로 만드는 주체가 더 앞 wave인가". 시나리오 12·13은 콜드스타트로 |
| retry가 소진되면 다시 시도하지 않고, 좀비 operation은 시작 시점 revision 결과를 계속 보여 준다. appset 앱은 retry가 없으면 Missing 고착 | TD:28-45, `platform/argocd/root/appset.yaml:58-71` | 모든 Application에 retry(limit·backoff). 운영 절차에 명시 sync |
| root → Application selfHeal 사슬 때문에 Application 하나를 잠시 끄는 것은 Git 변경 외에는 불가능하고, 라이브 장애 주입은 약 5초 만에 되돌려져 거짓 PASS를 낸다 | TD:216-234 | 장애 주입 시험(시나리오 14)은 Git PR로 하거나 Argo CD 밖 자원(외부 계정·네트워크)에서 |
| Application spec의 zero-value 필드는 정규화와 selfHeal이 플립플롭한다 | TD:212-214 | 기본값 필드를 쓰지 않는다 |
| SSA는 atomic 리스트(CNPG plugins·roles 등)의 서버 기본값을 기재하지 않으면 영구 OutOfSync, 중복 env 키와 스키마 밖 필드를 거부한다. SSA 관리 객체에 `kubectl apply --dry-run=server`는 거짓 실패 | TD:47-49, TD:105-124, TD:1283-1321 | atomic 리스트는 기본값까지 적는다. 수동 검증은 `kubectl diff` 대신 Argo CD diff |
| 마지막 리소스를 지우면 auto-sync가 prune을 거부한다(`allowEmpty`) | TD:2441-2462 | 비워질 수 있는 data Application만 `allowEmpty: true` + 데이터 객체는 `Prune=false`(C.5.5) |
| `chart:` 필드를 쓰면 repoURL은 Helm 레지스트리, targetRevision은 semver다. 차트의 `crds/` CRD는 kustomize helm 렌더에서 빠진다 | TD:51-52, TD:380-382 | 공유 차트는 git `path:` + 태그. 외부 차트는 `chart:` + 고정 semver |
| `app.kubernetes.io/instance` 라벨은 Argo CD v3가 자식을 트리에서 숨긴다. selector 라벨이 가변값이면 Deployment selector 불변으로 영구 실패 | `platform/charts/app/templates/_helpers.tpl:9-24` | 차트는 `homelab.ukyi.app/app` 같은 고정 라벨만 selector에 |
| repo-server에 netpol이 없으면 다른 ns 파드가 렌더를 요청해 복호화 평문을 받을 수 있었다. `ARGOCD_CONTROLLER_REPLICAS`를 직접 넣으면 SSA가 중복 키로 거부 | `platform/argocd/bootstrap-values.yaml:5-30` | 공식 매니페스트의 NetworkPolicy 유지(v3.5.5 install.yaml에 구성 요소별 7개가 있다[S181]. [미검증] 라이브 적용, E2). replica 설정은 공식 방식 |
| 자기 관리 Application과 root를 부트스트랩에서만 만들면 핀 이동이 한쪽만 된다. 부트스트랩의 helm 실패가 파이프에 삼켜져 "complete"를 찍었다 | `scripts/bootstrap.sh:24`, `:33-44` | root가 argocd Application을 소유. 부트스트랩은 `set -euo pipefail` |
| 자기 저장소 참조 revision이 브랜치 이름으로 남은 채 main에 병합하면 Argo CD가 죽은 브랜치를 따라간다(ApplicationSet git 생성기는 키가 `revision`) | `scripts/check-argocd-revision.sh:6-10` | CI 검사(C.4.6). `rebuild` → main 병합 전 확인 |
| 멀티소스 Application은 `status.sync.revision`을 비우고 `revisions[]`만 채운다 | `tools/README.md:594-599` | CLI `status`는 둘 다 읽는다 |
| argocd ns의 application-controller는 cluster-admin이라 PSA는 경계가 아니라 위생이다 | `platform/namespaces/prod/namespaces.yaml:149-152` | 문서화만 |
| Argo CD는 `timeout.reconciliation`에 jitter(기본 1분)를 더해 실제 폴링 간격이 60~120초가 된다 | [S209] | `argocd-cm`에 `timeout.reconciliation.jitter: 0`(C.3.3) |

**E3 시크릿**

| 함정 | 근거 | 대응 |
|---|---|---|
| `terraform output -json`이 비면 `jq -r`가 문자열 `null`을 내 그대로 쓰인다 | `scripts/seed-secrets.sh:24-30` | `jq -re`, 값 부재는 실패 |
| DB 비밀번호를 재생성하면 복원된 DB의 비밀번호와 어긋난다 | `scripts/seed-secrets.sh:126-136` | Infisical에 값이 있으면 재사용(C.6.5) |
| envFrom Secret 변경은 파드 재시작 전까지 반영되지 않는다 | TD:89-90, [S46] | 회전 절차의 마지막에 rollout restart |
| 자격이 에이전트 트랜스크립트로 유출된 사고(2026-08-18)가 있었다 | `policy/gh-secret-var-classification.json:5` | 에이전트는 시크릿 값을 출력·조회하지 않는다. CLI 출력에도 값 없음 |
| 자격 파일의 접미사 사본(`.bak`, rename)이 `.gitignore`를 빠져나간다 | `tests/gates/test_iac-credential-gitignore.bats:4-11` | 로컬 자격 파일 자체를 두지 않고(`infisical run`), `.gitignore` 패턴 + gitleaks |
| 클러스터에는 넓은 Terraform 토큰 대신 좁은 토큰을 넣는다 | `scripts/seed-secrets.sh:13-17` | 클러스터에 Cloudflare 토큰을 두지 않는다(터널 토큰만). Terraform 자격은 machine identity가 없는 Infisical 프로젝트 `homelab-admin`에 둬 ESO identity도 읽지 못한다(C.6.3) |
| Claude Code PreToolUse 훅은 exit 2만 차단, 그 밖은 fail-open | TD:809 | 훅을 다시 만들면 exit 2 |
| ESO `v1beta1`은 served가 아니다. Infisical provider는 stability alpha, ESO는 최신 minor 하나만 지원(2~3주마다 새 minor). `recursive`·`find`에 열린 버그(#6876, #6230). `deletionPolicy` Delete·Merge는 누락 키를 조용히 건너뛴다 | [S20][S22][S23][S24] | `external-secrets.io/v1`, 키는 `data[]`로 명시, `deletionPolicy: Retain`(기본), D-18 갱신 대상 |
| Universal Auth client secret의 사용 횟수를 1로 두면 ESO는 동기화마다 로그인하므로 두 번째 동기화부터 실패한다 | [S05][S24] (ESO v2.13.0 `providers/v1/infisical/provider.go`의 NewClient·Close), 추측 | ESO용 client secret은 사용 횟수 0(무제한), TTL은 복구 자산 점검 주기에 맞춤 |
| `target.template`이 없는 ExternalSecret은 자기 라벨·주석(Argo CD `tracking-id` 포함)을 대상 Secret에 복사한다. 다른 Application이 소유한 Secret에 `creationPolicy: Merge`로 합치면 그 Secret의 `tracking-id`가 바뀌어 원래 Application이 되돌리고, 두 컨트롤러가 번갈아 덮어쓴다 | ESO v2.13.0 `externalsecret_controller_template.go` `setMetadata`, T09 실측(2026-10-20, PR #766·#767) | Merge로 합치는 ExternalSecret에는 `target.template`(`engineVersion: v2`, `mergePolicy: Merge`)을 둔다. template이 있으면 template의 metadata만 쓴다. 공유 차트(C.4.5)의 ExternalSecret도 같은 이유로 template을 둘지 T10이 정한다 |

**E4 네트워크·DNS·관측**

| 함정 | 근거 | 대응 |
|---|---|---|
| AdGuard ConfigMap은 첫 부팅 시드 전용이라 수정이 라이브에 안 닿는다 | TD:285-287, `platform/adguard/prod/adguardhome.yaml:1-3` | 원본 선언(C.2): 시드는 Git, 라이브 변경은 내보내기로 Git에 반영 |
| AdGuard는 setcap 바이너리라 `allowPrivilegeEscalation: true` + `NET_BIND_SERVICE`만, 빈 PVC에 파일을 만드는 컨테이너는 소비자와 같은 uid | `platform/adguard/prod/deployment.yaml:13-24`, `:111-115` | 그대로 가져온다 |
| 공유기가 LAN의 유일한 DNS 클라이언트라 기본 ratelimit 20이 집 전체를 조인다. 사설 PTR이 로그를 오염. liveness 재시작이 유일 리졸버를 끊는다. 질의 로그 30일은 약 1.7GB | `platform/adguard/prod/adguardhome.yaml:19-45`, `:68-75`, `deployment.yaml:96-101` | ratelimit 끔(처음엔 100 + 공유기 예외였으나 2026-10-21 U32에서 servicelb 뒤 출처가 공유기가 아니라 예외가 맞지 않음을 확인), `local_ptr_upstreams`, liveness 없음, 로그 보존 7일 |
| servicelb(klipper) SNAT 때문에 NetworkPolicy로 :53 ingress를 출처 제한할 수 없다 | `platform/adguard/prod/networkpolicy.yaml:9` | 수용(LAN과 tailnet 서비스, D-08). 관리 UI는 Tailscale Ingress로만. tailnet 질의도 svclb 출처 하나로 보여 ratelimit 버킷을 함께 쓸 수 있다(U32. 2026-10-21 E4a 확인: LAN 출처와 같은 /24 버킷을 쓴다. ratelimit을 껐다) |
| Tailscale `autogroup:self` 규칙이 빠지면 운영자 SSH가 끊긴다. `autogroup:self`는 태그 기기에 적용되지 않는다 | `infra/tailscale/acl.tf:8-10`, [S117] | 2026-10-20 F D-11 (c)로 NUC를 `tag:nuc`로 태그한다. 태그를 붙이기 전에 `autogroup:owner`·`autogroup:admin` → `tag:nuc:22,6443`, `autogroup:member → tag:nuc:53`을 먼저 적용해야 원격 접속이 끊기지 않는다(E4a 적용 순서, 2026-10-21 적용). NUC는 Tailscale SSH를 켜지 않아 원격 SSH는 22 포트 규칙으로 닿는 sshd이고, `tag:nuc` 대상 ssh 규칙은 쓰이지 않는다 |
| 태그 없는 사용자 기기로 재등록하면 키 만료가 기본값(켜짐, 180일)으로 돌아온다. 태그를 붙여 등록하면 기본으로 꺼진다 | `infra/tailscale/acl.tf:61-74`, [S119] | D-11 (c)(2026-10-20)로 NUC는 `--advertise-tags=tag:nuc`로 등록해 키 만료가 기본으로 꺼진다. E2 사람 작업: 옛 NUC 기기 삭제 → 태그를 붙여 재등록 → MagicDNS 이름의 첫 라벨이 `NODE_NAME`과 같은지 확인 → 태그가 `tag:nuc`이고 키 만료가 꺼져 있는지 확인(C.3.2의 0, `bootstrap.md`). 재등록으로 Tailscale IP가 바뀌면 전역 nameserver도 바뀌어야 한다: DNS Terraform이 `data.tailscale_devices`로 IP를 다시 읽고 precondition이 태그와 만료 꺼짐을 확인한다(C.3.6) |
| Tailscale은 전역 nameserver에 동시에 묻고 처음 온 정상 응답을 쓴다. 차단하지 않는 서버를 하나라도 섞으면 그 서버가 먼저 답한 질의는 차단이 빠진다(C-05의 Cloudflare가 그렇다). 평문 UDP로 가는 공용 서버는 53번을 가로채는 망에서 그 망의 답에 진다. Override를 켜면 ACL이 막은 nameserver는 쓰이지 않는다 | [S110][S111][S186] | D-08 확정안(b′)은 전역 nameserver를 모두 같은 기본 목록의 차단 리졸버(NUC AdGuard Home, AdGuard 공용 2개)로 두고 비차단 리졸버를 더하지 않는다. NUC를 `tag:nuc`로 태그하면(F D-11 (c)) `tag:nuc:53` 규칙을 함께 연다. 빠뜨려도 공용 서버가 답해 E4a에서 드러나지 않으므로 시나리오 14의 사용자 규칙 적용률과 이탈 경보(C.3.7)로 본다 |
| AdGuard Home이 tailnet에서 조용히 빠져도(NUC 재등록으로 IP가 바뀜, ACL 실수, svclb 경로 문제, ratelimit 드롭) 공용 서버가 모두 답해 증상도 기기 경고도 없다. 사용자 규칙과 통계만 계속 빠진다 | [S186] (처음 온 정상 응답 채택), 추측 | "tailnet 출처 질의가 1시간 0건이면 경보"(C.3.7) |
| `data.tailscale_device`(hostname)는 같은 hostname 기기가 여럿이면 오류 없이 첫 기기를, 없으면 오류로 root 전체 plan을 막는다. 재등록 뒤 옛 기록이 남으면 죽은 IP를 nameserver로 넣는 apply가 성공하고(옛 함정 재현, `infra/tailscale/acl.tf:53-56`), 다른 기기가 같은 hostname을 쓰면 tailnet 전역 DNS를 가져간다 | [S187] | `data.tailscale_devices`로 받아 precondition(정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`). IPv4는 `100.` 대역으로 골라낸다. DNS는 별도 root `infra/tailscale-dns`, `prevent_destroy`, count 없음(C.3.6) |
| `tailscale_dns_configuration`은 tailnet DNS 설정 전체를 소유한다. 선언하지 않은 콘솔 값(nameserver, split DNS, search path)은 첫 apply에서 지워지고, `override_local_dns`를 빠뜨리면 기본 false라 기기가 로컬 DNS를 계속 쓴다(plan은 정상). 다른 DNS 리소스와 함께 쓰면 서로 덮어쓴다(옛 "apply마다 nameserver를 비우는 경쟁"의 원인으로 추측, `infra/tailscale/acl.tf:79-82`) | [S187] | 첫 apply 전에 콘솔 값을 그대로 옮겨 plan 무변경을 확인한 뒤 바꾼다. 다른 DNS 리소스를 두지 않는다 |
| operator Ingress reconcile은 메타데이터만 바뀐 변경을 무시한다. 프록시 파드는 무제한 메모리였다 | TD:296-298, `platform/tailscale/prod/proxyclass.yaml:1-4` | 변경 시 Ingress를 다시 만든다. ProxyClass 메모리 캡 |
| Tailscale SSH ACL에 root가 있어 비밀번호 없이 root 접속이 된다. 옛 구성은 이것을 비대화형 검증 경로로 썼고, 좁히면 그 경로가 사라진다 | `infra/tailscale/acl.tf:32-40` | 옛 규칙(`accept`, nonroot + root) 유지(C.3.5. F D-11 (a), 확정(사용자 2026-10-18, T05)). `check` + nonroot로 좁히는 F D-11 (b)는 고르지 않았다. 2026-10-21: NUC의 Tailscale SSH를 켜지 않기로 해(사용자) 원격 SSH는 sshd(키 인증, root 로그인 금지)이고 이 root 경로는 쓰이지 않는다 |
| Cloudflare Free: WAF 사용자 규칙 5개, 정규식 불가, rate-limit 1개·10초, 일부 값은 apply에서만 400 | `infra/cloudflare/waf.tf:11-14`, `:29-46`, [S136][S137] | `eq`·`ne`만 쓰는 규칙. apply는 사람이 보며 |
| R2 lifecycle `prefix = ""`는 버킷 전체 만료다. R2 Object R&W 토큰은 ListBuckets·HeadBucket이 안 된다 | `infra/cloudflare/r2.tf:16-21`, TD:61-63 | lifecycle은 prefix 명시, rclone `no_check_bucket=true` |
| cloudflared 2026.8.0과 2026.8.1은 쓰지 말라는 경고가 있다. 같은 토큰으로 커넥터 둘이면 비결정 분배 | [S133], `platform/argocd/root/appset.yaml:29-34` | 2026.10.1 고정, 새 터널 |
| vector·VictoriaLogs OOM 결합 루프: GOMEMLIMIT으로 못 막고, 장애 뒤 백로그 버스트가 OOM을 일으킨다. VictoriaMetrics는 GOMEMLIMIT과 allowedPercent 두 경로가 따로 산다 | TD:126-160, TD:2306-2327 | limit에 백로그 여유, `--memory.allowedBytes` 절대값 |
| vmalert는 `configCheckInterval` 없으면 룰 변경을 무시하고, ConfigMap 변경은 롤아웃을 일으키지 않는다 | TD:1783-1794, TD:338-349 | `-configCheckInterval=30s`, configMapGenerator 해시 |
| vector는 root여야 `/var/log/pods`를 읽고, 아니면 수집이 조용히 0이다. VictoriaLogs·vmalert는 distroless라 exec 질의가 빈 출력 | TD:300-316 | vector root + privileged ns, 진단은 HTTP API로 |
| push 메트릭 주기가 룩백보다 길면 룰이 영원히 발화하지 않는다. 재부팅으로 instance 라벨이 바뀌면 increase 누적 오발화. `failedJobsHistoryLimit`가 N 미만이면 "N회 실패"를 셀 수 없다. 메모리 분자를 working_set으로 두면 캐시를 압력으로 센다 | TD:526, TD:507-525, `tests/gates/test_cronjob-flapping.bats:5`, `tests/gates/vmalert-memory-nearlimit-firing-e2e.sh:5` | 룰 작성 규칙 4줄, 룰 단위 시험 |
| VictoriaMetrics `retention.maxDiskSpaceUsageBytes`는 엔터프라이즈 전용. 보존 용량의 GB와 PVC의 Gi를 접미사로 비교하면 반대로 읽힌다 | TD:86-87, `tools/README.md:887-890` | 보존 기간으로 제한, 단위를 values 주석에 |
| Alertmanager Telegram 전송 확인은 로그가 아니라 `alertmanager_notifications_total{integration="telegram"}`. 자동 HTML escape 위에 이중 escape 금지. Argo CD notifications의 webhook 방식은 토큰을 DEBUG 로그로 유출했다 | TD:332-335, `platform/victoria-stack/prod/alertmanager-config/alertmanager.yml:45-48`, `platform/argocd/bootstrap-values.yaml:137-139` | 시나리오 16 검증 지표. Argo CD 알림은 notifications 대신 메트릭 경보로 |
| busybox nc relay가 연결 없이 반환할 때 ping해 dead-man이 영구 초록이 됐다 | `platform/victoria-stack/prod/deadmanswitch-relay.yaml:9-16`, TD:305-309 | Watchdog을 healthchecks로 직접(미검증), 안 되면 relay에 그 가드 |
| Grafana 플러그인 런타임 다운로드가 emptyDir sizeLimit을 넘기면 부팅·축출 루프 | TD:605-628 | 런타임 다운로드(preinstall)는 끄고, 필요한 플러그인 하나(VictoriaLogs 데이터소스)만 init 컨테이너가 버전·sha256 고정으로 PVC에 받는다(T08b) |
| ipBlock에 pod CIDR을 넣으면 기본 거부가 무력화된다. kube-router는 새 파드 규칙을 수 초 늦게 설치한다. apiserver egress는 노드 서브넷:6443이어야 하고, 반대로 NetworkPolicy는 노드 로컬(INPUT) 경로를 막지 못한다 | TD:252-274 | 차트 정책에 pod CIDR 금지. 격리 공간은 파드 netns 방화벽(C.8) |
| PSA baseline도 hostPath·hostPID를 금지해 node-exporter·vector는 privileged ns가 필요하다 | TD:236-239 | `observability` ns privileged, 앱 ns restricted |

**E5 CI/CD (GitHub)**

| 함정 | 근거 | 대응 |
|---|---|---|
| `gh pr merge --auto`는 이미 clean인 PR에 에러를 낸다. strict + 비동기 auto-merge는 두 번째 PR을 BEHIND로 멈춘다. `gh pr update-branch`는 head를 머지 커밋으로 바꾼다 | TD:403-404, `tests/gates/test_pr-sweeper.bats:2-3`, `tools/README.md:390-392` | GitHub auto-merge를 쓰지 않고 merge App이 직접 병합. strict 끔 |
| 워크플로 `git commit`은 서명되지 않아 커밋 신원 검사는 인증이 아니다. ruleset 거부 코드는 GH013이고 owner·admin에도 암묵 bypass가 없다. ruleset은 PR 생성을 막지 못한다 | TD:582-602 | 신원은 PR 작성자(App 봇 계정)와 ruleset bypass로. PR 생성은 막지 않고 병합만 막는다 |
| `github.actor`는 재실행에서 보존되고 개시자는 `github.triggering_actor`다. `actions: write`는 재실행을 포함한다. GitHub login은 대소문자를 구별하지 않는다 | TD:2053-2075, TD:2128-2139 | 병합 워크플로는 actor가 아니라 PR 상태를 매번 다시 읽고, 신원 비교는 숫자 ID로 |
| GHA run 기본 셸에는 pipefail이 없다. 스텝 레벨로 게이트된 job은 스텝이 전부 skip돼도 success다. 따옴표 없는 스텝 이름의 콜론이 YAML을 깬다 | TD:458, `policy/workflow-readiness.json:7-9`, `tests/gates/test_workflow-yaml.bats:2-4` | `defaults.run.shell: bash`, 자격 부재는 실패, actionlint |
| GitHub은 60일 활동이 없으면 스케줄 워크플로를 비활성화한다. 10분 크론이 실측 60~90분 지연됐다 | `tests/gates/test_gha-liveness-exporter.bats:5`, `.github/workflows/reusable-app-build.yaml:131` | 스케줄 워크플로를 두지 않는다 |
| fine-grained PAT은 `GET /apps/{slug}`를 404로 막는다. `create-github-app-token`의 `repositories`는 owner 없는 이름이고 owner를 비우면 현재 저장소만이다 | TD:69-76, TD:406-409, [S90] | App ID·설치 ID는 숫자로 고정. 토큰 발급에 `owner`·`repositories`·`permission-*` 명시 |
| `concurrency`는 순서를 보장하지 않는다. `queue: max`와 `cancel-in-progress: true`는 함께 못 쓴다 | [S80], TD:411-413 | 순서는 compare API로 지킨다(C.4.3) |
| GHCR org 패키지의 첫 가시성은 문서끼리 어긋난다: 패키지 문서는 연결 저장소의 접근 권한만 물려받고 가시성은 물려받지 않는다고 하고[S96], Actions 문서는 `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는다고 한다[S213]. 옛 구성에서는 첫 push가 private이었다. 가시성은 UI에서만 바꾸고 public 전환은 되돌릴 수 없다 | TD:65-67, [S96], [S213] | 앱 패키지는 public만(D-29). E5에서 org Package Creation의 Public 허용을 확인하고 `homelab-probe` 첫 push로 시험한다(U39). 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다. `homelab app add`는 익명 pull이 안 되는 패키지를 거부한다(C.7, C.4.10) |
| `client_payload`와 디스패치 입력은 비신뢰다 | TD:96-98 | 워크플로 입력은 env 경유 + 정규식 |
| QEMU amd64 leg의 bun이 크래시 루프로 release를 6시간 태웠다. attestation을 켜면 인덱스 digest가 매번 달라져 배포가 헛돈다. Dockerfile `ARG TARGETARCH` 기본값이 플랫폼 인자를 이긴다. `setup-qemu`는 `setup-buildx`보다 앞 | TD:1948, `.github/workflows/reusable-app-build.yaml:76-77`, `:97-120` | amd64 네이티브 단일 빌드, 모든 job `timeout-minutes`, `provenance: false` |
| 상류 레지스트리 릴리스 태그는 불변이 아니다. GitHub API는 낡은 스냅샷을 200으로 돌려줄 수 있다 | `docs/traps.md:103`, TD:1355 | 외부 레지스트리 조회를 필수 검사에 넣지 않는다. 병합 워크플로는 실패 때 재조회 |
| 빌드의 paths·diff 감지는 새 브랜치와 dispatch에서 무력하다 | TD:92-94 | 공통 빌드에 경로 필터를 쓰지 않는다 |
| reusable 워크플로의 `permissions`는 caller 상한을 넘을 수 없고 넘기면 run 전체가 죽는다 | `.github/workflows/reusable-app-build.yaml:21-31`, [S81] | 템플릿 caller가 호출 job에 상한으로 `id-token: write`, `attestations: write`, `packages: write`, `contents: read`를 선언하고, `app-build`가 job마다 다시 좁힌다(`id-token`·`attestations`는 deploy-pr job, `packages`는 push job만, C.4.1) |
| `workflow_run` 소비자는 head 저장소와 head 브랜치를 확인해야 fork 아티팩트에 조종되지 않는다 | `.github/workflows/bump.yaml:27-33` | `deploy-merge`의 첫 검사 |
| `GITHUB_TOKEN`이 만든 PR의 `pull_request` 실행은 승인 대기로 생긴다 | [S92] | 배포 PR은 App 토큰으로 만든다 |
| `pull_request`는 PR merge commit의 워크플로를 실행해 같은 저장소 브랜치 PR은 검사 자체를 바꿀 수 있다. `pull_request_target`의 public 저장소 기본 차단 정책은 지금 evaluate 모드라 실행이 계속되고, 2026-11-02 강제도 GA 전부터 기본 정책을 쓰던 저장소가 대상이다. Draft PR도 CI를 실행한다 | [S94], [S104], `docs/reviews/aiops-codex/input/research.md:282-284` | 자동 병합 판단은 `workflow_run`(main 코드)에서만. `pull_request_target`은 쓰지 않는다 |
| gitleaks 면제를 파일명만으로 걸면 기본 룰셋 전체가 꺼진다 | `.gitleaks.toml:8-16` | 면제는 경로 + 룰 범위 |
| 필수 검사는 PR에서 실제로 도는 job 이름이어야 한다 | `infra/github/repo.tf:52` | ruleset 선언(`infra/github` HCL)의 검사 이름 `ci`와 job 이름 일치를 E5 검증 |
| 트리거 열거나 `permissions:` 선언으로 워크플로 특권을 판정할 수 없다(재실행이 트리거를 우회) | `docs/adr/0002-dominance-classifier-rejected.md:5-12` | 특권은 서버가 강제하는 경계로 묶는다: 배포 키는 OIDC identity의 claim(저장소, 워크플로 파일과 ref, 이벤트), 병합 키는 environment `automerge`의 배포 브랜치 정책(main)과 main을 바꾸는 사람 검토(ruleset B), 그리고 App 설치 범위(C.4.8). ci의 workflow-guard(트리거·environment 사용처 검사, C.4.6)는 실수를 잡는 장치이고 경계가 아니다 |
| GitHub provider v6.13.0의 legacy 클라이언트는 갱신 apply가 한 번 실패하면 state에 계획값이 남고 etag는 그대로라, 그 ruleset의 드리프트가 그 뒤 plan과 `-refresh-only`에 영구히 안 보인다. 수정 #3637은 미출시다 | [S192] | provider 6.13.0 정확 핀(legacy 클라이언트). 래퍼가 apply 실패를 보면 그 plan의 ruleset을 `state rm` 후 import한다. bypass는 guard가 provider state를 거치지 않는 GET으로 다시 본다(C.3.9) |
| Terraform `check` 블록은 실패해도 경고만 내고 plan이 초록으로 끝난다(옛 "조용한 초록"). provider는 셸에 `GITHUB_APP_*` 세 값이 있으면 owner 토큰 대신 App 인증을 조용히 쓰고, gh 호출이 실패하면 익명으로 떨어진다. 토큰을 `-var`로 넘기면 값이 plan 파일에 남는다. 쓰기 권한 없는 토큰에는 bypass 목록과 병합 설정이 안 보여 허위 드리프트가 난다 | [S191][S193][S195][S196], `infra/github/provider.tf:6-10` | guard는 `github_rest_api` 데이터 소스 postcondition(실패하면 plan 오류). 래퍼가 `GITHUB_TOKEN`을 환경변수로만 넘기고 `GITHUB_APP_*`를 unset한다. admin guard가 익명·권한 부족을 오류로 바꾼다. CI에서 plan하지 않는다 |
| `terraform test`의 `mock_provider`는 덮어쓰지 않은 계산 문자열에 임의 8자를 넣는다. guard 하나만 덮어쓴 음성 시험은 나머지 guard까지 실패해 시험 자체가 깨진다 | [S194] | run마다 모든 guard 인스턴스에 정상 JSON을 `override_data`로 넣고 하나만 망가뜨린다 |
| GitHub environment를 지우거나 다시 만들면 그 secret도 지워지고, Infisical은 GitHub 대상에 주기 재동기화가 없어 다음 값 변경이나 Sync 재실행까지 병합 키가 빈 문자열이다. 없는 이름의 environment를 참조하는 워크플로는 보호 규칙 없는 environment를 새로 만들고, environment 이름은 대소문자를 가리지 않는다 | [S102][S200][S203] | environment `automerge`는 Terraform `prevent_destroy`, 다시 만들면 Sync 재실행. ci의 workflow-guard가 다른 워크플로의 `automerge` 사용(대소문자 무시)을 막는다(C.4.6) |
| GitHub App private key는 만료되지 않고 25개까지 함께 유효하다. 회전 뒤 `deploy-merge`가 성공해도 옛 키로 성공했을 수 있다 | [S199] | 회전 때 environment secret의 `updated_at`이 교체 시각 이후인지 확인한 뒤 옛 키를 지운다(C.6.5) |
| ruleset의 `bypass_actors`는 규칙 하나가 아니라 ruleset 전체에 걸린다. 태그 ruleset의 bypass는 `always` 모드만 된다. 모드 `exempt`는 그 행위자에게 규칙을 돌리지 않고 bypass 감사 기록도 만들지 않는다 | [S85] | 태그 ruleset을 갱신·삭제 금지(D1, bypass 없음)와 생성 제한(D2, 관리자 bypass)으로 나눈다. guard가 `exempt`를 금지한다(C.3.9, C.4.7) |
| bypass 병합은 "새 push 때 승인 무효화"와 "마지막 push 승인"까지 건너뛰어 검토 뒤 들어온 커밋도 병합된다. `gh pr merge --admin`은 gh의 사전 점검만 끄는 클라이언트 쪽 표시이고, 서버는 bypass 목록의 호출자를 알아서 우회한다 | [S208] | owner PR은 `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`로 병합한다(C.4.7) |
| ruleset 변경 이력(History)은 문서상 Enterprise 기능이다. rule suites 목록 API는 기본 `time_period=day`라 그냥 부르면 지난 bypass 기록을 놓친다 | [S206][S207] | ruleset은 지우지 말고 `disabled`로만 끄고 정답은 git의 HCL. 감사는 org 감사 로그(180일)와 월 1회 `time_period=month` 대조(C.4.7) |
| GitHub App 이름은 GitHub 전체에서 하나뿐이다. 처음 정한 `homelab-deploy`(봇 사용자 ID 217504981)·`homelab-merge`(299472841)는 다른 계정의 비공개 App이었다. 옛 이름으로 봇 ID나 App ID를 조회해 넣으면 조건 1이 남의 App이 연 PR을 통과시키고 ruleset bypass가 남의 App을 가리킨다 | `https://github.com/apps/<이름>`, `GET /users/<이름>%5Bbot%5D`(2026-10-21 확인) | 새 이름 `ukyi-homelab-*`(C.4.7 App 이름). `app-build`는 `create-github-app-token`의 `app-slug` 출력으로 커밋 작성자를 만들고, 사람이 채우는 ID 자리(`deploy-merge.yaml`, `infra/github/variables.tf`)에 주석을 둔다 |
| GitHub OIDC `sub`는 2026-07-15 뒤 만든·이름 바꾼 저장소에서 숫자 ID가 든 불변 형식(`repo:ukyi-app@292175290/<앱>@<저장소ID>:ref:...`)이고, 그 전 저장소(`files`, 템플릿)는 옛 형식(`repo:ukyi-app/<앱>:...`)이다. Infisical Subject를 옛 형식 `repo:ukyi-app/*:ref:refs/heads/main`으로 두었더니 `homelab-probe`의 deploy-pr이 403 "OIDC subject not allowed"였다 | [S103], `GET /repos/ukyi-app/<저장소>/actions/oidc/customization/sub`, `homelab-probe` run 39543199006(2026-10-21) | Subject를 `repo:ukyi-app@292175290/*:ref:refs/heads/main`으로 바꿨다(재실행 통과). 옛 형식 저장소가 `app-build`를 쓰기 전에는 그 저장소의 OIDC 설정에서 불변 subject를 켠다. 실제 경계는 개별 claim(owner ID·ref·event·`job_workflow_ref` 태그)이다 |
| 새 파드는 시작 직후 약 1초 동안 NetworkPolicy가 붙기 전이라 egress가 모두 열린다(k3s 내장 kube-router netpol의 파드 동기화 지연). 앱 컨테이너가 시작하자마자 연결하면 tailnet·LAN·kube API에 닿는다 | `app-homelab-probe` 시험 파드: 시작 즉시 연결은 모두 성공, 0.5초 간격 측정에서 0초 열림·1초부터 차단, 25초 뒤에는 설계대로 차단(2026-10-21, approvals 15:48 행) | 사용자가 한계로 승인했다(2026-10-21 "한계로 승인하고 T13에서 완화하자"). 이 틈으로 닿는 곳은 적어도 실측된 대상(Argo CD tailnet 443, 공유기의 80·443, kube API, 공개 인터넷 `1.1.1.1:80`. 앱 파드는 서비스 계정 토큰을 마운트하지 않는다)이고, 같은 LAN의 다른 호스트·포트, ACL상 다른 허용 대상, 공개 인터넷의 443 밖 포트(정상 정책은 443만 연다)도 열려 있다고 봐야 한다. 의존성 공급망 공격이 쓸 수 있으므로 T13 할 일 9에서 완화 전에 전체 LAN·tailnet·공개 인터넷 도달성을 조사하고, 노드 nftables로 파드 대역 → tailnet·LAN 사설 대역을 정책과 무관하게 막고 재시험한다 |
| `gh api`는 HTTP 실패에도 응답 본문(404면 `{"message":"Not Found",...}`)을 stdout에, `gh: Not Found (HTTP 404)`를 stderr에 내고 exit 1이다. `$(gh api ... 2>/dev/null \|\| true)`로 "없음"을 받으면 그 JSON이 값이 된다. `app-build-v1.0.0`은 배포 브랜치가 아직 없는 첫 배포 PR에서 그 JSON을 `--force-with-lease` 기대값으로 넘겨 git 파싱 오류("cannot parse expected object name")로 끝났다. 모든 앱의 첫 배포가 막힌다 | 실측(2026-10-21 `homelab-probe` run 39545899261, gh 2.102.0) | "없음"을 받아 넘길 곳만 stderr의 `HTTP 404`로 가르고 그 밖의 실패는 멈춘다(`read_image`, `read_lease`). 나머지 `gh api`는 `\|\| true` 없이 `set -e` 아래 대입으로만 쓴다. `tools/app-build.test.sh`가 그 단계를 워크플로에서 그대로 꺼내 가짜 gh(404·200·500)로 시험한다(ci). 고친 판은 `app-build-v1.0.1` |
| 호스팅형 Renovate App은 설치한 저장소에 Contents·Workflows·Commit statuses·Checks·Issues·Pull requests 쓰기를 가진다. 실제 설치(2026-10-21 20:57, approvals 20:54 행)에는 문서 표에 없던 `members: read`(org 구성원·팀)·`packages: read`도 있다(그 밖 administration·metadata·vulnerability_alerts read). 브랜치에 워크플로를 써서 돌리면 그 실행은 저장소·org Actions secret을 읽을 수 있고, statuses write로 커밋 상태를 찍을 수 있다 | [S232], 실측(2026-10-21 `gh api`: homelab·`homelab-app-template`·`homelab-probe`·`files`의 저장소 Actions secret·Dependabot secret 0, org secret 0, environment는 homelab `automerge` 하나) | 저장소·org secret을 두지 않는다. 병합 키는 environment `automerge`(배포 브랜치 main)에만 두고, homelab의 repo·org secret 0은 guard가 대조한다(C.3.9). 필수 검사 `ci`는 `integration_id`를 GitHub Actions App으로 고정해 statuses write로 위조할 수 없다(`infra/github/rulesets.tf`). `deploy/*` 생성은 배포 App만(ruleset C `deploy-branches`), 릴리스 태그는 관리자만(D2). Renovate PR은 deploy-merge 조건 1(작성자 배포 App) 밖이라 자동 병합되지 않는다. 승인·병합 API로 main을 바꾸는 길은 Restrict updates가 막는다(아래 owner PR 승인 행). 새 저장소·org secret을 더하면 Renovate와 Codex Connector가 만든 브랜치의 실행에 노출되므로 배포 브랜치를 제한한 environment secret으로만 둔다(Codex Connector와 같은 분석, C.4.8, F D-26) |
| PR 작성자가 유일한 code owner면(`CODEOWNERS` `* @<owner 계정>`, owner가 연 PR과 owner로 찍히는 Codex PR) code owner 리뷰 요구가 효력을 잃고, pull_requests write를 가진 App의 승인 하나로 `reviewDecision`이 `APPROVED`가 된다. 그 App에 contents write가 있으면 bypass 없이 병합까지 된다. owner는 자기 PR을 승인하지 못하므로 사람은 이 승인을 막을 수도 없다 | 실측(2026-10-21 homelab #822: 배포 App 승인 뒤 같은 토큰의 병합 200, main b25aac6, approvals 21:01~21:07 행. 원인은 추정) | 승인 요건에 기대지 않는다. ruleset B와 `app-main`에 Restrict updates(`update`)를 걸어 main 갱신을 bypass 신원만 하게 하고, 사람 병합은 늘 관리자 bypass(`--admin --match-head-commit`)로 한다. deploy-merge 조건 9가 앱 main의 `update` 규칙을 확인한다. `infra/github/tests`가 두 ruleset의 `update`를 assert한다 |
| PR 본문에 `@codex` 글자가 있으면(백틱 안 포함) Codex Connector가 자동 리뷰 대신 작업 요청으로 보고 "To use Codex here, create an environment for this repo." 답글만 단다. 자동 코드 리뷰 요약이 생기지 않는다(원인 미확인) | #828(15:38:36Z), #829(2026-10-22 02:17:30Z) | PR 본문에는 그 문자열을 쓰지 않는다("Codex 멘션"처럼 바꿔 쓴다). 리뷰는 `@codex review` 댓글로 부른다 |

**E6 데이터**

| 함정 | 근거 | 대응 |
|---|---|---|
| CNPG bootstrap은 초기화 때만 읽힌다. recovery 블록을 남기면 볼륨 유실 때 낡은 아카이브로 조용히 복구된다 | `platform/cnpg/prod/cluster.yaml:50-62` | 공유 클러스터는 평상시 `initdb`만. 앱 하나 복원은 별도 클러스터 이름으로(C.5.7). 빈 NUC 복구는 root apply 전에 recovery(옛 serverName) + 새 serverName PR을 먼저 병합하고, 복구 확인 뒤 정리 PR로 `initdb`로 되돌린다(C.6.4, U26) |
| 두 primary가 같은 R2 prefix에 아카이브하면 타임라인이 섞이고 되돌릴 수 없다(R2 버저닝 없음) | ADR 0006:17-19, `scripts/check-pg-servername.sh:5-8` | serverName에 세대 `pg-<YYYYMMDD>`. VM은 전용 버킷과 전용 serverName(E8 VM 격리). 비어 있지 않은 prefix에 쓰려는 클러스터는 CNPG의 빈 아카이브 검사로 멈춘다[S32] |
| ObjectStore가 Cluster보다 늦으면 "barman object configuration not found"로 무한 requeue | `platform/cnpg/prod/object-store.yaml:7-20` | 같은 Application 안에서 ObjectStore wave를 앞에 |
| 자격 Secret은 그것을 쓰는 CR보다 먼저 있어야 한다 | `platform/cnpg/prod/kustomization.yaml:46-56` | ExternalSecret wave를 CR보다 앞에, 준비 확인 |
| plugins·managed roles 같은 atomic 리스트는 서버 기본값까지 적어야 한다 | TD:105-123, `platform/cnpg/prod/cluster.yaml:84-86`, `:108-110` | Cluster plugins 항목에 기본값 명시 |
| CNPG operator 차트 values는 top-level이어야 한다(umbrella로 감싸면 조용히 무시). 벤더 Deployment의 `args`를 strategic patch하면 통째로 지워진다 | `platform/cnpg/operator/values.yaml:1-5`, `platform/cnpg/barman-plugin/kustomization.yaml:14-21`, TD:2258 | 공식 차트 직접 사용, patch 없이 values로 |
| Pooler의 예약 파라미터는 webhook이 거부하고, transaction 풀링은 startup GUC·advisory lock과 맞지 않는다 | TD:100-103, `platform/cnpg/prod/pooler.yaml:18-22`, [S38] | Pooler 없이 시작, 마이그레이션은 `pg-rw` 직결 |
| DROP된 role의 passwordStatus가 남는다. `ensure: absent`와 role 제거를 한 revision에 넣으면 cannotReconcile | TD:2498-2528, `tools/teardown-resource.ts:8-10` | 폐기는 단계 PR 둘(C.5.5), role 준비 확인은 실제 접속으로 |
| 덤프 잡이 `set -euo pipefail`로 DB 목록을 돌면 DROP된 DB 하나가 뒤 덤프를 모두 죽인다 | `tools/teardown-resource.ts:15-16` | 덤프를 둔다면 DB마다 별도 Job |
| 복원 드릴: EXIT trap만으로는 고아 Cluster가 남고, Cluster를 지워도 PVC가 남아 재사용되면 "검증된 복원"이 거짓 | TD:1221-1282, TD:1245-1247 | 복원용 클러스터는 고유 이름, 끝나면 Cluster와 PVC 모두 지우고 확인 |
| PG major 업그레이드는 서버·백업·클라이언트 이미지를 함께. `runAsUser`가 passwd에 없으면 libpq 기본 사용자 실패 | TD:485-491, TD:78-80 | 복원·덤프 Job은 클러스터와 같은 CNPG PostgreSQL 이미지, `PGUSER` 명시 |
| WaitForFirstConsumer PVC + 파드 없는 sync가 PostSync 훅을 막는다 | `platform/cnpg/prod/basebackup-pvc-warmup.yaml:3-13` | PostSync 훅을 데이터 Application에 두지 않는다 |
| Valkey RWO PVC + RollingUpdate 교착, 자격을 argv로 넘기면 ps에 노출. 공식 차트는 인증 기본이 꺼져 있고 켜면 `default` 사용자를 반드시 정의해야 한다 | `tools/provision-cache.ts:105`, `platform/cache/prod/backup-cronjob.yaml:60`, [S43] | `deploymentStrategy: Recreate`, `REDISCLI_AUTH` env, `auth.enabled: true` + default 사용자 |
| `--cascade=orphan`으로 남은 PVC는 Bound라 phase만 보는 감사로 못 잡는다 | `scripts/audit-orphan-pv.sh:6-13` | `data list`는 소비 여부로 판정 |
| 새 파드는 시작 직후 잠깐 상대 NetworkPolicy의 허용 집합(파드 IP 집합)에 없어 첫 접속이 거부된다. Job 재시도는 새 파드라 같은 창에 다시 걸린다 | T11 시나리오 4(2026-10-23): 영속 Valkey 백업 Job 3회 모두 `Connection refused`, 진단 파드에서 0초 거부·0.25초 뒤 허용(k3s kube-router). kind 로컬 시험에는 이 지연이 없다 | 시작하자마자 같은 클러스터 안 상대에 붙는 컨테이너(백업 스냅샷 등)는 스크립트 안에서 재시도한다(데이터 차트 1.0.1) |

**E7 CLI와 셸**

| 함정 | 근거 | 대응 |
|---|---|---|
| 변이 호출이 타임아웃이면 결과는 "실패"가 아니라 "미상"이고, 재시도는 두 번 실행이다 | `tools/README.md:264-272` | 재시도 대신 상태 재조회 후 이어 하기 |
| 같은 플래그를 두 번 받는 파서는 `--confirm` 파괴 확인을 우회시킨다 | `tools/README.md:442-445` | 중복 플래그 거부 |
| `bun link`는 절대경로 고정이라 worktree에서 하면 전역 명령이 끊긴다. mise·asdf의 bun은 `$BUN_INSTALL/bin`을 PATH에 넣지 않는다 | `tools/README.md:211-217` | `bun build --compile`로 단일 실행 파일을 `~/.local/bin`에 |
| NUC에서 docker compose 포트를 접두 없이 열면 LAN 전체에 열린다 | `tools/dev-postgres/compose.yaml:10-14` | 템플릿 compose는 `127.0.0.1:` 접두 |
| 셸 검사 함정: `done < <(cmd)`는 실패를 전파하지 않음, en_US `sort -u`가 `-1`과 `1`을 같게 봄, pipefail 아래 `grep -q`가 SIGPIPE 거짓 실패, 인용 안 한 heredoc의 백틱 실행, `\|\| true`가 앞 실패를 삼킴 | `scripts/lib/scan-floor.sh:6-9`, `scripts/check-locale-collation.sh:4-9`, `scripts/check-sigpipe-writers.sh:5-10`, TD:2035, TD:1761 | 검사는 TypeScript로 쓰고 셸은 짧게. `LC_ALL=C` |
| 0건을 처리하고 성공하는 검사는 검사가 아니다 | TD:651, `tests/gates/test_guard-skip-signalling.bats:5` | 직접 쓴 검사는 대상 0건이면 실패 |
| kubectl 1.36은 하위 명령 앞에 전역 플래그(`kubectl options`의 `-n`·`--context` 등)만 받는다. `-A`·`-o`·`-l`은 `get`의 플래그라 앞에 두면 `flags cannot be placed before plugin name`으로 끝난다. argv를 그대로 맞추는 시험 스텁은 이 순서를 못 잡는다 | T12-05 운영(2026-10-26): `homelab data list`·purge PV 확인 실패, #894 | 하위 명령 플래그는 하위 명령 뒤에. 시험 스텁도 같은 순서를 거부한다(`cli/test/kubectl-order.ts`) |
| 단위 시험이 저장소의 실제 `data/`·`apps/` 파일을 읽으면, 그 파일을 바꾸는 운영 PR(CLI가 만든 purge PR 등)의 필수 `ci`가 깨진다 | T12-05 운영(2026-10-26): purge PR #906·#907 ci 실패, #908 | 시험은 fixture만 읽는다 |
| 앱·데이터 Application의 source revision은 차트 태그다(values는 ApplicationSet이 main에서 읽어 넣는다). main 병합으로 `status.sync.revision`이 움직이지 않아, 병합 커밋과 같아지기를 기다리면 끝나지 않는다 | T12-05 운영(2026-10-26) 4-1, `platform/appsets/apps/files/applicationset.yaml` | 반영 확인은 파드 imageID(= `image.yaml` digest)와 리소스·ExternalSecret 상태로 한다 |
| 옛 저장소의 `bun link`가 남긴 `~/.bun/bin/homelab`이 PATH 앞에서 새 실행 파일을 가린다 | T12-05 운영(2026-10-26) 0단계 | `homelab doctor`가 PATH의 첫 `homelab`이 실행 중인 파일인지 본다(#894). 옛 링크는 지운다 |

**봇 자리 설계에 쓰는 옛 AIOps 교훈**

| 교훈 | 근거 | 반영 |
|---|---|---|
| 같은 저장소 Draft PR도 CI를 실행하고 옛 IaC plan은 운영 자격을 썼다. Draft만으로 실행과 자격을 분리할 수 없다. PR 코드는 workflow 권한을 높여 요청할 수 있다 | `docs/decisions/0009-aiops-fork-pr-boundary.md:10-13`, ADR 0010:21-23 | 봇 PR은 자격 없는 CI만 받고, 운영 자격은 main 전용 environment에만(C.8) |
| 광역 App 개인 키로 좁은 토큰을 발급하면 그 키가 넓은 권한을 다시 발급할 수 있다. 역할마다 App을 나눈다 | `docs/reviews/aiops-codex/input/research.md:295-296`, `docs/aiops.md:91-93` | 배포·병합·리뷰·봇 변경 PR App을 각각 분리(C.4.7, C.8) |
| 모델·검증기에는 GitHub 쓰기 자격을 주지 않는다. 게시기는 merge, ready, auto-merge, dispatch를 하지 않는다 | ADR 0010:16-17 | 격리 공간에는 쓰기 자격 없음, D-24 App 권한에서 workflows·actions 제외 |
| 기존 writer 키를 다른 호스트로 복사하는 것은 단순 재사용이 아니다(ruleset bypass 신원) | `docs/reviews/aiops-codex/input/research.md:305-309` | 봇은 새 신원과 새 브랜치 접두사 `bot/` |
| NUC를 self-hosted runner로 등록하지 않는다 | `docs/reviews/aiops-codex/input/design.md:267-268` | GitHub 호스티드 러너만 |
| worktree·sandbox 설정만 보고 격리됐다고 판정하지 않는다. 모의 비밀 읽기, 임의 외부 쓰기, 운영 변경 거부를 실측한다 | `docs/reviews/aiops-codex/input/design.md:210`, `:279` | C.8 격리 공간의 준비 확인 명령 |
| 증거 수집은 Secret과 Pod env를 고르지 않고 로그의 자격 표기를 지운다 | `docs/aiops.md:29-33` | 봇 읽기 RBAC에서 secrets·configmaps·pods/log 제외(C.8) |

### B.9 D-27: NUC 로컬 전용 자료 없이 판정한 곳

T04는 로컬 런북(`~/workspace/homelab/docs/runbooks/`, `~/workspace/homelab-infra/`)을 읽지 않았다. 교훈 표의 판정 중 로컬 자료가 꼭 있어야 하는 행은 없다. 옛 주석이 런북을 가리키는 절차(AdGuard 폴백 드릴, `restore.md` 경로 등)는 새 구조에서 새로 설계했다. 다만 아래 셋은 로컬 자료로 보완해야 목록이 완전해진다.

| 위치 | 이유 | 보완할 티켓 |
|---|---|---|
| E1 자격 폐기 표의 완전성 | 공개 근거(`policy/credential-expiry.json` 11행, 코드 선언, `gh api` 실측)로 만든 목록이라 코드 밖 자격(콘솔에서 만든 토큰 등)이 빠졌을 수 있다 | T06(D-27이 허용하면 `token-inventory` 류 런북을 읽기 전용으로, 이름만 옮김) |
| AdGuard 라이브 설정 | 시드(`platform/adguard/prod/adguardhome.yaml`)와 라이브가 다를 수 있다(ADR 0007:26-29). 필터·클라이언트 이름은 로컬 PVC에만 있다 | T06 선행 확인 2(내보내기, 저장소 밖) → E4 입력 |
| `~/workspace/homelab-infra/`의 내용 | 무엇이 있는지 알 수 없어 저장소에 없는 운영 자산이 있는지 판정하지 못했다 | T06 선행 확인 2(보존 점검) |

**T06 할 일 1(2026-10-18)에서 닫음:** 첫째 줄은 로컬 런북 대조로 자격 9줄을 더해 닫았다. 셋째 줄은 `homelab-infra`가 인계·계획 문서뿐이라 닫았다(저장소에 없는 운영 자산 없음). 둘째 줄(AdGuard 라이브 설정)은 T06 선행 확인 2의 내보내기로 닫는다. 결과는 T06 "할 일 1 결과"에 있다.

### B.10 커버리지 요약

방법: 이 문서의 B절에서 `| ID | 경로(glob) |` 머리를 가진 표의 둘째 열 백틱 토큰을 뽑아 중괄호를 펼치고, `git -C /home/ukyi/homelab ls-tree 2d2054a <dir>/`의 1단계 항목에 `fnmatch`로 대조했다(2026-10-17 실행, 스크립트는 저장소 밖 조사 작업 폴더). `tests/gates`·`tests/posture` 디렉터리 항목은 하위 항목이 하나라도 덮이면, `.github/workflows`·`.github/actions`는 하위 항목이 모두 덮이면 덮인 것으로 센다. `NUC:` 행은 호스트 행으로 따로 센다.

| 범위 | 1단계 항목 수 | 덮은 수 | 두 행 이상 | 표 |
|---|---|---|---|---|
| `infra/` | 6 | 6 | 0 | B.1 |
| `platform/` | 17 | 17 | 0 | B.1 |
| `apps/` | 2 | 2 | 0 | B.1 |
| `ops/` | 2 | 2 | 0 | B.1 |
| `tools/` | 45 | 45 | 0 | B.2 |
| `scripts/` | 44 | 44 | 0 | B.2 |
| `tests/` | 23 | 23 | 0 | B.2 |
| `tests/gates/` (하위) | 127 | 127 | 0 | B.2 |
| `tests/posture/` (하위) | 5 | 5 | 0 | B.2 |
| `policy/` | 11 | 11 | 0 | B.2 |
| `docs/` | 10 | 10 | 0 | B.3 |
| `.github/` | 3 | 3 | 0 | B.3 |
| `.github/workflows/` (하위) | 26 | 26 | 0 | B.3 |
| `.github/actions/` (하위) | 9 | 9 | 0 | B.3 |
| 루트 파일(blob) | 16 | 16 | 0 | B.3 |
| `.claude/` | 3 | 3 | 0 | B.3 |
| 호스트 수준(NUC) | design-prompt §3 목록 4묶음 + k3s | 9행 | 해당 없음 | B.4 |

저장소 표 122행(B.1 27, B.2 50, B.3 45)과 호스트 9행이다. 어느 1단계 항목에도 맞지 않는 glob은 0개, 행 ID 중복은 0개다. 루트의 tree 항목(`apps/ infra/ ops/ platform/ policy/ scripts/ tests/ tools/ docs/ .github/ .claude/`)은 각 디렉터리 행이 덮는다.

---

## C. 목표 구조

이 절 전체가 설계 제안이다. 문장 안의 사실은 근거를 달았고, 확인하지 못한 가정은 `[미검증]`으로 표시했다.

### C.1 저장소 배치

```text
homelab/                          (목표 예시)
├── README.md  AGENTS.md  CLAUDE.md(@AGENTS.md)  .gitignore  .gitleaks.toml
├── .pre-commit-config.yaml  .tool-versions  renovate.json  package.json  CODEOWNERS
├── host/                         호스트 설정. 사람이 편집, 사람이 sudo로 적용
│   ├── versions.env              클러스터 공통: k3s 버전, 타임존, 노드 업스트림 DNS
│   ├── clusters/prod.env  vm.env 클러스터별: 노드 이름·IP, 인터페이스, TLS SAN(E8 VM 격리)
│   ├── k3s-config.yaml           /etc/rancher/k3s/config.yaml 원본(클러스터별 값은 자리표시, install.sh가 렌더)
│   ├── etc/                      drop-in (resolved, networkd, sshd, journald, tmpfiles)
│   └── install.sh  preflight.sh  verify.sh
├── platform/                     플랫폼 구성 요소. 사람이 편집, Argo CD가 적용
│   ├── argocd/                   Kustomize: 공식 install.yaml(v3.5.5) + patch
│   ├── root/                     root Application(클러스터마다 하나)과 구성 요소별 Application(각자 wave·retry),
│   │                             클러스터별 값 values-prod.yaml·values-vm.yaml(E8 VM 격리)
│   ├── appsets/                  ApplicationSet apps, data와 AppProject
│   ├── namespaces/ external-secrets/ cert-manager/ traefik/ cloudflared/ tailscale/
│   ├── adguard/ go/(짧은 주소, C.3.5) observability/ cnpg/ sandbox/ bot-slot/(봇 자리, C.8)
│   └── charts/app/  charts/app-data/      공유 차트(git 태그로 버전)
├── apps/<app>/values.yaml        사람 소유. CLI가 처음 한 번 쓴다
├── apps/<app>/image.yaml         배포 App 소유(자동 생성 결과물). 사람은 롤백 때만
├── data/<app>/values.yaml        사람 소유. CLI가 처음 한 번 쓴다
├── infra/cloudflare/  infra/tailscale/  infra/tailscale-dns/    Terraform root(owner 로컬 apply). Tailscale DNS 설정은 ACL과 나눈 별도 root(C.3.6)
├── infra/github/                 Terraform root(ruleset·environment·Actions 권한, guard, app-repos.json, tests/. owner 로컬 래퍼만, E5, C.3.9)
├── tools/tf-github.sh            GitHub root 래퍼(E5. E7부터 `homelab github`가 같은 규칙으로 감싼다)
├── cli/                          Bun·TypeScript CLI
├── .github/workflows/            ci.yaml, app-build.yaml(공통 reusable), deploy-merge.yaml, README.md
└── docs/                         plans/, runbooks-public/(bootstrap.md, restore.md, rotate.md, recovery-assets.md)
```

- 사람이 편집하는 원본과 자동 생성 결과물을 파일 단위로 나눈다. 자동 생성 파일은 `apps/<app>/image.yaml` 하나뿐이다.
- 앱(`apps/`)과 데이터(`data/`)를 다른 최상위 디렉터리에 둔다. `git rm -r apps/<app>`이 데이터 선언을 건드릴 수 없게 하기 위해서다(C.5.5).
- 차트 밖 매니페스트를 앱 디렉터리에 두지 않는다(옛 appset source #3 금지, B.5). 차트가 못 하는 일은 차트 기능으로 넓히되 소비자가 둘 이상일 때만(ADR 0004).

### C.2 설정·데이터·자격증명의 소유자

"원본"은 사람이 값을 바꾸는 곳이고, "사본"은 자동으로 만들어지는 실행용 복제다. 한 대상의 원본은 하나다.

| 대상 | 원본 | 사본·결과물 | 바꾸는 주체 | 비고 |
|---|---|---|---|---|
| 호스트 설정 | `host/` | 노드의 `/etc/...` 파일 | 사람(`host/install.sh`, sudo) | Argo CD 밖. 라이브와 Git 대조는 `host/verify.sh` |
| k3s 버전 | `host/versions.env` | 라이브 k3s | 사람 | 핀을 병합해도 라이브는 안 바뀐다(B.8 E2) |
| 플랫폼 구성 | `platform/**` | 클러스터 리소스 | Argo CD | 사람은 PR로만 |
| 앱 배포 설정 | `apps/<app>/values.yaml` | Deployment·Service·Ingress·NetworkPolicy·ExternalSecret·Job | Argo CD | 앱 저장소에는 배포 설정을 두지 않는다 |
| 배포 이미지 | `apps/<app>/image.yaml` | 파드 이미지 | 배포 App(자동), 사람(롤백) | digest와 소스 revision |
| 앱 데이터 선언 | `data/<app>/values.yaml` | Database·DatabaseRole·Valkey·백업 Job | Argo CD | 앱 Application과 다른 Application |
| 공개 DNS·터널·zone 설정·WAF·백업 버킷 | `infra/cloudflare` | Cloudflare | 사람(`terraform apply`) | CI는 apply하지 않는다 |
| tailnet ACL과 DNS 설정 | `infra/tailscale`(ACL)과 `infra/tailscale-dns`(`tailscale_dns_configuration`, 별도 root, C.3.6) | Tailscale | 사람(`terraform apply`) | DNS 설정(Override, 전역 nameserver, MagicDNS)도 코드로 둔다(D-08). 옛 "매 apply마다 nameserver를 비우는 경쟁"은 다른 DNS 리소스를 함께 쓴 탓으로 보고(추측, `2d2054a:infra/tailscale/acl.tf:79-82`) 그 리소스를 두지 않는다. NUC IP는 Git에 두지 않고 `data.tailscale_devices`로 읽는다. 확인은 `tailscale dns status --all` |
| GitHub 보호 설정(ruleset, environment와 배포 정책, Actions 권한) | `infra/github` Terraform root | GitHub. state는 R2 `v2/github/terraform.tfstate` | 사람(owner 로컬 래퍼 `tools/tf-github.sh`, E7부터 `homelab github plan`·`apply`) | 저장소 설정(`allow_auto_merge=false`, squash만, 병합 뒤 삭제)과 fork PR 승인 정책은 리소스가 아니라 `gh api`로 맞추고 guard가 확인한다. 대조는 `homelab github verify`(= plan과 guard). CI는 plan하지 않는다(C.3.9, D-28) |
| AdGuard 설정 | Git 시드 `platform/adguard/seed/` | 라이브 PVC의 `AdGuardHome.yaml` | 사람(Git), 라이브는 UI | 원본 선언: 재구축 때 살아남는 것은 Git 시드뿐이다. UI에서 바꾼 것 중 남길 것은 시드로 옮긴다(ADR 0007 방식). LAN 기기 이름은 시드에 넣지 않는다 |
| PostgreSQL 데이터 | CNPG Cluster `pg`의 PVC | R2 base backup + WAL(14일) | 앱, CNPG | C.3.8 |
| 영속 Valkey 데이터 | 앱 ns의 PVC | R2 RDB(하루 1회, 14일) | 앱, 백업 Job | 캐시용 Valkey는 메모리만, 백업 없음 |
| 메트릭·로그 | 관측 PVC | 없음 | 관측 스택 | 유실 허용(재생성 불가지만 운영 판단에 필수 아님) |
| Grafana 대시보드 | Git(provisioning) | Grafana | 사람 | UI 저장은 남지 않는다 |
| 앱 시크릿 | Infisical `homelab`/`prod` `/apps/<app>` | 앱 ns의 Kubernetes Secret | 사람(값), ESO(사본) | Git에는 참조만 |
| 앱 DB·Valkey 비밀번호 | Infisical `/apps/<app>/postgres`, `/apps/<app>/valkey` | `database` ns의 basic-auth Secret, 앱 ns의 연결 Secret | CLI(최초 1회 생성), 사람(회전 명령) | 원본 하나, 사본 둘 |
| 플랫폼 시크릿 | Infisical `/platform/<구성 요소>` | 해당 ns의 Secret | 사람 | 터널 토큰, Tailscale operator OAuth, R2 백업 키, Telegram 봇 토큰, healthchecks ping URL, Grafana·AdGuard·Argo CD 관리자 자격 |
| Terraform 자격(Cloudflare zone·터널, Tailscale ACL·DNS, R2 state) | Infisical 프로젝트 `homelab-admin`(machine identity 없음, 사람만). R2 state 키는 모든 root가 함께 쓰는 `/terraform/state`에만 두고, provider 자격은 root별 경로 `/terraform/cloudflare`·`/terraform/tailscale`에 둔다. GitHub 래퍼는 `/terraform/state`만 읽는다(C.3.9) | 실행 중 프로세스 env | 사람(`infisical run` 두 번을 겹친 명령, C.3.9 표) | 로컬 `.env.secrets`·`terraform.tfvars` 파일을 두지 않는다. 클러스터(ESO)와 CI identity가 들어가지 않는 프로젝트라 클러스터가 뚫려도 이 자격은 안 샌다(C.6.3). GitHub root의 토큰은 여기 두지 않는다: 사람의 `gh auth token` 또는 범위를 줄인 만료 있는 fine-grained PAT를 실행 때 `GITHUB_TOKEN` 환경변수로만 넘긴다(C.3.9) |
| GitHub App 키(배포·병합) | Infisical 프로젝트 `homelab-ci-deploy`(배포 키), `homelab-ci-merge`(병합 키). 키마다 프로젝트 하나 | 배포 키: Actions 실행 중 메모리(OIDC identity `gha-homelab-deploy`로 조회). 병합 키: homelab environment `automerge`의 secret `HOMELAB_MERGE_KEY` 하나(Infisical Secret Sync 사본) | 사람(발급·Infisical 등록). GitHub 쪽 사본은 sync가 쓴다 | 배포 키는 GitHub에 사본이 없다. 병합 키 사본 하나는 C.6.2 규칙의 유일한 예외다(C.4.8, D-04) |
| Infisical GitHub 연결 PAT | Infisical App Connection(owner 계정의 fine-grained PAT, homelab만, Metadata read·Environments RW·Secrets RW, 만료 없음: 사용자 2026-10-21) | 없음 | 사람(발급, 샌 의심·범위 변경 때 교체) | 병합 키 sync 전용. 회수되면 sync가 실패하고 Infisical이 프로젝트 Admin에게 메일을 보낸다[S203]. org가 fine-grained PAT를 허용해야 한다(C.4.8) |
| ESO 부트스트랩 자격 | 저장소 밖 복구 자산 | `external-secrets` ns의 Secret 1개 | 사람(클러스터마다 한 번 `kubectl`) | 평상시 기준으로 유일하게 사람이 손으로 넣는 Secret. VM 시험(E8 VM 격리 3번)에서는 복구 원본 R2 읽기 자격 Secret 하나를 더 손으로 넣고(Infisical 밖, 복구 자산의 읽기 전용 토큰) 복구가 끝나면 지운다. VM의 ESO 부트스트랩 Secret은 복구 자산이 아니라 VM 준비 자산의 `eso-homelab-dev` 자격으로 만든다(E8 VM 격리 2번). Infisical 장애 분기는 따로다: 암호화 내보내기에서 필요한 플랫폼·앱 Secret을 손으로 만들고 기록한 뒤 장애가 끝나면 ESO 관리로 되돌린다(C.6.4) |
| 시스템이 자동 발급·갱신하는 자격 | 그 시스템 | 그 시스템 | 그 시스템 | Argo CD 내부 키, CNPG 내부 인증서·복제 사용자, cert-manager 내부 인증서, `*.ts.net` 인증서, Cloudflare edge 인증서, App 설치 토큰(1시간), Infisical access token |
| k3s kubeconfig·노드 토큰 | NUC `/etc/rancher/k3s/`(root 0600) | 운영자 기기의 kubeconfig 사본 | 사람 | 저장소·Infisical에 두지 않는다. context 이름에 클러스터를 각인 |

### C.3 기반 플랫폼

#### C.3.1 구성 요소, 버전 고정, 부트스트랩 순서

버전은 2026-10-17 최신 안정판이다(사실, 근거 열). "미검증" 버전은 이번 조사에서 공식 릴리스를 확인하지 않은 것이라 E단계 시작 때 정해 고정한다.

| 구성 요소 | 선택 | 버전 | 고정 방식 | 순서 | 준비 확인 |
|---|---|---|---|---|---|
| OS | Ubuntu 26.04.1 LTS 유지(D-12) | 26.04.1(실측) | 해당 없음 | E2 시작 | `lsb_release -d` |
| k3s | 단일 서버, 내장 Traefik·metrics-server 끔. servicelb·local-path·CoreDNS·flannel·kube-router netpol은 유지 | v1.36.5+k3s1(stable)[S50][S56] | `host/versions.env`의 `INSTALL_K3S_VERSION` + `host/k3s-config.yaml` | E2 호스트 | `kubectl get node -o wide` Ready, `k3s --version` |
| Argo CD | 공식 install.yaml을 Kustomize base로, 자기 관리 | v3.5.5(3.5는 Kubernetes 1.33~1.36 시험)[S60][S61] | Kustomize 원격 base URL의 태그 | wave -10 | `kubectl -n argocd get deploy,sts` 전부 Ready, root Application Synced·Healthy |
| 플랫폼 ns | ns·PSA 라벨 선언 | 해당 없음 | Git | -9 | `kubectl get ns -L pod-security.kubernetes.io/enforce` |
| External Secrets Operator | Infisical provider, Universal Auth | v2.13.0, chart 2.13.0(Kubernetes 1.36 지원)[S20][S24] | Application의 chart semver | -8 operator, -7 ClusterSecretStore | `kubectl get clustersecretstore` 모두 `Ready=True`(E3 뒤 `infisical-platform`·`infisical-apps` 둘, E4b 뒤 `infisical-sandbox` 포함 셋) |
| cert-manager | 클러스터 안 인증서만(Barman plugin TLS)[S33] | 미검증(E4) | chart semver | -7 | `kubectl -n cert-manager get deploy` Ready, 시험 Certificate Ready |
| CNPG operator + Barman Cloud Plugin | 공식 차트 | operator 1.30.1(chart `cloudnative-pg` 0.29.1), plugin v0.15.1(chart 0.8.1)[S36]. 2026-10-23에도 최신(T11) | chart semver + 이미지 digest(sidecar 포함) | -6 | `kubectl -n cnpg-system get deploy` Ready |
| Traefik | 공개 HTTP 라우팅만, Service는 ClusterIP | 미검증(E4) | chart semver | -5 | `kubectl -n traefik get deploy` Ready, 시험 Ingress 응답 |
| cloudflared | 원격 관리 터널 커넥터 | 2026.10.1(2026.8.0·8.1은 쓰지 말라는 경고)[S133] | 이미지 태그 + digest | -5 | 커넥터 `/ready` 200, `curl -sI https://<시험 host>.ukyi.app` |
| Tailscale operator | 내부 UI Ingress(`*.ts.net`) | chart 1.104.1[S114][S116] | chart semver | -5 | operator Ready, Ingress `status.loadBalancer.ingress[0].hostname`이 `*.ts.net` |
| AdGuard Home | LAN `:53` | v0.107.79[S152] | 이미지 digest | -5 | `dig @192.168.117.15 example.com +short` 응답 |
| 관측 | VictoriaMetrics single, vmalert, Alertmanager, Grafana, VictoriaLogs single, vector, node-exporter, kube-state-metrics | Alertmanager 0.34.1[S164], 나머지 미검증(E4) | chart semver | -4 | C.3.7 |
| CNPG 클러스터 `pg` + ObjectStore + ScheduledBackup | 공유 클러스터 | PostgreSQL 18.6, 이미지 `18.6-standard-trixie`(T11). 1.30.1 기본은 `-system-` 변형(standard + barman-cloud 바이너리, in-tree `barmanObjectStore`용)이다. postgres-containers README가 system을 deprecated로 두고 in-tree Barman Cloud 지원이 빠질 때(1.31.0 예정) 없앤다고 적어 plugin과 함께 쓰는 standard로 한다[S36] | 이미지 태그 + digest | -3 | `kubectl -n database get cluster pg`가 "Cluster in healthy state", 첫 백업 `completed` |
| 격리 작업 공간 + egress 프록시 | C.8 | 프록시 이미지 미검증(E4) | 이미지 digest | -2 | C.8 준비 확인 |
| ApplicationSet `apps`, `data` | 앱·데이터 등록 | 해당 없음 | Git | 0 | `kubectl -n argocd get applicationsets` |
| 짧은 주소 리다이렉터 `go` | C.3.5(nginx-unprivileged, operator LoadBalancer Service HTTP 80, ns `go` restricted). D-30 | nginx 1.30.6(2026-10-21 stable) | 이미지 digest | 1(맨 뒤. 실패해도 다른 구성 요소를 막지 않는다) | C.3.5 준비 확인 |
| 봇 자리 Application `bot-slot` | C.8(봇 ns의 NetworkPolicy·읽기 전용 SA, sandbox 작업자 ingress 허용. E4b~E8은 시험 ns) | 해당 없음 | Git(작은 Helm 차트 `platform/bot-slot`) | 1(맨 뒤, retry 무제한·`refresh: true`) | C.8 준비 확인 |
| 공유 차트 `app`, `app-data` | 앱·데이터 렌더 | `app-chart-v1.0.0`, `data-chart-v1.0.0`(시작값) | git 태그 | 앱마다 | C.4.5 |
| Valkey | 공식 차트(데이터 차트의 subchart) | chart 0.12.0(appVersion 9.1.2)[S43] | `Chart.lock` + 벤더한 tgz | 앱마다 | C.5.6 |

순서 근거: 시크릿이 필요한 모든 구성 요소보다 ESO와 ClusterSecretStore가 먼저다. Barman plugin은 cert-manager 뒤다. 앱과 데이터는 맨 뒤다. 각 wave는 root Application이 자식 Application의 Healthy를 기다리도록 health 사용자 정의를 켠다(C.3.3). 봇 자리(1)는 봇 ns를 만드는 앱 Application(ApplicationSet `apps`, 0)보다 뒤다. 봇 자리는 대상 ns를 만들지 않으므로, 빈 클러스터에서 봇 ns가 아직 없으면 sync가 실패한 채 무제한 retry(`refresh: true`라 재시도마다 최신 revision)로 기다린다. 이보다 뒤 wave는 없고, root의 sync는 마지막 wave의 일반 리소스를 적용하면 그 health를 기다리지 않고 끝난다[S183]. 그래서 이 기다림은 교착이 아니고 다른 Application으로 번지지 않는다(C.8 봇 자리 Application).

#### C.3.2 호스트·k3s

**부트스트랩 절차** (`docs/runbooks-public/bootstrap.md`가 이 순서를 그대로 적는다. 시나리오 13의 입력)

0. 클러스터 이름을 고른다: 운영 NUC는 `prod`, 시나리오 13의 VM은 `vm`. 아래 host 스크립트는 모두 `--cluster <이름>`을 받아 공통 `host/versions.env`와 클러스터별 `host/clusters/<이름>.env`(노드 이름·IP, 인터페이스, TLS SAN)를 함께 읽는다. 같은 이름이 kubeconfig context 각인(VM은 `homelab-vm`)과 root 파일(C.3.3의 3)을 정한다(E8 VM 격리 1번). `vm.env`의 값은 VM을 준비할 때(E8 사람 작업) 그 VM의 노드 이름·IP·인터페이스로 채운다. `vm.env`의 노드 이름은 운영과 겹치지 않게 `vm-` 접두로 정한다(예: `vm-node`. 파괴 명령 전 노드 이름 확인이 두 클러스터를 가른다, 아래 판정 표). **VM 호스트는 tailnet에 넣지 않는다**(D-12, 확정(사용자 2026-10-18, T05). E8 VM 격리 4번). `vm.env`는 `TAILNET_JOIN=false`이고, host 스크립트는 이 값이 false면 2번의 Tailscale 단계를 건너뛰고 3번의 TLS SAN에서 MagicDNS 이름을 뺀다(클러스터 이름 분기가 아니라 값으로 가른다). VM 접근은 LAN 주소나 콘솔로 한다. 운영 NUC는 tailnet에 없을 때만(OS를 다시 설치했을 때) Tailscale을 설치해 등록한다. **`tailscale up` 전에 Tailscale 콘솔에서 옛 NUC 호스트 기기를 지운다.** 남아 있으면 새 등록 이름에 `-1`이 붙고, 옛 기기를 나중에 지워도 이름이 되돌아가지 않는다(E8 VM 격리 4번과 같은 함정). 그다음 사람이 `docs/runbooks-public/bootstrap.md`와 같은 플래그로 `sudo tailscale up --hostname=<노드 이름> --accept-dns=false --advertise-tags=tag:nuc --advertise-routes=192.168.117.1/32`를 실행해 로그인하고(D-11 (c). `--ssh`는 주지 않는다), **`tailscale status --self --peers=false --json | jq -r '.Self.DNSName | rtrimstr(".")'`의 첫 라벨이 `prod.env`의 `NODE_NAME`과 같은지 확인한다.** MagicDNS 전체 이름은 tailnet 이름을 담으므로 공개 저장소의 env 파일에 두지 않는다. install.sh가 같은 명령으로 실행 때 얻어 `NODE_MAGICDNS`로 쓴다. 다르면 k3s TLS SAN, tailnet kubectl, `ssh <NUC>` 확인이 어긋난다. 그 뒤 키 만료를 해제한다(E2). 다시 등록해 Tailscale IP가 바뀌었으면 DNS Terraform을 apply해 전역 nameserver의 NUC 주소를 갱신한다(C.3.6. 그 전에는 공용 서버가 답한다). 2번의 `tailscale set --accept-dns=false`가 이 등록을 전제로 한다.
1. `host/preflight.sh --cluster <이름> --before`: 설치 전 확인. 노드 IP가 `host/clusters/<이름>.env`와 같음, k3s 잔여 경로(`/var/lib/rancher/k3s`, `/var/lib/rancher/k3s-storage`, `/etc/rancher/k3s`) 부재. 하나라도 실패하면 중단. 타임존, DNS, 스왑은 여기서 보지 않는다. 그 값은 2번이 적용하므로(스왑 제거는 H6), 새 VM이나 다시 설치한 호스트가 1번에서 멈춰 2번에 닿지 못하기 때문이다.
2. `sudo host/install.sh --cluster <이름> --host-config`: `host/etc/` 파일 목록을 그대로 복사(확장자 화이트리스트 열거 없이). 인터페이스 이름이 경로에 들어가는 networkd drop-in(옛 `10-netplan-wlo1.network.d/`, `2d2054a:infra/k3s-bootstrap/host-config.sh:52`)만 클러스터 값의 인터페이스로 경로를 정해 쓴다. `networkctl reconfigure <iface>` 뒤 IPv4 복귀를 기다림, `tailscale set --accept-dns=false`(`TAILNET_JOIN=false`면 건너뜀, 0번), `timedatectl set-timezone Asia/Seoul`. 적용 뒤 `host/preflight.sh --cluster <이름> --after`가 설정 불변식을 본다: 스왑 없음, 타임존 Asia/Seoul, systemd-resolved 스텁 꺼짐, `/etc/resolv.conf`가 loopback·tailnet·자기 주소가 아님, 링크가 DHCP DNS를 거부. 하나라도 실패하면 3번으로 가지 않는다(옛 `infra/k3s-bootstrap/host-preflight.sh:42-216`의 6항목을 1번과 여기로 나눔. 옛 구성도 host-config 적용을 먼저 마친 뒤 preflight를 돌렸다).
3. `sudo host/install.sh --cluster <이름> --k3s`: `INSTALL_K3S_VERSION`을 고정하고 `host/k3s-config.yaml`의 자리표시를 클러스터 값으로 채워 `/etc/rancher/k3s/config.yaml`로 쓴 뒤 설치(채널 설치 없음)[S51].
4. `host/verify.sh --cluster <이름>`: 노드 Ready, 라이브 node-args 어노테이션이 config와 같은지(옛 `infra/k3s-bootstrap/verify-cluster.sh:44-61` 방식), SAN·노드 이름, `local-retain` StorageClass.
5. 이후 C.3.3.

**k3s 설정** (목표 예시)

```yaml
# host/k3s-config.yaml  (목표 예시. ${...}는 install.sh가 host/clusters/<이름>.env로 채운다)
# prod.env 값: NODE_NAME=nuc-15-pro, NODE_IP=192.168.117.15, TAILNET_JOIN=true
# NODE_MAGICDNS는 env 파일에 두지 않는다. install.sh가 tailscale status --json으로 얻는다(tailnet 이름 비공개)
# vm.env는 TAILNET_JOIN=false(VM 호스트는 tailnet에 넣지 않음, C.3.2의 0)
node-name: ${NODE_NAME}
node-ip: ${NODE_IP}
tls-san:
  - ${NODE_NAME}
  - ${NODE_IP}
  - ${NODE_MAGICDNS}             # 운영자 기기에서 tailnet으로 kubectl. TAILNET_JOIN=false(VM)면 이 줄을 빼고 렌더
disable:
  - traefik                      # Argo CD가 관리하는 Traefik을 따로 둔다
  - metrics-server               # Grafana가 대신한다(kubectl top 없음)
secrets-encryption: true
write-kubeconfig-mode: "0600"
kubelet-arg:
  - "system-reserved=cpu=500m,memory=1Gi"
  - "eviction-hard=memory.available<500Mi,nodefs.available<10%"
```

**`infra/k3s-bootstrap` 하위 항목 판정** (P05의 세부)

| 옛 하위 항목 | 판정 | 새 자리와 이유 |
|---|---|---|
| `versions.env` | 단순화해서 가져옴 | 두 층으로 나눈다. 공통 `host/versions.env`(k3s 버전, 타임존, 노드 업스트림 DNS)와 클러스터별 `host/clusters/<이름>.env`(노드 이름·IP, 인터페이스, TLS SAN. `prod.env`, `vm.env`). bulk 국면 장치와 룰 리터럴 등식은 버린다(`versions.env:136-169`) |
| `k3s-install.sh` | 가져옴 | 플래그 계약(traefik·metrics-server 끔, servicelb 유지, secrets-encryption, kubelet 예약, IP·이름 고정과 SAN 명시(SAN 변경은 재시작으로 반영, B.8 E2), kubeconfig 0600, 버전 고정)을 config 파일로 옮긴다(`k3s-install.sh:56-102`). 단 local-storage는 켠다(아래) |
| `host-config.sh` + resolved·networkd drop-in, `accept-dns=false`, resolv.conf 심링크 | 가져옴 | 노드 DNS 순환 방어(B.8 E2) |
| journald·sshd·tmpfiles drop-in, 스왑 제거, 타임존 | 가져옴 | H4, H6 |
| `host-preflight.sh`, `host-up.sh`, `verify-cluster.sh` | 단순화해서 가져옴 | preflight·install·verify 세 스크립트. 순서가 계약이고, sudo가 필요한 단계는 파이프라인에 넣지 않는다(`host-up.sh:5-14`) |
| `apply-storage.sh`, `storage/**`, `bulk-gate-probe.sh` | 단순화해서 가져옴 | k3s 내장 local-path provisioner를 쓰고 Retain StorageClass `local-retain`(WaitForFirstConsumer) 하나만 더한다. bulk 티어는 소비자가 없어 뺀다 |
| `assert-cluster-identity.sh`, `kubeconfig-identity.sh` | 단순화해서 가져옴 | kubeconfig context 이름 각인 + 파괴 명령 전 노드 이름 확인으로 줄인다. VM 검증 기간에 두 클러스터가 공존한다 |
| `files-data-backup`, `systemd-failed-sweep`, `unit-failure-notify@` 유닛 | 버림 | H3 |
| `versions-read.sh`, `motd/**`, `aiops-*`, `tests/**` | 버림 | 소비자 없음, 범위 밖 |

**디스크와 저장 위치:** k3s 데이터와 PV는 루트 LV(913G, 사용 381G, 남은 약 487G, 실측 `df -hT`)에 둔다. local-path 기본 위치(`/var/lib/rancher/k3s/storage`)라 `k3s-uninstall.sh`가 함께 지운다[S54]. 그래서 철거와 재설치가 단순하고, 데이터 보존은 R2 백업이 맡는다. `/mnt/bulk`(1.8T)는 E1에서 비우고 fstab 항목을 지운 뒤 쓰지 않는다(D-12). local-path는 용량을 강제하지 않는다[S57]. 그래서 디스크 사용량은 경보(C.3.7)로 본다.

**재부팅:** k3s는 `enabled`라 부팅 때 시작한다. 그 뒤 Argo CD가 모든 Application을 다시 맞추고, 준비 상태는 G 시나리오 12의 명령으로 확인한다.

#### C.3.3 Argo CD 경계와 부트스트랩 순서

**최초 설치와 자기 관리의 경계:** 평상시 기준으로 사람이 `kubectl`로 하는 일은 셋뿐이다. 그 뒤 모든 변경은 PR → main이다. VM 시험(E8 VM 격리 3번)에서는 root apply 전에 복구 원본 R2 읽기 자격 Secret 하나를 더 손으로 넣고(Infisical 밖, 복구 자산의 읽기 전용 토큰) 복구가 끝나면 지운다. 이 단계는 `bootstrap.md`의 vm 분기("다른 클러스터에서 복구" 단계)에만 적는다. Infisical 장애 분기는 따로 적는다: ESO가 동기화하지 못하므로 암호화 내보내기에서 필요한 플랫폼·앱 Secret을 손으로 만들고 기록한 뒤, 장애가 끝나면 ESO 관리로 되돌린다(C.6.4의 "Infisical 일시 장애"·"클러스터 유실 + Infisical 장애" 행).

```bash
# 목표 예시 (E2에서 docs/runbooks-public/bootstrap.md로 옮긴다). E3 뒤의 모양이고 복구(시나리오 13, C.6.4)에서 그대로 쓴다.
# 최초 E2에서는 2번을 건너뛴다. 그때 root에는 argocd·namespaces만 있고, ESO·Store와 부트스트랩 Secret은 E3이 함께 더한다.
set -euo pipefail
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts --field-manager=argocd-controller -k platform/argocd  # 1. 고정 버전 설치 [S62][S63]. manager를 Argo CD와 같게(T07 리뷰 2026-10-19)
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic infisical-universal-auth \
  --from-literal=clientId="$ESO_CLIENT_ID" --from-literal=clientSecret="$ESO_CLIENT_SECRET"  # 2. 복구 자산에서(VM은 VM 준비 자산의 eso-homelab-dev 값). 값은 출력하지 않는다
kubectl apply -f platform/root/root-prod.yaml                               # 3. root Application(VM은 root-vm.yaml, E8)
```

- **root 파일과 렌더 범위:** `platform/root`는 Helm 차트로 둔다[권장]. 클러스터마다 하나인 root가 자기 클러스터 값 파일을 `helm.valueFiles`로 읽어 구성 요소 Application의 Helm values로 넘기는 것이 클러스터별 값 전달의 기본이다(E8 VM 격리 1번). 아래 확인 명령과 E2의 손 확인 명령은 이 전제로 `helm template`을 쓴다. 운영 root `root-prod.yaml`과 VM root `root-vm.yaml`은 둘 다 E2에서 같은 모양으로 만든다(이름과 `helm.valueFiles`의 값 파일만 다름). 두 root 파일과 `values-*.yaml`은 차트 루트에 두고 자식 Application은 `templates/`에만 둔다. Helm은 `templates/` 아래만 렌더하므로 운영 root가 같은 디렉터리의 `root-vm.yaml`을 자식으로 만들지 않는다(반대도 같다). 확인: `helm template root platform/root -f platform/root/values-prod.yaml | yq -N 'select(.kind == "Application") | .metadata.name'`에 `root-prod`·`root-vm`이 없다(E2 검증).
- **vm 분기의 추가 단계**(`bootstrap.md`의 vm 분기에 이 순서로 적는다. E8 VM 격리 2·3번): (1) 2번 전에 운영 클러스터(main을 동기화한 결과)의 ExternalSecret 키 목록과 `homelab-dev`의 키를 대조해 빠진 키 0을 확인한다(값은 출력하지 않는다. 클러스터 층 값은 키 이름을 바꾸지 않아 이 목록이 VM이 읽을 목록과 같다, E8 VM 격리 1·2번). 하나라도 빠지면 멈춘다. (2) 2번의 ESO 자격은 VM 준비 자산의 `eso-homelab-dev` 값이다. (3) 3번 전에 복구 원본 R2 읽기 자격 Secret을 넣는다. (4) 3번은 `root-vm.yaml`을 apply한다.
- `platform/argocd/kustomization.yaml`은 `https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml`을 base로 하고 ConfigMap patch만 얹는다. 공식 권장 방식이고 자기 관리 Application에는 `ServerSideApply=true`가 필요하다[S62][S63]. Helm 차트는 커뮤니티 유지라 쓰지 않는다[S61].
- root가 `argocd` Application까지 소유한다. 옛 구성은 자기 관리 App과 root를 부트스트랩에서만 만들어 핀 이동이 한쪽만 될 수 있었다(`2d2054a:scripts/bootstrap.sh:33-44`).
- `argocd` Application은 `selfHeal: true`, `prune: false`로 둔다. 자기 관리 App이 prune으로 자기를 지우지 않게 하는 공식 문서가 없어 보수적으로 간다[미검증, 커뮤니티 사례만].
- 업그레이드는 base URL의 버전 문자열 하나를 바꾸는 PR이다.

**`argocd-cm`·`argocd-rbac-cm` patch** (목표 예시의 요지)

| 키 | 값 | 이유 |
|---|---|---|
| `timeout.reconciliation` | `60s` | 공개 webhook 없이 main 폴링(A.4 3번, 확정(사용자 2026-10-18, T05)). 옛 30초 + webhook(`2d2054a:platform/argocd/bootstrap-values.yaml:293-297`) |
| `timeout.reconciliation.jitter` | `0` | 기본 jitter 1분이 `timeout.reconciliation`에 더해져 실제 간격이 60~120초가 된다. 0이면 jitter를 끈다[S209] |
| `admin.enabled` | `"false"` | 사람은 로컬 계정 `owner`(login), 봇은 `bot-reader`(apiKey만)[S71]. 옛 결정과 같음(`bootstrap-values.yaml:291`) |
| `resource.exclusions` | Endpoints, EndpointSlice, Event | 옛 실측(`bootstrap-values.yaml:305-310`) |
| `resource.customizations.health.argoproj.io_Application` | 공식 문서의 Lua | app-of-apps에서 wave가 자식 Healthy를 기다리게 한다[S69] |
| `policy.default` | 비움 | `policy.default` 권한은 deny로 막을 수 없다[S70]. 계정마다 명시 정책 |
| `resource.customizations.health.external-secrets.io_ExternalSecret` | 내장 Lua를 덮어쓴다. status·conditions가 아직 없으면(ESO가 처음 reconcile하기 전) Progressing. `Ready=True`면 Healthy. `Ready=False`라도 지금 spec으로 동기화한 이력이 있으면(`status.syncedResourceVersion`의 앞부분 generation이 `metadata.generation`과 같으면) Healthy(메시지에 실패 표시). `Ready=False`이면서 그 동기화 이력이 없을 때만 Degraded. ESO는 동기화에 성공할 때만 `syncedResourceVersion`을 `<generation>-<라벨·주석 해시>`로 쓴다(v2.13.0 소스[S24]). 그래서 새 키를 더한 spec 변경(generation 증가)이 실패하면 Degraded이고, spec이 그대로인 갱신 실패(Infisical 장애)는 Healthy다 | 내장 health는 `Ready=False`를 Degraded로 본다[S75]. 그대로 두면 Infisical 장애 때 ExternalSecret(wave 0)이 Degraded가 되어 이미지만 바꾸는 배포까지 뒤 wave에서 멈출 수 있다(추측, [S68]). 장애는 ExternalSecretNotReady 경보가 따로 알린다. 상태가 아직 없는 첫 순간을 Degraded로 보면 첫 sync가 쓸데없이 실패하고 retry로 다시 돌아 Progressing으로 둔다(추측). **[미검증]** E3·시나리오 6·7에서 확인 |

**AppProject**

| 프로젝트 | 대상 ns | 허용 kind | 비고 |
|---|---|---|---|
| `platform` | 전부 | 전부 | 플랫폼 구성 요소. root Application 자신은 `default` 프로젝트다(사용자 결정 2026-10-19, T07): root가 이 프로젝트를 만들므로, root가 여기 속하면 프로젝트가 생기기 전에 Argo CD v3.5.5가 `InvalidSpecError`로 멈춘다. 옛 구성도 `default`였고 `platform`이 전부 허용이라 권한 차이는 없다 |
| `apps` | `app-*` | Deployment, Service, Ingress, NetworkPolicy, ExternalSecret, Job, ServiceAccount, ConfigMap, PodDisruptionBudget, ReplicaSet, Pod. cluster-scoped는 Namespace `app-*`만(이름 glob), Secret 금지 | 옛 허용 목록 방식(`2d2054a:platform/argocd/root/projects.yaml:20-36`). ApplicationSet 템플릿의 `project`는 고정값[S66]. T10(2026-10-20): ApplicationSet의 `CreateNamespace`가 만드는 Namespace도 프로젝트 허용을 검사해 Namespace `app-*`를 더했다(v3.5.5 `gitops-engine/pkg/sync/sync_context.go` autoCreateNamespace가 권한 검사 앞). ReplicaSet·Pod는 UI 트리와 파드 로그용이다(차트는 만들지 않는다) |
| `data` | `database`, `app-*` | Database, DatabaseRole, ExternalSecret, Deployment, Service, PersistentVolumeClaim, ConfigMap, CronJob, Job, NetworkPolicy, ServiceAccount. cluster-scoped 금지 | 데이터 수명 분리. Job은 PUBLIC CONNECT를 막는 PostSync hook `pg-acl-<앱>` 하나 때문이다(데이터 차트 1.0.3, C.5.3, 사용자 결정 2026-10-26, T13). 복원용 Job·임시 Cluster는 여전히 Argo CD가 소유하지 않는다. CLI가 `kubectl`로 만드는 GitOps 밖 일회성 객체다(C.5.7) |

**root 아래 wave와 규칙**

- wave 표는 C.3.1의 "순서" 열이다. 모든 Application에 `retry`(limit 10, backoff 30s → 최대 5m)를 둔다. 봇 자리 Application만 `limit: -1`(무제한[S182])과 `refresh: true`(재시도마다 최신 revision[S185])다. 봇 ns가 생길 때까지 기다려야 해서다(C.8). `refresh`가 없으면 무제한 재시도가 처음 실패한 revision을 계속 쓰고, operation이 Running으로 남아 고치는 PR이 반영되지 않는다.
- Application 안의 wave 규칙(옛 원장에서 남긴 한 줄, `2d2054a:platform/argocd/root/SYNC-WAVES.md:17-22`): **음수 wave를 붙인 리소스를 Healthy로 만드는 주체가 더 앞 wave에 있는가.** 아니면 교착이다.
- sync-wave는 Application 사이 순서를 보장하지 않는다(health 사용자 정의로 root가 기다리게 할 뿐이다). 그래서 G절의 완료 조건은 실제 준비 상태와 접속 확인이다.
- ApplicationSet `apps`·`data`는 git files 생성기(`apps/*/values.yaml`, `data/*/values.yaml`)와 `requeueAfterSeconds: 60`을 쓴다. 공개 webhook이 없어서다. T10(2026-10-20): `apps`는 `apps/*/values.yaml`과 `apps/*/image.yaml` 두 git files 생성기를 merge 생성기(짝 키 `values.app` = 디렉터리 이름)로 묶고, 두 파일의 키를 `templatePatch`로 `helm.valuesObject`에 넣는다. 차트(태그)와 values(main)를 source 둘(`ref: values`)로 나누면 같은 저장소의 다른 revision이라 Argo CD v3.5.5가 거부한다("cannot reference a different revision of the same repository", `reposerver/repository/repository.go`). `missingkey=error`는 두지 않는다. 한 앱의 파일이 깨지면 ApplicationSet 전체 생성이 멈춰 모든 앱의 배포가 서기 때문이다. 빠진 키는 ci의 같은 렌더와 차트 schema가 막는다. ApplicationSet은 클러스터 tailnet 접두를 받으려고 작은 Helm 차트 `platform/appsets/apps`에 두고, AppProject `apps`는 T07이 둔 자리(`platform/root/templates/project-apps.yaml`, wave -11)에 남긴다.

#### C.3.4 외부 공개

```text
인터넷 ──▶ Cloudflare(zone ukyi.app, HSTS, WAF) ──▶ 터널 homelab(원격 관리)
        ──▶ cloudflared(ns cloudflared) ──▶ traefik.traefik.svc:80 ──▶ Ingress(host) ──▶ app-<app> Service
```

- **터널:** 원격 관리 터널을 새로 만든다(Cloudflare 권장[S130], Terraform 리소스[S132]). ingress 규칙은 Terraform 한 곳에만 둔다: `*.ukyi.app`과 `ukyi.app` → `http://traefik.traefik.svc.cluster.local:80`, 마지막은 `http_status:404`[S134][S135]. 커넥터는 1개(롤링 업데이트 `maxSurge: 1`)다. 단일 노드라 복제본을 늘려도 고가용성은 아니다[S131].
- **DNS:** 와일드카드 `*` CNAME과 apex를 터널로(proxied). 어느 이름이 공개되는지는 Git의 Ingress가 정한다. 모르는 host는 Traefik이 404다. [미검증] 원격 관리 터널의 와일드카드 hostname 지원(공식 근거는 로컬 설정 매칭 규칙 하나[S134]). 실패하면 공개 host마다 Terraform DNS 레코드를 둔다(사람 apply, 앱 등록 PR에 안내). 이 레코드는 운영 터널만 가리킨다. 같은 Git 트리를 따르는 검증 VM(시나리오 13)에서 공개 host를 `curl`하면 운영이 답하므로, VM은 공개 URL 대신 시험 터널 연결과 Traefik을 직접 확인한다(E8 VM 격리 5번).
- **Traefik:** Service는 ClusterIP라 LAN·tailnet에서 직접 닿지 않는다. Ingress class `traefik` 하나, 엔트리포인트 `web` 하나다. Gateway API와 내부 TLS 리스너는 두지 않는다(A.4 8번).
- **공개 host 규칙:** `^[a-z0-9-]+\.ukyi\.app$` 한 단계만 허용한다(공유 차트 schema). Universal SSL은 apex와 첫 단계 하위 도메인만 덮는다[S141].
- **HSTS:** zone 설정(includeSubDomains, nosniff, 180일, preload 끔)을 새 Terraform으로 그대로 가져온다(D-11). 다만 `ukyi.app` 아래 이름을 HTTPS 전용으로 잠그는 주된 원인은 이 헤더가 아니다. `.app` 최상위 도메인 전체가 브라우저 HSTS preload 목록에 있어[S210], zone 설정과 상관없이 `ukyi.app` 아래 모든 이름은 주요 브라우저에서 늘 HTTPS로만 열리고 인증서 오류를 넘길 수 없다[S140][S142]. 공개 host는 모두 Cloudflare가 유효 인증서로 받으므로 문제없다. 내부 UI는 `ukyi.app` 밖(`*.ts.net`)이라 이 preload와 무관하지만, ts.net도 인증서를 받지 못하면 넘어갈 수 없다(C.3.5).
- **WAF(Free, 사용자 규칙 5개, 정규식 불가)[S136][S137]:** 규칙 1 "host가 `hooks.ukyi.app`이고 (path ≠ `/github` 또는 method ≠ POST)면 Block"(봇 webhook 자리, C.8). 나머지는 zone 기본 보호를 상속한다(옛 실측: GitHub webhook POST 통과, `2d2054a:infra/cloudflare/waf.tf:29-37`).
- **준비 확인:** 시험 앱 host에 `curl -sfI https://<host>.ukyi.app` → 200, 없는 host → 404, `cloudflared` `/ready` → 200.

#### C.3.5 내부 접근

- **내부 UI:** Argo CD, Grafana, AdGuard 관리 화면을 Tailscale operator Ingress(`ingressClassName: tailscale`)로 낸다. 이름은 `<서비스>.<tailnet>.ts.net`이고 operator가 유효 TLS 인증서를 붙인다[S114][S115]. Ingress는 기본으로 인터넷에 공개되지 않는다[S114]. UI마다 단독 프록시다(Ingress마다 operator가 프록시 기기 하나). `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01용 Cloudflare 토큰, traefik-ts L4 프록시는 두지 않는다(D-08, 확정(사용자 2026-10-18)).
- **사람 작업(E4):** tailnet에서 HTTPS 인증서를 켠다(MagicDNS는 이미 켜져 있음). 켜면 기기 이름과 tailnet DNS 이름이 공개 CT 로그에 실린다[S120]. 그래서 공개해도 되는 일반 이름(`argocd`, `grafana`, `adguard`)만 쓴다.
- **이름과 인증서 장애:** 전체 이름(`https://argocd.<tailnet>.ts.net`)만 열린다. 짧은 이름 `https://argocd`는 인증서 경고가 아니라 TLS 연결 실패다. 프록시는 정확한 이름과 포트(FQDN:443)에만 인증서를 낸다. operator의 http-redirect 어노테이션은 `http://<전체 이름>`을 칠 때만 도움이 되고, `http://argocd`는 `https://argocd`로 넘어가 같은 실패가 난다[S211]. 프록시는 인증서를 새로 받지 못하면 만료된 인증서를 내지 않고 핸드셰이크를 실패시키므로, 옛 `*.home.ukyi.app`(`.app` HSTS preload[S210])처럼 넘어갈 수 없다. 갱신은 수명의 2/3에서 시작하므로 실패가 이어져도 만료까지 약 30일 여유가 있다(cert-manager도 같다[S212]). 그 사이 알아채는 것이 관건이고, 막혔을 때의 비상 경로는 `kubectl -n argocd port-forward svc/argocd-server 8080:80` 같은 port-forward다(Tailscale까지 끊기면 kubectl도 LAN 주소로 붙는다).
- **짧은 주소(D-30, 확정(사용자 2026-10-20)):** tailnet 전용 리다이렉터 `go`가 `go/<이름>/<경로>`를 `https://<이름>.<tailnet>.ts.net/<경로>`로 302 보낸다. operator LoadBalancer Service(`loadBalancerClass: tailscale`, `tailscale.com/hostname: go`, `tailscale.com/tags: tag:k8s-go`)로 HTTP 80만 낸다[S229]. Ingress로 내지 않는 것은 위 문단대로 operator Ingress가 FQDN:443 인증서만 다뤄 `go/`가 TLS 실패하기 때문이다. 짧은 이름 `go`는 MagicDNS가 더하는 검색 도메인으로 풀린다[S222]. 443은 열지 않아 브라우저가 `https://go`를 먼저 시도해도 인증서 오류가 아니라 연결 거부로 끝난다(브라우저별 동작은 T08c 수용 시험). 처음 보는 단일 라벨 `go/<이름>`은 브라우저가 검색어로 보내므로, 기기·브라우저마다 처음 한 번 `http://go/<이름>`으로 연 뒤 스킴 없는 입력을 쓴다(D-30 입력 방식, 사용자 2026-10-21). 첫 구간은 평문 HTTP지만 WireGuard 안이고 담기는 것은 링크 이름뿐이다. 인증서를 받지 않아 CT에 새 이름이 실리지 않고, `go`가 멈춰도 전체 주소는 그대로 열린다. 대상 호스트는 DNS 라벨(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, 접두 포함 63자 이하) 하나에 tailnet 도메인을 붙인 것뿐이라 열린 리다이렉트가 아니고, 영구 캐시되는 301은 쓰지 않는다. tailnet 도메인 값은 저장소에 두지 않는다(D-23). 이름은 HSTS preload 최상위 도메인(`app`, `dev` 등)과 겹치면 안 된다. 브라우저가 `http://`를 HTTPS로 바꿔 실패한다[S210]. 구현(T08c)은 `platform/go`(Application `go`, wave 1, ns `go` restricted)다. tailscale ns(privileged)와 Application을 나눠 `go`의 실패가 operator와 root를 멈추지 않게 했다. 접근 로그는 끄고 오류 로그는 crit 이상만 남겨 경로·쿼리를 로그에 두지 않는다. Service는 NodePort를 받지 않는다(`allocateLoadBalancerNodePorts: false`, 받으면 LAN의 30000번대가 열린다).
- **operator:** chart 1.104.1, OAuth client(Services·Devices Core·Auth Keys write, 태그 `tag:k8s-operator`. Services는 2026-10-20 공식 설치 문서 기준으로 더함)는 Infisical `/platform/tailscale`에서 ESO로[S116]. ns `tailscale`은 privileged(옛 실측, `2d2054a:platform/namespaces/prod/namespaces.yaml:116-131`). ProxyClass로 프록시 메모리 상한을 둔다.
- **ACL**(`infra/tailscale`, owner 로컬 apply, 목표 예시의 요지):

```hujson
// infra/tailscale/policy.hujson  (목표 예시. D-11 (c), 2026-10-20)
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:k8s-go": ["tag:k8s-operator"],
    "tag:nuc": ["autogroup:owner", "autogroup:admin"]
  },
  // NUC가 광고하는 공유기 경로를 태그 기준으로 자동 승인한다(재등록 뒤에도 유지)
  "autoApprovers": { "routes": { "192.168.117.1/32": ["tag:nuc"] } },
  "acls": [
    // 사람 기기끼리. NUC는 tag:nuc라 여기에 들지 않는다
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] },
    // 사람 기기 → NUC: SSH·kubectl은 운영자(Owner·Admin)만(태그 대상이라 self처럼 소유자로 좁혀지지 않는다), AdGuard DNS는 member
    // Owner는 autogroup:admin에 들지 않는다. 빠지면 태그를 붙이는 순간 유일한 운영자의 SSH·kubectl이 끊긴다
    // NUC → 사람 기기 규칙은 두지 않는다(U28)
    { "action": "accept", "src": ["autogroup:owner", "autogroup:admin"], "dst": ["tag:nuc:22,6443"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:nuc:53"] },
    // 내부 UI 프록시(operator Ingress)는 443만. NUC 쪽 확인 명령도 같은 길을 쓴다
    { "action": "accept", "src": ["autogroup:member", "tag:nuc"], "dst": ["tag:k8s:443"] },
    // 짧은 주소 리다이렉터(D-30)는 80만. 모든 프록시에 80을 열지 않으려고 태그를 나눈다
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:k8s-go:80"] }
  ],
  "grants": [
    // 공유기 관리 화면. NUC가 192.168.117.1/32 서브넷 경로를 광고한다
    { "src": ["autogroup:member"], "dst": ["192.168.117.1/32"], "ip": ["tcp:80", "tcp:443"] }
  ],
  "ssh": [
    // self 대상은 태그 전환 중(ACL apply 뒤 태그를 붙이기 전) NUC SSH가 끊기지 않게 남긴다. 사람 기기끼리도 쓴다
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"] },
    // root는 기존 비대화형 운영 경로다. 태그 대상의 autogroup:nonroot는 src 전원에게 비root 사용자를 열므로 src를 운영자(Owner·Admin)로 좁힌다
    { "action": "accept", "src": ["autogroup:owner", "autogroup:admin"], "dst": ["tag:nuc"], "users": ["autogroup:nonroot", "root"] }
  ]
}
```

- **NUC 신원(F D-11 (c), 확정(사용자 2026-10-20)):** NUC는 `tag:nuc` 태그 기기다. 2026-10-18~2026-10-20에는 (a)(태그 없는 사용자 기기, self 규칙)였고, E4a의 U28에서 파드가 NUC의 Tailscale 주소로 바뀌어(SNAT) 운영자 기기에 닿는 것이 확인돼 바꿨다. 태그 기기에는 `autogroup:self`가 적용되지 않으므로[S117] 사람 기기 → NUC 경로를 위 예시처럼 포트별로 연다. SSH 22·kubectl 6443(mosh를 쓰면 그 UDP 범위도)과 ssh 규칙은 운영자(`autogroup:owner`·`autogroup:admin`)만이다. Owner는 `autogroup:admin`에 들지 않으므로 둘 다 적는다[S230]. (a)의 self 대상은 NUC 소유자에게만 열렸는데, 태그 대상은 그렇게 좁혀지지 않아 member를 쓰면 나중에 member가 늘 때 호스트와 k3s가 함께 열린다. AdGuard DNS 53은 member다. NUC → 사람 기기 규칙은 두지 않아 NUC와 파드가 운영자 기기에 닿지 못한다. 태그 기기는 키 만료가 기본으로 꺼져 재등록 때 손 작업이 없다[S119]. ssh 규칙은 `accept`에 `autogroup:nonroot`와 `root` 그대로다(`check`로 좁히는 F D-11 (b)는 고르지 않았다). 태그 대상의 `autogroup:nonroot`는 src 전원에게 모든 비root 사용자를 연다는 공식 경고가 있어 src를 운영자로 좁혔다[S121]. 적용 순서와 되돌리기는 E4a(T08a)다.
- **남는 위험:** (c)로 NUC → 운영자 기기 길은 Tailscale에서 막힌다. 파드에서 다른 tailnet 대상(내부 UI 프록시 `tag:k8s:443`)으로 가는 길은 `tag:nuc` 규칙대로 남으므로, 공유 차트 egress의 tailnet 대역 제외(C.4.5)와 작업자 공간의 init 규칙(C.8)은 그대로 둔다. 사람 기기를 잃으면 그 기기의 SSH 키로 비root 계정에 들어온다. NUC는 Tailscale SSH를 켜지 않아(사용자 2026-10-21) ssh 규칙의 비밀번호 없는 root 경로는 쓰이지 않고 sshd는 root 로그인을 막는다. Tailscale SSH를 다시 켜면 그 root 경로가 살아나므로 켜기 전에 ssh 규칙을 다시 본다(F D-11 (b)는 고르지 않음).
- **PostgreSQL GUI 접속:** 옛 tailnet LB(`pg-rw`)는 두지 않고 `kubectl port-forward -n database svc/pg-rw 5432`로 한다. tailnet 기기·Pooler 혼선 함정(`2d2054a:platform/cnpg/prod/pg-rw-tailscale-service.yaml:6-12`)이 없다.
- **준비 확인:** tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net` → 200 또는 로그인 리다이렉트, tailnet 밖에서는 이름이 풀리지 않음, 노트북에서 NUC tailnet 주소로 `ssh` 성공(sshd. Tailscale SSH는 켜지 않는다). 짧은 주소: tailnet 기기에서 `curl -sI http://go/argocd` → 302이고 Location이 `https://argocd.<tailnet>.ts.net`, `curl -sI http://go/evil.com` → 404, `curl -sI https://go/` → 연결 실패(인증서 오류가 아님). 브라우저마다 처음 한 번 `http://go/argocd`로 연 뒤, 주소창에 스킴 없이 친 `go/argocd`가 Argo CD 로그인 화면을 연다(맥 Safari·Chrome, 아이폰 Safari 셀룰러. 처음 보는 단일 라벨은 브라우저가 검색어로 보낸다, D-30 입력 방식). 규칙 자체는 `tools/go-redirect.test.sh`(로컬, 컨테이너 필요)로 본다.

#### C.3.6 DNS (AdGuard, 노드 DNS, Tailscale)

**AdGuard** (`platform/adguard`, ns `adguard`)

- Deployment 1개, `Recreate`, PVC `local-retain` 1Gi. Service `LoadBalancer`(servicelb)로 노드 LAN IP `192.168.117.15:53` TCP·UDP를 연다(C-04). servicelb는 LoadBalancer Service마다 hostPort DaemonSet을 만든다[S53]. 공유기가 모든 LAN 질의를 대신 보내므로 LAN 쪽에서는 hostNetwork의 장점(클라이언트 IP 보존)이 없다(사실: 옛 실측 "LAN 전체가 공유기 IP 하나로 들어옴", `2d2054a:platform/adguard/prod/adguardhome.yaml:33-45`). tailnet 쪽은 다르다. D-08 (b′)에서 Tailscale 기기는 NUC의 Tailscale 주소 `:53`으로 직접 묻는다. hostPort DNAT는 목적지 주소를 가리지 않아 같은 Service가 tailnet 주소에도 걸린다(옛 실운영 경로, B.8 E2의 portmap 함정과 같은 원리). klipper-lb의 MASQUERADE로 tailnet 질의는 svclb 파드 IP로, 공유기 경유 LAN 질의는 `10.42.0.1`로 보여 같은 /24 ratelimit 버킷을 쓴다(U32, 2026-10-21 E4a 확인). 그래서 ratelimit을 끈다(확정(사용자 2026-10-21)). 출처 예외(`ratelimit_whitelist`)는 파드 IP가 재시작마다 바뀌어 쓰지 않고, hostNetwork도 아래 대가 때문에 쓰지 않는다. 대가: 고장 나거나 침해된 LAN·tailnet 기기 하나가 질의를 쏟아내도 AdGuard가 막지 않고, 공유기가 보조 DNS로 넘어가지 않아 그동안 집 LAN 전체의 이름 해석이 느려지거나 멈출 수 있다(사용자가 알고 고름). 필요해지면 노드 nftables에서 NAT 전 출처별 한도를 둔다(후속 후보). hostNetwork는 실제 100.x 출처를 보존하지만 PSA 예외가 필요하고, AdGuard 파드가 노드 네트워크 네임스페이스에 들어가 침해되면 노드의 `127.0.0.1` 서비스와 모든 인터페이스(LAN, `tailscale0`)에 닿는다.
- 설정: Git 시드(업스트림 DoH 2개, `upstream_mode: load_balance`, ratelimit 끔(U32 결과, 확정(사용자 2026-10-21)), `local_ptr_upstreams`, 필터 목록은 AdGuard DNS filter 하나(옛 시드와 같고 공용 AdGuard DNS와 같은 목록이라 D-08 (b′)의 일관성이 여기서 나온다[S190], 사용자 규칙은 최소), 질의 로그 7일)를 첫 부팅에만 복사한다(`cp -n`). 실행 중 설정 파일은 AdGuard가 다시 쓴다[S151]. 관리자 비밀번호 해시는 ESO Secret에서 init이 주입한다.
- rewrite는 두지 않는다. 내부 이름이 `*.ts.net`이라 필요 없다. 옛 리컨실러와 "rewrite 대상 IP가 바뀌는" 함정(`2d2054a:docs/traps-detail.md:289-294`)이 사라진다.
- liveness 없음, readiness는 TCP 53. 관리 UI는 Tailscale Ingress로만.

**노드 자신의 DNS:** 노드는 AdGuard를 쓰지 않는다. resolved 스텁 끔 + `DNS=1.1.1.1 9.9.9.9`, 링크 `UseDNS=false`, `tailscale set --accept-dns=false`(C.3.2). CoreDNS는 노드의 resolv.conf(공용 DNS)로 전달하므로 파드도 AdGuard에 의존하지 않는다. 그래서 콜드스타트에 AdGuard가 없어도 이미지 pull이 된다.

**Tailscale DNS (D-08 (b′), 확정(사용자 2026-10-18)):** Override local DNS 켬, 전역 nameserver = [NUC의 Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS[S189]), C-05의 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬. nameserver의 `use_with_exit_node`는 기본값(끔)으로 둔다. exit node를 쓸 계획이 생기면 두 공용 주소에만 켠다(클라이언트 1.88.1 이상[S187]). NUC 자신은 `accept-dns=false` 그대로다(노드 DNS 순환 방어, C.3.2).

- **원리:** Tailscale 클라이언트는 전역 nameserver에 동시에 묻고 처음 온 정상 응답을 쓴다. SERVFAIL·REFUSED는 약한 오류라 다른 서버의 답을 기다리지만, 차단 응답(`0.0.0.0`, NXDOMAIN)은 정상 응답이라 먼저 오면 그대로 쓰인다[S110][S186]. 그래서 모든 nameserver가 같은 기본 목록으로 차단해야 한다. AdGuard 공용 DNS는 AdGuard Home 기본값과 같은 AdGuard DNS filter를 쓴다[S189][S190]. C-05처럼 비차단 서버(Cloudflare)를 섞으면 그 서버가 먼저 답한 질의는 차단이 빠진다. 공식 문서도 서버마다 기준이 다르면 차단이 우회된다고 경고한다[S110][S111].
- **목적:** Tailscale을 켠 기기는 집 안팎 어디서든 차단된다. NUC나 AdGuard Home이 멈춰도 공용 서버가 차단하며 답하므로 tailnet DNS가 끊기지 않는다. 옛 구성(Override 켬 + NUC 하나, `2d2054a:infra/tailscale/acl.tf:42-86`)의 "NUC 하나가 tailnet 전체 DNS를 죽임"이 사라진다.
- **대가** (문서화하고 감수한다):
  - AdGuard Home의 사용자 규칙·허용 목록·추가 필터 목록은 AdGuard Home이 먼저 답한 질의에만 적용된다. Tailscale 기기에서 확실하게 적용되는 것은 AdGuard DNS filter 수준의 차단이다. 집에서도 AdGuard Home 캐시에 없는 이름은 공용 서버가 먼저 답할 수 있다(추측). 적용률은 시나리오 14에서 잰다(U33).
  - 공용 경로는 평문 UDP다. AdGuard 공용 주소는 Tailscale의 자동 DoH 목록에 없다[S186]. 그래서 AdGuard사가 질의를 받고, 53번을 가로채는 망(호텔, 공항, 일부 ISP)에서는 그 망의 리졸버가 먼저 답해 차단이 빠지거나 위조된 답이 쓰일 수 있다. tailscaled는 DNSSEC을 검증하지 않는다[S186].
  - AdGuard Home이 tailnet에서 조용히 빠져도(NUC 재등록으로 IP가 바뀜, ACL 실수, svclb 경로 문제, ratelimit 드롭) 공용 서버가 답해 증상이 없다. 그래서 "tailnet 출처 질의가 1시간 0건이면 경보"를 둔다(C.3.7).
  - Override를 켜면 기기의 로컬 DNS를 무시하므로[S110] 회사·호텔 내부 이름이나 공유기가 로컬로만 답하는 이름은 Tailscale을 켠 동안 풀리지 않는다.
  - DNS 차단은 같은 도메인에서 나오는 광고(유튜브 등)를 막지 못한다. 브라우저 보안 DNS(사용자 지정 DoH)나 안드로이드 개인 DNS를 켠 기기는 이 경로를 우회한다.
- **관리: Terraform `tailscale_dns_configuration`**(provider v0.29.2[S187]. 문서는 정식으로 보이나 고정 버전 소스의 Read가 `Alpha Resource` 경고를 낸다, T08a 2026-10-20 확인). `data.tailscale_devices`로 hostname이 `nuc-15-pro`인 기기를 받아 precondition을 건다: 정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`. (a) 동안은 기대 소유자 값을 변수(Infisical `homelab-admin`의 `/terraform/tailscale`)로 받았고(D-23), (c) 적용 PR에서 그 변수와 키를 지운다. IPv4는 주소 목록에서 `100.` 대역으로 골라낸다(목록 순서는 문서에 없음[S187]). `tailscale_dns_nameservers` 같은 다른 DNS 리소스와 함께 쓰지 않는다. 이 리소스는 DNS 설정 전체를 소유하므로 첫 apply 전에 콘솔의 현재 값(C-05 포함)을 기록하고, 그 값을 그대로 옮긴 HCL로 새 state에 import한 뒤(import 블록. provider가 DNS 설정 import를 지원한다[S217]) plan 무변경을 확인한다. import 없이 새 state로 plan하면 생성 계획이 나온다. 그다음 PR로 (b′) 값으로 바꾼다. DNS는 ACL과 나눈 별도 root `infra/tailscale-dns`에 둔다. NUC 기기가 없을 때(빈 NUC 복구 도중) data source precondition 오류가 ACL apply까지 막지 않게 하려는 것이다. 조건부(`count`)는 쓰지 않는다. 리소스에 count를 걸면 NUC가 없는 동안 apply가 `tailscale_dns_configuration` 삭제를 계획하고, 이 리소스가 DNS 설정 전체를 소유하므로 NUC 장애 중에 필요한 공용 폴백과 Override까지 사라진다. 리소스에는 `prevent_destroy`를 걸고, NUC가 tailnet에 없는 동안은 이 root를 apply하지 않는다(마지막 값이 남아 공용 서버가 답한다). Override가 켜진 상태에서 AdGuard Home이 죽어도 공용 서버가 답하므로 Terraform을 돌리는 기기의 DNS 문제는 작다. **U34 통과**(2026-10-20~21 T08a: import 무변경, 목표 apply, 실제 NUC로 precondition 통과, 로컬 backend 사본의 plan으로 0대·2대·태그 다름이 각각 해당 precondition에서 중단).

기기별 동작:

| 기기 | 평상시 | AdGuard Home 정지(NUC 정지 포함) |
|---|---|---|
| LAN 기기(Tailscale 없음) | 공유기 → AdGuard, 광고 차단 | 공유기가 보조 `1.1.1.1`로 넘길 때까지 페이지 로드 지연·간헐 실패가 날 수 있다. 차단 없음. 옛 실측에서 이 공유기는 보조로 넘어가는 문턱이 높았다: AdGuard가 질의를 응답 없이 버린 시험에서 동시 질의 40건 중 20건이 무응답이었고 보조로 샌 것은 0건이었다(`2d2054a:platform/adguard/prod/adguardhome.yaml:33-39`). **2026-10-20 시나리오 14 실측(U19):** AdGuard 정지 6분 35초 동안 공유기 경유 질의 26회가 모두 5초 시간 초과였고 20초를 기다려도 답이 없었다. NUC가 아예 응답하지 않게 만든 2분 30초 시험에서도 11회 모두 시간 초과였다. 이 공유기(Netgear Orbi RBR350)는 보조로 넘어가지 않고, 기기에 나눠 줄 DNS 설정과 DNS 프록시 끄기가 없다. 그래서 그동안 Tailscale 없는 LAN 기기의 DNS는 전부 끊긴다. AC-P6 LAN 불합격을 사용자가 한계로 승인했다(완화: 런북 `nuc-dns-outage.md`, T08b AdGuard 정지 경보) |
| Tailscale 기기(집 안팎) | 전역 nameserver 셋에 동시 질의. AdGuard Home이나 AdGuard 공용이 답해 기본 목록으로 차단. AdGuard Home 전용 규칙은 AdGuard Home이 먼저 답한 질의에만 | 공용 서버가 답해 기본 차단 유지, 체감 없음. 사용자 규칙·통계만 빠진다. 공용 서버까지 닿지 않으면 SERVFAIL(UDP 2초 뒤 TCP 병행, 질의 상한 10초[S186]) |
| 내부 UI `*.ts.net` | MagicDNS(클라이언트가 기기 목록으로 직접 답함[S186]) | 이름은 풀린다. NUC가 멈췄으면 UI 자체가 같이 멈춘다 |
| NUC 노드와 클러스터 파드 | 공용 DNS 직접 | 영향 없음 |

**AC-P6 판정 기준 (LAN 기기의 AdGuard 정지 중 허용 지연) [확정(사용자 2026-10-18, T05)]:** AdGuard를 멈춘 5분 동안 LAN 기기에서 10초 간격으로 30회 질의해 실패 0회, 질의마다 응답 5초 이하. 질의 이름은 매번 처음 묻는 고유 이름이다(예: `am<측정 시각>-<회차>.example.com`). 같은 이름을 되풀이하면 공유기가 답을 캐시할 경우 AdGuard가 멈춰도 캐시가 답해 거짓 통과가 나기 때문이다. 고유 이름은 대개 없는 이름이라 응답 코드 NOERROR와 NXDOMAIN을 모두 응답으로 세고, 시간 초과·SERVFAIL·REFUSED를 실패로 센다. 측정값(질의별 이름, 응답 코드, 응답 시간, 실패 수)은 그대로 결과표에 남긴다. 기준에 못 미치면 시나리오 14를 실패로 기록하고, 사용자가 한계로 승인하거나 F D-08을 다시 본다. **2026-10-20 결과:** 불합격(30회 중 26회 실패, 모두 시간 초과). 사용자가 한계로 승인했다.

검토 후 제외한 안은 F D-08에 있다: (a) AdGuard 단독(사용자 규칙이 늘 적용되지만 NUC 장애가 Tailscale 기기 전체의 DNS 장애가 됨), (a+) 자동 전환, (c) NextDNS.

#### C.3.7 관측·알림·외부 생존 감시

| 구성 | 역할 | 설정 요지 |
|---|---|---|
| VictoriaMetrics single | 메트릭 저장 + 스크레이프. vmsingle이 `-promscrape.config`로 직접 수집하므로 vmagent를 두지 않는다[S167] | 보존 30일, `-memory.allowedBytes` 절대값(B.8 E4). v1.154.1(T08b) |
| vmalert | 룰 평가 → Alertmanager | `-configCheckInterval=30s`, 룰은 Git, 단위 시험은 CI(`vmalert-tool unittest`, U11 확인 T08b). v1.154.1 |
| Alertmanager | 라우팅 | 0.34.1[S164]. 설정은 configMapGenerator 해시로 롤아웃 |
| Grafana | 사람 UI, 봇의 읽기 API(Viewer 서비스 계정, C.8) | 대시보드는 Git provisioning, Tailscale Ingress. 13.2.4. 플러그인은 VictoriaLogs 데이터소스 `victoriametrics-logs-datasource` v0.33.1 하나(서명 commercial, VictoriaMetrics). init 컨테이너가 GitHub 릴리스 zip을 sha256 확인 뒤 `grafana-data` PVC에 넣고, 표시 파일이 맞으면 받지 않는다. 런타임 다운로드는 끈다(`GF_PLUGINS_PREINSTALL_DISABLED`). 그래서 Grafana 파드 egress에 인터넷 443(사설망·tailnet·link-local 제외)이 열린다. 로그 플러그인이 응답의 약 15배를 메모리에 올려 데이터소스 응답 상한 4 MiB(`GF_DATAPROXY_RESPONSE_LIMIT`)와 memory limit 512Mi를 둔다(T08b 실측) |
| vmauth | Grafana 데이터소스와 vmsingle·VictoriaLogs 사이 읽기 전용 프록시(U12 대안) | Viewer도 데이터소스 resources 경로로 임의 경로에 POST해 vmsingle 직결이면 `delete_series`·import에, VictoriaLogs 직결이면 `/insert/*`·`/internal/force_merge`에 닿는다(T08b 실측). 질의 API 경로만 허용하고 Grafana의 vmsingle·VictoriaLogs 직접 연결은 NetworkPolicy로 막는다. VictoriaLogs는 플러그인이 부르는 `/select/logsql/*` 질의 경로와 `/select/tenant_ids`만 열고, 시간·동시 제한이 없는 `/select/logsql/tail`은 열지 않는다(Explore Live 보기가 안 되는 대가). vmsingle의 `-deleteAuthKey`는 import·write를 막지 못해 쓰지 않는다. v1.154.1 |
| VictoriaLogs single + vector | 로그 14일 | vector는 root(privileged ns `observability`). VictoriaLogs v1.53.0, vector 0.60.0. Grafana 데이터소스(uid `victorialogs`)는 vmauth를 거친다 |
| node-exporter(systemd 수집 켬) + kube-state-metrics | 호스트·클러스터 지표 | 호스트 유닛 실패를 node-exporter가 본다(옛 스윕 유닛 대체). node-exporter v1.12.1, KSM v2.20.0 |

**핵심 룰(15개 안팎):** Watchdog(항상 발화), TargetDown, KubePodCrashLooping, KubePodNotReady(15분), OOMKilled, NodeMemoryHigh, NodeFilesystemAlmostFull, NodeSystemdUnitFailed, ArgoCDAppDegraded·OutOfSync(30분, `argocd_app_info` 지표), ExternalSecretNotReady(ESO 지표), CNPGClusterNotHealthy, PGBackupStale(마지막 성공 백업 26시간 초과)·WALArchiveFailing, ValkeyBackupStale, KubeJobFailed, AdGuard tailnet 이탈(아래). 룰 작성 규칙 4줄은 B.8 E4. Argo CD notifications는 설정하지 않고 지표 경보로 대신한다(옛 webhook 방식 토큰 유출 함정).

**알림 라우팅** (목표 예시)

```yaml
# Alertmanager route (목표 예시)
route:
  receiver: telegram                     # 비AI 알림 경로 (봇과 독립)
  routes:
    - matchers: [alertname="Watchdog"]
      receiver: healthchecks             # 외부 생존 감시
      group_wait: 0s
      group_interval: 1m                 # 다시 보내기는 이 틱에서만 일어난다. 빼면 기본 5m이 실제 간격이 된다
      repeat_interval: 1m
    # 봇 자리(C.8): 봇이 생기면 아래 네 줄을 함께 켠다. continue: true는 다음 형제 route를 계속 검사하게 할 뿐,
    # 일치한 자식이 있으면 부모 receiver(telegram)로는 보내지 않는다. 그래서 뒤에 Telegram 형제 route를 둔다
    # - matchers: [severity=~"warning|critical"]
    #   receiver: bot
    #   continue: true
    # - matchers: [severity=~"warning|critical"]
    #   receiver: telegram
receivers:
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/telegram/token
        chat_id_file: /etc/alertmanager/secrets/telegram/chat_id   # 0.34.1에 있다. chat ID는 개인 식별자라 공개 저장소에 두지 않는다(T08b)
  - name: healthchecks
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/healthchecks/ping_url
        send_resolved: false
```

- **비AI 알림 경로(D-10):** Alertmanager 내장 `telegram_configs`가 봇을 거치지 않고 보낸다[S163][S165]. 봇 route를 켤 때는 위 예시처럼 Telegram 형제 route를 함께 켜고, 봇이 정상일 때와 멈췄을 때 모두 Telegram 수신을 확인한다(E9, C.8). `continue: true`는 부모 receiver로 되돌려 보내는 기능이 아니다[S163]. 전송 확인 지표는 `alertmanager_notifications_total{integration="telegram"}`(B.8 E4).
- **외부 생존 감시(D-10):** Watchdog → healthchecks.io 체크(Period 5분, Grace 5분). Watchdog 라우트는 `group_interval: 1m`과 `repeat_interval: 1m`을 함께 둬 약 1분마다 ping한다. Alertmanager는 group_interval 틱(기본 5m)에서만 다시 보내므로[S163] `repeat_interval`만 1m으로 두면 실제 간격이 5분이 되어 Period와 같아지고 여유가 Grace 5분뿐이다. 1분 간격이면 일시적인 전송 실패 몇 번은 Period 안에서 흡수된다. healthchecks.io ping은 GET·POST를 받고[S161], Watchdog 패턴은 공식 런북이 설명한다[S162]. healthchecks.io 쪽 통지(이메일, Telegram)는 NUC를 거치지 않는다. Alertmanager webhook이 ping URL로 직접 보내는 구성은 동작한다(U10 결과 2026-10-23, T08b: 새 체크 초록, ping을 막자 down·풀자 up 알림). 실패했다면 옛 relay를 가드(연결 없이 반환하면 ping하지 않음, `2d2054a:platform/victoria-stack/prod/deadmanswitch-relay.yaml:13-16`)와 함께 작게 둔다.
- **선택 항목:** 공개 경로 생존 확인. 클러스터 안 CronJob이 인터넷을 돌아 공개 시험 URL을 호출하고 성공하면 두 번째 healthchecks 체크를 ping한다. 터널·Traefik·앱 경로 고장을 잡는다. 무료 체크는 20개다[S160]. 기본은 두지 않는다(F D-10의 선택 항목).
- **AdGuard tailnet 이탈 감시(D-08):** (b′)에서는 AdGuard Home이 tailnet에서 빠져도 공용 서버가 답해 증상이 없다(C.3.6). 그래서 AdGuard Home 질의 로그에서 tailnet 출처 질의가 1시간 0건이면 경보한다. 질의 로그를 세는 방식은 E4b(T08b, 2026-10-22)에서 정했다: `adguard` ns의 리더 파드(vector, `platform/adguard` querylog-reader)가 `adguard-data` PVC를 읽기 전용으로 붙여 질의 로그 파일에서 클라이언트 IP별 마지막 질의 시각만 지표로 내고(도메인 이름은 내지 않고 VictoriaLogs로도 보내지 않는다), 룰이 그 시각을 kube-state-metrics의 svclb 파드 IP와 맞춘다. API는 관리자 자격이 필요하고(읽기 전용 역할 없음) Infisical에는 bcrypt 해시만 있어 쓰지 않았다. AdGuard는 메모리 버퍼(`querylog.size_memory`)가 찰 때만 파일에 써서, 룰은 지금 시각이 아니라 파일의 가장 새 항목과 비교한다(버퍼 크기는 지연만 바꾸고 오경보를 만들지 않는다). 버퍼는 100으로 낮추고 init이 라이브 설정에도 강제한다(병합이 AdGuard를 한 번 재시작하므로 별도 PR로 정지 경보 시험과 묶는다). tailnet 출처를 가르려면 tailnet 질의가 LAN 질의와 다른 출처로 보여야 한다. E4a의 U32 결과(2026-10-21): 공유기 경유 LAN 질의는 `10.42.0.1`(노드 cni0), tailnet 질의는 svclb 파드 IP로 보인다. tailnet 질의는 "지금 svclb 파드 IP"(kube-system의 `svccontroller.k3s.cattle.io/svcname=adguard-dns` 라벨 파드 IP를 셀 때마다 API로 읽는다. 재시작마다 바뀐다)인 출처로 센다. "`10.42.0.1`이 아닌 출처"로 세면 AdGuard Service에 직접 묻는 클러스터 파드(10.42.0.x)도 tailnet으로 잡혀, tailnet 경로가 끊겨도 경보가 울리지 않는다(DNS ingress는 출처를 좁히지 않음). 대안은 tailnet 기기의 주기 시험 질의다. (b′)에서 이 경보가 이탈을 잡는 유일한 장치라서, E4b 완료 기준에 실제 발화 시험을 둔다(E4b). 경보는 1시간 무질의가 지난 뒤 다음 평가 주기에 울린다.

#### C.3.8 백업

| 대상 | 방식 | 위치 | 일정 | 보존 | 복원 |
|---|---|---|---|---|---|
| PostgreSQL(공유 클러스터) | Barman Cloud Plugin: base backup + WAL 연속 아카이브[S33][S35]. in-tree `barmanObjectStore`는 1.31.0에서 제거 예정이라 처음부터 plugin[S36] | R2 버킷 `homelab-backups`의 `pg/` prefix, serverName `pg-<YYYYMMDD>`(클러스터 세대). 둘 다 클러스터별 values의 값이고 VM은 전용 버킷·serverName(E8) | 매일 03:00 KST(ScheduledBackup은 UTC라 `0 0 18 * * *`) | 14일(ObjectStore `retentionPolicy`) | C.5.7. 복원은 항상 새 클러스터로 한다[S32] |
| 영속 Valkey | `valkey-cli --rdb`로 받아 업로드하고 되읽어 sha256 대조(옛 방식과 공식 문서가 맞음. `--rdb`가 서버에 RDB를 새로 만들게 해 따로 `BGSAVE`하지 않는다)[S41][S42] | 같은 버킷 `valkey/<app>/` | 매일 03:30 KST(CronJob `timeZone: Asia/Seoul`로 노드 TZ에 기대지 않는다) | 14일(R2 lifecycle, prefix `valkey/` 명시) | C.5.6 |
| AdGuard | 없음(Git 시드가 원본) | 해당 없음 | 해당 없음 | 해당 없음 | 재배포 |
| Infisical 값 | 분기마다 `prod` 환경 암호화 내보내기를 복구 자산으로(Free에 PITR·버전 이력 없음[S01][S03]) | 저장소 밖 두 곳 | 분기 1회(사람) | 최근 2부 | C.6.4 |

- 운영 R2 버킷은 새 이름 하나다(옛 `homelab-pg-backups-prod` 등은 폐기, C-02·C-03). 시나리오 13의 VM 전용 버킷은 시험 동안만 있다(E8). lifecycle은 prefix를 반드시 적는다(`prefix = ""`는 버킷 전체 만료, `2d2054a:infra/cloudflare/r2.tf:16-21`).
- R2 자격은 이 버킷 전용 Object Read & Write 토큰 하나다. 사람이 대시보드에서 발급해 Infisical `/platform/backup`에 넣는다. CNPG(`database` ns)와 영속 Valkey가 있는 앱 ns에만 ESO로 전달한다. 영속 Valkey 앱 ns에 같은 토큰이 가는 것은 남는 위험이다(그 ns가 다른 백업 객체를 읽을 수 있음). 영속 Valkey는 드물어 감수하고 F D-06에 적었다.
- Barman plugin + R2: S3 호환은 endpoint와 자격으로 설정하고, boto3 checksum 오류에는 `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` 등을 넣으라는 문서가 있다[S35]. R2 region은 `auto`다[S37]. 이슈 #411(R2에서 안 됨)은 열려 있으나 보고자는 원인이 같은 이름 복원이었다고 적었다. **[미검증]** v0.15.1 + R2에서 새 클러스터 복원. 백업이 올라가는 것이 아니라 "R2에서 새 클러스터로 복원된다"로 검증한다(시나리오 10).
- **R2 endpoint는 Git에 두지 않는다(T11, 2026-10-23):** R2 S3 endpoint에 Cloudflare 계정 ID가 들어가므로 ObjectStore `endpointURL`(평문)을 비우고, Infisical `/platform/backup/R2_ENDPOINT`를 sidecar env `AWS_ENDPOINT_URL_S3`(`instanceSidecarConfiguration.env`의 `secretKeyRef`)로 넣는다. `endpointURL`이 비면 plugin이 `--endpoint-url`을 넘기지 않고(barman-cloud v0.6.0) sidecar의 botocore 1.43이 이 env를 읽는다. region은 `AWS_DEFAULT_REGION=auto`로 준다. `AWS_REGION`은 botocore가 읽지 않아 `us-east-1`이 된다(sidecar 이미지 실측. 옛 ObjectStore의 `AWS_REGION: auto`는 효과가 없었다). kind + S3 호환 저장소(RustFS)에서 이 설정으로 WAL 아카이브, base backup `completed`, 새 serverName으로의 복구(base backup 뒤 WAL의 표식 행까지)를 확인했다. R2 자체에서는 아직이다. barman은 모든 barman-cloud 명령의 연결 확인으로 `head_bucket`을 부르고 권한 거부면 실패한다. 옛 기록은 "R2 Object R&W 토큰은 HeadBucket 불가"였으나(`2d2054a:docs/traps-detail.md:62`), 2026-10-23 새 버킷 전용 토큰을 sidecar 이미지의 boto3로 단독 시험해 `homelab-backups` head_bucket 200, `pg/` 목록 200, 다른 버킷 403을 확인했다(사전 확인 통과). 배포 뒤 첫 WAL 아카이브로 최종 확인한다. 막히면 첫 아카이브가 "Permission denied when accessing bucket"으로 멈춘다.
- 복원 드릴은 자동화하지 않는다. 옛 자동 드릴은 고아 클러스터·PVC 재사용으로 거짓 PASS를 냈다(`2d2054a:docs/traps-detail.md:1221-1282`). 대신 PGBackupStale 경보 + 분기 1회 사람이 `homelab db restore-check`(목표 UX)를 돌린다. 시나리오 10이 첫 실행이다. 자동화는 수요가 생기면 더한다.

#### C.3.9 Terraform과 GitHub 설정

| root | 관리 대상 | 적용 | state |
|---|---|---|---|
| `infra/cloudflare` | 터널과 터널 설정, DNS(와일드카드, apex), zone 설정 9개(HSTS 포함), WAF 규칙, R2 버킷 `homelab-backups`와 lifecycle | owner 로컬 `infisical run --projectId=<homelab-admin> --env=prod --path=/terraform/state -- infisical run --projectId=<homelab-admin> --env=prod --path=/terraform/cloudflare -- terraform apply`(R2 키와 provider 자격을 겹쳐 받는다. 두 경로의 이름이 겹치지 않게 둔다, U02). provider v5(`>= 5.8.2`)[S132] | R2 `homelab-tfstate`, 키 `v2/cloudflare/terraform.tfstate` |
| `infra/tailscale` | ACL(정책 파일) | 같은 방식(provider 자격 경로 `/terraform/tailscale`) | 키 `v2/tailscale/terraform.tfstate` |
| `infra/tailscale-dns` | DNS 설정 `tailscale_dns_configuration`(D-08, `prevent_destroy`). ACL과 나눈 이유는 NUC 기기가 없을 때 data source precondition 오류가 ACL apply를 막지 않게 하려는 것이다(C.3.6) | 같은 방식(`/terraform/tailscale`). Tailscale OAuth client에 DNS 쓰기와 기기 읽기 범위가 더 필요하다. NUC가 tailnet에 없는 동안은 apply하지 않는다 | 키 `v2/tailscale-dns/terraform.tfstate` |
| `infra/github`(D-28) | ruleset 6개(A~C, 태그를 지키는 D1·D2, E1의 임시 `main-interim`. `main-interim`은 E5 1단계에서 active 그대로 import하고, ruleset B가 main에 걸린 것을 확인한 2단계 PR에서 `disabled`로 바꿔 그 뒤에는 되돌릴 때만 쓴다, E5), `homelab-app-template`과 등록된 앱 저장소마다 `app-main`(`app-repos.json`을 `for_each`), environment `automerge`와 배포 브랜치 정책 main, Actions 권한(`github_actions_repository_permissions`: 켜기, `allowed_actions` selected. `github_workflow_repository_permissions`: 기본 `GITHUB_TOKEN` read, PR 승인 불가). `github_repository`와 시크릿 리소스는 두지 않는다 | owner 로컬 래퍼만(E5 `tools/tf-github.sh`, E7부터 `homelab github plan`·`apply`·`verify`) | 키 `v2/github/terraform.tfstate` |

- 옛 state 키(`<root>/prod/terraform.tfstate`)를 쓰지 않는다. 같은 키면 옛 state를 물려받아 plan이 옛 자원 삭제를 제안한다(design-prompt §1 6항).
- 잠금은 Terraform S3 backend `use_lockfile = true`다. R2의 PutObject `If-None-Match`는 커밋된 버킷 상태에 원자적으로 평가되고[S37], S3 backend는 잠금 파일 `<key>.tflock`을 `If-None-Match: *`로 만든다[S195]. 그래서 문서·소스로는 확인됐다. HashiCorp는 S3 호환 저장소를 best effort로만 지원하므로 E4a에서 동시 실행 시험을 한 번 한다(U02). R2는 버킷 versioning이 없어[S37] state가 덮어써져도 이력이 없다. 그래서 래퍼가 apply 전에 `terraform state pull` 사본을 저장소 밖에 남긴다. backend의 자격은 환경변수로만 넣고 공개해도 되는 endpoint만 `-backend-config`로 넣는다(backend 값은 `.terraform`과 plan 파일에 남는다[S195]).
- CI는 자격 없이 `terraform fmt -check`, `terraform init -backend=false && terraform validate`, `infra/github`의 `terraform test`(mock), 그리고 `*override.tf*`·`*.tfvars*` 파일 커밋 거부만 한다. 무인 apply, CI plan, 주기 드리프트 감시는 두지 않는다(R20). GitHub root를 CI에서 plan하면 admin이 아닌 토큰에는 bypass 목록과 병합 설정이 안 보여 허위 드리프트가 구조적으로 생긴다[S191][S196].
- 저장소(`homelab`, `homelab-app-template`, 앱 저장소)는 Terraform 리소스로 두지 않아 destroy로 지워질 길이 없다(A.4 4번).

**`infra/github` (D-28, 확정(사용자 2026-10-18))** (목표 예시. HCL·셸은 문서와 provider·Terraform 소스로 맞춰 썼다. guard 동작은 T10의 실제 plan·verify로 확인했다, U35)

- **저장소 설정은 리소스가 아니다.** `allow_auto_merge=false`, squash만, 병합 뒤 브랜치 삭제는 `gh api -X PATCH`로 맞추고 guard가 확인만 한다. 앱 저장소의 보안 설정(secret scanning·push protection, private vulnerability reporting)도 같다. U38 대책도 같다: 저장소 다섯의 PR 생성 `pull_request_creation_policy=collaborators_only`(`gh api -X PATCH`)와 org interaction limit `collaborators_only`(`gh api -X PUT orgs/ukyi-app/interaction-limits`)를 guard 2가 확인한다(사용자 결정 2026-10-22 17:50 "가드방식으로 미리 알려주면"). interaction limit은 최대 6개월이고 영구 옵션이 없으며, GitHub는 만료를 미리 알려 주지 않는다(문서에서 찾지 못함). 그래서 guard 2가 만료 45일 전부터 실패한다. verify가 월 1회라 30일이면 며칠 밀려도 놓치고, 45일이면 만료 전 verify가 적어도 한 번 걸린다. 걸리면 verify뿐 아니라 plan·apply도 다시 걸 때까지 멈춘다. 한계는 verify를 돌릴 때만 알린다는 것이다(캘린더 일정은 두지 않는다). `pull_request_creation_policy`는 공식 REST 문서에 없는 필드라 이름이 바뀌면 guard 2가 막는 쪽으로 실패한다. interaction limit 조회는 classic 토큰이면 래퍼가 요구하는 `admin:org`(응답 머리글 `X-Accepted-OAuth-Scopes: admin:org`, 2026-10-22 실측), fine-grained PAT이면 org Administration read다. 새 앱은 `homelab app new`가 켜고(C.7), `files`·템플릿의 secret scanning·push protection은 결정 5 하드닝이 먼저 켰다(0절 8항, 2026-10-18 실행). 결정 5 하드닝 목록에는 private vulnerability reporting이 없었다(spec §5.1 결정 5, 0절 8항). 그래서 `files`·템플릿에서는 아직 꺼져 있다(실측 2026-10-18 16:31 KST: `gh api --method GET repos/ukyi-app/<저장소>/private-vulnerability-reporting --jq .enabled` → `files`·`homelab-app-template`은 `false`. 내용 전 하드닝에 이 항목을 넣은 `homelab-bot`은 `true`, C.8 봇 저장소). 꺼진 채로는 guard 2가 두 저장소에서 실패해 모든 github plan이 멈춘다. 켜는 일은 사람 작업이고(spec §11), 늦어도 E5 첫 `infra/github` plan 전에 `gh api -X PUT repos/ukyi-app/<저장소>/private-vulnerability-reporting`(별도 엔드포인트[S214])으로 켠다. fork PR 승인 정책(`all_external_contributors`[S198])도 provider가 지원하지 않아[S191] `gh api -X PUT`으로 맞추고 guard가 확인한다. 시크릿 리소스(`github_actions_environment_secret` 등)는 값이 state에 평문으로 남아[S191] 두지 않는다. 병합 키는 Infisical sync가 쓴다(C.4.8).
- **App ID는 숫자 리터럴**로 둔다. `data.github_app`은 fine-grained 토큰에서 404로 죽어 plan을 조용히 무변경으로 만들었다(B.1 P04). private App의 ID는 익명 조회가 안 되는 값이라 공개 HCL에 처음 실린다(실측 2026-10-18: 옛 writer App의 `GET /apps/<slug>`가 익명 404, owner 토큰 200). 자격은 아니다(키가 있어야 토큰을 발급한다).
- **provider:** `integrations/github` 6.13.0 정확 핀, legacy 클라이언트 기본값[S191]. #3519(갱신 apply가 한 번 실패하면 그 ruleset 드리프트가 영구히 안 보임. 수정 #3637 미출시[S192]) 때문에 래퍼가 apply 실패 뒤 재import한다(아래). `.terraform.lock.hcl` 변경은 사람이 확인한다. #3637이 들어간 릴리스가 나오면 올린다.
- **guard**는 `check` 블록이 아니라 `github_rest_api` 데이터 소스의 postcondition이다. check는 실패해도 경고만 내고 plan이 초록으로 끝나지만, postcondition은 plan을 오류로 멈춘다[S193]. `github_rest_api`는 provider 인증을 다시 써서 토큰이 state에 남지 않는다[S191]. 보는 것은 아홉이다.
  1. 토큰이 admin인지(`GET repos/ukyi-app/homelab`의 `permissions.admin`. 익명 폴백과 권한 부족을 드리프트가 아니라 오류로 바꾼다)
  2. 저장소 설정(homelab: `visibility` public, 기본 브랜치 `main`, `allow_auto_merge=false`, squash만, 병합 뒤 삭제, PR 생성 `pull_request_creation_policy=collaborators_only`. 템플릿과 `app-repos.json`의 앱 저장소: `visibility` public, 기본 브랜치 `main`(`app-main`은 `~DEFAULT_BRANCH`를 보호하지만 CODEOWNERS·자동 병합 조건·Argo CD는 `main`을 본다), secret scanning·push protection·private vulnerability reporting 켬, PR 생성 `collaborators_only`, D-29)와 org interaction limit(`collaborators_only`이고 만료까지 45일 넘게 남음, U38)
  3. 저장소별 ruleset 이름 집합과 개수(`rulesets?includes_parents=false`. 같은 이름 중복을 잡으려고 개수도 본다)
  4. ruleset별 bypass가 허용 목록 안에만 있는지, `exempt` 금지, 응답에 `bypass_actors`가 없으면 실패(provider state를 거치지 않는 GET이라 #3519 상태에서도 bypass는 잡는다)
  5. `codeowners/errors?ref=main`이 200이고 `errors`가 빈 배열(404는 `CODEOWNERS` 없음, C.4.7 조건 9)
  6. 옛 브랜치 보호 `branches/main/protection`이 404
  7. fork PR 승인 정책이 org와 대상 저장소마다 `all_external_contributors`(D-29)
  8. org public 저장소 완결성: 보관되지 않은 public 저장소 이름 집합이 homelab + `homelab-app-template` + `app-repos.json`(봇 저장소 포함, C.8)과 같음
  9. environment `automerge`의 배포 브랜치 정책 `[main]`, secret 이름 집합이 `[]` 또는 `[HOMELAB_MERGE_KEY]`, homelab repo secret 0개, org secret 0개(D-04, C.4.8). 키가 없는 상태(`[]`)는 받아들인다. environment를 다시 만든 직후와 E5 1단계 apply 직후에는 Sync 전이라 키가 없고, 그때 verify가 실패하면 Sync 재실행 앞의 verify 단계가 스스로 막히기 때문이다. 키가 없으면 자동 병합이 멈출 뿐이라 안전한 쪽이다. 키가 있는지는 E5 완료 기준과 회전 절차의 `updated_at` 확인이 따로 본다

  guard는 둘로 나눈다. 관리 자원의 내용을 보는 guard 3·4(ruleset)와 9(environment)에만 그 자원에 대한 의존을 건다(guard 3·9는 `depends_on`, guard 4는 endpoint의 `ruleset_id` 참조). 변경이 예정되면 이 셋의 읽기가 apply 뒤로 미뤄져 고친 뒤 상태를 보고, 변경이 없으면 plan 때 바로 본다[S193]. 나머지 1·2·5·6·7·8에는 의존을 걸지 않아 plan 때 늘 평가된다. 그래서 admin이 아닌 토큰이나 익명 폴백은 ruleset 변경 예정 여부와 상관없이 guard 1에서 plan 오류로 멈춘다. 허위 드리프트가 "차이"(exit 2)로 보이거나, 불완전한 bypass 값이 apply 실패 뒤 재import로 state에 들어가기 전에 멈추는 것이다. 미뤄진 guard 결과는 plan 출력에 없으므로 apply 뒤 verify를 다시 돌린다. postcondition은 이미 적용한 변경을 되돌리지 않는다[S193].
- **래퍼** (`tools/tf-github.sh`. E7부터 `homelab github`가 같은 규칙으로 감싼다):
  - `GITHUB_TOKEN`은 환경변수로만 넘긴다(기본 `gh auth token`, 또는 만료 있는 fine-grained PAT). `-var`로 넘기면 값이 plan 파일에 남는다. `GITHUB_APP_ID`·`GITHUB_APP_INSTALLATION_ID`·`GITHUB_APP_PEM_FILE`을 unset한다(셋이 모두 있으면 provider가 토큰보다 App 인증을 먼저 쓴다[S191]).
  - 토큰 종류를 먼저 가른다. classic·OAuth 토큰(`ghp_`, `gho_`)은 `X-OAuth-Scopes` 머리글을 끝까지 읽은 뒤, 비어 있거나 `delete_repo`가 있으면 거부한다. `gh api -i user | grep -q` 꼴은 pipefail 아래 SIGPIPE로 열린 채 실패한다(실측 2026-10-18: 범위가 있는데도 15회 중 1회, 30회 중 1회 놓침). fine-grained PAT(`github_pat_`)에는 그 머리글이 없어 다른 규칙을 쓴다: 만료 머리글(`GitHub-Authentication-Token-Expiration`)이 있어야 한다(래퍼는 머리글이 있는지만 본다. 실제 토큰으로는 시험하지 않았다(U35 미실행 항목): 운영은 classic/OAuth 토큰을 쓰고, 머리글이 없거나 이름이 다르면 거부 쪽으로 실패한다). 발급 규칙(리소스 소유자 `ukyi-app`, 대상 저장소만 선택, 만료 지정)은 사람이 지킨다. **이 경로에는 저장소 삭제 방어가 없다.** ruleset을 쓰는 데 필요한 Administration write가 저장소 삭제 권한도 주기 때문이다. 대신 owner 계정의 다른 저장소와 org에는 닿지 않고 만료가 있다. 그 밖의 토큰 종류는 거부한다. 그다음 guard 1과 같은 확인(`gh api repos/ukyi-app/homelab --jq .permissions.admin`이 `true`)을 plan 전에 한 번 한다.
  - 사용자의 작업 사본에서 돌지 않는다. 고정 URL(`https://github.com/ukyi-app/homelab.git`)에서 main을 임시 디렉터리에 새로 clone한 사본의 `infra/github`에서 plan·apply하고, 실행한 SHA를 출력한 뒤 사본을 지운다. git은 `env -i`로 띄워 작업 사본의 `.git`(설정, remote URL, URL rewrite, hook)과 전역·시스템 git 설정을 쓰지 않는다(`tools/tf-github.sh`. 처음 문구의 `git worktree`는 작업 사본의 `.git`을 써서 실제 래퍼가 택하지 않았다, T12 정정). plan도 HCL과 provider를 실행하므로, 작업 사본의 수정본·미추적 파일이나 `.gitignore`가 숨기는 `*_override.tf`·`*.auto.tfvars`(git status에 안 보인다)가 owner 토큰과 R2 키를 가진 채 실행되면 안 된다. 같은 작업 사본을 AI 에이전트도 편집하고, 옛 구성은 같은 무시 패턴을 bats no-override 가드와 짝지었다(R41). 임시 사본에 `*override.tf*`·`*.tfvars*`가 있으면 거부한다(커밋된 것은 CI도 거부한다). `TF_CLI_ARGS`·`TF_CLI_ARGS_*`, `TF_LOG*`(디버그 로그가 요청 내용을 남긴다)를 unset한다. `TF_CLI_CONFIG_FILE`은 unset하지 않고 래퍼가 만든 설정 파일(`provider_installation { direct {} }`만 담음)을 가리키게 한다. unset하면 Terraform이 같은 사용자(또는 AI 에이전트)가 쓸 수 있는 `~/.terraformrc`로 돌아가고, 거기의 `dev_overrides`나 암묵 로컬 미러로 다른 provider 바이너리가 들어올 수 있다. registry에서 받은 provider는 `.terraform.lock.hcl` 해시로 확인한다. 그래서 봇·Renovate·Codex Connector의 PR 브랜치 코드는 이 경로로 실행되지 않는다. PR의 미리보기는 CI의 mock 시험으로만 한다.
  - `rm -f tfplan` 뒤 `plan -out=tfplan -detailed-exitcode`. 종료 코드는 0·2만 허용한다(1은 guard 실패 포함. 그 밖의 코드도 거부해 낡은 tfplan으로 판단하지 않는다).
  - plan에 delete가 있으면 `--allow-destroy` 없이는 멈춘다(app-main 삭제, environment 교체 방어. homelab ruleset 여섯과 environment `automerge`는 `prevent_destroy`도 있다).
  - apply 전에 `terraform state pull` 사본을 저장소 밖에 남긴다.
  - apply가 실패하면 그 plan에 있던 ruleset을 `terraform state rm` 후 import로 다시 편입한다(#3519 대응).
  - R2 키는 `infisical secrets get AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY --plain --projectId=<homelab-admin> --env=prod --path=/terraform/state`로 이름 둘만 받아 래퍼의 셸 변수에 둔다(파일·argv·로그 없음). `infisical run`은 쓰지 않는다: 그 경로의 모든 키를 환경으로 넣어, `LD_PRELOAD`·`BASH_ENV`·`PATH` 같은 이름이 실수나 변조로 들어가면 자식 프로세스 시작(동적 링커, 셸 시작) 때 `GITHUB_TOKEN`을 읽을 수 있다(T10 Codex 리뷰). terraform은 허용 목록 환경(PATH, HOME, LC_ALL, TMPDIR, `GITHUB_TOKEN`, AWS 키 둘, `TF_IN_AUTOMATION`, `TF_CLI_CONFIG_FILE`)으로 exec한다(값은 export, argv에 두지 않음).
  - `plan`과 `verify`는 `-lock=false`로 돌아 R2에 잠금 객체를 쓰지 않는다(CLI의 "plan은 읽기 전용" AC-P13을 지킨다). `verify`는 `plan -lock=false -detailed-exitcode`다(0 같음, 2 차이, 1 guard 실패). `apply`만 잠금을 잡고 plan을 다시 만든 뒤 적용한다.
- **CI 시험:** `terraform test`의 `mock_provider`로 guard 음성 시험을 한다. run 블록은 `command = apply`로 둔다(plan이면 의존 때문에 미뤄진 guard 3·4·9가 평가되지 않아 `expect_failures`가 성립하지 않는다). run마다 모든 guard 인스턴스(위 아홉의 각 저장소·ruleset 인스턴스)에 정상 JSON을 `override_data`로 넣고 하나만 망가뜨려 `expect_failures`로 본다. 덮어쓰지 않은 계산 문자열은 임의 8자라 나머지 guard까지 실패하기 때문이다[S194]. mock 시험은 HCL 식만 검증하고 실제 API 응답 모양의 변화는 보지 못한다. T10(2026-10-20, Terraform 1.16.6 실측): apply run의 plan 단계에서 난 기대 실패를 Terraform test는 "Expected failure while planning"으로 실패 처리한다. 그래서 의존이 없어 plan 때 평가되는 guard(1·2·5·6·7·8, repo·org secret)와 import 대상(변경 없음) guard는 `command = plan`으로, 미뤄지는 guard(새로 만드는 ruleset의 3·4, environment의 9)는 run마다 `state_key`를 달리한 `command = apply`로 본다(`infra/github/tests/guards.tftest.hcl`).
- **도입 순서:** E1의 `main-interim`과 옛 브랜치 보호 DELETE, E2의 `ci` ruleset은 `gh api`로 한다(E1에는 Infisical(E3)이 없어 state 자격이 없다). 결정 5 하드닝이 E1 전에 `files`·`homelab-app-template`에 건 `app-main`도 E5에서 같은 방식으로 import한다. E5에서 import 블록으로 편입하고 `ci`는 `main-checks`로 제자리 이름 변경한다(provider에서 `name`은 ForceNew가 아니다[S191]. 보호 공백이 없다). import 블록은 첫 apply 뒤 지운다. E5의 첫 apply는 `main-interim`을 끄기 전에 ruleset B가 걸렸는지 확인하는 두 단계다(E5).
- **운영:** 보호를 바꿀 때는 HCL 수정 → PR(CI의 fmt·validate·mock 시험) → 검토 → 관리자 bypass 병합 → main에서 `homelab github plan`으로 diff 확인 → 예상과 같으면 `homelab github apply`, 다르면 고치는 PR. 래퍼가 PR 브랜치 코드를 실행하지 않으므로 병합 전 라이브 plan은 없다. 월 1회와 콘솔에서 무언가를 바꾼 뒤 `homelab github verify`(exit 0이면 같음). 새 앱은 `app-repos.json` PR을 병합한 뒤 apply한다(C.7). ruleset은 지우지 말고 `disabled`로만 끄고, 정답은 git의 HCL이다. ruleset 변경 이력(History) 화면·API는 문서상 Enterprise 기능이라 기대지 않는다(이 저장소에서 API가 응답하긴 했다)[S207]. 감사 기록은 org 감사 로그(최근 180일, owner만)다[S207]. 월 1회 verify 때 bypass 기록을 PR 작성자와 대조한다(C.4.7).
- **비상 경로**(런북 `docs/runbooks-public/`에 둔다): guard 하나가 실패하면 모든 plan·apply가 멈춘다. 예를 들어 관리 ruleset을 콘솔에서 지웠는데 템플릿 `CODEOWNERS` 오류나 목록에 없는 새 public 저장소가 함께 있으면 재생성 apply도 못 한다. 이때 `terraform apply -target=github_repository_ruleset.<이름>`으로 그 ruleset만 다시 만든다. `-target`은 의존 그래프 밖 guard를 건너뛰므로 바로 뒤에 전체 `homelab github verify`를 돌린다. homelab ruleset이 지워진 동안은 apply까지 보호 공백이 있다(조건 9는 앱 저장소의 `app-main`만 보므로 막지 못한다).
- **선택지로만 기록:** 무인 부분 감시. 기본 `GITHUB_TOKEN`으로 하루 1회 ruleset 목록·rules·`updated_at`을 기대값과 비교한다. public 저장소에서는 Metadata read로 읽히지만 bypass 내용, 병합 설정, fork PR 정책, 브랜치 보호는 보지 못한다. R20(무인 감시 없음)을 바꾸는 일이라 채택하지 않았다(F D-28).

### C.4 앱 코드부터 배포까지

#### C.4.1 흐름

```text
1 앱 저장소 PR            app-build(PR 모드): 테스트 + 빌드(push 없음). 시크릿 없음
2 앱 기본 브랜치 push      app-build(release 모드): 테스트 → amd64 빌드 → GHCR push(packages write는 push job만, 캐시 없이)
                            ghcr.io/ukyi-app/<app>:sha-<커밋>, 라벨 org.opencontainers.image.revision·source
                            → 출력 digest[S170][S171]
3 같은 run의 deploy-pr job (기본 브랜치 push일 때만. 앱 코드를 체크아웃·실행하지 않고, id-token·attestations write는 이 job만)
    먼저 그 digest의 build provenance attestation 생성(actions/attest, GitHub API에 저장. 미등록 앱도)[S174]
    앱 저장소는 public만이라(D-29) 늘 만든다. private이면 attest가 실패해 PR 생성 전에 끝난다(fail-safe)
    OIDC(gha-homelab-deploy) → Infisical(homelab-ci-deploy)에서 ukyi-homelab-deploy App 키
    → 설치 토큰(homelab만, contents·pull_requests write)
    토큰 역할: 앱 저장소 쪽 읽기(compare, 기본 브랜치 확인)는 이 job의 GITHUB_TOKEN(caller 저장소 contents: read),
              App 설치 토큰은 homelab 쪽(image.yaml 읽기, deploy/<app> push, PR)에만 쓴다(C.4.8)
    homelab main의 apps/<app>/image.yaml을 읽음
      ├─ 없음 → "미등록 앱" 요약을 남기고 종료(성공). 최초 등록은 사람 PR(C.7 app add)
      ├─ hold: true → "배포 보류" 요약을 남기고 종료
      └─ 앱 저장소 compare(배포 revision...새 revision, GITHUB_TOKEN)가 ahead이고, 열린 deploy/<app> 브랜치의 revision보다도 ahead일 때만
         image.yaml 갱신 → deploy/<app>에 --force-with-lease push → PR 생성 또는 갱신
4 homelab ci(필수 검사)      PR에서 실행
5 homelab deploy-merge        workflow_run(ci 완료)만 → main의 워크플로 코드가 C.4.7의 조건 9개를 검사
                            → merge job(environment automerge, deployment: false)이 secret HOMELAB_MERGE_KEY를 받음
                              (원본 Infisical homelab-ci-merge의 Secret Sync 사본. Infisical OIDC 없음, D-04)
                            → ukyi-homelab-merge App이 검사한 head SHA로 squash 병합
6 Argo CD                    main 폴링(60초, jitter 0) → app-<app> 동기화 → 롤링
7 확인                      Application Synced·Healthy, sync revision = 병합 커밋, 파드 imageID의 digest = image.yaml digest
                            (homelab status <app>). 30분 넘게 Degraded·OutOfSync면 Telegram 경보
```

앱 저장소에는 코드, Dockerfile, 테스트, `CODEOWNERS`, 그리고 짧은 호출 워크플로 하나만 있다(목표 예시).

```yaml
# 앱 저장소 .github/workflows/build.yaml  (목표 예시, 템플릿 D-21이 심는다)
name: build
on:
  pull_request:
  push:
    branches: [main]
permissions: {}            # 워크플로 기본은 권한 없음
jobs:
  build:
    uses: ukyi-app/homelab/.github/workflows/app-build.yaml@app-build-v1.0.0
    permissions:           # app-build 전체의 상한. reusable 워크플로 권한은 caller를 넘을 수 없다
      contents: read
      packages: write      # app-build 안에서는 push job만 받는다
      id-token: write      # app-build 안에서는 deploy-pr job만 받는다(Infisical OIDC, attestation 서명)
      attestations: write  # app-build 안에서는 deploy-pr job만 받는다(build provenance, C.4.7 조건 5)
```

공통 워크플로는 job마다 권한을 다시 좁힌다. 앱 코드(시험, 의존성, Dockerfile의 `RUN`)가 도는 job은 OIDC 토큰을 만들 수 없다. GitHub은 `id-token: write`가 없는 job에서 OIDC 토큰 요청을 허용하지 않는다[S105].

```yaml
# homelab .github/workflows/app-build.yaml의 job별 권한  (목표 예시, 추가 구현 필요. 권한 줄과 attest 단계만 보임)
on: workflow_call
permissions: {}
jobs:
  test:        # 앱 시험(PR이면 push 없는 빌드까지). 앱 코드를 실행한다. 쓰기 권한·OIDC 없음
    permissions: { contents: read }
  push:        # 기본 브랜치 push일 때만. 빌드(Dockerfile RUN이 앱 코드를 실행) → GHCR push. 캐시를 읽지도 쓰지도 않는다(D-29)
    needs: test
    permissions: { contents: read, packages: write }
  deploy-pr:   # 기본 브랜치 push일 때만. 앱 코드를 체크아웃·실행하지 않고 push job의 digest 출력만 받는다
    needs: push
    permissions: { contents: read, id-token: write, attestations: write }   # contents: read는 GITHUB_TOKEN의 앱 저장소 compare용
    steps:
      - uses: actions/attest@<SHA>   # 첫 단계. subject-name ghcr.io/ukyi-app/<app>, subject-digest = push 출력
      # 가시성 조건 없음. 앱 저장소는 public만(D-29). private이면 이 단계가 실패해 PR을 만들지 않는다
```

attest 단계에는 가시성 조건이 없다. 앱 저장소는 public만 허용하므로(D-29) private 분기를 두지 않는다. 누가 앱 저장소를 private으로 바꾸면 Free에서는 attestation을 만들 수 없어[S174] 이 단계가 실패하고, job이 PR 생성 전에 끝나 그 앱의 배포가 멈춘다(fail-safe. 앱 저장소 Actions 요약과 `homelab status`의 빌드 실패로 보인다). 자동 병합 쪽은 C.4.7 조건 5·9가 따로 막는다.

push job은 캐시(Actions 캐시, buildx 캐시)를 읽지도 쓰지도 않는다. 캐시는 같은 저장소의 다른 실행(시험 job, 다른 워크플로)이 남긴 내용이라 배포 이미지의 입력에서 뺀다(D-29). 대가는 빌드 시간이다.

push job의 `packages: write`는 그 앱 저장소의 패키지 쓰기라 앱 코드에 열려 있다. 그 앱 저장소의 다른 워크플로 실행도 `packages: write`를 요청하면 같은 패키지에 쓸 수 있고, 이미지 라벨은 push한 쪽이 마음대로 붙인다. 그래서 자동 병합은 라벨이 아니라 deploy-pr job이 만든 attestation으로 출처를 본다(C.4.7 조건 5). 다른 저장소 쓰기 자격과 OIDC 토큰은 push job에 없다. attestation은 이미지 밖에 따로 저장되는 서명 문서라 이미지 digest를 바꾸지 않는다. 그래서 빌드의 `provenance: false`(C.4.3)와 함께 쓸 수 있다.

#### C.4.2 갱신 방식 비교와 선택

| 기준 | **앱 CI가 빌드 직후 digest PR (선택)** | Argo CD Image Updater PR 모드 | 옛 방식: homelab이 GHCR 폴링 |
|---|---|---|---|
| 저장소 간 쓰기 자격 위치 | Actions 실행 중 메모리(Infisical OIDC 조회, C.4.8) | 클러스터 Secret(Image Updater의 App 키)[S74] | homelab Environment(writer App) |
| digest 정확성 | 빌드 출력 digest를 그대로 씀[S170] | 레지스트리를 다시 읽어 고름. digest 전략은 가변 태그를 따라감[S74] | 레지스트리를 다시 읽음 |
| 늦은 빌드 처리 | compare API로 조상 관계 확인(C.4.3) | digest 전략은 늦게 다시 옮긴 태그로 역행 가능, 단조 태그 + alphabetical이면 피할 수 있으나 Git에 digest가 기록되는지 미확인[S74] | 커밋 순서 권위 + descendant 검사(복잡한 실행기) |
| 추가 구성 요소 | 없음(공통 워크플로 한 단계) | 클러스터 컨트롤러 1개 + CRD | 크론 워크플로, 두 App, 회수 job |
| 지연 | 빌드 직후 | 기본 2분 주기[S74] | 10분 크론, 실측 60~90분 |
| 성숙도 | GitHub 표준 기능 조합 | v1.3.1, 문서가 "active development, non-critical environments"라고 씀[S74] | 옛 구성(사라짐) |
| PR 작성자·브랜치 | `ukyi-homelab-deploy[bot]`, `deploy/<app>` | Image Updater App, `image-updater-<key>-<sha256>` | writer App |

선택 이유: 빌드 결과와 배포 이미지를 같은 run에서 잇고, 순서 검사를 결정적으로 하며, 클러스터에 저장소 쓰기 키를 두지 않는다. 대가는 앱 CI가 저장소 간 쓰기 키를 실행 중에 받는다는 점이고, 그 범위를 C.4.7·C.4.8로 줄인다.

#### C.4.3 digest와 늦은 빌드 방지

```yaml
# apps/smoke/image.yaml  (목표 예시. 배포 App이 쓴다. 사람은 롤백 때만)
repository: ghcr.io/ukyi-app/smoke
digest: sha256:<64자 16진수>
revision: <앱 저장소 커밋 40자>
hold: false
```

- 배포는 태그가 아니라 `repository@digest`로만 한다. 공유 차트가 digest 없는 이미지를 렌더하지 않는다(schema 필수 키).
- 이미지 인덱스 digest가 매번 달라지지 않게 `provenance: false`로 빌드한다(`2d2054a:.github/workflows/reusable-app-build.yaml:97-107`). 이것은 buildx가 이미지 인덱스 안에 넣는 provenance다. 자동 병합의 출처 확인은 이미지 밖에 저장하는 GitHub artifact attestation으로 따로 한다(C.4.1, C.4.7 조건 5).
- **순서 규칙:** 새 revision이 (1) homelab main의 `image.yaml` revision보다, (2) 열린 `deploy/<app>` 브랜치의 revision보다 모두 **ahead**일 때만 갱신한다. 비교는 GitHub compare API의 `status`(`ahead`, `behind`, `diverged`, `identical`)다[S83]. `behind`·`identical`·`diverged`면 아무것도 쓰지 않고 요약에 이유를 남긴다.
- **경쟁 처리:** push는 `--force-with-lease=deploy/<app>:<읽은 SHA>`로 한다. 그 사이 다른 빌드가 브랜치를 바꿨으면 push가 실패하고, job은 한 번 다시 읽어 규칙을 재평가한다.
- **병합 직전 재검사:** `deploy-merge`가 main의 revision 대비 ahead인지 다시 본다(그 사이 롤백이나 다른 병합이 있었을 수 있다).
- `concurrency: deploy-<app>`, `cancel-in-progress: true`는 낭비를 줄이는 보조 장치일 뿐이다. GitHub 문서가 순서를 보장하지 않는다고 적는다[S80].
- 재실행된 옛 빌드도 같은 규칙에 걸려 `behind`로 끝난다(재실행은 `run_number`를 바꾸지 않는다[S82]. 판단은 커밋 관계로 한다).

이 규칙은 옛 `tools/poll-ghcr.ts:6-9`의 불변식("새 이미지 커밋이 배포 커밋의 descendant일 때만")을 그대로 가져온 것이다(L06).

#### C.4.4 이미지별 단일 갱신 주체

| 이미지·버전 | 갱신 주체 | 위치 | 병합 |
|---|---|---|---|
| 앱 이미지 | `ukyi-homelab-deploy` App(앱 기본 브랜치 빌드) | `apps/<app>/image.yaml` | 자동(C.4.7) |
| 앱 롤백 | 사람(`homelab rollback`) | 같은 파일 + `hold: true` | 사람 |
| 공유 차트 버전 사용처 | 사람 또는 Renovate PR | `apps/<app>/values.yaml`의 `chartVersion` | 사람 |
| 플랫폼 차트·이미지(Argo CD, ESO, CNPG, Traefik 등) | Renovate PR(D-18) | `platform/**` | 사람 |
| k3s | Renovate PR(핀) + 사람이 호스트에서 적용 | `host/versions.env` | 사람 |
| 공통 워크플로 호출 ref | 앱 저장소의 Renovate PR | 앱 저장소 `build.yaml` | 사람(앱 저장소) |
| 액션 SHA 핀 | Renovate PR | `.github/workflows/**` | 사람 |

한 앱에 옛 이미지 갱신 자동화와 새 공통 워크플로를 동시에 두지 않는다(T22 제약과 같음).

#### C.4.5 공통 차트·워크플로의 버전과 영향 범위

- **버전 방식:** git 태그다. `app-chart-vX.Y.Z`, `data-chart-vX.Y.Z`, `app-build-vX.Y.Z`. 태그 ruleset D1이 갱신·삭제를 bypass 없이 막아 관리자도 태그를 옮기거나 지우지 못한다(C.4.7).
- **영향 범위:** 앱 Application은 `apps/<app>/values.yaml`의 `chartVersion` 태그로 차트를 렌더한다. 차트를 바꾸는 PR은 어느 앱에도 바로 적용되지 않는다. 시험 앱이 먼저 새 버전으로 올리고, 다른 앱은 각자 PR로 따라간다. 차트 PR의 CI는 차트 안의 시험 values(`platform/charts/app/ci/*.yaml`)로 렌더한다. 막아야 할 values는 `tools/ci/fixtures/charts/app/`의 음성 fixture로 렌더 실패를 확인한다. 등록된 앱은 ci가 ApplicationSet과 같게(values.yaml + image.yaml + 클러스터 접두, 그 앱의 차트 태그) 클러스터마다 렌더한다(T10).
- **semver 뜻:** patch는 렌더 결과가 같거나 버그 수정, minor는 선택 항목 추가, major는 values 형식 변경(CLI가 이전 안내를 출력).
- **공통 워크플로:** 앱 저장소는 `@app-build-vX.Y.Z` 태그로 호출한다. reusable 워크플로 ref는 SHA·태그·브랜치를 받고, 태그와 같은 이름의 브랜치가 있으면 태그가 우선한다[S81]. homelab main이 바뀌어도 앱 빌드가 깨지지 않는다(옛 `@main` 의존 4개 저장소 문제 재발 방지).
- **스키마:** 앱 설정 스키마는 차트의 `values.schema.json`(닫힌 schema)이다. 앱 저장소가 homelab main에서 스키마를 받아 오지 않는다(L04).

**공유 차트 `app`이 내는 것** (목표 예시)

| 항목 | 기본값 | 근거 |
|---|---|---|
| 워크로드 | Deployment 1개(kind `web`·`worker`), selector는 고정 라벨 `homelab.ukyi.app/app` | 가변 selector 영구 실패, `app.kubernetes.io/instance` 숨김(B.8 E2) |
| 보안 | non-root, readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault, SA 토큰 미마운트. 선택 항목 `serviceAccountName`을 주면 그 SA로 돌고 토큰을 마운트한다(봇의 `bot-reader`, C.8). 차트는 SA·바인딩을 만들지 않는다. 그 SA는 봇 자리 Application이 봇 ns에만 만들므로, 다른 앱이 이 값을 켜면 SA가 없어 파드가 생기지 않고 권한도 얻지 못한다 | 옛 기본값(`2d2054a:platform/charts/app/values.yaml:57-72`). 선택 항목은 봇 읽기 전용 접근(C.8). 소비자가 봇 하나라 C.1의 확장 기준(둘 이상)에 못 미치지만, 차트 밖에서 파드의 SA를 바꿀 길이 없어 예외로 넓힌다. 권한은 이 값이 아니라 platform 쪽 SA·바인딩이 정한다 |
| 자원 | requests·memory limit 필수 | L28 |
| probe | readiness 필수, liveness 선택 | 시나리오 1·12 |
| 전략 | PVC가 있으면 Recreate | RWO 교착 |
| 시크릿 | `secrets: [KEY, ...]`를 ExternalSecret `data[]`로(키마다 명시). 컨테이너 env도 키마다 `valueFrom.secretKeyRef`(`optional` 없음, 기본 false)로 넣고 `envFrom`은 쓰지 않는다. Secret에 그 키가 없으면 새 파드가 `CreateContainerConfigError`로 시작하지 않는다[S46]. `envFrom`은 Secret에 있는 키만 넣어 빠진 키를 알리지 않고 파드를 띄운다 | C.6.2, 시나리오 6 |
| DB·캐시 연결 | `uses.postgres: true`면 `DATABASE_URL`, `uses.valkey: true`면 `VALKEY_URL`을 env로 | 손 배선 제거(L03) |
| 캐시 Valkey | `cache:`가 있으면 공식 Valkey 차트(subchart)로 렌더. 영속 Valkey는 데이터 차트 쪽(C.5.6). `app-chart-v1.0.0`에는 아직 없다. Valkey 차트 벤더링과 함께 T11이 minor 버전으로 더한다(T10 결정 2026-10-20). 연결은 Service `<앱>-valkey:6379` 약속으로 v1.0.0의 `uses.valkey`가 이미 배선한다 | 캐시는 데이터가 아니라 앱과 수명을 같이한다 |
| 마이그레이션 | `migration.command` 있으면 Sync hook Job | C.5.4 |
| 공개 | `public.host` 있으면 Ingress(class `traefik`) | C.3.4 |
| 내부 | `internal.name` 있으면 Tailscale Ingress(DNS 라벨 `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, `<접두><이름>` 63자 이하, `go`·`vm-go`는 리다이렉터 이름이라 모든 클러스터에서 예약, D-30). T10(2026-10-20): Tailscale 기기 이름은 문자로 시작하고 끝나야 해서 차트 schema는 `^[a-z]([a-z0-9-]{0,61}[a-z])?$`로 좁혔다. ci는 같은 클러스터 안 내부·공개 host 중복을 거부한다 | C.3.5 |
| 네트워크 | 기본 거부 + 허용(같은 ns, Traefik ns에서 앱 포트(공개 시), Tailscale operator ns(`tailscale`)의 Ingress 프록시 파드에서 앱 포트(내부 노출 `internal.name` 시. 프록시는 앱이 아니라 operator ns에서 돈다[S115]), DNS, `database` ns 5432(DB 시), 인터넷 443). 인터넷 443은 ipBlock `0.0.0.0/0`에 except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`(tailnet)을 명시한다. IPv6 허용 줄은 두지 않아 tailnet IPv6 `fd7a:115c:a1e0::/48`도 막힌다. IPv6 허용을 더할 때는 except에 `fd7a:115c:a1e0::/48`을 함께 넣는다. 봇에만 필요한 클러스터 안 허용(작업자 Service, Grafana·Argo CD API, Alertmanager에서 오는 수신)은 이 차트가 아니라 platform 쪽 봇 자리 Application이 더한다(C.8) | P19, ipBlock에 pod CIDR 금지. tailnet 제외는 아래 "tailnet 차단" |
| 이미지 pull | 없음(`imagePullSecrets`를 내지 않는다). 앱 패키지는 public만이라 익명 pull이 된다(D-29) | P16, C.4.10 |

```yaml
# apps/smoke/values.yaml  (목표 예시. CLI가 처음 쓰고 이후 사람이 편집)
chartVersion: 1.0.0
kind: web
port: 8080
resources: { cpu: 50m, memory: 128Mi }
public:
  host: smoke.ukyi.app
secrets: [EXAMPLE_API_KEY]
cache:
  maxmemory: 64mb
uses:
  postgres: true
  valkey: true
migration:
  command: ["./migrate", "up"]
```

- **tailnet 차단:** 파드가 tailnet 주소로 보낸 패킷은 노드의 `tailscale0`으로 나가며 출발 주소가 NUC의 Tailscale 주소로 바뀐다(U28, 2026-10-20 확인). D-11 (c)(2026-10-20)로 NUC → 운영자 기기 길은 Tailscale에서 막히지만, `tag:nuc`가 닿는 tailnet 대상(내부 UI 프록시)은 남고 ACL 실수 한 번이면 다시 열린다(C.3.5, F D-11). 그래서 위 except가 tailnet 대역을 사설 대역과 함께 명시해 뺀다. NetworkPolicy는 파드에서 나가는(FORWARD) 경로의 목적지로 평가되므로 이 대역을 막는다. 노드 자신의 주소로 가는 노드 로컬(INPUT) 경로는 못 막는다(TD:270-274, B.8 E4). **확인:** 시나리오 1에서 앱 라벨을 단 시험 파드로 운영자 기기의 tailnet 주소 연결이 실패하는지 본다.

#### C.4.6 검사 범위

homelab의 필수 검사는 `ci` 하나다(ADR 0003). `ci`는 `bun run ci` 하나를 실행하고, 로컬에서도 같은 명령이다(L42). 직접 쓴 검사는 대상이 0건이면 실패한다(L40).

| 검사 | 막는 사고(B행) | 도구 |
|---|---|---|
| 시크릿 유출 | 평문 시크릿 커밋(L16, L17, R42) | gitleaks(고정 버전) + `kind: Secret` 매니페스트 0건 |
| 공개 금지 값(D-23) | tailnet 이름·Tailscale IP 커밋 | gitleaks 기본 룰은 둘 다 잡지 않아 `.gitleaks.toml`에 `tailnet-hostname`·`tailscale-ip`·`tailscale-ipv6` 룰을 더했다(2026-10-22, 대역 표기 `100.64.0.0/10`과 MagicDNS 고정 주소 `100.100.100.100`·`fd7a:115c:a1e0::53`만 면제, IPv6 대역 표기는 룰 모양상 걸리지 않음). 앞 경계는 `\b`가 아니라 라벨 밖 글자라 `_<이름>_` 강조도 잡고, 뒤 경계 글자는 소비하지 않아 같은 줄의 연속된 값(면제 값 바로 뒤의 실제 값)도 잡는다. IPv4·IPv6·이름 꼴이 아닌 값(`100.64.1.2.3`, `::12345`, `.ts.network`, `.ts.net.example`)은 면제로 푼다. 모든 호출에 `--ignore-gitleaks-allow`를 둬 인라인 `gitleaks:allow`로 비켜 가지 못하고, `.gitleaksignore`는 ci와 pre-commit 훅이 거부한다(`--gitleaks-ignore-path`를 바꿔도 스캔 루트의 파일을 읽어 막지 못함, v8.30.1 실측). 룰 시험은 ci 단계 `gitleaks rules`. CI는 작업 트리, pre-commit은 staged 변경만 보므로 히스토리는 범위 밖이다(D-03) |
| 앱·데이터 values 스키마 | 오타·미지원 키, 부분 등록(L03, L04) | 각자 고정한 차트 버전의 `values.schema.json` |
| 렌더 + 스키마 | 깨진 매니페스트 | helm template(앱마다 그 차트 태그, platform의 로컬 차트 `root`는 클러스터 값 파일마다, `bot-slot`은 자기 values로), kustomize build(그 밖의 플랫폼) → kubeconform(CRD 스키마 포함) |
| 렌더 결과 정책 | limit 누락(L28), digest 아닌 이미지(L27), 자기 저장소 참조 revision이 `main`이 아님(L31), 읽기 전용 Role의 verb·roleRef(L30), Ingress host 규칙 | TypeScript 검사 1개(렌더 출력 대상) |
| 워크플로 | 무핀 액션, YAML 오류(L33) | actionlint + "`uses`는 40자 SHA(자기 저장소 태그 예외)" |
| Terraform | 문법 오류(P02), GitHub guard 식의 오류 | `terraform fmt -check`, `validate`(자격 없음), `infra/github`의 `terraform test`(mock_provider, guard 음성 시험, C.3.9) |
| 워크플로 경계(workflow-guard) | 병합 키(environment `automerge` secret)가 `deploy-merge`의 merge job 밖에서 쓰이는 것, environment secret을 쓰는 워크플로의 다른 트리거 | TypeScript 검사 1개(아래) |
| 경보 룰 | 죽은 알림(L35) | vmalert 룰 단위 시험[미검증: `vmalert-tool unittest` 형식, E4] |
| CLI | `plan`의 숨은 쓰기(L50), 타입 계약 위반(불투명 Secret에 원문 메서드, 읽기 문맥에 쓰기 함수) | `bun test`(외부 명령 argv 기록 단언), strict `tsc --noEmit`(`cli/tsconfig.json`, TypeScript 7.0.2·`@types/bun` 1.4.3을 `bun install --frozen-lockfile --ignore-scripts`로 `bun.lock` 해시대로 받는다. R37, 사용자 결정 2026-10-23, T12-01b) |

필수 검사에 넣지 않는 것: 외부 레지스트리 조회, 라이브 클러스터 조회, GitHub 설정 대조. 브랜치와 무관하게 모든 PR을 막은 옛 사고(P27, R10) 때문이다. GitHub 설정 대조(`homelab github verify` = `infra/github`의 plan과 guard. E5는 래퍼 `tools/tf-github.sh verify`)는 사람이 E5와 시나리오 15에서 돌린다. CI는 자격이 없어 plan하지 않는다(C.3.9).

**workflow-guard** [제안, D-04]: `.github/workflows/`의 모든 워크플로 파일을 YAML 별칭(anchor·alias)까지 푸는 파서로 읽는다(대상 0개면 실패). 다음 중 하나라도 있으면 실패한다. (1) job의 environment 이름에 표현식(`${{`)이 있다. (2) 이름을 소문자로 바꿔 `automerge`인 environment를 `deploy-merge.yaml`의 merge job 말고 다른 곳에서 쓴다. 문자열형(`environment: automerge`)과 객체형(`environment: {name: ...}`)을 모두 본다. environment 이름은 대소문자를 가리지 않는다[S102]. (3) `deploy-merge.yaml`의 트리거가 정확히 `workflow_run` 하나가 아니다. (4) `secrets: inherit`나 로컬(`./`)이 아닌 reusable 워크플로 호출이 있다(caller가 넘긴 secret을 called job의 environment가 받는다[S200]). (5) `toJSON(secrets)`나 `secrets[...]` 같은 동적 secrets 참조가 있거나, `secrets.HOMELAB_MERGE_KEY`가 merge job 밖에 있다. (6) environment secret을 쓰는 워크플로가 `workflow_run` 말고 다른 트리거를 가진다(F D-26 조건 (2)). 각 규칙이 걸리는지 보는 음성 fixture를 둔다. PR이 이 검사 코드 자체를 고치면 그 PR의 `ci`는 고친 코드로 돌므로, 이 검사는 실수를 잡는 장치이고 악의적인 워크플로 변경은 사람 검토(ruleset B)가 막는다. GitHub이 강제하는 것은 배포 브랜치(main)뿐이다. `workflow_run`·`schedule`·`issue_comment` 같은 이벤트는 GITHUB_REF가 기본 브랜치라 정책을 통과한다[S104].

| PR 종류 | 작성 주체 | 검사 | 병합 | 병합 뒤 확인 |
|---|---|---|---|---|
| 앱 이미지 갱신 | `ukyi-homelab-deploy` | `ci` + `deploy-merge`의 조건 9개 | `ukyi-homelab-merge` 자동(조건 9개가 모두 참일 때. 하나라도 어긋나면 열린 채 남고 사람이 판단) | Argo CD Healthy, 경보 |
| 앱 등록·DB·캐시 추가·앱 삭제·롤백 | 사람(CLI) | `ci` | 사람이 검토 후 병합(관리자 bypass, C.4.7) | `homelab status <app>` |
| 데이터 폐기 | 사람(`data purge`) | `ci` | 사람이 검토 후 병합(단계 PR 둘) | `homelab data list` |
| 공유 차트·공통 워크플로 | 사람, Renovate | `ci`(차트 시험 values 렌더) | 사람이 검토 후 병합. Renovate PR은 code owner 승인이 있어야 병합된다 | 태그 생성 → 시험 앱 먼저 올림 |
| 플랫폼 구성 | 사람, Renovate, 봇 변경 PR(D-24) | `ci` | 사람이 검토 후 병합. Renovate·봇 PR은 code owner 승인이 있어야 병합된다 | Argo CD Healthy, `homelab status --platform` |
| Codex Connector가 만든 변경 | 사람(owner 계정으로 찍힘. 실측 1건과 공개 표본 30건, 2026-10-18, C.4.7) | `ci` | owner가 검토 후 관리자 bypass로 병합. 작성자가 owner라 승인 관문이 없고 owner의 검토가 유일한 관문이다 | 바꾼 범위에 따라 위 행과 같음 |

#### C.4.7 자동 병합 범위와 서버 쪽 강제 (D-07, AC-P8)

**사람 승인 없이 병합되는 PR의 조건** (모두 참일 때만. `.github/workflows/README.md`에 같은 목록을 공개한다)

1. PR 작성자가 `ukyi-homelab-deploy[bot]`이다(로그인 문자열이 아니라 숫자 사용자 ID로 비교).
2. head 저장소가 `ukyi-app/homelab`이고 head 브랜치가 `deploy/<app>`이며 `apps/<app>/`가 main에 있다.
3. 바뀐 파일이 정확히 `apps/<app>/image.yaml` 하나다.
4. 바뀐 키가 `digest`와 `revision`뿐이다(`repository` 그대로, `hold: false`).
5. `repository@digest`가 GHCR에 있고, 그 이미지의 `org.opencontainers.image.revision` 라벨이 `revision`과 같고 `org.opencontainers.image.source`가 `https://github.com/ukyi-app/<app>`이다. 라벨은 push한 쪽의 자기 신고라 출처를 따로 확인한다: 그 digest의 build provenance attestation이 있고, 서명 워크플로가 `ukyi-app/homelab/.github/workflows/app-build.yaml@refs/tags/app-build-v*`, 원본 저장소가 `ukyi-app/<app>`, 원본 ref가 `refs/heads/main`, 원본 커밋이 `revision`이며 GitHub 호스트 runner에서 만들어졌다. 확인은 `gh attestation verify oci://ghcr.io/ukyi-app/<app>@<digest> --repo ukyi-app/<app> --cert-identity-regex '^https://github\.com/ukyi-app/homelab/\.github/workflows/app-build\.yaml@refs/tags/app-build-v' --source-ref refs/heads/main --source-digest <revision> --deny-self-hosted-runners`[S175]다. reusable 워크플로가 만든 attestation은 그 reusable 워크플로가 서명자라 서명 워크플로를 따로 지정해야 한다[S175]. attestation은 `app-build`의 deploy-pr job이 앱 main push 실행에서만 만든다(C.4.1). Free에서 attestation은 public 저장소에서만 만들 수 있다[S174]. 앱 저장소는 public만 허용하므로(D-29) deploy-pr job은 늘 attest하고, attest가 실패하면 배포 PR을 만들지 않는다(C.4.1). **[미검증] U30.**
6. `revision`이 앱 저장소 기본 브랜치에 있고 main의 배포 revision 대비 compare `ahead`다.
7. 그 head SHA의 `ci`가 성공했다.
8. PR이 Draft가 아니고 `hold` 라벨이 없다.
9. 앱 저장소 `ukyi-app/<app>`이 public이고, 그 main에 앱 저장소 ruleset(아래 `app-main`)의 규칙이 active로 보인다. `GET /repos/ukyi-app/<app>`의 `visibility`가 `public`이고, `GET /repos/ukyi-app/<app>/rules/branches/main`에 `pull_request`(`required_approving_review_count` 1 이상, `require_code_owner_review: true`, `dismiss_stale_reviews_on_push: true`), `non_fast_forward`, `deletion`, `update`(Restrict updates, `update_allows_fetch_and_merge`가 참이 아님) 규칙이 있다. 이 API는 active 규칙만 돌려준다[S85]. `update`가 실제 장치다: 승인 요건만으로는 owner PR을 막지 못한다(U08 (나), 아래 ruleset B 행). 그리고 main에 유효한 `CODEOWNERS`가 있다: `GET /repos/ukyi-app/<app>/codeowners/errors?ref=main`이 200이고 `errors`가 빈 배열이다[S178]. 파일이 없으면 이 API는 404다(2026-10-18 실측: 지금 `CODEOWNERS`가 없는 `homelab-app-template`에서 404, 파일이 있는 public 저장소에서 `{"errors":[]}`). 파일이 없거나 소유자 줄이 깨지면(깨진 줄은 건너뛴다[S179]) code owner가 지정되지 않으므로, code owner 요구가 효력을 잃었다고 보고 불일치로 처리한다. 효력을 잃으면 pull_requests write를 가진 다른 신원(리뷰 전용 App 등, C.8)의 승인 하나로 병합 조건이 찬다. 새 push 때 승인 무효화가 없으면 사람이 승인한 뒤 덧붙인 커밋이 다시 검토 없이 병합된다. 저장소를 읽지 못하면(private) 불일치로 본다. 앱 저장소는 public만 허용하므로(D-29) 이 조건은 평소에 늘 참이다. 누가 저장소를 private으로 바꾸거나 `app-main`을 끄거나 `CODEOWNERS`를 깨면 자동 병합을 멈추는 fail-safe로 남긴다. bypass 목록은 쓰기 권한이 없으면 보이지 않으므로[S85] "App bypass 없음"은 GitHub Terraform root의 guard(`homelab github verify`, C.3.9)가 대조한다. guard는 대상 저장소(homelab, `homelab-app-template`, `app-repos.json`의 앱 저장소)마다 선언한 ruleset 이름·개수와 bypass 허용 목록(`exempt` 금지)을 보고, main에 `CODEOWNERS`가 있고 `codeowners/errors`가 빈 결과인지 본다. `pull_request` 규칙의 `require_code_owner_review`·`dismiss_stale_reviews_on_push`는 HCL 선언이라 plan이 차이를 보인다(#3519로 숨는 경우는 래퍼의 apply 실패 뒤 재import가 맡는다, C.3.9). `CODEOWNERS` 내용이 `* @<owner 계정>`인지는 guard에 contents API 비교로 더할 수 있다[제안]. **[미검증] U25:** homelab 쪽 토큰으로 다른 public 저장소의 규칙과 `codeowners/errors`를 읽을 수 있는지.

검사가 끝나면 `ukyi-homelab-merge` App이 `PUT /repos/ukyi-app/homelab/pulls/{n}/merge`를 검사한 head SHA(`sha` 인자)와 squash로 호출한다. 검사와 병합 사이에 새 커밋이 들어오면 GitHub이 병합을 거부한다. 조건이 하나라도 틀리면 병합하지 않고 그대로 둔다(사람이 보고 병합할 수 있다). 이유 댓글은 `ukyi-homelab-deploy`가 작성한 PR에만 남긴다. `deploy-merge`는 모든 PR의 `ci` 완료마다 돌므로 다른 PR의 불일치는 실행 로그에만 남긴다.

**서버 쪽 장치**

| 장치 | 설정 | 막는 것 |
|---|---|---|
| 저장소 설정 | `allow_auto_merge=false`, squash만, 병합 뒤 브랜치 삭제(Terraform 리소스가 아니라 `gh api`로 맞추고 guard가 확인, C.3.9) | GitHub auto-merge는 작성자 조건이 없다[S88]. 쓰기 권한이 있는 누구나 켤 수 있다 |
| ruleset A `main-checks` | 대상 main. 필수 상태 검사 `ci`(출처 GitHub Actions), strict 끔. **bypass 없음** | 검사를 건너뛴 병합. strict를 끄는 이유는 배포 PR이 서로 다른 파일만 바꿔 BEHIND 정지와 스위퍼가 필요 없어서다(R17) |
| ruleset B `main-review` | 대상 main. PR 필수, 승인 1, code owner 리뷰 필수(`CODEOWNERS`는 `* @<owner 계정>`), 새 push 때 승인 무효화, 마지막 push 승인 필수, force push·삭제 금지, **main 갱신 제한(Restrict updates, `update`)**. bypass: 저장소 관리자 역할(`pull_request` 모드), `ukyi-homelab-merge` App(`pull_request` 모드) | 직접 push. 사람 승인 없는 병합. main 갱신(PR 병합 포함)은 bypass 신원만 한다. 승인 요건만으로는 부족했다: owner가 연 PR은 작성자가 유일한 code owner라 쓰기 권한 App의 승인 하나로 요건이 찼고, bypass 없는 배포 App이 승인·병합해 main에 들어갔다(2026-10-21 #822, U08 (나), approvals 21:01~21:07 행). pull_requests·contents write를 가진 신원(배포 App, Codex Connector, Renovate, 봇 변경 PR App)이 승인하든 병합 API를 부르든 main은 바뀌지 않는다. pull_request 모드 bypass는 PR로만 우회한다[S235] |
| ruleset C `deploy-branches` | 대상 `refs/heads/deploy/**`. 생성·갱신 제한, bypass `ukyi-homelab-deploy` App(`always`) | 다른 신원이 배포 브랜치를 만들거나 덮는 것(옛 R-46 계열) |
| ruleset D1 `release-tags-lock` | 대상 태그 `app-chart-v*`, `data-chart-v*`, `app-build-v*`. 갱신·삭제 제한. **bypass 없음** | 관리자를 포함해 누구도 버전 태그를 옮기거나 지우지 못한다. bypass 목록은 규칙 하나가 아니라 ruleset 전체에 걸리므로[S85], 생성 제한과 한 ruleset에 두면 관리자 bypass가 갱신·삭제까지 우회한다(실수한 `git push -f origin <태그>`도 통과). 잘못 만든 태그를 지워야 하면 D1을 잠시 `disabled`로 바꿨다가 되돌린다(org 감사 로그에 남음) |
| ruleset D2 `release-tags-create` | 같은 대상. 생성 제한. bypass: 저장소 관리자 역할(태그 ruleset이라 `always` 모드[S85]) | 관리자만 새 버전 태그를 만든다. 배포 키 identity가 이 태그 ref에만 묶이므로(C.4.8) 키를 받는 워크플로 코드도 관리자가 만든, 움직이지 않는 태그로 고정된다 |
| ruleset `app-main`(앱 저장소와 `homelab-app-template`마다, 같은 선언. `infra/github`의 `app-repos.json` `for_each`) | 대상 앱 저장소 main과 템플릿 저장소 `homelab-app-template`의 main. PR 필수, 승인 1, code owner 리뷰 필수(템플릿이 `CODEOWNERS`에 `* @<owner 계정>`을 심음), 새 push 때 승인 무효화, force push·삭제 금지, main 갱신 제한(Restrict updates, `update`. ruleset B 행과 같은 이유, U08 (나)). bypass: 저장소 관리자 역할(`pull_request` 모드)만, **App bypass 없음**. 봇 변경 PR App의 브랜치는 `bot/**`만(봇 코드 규칙. 선택: homelab의 ruleset E와 같은 모양으로 `bot/**` 생성·갱신을 그 App 전용으로). 적용은 `infra/github` Terraform(E5의 `homelab-app-template`과 시험 앱 저장소는 래퍼, 이후 `homelab github apply`). 새 앱은 `homelab app new`가 `app-repos.json` PR 병합 뒤 저장소를 만들고 곧바로 apply한다(C.7). 대조는 `homelab github verify`(템플릿 포함) | 앱 main 직접 push와 승인 없는 병합. 자동 배포는 앱 main을 믿으므로(조건 6) 앱 main을 바꿀 수 있는 신원이 곧 배포 주체다. Codex Connector·Renovate·봇 변경 PR App이 앱 main에 직접 쓰거나 승인 없이 병합하지 못한다(Codex가 만든 PR은 owner 계정으로 찍혀 owner 검토만 거친다, C.4.7 사람 PR의 병합). 템플릿 main은 모든 새 앱의 첫 main 내용(코드, Dockerfile, `CODEOWNERS`, `build.yaml`)이 되고, 그 내용은 사람 검토 없이 새 앱 main에 들어간다. `app-main`은 새 저장소를 만든 뒤에야 걸리므로 템플릿 main을 같은 규칙으로 막아야 이 간접 경로가 닫힌다(템플릿은 public이고 Codex Connector는 org 전체에 contents·workflows write가 있다, 0절). Free에서는 private 저장소에 걸 수 없다(0절). 그래서 앱 저장소는 public만 허용하고(D-29), 저장소가 private으로 바뀌어 이 ruleset이 효력을 잃으면 조건 9가 자동 병합을 멈춘다. `files`·템플릿에는 결정 5 하드닝이 E5보다 먼저 같은 규칙을 걸었다(0절 8항, 2026-10-18 실행) |
| App `ukyi-homelab-deploy` | homelab에만 설치. contents write, pull_requests write, metadata read. **workflows·actions·administration 권한 없음** | 키가 새도 main에 못 쓰고(ruleset B), 워크플로 파일을 바꾸는 push를 못 하며[S100] (추가 권한 표의 workflows 표시, 단일 근거, E5에서 시험), 병합을 못 한다 |
| App `ukyi-homelab-merge` | homelab에만 설치. contents write, pull_requests write, checks·actions read. 키의 원본은 Infisical 프로젝트 `homelab-ci-merge`이고(machine identity 없음), Secret Sync가 homelab environment `automerge`에 사본 하나를 쓴다(C.4.8, D-04). 그 secret을 쓰는 것은 `deploy-merge`의 merge job뿐이다(ci의 workflow-guard, C.4.6). 앱 CI의 배포 identity는 이 프로젝트에 없다 | 검사를 통과한 배포 PR만 병합 |
| environment `automerge` | 배포 브랜치 정책 main(커스텀 정책 `main` 하나), secret `HOMELAB_MERGE_KEY` 하나, Terraform `prevent_destroy`. 다시 만들면 Infisical Sync를 다시 실행한다 | 브랜치 실행(Codex Connector가 올린 브랜치 워크플로 포함)이 병합 키를 쓰는 것. GitHub이 그 job을 거부한다 |
| 워크플로 `deploy-merge` | `on: workflow_run`(ci, completed) 하나. `workflow_run`은 기본 브랜치의 워크플로 파일로 돈다[S104]. merge job은 `environment: {name: automerge, deployment: false}`이고 `actions/create-github-app-token`에 `secrets.HOMELAB_MERGE_KEY`를 준다 | 같은 저장소 PR이 `pull_request` 워크플로를 바꿔 검사를 무력화하는 것[S94]. `pull_request_target`은 쓰지 않는다 |

App을 둘로 나누는 이유: 배포 App 키는 앱 CI 실행 중에 쓰인다. 그 App이 병합 bypass까지 가지면 키 유출이 곧 검사 우회다(B.8 AIOps 교훈 "역할마다 App을 나눈다"). 같은 이유로 두 키를 서로 다른 Infisical 프로젝트에 두고 전달 경로도 나눈다(배포 키는 OIDC identity, 병합 키는 environment sync). Free에는 경로 RBAC가 없어 한 프로젝트에 두면 그 프로젝트를 읽는 identity가 두 키를 다 읽는다(C.6.3, C.4.8).

**App 이름(2026-10-21 변경):** 처음 정한 `homelab-deploy`·`homelab-merge`는 GitHub 전체에서 이미 쓰이는, 다른 계정의 비공개 App 이름이었다. 사용자가 개인·org App 목록에 둘 다 없음을 확인했고(사용자 2026-10-21 "둘다없어"), 새 이름이 비어 있음을 확인한 뒤(`https://github.com/apps/<이름>` 404, 봇 사용자 없음) `ukyi-homelab-deploy`·`ukyi-homelab-merge`로 바꿨다. 시험 App도 같은 접두로 `ukyi-homelab-bot-standin`(봇 신원 대역, G 시나리오 15)·`ukyi-homelab-review-probe`(리뷰 전용 App 설치 구조, C.8)라 부른다. 바꾸지 않은 것: Infisical 프로젝트 `homelab-ci-deploy`·`homelab-ci-merge`, identity `gha-homelab-deploy`, 키 이름 `HOMELAB_DEPLOY_KEY`·`HOMELAB_MERGE_KEY`, Terraform 변수 이름, approvals.md의 지난 기록. 함정은 B.8 E5.

**봇 변경 PR 신원(D-24)이 digest만 바꿔도 자동 병합되지 않는 이유:** 조건 1(작성자)에서 빠지고, ruleset C 때문에 `deploy/` 브랜치를 만들 수 없고, ruleset A·B의 bypass에 없다. 앱 저장소를 거치는 간접 경로도 막힌다: 앱 저장소(public만, D-29) main과 새 앱의 첫 내용이 되는 `homelab-app-template` main에는 `app-main` 때문에 승인 없이 쓸 수 없고, `app-main`이 꺼진 앱은 조건 9에서 빠진다. 시험은 봇 신원이 생기기 전 다른 시험 App으로 한다(G 시나리오 15).

**사람 PR의 병합:** 사람은 한 명이고 code owner도 그 사람이다. GitHub은 PR 작성자가 자기 PR을 승인하지 못하게 한다[S106]. 그래서 owner가 만든 PR(CLI가 사람의 `gh` 로그인으로 만드는 `cli/*` PR, 롤백, 데이터 폐기, 플랫폼 변경, rebuild → main)은 ruleset B의 "승인 1 + code owner 리뷰"를 채울 수 없다. owner가 검토한 뒤 관리자 역할 bypass(`pull_request` 모드)로 병합하고, **이 bypass 병합이 곧 사람 검토다.** bypass는 ruleset B에만 있으므로 ruleset A의 필수 검사 `ci`는 그대로 적용된다(U08). 이 문서에서 사람 PR의 "사람 승인"은 이 검토 후 병합을 뜻한다.

- **병합 명령:** bypass 병합은 ruleset B의 "새 push 때 승인 무효화"와 "마지막 push 승인"도 건너뛰므로, 검토한 뒤 들어온 커밋도 그대로 병합된다. 그래서 owner PR은 `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`로 병합한다(head가 그 SHA가 아니면 거부된다[S208]). `--admin`은 gh가 스스로 하는 사전 점검만 건너뛰는 클라이언트 쪽 표시이고 API에는 아무것도 보내지 않는다. 서버는 호출자가 bypass 목록에 있으면 알아서 우회한다(gh 관리자 답변, 공식 문서 아님[S208]). 그래서 "bypass 체크 = 검토 서명"은 웹 화면에서만 성립하고, owner 토큰으로 병합 API를 부르는 도구는 확인 없이 병합할 수 있다. Restrict updates 뒤로는 남의 PR(봇 변경 PR App, Renovate)도 bypass 신원만 병합할 수 있으므로 같은 명령(`--admin`, `--match-head-commit`)으로 병합한다. 사람의 승인 리뷰는 기록으로 남길 수 있지만 병합 조건은 아니다.
- **승인 관문이 걸리는 대상:** owner가 작성자가 아닌 PR, 곧 봇 변경 PR App·Renovate의 PR이다. Codex Connector의 PR은 사실상 늘 owner 계정이 작성자로 찍힌다(실측 2026-10-18: 이 org의 Codex PR 1건과 2026-09-01 뒤 public `codex/` 브랜치 PR 표본 30건이 모두 사용자 계정 작성. 작성자가 Connector 봇 계정인 public PR은 검색 결과 4건뿐. 공식 문서 확인은 미검증). 그래서 Codex PR에는 승인 관문이 없고, owner가 bypass 병합 전에 하는 검토가 유일한 관문이다. 승인 관문은 owner PR에서 쓰기 권한 App 승인 하나로 열렸다(U08 (나)). 실제로 main을 지키는 것은 Restrict updates(bypass 신원만 갱신)다. App 설치 토큰(bypass 없는 App 신원)이 owner PR을 승인하고 병합하는 길은 이 규칙으로 막힌다(2026-10-21 apply 뒤 재시험 (1), 같은 권한 꼴의 배포 App으로 확인, U08). Codex가 owner를 대신하는 사용자 토큰으로 병합 API를 부르는 길은 지금 없다. owner가 연 시험 PR #828에 `@codex`로 병합을 요청하자 Connector가 "To use Codex here, create an environment for this repo." 답글만 달고 커밋·병합 없이 끝났다(2026-10-22, U37 통과(조건부)). Codex 클라우드 작업은 저장소별 작업 환경(environment)이 있어야 시작되고, homelab과 앱 저장소에는 환경을 두지 않는다(F D-26 조건 (5)). 환경이 생기면 요청의 행위자가 owner라 관리자 역할 bypass로 update 규칙도 넘을 수 있으므로, 만들기 전에 U37을 다시 시험한다.
- **U08 셋째 조건:** 일상 병합 전체가 관리자 역할 bypass가 org owner에게 적용되는지에 달려 있다. 첫 실측은 결정 5 하드닝(E5보다 앞서 `files`·`homelab-app-template`에 `app-main`을 건 사람 스크립트, 2026-10-18)의 `current_user_can_bypass`이고, 두 저장소 모두 `pull_requests_only`였다. 이 값은 API가 알려 주는 우회 가능 여부이고 실제 bypass 병합은 아직 해 보지 않았다. homelab에서는 E1에서 임시 ruleset을 만든 직후 `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .current_user_can_bypass` → `pull_requests_only`를 첫 시험으로 본다(이 필드는 실측으로 확인했다: 지금 writer 전용 ruleset 둘에서 owner 값은 `never`). 틀리면 F D-07의 대안 순서(owner를 `User` 행위자로 → `OrganizationAdmin` → owner만 든 팀)로 간다.

**남는 위험** (문서화하고 감수한다)

- 관리자(사람)는 ruleset을 끄거나 지울 수 있고, 이것은 막을 수 없다. ruleset 변경 이력(History) 화면·API는 문서상 Enterprise 기능이라 기대지 않는다(이 저장소에서 API가 응답하긴 했다)[S207]. 남는 감사 기록은 org 감사 로그(이벤트 `repository_ruleset.create`·`update`·`destroy`, 최근 180일, owner만 봄)다[S207]. 그래서 ruleset은 지우지 말고 `disabled`로만 끄고, 정답은 git의 HCL로 둔다(C.3.9). 관리자 우회는 AC-P8의 "놓치는 것"과 같다. 사람 PR의 일상 병합도 관리자 bypass라서 bypass 기록만으로는 일상 병합과 예외적 우회를 가를 수 없다. 가르는 기준은 PR을 거쳤는지(`pull_request` 모드라 직접 push는 막힘)와 `ci` 결과다. 월 1회 bypass 기록(`gh api 'repos/ukyi-app/<저장소>/rulesets/rule-suites?time_period=month'`. 기본값 `day`로 부르면 놓친다[S206])을 PR 작성자와 대조한다. bypass 모드 `exempt`는 규칙을 아예 돌리지 않고 bypass 기록도 남기지 않으므로[S85] 쓰지 않고, guard가 금지한다(C.3.9).
- `ukyi-homelab-deploy` 키가 새면 공격자는 배포 PR을 만들 수 있지만, 자동 병합되는 것은 앱 main push에서 태그 고정 `app-build`가 attestation을 만든, 배포 revision보다 새 이미지뿐이다(조건 5·6). 라벨만으로는 이를 보장하지 못한다. 라벨은 push한 쪽의 자기 신고이고, 앱 저장소의 다른 워크플로 실행(같은 저장소 브랜치 PR 워크플로가 `packages: write`를 요청하는 경우 등. Codex Connector는 workflows write가 있다)도 그 패키지에 쓸 수 있다. 키 유출과 이 경로가 겹치면 main에서 빌드되지 않은 이미지에 맞는 라벨을 붙일 수 있어, 조건 5가 attestation의 서명 워크플로·원본 ref·원본 커밋을 함께 본다. 다른 내용은 사람 승인이 필요하다. 키는 앱 main push에서 태그로 고정한 `app-build`의 deploy-pr job만 꺼낸다(C.4.8). U30이 틀려 attestation 확인을 쓸 수 없으면 조건 5는 라벨만 남는다. 그때는 "배포 키 유출 + 앱 저장소 워크플로 실행 권한 = 임의 이미지 자동 배포" 위험을 감수하거나 자동 병합을 끄고 사람이 병합한다(F D-07의 "자동 병합 없음").
- contents write를 가진 신원(봇 변경 PR App, Codex Connector, Renovate)도 bypass 목록에 없어 main을 바꾸는 병합을 할 수 없다(Restrict updates). 2026-10-21 전에는 code owner 승인 뒤 API 병합이 가능했고, owner PR에서는 App 승인만으로도 됐다(U08 (나)). "봇은 병합하지 않는다"(D-24)는 봇 코드 쪽 규칙과 시험(CHANGE-02 계열)으로 지킨다.
- ChatGPT Codex Connector는 org 전체에 contents·workflows·actions write가 있다(0절). homelab main은 ruleset B, public 앱 저장소 main과 `homelab-app-template` main은 `app-main`이 막는다. 브랜치에서 워크플로 파일을 바꾸거나 run을 재실행해도 App 키를 얻지 못한다. 배포 키는 앱 main push의 태그 고정 `app-build`의 OIDC identity만 받고, 병합 키는 environment `automerge`(배포 브랜치 main)의 secret이라 브랜치 실행은 받지 못한다(C.4.8). main의 다른 워크플로가 `automerge`를 쓰는 것은 ci의 workflow-guard와 사람 검토가 막는다. Codex Connector는 `repository_dispatch`(contents write)와 `workflow_dispatch`(actions write)를 일으킬 수 있으므로 environment secret을 쓰는 워크플로의 트리거는 `workflow_run`만이다(F D-26 조건 (2)). `deploy-merge` 재실행은 PR 상태를 처음부터 다시 검사하므로 결과가 같다.
- 병합 키 사본이 GitHub environment에 있다(C.6.2의 유일한 예외). Infisical의 GitHub 연결 PAT(homelab만, Secrets·Environments RW)가 새면 그 environment secret을 바꾸거나 repo secret을 만들 수 있다. sync를 Repository나 Organization 범위로 잘못 만들면 키가 배포 브랜치 정책 밖의 repo·org secret이 되어 어느 브랜치 워크플로든 읽는다. 그래서 guard가 repo secret 0개·org secret 0개와 environment secret 이름을 대조한다(C.3.9).
- Codex Connector의 PR은 owner 계정으로 찍혀 승인 관문이 없다. Codex가 바꾼 내용은 owner가 bypass 병합 전에 보는 검토가 유일한 관문이다. Codex Connector 설치 토큰으로 owner PR을 승인·병합하는 길은 Restrict updates로 막힌다(재시험 (1)은 같은 권한 꼴의 배포 App으로 확인). owner 권한(사용자 토큰)으로 병합 API를 부르는 길은 작업 환경이 없어 Codex 작업이 시작되지 않으므로 지금은 없다(U37 통과(조건부), #828). 환경을 두지 않는 것이 조건이다(F D-26 (5)). 외부인이 public 저장소의 PR·댓글로 Codex를 부를 수 있는지는 미검증이고, 시험 대신 interaction limit `collaborators_only`와 PR 생성 Collaborators only를 먼저 걸었다(2026-10-22, U38, C.4.10).

**[미검증] (U08. 셋째 조건은 결정 5 하드닝에서 `pull_requests_only`를 먼저 확인했고 실제 병합은 E1, 나머지는 E5에서 시험):** bypass `pull_request` 모드인 App이나 관리자가 병합할 때 bypass 없는 다른 ruleset(A)의 필수 검사가 그대로 적용되는지[S85][S86]. App의 승인 리뷰가 code owner 승인을 대신할 수 없는지. 관리자 역할 bypass가 org owner에게 적용되는지. homelab 쪽 토큰으로 public 앱 저장소의 규칙을 읽을 수 있는지(U25). Codex가 owner 권한으로 병합 API를 부를 수 있는지(U37). **결과(2026-10-21, 시나리오 15):** 관리자 bypass에도 ruleset A가 적용되고(`ci` 실패 PR `--admin` 거부), 관리자 역할 bypass로 owner PR이 병합된다. U25는 통과. **2026-10-21 U08 나머지:** 병합 App bypass 병합에도 ruleset A의 `ci`가 적용된다(통과). App 승인은 owner PR에서 code owner 승인을 대신했다(실패, #822). 그래서 부록 1 "틀리면" 열대로 Restrict updates를 B와 `app-main`에 더했다. **apply 뒤 재시험(2026-10-21, approvals 21:24~21:27·21:27~21:33 행): 통과.** ruleset 5개의 `update`를 켠 뒤 (1) 배포 App 승인으로 reviewDecision이 `APPROVED`여도 mergeStateStatus `BLOCKED`이고 같은 토큰의 병합은 405 "Cannot update this protected ref." (2) owner `--admin` 병합은 된다(probe #8). (3) 배포 PR #826을 `ukyi-homelab-merge`가 자동 병합했다. U37은 2026-10-22 통과(조건부: Codex 작업 환경을 두지 않음, 부록 1).

#### C.4.8 App 키 전달 방식과 T09 → T10 간선

App 키의 원본은 Infisical이다(C-07). Actions 실행에 전달하는 방식을 비교했다. 배포 키는 (1), 병합 키는 (2)로 확정했다(D-04, 확정(사용자 2026-10-18)).

| 방식 | 키 위치 | 기본 브랜치 한정 | Free 제약 | 판정 |
|---|---|---|---|---|
| **(1) Infisical OIDC Auth + `Infisical/secrets-action`** | 실행 중 메모리만. GitHub에 사본 없음 | identity의 claim(`ref`, `job_workflow_ref`, `event_name`)으로 | identity 1개(배포 키). OIDC Auth의 플랜 표시가 문서에 없음[S09][S17] | **배포 키: 확정(D-04)** |
| (2) Infisical GitHub Secret Sync → 저장소 environment | GitHub environment secret(사본) | environment의 배포 브랜치 정책(main)으로 | sync 10개[S01]. environment는 Free에서 public 저장소에만[S102] | **병합 키: 확정(D-04)**. homelab environment `automerge` 하나에 sync 1개. 배포 키를 앱별 sync로 옮기는 안은 검토 후 제외(F D-04) |
| (3) GitHub Secrets를 원본으로 | GitHub | environment로 | 해당 없음 | C-07 예외라 권하지 않음 |
| (4) 클러스터에 키(Image Updater) | 클러스터 Secret | 해당 없음 | 해당 없음 | C.4.2에서 제외 |

**설계** (목표 예시)

- **키마다 프로젝트를 나눈다.** Infisical 프로젝트 `homelab-ci-deploy`(환경 `prod`)에는 `ukyi-homelab-deploy` 키만, `homelab-ci-merge`(환경 `prod`, 경로 `/`)에는 `ukyi-homelab-merge` 키 `HOMELAB_MERGE_KEY` 하나만 둔다. `homelab-ci-deploy`에는 배포 키 전용 OIDC identity `gha-homelab-deploy` 하나만 읽기로 들어간다. `homelab-ci-merge`에는 machine identity가 없고 Secret Sync만 읽는다. `gha-homelab-merge`는 만들지 않는다(D-04). Free에는 경로 RBAC가 없어 identity는 들어간 프로젝트 전체를 읽는다(C.6.3). 그래서 `secrets-action`의 `secret-name` 지정은 경계가 아니고, 프로젝트를 나누는 것만 경계다. ESO identity는 두 프로젝트 어디에도 없다(클러스터가 뚫려도 App 키는 안 샌다).
- **배포 키 OIDC 공통 설정:** issuer `https://token.actions.githubusercontent.com`, audience 고정 문자열. `sub` 문자열 대신 개별 claim으로 묶는다. GitHub은 2026-07-15 뒤 만든·이름 바꾼 저장소에 숫자 ID가 들어간 subject를 쓰기 때문이다[S103]. Infisical 문서는 subject·audience·claim에 glob을 허용하되 가능하면 고정값을 쓰라고 한다[S09] (단일 근거). claim의 뜻은 GitHub OIDC 참조를 따른다[S105]. Infisical의 Subject 칸은 불변 형식 `repo:ukyi-app@292175290/*:ref:refs/heads/main`이다(2026-10-21. 옛 형식으로 두면 새 저장소가 403, B.8 E5). 옛 형식 저장소(`files`, 템플릿)는 `app-build`를 쓰기 전에 저장소 OIDC 설정에서 불변 subject를 켠다.
- **`gha-homelab-deploy`(배포 키):** `repository_owner = ukyi-app`, `ref = refs/heads/main`, `event_name = push`, `job_workflow_ref = ukyi-app/homelab/.github/workflows/app-build.yaml@refs/tags/app-build-v*`. `@*`는 쓰지 않는다. 그러면 브랜치·PR 실행, 앱 저장소의 다른 워크플로, 브랜치 ref로 부른 `app-build`는 키를 받을 수 없다. `app-build-v*` 태그는 ruleset D2로 관리자만 만들고, D1 때문에 관리자도 옮기거나 지울 수 없다. glob이 안 되면 태그를 만들 때마다 이 claim 값을 사람이 바꾼다(릴리스 절차에 넣음).
- **병합 키: Infisical Secret Sync → environment `automerge`** (D-04, 확정(사용자 2026-10-18)). 원본은 Infisical 프로젝트 `homelab-ci-merge`다. GitHub Secret Sync 하나(Scope Repository Environment: `ukyi-app/homelab` / `automerge`)가 사본 하나를 쓴다[S202]. App Connection은 Infisical GitHub App이 아니라 homelab 하나로 좁힌 fine-grained PAT다(Metadata read, Environments RW, Secrets RW, 만료 없음[S201][S202]. 처음 설계는 만료 지정이었고 사용자 2026-10-21 만료 없이 쓰기로 했다). GitHub App 연결은 조직 Secrets write를 org 전체에 받기 때문이다. PAT의 대가는 넷이다: owner 계정에 묶이고, Infisical에 PAT가 저장되며, 만료가 없어 새면 회수할 때까지 유효하고(월 1회 verify가 environment 정책·secret 범위 변경을 잡는다), org가 fine-grained PAT를 허용해야 한다. sync 설정은 Initial Sync Behavior Overwrite Destination Secrets, Auto-Sync 켬, Key Schema 비움(전용 environment라 원본에 없는 secret은 지우는 편이 낫다), 삭제 켬(Disable Secret Deletion 끔)이다. Free sync 10개 중 1개다[S203]. 값이 바뀌면 0~10초 뒤 동기화하고, 실패하면 5회 재시도한 뒤 멈춘다. GitHub 대상에는 일일 재시도와 주기 재동기화가 없고, 마지막 시도가 실패하면 프로젝트 Admin(1인 운영이면 owner)에게 메일이 온다[S203]. 키 이름은 대문자로 바뀌어 전송되므로 원본 키는 대문자로 둔다[S203].
- **environment `automerge`:** 배포 브랜치 정책 main(커스텀 정책 `main` 하나), Terraform `prevent_destroy`(C.3.9). environment 생성과 배포 정책 변경은 Administration write가 필요해 sync의 PAT로는 바꿀 수 없다[S100]. 그래서 Terraform이 environment를 먼저 만들어야 sync가 성공한다. environment를 지웠다 다시 만들면 그 secret도 지워지므로[S102] Sync를 다시 실행한다. 없는 이름을 참조하는 워크플로는 보호 규칙 없는 environment를 새로 만든다[S200]. 이 environment를 지워 두지 않는 이유다. `prevent_destroy`는 콘솔 삭제를 막지 못하고, 지워진 뒤 `deploy-merge`가 한 번 돌면 정책 없는 `automerge`가 다시 생긴다. 그 상태에서 Sync를 다시 실행하면 병합 키가 보호 없는 environment에 들어가 브랜치 워크플로가 읽을 수 있다. 그래서 environment를 다시 만드는 일은 Terraform apply로만 하고, Sync 재실행·병합 키 회전·PAT 교체는 모두 `homelab github verify`(E7 전에는 `tools/tf-github.sh verify`) exit 0을 첫 단계로 한다(guard 9의 배포 브랜치 정책 `[main]` 통과, C.6.5).
- **`deploy-merge`:** `on`은 `workflow_run`(ci, completed) 하나다. merge job에 `if: github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'success'`와 `environment: {name: automerge, deployment: false}`를 둔다(`deployment: false`는 배포 기록 없이 secret만 쓴다[S200]). 단계는 `actions/create-github-app-token@<v3.3.0의 SHA>`(`private-key: ${{ secrets.HOMELAB_MERGE_KEY }}`, `owner: ukyi-app`, `repositories: homelab`)이다. Infisical OIDC 단계와 그것을 위한 `id-token: write`는 없다. 앱 저장소 실행과 homelab 브랜치 실행은 병합 키를 받지 못한다: 브랜치 실행은 배포 브랜치 정책이 job을 거부하고, 다른 저장소 실행에는 homelab의 environment secret이 없다. main의 다른 트리거(`workflow_dispatch`, `repository_dispatch`, `schedule`, `issue_comment` 등)와 다른 워크플로의 `automerge` 사용은 ci의 workflow-guard(C.4.6)와 F D-26 조건 (2)가 막는다. GitHub이 막아 주는 것은 브랜치뿐이다. 그런 이벤트는 GITHUB_REF가 기본 브랜치라 정책을 통과한다[S104]. **[미검증] U36.**
- **보강 셋:** (1) ci의 workflow-guard(C.4.6). (2) F D-26 조건 (2)를 "environment secret을 쓰는 워크플로는 `workflow_run`만"으로 넓힌다. (3) Terraform guard가 environment 브랜치 정책 `[main]`, secret 이름 집합(`[]` 또는 `[HOMELAB_MERGE_KEY]`), homelab repo secret 0개, org secret 0개를 대조한다(C.3.9). (3)은 sync를 Repository나 Organization 범위로 잘못 만들어 키가 배포 브랜치 정책 밖으로 나가는 것과, Key Schema 없이 삭제가 켜진 잘못된 범위의 sync가 기존 secret을 지우는 것을 잡는다.
- **D-07과의 의존:** D-07(자동 병합 범위)은 배포 digest PR만 자동 병합하기로 확정(사용자 2026-10-18, T05)됐다. 그래서 `deploy-merge`, 병합 키, sync, environment `automerge`는 유지된다. D-07을 다시 열어 자동 병합을 없애면 이것들이 사라지고 identity는 그대로 4/5다.
- **job 단위 권한:** `app-build` 안에서 `id-token: write`와 `attestations: write`는 앱 코드를 체크아웃·실행하지 않는 deploy-pr job에만, `packages: write`는 push job에만 준다(C.4.1 예시). 그래서 앱 코드는 이 워크플로 서명의 attestation도 만들 수 없다(C.4.7 조건 5). deploy-pr job은 늘 attest부터 한다(가시성 분기 없음. 앱 저장소는 public만, D-29). 시험·빌드 job은 `contents: read`뿐이라 앱 시험 코드나 그 의존성은 OIDC 토큰을 만들 수 없다[S105]. caller의 권한 선언은 이 job들의 상한일 뿐이다(B.8 E5).
- 배포 키 워크플로 단계(deploy-pr job): `Infisical/secrets-action@<v1.0.18의 SHA>`(method `oidc`, 그 키의 identity와 프로젝트, `secret-name` 지정, 없으면 오류로 끝남)[S14] → `actions/create-github-app-token@<v3.3.0의 SHA>`(`client-id`, `private-key`, `owner: ukyi-app`, `repositories: homelab`, `permission-contents: write`, `permission-pull-requests: write`). 설치 토큰은 1시간 뒤 만료되고 job 끝에 폐기된다[S90][S91].
- **토큰 역할 나눔:** 앱 저장소 쪽 읽기(compare[S83], 기본 브랜치 확인)는 App 토큰이 아니라 deploy-pr job의 `GITHUB_TOKEN`(caller 저장소 `contents: read`)으로 한다. App `ukyi-homelab-deploy`는 homelab에만 설치돼 있어 앱 저장소 쪽은 App 토큰으로 읽지 않는다. called 워크플로는 `GITHUB_TOKEN`을 받고 권한은 caller가 준 것 이하이며[S81], 그 토큰의 권한은 워크플로를 실행하는 저장소로 한정된다[S92]. App 설치 토큰은 homelab 쪽(`image.yaml` 읽기, `deploy/<app>` push, PR 생성)에만 쓴다.
- **[미검증] U05 (E3 첫 작업, 시나리오 15에서 다시):** Infisical OIDC Auth의 Free 사용 가능 여부, 배포 identity의 claim 묶기(glob `app-build-v*`, `event_name`), `app-build`의 test·push job에서 OIDC 토큰 발급 불가. Free 사용이나 claim 묶기가 안 되면 배포 키도 (2)로 간다: 앱 저장소마다 environment와 sync 하나(병합 sync를 빼면 앱 9개까지), 그다음은 Pro(F D-04).
- **검토 후 제외(F D-04):** 배포 키를 앱별 environment sync로 옮기는 안(identity 3/5가 되지만 앱마다 environment·sync·연결 범위가 늘고 앱 9개에서 막히며, 앱 main에서 environment를 선언한 아무 job이 키를 받는다), 배포 PR 생성을 homelab으로 옮기는 안(자격 없이 즉시 깨울 수단이 없어 schedule에 기대면 몇 시간 늦는다), VM identity 제거(VM 시험이 ESO 경로를 검증하지 못한다). CI가 tailnet에 붙어야 하면 Tailscale의 GitHub Actions OIDC(workload identity federation)로 저장한 시크릿·identity·sync 없이 된다[S188].

**T09 → T10 간선의 답:** "완료" 간선으로 둔다(T05 재분해에서 적용, 2026-10-18, spec §8.2). Infisical 프로젝트·배포 identity가 먼저 있어야 배포 PR이 만들어진다(App 생성·키 등록과 병합 키 sync는 T10 자신의 일이다. sync는 environment가 생기는 E5에서 만든다). 다만 T10의 작성 작업(차트, 워크플로, `infra/github` HCL)은 T07 뒤 바로 시작할 수 있고, T09가 필요한 것은 T10의 종단 시험(시나리오 1·11·15를 CLI 없이 하는 동등 절차, E5)뿐이다. 그래서 간선은 "T09 → T10 완료"로 두고 착수는 병행한다(E.2).

#### C.4.9 이미지 롤백과 DB 복원의 구분

| | 이미지 롤백 | DB 복원 |
|---|---|---|
| 바꾸는 것 | 실행 중인 이미지(`image.yaml`) | 데이터 |
| 명령 | `homelab rollback <app> --to <revision 또는 digest>` | `homelab db restore <app> --to <시각>`(C.5.7) |
| 경로 | 사람 PR. `image.yaml`을 이전 값으로 + `hold: true`(새 배포 PR을 멈춤). 조건 1에서 빠지므로 자동 병합되지 않는다 | 사람이 실행하는 단계 절차. 자동으로 일어나지 않는다 |
| 되돌림 | `homelab rollback <app> --release`(`hold: false`) 뒤 다음 빌드가 정상 흐름 | 복원 전 자동 덤프(C.5.7 1단계)로 되돌릴 수 있음 |
| 데이터 영향 | 없음. expand/contract 마이그레이션이면 옛 이미지가 새 스키마로 돈다(C.5.4) | 복원 시각 이후의 쓰기가 사라진다 |

Argo CD의 rollback 기능은 쓰지 않는다. 자동 동기화와 selfHeal이 Git 상태로 되돌리기 때문이다(옛 실측 TD:216-234와 같은 원리). 바꿀 수 있는 레버는 Git뿐이다.

#### C.4.10 공개 저장소 Actions 위협 점검

| 위협 | 현재 (사실, 0절) | 설계 |
|---|---|---|
| fork PR | 승인 정책 `first_time_contributors`(org와 public 저장소. 2026-10-18 결정 5 하드닝 뒤 org·`files`·템플릿은 `all_external_contributors`) | "모든 외부 기여자 승인 필요"(`all_external_contributors`[S198])로 org와 모든 public 저장소(homelab, 템플릿, 앱 저장소)에서 올린다(D-29. `files`·템플릿·org는 결정 5 하드닝으로 2026-10-18에 먼저 올렸다). provider가 지원하지 않아 `gh api`로 맞추고 Terraform guard가 확인한다(C.3.9). 첫 기여자 기준은 사소한 PR 하나 병합 뒤 승인 없이 실행된다는 경고가 있다[S93]. fork PR에는 시크릿이 가지 않는다[S101] |
| `pull_request_target` | 새 구조에서 쓰지 않음 | 쓰지 않는다. public 저장소 기본 차단 정책은 지금 evaluate 모드(실행 계속)이고 2026-11-02 강제도 GA 전부터 기본 정책을 쓰던 저장소가 대상이라 이 정책에 기대지 않는다[S94] |
| self-hosted runner | org·homelab 0개 | 두지 않는다[S95]. NUC를 runner로 등록하지 않는다 |
| GHCR 공개 여부 | 6개 중 5 public. `page`·`trip-mate-api` 패키지를 2026-10-18에 지워 4개 중 3 public(D-29) | 앱 이미지는 public만(D-29). pull 자격(classic PAT, `imagePullSecrets`)은 두지 않는다. `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는지는 문서끼리 어긋나므로[S96][S213] E5에서 org Package Creation의 Public 허용을 확인하고 `homelab-probe` 첫 push로 시험한다(U39). 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다. public 패키지는 다시 private이 안 된다[S96]. `homelab app add`는 익명 pull이 안 되는 패키지를 거부한다(C.7) |
| 액션 공급망 | SHA 고정 강제 꺼짐, `allowed_actions=all` | 모든 `uses`를 40자 SHA로(CI 검사). `allowed_actions`를 selected(GitHub 소유, 검증된 제작자, 목록: `Infisical/secrets-action` 등)로. org의 SHA 고정 정책을 켜도 reusable 워크플로는 태그로 부를 수 있다[S93] |
| `GITHUB_TOKEN` | 기본 read, PR 승인 불가 | 유지한다. 워크플로마다 `permissions`를 최소로 |
| Environment | `homelab-main`(secret 19개) 외 3개 | 모두 지우고(E1) `automerge`(배포 브랜치 정책 main, secret `HOMELAB_MERGE_KEY` 하나. Infisical Secret Sync 사본, D-04) 하나만. 그 secret을 쓰는 것은 `deploy-merge`의 merge job뿐이고 트리거는 `workflow_run`만이다(C.4.6 workflow-guard, C.4.8). Terraform guard가 repo·org secret 0개를 확인한다 |
| Codex Connector | org 전체, actions·workflows write | D-26 조건(homelab·앱 저장소의 어떤 bypass에도 없음, 시크릿을 쓰는 `workflow_dispatch` 없음, environment secret을 쓰는 워크플로는 `workflow_run`만, 앱 저장소와 `homelab-app-template`의 main은 `app-main`, Codex 작업 환경 없음). Codex PR은 owner 계정으로 찍혀 승인 관문이 없다(C.4.7). Codex 클라우드 작업(댓글로 시키는 코드 변경·병합)은 저장소별 작업 환경이 있어야 시작되고 homelab에는 없다(#828 답글 "To use Codex here, create an environment for this repo.", U37). homelab과 앱 저장소에 환경을 두지 않는다(D-26 조건 (5)). 외부인의 Codex 호출 여부는 U38(미검증. 2026-10-22 interaction limit·PR 생성 제한을 먼저 걸었다) |
| 같은 저장소 PR의 검사 변조 | `pull_request`는 merge commit의 워크플로를 실행[S94] | 자동 병합 판단은 `workflow_run`에서만(C.4.7) |
| 앱 저장소 보안 설정 | secret scanning·push protection은 `homelab`만 켜짐(실측 2026-10-18) | 앱 저장소·템플릿·봇 저장소(모두 public, D-29)에 secret scanning·push protection과 private vulnerability reporting을 켠다. public이 되면 이 기능을 쓸 수 있게 될 뿐 저절로 켜지지 않는다[S214]. `homelab app new`가 `gh api`로 켜고 Terraform guard가 확인한다(C.3.9). Actions 로그 보존 단축은 검토한다 |
| 외부인 입력(PR·이슈·댓글) | org·저장소 interaction limit 없음(실측 2026-10-18). 2026-10-22부터 org limit `collaborators_only`(만료 2027-04-22)와 저장소 다섯의 PR 생성 Collaborators only(U38) | 외부인 PR·댓글이 봇 webhook과 Codex의 입력이 될 수 있다. fork PR 승인 정책은 Actions 실행만 막고 webhook·Codex 트리거는 막지 않는다. 봇은 모델 호출 전에 `author_association`을 확인한다(C.8). interaction limit `collaborators_only`(최대 6개월이라 6개월마다 다시 건다. 만료 45일 전부터 verify guard 2가 멈춘다)와 저장소의 PR 생성 Collaborators only는 Codex 외부 호출 시험(U38) 대신 먼저 걸었다(사용자 결정 2026-10-22 "대책 먼저 걸자"). 둘 다 guard 2가 확인한다(C.3.9). org limit은 새 저장소에도 걸리고, PR 생성 정책은 저장소마다라 새 앱은 `homelab app new`가 켠다. 다시 거는 명령은 `docs/runbooks-public/github.md` 2절[S214] |
| 공개 내용(코드·로그·이미지) | D-23 금지 규칙은 `homelab`과 봇 evidence에만 걸려 있음 | D-23 금지 항목(tailnet 이름, Tailscale IP 등)을 앱 저장소의 코드·CI 로그·이미지까지 넓히고, 템플릿 CI에 금지 패턴 검사를 둔다(D-21). 배포 이미지 빌드(push job)는 캐시 없이 한다(C.4.1) |

### C.5 PostgreSQL·Valkey 추가 흐름

#### C.5.1 흐름

```text
사람  homelab db add smoke                 계획만 보여 준다(쓰기 없음)
사람  homelab db add smoke --apply
        1 Infisical homelab/prod /apps/smoke/postgres/PASSWORD 확인 → 없을 때만 생성·저장
        2 data/smoke/values.yaml에 postgres.enabled: true (파일이 없으면 생성)
        3 apps/smoke/values.yaml에 uses.postgres: true
        4 브랜치 cli/db-add-smoke → PR (사람 검토 대상)
사람  PR 검토 후 병합 (자기 PR이라 관리자 bypass, C.4.7)
자동  Application smoke-data (ApplicationSet data, 차트 app-data)
        database ns: ExternalSecret pg-role-smoke(basic-auth, 라벨 cnpg.io/reload) → DatabaseRole smoke → Database smoke
      Application smoke (ApplicationSet apps, 차트 app)
        app-smoke ns: ExternalSecret smoke-db(DATABASE_URL) → 마이그레이션 Job(Sync hook) → Deployment 롤링
사람  homelab status smoke                 DB·역할·Secret·마이그레이션·파드 준비 상태
```

자격증명 원본은 Infisical 키 하나이고, 사본은 `database` ns의 basic-auth Secret(CNPG용)과 앱 ns의 연결 Secret(앱용) 둘이다. 네트워크 접근은 공유 차트 netpol이 `uses.postgres`를 보고 `database` ns 5432 egress를 열고, `database` ns 정책은 `homelab.ukyi.app/kind=app` 라벨 ns에서 오는 5432만 받는다. 예외는 같은 ns의 데이터 차트 hook(라벨 `homelab.ukyi.app/role: pg-acl`)에서 Cluster `pg` 5432로 오는 것 하나다(C.5.3). 백업은 공유 클러스터 전체를 백업하므로 새 DB가 자동으로 포함된다.

#### C.5.2 공유 인스턴스와 전용 인스턴스 (D-05)

| 기준 | 공유 Cluster `pg` + 앱별 DB·역할 (기본) | 앱 전용 Cluster |
|---|---|---|
| 운영 편의 | PostgreSQL 프로세스·백업 설정·감시가 하나 | 앱마다 인스턴스, ObjectStore serverName, 백업 일정, 경보 |
| 자원 | 단일 노드에 PostgreSQL 하나 | 앱마다 메모리 수백 MB |
| 장애 범위 | 클러스터 장애·업그레이드가 모든 앱에 | 그 앱만 |
| 특정 앱만 복원 | 임시 클러스터 PITR → 그 DB만 덤프·복원(C.5.7). 공식 제자리 복원 절차는 없다[S32] | 그 클러스터의 PITR 하나[S32] |
| 버전·확장 격리 | 같은 PostgreSQL major·확장 | 독립 |

전용 Cluster를 고르는 조건(하나라도): (1) 독립 PITR이나 빠른 복원이 필요하다, (2) 데이터가 10GB를 넘거나 쓰기가 많다, (3) 다른 PostgreSQL major나 확장이 필요하다, (4) 다른 보존 기간이 필요하다. 봇은 공유 인스턴스로 시작한다(D-05, 확정(사용자 2026-10-18, T05). DISCOVERY가 조건에 걸리면 재판단).

#### C.5.3 CNPG 선언형 관리

**버전과 지원 범위** (사실): CNPG 1.30.1(2026-09-23), chart `cloudnative-pg` 0.29.1, 기본 PostgreSQL 18.6. 1.30.x는 Kubernetes 1.34~1.36 지원, EOL은 약 2026-12라 1.31 출시 뒤 올림을 계획에 넣는다[S36]. in-tree Barman Cloud는 1.31.0에서 제거 예정이라 Barman Cloud Plugin v0.15.1(chart 0.8.1)로 시작한다[S33][S36].

**선언형 DB·역할 기능** (사실, 1.30 공식 문서와 소스)

- `Database`: 필수 `spec.name`, `spec.owner`, `spec.cluster.name`. `spec.cluster`는 바꿀 수 없고 Cluster와 같은 ns여야 한다. 같은 DB를 두 CR이 관리하면 두 번째를 거부한다. `databaseReclaimPolicy` 기본 `retain`이라 CR을 지워도 DB가 남는다. `ensure: absent`로도 지운다[S30].
- `DatabaseRole`: 1.30.0에 새로 생긴 CRD로 문서가 권장한다. 역할·Cluster·`passwordSecret`이 같은 ns여야 한다. `passwordSecret`은 `kubernetes.io/basic-auth` 타입이고, `cnpg.io/reload: "true"` 라벨이 있으면 비밀번호 변경이 즉시 적용된다. reclaim 기본 `retain`. 이미 있는 역할을 adopt하면 목록에 없는 멤버십을 취소하고 `connectionLimit`을 -1, `validUntil`을 infinity로 바꾼다[S31].
- Argo CD 내장 health는 `Cluster`에만 있고 `Database`·`DatabaseRole`에는 없다(단일 근거: v3.5.5 `resource_customizations` 트리[S75]). 그래서 준비 확인은 각 CR의 `status`(적용 여부)와 실제 접속으로 한다.
- 1.30.0은 비밀번호 Secret을 못 읽을 때 역할 비밀번호를 지우던 문제를, 1.30.1은 `DatabaseRole` 삭제 중 소유 리소스 재생성으로 Argo CD foreground 삭제가 막히던 문제를 고쳤다[S36].

**설치할 리소스** (목표 예시. 필드 이름은 U15로 확인했다: CNPG v1.30.1 소스와 운영 status, 2026-10-23 T11)

```yaml
# platform/cnpg/cluster.yaml을 운영 값(platform/root/values-prod.yaml, E8 VM 격리)으로 렌더한 결과  (목표 예시)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: database
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:<digest>
  storage: { storageClass: local-retain, size: 20Gi }
  walStorage: { storageClass: local-retain, size: 5Gi }
  bootstrap:
    initdb: {}                       # 평상시. 빈 NUC 복구 때만 root apply 전 PR로 recovery를 렌더하고 복구 뒤 되돌린다(C.6.4, B.8 E6)
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true                  # atomic 리스트라 기본값까지 적는다
      isWALArchiver: true
      parameters:
        barmanObjectName: r2
        serverName: pg-20261101      # 클러스터 세대. 클러스터별 values의 값(VM은 다른 버킷·값, E8). 재구축·복구마다 새 값
---
# data/smoke를 data-chart가 렌더한 결과 (목표 예시)
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: smoke
  namespace: database
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  cluster: { name: pg }
  name: smoke
  login: true
  passwordSecret: { name: pg-role-smoke }
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: smoke
  namespace: database
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  cluster: { name: pg }
  name: smoke
  owner: smoke
```

- 앱마다 역할 하나(이름 = 앱 이름 = DB owner). 옛 owner·ro 두 역할 중 ro는 수요가 생기면 더한다. owner를 앱끼리 공유하지 않는다(L10).
- 앱 DB의 PUBLIC CONNECT를 막는다(사용자 결정 2026-10-26, T13). PostgreSQL은 새 DB에 PUBLIC CONNECT를 기본으로 줘 공유 Cluster의 다른 앱 역할도 남의 DB에 접속한다(테이블 권한은 없다, T11 후속). CNPG 1.30.1 `Database`에는 DB 권한 필드가 없어(`allowConnections`는 모두를 막는다, CRD·공식 문서) 데이터 차트 1.0.3이 PostSync hook Job `pg-acl-<앱>`(ns `database`)을 둔다. 앱 역할 자격(`pg-role-<앱>`)으로 `REVOKE CONNECT ... FROM PUBLIC`, `GRANT CONNECT ... TO <앱 역할>, cnpg_metrics_exporter`를 넣고 PUBLIC CONNECT가 없는지 본다. 슈퍼유저 자격은 쓰지 않는다. sync마다 돌아(멱등) 이미 있는 DB는 chartVersion을 올린 sync에서 막힌다. `cnpg_metrics_exporter`는 CNPG 1.30의 지표 수집 역할이다. 기본 쿼리 `pg_extensions`의 `target_databases: ['*']`는 CONNECT 없는 DB를 오류 없이 건너뛰어(1.30.1 `metrics/collector.go`), 주지 않으면 그 DB 지표가 조용히 빠진다. `postgres` DB와 CNPG 기본 DB `app`은 건드리지 않는다(복원 Job이 DB가 지워진 재시도에서 `postgres` DB로 접속을 본다, C.5.7). hook은 sync 때만 돌므로 GitOps 밖에서 DB를 다시 만드는 복원(C.5.7 4단계)이 같은 SQL을 넣는다.
- 공유 `Cluster` 파일에 앱 역할을 덧붙이지 않는다. 앱마다 `DatabaseRole` CR이라 앱 등록이 공용 파일을 고치지 않는다(조사 메모 02의 열린 질문 8번 답).
- 옛 `ensure-role-password` PostSync 훅은 두지 않는다. `DatabaseRole`의 `cnpg.io/reload`와 status, 그리고 CLI의 실제 접속 확인이 대신한다.
- Pooler는 두지 않는다. 도입하면 마이그레이션은 Pooler를 거치지 않는다(transaction 모드는 advisory lock을 못 씀[S38]).

#### C.5.4 마이그레이션 방식 (D-22)

| 기준 | 앱 시작 시 self-migration | Kubernetes Job (Argo CD Sync hook) |
|---|---|---|
| 동시 실행 | 파드 수만큼 시도, 도구의 잠금(대개 advisory lock)에 의존 | sync당 Job 하나 |
| 재실행 안전성 | 파드 재시작마다 실행, 도구가 멱등이어야 함 | sync마다 실행, 도구가 멱등이어야 함 |
| 실패 가시성 | CrashLoop | sync 실패, Application Degraded → 경보 |
| PgBouncer | transaction 모드면 advisory lock 불가[S38] | `pg-rw` 직결로 따로 붙이기 쉬움 |
| 첫 배포 순서 | 파드가 Secret 준비를 기다림(Kubernetes 기본) | PreSync hook은 Sync 단계 리소스(ExternalSecret)보다 먼저 돌아 첫 배포에서 실패한다(추측: 공식 단계 순서에서 추론[S68]) |

**결정(D-22, 확정(사용자 2026-10-18, T05)):** Sync 단계 hook Job이다. `argocd.argoproj.io/hook: Sync`, `hook-delete-policy: BeforeHookCreation`, wave 순서는 ExternalSecret(0) → 마이그레이션 Job(1) → Deployment(2), `backoffLimit: 1`, `activeDeadlineSeconds: 600`. 접속은 `pg-rw.database.svc` 직결이다. 앱은 시작 때 스키마 버전만 확인하고 모자라면 실패한다. 이전 버전 호환(expand/contract)은 필수다. PreSync·Sync hook 모두 새 이미지보다 먼저 스키마를 바꾸므로 그동안 옛 파드가 새 스키마로 돈다(추측). hook은 selective sync에서 돌지 않는다[S68]. 그래서 운영 절차에서 부분 sync를 쓰지 않는다.

**첫 배포 순서:** 데이터 Application(`smoke-data`)과 앱 Application(`smoke`)은 다른 Application이라 순서가 보장되지 않는다. 앱 쪽이 먼저 돌면 역할이 아직 없어 Job이 실패하고, retry backoff로 다시 시도해 수렴한다(B.5의 수렴 보장). `homelab status`는 이 상태를 "DB 준비 대기"로 보여 준다.

`migration.command`가 없는 앱은 스스로 self-migration한다(이미 그렇게 짠 앱용). 이때 replicas는 1로 둔다.

#### C.5.5 앱 삭제와 데이터 폐기의 분리

| 상황 | 일어나는 일 | 보호 장치 (근거) |
|---|---|---|
| `homelab app remove smoke`(PR 병합) | `apps/smoke/` 삭제 → Application `smoke` cascade 삭제 → Deployment, Service, Ingress, 캐시 Valkey, 앱 ns ExternalSecret과 그 Secret(Owner 정책으로 GC[S23]) 삭제. ns는 남는다(CreateNamespace로 만든 ns는 Argo CD가 추적하지 않음[S67]) | 데이터는 다른 Application(`smoke-data`)이라 건드리지 않는다 |
| 누군가 `data/smoke/`를 지움 | Application `smoke-data` 삭제 시도 | `Database`·`DatabaseRole`·Valkey PVC·`Cluster`·`ObjectStore`에 `Prune=false,Delete=false`[S67]. Valkey PVC는 공식 차트의 `keepPvc` 대신 데이터 차트가 직접 렌더해 같은 보호 주석을 붙인다(서버를 내려도 남게, T11). reclaim `retain`[S30][S31]. StorageClass `local-retain`이라 PVC가 지워져도 PV가 남는다 |
| ApplicationSet `data` 자체가 지워짐 | 하위 Application cascade 시도 | 위와 같은 리소스 단위 보호 |
| `homelab data purge smoke --confirm smoke` | 사전 확인: `apps/smoke/` 없음, 앱 워크로드 없음을 확인한 폐기 확인 기록 뒤에 끝난 base backup과 시작한 Valkey 백업(C.7), 지울 목록 출력. **PR 1**(`purge: prepare`): `data/smoke/values.yaml`에 `purge: true`(데이터 차트 1.0.2부터, 옛 `chartVersion`이면 같은 PR에서 올린다)로 보호 주석 제거, `Database`·`DatabaseRole` reclaim `delete`. Valkey PV의 reclaim은 StorageClass 값이라 차트로 못 바꿔 CLI가 PVC에 묶인 PV만 `Delete`로 바꾼다. 병합·동기화 뒤 살아 있는 리소스에서 주석이 빠졌는지 확인. **PR 2**: `data/smoke/` 삭제 → cascade로 CR·PVC 삭제 → CNPG가 DB·역할 DROP. 끝에 Infisical `/apps/smoke` 키 삭제를 한 번 더 확인받고 지운다 | 두 PR 모두 사람 승인. 같은 revision에 `ensure: absent`와 역할 제거를 넣지 않는다(B.8 E6). 역할이 객체를 소유하면 DROP ROLE이 Terminating에서 재시도한다[S31] |

- 비워질 수 있는 Application을 일부러 만들지 않는다. 앱 Application은 늘 Deployment를 갖고, 데이터 Application은 PR 2에서 통째로 지운다(마지막 리소스 prune 거부 함정 회피, B.8 E2).
- 폐기 뒤에도 그 DB는 base backup 안에 보존 기간(14일) 동안 남는다. 완전 삭제는 보존 기간이 지나야 끝난다.
- `homelab data list`는 `data/<app>`이 있는데 `apps/<app>`이 없는 것, 앱 없는 `Database`, Released PV, 아무 파드도 마운트하지 않은 PVC를 보여 준다(L12 판정 기준). 중간에 멈춘 복원이 남긴 객체(라벨 `homelab.ukyi.app/restore`, C.5.7)도 함께 보여 준다.

#### C.5.6 Valkey (D-06)

공식 차트 `valkey` 0.12.0(appVersion 9.1.2)을 subchart로 쓴다[S43]. 앱 차트(1.1.0)는 `cacheServer`, 데이터 차트(1.0.0)는 `valkeyServer`라는 이름으로 넣고, CI·Argo CD가 외부 저장소를 받지 않게 tgz를 커밋한다(공식 index digest와 sha256을 Chart.yaml 주석에 적고 `tools/ci/data.ts`가 대조, T11). valkey-operator는 스스로 "not ready for production use"라고 밝히고[S44], Bitnami 무료 카탈로그는 2025-08-28 뒤 사실상 멈췄다[S45]. 단일 인스턴스로 시작하고 Sentinel·Cluster는 두지 않는다.

| 항목 | 캐시 (기본) | 영속 (작업 큐 등) |
|---|---|---|
| 선언 위치 | `apps/<app>/values.yaml`의 `cache: {enabled: true}`(`uses.valkey: true`와 함께). 앱 차트가 렌더해 앱과 함께 생기고 사라진다 | `data/<app>/values.yaml`의 `valkey: {persistent: true}`. 데이터 차트가 렌더해 앱 삭제 뒤에도 남는다 |
| 메모리 | `maxmemory` 64mb, limit = maxmemory × 1.5 + 64Mi = 160Mi(옛 기본값 `2d2054a:tools/provision-cache.ts:36`, 산식 `:53`). subchart 값은 템플릿으로 계산할 수 없어 1.1.0은 크기 고정이다(16~1024 조절은 차트를 바꿀 때) | 같은 산식, 128mb, 256Mi(고정) |
| eviction | `allkeys-lru` | `noeviction`(Valkey 기본값[S47]). 메모리가 차면 쓰기 오류로 드러난다 |
| 저장 | `dataStorage.enabled: false`, `save ""`, `appendonly no` | PVC `valkey-data`(`local-retain` 1Gi)는 데이터 차트가 직접 렌더하고 보호 주석을 붙인다(서버를 내려도 남게). `appendonly yes`, `appendfsync everysec`, RDB `save` 기본 유지[S41] |
| 배포 전략 | `Recreate` | `Recreate`(RWO PVC를 두 파드가 함께 잡는 RollingUpdate 교착 회피) |
| 인증 | `auth.enabled: true`, `default` 사용자 비밀번호는 ESO Secret. 차트는 인증을 켜면 `default` 사용자를 반드시 정의해야 한다[S43] | 같음 |
| 접근 | 앱 차트 NetworkPolicy(같은 ns만) | 데이터 차트의 Valkey 정책(같은 ns → 6379, egress 없음)과 백업 Job 정책(Valkey 6379, DNS, 인터넷 443). 앱을 지워 앱 차트 정책이 사라져도 남는다 |
| 백업 | 없음 | CronJob `<app>-valkey-backup` 하루 1회 `valkey-cli --rdb` → rclone으로 R2 `valkey/<app>/dump-<UTC 시각>.rdb`, 되읽어 sha256 대조, 14일(lifecycle). 자격은 argv가 아니라 `REDISCLI_AUTH` env. R2 자격은 앱 store에서 절대 키 `/platform/backup/*`(U06, T11) |
| 유실 허용 | 전부(재생성) | 프로세스·노드 재시작 약 1초(AOF everysec[S41]), 디스크 유실 최대 24시간(하루 1회 RDB) |
| 앱 삭제 시 | 함께 삭제 | 보존(C.5.5) |

앱은 어느 쪽이든 `VALKEY_URL` env 하나로 붙는다(공유 차트가 배선). 앱 이름 한도는 캐시 51자(공식 차트의 init 컨테이너 `<app>-valkey-init`이 63자 안), 영속 38자(CronJob `<app>-valkey-backup`이 52자 안)다. 차트가 렌더를 막는다(T11).

**영속 Valkey 복원 절차** (U18 로컬 확인과 운영 시나리오 4 통과 2026-10-23, T11. 실행 명령은 `docs/runbooks-public/restore.md` 1절)

1. PR로 `data/<app>/values.yaml`에 `valkey.running: false`(서버 Deployment를 내리고 PVC는 남기고 백업 CronJob은 suspend). Helm condition은 부정을 못 해 `suspend: true` 대신 이 이름이다. selfHeal 때문에 `kubectl scale`은 되돌려진다(B.8 E2).
2. 복원 Job이 PVC를 마운트해 R2의 RDB를 `dump.rdb`로 두고 `appendonlydir`을 비운다(AOF가 켜져 있으면 시작 때 AOF가 우선한다[S41]). 이 Job은 Git에 두지 않고 CLI(또는 `restore.md`를 따르는 사람)가 `kubectl`로 만드는 일회성 객체이고, 끝나면 지우고 0개를 확인한다(C.5.7의 "복원 리소스는 GitOps 밖이다"). 같은 PVC에는 한 번에 파드 하나만 쓴다(`ReadWriteOnce`는 같은 노드의 여러 파드를 막지 않는다). 그래서 Job 이름은 실행 id와 무관하게 앱마다 `restore-vk` 하나이고(API 서버의 이름 유일성이 잠금), 만들기 직전에 그 PVC를 마운트하는 끝나지 않은 파드·Job이 있으면 멈춘다(T11 #872 뒤 후속).
3. PR로 `running: true`와 `restoreMode: true`(`appendonly no`)를 함께 넣어 새 파드가 RDB를 읽게 하고 키 수를 확인한 뒤, 이 실행의 검증 키 `homelab:restore:<실행 id>`(값 `1`, 만료 없음)를 쓴다. 앱이 복원 중에도 키를 써서 키 수만으로는 복원한 데이터가 남았는지 알 수 없기 때문이다. 4·5단계는 이 키가 있어야 통과하고, 정리 때 지운다. AOF를 켠 채 `appendonlydir`만 지우면 Valkey 9.1.2는 RDB를 읽지 않고 빈 데이터로 시작해 빈 AOF를 만든다(U18 실측). 그래서 이 단계가 필요하다.
4. `CONFIG SET appendonly yes`로 AOF를 다시 만들고 `INFO persistence`에서 rewrite 완료를 확인한다. 완료는 `aof_enabled:1`·`aof_rewrite_in_progress:0`·**`aof_rewrite_scheduled:0`**·`aof_last_bgrewrite_status:ok`가 함께일 때다(`CONFIG SET` 직후 서버는 rewrite를 시작하거나 예약하므로 넷이면 그 rewrite가 끝났다. `aof_rewrites` 같은 횟수는 서버가 다시 뜨면 0이라 보지 않는다). RDB 저장 중에 켜면 Valkey 9.1.2는 첫 AOF 생성을 예약만 해 앞의 셋이 맞는데 `scheduled:1`이고, 이때 다시 띄우면 데이터가 비거나 옛 상태로 돌아간다(로컬 실측 2026-10-26).
5. PR로 `running`·`restoreMode` 줄을 지운다. ConfigMap만 바뀌므로 `kubectl rollout restart`로 서버를 다시 띄워 AOF에서 다시 읽히는지 본다. PR을 기다리는 동안 서버가 다시 떴을 수 있어(복원 모드면 `appendonly no`로 돌아간다), 다시 띄우기 직전에 `appendonly`·AOF 상태를 다시 보고 다르면 4단계부터 한다. 데이터 확인은 고정 키 수 비교가 아니라 검증 키가 있고 키가 0개가 아닌지다(TTL 만료·앱 쓰기 허용). 재시작 뒤 검증 키가 없으면 앱이 새로 쓴 키가 있어도 멈춘다(빈 데이터·옛 AOF 의심). 운영자가 아는 만료 없는 앱 표식 키가 있으면 그것도 본다(선택). 파드를 직접 지우지 않는다. `Recreate`의 "옛 파드가 끝난 뒤 새 파드" 보장은 Deployment 업데이트에만 있고, 파드를 지우면 ReplicaSet이 옛 파드가 끝나기 전에 새 파드를 만든다(로컬 kind 1.37 실측 약 14초 겹침, T11).

#### C.5.7 공유 PostgreSQL에서 특정 앱만 복원 (시나리오 10)

CNPG 복원은 제자리가 아니라 항상 새 클러스터를 만든다[S32]. 공유 클러스터 안의 DB 하나만 되돌리는 공식 절차는 없다. 그래서 `homelab db restore <app> --to <시각>`(목표 UX)이 아래를 단계별로 확인하며 한다.

1. **되돌림용 덤프:** 현재 DB를 `pg_dump -Fc`로 R2 `pgdump/<app>/pre-restore-<시각>`에 남긴다. 주 파드 안 `postgres` 로컬 접속으로 덤프해 도우미 Job(rclone, 실행 id 라벨)의 `rclone rcat`으로 바로 올린다(T11. 5432 네트워크를 쓰지 않고 사람 기기에 데이터가 남지 않는다). `pgdump/`에는 lifecycle이 없어 확인 뒤 손으로 지운다.
2. **임시 클러스터:** `pg-restore-<실행 id>`를(앱 이름을 넣지 않는다. CNPG가 `<클러스터>-1`을 파드 hostname으로 써 앱 이름 37자부터 63자를 넘는다, T11) `bootstrap.recovery`(ObjectStore, `recoveryTarget.targetTime`)로 만든다[S32]. 이 클러스터에는 WAL 아카이버 plugin을 붙이지 않는다(운영 prefix에 쓰지 않게, B.8 E6).
3. **앱 멈춤:** PR로 `apps/<app>/values.yaml`에 `suspended: true`(앱 차트 1.1.0. replicas 0, 마이그레이션 Job도 렌더하지 않아 복원 중 스키마를 바꾸지 않는다). 사람 승인. 멈춤 확인은 Deployment replicas와 Running·Pending 앱 파드로 한다. 완료된 `<app>-migrate` 파드는 hook 삭제 정책(`BeforeHookCreation`) 때문에 남아 있을 수 있다.
4. **덤프·복원:** 빈 DB에 복원한다. 공유 클러스터에서 앱이 멈춘 것을 확인하고 `DROP DATABASE <app> WITH (FORCE)`(남은 연결을 끊고 지운다[S216]) → `CREATE DATABASE <app> OWNER <앱 역할>`(Database 리소스와 같은 설정) → C.5.3의 PUBLIC CONNECT 차단 SQL(데이터 차트 hook과 같은 ACL, 다시 만든 DB는 기본값으로 돌아가고 hook은 sync 때만 돈다) → 임시 클러스터에서 그 DB만 덤프해 **앱 역할로** 복원한다: `kubectl exec <임시 주 파드> -- pg_dump -Fc <app> | kubectl exec -i <앱 ns 복원 Job> -- pg_restore --no-owner --no-privileges`(덤프는 `postgres` 로컬 접속, 복원은 앱 역할로 `pg-rw` 접속, `--clean` 없이). 비밀번호는 Job이 앱 연결 Secret에서 꺼내 메모리 pgpass로 두고 libpq 환경변수로 접속해 명령행 인자에 넣지 않는다. 덤프는 앱이 만든 객체라 슈퍼유저로 복원하면 심어 둔 함수·CHECK가 슈퍼유저 문맥에서 돌아 앱 역할을 승격할 수 있다(로컬 시험에서 재현, `docs/runbooks-public/restore.md` 2a, T11). 그래서 모든 객체가 앱 역할 소유가 되고, 확장은 원본의 스키마·버전·소유자로 먼저 만들고(`postgres` 소유는 `postgres`가, 앱 역할 소유 trusted 확장은 앱 역할이. 덤프 SQL은 실행하지 않는다. 확장·스키마 이름과 버전은 앱이 만든 값이라 모양 검사와 대상 이미지의 설치 가능 목록으로 거른 뒤 psql 변수 인용 `:"이름"`·`:'값'`으로만 넣는다) 그 `EXTENSION`·`COMMENT - EXTENSION` 항목은 복원 목록(`-L`)에서 뺀다. DB 삭제 앞의 확인(되돌림 사본, 임시 클러스터, 앱 멈춤, 앱 역할 실제 접속, 목록과 복원 SQL 검증)은 하나라도 실패하면 삭제 단계가 시작하지 않는다(표식 파일, `restore.md` 0.1). 한 앱 DB에는 복원 하나만 돈다. 앱 ns의 고정 이름 ConfigMap `restore-pg`를 잠금으로 처음에 만들고(이름 유일성이 잠금, C.5.6 Valkey `restore-vk`와 같은 원리) 재개까지 쥔다. 뒤의 모든 단계가 잠금이 자기 실행의 것인지 클러스터에서 다시 본다. 표식만 믿지 않고 DROP 직전에 앱 멈춤, 4-4·4-5 입력(목록·SQL)이 4-2가 검증을 끝낸 때의 내용(sha256, 기준은 4-2만 만든다)과 같은지, 임시 클러스터의 복원 원본(Ready, 복구 지점·serverName)과 덤프 실제 읽기를 다시 본다. 잠금은 그 실행의 파드가 모두 없어진 것을 확인한 뒤 마지막에 지운다(Job은 foreground 삭제)(T11 #874 뒤 후속). 되돌림 사본은 한 실행에 한 번만 만들고 덮어쓰지 않는다. `--no-privileges`만 쓰면 원본의 `REVOKE ... FROM PUBLIC`이 사라져 함수가 PUBLIC 실행 가능으로 넓어지므로, ACL 항목(`ACL`, `DEFAULT ACL`)을 한 번 더 넣고(앱 역할 소유 객체는 앱 역할로, `postgres` 소유 확장 객체는 `pg_restore -f -`로 만든 SQL을 DB 삭제 전(4-2)에 문장 종류별로 검증해 두고 그 파일만 `postgres`로) 원본(임시 클러스터)과 확장 객체를 포함한 ACL을 대조한다. DB 단위 권한(CONNECT)은 DB별 덤프에 없어 대조하지 않고 위 차단 SQL 뒤 PUBLIC CONNECT가 없는지만 본다. GRANT·REVOKE는 소유자만 할 수 있어 앱 역할로는 자기 객체 권한만 바뀐다(로컬 시험, T11). 복원 뒤 앱 역할의 `rolsuper` 등이 모두 false인지 본다. `--clean`만 쓰면 덤프에 있는 객체만 지워 T1 뒤에 만든 스키마·테이블이 남는다[S215]. CNPG Database 리소스는 그대로 두며, 재조정이 다시 만든 DB를 건드리지 않는지는 E6에서 확인한다(형식 미검증).
5. **앱 재개:** 캐시 Valkey를 쓰는 앱은 캐시 파드를 지워 비운다(T1 뒤의 값이 남는다). 그다음 PR로 `suspended: false`.
6. **정리:** 임시 Cluster와 그 PVC, 1·4단계 Job을 지우고 모두 없는지 확인한다(옛 드릴의 고아·PVC 재사용 거짓 PASS 함정). 확인은 아래 라벨로 `kubectl -n database get cluster,job,pvc -l homelab.ukyi.app/restore=<실행 id>` → 0개.
7. **확인:** 앱 readiness와 표식 행(시나리오 10).

**복원 리소스는 GitOps 밖이다.** 1·4단계 Job, 2단계 임시 Cluster `pg-restore-*`, C.5.6의 Valkey 복원 Job은 Git에 두지 않는다. CLI(`homelab db restore`·`restore-check`, 또는 `docs/runbooks-public/restore.md`를 따르는 사람)가 `kubectl`로 직접 만드는 일회성 객체다. 그래서:

- AppProject `data`의 허용 kind(C.3.3)에 Cluster를 넣지 않는다. Job은 C.5.3의 PostSync hook 때문에 허용하지만(2026-10-26, T13) 복원 Job은 그대로 GitOps 밖이다. 어느 Application도 이 객체를 소유하지 않으므로(Argo CD 추적 주석 없음) selfHeal이 되돌리거나 prune이 지우는 대상이 아니다. 같은 이유로 Argo CD가 대신 치워 주지도 않는다.
- 필요한 kubeconfig 권한: 사람의 kubeconfig(C.2, 현재 cluster-admin)로 `database` ns의 `clusters.postgresql.cnpg.io`·`jobs` create·get·delete, `persistentvolumeclaims` get·delete, Valkey 복원이면 앱 ns의 `jobs` create·get·delete. 봇 읽기 계정(C.8)과 CI에는 이 권한이 없다.
- 객체 이름은 실행마다 고유하게(`pg-restore-<실행 id>`, `restore-<실행 id>-r2`·`-db`, Valkey 복원은 예외로 앱마다 고정 `restore-vk`(C.5.6 2단계). 실행 id는 초 단위 시각 + 난수라 같은 분의 두 복원도 라벨이 겹치지 않는다) 하고 라벨 `homelab.ukyi.app/restore=<실행 id>`를 붙인다. 임시 Cluster는 `inheritedMetadata`로 그 라벨을 PVC 등 자기가 만드는 객체에 물려준다(옛 구성이 같은 필드로 PVC·Service에 주석을 물려줌, `2d2054a:platform/cnpg/prod/cluster.yaml:124-129`). 6단계 정리 확인과, 중간 실패로 남은 객체를 `homelab data list`가 보여 주는 기준이 이 라벨이다.
- `database` ns의 NetworkPolicy는 앱 ns에서 오는 5432와 데이터 차트 hook 라벨(`pg-acl`)만 받는다(C.5.1). 그래서 덤프·복원은 Job의 5432 접속이 아니라 `kubectl exec` 파이프(파드 안 로컬 접속)로 하고, 허용 규칙을 따로 두지 않는다(T11).
- 3·5단계(앱 멈춤·재개)만 Git PR이다. 앱 replicas는 selfHeal 때문에 `kubectl scale`로 바꿀 수 없다(B.8 E2).

앱별 정기 논리 덤프(옛 `pgdump-hedge`)는 기본으로 두지 않는다. 복원 속도가 중요해지면 D-05의 전용 Cluster 조건으로 다시 본다.

### C.6 시크릿 전달 흐름

```text
사람 ──(값 등록·변경)──▶ Infisical Cloud
                          ├─ 프로젝트 homelab (환경 prod; 폴더 /platform/*, /apps/*)
                          │     ▲ identity eso-homelab (Universal Auth, 읽기)
                          │     │
                          │   ESO (ns external-secrets, 부트스트랩 Secret 1개)
                          │     ├─ ClusterSecretStore infisical-platform → 플랫폼 ns만(sandbox 제외)
                          │     ├─ ClusterSecretStore infisical-apps     → app-* ns와 database ns만
                          │     │     └─ ExternalSecret(키 명시) → Kubernetes Secret(사본) → 앱·CNPG·Valkey
                          │     └─ ClusterSecretStore infisical-sandbox  → sandbox ns만(/apps/homelab-bot/worker, E4b, C.8)
                          ├─ 프로젝트 homelab-dev (환경 dev; 로컬 개발 값, VM 검증 값)
                          │     ▲ identity eso-homelab-dev (Universal Auth, 읽기. VM 클러스터의 ESO만)
                          ├─ 프로젝트 homelab-admin (환경 prod; Terraform 자격. machine identity 없음, 사람만)
                          ├─ 프로젝트 homelab-ci-deploy (환경 prod; App ukyi-homelab-deploy 키 하나)
                          │     ▲ identity gha-homelab-deploy (OIDC: 앱 main push의 app-build@태그, 토큰은 deploy-pr job만)
                          └─ 프로젝트 homelab-ci-merge (환경 prod; App ukyi-homelab-merge 키 하나. machine identity 없음)
                                └─ Secret Sync(fine-grained PAT 연결, homelab만) ──▶ GitHub ukyi-app/homelab
                                      environment automerge(배포 브랜치 main)의 secret HOMELAB_MERGE_KEY(사본)
                                      ──▶ deploy-merge의 merge job만(workflow_run, D-04)
로컬 개발: infisical run --env=dev -- <명령>   (사람의 Infisical 로그인, 프로젝트 homelab-dev)
```

#### C.6.1 Kubernetes 전달 계층: ESO와 Infisical Operator 비교

| 항목 | **External Secrets Operator (선택)** | Infisical Kubernetes Operator |
|---|---|---|
| 버전 | v2.13.0(2026-10-16)[S24] | v0.11.12(2026-10-16)[S16] |
| 지원 Kubernetes | 2.13은 1.36[S20] | 문서상 1.29~1.33(단일 근거)[S16] |
| 성숙도 | 본체는 성숙, Infisical provider는 stability alpha[S20] | Infisical 공식 제품 |
| 원본 접속 실패 | 기존 Secret을 쓰지도 지우지도 않고 재시도(소스 확인)[S24] | 문서에 없음, 기존 Secret 처리 미확인 |
| 필수 키 누락 | `deletionPolicy: Retain`(기본)이면 동기화 실패, Secret 불변[S23][S24] | 문서에 없음 |
| 갱신 주기 | `refreshInterval` 기본 1h, annotation으로 즉시 갱신[S22] | `refreshInterval` 필수 |
| 파드 재시작 | 내장 없음 | `auto-reload` 주석으로 롤링 재시작[S10] |
| 다른 원본 | 여러 provider | Infisical만 |

**선택은 ESO다**(확정(사용자 2026-10-18, T05), F "Kubernetes 시크릿 전달 계층"). Infisical Operator의 장점은 auto-reload 하나인데, 문서상 지원 버전이 k3s 1.36과 맞지 않는다(단일 근거). 이 근거가 틀려도 ESO 선택은 위 표의 "원본 접속 실패"(소스 확인)와 "필수 키 누락" 행으로 선다. 자동 재시작은 오히려 피한다(C.6.5의 "안전한 반영 순서"). ESO 설정 규칙: `external-secrets.io/v1`만(v1beta1은 served가 아님[S24]), 키는 `data[]`로 하나씩 명시, `deletionPolicy: Retain`, `creationPolicy: Owner`, `find`·`recursive` 쓰지 않음(열린 버그 #6876·#6230[S24]), 최소 v2.10.0 이상(#6821 수정). ESO는 최신 minor 하나만 지원하고 2~3주마다 새 minor가 나와 D-18의 상시 갱신 대상이다[S20].

#### C.6.2 원본과 사본의 규칙

- 앱·DB·Valkey·외부 API 자격의 원본은 Infisical이다. Git에는 ExternalSecret(참조), ClusterSecretStore(동기화 선언), 비밀이 아닌 설정만 둔다. CI가 `kind: Secret` 매니페스트를 거부한다(C.4.6).
- Kubernetes Secret은 실행용 사본이다. 사람은 Infisical만 편집한다. 하나의 Secret은 하나의 ExternalSecret만 만든다.
- 같은 값을 Infisical·GitHub Secrets·암호화 YAML에 중복으로 두지 않는다. 예외는 하나다: 병합 App 키는 Infisical `homelab-ci-merge`가 원본이고 Secret Sync가 homelab environment `automerge`에 사본 하나를 쓴다(D-04, C.4.8). 사람은 GitHub 쪽 사본을 직접 편집하지 않는다. 그 밖의 GitHub Secrets(repo·org secret)는 쓰지 않고, Terraform guard가 repo·org secret 0개를 확인한다(C.3.9).
- 시스템이 자동 발급·갱신하는 인증서와 토큰은 그 시스템에 둔다(C.2 마지막 줄들).

```yaml
# 공유 차트가 apps/smoke/values.yaml의 secrets: [EXAMPLE_API_KEY]로 렌더 (목표 예시)
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: smoke-app
  namespace: app-smoke
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: infisical-apps }
  target:
    name: smoke-app
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: EXAMPLE_API_KEY
      remoteRef:
        key: /apps/smoke/EXAMPLE_API_KEY    # [미검증] provider의 경로 포함 키 문법, E3에서 확인
```

#### C.6.3 권한 경계와 요금제 (D-04)

**구조:** 읽는 주체가 다른 값마다 프로젝트를 나눈다. Free는 identity를 프로젝트에 넣으면 그 프로젝트의 모든 환경·경로를 같은 역할로 보기 때문이다[S01][S04]. 프로젝트는 다섯이다: `homelab`(환경 `prod`, 운영 값), `homelab-dev`(환경 `dev`, 로컬 개발·VM 검증 값), `homelab-admin`(환경 `prod`, Terraform 자격. machine identity를 넣지 않는다), `homelab-ci-deploy`·`homelab-ci-merge`(환경 `prod`, App 키 하나씩). identity는 넷이고 Free 한도 5개 중 하나가 빈다. 병합 키 프로젝트 `homelab-ci-merge`에는 identity가 없고 Secret Sync만 읽는다(F D-04, 확정(사용자 2026-10-18)).

| identity | 인증 | 들어가는 프로젝트 | 권한 | 이유 |
|---|---|---|---|---|
| 사람(owner) | 로그인 + 2FA | 전부 | 관리자 | 값 등록·회전. `homelab-admin`은 사람만 읽는다 |
| `eso-homelab` | Universal Auth(client ID·secret) | `homelab`만 | 읽기 | Kubernetes API를 인터넷에 열지 않는다. Kubernetes Auth는 Infisical이 클러스터 TokenReview를 불러야 하고, 사설 클러스터용 Gateway는 Enterprise다[S06] |
| `eso-homelab-dev` | Universal Auth(client ID·secret) | `homelab-dev`만 | 읽기 | 시나리오 13의 VM 클러스터용. 운영 Infisical 값을 읽을 자격이 VM에 아예 없다(E8). client secret은 E8에서 VM을 준비할 때 발급해 저장소 밖 VM 준비 자산에 두고 VM 폐기 때 폐기한다(E8 VM 격리 2번). 예외는 하나로, 시나리오 13의 DB 복구 동안만 복구 자산의 R2 읽기 전용 자격을 VM에 손으로 넣는다(Infisical 밖, E8 VM 격리 3번) |
| `gha-homelab-deploy` | OIDC(GitHub Actions) | `homelab-ci-deploy`만 | 읽기 | 앱 main push의 `app-build` deploy-pr job. GitHub에 자격을 저장하지 않는다(C.4.8) |
| (identity 아님) Secret Sync `homelab-ci-merge` → environment `automerge` | GitHub App Connection(owner의 fine-grained PAT, homelab만) | `homelab-ci-merge`만 | 읽기, GitHub environment secret 쓰기 | 병합 키를 identity 없이 전달한다. sync는 identity 수에 들지 않는다(좌석은 사람과 machine identity[S01]). `gha-homelab-merge`는 만들지 않는다(C.4.8) |

**경계가 실제로 막는 것과 못 막는 것**

| 경계 | 막는 것 | 못 막는 것 (대응) |
|---|---|---|
| Infisical 프로젝트(identity 소속) | 클러스터(ESO)가 GitHub App 키를 못 읽음. GitHub Actions가 클러스터 시크릿을 못 읽음. 앱 CI(배포 identity)가 병합 App 키를 못 읽음 | 같은 프로젝트 안의 폴더 구분. Free는 RBAC(환경·경로 제한)가 없다[S01][S04]. 그래서 한 프로젝트에는 읽는 주체가 같은 값만 둔다 |
| OIDC identity의 claim(배포 키, C.4.8) | 앱 저장소의 다른 워크플로, 브랜치·PR 실행, 앱 시험 단계가 배포 키를 꺼내는 것 | claim에 맞는 실행 안의 코드(태그 고정 `app-build`)가 하는 일. 대응: 그 코드는 관리자만 만들고(ruleset D2) 아무도 옮기지 못하는(D1) 태그로만 바뀐다 |
| environment `automerge`의 배포 브랜치 정책(병합 키, C.4.8) | homelab 브랜치 실행(Codex Connector가 올린 브랜치 워크플로 포함)과 다른 저장소 실행이 병합 키를 쓰는 것 | main에서 `automerge`를 선언한 job이면 이벤트와 상관없이 받는다(GitHub은 브랜치만 본다). 대응: ci의 workflow-guard(C.4.6), F D-26 조건 (2), main 변경은 사람 검토(ruleset B). sync를 repo·org 범위로 잘못 만들면 정책 밖으로 나가므로 Terraform guard가 repo·org secret 0개를 확인한다 |
| Infisical 프로젝트 `homelab-admin`(machine identity 없음) | 클러스터(ESO)·CI가 Terraform 자격(Cloudflare zone·터널, Tailscale ACL, R2 state)을 못 읽음. 클러스터나 ESO가 뚫려도 사람 전용 관리 자격은 안 샌다 | 사람 계정 탈취(로그인 2FA, 복구 자산 보관으로 대응) |
| Infisical 프로젝트 `homelab-dev`와 VM 전용 identity | VM 클러스터가 prod 값을 못 읽음. VM 설정이 실수로 `homelab`을 가리켜도 그 identity로는 거부된다 | dev 값끼리는 구분이 없다(대응: 시험용 값만 둔다. 시험 터널 토큰·체크·수신자, VM 전용 R2 버킷 토큰, VM operator OAuth client는 운영과 다른 값, E8) |
| ClusterSecretStore `conditions`[S21] | 플랫폼 store를 앱·sandbox ns에서 못 씀, 앱 store를 플랫폼·sandbox ns에서 못 씀, 작업자 store `infisical-sandbox`(conditions는 `sandbox` ns 하나, `secretsPath` `/apps/homelab-bot/worker`)를 sandbox 밖에서 못 씀 | 앱 store를 쓰는 ExternalSecret이 다른 앱 경로를 키로 지정하는 것(`secretsPath`는 보안 경계가 아니라고 문서가 적음[S11]). 대응: ExternalSecret은 Git PR(사람 승인)과 공유 차트로만 생기고, 차트는 `/apps/<자기 앱>/` 경로만 렌더한다. 작업자 store도 identity가 `eso-homelab`이라 Free에 경로 RBAC가 없어 `homelab` 프로젝트의 다른 경로(`/platform/*` 포함)를 읽을 수 있다. 대응: sandbox의 ExternalSecret은 `platform/sandbox`의 Git 매니페스트로만 생기고, sandbox 서비스 계정에는 ExternalSecret 생성 권한이 없어 작업자가 경로를 고를 수 없다(C.8) |
| Kubernetes ns·RBAC | 앱 파드가 다른 ns의 Secret을 못 읽음 | 클러스터 관리자 |

**Free 플랜 사실과 영향** (2026-10-17)[S01][S02][S07]

| Free 한도·부재 | 영향 | 대응 |
|---|---|---|
| identity 5개(사람 포함) | 앱마다 machine identity를 줄 수 없다 | identity 4개(사람 1, 머신 3)로 설계, 여유 1. 병합 키는 identity 대신 Secret Sync. 넘칠 때의 대안은 F D-04 |
| 프로젝트 무제한 | 프로젝트를 경계로 쓸 수 있다 | 프로젝트 5개 |
| 환경 3개, secret sync 10개 | 충분 | 프로젝트마다 환경 하나(`prod` 또는 `dev`). sync는 병합 키 1개(1/10) |
| RBAC 없음(경로 제한 불가) | 프로젝트 단위가 유일한 경계 | 읽는 주체가 다른 값마다 프로젝트를 나눔(5개) |
| 버전 이력·PITR 없음 | 실수로 덮어쓴 값을 되돌릴 수 없다 | CLI는 기존 값을 덮어쓰지 않는다. 회전은 옛 값을 `<KEY>_PREVIOUS`로 남겼다가 확인 뒤 지운다. 분기마다 `homelab`·`homelab-admin` 암호화 내보내기(C.6.4) |
| 감사 로그 없음 | 누가 언제 읽었는지 모름 | 감수(사람 1명) |
| Universal Auth trusted IP 제한은 유료[S05] | client secret이 bearer 자격 | 저장소 밖 보관, 연 1회 회전 |
| API 한도: read 200/분, secret 120/분, IP당 600/분 | ESO는 동기화마다 로그인·조회·폐기 3번 호출한다[S24]. ExternalSecret 30개 × 1h 주기면 분당 약 1.5회(추측) | 충분 |

Pro(identity당 월 $20 연간 / $23 월간)는 RBAC, 버전 이력·PITR, 감사 로그 30일, IP 허용 목록을 준다. identity 4개면 월 $80~92다[S01]. 비용과 권한 분리가 충돌하는 지점(경로 단위 RBAC)은 프로젝트 분리로 메웠으므로 Free로 시작한다(F D-04).

#### C.6.4 최초 연결과 재해 복구

평상시에는 ESO가 Infisical에 처음 접속하는 자격(Universal Auth client ID·secret) 하나만 클러스터 밖에서 사람이 넣는다. VM 시험(시나리오 13)에서만 복구 원본 R2 읽기 자격 Secret 하나가 더 있고 복구가 끝나면 지운다(C.2). Infisical 장애 분기는 이와 따로, 암호화 내보내기에서 필요한 플랫폼·앱 Secret을 손으로 만들고 기록한 뒤 장애가 끝나면 ESO 관리로 되돌린다(아래 복구 순서의 "Infisical 일시 장애"·"클러스터 유실 + Infisical 장애" 행). 일반 앱 시크릿은 Infisical에만 있다. **복구 자산 목록 자체는 저장소 밖 비공개 위치에 둔다(D-23).** 여기에는 종류와 순서만 쓴다.

**복구 자산의 종류**

| 종류 | 쓰는 상황 |
|---|---|
| 계정 접근 수단(GitHub org owner, Infisical, Cloudflare, Tailscale, healthchecks.io의 로그인과 2FA 복구 코드) | 모든 복구의 출발점 |
| ESO 부트스트랩 자격 | 클러스터 재구축 |
| Infisical 암호화 내보내기(분기 1회, `homelab`과 `homelab-admin`. App 키는 GitHub에서 새로 발급하므로 뺀다) | Infisical 계정 잠김·영구 손실 |
| R2 백업 읽기 자격 사본(운영 백업 버킷만, 읽기 전용) | Infisical 없이 DB 복원, 시나리오 13에서 VM의 복구 원본 읽기(E8) |
| Terraform state 버킷 접근 자격 사본 | Infisical 없이 Cloudflare·Tailscale 설정 복구 |
| AdGuard 라이브 설정 내보내기(선택) | UI에서만 바꾼 규칙 복구 |

- 보관: 저장소 밖, NUC 밖 두 곳(예: 비밀번호 관리자 + 오프라인 암호화 사본). 단일 디스크 단일 사본은 매체 유실에 무방비였다(`2d2054a:scripts/backup-local-asset.sh:3-4`).
- 신선도: "백업이 있다"가 아니라 "현재 값과 맞다"를 잰다(L15, L46). 분기 1회 사람이 확인하고, 시나리오 13(VM 재구축)을 이 자산과 VM 준비 자산으로 실행해 실제로 검증한다. VM은 운영 ESO 자격 대신 VM 전용 `eso-homelab-dev` 자격을 쓰므로(E8 VM 격리 2번), 복구 자산의 운영 ESO 자격은 E3과 E8에서 그 값으로 Infisical에 로그인되는지 따로 본다(응답 코드만).
- 옛 SOPS age 개인 키는 새 구조에 쓰이지 않는다. 옛 공개 히스토리의 SOPS 파일을 풀 수 있을지 모르므로(일치 여부 미확인) T06 자격 폐기가 끝났는지 확인한 뒤 지운다(D-20).

**복구 순서**

| 상황 | 순서 |
|---|---|
| 클러스터 유실(빈 NUC) | 계정 접근 → `git clone` → **복구 PR 병합(root apply 전):** `platform/root/values-prod.yaml`의 CNPG 값에 복구 원본(지금 Git의 serverName)을 넣고 serverName을 새 세대 `pg-<복구일>`로 바꾼다. 렌더 결과는 `bootstrap.recovery` + `externalClusters`(원본 전용 ObjectStore, 옛 serverName) + plugins(새 serverName)다 → **실제 빈 NUC 복구에서만:** Tailscale 콘솔에서 유실된 옛 운영 클러스터의 operator·프록시 기기(`tag:k8s-operator`, `tag:k8s`)를 삭제하고, **OS를 다시 설치했으면 `tailscale up` 전에 옛 NUC 호스트 기기도 삭제**(남아 있으면 새 Ingress 이름과 새 NUC 등록 이름에 `-1`이 붙고 기기를 지워도 되돌아가지 않는다, `2d2054a:platform/tailscale/prod/traefik-ingress.yaml:12-15`). VM 시험(시나리오 13)에서는 이 단계를 건너뛴다. 그때 이 기기들은 살아 있는 운영 클러스터의 것이다 → `host/` 부트스트랩(C.3.2의 0. NUC를 다시 등록했으면 `tailscale status --self --peers=false --json \| jq -r '.Self.DNSName \| rtrimstr(".")'`의 첫 라벨이 `prod.env`의 `NODE_NAME`과 같은지 확인하고, 키 만료를 해제한 뒤 Tailscale DNS root `infra/tailscale-dns`를 apply해 전역 nameserver의 NUC 주소를 갱신한다. 그 전에는 공용 서버가 답한다, C.3.6) → k3s → Argo CD(`kubectl` 1) → ESO 부트스트랩 Secret(복구 자산) → root apply → ESO가 플랫폼 시크릿 동기화 → 플랫폼 구성 요소 → CNPG가 옛 serverName 아카이브에서 Cluster `pg`를 복구하고 새 serverName으로 아카이브 시작 → 복구 확인(`kubectl -n database get cluster pg` healthy, 앱 DB의 표식 행, 새 serverName의 첫 base backup `completed`) → 영속 Valkey RDB 복원(C.5.6) → 앱 → 시나리오 1·10 확인 → **정리 PR:** 복구 원본을 지워 렌더 결과를 `initdb`로 되돌린다(새 serverName은 유지) |
| Infisical 일시 장애 | 기존 서비스는 그대로 돈다(C.6.6). 새 배포·회전은 멈춘다(이미 열린 배포 PR의 병합은 GitHub의 병합 키 사본으로 계속된다). 재구축이 급하면 암호화 내보내기로 필요한 Secret만 손으로 만들고 기록한 뒤, 장애가 끝나면 ESO 관리로 되돌린다 |
| Infisical 계정 잠김·영구 손실 | 새 org·프로젝트 5개 → 암호화 내보내기로 값 복원 → machine identity 3개 재발급(C.6.3: `eso-homelab`, `eso-homelab-dev`, `gha-homelab-deploy`) → ESO 부트스트랩 Secret 교체 → 배포 키 OIDC identity 연결 → App 키 재등록(GitHub에서 새 키, 키마다 자기 프로젝트에) → `homelab github verify` exit 0 확인(C.4.8) → GitHub 연결(fine-grained PAT)과 병합 키 sync를 다시 만들고 environment secret `updated_at` 확인. 그 사이 병합은 GitHub에 남은 사본으로 되지만 배포 PR 생성은 OIDC라 멈춘다 |
| 클러스터 유실 + Infisical 장애 | R2 백업 읽기 자격 사본으로 DB 복원까지 먼저. ESO가 동기화하지 못하므로 필요한 플랫폼·앱 Secret은 암호화 내보내기에서 임시로 손으로 만들고 기록한다. **root의 wave 진행에 기대지 않는다** [제안]: Infisical에 닿지 못하는 ClusterSecretStore(wave -7)는 Degraded가 되고 root는 자식 Healthy를 기다리므로 뒤 wave(CNPG 등)가 멈춘다. 빈 클러스터에는 동기화 이력이 없어 ExternalSecret health 덮어쓰기(C.3.3)도 Degraded를 낸다. 그래서 복구 PR(빈 NUC 복구의 복구 PR과 같은 방식)에 root 값 `externalSecrets.enabled: false`를 넣는다. root는 이 값을 클러스터 값 전달 경로(C.3.3, E8 VM 격리 1번)로 모든 구성 요소 Application과 ApplicationSet `apps`의 공유 차트에 넘겨, ClusterSecretStore와 모든 ExternalSecret(앱의 것과 CNPG 백업 자격·Alertmanager 수신자 같은 플랫폼 구성 요소의 것)을 렌더하지 않게 한다. Helm 차트가 아닌 구성 요소에 넘기는 방식은 E2가 정하는 값 전달 방식을 따른다. 그리고 손으로 만든 같은 이름의 Secret을 쓴다. 장애가 끝나면 그 값을 되돌리는 PR로 ESO 관리로 돌아간다. 그 전에 손 Secret을 지울지(ESO가 소유자 없는 기존 Secret을 넘겨받는지)는 U40에서 정한다. 실행 중인 파드는 Secret을 지워도 env를 유지한다 |

**빈 NUC 복구의 복구 PR과 정리 PR** (D-05, 확정(사용자 2026-10-18, T05))

- **복구 PR을 root apply보다 먼저 병합하는 이유:** Git이 평상시 값(`initdb`, 지금 serverName)인 채 root를 apply하면 Argo CD가 자동 동기화로 빈 Cluster `pg`를 먼저 만들고, 앱 `Database`·`DatabaseRole`도 그 위에 생긴다. bootstrap은 초기화 때만 읽혀 나중에 Git을 고쳐도 떠 있는 클러스터는 바뀌지 않고(`2d2054a:platform/cnpg/prod/cluster.yaml:50-53`), Cluster에는 `Prune=false,Delete=false`가 있어 Argo CD가 지우지도 않는다(C.5.3). 그래서 Git이 처음부터 복구 정의를 가리키게 한다.
- **serverName은 반드시 새 값:** CNPG 문서는 한 클러스터에서 같은 ObjectStore를 백업과 복구에 함께 쓰지 말고, 꼭 그래야 하면 serverName을 다르게 하라고 한다. 또 비어 있지 않은 아카이브에 쓰려는 클러스터는 "Expected empty archive" 오류로 `Setting up primary`에 멈춘다고 적는다[S32]. 그래서 복구 PR은 같은 버킷을 가리키는 원본 전용 ObjectStore(예: `r2-source`, 옛 serverName)를 따로 렌더하고, 아카이브는 기존 ObjectStore에 새 serverName으로 한다. 새 값을 빠뜨리면 조용히 섞이지 않고 멈춘다. 이 검사를 끄는 `cnpg.io/skipEmptyWalArchiveCheck` 주석은 쓰지 않는다.
- **정리 PR:** 복구 확인 뒤 복구 원본을 지워 렌더 결과를 `initdb`로 되돌린다. recovery를 남기면 나중에 볼륨을 잃고 Cluster를 다시 만들 때 옛 아카이브에서 낡은 데이터로 조용히 복구된다(B.8 E6, `2d2054a:platform/cnpg/prod/cluster.yaml:54-59`). 떠 있는 클러스터에는 영향이 없다(옛 버전 실측, 같은 파일 `:50-53`). **U26(2026-10-23, T11 시나리오 10에서 확인, kubectl 경로):** CNPG 1.30.1에서 떠 있는 Cluster의 `bootstrap` 변경을 webhook이 거부하지 않고 파드도 다시 뜨지 않는다. Argo CD 경로는 시나리오 13에서 본다. 거부되면 recovery를 남겨 두고, 낡은 복구본이 새 serverName prefix에 쓰려 할 때 위 빈 아카이브 검사가 멈추게 하는 것에 기댄다(CNPGClusterNotHealthy 경보로 드러남).
- **고르지 않은 대안(F D-05):** Cluster `pg`를 자동 동기화가 꺼진 별도 Application으로 두고, 복구 때 사람이 복구 정의로 바꾼 뒤 직접 sync한다.
- 이 순서는 `docs/runbooks-public/restore.md`(E6)에 적고 시나리오 13이 VM에서 실행한다(E8 VM 격리 3번). `restore.md`는 Tailscale 기기 삭제 단계를 "실제 빈 NUC 복구" 분기로 적고, "VM 시험" 분기에는 그 단계를 건너뛰고 시험 뒤 `vm-*` 기기만 지운다고 적는다(E8 VM 격리 4번).
- **VM 시험의 앱·영속 Valkey 멈춤:** 공용 `apps/<앱>/values.yaml`(`suspended`)·`data/<앱>/values.yaml`(`valkey.running`)은 운영도 읽으므로 VM 복구 PR에 넣지 않는다. 대신 `values-vm.yaml`의 `cluster.restore`(`suspendedApps` 앱 이름 목록, `valkey` 앱 이름 → `stopped`·`restoreMode`)에 넣고, ApplicationSet `apps`·`data`가 VM에서만 그 앱의 값을 덮어쓴다(사용자 결정 2026-10-26, T13. 운영 값은 빈 값이라 운영 렌더는 그대로).

#### C.6.5 값 변경과 비밀번호 회전

다음 네 단계는 서로 다른 단계이고 원자적이지 않다: (1) Infisical 원본 변경, (2) Kubernetes Secret 갱신, (3) 실제 DB·Valkey 자격 적용, (4) 앱의 새 자격 사용. 환경변수는 파드를 재시작해야 바뀐다[S46].

| 종류 | 순서 | 명령 (목표 UX) |
|---|---|---|
| 일반 API 키 | Infisical 값 변경 → ExternalSecret 즉시 동기화(annotation 변경[S22]) → Secret 갱신 확인 → 앱 rollout restart → readiness 확인 | `homelab secret set`, `homelab secret sync <app>` |
| DB 비밀번호 | 새 값 생성 후 Infisical에 저장(옛 값은 `PASSWORD_PREVIOUS`) → `database` ns ExternalSecret 동기화 → CNPG가 `cnpg.io/reload`로 즉시 ALTER ROLE[S31] → 역할 status 확인 → 앱 ns ExternalSecret 동기화 → 앱 rollout restart → 실제 접속 확인 → `PASSWORD_PREVIOUS` 삭제. 3~6 사이 옛 값으로 새 연결을 여는 파드는 실패한다(T11 시나리오 8: 새 접속 중단 약 17~20초, 사람 손 속도). 이미 열린 연결은 유지된다(U17). 무중단이 필요하면 역할 두 개를 번갈아 쓰는 방식(선택) | `homelab db rotate <app>` |
| Valkey 비밀번호 | Infisical → 동기화 → Valkey 재시작(사용자 목록은 시작 때 읽음) → 앱 재시작 → 접속 확인 | `homelab cache rotate <app>` |
| 플랫폼 토큰(터널 등) | 새로 발급(Terraform 또는 콘솔) → Infisical → 동기화 → 구성 요소 재시작 → 확인 → 옛 토큰 폐기 | `docs/runbooks-public/rotate.md` |
| GitHub App 키 | 배포 키: GitHub에서 새 키 → `homelab-ci-deploy` 값 교체 → 다음 deploy-pr 실행 확인 → 옛 키 삭제. 병합 키: `homelab github verify` exit 0 확인(C.4.8) → GitHub에서 새 키 → `homelab-ci-merge` 값 교체 → `gh api repos/ukyi-app/homelab/environments/automerge/secrets/HOMELAB_MERGE_KEY --jq .updated_at`이 교체 시각 이후인지 확인(Infisical 실패 알림 메일이 왔거나 시각이 이전이면 Sync를 다시 실행) → 옛 키 삭제. App 키는 만료되지 않고 25개까지 함께 유효해[S199] `deploy-merge` 성공만으로는 새 키 반영을 증명하지 못한다. 옛 키를 지운 뒤에야 401이 나고, 그때 배포 PR은 열린 채 남는다(안전한 쪽 실패) | 같은 문서 |
| Infisical GitHub 연결 PAT | `homelab github verify` exit 0 확인(C.4.8) → 새 fine-grained PAT(homelab만, Metadata read, Environments RW, Secrets RW, 만료 없음: 사용자 2026-10-21) 발급 → Infisical App Connection 교체 → Sync 재실행과 `updated_at` 확인 → 옛 PAT 폐기 | 같은 문서 |
| ESO 부트스트랩 자격 | 새 client secret → 복구 자산 갱신 → Kubernetes Secret 교체 → ESO 재시작 → 동기화 확인 → 옛 secret 폐기 | 같은 문서 |

규칙:

- 최초 생성은 한 번만 하고, 이후 일반 재배포·재실행은 값을 바꾸지 않는다. CLI는 Infisical에 값이 있으면 쓰지 않는다(옛 `scripts/seed-secrets.sh:126-136`의 원칙).
- 필수 키가 없으면 ExternalSecret이 `SecretSyncedError`로 멈추고 Secret은 바뀌지 않으며, 처음이면 파드가 시작하지 않는다[S23][S46]. 잘못된 값이 적용되지 않는다(시나리오 6).
- 자동 재시작 컨트롤러(Reloader 등)는 두지 않는다. 재시작은 위 순서의 한 단계로 명시적으로 한다.
- ESO용 Universal Auth client secret은 사용 횟수 무제한, TTL 0으로 두고 연 1회 손으로 회전한다. ESO는 동기화마다 로그인하므로 사용 횟수를 1로 두면 두 번째 동기화부터 실패한다(추측, [S05][S24]).

#### C.6.6 Infisical 장애·인증 만료 때의 동작

| 상황 | 동작 | 근거 |
|---|---|---|
| Infisical 연결 실패 | ESO가 기존 Secret을 쓰지도 지우지도 않고 재시도. 실행 중 파드는 그대로, 파드 재시작도 etcd의 Secret으로 된다 | 사실: ESO v2.13.0 `externalsecret_controller.go`[S24] |
| 새 앱·새 키 | Secret이 생기지 않거나 새 키가 빠져 새 파드가 시작하지 않는다. 지금 spec으로 동기화한 적 없는 `Ready=False` ExternalSecret을 health(내장 health[S75]와 C.3.3의 덮어쓰기 모두)가 Degraded로 보고 그 Application이 Degraded가 된다 | [S46], Argo CD 내장 `ExternalSecret/health.lua`[S75], C.3.3 |
| 같은 Application의 뒤 wave | 앞 wave가 unhealthy면 뒤 wave로 넘어가지 않을 수 있다. 그래서 "지금 spec으로 한 번 동기화된 ExternalSecret은 갱신 실패에도 Healthy, 상태가 아직 없으면 Progressing"으로 health를 덮어쓴다(C.3.3). 결과: 기존 키만 쓰는 배포(이미지 변경)는 Infisical 장애 중에도 진행되고, 새 키가 필요한 배포만 멈춘다 | 추측([S68][S75]), 시나리오 7에서 확인 |
| client secret 만료·폐기 | 모든 동기화가 즉시 실패, 기존 Secret 유지, ExternalSecretNotReady 경보 | [S05][S24] |
| CI에서 Infisical 장애 | `deploy-pr` job이 실패로 끝난다(빌드는 성공, PR 없음). 조용히 넘어가지 않는다. 다음 빌드나 재실행이 이어 간다. 병합은 GitHub environment의 사본으로 계속되지만, 새 배포 PR이 생기지 않으므로 이득은 장애 전에 열린 PR뿐이다 | `Infisical/secrets-action`은 시크릿이 없으면 오류로 끝난다[S14] |
| 병합 키 Secret Sync 실패(PAT 회수, 범위 오류) | GitHub에 옛 사본이 남아 병합은 계속된다. 5회 재시도 뒤 멈추고 프로젝트 Admin에게 메일이 온다. 주기 재동기화가 없어 사람이 Sync를 다시 실행할 때까지 그대로다 | [S203] |
| 429 한도 초과 | ESO 재시도 | [S07] |

### C.7 CLI와 운영 경험

**원칙:** 얇게 만든다. `gh`, `git`, `infisical`, `kubectl`을 부르고 자체 상태 저장소를 두지 않는다. 배포 상태는 GitHub(실행·PR)과 Argo CD Application CR(`kubectl`로 읽음, NUC에 argocd CLI가 없음, spec §4.5)에서 읽는다. 언어는 Bun·TypeScript(design-prompt §8 기본값), 배포는 `bun build --compile` 단일 실행 파일(B.8 E7의 `bun link` 함정 회피).

**명령** (T12에서 만들었고 2026-10-26 운영 검증(T12-05)을 통과했다. 바꾸는 명령은 기본이 `plan`이고 `--apply`로 실행한다)

| 명령 | 하는 일 | `plan`이 읽는 것 | `--apply`가 바꾸는 것 |
|---|---|---|---|
| `homelab doctor` | 로컬 도구·로그인·kubectl context 점검 | 로컬 | 없음 |
| `homelab app new <app>` | 템플릿 main에 `app-main`이 active인지 먼저 본다(아니면 멈춤. 검토 안 된 템플릿 내용이 새 앱 main에 들어가는 것을 막음). 그다음 `infra/github/app-repos.json`에 앱을 더하는 PR을 연다(사람 검토 후 병합). 병합 뒤 다시 실행하면 템플릿(`homelab-app-template`)으로 public 앱 저장소를 만들고(private 선택지는 없다, D-29) 저장소 보안 설정(fork PR 승인 `all_external_contributors`, secret scanning·push protection, private vulnerability reporting, PR 생성 `pull_request_creation_policy=collaborators_only`)을 `gh api`로 켠 뒤, 곧바로 main에서 `homelab github apply`로 main ruleset `app-main`(C.4.7)을 건다. plan에 `app_main["<app>"]` 생성 말고 다른 변경이 있으면 멈춘다(래퍼 `plan --plan-json`이 남긴 변경 목록(주소·동작, 값 없음)으로 판정한다. 새 `app_main`에 의존해 미뤄진 guard 3·4의 읽기(data `read`)는 세지 않고 래퍼 apply 끝의 verify가 본다. T12). 래퍼가 고정 URL에서 새로 clone한 main에서만 돌아 목록 변경을 먼저 병합한다(C.3.9). 그래서 목록 PR이 병합되기 전에는 저장소를 만들지 않는다(목록 밖 public 저장소는 guard 8이 모든 plan을 멈춘다). 이미 있는 저장소가 템플릿에서 만든 public 저장소가 아니면 덮지 않고 멈춘다(T12). 저장소 생성과 apply 사이 약 1분은 새 main에 보호가 없지만 조건 9가 자동 병합을 막는다. | GitHub, homelab main | `app-repos.json` PR, public 저장소 생성과 보안 설정, `app-main` 적용 |
| `homelab app add <app> [--public <host>] [--internal <name>] [--postgres] [--cache[=persistent]]` | 최초 등록. DB·캐시를 같은 PR에 함께 넣을 수 있다. 앱 저장소가 private이거나 GHCR 패키지를 익명으로 받을 수 없으면 멈춘다(D-29. 익명 확인은 `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:ukyi-app/<app>:pull'` → 200). `app-main` 대조 결과(자동 배포 가능 여부)를 계획에 보여 준다 | 앱 저장소 main HEAD, 그 빌드의 GHCR digest·라벨, 앱 저장소 가시성·ruleset, GHCR 익명 토큰 응답, homelab main, Infisical 키 존재 | `apps/<app>/values.yaml`·`image.yaml`(+ `data/<app>/values.yaml`, Infisical 비밀번호) PR |
| `homelab db add <app>` | PostgreSQL 연결 | Infisical 키 존재, homelab 파일 | Infisical 비밀번호(없을 때만), `data/<app>`·`apps/<app>` PR |
| `homelab cache add <app> [--persistent]` | Valkey 연결 | 같음 | 같음 |
| `homelab secret set <app> <KEY>` | 앱 시크릿 등록(값은 stdin) | Infisical 키 존재 | Infisical(있으면 `--replace` 필요) |
| `homelab secret sync <app>` | 즉시 동기화 + 재시작 | ExternalSecret 상태 | annotation, rollout restart |
| `homelab status [<app>] [--platform]` | 빌드·배포 PR·Argo CD·DB·시크릿·마이그레이션 준비 상태와 다음 행동. 준비 안 된 줄이 하나라도 있으면 exit 1이고 다음 행동은 첫 문제의 것이다(진행 중도 문제로 보인다, T12-02) | GitHub(앱 저장소 main의 마지막 Actions run, homelab의 열린 `deploy/<app>` PR), homelab main의 values·image.yaml, Argo CD Application `<app>`·`<app>-data`, 파드 Ready와 imageID(= image.yaml digest), ExternalSecret Ready(빠진 키는 values `secrets` − Infisical 키 이름으로), CNPG DatabaseRole·Database `status.applied`, Job `<app>-migrate`, Valkey Deployment·백업 CronJob `lastSuccessfulTime`, 공개 host `/healthz` 응답 코드. `--platform`: project `platform` Application, 노드, Cluster `pg`, ClusterSecretStore | 없음 |
| `homelab logs <app> [--since <기간>] [--job migrate] [--previous]` | 로그 | `kubectl logs`(지금 파드, 마이그레이션 Job). 과거 로그는 Grafana(VictoriaLogs) 안내만이다: CLI에서 닿을 경로가 없고(클러스터 안 서비스, 읽기 경로는 Grafana 데이터소스 뒤 vmauth, C.3.7) 새 자격을 두지 않는다(T12-02) | 없음 |
| `homelab rollback <app> --to <rev\|digest>` / `--release` | 이미지 롤백·해제. `--release`는 `hold: false`만 바꾸고 `image.yaml`의 이미지는 그대로 둔다. 다음 빌드의 배포 PR이 이미지를 바꾼다. 다음 빌드를 기다리지 않고 최신으로 돌아가려면 `--to <최신 커밋>` 뒤 `--release`다(T12-05) | `image.yaml`의 git 기록 | PR |
| `homelab db rotate <app> [--finish]` / `homelab cache rotate <app> [--finish]` | 명시적 비밀번호 회전(C.6.5). 상태 저장소가 없어 Infisical `PASSWORD_PREVIOUS`가 "회전 중" 기록이다: 기본은 새 값 → 사본 동기화 → (DB는 CNPG 적용 대기) → 재시작 → 헬스·새 값 접속·옛 값 거부 확인까지 하고 `PASSWORD_PREVIOUS`를 남긴다(다시 쳐도 모두 same). `--finish`가 같은 확인(영속 Valkey는 수동 백업 Job까지)을 다시 한 뒤 지운다(T12-03) | 상태 | Infisical, Secret, 재시작(템플릿 주석 `homelab.ukyi.app/secrets-rv`) |
| `homelab db restore <app> --to <시각>` / `--finish` / `--abort`, `homelab db restore-check` | 앱 하나 복원(C.5.7) / 최신 백업 복원 시험. `--to`는 오프셋 필수(RFC 3339 또는 런북 꼴)이고 UTC `YYYY-MM-DD HH:MM:SS+00`으로 바꿔 넘긴다. 범위: WAL 아카이브 중, ObjectStore의 복구 가능 범위(`firstRecoverabilityPoint`) 안(없으면 멈춤), T1 앞과 **뒤**에 끝난 completed base backup이 있다. 뒤의 백업이 WAL이 T1까지 R2에 있다는 근거다(`pg_backup_stop`은 끝 WAL 아카이브를 기다린다). CNPG 1.30.1 Cluster에는 마지막 아카이브 시각 필드가 없어 마지막 백업 뒤의 시각은 온디맨드 base backup을 만든 뒤에 복원한다(#886 r1). 실행 기록은 앱 ns의 잠금 ConfigMap `restore-pg`(런북 `$W`의 표식·고정 값·4-2 입력을 클러스터에). DB를 지우는 단계는 앞 표식(되돌림 사본·임시 Cluster·앱 멈춤·앱 역할 접속·4-2)이 모두 있고, 지금 앱이 멈춰 있고, 되돌림 사본이 R2에 있을 때만 시작한다(core가 잠금·입력·원본·덤프 읽기를 다시 본다). 같은 실행을 두 호출이 함께 돌리지 않게 바꾸는 단계마다 고정 이름 lease Job(`restore-<실행 id>-lease`, suspend)을 쥔다. 본 복원이 중간에 끊기면 다음 실행이 빈 DB로 다시 만들고 처음부터 복원한다. 끝나도 잠금은 남고 `--finish`가 지운다. `--abort`는 DB를 지우기 전에만. `restore-check`는 지금 − 10분까지 임시 Cluster로 복구해 Database CR마다 DB가 있는지 본 뒤 지운다. 앞 시도의 임시 Cluster는 다시 쓰지 않고 `--abort`로 버린다(T12-03) | 백업 목록 | `kubectl`로 만드는 GitOps 밖 일회성 임시 Cluster·Job(라벨 `homelab.ukyi.app/restore`, 끝나면 지우고 0개 확인, selfHeal·prune 대상 아님, 사람 kubeconfig의 `database` ns 쓰기 권한 필요, C.5.7), 앱 멈춤·재개 PR |
| `homelab cache restore <app> [--object <dump-…rdb>] [--backup-first]` / `--finish` / `--abort` | 영속 Valkey 하나 복원(C.5.6, restore.md 1절. 결정 D1, 사용자 2026-10-23, T12). 멈춘 단계에서 다시 시작하려고 실행 기록(표식·받은 객체·키 수)을 앱 ns의 ConfigMap `restore-vk`에 둔다(restore.md의 `$W`를 클러스터에). PR 셋(내림·복원 모드·끄기)마다 병합을 기다리며 멈추고(종료 코드 3) 같은 명령이 잇는다. 끝나도 기록은 남고 `--finish`가 지운다. `--abort`는 복원 Job 전에만(T12-03) | R2 백업 목록, `data/<app>`의 `valkey.persistent` | restore.md 1절 순서(복원 모드로 RDB를 읽은 뒤 AOF를 켠다)를 `kubectl`로, 일회성 객체는 끝나면 지우고 0개 확인 |
| `homelab app remove <app>` | 앱 삭제(데이터 보존) | homelab | PR |
| `homelab data list` | 주인 없는 보존 데이터 | homelab, CNPG, PV·PVC | 없음 |
| `homelab data purge <app> --confirm <app>` | 데이터 폐기(C.5.5). 단계마다 main 파일과 살아 있는 리소스로 어디까지 왔는지 본다: 앱 워크로드 없음 확인 → 폐기 확인 기록(`database` ns ConfigMap `data-purge-<app>`. 생성 시각(API 서버 시계)이 기준이다. 앱 ns가 없는 PostgreSQL 전용 데이터도 같은 자리) → 그 시각 뒤에 끝난 completed base backup과 그 시각 뒤에 시작해 성공한 Valkey 백업 Job(보존 14일 − 여유 2일 안). 그래서 첫 실행은 기록만 남기고 백업이 없어 exit 1로 멈춘다. 정기 백업(PostgreSQL 03:00, Valkey 03:30 KST)을 기다리거나 온디맨드 백업(CNPG `Backup` CR, CronJob `<app>-valkey-backup`에서 만든 Job)을 만든 뒤 다시 실행한다. 사이에 앱 워크로드가 다시 보이면 기록을 지우고 멈춘다(T12-03 후속 #889·#893·#896) → PR 1(`purge: true`) 병합 → 동기화 대기 → Valkey PV reclaim Delete → PR 2(`data/<app>/` 삭제) → 삭제 대기 → Infisical 키는 터미널에서 앱 이름을 다시 친 뒤(T12-03) | 백업 신선도, 앱 등록 여부 | PR 2개, Infisical 키 삭제(마지막, 재확인 뒤) |
| `homelab github plan` / `apply` / `verify` | GitHub Terraform root(C.3.9)를 E5 래퍼 `tools/tf-github.sh`와 같은 규칙으로 감싼다: `GITHUB_TOKEN` 환경변수로만, `GITHUB_APP_*`·`TF_CLI_ARGS*`·`TF_LOG*` unset, `TF_CLI_CONFIG_FILE`은 래퍼 소유 설정 파일로 고정, 토큰 종류별 확인(classic·OAuth는 `delete_repo` 범위 거부, fine-grained PAT는 만료 확인), 고정 URL(`https://github.com/ukyi-app/homelab.git`)에서 main을 새로 clone한 사본에서만 실행(`env -i`로 hook·전역 git 설정을 끊는다. 작업 사본과 그 `.git`은 쓰지 않는다), plan 종료 코드 0·2만, delete는 `--allow-destroy`로만, apply 전 state 백업, apply 실패 뒤 ruleset 재import. `plan`·`verify`는 `-lock=false`라 R2에 잠금을 쓰지 않는다(AC-P13). `verify`는 `plan -lock=false -detailed-exitcode`(0 같음, 2 차이, 1 guard 실패). `homelab github *`의 종료 코드는 래퍼 코드 그대로다(결정 D2) | GitHub(대상 homelab, `homelab-app-template`, `app-repos.json`의 앱 저장소), R2 state | ruleset, environment, Actions 권한(`apply`만). 저장소 설정과 fork PR 정책은 리소스가 아니라 guard가 다르다고 알려 주면 사람이 `gh api`로 맞춘다 |

**`plan`은 읽기 전용이다.** 비밀번호 생성, Infisical 쓰기, 브랜치 push, PR 생성, `kubectl` 변경이 일어나지 않는다. 시험은 외부 명령 argv를 기록하는 PATH 스텁으로 모든 명령을 `plan` 모드로 돌려 쓰기 부명령이 0건임을 단언한다(L50, AC-P13). 쓰기 판정은 읽기 허용 목록이고 목록 밖(모르는 도구·하위 명령 포함)은 쓰기로 본다(`cli/src/core/writes.ts`). 구조(사용자 결정 2026-10-23, T12 #873 3라운드): 명령은 외부 명령을 직접 실행할 수 없고 CLI 공통부가 주는 타입 있는 어댑터만 부른다. 어댑터마다 argv 모양이 고정이라 안전의 근거는 어댑터 모양이고, 쓰기 판정은 마지막 방어선과 시험 원장 집계로 남는다. 읽기 문맥에는 쓰기 함수가 없고, 쓰기 어댑터는 엔진이 단계 실행 한 번마다 새로 만들어 넘긴 뒤 폐기한다. 범용 kubectl 조회에는 Secret·`--raw`·`config view`가 없고(값은 해시·존재만 내는 전용 어댑터), curl은 GHCR 익명 토큰 조회 하나(`-q`로 `.curlrc` 끔), git은 github 위임의 임시 폴더 fresh clone 하나다. 명령의 import 허용 목록과 전역 금지(파일·프로세스·네트워크·환경변수)는 정적 시험이 막는다.

**명령 경계의 위협 모델(사용자 결정 2026-10-23, T12-01b):** 명령 경계(불투명 시크릿 핸들, 정적 import 경계, 타입 있는 어댑터)는 실수로 새는 것을 막는 장치다. 같은 프로세스에서 일부러 전역을 바꾸는 코드는 막지 않는다(명령 코드는 저장소의 리뷰받은 코드다). 싼 보강 둘을 둔다: CLI 공통부는 시작할 때 잡아 둔 내장 함수(`JSON.parse`·`JSON.stringify`·`Object.freeze`·`String.prototype.includes` 등, `cli/src/core/intrinsics.ts`, 진입점의 첫 import)로 시크릿 판정·출력·해석을 하고, 명령 파일의 내장 전역 변경(재할당, 프로토타입, `defineProperty`류, `Object.assign(내장, …)`)은 정적 시험이 막는다.

**재실행 안전:** 여러 시스템의 변경은 원자적 트랜잭션이 아니다. 그래서 각 단계가 실행 직전에 현재 상태를 읽고 이미 된 단계는 건너뛴다(Infisical 키 있음 → 재사용, 파일 같음 → 변경 없음, 같은 브랜치 PR 열림 → 갱신). 변이 호출이 타임아웃이면 재시도하지 않고 상태를 다시 읽는다(B.8 E7). 중복 플래그는 거부한다.

**출력** (목표 예시)

```text
$ homelab db add smoke
계획 (아무것도 바꾸지 않았다)
  1 Infisical homelab/prod /apps/smoke/postgres/PASSWORD   없음 → 생성
  2 data/smoke/values.yaml                                 없음 → 생성 (postgres)
  3 apps/smoke/values.yaml                                 uses.postgres: false → true
  4 PR ukyi-app/homelab                                    새로 (브랜치 cli/db-add-smoke)
다음: homelab db add smoke --apply
```

```json
{"schema":"homelab-cli/v1","command":"db add","app":"smoke","mode":"plan","status":"pending",
 "steps":[{"id":"infisical-password","state":"missing","action":"create","target":"Infisical homelab/prod /apps/smoke/postgres/PASSWORD","detail":"없음 → 생성","result":"planned"},
          {"id":"data-values","state":"missing","action":"create","target":"data/smoke/values.yaml","detail":"없음 → 생성 (postgres)","result":"planned"},
          {"id":"app-values","state":"differs","action":"update","target":"apps/smoke/values.yaml","detail":"uses.postgres: false → true","result":"planned"},
          {"id":"pr","state":"missing","action":"create","target":"PR ukyi-app/homelab","detail":"새로 (브랜치 cli/db-add-smoke)","result":"planned"}],
 "notes":[],"next":"homelab db add smoke --apply"}
```

- JSON 키(T12): `mode`는 `plan | apply | read`, `status`는 `same`(변경 없음) `pending`(plan에 차이) `done` `waiting`(apply 뒤 바깥 대기) `failed` `usage`. `steps[].state`는 `missing | differs | same`이고 apply에서는 실행 직전에 읽은 상태다(그래서 재실행의 모든 단계가 `same`, G 시나리오 5). `action`은 `create | update | delete | none`, `result`는 `planned | skipped | applied | waiting | failed | not-run`. 실패에는 `error: {message, next}`, `github *`에는 래퍼 종료 코드 `exitCode`가 붙는다.

- 어떤 출력에도 시크릿 값이 없다. 값의 존재만 보인다. 마지막 변경 시각은 Infisical CLI 0.44.2가 내지 않는다(목록 JSON은 `secretKey`·`secretValue`뿐, 2026-10-23 로컬 가짜 API 실측, T12, lead 결정으로 존재만). 시크릿은 값 감쌈 타입으로만 다니고 stdin으로만 넘긴다. 시크릿 입력은 16자 이상만 받고, 출력 계층은 16자 이상 원문이 섞인 출력을 막는다(짧은 값 추적은 고정 옵션·JSON 키와 겹쳐 뺐다, 사용자 결정 2026-10-23). 명령이 받는 시크릿 핸들은 원문을 꺼내는 메서드가 없는 불투명 객체이고(16자 미만 기존 값의 보호는 이것에 기댄다), 원문 해석은 CLI 공통부 안에서만 한다(T12 #873 3라운드).
- Infisical CLI 0.44.2는 로그인 사용자의 조회 값을 `$HOME/.infisical/secrets-backup/`에 파일로 남긴다(`infra/README.md` 2절). CLI의 모든 `infisical` 호출은 래퍼(`tools/tf-github.sh`)와 같은 보호를 거친다: 그 폴더를 0500으로 잠그고(남은 파일은 지운다) 실제로 쓰기 불가인지 써 보고 확인한 뒤 실행하고, 호출 뒤 파일이 생겼으면 지우고 실패한다. 경로가 심볼릭 링크면 멈춘다. 같은 HOME의 다른 실행과 겹쳐도 백업 경로를 다시 열지 않는다: 이미 잠긴 빈 폴더는 그대로 두고, 남은 파일은 폴더째 옆 이름으로 옮긴 뒤 처음부터 0500인 새 폴더를 만들고 지운다. HOME은 실제 경로로 풀어 자식에게도 그 값을 주고, `.`·`..` 성분이 있는 HOME은 거부한다(#876 리뷰). 이 로컬 폴더 정리는 `plan`에서도 한다(Git·Infisical·클러스터는 바꾸지 않는다, T12-01b #873 리뷰 P1). 알려진 한계(lead 결정 2026-10-26): `tools/tf-github.sh`(`homelab github *`가 위임하는 래퍼 포함)는 이 폴더를 잠깐 0700으로 열고 비운 뒤 잠그므로, 같은 HOME에서 래퍼와 다른 CLI 명령을 동시에 돌리면 그 틈에 쓴 백업을 양쪽이 놓칠 수 있다. 동시에 돌리지 않는다.
- 등록 명령의 읽기와 재실행 same 판정(T12-02, 시나리오 5·AC-1): `app add`는 앱 저장소 가시성·`app-main` ruleset(없으면 경고만), main HEAD의 이미지(GHCR package version의 태그 `sha-<HEAD>` → digest, 그 digest의 build provenance가 이 저장소 `refs/heads/main`의 HEAD 커밋인지), GHCR 익명 토큰 응답을 읽는다. 이미지 라벨 대신 provenance를 본다(라벨은 packages 쓰기 권한이면 누구나 붙인다). 두 번째 실행이 모두 `same`인 근거는 단계마다 이렇다: 비밀번호는 키가 있으면 재사용하고 값은 읽지도 바꾸지도 않는다. values는 명령이 다루는 키만 비교하고 플래그는 더하기만 한다(사람이 쓴 키·주석은 그대로). `image.yaml`은 없을 때만 만든다(등록 뒤에는 배포 App 소유라 그사이 배포가 끼어도 같음). PR은 main이 원하는 내용이면 같음, 열린 CLI PR이 같은 내용이면 같음 + 대기(3). values `secrets`는 Infisical `/apps/<app>`의 키 이름과 기존 목록의 합집합이다(설계 D 4~5번).
- 캐시를 쓰던 앱의 `cache add --persistent`는 PR 둘이다(캐시와 영속 Valkey의 이름이 같다, T11 #859·#860): main에 `cache`가 있으면 캐시 끄기 PR, 병합 뒤 같은 명령을 다시 실행하면 앱 Application에 `<app>-valkey*`가 남은 동안 대기(3)하고 정리되면 영속 PR을 연다. 두 PR은 같은 브랜치 `cli/cache-add-<app>`를 차례로 쓴다.
- `secret sync`는 `<app>-app`(앱 자체 키)만 동기화하고 재시작한다. DB·Valkey 쪽은 순서가 있는 회전(`db rotate`·`cache rotate`)의 몫이다(Valkey 서버를 다시 띄우지 않고 `valkey-auth`만 바꾸면 앱이 인증에 실패한다). 재시작은 파드 템플릿 주석에 참조 Secret의 resourceVersion 해시를 쓰는 방식이라 값이 그대로면 다시 실행해도 재시작하지 않는다.
- `homelab logs`는 앱 로그를 그대로 보인다. 앱이 자격을 로그에 쓰지 않는 것은 앱 계약이다(T12 #873 3라운드 판단). CLI는 로그 속 임의 값이 시크릿인지 알 수 없고 추측 마스킹은 놓친 값을 가린 것처럼 보이게 하며, 같은 사람은 kubeconfig로 `kubectl logs`를 직접 본다. 그 실행이 다룬 시크릿(16자 이상)이 로그에 섞이면 출력 계층이 결과 전체를 막는다.
- 종료 코드(결정 D2, 사용자 2026-10-23, T12): 0 완료·변경 없음·plan(차이가 있어도), 1 실패(원인과 다음 행동 출력), 3 대기(apply 뒤 PR 병합·동기화 대기), 64 사용법 오류(EX_USAGE. 모르는·중복 플래그, 줄바꿈이 낀 값 포함). `homelab github *`만 래퍼 코드 그대로(0 같음, 2 차이, 1 guard·실패).
- PR 작성(결정 D3, T12): 로컬 체크아웃 없이 GitHub API(`gh api`)로 tree·commit을 만들어 브랜치에 올린다. 브랜치 머리 커밋에 트레일러 `Homelab-CLI:`가 없으면(사람이 push한 커밋) 덮지 않고 멈춘다(lead 결정 2026-10-23). 갱신은 force를 쓰지 않는다: 새 커밋의 부모를 [main 스냅샷, 확인한 브랜치 머리]로 두고 fast-forward로만 옮겨, 확인과 갱신 사이의 사람 push는 GitHub가 422로 거부한다(#873 리뷰, 처음 안의 force 이동을 바꿈). 파일 내용은 그 main 스냅샷에서 다시 계산해 그사이 병합된 변경을 되돌리지 않는다. 열린 PR은 main과 비교하기 전에 먼저 보고, "같음"으로 보려면 머리가 CLI 커밋이고 PR 전체 변경이 그 명령의 파일뿐이어야 한다.
- 배포: `bun cli/build.ts --install`이 `~/.local/bin/homelab`에 두고 이전 파일을 `homelab.prev`로 남긴다(되돌리기, `cli/README.md`). `--compile` 실행 파일은 기본으로 실행 폴더의 `.env`·`bunfig.toml`을 읽어(2026-10-23 실측) 둘 다 끈다.
- CLI가 만드는 PR 브랜치는 `cli/<동사>-<app>`이다. 사람이 검토 후 병합한다. 작성자가 owner 자신이라 승인할 수 없으므로 검토한 head SHA를 고정해 관리자 bypass로 병합하고(`gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`), 필수 검사 `ci`는 그대로 걸린다(C.4.7). 사람의 `gh` 로그인, `infisical login`, kubeconfig를 쓰고 자격을 저장하지 않는다.

### C.8 봇을 위한 여지

design-prompt §2 표의 아홉 자리다. 봇 V1~V3은 운영 읽기 전용이다(C-08). "준비 확인 방법"은 봇 없이 플랫폼이 자리를 제대로 준비했는지 보는 방법이고, 실제 사용 검증은 봇 구현(T16b·T17)에서 한다. T15 결정(D-14~D-17, D-24. 확정(사용자 2026-10-18, T15))을 아래 표와 "봇 자리 Application"에 반영했다. 요지는 F "봇 결정(T15)"이다.

| 자리 | 위치 | 권한 범위 | 준비 확인 방법 | 단계 | AC |
|---|---|---|---|---|---|
| 리뷰 전용 GitHub App | 봇 쪽 GitHub App(D-16 기본안, 확정(사용자 2026-10-18, T15): 전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버). 저장소마다 "Only select repositories"로 설치. webhook은 아래 공개 경로로. 봇이 리뷰하는 저장소는 Codex 자동 리뷰를 저장소별 Codex 설정에서 끈다(사람 작업. 수동 `@codex review`는 남긴다). Codex Connector 설치 범위는 선택 저장소로 줄이고 private `homelab-bot-ops`는 뺀다(사람 작업, `homelab-bot-ops` 첫 push 전, F D-26. 2026-10-18 17:45 완료, spec §11). 리뷰 App 생성·설치는 T17 | pull_requests write(리뷰·댓글), contents read, checks read, metadata read, issues read(PR 댓글 리뷰 요청의 `issue_comment` 구독용, 봇 저장소 DECISIONS D-16, T17). contents write·workflows·actions·administration 없음. 어떤 ruleset bypass에도 없어 이 App의 승인과 무관하게 main을 바꾸는 병합은 bypass 신원만 한다(ruleset B·`app-main`의 Restrict updates). code owner가 아니라는 것만으로는 보장되지 않는다: owner가 연 PR에서는 쓰기 권한 App의 승인 하나로 리뷰 요건이 찼다(2026-10-21 #822, U08 (나)). 이 보장은 대상 main에 유효한 `CODEOWNERS`가 있고 `pull_request` 규칙의 `require_code_owner_review`·`dismiss_stale_reviews_on_push`가 `true`일 때만 선다(조건 9와 Terraform guard가 확인, C.4.7) | E5에서 시험 App `ukyi-homelab-review-probe`를 만들어 한 저장소에만 설치: `gh api orgs/ukyi-app/installations --jq '.installations[] \| select(.app_slug=="ukyi-homelab-review-probe") \| .repository_selection'` → `selected`, App 설치 토큰으로 `GET /installation/repositories` → 그 저장소 하나, E5의 래퍼 `tools/tf-github.sh verify`(E7부터 `homelab github verify`. guard가 bypass 허용 목록을 본다)로 bypass 목록에 없음과 대상 저장소마다 `CODEOWNERS` 존재, `gh api repos/ukyi-app/<저장소>/codeowners/errors --jq '.errors \| length'` → `0`, `gh api repos/ukyi-app/<저장소>/rules/branches/main --jq '.[] \| select(.type=="pull_request") \| .parameters \| [.require_code_owner_review, .dismiss_stale_reviews_on_push]'` → `[true,true]` 확인 | E5 | AC-P12 |
| 읽기 전용 접근 | (a) Kubernetes SA `bot-reader`(봇 ns. 아래 봇 자리 Application이 만들고, 봇은 공유 차트의 `serviceAccountName: bot-reader`로 그 토큰을 받는다, C.4.5) + ClusterRole `homelab-readonly`(라벨 `homelab.ukyi.app/readonly`) (b) Argo CD 로컬 계정 `bot-reader`(apiKey만) (c) Grafana 서비스 계정 `bot-reader`(Viewer) | (a) get·list·watch: pods, deployments, replicasets, statefulsets, daemonsets, jobs, cronjobs, services, ingresses, events, nodes, namespaces, PV·PVC, CNPG clusters·databases·backups, ExternalSecret, Argo CD applications. secrets, configmaps, pods/log, pods/exec, 모든 쓰기 없음(봇 R05~R06의 "Secret·임의 ConfigMap·로그 전체 수집 금지"와 맞춤). `view` 기본 역할은 Secret을 못 읽지만[S49] configmaps·로그를 포함하므로 쓰지 않고 명시 목록으로 (b) `applications, get`, `applicationsets, get`, `projects, get`. sync·exec·logs 없음, `policy.default` 비움[S70] (c) 대시보드 보기와 데이터소스 질의(메트릭·로그·경보 읽기). 로그는 VictoriaLogs 데이터소스(uid `victorialogs`, 플러그인, C.3.7)로 `POST /api/ds/query`에 LogsQL을 보내고, 데이터소스는 메트릭과 같은 읽기 전용 vmauth를 거친다. 봇 ns의 NetworkPolicy(공유 차트의 기본 거부·허용 목록 + 아래 봇 자리 Application의 정책)는 클러스터 안에서 Grafana·Argo CD API만 더 열고 vmsingle·VictoriaLogs·Alertmanager API에는 직접 닿지 않는다(Alertmanager API는 침묵 생성이 가능). Kubernetes API는 노드 로컬 경로라 NetworkPolicy로 열거나 막을 수 없어(C.4.5 tailnet 차단의 노드 로컬 한계) 읽기 전용 SA가 경계다 | `kubectl auth can-i --as=system:serviceaccount:<봇 자리 ns>:bot-reader list pods -A` → yes(`<봇 자리 ns>`는 E4b의 시험 ns `bot-slot-probe`, E9부터 `app-homelab-bot`), 같은 주체로 `get secrets -A`, `get pods --subresource=log -A`, `create deployments -n app-smoke` → no. `argocd admin settings rbac can bot-reader get applications '*/*'` → Yes, `sync` → No(argocd-rbac-cm 오프라인 평가). Grafana 토큰으로 `GET /api/search` → 200, `POST /api/dashboards/db` → 403. CI 검사(L30)가 verb·roleRef를 막는다. Grafana Viewer의 데이터소스 질의 허용 범위(U12 결과 2026-10-23, T08b): Viewer는 대시보드 쓰기가 403이지만 데이터소스 resources 경로로 임의 경로에 POST할 수 있었다. 그래서 메트릭·로그 데이터소스를 모두 읽기 전용 vmauth 뒤에 두었고(C.3.7 vmauth 행), Viewer 토큰으로 질의는 200, 쓰기 경로(메트릭 `delete_series`·import, 로그 `/insert/*`·삭제·`/internal/*`)는 400·403이다 | E4 | AC-P12 |
| 병합 조건 공개 | `.github/workflows/README.md`(조건 9개)와 C.4.7. 강제는 ruleset A~D(D는 배포 키 identity가 묶이는 `app-build-v*` 등 버전 태그를 지키는 둘: 갱신·삭제 금지 D1, 생성 제한 D2), 앱 저장소와 `homelab-app-template`의 `app-main`, 배포 키 OIDC identity와 병합 키 environment `automerge`(배포 브랜치 main), `deploy-merge` | `ukyi-homelab-deploy`(PR 작성), `ukyi-homelab-merge`(병합). 그 밖의 신원은 code owner 승인 없이 homelab main, 앱 저장소(public만, D-29) main, `homelab-app-template` main에 못 쓴다. 예외로 Codex Connector의 PR은 owner 계정으로 찍혀 승인 관문 없이 owner 검토만 거친다(C.4.7) | 시나리오 15, `homelab github verify`(E5는 래퍼. 라이브 ruleset·environment·Actions 권한이 `infra/github` 선언과 같고 guard가 통과하는지) | E5 | AC-P8 |
| 봇 변경 PR 작성 자격 | 봇 전용 쓰기 GitHub App(D-24, 확정(사용자 2026-10-18, T15)). 선택 저장소에만 설치, webhook 끔. 게시 서버만 쓴다: 작업마다 저장소 하나로 좁힌 1시간 설치 토큰[S91]으로 push와 PR 생성을 하고, 작업자에는 GitHub 자격이 없다(D-15, 아래 격리 행). 브랜치 `bot/**`. App 이름·설치 저장소, 토큰 분리, ruleset E(`bot/**` 생성·갱신을 그 App만) 여부, 허용 파일 경로(설정 키 `github.change_writer_allow_paths`)는 T19에서 정한다 | Contents write(브랜치 push), Pull requests write, Metadata read. Workflows·Actions·Administration·Issues 없음, merge bypass 없음. 그래서 봇은 `.github/workflows` 변경 PR을 만들 수 없다(D-24가 받아들인 범위 축소, U09). Contents write로 되는 병합 API, `POST /merges`, `repository_dispatch`, update-branch, GraphQL 병합은 권한으로 막을 수 없어[S100] 게시 서버의 API 허용 목록이 막는다(봇 시험 CHANGE-02 계열, C.4.7). **homelab:** main 직접 push 불가(ruleset B), `deploy/**` 생성 불가(ruleset C), 자동 병합 조건 1에서 빠짐. **앱 저장소:** 앱 저장소(모두 public, D-29)와 `homelab-app-template`의 main 직접 push 불가(`app-main`, App bypass 없음) | E5에서 봇 신원 대신 시험 App `ukyi-homelab-bot-standin`(homelab과 E5의 시험 앱 저장소 `homelab-probe`에 설치. E8은 `homelab-smoke`로 다시)으로: `bot/x` push 성공, homelab main push → GH013 거부, `homelab-probe` main push → GH013 거부, `deploy/x` 생성 → 거부, digest만 바꾼 PR → `deploy-merge`가 "조건 1 불일치"로 병합하지 않음 | E5(실제 신원의 모양은 T15 D-24, 생성·설치는 T19) | AC-P8 |
| 공개 HTTPS webhook 수신 경로 | `https://hooks.ukyi.app/github` → Cloudflare(WAF 규칙 1) → 터널 → Traefik Ingress(host `hooks.ukyi.app`, path `/github` Exact) → 봇 Service | POST 한 경로만. 출처 확인은 HMAC `X-Hub-Signature-256`, 상수 시간 비교(봇이 검증)[S98]. 봇은 모델 호출 전에 이벤트의 `author_association`(OWNER·MEMBER·COLLABORATOR)과 설치·저장소 허용을 확인해, public 저장소의 외부인 PR·댓글이 모델 호출을 일으키지 않게 한다(D-29). App이 만든 PR은 이 값에 들지 않는다(실측 2026-10-18, `gh api 'repos/ukyi-app/<저장소>/pulls?state=all'`의 `author_association` 집계: 옛 writer App의 PR은 public 저장소에서 `CONTRIBUTOR`, 그 App의 병합 커밋이 없는 private 저장소에서 `NONE`이었고 OWNER·MEMBER·COLLABORATOR는 없었다. owner가 org 저장소에 연 PR은 `MEMBER`다). 그래서 D-16 안에 허용 봇 작성자 목록을 둔다(확정(사용자 2026-10-18, T15)): `pull_request.user.type`이 `Bot`이고 숫자 `user.id`가 목록에 있으면 통과한다. 초기 목록은 호스팅형 Renovate 봇과 D-24 App의 봇 사용자(생성 뒤)이고, 배포 갱신 App(`ukyi-homelab-deploy`)·Codex Connector·옛 writer App은 넣지 않는다. fork PR은 모델을 부르지 않는다. 댓글 트리거는 `comment.author_association`을 보고 Bot 댓글은 무시한다. `CONTRIBUTOR`는 허용하지 않는다(외부인도 병합된 커밋이 하나 생기면 `CONTRIBUTOR`다[S218]). 실제 ID는 Infisical `/apps/homelab-bot/`의 runtime policy(키 이름 예: `review.allowed_bot_author_ids`)에만 두고 공개 문서에는 쓰지 않는다. 허용 작성자의 PR 본문도 비신뢰 자료로 다룬다. GitHub webhook은 사용자 헤더를 못 붙여 Cloudflare Access Service Auth로 거를 수 없다[S139]. IP 제한은 선택이고 GitHub 대역은 바뀌므로 넣으면 갱신 담당을 정한다[S99]. 이 경로를 받는 봇 게시 서버는 공유 차트 앱이라 egress가 C.4.5의 허용 목록과 봇 자리 Application(아래)이 연 클러스터 안 목적지뿐이고 인터넷 443에서 사설·tailnet 대역이 빠진다(tailnet 불통은 시나리오 1에서 확인) | E4에서 시험 수신기(HMAC 검증만 하는 작은 서비스)로: `curl -s -o /dev/null -w '%{http_code}' https://hooks.ukyi.app/github`(GET) → 403, 다른 경로 POST → 403(또는 404), 서명이 틀린 POST → 401, 한 저장소에 시험 webhook을 걸고 ping 전송 → Recent Deliveries 200. 봇 배포 때 시험 수신기를 지운다 | E4 | AC-P12 |
| 경보 외부 수신자 | Alertmanager 라우트(`continue: true`) → receiver `bot`의 `webhook_configs.url_file` → 클러스터 안 봇 Service(공개 아님, 경보 수신 포트 8081, D-15). C.3.7 예시의 주석 처리된 줄 | Alertmanager가 보내기만 한다. 봇은 Alertmanager API에 NetworkPolicy로 닿지 않는다. 비AI 경로(Telegram)는 그대로 받는다 | E4에서 시험 수신기(봇 자리 Application의 시험 ns에 시험 라벨로 둔 것, 아래)로: `amtool config routes test ... severity=warning` → `bot` 포함, `amtool alert add alertname=BotRouteTest severity=warning` → 수신기 로그 수신 + `alertmanager_notifications_total{integration="webhook"}` 증가 + Telegram도 수신 | E4 | AC-P12 |
| 격리 작업 실행 공간 | ns `sandbox`(작업자) + ns `egress`(허용 목록 프록시) | **자격:** SA 토큰 미마운트, RBAC 없음, hostPath·hostNetwork·호스트 소켓 없음, Secret은 Infisical `/apps/homelab-bot/worker`의 모델 자격 하나(같은 봇의 게시 서버와 다른 ns·경로). 이 Secret은 작업자 전용 ClusterSecretStore `infisical-sandbox`(conditions는 `sandbox` ns 하나, `secretsPath` `/apps/homelab-bot/worker`)로 받는다. ExternalSecret은 `platform/sandbox`의 Git 매니페스트로만 생기고 sandbox 서비스 계정에는 ExternalSecret 생성 권한이 없어 작업자가 경로를 고를 수 없다. 남는 위험: store identity `eso-homelab`은 Free에 경로 RBAC가 없어 `homelab` 프로젝트의 다른 경로도 읽을 수 있다(C.6.3). **모델 자격과 영속 쓰기 공간(D-14, 확정(사용자 2026-10-18, T15). 이 행의 변경):** 모델 자격은 봇 전용 ChatGPT 구독 계정의 Codex 인증 파일(`auth.json`)이고 작업자 전용 `CODEX_HOME`에 둔다. 사람의 개인 `CODEX_HOME`(`~/.codex*`)은 쓰지도 복사하지도 않는다. Codex는 `last_refresh`가 약 8일보다 오래되면 토큰을 갱신해 `auth.json`에 다시 쓰고, 공식 안내는 갱신본을 실행 사이에 보존하고 "seed auth.json only if it is missing"이라고 한다[S219]. ESO 한 방향 전달만으로는 갱신본을 지키지 못하므로 sandbox ns에 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나)을 둔다. Infisical `/apps/homelab-bot/worker`의 값은 첫 시드와 재시드용이고, 작업자는 영속 공간에 파일이 없을 때만 시드를 복사한다. 갱신본을 옛 시드로 덮거나 다른 실행이 먼저 토큰을 돌리면 사람이 다시 시드해야 한다[S219]. 한 `auth.json`은 한 기기나 직렬 작업 하나만 쓴다[S219]. 그래서 작업자는 상주 파드 하나, 동시성 1이고 [제안] Deployment는 replicas 1, `strategy: Recreate`다(RollingUpdate면 교체 중 두 파드가 같은 파일을 쓴다). 한도 도달·인증 만료 때는 다른 계정이나 인증으로 자동 전환하지 않고 waiting으로 둔다(봇 코드 규칙). 옛 구독 OAuth 프록시와 다계정 순회는 다시 쓰지 않는다. **남는 위험(D-14):** 같은 공식 문서는 이 경로를 "trusted private automation"용 고급 경로로 두고 "Do not use this workflow for public or open-source repositories"라고 적는데[S219], 봇의 리뷰 대상은 public 저장소다(D-29). 이 문구가 실행 위치를 말하는지 다루는 코드를 말하는지는 [미검증]이고 OpenAI 확인 항목이다(spec §10). **네트워크:** NetworkPolicy 기본 거부, egress는 `egress` ns 프록시 파드의 3128 하나뿐이고 DNS(CoreDNS 53)는 열지 않는다. CoreDNS는 임의 이름을 공용 DNS에 재귀 질의하므로, DNS를 열면 이름에 실은 자격이 허용 목록 밖으로 나갈 수 있다. 그래서 작업자는 프록시를 이름이 아니라 고정 ClusterIP로 받고(프록시 Service의 `spec.clusterIP`를 서비스 대역 안 고정값으로 선언, 작업자 env `HTTPS_PROXY=http://<프록시 ClusterIP>:3128`), 목적지 이름 해석은 프록시가 한다(U29 결과 2026-10-22, T08b: DNS 없는 파드의 curl이 `HTTPS_PROXY`만으로 codeload 압축본을 받았다. 실제 Codex·git·패키지 관리자는 E9). 프록시가 도메인 허용 목록(모델 API, 코드 읽기용 `codeload.github.com`, 패키지 레지스트리)만 통과. 프록시는 CONNECT 이름과 터널 안 TLS SNI를 둘 다 허용 목록과 맞추고 업스트림은 SNI로 푼다(Envoy, 사용자 결정 2026-10-22, T08b). CONNECT 이름만 보면 허용 이름으로 터널을 열고 SNI를 바꿔 같은 CDN의 다른 사이트에 닿는다(lab 실측). 남는 위험: SNI는 허용 이름이고 TLS 안 HTTP Host만 다른 요청은 프록시가 못 본다(lab에서는 Cloudflare가 403으로 거부, CDN 동작이라 보장 아님). `github.com`·`api.github.com`·`gist.github.com`은 넣지 않는다(D-15, 아래 코드 읽기). 구독 인증(D-14)이 쓰는 모델·인증 호스트 목록은 [미검증]이고 E9에서 실측해 넣는다. NetworkPolicy는 노드 로컬 경로(노드 IP의 6443·10250·22)를 못 막으므로(TD:263-274) 작업자 파드 netns 안에서 init 컨테이너(NET_ADMIN, 그 컨테이너만)가 "프록시 ClusterIP:3128 외 출력 차단(DNS 포함)" 규칙을 건다. 실측(2026-10-22, T08b): 이 k3s의 kube-router netpol은 노드 IP·`10.43.0.1`도 막았다. 그래도 구현 의존이고 파드 시작 직후 netpol 적용 전 약 1초 공백(T10 발견, B.8)도 있어 init 방화벽을 둔다. 출력에서 허용하는 것은 셋뿐이다: loopback(`-o lo`), 이미 맺어진 연결의 패킷(conntrack `ESTABLISHED,RELATED`), 프록시 ClusterIP:3128로 가는 새 연결. 둘째가 없으면 봇이 작업자 Service로 보낸 요청의 응답 패킷도 막혀 작업 전달이 끊기고, 첫째가 없으면 파드 안 `127.0.0.1` 통신이 끊긴다. 작업자가 새로 여는 연결은 여전히 프록시 하나뿐이다. init 규칙은 파드 netns에서 보이는 목적지(프록시 ClusterIP)로, NetworkPolicy는 DNAT 뒤 목적지(프록시 파드)로 쓴다(TD:263-269). 본 컨테이너는 NET_ADMIN이 없어 못 바꾼다. 그래서 이 ns의 PSA는 privileged가 되고, 파드는 Git(Argo CD)만 만든다. 봇에게 파드 생성 권한을 주지 않고 작업 전달은 봇 → 작업자 Service ingress 하나로(이 ingress 허용은 아래 봇 자리 Application에 있고, `platform/sandbox`에는 기본 거부만 있다). 작업자는 상주 파드 하나(동시성 1, 컨테이너 포트 8080)이고 작업 단위 파드는 두지 않는다(D-15). 나중에 필요해지면 ValidatingAdmissionPolicy로 파드 모양을 고정한 뒤에만 둔다. **코드 읽기(D-15, 확정(사용자 2026-10-18, T15)):** 프록시는 CONNECT의 호스트 이름만 보므로 `github.com`을 허용하면 읽기와 쓰기를 가르지 못한다. 작업 입력에 심긴 남의 토큰으로 다른 저장소에 push하거나 gist를 만들어 자격이나 코드를 밖으로 보낼 수 있고, D-14로 작업자에 구독 인증 파일이 있으니 그 파일도 이 길로 나갈 수 있다. 그래서 작업자의 코드 읽기는 `codeload.github.com` 압축본만이고, 작업자 egress에서 `github.com`·`api.github.com`·`gist.github.com`을 뺀다. 작업자에는 GitHub 자격이 없다. 대상 저장소는 public이라(D-29) 압축본을 자격 없이 받는다고 보고, 프록시 경유 동작은 E4b 시험 파드에서 확인한다. 받은 압축본은 작업자가 `git init`으로 한 번 커밋해 `codex exec`의 Git 저장소 요구[S220]를 맞추고, diff는 base·head 압축본으로 만든다. push와 PR 생성은 게시 서버가 D-24 App으로 한다(위 봇 변경 PR 행). 대가는 `git clone`과 히스토리(`git log`, `blame`)를 쓸 수 없는 것이다. **남는 위험(쓰기 유출):** 패키지 레지스트리의 게시 API는 이 결정으로 줄지 않는다. 그래서 받기와 게시가 같은 호스트인 npm(`registry.npmjs.org`)은 허용 목록에서 뺐다(lead 결정 2026-10-22, T08b #836 보안 리뷰). 작업 입력에 심긴 npm 토큰으로 `auth.json`을 패키지로 게시할 수 있어서다. 필요해지면 T16b가 GET 전용 미러를 정한다. PyPI는 게시가 `upload.pypi.org`로 갈려 받기 호스트(`pypi.org`, `files.pythonhosted.org`)만 둔다 | E4에서 시험 파드로: 안에서 `curl -m 5`로 `https://10.43.0.1`, `https://<노드 IP>:6443`, `<노드 IP>:22`, 공유기 IP, tailnet 주소, `https://app.infisical.com` → 모두 실패. `nslookup example.com` → 실패(DNS 차단), `nc -z -w 3 <CoreDNS ClusterIP> 53` → 실패. `HTTPS_PROXY`만 둔 채 `curl -sI https://<허용 도메인>` → 연결(이름 해석은 프록시), `curl -x http://<프록시 ClusterIP>:3128 https://<허용 밖 도메인>` → 프록시 거부. D-15 허용 목록: `HTTPS_PROXY`만 둔 채 `curl -sfo /dev/null https://codeload.github.com/ukyi-app/<public 시험 저장소>/tar.gz/<SHA>` → 성공, `https://github.com`·`https://api.github.com`·`https://gist.github.com` → 프록시 거부. D-14 영속 공간: 시험 작업자가 `CODEX_HOME` 볼륨에 시험 파일을 쓰고 파드를 지운 뒤 새 파드에서 같은 내용이 남음, `kubectl -n sandbox get deploy <작업자> -o jsonpath='{.spec.replicas} {.spec.strategy.type}'` → `1 Recreate`. 시험 작업자 파드가 HTTP를 받는 상태에서 안에서 `curl -sf http://127.0.0.1:<포트>/` → 성공(loopback 허용), 봇 자리 시험 파드(봇 자리 Application의 시험 ns `bot-slot-probe`에 `target`의 시험 라벨로 둔 것. 그 ns에는 C.4.5 네트워크 행을 손으로 옮긴 정책이 있다, 아래)에서 `curl -sf http://<작업자 Service>.sandbox:<포트>/` → 성공(응답 패킷이 init 규칙의 `ESTABLISHED` 허용으로 나감), 같은 파드에서 Grafana·Argo CD API → 연결, vmsingle·Alertmanager API → 실패(봇 자리 Application이 연 것만 닿음), 같은 라벨이 없는 파드에서 작업자 Service → 실패(sandbox ingress의 출처 확인). `/var/run/secrets/kubernetes.io/serviceaccount` 없음. `kubectl auth can-i --as=system:serviceaccount:sandbox:default list secrets -n sandbox`와 `create externalsecrets.external-secrets.io -n sandbox` → 둘 다 no. 사람이 sandbox ns에 만든 시험 ExternalSecret이 `infisical-platform`이나 `infisical-apps`를 가리키면 conditions로 동기화 거부. 모의 비밀 읽기·임의 외부 쓰기·운영 변경 거부를 실측(AIOps 교훈). init 방화벽 방식은 동작한다(U13 결과 2026-10-22 시험 ns, 2026-10-23 실제 작업자, T08b: 위 실패·성공 목록이 그대로 나왔고 본 컨테이너의 `iptables -F`는 실패). 안 됐다면 호스트 전용 UID + nft(옛 AIOps 방식)로 물러난다(D-15, 확정(사용자 2026-10-18, T15)) | E4(D-14 영속 공간과 D-15 허용 목록 포함). 실제 인증 시드와 모델 호스트는 E9 | AC-P12 |
| 비AI 알림 경로 | Alertmanager 기본 receiver `telegram`(`telegram_configs`) | 송신 전용 새 Telegram 봇의 토큰(E3에서 새 봇 생성, Infisical `/platform/alerting`). 봇·Discord와 다른 채널(D-10) | 시나리오 16 | E4 | AC-P11 |
| 외부 생존 감시 | healthchecks.io 새 체크 ← Alertmanager Watchdog 라우트(`url_file`) | ping URL만. 통지는 healthchecks.io → 이메일·Telegram(NUC를 거치지 않음) | 시나리오 17 | E4 | AC-P11 |

**봇 저장소** (F D-29, D-13 확정(사용자 2026-10-18, T14)): 봇 코드 저장소는 `ukyi-app/homelab-bot`이고 public이다. 그래야 `app-main`·attestation·자동 배포(조건 9)를 받는다. 앱 이름도 `homelab-bot`이라 ns `app-homelab-bot`, Infisical `/apps/homelab-bot/`(게시 서버)와 `/apps/homelab-bot/worker`(작업자), 이미지 이름, 배포 설정 `apps/homelab-bot/`·`data/homelab-bot/`이 이를 따른다. 운영 산출물(evidence, handoffs, runtime-policies 실제 값, DISCOVERY의 내부 경로, 허용 목록 실제 값)은 봇 저장소에 두지 않는다. 개발 산출물(evidence, handoffs, DISCOVERY의 내부 경로)은 private 저장소 `ukyi-app/homelab-bot-ops`에 두고, 봇이 실행 중 읽는 값(runtime-policies 실제 값, 허용 목록 실제 값)은 Infisical `/apps/homelab-bot/`에 두며, 봇 저장소에는 키 이름만 둔다. 공개해도 되는 봇 산출물(`PROJECT_STATUS.md`, `DECISIONS.md`, `VERIFICATION.md` 요약 등 내부 정보 없는 것)은 봇 저장소 `docs/ai-bot/`에 둔다. 봇 프롬프트 문서(homelab `docs/plans/2026-10-17-homelab-rebuild/bot/`의 `00`~`04`)는 봇 저장소 생성·하드닝 뒤 PR로 `docs/ai-bot/prompts/`에 옮긴다. 옛 `aiops` 저장소와 App은 재사용하지 않고 제거한다.

- **생성 시점과 방법:** D-13이 정해져(T14) 사람이 `homelab-bot`과 `homelab-bot-ops`를 만든다(T15가 공개 가능한 산출물을 커밋한다). `homelab-bot-ops`는 private라 Free에서 ruleset을 걸 수 없다(0절). 앱 저장소가 아니므로 `app-repos.json`(public 앱 저장소 목록, guard 2·8)에 넣지 않는다. 아래는 `homelab-bot`의 방법이다. 템플릿을 쓰지 않고 빈 public 저장소로 만든다. E5 전 템플릿은 옛 내용이라 옛 워크플로가 새 저장소에서 돌 수 있기 때문이다. 내용을 넣기 전에 결정 5와 같은 하드닝(`.github/CODEOWNERS`, secret scanning·push protection, private vulnerability reporting, fork PR 승인 `all_external_contributors`, 그리고 E5 전이면 `app-main`)을 건다(하드닝 스크립트의 대상 목록만 바꿔 실행). 그 뒤 내용은 PR로만 들어간다.
- **`app-repos.json` 편입:** E5 전에 만들었으면 E5가 `app-repos.json`에 넣고 그 `app-main`을 import한다. E5 뒤에 만들면 `app-repos.json` PR 병합 → 저장소 생성 → `app-main`을 뺀 하드닝 → apply가 `app-main`을 만든다(C.7 `app new`와 같은 순서. 스크립트로 `app-main`까지 걸면 apply가 같은 이름을 다시 만들려 해 실패한다). 어느 쪽이든 목록에 없는 public 저장소가 있는 동안 guard 8이 모든 github plan을 멈춘다(C.3.9).
- **E9:** 저장소를 새로 만들지 않고 `homelab app add`로 등록한다(E9).

**봇 자리 Application** (격리 작업 공간 기본 방식, 확정(사용자 2026-10-18, T05). 라벨·포트는 D-15, 확정(사용자 2026-10-18, T15): 라벨 `homelab-bot`, 앱·작업자 8080, 경보 수신 8081): 봇 게시 서버는 공유 차트 앱이라 차트의 기본 거부와 허용 목록(C.4.5)을 받는다. 그 목록에는 봇이 쓰는 클러스터 안 경로가 없다: 인터넷 443 규칙은 `10.0.0.0/8`(서비스·파드 대역)을 빼므로 sandbox 작업자 Service, Grafana, Argo CD API로 나가는 연결과 `observability` ns의 Alertmanager에서 들어오는 경보가 막힌다. 봇의 읽기 전용 Kubernetes 자격(위 읽기 전용 접근 (a))도 차트 밖이다. 차트 기능으로 넓히지 않는다. 소비자가 봇 하나뿐이라 차트 확장 기준(소비자 둘 이상, C.1)에 못 미치고, 차트 밖 매니페스트를 앱 디렉터리에 두지 않는 규칙(C.1)도 있다. 그래서 봇 쪽 platform 리소스를 root 아래 Application `bot-slot`(원본 `platform/bot-slot/`, 작은 Helm 차트, wave 1) 하나에 모은다. NetworkPolicy는 허용의 합집합이라 봇 파드는 차트의 허용에 이 Application의 허용만 더 받는다.

- **대상 값 하나:** `platform/bot-slot/values.yaml`의 `target`(ns, 앱 라벨 `homelab.ukyi.app/app`의 값, 작업자 포트, 봇의 경보 수신 포트)이 아래 모든 리소스의 대상과 출처를 정한다. E4b~E8은 시험 ns `bot-slot-probe`, 시험 라벨, 시험 작업자·시험 수신기의 포트이고, E9부터 `app-homelab-bot`, `homelab-bot`, 작업자 포트 8080, 경보 수신 포트 8081이다(D-15). 게시 서버의 앱 포트(webhook 수신)는 봇 values의 `port: 8080`이고, 경보 수신을 다른 포트로 두어 Traefik(공개 webhook)과 Alertmanager(클러스터 안)의 허용을 포트로 가른다. 공유 차트 values의 포트는 `port` 하나뿐이라(C.4.5) Alertmanager가 가리킬 경보 수신 Service는 이 Application이 `target`으로 만든다(E4b 정함, T08b 2026-10-22): `target` ns의 `<target.app>-alerts`, `target` 라벨 파드의 경보 수신 포트. 봇 receiver의 url은 `http://<target.app>-alerts.<target.namespace>:<경보 수신 포트>/`다. 이 값을 바꾸는 PR 하나로 봇 쪽 정책의 대상, sandbox ingress의 출처, SA `bot-reader`의 ns가 함께 바뀐다. 작업자 포트는 `platform/sandbox`의 작업자 컨테이너 포트와 같아야 한다(준비 확인의 `curl`이 본다).
- **담는 것:** (1) `target` ns의 NetworkPolicy: `target` 라벨 파드의 egress를 `sandbox` ns 작업자 파드(작업자 포트), `observability` ns Grafana 파드(Grafana 포트), `argocd` ns `argocd-server` 파드(서버 포트)로 열고, ingress를 `observability` ns Alertmanager 파드에서 경보 수신 포트로 연다. vmsingle·VictoriaLogs·Alertmanager API는 열지 않는다. Kubernetes API는 노드 로컬 경로라 이 정책과 무관하고 읽기 전용 SA가 경계다(C.4.5). (2) `sandbox` ns의 NetworkPolicy: `target` ns·라벨에서 작업자 포트로 오는 ingress. 작업자 쪽 기본 거부(`platform/sandbox`)에 더하는 유일한 허용이다. (3) 읽기 전용 Kubernetes 자격: `target` ns의 SA `bot-reader`, ClusterRole `homelab-readonly`, 둘을 잇는 ClusterRoleBinding. 봇은 공유 차트의 `serviceAccountName: bot-reader`로 이 토큰을 받는다(C.4.5). (4) E4b~E8만(`probe: true`): 시험 ns `bot-slot-probe`의 Namespace(이 Application 안 앞 sync-wave)와 C.4.5 네트워크 행을 손으로 옮긴 정책(기본 거부, DNS, 같은 ns, 인터넷 443과 그 except). 공유 차트는 E5(T10)가 만들어 E4b(T08b)가 쓸 수 없으므로 손으로 옮긴다. E9에서 `probe: false`로 둘을 지우면 봇 ns의 기본 거부와 허용 목록은 실제 차트 렌더가 낸다.
- **받는 쪽:** `argocd-server`에는 공식 install.yaml의 `argocd-server-network-policy`가 모든 출처의 ingress를 연다(v3.5.5[S181]). `observability` ns는 처음에 ingress NetworkPolicy를 두지 않기로 했지만, 실제 스택(T08b #834)은 ingress 기본 거부에 Grafana는 `tailscale` ns에서만 받고 Alertmanager egress도 DNS와 인터넷 443으로 좁혔다. 그래서 이 Application이 `observability` ns에 둘을 더한다(T08b 2026-10-22): `target` ns·라벨에서 Grafana 3000으로 오는 ingress, Alertmanager에서 `target` ns·라벨의 경보 수신 포트로 가는 egress. 봇 값이 두 곳으로 나뉘지 않게 `platform/observability` 쪽은 고치지 않는다. 받는 쪽에 더하는 허용은 이 둘과 (2)다.
- **콜드스타트 순서:** 이 Application은 대상 ns를 만들지 않는다(`CreateNamespace` 없음. 봇 ns의 소유자는 앱 Application 하나, B.5). wave 1이라 ApplicationSet `apps`(wave 0) 뒤이고, 이보다 뒤 wave나 이 Application에 기대는 Application은 없다. 빈 클러스터 root apply에서 봇 ns가 아직 없으면 이 Application의 sync는 실패하고(ns가 없으면 sync가 실패한다[S67]) `retry.limit: -1`(무제한[S182])로 backoff 상한 5분마다 다시 한다. `retry.refresh: true`[S185]라 재시도마다 최신 revision을 쓴다. 그래서 잘못된 `target`을 고치는 PR도 다음 재시도에 반영된다(이 값이 없으면 operation이 Running으로 남아 `argocd app terminate-op` 없이는 풀리지 않는다). 앱 Application이 ns를 만들면 다음 재시도에서 수렴한다. 그사이 봇 Deployment는 SA `bot-reader`가 없어 파드를 만들지 못하고 기다린다. root의 sync는 마지막 wave의 일반 리소스를 적용하면 health를 기다리지 않고 끝나므로[S183] root의 다음 sync와 다른 Application은 막히지 않는다(그동안 root health만 Healthy가 아니다). E4b~E8은 시험 ns를 이 Application이 직접 선언해 이 기다림이 없다. 봇을 지울 때(`homelab app remove homelab-bot`)는 `target`을 E4b~E8의 시험 값으로 되돌리고 `probe: true`를 함께 켜는 PR을 낸다(시험 ns는 `probe: true`일 때만 선언된다). 남기면 다음 콜드스타트에서 이 Application이 끝없이 기다린다. 확인은 E9 검증의 콜드스타트 순서 재현이다.
- **바꾸는 경로:** 이 Application의 변경은 `image.yaml` 밖의 platform 변경이라 자동 병합 조건 3에서 빠지고 사람이 검토 후 병합한다(C.4.6 플랫폼 구성 행). E9는 `target` 변경 PR을 봇 등록 PR보다 먼저 병합해 위 콜드스타트 순서를 운영에서 재현한다(E9 검증).
- **준비 확인과 같은 정책:** E4b의 봇 자리 시험 파드와 경보 시험 수신기는 시험 ns `bot-slot-probe`에 시험 라벨로 둔다. 그 ns에는 이 Application의 (1)·(2)와 손으로 옮긴 차트 정책이 함께 있어, E4b 시험이 실제 봇이 받을 허용과 같은 규칙에서 돈다. 손으로 옮긴 정책과 차트 렌더의 차이는 E9가 같은 명령을 실제 봇(실제 차트 렌더)으로 다시 해서 잡는다.
- **고르지 않은 대안:** 공유 차트에 values로 켜는 닫힌 허용 목록(예: `network.platformAccess: [sandbox-worker, bot-read, alertmanager-ingress]`, 이름마다 고정 규칙)과 SA를 두고 `apps/<봇>/values.yaml`에서 켠다. 봇 ns 정책이 ns를 만드는 앱 Application 안에 있어 콜드스타트 기다림이 없고 봇 values PR 한 곳에서 보인다. 대신 차트 minor 버전이 오르고, 다른 앱도 values PR(사람 검토)로 같은 길을 켤 수 있으며, 작업자·Grafana·Argo CD 포트 같은 platform 사실이 차트에 들어간다. sandbox ingress와 ClusterRoleBinding은 여전히 platform에 남아 봇 ns·라벨 값이 두 곳으로 나뉜다.

---

## D. 대표 운영 시나리오: 새 앱에 PostgreSQL과 Valkey를 연결해 배포하기

사용자 관점의 처음부터 끝까지다. 앱 이름은 `memo`(가짜), 값은 모두 가짜이고 참조만 쓴다. 명령과 출력은 **목표 예시**다(CLI는 E7에서 만든다). 전제: E8까지 끝난 플랫폼, 사람의 `gh`·`infisical` 로그인, kubeconfig, `homelab` CLI.

| # | 사람이 하는 일 | 자동으로 일어나는 일 | 사람이 보는 확인 |
|---|---|---|---|
| 1 | `homelab app new memo` → 계획 확인 → `homelab app new memo --apply` → 열린 `infra/github/app-repos.json` PR을 검토 후 병합 → `homelab app new memo --apply` 다시 | CLI가 템플릿 main의 `app-main`이 active인지 확인하고 `app-repos.json`에 `memo`를 더하는 PR을 연다. 병합 뒤 다시 실행하면 GitHub이 `homelab-app-template`으로 `ukyi-app/memo`(public. 앱 저장소는 public만, D-29)를 만들고, CLI가 저장소 보안 설정(fork PR 승인 `all_external_contributors`, secret scanning·push protection, private vulnerability reporting)을 켠 뒤 main에서 `homelab github apply`로 main ruleset `app-main`(PR 필수, 승인 1 + code owner, App bypass 없음)을 건다(래퍼가 fetch한 `origin/main`에서만 돌아 목록 PR을 먼저 병합한다, C.3.9). 첫 main 내용은 템플릿 main에서 오고, 템플릿 main도 같은 `app-main`으로 보호되어 사람이 검토한 내용만 담긴다(C.4.7). 템플릿에 Dockerfile, `/healthz`, `CODEOWNERS`, 짧은 `build.yaml`(공통 워크플로를 태그로 호출), 로컬 compose(`127.0.0.1:` 접두 PostgreSQL·Valkey), `migrate` 예시가 들어 있다 | 저장소 URL, "main ruleset active" |
| 2 | 코드를 쓰고 로컬에서 돌린다: `infisical run --env=dev --path=/apps/memo -- bun dev` | 개발용 값(Infisical 프로젝트 `homelab-dev`)이 환경변수로 들어온다. 운영 값은 로컬에 오지 않는다 | 로컬 화면 |
| 3 | 첫 PR을 열고 검토 후 main에 병합한다(자기 PR이라 관리자 bypass. `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`) | PR: `app-build`가 테스트와 빌드만(시크릿 없음). main push: 테스트 → 빌드 → `ghcr.io/ukyi-app/memo@sha256:aaaa…a`(revision `1111…1`). `deploy-pr` job은 homelab에 `apps/memo/image.yaml`이 없어 "미등록 앱, `homelab app add memo`로 등록" 요약을 남기고 성공으로 끝난다 | 앱 저장소 Actions 요약 |
| 4 | 앱이 쓰는 외부 API 키를 등록한다: `homelab secret set memo MEMO_API_TOKEN` (값은 입력창에서 받고 화면·기록에 남기지 않음) | Infisical `homelab/prod /apps/memo/MEMO_API_TOKEN`에 저장 | "등록됨, 마지막 변경 2026-11-02T10:00Z" |
| 5 | `homelab app add memo --public memo.ukyi.app --postgres --cache=persistent` | 계획만 출력한다(아래 상자). 아무것도 바꾸지 않는다 | 계획 |
| 6 | `homelab app add memo --public memo.ukyi.app --postgres --cache=persistent --apply` | 단계마다 상태를 다시 읽고 실행: Infisical에 DB·Valkey 비밀번호가 없으므로 생성·저장, `apps/memo/values.yaml`·`apps/memo/image.yaml`(3번 빌드의 digest·revision)·`data/memo/values.yaml` 작성, 브랜치 `cli/app-add-memo` push, PR #123 생성 | PR 링크, "다음: PR 검토 후 병합" |
| 7 | PR #123을 읽고 검토 후 병합한다. 작성자가 자기 자신이라 승인은 할 수 없고 관리자 bypass로 병합한다: `gh pr merge 123 --squash --admin --match-head-commit <검토한 SHA>`(C.4.7) | `ci`가 values 스키마, 렌더, 정책을 검사한다. bypass 병합에도 `ci`는 필수다. 사람이 병합한다(앱 등록은 자동 병합 조건 밖) | `ci` 초록 |
| 8 | 기다린다 (1~3분) | Argo CD가 main을 폴링해 Application `memo`와 `memo-data`를 만든다. `memo-data`: `database` ns에 ExternalSecret `pg-role-memo` → DatabaseRole `memo` → Database `memo`, `app-memo` ns에 영속 Valkey(PVC 보존 주석)와 백업 CronJob. `memo`: ExternalSecret `memo-app`·`memo-db`·`memo-valkey` → 마이그레이션 Job(Sync hook) → Deployment → Ingress `memo.ukyi.app` → NetworkPolicy. 데이터 쪽이 늦으면 마이그레이션 Job이 한 번 실패하고 retry로 수렴한다 | `homelab status memo`가 "DB 준비 대기"에서 "준비됨"으로 바뀜 |
| 9 | `homelab status memo`, 브라우저로 `https://memo.ukyi.app` | 없음 | 아래 상자, 앱 화면 |
| 10 | 이후에는 코드를 main에 병합하기만 한다 | 빌드 → `deploy/memo` PR(`ukyi-homelab-deploy[bot]`) → `ci` → `deploy-merge`가 조건 9개 확인(`memo`가 public이고 `app-main` active) → `ukyi-homelab-merge`가 병합 → Argo CD 배포 → 실패하면 Telegram 경보 | `homelab status memo`의 revision이 새 커밋 |

5번의 계획 출력 (목표 예시)

```text
$ homelab app add memo --public memo.ukyi.app --postgres --cache=persistent
계획 (아무것도 바꾸지 않았다)
  1 앱 저장소 ukyi-app/memo main HEAD                     1111…1 (public, 빌드 성공, 이미지 익명 pull 가능)
  2 Infisical homelab/prod /apps/memo/postgres/PASSWORD   없음 → 생성
  3 Infisical homelab/prod /apps/memo/valkey/PASSWORD     없음 → 생성
  4 Infisical homelab/prod /apps/memo/MEMO_API_TOKEN      있음 (그대로 사용)
  5 apps/memo/values.yaml                                 없음 → 생성 (public memo.ukyi.app, postgres, valkey)
  6 apps/memo/image.yaml                                  없음 → 생성 (sha256:aaaa…a, revision 1111…1)
  7 data/memo/values.yaml                                 없음 → 생성 (postgres, valkey persistent)
  8 PR ukyi-app/homelab                                   새로 (브랜치 cli/app-add-memo)
주의: memo.ukyi.app은 공개된다. 공개 여부는 PR 병합으로 확정된다.
다음: 같은 명령에 --apply
```

9번의 상태 출력 (목표 예시)

```text
$ homelab status memo
memo  revision 1111…1  image sha256:aaaa…a
  빌드        성공     ukyi-app/memo run #7
  배포 PR     없음     (마지막 병합 #123)
  Argo CD     Synced·Healthy   memo, memo-data
  파드        1/1 Ready        imageID digest 일치
  시크릿      3/3 Ready        memo-app, memo-db, memo-valkey
  PostgreSQL  준비됨           역할 memo, DB memo, 마이그레이션 Job 성공
  Valkey      준비됨           영속, 마지막 백업 없음(첫 백업 03:30 KST 예정)
  공개        https://memo.ukyi.app  200
다음: 없음
```

**실패하면 어떻게 보이나** (사람이 원인과 다음 행동을 바로 알 수 있어야 한다)

| 상황 | `homelab status memo`가 보여 주는 것 |
|---|---|
| 4번을 빼먹음 | "시크릿 1/3 Ready: `memo-app`의 `MEMO_API_TOKEN`이 Infisical에 없음. 다음: `homelab secret set memo MEMO_API_TOKEN`". 파드는 시작하지 않고 잘못된 값으로 뜨지 않는다(시나리오 6) |
| 마이그레이션 실패 | "마이그레이션 Job 실패(로그 마지막 20줄). 다음: 코드 수정 뒤 main 병합" |
| 같은 명령을 다시 실행 | 6번을 또 실행하면 모든 단계가 "같음, 건너뜀"이고 비밀번호는 바뀌지 않는다(시나리오 5) |

**앱을 지울 때:** `homelab app remove memo --apply` → PR(사람이 검토 후 병합) → 앱 워크로드만 사라진다. `homelab data list`에 `memo`의 DB와 Valkey PVC가 "주인 없는 데이터"로 남는다. 정말 지우려면 나중에 `homelab data purge memo --confirm memo`로 두 단계 PR을 거친다(C.5.5).

---

## E. 단계별 구축 계획

### E.0 순서

design-prompt §10-E의 순서다: §1 미완료 항목(옛 클러스터 철거 포함) → 호스트·k3s 부트스트랩 → 기반 플랫폼 → 테스트 앱 → 첫 실제 앱(봇). main 교체는 철거 뒤(E2)다. 기존 앱 재연결은 테스트 앱 검증 뒤 준비하고 실제 배포는 봇의 첫 배포 뒤에 한다.

```text
화살표 왼쪽이 끝나야 오른쪽을 시작한다(E5는 착수와 완료를 나눔). 줄마다 E.1 선행 조건과 같다
T05 결정 ─▶ E1 철거·정리 ─▶ E2 main 교체·호스트·k3s·Argo CD ─▶ E3 시크릿 체계
E3 ─▶ E4a 네트워크·DNS·공개
E3, E4a ─▶ E4b 관측·알림·봇 자리
E4a ─▶ E4c 내부 UI 짧은 주소(T08c, D-30. 2026-10-20 추가)
E2 ─▶ E5 CI/CD 착수,  E3 ─▶ E5 완료
E4a 첫 Terraform apply(U02 잠금 시험) ─▶ E5 `infra/github` 첫 apply
E3, E4a, E5 ─▶ E6 데이터
E5, E6 ─▶ E7 CLI (읽기 명령은 E5 뒤 먼저 착수 가능)
E4a, E4b, E4c, E5, E6, E7 ─▶ E8 테스트 앱 통합 검증
E8, T14·T15 결정 ─▶ E9 봇 첫 배포(T16b)
E8 ─▶ E10 준비,  E9 ─▶ E10 기존 앱 재연결 배포
```

T15 결정(V1 범위 조정 안 3, 확정(사용자 2026-10-18, T15))으로 T16은 T16a(봇 FOUNDATION 로컬·mock, T15 뒤 바로 착수)와 T16b(실연동·첫 배포, T13 뒤)로 나뉜다. T16a는 플랫폼 단계를 쓰지 않아 위 그림에 없고, E9는 T16b의 플랫폼 쪽이다.

각 단계의 외부 변경(계정, App, 삭제, 배포, 병합, 공개)은 사람 승인 뒤에 하고 [approvals.md](../approvals.md)에 남긴다(AC-X2). 단계 문서·설정은 E2 전까지 `rebuild`에 커밋하고, E2 뒤에는 PR로 main에 병합한다(spec §12).

### E.1 단계별 내용

#### E1 철거·정리 (T06)

| 항목 | 내용 |
|---|---|
| 만들 것 | 새 플랫폼은 없다. T06의 정리 목록·자격 폐기 표 상태, approvals 기록, GitHub 임시 ruleset `main-interim`(E5까지 main 보호. `gh api`로 만들고 E5에서 Terraform이 import한다, C.3.9) |
| 옛 저장소에서 가져올 것 | 파괴 절차 원칙(확인 env가 필요한 별도 파일, 남은 경로 부재 확인, L22), 호스트 판정 H1~H9, B.8 "E1 철거" 함정 |
| 선행 조건 | T05 결정(D-10, D-11, D-12, D-26, D-27. 모두 확정(사용자 2026-10-18, T05)). aiops 자원은 보류한다. `aiops` 저장소와 옛 aiops App은 제거하기로 했고(D-29) T22에서 교훈을 추린 뒤 지운다. 0절 7항(`page`·`trip-mate-api` 삭제)과 8항(결정 5 하드닝)은 2026-10-18에 실행했다. 시작 때 0절 7·8항의 확인 명령으로 다시 본다. T02 push, T01 PR 닫기(완료, 0절). **사람 작업:** NUC 로컬 자료 보존(옛 사본 번들, 로컬 자격 파일은 state 처리 끝까지 보존), AdGuard 라이브 설정 내보내기(sudo, 비밀값 제외, 저장소 밖. 사용자 규칙·허용 목록·추가 필터 목록의 개수를 세어 D-08 (b′)의 대가 크기를 기록한다, C.3.6), "돌아갈 수 없는 지점" 확인 기록, healthchecks 체크 `homelab-watchdog` 일시 정지. **필요한 자격:** 옛 사본 kubeconfig(컨트롤러 축소), 옛 Terraform 자격(state 처리, 이 단계에서만), Cloudflare·R2·Tailscale·GitHub·healthchecks 콘솔 |
| 완료 기준 | T06 완료 조건, 0절 3·4·6항이 "완료". **자격 폐기 표의 옛 Telegram 봇 토큰 행은 폐기하지 않고 `보류(D-10, T22)`로 둔다.** 저장소 밖 `mac-uptime-guard`가 같은 토큰을 써서 폐기하면 그 알림이 아무 표시 없이 끊긴다. D-10은 새 봇으로 확정(사용자 2026-10-18, T05)됐고 옛 봇 토큰을 재발급하는 대안은 고르지 않았으므로, E3이 이 행을 닫는 분기는 쓰이지 않는다. **옛 healthchecks ping URL 행은 `보류(D-10, T08b)`로 둔다.** 체크는 선행 조건의 사람 작업으로 일시 정지돼 있고, E4b가 새 외부 생존 감시가 초록인 것을 확인한 뒤 옛 체크를 지우며 닫는다(D-10은 healthchecks.io를 계정 재사용, 체크 새로 쓰기로 확정). 자격 폐기 표에는 `page`·`trip-mate-api`의 옛 자격(trip-mate-api의 Google OAuth client, OXR app id, `BETTER_AUTH_SECRET`, page admin token) 행을 넣고 폐기한다(D-29, 0절 7항). GitHub: **임시 ruleset `main-interim`을 먼저 건다**(대상 main. PR 필수, 승인 1, code owner 리뷰 필수, force push·삭제 금지, bypass는 저장소 관리자 역할(`pull_request` 모드)만). 그다음 `main-interim`이 active인지 확인한다(`gh api repos/ukyi-app/homelab/rulesets/<id> --jq .enforcement` → `active`, `gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[].type]'`에 `pull_request`). 확인한 뒤에만 같은 단계에서 옛 브랜치 보호(`gate`·push 제한을 포함한 전체)를 삭제하고(`gh api -X DELETE repos/ukyi-app/homelab/branches/main/protection`) 같은 경로가 404인지 본다(E5부터 Terraform guard가 404를 계속 확인한다). 이어서 ruleset 2개·webhook·environment 4개·저장소 변수 2개 삭제, `allow_auto_merge=false`, 옛 reader·writer·dispatch App 삭제(aiops App은 보류, D-29대로 T22에서 삭제. 다만 homelab에 설치돼 있으면 homelab 설치만 지금 해제한다. 남아 있으면 그 App의 승인 리뷰가 `main-interim`의 승인 1을 채울 수 있다(추측)). 이렇게 해야 E5에서 ruleset A~D가 생길 때까지 main이 열리지 않는다(E5는 ruleset B가 걸린 것을 확인한 뒤에만 `main-interim`을 끈다. E2부터 Argo CD가 main을 자동 동기화하고 Codex Connector는 contents write가 있다). 옛 main에는 `CODEOWNERS`가 없어(`git ls-tree -r 2d2054a`에 없음) code owner 조건은 E2의 main 교체 뒤부터 효력이 있고, 그 사이는 승인 1이 막는다. 임시 ruleset을 만든 직후 U08 셋째 조건을 첫 시험으로 본다(C.4.7). Cloudflare: 옛 터널·DNS·WAF·캐시 규칙 삭제(zone 설정은 D-11대로 남김), R2 옛 버킷 3개 삭제, 옛 state 객체 비공개 이동. NUC: k3s, 옛 유닛, 옛 데이터 경로(`/mnt/bulk`는 비우고 fstab 항목 삭제) 부재. **노드 DNS drop-in과 `accept-dns=false`는 남긴다**(H5). Tailscale ACL·DNS는 건드리지 않는다(C-05 유지) |
| 검증 방법 | `test ! -e /usr/local/bin/k3s && ! systemctl cat k3s.service >/dev/null 2>&1 && sudo test ! -e /var/lib/rancher/k3s && sudo test ! -e /var/lib/rancher/k3s-storage`. `systemctl list-unit-files \| grep -E 'aiops\|files-data\|systemd-failed-sweep\|unit-failure\|motd-refresh'` → 빈 결과. `systemctl status /var/lib/homelab-aiops`(경로로 조회) → 유닛 없음, `findmnt /var/lib/homelab-aiops` → 빈 결과. `gh api repos/ukyi-app/homelab/rulesets --jq '[.[] \| {name, enforcement}]'` → `main-interim` 하나, `active`. `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .current_user_can_bypass`(owner) → `pull_requests_only`(U08 셋째 조건). `gh api repos/ukyi-app/homelab --jq .allow_auto_merge` → `false`. `gh api repos/ukyi-app/homelab/branches/main/protection` → 404(옛 브랜치 보호 삭제). `gh api repos/ukyi-app/homelab --jq .archived` → `false`. 옛 aiops App이 homelab에 설치돼 있지 않음(`gh api orgs/ukyi-app/installations`의 그 App `repository_selection`이 `all`이면 설치된 것이고, `selected`면 org 설정의 설치된 App 화면 Repository access에서 homelab이 없는지 본다). `gh api repos/ukyi-app/page`와 `gh api repos/ukyi-app/trip-mate-api` → 404(0절 7항이 실행됐는지). `tailscale dns status` → C-05 그대로. 자격 폐기 표와 각 콘솔 목록 대조 |
| 되돌리는 방법 | 컨트롤러 축소까지는 replicas를 되돌리면 옛 Argo CD가 돌아온다. k3s 제거와 외부 자원·자격 삭제는 되돌릴 수 없다(그래서 선행 확인에서 사람이 확인). 보호·ruleset 해제는 T06 문서에 남긴 옛 설정으로 다시 만들 수 있다. 임시 ruleset `main-interim`은 되돌리지 않고 E5까지 둔다 |

#### E2 main 교체·호스트·k3s·Argo CD (T07)

| 항목 | 내용 |
|---|---|
| 만들 것 | `host/`(C.3.2. 클러스터별 값은 `host/clusters/prod.env`, VM의 `vm.env`는 E8 전에 채움), `platform/argocd`·`platform/root`·`platform/namespaces`(C.3.3, 뒤 단계 Application 자리를 미리 만들어 동시 편집 충돌을 막음. `platform/root`에는 운영 root `root-prod.yaml`, 같은 모양의 VM root `root-vm.yaml`(운영에는 apply하지 않음, 운영 root가 자식으로 렌더하지 않음, C.3.3)과 클러스터 값 파일 `values-prod.yaml`을 둔다. `platform/root`는 Helm 차트이고(권장, C.3.3) root가 `helm.valueFiles`로 읽은 값을 구성 요소 Application의 Helm values로 넘긴다. Helm 차트가 아닌 구성 요소에 넘기는 방식은 여기서 정한다, E8 VM 격리 1번. VM의 `values-vm.yaml`은 E8 전에 채움), `README.md`·`AGENTS.md`·`CLAUDE.md`·`.gitignore`·`.gitleaks.toml`·`.pre-commit-config.yaml`·`.tool-versions`·`CODEOWNERS`, 최소 `ci.yaml`(gitleaks, actionlint, kustomize build), `docs/runbooks-public/bootstrap.md`, 필수 검사 `ci` ruleset(bypass 없음, E5의 ruleset A와 같은 모양. main 교체·Actions 재활성 뒤 main에서 `ci`가 한 번 초록인 것을 본 다음 `gh api`로 건다. E5에서 Terraform이 import해 `main-checks`로 제자리 이름 변경, C.3.9) |
| 옛 저장소에서 가져올 것 | P05 하위 판정(C.3.2 표), H4·H5·H6, L21 원칙, P08의 실측 설정값, R33·R34·R41·R42, B.8 "E2" 함정 |
| 선행 조건 | E1 완료(시작 조건 명령 재실행, 기록). D-03·D-12·D-25·D-26(확정). **사람 작업:** rebuild → main PR 검토 후 병합(Codex Connector 자동 리뷰는 D-26대로). 이 PR은 E1의 임시 ruleset 아래에서 owner가 관리자 bypass(`pull_request` 모드)로 squash 병합한다(`--match-head-commit <검토한 SHA>`, D-25, C.4.7). 그때는 Actions가 꺼져 있어 `ci`가 돌지 않으므로 `ci` 필수 검사는 이 병합 뒤에 더한다. sudo로 호스트 설정과 k3s 설치, Actions 재활성 승인(`allowed_actions`는 바로 C.4.10 설계값). OS를 다시 설치했다면 옛 NUC 기기 삭제, Tailscale 재등록(`tag:nuc`, D-11 (c))과 이름 확인 뒤 태그와 키 만료 꺼짐 확인(C.3.2의 0). **필요한 자격:** GitHub 관리자, NUC sudo. 새 외부 자격은 없다 |
| 완료 기준 | main이 새 구조. Argo CD가 main을 동기화하고 `argocd`·`namespaces` Application이 Synced·Healthy. k3s가 고정 버전. 노드 DNS가 공용 DNS 직접. 재부팅 뒤 k3s·Argo CD 복귀(시나리오 12의 이 범위). `bootstrap.md` 밖의 수동 단계 없음. 저장소 Actions가 켜지고 새 워크플로만 있음. main에 임시 ruleset과 필수 검사 `ci`가 함께 걸림 |
| 검증 방법 | `host/verify.sh --cluster prod`. `kubectl -n argocd get applications`. `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation} {.data.timeout\.reconciliation\.jitter}'` → `60s 0`(C.3.3). `resolvectl status`에 `1.1.1.1 9.9.9.9`, `tailscale dns status` → "Tailscale DNS: disabled". `sudo reboot` 뒤 같은 확인. `gh api repos/ukyi-app/homelab/actions/permissions` → `enabled:true`, `allowed_actions:selected`. `gh api repos/ukyi-app/homelab/rules/branches/main --jq '[.[].type]'` → `pull_request`, `required_status_checks` 포함. 자기 저장소 참조 revision이 모두 `main`인지 손으로 확인한다(L31의 내용. L31 자동 검사는 E5의 전체 `ci`에 생기고, rebuild → main 병합 때는 Actions가 꺼져 있으며 최소 `ci`에도 없다): 병합 전 rebuild 작업 트리와 병합 뒤 main에서 `{ helm template root platform/root -f platform/root/values-prod.yaml; for f in $(git ls-files 'platform/*.yaml' \| grep -vE '/templates/\|/values[^/]*\.yaml$'); do echo ---; cat "$f"; done; } \| yq -N '.. \| select(tag == "!!map") \| select(has("repoURL")) \| select(.repoURL \| test("(?i)ukyi-app/homelab(\\.git)?/?$")) \| (.targetRevision // .revision // "없음")' \| sort \| uniq -c` → 한 줄 `<N> main`(N은 1 이상. 다른 값이 한 줄이라도 있거나 0줄이면 실패, L40). `repoURL`을 가진 모든 맵을 훑어 Application 단일·다중 소스와 ApplicationSet git 생성기의 `revision`을 함께 잡고, `.git` 접미사와 대소문자 차이도 같은 저장소로 본다(옛 함정, `2d2054a:scripts/check-argocd-revision.sh:6-10`, `:20-29`). 운영 root 렌더 결과에 `root-vm` Application이 없음(C.3.3). 작업 기록과 `bootstrap.md` 대조 |
| 되돌리는 방법 | T07 "되돌리기" 그대로: Argo CD가 main을 보기 전이면 revert PR. 본 뒤면 Argo CD 자동 동기화를 먼저 멈추고 revert(그대로 revert하면 옛 트리가 새 클러스터에 깔림). Actions를 켠 뒤라면 revert 전에 끈다(`gh api -X PUT repos/ukyi-app/homelab/actions/permissions -F enabled=false`). k3s 재시도는 `k3s-uninstall.sh` + 잔여 경로 확인 뒤 다시 |

#### E3 시크릿 체계 (T09)

| 항목 | 내용 |
|---|---|
| 만들 것 | Infisical 프로젝트 5개(`homelab` prod, `homelab-dev` dev, 사람 전용 `homelab-admin`, `homelab-ci-deploy`, `homelab-ci-merge`)와 identity 4개(사람, `eso-homelab`, `eso-homelab-dev`, `gha-homelab-deploy`. C.6.3. `eso-homelab-dev`은 E8의 VM 검증용. 병합 키는 identity 없이 E5에서 environment가 생긴 뒤 Secret Sync, D-04), `platform/external-secrets`(ESO 2.13.0 + ClusterSecretStore 2개), ESO 부트스트랩 Secret, 플랫폼 시크릿 등록(`homelab`: 새 Telegram 봇 토큰, Grafana·AdGuard·Argo CD 관리자 자격. Terraform 자격은 `homelab-admin`에만), 저장소 밖 복구 자산과 목록, `docs/runbooks-public/rotate.md` 초안. **첫 작업:** Infisical OIDC Auth의 Free 사용 가능 여부와 배포 identity의 claim 묶기 확인(C.4.8, U05). 시험 워크플로는 시크릿 없는 시험 키로 하고 끝나면 지운다 |
| 옛 저장소에서 가져올 것 | L19 원칙(값 부재는 실패, 비밀번호 재생성 금지, 좁은 토큰), L15·L46 교훈(복구 자산 신선도), R40 원칙, B.8 "E3" 함정 |
| 선행 조건 | E2. D-04, D-20. **사람 작업:** Infisical 가입(2FA), 요금제 선택, identity 생성, Universal Auth client secret 발급, 새 외부 토큰 발급(Cloudflare Terraform용 토큰, R2 state 버킷 키, Tailscale Terraform용 OAuth(ACL과 DNS 쓰기, 기기 읽기). 셋 다 `homelab-admin`에 등록), homelab 알림용 Telegram 봇 새로 만들기(BotFather, D-10. 새 봇은 대화를 먼저 시작할 수 없어 사람이 새 봇에게 먼저 메시지를 보낸다[S172]). **옛 봇의 토큰은 재발급하지 않는다(D-10, 확정(사용자 2026-10-18, T05). 재발급 대안은 고르지 않았다):** `/token` 재발급은 유출 대응용이라 옛 토큰이 끊긴다고 봐야 하고[S173] (추측), 그 토큰을 쓰는 저장소 밖 `mac-uptime-guard`(`2d2054a:policy/gh-secret-var-classification.json:91`)의 알림이 T22까지 아무 표시 없이 멈춘다. 옛 봇과 토큰은 T22가 `mac-uptime-guard`를 처리할 때까지 그대로 둔다. 복구 자산을 NUC 밖 두 곳에 저장 |
| 완료 기준 | ClusterSecretStore 2개 Ready. 시험 ns의 ExternalSecret이 동기화. 아래 동등 절차로 시나리오 6·7의 E3 범위(`SecretSyncedError`, Secret 불변, `CreateContainerConfigError`, 기존 Secret 유지, ExternalSecret health 덮어쓰기) 통과. 경보·Telegram 수신(E4b), 배포 PR 자동 병합 흐름(E5), `homelab status` 표시(E8)는 E3 완료 기준에서 빼고, 어느 항목도 E4b·E5·E7의 산출물을 쓰지 않는다. 복구 자산 목록이 저장소 밖에 있고 저장소에는 종류·위치만. T06 자격 폐기 표의 `보류(…, T09)` 줄이 모두 닫힘. **다음 두 줄은 이 닫기에서 뺀다:** 옛 healthchecks ping URL 행 `보류(D-10, T08b)`는 E4b(T08b)가 닫는다. 옛 Telegram 봇 토큰 행 `보류(D-10, T22)`는 T22가 `mac-uptime-guard`를 처리한 뒤 닫는다(E10). D-10이 새 봇으로 확정(사용자 2026-10-18, T05)돼, E3이 이 행을 닫는 대안 분기(옛 봇 재사용)는 쓰이지 않는다. 복구 자산의 운영 ESO 자격으로 Infisical 로그인 성공(아래 장애 주입 뒤에도). 배포 키 OIDC 방식 확정(안 되면 배포 키도 앱별 Secret Sync로 전환하고 기록, F D-04). `homelab-ci-merge`에 machine identity가 없음. `eso-homelab`이 `homelab` 밖의 프로젝트(`homelab-admin`, `homelab-dev`, `homelab-ci-*`)를 읽지 못함 |
| 검증 방법 | `kubectl get clustersecretstore -o wide`. 없는 키를 가리키는 시험 ExternalSecret → `kubectl get externalsecret -o jsonpath='{.status.conditions}'`에 `SecretSyncedError`, 대상 Secret 없음. 아래 "시험용 client secret 장애 주입"으로 ESO 인증을 끊음 → 기존 시험 Secret 유지, Ready=False(경보는 E4b에서 본다) → 부트스트랩 Secret을 원래 client secret으로 되돌려 복구. 시나리오 6·7은 아래 동등 절차. 복구 자산의 운영 ESO client ID·secret으로 Infisical Universal Auth 로그인 → 성공(토큰은 출력하지 않고 응답 코드만. 장애 주입 전과 뒤에 한 번씩). `eso-homelab`의 Universal Auth로 로그인한 토큰으로 `homelab-admin`·`homelab-dev`·`homelab-ci-*` 값 조회 → 모두 거부(값은 출력하지 않고 응답 코드만 본다) |
| 되돌리는 방법 | ESO Application을 revert PR로 제거(시험 ns만 영향), 부트스트랩 Secret 삭제, identity 비활성화. Infisical 프로젝트와 값은 남긴다 |

**E3의 동등 절차** [제안]: 경보(E4b), 배포 PR 흐름(E5), `homelab status`(E7)는 E3 뒤에 생기므로, E3은 시나리오 6·7을 그 산출물 없이 시험 ns에서 같은 확인으로 통과시킨다. 대상은 root 아래에 PR로 더한 시험 Application `e3-probe`(프로젝트 `platform`, ns `app-e3-probe`. `infisical-apps` store의 conditions가 `app-*`라서다)다. 원본은 `platform/e3-probe/`에 손으로 쓴 Deployment 1개(digest로 고정한 공개 이미지, readiness, 키마다 `valueFrom.secretKeyRef`, `envFrom` 없음, C.4.5와 같은 모양)와 ExternalSecret 1개(키마다 `data[]`)이고, 값은 사람이 Infisical `homelab`/`prod`의 `/apps/e3-probe/`에 만든 시험 키 하나다. ExternalSecret health 덮어쓰기(C.3.3)가 `argocd-cm`에 있어야 한다.

- **시나리오 6(E3 범위):** Infisical에 없는 키를 ExternalSecret `data[]`와 Deployment env에 더하는 손 PR 병합 → `kubectl -n app-e3-probe get externalsecret e3-probe -o jsonpath='{.status.conditions[0].reason}'` → `SecretSyncedError`, 대상 Secret의 `sha256sum`이 전후 같음, 새 파드 `CreateContainerConfigError`와 옛 파드 Ready, `kubectl -n argocd get application e3-probe -o jsonpath='{.status.health.status}'` → `Degraded`(지금 spec으로 동기화한 이력 없음). revert PR → Healthy.
- **시험용 client secret 장애 주입** [제안]: 운영 ESO client secret(복구 자산의 값)은 폐기하지 않는다. 폐기하면 저장소 밖 복구 자산이 폐기된 값으로 남고, 시나리오 13은 VM 전용 identity를 써서 이를 잡지 못해 실제 빈 NUC 복구 때에야 드러난다. 대신 `eso-homelab`에 시험용 두 번째 Universal Auth client secret을 발급한다(identity마다 client secret을 여럿 두고 ID별로 폐기할 수 있다[S180]). 부트스트랩 Secret `external-secrets/infisical-universal-auth`의 `clientSecret`만 그 값으로 바꾸고(값은 출력하지 않는다) ClusterSecretStore Ready를 확인한 뒤, Infisical에서 두 번째 secret을 폐기해(승인 기록) 장애를 낸다. 복구는 부트스트랩 Secret을 원래 secret으로 되돌리는 것이고, 두 번째 secret은 폐기된 채 남긴다. 끝에 복구 자산의 운영 ESO 자격으로 로그인 → 성공(응답 코드만). E4b·E5·E8(시나리오 7)도 이 방법을 쓴다.
- **시나리오 7(E3 범위):** 위 시험용 client secret 장애 주입(승인 기록) → ExternalSecret 즉시 갱신 annotation[S22]으로 실패를 바로 일으킴 → `kubectl get clustersecretstore` Ready=False, 기존 Secret 그대로 → `kubectl -n app-e3-probe delete pod -l app=e3-probe` 뒤 기존 Secret으로 Ready → Deployment 이미지 digest만 바꾸는 손 PR 병합 → 새 파드 Ready, Application Healthy(health 덮어쓰기, U07) → 새 키를 요구하는 손 PR → Degraded, 원인은 ExternalSecret conditions에 보임 → 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀와 자동 재동기화.
- **E3에서 빼고 넘기는 확인:** ExternalSecretNotReady 경보와 Telegram 수신은 E4b(완료 기준의 시나리오 6·7 경보 부분), 이미지만 바꾸는 배포 PR의 자동 병합은 E5(동등 절차의 시나리오 7 배포 흐름 부분), `homelab status`가 빠진 키와 다음 명령을 보여 주는지는 E8(시나리오 6·7 전체를 `homelab-smoke`로)이 본다.
- 끝에 시험 Application·`platform/e3-probe/`를 지우는 PR을 병합하고 Infisical 시험 키를 지운다.

#### E4a 네트워크·DNS·외부 공개 (T08a)

| 항목 | 내용 |
|---|---|
| 만들 것 | `infra/cloudflare`(새 터널, 와일드카드·apex DNS, zone 설정 9개, WAF 규칙, R2 `homelab-backups`와 lifecycle), `infra/tailscale`(ACL), `infra/tailscale-dns`(DNS 설정 `tailscale_dns_configuration`, 별도 root, C.3.6), `platform/cert-manager`, `platform/traefik`, `platform/cloudflared`, `platform/tailscale`(operator + ProxyClass), `platform/adguard`(T06 내보내기에서 비밀·LAN 기기 이름을 뺀 시드, 필터는 AdGuard DNS filter 하나), Argo CD·AdGuard 내부 Ingress, `hooks.ukyi.app` 경로와 시험 수신기 |
| 옛 저장소에서 가져올 것 | P03, P06, P07, P12, P21, P22의 실측 설정값, H5, B.8 "E4" 함정(AdGuard, Tailscale, Cloudflare) |
| 선행 조건 | E3(터널 토큰·OAuth를 Infisical로 받기 위해). D-08, D-11. **사람 작업:** Terraform apply(owner 로컬, `infisical run`), Tailscale operator OAuth client 발급, tailnet HTTPS 인증서 켜기, Tailscale DNS Terraform 첫 apply(콘솔의 현재 값을 기록 → 그대로 옮긴 HCL로 새 state에 import → plan 무변경 확인) 뒤 D-08 (b′) 값으로 바꾸는 PR과 apply(Override 켬, 전역 nameserver [NUC Tailscale IP, `94.140.14.14`, `94.140.15.15`], C-05의 Cloudflare 4개 삭제), NUC 키 만료 해제 확인, AdGuard 내보내기 파일 제공 |
| 완료 기준 | 시나리오 14 통과(또는 못 미친 항목을 기록하고 사용자가 한계로 승인. 2026-10-20 AC-P6 LAN이 이 경우다). Tailscale DNS가 (b′)이고 DNS plan이 무변경. 공개 시험 URL 200, 없는 host 404. 내부 UI가 `*.ts.net`으로 열림. 새 ACL 적용 뒤 원격에서 NUC로 SSH(tailnet 주소의 sshd) 성공. C.8의 공개 webhook 경로 준비 확인 통과 |
| 검증 방법 | `curl -sI https://<시험 host>.ukyi.app`, `curl -sI https://nope.ukyi.app`. tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net`. `ssh <NUC>`(tailnet 주소, sshd). `dig @192.168.117.15 example.com +short`. `tailscale dns status --all`에 nameserver 셋(NUC, AdGuard 공용 2개)과 Cloudflare 없음. 셀룰러의 Tailscale 기기에서 광고 도메인(예: `doubleclick.net`) 차단 응답과 AdGuard Home 질의 로그 도착, 그 질의의 출처 표시 기록(U32). R2 잠금 동시 실행 시험 1회(U02: 같은 root를 두 터미널에서 동시에 plan해 하나가 잠금 오류로 멈추는지). 시나리오 14 명령(G). C.8 webhook 경로 명령. U28: 새 ACL 적용 뒤 NetworkPolicy가 없는 시험 ns의 파드에서 운영자 노트북의 시험 포트로 연결해 성공 여부를 기록(결과가 F D-11 (c) 재검토의 입력) |
| 되돌리는 방법 | Tailscale ACL은 적용 전 정책 사본을 남기고 그 사본으로 되돌린다. DNS는 C-05 값을 선언한 커밋으로 되돌려 apply(급하면 콘솔에서 Cloudflare 항목을 다시 넣고 HCL을 맞춤). Terraform은 새 state라 새 자원만 `terraform destroy -target`으로 지울 수 있다(옛 자원 없음). 클러스터 쪽은 revert PR |

#### E4b 관측·알림·봇 자리 (T08b)

| 항목 | 내용 |
|---|---|
| 만들 것 | `platform/observability`(차트, 핵심 룰과 단위 시험, Git 대시보드), Alertmanager 라우트(Telegram, healthchecks, 봇 자리 주석), healthchecks.io 새 체크, AdGuard tailnet 이탈 감시(tailnet 출처 질의 1시간 0건 경보, C.3.7. 방식은 E4a의 U32 결과로 정함), 읽기 전용 계정 셋(Kubernetes SA·ClusterRole·바인딩은 아래 `platform/bot-slot`에, Argo CD `bot-reader`, Grafana SA), `platform/sandbox`(작업자 전용 ClusterSecretStore `infisical-sandbox`, 작업자 쪽 기본 거부, 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나, D-14), 상주 작업자 자리(상주 파드 하나와 컨테이너 포트 8080은 D-15. [제안] Deployment replicas 1, `strategy: Recreate`는 D-15가 정한 값이 아니다, C.8 격리 행))와 egress 프록시(고정 ClusterIP Service. 코드 읽기는 `codeload.github.com`만 허용하고 `github.com`·`api.github.com`·`gist.github.com`은 넣지 않는다, D-15. 구독 인증의 모델 호스트는 E9에서 넣는다), 봇 자리 Application `platform/bot-slot`(wave 1, retry 무제한·`refresh: true`. `target`은 시험 ns `bot-slot-probe`와 시험 라벨이고, `probe: true`로 그 ns의 Namespace와 C.4.5 네트워크 행을 손으로 옮긴 정책을 Git에 둔다. 봇 쪽 NetworkPolicy, sandbox 작업자 ingress 허용, SA `bot-reader`, C.8), C.8 준비 확인용 경보 시험 수신기와 시험 파드(작업자, 봇 자리). webhook 시험 수신기와 C.8 webhook 확인은 E4a(T08a)가 만든다 |
| 옛 저장소에서 가져올 것 | P23 하위(vmsingle 메모리 설정, vmalert reload, Alertmanager 설정 해시, 외부 수신자 `continue: true` 선례), L30, L34~L36의 교훈, L39, AIOps 격리 교훈(B.8 끝) |
| 선행 조건 | E3, E4a(Grafana 내부 Ingress용 Tailscale operator, AdGuard Home과 U32 출처 결과, 새 ACL). D-09, D-10, D-14·D-15(확정(사용자 2026-10-18, T15): 작업자 영속 공간, 동시성 1, 포트, `codeload.github.com`만 허용, U13이 안 되면 호스트 전용 UID + nft). **사람 작업:** healthchecks.io 새 체크(Period·Grace), 새 Telegram 봇의 수신 chat 확인, 시험 경보 승인 |
| 완료 기준 | 시나리오 16·17 통과. 시나리오 6·7의 경보 부분(E3이 넘긴 것) 통과. AdGuard tailnet 이탈 경보 발화 시험 통과(아래 검증 방법). C.8의 읽기 전용 접근(그 줄의 CI 검사 L30은 전체 `ci`가 생기는 E5에서 본다)·경보 외부 수신자·격리 작업 공간 준비 확인 통과(D-14 영속 공간 유지와 D-15 허용 목록 확인 포함). 핵심 룰 단위 시험 통과. 옛 healthchecks 체크 삭제(새 체크가 초록이 된 뒤)와 T06 자격 폐기 표의 그 줄(옛 ping URL, `보류(D-10, T08b)`) 닫힘, approvals 기록 |
| 검증 방법 | G 시나리오 16·17 명령. 시나리오 6·7 경보 부분: 시험 ns에 없는 키를 가리키는 ExternalSecret을 두고, 또 E3의 시험용 client secret 장애 주입으로 ESO 인증을 잠시 끊어(승인 기록. 운영 client secret은 폐기하지 않는다) ExternalSecretNotReady 경보가 Telegram에 도착하는지 보고 복구 뒤 resolved와 시험 ns 삭제를 확인한다. C.8 표의 명령. `vmalert-tool unittest`(형식 미검증). **이탈 경보 발화 시험:** 감시 방식(E4a의 U32 결과)에 맞춰 tailnet 경로만 끊는다. NUC를 `tag:nuc`로 태그해 `tag:nuc:53` 규칙이 따로 있으면(D-11) 정책 사본을 남기고 그 규칙을 뺀 정책을 apply한다(승인 기록). 태그하지 않아 `autogroup:self:*`가 모든 포트를 열고 있으면 사람이 sudo로 `iptables -t raw -I PREROUTING -i tailscale0 -p udp --dport 53 -j DROP`(tcp도 같이)를 임시로 넣고 시험 뒤 지운다. raw PREROUTING은 hostPort DNAT보다 먼저라 svclb 경로까지 끊긴다(형식 미검증). 그 동안 Tailscale 기기는 공용 서버로 해석한다(C.3.6). 1시간 무질의 뒤 다음 평가 주기 안에 Telegram 수신을 확인하고, 정책을 되돌린 뒤 resolved를 확인한다. 룰 논리는 단위 시험으로 따로 본다 |
| 되돌리는 방법 | revert PR. healthchecks 체크는 일시 정지 |

#### E4c 내부 UI 짧은 주소 (T08c, 2026-10-20 추가)

| 항목 | 내용 |
|---|---|
| 만들 것 | tailnet 전용 리다이렉터 `go`(상태 없는 웹 서버 Deployment, operator LoadBalancer Service HTTP 80, NetworkPolicy, tailnet 도메인 ExternalSecret), ACL `tag:k8s-go`·`autogroup:member → tag:k8s-go:80`(C.3.5, F D-30) |
| 선행 조건 | E4a(Tailscale operator·ProxyClass, ACL root). D-30. **사람 작업:** Infisical `homelab`/prod와 `homelab-dev`/dev에 tailnet 도메인 키 등록, ACL apply(owner 로컬), 맥·아이폰 셀룰러 확인 |
| 완료 기준 | T08c 완료 조건. 아이폰 Safari에서 처음 한 번 `http://go/argocd`로 연 뒤 스킴 없는 `go/argocd`가 열리는 것이 필수다(D-30 입력 방식, 사용자 2026-10-21). VM은 렌더만 보고 실접속은 E8 시나리오 13에서 본다 |
| 검증 방법 | T08c 완료 조건의 명령 |
| 되돌리는 방법 | Application이 살아 있을 때 `go` 매니페스트를 지우는 PR로 prune 완료(Service·프록시 기기 사라짐)를 확인한 뒤 ACL 두 줄을 지운다 |

#### E5 CI/CD (T10)

| 항목 | 내용 |
|---|---|
| 만들 것 | `platform/charts/app`과 태그 `app-chart-v1.0.0`, ApplicationSet `apps`와 AppProject `apps`, `.github/workflows/app-build.yaml`과 태그 `app-build-v1.0.0`, 전체 `ci.yaml`, `deploy-merge.yaml`, `.github/workflows/README.md`(자동 병합 조건 공개), Terraform root `infra/github`(C.3.9: ruleset·environment·Actions 권한 리소스, guard, `app-repos.json`, `tests/`의 mock 시험, E1·E2 ruleset의 import 블록)와 CLI와 독립된 래퍼 `tools/tf-github.sh`(E7의 `homelab github plan`·`apply`·`verify`가 같은 규칙으로 감싼다), GitHub App `ukyi-homelab-deploy`·`ukyi-homelab-merge`, environment `automerge`(배포 브랜치 main, `prevent_destroy`)와 병합 키 Secret Sync(Infisical GitHub 연결은 homelab만 고른 fine-grained PAT, D-04), ci의 workflow-guard와 음성 fixture(C.4.6), ruleset A~D(E2의 `ci` ruleset은 import해 `main-checks`로 제자리 이름 변경한다. E1의 임시 ruleset은 import하고 지우지 않는다. **첫 apply는 두 단계다.** 1단계 PR은 `main-interim`을 enforcement `active` 그대로 import하고 ruleset A~D를 만든다. apply 뒤 `gh api repos/ukyi-app/homelab/rulesets/<main-review id> --jq .enforcement` → `active`, `gh api repos/ukyi-app/homelab/rules/branches/main`에 그 ruleset의 `pull_request` 규칙이 보이는지 확인한다. 그다음 2단계 PR에서 `main-interim`을 `disabled`로 바꿔 되돌릴 때 쓴다. 한 apply에서 같이 하면 Terraform이 독립 자원을 병렬로 적용해, B 생성이 실패하거나(#3519 때문에 부분 실패를 전제한다) 비활성화가 먼저 끝날 때 main에 필수 검사 `ci`만 남는 공백이 생긴다(Codex Connector·Renovate는 contents write가 있다). 2단계 뒤에도 `main-interim`을 HCL에 enforcement `disabled`로 선언해 둔다. 선언하지 않으면 guard의 ruleset 이름 집합 검사가 늘 실패하고, 이름으로 예외를 두면 몰래 바꾼 ruleset을 놓친다, C.3.9), 저장소 설정(E1에서 끈 `allow_auto_merge=false`, squash만, 병합 뒤 삭제. `gh api`로 맞추고 guard가 확인), Actions 설정(selected는 Terraform, fork 승인 `all_external_contributors`는 `gh api` + guard), 앱 저장소 공통 ruleset `app-main`(`app-repos.json`의 `for_each`)과 `homelab-app-template`·`homelab-probe`·`files` 적용(래퍼로. 결정 5 하드닝이 `files`·템플릿에 이미 건 `app-main`은 import해 같은 이름을 두 번 만들지 않는다. 하드닝 전이면 템플릿에는 내용 교체 전에 걸어 교체도 PR로 한다. 템플릿 main은 모든 새 앱의 첫 main 내용이라서다, C.4.7. `files`는 남은 public 앱 저장소라 `app-repos.json`에 있어야 guard 8을 통과한다. T14가 봇 저장소를 이미 만들었으면 그것도 넣고 `app-main`을 import한다, C.8), 앱 저장소 보안 설정(secret scanning·push protection, private vulnerability reporting. `gh api` + guard, D-29), `homelab-app-template` 내용 교체(D-21, `CODEOWNERS` 포함), Renovate(D-18), 손으로 등록하는 시험 앱 저장소 `ukyi-app/homelab-probe`(템플릿에서 `gh repo create --public --template`, E6·E7이 이어 쓰고 E7 끝에 등록·데이터를 지움. E8의 `homelab-smoke`는 E8이 CLI로 새로 만든다), 봇 신원 대신 쓸 시험 App `ukyi-homelab-bot-standin` |
| 옛 저장소에서 가져올 것 | L06·L07·L08·L27·L31·L33의 불변식, R10·R14·R16·R26·R29·R42·R43, B.5 공유 차트 판정, B.8 "E5" 함정 |
| 선행 조건 | 착수: E2. 완료: E3(Infisical `homelab-ci-deploy`·`homelab-ci-merge` 프로젝트, 배포 키 OIDC identity. App 키는 E5가 App을 만들고 등록한다). `infra/github` 첫 apply: E4a의 첫 Terraform apply와 R2 잠금 시험(U02) 뒤(R2 state를 처음 쓰는 단계를 하나로 둔다, E.0). D-04·D-07·D-18·D-21·D-26·D-28·D-29(확정). **사람 작업:** App 2개 생성·homelab에만 설치·키를 키별 Infisical 프로젝트에 등록, Infisical GitHub 연결용 fine-grained PAT 발급(homelab만, Metadata read, Environments RW, Secrets RW, 만료 없음(사용자 2026-10-21). org가 fine-grained PAT를 허용하는지 먼저 확인)과 병합 키 sync 생성(1단계 apply로 environment가 생긴 뒤, 2단계 전), `infra/github` 첫 apply(import 포함)와 저장소 설정·fork PR 정책 `gh api` 적용 승인, template 저장소 내용 교체 승인, Renovate 설치, 시험 App 생성(쓰기 직전에. `ukyi-homelab-bot-standin`은 homelab과 `homelab-probe`에, `ukyi-homelab-review-probe`는 저장소 하나에 설치), `homelab-probe` 저장소 생성, org Package Creation의 Public 허용 확인(REST로 읽을 수 없어 화면에서, D-29) |
| 완료 기준 | 아래 CLI 없는 동등 절차로 시나리오 1(DB·공개 URL 없이), 11, 15와 시나리오 7의 배포 흐름 부분(E3이 넘긴 것) 통과. 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않음(AC-P8). 리뷰 전용 App의 저장소별 설치 확인(C.8). C.8 읽기 전용 접근 줄의 CI 검사(L30)가 verb·roleRef를 어긴 시험 매니페스트를 거부(E4b가 넘긴 것). 래퍼 `tools/tf-github.sh verify`가 exit 0(plan 무변경, guard 통과. 대상 homelab, `homelab-app-template`, `homelab-probe`, `files`). `infra/github`의 `terraform test`와 workflow-guard 음성 fixture가 CI에서 통과. environment secret `HOMELAB_MERGE_KEY`가 있고 `updated_at`이 sync 생성 뒤. `homelab-probe` 첫 push 뒤 패키지 가시성을 기록하고(`gh api orgs/ukyi-app/packages/container/homelab-probe --jq .visibility`. public이면 손 작업 없음, private이면 UI에서 Public으로 바꾸고 앱마다 같은 손 작업을 런북에 적음, U39) 익명 pull 토큰 응답이 200. `main-interim`이 `disabled`이고 그 전 1단계 확인(ruleset B active, main에 `pull_request` 규칙) 기록이 있음. 어느 항목도 E7의 CLI나 E4a의 공개 경로를 쓰지 않는다 |
| 검증 방법 | 아래 동등 절차. G 시나리오 11·15 명령(`homelab-smoke`를 `homelab-probe`로, `homelab github verify`를 래퍼 `tools/tf-github.sh verify`로). guard 음성 시험은 CI의 mock 시험으로, 라이브 확인은 래퍼 plan으로. `gh api orgs/ukyi-app/installations`로 설치 범위 확인 |
| 되돌리는 방법 | ruleset은 HCL에서 enforcement를 `disabled`로 바꿔 apply한다(급하면 `gh api -X PUT repos/ukyi-app/homelab/rulesets/<id> -f enforcement=disabled` 뒤 HCL을 맞춤). 그 전에 임시 ruleset `main-interim`을 다시 active로 해 main이 열리지 않게 한다. App 설치 해제, 워크플로 revert PR. template 저장소의 이전 내용은 git 히스토리에 남는다 |

**E5의 CLI 없는 동등 절차** [제안]: CLI는 E7에서 생기므로 E5는 시나리오를 CLI 없이 같은 확인으로 통과시킨다. CLI 경로 재확인은 E7, CLI와 공개 URL을 포함한 시나리오 전체 실행은 E8이 맡는다.

- **시나리오 1(DB·공개 URL 없이):** `homelab-probe` main에 커밋 → 앱 저장소 `app-build` 요약이 "미등록"이고 homelab에 PR 없음 → 사람이 `apps/homelab-probe/values.yaml`(`public` 없이)과 `apps/homelab-probe/image.yaml`(그 빌드의 digest·revision, `hold: false`)을 손으로 써서 PR, 검토 후 관리자 bypass 병합 → G 시나리오 1의 Argo CD·imageID·tailnet 불통 확인 명령(이름만 바꿈) → 공개 URL 대신 `kubectl -n app-homelab-probe port-forward svc/homelab-probe 18080:<서비스 포트>` 뒤 `curl -sf http://127.0.0.1:18080/healthz` → 두 번째 커밋의 `deploy/homelab-probe` PR이 `ukyi-homelab-merge`로 자동 병합되고 새 revision이 배포됨.
- **시나리오 7(배포 흐름 부분):** `homelab-probe`에 시험 키 하나(`apps/homelab-probe/values.yaml`의 `secrets:`와 사람이 만든 Infisical 값)를 둔 상태에서, E3의 시험용 client secret 장애 주입으로 ESO 인증을 끊고(승인 기록. 운영 client secret은 폐기하지 않는다) `homelab-probe`의 ExternalSecret이 Ready=False가 된 것을 본 뒤, `homelab-probe` main에 커밋 → `deploy/homelab-probe` PR이 `ukyi-homelab-merge`로 자동 병합 → 새 revision의 파드 Ready, Application Healthy → 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀. 경보는 보지 않는다(E4b가 따로 본다).
- **시나리오 11:** G 명령은 CLI를 쓰지 않으므로 이름만 `homelab-probe`로 바꿔 그대로.
- **시나리오 15:** G 명령에서 `homelab-smoke`를 `homelab-probe`로, `homelab github verify`를 `tools/tf-github.sh verify`로 바꾼다.

#### E6 데이터 서비스 (T11)

| 항목 | 내용 |
|---|---|
| 만들 것 | `platform/cnpg`(operator, Barman plugin, ObjectStore, Cluster `pg`, ScheduledBackup, NetworkPolicy), `platform/root/values-prod.yaml`의 CNPG 키(버킷, serverName. Cluster `pg`가 이 값으로 렌더된다, C.5.3), `platform/charts/app-data`와 태그 `data-chart-v1.0.0`, ApplicationSet `data`, 영속 Valkey 백업 CronJob 템플릿, `docs/runbooks-public/restore.md`(C.5.6, C.5.7, C.6.4의 빈 NUC 복구 순서와 복구·정리 PR) |
| 옛 저장소에서 가져올 것 | P13 하위(파라미터 산정, plugin 기본값 명시, ObjectStore 먼저, UTC 일정), P09, L10, L11, L13, L14, B.8 "E6" 함정 |
| 선행 조건 | E3, E4a(cert-manager, R2 버킷), E5(배포 흐름, 앱 차트의 연결 배선). D-05, D-06, D-22. **사람 작업:** R2 백업 버킷 전용 토큰 발급 → Infisical `/platform/backup` |
| 완료 기준 | 아래 CLI 없는 동등 절차로 시나리오 2, 3, 4, 8, 9, 10 통과. 첫 base backup `completed`. R2에서 새 클러스터로 복원 성공. 어느 항목도 E7의 CLI를 쓰지 않는다 |
| 검증 방법 | 아래 동등 절차(G의 확인 명령을 `homelab-probe`로). `kubectl -n database get backups`. U26: 복원 시험의 임시 Cluster에서 `bootstrap`을 `initdb`로 바꾸는 변경이 거부되지 않는지 |
| 되돌리는 방법 | revert PR. 데이터 리소스는 보호 주석이 있어 revert로 지워지지 않는다. 클러스터를 다시 만들면 새 serverName. 실패한 복원 시험은 임시 Cluster·PVC 삭제를 확인 |

**E6의 CLI 없는 동등 절차** [제안]: E5의 `homelab-probe`를 이어 쓴다. DB·Valkey 비밀번호는 CLI 대신 사람이 Infisical `homelab`/`prod`의 `/apps/homelab-probe/postgres/PASSWORD`·`/apps/homelab-probe/valkey/PASSWORD`에 직접 만든다(값은 화면·셸 기록에 남기지 않는다). 앱 확인은 E5처럼 port-forward로 `/healthz/db`·`/healthz/cache`를 부른다.

- **시나리오 2:** 손 PR(`data/homelab-probe/values.yaml`에 `postgres.enabled: true`, `apps/homelab-probe/values.yaml`에 `uses.postgres: true`) 병합 → G의 kubectl·`psql` 확인.
- **시나리오 3:** 손 PR(`apps/homelab-probe/values.yaml`에 `cache:`와 `uses.valkey: true`) 병합 → G의 확인.
- **시나리오 4:** G 명령은 CLI를 쓰지 않는다. 복원은 `restore.md`의 C.5.6 절차를 사람이 따른다.
- **시나리오 8:** `homelab db rotate` 대신 `rotate.md`의 DB 비밀번호 순서(C.6.5)를 사람이 따른다 → G의 확인.
- **시나리오 9:** `homelab app remove` 대신 `apps/homelab-probe/`를 지우는 손 PR → G의 kubectl·`psql` 확인. `homelab data list` 대신 `kubectl -n database get database,databaserole`과 `kubectl -n app-homelab-probe get pvc`. 재등록은 그 PR의 revert PR → 표식 행 같음.
- **시나리오 10:** 두 번째 DB는 손 PR `data/homelab-probe2/values.yaml`(DB만). `homelab db restore` 대신 `restore.md`의 C.5.7 단계를 사람이 `kubectl`로 따른다(복원 리소스는 GitOps 밖) → G의 확인.

#### E7 CLI (T12)

| 항목 | 내용 |
|---|---|
| 만들 것 | `cli/`(C.7 명령, `cache restore` 포함), 시험(`plan` 부수효과 0 단언 포함, 필수 `ci`의 `cli` 단계), `bun build --compile` 배포 절차(`cli/build.ts`, `cli/README.md`) |
| 옛 저장소에서 가져올 것 | L01·L02의 쓸 만한 부분(이름 정규식, 실행 seam, Argo CD revision 해석), L12 판정 기준, L48, L50 기법, R37, B.8 "E7" |
| 선행 조건 | E5, E6. 읽기 명령(`doctor`, `status`)은 E5 뒤 먼저 착수 가능. 새 외부 자격 없음 |
| 완료 기준 | 시나리오 5 통과(`homelab-probe`로). `plan` 실행 전후 Git·Infisical·클러스터 상태가 같음(AC-P13). 사람용 출력과 JSON 출력. **CLI 경로 재확인:** C.7의 쓰기 명령(`app add`, `db add`, `cache add`, `secret set`, `db rotate`, `db restore`, `rollback`, `app remove`, `data purge`, `github apply`)과 읽기 명령(`status`, `data list`, `github plan`, `github verify`)을 `homelab-probe`에 한 번씩 실행해 E5·E6 동등 절차와 같은 확인을 통과(시나리오 2·3·8·9·10의 CLI 경로). `homelab github verify`는 래퍼 `tools/tf-github.sh verify`와 같은 종료 코드. `app new`는 `plan`만 보고 실제 생성은 E8 시나리오 1. 끝에 `app remove`·`data purge`로 `homelab-probe`의 등록과 데이터를 지운다 |
| 검증 방법 | 같은 등록 명령 두 번 실행 비교, 중간 실패 뒤 재실행으로 이어지는지, `bun test`, 위 명령별로 E5·E6 동등 절차의 확인 명령 재실행 |
| 되돌리는 방법 | CLI는 로컬 도구라 이전 실행 파일로 돌아간다. CLI가 만든 PR은 닫는다 |

#### E8 테스트 앱 통합 검증 (T13)

| 항목 | 내용 |
|---|---|
| 만들 것 | E7의 CLI로 새로 만드는 시험 앱 `homelab-smoke`(시나리오 1의 `homelab app new`)로 CLI를 쓰는 시나리오를 포함해 1~17 전체 실행(시나리오 1의 공개 URL 확인 포함), VM 재구축과 DB 복구(시나리오 13), 결과표 `platform/verification.md`(이 문서 옆, PR로 main) |
| 옛 저장소에서 가져올 것 | L23의 복구 순서, L45·L46의 확인 항목 |
| 선행 조건 | E4a, E4b, E4c, E5, E6, E7. D-12(VM 방식), D-30(VM의 `vm-go` 실접속은 시나리오 13에서 본다). **사람 작업:** VM 준비(`vm-` 접두 노드 이름, NUC에서 닿는 노드 IP(아래 VM 위치). VM 호스트는 tailnet에 넣지 않는다, C.3.2의 0), VM 격리 설정(아래: VM 값 파일 `host/clusters/vm.env`(노드 이름 `vm-` 접두)·`platform/root/values-vm.yaml` PR(`root-vm.yaml`은 E2가 만들어 둠), VM 전용 R2 버킷·토큰, VM operator OAuth client, 시험 터널·체크·수신자를 `homelab-dev`에, 운영 ExternalSecret 키 목록에 맞춘 나머지 `homelab-dev` 시험 값 채우기와 빠진 키 0 확인(2번), `eso-homelab-dev` client secret 발급과 VM 준비 자산 보관(2번), 복구 자산의 R2 읽기 전용 토큰을 시험 동안만 VM에), 시험 App `ukyi-homelab-bot-standin`을 `homelab-smoke`에도 설치(시나리오 15), NUC 재부팅·네트워크 차단 시험 승인 |
| 완료 기준 | 시나리오 1~17이 모두 "실제 검증 완료"이거나 사용자가 승인한 한계로 기록. AC-P12 다섯 자리와 AC-P11·AC-P8 자리 확인 |
| 검증 방법 | G절 전체. 시나리오 7·13 뒤 복구 자산의 운영 ESO client ID·secret으로 Infisical Universal Auth 로그인 → 성공(토큰은 출력하지 않고 응답 코드만. 시나리오 7의 장애 주입이 운영 secret을 폐기하지 않았음을 확인) |
| 되돌리는 방법 | 시험 앱은 `homelab app remove` 뒤 `homelab data purge`. VM은 폐기하고 VM 전용 R2 버킷과 tailnet의 `vm-*` 기기(VM operator·프록시)를 지우며, `eso-homelab-dev` client secret을 폐기하고, values-vm의 복구 원본은 정리 PR로 지운다 |

**VM 격리** [제안]: VM은 운영과 같은 Git 트리(main)를 따르되, 운영이 쓰는 외부 상태(Infisical 운영 값, 백업 prefix, tailnet 이름, 공개 터널, 감시 체크)에 쓰지 않는다. 옛 두 클러스터가 같은 터널 토큰과 체크를 오염시킨 사고(B.8 E1)와 두 primary의 타임라인 혼합(B.8 E6)을 피한다.

1. **클러스터 값 주입:** 클러스터마다 다른 값은 두 층의 클러스터별 파일에만 둔다. 클러스터 층은 `platform/root/values-prod.yaml`과 `values-vm.yaml`, 호스트 층은 `host/clusters/prod.env`와 `vm.env`(노드 이름·IP, 인터페이스, TLS SAN, C.3.2)다. `platform/root`는 Helm 차트로 둔다[권장, C.3.3]. root Application도 클러스터마다 하나(`root-prod.yaml`, `root-vm.yaml`. 둘 다 E2가 만들고 운영 root는 `root-vm.yaml`을 렌더하지 않는다, C.3.3)이고 각자 자기 values 파일을 `helm.valueFiles`로 읽어, 필요한 값만 구성 요소 Application의 Helm values로 넘긴다. `bootstrap.md`는 처음에 클러스터 이름(`prod` 또는 `vm`)을 하나 고르고, 그 이름으로 host 스크립트의 `--cluster`(C.3.2)와 root apply 파일(C.3.3의 3)을 함께 고른다. 구성 요소 매니페스트와 host 스크립트에는 클러스터 이름 분기를 두지 않고 값 파일만 바꾼다. 클러스터 층에 담는 값: Infisical 프로젝트·환경, CNPG 버킷·serverName·복구 원본, Tailscale hostname 접두(operator 자신의 기기 이름 포함). **시크릿의 키 이름은 클러스터 층 값으로 바꾸지 않는다.** 터널 토큰, 체크 ping URL, Telegram 봇 토큰, R2 토큰, operator OAuth는 운영과 같은 키 이름이고, VM은 프로젝트·환경만 `homelab-dev`/`dev`로 바뀌어 그 키에서 VM 전용 값을 읽는다(3·4·5번). 그래서 VM과 운영의 ExternalSecret 키 목록은 같다(2번의 키 대조가 이에 기댄다). Helm 차트가 아닌 구성 요소(Kustomize·평문 매니페스트)에 클러스터 값을 넘기는 방식(작은 래퍼 차트로 감쌈 등)만 E2에서 `platform/root`를 만들 때 정하고, VM 값 파일 둘(`values-vm.yaml`, `host/clusters/vm.env`)은 E8 전에 채운다. **결정(사용자 2026-10-19, T07, A안):** 클러스터 값이 필요한 구성 요소만 작은 로컬 Helm 차트로 감싸고, root가 필요한 키만 `source.helm.valuesObject`로 넘긴다. 클러스터 값이 없는 구성 요소는 Kustomize·평문 그대로 둔다. 그 차트 안의 ExternalSecret `target.template`의 `{{ }}`는 Helm이 렌더하지 않게 이스케이프한다. 고르지 않은 안: root가 `kustomize.patches`를 값으로 렌더(로컬 렌더와 실제 배포가 달라짐), 클러스터별 overlay(VM 값이 여러 디렉터리로 흩어짐). **VM 프로필 단언(T13):** 운영이 아닌 클러스터의 root 렌더는 접두 `vm-`, Infisical `homelab-dev`/`dev`, 운영과 다른 버킷, 운영과 다른 `pg-vm-<YYYYMMDD>`가 아니면 실패하고, `root-<클러스터>`가 이름이 다른 값 파일을 읽어도 실패한다(`platform/root/templates/cluster-check.yaml`, 음성 시험 `tools/ci/fixtures/root/`). 운영 렌더는 바뀌지 않는다.
2. **Infisical:** VM의 ESO는 프로젝트 `homelab-dev`(환경 `dev`)를 VM 전용 identity `eso-homelab-dev`으로만 읽는다. VM의 부트스트랩 Secret에는 그 identity의 자격만 넣는다. 이 identity는 `homelab` 프로젝트에 들어가지 않으므로, 설정이 실수로 운영 프로젝트를 가리켜도 VM은 운영 값을 읽지 못한다(C.6.3).
   - **VM 준비 자산:** `eso-homelab-dev`(E3에서 identity만 만듦)의 Universal Auth client secret은 E8 사람 작업에서 VM을 준비할 때 발급하고, 저장소 밖에 복구 자산과 따로 표시한 항목(예: 비밀번호 관리자의 "VM 시험" 항목)으로 둔다. VM의 부트스트랩 Secret은 이 값으로 만들고(C.3.3 vm 분기), VM 폐기 때 Infisical에서 이 client secret을 폐기한다.
   - **`homelab-dev` 키 채우기:** VM은 운영과 같은 Git 트리를 따르므로 운영 ExternalSecret이 읽는 키가 `homelab-dev`의 같은 경로에 모두 있어야 한다. 빠지면 그 ExternalSecret이 `SecretSyncedError`로 멈추고 구성 요소·앱이 뜨지 않는다. 사람이 VM bootstrap 직전에 운영 클러스터(main을 동기화한 결과)에서 키 목록을 뽑는다(클러스터 층 값은 키 이름을 바꾸지 않으므로 VM이 읽을 목록과 같다, 1번. 예: `kubectl --context <운영 context> get externalsecret -A -o json \| jq -r '.items[] \| .spec.secretStoreRef.name as $s \| .spec.data[]? \| "\($s) \(.remoteRef.key)"' \| sort -u`. 키 이름만 나온다). store마다 `secretsPath`를 붙인 같은 경로에 시험 값을 `homelab-dev`/`dev`로 채운다. 운영과 같은 키 이름에 VM 전용 값을 넣는 키(시험 터널 토큰, 시험 체크 ping URL, 시험 Telegram 봇 토큰, VM 전용 R2 토큰, VM operator OAuth)는 위 3·4·5번의 값이고, 그 밖의 키(Grafana·AdGuard·Argo CD 관리자 자격, `homelab-smoke`의 앱 키·DB·Valkey 비밀번호 등)는 새 시험 값이다. 운영 값을 복사하지 않는다. 확인은 값 없이 키 이름만 비교한다(`homelab-dev`에서 경로별 키 이름만 뽑아 위 목록과 `comm -23`으로 대조 → 빈 결과). 같은 대조를 `bootstrap.md` vm 분기의 첫 단계로 다시 한다(C.3.3).
3. **백업 버킷과 serverName:** VM의 CNPG는 VM 전용 R2 버킷(예: `homelab-backups-vm`, 시험 때 사람이 만들고 VM 폐기 때 지움)과 VM 전용 serverName(`pg-vm-<YYYYMMDD>`)으로만 아카이브한다. 그 버킷 전용 Object Read & Write 토큰은 `homelab-dev`에 둔다. 그래서 VM에는 운영 버킷에 쓰는 자격이 없다. 같은 Git 트리를 따라도 운영 serverName·버킷이 values-prod에만 있어 VM이 운영 prefix에 아카이브하지 않는다. 운영 아카이브는 시나리오 13의 복구 원본으로만 쓴다: values-vm의 복구 원본을 운영 serverName으로 하는 복구 PR을 VM root apply 전에 병합하고(C.6.4와 같은 순서), 원본 ObjectStore의 자격은 복구 자산의 R2 읽기 전용 토큰으로 VM에 손으로 넣는 Secret 하나다(Infisical에 두지 않음, `bootstrap.md`의 "다른 클러스터에서 복구" 단계로 적음). 이 토큰은 운영 아카이브를 바꿀 수 없다. VM은 운영 DB 사본을 갖게 되므로 시험 뒤 VM을 폐기하고, 정리 PR로 values-vm의 복구 원본을 지운다. 복구 동안 VM 앱·영속 Valkey는 공용 values가 아니라 values-vm의 `cluster.restore`로 멈춘다(C.6.4). **[미검증] U27:** 읽기 전용 토큰으로 plugin 복구가 되는지.
4. **Tailscale 이름:** VM의 operator Ingress는 hostname 접두 `vm-`(예: `vm-argocd`)를 쓰고, operator 자신의 기기 이름(차트 `operatorConfig.hostname`, 기본 `tailscale-operator`. `tailscale/tailscale@9a522a9:cmd/k8s-operator/deploy/chart/values.yaml:84`, v1.104.1 태그, `gh api 'repos/tailscale/tailscale/contents/cmd/k8s-operator/deploy/chart/values.yaml?ref=v1.104.1'`로 확인)도 `vm-tailscale-operator`로 둔다. VM operator의 OAuth client도 따로 발급해 `homelab-dev`에 둔다. 같은 tailnet에서 이름이 겹치면 뒤에 등록된 기기에 `-1`이 붙고, 앞 기기를 지워도 되돌아가지 않아 콘솔에서 이름을 손으로 바꿔야 한다(`2d2054a:platform/tailscale/prod/traefik-ingress.yaml:12-15`). 접두로 운영 이름(`argocd`, `grafana`, `adguard`, `tailscale-operator`)을 건드리지 않는다. **VM 호스트는 tailnet에 넣지 않는다**(D-12, 확정(사용자 2026-10-18, T05)). 사람이 로그인해 넣으면 태그 없는 사용자 기기가 되어, 운영자 규칙(`tag:nuc:22,6443`)과 `autogroup:member → autogroup:self:*`(C.3.5)로 VM 호스트 프로세스(hostNetwork 파드 포함)가 운영 NUC의 SSH·kubectl 포트와 사람 기기 전체에 닿는다. 운영 DB 사본과 시험 자격이 올라간 VM에서 운영 노드와 운영자 기기로 가는 길이 새로 열리는 셈이다. 그래서 `vm.env`는 `TAILNET_JOIN=false`이고, host 스크립트는 이 값으로 Tailscale 단계와 SAN의 MagicDNS 이름을 건너뛴다(C.3.2의 0, 값으로 가르는 것이라 클러스터 이름 분기가 아니다). VM 접근은 노드 IP(`vm.env`, TLS SAN에 있음)나 콘솔로 한다. VM operator가 만드는 `vm-*` 기기는 운영 NUC에 닿지 못한다(추측: 이 기기는 태그 기기(`tag:k8s-operator`, `tag:k8s`)이고 태그 기기는 사용자 신원이 없어[S184] `autogroup:member`·`autogroup:self`에 들지 않으며, 이 ACL에는 그 태그를 src로 둔 규칙이 없어 기본 거부다[S117]). 검토 후 제외한 대안(VM 호스트를 `tag:vm`으로 등록)은 F D-12. **C.6.4 복구 순서의 "옛 클러스터 operator·프록시 기기(`tag:k8s-operator`, `tag:k8s`) 삭제" 단계는 VM 시험에서 건너뛴다.** 그 시점의 이 태그 기기는 운영 클러스터의 것이라, 지우면 운영 operator와 내부 UI 프록시가 tailnet에서 빠진다. 시험 뒤에는 VM operator·프록시 기기(`vm-*`)만 콘솔에서 지운다. 별도 tailnet은 검토 후 제외한 대안이다(F D-12).
5. **공개 터널·감시·알림:** 시험 터널(별도 토큰), 시험 healthchecks 체크, 시험 Telegram 수신자(시험 봇 토큰)를 쓰고 값은 운영과 같은 키 이름으로 `homelab-dev`에 둔다(1번). 운영 터널 토큰과 체크 ping URL은 VM에 없다. **VM은 운영 공개 URL을 쓰지 않는다.** VM은 같은 Git 트리를 따라 Ingress host가 운영과 같고(`smoke.ukyi.app`), 와일드카드 DNS는 운영 터널을 가리킨다(C.3.4). 그래서 VM에서 `curl https://smoke.ukyi.app`을 부르면 운영 앱이 답해 VM이 고장이어도 통과한다(거짓 PASS). VM의 공개 경로는 두 가지로 직접 확인한다. (a) 시험 터널 연결: VM의 cloudflared `/ready` 200과 메트릭 `cloudflared_tunnel_ha_connections`(활성 연결 수[S177]) 1 이상. (b) Traefik 라우트: `kubectl --context homelab-vm -n traefik port-forward svc/traefik 18081:80` 뒤 `curl -sf -H 'Host: smoke.ukyi.app' http://127.0.0.1:18081/healthz` → 200, 없는 host → 404. 운영 DNS 레코드를 VM용으로 바꾸지 않고, 시험 터널에는 DNS 레코드를 만들지 않는다. 인터넷에서 VM까지 실제로 닿는지 보는 검토 후 제외한 대안은 F D-12다.
6. **kubeconfig:** context를 `homelab-vm`으로 각인한다(B.8 E2).

**VM 위치(사용자 2026-10-26, NUC 임시 VM. 네트워크 lead 2026-10-26):** 다른 기기 대신 NUC의 임시 KVM VM(시험 뒤 삭제)이고, 네트워크는 NUC 본체 브리지를 바꾸지 않는 libvirt NAT다. 그래서 운영자 기기가 LAN으로 VM에 닿지 않고, 운영자 확인(SSH, `homelab-vm` kubeconfig, port-forward)은 NUC에서 한다. NAT 출구를 NUC의 LAN 인터페이스로 묶어 VM 트래픽이 NUC의 tailscale0로 나가 NUC의 tailnet 신원(`tag:nuc`)을 쓰지 않게 한다. 만들기·지우기는 `docs/runbooks-public/vm.md`.

#### E9 첫 실제 앱(봇)의 플랫폼 쪽 준비와 첫 배포 (T16b, 선행 T13·T14·T15)

| 항목 | 내용 |
|---|---|
| 만들 것 | CLI로 봇 등록(`apps/homelab-bot/`, `data/homelab-bot/`), Infisical `/apps/homelab-bot/`(게시 서버)와 `/apps/homelab-bot/worker`(작업자) 분리, 시험 수신기를 봇으로 교체, Alertmanager 봇 라우트 켬, 격리 공간에 작업자 배치(상주 파드 하나, 동시성 1, D-15), 작업자가 영속 공간에 `auth.json`이 없을 때 Infisical `/apps/homelab-bot/worker`의 첫 시드를 복사(D-14, C.8 격리 행), egress 허용 목록에 구독 인증이 쓰는 모델·인증 호스트를 실측으로 넣음(코드 읽기는 E4b의 `codeload.github.com`만 그대로), 봇 자리 Application(C.8)의 사람 PR(`image.yaml` 밖이라 자동 병합 대상 아님): `target`을 봇 ns `app-homelab-bot`, 라벨 `homelab-bot`, 작업자 포트 8080, 경보 수신 포트 8081(D-15)로 바꾸고 `probe: false`로 시험 ns와 손으로 옮긴 정책을 지운다. 이 값 하나로 봇 쪽 정책의 대상과 sandbox ingress의 출처, SA `bot-reader`의 ns가 함께 바뀐다. 봇 등록 PR보다 먼저 병합한다(아래 콜드스타트 순서 재현). 봇 values에 `serviceAccountName: bot-reader`(C.4.5)와 `port: 8080`. 봇 리뷰 App(D-16)과 쓰기 App(D-24)은 여기서 만들지 않는다: 리뷰 App은 T17, 쓰기 App은 T19에서 사람이 만들고 설치한다(V1 단계별 시범 운영, D-24의 App 이름·설치 저장소는 T19) |
| 옛 저장소에서 가져올 것 | 없음(교훈은 C.8에 반영됨) |
| 선행 조건 | E8(T13) 완료, D-13 확정(사용자 2026-10-18, T14. 저장소 `ukyi-app/homelab-bot`, 앱 이름 `homelab-bot`. 가시성은 D-29로 public), T15 결정(D-14~D-17, D-24. 확정(사용자 2026-10-18, T15)). T16은 T16a(FOUNDATION 로컬·mock)와 T16b(실연동·첫 배포)로 나뉘었고 이 단계는 T16b다(E.0). **사람 작업:** 봇 저장소는 T14가 만든 것을 쓴다(C.8 봇 저장소. 여기서 만들지 않는다). 등록은 `homelab app add homelab-bot`이고, 봇 저장소 워크플로를 템플릿의 `build.yaml`(`app-build@<태그>` 호출)로 맞추는 PR을 먼저 병합한다. 봇 전용 개인 Discord 서버·봇 계정(D-17. 실제 서버·채널·사용자 ID는 Infisical `/apps/homelab-bot/`에만), 봇 전용 ChatGPT 구독 계정 준비와 `auth.json` 첫 시드의 Infisical `/apps/homelab-bot/worker` 등록(D-14. 개인 `~/.codex*`는 쓰지 않는다. 시점은 T16b 전(모델을 처음 쓰는 단계 전)이다. 대화 레인이 모델을 써서 이 단계가 처음이다. 이 시점은 에이전트 정리다, spec §11), 첫 배포 승인 |
| 완료 기준 | 봇에 대해 시나리오 1 통과(두 번째 커밋 자동 병합 포함)와 AC-B3 증거. 봇 저장소가 public이고 보안 설정(D-29)이 켜져 있으며, 운영 산출물(evidence, handoffs, runtime-policies 실제 값 등)이 저장소에 없음(C.8 봇 저장소). C.8 표 명령을 실제 봇으로 다시 통과(작업자 egress가 `codeload.github.com`과 모델·인증 호스트만 허용하고 `github.com`·`api.github.com`·`gist.github.com`을 거부, 작업자 파드를 다시 만든 뒤에도 영속 공간의 `auth.json`이 시드로 덮이지 않음). 봇 자리 Application의 콜드스타트 순서 확인 통과. Alertmanager 봇 route를 켠 뒤(Telegram 형제 route 함께, C.3.7) 봇이 정상일 때와 replicas 0일 때 모두 시험 경보가 Telegram에 도착 |
| 검증 방법 | 시나리오 1 명령, C.8 표 명령을 실제 봇(실제 차트 렌더)으로 다시. **콜드스타트 순서(C.8 봇 자리 Application):** (1) 렌더: `helm template root platform/root -f platform/root/values-prod.yaml \| yq -N 'select(.kind == "Application") \| .metadata.name + " " + (.metadata.annotations."argocd.argoproj.io/sync-wave" // "0")' \| sort -k2 -n \| tail -2` → 마지막 줄이 `bot-slot 1`이고 그 앞 줄의 wave는 0 이하(뒤 wave 없음), 같은 렌더에서 `bot-slot`의 `spec.syncPolicy`에 `CreateNamespace=true`가 없고 `retry.limit`이 `-1`, `retry.refresh`가 `true`. (2) 재현: 빈 클러스터에서 생기는 "봇 ns보다 봇 자리가 먼저 sync되는" 조건을 `target` 변경 PR을 봇 등록 PR보다 먼저 병합해 운영에서 만든다 → `kubectl -n argocd get application bot-slot -o jsonpath='{.status.operationState.phase} {.status.operationState.message}'`가 phase `Running`이고 메시지에 `namespaces "app-homelab-bot" not found`와 `Retrying attempt`가 있음(무제한 재시도라 Failed가 되지 않는다), root·`bot-slot` 밖의 Application은 Synced·Healthy 그대로 → 봇 등록 PR 병합(ArgoCDAppDegraded 30분 경보 전에) → backoff 상한 5분 안팎에 `bot-slot` Synced·Healthy, SA `bot-reader`가 생긴 뒤 봇 파드 Ready. 재현은 root의 wave 진행을 다시 거치지 않으므로 (1)과 함께 본다 |
| 되돌리는 방법 | `homelab app remove homelab-bot`(데이터 보존)과 봇 자리 `target`을 E4b~E8의 시험 값으로 되돌리고 `probe: true`를 함께 켜는 PR(C.8). T17·T19 뒤라면 App 설치 해제 |

#### E10 기존 앱 재연결 (T22)

| 항목 | 내용 |
|---|---|
| 만들 것 | 재연결할 앱 저장소의 워크플로를 `app-build@<태그>` 호출로 바꾸고 SealedSecrets 산출물·main 스키마 받기를 지움. 남는 앱 저장소는 `files` 하나다(`page`·`trip-mate-api`는 2026-10-18에 삭제해 재연결 대상이 아니다, 0절 7항). `CODEOWNERS`(`* @<owner 계정>`)와 main ruleset `app-main`은 결정 5 하드닝과 E5의 `app-repos.json`으로 이미 걸려 있다(`CODEOWNERS`가 없거나 깨졌거나 규칙의 `require_code_owner_review`·`dismiss_stale_reviews_on_push`가 `true`가 아니면 조건 9로 자동 병합되지 않음, C.4.7). CLI로 등록. 재연결하지 않는 앱 저장소는 보관하거나 지운다. 비앱 저장소 처리(D-29): `aiops` 저장소와 옛 aiops App은 교훈을 추린 뒤 삭제, `aiops-autodeploy-canary` 저장소는 공개하지 않고 private 보관(삭제도 가능), `mac-uptime-guard`는 제거. `mac-uptime-guard` 순서: 저장소 밖 장치 끄기 → 옛 Telegram 봇 토큰 폐기와 옛 봇 삭제(T06 자격 폐기 표의 `보류(D-10, T22)` 행 닫기. D-10은 새 봇으로 확정(사용자 2026-10-18, T05)) → 저장소 삭제 |
| 옛 저장소에서 가져올 것 | 0절의 저장소별 의존 목록, L04·L15의 사본 위치 |
| 선행 조건 | 준비는 E8 뒤, 실제 배포는 E9 뒤. D-18, D-21, D-29. **사람 작업:** 대상 선택, `mac-uptime-guard` 장치 끄기, 저장소 보관·삭제·App 정리 승인 |
| 완료 기준 | 재연결한 앱마다 시나리오 1 전체와 `homelab github verify` 차이 없음(`CODEOWNERS` 존재, `codeowners/errors` 빈 결과, code owner 리뷰·승인 무효화 규칙 포함). 앱 저장소는 public만이라(D-29) private 앱 기준은 없다. `page`·`trip-mate-api` 저장소와 패키지가 404(0절 7항이 실행됐는지). `aiops`·`mac-uptime-guard`가 404이고 `aiops-autodeploy-canary`는 private(지웠으면 404). 처리한 저장소·App마다 approvals 기록. T06 자격 폐기 표의 옛 Telegram 봇 토큰 행이 닫힘(`mac-uptime-guard` 장치를 끈 뒤 폐기) |
| 검증 방법 | 시나리오 1 명령, `gh api repos/ukyi-app/<repo> --jq '.visibility, .archived'`, `gh api orgs/ukyi-app/installations`, 지운 저장소·패키지는 `gh api repos/ukyi-app/<repo>`와 `gh api orgs/ukyi-app/packages/container/<패키지>` → 404 |
| 되돌리는 방법 | 앱 저장소 PR revert, `homelab app remove` |

### E.2 단계와 티켓(T06~T13)의 대응, 재분해 (T05에서 적용, 2026-10-18)

이 표가 T05의 재분해 기준이다(spec §4.4, §12). T05가 2026-10-18에 이 표대로 T06~T13을 고쳤다. T08은 [T08a](../issues/T08a-network.md)와 [T08b](../issues/T08b-observability.md)로 나눴고 옛 T08 티켓 파일은 지웠다. 둘째 열은 재분해 전 티켓이다. E9·E10 행은 P2 밖 티켓(T16, T22)이다. E9 내용(봇 자리 `target` 변경 PR과 콜드스타트 순서 확인)은 T16 티켓에 넣었다. T15 결정으로 T16이 T16a·T16b로 나뉘어 E9는 T16b가 맡는다(E.0). E10 내용은 T22에 있고, `mac-uptime-guard` 장치 끄기, 옛 Telegram 봇 토큰 폐기와 옛 봇 삭제, 저장소 삭제는 T22 할 일 7이다.

| 단계 | 재분해 전 티켓 | 재분해 (T05에서 적용) | 이유 |
|---|---|---|---|
| E1 | T06 | 그대로. 정리 목록에 0절의 새 사실(저장소 auto-merge 허용, environment 4개, Codex Connector 권한)을 더한다. 보호 해제와 같은 단계에 임시 ruleset `main-interim`과 `allow_auto_merge=false`를 넣고 옛 브랜치 보호는 `main-interim` active 확인 뒤 DELETE하고 404를 본다(`gh api`, `main-interim`은 E5에서 import). 자격 폐기 표에 `page`·`trip-mate-api`의 옛 자격 행을 넣는다(D-29). 자격 폐기 표의 옛 Telegram 봇 토큰 행은 `보류(D-10, T22)`로 두고 이 티켓에서 폐기하지 않는다(D-10 확정(사용자 2026-10-18, T05): 새 봇. 옛 봇 토큰 재발급 대안은 고르지 않아 T09가 이 행을 닫는 분기는 쓰이지 않는다). 옛 healthchecks ping URL 행은 `보류(D-10, T08b)`로 두고, T08b가 새 체크 초록 확인 뒤 옛 체크를 지우며 닫는다 | 범위 일치. E5까지 main이 열리지 않게 한다. `mac-uptime-guard` 알림이 T22 전에 조용히 끊기지 않게 한다 |
| E2 | T07 | 그대로. 재분해 전 할 일 7(Argo CD 읽기 전용 계정)은 E4b(T08b)로 옮기고, 최소 `ci.yaml`과 main 교체 뒤 `ci` 필수 검사를 넣는다 | 읽기 전용 계정 셋을 한 단계에서 함께 확인한다. main 교체 직후부터 시크릿 유출 검사가 돌고 병합 조건이 된다 |
| E3 | T09 | 그대로. 첫 작업으로 배포 키 OIDC 확인을 넣는다. identity는 4개다(D-04). 완료 기준의 시나리오 6·7은 E3 범위(E3 표 아래 동등 절차, 시험 Application `e3-probe`)로 좁히고, 경보·Telegram은 T08b, 배포 PR 자동 병합 흐름은 T10, `homelab status`는 T13으로 보낸다 | C.4.8의 방식 결정이 E5를 좌우한다. T09 완료가 T08b·T10·T12를 기다리지 않게 한다 |
| E4a, E4b | T08 | **T08을 둘로 나눈다**: T08a 네트워크·DNS·외부 공개, T08b 관측·알림·봇 자리. T08b 완료 기준에 시나리오 6·7의 경보 부분과 T06 표의 옛 healthchecks ping URL 줄(`보류(D-10, T08b)`) 닫기를 넣고, C.8 읽기 전용 접근의 CI 검사(L30) 줄은 전체 `ci`를 만드는 T10에서 본다 | 결정이 다르고(D-08·D-11 대 D-09·D-10·D-15 입력), 완료 시나리오가 다르며(14 대 16·17), T08b는 T08a의 일부 경로만 기다린다 |
| E4c | 없음(2026-10-20 추가) | T08c를 새로 둔다(D-30). 선행은 T08a, T13이 기다린다 | `go` 리다이렉터는 T08a의 operator·ACL 경로 위에 얹는 작은 단계다. VM의 `vm-go` 실접속은 E8 시나리오 13에서 본다 |
| E5 | T10 | 그대로. 손 등록용 시험 앱 저장소(`homelab-probe`) 생성과 `infra/github` Terraform root와 CLI와 독립된 래퍼 `tools/tf-github.sh`, 병합 키 Secret Sync, ci의 workflow-guard를 넣는다(D-04, D-28). 결정 5 하드닝이 건 `app-main` import, 앱 저장소 보안 설정, GHCR 패키지 가시성 시험(U39)도 넣는다(D-29). 완료 기준은 CLI 없는 동등 절차(E5 표 아래, 시나리오 7의 배포 흐름 부분 포함)이고 공개 URL 확인은 T13으로 보낸다. 간선 T09 → T10은 "완료" 간선으로 두고 착수는 T07 뒤 병행한다(C.4.8) | C.4.8의 답. T10 완료가 T12(CLI)나 T08a(공개 경로)를 기다리지 않게 한다 |
| E6 | T11 | 선행을 T08a·T09·T10으로 바꾼다(재분해 전에는 T08·T09). 완료 기준은 CLI 없는 동등 절차(E6 표 아래) | cert-manager·R2 버킷은 T08a, 연결 배선과 배포 흐름은 T10. 관측(T08b)은 선행이 아니다. T11 완료가 T12를 기다리지 않게 한다 |
| E7 | T12 | 그대로. 읽기 명령은 T10 뒤 먼저 착수 가능. 완료 기준에 CLI 경로 재확인(`homelab-probe`)을 넣는다 | E5·E6이 CLI 없이 확인한 것을 CLI로 다시 본다 |
| E8 | T13 | 그대로. 선행에 T08a·T08b(2026-10-20부터 T08c도). CLI로 새로 만든 `homelab-smoke`로 시나리오 1~17 전체(공개 URL 포함) | |
| E9 | T16 | T16 할 일에 플랫폼 쪽 준비(E9 표)를 명시. 봇 자리 Application의 `target` 변경 PR(봇 등록 PR보다 먼저)과 콜드스타트 순서 확인을 넣는다. T15 결정(V1 범위 조정 안 3, 확정(사용자 2026-10-18, T15))으로 T16은 T16a(FOUNDATION 로컬·mock, T15 뒤 바로 착수)와 T16b(실연동·첫 배포, T13 뒤)로 나뉘고, E9는 T16b다 | 봇 ns는 앱 Application이 만들므로 그보다 뒤 wave의 봇 자리가 콜드스타트에 수렴하는지 운영에서 본다(C.8) |
| E10 | T22 | 그대로. 할 일에 `mac-uptime-guard` 장치 끄기 뒤 옛 Telegram 봇 토큰 폐기와 옛 봇 삭제를 더한다(T06 자격 폐기 표의 `보류(D-10, T22)` 행을 닫음). 비앱 저장소 처리(D-29: `aiops` 저장소·App과 `mac-uptime-guard` 저장소 삭제, `aiops-autodeploy-canary` private 보관. `mac-uptime-guard`는 2026-10-18 17:46 사용자 결정으로 private 보관에서 제거로 바뀌었다)를 넣고, `page`·`trip-mate-api` 재연결은 지운다(2026-10-18 삭제, 0절 7항). 완료 기준은 재연결한 앱마다 시나리오 1 전체다(앱 저장소는 public만이라 private 앱 기준은 없다) | D-10, D-20, D-29. E1과 E3은 이 행을 닫지 않는다. D-10이 새 봇으로 확정(사용자 2026-10-18, T05)돼 E3이 닫는 대안 분기(옛 봇 재사용)는 쓰이지 않는다 |

P2 의존성(T05가 2026-10-18에 spec §8.2에 적용): `T06 → T07`, `T07 → T09`, `T07 → T10`(착수), `T09 → T10`(완료), `T08a → T10`(`infra/github` 첫 apply만, R2 잠금 시험 U02 뒤), `T07 → T08a`, `T09 → T08a`, `T08a → T08b`, `T09 → T08b`, `T08a → T11`, `T09 → T11`, `T10 → T11`, `T10 → T12`, `T11 → T12`, `T08a → T13`, `T08b → T13`, `T10 → T13`, `T11 → T13`, `T12 → T13`. 2026-10-20 D-30으로 `T08a → T08c`, `T08c → T13`을 더했다. 순환은 없다(T06 → T07 → T09 → T08a → T10 → {T08b, T11} → T12 → T13의 위상 순서가 있다. T10 착수는 T07 뒤 병행하고, `infra/github` 첫 apply는 T08a 뒤다).

완료 기준이 쓰는 산출물도 같은 방향만 가리킨다(간선마다 "완료 기준이 쓰는 것 ← 만드는 단계"):

| 단계 | 완료 기준이 쓰는 것 | 만드는 단계 | 간선 |
|---|---|---|---|
| T06 | 정리 목록·자격 폐기 표, 임시 ruleset `main-interim`과 그 bypass 시험 | T06 자신 | 없음 |
| T07 | 임시 ruleset 아래의 rebuild → main 병합 | T06 | `T06 → T07` |
| T07 | `host/`, `bootstrap.md`, Argo CD, 최소 `ci`, 재부팅 복귀(시나리오 12의 k3s·Argo CD 범위), 자기 저장소 참조 revision의 손 확인 명령(L31의 내용. T10의 전체 `ci`에 생기는 L31 검사는 쓰지 않는다) | T07 자신 | 없음 |
| T09 | Argo CD·root·`argocd-cm`(ExternalSecret health 덮어쓰기 자리), 다시 켠 Actions(OIDC 시험 워크플로) | T07 | `T07 → T09` |
| T09 | ESO·ClusterSecretStore, 시험 Application `e3-probe`와 손 PR(시나리오 6·7의 E3 범위), 복구 자산, T06 표의 `보류(…, T09)` 줄 | T09 자신(T06의 표는 T07을 거쳐 앞) | 없음 |
| T08a | 터널 토큰·operator OAuth의 ESO 전달 | T09 | `T09 → T08a` |
| T08a | Argo CD | T07 | `T07 → T08a` |
| T08b | Grafana 내부 Ingress용 Tailscale operator, AdGuard Home과 U32 출처 결과(이탈 감시) | T08a | `T08a → T08b` |
| T08b | Telegram 토큰·healthchecks URL의 ESO 전달, 시나리오 6·7 경보 부분의 ExternalSecret·ESO | T09 | `T09 → T08b` |
| T08b | T06 표의 옛 healthchecks ping URL 줄 `보류(D-10, T08b)`(새 체크 초록 확인 뒤 옛 체크 삭제로 닫음) | T08b 자신(새 체크. T06의 표는 T07·T09를 거쳐 앞) | 없음 |
| T08b | 봇 자리 Application(시험 ns `bot-slot-probe`, C.4.5 네트워크 행을 손으로 옮긴 정책, SA `bot-reader`) | T08b 자신(T10의 공유 차트는 쓰지 않음, C.8) | 없음 |
| T08c | Tailscale operator·ProxyClass, ACL root(`infra/tailscale`) | T08a | `T08a → T08c` |
| T10 | Infisical 프로젝트·배포 OIDC identity, R2 state 자격(`homelab-admin`), 시나리오 7 배포 흐름 부분의 ESO | T09 | `T09 → T10`(완료) |
| T10 | R2 state 첫 사용과 잠금 시험(U02) | T08a | `T08a → T10`(`infra/github` 첫 apply만, E.0) |
| T10 | 손 등록 PR, `infra/github` Terraform root와 래퍼, 병합 키 sync, `homelab-probe`, 전체 `ci`(C.8 읽기 전용 접근 줄의 CI 검사 L30 포함) | T10 자신 | 없음 |
| T11 | cert-manager, R2 버킷 | T08a | `T08a → T11` |
| T11 | 앱 차트 연결 배선, `homelab-probe` 등록 | T10 | `T10 → T11` |
| T11 | 플랫폼 시크릿 전달 | T09 | `T09 → T11` |
| T12 | E5·E6 동등 절차의 확인 대상 | T10, T11 | `T10 → T12`, `T11 → T12` |
| T13 | 공개 URL(시나리오 1), 관측·경보(16·17), CLI, `go` 리다이렉터(시나리오 13의 `vm-go`) | T08a, T08b, T08c, T12 | `T08a → T13`, `T08b → T13`, `T08c → T13`, `T12 → T13` |

위 표는 T06~T13의 모든 단계를 다시 나열한 것이다. 각 행의 "만드는 단계"는 그 단계 자신이거나 위 P2 의존성의 앞 단계다. T09의 완료 기준은 경보(T08b), 배포 PR 흐름(T10), `homelab status`(T12)를 쓰지 않는다(E3 표 아래 동등 절차). T08b는 T10의 전체 `ci`도 공유 차트도 쓰지 않는다(L30 줄은 T10이 보고, 봇 자리 시험 ns의 정책은 손으로 옮긴 것이다). T10·T11의 완료 기준은 T12의 CLI도, T08a의 공개 경로(T10)도, T13의 산출물도 쓰지 않는다. 그래서 뒤 단계로 향하는 완료 의존은 없다.

### E.3 봇 자리와 병합·알림 자리별 담당 단계

| 자리 | AC | 담당 단계 (티켓, T05에서 적용) | 재분해 전 잠정 배정과 비교 |
|---|---|---|---|
| 공개 HTTPS webhook 수신 경로 | AC-P12 | E4a (T08a) | 같음(T08) |
| 읽기 전용 접근: Kubernetes·관측 | AC-P12 | E4b (T08b) | 같음(T08) |
| 읽기 전용 접근: Argo CD | AC-P12 | E4b (T08b) | **변경**(T07 → T08b). 세 계정을 한 단계에서 확인 |
| 경보 외부 수신자 | AC-P12 | E4b (T08b) | 같음(T08) |
| 격리 작업 실행 공간 | AC-P12 | E4b (T08b). 작업자 전용 ClusterSecretStore와 DNS 없는 egress(프록시 고정 ClusterIP), 작업자 영속 공간(D-14)과 `codeload.github.com`만 여는 허용 목록(D-15)까지. 실제 인증 시드와 모델 호스트는 E9(T16b) | 같음(T08) |
| 리뷰 전용 App 저장소별 설치 구조 | AC-P12 | E5 (T10) | 같음 |
| 병합 조건 공개 | AC-P8 | E5 (T10) | 같음 |
| 봇 변경 PR의 자동 병합 차단 | AC-P8 | E5 (T10, 시험 신원), 실제 신원은 T19 | 같음 |
| 비AI 알림 경로 | AC-P11 | E4b (T08b) | 같음(T08) |
| 외부 생존 감시 | AC-P11 | E4b (T08b) | 같음(T08) |

모든 자리의 최종 확인은 E8(T13)이다. T05가 2026-10-18에 이 배정을 spec §4.4·§9와 각 티켓에 적용했다. 넷째 열의 T08은 재분해 전 티켓이다.

---

## F. 결정이 필요한 사항

design-prompt §10-F 목록 전부다. 각 결정에 선택지, 권장 기본값, 이유를 적고, spec §5.3 추천과 다르면 **조정 권고**로 표시했다. 끝의 "추가 확인"은 T05가 확인할 설계 기본값이었다. D-04·D-08·D-28·D-29는 사용자가 2026-10-18에 따로 확정했다. D-30은 2026-10-20에 따로 확정했다. 나머지 결정과 "추가 확인"은 같은 날 사용자가 T05 질문에 답해 모두 이 문서의 권장대로 확정했다(확정(사용자 2026-10-18, T05)). 확정한 결정은 "권장"을 "결정"으로 바꾸고 이유·대가·검토 후 제외한 안은 남겼다. 봇 결정 게이트 D-14~D-17·D-24는 T15에서 확정했고(확정(사용자 2026-10-18, T15)), 이 설계에 주는 변경만 끝의 "봇 결정(T15)"에 둔다.

### D-04 Infisical 요금제와 머신 계정

**확정(사용자 2026-10-18).** Infisical Cloud Free, identity 4/5. 병합 App 키는 identity 대신 Secret Sync로 homelab environment `automerge`에 사본 하나를 둔다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **Free (확정)** | 비용 0. identity 5개(사람 포함), 프로젝트 무제한, 환경 3, sync 10[S01] | RBAC(경로 제한), 버전 이력·PITR, 감사 로그, IP 허용 목록 없음[S01][S03][S05] |
| Pro | RBAC, 버전 이력·PITR, 감사 로그 30일, IP 허용 목록 | identity당 월 $20(연간)/$23(월간), 이 설계(identity 4개)면 월 $80~92[S01] |

Free 안에서 키 전달과 identity 배분:

| 안 | identity | sync | 판정 |
|---|---|---|---|
| 배포 키·병합 키 모두 OIDC(원안) | 5/5(여유 0) | 0 | 검토 후 제외. 여유가 없고 병합 쪽 OIDC claim(reusable이 아닌 워크플로의 `job_workflow_ref`)도 미확인이었다 |
| **병합 키만 environment sync, 배포 키는 OIDC** | **4/5** | **1/10** | **확정** |
| 배포 키도 앱별 environment sync | 3/5 | 1 + 앱 수(앱 9개까지) | 검토 후 제외(아래) |
| 배포 PR 생성을 homelab으로 옮김(schedule 감지, 또는 webhook 중계) | 3/5 | 2~3 | 검토 후 제외(아래) |
| 위 어느 것 + VM identity 제거 | 하나 더 줄어 최소 2/5 | 같음 | 검토 후 제외(아래) |

- **결정:**
  - identity 넷: 사람, `eso-homelab`(Universal Auth, `homelab`, 운영 ESO), `eso-homelab-dev`(Universal Auth, `homelab-dev`, VM 시험 ESO), `gha-homelab-deploy`(OIDC, `homelab-ci-deploy`, 배포 App 키). `gha-homelab-merge`는 만들지 않는다.
  - 프로젝트 다섯: `homelab`(`prod`, 운영 값), `homelab-dev`(`dev`, 로컬 개발·VM 검증 값), `homelab-admin`(`prod`, Terraform 자격, machine identity 없음), `homelab-ci-deploy`(`prod`, 배포 키), `homelab-ci-merge`(`prod`, 병합 키, machine identity 없음). 개발·운영 분리는 프로젝트 단위로 유지한다.
  - 병합 App 키: 원본은 Infisical 프로젝트 `homelab-ci-merge`. Infisical Secret Sync(GitHub, Scope Repository Environment: `ukyi-app/homelab` / `automerge`)로 사본 1개. App Connection은 GitHub App이 아니라 homelab 하나로 좁힌 fine-grained PAT(Metadata read, Environments RW, Secrets RW, 만료 없음: 사용자 2026-10-21)다. Auto-Sync 켬, Key Schema 비움, 삭제 켬, sync 1/10. environment `automerge`는 배포 브랜치 정책 main, `prevent_destroy`, 다시 만들면 Sync 재실행(C.4.8).
  - `deploy-merge`: `on`은 `workflow_run`(ci completed)만, merge job에 `environment: {name: automerge, deployment: false}`, `actions/create-github-app-token`에 `secrets.HOMELAB_MERGE_KEY`. Infisical OIDC 단계는 없다.
  - 보강: ci의 workflow-guard(YAML 별칭까지 푸는 파서, environment 이름 대소문자 무시·문자열형과 객체형, 표현식 이름 금지, `automerge`는 `deploy-merge.yaml`의 merge job만, `deploy-merge` 트리거는 `workflow_run`만, `secrets: inherit`와 로컬이 아닌 reusable 호출 금지, `toJSON(secrets)`·동적 secrets 참조 금지, 음성 fixture. C.4.6). D-26 조건 (2)를 "environment secret을 쓰는 워크플로는 `workflow_run`만"으로 넓힌다. Terraform guard가 environment 브랜치 정책 `[main]`, secret 이름 `[HOMELAB_MERGE_KEY]`, repo secret 0개, org secret 0개를 대조한다(C.3.9).
  - 회전: 새 키 발급 → Infisical 값 교체 → environment secret `updated_at`이 교체 시각 이후인지 확인 → 옛 키 삭제. App 키는 만료가 없고 25개까지 동시 유효해[S199] `deploy-merge` 성공만으로는 새 키 반영을 증명하지 못한다. sync 실패 알림은 프로젝트 Admin 메일로 온다[S203], C.6.5.
- **이유:** Free에는 경로·환경 RBAC가 없어 identity를 프로젝트에 넣으면 그 프로젝트 전체를 읽는다(C.6.3). 그래서 읽는 주체가 다른 값마다 프로젝트를 나눈다: 앱 CI가 병합 App 키를(C.4.8), 클러스터가 Terraform 자격을, VM이 운영 값을 못 읽게 한다. 프로젝트는 Free에서 무제한이다[S01]. 병합 키를 sync로 옮기면 비용 0으로 영구 여유 1자리가 생기고, 병합 쪽 OIDC 미확인(옛 U05의 병합 절반)이 사라진다. ESO identity는 sync로 대신할 수 없다(Kubernetes 대상 sync가 없고 ESO의 Infisical provider는 machine identity 인증만 쓴다[S203][S24]). 배포 키는 OIDC로 두어 GitHub에 사본이 없고, 앱이 몇 개든 설정 하나로 끝난다. 값 되돌리기가 없는 위험은 CLI의 "덮어쓰기 금지·옛 값 보관"과 분기 암호화 내보내기로 줄인다. Pro로 바꿀 조건: 값 유실 사고가 한 번이라도 나거나, 사람이 둘 이상이 되거나, 감사 기록이 필요해질 때.
- **대가:** 병합 키 사본이 GitHub environment에 하나 생긴다(C.6.2 규칙의 유일한 예외). 경계가 "`deploy-merge` 파일과 `workflow_run` claim"에서 "main에서 `automerge`를 선언한 job"으로 넓어져 ci의 workflow-guard와 사람 검토가 지킨다. guard는 실수를 잡는 장치다(PR이 guard 코드를 고치면 그 PR의 ci는 고친 코드로 돈다). PAT 연결은 owner 계정에 묶이고, Infisical에 PAT가 저장되며, 만료가 없어 새면 회수할 때까지 유효하고(새었다고 의심되면 교체, 사용자 2026-10-21), org가 fine-grained PAT를 허용해야 한다. GitHub 대상 sync에는 주기 재동기화가 없어 회전 때 `updated_at`을 사람이 확인한다. 가용성 이득은 거의 없다: Infisical 장애 중에도 병합은 사본으로 되지만 배포 PR 생성은 OIDC라 멈춘다.
- **D-07 의존:** D-07(자동 병합 범위)은 배포 digest PR만 자동 병합하기로 확정(사용자 2026-10-18, T05)됐다. 그래서 `deploy-merge`, 병합 키, sync, environment `automerge`는 유지된다. D-07을 다시 열어 자동 병합을 없애면 이것들이 사라지고 identity는 그대로 4/5다.
- **한도에 닿을 때:** 여유 1자리를 넘어 machine identity가 더 필요해지면 Pro로 바꾼다(identity당 월 $20 연간, $23 월간). 자리를 만들려고 배포 키와 병합 키의 경로를 다시 합치지는 않는다(C.4.8). 옛 비상안 (1)(`eso-homelab-dev`을 시나리오 13 때만 만들기)은 영구 여유를 만들지 못하므로 지웠다. E3의 U05 시험이 실패하면(Free OIDC나 claim 묶기 불가) 배포 키를 앱별 environment sync로 옮긴다(앱 저장소 public 필요, 앱 9개까지). 프로젝트 무제한은 2026-08-03에 3개에서 바뀐 것이라는 서드파티 기록이 있다(단일 근거). 프로젝트 한도가 다시 생기면 이 분리를 유지할 수 없으므로 그때 Pro를 다시 본다.
- **검토 후 제외한 안과 이유:**
  - 배포 키도 앱별 environment sync(3/5): 앱마다 environment, sync, 연결 범위가 늘고 Free sync 한도로 앱 9개에서 막힌다. 키 사본이 앱 수만큼 생기고, 앱 main에서 environment를 선언한 아무 job이 키를 받는다(앱 main에는 필수 검사가 없어 workflow-guard를 강제할 수 없다). `issue_comment` 같은 이벤트는 GITHUB_REF가 기본 브랜치라 정책을 통과하므로[S104] public 앱에서는 외부인이 키를 쓰는 실행을 일으킬 수 있다.
  - 배포 PR 생성을 homelab으로 옮김(3/5): 앱 저장소에 저장소 간 자격이 없어지지만, 자격 없이 즉시 깨울 수단이 없다. schedule은 이 org 옛 실행 기록에서 실행 간격 중앙값이 최근 3~5.5시간이었다(실측 2026-10-18, 옛 `bump-poll`·`pr-sweeper`의 scheduled 실행 각 1,000건, 취소 0건). 즉시 감지 중계(org webhook → Cloudflare Worker → `repository_dispatch`)는 구성 요소 넷과 Cloudflare 쪽 homelab 쓰기 키가 늘어 1인 운영에 과하다. `GITHUB_TOKEN`으로 만든 PR의 `pull_request` 실행은 승인 대기로 생기므로[S92] App 키도 결국 필요하다.
  - VM identity 제거: VM 시험이 "ESO → Infisical 로그인 → Secret" 경로를 검증하지 못하고 VM 렌더가 운영과 달라진다. 복구 자산을 실제로 검증하는 유일한 시험이 약해진다.
  - Infisical GitHub App 연결: 조직 Secrets write가 org 전체에 걸린다. 그래서 homelab 하나로 좁힌 PAT 연결을 골랐다.
  - 회전 때 사람이 손으로 복사(`gh secret set --env automerge`, sync 0): Infisical GitHub 연결이 없지만 사본이 어긋나도 고쳐지지 않는다.
  - Infisical 설정을 Terraform으로 관리: provider 인증용 machine identity가 비운 자리를 다시 차지한다.
- **참고:** CI가 tailnet에 붙어야 하면 Tailscale의 GitHub Actions OIDC(workload identity federation)로 저장한 시크릿·identity·sync 없이 된다(`tailscale/github-action` v4.2.0, Tailscale 1.90.1 이상, 태그 필수[S188]).
- **spec 대비:** 구체화(추천은 "조사 결과로 정함, 환경 분리 유지").
- **미검증:** 유료 identity "무제한" 표기 변경 기록(U24, 서드파티 근거만). U05(OIDC Free·claim 묶기)와 U36(PAT 연결 sync, `deployment: false`의 브랜치 정책)은 2026-10-21 통과(부록 1).

### D-05 공유 PostgreSQL과 전용 인스턴스 기준

**확정(사용자 2026-10-18, T05).** 공유 Cluster `pg` + 앱별 DB·역할(봇 포함). 빈 NUC 복구는 Cluster를 자동 동기화로 둔 채 root apply 전 복구 PR → 복구 확인 → 정리 PR로 한다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **공유 Cluster + 앱별 DB·역할 (확정)** | 인스턴스·백업·감시가 하나, 자원 적음 | 장애·업그레이드가 모든 앱에, 앱 하나 복원은 임시 클러스터 + 덤프(C.5.7) |
| 앱마다 전용 Cluster | 독립 PITR, 격리 | 앱마다 백업·감시·자원 |

- **결정:** 공유 인스턴스 + 앱별 DB(봇 포함). 전용 Cluster는 C.5.2의 조건 넷(독립 PITR, 10GB 초과·쓰기 많음, 다른 major·확장, 다른 보존)에 하나라도 걸릴 때만 둔다.
- **이유:** CNPG 복원은 항상 새 클러스터를 만들고[S32] 공유 클러스터 안 DB 하나의 제자리 복원 공식 절차는 없지만, 임시 클러스터 + 논리 덤프로 시나리오 10을 만족한다. 홈랩 규모에서 운영 단순함이 크다.
- **빈 NUC 복구 때 Cluster 정의 (결정과 검토 후 제외한 안):** 결정은 Cluster `pg`를 다른 플랫폼 구성 요소처럼 자동 동기화로 두고, 복구 때는 root apply 전에 복구 원본(옛 serverName)과 새 serverName을 넣는 PR을 병합한 뒤 복구 확인 뒤 정리 PR로 `initdb`로 되돌리는 것이다(C.6.4). 고르지 않은 대안(수동 sync)은 Cluster `pg`(와 ObjectStore)를 자동 동기화가 꺼진 별도 Application으로 두고, 복구 때 사람이 복구 정의로 바꾼 뒤 직접 sync하는 것이다. 대안은 root apply 순서와 무관해 실수 여지가 적지만, 평상시 Cluster 변경(파라미터, 이미지 올림)도 사람이 sync해야 하고 selfHeal이 없어 라이브 표류를 Argo CD가 되돌리지 않는다.
- **spec 대비:** 일치.

### D-06 영속 Valkey의 유실 허용 범위

**확정(사용자 2026-10-18, T05).** AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 재시작 손실 약 1초, 디스크 유실 최대 24시간.

| 선택지 | 손실 범위 | 비용 |
|---|---|---|
| RDB만(하루 1회 + 기본 `save`) | 재시작 때 마지막 스냅샷 뒤 전부(최대 수 분~1시간), 디스크 유실 최대 24시간 | 가장 단순 |
| **AOF `everysec` + 하루 1회 RDB를 R2로 (확정)** | 프로세스·노드 재시작 약 1초, 디스크 유실 최대 24시간 | AOF 디스크 쓰기, 복원 절차에 AOF 처리 단계 |
| AOF `always` | 재시작 손실 거의 0 | 쓰기 성능 저하 |

- **결정:** AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 영속 Valkey는 필요한 앱만 쓰고, 큐의 유실이 치명적이면 그 데이터는 PostgreSQL에 둔다.
- **이유:** AOF와 RDB를 함께 켜면 시작 때 AOF를 쓰고 `everysec`이면 장애 때 약 1초를 잃을 수 있다고 공식 문서가 적는다[S41]. RDB는 실행 중 복사가 안전해 백업이 단순하다[S41]. 남는 위험: 영속 Valkey가 있는 앱 ns에 R2 백업 토큰이 간다(C.3.8).
- **spec 대비:** 제안(추천은 "P1 제안을 따른다").
- **미검증:** RDB 복원 단계(공식 절차 문서 없음), ACL을 켠 상태에서 `valkey-cli --rdb`에 필요한 권한. 시나리오 4에서 확정한다.

### D-07 자동 병합 범위

**확정(사용자 2026-10-18, T05).** 배포 App이 앱 기본 브랜치 빌드에서 만든 한 앱 `image.yaml` digest·revision만 바뀐 PR만 자동 병합하고 서버 쪽에서 강제한다. GitHub auto-merge 허용은 끈다. 나머지는 사람이 검토 후 병합한다. 그래서 D-04의 병합 키와 Secret Sync는 유지된다.

| 선택지 | 내용 |
|---|---|
| **배포 digest PR만, 서버 강제 (확정)** | C.4.7의 조건 9개. 강제는 ruleset A~D(D는 배포 키 identity가 묶이는 `app-build-v*` 등 버전 태그를 지키는 둘: 갱신·삭제 금지 D1, 생성 제한 D2) + 앱 저장소·`homelab-app-template`의 `app-main` + `workflow_run` 병합 워크플로 + App 2개와 키별 Infisical 프로젝트(배포 키는 OIDC identity, 병합 키는 environment `automerge` sync 사본, D-04) |
| 자동 병합 없음 | 모든 배포 PR을 사람이 병합. 가장 안전하지만 반복 배포가 사람 대기 |
| 옛 방식처럼 데이터·시크릿 PR도 자동 | 리뷰 수 0이라 사람 검토가 없었다(B.7 2번). 권하지 않음 |

- **결정:** 배포 갱신 App(`ukyi-homelab-deploy`)이 앱 기본 브랜치 빌드에서 만든, 한 앱의 `image.yaml` digest·revision만 바뀐 PR만 자동 병합한다. 그 앱 저장소의 main ruleset `app-main`이 active로 확인될 때만이다(조건 9. 앱 저장소는 public만, D-29). GitHub auto-merge 허용은 끈다. 나머지는 사람이 검토 후 병합한다. owner가 만든 PR은 자기 승인이 안 되므로[S106] 관리자 bypass 병합이 곧 사람 검토이고, ruleset A의 `ci`는 그대로 걸린다. owner PR은 검토한 SHA를 고정해 병합한다(`gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`). bypass 모드 `exempt`는 쓰지 않고, bypass 기록은 월 1회 PR 작성자와 대조한다. main 갱신은 Restrict updates로 bypass 신원(관리자 역할, `ukyi-homelab-merge`)만 한다. 승인 요구만으로는 owner PR을 막지 못했다(U08 (나): 작성자가 유일한 code owner인 owner PR에서 쓰기 권한 App 승인 하나로 요건이 찼다). 그래서 사람이 병합하는 PR은 작성자와 상관없이 관리자 bypass 병합이다. Codex PR은 owner 계정으로 찍혀 owner의 검토가 유일한 관문이다(C.4.7).
- **이유:** ruleset에는 PR 작성자 조건이 없어[S87] 작성 주체 조건은 "배포 브랜치 생성 제한(ruleset C) + main 코드의 병합 워크플로가 작성자 확인 + 병합 App만 bypass"로 만든다. auto-merge는 작성자 조건이 없다[S88]. 자동 배포는 앱 main을 믿으므로 앱 main을 보호할 수 있어야 한다. Free에서는 public 저장소에만 ruleset을 걸 수 있어 앱 저장소를 public만 둔다(D-29).
- **U08 셋째 조건이 틀릴 때(관리자 역할 bypass가 org owner에게 적용되지 않음):** 첫 실측인 결정 5 하드닝(2026-10-18, 앱 저장소 두 곳)에서 `current_user_can_bypass`는 `pull_requests_only`였고, homelab에서는 E1에서 임시 ruleset을 건 직후 본다. 틀리면 owner는 자기 PR을 병합할 수 없으므로 bypass 행위자를 이 순서로 바꿔 시험한다. (1) owner 계정을 `actor_type` `User`로(`pull_request` 모드). 2026-05-07부터 저장소 수준 ruleset에 개인 사용자를 bypass 행위자로 넣을 수 있다[S205][S85]. 공지에 요금제 조건이 없어 Free org에서 되는지는 미검증이다. 관리자 역할 전체 대신 owner 한 명만 bypass하므로, 나중에 다른 사람이나 App에 admin 역할을 줘도 bypass가 함께 넓어지지 않는다. (2) `OrganizationAdmin`(REST `actor_type`의 값[S85]). (3) owner만 든 팀(secret 아님, U31). 다른 길로, ruleset B의 승인 수를 0으로 내리고 "Restrict updates"로 main 갱신을 bypass 목록(위 행위자와 `ukyi-homelab-merge`)에만 허용할 수 있다. 그러면 봇·Renovate의 PR을 막는 장치가 승인 요구에서 갱신 제한으로 바뀌지만, 이 길도 owner 쪽 행위자로 위 셋 중 하나가 서야 한다. 셋 다 안 되면 이 결정(D-07)을 다시 열어 사용자가 정한다. 모두 [미검증]이고 E1에서 시험한다.
- **spec 대비:** 일치하고 강제 장치를 구체화했다.
- **미검증:** bypass App 병합과 관리자 bypass 병합 때 bypass 없는 ruleset의 필수 검사 적용, App 승인이 code owner 승인을 대신하지 못함, 관리자 역할 bypass의 org owner 적용(U08. 셋째는 결정 5 하드닝에서 `pull_requests_only`를 먼저 확인했고 실제 병합은 E1, 나머지는 E5에서 시험, 시나리오 15). U08은 2026-10-21 시나리오 15에서 관리자 쪽(필수 검사 적용, 관리자 역할 bypass 병합)이 통과했고, 같은 날 시험에서 병합 App bypass의 필수 검사 적용은 통과, App 승인의 code owner 대체 금지는 실패했다. "틀리면" 열대로 Restrict updates를 적용했고 apply 뒤 재시험(bypass 밖 App의 병합 거부, owner `--admin` 병합, 배포 PR 자동 병합)이 통과했다(approvals 21:24~21:27·21:27~21:33 행). U25(앱 저장소 규칙·`codeowners/errors` 읽기)와 U30의 정상 main 이미지 경로는 통과했고, U30의 main 밖 이미지 거부는 T13(부록 1). U08 셋째 조건이 틀릴 때의 대안 행위자(`User`, `OrganizationAdmin`, owner만 든 팀)의 Free 동작(U31). Codex의 owner PR 병합(U37)은 2026-10-22 통과(조건부): App 설치 토큰 경로는 Restrict updates로 막히고(재시험), owner 권한(사용자 토큰) 경로는 Codex 작업 환경이 없어 시작되지 않는다(#828). 환경을 두지 않는 것이 조건이다(F D-26 (5)).

### D-08 AdGuard 재구축 방식과 Tailscale DNS 폴백

**확정(사용자 2026-10-18).** 내부 UI는 `*.ts.net`, Tailscale DNS는 (b′).

| 선택지 | Tailscale 기기 광고 차단 | AdGuard·NUC 장애 때 Tailscale 기기 | 판정 |
|---|---|---|---|
| (a) AdGuard 단독(Override 켬, nameserver = NUC) | 어디서나, AdGuard Home 규칙 그대로 | 이름 해석이 끊김(UDP 2초 뒤 TCP 병행, 질의 상한 10초 뒤 SERVFAIL[S186]. 옛 구성, 지금 C-05로 임시 보완) | 검토 후 제외 |
| (a+) (a) + 외부 감시가 Tailscale API로 nameserver 자동 전환 | 평소 어디서나 | 처음 3~5분은 (a)와 같고 그 뒤 공용 차단(추정) | 검토 후 제외 |
| (b) AdGuard + 비차단 공용 DNS 병렬(지금 C-05) | 보장 못 함(먼저 답한 비차단 서버의 질의는 차단 없음[S110][S186]) | 유지 | 제외 |
| **(b′) AdGuard Home + AdGuard 공용 DNS 병렬, Override 켬** | 어디서나 기본 목록(AdGuard DNS filter[S189][S190]). AdGuard Home 전용 규칙은 일부 질의에만 | 공용 서버가 차단하며 답함, 체감 없음 | **확정** |
| (c) NextDNS 단독 전역(AdGuard Home은 LAN 전용) | 어디서나(NextDNS 목록, DoH) | 영향 없음. NextDNS 장애 때는 tailnet 전체 DNS 실패 | 검토 후 제외 |
| spec안: Override 끔 + 내부 도메인만 split DNS | 집 LAN에서만 | 내부 이름만 영향 | 제외(내부 UI가 `*.ts.net`이라 split DNS가 필요 없음) |
| 옛 권장 (c′): Override 끔 + 전역 nameserver 비움 | 집 LAN에서만 | 영향 없음 | 대체됨(Tailscale을 켜면 어디서나 차단하라는 요구) |

- **결정:**
  - 내부 UI 이름은 Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`(UI마다 단독 프록시). `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01용 Cloudflare 토큰, traefik-ts는 두지 않는다(C.3.5).
  - AdGuard Home은 같은 LAN IP `:53`(servicelb). Git 시드가 원본이고 라이브 UI 변경 중 남길 것은 시드로 옮긴다. 필터는 AdGuard DNS filter 하나, 사용자 규칙은 최소(C.3.6).
  - Tailscale DNS (b′): Override local DNS 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS. AdGuard Home 기본값과 같은 AdGuard DNS filter[S189][S190]), C-05 임시 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬, `use_with_exit_node`는 기본 끔. NUC는 `accept-dns=false` 유지. C-05 임시 항목은 E4a에서 이 값으로 대체한다.
  - 관리: Terraform `tailscale_dns_configuration`(provider v0.29.2. 문서상 정식[S187]이나 Read가 `Alpha Resource` 경고를 내고, 동작은 T08a U34로 확인). `data.tailscale_devices`로 hostname 일치 기기를 받아 precondition(정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`)을 걸고, IPv4는 `100.` 대역으로 골라낸다. `tailscale_dns_nameservers`와 함께 쓰지 않는다. 이 자원은 DNS 설정 전체를 소유하므로 첫 apply 전에 콘솔 값을 그대로 옮긴 HCL로 새 state에 import하고 plan 무변경을 확인한 뒤 바꾼다[S217]. NUC가 없을 때 ACL apply까지 막히지 않게 DNS는 별도 root `infra/tailscale-dns`에 두고 `prevent_destroy`를 건다. 조건부(`count`)는 NUC가 없는 동안 DNS 설정 전체 삭제를 계획하므로 쓰지 않는다(C.3.6). Override가 켜진 상태에서 AdGuard가 죽어도 공용 서버가 답하므로 Terraform을 돌리는 기기의 DNS 문제는 작다(C.3.6).
  - NUC는 `tag:nuc`로 태그한다(D-11 (c), 확정(사용자 2026-10-20). 그 전에는 (a)). 그래서 `autogroup:member → tag:nuc:53` ACL 규칙이 필요하다. AdGuard 노출은 설계대로 servicelb이고, svclb 출처 MASQUERADE로 ratelimit 버킷을 함께 쓰는지 E4a에서 확인한다. 필요하면 `ratelimit_whitelist`나 hostNetwork로 간다(hostNetwork는 노드 네임스페이스 공격면이 는다, U32). 2026-10-21 확인: 함께 쓴다. ratelimit을 껐다(사용자).
  - 시나리오 14에 셀룰러 Tailscale 기기 확인(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상)과 사용자 규칙 적용률 측정(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩)을 넣는다(G).
- **목적·이유:** Tailscale을 켠 기기는 집 안팎 어디서든 차단되고, NUC 장애 때도 공용 서버가 차단하며 답한다. Tailscale은 전역 nameserver에 동시에 묻고 처음 온 정상 응답을 쓰므로[S110][S186] 모든 nameserver가 같은 기본 목록으로 차단하면 병렬이어도 기본 차단이 유지된다. 옛 구성의 가장 비싼 실패(NUC·AdGuard·키 만료·재등록 IP 변경·ACL 실수 하나가 Tailscale 기기 전체의 DNS 장애)가 "사용자 규칙만 잠시 빠짐"으로 줄고, 새 장치나 자격이 들지 않는다. 내부 UI를 `*.ts.net`으로 옮기면 내부 이름이 AdGuard·nameserver와 무관해지고, 인증서가 깨질 원인 사슬(Cloudflare DNS 편집 토큰, cert-manager DNS-01, Traefik 내부 TLS, AdGuard rewrite·리컨실러)이 짧아진다(A.4 1번). 인증서를 못 받으면 막히는 것은 두 방식이 같다: `*.home.ukyi.app`은 `.app` 최상위 도메인의 HSTS preload로[S210], ts.net은 프록시가 핸드셰이크를 실패시켜[S211] 넘어갈 수 없다. 두 방식 모두 갱신 실패 뒤 약 30일 여유가 있고 비상 경로는 `kubectl port-forward`다(C.3.5). 단일 서버에서 제공할 수 없는 가용성을 전제로 두지 않는다(design-prompt §2).
- **대가:**
  - AdGuard Home 사용자 규칙·허용 목록·추가 목록은 AdGuard Home이 먼저 답한 질의에만 적용된다. Tailscale 기기에서 확실하게 적용되는 것은 AdGuard DNS filter 수준의 차단이다.
  - 공용 경로는 평문 UDP다. AdGuard사가 질의를 받고, 가로채는 망에서는 그 망이 먼저 답해 차단이 빠지거나 위조될 수 있다. tailscaled는 DNSSEC을 검증하지 않는다[S186].
  - AdGuard Home이 tailnet에서 조용히 빠져도 증상이 없으므로 "tailnet 출처 질의가 1시간 0건이면 경보" 감시가 필요하다(C.3.7).
  - Override를 켜면 로컬 DNS 전용 이름(회사·호텔 내부 이름)이 Tailscale을 켠 동안 안 풀린다[S110].
  - DNS 차단은 같은 도메인 광고(유튜브 등)를 못 막고, 브라우저 보안 DNS·안드로이드 개인 DNS는 이 경로를 우회한다.
  - HTTPS 인증서를 켜면 tailnet 이름과 기기 이름이 CT 로그에 공개된다[S120].
  - 옛 사용자 선택은 "AdGuard 전역, 폴백 없음"이었다(`2d2054a:infra/tailscale/acl.tf:47-50`). (b′)는 사용자 규칙의 일관성을 내주고 가용성을 얻는다.
- **검토 후 제외한 안과 이유:**
  - (a) AdGuard 단독 + 장애 때 수동 전환: 사용자 규칙·통계가 늘 적용되지만, AdGuard·NUC·키 만료·재등록 IP 변경·ACL 실수 중 하나만 생겨도 Tailscale 기기 전체가 인터넷 장애처럼 보이고, 사람이 알아채고 손을 써야 한다(기기에서 Tailscale DNS 끄기, 콘솔 nameserver 교체). 가족 기기는 NUC:53 ACL을 따로 열어야 한다.
  - (a+) (a) + healthchecks.io 웹훅 → Cloudflare Worker가 Tailscale API로 nameserver를 자동 전환: 장치 넷(CronJob, 체크, Worker, OAuth client)이 늘고, DNS 쓰기 자격이 새면 tailnet 전체 DNS를 공격자가 정한다. 전환되기 전 몇 분은 (a)와 같다. Terraform으로 DNS를 관리하면 전환 상태가 드리프트로 보이고, 장애 중 apply가 죽은 NUC로 되돌린다.
  - (c) NextDNS 단독 전역: NUC와 분리되고 DoH로 암호화되지만, 규칙을 AdGuard Home과 두 곳에서 따로 관리하고, 무료는 월 300,000 질의를 넘으면 그 달 남은 기간 차단 없이 답한다(Pro 월 ₩2,500[S204]). NextDNS 장애 때 tailnet 전체 DNS가 실패하고, 프로필 ID가 든 주소는 공개 저장소에 둘 수 없다.
  - 그 밖에 조사에서 함께 본 것: 동반 리졸버를 Control D(DoH 우선, 차단 목록 다름)로 바꾸기, AdGuard DNS 개인 서버, NUC를 exit node로, 두 번째 AdGuard Home 서버(C-07의 단일 서버와 충돌).
- **spec 대비:** 조정. spec 후보 (a)(b)(c)에 없던 (b′)다. 옛 문서가 (b)를 "차단을 보장할 수 없다"로 뺀 판단은 비차단 서버를 섞을 때만 맞아 범위를 좁혔다(평문 경로와 AdGuard Home 전용 규칙의 한계는 위 대가).
- **미검증:** 공용 서버의 실제 차단과 사용자 규칙 적용률(U33, 시나리오 14), servicelb 경로의 tailnet 출처와 ratelimit(U32), DNS Terraform 동작(U34), 공유기가 AdGuard 정지 때 보조 DNS로 넘어가는 지연과 실패율(U19, 시나리오 14). 옛 실측은 넘어가는 문턱이 높아 페이지 로드 지연·간헐 실패가 났다(`2d2054a:platform/adguard/prod/adguardhome.yaml:39`). 허용 기준(C.3.6의 AC-P6 판정 기준)은 설계 제안대로 확정(사용자 2026-10-18, T05)이다. **2026-10-20 T08a 결과:** U34의 import·DNS 동작 통과(`tag:nuc` precondition은 (c) 적용 때 검증), U33 셀룰러 통과(적용률 셀룰러 19/20, 집 Wi-Fi 남음), U19 반증(공유기가 보조로 넘어가지 않음, AC-P6 LAN 불합격을 사용자가 한계로 승인), U32 남음. **2026-10-21:** 집 Wi-Fi 적용률 20/20, U32 확인(LAN·tailnet 출처가 같은 /24 버킷 → ratelimit 끔, 사용자), U34 `tag:nuc` precondition 통과.

### D-09 관측 스택 구성

**확정(사용자 2026-10-18, T05).** 옛 계열 최소 구성. vmagent와 보조 수집기 4개는 두지 않고, 핵심 룰 15개 안팎을 단위 시험과 함께 둔다.

| 선택지 | 내용 |
|---|---|
| **옛 계열 최소 구성 (확정)** | VictoriaMetrics single(자체 스크레이프, vmagent 없음[S167]), vmalert, Alertmanager, Grafana, VictoriaLogs single + vector, node-exporter, kube-state-metrics. 공식·상류 차트, 핵심 룰 15개 안팎 + 단위 시험 |
| kube-prometheus 계열(operator + 기본 룰 묶음) | 기본 룰·대시보드가 많다. operator와 CRD가 더 들어온다 |
| 로그 저장소 없이 | 구성 요소가 준다. 봇의 로그 조회(R05)와 재시작 이전 로그 확인이 어렵다 |

- **결정:** 옛 계열 최소 구성. 보조 수집기 4개, CI·메타·기판 룰은 두지 않는다.
- **이유:** 옛 운영 함정(OOM 결합, reload, ConfigMap 롤아웃, root 수집, Telegram escape)의 처방이 이미 있다(B.8 E4). 봇 읽기 자리(Grafana Viewer)와 경보 외부 수신자 선례가 그대로 맞는다.
- **spec 대비:** 구체화.
- **미검증:** 각 차트 버전(E4b에서 고정), `vmalert-tool unittest` 형식, Grafana Viewer의 질의 범위.

### D-10 비AI 알림 채널과 외부 생존 감시

**확정(사용자 2026-10-18, T05).** homelab 알림용 Telegram 새 봇 + healthchecks.io(계정 재사용, 체크 새로). 옛 Telegram 봇·토큰은 `mac-uptime-guard`를 처리하는 T22까지 그대로 둔다. 옛 봇 토큰을 재발급하는 대안은 고르지 않았다.

| 선택지 | 내용 |
|---|---|
| **Telegram(homelab 알림용 새 봇) + healthchecks.io(계정 재사용, 새 체크) (확정)** | Alertmanager 내장 `telegram_configs`[S163][S165], Watchdog → healthchecks ping[S161][S162]. 무료 체크 20개[S160] |
| Discord webhook(봇 서버와 다른 채널) | Alertmanager 내장 `discord_configs`. 봇과 같은 플랫폼이라 독립성이 약하다 |
| 이메일 | 놓치기 쉽다 |

- **결정:** Telegram + healthchecks.io. homelab 알림용 Telegram 봇을 E3에서 새로 만든다. 옛 봇과 토큰은 그 토큰을 쓰는 저장소 밖 `mac-uptime-guard`를 T22에서 처리(장치를 끔. 저장소는 그 뒤 삭제, D-29)할 때까지 그대로 두고, 그 뒤 옛 봇을 지운다. 그래서 T06 자격 폐기 표의 옛 Telegram 봇 토큰 행은 `보류(D-10, T22)`이고, E1(T06)은 폐기하지 않고 E3(T09)의 "`보류(…, T09)` 줄 모두 닫힘"에서도 빠진다(E1·E3 완료 기준, E10). healthchecks.io는 새 체크(Period 5분, Grace 5분)를 만든 뒤 옛 `homelab-watchdog`를 지운다. T06 표의 옛 ping URL 행은 `보류(D-10, T08b)`이고, E4b가 새 체크가 초록인 것을 확인한 뒤 옛 체크를 지우며 닫는다(E1·E4b 완료 기준). Watchdog은 relay 없이 Alertmanager webhook의 `url_file`로 ping한다. 안 되면 가드가 있는 작은 relay. 선택 항목: 공개 경로 생존 확인용 두 번째 체크(C.3.7).
- **이유:** 봇과 독립이고 NUC를 거치지 않는 통지 경로다. 옛 ping URL은 옛 자격이라 새로 발급한다(D-20). Telegram은 옛 토큰을 재발급하지 않고 새 봇을 만든다. 재발급하면 옛 토큰을 쓰는 `mac-uptime-guard`의 알림이 T22까지 아무 표시 없이 끊기기 때문이다(E3, `2d2054a:policy/gh-secret-var-classification.json:91`).
- **검토 후 제외한 안(옛 봇 토큰 재발급):** 옛 봇의 토큰을 E3에서 재발급하고, 같은 E3 사람 작업에 `mac-uptime-guard` 설정 갱신과 그 장치의 시험 알림 수신 확인을 함께 넣는 안이다. 봇 계정은 하나로 유지되지만 저장소 밖 장치를 E3에서 함께 고쳐야 하고, 빠뜨리면 감시 장치가 조용히 실패한다. 이 안을 고르지 않았으므로 E3(T09)이 옛 봇 토큰 행을 닫는 분기는 쓰이지 않고, 그 행은 T22가 닫는다.
- **spec 대비:** 구체화.
- **미검증:** Alertmanager webhook → healthchecks ping 직접 연결의 실동작, healthchecks 무료 플랜의 연동별 제한.

### D-11 옛 외부 자원: import 또는 삭제

**확정(사용자 2026-10-18, T05).** 아래 표 그대로다. zone·tailnet·R2 state 버킷만 이어 쓰고 나머지는 새로 정의하거나 지운다. state 키 접두는 `v2/`, zone 설정 9개는 새 Terraform으로 가져온다. Tailscale ACL은 처음 (a)였고 2026-10-20 U28 결과로 (c)로 바꿨다(사용자).

| 자원 | 결정 | 이유 |
|---|---|---|
| Cloudflare zone `ukyi.app` | 유지 | 이어 쓰는 자산 |
| zone 설정 9개(HSTS 포함) | **새 Terraform으로 가져옴**(값 유지: HSTS includeSubDomains 180일, preload 끔, `always_use_https`, TLS 1.2 최소, TLS 1.3, `browser_check`, `security_level` medium 등) | zone이 남아 설정도 남는다. 코드로 보이게 한다 |
| 옛 터널, DNS 레코드, WAF·캐시 규칙 | 삭제(E1), 새로 정의(E4a) | 이름·phase 충돌 방지, 옛 토큰 무효화. 같은 토큰의 두 커넥터 함정 |
| R2 `homelab-tfstate` | 유지, 새 키 접두 `v2/` | 옛 키를 쓰면 옛 state 상속 |
| R2 옛 백업·media 버킷 3개 | 삭제(`prevent_destroy` 둘은 콘솔) | C-02, C-03 |
| Tailscale tailnet | 유지. ACL은 새 코드로 덮어씀(self·ssh 유지, 아래 (a)), DNS 설정도 Terraform `tailscale_dns_configuration`으로(D-08 확정) | 하나뿐인 설정 |
| Tailscale tagged 기기·OAuth 3종 | 삭제 | 옛 operator·CI용 |
| GitHub 옛 App(reader, writer, dispatch), environment 4개, 저장소 변수 2개, webhook | 삭제 | 새 App·environment로 대체, 공개 webhook 없음 |
| GHCR `pg-tools`, `skopeo` | 삭제 | 소비자 없음. public 패키지는 한 버전이라도 다운로드가 5000회를 넘으면 API로 지울 수 없다(2026-10-18 `page`에서 HTTP 400). 그날 UI의 전체 다운로드는 `skopeo` 1.76k, `pg-tools` 973 |
| GHCR 앱 패키지 4개 | `page`·`trip-mate-api`는 저장소와 함께 삭제(D-29, 2026-10-18 실행, 0절 7항). `files`는 T22까지 유지, `aiops-autodeploy-canary`(private)는 저장소 처리와 함께(T22) | 쓰지 않는 앱은 지우고, 남는 앱은 재연결 판단 |
| healthchecks.io 옛 체크 | 새 체크가 초록이 된 뒤 삭제 | D-10 |

- **spec 대비:** 일치하고 항목별로 구체화했다. org 저장소 처리는 D-29(공개 정책, 삭제·보관)·D-21·T22가 맡고, 봇 저장소(`homelab-bot`, `homelab-bot-ops`)는 D-13이 맡는다.

**Tailscale ACL과 NUC 신원** (위 tailnet 행의 세부)

| 선택지 | 장점 | 단점 |
|---|---|---|
| (a) 처음 결정(2026-10-18~2026-10-20): NUC는 태그 없는 사용자 기기, 옛 규칙 유지. `autogroup:member → autogroup:self:*`, ssh `accept` + `autogroup:nonroot`·`root`(C.3.5 예시) | spec §10 12항 그대로다. 운영자의 SSH·mosh·kubectl 경로와 root 비대화형 경로가 옛 구성과 같아 E4a에서 원격 접속이 끊길 일이 없다 | self 규칙이 NUC에서 운영자 기기로 가는 모든 포트도 연다. 파드 egress가 NUC 주소로 바뀌어 나가면(U28) 파드가 운영자 기기에 닿을 수 있어, 공유 차트의 tailnet 대역 제외(C.4.5)와 작업자 init 규칙(C.8)에 기댄다. egress 정책이 없는 플랫폼 파드에는 위험이 남는다. 재등록마다 키 만료를 손으로 끈다[S119]. 노트북을 잃으면 비밀번호 없는 root 접속까지 열린다 |
| (b) (a)에서 ssh만 좁힘: `check` + `autogroup:nonroot` | 노트북 탈취 때 재인증 없는 접속과 root 직행을 막는다 | `check`는 checkPeriod(기본 12시간, 1분~168시간)가 지나면 SSH 연결을 맺기 전에 브라우저 재인증을 요구한다[S121]. 휴대 기기에서 원격 작업 세션을 새로 열거나 다시 붙을 때 재인증 화면을 거쳐야 하고, 사람 없이 도는 SSH(스크립트, 에이전트의 원격 명령)는 기간이 지나면 실패한다. root 비대화형 경로가 사라져 sudo가 필요한 확인은 대화형으로 한다(`2d2054a:infra/tailscale/acl.tf:33-36`). spec의 "ssh 규칙 유지"보다 좁아 조정 권고가 된다 |
| **(c) 확정(사용자 2026-10-20): NUC를 `tag:nuc`로 태그** | 태그 기기는 키 만료가 기본으로 꺼져[S119] 재등록 때 손 작업이 없다. ACL을 `autogroup:owner`·`autogroup:admin` → `tag:nuc:22,6443`(mosh를 쓰면 그 UDP 범위도)과 `tag:nuc` 대상 ssh 규칙으로 바꾸고 `tag:nuc`에서 사람 기기로 가는 규칙을 두지 않으면, NUC와 거기서 주소가 바뀌어 나가는 파드가 운영자 기기에 닿지 못한다. U28의 결과와 무관하게 막힌다 | spec §10 12항의 "autogroup:self 유지"와 달라 조정 권고다. `autogroup:self`가 태그 기기에 적용되지 않아[S117] 규칙을 태그 기준으로 다시 써야 하고, 빠뜨리면 원격 경로가 끊긴다(B.8 E4. 적용 전 정책 사본으로 되돌림, E4a). 옛 self 규칙이 모든 포트를 열어 쓰던 경로(SSH·mosh, `acl.tf:8-9`. 원격 kubectl, `acl.tf:16-19`)를 하나씩 다시 열어야 한다. ssh 규칙 dst가 태그면 `autogroup:nonroot`가 src 전원에게 모든 비root 사용자를 연다는 공식 경고가 있다(지금은 사람 1명)[S121]. 태그 등록에는 tagOwners 선언과 기기 태그 지정(콘솔 또는 `--advertise-tags`)이 필요하다. D-08 (b′)에서도 `tag:nuc:53`을 연다(빠뜨려도 공용 서버가 답해 E4a에서 드러나지 않으므로 시나리오 14의 적용률과 이탈 경보로 본다) |

- **결정:** (c)(사용자 2026-10-20: "없어 c가 나을거같네", NUC에서 사람 기기로 먼저 접속할 일이 없다는 답과 함께). 처음 결정은 (a)였다(spec 추천과 같고 E4a에서 원격 접속을 잃을 위험이 가장 작아서). 아래 바꿀 조건이 E4a에서 충족됐다: U28에서 파드가 NUC 주소로 운영자 기기에 닿았고, egress 정책이 없는 플랫폼 파드를 모두 막는 것보다 Tailscale에서 길을 끊는 편이 단순하다. 곧 클러스터에서 봇 작업자가 코드를 실행하므로(T16b 이후) 그 전에 적용한다. (b)는 고르지 않았다. 적용 순서(규칙 먼저, 태그 나중)와 되돌리기는 E4a(T08a)다.
- **(c)로 바꿀 조건(E4a에서 다시 봄, 2026-10-20 충족):** U28 시험에서 파드가 NUC 주소로 운영자 기기에 닿는 것이 확인되고, egress 정책이 없는 플랫폼 파드를 모두 막기 어렵다고 판단될 때. 이때 (b)의 `check`를 함께 고를 수 있다. 바꾸면 C.3.5 예시와 E4a 검증을 함께 고친다.
- **spec 대비:** (c)는 spec §10 12항의 "autogroup:self 유지"와 달라 조정이다. self 규칙은 사람 기기끼리 쓰려고 남고, NUC만 태그 규칙으로 옮긴다.
- **결과(2026-10-21, E4a):** (c) 적용 뒤 집 밖 기기에서 SSH(22)·kubectl(6443)·AdGuard DNS·공유기 관리 화면·내부 UI가 되고, U28 재시험에서 시험 파드가 운영자 기기에 닿지 않았다. NUC에서 사람 기기로 가는 tailnet 연결도 막힌다(LAN 주소로는 된다). NUC는 Tailscale SSH를 켜지 않는다(사용자 2026-10-21). 원격 SSH는 tailnet 주소의 sshd(키 인증, root 로그인 금지, H4)이고 22 포트 규칙이 그 길을 연다. 그래서 `tag:nuc` 대상 ssh 규칙(root 포함)은 쓰이지 않는다. 켜면 키 없이 root까지 열리므로 켜기 전에 이 규칙을 다시 본다.

### D-12 철거 방식과 빈 NUC 검증 방식

**확정(사용자 2026-10-18, T05).** OS 유지 + k3s 제거 + 호스트 정리(B.4의 H1·H2·H3·H7·H8·H9). H4·H5 drop-in은 남기고 E2가 덮어쓴다. `/mnt/bulk`는 비우고 fstab 항목을 지운다. 빈 NUC 검증은 VM에서 하고(E8 격리 조건 여섯), VM 호스트는 tailnet 밖에 둔다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **OS 유지 + k3s 제거 + 호스트 정리 + 옛 데이터 경로 삭제 (확정)** | NUC 로컬 자료·Codex 홈이 남고 빠르다 | 잔여물 판정이 필요(B.4) |
| OS 재설치 | 깨끗하다, 실제 빈 NUC 검증이 된다 | 로컬 자료 보존 부담(spec §4.5), Tailscale 재등록(키 만료·IP 변경) |

- **결정:** OS 유지. 철거 범위는 B.4의 H1·H2·H3·H7·H8·H9. **노드 DNS drop-in(H5)과 sshd·journald·tmpfiles drop-in(H4)은 남기고 E2가 같은 이름으로 덮어쓴다.** `/mnt/bulk`는 비우고 fstab 항목을 지운 뒤 쓰지 않는다. 시나리오 13은 VM에서 하고, VM은 E8의 격리 조건 여섯을 지킨다: (1) 클러스터별 값 파일 `platform/root/values-vm.yaml`과 root `root-vm.yaml`, 호스트 값 파일 `host/clusters/vm.env`(노드 이름·IP, 인터페이스, TLS SAN. `bootstrap.md`가 클러스터 이름으로 고른다, C.3.2), (2) Infisical 프로젝트 `homelab-dev`와 VM 전용 identity, (3) VM 전용 R2 버킷·토큰과 serverName(운영 아카이브는 복구 자산의 읽기 전용 토큰으로 복구 원본에만), (4) Tailscale hostname 접두 `vm-`(operator 자신 포함)와 VM 전용 operator OAuth client. VM 호스트는 tailnet에 넣지 않는다(`vm.env`의 `TAILNET_JOIN=false`로 Tailscale 단계를 건너뜀, 접근은 LAN·콘솔. 넣으면 ACL의 self·ssh root 규칙으로 운영 NUC에 닿는다). 빈 NUC 복구 순서의 옛 클러스터 Tailscale 기기 삭제 단계는 VM에서 건너뛰고 시험 뒤 `vm-*` 기기만 지운다, (5) 시험 터널·체크·수신자. VM은 운영 공개 URL을 쓰지 않고 시험 터널 연결 수와 Traefik 라우트(Host 헤더, port-forward)로 공개 경로를 확인한다, (6) kubeconfig context 각인. VM 위치는 NUC가 아닌 다른 기기를 우선한다(NUC 호스트에 가상화 구성 요소를 늘리지 않음). 없으면 NUC의 임시 VM을 시험 뒤 지운다.
- **이유:** spec 추천과 같다. 대체 없이 노드 DNS 설정을 지우면 순환이 다시 생긴다(spec §4.5). VM 격리 여섯은 VM이 운영과 같은 Git 트리를 따르면서도 운영 백업 prefix(타임라인 혼합, B.8 E6), tailnet 이름(`-1` 접미, `2d2054a:platform/tailscale/prod/traefik-ingress.yaml:12-15`), 터널·체크(B.8 E1)에 쓰지 않게 한다.
- **검토 후 제외한 VM 격리 대안:** Tailscale은 접두 대신 VM 전용 tailnet(계정·ACL·HTTPS 설정을 한 벌 더 관리). VM 호스트는 tailnet 밖 대신 `tag:vm` 태그 기기로 등록(`tagOwners`에 추가, `tailscale up --advertise-tags=tag:vm`)하고 `tag:vm`을 src로 둔 규칙 없이 `autogroup:member → tag:vm:22,6443`만 시험 동안 연다. 운영자 기기에서 tailnet으로 VM에 닿고 VM에서 운영 기기로는 못 가지만, 시험 앞뒤로 ACL을 바꿔 apply해야 하고(원격 경로를 끊을 위험, B.8 E4) 시험 뒤 기기 삭제가 남는다. 백업은 전용 버킷 대신 운영 버킷 안 VM 전용 prefix(토큰이 운영 prefix까지 쓸 수 있어 권하지 않음). 공개 경로는 권장(시험 터널 연결 수 + Traefik 직접 확인) 대신 values-vm에 공개 host 접두(예: `vm-smoke.ukyi.app`, 첫 단계 하위 도메인이라 Universal SSL이 덮는다[S141])를 두고, 그 host 하나만 시험 터널로 보내는 DNS 레코드와 터널 ingress 규칙을 시험 동안만 만든다. 인터넷에서 VM까지 실제 경로를 보지만, 차트가 클러스터 값으로 공개 host를 바꾸는 장치가 하나 늘고 운영 zone에 시험 레코드를 넣었다 지워야 한다(운영 Terraform 밖 손 작업이면 지우는 것을 잊기 쉽다).
- **spec 대비:** 구체화.

### D-18 새 플랫폼의 의존성 업데이트 방식

**확정(사용자 2026-10-18, T05).** 호스팅형 Renovate App을 저장소별로 설치하고 자동 병합은 모두 끈다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **호스팅형 Renovate App(저장소별 설치) (확정)** | homelab Actions·키와 분리(옛 구성은 homelab Actions를 끄자 org 전체가 멈춤, spec §4.5). custom regex 매니저로 `host/versions.env`, 차트 버전, Application YAML까지 | 외부 App에 쓰기 권한 |
| homelab Actions의 self-hosted Renovate(옛 방식) | 옛 설정 재사용 | homelab Actions·App 키에 org 전체가 묶임 |
| Dependabot | GitHub 내장 | Argo CD Application·custom 버전 파일을 다루지 못함(추측) |

- **결정:** 호스팅형 Renovate App을 homelab과 앱 저장소에 저장소별로 설치한다. 자동 병합은 모두 끈다(옛 `renovate.json:129-132`의 인프라 자동 병합 금지 유지). Renovate PR은 자동 병합 조건 밖이라 사람이 병합하고, 봇 V1 기능 7의 리뷰 대상이 된다. ESO는 2~3주마다 minor가 나오므로 주 1회 묶음으로 받는다.
- **이유:** C.4.4의 "앱 이미지 외 모든 버전의 단일 갱신 주체".
- **spec 대비:** 제안(추천은 "설계 결과를 따른다").
- **미검증:** 호스팅형 Renovate App의 현재 이용 조건(E5에서 확인). **2026-10-21 결과: 통과(조건부, 부록 1 U20).** Community Cloud는 무료이고 저장소 수 제한이 없다. 제한은 org당 동시 job 1개와 4시간 주기다[S231][S234]. 쓰기 권한의 위험은 B.8 E5의 Renovate 행 장치로 막는다[S232]. 무료 조건이 바뀌면[S233] 부록 1 "틀리면" 열대로 self-hosted Renovate를 homelab과 분리한 별도 저장소 Actions로 옮긴다. 설정은 저장소 루트 `renovate.json`(자동 병합 끔, 월요일 0~6시 Asia/Seoul)이고, 설치는 그 PR 병합 뒤 사람이 homelab·`homelab-app-template`·`homelab-probe`에 한다(`files`는 T22 재연결 때). **첫 실행(2026-10-21 20:57 KST 첫 job):** Dependency Dashboard가 세 저장소에 열렸고 homelab 대시보드에 설정 경고·오류가 없다. 월요일 일정 대기 9건, `apps/*/image.yaml`과 자기 저장소 `repoURL`은 잡히지 않았다(T10 확인한 항목).

### D-20 시크릿 새로 발급·옛 값 미사용

**확정(사용자 2026-10-18, T05).** 모든 값을 새로 발급한다. 옛 자격은 E1(T06)에서 폐기한다. 예외는 옛 Telegram 봇 토큰(`보류(D-10, T22)`)과 옛 healthchecks ping URL(`보류(D-10, T08b)`)이다. SOPS age 개인 키는 T06 자격 폐기 완료를 확인한 뒤 지운다.

- **선택지:** 새로 발급(확정) / 옛 값 재사용.
- **결정:** 모든 값을 새로 발급해 Infisical에 등록한다. 옛 자격은 E1에서 폐기한다. healthchecks ping URL은 E4b가 새 체크를 만들고 초록인 것을 확인한 뒤 옛 체크를 지운다(T06 자격 폐기 표의 행은 `보류(D-10, T08b)`. E1·E3은 닫지 않는다). Telegram은 새 봇을 쓰고(D-10) 옛 봇 토큰은 새 구조에 넣지 않지만, 저장소 밖 `mac-uptime-guard`가 쓰므로 E1에서 폐기하지 않고 T22에서 그 처리와 함께 폐기한다(T06 자격 폐기 표의 행은 `보류(D-10, T22)`, E3의 보류 줄 닫기에서도 빠짐. D-10의 옛 봇 토큰 재발급 대안은 고르지 않았다). SOPS age 개인 키는 새 구조에서 쓰지 않으므로 T06 자격 폐기 완료를 확인한 뒤 지운다(옛 공개 히스토리의 SOPS 파일을 풀 수 있을지 모르는 키다).
- **이유:** 옛 값은 무만료 자격 11개를 포함하고(L18), 일부는 유출 사고 이력이 있다(2026-08-18).
- **spec 대비:** 일치, age 키 처리를 구체화.

### D-21 `homelab-app-template` 재사용

**확정(사용자 2026-10-18, T05).** 저장소·이름을 재사용하고 내용을 아래 목록으로 교체한다.

- **선택지:** 저장소·이름 재사용, 내용 교체(확정) / 새 저장소 / 템플릿 없이 CLI가 생성.
- **결정:** 재사용하고 내용을 바꾼다. 새 내용: Dockerfile(amd64, `ARG TARGETARCH` 기본값 없음), `/healthz`, `CODEOWNERS`(`* @<owner 계정>`, `app-main`의 code owner 리뷰용), 짧은 `build.yaml`(공통 워크플로를 태그로 호출, 호출 job에 권한 상한 선언), 로컬 compose(`127.0.0.1:` 접두), `infisical run` 개발 안내, 마이그레이션 예시, Renovate 설정. 옛 SealedSecrets 도구·인증서 사본, `.app-config.yml`, main 스키마 받기 CI는 지운다. 템플릿 저장소 자신의 main에도 `app-main`을 내용 교체 전에 건다(C.4.7, E5). 새 앱의 첫 main 내용이 사람 검토 없이 템플릿에서 오기 때문이다.
- **이유:** 저장소가 이미 있고 `is_template:true`다(0절). 앱 저장소에 배포 설정을 두지 않는 구조(C.2)에 맞춘다.
- **spec 대비:** 일치.

### D-22 앱 DB 마이그레이션 방식

**확정(사용자 2026-10-18, T05).** Argo CD Sync 단계 hook Job + `pg-rw` 직결. 이미 self-migration인 앱은 replicas 1에서 선택으로 허용한다.

- **선택지:** 앱 시작 시 self-migration / Argo CD hook Job(PreSync 또는 Sync. Sync 단계로 확정).
- **결정:** Sync 단계 hook Job(`BeforeHookCreation`, ExternalSecret 다음 wave) + `pg-rw` 직결, 앱은 시작 때 스키마 버전만 확인. expand/contract 필수. 이미 self-migration으로 짠 앱은 선택 사항으로 허용(replicas 1).
- **이유:** C.5.4 비교. PreSync는 첫 배포에서 Secret보다 먼저 돌 수 있다(추측). 실패가 sync 실패로 보인다.
- **spec 대비:** 제안(추천은 "비교 결과를 따른다").

### Kubernetes 시크릿 전달 계층

**확정(사용자 2026-10-18, T05).** ESO v2.13.x.

- **선택지:** ESO(확정) / Infisical Kubernetes Operator.
- **결정:** ESO v2.13.x, `external-secrets.io/v1`, 키 명시, `deletionPolicy: Retain`, `find`·`recursive` 금지.
- **이유:** C.6.1. Infisical Operator는 문서상 Kubernetes 1.33까지라 k3s 1.36과 맞지 않고(단일 근거[S16]), 장점인 auto-reload는 이 설계가 피하는 동작이다. ESO 선택은 이 버전 근거 없이도 선다: 원본 접속 실패 때 기존 Secret을 쓰지도 지우지도 않고 재시도하는 동작을 v2.13.0 소스로 확인했고[S24], 필수 키가 빠지면 Secret을 바꾸지 않는다[S23][S24]. Infisical Operator는 이 두 동작이 문서에 없다(C.6.1 표).
- **spec 대비:** 일치(C-07의 "ESO 우선 검토" 결론).

### D-25 rebuild → main 병합 방식

**확정(사용자 2026-10-18, T05).** squash 병합. spec D-03 문구를 이에 맞췄다.

- **선택지:** squash(확정) / merge commit(이 병합만 허용했다 되돌림).
- **결정:** squash. 저장소가 squash만 허용하고 병합 뒤 head 브랜치를 지우므로 `rebuild`가 사라진다. 옛 main은 새 main의 조상으로 남아 D-03의 히스토리 유지가 지켜지고, 중간 커밋은 PR 기록에 남는다. 병합 전 rebuild 작업 트리에서 자기 저장소 참조 revision이 모두 `main`인지 E2 검증 방법의 손 확인 명령으로 본다(L31의 내용. L31 자동 검사는 E5의 전체 `ci`에서 생긴다). 이 PR은 E1의 임시 ruleset 아래에서 owner가 검토한 뒤 관리자 bypass(`pull_request` 모드)로 병합한다(자기 PR이라 승인 불가, Actions가 꺼져 있어 `ci`는 아직 없음, E2).
- **spec 대비:** 일치.

### D-26 ChatGPT Codex Connector App 처리

**확정(사용자 2026-10-18, T05).** 유지하고 아래 조건 다섯을 건다(다섯째는 2026-10-22 U37 결과로 더함). 설치 범위 축소는 D-16(T15)과 함께 본다. D-16(확정(사용자 2026-10-18, T15))이 설치 범위를 선택 저장소로 줄이고 private `homelab-bot-ops`를 빼기로 정했다(사람 작업, "봇 결정(T15)"). 축소는 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 사람이 하기로 했고(T15), 2026-10-18 17:45에 완료했다(spec §11). `repository_selection` = `selected`는 API로 확인했고, 남긴 저장소 목록은 사용자 보고다(API 확인은 아직). 조건 (1)~(4)는 그대로다.

- **선택지:** 유지(확정) / 설치 범위 축소(선택 저장소, D-16과 함께 봄) / 제거.
- **결정:** 유지하되 조건 다섯을 건다: (1) homelab과 앱 저장소의 어떤 ruleset bypass에도 넣지 않는다, (2) 시크릿을 쓰는 `workflow_dispatch` 워크플로를 두지 않고, environment secret을 쓰는 워크플로는 트리거를 `workflow_run` 하나만 둔다(actions write로 `workflow_dispatch`를, contents write로 `repository_dispatch`를 일으킬 수 있어서. D-04 확정으로 넓힘, ci의 workflow-guard가 확인), (3) 배포 키는 앱 main push의 태그 고정 `app-build`만 OIDC claim으로 꺼내고, 병합 키는 environment `automerge`(배포 브랜치 main)의 secret이라 `deploy-merge`의 merge job만 쓴다(C.4.6, C.4.8), (4) 앱 저장소는 public만 두고(D-29) 그 main과 `homelab-app-template` main에 `app-main`을 건다. 자동 배포는 `app-main`이 active로 확인된 앱에서만 일어난다(C.4.7 조건 9), (5) homelab과 앱 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`(`infra/github/app-repos.json`의 앱 저장소), 이후 새 앱)에 Codex 클라우드 작업 환경(environment)을 두지 않는다(사용자 결정 2026-10-22 "환경 안 둘게"). 리뷰(`@codex review`, 자동 리뷰)와 로컬 Codex CLI는 환경 없이 그대로 쓴다. 환경이 없으면 `@codex` 작업이 시작되지 않아 Codex가 owner 권한으로 병합 API를 부르는 길이 없다(U37). 앱 저장소에 환경이 있으면 owner 권한 병합이 곧 자동 배포로 이어진다. 환경을 만들게 되면 그 전에 U37을 다시 시험한다. 설치 범위 축소는 D-16(봇 PR 리뷰)과 함께 본다.
- **이유(앱 저장소까지 본 판단):** 권한이 spec 서술보다 넓다(org 전체 저장소에 contents·workflows·actions write, issues write 포함, 0절). 자동 배포는 앱 저장소 main을 믿으므로, 앱 main을 바꿀 수 있는 신원이 곧 배포 주체다. 지금 앱 저장소에는 보호가 없어 이 App이 앱 main에 직접 쓸 수 있다(spec §4.5. `files`·템플릿은 2026-10-18 결정 5 하드닝으로 막혔다, 0절 8항). 새 구조에서 유지 결정이 성립하는 근거는 넷이다. (a) homelab main은 ruleset B가, 앱 저장소 main과 모든 새 앱의 첫 main 내용이 되는 `homelab-app-template` main은 `app-main`이 막아 이 App의 설치 토큰으로는 바꿀 수 없다(템플릿·`files`는 결정 5 하드닝이 E5보다 먼저 건다, C.4.7). 처음에는 code owner 승인 요구에 기댔지만 owner PR에서는 쓰기 권한 App 승인 하나로 요건이 찼으므로(U08 (나)), 2026-10-21부터 main 갱신 제한(Restrict updates)이 막는다(apply 뒤 재시험에서 bypass 없는 App의 병합 405 확인, U08). 다만 Codex가 만든 PR은 사실상 늘 owner 계정으로 찍혀 승인 관문이 없고, owner가 bypass 병합 전에 하는 검토가 유일한 관문이다(C.4.7). (b) 브랜치에서 워크플로 파일을 바꾸거나 run을 재실행해도 App 키를 얻지 못한다(배포 키는 claim이 ref·이벤트·워크플로 파일을 고정하고, 병합 키는 environment 배포 브랜치 정책이 main 밖 실행을 거부한다). main의 워크플로가 `automerge`를 쓰는 것은 workflow-guard와 사람 검토가 막는다. 설치 범위 축소·제거를 볼 때는 이 guard의 효력과 함께 본다: Codex Connector를 선택 저장소로 줄이면 `repository_dispatch`·`workflow_dispatch`·issue 경로의 위험이 함께 준다. `deploy-merge` 재실행은 같은 PR을 처음부터 다시 검사하므로 결과가 같다(C.4.7). (c) 앱 저장소는 public만이라(D-29) 보호되지 않는 앱 main이 없다. (d) 무료 PR 리뷰의 가치가 있다. 성립 조건이 깨지는 경우: 앱 저장소의 `app-main`이 빠지거나 꺼지면 조건 9가 그 앱의 자동 병합을 멈춘다. 템플릿의 `app-main`이 빠지거나 꺼지는 것은 조건 9가 보지 못하므로 Terraform guard(`homelab github verify`, C.3.9)가 잡고, `homelab app new`는 저장소를 만들기 전에 템플릿 main의 `app-main`이 active인지 읽어 아니면 멈춘다(C.7). Codex PR을 owner가 내용을 보지 않고 bypass 병합하면 이 App이 곧 변경 주체가 된다. homelab이나 앱 저장소에 Codex 작업 환경을 만들면 조건 (5)가 깨진다: 행위자가 owner라 관리자 역할 bypass로 update 규칙도 넘을 수 있고, 앱 저장소면 그 병합이 곧 자동 배포다. 그래서 만들기 전에 U37을 다시 시험하고, 된다면 설치 범위를 줄이거나 제거한다. Codex Connector 설치 토큰으로 owner PR을 승인하고 병합하는 길은 Restrict updates로 막힌다(재시험은 같은 권한 꼴의 배포 App으로 확인). Codex가 owner 권한(사용자 토큰)으로 병합 API를 부르는 길은 저장소에 Codex 작업 환경이 없어 지금은 열리지 않는다(U37 통과(조건부), #828, 조건 (5)). 외부인이 public 저장소의 PR·댓글로 Codex를 부를 수 있는지는 미검증이다(U38). 시험 대신 "틀리면" 열의 대책을 먼저 걸었다: org interaction limit `collaborators_only`와 저장소 다섯의 PR 생성 Collaborators only(2026-10-22, D-29). 설치 범위는 이미 선택 저장소다(D-16). 이 위험이 더 크다고 보면 설치를 제거한다. 배포 PR에도 리뷰가 달려 사용량을 쓸 수 있다(작성자별 제외 가능 여부는 미검증).
- **spec 대비:** 일치, 조건 추가. Draft PR이 자동 리뷰를 피하는지는 여전히 미검증.

### D-27 NUC 로컬 전용 자료를 T06 입력으로 쓸지

**확정(사용자 2026-10-18, T05).** T06 목록 작성에만 읽기 전용으로 쓰고, 값·절차 원문은 저장소 문서에 옮기지 않는다.

- **선택지:** 읽기 전용으로 쓰고 이름만 옮김(확정) / 쓰지 않음.
- **결정:** spec 추천대로 T06 목록 작성에만 읽기 전용으로 쓰고, 값과 절차 원문은 저장소 문서에 옮기지 않는다. T04는 읽지 않았고, 로컬 자료 없이 판정하지 못한 곳은 B.9의 셋이다.
- **spec 대비:** 일치.

### D-28 GitHub 보호 설정 관리 방식

**확정(사용자 2026-10-18).** Terraform 개선안(T1). spec에 없던 결정이고, A.4 4번의 원안(JSON + `gh api`)을 바꿨다.

| 선택지 | 장점 | 단점 | 판정 |
|---|---|---|---|
| **T1 Terraform 개선안:** ruleset·environment·Actions 권한만 리소스, 저장소 설정은 guard로 확인 | plan 미리보기와 필드 정규화를 provider가 한다. Cloudflare·Tailscale root와 도구·state·래퍼를 함께 쓴다. import로 이름 변경과 편입을 보호 공백 없이 한다 | provider 버그(#3519 미수정[S192]), 신기능 지원 지연(fork PR 승인 정책 미지원[S191]), state·잠금 관리, HCL guard가 읽기 어렵다 | **확정** |
| J JSON + `gh api` 적용·대조 스크립트(원안) | state·잠금·provider가 없다. 모든 REST 필드를 바로 쓴다. 새 앱 보호 공백이 0이다 | 미리보기와 정규화를 직접 짜고 유지해야 한다(정규화 버그가 "차이 없음" 거짓말을 할 수 있다). Terraform이 어차피 남아 운영 도구가 둘이 된다 | 검토 후 제외 |
| T2 T1 + `github_repository`까지 관리 | 저장소 설정을 선언하고 손 변경을 되돌린다. 새 앱 저장소와 ruleset을 한 apply로 만든다 | 옛 사고의 그 리소스를 다시 들인다. 기본값 없는 bool이 많아 빠뜨리면 기능을 끄자고 제안한다. 삭제 방어가 얇다: import 직후에는 `archive_on_destroy`가 state에 없고, 토큰 범위 검사는 열린 채 실패할 수 있으며, Free에서는 fork가 하나라도 생기면 삭제한 저장소를 복원할 수 없다[S197] | 검토 후 제외 |
| X Terraform + CI plan | 사람이 잊어도 드리프트가 보인다 | admin이 아닌 토큰에는 bypass 목록·병합 설정이 안 보여 허위 드리프트가 구조적으로 생긴다[S191][S196]. 없애려면 admin 키를 CI에 줘야 해 "자동화에 admin 자격을 주지 않는다"와 충돌한다 | 검토 후 제외 |

- **결정:**
  - `infra/github` Terraform root. 리소스는 `github_repository_ruleset`, `github_repository_environment`(+ deployment policy), `github_actions_repository_permissions`, `github_workflow_repository_permissions`만이다. `github_repository`와 시크릿 리소스는 두지 않는다. 저장소 설정(`allow_auto_merge=false`, squash만, 병합 뒤 삭제 등)은 guard로 확인만 하고 값은 `gh api`로 맞춘다. fork PR 승인 정책은 provider 미지원이라 `gh api` PUT + guard다.
  - 실행은 owner 로컬만. 래퍼(E5 `tools/tf-github.sh`, E7부터 `homelab github plan`·`apply`·`verify`): `GITHUB_TOKEN`은 환경변수로만(기본 `gh auth token`, 또는 만료 있는 fine-grained PAT, `-var` 금지), `GITHUB_APP_ID`·`GITHUB_APP_INSTALLATION_ID`·`GITHUB_APP_PEM_FILE` unset, 토큰 종류별 확인(classic·OAuth는 범위를 끝까지 읽어 비었거나 `delete_repo`가 있으면 거부, pipefail·SIGPIPE로 열린 채 실패하지 않게. fine-grained PAT는 만료 머리글을 확인하고 저장소 삭제 방어가 없다는 대가를 진다), 고정 URL에서 main을 새로 clone한 사본에서만 실행(`env -i`로 hook·전역 git 설정 차단. plan도 코드를 실행한다. 작업 사본의 override 파일·`TF_CLI_ARGS*`·`TF_LOG*` 차단, `TF_CLI_CONFIG_FILE`은 래퍼 소유 설정 파일로 고정해 `~/.terraformrc`의 `dev_overrides`를 막음), `plan`·`verify`는 `-lock=false`, `rm -f tfplan` 후 plan, 종료 코드 0·2만 허용, plan에 delete가 있으면 `--allow-destroy` 없이는 멈춤, apply 전 state pull 백업, apply가 실패하면 그 plan의 ruleset을 state rm 후 import(provider v6.13.0 #3519 etag 버그 대응, 수정 #3637 미출시[S192]). provider 6.13.0 정확 핀(legacy 클라이언트)과 `.terraform.lock.hcl` 변경은 사람이 확인한다.
  - guard는 check 블록이 아니라 `github_rest_api` 데이터 소스 postcondition이다(실패하면 plan 오류[S193]): 토큰 admin 여부, 저장소 설정, 저장소별 ruleset 이름 집합과 개수, ruleset별 bypass 허용 목록과 exempt 금지, `codeowners/errors` 빈 배열, 옛 브랜치 보호 404, fork PR 승인 정책, org public 저장소 완결성, 그리고 D-04의 environment `automerge` 브랜치 정책·secret 이름과 repo·org secret 0개. guard 실패가 모든 apply를 막을 때의 비상 경로(`-target` 재생성 뒤 전체 verify)를 런북에 둔다(C.3.9).
  - App ID는 숫자 리터럴이다. private App의 ID는 익명 조회가 안 되는 값이라 공개 HCL에 처음 노출된다는 점을 기록한다(자격은 아니다).
  - state: R2 `homelab-tfstate`의 `v2/github/terraform.tfstate`, `use_lockfile = true`. R2 PutObject의 `If-None-Match` 원자성[S37]과 S3 backend lockfile 구현[S195]으로 U02는 문서·소스로 확인됐고, E4a에서 동시 실행 시험 1회만 남았다. R2는 versioning이 없으므로 래퍼가 백업한다.
  - CI: `fmt -check`, `init -backend=false`, `validate`, `terraform test`(mock_provider, 모든 guard 인스턴스에 정상 JSON을 override한 뒤 하나만 망가뜨림[S194]). CI에서 plan하지 않는다.
  - E1의 `main-interim`과 옛 브랜치 보호 DELETE, E2의 `ci` ruleset은 `gh api`로 하고 E5에서 import한다(`ci` → `main-checks` 제자리 이름 변경).
- **이유:** T1과 J는 둘 다 owner admin 토큰만 쓰고, 저장소를 지울 길이 없고, 시크릿이 없고, 관리 밖 ruleset·bypass를 잡는다. T1이 앞서는 것은 plan 미리보기, provider가 하는 정규화, Cloudflare·Tailscale root와 같은 도구·state·래퍼다. 사용자가 Terraform을 선호하고 Terraform이 어차피 남는다. #3519가 필드 단위 안전성을 J보다 약하게 만드는 점은 래퍼의 apply 실패 뒤 재import로 메운다.
- **대가:** provider 버그가 들어오고 GitHub 신기능 지원이 늦다(fork PR 승인 정책은 아직 미지원[S191]). owner 토큰과 R2 키가 provider 프로세스에 들어간다(래퍼의 `origin/main` 임시 worktree 실행, provider 핀, lock 파일 사람 확인으로 줄인다). fine-grained PAT를 쓰면 범위는 좁아지지만 저장소 삭제 방어가 없다. guard가 HCL `jsondecode`·`for` 식이라 TypeScript보다 읽기 어렵다. guard 하나가 실패하면 모든 plan이 멈춘다(비상 경로). 새 앱은 `app-repos.json` PR을 병합한 뒤에야 apply할 수 있다(래퍼가 fetch한 `origin/main`에서만 돈다, C.7). CI에서 드리프트를 감시하지 않는다: 대조는 사람이 verify를 돌릴 때만 한다(월 1회와 콘솔 수정 뒤).
- **선택지로만 기록:** 무인 부분 감시. 기본 `GITHUB_TOKEN`으로 하루 1회 ruleset 목록·rules·`updated_at`을 기대값과 비교한다. public 저장소에서는 Metadata read로 읽히지만 bypass 내용, 병합 설정, fork PR 정책, 브랜치 보호는 보지 못한다. R20(무인 감시 없음)을 바꾸는 일이라 채택하지 않았다.
- **spec 대비:** 해당 없음(새 결정).
- **미검증:** R2 잠금 동시 실행(U02). guard HCL과 mock 시험(U35)은 2026-10-21~22 통과(fine-grained PAT 만료 머리글만 미실행, 부록 1).

### D-29 저장소 공개 정책

**확정(사용자 2026-10-18).** 앱 저장소는 public만 허용한다. 앱이 아닌 저장소는 공개하지 않는다. spec에 없던 결정이다.

| 선택지 | 장점 | 단점 | 판정 |
|---|---|---|---|
| **A 앱 저장소는 public만** | Free에서 ruleset, environment, attestation이 public 저장소에만 있어(0절, [S102][S174]) 모든 앱이 같은 보호와 자동 배포를 받는다. private 분기(attest 건너뛰기, 사람 병합 경로, E9·E10 private 기준)와 GHCR pull 자격(classic PAT, `imagePullSecrets`)이 빠진다 | 코드·이슈·Actions 로그·이미지가 되돌릴 수 없게 공개된다. 외부인 PR·댓글이 봇과 Codex의 입력이 될 수 있다. public 패키지는 다시 private이 안 된다[S96] | **확정** |
| B 앱마다 public·private 선택(옛 설계) | 코드를 숨길 수 있다 | private 앱은 Free에서 main 보호가 없고 attestation을 만들 수 없어 자동 배포가 안 되며, pull 자격이 필요하다. GitHub Team으로 올려도 풀리지 않는다: attestation은 Free·Pro·Team에서 public 저장소 전용이고 private은 Enterprise Cloud다[S174]. Team으로 얻는 것은 private 앱 main 보호(ruleset)뿐이고 배포 PR은 계속 사람이 병합한다 | 검토 후 제외 |
| C 비앱 저장소까지 공개 | 규칙이 하나다 | `aiops`·`aiops-autodeploy-canary`·`mac-uptime-guard`는 배포되는 앱이 아니라 공개 이득(보호·자동 배포)이 없고 노출만 남는다 | 검토 후 제외 |

- **결정:**
  - **앱 저장소:** public만 허용하고 설계의 private 앱 경로를 모두 지웠다. `homelab app new --private`은 없고, `homelab app add`는 private 저장소와 익명 GHCR pull이 안 되는 패키지를 거부한다(C.7). deploy-pr job은 늘 attest한다(가시성 분기 없음, C.4.1). GHCR pull 자격(classic PAT, `imagePullSecrets`, ExternalSecret)은 두지 않는다(C.4.5, C.4.10). 조건 9(public + `app-main` active + 유효한 `CODEOWNERS`)는 저장소가 private으로 바뀌거나 규칙이 꺼질 때 자동 병합을 멈추는 fail-safe로 남긴다(C.4.7).
  - **GHCR 패키지:** `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는지 문서끼리 어긋난다[S96][S213]. E5에서 org Package Creation의 Public 허용을 확인한 뒤 `homelab-probe` 첫 push로 시험한다(U39). 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다(되돌릴 수 없다). public 패키지는 다시 private이 안 된다[S96].
  - **public 앱 저장소 기본 설정:** org와 저장소의 fork PR 승인 `all_external_contributors`[S198], secret scanning·push protection 켬, private vulnerability reporting 켬[S214]. Actions 로그 보존 단축은 검토한다. interaction limit `collaborators_only`(최대 6개월이라 6개월마다 갱신)와 PR 생성 Collaborators only는 Codex 외부 호출 시험(U38) 대신 2026-10-22에 먼저 걸었다(org limit 만료 2027-04-22, 저장소 다섯의 `pull_request_creation_policy=collaborators_only`)[S214]. 배포 이미지 빌드(push job)는 캐시 없이 한다(C.4.1). 봇은 모델 호출 전에 `author_association`을 확인한다(C.8). D-23 금지 항목(tailnet 이름, Tailscale IP 등)을 앱 저장소의 코드·로그·이미지까지 넓히고 템플릿 CI에 금지 패턴 검사를 둔다(D-21). 새 앱은 `homelab app new`가 설정을 켜고 Terraform guard가 확인한다(C.3.9, C.7). PR 생성 `pull_request_creation_policy=collaborators_only`도 `homelab app new`가 켜고 guard 2가 확인한다. org interaction limit과 만료 45일 전 경고도 guard 2가 본다(C.3.9, 사용자 결정 2026-10-22 17:50). interaction limit은 org 단위라 새 저장소에 따로 걸지 않는다(org limit이 저장소 limit을 덮는다).
  - **비앱 저장소:** `aiops`와 `mac-uptime-guard`는 쓰지 않으며 제거(삭제)한다. `aiops-autodeploy-canary`는 공개하지 않고 private으로 보관한다(삭제도 가능). 실행은 T22다. `mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤(D-10) 저장소를 지운다. `mac-uptime-guard`는 처음에 private 보관이었고, 2026-10-18 17:46 사용자 결정("aiops와 mac-uptime-guard는 제거예정")으로 제거로 바뀌었다. 앱이 아닌 저장소를 공개하는 일은 없다.
  - **봇 저장소(D-13 확정(사용자 2026-10-18, T14)):** 봇 코드 저장소는 `ukyi-app/homelab-bot`(public)이다. 운영 산출물(evidence, handoffs, runtime-policies 실제 값, DISCOVERY의 내부 경로, 허용 목록 실제 값)은 봇 저장소에 두지 않는다: 개발 산출물은 private 저장소 `ukyi-app/homelab-bot-ops`, 봇이 실행 중 읽는 값은 Infisical `/apps/homelab-bot/`(C.8). 옛 `aiops` 저장소와 App은 재사용하지 않고 제거한다.
  - **`page`·`trip-mate-api`:** 쓰지 않으므로 저장소와 GHCR 패키지를 삭제했다(2026-10-18 결정·실행, 0절 7항). 남는 앱 저장소는 `files`와 `homelab-app-template`이다. 두 앱의 옛 자격(trip-mate-api의 Google OAuth client, OXR app id, `BETTER_AUTH_SECRET`, page admin token)은 T06 자격 폐기 표에서 폐기한다(E1). 두 앱은 재연결 대상이 아니다(E10).
- **지금 하드닝(사용자 결정 5, 2026-10-18 결정·실행):** 지금 열린 구멍(public 앱 저장소 main 보호 0개, fork PR 승인 `first_time_contributors`, Codex Connector의 org 전체 쓰기, 0절 8항)을 E5보다 먼저 막는다. `files`와 `homelab-app-template`에 `.github/CODEOWNERS`(`* @<owner 계정>`)와 `app-main` ruleset(PR 필수, 승인 1, code owner, 새 push 때 승인 무효화, force push·삭제 금지, bypass 저장소 관리자 역할 `pull_request` 모드), secret scanning·push protection, 저장소와 org의 fork PR 승인 `all_external_contributors`를 건다. 자동 권한 검사가 에이전트 실행을 막아 사람이 스크립트로 실행했다(2026-10-18). U08 셋째 조건의 첫 실측인 `current_user_can_bypass`는 두 저장소 모두 `pull_requests_only`였다. E5는 이 `app-main`을 import한다(C.3.9). 커밋 이메일: 커밋 작성자 이메일 공개는 사용자가 받아들였다(2026-10-18). GitHub 이메일 비공개 설정은 하지 않고, 작업 사본은 전역 설정(개인 이메일)으로 커밋한다.
- **이유:** Free에서 서버 쪽 강제와 출처 확인은 public 저장소에만 있다. 자동 배포는 앱 main을 믿으므로 앱 main을 보호할 수 있어야 하고, 그러려면 public이어야 한다. 규칙이 하나면 private 분기와 pull 자격, 그 미검증 항목(옛 U30 (4))이 빠진다. 비앱 저장소는 배포되지 않아 공개 이득이 없다.
- **대가:** 코드·이슈·Actions 로그·public 이미지가 되돌릴 수 없게 공개된다. private으로 돌려도 노출은 회수되지 않고 보호만 사라진다. 외부인 입력이 봇·Codex로 들어가는 경로, 공개 로그 안에서 배포 키를 다루는 경로, 앱 저장소에서 tailnet 이름 같은 내부 정보가 새는 경로를 위 기본 설정으로 막아야 한다(C.4.10). U39가 통과해 첫 push 패키지가 public이었다(부록 1). 문서끼리 어긋나는 동작이라 GitHub가 바꾸면 새 앱마다 패키지 Public 손 전환이 다시 생길 수 있고, 그때는 `homelab app add`의 GHCR 익명 확인이 멈춰 알린다.
- **spec 대비:** 해당 없음(새 결정).
- **미검증:** Codex 외부 호출(U38. 시험 대신 대책을 먼저 걸었다, 부록 1), U08 셋째 조건의 실제 bypass 병합(하드닝의 `current_user_can_bypass`는 `pull_requests_only`). 패키지 가시성 상속(U39)은 통과했다(2026-10-21 `homelab-probe` 첫 push 패키지가 `public`, 부록 1).

### D-30 내부 UI 짧은 주소

**확정(사용자 2026-10-20).** D-08의 `*.ts.net`은 그대로 두고 tailnet 전용 리다이렉터 `go`를 더한다. 사용자 요구는 "주소를 짧게, 그러나 장애·보안 위험은 늘리지 않기"였다. 세 에이전트(Claude Opus 5.5, Codex gpt-6-astra, DeepSeek V4.1 Flash)가 같은 과제를 따로 검토했고, 셋 모두 `*.lab.ukyi.app`에 반대했다. 둘은 기기 즐겨찾기, 하나는 리다이렉터를 추천했고 사용자는 리다이렉터를 골랐다(즐겨찾기는 두지 않음).

| 선택지 | 주소 예 | 판정 |
|---|---|---|
| D-08 그대로 | `argocd.<tailnet>.ts.net` | 짧은 입력 없음 |
| **`go` 리다이렉터** | `go/argocd` | **확정** |
| 기기 즐겨찾기·홈 화면·텍스트 대체만 | 입력만 줄고 주소는 같음 | 검토 후 제외(사용자 선택) |
| `*.lab.ukyi.app`(공개 A 레코드 + `_acme-challenge` 위임 + 내부 Traefik) | `argocd.lab.ukyi.app` | 검토 후 제외 |
| 사설 CA + 짧은 이름 | `argocd.internal` | 검토 후 제외 |
| Cloudflare Access로 공개 | `argocd.ukyi.app` | 검토 후 제외 |
| Cloudflare WARP private hostname | `argocd.<내부 이름>` | 검토 후 제외 |
| tailnet 이름을 fun name으로 | `argocd.<생성된 이름>.ts.net` | 검토 후 제외 |

- **결정:** C.3.5 "짧은 주소"대로다. 리다이렉터는 상태 없는 웹 서버 파드 하나와 operator LoadBalancer 프록시 기기 하나다. 규칙이 패턴이라 Grafana(T08b)와 앱 내부 노출(T10 `internal.name`)이 등록 없이 따라온다. VM은 `vm-go`가 `vm-<이름>`으로 보낸다. ACL은 `tag:k8s-go`를 새로 두고 `autogroup:member → tag:k8s-go:80`만 연다. `go`와 `vm-go`는 모든 클러스터에서 앱 내부 이름으로 쓸 수 없게 예약한다. 실행은 T08c이고, VM 실접속은 T13 시나리오 13에서 본다.
- **이유:** 새 자격이 없다(인증서·DNS 쓰기·ACME 계정 없음). 공개 DNS와 CT에 새로 실리는 것이 없다. 이름 풀이는 D-08처럼 기기 안의 MagicDNS라 AdGuard·공개 DNS·집 인터넷과 무관하다. `go`가 죽어도 전체 주소가 그대로라 장애가 짧은 입력에서 멈춘다.
- **대가:** 첫 구간은 평문 HTTP다(WireGuard 안, 링크 이름만 담김). 주소창의 최종 주소는 여전히 길다. 파드·tailnet 기기·ACL 규칙이 하나씩 늘고, tailnet 도메인을 실행 때 넣는 경로가 생긴다. 이름 `go`를 예약한다. 처음 보는 단일 라벨 입력은 모든 브라우저가 검색어로 보낸다(사용자 확인 2026-10-21). 그래서 기기·브라우저마다 처음 한 번 `http://go/<이름>`으로 열고, 그 뒤 스킴 없는 `go/<이름>`을 쓴다(사용자 결정 2026-10-21 "1번으로 되긴하네 그냥 이렇게 하지뭐". 맥 Safari·Chrome 확인, 아이폰 Safari는 2026-10-22 확인).
- **검토 후 제외한 안과 이유:**
  - `*.lab.ukyi.app`: (1) 관리 화면과 공개 앱이 같은 등록 도메인 `ukyi.app` 아래라 브라우저에서 같은 사이트가 된다[S226]. 공개 앱이 침해되면 `Domain=ukyi.app` 쿠키를 심을 수 있고 SameSite 쿠키가 CSRF 방어가 되지 못한다. `ts.net`은 Public Suffix List 항목이라 tailnet마다 다른 사이트다[S225]. (2) 이름 풀이가 기기 안 MagicDNS에서 공개 DNS로 옮겨간다. TTL Auto가 300초라[S227] 집 인터넷이 끊기면 약 5분 뒤 이름이 안 풀린다. 평문 공용 DNS 경로에서 답이 위조되면 남는 방어는 TLS뿐인데, 그 인증서를 낼 수 있는 위임 zone 토큰이 클러스터 안에 있다. (3) 공개 A 레코드가 입구 기기의 Tailscale IP를 담는다. 그 IP가 공개 DNS에 실리고(D-23 취지와 충돌), 재등록·IP 변경 때마다 사람이 apply해야 한다(2026-10-20에 실제로 IPv4를 바꿨다). (4) Cloudflare 하위 zone은 Enterprise 전용이라[S228] 도전용 별도 등록 도메인이 필요하고, 그 갱신·결제가 새 장애점이다. CAA `accounturi`로 좁히면 재구축으로 ACME 계정 키를 잃을 때 갱신이 조용히 막힌다. (5) 내부 Traefik 하나가 모든 내부 UI의 공통 장애점이 되고, 비상구로 남길 `*.ts.net` 인증서가 계속 CT에 실려 CT를 줄이는 효과도 작다.
  - 기기 즐겨찾기만: 새 부품이 없어 가장 안전하지만 기기마다 등록해야 한다. 사용자가 리다이렉터를 고르며 함께 두지 않기로 했다.
  - 사설 CA: 가장 짧지만 기기마다 루트 신뢰를 설치·회수해야 하고, CA 키가 새 경계가 된다(이름 제약이 없으면 신뢰한 기기에서 모든 사이트를 위조할 수 있다).
  - Cloudflare Access: 관리 화면을 인터넷에 낸다. Access 설정 하나가 경계이고, Cloudflare 장애 때 공개·관리 경로가 함께 멈춘다.
  - WARP private hostname: iOS·Android는 VPN을 하나만 켤 수 있어[S223] Tailscale과 함께 쓸 수 없다.
  - fun name: 생성된 후보에서만 고르고 길이 차이가 작다. HTTPS에 쓴 뒤에는 다시 뽑을 수 없고 기존 링크가 깨질 수 있다[S221].
  - golink: 자체 `TS_AUTHKEY`·SQLite·영속 볼륨이 필요하다[S224]. 규칙이 패턴이라 링크를 손으로 관리할 일이 없어 정적 리다이렉터로 충분하다.
- **spec 대비:** 없음(2026-10-20 새 결정).
- **미검증:** `https://go/` 거부는 맥에서만 확인했다. 로그 저장소의 시험 쿼리 0건은 T08b 뒤에 본다(T08b 완료 조건). **확인(2026-10-22 18:37~18:38):** 경로·쿼리 유지 재확인 뒤 `go` 파드 로그 0줄·시험 쿼리 0건, Tailscale을 끈 기기에서 `go`가 풀리지 않음(사용자 "둘다 확인했어. 잘돼.", approvals 18:37·18:38 행). **확인(2026-10-22):** 아이폰 Safari(셀룰러, Tailscale 켬)에서 처음 한 번 `http://go/argocd`로 연 뒤 스킴 없는 `go/argocd`가 열림(사용자 "둘 다 잘 열려"), `go` 파드 0개 동안 전체 주소 200이고 원복 뒤 `go/` 복구(approvals 2026-10-22 11:05~11:06 행), `values-vm.yaml` 렌더의 Service hostname `vm-go`·리다이렉트 접두 `vm-`(T08c). **확인(2026-10-21):** 맥 Safari·Chrome의 입력 방식·Argo CD·AdGuard·경로·쿼리 유지·404·`https://go/` 실패(사용자 "전부 잘 열려", approvals 16:15 행), 프록시 기기 이름 `go`(접미 번호 없음)와 svclb DaemonSet 없음(approvals 15:14 행).

### 봇 결정(T15)

**확정(사용자 2026-10-18, T15).** 봇 결정 게이트 D-14~D-17·D-24와 V1 범위 조정이다. 결정 본문과 근거는 spec §5.1이고, 여기에는 이 설계에 주는 변경과 쓰는 곳만 둔다. D-14는 권장안(OpenAI API 프로젝트 키)이 아니라 사용자가 고른 안이다. D-15는 사용자가 D-14 구독 인증 파일의 유출 경로 설명(GitHub를 열면 남의 토큰으로 gist·push 유출 가능)을 듣고 골랐다.

| ID | 결정 요지 | 이 설계에서 쓰는 곳 |
|---|---|---|
| D-14 | 봇 전용 ChatGPT 구독 계정 + 작업자 전용 `CODEX_HOME`. 개인 `~/.codex*` 사용·복사 금지, 한도·인증 만료 때 다른 계정·인증으로 자동 전환하지 않고 waiting, 작업 직렬 1개, 인증 갱신본을 되쓰는 작업자 전용 영속 쓰기 공간, 옛 구독 OAuth 프록시·다계정 순회 재사용 금지. 남는 위험: 공식 문서가 이 경로를 public 저장소에 쓰지 말라고 적는데[S219] 리뷰 대상은 public이다. 적용 범위는 [미검증]이고 OpenAI 확인 항목이다(spec §10) | C.8 격리 행(모델 자격과 영속 쓰기 공간), E4b, E9 |
| D-15 | NUC 클러스터 안. 게시 서버는 ns `app-homelab-bot`, 작업자는 `sandbox` ns의 상주 파드(동시성 1). 라벨 `homelab-bot`, 앱·작업자 포트 8080, 경보 수신 8081. 작업자 코드 읽기는 `codeload.github.com` 압축본만(egress에서 `github.com`·`api.github.com`·gist 제외, 작업자에 GitHub 자격 없음), `git init` 한 번 커밋, base·head 압축본으로 diff. push와 PR 생성은 게시 서버가 D-24 App으로. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft | C.8 격리 행·경보 수신 행·봇 자리 Application, E4b, E9, 부록 1 U13 |
| D-16 | 기본안(전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버). 봇이 리뷰하는 저장소는 Codex 자동 리뷰를 저장소별 Codex 설정에서 끈다(사람 작업, 수동 `@codex review`는 남김). Codex Connector는 선택 저장소로 줄이고 `homelab-bot-ops`를 뺀다(사람 작업, `homelab-bot-ops` 첫 push 전, spec §11. 2026-10-18 17:45 완료). 하위 결정(새 ID 없음): 허용 봇 작성자 목록(`user.type`이 `Bot`이고 숫자 `user.id`가 목록에 있으면 통과. 초기 목록은 호스팅형 Renovate와 D-24 App의 봇 사용자. 배포 갱신 App·Codex Connector·옛 writer 제외, fork PR 제외, 댓글은 `comment.author_association`을 보고 Bot 댓글 무시, `CONTRIBUTOR` 불허, 실제 ID는 Infisical에만) | C.8 리뷰 App 행·webhook 행, F D-26 |
| D-17 | 봇 전용 개인 Discord 서버. Gateway로 받고 Interactions Endpoint는 비워 공개 수신 경로가 늘지 않는다. 실제 서버·채널·사용자 ID는 Infisical `/apps/homelab-bot/`에만. DM 허용과 브리핑 시각은 T16a에서 정했다(확정(사용자 2026-10-20): DM 끔, 브리핑 매일 08:50 Asia/Seoul) | 플랫폼 변경 없음(봇 공개 경로는 GitHub webhook 하나 그대로, C.8). E9 사람 작업 |
| D-24 | 봇 전용 쓰기 GitHub App: Contents write + Pull requests write + Metadata read, Workflows·Actions·Administration·Issues 없음, webhook 끔, 선택 저장소 설치, 작업마다 저장소 하나로 좁힌 1시간 토큰. 병합 API·`/merges`·`repository_dispatch`·update-branch·GraphQL 병합은 게시 서버 허용 목록이 막는다. `.github/workflows` 변경 PR은 만들 수 없다(범위 축소). 토큰 분리, ruleset E, App 이름·설치 저장소, 허용 파일 경로는 T19에서 정한다 | C.8 봇 변경 PR 행, C.4.7 |
| V1 범위 | 안 3: 단계별 제한 시범 운영(단계마다 사람 승인과 approvals 기록)과 T16 분할(T16a 로컬·mock은 T15 뒤 바로, T16b 실연동·첫 배포는 T13 뒤). 기능 수는 줄이지 않는다 | E.0, E9, E.2 |

- **D-26과의 관계:** D-26이 "D-16과 함께" 미룬 설치 범위 축소는 D-16에서 선택 저장소로 정했고, 사람이 2026-10-18 17:45에 실행했다. D-26의 조건 (1)~(4)는 그대로이고, 2026-10-22에 (5)(Codex 작업 환경을 두지 않음, U37)를 더했다.
- **App 생성 시점:** 리뷰 App(D-16)은 T17, 쓰기 App(D-24)은 T19에서 사람이 만든다. E9(T16b)는 App 없이 첫 배포한다.
- **spec 대비:** D-14는 spec §5.3 추천 기본값("전용 계정과 전용 CODEX_HOME. 자동 호출 약관 확인 후 결정")의 구독 쪽이고, 약관 확인은 위 [미검증]으로 남았다. D-15·D-16·D-24는 spec §5.3 추천 기본값을 구체화했다. D-17의 spec §5.3 추천 기본값은 "사용자 제공"이었고, 결정은 에이전트 추천을 사용자가 수락한 것이다.

### 추가 확인 (T05에서 설계 기본값으로 확정)

사용자가 2026-10-18에 T05 질문에 답해 모두 이 문서의 기본값대로 확정했다. Argo CD 공개 webhook은 사용자가 설명을 듣고 직접 골랐다("두지않고 폴링으로 하자").

| 항목 | 확정한 기본값 | 근거 |
|---|---|---|
| CI의 App 키 전달 방식(T09 → T10 답) | **확정(사용자 2026-10-18, D-04):** 배포 키는 Infisical OIDC Auth 실행 시 조회(claim으로 묶음), 병합 키는 Secret Sync → homelab environment `automerge`. 배포 키 OIDC가 안 되면 앱별 Secret Sync(앱 저장소 public) | C.4.8 |
| 격리 작업 공간 기본 방식(D-15 입력) | **확정(사용자 2026-10-18, T05):** Kubernetes ns + 기본 거부 NetworkPolicy + 허용 목록 egress 프록시(작업자는 DNS 없이 프록시 고정 ClusterIP만) + 파드 netns 방화벽(init) + 작업자 전용 ClusterSecretStore, 파드는 Git만 생성. 봇 쪽 클러스터 안 경로·sandbox 작업자 ingress·읽기 전용 SA는 root 아래 봇 자리 Application(wave 1, retry 무제한·`refresh: true`, 대상 ns·라벨·포트를 값 하나로. 공유 차트 확장은 고르지 않은 대안). D-15(T15)는 그 라벨·포트를 정한다. 코드 읽기를 읽기 전용 호스트로 좁힐지는 D-15(T15)에서 정함. D-15는 확정(사용자 2026-10-18, T15)됐다: 라벨 `homelab-bot`, 포트 8080·8081, 코드 읽기는 `codeload.github.com`만("봇 결정(T15)") | C.8 |
| 공개 DNS 방식 | **확정(사용자 2026-10-18, T05):** 와일드카드 레코드 하나. 원격 관리 터널에서 안 되면 host별 Terraform 레코드 | C.3.4 |
| Argo CD 공개 webhook | **확정(사용자 2026-10-18, T05):** 두지 않음, 60초 폴링(`timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 0`). 사용자가 설명을 듣고 골랐다 | A.4 3번 |
| GitHub 보호 설정 관리 | **확정(사용자 2026-10-18, D-28):** Terraform root `infra/github`(저장소·시크릿 리소스 없음, guard, owner 로컬 래퍼만, CI는 plan 없음) | A.4 4번, C.3.9, F D-28 |
| 저장소 공개 정책 | **확정(사용자 2026-10-18, D-29):** 앱 저장소는 public만, 비앱 저장소는 공개하지 않음, 봇 코드 저장소는 public(운영 산출물은 저장소 밖) | F D-29 |
| 백업 보존 | **확정(사용자 2026-10-18, T05):** PostgreSQL·Valkey 14일, R2 버킷 `homelab-backups` 하나 | C.3.8 |

---

## G. 검증 시나리오

design-prompt §9의 시나리오 1~17이다. **상태는 모두 "설계상 기대"다**(아직 실행하지 않았다). 실행 결과는 E8에서 `platform/verification.md`에 "실제 검증 완료 / 설계상 기대 / 실패"로 기록한다.

공통 전제:

- 시험 앱은 `ukyi-app/homelab-smoke`(ns `app-homelab-smoke`, 공개 host `smoke.ukyi.app`), 두 번째 시험 DB용으로 `homelab-smoke2`를 쓴다. 이름과 host는 가짜 예시다. E5·E6·E7이 쓰는 손 등록 시험 앱 `homelab-probe`의 이름은 E5, `homelab-smoke`의 이름과 host는 E8에서 정한다. 아래 표의 명령은 E8이 E7의 CLI로 `homelab-smoke`를 새로 만들어 실행하는 형태다.
- **E5·E6은 CLI 없는 동등 절차로 먼저 통과시킨다.** 손으로 만들고 등록한 `homelab-probe`(두 번째 DB는 `homelab-probe2`, 공개 host 없음)로 표의 확인 명령을 이름만 바꿔 쓰고, `homelab` 명령 자리는 E5·E6 표 아래의 동등 절차(손으로 쓴 values·image.yaml PR, `restore.md`·`rotate.md`를 따르는 손 절차, 래퍼 `tools/tf-github.sh verify`)로 바꾼다. 공개 URL 확인은 port-forward로 바꾼다. E7은 같은 확인을 CLI로 다시 한다. E3은 시나리오 6·7의 E3 범위를 E3 표 아래 동등 절차(시험 Application `e3-probe`, 손 PR)로 먼저 보고, 경보는 E4b, 배포 PR 흐름은 E5가 나눠 본다.
- **담당 단계 열:** 그 시나리오를 완료 기준으로 갖는 단계다. 괄호는 그 단계의 범위나 방법이다. E8은 모든 시나리오를 다시 실행해 결과표에 기록한다.
- **서로 다른 Argo CD Application 사이의 순서는 sync-wave만으로 보장되지 않는다.** 그래서 모든 완료 조건은 Application 상태가 아니라 실제 준비 상태(파드 Ready, CR status)와 접속 확인(HTTP, DB 질의)으로 판정한다.
- 장애 주입은 selfHeal이 되돌리지 않게 Git PR이나 Argo CD 밖(외부 계정, 물리 네트워크)에서 한다(B.8 E2).
- 시크릿 값은 출력하지 않는다. 같은지 비교할 때는 `sha256sum` 결과만 본다.

| # | 시나리오 | 기대 결과 | 검증 방법 (명령 수준) | 담당 단계 | 상태 |
|---|---|---|---|---|---|
| 1 | DB 없는 작은 웹앱을 새 저장소에서 처음 배포 | 첫 빌드는 "미등록"으로 PR 없음 → `app add` PR(사람 병합) → Argo CD Synced·Healthy → 파드 imageID digest = `image.yaml` digest → 공개 URL 200. 두 번째 커밋은 `deploy/homelab-smoke` PR이 자동 병합되어 새 revision이 배포된다. 앱 저장소와 패키지는 public이고 익명 pull 토큰 응답이 200이다(D-29). 앱 라벨을 단 시험 파드에서 운영자 기기의 tailnet 주소로 가는 연결이 실패한다(C.4.5) | `homelab app new homelab-smoke --apply`(열린 `app-repos.json` PR 병합 뒤 한 번 더), push, `gh run list -R ukyi-app/homelab-smoke -L 1`, `homelab app add homelab-smoke --public smoke.ukyi.app --apply` 후 병합. `kubectl -n argocd get application homelab-smoke -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}'`. `kubectl -n app-homelab-smoke get pod -l homelab.ukyi.app/app=homelab-smoke -o jsonpath='{..imageID}'`와 `yq .digest apps/homelab-smoke/image.yaml` 비교. `curl -sf https://smoke.ukyi.app/healthz`. `gh api repos/ukyi-app/homelab-smoke --jq .visibility` → `public`, `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:ukyi-app/homelab-smoke:pull'` → 200. 두 번째 커밋 뒤 `gh pr list -R ukyi-app/homelab --head deploy/homelab-smoke --state merged -L 1 --json author,mergedBy`. tailnet 불통: 운영자 노트북에서 시험 포트를 잠시 열고(`nc -l 18080`), 노드에서 `nc -z -w 3 <노트북의 Tailscale 주소> 18080` → 성공(대조), `kubectl -n app-homelab-smoke run tailnet-probe --rm -i --restart=Never --image=busybox:1.37 --labels=homelab.ukyi.app/app=homelab-smoke --overrides='<비root·seccomp securityContext>' -- nc -z -w 3 <노트북의 Tailscale 주소> 18080` → 실패 | E5(동등 절차: `homelab-probe`, DB·공개 URL 없이), E8(CLI·공개 URL 포함 전체) | 설계상 기대 |
| 2 | 기존 앱에 PostgreSQL 추가 | `Database`·`DatabaseRole` 적용, 두 ExternalSecret Ready, 마이그레이션 Job 성공, 앱이 DB에 접속. 데이터 Application이 늦으면 Job이 한 번 실패하고 retry로 수렴 | `homelab db add homelab-smoke --apply` 후 병합. `kubectl -n database get database,databaserole homelab-smoke -o yaml`의 status. `kubectl -n app-homelab-smoke get externalsecret,jobs`. `curl -sf https://smoke.ukyi.app/healthz/db`. `kubectl -n database exec pg-1 -- psql -U postgres -tAc "select 1 from pg_database where datname='homelab-smoke'"` | E6(동등 절차), E7(CLI 경로), E8 | 설계상 기대 |
| 3 | 기존 앱에 캐시용 Valkey 추가 | PVC 없는 Valkey, `allkeys-lru`, 인증 없는 접속 거부, 다른 ns에서 6379 불통, 앱 캐시 ping 성공 | `homelab cache add homelab-smoke --apply` 후 병합. `kubectl -n app-homelab-smoke get pvc`(캐시용 없음). Valkey 파드 안 `sh -c 'REDISCLI_AUTH="$VALKEY_PASSWORD" valkey-cli CONFIG GET maxmemory-policy'` → `allkeys-lru`. 인증 없이 `valkey-cli PING` → `NOAUTH`. 다른 ns 시험 파드에서 `nc -z -w 3 <valkey 서비스> 6379` → 실패. `curl -sf https://smoke.ukyi.app/healthz/cache` | E6(동등 절차), E7(CLI 경로), E8 | 설계상 기대 |
| 4 | 영속 작업용 Valkey의 백업과 복원 | 표식 키를 쓴 뒤 백업 Job이 R2 `valkey/<app>/`에 RDB를 올리고, 데이터를 지운 뒤 C.5.6 절차로 복원하면 표식 키가 돌아오고 AOF가 다시 켜진다 | `data/homelab-smoke/values.yaml`에 `valkey.persistent: true`. 표식 키 `SET`. `kubectl -n app-homelab-smoke create job --from=cronjob/homelab-smoke-valkey-backup manual-1` 뒤 Job 로그의 업로드 객체·sha256. 키 삭제 → 복원 절차 → `GET` 표식 키, 재시작 뒤 검증 키 `homelab:restore:<실행 id>` `EXISTS` 1, `INFO persistence`의 AOF 완료(`aof_enabled:1`·`aof_rewrite_in_progress:0`·`aof_rewrite_scheduled:0`·`aof_last_bgrewrite_status:ok`, C.5.6 4단계와 같다) | E6, E8 | 설계상 기대 |
| 5 | 같은 등록 명령을 재실행해도 데이터·비밀번호 불변 | 두 번째 실행의 모든 단계가 "같음, 건너뜀", 새 PR·커밋 없음, Secret 해시 같음, 데이터 행 수 같음 | `homelab app add homelab-smoke --public smoke.ukyi.app --postgres --cache --apply`를 두 번. 전후 `kubectl -n database get secret pg-role-homelab-smoke -o jsonpath='{.data.password}' \| sha256sum` 비교. `gh pr list -R ukyi-app/homelab --head cli/app-add-homelab-smoke --state all`. 표식 테이블 `select count(*)` 비교. `homelab ... --json`의 `steps[].state`가 모두 `same` | E7(`homelab-probe`), E8 | 설계상 기대 |
| 6 | 필수 시크릿이 없으면 잘못된 값 적용 없이 명확히 실패 | ExternalSecret `SecretSyncedError`, 기존 Secret 불변, 새 버전 파드가 Ready가 되지 않고 옛 파드가 계속 서비스. 마이그레이션 hook이 있는 앱(ExternalSecret 0 → Job 1 → Deployment 2, C.5.4)은 ExternalSecret이 Degraded라 뒤 wave가 적용되지 않아 새 파드 자체가 생기지 않는다. ExternalSecret과 Deployment가 같은 wave면 새 파드가 `CreateContainerConfigError`로 시작하지 않는다(E3의 손으로 쓴 시험 앱이 이 경우), Application Degraded, ExternalSecretNotReady 경보, `homelab status`가 빠진 키와 다음 명령을 보여 줌 | `apps/homelab-smoke/values.yaml`에 Infisical에 없는 키를 더하는 PR 병합. `kubectl -n app-homelab-smoke get externalsecret homelab-smoke-app -o jsonpath='{.status.conditions[0].reason}'`. 대상 Secret 해시 비교. `kubectl -n app-homelab-smoke get pods`와 Deployment의 `metadata.generation`·`status.observedGeneration`(뒤 wave 미적용이면 generation이 그대로). Telegram 수신. revert PR로 원복 | E3(시험 ns: `SecretSyncedError`·Secret 불변·`CreateContainerConfigError`·health 덮어쓰기. E3 표 아래 동등 절차), E4b(ExternalSecretNotReady 경보·Telegram 수신), E8(`homelab status` 포함 전체) | 설계상 기대 |
| 7 | Infisical 장애·인증 만료 중 기존 서비스와 신규 배포 | 기존 파드 계속 동작, 파드를 지워도 기존 Secret으로 다시 뜸, ClusterSecretStore Ready=False와 경보. 이미지만 바꾸는 배포는 진행(ExternalSecret health 덮어쓰기, C.3.3), 새 키가 필요한 배포는 그 앱에서 멈추고 원인이 보임. 복구 뒤 자동 재동기화 | E3의 시험용 client secret 장애 주입(두 번째 client secret을 부트스트랩 Secret에 넣고 그것을 폐기. 외부 변경, 승인 기록. 운영 client secret은 폐기하지 않는다). `kubectl -n app-homelab-smoke delete pod -l homelab.ukyi.app/app=homelab-smoke` 뒤 Ready. `kubectl get clustersecretstore`. 앱 커밋 push로 배포 PR 병합 → 새 revision Healthy. 새 키를 요구하는 PR → Degraded. 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀. 복구 자산의 운영 ESO 자격으로 로그인 → 성공(응답 코드만) | E3(시험 ns: 기존 Secret 유지·Ready=False·health 덮어쓰기로 이미지만 바꾼 손 PR 진행·새 키 Degraded. E3 표 아래 동등 절차), E4b(경보), E5(배포 PR 자동 병합 흐름, `homelab-probe`), E8(전체) | 설계상 기대 |
| 8 | DB 비밀번호 변경 후 실제 앱 접속까지 확인 | `homelab db rotate`가 C.6.5 순서대로 진행, 역할 status 갱신, 앱 재시작 뒤 `/healthz/db` 200, 옛 비밀번호로 새 접속 실패. 중단 시간 측정 | `homelab db rotate homelab-smoke --apply`. 전후 Secret 해시가 다름. `kubectl -n database get databaserole homelab-smoke -o yaml` status. `curl -sf https://smoke.ukyi.app/healthz/db`. 시험 파드에서 `PASSWORD_PREVIOUS`(삭제 전)로 `psql` → 인증 실패 | E6(동등 절차: `rotate.md`를 손으로), E7(CLI 경로), E8 | 설계상 기대 |
| 9 | 앱을 삭제해도 DB·영속 데이터 보존 | Application·파드 삭제, `Database`·`DatabaseRole`·영속 Valkey PVC·Infisical 키 유지, `homelab data list`에 표시, 다시 등록하면 같은 데이터 | `homelab app remove homelab-smoke --apply` 후 병합. `kubectl -n argocd get application homelab-smoke`(NotFound), `kubectl -n database get database,databaserole homelab-smoke`, `kubectl -n app-homelab-smoke get pvc`, `psql`로 표식 행 수. `homelab data list`. `homelab app add ...` 재실행 뒤 표식 행 같음 | E6(동등 절차), E7(CLI 경로), E8 | 설계상 기대 |
| 10 | 공유 PostgreSQL에서 특정 앱만 복원 | 시각 T1 상태로 `homelab-smoke`만 돌아오고(T1 뒤 만든 스키마·테이블도 없음) `homelab-smoke2`의 T1 뒤 쓰기는 남음. 임시 Cluster·PVC가 끝나고 없음. R2 → 새 클러스터 복원이 실제로 됨 | 두 DB에 표식 행, T1 기록, T1 뒤 `homelab-smoke` 행 삭제와 `homelab-smoke2` 행 추가, T1 뒤 `homelab-smoke`에 시험 스키마와 테이블 생성. `homelab db restore homelab-smoke --to <T1>`. 두 DB 행 비교, T1 뒤 만든 시험 스키마·테이블이 없는지 확인(`\dn`, `\dt`). `kubectl -n database get cluster,pvc`에 `pg-restore-*` 없음 | E6(동등 절차: `restore.md`를 손으로), E7(CLI 경로), E8 | 설계상 기대 |
| 11 | 빌드 완료 순서가 바뀌어도 과거 이미지로 배포되지 않음 | 커밋 A, B 순서에서 A 빌드가 늦게 끝나도 A는 `behind`로 PR을 만들지 않고, `image.yaml`은 B로 끝남. A 빌드를 재실행해도 같음 | 앱 저장소에 커밋 A(느린 시험 표시 파일)와 B를 연달아 push. `gh run view <A run> --log \| grep -i behind`. `git -C <homelab> log -p -- apps/homelab-smoke/image.yaml \| head`. `gh pr list -R ukyi-app/homelab --head deploy/homelab-smoke --state all`. `gh run rerun <A run>` 뒤 같은 확인 | E5, E8 | 설계상 기대 |
| 12 | NUC 재부팅 후 의존 서비스 준비 | 사람 손 없이 노드 Ready, 모든 Application Synced·Healthy, CNPG healthy, ExternalSecret Ready, AdGuard 응답, 공개·내부 URL 응답, 앱 DB 접속. 복귀 시간 측정(목표 10분 안, 제안) | `sudo reboot`. 이후 `kubectl get nodes`, `kubectl -n argocd get applications`, `kubectl -n database get cluster pg`, `kubectl get externalsecret -A`, `dig @192.168.117.15 example.com +short`, `curl -sf https://smoke.ukyi.app/healthz/db`, tailnet 기기에서 `curl -sI https://grafana.<tailnet>.ts.net`. 각 시각 기록 | E2(k3s·Argo CD 범위), E8 | 설계상 기대 |
| 13 | 빈 NUC에서 문서 절차만으로 재구축 후 테스트 앱 배포 | VM(D-12)에서 `docs/runbooks-public/bootstrap.md`·`restore.md`와 복구 자산 + VM 준비 자산(`eso-homelab-dev` 자격, E8 VM 격리 2번)만으로 플랫폼이 서고 시험 앱이 배포됨. DB는 C.6.4 순서(root apply 전 복구 PR)로 운영 R2 아카이브에서 복구되어, 시험 시작 직전에 운영 `homelab-smoke` DB에 넣은 표식 행이 VM에 있음. VM의 새 아카이브는 VM 전용 버킷·serverName에만 생기고 VM은 운영 prefix에 쓰지 못함. 정리 PR 뒤 렌더 결과가 `initdb`. 운영 tailnet 기기(`argocd`, `grafana`, `adguard`, 운영 operator)와 운영 공개 URL·DNS는 시험 전후 그대로. 문서에 없는 수동 단계가 하나라도 있으면 실패로 기록 | VM 격리(E8). `bootstrap.md`에서 클러스터 이름 `vm`을 고르고 `host/clusters/vm.env`로 호스트를 세운다. vm 분기 첫 단계의 `homelab-dev` 키 대조 → 빠진 키 0(값 출력 없음). 실행 기록과 문서 단계 대조, `host/verify.sh --cluster vm`, VM에서 시나리오 1의 확인 명령(공개 URL `curl`은 운영에 닿으므로 쓰지 않고 E8 VM 격리 5번의 시험 터널 연결 수와 Host 헤더 확인으로 바꾼다. tailnet 불통 확인은 VM에서 하지 않고 "해당 없음(VM 호스트는 tailnet 밖, E8 VM 격리 4번)"으로 기록하며, 대신 VM 노드에 `tailscale0` 인터페이스가 없음을 `ip link show tailscale0` 실패로 확인한다), 걸린 시간. `restore.md`의 "VM 시험" 분기대로 C.6.4의 Tailscale 기기 삭제 단계는 건너뛰고, 시험 뒤 `vm-*` 기기만 지운다. 시험 전후 Tailscale 콘솔의 운영 기기 목록 비교, 시험 중 `vm-*` 기기가 모두 태그 기기(VM 호스트는 tailnet에 없음, E8 VM 격리 4번). `kubectl --context homelab-vm -n database get cluster pg -o jsonpath='{.status.phase}'`, VM에서 `psql`로 표식 행, VM 버킷의 `pg-vm-*/` 객체 존재(`rclone lsf`). VM에 있는 운영 버킷 자격(읽기 전용 토큰)으로 운영 버킷에 시험 객체 쓰기 → 거부(응답 코드만 기록) | E8 | 설계상 기대 |
| 14 | AdGuard가 멈췄을 때 LAN·Tailscale 기기의 이름 해석 | C.3.6 표대로: LAN 기기는 정지 동안 이름 해석이 전부 실패한다(2026-10-20 실측: 이 공유기는 보조 DNS로 넘어가지 않음, U19 반증. AC-P6 LAN 불합격을 사용자가 한계로 승인했고 완화는 런북 `nuc-dns-outage.md`와 T08b AdGuard 정지 경보). 차단은 없다. 질의별 응답 시간과 실패 수를 기록하고 C.3.6의 AC-P6 판정 기준[확정(사용자 2026-10-18, T05)]으로 판정한다. Tailscale 기기(셀룰러)는 AdGuard Home 정지 중에도 공용 서버가 답해 광고 도메인은 차단 응답, 일반 도메인은 정상 응답(D-08 (b′), U33). 노드 이름 해석·이미지 pull 정상, `*.ts.net` 내부 UI 접근 가능. 원복 뒤 차단 복귀. 사용자 규칙 적용률을 측정해 기록한다: AdGuard Home에만 넣은 시험 차단 규칙이 집 Wi-Fi와 셀룰러의 Tailscale 기기에서 각각 20회 중 몇 번 차단되는지(판정 기준 없음, 기록만) | PR로 `platform/adguard` replicas 0 → 병합. LAN 기기에서 10초 간격 30회, 매번 고유 이름으로 `dig "am$(date +%s)-$i.example.com" +tries=1 +time=5`(`$i`는 회차, 캐시되지 않은 이름이라 공유기 캐시로 거짓 통과하지 않음)의 이름·`status`·`Query time`과 실패 수(시간 초과·SERVFAIL·REFUSED)를 기록, 차단 목록 도메인 질의. 셀룰러의 Tailscale 기기에서 AdGuard 정지 중 `nslookup doubleclick.net` → 차단 응답(`0.0.0.0` 또는 NXDOMAIN), `nslookup example.com` → 정상. 원복 뒤 같은 기기의 질의가 AdGuard Home 질의 로그에 찍히는지(출처 표시는 U32). 적용률: 공용 DNS에서 정상 주소가 나오는 이름을 쓴다. `*.ukyi.app` 와일드카드가 있으므로 매번 다른 이름 `adg-<날짜>-<회차>.ukyi.app`이다(없는 이름은 공용 서버도 NXDOMAIN이라 차단으로 잘못 센다). 규칙 전에 같은 꼴의 이름이 두 경로 모두 정상 주소로 풀리는지 먼저 본다. 그다음 AdGuard Home에만 시험 차단 규칙(예: `\|\|adg-<날짜>-*.ukyi.app^`)을 넣고 집 Wi-Fi와 셀룰러의 Tailscale 기기에서 20회씩 질의해 `0.0.0.0` 응답만 차단으로 센다(NXDOMAIN은 세지 않는다). AdGuard Home 질의 로그의 해당 이름과 대조한 뒤 규칙을 지운다. 노드에서 `resolvectl query example.com`, `sudo k3s crictl pull docker.io/library/busybox:1.37`. tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net`. revert PR 뒤 차단 도메인 확인 | E4a, E8 | 설계상 기대 |
| 15 | 자동 병합 조건 밖의 PR은 사람 승인 뒤에만 병합 | 사람의 공유 차트 PR: `ci` 통과, `deploy-merge`가 "조건 1 불일치"로 병합하지 않음, owner가 검토 후 관리자 bypass로 병합하는 것만 성공(자기 승인은 불가), `ci`가 실패한 PR은 bypass로도 병합 거부, 검토 뒤 새 커밋이 들어온 PR은 `--match-head-commit <검토한 SHA>`로 병합 거부. 관리자도 버전 태그를 옮기거나 지우지 못한다(ruleset D1). 시험 App `ukyi-homelab-bot-standin`(봇 신원 대역): digest만 바꾼 PR이 병합되지 않고, homelab main·`deploy/`와 `homelab-smoke` main push는 GH013 거부. `ukyi-homelab-deploy` 토큰으로 워크플로 파일을 바꾸는 push 거부. 앱 CI는 병합 키를 얻지 못한다: 앱 시험 단계는 OIDC 토큰을 못 만들고, 병합 키는 homelab environment `automerge`에만 있다. homelab 브랜치에서 `automerge`를 선언한 job은 배포 브랜치 정책으로 거부되고(`deployment: false` 포함), 다른 저장소가 homelab 워크플로를 불러 `automerge`를 선언해도 키가 비어 있다. workflow-guard 음성 fixture가 모두 실패로 잡힌다. `homelab-smoke`의 `app-main`을 끄면 다음 배포 PR이 "조건 9 불일치"로 남는다. main 밖에서 빌드한 이미지는 라벨이 맞아도 조건 5에서 거부된다(attestation 없음 또는 원본 ref가 main이 아님). `homelab-app-template` main에도 `app-main` 규칙이 있다. 라이브 설정이 `infra/github` 선언과 같고 guard가 통과한다(`homelab github verify` exit 0). 선언 밖 ruleset이 생기면 verify가 guard 오류로 멈춘다 | 공유 차트 PR → `gh run view <deploy-merge run> --log`. `ci`를 일부러 깨뜨린 owner PR에 `gh pr merge --admin` → 거부. 검토한 SHA를 적어 둔 owner PR에 시험 커밋을 하나 더 push한 뒤 `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>` → 거부. owner 계정으로 기존 `app-chart-v1.0.0` 태그를 다른 커밋으로 옮기는 push(`git push -f origin <다른 커밋>:refs/tags/app-chart-v1.0.0`)와 그 태그 삭제 push → 둘 다 GH013 거부. 시험 App 토큰으로 `gh api -X PUT repos/ukyi-app/homelab/pulls/<n>/merge` → 거부. `git push`(homelab main, `deploy/x`, `homelab-smoke` main) → GH013. 배포 App 토큰으로 `.github/workflows/ci.yaml`을 바꾼 브랜치 push → 거부. `homelab-smoke`의 시험이 `test -z "$ACTIONS_ID_TOKEN_REQUEST_URL"`를 단언(test job에 `id-token` 없음). `homelab-smoke` 시험 브랜치 워크플로가 `gha-homelab-deploy`로 OIDC 로그인 → 거부(claim 불일치, 응답 코드만 기록). homelab 시험 브랜치 워크플로의 job이 `environment: {name: automerge, deployment: false}`를 선언 → job 거부(배포 브랜치 정책, U36). `homelab-smoke`의 시험 워크플로가 homelab 워크플로를 불러 `automerge`를 선언 → `HOMELAB_MERGE_KEY`가 빈 문자열(길이만 기록). `bun run ci`가 workflow-guard 음성 fixture(대소문자를 바꾼 `AutoMerge`, 표현식 이름, YAML 별칭, `secrets: inherit`, `toJSON(secrets)`, `workflow_dispatch` 트리거)를 모두 실패로 잡음. `gh api -X PUT repos/ukyi-app/homelab-smoke/rulesets/<id> -f enforcement=disabled` → 앱 커밋 push → `deploy-merge` 로그에 조건 9 → 다시 `active`. `homelab github verify` → exit 0, 콘솔에서 선언 밖 시험 ruleset(`disabled`)을 하나 만들고 다시 → exit 1(guard 오류) → 시험 ruleset 삭제 → exit 0. `gh api repos/ukyi-app/homelab/environments/automerge/secrets --jq '[.secrets[].name]'` → `["HOMELAB_MERGE_KEY"]`, `gh api repos/ukyi-app/homelab/actions/secrets --jq .total_count` → `0`, `gh api repos/ukyi-app/homelab --jq .allow_auto_merge` → `false`, `gh api repos/ukyi-app/homelab/rulesets/<id> --jq .bypass_actors`, `gh api repos/ukyi-app/homelab-smoke/rules/branches/main --jq '[.[].type]'`, 같은 명령을 `homelab-app-template`에. main 밖 빌드 거부: `homelab-smoke` main에 시험이 일부러 실패하는 커밋 C를 넣어(정상 빌드와 배포 PR이 생기지 않음), 시험 브랜치 워크플로(`packages: write`)가 이미지를 빌드해 revision 라벨 C와 source 라벨을 붙여 GHCR에 push한다. 배포 App 토큰(키 유출 대역)으로 그 digest와 revision C의 `deploy/homelab-smoke` PR을 만든다 → `deploy-merge` 로그에 "조건 5 불일치"(다른 조건은 통과), 병합 없음. 같은 digest에 조건 5의 `gh attestation verify` → 실패, 정상 main 빌드의 digest → 성공. 다음 커밋으로 시험을 고치고, 시험 패키지 버전·PR·브랜치 워크플로를 지운다 | E1(임시 ruleset active와 `current_user_can_bypass`만), E5(동등 절차: `homelab-probe`, 래퍼 `tools/tf-github.sh verify`), E8 | 설계상 기대 |
| 16 | 봇이 없거나 멈춘 상태에서 테스트 경보가 비AI 경로로 도착 | 봇 없이 Telegram에 시험 경보 도착(2분 안), 전송 지표 증가, 실패 지표 불변 | 봇이 없는 E4b 시점 또는 봇 replicas 0. `kubectl -n observability exec deploy/alertmanager -- amtool alert add alertname=PlatformTest severity=warning --alertmanager.url=http://localhost:9093`. Telegram 수신 시각. `alertmanager_notifications_total{integration="telegram"}`, `alertmanager_notifications_failed_total{integration="telegram"}` 조회(Grafana 또는 vmsingle API) | E4b, E8 | 설계상 기대 |
| 17 | NUC 전체가 멈추면 외부 생존 감시가 감지해 알림 | Period + Grace(10분) 뒤 healthchecks.io가 down으로 바꾸고 NUC를 거치지 않는 경로(이메일, Telegram 연동)로 알림. 복구 뒤 up 알림 | NUC 네트워크를 물리적으로 끊거나 전원을 끔(원격 접속이 끊기므로 현장에서). healthchecks.io 대시보드와 이벤트 기록, 수신 시각 | E4b, E8 | 설계상 기대 |

---

## 부록

### 부록 1. 미검증 목록

확인하지 못한 가정과 그것을 확인할 단계다. 설계는 각 항목이 틀렸을 때의 대안을 본문에 함께 적었다.

| # | 가정 | 틀리면 | 확인 단계 | 본문 |
|---|---|---|---|---|
| U01 | 원격 관리 Cloudflare 터널이 와일드카드 hostname(`*.ukyi.app`)을 받는다(공식 근거는 로컬 설정 매칭 규칙 하나) | 공개 host마다 Terraform DNS 레코드(사람 apply) | E4a | C.3.4 |
| U02 | Terraform S3 backend `use_lockfile`이 R2에서 동작한다. 문서·소스로는 확인됐다: R2의 PutObject `If-None-Match`는 커밋된 버킷 상태에 원자적으로 평가되고 동시 요청 중 최대 하나만 성공하며[S37], S3 backend는 잠금 파일 `<key>.tflock`을 `If-None-Match: *`로 만든다[S195]. HashiCorp는 S3 호환 저장소를 best effort로만 지원하므로 남은 것은 동시 실행 시험 1회다(2026-10-18 확인) | owner 로컬 단일 실행자 규칙으로 감수(래퍼가 apply 전 state를 백업하므로 덮어쓰기는 되돌릴 수 있다, C.3.9). 같은 첫 apply에서 `infisical run` 두 번을 겹친 명령이 바깥 경로(`/terraform/state`)의 R2 키를 안쪽 실행까지 넘기는지도 본다(안 되면 root마다 R2 키를 provider 경로에 함께 둔다) | E4a(동시 실행 시험 1회, `infra/github` 첫 apply보다 먼저, E.0) | C.3.9 |
| U03 | Argo CD v3.5.5 공식 install.yaml에 구성 요소별 NetworkPolicy가 들어 있고 라이브에 그대로 적용된다(파일에 7개가 있고 `argocd-server`는 모든 출처 ingress임은 2026-10-18 확인[S181]. 남은 것은 라이브 적용) | Kustomize patch로 repo-server 등 정책 추가 | E2 | B.8 E2 |
| U04 | 자기 관리 `argocd` Application을 `prune: false`로 두면 자기 삭제 위험이 없다(공식 문서 없음) | 커뮤니티 사례대로 finalizer 없이 + 사람 확인 | E2 | C.3.3 |
| U05 | Infisical OIDC Auth를 Free에서 쓸 수 있고, 배포 키 identity `gha-homelab-deploy`의 개별 claim을 묶을 수 있다(문서는 claim의 glob을 허용한다고 적음[S09], 실동작 미확인): `repository_owner`, `ref = refs/heads/main`, `event_name = push`, `job_workflow_ref = …/app-build.yaml@refs/tags/app-build-v*`. `app-build`의 test·push job(`id-token` 없음)은 OIDC 토큰을 발급받지 못한다[S105]. 병합 키는 OIDC를 쓰지 않으므로(F D-04 확정, Secret Sync) 병합 identity의 claim은 이 항목에서 빠졌다. 병합 쪽 가정은 U36이다 | Free 사용이나 claim 묶기가 안 되면 배포 키도 앱 저장소마다 environment sync로 옮긴다(앱 저장소 public 필요, 병합 sync 1개를 빼면 앱 9개까지. 그다음은 Pro, F D-04). glob만 안 되면 태그마다 claim 값을 사람이 갱신 **결과:** Free에서 OIDC 로그인과 claim glob(`job_workflow_ref`의 `*`) 동작, `event_name` 불일치 401(2026-10-19 시험 브랜치). 2026-10-21 `homelab-probe` 첫 main push에서 실제 `app-build@app-build-v1.0.0`의 deploy-pr이 배포 키를 받았다(Subject를 불변 형식으로 바꾼 뒤. B.8 E5). | E3 첫 작업, 시나리오 15 | C.4.8 |
| U06 | ESO Infisical provider에서 `remoteRef.key`에 경로를 포함할 수 있다 | 앱마다 `secretsPath`를 다르게 한 store 또는 ExternalSecret별 경로 지정 방식으로 | E3 | C.6.2 |
| U07 | ExternalSecret health를 덮어쓰면 Infisical 장애 중에도 이미지만 바꾸는 배포가 진행된다 | 장애 중 배포 정지를 감수하고 문서화 | E3, 시나리오 7 | C.3.3, C.6.6 |
| U08 | ruleset bypass `pull_request` 모드 App이나 관리자가 병합해도 bypass 없는 ruleset(A)의 필수 검사가 적용된다. App 승인은 code owner 승인을 대신하지 못한다. 저장소 관리자 역할 bypass가 org owner에게 적용된다(사람 PR의 일상 병합이 모두 여기에 달림) | 앞의 둘: 병합 워크플로가 검사 결과를 직접 확인하는 것으로 보강, code owner 대신 "Restrict updates" 검토. 셋째: F D-07의 대안 순서(owner를 `User` 행위자로 → `OrganizationAdmin` → owner만 든 팀, U31. 또는 승인 0 + "Restrict updates"이고 bypass는 그 행위자와 `ukyi-homelab-merge`) **결과(2026-10-21): 통과(조건부: 둘째 기대는 틀려 "틀리면" 열의 Restrict updates로 대응).** 시나리오 15: 관리자 `gh pr merge --admin`도 `ci`가 실패한 #808에서 거부("Required status check ci is failing") = 관리자 bypass에도 ruleset A가 적용된다. 관리자 역할 bypass로 owner PR 병합 성공(#799 첫 관리자 우회 병합, #812 시나리오 15-13. 자기 승인은 거부). **나머지 결과(2026-10-21 시험 PR, approvals 21:01~21:07 행):** (가) **통과** — 병합 App 설치 토큰의 `PUT /pulls/821/merge`(head 커밋 `[skip ci]`로 `ci` 미보고)가 405 "Required status check "ci" is expected."(리뷰 요건은 bypass, 필수 검사는 적용). (나) **실패** — owner가 연 #822에서 `ci` 성공 뒤 bypass 없는 배포 App이 승인하자 `reviewDecision` `APPROVED`·`mergeStateStatus` `CLEAN`, 같은 토큰의 병합이 200으로 main에 들어갔다(b25aac6, #823으로 제거). `CODEOWNERS` `* @<owner 계정>`, `codeowners/errors` 0, `require_code_owner_review: true`였다. 원인 추정(미확인): 작성자가 유일한 code owner면 code owner 요건이 빠지고 "쓰기 권한자 승인 1"만 남는다. 대응: "틀리면" 열대로 ruleset B와 `app-main`에 Restrict updates(`update`, bypass 목록은 그대로)를 더하고 deploy-merge 조건 9가 앱 main의 `update` 규칙을 확인한다(사용자 결정 2026-10-21 21:12). **apply 뒤 재시험(approvals 21:24~21:27·21:27~21:33 행): 통과.** ruleset 5개(homelab `main-review`, `app-main`의 `files`·`homelab-app-template`·`homelab-bot`·`homelab-probe`)의 `update` false → true, apply 뒤 verify exit 0. (1) owner가 연 시험 PR #825에서 배포 App 승인 뒤 reviewDecision `APPROVED`·mergeStateStatus `BLOCKED`, 같은 토큰의 병합 405 "Cannot update this protected ref." (2) owner `--admin` 병합 됨(probe #8, update 규칙 아래 관리자 bypass). (3) probe main 빌드의 배포 PR #826을 `ukyi-homelab-merge`가 자동 병합(조건 9의 `update` 확인 포함), 새 파드 Running. **판정:** (가) 통과. (나)는 원래 기대(App 승인이 code owner 승인을 대신하지 못함)가 틀렸고, "틀리면" 열의 대응(Restrict updates)을 적용해 bypass 밖 신원의 병합이 막히는 것을 확인했다. 셋째(관리자 역할 bypass)는 시나리오 15에서 통과. | 셋째의 첫 실측은 결정 5 하드닝의 `current_user_can_bypass`(2026-10-18, 앱 저장소 `app-main` 두 곳 모두 `pull_requests_only`. 실제 bypass 병합은 아직), homelab은 E1(임시 ruleset을 건 직후 `current_user_can_bypass`, rebuild → main 병합). 나머지는 E5, 시나리오 15 | C.4.7, F D-07 |
| U09 | workflows 권한이 없는 App 토큰은 워크플로 파일을 바꾸는 push를 못 한다(근거: 권한 표의 추가 권한 표시, 단일 근거) | 배포 브랜치 ruleset에 파일 경로 제한을 둘 수 없으므로(Free) `deploy-merge` 조건 3이 유일한 방어 **결과(2026-10-21, 시나리오 15): 통과.** `ukyi-homelab-deploy` 설치 토큰으로 `deploy/s15-wf`에 `.github/workflows/ci.yaml`을 바꾼 커밋을 push → "refusing to allow a GitHub App to create or update workflow ... without `workflows` permission"(approvals 15:05~15:30 행). | E5, 시나리오 15 | C.4.7 |
| U10 | Alertmanager webhook을 healthchecks.io ping URL로 직접 보내도 동작한다 **결과(2026-10-23, T08b):** 동작한다. 새 체크가 초록이 됐고, 파드에서 ping 주소로 가는 443만 막자 down 알림, 풀자 up 알림이 왔다. relay는 두지 않았다 | 가드가 있는 작은 relay | E4b | C.3.7 |
| U11 | `vmalert-tool unittest`로 룰 단위 시험을 CI에서 돌릴 수 있다 **결과(2026-10-22, T08b):** 된다. 룰 20개 모두 단위 시험이 있고 `bun run ci`가 돌린다. `-disableAlertgroupLabel`과 `groupname`은 같이 못 쓰고, annotation까지 비교한다. CI 도구는 OSS 자산(`vmalert-tool-prod`)을 이름으로 고정한다(`v*.tar.gz`는 enterprise 자산이 잡힌다) | promtool 형식 또는 시험 경보 수동 확인 | E4b | C.3.7, C.4.6 |
| U12 | Grafana Viewer 서비스 계정은 대시보드·데이터소스 질의만 하고 쓰기는 못 한다 **결과(2026-10-23, T08b):** 반만 맞다. 대시보드 쓰기는 403이지만 데이터소스 resources·proxy 경로로 임의 경로에 POST할 수 있어 직결이면 vmsingle `delete_series`·import, VictoriaLogs `/insert/*`(실측 저장됨)에 닿는다. 대안(읽기 프록시)을 택해 두 데이터소스 앞에 vmauth를 두었다(C.3.7, #842·#849). 그 뒤 Viewer 토큰으로 `GET /api/search` 200, `POST /api/dashboards/db` 403, 메트릭·로그 질의 200, 쓰기 경로 400·403 | 봇 읽기를 데이터소스 API 앞의 별도 읽기 프록시로 | E4b | C.8 |
| U13 | 작업자 파드 netns 안 init 방화벽(NET_ADMIN)이 노드 로컬 경로(노드 IP의 6443·10250·22)와 DNS(53)까지 막고, 새 출력 연결은 프록시 ClusterIP:3128만 남긴다. loopback(`-o lo`)과 conntrack `ESTABLISHED,RELATED` 허용으로 봇 → 작업자 Service 요청의 응답과 파드 안 통신은 지나간다 **결과(2026-10-22 시험 ns, 2026-10-23 실제 작업자, T08b):** 그렇다. API 서버·노드 6443·10250·22·공유기·tailnet 주소·Infisical 직접·DNS가 모두 실패하고 loopback·봇 자리 시험 파드의 요청 응답은 성공했다. 본 컨테이너의 `iptables -F`는 실패한다. 이 k3s의 kube-router netpol도 노드 IP·`10.43.0.1`을 막았지만 구현 의존이라 init 방화벽을 그대로 둔다(C.8) | 호스트 전용 UID + nft로 물러난다(D-15, 확정(사용자 2026-10-18, T15)) | E4b | C.8 |
| U14 | cert-manager, Traefik, 관측 차트들, egress 프록시의 현재 안정 버전 **결과(관측·egress 프록시, 2026-10-22~23, T08b):** vmsingle·vmalert·vmauth v1.154.1, VictoriaLogs v1.53.0, Alertmanager 0.34.1, Grafana 13.2.4, VictoriaLogs 데이터소스 플러그인 v0.33.1(zip sha256 고정), vector 0.60.0, node-exporter v1.12.1, kube-state-metrics v2.20.0, egress 프록시 Envoy distroless-v1.40.0. 이미지는 digest로 고정했다 | E4 시작 때 정해 고정 | E4a, E4b | C.3.1 |
| U15 | CNPG 1.30의 `DatabaseRole` 필드 이름과 `Database`·`DatabaseRole` status 필드 **결과(2026-10-23, T11, 소스만):** CNPG v1.30.1 `api/v1/databaserole_types.go`와 kubeconform 스키마(datreeio 고정 커밋)가 같다. spec `cluster.name`(불변)·`name`·`login`·`passwordSecret.name`·`databaseRoleReclaimPolicy`, status `applied`·`message`·`observedGeneration`·`secretResourceVersion`·`conditions`. 데이터 차트가 이 이름으로 렌더한다. **운영 status(2026-10-23, 시나리오 2):** `Database` `applied: true`·`observedGeneration`, `DatabaseRole` `applied: true`·`secretResourceVersion`(= 역할 Secret의 resourceVersion)·condition `PasswordSecretChange`. 새 역할은 CNPG가 인스턴스 Role에 Secret 읽기를 더할 때까지 약 30초 `secrets ... is forbidden`으로 applied false였다가 스스로 풀렸다(시나리오 10의 probe2) | 1.30 API 문서대로 차트 수정 | E6 | C.5.3 |
| U16 | Barman Cloud Plugin v0.15.1 + R2에서 새 클러스터 복원이 된다(이슈 #411 열림). 2026-10-23 kind + S3 호환 저장소에서는 env endpoint 설정으로 백업·새 serverName 복구가 됐다(T11). **운영 결과(2026-10-23, T11):** 버킷 한정 Object Read & Write 토큰의 HeadBucket·`pg/` list 200(다른 버킷 403), 첫 base backup completed, 시나리오 10에서 R2 `pg-20261023`의 base backup과 WAL로 임시 Cluster가 targetTime까지 94초 안에 healthy가 되고 내용이 T1과 같았다 | checksum env 추가, 안 되면 다른 S3 호환 저장소 검토 | E6, 시나리오 10 | C.3.8 |
| U17 | PostgreSQL 비밀번호 변경 뒤 이미 열린 연결이 유지된다 **결과(2026-10-23, T11 시나리오 8):** 유지된다. 앱 역할로 연 연결(127.0.0.1 TCP, sslmode require)이 ALTER ROLE 4분 뒤에도 같은 pid로 질의에 성공했다. 연결 풀을 쓰는 앱은 새 연결을 열 때만 실패한다 | 회전 때 중단 시간 증가. 무중단이면 역할 두 개 교대 | E6, 시나리오 8 | C.6.5 |
| U18 | Valkey RDB 복원 절차(AOF가 켜져 있을 때), ACL 상태의 `valkey-cli --rdb` 필요 권한 **결과(2026-10-23, T11, 로컬 podman, valkey 9.1.2):** C.5.6 절차대로 된다. `appendonlydir`을 남기면 AOF가 이기고, 지우고 `appendonly yes`로 시작하면 RDB를 무시하고 빈 데이터로 시작한다(그래서 복원 모드가 필수). `appendonly no`로 읽고 `CONFIG SET appendonly yes` 뒤 재시작하면 키가 그대로다. `--rdb`에는 `sync`·`replconf`가 필요하다(없으면 NOPERM). 백업 Job과 복원 Job 스크립트를 로컬 S3(`rclone serve s3`)로 돌려 왕복을 확인했다. **운영 결과(2026-10-23, 시나리오 4):** 데이터 차트 1.0.1의 백업 Job이 R2에 올리고 sha256 대조, 복원 Job → 복원 모드(`appendonly no`)에서 표식 키 돌아옴·백업 뒤 키 없음 → `CONFIG SET appendonly yes`(rewrite ok) → 파드 재시작 뒤 AOF에서 같은 키 수. 1.0.0 백업 Job은 새 파드의 첫 접속 거부로 매번 실패했다(B.8 E6) | 복원 절차 수정 | E6, 시나리오 4 | C.5.6 |
| U19 | 공유기가 AdGuard 정지 때 보조 DNS(`1.1.1.1`)로 C.3.6의 AC-P6 판정 기준 안에 넘어간다. 옛 실측은 반대 방향이다: 응답 없이 버려진 질의에서 넘어가는 문턱이 높아 페이지 로드 지연·간헐 실패가 났다(`2d2054a:platform/adguard/prod/adguardhome.yaml:33-39`, ratelimit 드롭이라 정지 때와 다를 수 있음) **결과(2026-10-20, T08a): 반증.** AdGuard 정지 중 공유기 경유 질의 30회 중 26회 시간 초과(복구 뒤 4회 정상), NUC 무응답 시험 11회 모두 시간 초과. 이 공유기는 보조로 넘어가지 않는다. AC-P6 LAN 불합격을 사용자가 한계로 승인했다(런북 `nuc-dns-outage.md`). | 측정값을 기록하고 시나리오 14를 실패로 둔 뒤, 사용자가 한계로 승인하거나 D-08 재검토 | E4a, 시나리오 14 | C.3.6, F D-08 |
| U20 | 호스팅형 Renovate App의 현재 이용 조건이 이 용도에 맞다 **결과(2026-10-21, T10): 통과(조건부).** Mend Community Cloud는 무료이고 public·private 저장소 수 제한이 없다. 제한(org당 동시 job 1개, 활성 저장소 4시간마다, runner 1 vCPU·3GB·15GB, job 30분, Merge Confidence 워크플로·헬프데스크 없음)은 주 1회 일정·자동 병합 없음인 이 용도에 걸리지 않는다[S231][S234]. 조건 둘: 무료 서비스는 as-is이고 유료 플랜이 나중에 더해질 수 있다[S233]. 호스팅 App의 Contents·Workflows·statuses 쓰기[S232](실제 설치에는 `members`·`packages` read가 더 있다, approvals 2026-10-21 20:54 행)는 저장소·org secret 0과 environment 제한으로만 안전하다(B.8 E5 Renovate 행). 둘 중 하나가 깨지면 "틀리면" 열로 간다 | self-hosted Renovate를 별도 저장소 Actions로(homelab과 분리) | E5 | F D-18 |
| U21 | Codex Connector가 Draft PR이나 특정 작성자(배포 App) PR의 자동 리뷰를 건너뛸 수 있다 **결과(2026-10-21 관측, T10): 통과.** homelab은 Codex 자동 리뷰가 켜져 있다(#819 요약 댓글 "Review trigger: PR opened", 안내 "Open a pull request for review / Mark a draft as ready / @codex review"). 그래도 배포 App PR 5건(#805·#807·#811·#816·#818, 가장 오래 열린 #811 2분 10초)과 시험 App PR #810(10분)에 반응·리뷰 0, Draft #808·#809는 Draft인 11분 동안 반응 0(ready 뒤 요청에만 응답). Draft·App 작성 PR은 자동 리뷰 대상이 아니다. 근거는 관측과 요약 댓글 문구뿐이고 공식 문서는 없다 | 배포 PR에도 리뷰가 달리는 것을 감수하거나 D-26에서 설치 범위 축소 | E5 | F D-26 |
| U22 | Actions가 꺼진 저장소의 reusable 워크플로를 다른 저장소가 호출할 수 있는지(지금 이것을 호출하는 저장소의 상태. `page`·`trip-mate-api`는 2026-10-18에 지워 남는 것은 `files`와 `aiops-autodeploy-canary`) | E2 재활성 전까지 앱 저장소 빌드가 실패할 수 있음. E10 전에는 영향이 작다 | E2 이후 | 0절 |
| U23 | Infisical Free의 "버전 이력 없음"의 정확한 범위(가격표 한 행에 PITR과 묶임) | 버전 이력이 있으면 회전의 `_PREVIOUS` 보관을 줄일 수 있음 | E3 | C.6.3 |
| U24 | Infisical 유료 플랜 identity "무제한" 표기 변경(서드파티 기록만) | Pro 비용 재계산 | D-04 재검토 때 | F D-04 |
| U25 | `deploy-merge`가 homelab 쪽 토큰(`GITHUB_TOKEN` 또는 `ukyi-homelab-merge` 설치 토큰)으로 public 앱 저장소의 `GET /repos/ukyi-app/<app>`과 `GET /repos/ukyi-app/<app>/rules/branches/main`, `GET /repos/ukyi-app/<app>/codeowners/errors`를 읽을 수 있다(공식 문서에 토큰 권한 표시가 없음[S85][S178]. owner 로그인으로는 응답 형식을 실측함) | 앱 저장소에 metadata read만(`codeowners/errors`가 더 요구하면 contents read도) 가진 읽기 전용 App을 따로 설치해 그 토큰으로 읽는다(App 하나 증가). 그때까지 조건 9를 만족할 수 없어 자동 병합은 멈춘다 **결과(2026-10-21): 통과.** deploy-merge(`GITHUB_TOKEN`)가 `homelab-probe`의 저장소·`rules/branches/main`·`codeowners/errors`·CODEOWNERS를 읽어 배포 PR #805·#807을 병합했고, `app-main`을 끈 동안 #811을 "조건 9 불일치"로 멈춘 뒤 켜고 재판정해 병합했다(approvals 14:07, 14:56~15:02, 15:25~15:28 행). | E5, 시나리오 15 | C.4.7 |
| U26 | CNPG 1.30.1에서 떠 있는 Cluster의 `spec.bootstrap`을 `recovery`에서 `initdb`로 바꾸는 변경을 webhook이 거부하지 않고, 떠 있는 클러스터에는 영향이 없다(옛 버전 실측만, `2d2054a:platform/cnpg/prod/cluster.yaml:50-53`). 2026-10-23 kind(1.30.1, server-side apply)에서 거부 없이 적용되고 파드 재시작 없이 healthy가 유지됐다(T11). 같은 날 운영 클러스터의 복원 시험 임시 Cluster에서도 merge patch가 거부되지 않고 파드 uid·재시작 수가 그대로였다(시나리오 10). 운영 Argo CD 경로는 시나리오 13에서 | 정리 PR을 하지 않고 recovery를 남긴다. 낡은 복구본이 새 serverName prefix에 아카이브하려 하면 빈 아카이브 검사로 멈추는 것[S32]과 CNPGClusterNotHealthy 경보에 기댄다 | E6(복구 시험), 시나리오 13 | C.6.4 |
| U27 | 운영 버킷에만 한정한 R2 Object Read only 토큰으로 Barman Cloud Plugin 복구(base backup·WAL 읽기)가 된다(R2 Object 토큰은 ListBuckets·HeadBucket이 안 된다, B.8 E4) | 그 읽기 전용 토큰으로 운영 아카이브를 VM 전용 버킷에 `rclone`(`no_check_bucket=true`)으로 복사한 뒤 그 사본에서 복구 | E8, 시나리오 13 | E8 VM 격리 |
| U28 | 파드가 tailnet 주소(`100.64.0.0/10`)로 보낸 패킷은 노드의 `tailscale0`으로 나가며 출발 주소가 NUC의 Tailscale 주소로 바뀌고(flannel 마스커레이드, 추측), 받는 기기의 ACL은 NUC를 출발지로 본다. 그래서 NUC가 태그 없는 사용자 기기이면 `autogroup:member → autogroup:self:*` 아래에서 파드가 운영자 기기에 닿는다 **결과(2026-10-20, T08a):** 맞다. NetworkPolicy 없는 시험 ns 파드가 운영자 맥의 시험 포트에 연결됐고, `tailscale0` tcpdump에서 출발 주소가 NUC의 Tailscale 주소였다. 그래서 D-11을 (c)로 바꿨다(사용자 2026-10-20). (c) 적용 뒤 같은 시험은 실패했다(2026-10-21, 3회 모두. 대조로 같은 파드의 인터넷 연결과 다른 맥의 연결은 성공) | 바뀌지 않으면 패킷이 tailnet에서 버려져 위험이 작아진다. 공유 차트의 tailnet 대역 제외는 해가 없으니 그대로 둔다. 닿는 것이 확인되면 egress 정책이 없는 플랫폼 파드를 찾아 같은 제외를 넣거나 F D-11 (c)를 다시 본다 | E4a(새 ACL 적용 뒤, NetworkPolicy가 없는 시험 ns의 파드에서 운영자 기기의 시험 포트로 연결해 성공 여부와 받은 쪽의 출발 주소만 기록), 시나리오 1(앱 라벨 시험 파드는 실패) | C.3.5, C.4.5, F D-11 |
| U29 | 작업자 쪽 도구(모델 CLI, git, 패키지 관리자)가 `HTTPS_PROXY`를 따라 목적지 이름 해석을 프록시에 맡기므로, 작업자 파드에 DNS가 없어도 동작한다 **결과(E4b 부분, 2026-10-22, T08b):** DNS 없는 시험 파드와 실제 작업자 파드의 curl이 `HTTPS_PROXY`만으로 codeload 압축본과 pypi에 닿았다. 모델 CLI·git·패키지 관리자는 E9에서 본다 | 그 도구만 프록시 설정을 따로 준다. 안 되면 DNS를 열되 CoreDNS가 아니라 `egress` ns에 허용 목록 도메인만 푸는 전용 DNS를 두고 작업자는 그것만 쓴다 | E4b(시험 파드), E9(실제 Codex. T15 조사로는 확인하지 못함) | C.8 |
| U30 | 조건 5의 출처 확인이 이 구성에서 동작한다. (1) Free org의 public 앱 저장소에서 reusable `app-build`(태그 호출)의 deploy-pr job이 `actions/attest`로 GHCR digest의 build provenance attestation을 만든다(문서는 Free·Pro·Team에서 public 저장소만 가능하다고 적음[S174], 실동작 미확인). (2) 그 attestation의 서명 인증서 SAN이 `https://github.com/ukyi-app/homelab/.github/workflows/app-build.yaml@refs/tags/app-build-v<버전>`이고, 원본 저장소·ref·커밋이 호출한 앱 저장소의 `refs/heads/main`과 그 커밋이라 `--cert-identity-regex`·`--source-ref`·`--source-digest`로 가를 수 있다(문서는 reusable 워크플로가 서명자라고만 적음[S175]). (3) `deploy-merge`가 homelab 쪽 토큰(`GITHUB_TOKEN` 또는 `ukyi-homelab-merge` 설치 토큰)으로 앱 저장소의 attestation(`GET /repos/{owner}/{repo}/attestations/{subject_digest}`, "저장소 읽기 권한" 필요[S176])과 public GHCR manifest를 읽을 수 있다(App 토큰의 다른 저장소 읽기는 문서에 없음, U25와 같은 질문). 옛 (4)(private 앱에서 attest를 건너뛰고 배포 PR을 만드는 분기)는 D-29로 private 앱이 없어져 지웠다 | (3)만 안 되면 attestation을 `push-to-registry: true`로 GHCR에도 올리고(그 job에 `packages: write` 추가) `--bundle-from-oci`로 읽거나[S175], U25의 읽기 전용 App 토큰으로 읽는다. (1)·(2)가 안 되면 조건 5는 라벨만 남고, C.4.7 남는 위험 2번을 감수하거나 자동 병합을 끈다(F D-07). **결과(2026-10-21): 정상 main 이미지 경로 통과.** (1)~(3): `app-build@app-build-v1.0.1`의 deploy-pr이 attestation을 만들었고, deploy-merge의 `gh attestation verify`(서명자 정규식·`--source-ref refs/heads/main`·`--source-digest`)가 통과해 #805·#807·#811이 자동 병합됐다. main 밖에서 빌드한 이미지가 조건 5에서 거부되는지(음성)는 실행하지 않았고 T13으로 넘겼다(시나리오 15-11, approvals 15:35 행). | (1)~(3): E5 첫 배포 PR, 시나리오 15 | C.4.1, C.4.7 |
| U31 | U08 셋째 조건이 틀릴 때 쓸 bypass 행위자가 Free org에서 owner에게 적용된다. 순서대로 시험한다: (1) owner 계정을 `actor_type` `User`로(`pull_request` 모드). 2026-05-07부터 저장소 수준 ruleset에 개인 사용자를 bypass 행위자로 넣을 수 있고[S205], REST `actor_type`에 `User`가 있다[S85]. 공지에 요금제 조건이 없어 Free 동작은 미확인이다. (2) `OrganizationAdmin`. (3) owner만 든 팀(secret 아님. 문서는 팀을 bypass 행위자로 들고 요금제 제한을 적지 않는다[S85]) | 셋 다 안 되면 owner PR을 병합할 bypass 행위자가 없다. 그때는 F D-07을 다시 열어 사용자가 정한다 | E1(임시 ruleset에서 `current_user_can_bypass`) | F D-07 |
| U32 | servicelb로 연 AdGuard `:53`에 tailnet 기기가 NUC의 Tailscale 주소로 닿는다(옛 실운영 경로, portmap DNAT가 목적지를 가리지 않음, B.8 E2). klipper-lb의 MASQUERADE로 tailnet 질의가 AdGuard에 svclb 파드 IP 하나로 보여(소스 기반 추측) ratelimit 100 버킷을 함께 써도 질의가 버려지지 않는다 **결과(2026-10-21, T08a):** tailnet 기기는 닿는다. 출처는 하나가 아니라 둘이다: 공유기 경유 LAN 질의는 `10.42.0.1`(노드 cni0), tailnet 질의는 svclb 파드 IP. 같은 /24라 `ratelimit_subnet_len_ipv4: 24`에서 집 LAN과 tailnet 전체가 버킷 하나를 쓰고 공유기 주소 예외는 맞지 않는다. 약 9.5시간 로그에 초당 100건 이상인 초가 셋이다(버려졌는지는 로그로 확인 못 함). ratelimit을 껐다(확정(사용자 2026-10-21). 파드 IP 예외는 재시작마다 바뀌고, hostNetwork는 아래 대가 때문에 제외) | (처음 대응안: 시드 `ratelimit_whitelist`에 svclb 출처. 파드 IP가 재시작마다 바뀌어 쓰지 않았다.) 지금은 ratelimit을 끈다(2026-10-21). 한 기기의 질의 폭주를 막아야 하면 노드 nftables에서 NAT 전 출처별 한도를 둔다(후속 후보). 기기별 출처가 꼭 필요하면 hostNetwork로 바꾼다(실제 100.x 출처 보존. 대가: PSA 예외와 노드 네트워크 네임스페이스 공격면 증가, AdGuard가 침해되면 노드의 `127.0.0.1` 서비스와 모든 인터페이스에 노드 자격으로 닿는다) | E4a(AdGuard 질의 로그의 출처 확인) | C.3.6, F D-08 |
| U33 | D-08 (b′)에서 AdGuard 공용 DNS(`94.140.14.14`, `94.140.15.15`)가 AdGuard Home 기본값과 같은 목록(AdGuard DNS filter)으로 차단해, AdGuard Home이 멈춰도 Tailscale 기기의 광고 도메인이 차단된다(문서 근거[S189][S190], 실측 전). AdGuard Home 전용 규칙의 적용률(AdGuard Home이 먼저 답한 비율)은 미측정이다 **결과(2026-10-20, T08a):** 셀룰러 Tailscale 기기에서 NUC AdGuard 무응답 중 `doubleclick.net` → `0.0.0.0`, `example.com` 정상(통과). 사용자 규칙 적용률 셀룰러 19/20, 집 Wi-Fi 20/20(2026-10-21). 시험 규칙은 지웠다. | 공용 서버가 차단하지 않으면 (b′)의 전제가 무너지므로 F D-08을 다시 연다(동반 리졸버 교체 또는 (a)). 적용률이 낮으면 사용자 규칙·허용 목록은 Tailscale 없는 LAN 기기용으로만 보고 결과표에 기록한다 | E4a, 시나리오 14 | C.3.6, F D-08 |
| U34 | Tailscale provider v0.29.2의 `tailscale_dns_configuration`이 콘솔의 현재 DNS 설정을 그대로 옮긴 선언으로 새 state에 import하면 plan 무변경이고, `data.tailscale_devices`의 hostname 일치와 precondition(정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`), `100.` 대역 IPv4 고르기가 HCL로 동작한다(문서·소스로만 맞춰 썼고 실행하지 않음[S187]) **결과(2026-10-20, T08a):** import·DNS 동작은 통과다(콘솔 값 import 뒤 sensitive 표시만 바뀌는 계획, (b′) 목표 적용 뒤 plan 무변경, provider는 `Alpha Resource` 경고). 이 실행은 (a)의 소유자·태그 없음 precondition으로 했다. D-11 (c)의 `tag:nuc` precondition은 2026-10-21 (c) 적용 뒤 plan 무변경으로 통과했다(값이 같아 apply는 하지 않음). precondition의 실패 쪽은 2026-10-21 실제 provider 데이터로 확인했다. R2 state 대신 로컬 backend 사본에서 plan만 하고, hostname을 없는 이름으로(0대), 실제 기기 목록을 두 번 이어 붙여(2대), 기대 태그를 바꿔(태그 다름) 돌리자 각각 해당 precondition 오류로 중단했다. 바꾸지 않은 대조 사본은 통과했다. 2대와 태그 다름은 실제 기기가 아니라 식을 바꾼 흉내다(mock 시험은 v0.29.2 `devices` 중첩 블록을 채우지 못해 쓰지 않음, `infra/README.md`). | 콘솔에서 한 번 설정하고 `bootstrap.md`에 값의 출처와 확인 명령(`tailscale dns status --all`)을 적는 방식으로 돌아간다(IaC 밖, 드리프트는 사람 확인) | E4a | C.3.6, C.3.9 |
| U35 | GitHub Terraform root의 guard가 설계대로 동작한다: `github_rest_api` 데이터 소스 postcondition이 실패하면 plan이 오류로 멈추고(익명 폴백·admin 아닌 토큰 포함), 의존이 없는 guard 1·2·5~8은 늘 plan 때 읽히고, 관리 자원에 의존을 건 guard 3·4·9(3·9는 `depends_on`, 4는 endpoint의 `ruleset_id` 참조)는 그 자원에 변경이 없으면 plan 때 읽히며, `command = apply`인 run 블록에서 `terraform test`의 `mock_provider`와 인스턴스별 `override_data`로 guard 하나만 망가뜨린 음성 시험이 통과한다(문서·소스로 맞춰 썼다[S191][S193][S194]). **결과(2026-10-22, T10): 통과, fine-grained PAT 만료 머리글만 미실행.** postcondition 실패 → plan 오류: guard 1이 익명 폴백과 admin 아닌 토큰(배포 App 설치 토큰)에서 exit 1 "guard 1:"(approvals 2026-10-21 21:04~21:05 행), guard 3이 콘솔로 만든 선언 밖 ruleset `s15-undeclared`에서 verify exit 1(시나리오 15-12, approvals 2026-10-21 15:36~15:40 행). 변경 없는 verify(시나리오 15의 verify 1·3): `github_rest_api` 51개가 모두 plan 때 읽혔고 미뤄진 것 0. ruleset 변경 예정(guard 1 시험의 owner admin 대조 plan, `main_interim` 1 change): 미뤄진 것은 `rulesets_homelab` 1개와 `bypass_homelab` 6개("depends on a resource or a module with changes pending")뿐이고 나머지 44개는 plan 때 읽혔다. 변경 없는 `app_main`에 걸린 `rulesets_app`·`bypass_app`과 guard 9도 plan 때 읽혔다. guard 4는 `depends_on`이 아니라 endpoint의 `ruleset_id` 참조로 의존이 생겨 같은 방식으로 미뤄진다. mock 음성 시험은 필수 `ci`의 `terraform test`(`infra/github/tests`, run 36개)에서 돈다. 미실행: fine-grained PAT의 `GitHub-Authentication-Token-Expiration` 머리글. 래퍼는 머리글이 있는지만 보고 없으면 거부한다(`tools/tf-github.sh` 111~113행). 운영은 classic/OAuth 토큰을 쓰고 이 경로를 쓰지 않으며, 틀려도 거부 쪽으로 실패하므로 쓰게 될 때 확인한다 | guard를 래퍼의 `gh api` + `jq` 검사로 옮겨 plan 앞에서 실패시킨다. 변경이 예정된 동안 guard 읽기가 apply 뒤로 미뤄져 verify 출력에 guard 결과가 빠지면, apply 뒤 변경 없는 상태에서 verify를 다시 돌린다 | E5 | C.3.9 |
| U36 | Infisical Free에서 homelab 하나로 좁힌 fine-grained PAT의 App Connection으로 GitHub Secret Sync(범위 Repository Environment, `ukyi-app/homelab` / `automerge`)를 만들 수 있다(문서[S202], 실측 전). `deployment: false`인 job에도 environment의 배포 브랜치 정책(main)이 걸린다(문서는 용도로만 설명[S200]). 다른 저장소의 워크플로가 homelab 워크플로를 불러 `automerge`를 선언하면 caller 저장소의 environment로 해석돼 병합 키가 비어 있다(문서 문구로만 뒷받침[S81]). `AutoMerge`처럼 대소문자만 다른 이름은 같은 environment로 해석된다(문서 'not case sensitive'[S102]) | PAT 연결이 안 되면 Infisical GitHub App 연결로 바꾼다(대가: 조직 Secrets write가 org 전체에 걸림). 브랜치 정책이 `deployment: false`에서 안 걸리면 `deployment: false`를 빼고 배포 기록을 감수한다. 다른 저장소 실행에 키가 들어가면 자동 병합을 끄고 F D-04·D-07을 다시 연다 **결과(2026-10-21): 통과.** PAT App Connection으로 Sync 생성, environment secret `[HOMELAB_MERGE_KEY]`(10:5x~11:05 행). homelab 시험 브랜치의 `automerge`·`AutoMerge` 선언 job은 `deployment: false`에도 "Branch ... is not allowed to deploy to automerge due to environment protection rules"로 거부, 키 길이 줄 없음. `homelab-probe`가 homelab 워크플로를 불러 `automerge`를 선언하면 키 길이 0이고, caller 저장소에 보호 규칙 없는 빈 `automerge` environment가 생긴다(지움. approvals 15:05~15:30, 15:35 행). | E5, 시나리오 15 | C.4.8, F D-04 |
| U37 | Codex Connector의 PR은 사실상 늘 owner 계정이 작성자다(실측 2026-10-18: 이 org 1건과 공개 표본 30건. 공식 문서 없음). 그런 PR에서 Codex가 owner 권한으로 병합 API를 부를 수 있는지, 그 요청에 관리자 역할 bypass가 적용되는지는 문서에 없고, Codex에 병합 기능이 있는지도 확인하지 않았다. **2026-10-21:** 같은 권한 꼴(pull_requests·contents write, bypass 없음)의 배포 App이 owner PR #822를 승인하고 병합했다(U08 (나)). Codex Connector 설치 토큰도 같은 길을 쓸 수 있었다고 본다. Restrict updates(ruleset B·`app-main`) apply 뒤 재시험에서 App 설치 토큰(bypass 없는 App 신원)의 병합은 막혔다(같은 권한 꼴의 배포 App, 405 "Cannot update this protected ref.", approvals 21:27~21:33 행). Codex가 owner를 대신하는 사용자 토큰으로 움직이면 요청의 행위자는 owner라 관리자 역할 bypass가 적용되면 update 규칙도 막지 못한다. 이 경로와 bypass 적용 여부는 미확인이다. **결과(2026-10-22, approvals 2026-10-22 00:17·01:48~01:5x·11:11 행): 통과(조건부).** owner가 연 시험 PR #828에 `@codex`로 병합을 요청하자 Connector가 10초 뒤 "To use Codex here, create an environment for this repo." 답글만 달고 끝났다(커밋 그대로, 병합 없음). Codex 클라우드 작업(댓글·웹에서 시키는 코드 변경)은 저장소별 작업 환경이 있어야 시작되고 homelab에는 없어, owner를 대신하는 토큰으로 병합 API를 부르는 길이 지금은 없다. 조건(사용자 결정 2026-10-22 "환경 안 둘게", F D-26 (5)): homelab과 앱 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`(`infra/github/app-repos.json`의 앱 저장소), 이후 새 앱)에 Codex 작업 환경을 두지 않고, 리뷰(`@codex review`, 자동 리뷰)와 로컬 Codex CLI는 환경 없이 쓴다. homelab에 환경이 없는 것은 #828 답글로 확인한 사실이고, 나머지 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`)에 지금 환경이 없는 것은 사용자 확인이 근거다(Codex 설정 페이지의 환경 목록 0개, 사용자 2026-10-22 11:40 "환경 하나도 없어", approvals 같은 시각 행). 앞으로 두지 않는 것은 결정이다. 환경을 만들게 되면 그 전에 다시 시험한다. 관찰(원인 미확인): PR 본문의 `` `@codex` `` 언급만으로도 같은 답글이 15:38:36Z에 달렸고, #828에는 자동 코드 리뷰 요약이 생기지 않았다 | 된다면 Codex가 owner PR을 owner 검토 없이 병합할 수 있다. F D-26에서 설치 범위를 줄이거나 제거한다 | E5(Codex 작업에 시험 PR 병합을 요청해 결과만 기록), 시나리오 15 | C.4.7, F D-26 |
| U38 | 외부인(org 밖 계정)이 public 저장소의 fork PR이나 `@codex` 댓글로 Codex Connector의 리뷰·작업을 일으키지 못한다(공식 문서에 누가 호출할 수 있는지 없음). **결과(2026-10-22, approvals 2026-10-22 11:25·11:27·11:27~11:35 행): 미검증 유지, "틀리면" 대책을 먼저 적용**(사용자 결정 "대책 먼저 걸자", org 밖 두 번째 계정 시험 대신). 적용: org `ukyi-app` interaction limit `collaborators_only`(6개월, 만료 2027-04-22T02:25:06Z. org limit이라 org의 모든 public 저장소에 걸리고 새 앱 저장소에도 자동으로 걸린다), 저장소 다섯(homelab, `homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`)의 PR 생성 `collaborators_only`(REST 필드 `pull_request_creation_policy`. 저장소 GET 응답에 있고 PATCH가 받았다. 공식 REST 문서에는 아직 없고, 2026-02-13 변경 공지가 화면 설정을 설명한다). 셋째 대책(Codex 설치를 선택 저장소로)은 이미 되어 있다(D-16, 2026-10-18). 대책 아래 봇 동작: 배포 App의 배포 PR 생성(#830)과 병합 App 자동 병합, Codex 리뷰(#829)는 정상. Renovate는 대책 뒤 의존성 변화가 없어 대시보드 갱신이 없었고, Awaiting Schedule 9건이 월요일(2026-10-26) 일정에 PR로 열리는지로 본다. 6개월마다 다시 건다(다음 만료 2027-04-22, `docs/runbooks-public/github.md` 2절). 만료 알림은 verify guard 2만 둔다(사용자 결정 2026-10-22 17:50, approvals 같은 시각 행): limit이 `collaborators_only`이고 만료까지 45일 넘게 남았는지와 저장소 다섯의 PR 생성 정책을 확인해, 이번 만료 기준 2027-03-08부터 verify·plan·apply가 멈춘다(C.3.9). 캘린더 일정은 두지 않는다. 라이브 확인: #831 병합 뒤 `tools/tf-github.sh verify` exit 0, No changes, `github_rest_api` 52개 모두 plan 때 읽힘(`interaction_limit_org` 포함, approvals 2026-10-22 18:31 행). 막히는 경우는 CI mock 시험만 했다 | 일어나면 저장소 interaction limit `collaborators_only`와 PR 생성 Collaborators only를 걸고, Codex 설치를 선택 저장소로 줄인다(F D-26, F D-29) | E5(org 밖 두 번째 계정으로 시험 public 저장소의 fork PR에 `@codex review` 댓글을 달아 반응·사용량·push 여부 기록) | C.4.10, F D-26, F D-29 |
| U40 | 클러스터 유실과 Infisical 장애가 겹친 복구에서, root 값 `externalSecrets.enabled: false`로 ClusterSecretStore와 ExternalSecret을 렌더하지 않으면 root wave가 손으로 만든 Secret만으로 끝까지 진행하고, 값을 되돌렸을 때 ESO가 같은 이름의 기존 Secret을 넘겨받는다(설계 추론, 실행 전) | 넘겨받지 않으면 되돌리는 PR 직전에 손 Secret을 지운다(실행 중 파드는 env 유지). root가 진행하지 않으면 필요한 Application만 손으로 sync하는 절차를 `restore.md`에 둔다 | E8(시나리오 13을 VM에서 Infisical 접근을 막고 한 번 더) | C.6.4 |
| U39 | `GITHUB_TOKEN`으로 만든 GHCR 패키지가 저장소 가시성(public)을 물려받는다(Actions 문서[S213]. 패키지 문서는 접근 권한만 물려받고 가시성은 물려받지 않는다고 적어 서로 어긋남[S96]). org Package Creation에서 Public이 허용돼 있어야 한다(REST로 읽을 수 없음) | 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다(되돌릴 수 없음). 그 전까지 `homelab app add`가 그 앱을 거부한다 **결과(2026-10-21): 통과.** `homelab-probe` 첫 push로 만든 패키지가 `public`, 익명 토큰으로 manifest 200. org Package Creation Public·Internal 허용, "Inherit access from source repository" 켬(사람 확인). | E5(`homelab-probe` 첫 push 뒤 `gh api orgs/ukyi-app/packages/container/homelab-probe --jq .visibility`) | B.8 E5, C.4.10, F D-29 |

### 부록 2. 출처 (2026-10-17 확인. 다른 날 확인한 것은 항목에 날짜를 적음)

**Infisical**

- S01 가격 https://infisical.com/pricing
- S02 가격(Markdown 판) https://infisical.com/pricing.md
- S03 PITR https://infisical.com/docs/documentation/platform/pit-recovery
- S04 RBAC https://infisical.com/docs/documentation/platform/access-controls/role-based-access-controls
- S05 Universal Auth https://infisical.com/docs/documentation/platform/identities/universal-auth
- S06 Kubernetes Auth(Gateway 유료) https://infisical.com/docs/documentation/platform/identities/kubernetes-auth
- S07 API 속도 제한 https://infisical.com/docs/api-reference/overview/rate-limits
- S09 OIDC Auth for GitHub https://infisical.com/docs/documentation/platform/identities/oidc-auth/github , 2026-10-18 확인
- S10 `InfisicalStaticSecret` https://infisical.com/docs/integrations/platforms/kubernetes/infisical-static-secret-crd
- S11 ESO Infisical provider https://external-secrets.io/latest/provider/infisical/
- S14 GitHub Actions 연동 https://infisical.com/docs/integrations/cicd/githubactions , `Infisical/secrets-action` README와 릴리스(v1.0.18) https://github.com/Infisical/secrets-action
- S16 Kubernetes Operator 개요 https://infisical.com/docs/integrations/platforms/kubernetes/overview , 릴리스(v0.11.12) https://github.com/Infisical/kubernetes-operator/releases
- S17 OIDC Auth 일반 https://infisical.com/docs/documentation/platform/identities/oidc-auth/general
- S180 Universal Auth client secret API(identity별 목록 `GET /api/v1/auth/universal-auth/identities/{identityId}/client-secrets`는 client secret 배열을 돌려주고, 폐기는 `POST .../client-secrets/{clientSecretId}/revoke`로 하나씩) https://infisical.com/docs/api-reference/endpoints/universal-auth/list-client-secrets , https://infisical.com/docs/api-reference/endpoints/universal-auth/revoke-client-secret , 2026-10-18 확인
- S202 Infisical GitHub Secret Sync(범위 Repository·Organization·Repository Environment, Initial Sync Behavior, Key Schema, Auto-Sync, Disable Secret Deletion) https://infisical.com/docs/integrations/secret-syncs/github , GitHub App Connection(GitHub App 방식과 fine-grained PAT 방식. PAT 방식은 대상 저장소를 고르고 Metadata read, Environments RW, Secrets RW) https://infisical.com/docs/integrations/app-connections/github , 2026-10-18 확인
- S203 Infisical 소스 main `47246be`의 secret sync(GitHub 대상 범위 3종, 생성 때 org 전체 sync 수로 Free 10개 한도 검사, 값 변경 뒤 0~10초 지터, 실패하면 3초부터 지수 백오프로 5회, 일일 재시도는 ExternalInfisical 대상만, 마지막 시도가 실패하면 프로젝트 Admin 역할 멤버에게 메일·콘솔 알림, 보낼 키가 100개를 넘으면 재시도 없이 실패, 키 이름은 대문자로 바뀜, sync 대상 목록에 Kubernetes 없음. `backend/src/services/secret-sync/secret-sync-queue.ts`, `github/github-sync-fns.ts`, `secret-sync-maps.ts`) https://github.com/Infisical/infisical/tree/47246be/backend/src/services/secret-sync , 2026-10-18 확인

**External Secrets Operator**

- S20 안정성·지원 https://external-secrets.io/latest/introduction/stability-support/
- S21 ClusterSecretStore https://external-secrets.io/latest/api/clustersecretstore/
- S22 ExternalSecret https://external-secrets.io/latest/api/externalsecret/
- S23 소유·삭제 정책 https://external-secrets.io/latest/guides/ownership-deletion-policy/
- S24 저장소 https://github.com/external-secrets/external-secrets : 릴리스 v2.7.0·v2.10.0·v2.12.0·v2.13.0, v2.13.0 소스(`pkg/controllers/externalsecret/externalsecret_controller.go`, `externalsecret_controller_secret.go`, `pkg/controllers/util/util.go`의 `GetResourceVersion`(2026-10-18 확인), `providers/v1/infisical/client.go`·`provider.go`, CRD), 이슈 #6230·#6876·#7069, PR #6434·#6821

**CloudNativePG, PostgreSQL**

- S30 선언형 DB(1.30) https://cloudnative-pg.io/docs/1.30/declarative_database_management
- S31 선언형 역할(1.30) https://cloudnative-pg.io/docs/1.30/declarative_role_management
- S32 복원(1.30) https://cloudnative-pg.io/docs/1.30/recovery
- S33 Barman Cloud Plugin 소개 https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/
- S35 Barman Cloud Plugin 객체 저장소 https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/
- S36 릴리스 v1.30.0·v1.30.1과 `docs/src/supported_releases.md` https://github.com/cloudnative-pg/cloudnative-pg/releases , 차트 `cloudnative-pg` 0.29.1·`plugin-barman-cloud` 0.8.1 https://github.com/cloudnative-pg/charts/releases , plugin v0.15.1과 이슈 #411 https://github.com/cloudnative-pg/plugin-barman-cloud
- S37 Cloudflare R2 S3 API https://developers.cloudflare.com/r2/api/s3/api/ (PutObject의 `If-None-Match`·`If-Match`는 커밋된 버킷 상태에 원자적으로 평가되고 동시 `If-None-Match: *` 요청 중 최대 하나만 성공, 버킷 versioning API 미구현. 이 부분 2026-10-18 확인)
- S38 PgBouncer 기능표 https://www.pgbouncer.org/features.html

**Valkey**

- S41 영속성 https://valkey.io/topics/persistence/
- S42 CLI https://valkey.io/topics/cli/
- S43 공식 Helm 차트(`valkey-0.12.0`의 values·templates) https://github.com/valkey-io/valkey-helm , 발표 글 https://valkey.io/blog/valkey-helm-chart/
- S44 valkey-operator README https://github.com/valkey-io/valkey-operator
- S45 Bitnami 카탈로그 변경 https://github.com/bitnami/charts/issues/35164
- S47 `valkey.conf`(9.0.6) https://github.com/valkey-io/valkey/blob/9.0.6/valkey.conf

**Kubernetes, k3s**

- S46 Secret https://kubernetes.io/docs/concepts/configuration/secret/ , 자격 전달 https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- S49 RBAC(사용자용 기본 역할) https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- S50 k3s 채널 https://update.k3s.io/v1-release/channels
- S51 k3s 수동 업그레이드·설정 https://docs.k3s.io/upgrades/manual , https://docs.k3s.io/installation/configuration
- S53 k3s 네트워크 서비스(ServiceLB) https://docs.k3s.io/networking/networking-services
- S54 k3s 제거 https://docs.k3s.io/installation/uninstall
- S56 k3s 릴리스 https://github.com/k3s-io/k3s/releases
- S57 local-path-provisioner README https://github.com/rancher/local-path-provisioner/blob/master/README.md

**Argo CD**

- S60 릴리스(v3.5.5) https://github.com/argoproj/argo-cd/releases
- S61 설치 https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/
- S62 선언형 설정(Argo CD를 Argo CD로 관리) https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- S63 3.2 → 3.3 업그레이드(SSA 필수) https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.2-3.3/
- S66 ApplicationSet Git 생성기 https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/
- S67 sync 옵션 https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- S68 sync wave·hook https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- S69 health https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
- S70 RBAC https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/ , 내장 정책 https://raw.githubusercontent.com/argoproj/argo-cd/master/assets/builtin-policy.csv
- S71 사용자 관리 https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/
- S72 webhook https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/
- S74 Image Updater https://argocd-image-updater.readthedocs.io/en/stable/ (update-methods, update-strategies), 릴리스(v1.3.1) https://github.com/argoproj-labs/argocd-image-updater/releases
- S75 내장 resource customizations(v3.5.5) https://github.com/argoproj/argo-cd/tree/v3.5.5/resource_customizations
- S76 Helm 문서(v3.5.5, `helm.sh/resource-policy: keep`) https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/user-guide/helm.md
- S181 Argo CD v3.5.5 install.yaml의 NetworkPolicy 7개(application-controller, applicationset-controller, dex-server, notifications-controller, redis, repo-server, server. `argocd-server-network-policy`는 `ingress: [{}]`로 모든 출처 허용) https://github.com/argoproj/argo-cd/blob/v3.5.5/manifests/install.yaml , https://github.com/argoproj/argo-cd/blob/v3.5.5/manifests/base/server/argocd-server-network-policy.yaml , 2026-10-18 확인
- S182 Application 명세 예시(`retry.limit`이 0보다 작으면 무제한 재시도) https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/application.yaml , 2026-10-18 확인
- S183 sync 엔진(v3.5.5. 마지막 phase·wave에 hook이 아닌 리소스만 남으면 적용 직후 sync를 성공으로 끝내고, 그 뒤 리소스가 degraded가 되어도 같음, `gitops-engine/pkg/sync/sync_context.go:705-706`) https://github.com/argoproj/argo-cd/blob/v3.5.5/gitops-engine/pkg/sync/sync_context.go , 2026-10-18 확인
- S209 argocd-cm 설정(`timeout.reconciliation.jitter`: sync 주기에 더하는 최대 지연, 0이면 끔, 기본 1분) https://argo-cd.readthedocs.io/en/stable/operator-manual/argocd-cm-yaml/ , 2026-10-18 확인

**GitHub**

- S80 workflow 문법(concurrency) https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency
- S81 reusable 워크플로 https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations , https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows
- S82 contexts https://docs.github.com/en/actions/reference/workflows-and-actions/contexts
- S83 커밋 비교 API https://docs.github.com/en/rest/commits/commits#compare-two-commits
- S85 ruleset REST(bypass 모드 `pull_request`·`always`·`exempt`. `exempt` 행위자에게는 규칙을 돌리지 않고 bypass 감사 기록도 만들지 않음. `pull_request` 모드는 브랜치 ruleset에만. `bypass_actors`는 ruleset 전체에 걸림. `actor_type` 값 Integration, OrganizationAdmin, RepositoryRole, Team, DeployKey, User) https://docs.github.com/en/rest/repos/rules , UI 안내 https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository (행위자 목록이 아직 옛 목록: 역할, 팀(secret 팀 제외), App, Dependabot. 요금제 제한 언급 없음). 이 부분 2026-10-18 확인. 개인 사용자 bypass 도입은 S205
- S86 ruleset 개요 https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- S87 ruleset 규칙 목록 https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- S88 auto-merge https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request
- S90 `actions/create-github-app-token`(v3.3.0) https://github.com/actions/create-github-app-token
- S91 설치 토큰 https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
- S92 `GITHUB_TOKEN` https://docs.github.com/en/actions/concepts/security/github_token
- S93 Actions 조직·저장소 설정 https://docs.github.com/en/organizations/managing-organization-settings/disabling-or-limiting-github-actions-for-your-organization , https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository
- S94 `pull_request_target` 안전 사용 https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target
- S95 Actions 보안 https://docs.github.com/en/actions/reference/security/secure-use
- S96 패키지 가시성 https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility
- S98 webhook 서명 검증 https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
- S99 GitHub IP 주소 https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses
- S100 GitHub App 권한 표 https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
- S101 Actions 시크릿 사용 https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
- S102 environment 관리 https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments (environment 이름은 대소문자를 가리지 않음, environment를 지우면 그 secret과 보호 규칙도 지워짐. 이 부분 2026-10-18 확인)
- S103 OIDC 불변 subject https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens
- S104 워크플로 트리거(`workflow_run`) https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run
- S105 OIDC 참조(claim 목록, `id-token: write` 없이는 토큰 요청 불가) https://docs.github.com/en/actions/reference/security/oidc , 2026-10-18 확인
- S106 필수 리뷰가 있는 PR 승인(작성자 자기 승인 불가) https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews , 2026-10-18 확인
- S174 artifact attestations(담는 정보: 워크플로 링크, 저장소·조직·environment·커밋 SHA·트리거 이벤트. 가용성: Free·Pro·Team은 public 저장소만, private은 Enterprise Cloud. 컨테이너 이미지는 `subject-name`·`subject-digest`, 권한 `id-token: write`·`attestations: write`) https://docs.github.com/en/actions/concepts/security/artifact-attestations , https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations (가용성 문구는 그 페이지가 싣는 `github/docs@dae83f7:data/reusables/gated-features/attestations.md`, `gh api repos/github/docs/contents/data/reusables/gated-features/attestations.md`로 확인), `actions/attest`(v4.2.2) https://github.com/actions/attest , 2026-10-18 확인
- S175 `gh attestation verify`(`--signer-workflow`, `--cert-identity-regex`, `--source-ref`, `--source-digest`, `--deny-self-hosted-runners`, `--bundle-from-oci`, reusable 워크플로는 그 워크플로가 서명자) https://cli.github.com/manual/gh_attestation_verify , 2026-10-18 확인
- S176 attestation REST(`GET /repos/{owner}/{repo}/attestations/{subject_digest}`, 저장소 읽기 권한 필요) https://docs.github.com/en/rest/repos/attestations , 2026-10-18 확인
- S178 CODEOWNERS 오류 목록 REST(`GET /repos/{owner}/{repo}/codeowners/errors`, `ref` 인자, 응답 `errors` 배열, 200·404. 토큰 권한 표시 없음) https://docs.github.com/en/rest/repos/repos#list-codeowners-errors , 2026-10-18 확인
- S179 code owner 소개(파일 위치 `.github/`·루트·`docs/` 순, 브랜치마다 그 브랜치의 파일, 문법이 틀린 줄은 건너뜀, 소유자는 쓰기 권한 필요) https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners , 2026-10-18 확인
- S196 저장소 REST(Get a repository: 병합 관련 설정은 contents read·write 권한이 있어야 보임. Delete a repository: OAuth app 토큰과 classic PAT는 `delete_repo` 범위 필요) https://docs.github.com/en/rest/repos/repos , 2026-10-18 확인
- S197 삭제한 저장소 복원(90일 안. 같은 fork 네트워크의 다른 저장소가 남아 있으면 복원할 수 없고, Support에 복원을 요청하는 것은 유료 플랜만) https://docs.github.com/en/repositories/creating-and-managing-repositories/restoring-a-deleted-repository , 2026-10-18 확인
- S198 Actions 권한 REST(fork PR 기여자 승인 정책 `fork-pr-contributor-approval`의 값 `first_time_contributors_new_to_github`·`first_time_contributors`·`all_external_contributors`) https://docs.github.com/en/rest/actions/permissions , 2026-10-18 확인
- S199 GitHub App private key 관리(App마다 25개까지 만들 수 있어 중단 없이 회전, 만료되지 않고 손으로 폐기) https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps , 2026-10-18 확인
- S200 job의 environment(`jobs.<job_id>.environment`의 `name`과 `deployment: false`, 이름에 표현식 허용, 없는 이름을 참조하면 보호 규칙 없는 environment가 생김, reusable 워크플로에서는 caller가 secret을 넘겨야 함, Free는 public 저장소만) https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idenvironment , https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments , 2026-10-18 확인
- S201 personal access token 관리(fine-grained PAT의 대상 저장소·권한·만료 지정, 조직 정책이 fine-grained PAT 사용과 만료를 제한할 수 있음) https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens , 2026-10-18 확인
- S205 GitHub changelog: 저장소 ruleset 개인 사용자 bypass와 브랜치 이름 변경(2026-05-07. UI·REST·GraphQL로 저장소 수준 ruleset에 개인 사용자를 bypass 행위자로 넣음, 요금제 조건 언급 없음) https://github.blog/changelog/2026-05-07-repository-rulesets-user-bypass-and-branch-renaming , 2026-10-18 확인
- S206 rule suites REST(`GET /repos/{owner}/{repo}/rulesets/rule-suites`, `time_period`는 `hour`·`day`·`week`·`month`이고 기본 `day`) https://docs.github.com/en/rest/repos/rule-suites , 2026-10-18 확인(실측: 이 저장소에서 `day` 0건, `month` 1건)
- S207 ruleset 이력과 감사 로그(github/docs 기능 플래그 `data/features/repo-rules-history.yml`이 `ghec`와 `ghes >=3.19`뿐이라 ruleset History는 문서상 Enterprise 기능. org 감사 로그는 owner만 보고 최근 180일, 이벤트 `repository_ruleset.create`·`update`·`destroy`, 감사 로그 REST·GraphQL API는 Enterprise Cloud) https://github.com/github/docs/blob/main/data/features/repo-rules-history.yml , https://docs.github.com/en/organizations/keeping-your-organization-secure/managing-security-settings-for-your-organization/reviewing-the-audit-log-for-your-organization , 2026-10-18 확인
- S208 `gh pr merge`(`--match-head-commit`: head가 그 SHA일 때만 병합, `--admin`) https://cli.github.com/manual/gh_pr_merge , gh 이슈 #13388(2026-05-15 gh 관리자 댓글: `--admin`은 클라이언트 쪽 확인일 뿐 API에 특별한 것을 보내지 않음. 공식 문서 아님) https://github.com/cli/cli/issues/13388 , 2026-10-18 확인
- S213 Actions로 패키지 게시(`GITHUB_TOKEN`으로 만든 패키지는 워크플로를 실행한 저장소의 가시성과 권한 모델을 물려받음. S96의 "access permissions (but not the visibility)"와 어긋남) https://docs.github.com/en/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions , 2026-10-18 확인
- S214 public 저장소 보안 설정(공개 전환은 GitHub Advanced Security 기능을 쓸 수 있게 할 뿐 켜지 않음. secret scanning·push protection은 저장소 `security_and_analysis`, private vulnerability reporting은 별도 엔드포인트, interaction limit 값 `existing_users`·`contributors_only`·`collaborators_only`와 최대 `six_months`) https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility , https://docs.github.com/en/rest/repos/repos , https://docs.github.com/en/rest/interactions/orgs , 2026-10-18 확인
- S218 `author_association` 값(CommentAuthorAssociation: `CONTRIBUTOR`는 "Author has previously committed to the repository", `MEMBER`는 "Author is a member of the organization that owns the repository", `NONE`은 관계 없음. App 계정이 받는 값은 문서에 없다) https://docs.github.com/en/graphql/reference/issues , 2026-10-18 확인
- S231 Mend Renovate Community Cloud(무료, public·private 저장소 수 제한 없음. org당 동시 job 1개, 활성 저장소는 4시간마다 스케줄, runner 1 vCPU·3GB 메모리·15GB 디스크, job 30분. Merge Confidence 워크플로·헬프데스크 없음. 대시보드 developer.mend.io) https://docs.renovatebot.com/mend-hosted/overview/ , 2026-10-21 확인
- S232 호스팅형 Renovate App 권한(Dependabot alerts·Administration·Metadata read, Checks·Contents·Commit statuses·Issues·Pull requests·Workflows read and write)과 저장 데이터(저장소별 의존성·버전 목록과 PR 기본 정보, job 뒤 소스 미보관) https://docs.renovatebot.com/security-and-permissions/ , 2026-10-21 확인
- S233 Mend 이용 약관(2025-03 갱신. 무료 서비스는 as-is, 유료 플랜을 나중에 더할 수 있음, 서비스 제공에 필요한 범위의 `Your Data` 이용 허락, 프로젝트 일부(메타데이터·의존성·파일 일부) 검사) https://www.mend.io/terms-of-service/ , 2026-10-21 확인
- S234 GitHub Marketplace Renovate(Community Cloud $0, 개인·org, public·private, 설치 때 저장소 선택) https://github.com/marketplace/renovate , 2026-10-21 확인
- S235 ruleset bypass "For pull requests only"("without allowing them to push directly", 그 행위자는 PR을 열어 "bypass any branch protections and merge that pull request") https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository , Restrict updates("only users with bypass permissions can push to branches or tags whose name matches") [S87]. 두 문서 모두 update 규칙과 pull_request 모드 bypass 병합을 함께 다루지는 않는다. 2026-10-21 확인
- S215 PostgreSQL 18 pg_restore(`--clean`은 복원할 데이터베이스 객체를 다시 만들기 전에 지운다. 덤프에 없는 객체는 대상이 아니다) https://www.postgresql.org/docs/18/app-pgrestore.html , 2026-10-18 확인
- S216 PostgreSQL 18 DROP DATABASE(`WITH (FORCE)`는 대상 DB의 기존 연결을 끊고 지운다) https://www.postgresql.org/docs/18/sql-dropdatabase.html
- S217 Tailscale Terraform provider v0.29.2 `tailscale_dns_configuration` 문서(Import 절) https://github.com/tailscale/terraform-provider-tailscale/blob/v0.29.2/docs/resources/dns_configuration.md , 2026-10-18 확인

**Terraform**

- S191 Terraform GitHub provider(`integrations/github` v6.13.0, 2026-07-08, 그 뒤 릴리스 없음. 리소스 `github_repository_ruleset`(import ID `저장소:ruleset_id`, `name` 변경은 제자리, bypass `actor_type`·`bypass_mode`, RepositoryRole admin의 `actor_id` 5), `github_repository_environment`·`github_repository_environment_deployment_policy`, `github_actions_repository_permissions`, `github_workflow_repository_permissions`. 데이터 소스 `github_rest_api`는 provider 인증으로 임의 GET을 보내고 404를 오류로 보지 않음. fork PR 승인 정책 리소스 없음(#3445·#3446 열림). 인증은 문서상 token이 먼저지만 소스는 `GITHUB_APP_ID`·`GITHUB_APP_INSTALLATION_ID`·`GITHUB_APP_PEM_FILE`이 모두 있으면 App 인증을 먼저 쓰고, gh 호출이 실패하면 빈 토큰(익명)으로 떨어짐. environment secret 리소스는 값을 state에서 숨기지 않음) https://github.com/integrations/terraform-provider-github/tree/v6.13.0 , https://registry.terraform.io/providers/integrations/github/6.13.0/docs , 2026-10-18 확인
- S192 GitHub provider 이슈 #3519(legacy 클라이언트가 state의 etag로 조건부 GET을 보내 304면 갱신하지 않으므로, 갱신 apply가 한 번 실패하면 그 리소스의 드리프트가 `-refresh-only`로도 안 보임. `github_repository_ruleset` 포함)와 수정 PR #3637(2026-09-09 main 병합, 미출시) https://github.com/integrations/terraform-provider-github/issues/3519 , https://github.com/integrations/terraform-provider-github/pull/3637 , 2026-10-18 확인
- S193 Terraform 사용자 정의 조건과 check(postcondition이 실패하면 오류로 작업을 멈추고 이미 한 작업은 되돌리지 않음, check 블록은 실패해도 경고만 내고 계속, 데이터 소스는 변경 예정 리소스에 의존하면 apply 때 읽힘) https://developer.hashicorp.com/terraform/language/expressions/custom-conditions , https://developer.hashicorp.com/terraform/language/checks , 2026-10-18 확인
- S194 Terraform test mock(`mock_provider`는 덮어쓰지 않은 계산 문자열 속성에 임의 8자 영숫자를 넣음, `override_data`는 v1.16.6 소스상 인스턴스 주소 허용) https://developer.hashicorp.com/terraform/language/tests/mocking , 2026-10-18 확인
- S195 Terraform S3 backend(`use_lockfile`은 잠금 파일 `<key>.tflock`을 조건부 쓰기 `If-None-Match: *`로 만듦(v1.16.6 소스의 lockWithFile), S3 호환 저장소는 best effort 지원, backend 설정과 `-backend-config` 값은 `.terraform`과 plan 파일에 남으므로 자격은 환경변수로) https://developer.hashicorp.com/terraform/language/backend/s3 , https://github.com/hashicorp/terraform/tree/v1.16.6/internal/backend/remote-state/s3 , 2026-10-18 확인

**Tailscale**

- S110 DNS https://tailscale.com/kb/1054/dns , https://tailscale.com/docs/reference/dns-in-tailscale
- S111 NextDNS 연동(다른 전역 nameserver를 두지 말 것) https://tailscale.com/docs/integrations/nextdns
- S114 Kubernetes operator https://tailscale.com/kb/1236/kubernetes-operator
- S115 operator 클러스터 ingress https://tailscale.com/kb/1439/kubernetes-operator-cluster-ingress
- S116 operator 설치 https://tailscale.com/docs/kubernetes-operator/install-operator , 차트 색인 https://pkgs.tailscale.com/helmcharts/index.yaml
- S117 정책 문법 https://tailscale.com/kb/1337/policy-syntax
- S119 키 만료 https://tailscale.com/kb/1028/key-expiry
- S120 HTTPS 인증서(CT 로그 공개) https://tailscale.com/kb/1153/enabling-https
- S121 Tailscale SSH(`check`의 checkPeriod 기본 12시간·1분~168시간, 태그 dst에서 `autogroup:nonroot` 경고, 2026-10-18 확인) https://tailscale.com/kb/1193/tailscale-ssh
- S184 태그(태그를 붙이면 사용자 기반 인증이 지워지고, 기기는 태그와 사용자 계정 중 하나만 가짐) https://tailscale.com/kb/1068/tags , 2026-10-18 확인
- S185 Application `syncPolicy.retry.refresh`(v3.5.5. 재시도 때 처음 revision 대신 최신 revision을 쓴다, 기본 false, `pkg/apis/application/v1alpha1/types.go:1549-1550`) https://github.com/argoproj/argo-cd/blob/v3.5.5/pkg/apis/application/v1alpha1/types.go , 2026-10-18 확인
- S186 Tailscale 클라이언트 DNS 소스(v1.104.1. `net/dns/resolver/forwarder.go`: 일반 IP nameserver는 모두 0ms에 동시 질의, 자동 DoH 목록의 공용 DNS는 DoH를 먼저 보내고 평문 UDP를 500ms 뒤 예비로 보냄, 같은 사업자 둘째 주소는 200ms 더 늦게, 처음 온 정상 응답 채택, SERVFAIL·REFUSED는 약한 오류, UDP 2초 무응답이면 TCP 병행, TCP 5초, 'DNS unavailable' 경고 15초, DNSSEC 검증 없음. `net/dns/publicdns/publicdns.go`: 자동 DoH 목록에 AdGuard가 없음. `net/dns/resolver/tsdns.go`: 질의 상한 10초, MagicDNS 이름은 기기 목록으로 직접 답함) https://github.com/tailscale/tailscale/tree/v1.104.1/net/dns , 2026-10-18 확인
- S187 Terraform Tailscale provider(v0.29.2, 2026-05-26. `tailscale_dns_configuration`은 tailnet DNS 설정 전체를 관리하고 `tailscale_dns_nameservers` 등 다른 DNS 리소스와 함께 쓰지 말 것, 기본값 `override_local_dns=false`·`magic_dns=true`·`use_with_exit_node=false`, `use_with_exit_node`는 클라이언트 1.88.1 이상. v0.24.0(2025-10-30)에서 alpha 표시 해제. 데이터 소스 `tailscale_device`는 hostname이 여럿 맞으면 첫 기기를 고르고 없으면 오류(`tailscale/data_source_device.go:105-118`), `addresses`의 순서는 문서에 없음, `tailscale_devices`는 목록을 돌려줌) https://registry.terraform.io/providers/tailscale/tailscale/0.29.2/docs , https://github.com/tailscale/terraform-provider-tailscale , 2026-10-18 확인
- S188 `tailscale/github-action`(v4.2.0. workload identity federation: `oauth-client-id`·`audience`와 `id-token: write`로 저장한 시크릿 없이 tailnet에 붙음, Tailscale 1.90.1 이상, 태그 필수) https://github.com/tailscale/github-action , 2026-10-18 확인
- S211 Tailscale v1.104.1 소스(`ipn/ipnlocal/serve.go`: 정확한 host:port 설정에만 인증서를 내고 발급이 실패하면 핸드셰이크 실패. `feature/acme/cert.go`: 유효한 캐시 인증서만 쓰고 수명의 2/3에서 갱신. `cmd/k8s-operator/ingress.go`: http-redirect는 `301:https://${HOST}${REQUEST_URI}`) https://github.com/tailscale/tailscale/blob/v1.104.1/ipn/ipnlocal/serve.go , https://github.com/tailscale/tailscale/blob/v1.104.1/feature/acme/cert.go , https://github.com/tailscale/tailscale/blob/v1.104.1/cmd/k8s-operator/ingress.go , 2026-10-18 확인
- S221 tailnet DNS 이름(fun name은 생성된 후보에서만 고름, HTTPS 인증서에 쓴 뒤에는 다시 생성할 수 없음, 바꾸면 기존 링크가 깨질 수 있음) https://tailscale.com/kb/1217/tailnet-name , 2026-10-20 확인
- S222 MagicDNS(Tailscale이 검색 도메인을 더해 기기 이름만으로 접근) https://tailscale.com/kb/1081/magicdns , 2026-10-20 확인
- S223 다른 VPN과 함께 쓰기("iOS and Android enforce a limit of running only one VPN at a time") https://tailscale.com/docs/reference/faq/other-vpns , 2026-10-20 확인
- S224 golink(노드 이름 `go`, `TS_AUTHKEY`·SQLite·영속 볼륨) https://github.com/tailscale/golink , 2026-10-20 확인
- S229 operator L3 노출(`loadBalancerClass: tailscale`, `tailscale.com/hostname`) https://tailscale.com/docs/kubernetes-operator/ingress/expose-workload-to-tailnet-l3 , v1.104.1 소스의 `tailscale.com/tags` 어노테이션(`cmd/k8s-operator/sts.go`, Service에도 적용 `svc.go`) https://github.com/tailscale/tailscale/blob/v1.104.1/cmd/k8s-operator/sts.go , 2026-10-20 확인
- S230 Tailscale 대상과 선택자(`autogroup:admin`은 Admin 역할, `autogroup:owner`는 Owner 역할로 따로 정의) https://tailscale.com/docs/reference/targets-and-selectors , 2026-10-20 확인

**Cloudflare, HSTS**

- S130 터널 로컬 관리(원격 관리 권장) https://developers.cloudflare.com/tunnel/advanced/local-management/
- S131 터널 Kubernetes 가이드 https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/
- S132 터널 Terraform 가이드 https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
- S133 cloudflared 릴리스 https://github.com/cloudflare/cloudflared/releases
- S134 터널 ingress 규칙(설정 파일) https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/
- S135 터널 설정 API https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/configurations/methods/update/
- S136 WAF 사용자 규칙 https://developers.cloudflare.com/waf/custom-rules/
- S137 규칙 언어 연산자 https://developers.cloudflare.com/ruleset-engine/rules-language/operators/
- S139 Access 정책 https://developers.cloudflare.com/cloudflare-one/access-controls/policies/
- S140 Cloudflare HSTS https://developers.cloudflare.com/ssl/edge-certificates/additional-options/http-strict-transport-security/
- S141 Universal SSL 한계 https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/
- S142 MDN HSTS https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security
- S177 터널 메트릭(`cloudflared_tunnel_ha_connections`: 활성 HA 연결 수) https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/monitor-tunnels/metrics/ , 2026-10-18 확인
- S210 HSTS preload 목록 조회(`app` 최상위 도메인이 `preloaded`, `ukyi.app`은 `app`으로 preload됨) https://hstspreload.org/api/v2/status?domain=app , https://hstspreload.org/api/v2/status?domain=ukyi.app , 2026-10-18 확인
- S212 cert-manager Certificate(기본으로 인증서 수명의 2/3 시점에 갱신) https://cert-manager.io/docs/usage/certificate/ , 2026-10-18 확인
- S225 Public Suffix List의 `ts.net`(Tailscale Inc. 항목) https://publicsuffix.org/list/public_suffix_list.dat , 2026-10-20 확인
- S226 MDN Site(등록 도메인이 같으면 하위 도메인끼리 같은 사이트), Set-Cookie(하위 도메인이 상위 도메인 쿠키를 설정할 수 있음, SameSite는 사이트 기준) https://developer.mozilla.org/en-US/docs/Glossary/Site , https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie
- S227 Cloudflare DNS TTL("A TTL of Auto is set to 300 seconds") https://developers.cloudflare.com/dns/manage-dns-records/reference/ttl/ , 2026-10-20 확인
- S228 Cloudflare 하위 도메인 zone(subdomain setup)은 Enterprise만 https://developers.cloudflare.com/dns/zone-setups/subdomain-setup/ , 2026-10-20 확인

**AdGuard, 관측·알림, 빌드**

- S151 AdGuard Home 설정 https://adguard-dns.io/kb/adguard-home/configuration/
- S152 AdGuard Home 릴리스 https://github.com/AdguardTeam/AdGuardHome/releases
- S189 AdGuard DNS 공용 서버(기본 서버 `94.140.14.14`·`94.140.15.15`와 IPv6 2개, "These servers block ads, tracking, and phishing") https://adguard-dns.io/kb/general/dns-providers/ , 2026-10-18 확인
- S190 AdGuard DNS filter("default filter for AdGuard Home and for the public AdGuard DNS servers") https://github.com/AdguardTeam/AdGuardSDNSFilter , 2026-10-18 확인
- S204 NextDNS 가격(무료는 월 300,000 질의, 넘으면 차단 없는 일반 DNS로 답함, Pro 월 ₩2,500·연 ₩25,000) https://nextdns.io/pricing , 2026-10-18 확인
- S160 healthchecks.io 가격 https://healthchecks.io/pricing/
- S161 healthchecks.io HTTP API https://healthchecks.io/docs/http_api/
- S162 Watchdog 런북 https://runbooks.prometheus-operator.dev/runbooks/general/watchdog/
- S163 Alertmanager 설정 https://prometheus.io/docs/alerting/latest/configuration/
- S164 Alertmanager 릴리스 https://github.com/prometheus/alertmanager/releases
- S165 Telegram Bot API https://core.telegram.org/bots/api
- S167 VictoriaMetrics single-node(직접 스크레이프) https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/
- S170 `docker/build-push-action`(v7.4.0, 출력 `digest`) https://github.com/docker/build-push-action
- S171 OCI 이미지 주석 https://github.com/opencontainers/image-spec/blob/main/annotations.md
- S172 Telegram 봇 소개(봇은 사용자와 대화를 먼저 시작할 수 없음) https://core.telegram.org/bots , 2026-10-18 확인
- S173 Telegram 봇 기능(BotFather `/token`: 토큰이 유출되거나 잃었을 때 새로 만듦) https://core.telegram.org/bots/features , 2026-10-18 확인

**OpenAI Codex**

- S219 Codex ChatGPT 관리 인증의 CI/CD 사용("advanced workflow for enterprise and other trusted private automation", "Do not use this workflow for public or open-source repositories", 조건 다섯 중 "you can preserve the refreshed auth.json between runs"와 "only one machine or serialized job stream will use a given auth.json copy", `last_refresh`가 약 8일보다 오래되면 갱신해 `auth.json`에 다시 씀, 영속 `CODEX_HOME`에서 "seed auth.json only if it is missing", 다른 기기·동시 작업이 토큰을 먼저 돌리거나 옛 파일이 복원되면 재시드) https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18 확인
- S220 Codex 비대화형 실행("Codex requires commands to run inside a Git repository", 끄려면 `--skip-git-repo-check`) https://learn.chatgpt.com/docs/non-interactive-mode , 2026-10-18 확인

**옛 저장소와 실측:** 옛 저장소 근거는 본문의 `2d2054a:<경로>:<줄>`(B절은 B.0의 줄임 표기)이다. 실측 명령은 0절과 B.4에 적었다. 조사 메모(저장소 밖)는 이 문서에 필요한 내용을 모두 옮겼다.
