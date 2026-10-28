# 홈랩 신규 구축 + AI 봇: 전체 계획

작성일: 2026-10-17
상태: 계획 갱신(2026-10-17 심층 감사, 2026-10-18 사용자 결정 반영). 합의(A) 부분 완료, 명세(B)·티켓(C) 갱신 완료. 자세한 상태는 §2.
문서 지도: [README.md](README.md)
대상 저장소: `ukyi-app/homelab` (같은 이름, 같은 저장소 재사용)

---

## 1. 한눈에 보기

- **무엇을:** 옛 홈랩을 걷어내고 같은 이름의 새 홈랩 플랫폼을 짓는다. 그 위에 첫 실제 앱으로 Discord AI 운영 봇 V1을 올린다.
- **순서:** 정리(P0) → 플랫폼 설계(P1) → 플랫폼 구축(P2), 봇 문서 정비와 DISCOVERY(P3)는 P2와 병행 → 봇 V1 구현(P4) → 기존 앱 재연결(P5). 이 순서는 확정이다(D-01, 2026-10-17). P4의 첫 티켓 T16a(FOUNDATION 로컬·mock)는 플랫폼을 쓰지 않아 T15 뒤 P2와 병행하고, 실연동·첫 배포(T16b)는 T13 뒤다(V1 범위 조정, §5.1).
- **지금 바로 할 수 있는 것(2026-10-26):** T08a·T08c·T08b·T11·T10·T12가 끝났다(2026-10-21·22·23·23·26·26). 다음은 T13(테스트 앱 통합 검증)이다. T16a도 끝나(2026-10-20) T17·T18·T20의 로컬·mock 착수가 가능하다. 전체 상태는 §8.3이다. D-14 차단 조건 때문에 공개 저장소 내용으로 구독 모델을 부르는 T17·T18 작업은 OpenAI 허용 확인이나 공식 지원 인증 전환 뒤에만 한다(§5.1).
- **가장 큰 위험(T07 전 기준. 2026-10-19 T06 철거와 T07 main 교체로 해소):** 옛 Argo CD가 아직 main을 `prune`·`selfHeal` 자동 동기화로 따라간다. 옛 클러스터를 내리기 전에는 main을 바꾸지 않고, 새 작업은 `rebuild` 브랜치에 둔다. 브랜치 보호가 관리자를 막지 않으므로(`enforce_admins=false`) push는 항상 명시적 refspec으로 한다.

### 현재 상태 (2026-10-17 실측, 2026-10-18 결정 반영)

| 항목 | 상태 |
|---|---|
| 옛 저장소 GitHub Actions | 비활성화 완료 (되살리기: `enabled=true`, `allowed_actions=all`) |
| 옛 저장소 열린 PR | 0개. 2026-10-17에 10개(renovate 5, aiops 5)를 닫았다(T01). 그중 renovate 5개는 `gate`가 통과한 병합 가능 상태였다. 브랜치는 남아 있다 |
| 원격 main | `2d2054aa294b3862de1b1af6eada88fb15e656e6` (2026-10-07 이후 변화 없음). annotated `legacy` 태그가 이 커밋을 가리킨다(T01, 2026-10-17) |
| GitHub org·저장소 | org는 Free 플랜. `homelab`은 public이고, 브랜치 보호·ruleset은 public이라서 동작한다(Free에서는 private 저장소에 쓸 수 없다). squash 병합만 허용하고 병합 뒤 브랜치를 자동 삭제한다. 저장소 설정 `allow_auto_merge`가 켜져 있다. D-07(확정(사용자 2026-10-18, T05))에 따라 T06에서 끈다. 앱 저장소(`page`, `trip-mate-api`, `files`, `homelab-app-template`)는 public인데 main 보호와 ruleset이 없다. `aiops`, `aiops-autodeploy-canary`는 private라 보호를 걸 수 없다. 2026-10-18 결정: 앱 저장소는 public만 허용한다(D-29). `page`·`trip-mate-api`는 저장소와 GHCR 패키지를 삭제했다(2026-10-18 실행). `files`·`homelab-app-template`에는 `CODEOWNERS`와 `app-main` ruleset 등을 걸었다(결정 5, §5.1, 2026-10-18 실행) |
| org GitHub App | 옛 reader·writer(전체 저장소. T06에서 삭제, D-11), 옛 aiops(선택 저장소. 제거 확정, 실행 T22), ChatGPT Codex Connector(2026-10-07 설치, contents·workflows·actions·issues·pull_requests 쓰기, PR을 열면 자동 리뷰. 조건 다섯을 걸고 유지한다, D-26(다섯째는 2026-10-22 사용자 결정). 설치 범위는 전체 저장소였고, 2026-10-18 17:45에 사람이 선택 저장소로 줄였다, D-16, §11. `repository_selection` = `selected`는 API로 확인했고, 남긴 저장소 목록은 사용자 보고다). D-11·D-26은 확정(사용자 2026-10-18, T05), D-16은 확정(사용자 2026-10-18, T15) |
| 다른 저장소의 열린 renovate PR | 29개였다(`page` 10, `trip-mate-api` 10, `homelab-app-template` 5, `aiops-autodeploy-canary` 4). `page`·`trip-mate-api`를 지워 9개가 남았다(2026-10-18 재조회, 설계 0절). 새 플랫폼은 호스팅형 Renovate App을 저장소별로 설치하고 자동 병합은 모두 끈다(D-18, 확정(사용자 2026-10-18, T05)) |
| 커밋 작성자 이메일 | 원격 `rebuild`의 커밋 `56eeb54`, `53fc932`, `4bb61ef`는 개인 이메일이고, 2026-10-18의 T04 커밋 몇 개는 잠시 쓴 noreply 주소다. 커밋 작성자 이메일 공개는 사용자가 받아들였다(2026-10-18). GitHub 이메일 비공개 설정은 하지 않고, 작업 사본의 로컬 noreply 설정도 지워 전역 설정(개인 이메일)으로 커밋한다 |
| 옛 클러스터 | 가동 중. NUC `nuc-15-pro`(LAN `192.168.117.15`)에서 k3s active. Application 22개가 모두 main을 따라간다 |
| 공유기 DNS | 주 `192.168.117.15`(AdGuard), 보조 `1.1.1.1`. 변경하지 않음 |
| Tailscale 전역 DNS | NUC(AdGuard) + Cloudflare Public DNS. 임시 폴백이라 광고 차단은 불안정. D-08이 확정(사용자 2026-10-18)돼 T08a에서 NUC(AdGuard Home) + AdGuard 공용 DNS 2개로 바꾼다(§4.5) |
| NUC 로컬 전용 자료 | git 밖 옛 런북, Terraform 자격 파일, 원격 없는 다른 프로젝트가 이 디스크에만 있다(§4.5). OS를 유지하고(D-12), T06 목록 작성에만 읽기 전용으로 쓴다(D-27). 둘 다 확정(사용자 2026-10-18, T05) |
| 플랫폼 프롬프트 | [platform/design-prompt.md](platform/design-prompt.md). T03 보강과 2026-10-17 감사 반영. 확정 결정의 자리는 2026-10-18에 T05가 채웠고, T15 결정(D-14~D-17, D-24)의 자리도 같은 날 채웠다 |
| 봇 문서 | [봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/prompts/`](https://github.com/ukyi-app/homelab-bot/tree/main/docs/ai-bot/prompts)의 `00`~`04`. 2026-10-18에 homelab `bot/`에서 PR로 옮겼다(봇 저장소 PR #1, D-13, §4.3). 결정 자리는 T05·T14가 채웠다. T15 결정(D-14~D-17, D-24)의 자리는 봇 저장소 PR로 채운다(§4.3) |
| `docs/` | `/home/ukyi/homelab`이 `ukyi-app/homelab`의 작업 사본이다(브랜치 `rebuild`, T02). 계획 문서는 원격 `rebuild`에 있다 |

---

## 2. 계획 상태

| 단계 | 상태 | 근거 |
|---|---|---|
| A. 합의 | 계획 수준 완료 | 확정 결정 38개(§5.1: C-01~C-08, D-01~D-30). 그중 T05 결정 게이트 14개(D-05~D-07, D-09~D-12, D-18, D-20~D-22, D-25~D-27)와 설계 F "추가 확인"의 기본값은 2026-10-18 T05 질문 응답으로, T14 결정 게이트(D-13의 나머지, D-19)는 같은 날 T14 질문 응답으로, T15 결정 게이트 5개(D-14~D-17, D-24)와 R08 보류, V1 범위 조정은 같은 날 T15 질문 응답으로 확정했다. D-30(내부 UI 짧은 주소)은 2026-10-20 대화로 확정했다. 지금 정할 결정 없음. 남은 단계 결정 게이트 없음(§5.3) |
| B. 명세 | 갱신 완료 | 이 문서. 인수 조건은 §7, 대응표는 §9 |
| C. 티켓 | 갱신 완료 | `issues/` 26개. T05가 2026-10-18에 P2 티켓을 설계 E에 맞춰 다시 쪼갰다(T08 → T08a·T08b). T15가 같은 날 V1 범위 조정(§5.1)에 따라 T16을 T16a·T16b로 나눴다. 2026-10-20 D-30으로 T08c를 더했다. 2026-10-29 T13 후속으로 T23을 더했다(사용자 결정). 상태는 §8.1·§8.3이다. 의존성 그래프는 §8 |

용어집: 없음. 새 저장소에 `GLOSSARY.md`가 없고, 이 계획을 위해 만들지 않았다.

**2026-10-17 심층 감사:** 문서 전체를 다섯 관점(봇 문서, 참조 무결성, 현실 대조, 계획 위험, T04 준비도)으로 감사하고 발견을 적대적으로 검증했다. 반영한 결과는 이 문서와 티켓, 프롬프트 문서에 있다. 감사 원본에는 NUC 경로와 App ID 같은 환경 식별자가 많아 저장소에 넣지 않았다.

---

## 3. 출처

| ID | 출처 | 상태 |
|---|---|---|
| S1 | [platform/design-prompt.md](platform/design-prompt.md) (플랫폼 프롬프트) | 플랫폼 설계 지시. T03 보강과 2026-10-17 감사 반영 |
| S2 | 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/prompts/` `00-start.md`~`04-audit-handoff.md` (봇 문서 `00`~`04`. 2026-10-18 전에는 homelab `bot/`) | 봇 V1~V5 지시, 요구 ID, 시험 카탈로그 |
| S3 | 2026-10-17·2026-10-18 대화의 결정 | §5.1 |
| S4 | 실측 | 옛 저장소 `origin/main` `2d2054a`(2026-10-07 fetch 기준), NUC 상태, GitHub·Tailscale 조회, 2026-10-17 감사의 읽기 전용 조회(`gh api` GET, `systemctl`, `tailscale` CLI, 옛 사본 kubeconfig로 한 `kubectl get`) |

---

## 4. 문서 분석

### 4.1 문서 지도

| 문서 | 역할 | 핵심 내용 |
|---|---|---|
| S1 | 플랫폼 설계 프롬프트 (조사·설계만) | 확정 전제, 구축 전 정리 6항목, 교훈 표, 기반 플랫폼, CI/CD, PostgreSQL·Valkey, 시크릿, CLI, 검증 시나리오 17개, 산출물 0·A~G |
| `00` | 봇 시작점 | 제품 정의, V1 필수 기능 7개, 보안 경계 9개, 공통 작업 규칙 10개, 설정 초안 |
| `01` | 봇 V1 | STAGE 7개, 공통 계약 F01~F09, 요구 R01~R18 |
| `02` | 봇 V2·V3 | V2 기능 12개, V3 기능 9개, 버전 진입 조건 |
| `03` | 봇 V4·V5 | V4 기능 7개(승인형 실행), V5 기능 6개(선택), 승인 객체 계약 |
| `04` | 감사·인수인계 | 감사 프롬프트, 작업 상태 10종, 증거 5등급, V1 수용 시험 30개, HANDOFF 양식, 출시 판정 4종 |
| [approvals.md](approvals.md) | 외부 변경 승인 기록 | 시각, 대상, 작업, 명령 또는 링크, 티켓 (AC-X2) |

**역할 규칙:** 상태·결정·순서·티켓의 기준은 이 명세다. 에이전트가 실행할 지시문, 요구 ID, 시험 카탈로그의 기준은 플랫폼 프롬프트와 봇 문서다. 두 쪽이 어긋나면 결정은 이 명세를, 지시와 ID는 프롬프트 문서를 따르고, 어긋난 쪽을 같은 변경에서 고친다.

### 4.2 두 문서 묶음의 관계

봇은 플랫폼이 제공하는 것 위에서만 돈다. 아래 표는 봇 문서의 요구를 플랫폼 쪽에서 다시 읽은 것이고, 마지막 열은 플랫폼 프롬프트에서 다루는 절이다.

| 봇 요구 (출처) | 플랫폼이 제공할 것 | 플랫폼 프롬프트 |
|---|---|---|
| 영속 inbox/outbox/job, 기억, 상태 백업 (F02, F07, R16) | PostgreSQL과 백업 | 있음 (§6) |
| Discord 토큰, GitHub App 키, 모델 자격 (F04, F09) | Infisical → ESO, 앱별 시크릿 격리. 같은 봇 안에서도 게시 서버와 작업자의 시크릿 범위를 나눌 수 있어야 한다 | 있음 (§2, §7) |
| 병합 전 리뷰 가능성 (`00` §6, V2-10) | 자동 병합 범위 명시 | 있음 (§5) |
| 서비스 상태·로그·메트릭 조회 (R04~R06) | 관측 API 읽기 전용 접근 | §2, §4 |
| 배포 상태 읽기 (R15) | Argo CD·Kubernetes 읽기 전용 계정 | §2 |
| GitHub webhook 수신 (PR_REVIEW) | 공개 HTTPS 수신 경로, 경로·출처 제한 | §2, §4 |
| 리뷰 전용 App (PR_REVIEW, R11) | 저장소별로 리뷰 전용 App을 추가 설치할 수 있는 구조 | §2, §5 |
| 알림 중계·자동 조사 (R07, V2-04) | Alertmanager → 외부 webhook 수신자 | §2 |
| 격리 작업 실행 (F03, R10, R13) | 운영·게시 자격과 운영 네트워크가 막힌 실행 공간. 모델 자격만 별도 범위로 받고, egress는 허용 목록으로 제한한다 | §2 |
| 봇 변경 PR 작성 (CHANGE_PR, R13) | 봇이 만든 PR은 내용이 digest만 바뀌어도 자동 병합되지 않는다. 자동 병합 조건에 작성 주체·브랜치를 넣고 서버 쪽에서 강제한다. 봇 쓰기 신원은 D-24 | §2, §5 |
| 봇이 죽어도 경보 (F06, OPS-02) | 봇과 독립된 비AI 알림 경로 | §2, §9 시나리오 16 |
| 홈랩 전체 중단 감지 (`04` §2 "운영 복구") | 외부 생존 감시 | §2, §9 시나리오 17 |

각 자리를 어느 구축 티켓이 만들지는 T05가 2026-10-18에 설계 E.3대로 정했다. 자리와 AC, 담당 티켓은 §4.4에 있다.

### 4.3 봇 문서의 결정 대기 자리

봇 문서는 새 플랫폼을 기준으로 한다. 플랫폼 설계 값이 필요한 곳은 결정 ID로 자리만 두었다. 색인은 `01` §11과 `04` §10에 있다. `00`에는 색인이 없고 §1·§3·§4·§5·§6·§8 곳곳에 자리가 있다. 결정이 나면 봇 저장소 `docs/ai-bot/prompts/` 전체에서 그 D-ID를 검색해 모두 고친다(§12, 봇 저장소 PR). 결정 ID 자리는 결정을 정한 티켓이 채우고(T05, T14, T15), 설계 문서의 값 반영과 빠진 자리 점검은 T14가 한다.

- **`00` §3·§6 (C-08 보호):** 문장은 사용자가 제공한 패키지 원문 그대로다. 옛 홈랩을 가리키는 곳에는 "> 참고:" 주석이 있다. `01` §5는 같은 뜻을 새 플랫폼 표현으로 적어서 두 문서의 문구가 다르다.
- **`04` §9:** V1 판정 정의의 유일한 기준이다. `01` §9는 판정 이름과 포인터만 둔다.
- **`02`·`03`:** D-19(확정(사용자 2026-10-18, T14))로 T14에서 정비했다. 옛 홈랩을 전제로 한 문장은 `00`·`01`·`04`와 같은 방식으로 고쳤고, 처리 기록은 각 문서 머리의 "T14에서 처리한 문장" 표(T14 전 "다시 검토할 문장" 표)에 있다. 복사용 프롬프트(`02` §0, `03` §0)도 고쳤다.
- **위치 (D-13):** 봇 문서의 최종 위치는 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/prompts/`다. 파일 이름(`00-start.md`~`04-audit-handoff.md`)은 그대로다. 2026-10-18에 봇 저장소 생성·하드닝 뒤 PR #1(squash 커밋 `0e9dfd4`)로 옮겼고, homelab의 `bot/` 폴더는 같은 날 지웠다(T14). 이 명세와 티켓은 새 위치를 가리킨다(참조 규칙은 §12).

T14 진행: 위 자리에 플랫폼 값을 채웠다. T05의 플랫폼 결정은 확정(사용자 2026-10-18, T05)이다(§5.1). D-13의 나머지(봇 저장소 이름, 산출물 위치, 프롬프트 문서의 최종 위치)와 D-19는 2026-10-18 T14 질문 응답으로 확정했다(§5.1). 같은 응답에서 R14 배정도 정했다: R14는 PR_REVIEW(`01` §5, T17)에서 빼고 CHANGE_PR(`01` §7, T19)에만 남긴다. 시험 CHANGE-01·03은 그대로다. 봇 저장소 둘(`ukyi-app/homelab-bot` public, `ukyi-app/homelab-bot-ops` private)은 2026-10-18에 사람이 만들었다(approvals.md). 문서 이동 PR(#1)도 같은 날 병합했다(위 "위치").

T15 진행: T15 결정(D-14~D-17, D-24)과 R08 보류, V1 범위 조정은 2026-10-18 T15 질문 응답으로 확정했다(§5.1). 봇 저장소 `docs/ai-bot/prompts/`의 그 자리는 봇 저장소 PR로 채운다(사람 승인 뒤 push, §12). 이때 `00` §3·§6 본문(C-08)과 `04` §9 판정 문장은 바꾸지 않고 "> 참고:" 줄만 더하며, 요구 ID·시험 ID·계약 문구는 바꾸지 않는다. R08은 요구를 그대로 두고 연결 방식만 T18에서 다시 판단한다.

### 4.4 플랫폼 문서에 남은 공백

- 구축 단계 프롬프트가 없다. 플랫폼 프롬프트는 설계까지만 다룬다. 그래서 T05가 설계 결과 E를 기준으로 P2 티켓(T06~T13)을 다시 쪼갰다(재분해 T05 2026-10-18). 기준은 설계 E.1(단계마다 선행 조건, 만들 것, 완료 기준, 검증 방법, 되돌리는 방법)과 E.2(단계와 티켓의 대응, P2 의존성)다. T08은 T08a(네트워크·DNS·외부 공개, 설계 E4a)와 T08b(관측·알림·봇 자리, 설계 E4b)로 나눴다. 각 P2 티켓은 시작할 때 그 티켓만 다시 계획한다(§8.5).
- 봇을 위한 자리와 AC: 플랫폼 프롬프트 §2 "봇을 위한 여지"의 자리 중 비AI 알림과 외부 생존 감시는 AC-P11, 병합 조건 공개와 봇 변경 PR의 자동 병합 차단은 AC-P8, 나머지 다섯 자리(webhook 수신 경로, 읽기 전용 접근, 경보 외부 수신자, 격리 작업 공간, 리뷰 전용 App)는 AC-P12가 맡는다.
- 자리별 담당 티켓은 설계 E.3대로 정했다(재분해 T05 2026-10-18).
  - T08a: 공개 HTTPS webhook 수신 경로.
  - T08b: 읽기 전용 접근 셋(Kubernetes·관측·Argo CD), Alertmanager 경보 외부 수신자, 격리 작업 공간, 비AI 알림, 외부 생존 감시. Argo CD 읽기 전용 계정은 잠정 배정의 T07에서 T08b로 옮겼다. 세 계정을 한 단계에서 함께 확인하기 위해서다.
  - T10: 리뷰 전용 App의 저장소별 설치 구조, 병합 조건 공개, 봇 변경 PR의 자동 병합 차단(시험 신원). 실제 봇 쓰기 신원은 T19다(D-24).
  - T13: 모든 자리의 최종 확인.

### 4.5 현실 제약

- **NUC 한 대:** 옛 클러스터와 새 클러스터를 동시에 돌릴 수 없다. 구축 기간에는 홈랩 서비스가 멈춘다. 데이터 폐기 합의(C-02, C-03)로 감수한다. 디스크는 루트 LV 913G와 별도 1.8T(`/mnt/bulk`, 옛 files 데이터)다. 네트워크는 무선(`wlo1`)이다.
- **옛 Argo CD:** main이 바뀌면 옛 클러스터가 새 내용을 따라 리소스를 지울 수 있다. 그래서 `rebuild` 브랜치에서 작업하고, 철거 뒤에 main을 바꾼다. root 앱이 Application과 ApplicationSet을 selfHeal로 소유하므로, Application 단위로 자동 동기화를 끄는 것은 효과가 없다. `legacy` 태그 push, `rebuild` push, rebuild → main PR 생성, 열린 PR 닫기는 옛 클러스터의 리소스를 바꾸지 않는다(2026-10-17 감사, 정적 분석). 저장소 push webhook이 옛 Argo CD에 refresh를 일으킬 수는 있지만, 모든 앱이 main을 따라가므로 변화는 없을 것으로 본다(추측).
- **옛 github Terraform root:** `github_repository.homelab`과 `github_repository.app_template`(D-21의 `homelab-app-template`)에 삭제 방지가 없다. 이 root를 destroy하면 두 저장소가 지워진다. 옛 state에는 평문 자격도 들어 있다.
- **옛 자동화의 범위:** `tf-reconcile`·`iac`는 Cloudflare root만 무인 apply한다. GitHub·Tailscale root는 plan만 돌려 드리프트를 Telegram으로 알린다. 일정은 30분마다였고 실측은 몇 시간 간격이었다. 지금은 Actions가 꺼져 모두 멈춰 있다. Renovate도 homelab Actions에서 org 전체를 돌았으므로 다른 저장소의 Renovate도 함께 멈췄다(다른 저장소에 열린 renovate PR 29개: `page` 10, `trip-mate-api` 10, `homelab-app-template` 5, `aiops-autodeploy-canary` 4. `page`·`trip-mate-api`를 지우면 9개가 남는다. D-18 입력).
- **Tailscale DNS:** Tailscale 문서에 따르면 모든 DNS를 Tailscale이 처리할 때는 등록된 nameserver에 동시에 묻고 가장 빠른 답을 쓴다. 지금(C-05) Tailscale 기기에서는 광고 차단과 `*.home.ukyi.app` 내부 이름이 불안정하고, 철거 기간에는 이를 감수한다. 옛 `infra/tailscale` root를 apply하면 이 임시 폴백(C-05)이 사라진다. D-08은 확정(사용자 2026-10-18)이고 새 구성은 (b′)다(§5.1): Override local DNS 켬, 전역 nameserver는 NUC Tailscale IP(AdGuard Home)와 AdGuard 공용 DNS `94.140.14.14`·`94.140.15.15`(AdGuard Home 기본값과 같은 AdGuard DNS filter), C-05의 Cloudflare 4개는 지운다. 목적은 Tailscale을 켠 기기가 집 안팎 어디서든 차단을 받고, NUC 장애 때도 공용 서버가 차단하며 답하는 것이다. 대가는 다섯이다.
  - AdGuard Home의 사용자 규칙·허용 목록·추가 목록은 AdGuard Home이 먼저 답한 질의에만 적용된다. 가장 빠른 답을 쓰므로 공용 서버가 먼저 답한 질의에는 빠진다.
  - 공용 경로는 평문 UDP다. AdGuard사가 질의를 받는다. 질의를 가로채는 망에서는 그 망이 먼저 답해 차단이 빠지거나 답이 위조될 수 있다. tailscaled는 DNSSEC을 검증하지 않는다.
  - AdGuard Home이 tailnet에서 조용히 빠져도 공용 서버가 답하므로 증상이 없다. 그래서 "tailnet 출처 질의가 1시간 0건이면 경보" 감시가 필요하다(T08b).
  - Override를 켜면 로컬 DNS 전용 이름(회사·호텔 내부 이름)이 Tailscale을 켠 동안 풀리지 않는다.
  - DNS 차단은 같은 도메인에서 나오는 광고(유튜브 등)를 막지 못하고, 브라우저 보안 DNS와 안드로이드 개인 DNS는 이 경로를 우회한다.
- **노드 자신의 DNS:** 공유기의 주 DNS가 NUC의 AdGuard라서, 노드가 DHCP DNS를 쓰면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 생긴다. 옛 host-config는 resolved drop-in(공용 DNS 직접 사용)과 `tailscale set --accept-dns=false`로 이를 막았다. T06은 이 설정(설계 B.4의 H5)을 남기고, T07(설계 E2)이 drop-in을 같은 이름으로 덮어쓴다(D-12, 확정(사용자 2026-10-18, T05)). 대체 없이 지우면 순환이 다시 생긴다.
- **HSTS:** `.app` 최상위 도메인 전체가 브라우저 HSTS preload 목록에 있어 `ukyi.app` 아래 모든 이름은 처음 접속하는 브라우저에서도 HTTPS 전용이다. 그래서 공개 이름은 처음부터 유효한 인증서를 써야 한다. `ukyi.app` zone의 HSTS 헤더(includeSubDomains, 180일)는 이와 별개이고 유지한다(D-11). 새 구조는 내부 UI를 Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`(UI마다 단독 프록시)으로 옮기고 `*.home.ukyi.app` 내부 이름을 두지 않는다(D-08). 그래서 내부 와일드카드 인증서와 cert-manager DNS-01용 Cloudflare 토큰이 필요 없다. 대신 tailnet HTTPS 인증서를 켜면 기기 이름과 tailnet DNS 이름이 공개 CT 로그에 실리므로, 공개해도 되는 기기 이름만 쓴다.
- **GitHub 요금제와 공개 범위:** org는 Free 플랜이고 `homelab`은 public이다. Free에서 브랜치 보호와 ruleset은 public 저장소에서만 동작한다. 그래서 봇 저장소를 private로 만들면 보호 규칙을 걸 수 없고(D-13), `homelab`을 private로 돌리면 AC-P8의 전제가 무너진다. T02 push부터 계획 문서가 공개되고, 사용자가 이를 받아들였다(D-23, 확정). 저장소 공개 정책은 D-29다(확정(사용자 2026-10-18)): 앱 저장소는 public만 허용하고, 봇 코드 저장소 `ukyi-app/homelab-bot`도 public이다(D-13). 앱이 아닌 저장소는 공개하지 않는다. 봇 운영 산출물 저장소 `ukyi-app/homelab-bot-ops`는 private라서 같은 이유로 보호 규칙을 걸 수 없다(D-13).
- **Codex Connector:** ChatGPT Codex Connector App이 org 전체 저장소에 쓰기 권한(contents, workflows, actions, issues, pull_requests)으로 설치돼 있고, PR을 열면 코드·보안 리뷰를 자동으로 단다. `homelab`에서는 main push 허용 목록에 없어서 main에 직접 쓰지는 못한다. 앱 저장소는 main 보호가 없어서 이 App이 main에 직접 쓸 수 있다(2026-10-17 실측). 새 구조의 자동 배포 경로가 앱 저장소 main을 믿으면 이 점이 AC-P8의 간접 자동 병합 경로가 된다. rebuild → main PR(T07)에도 돈다. 처리는 D-26, 봇 PR 리뷰와의 관계는 D-16이다. 결정 5(2026-10-18, §5.1)로 `files`·`homelab-app-template` main에 `CODEOWNERS`와 `app-main` ruleset을 걸었다(2026-10-18 실행). 이 App은 bypass 목록에 없어 두 저장소 main 직접 쓰기는 ruleset이 막는다(규칙 조회로 확인, 실제 push 시험은 하지 않음). `page`·`trip-mate-api`는 삭제한다(D-29). 설치 범위는 2026-10-18 17:45에 사람이 선택 저장소로 줄였다(D-16, §11).
- **봇 규모:** V1만으로 필수 기능 7개, 공통 계약 9개, 요구 18개, 수용 시험 30개다. 일정 위험 1순위다.
- **모델 계정:** NUC에 Codex 홈이 3개(`~/.codex`, `~/.codex-sub`, `~/.codex-work`) 있다. `~/.codex2`와 `~/.codex3`은 각각 `-sub`와 `-work`를 가리키는 심링크다. 옛 AIOps의 ChatGPT 구독 OAuth는 시스템 사용자 `aiops-proxy`의 CLIProxyAPI 저장소에 따로 있다. 봇 문서는 개인 CODEX_HOME(`~/.codex*` 전체) 자동 탐색을 금지하고, 구독 약관을 자동 호출 권한으로 가정하지 말라고 한다 (D-14).
- **NUC에 설치된 도구:** codex-cli 0.163.0, herdr 0.9.5, bun 1.4.3, Terraform 1.16.6, kubectl 1.37.1, k3s v1.36.4+k3s1, tailscale 1.104.1, gh 2.102.0, sops 3.13.1, age 1.3.2, helm v4.3.1. argocd, wrangler, infisical CLI는 없다. OS는 Ubuntu 26.04.1이다.
- **옛 규모 (교훈 대상):** 워크플로 25개(디렉터리 파일 26개, README 포함), bats 시험 파일 313개, AIOps 관련 파일 58개(경로 기준. 내용에서 언급하는 파일은 104개). 전체 파일 929개.
- **옛 AIOps 잔여물:** GitHub `ukyi-app/aiops`(Codex 진단·Draft PR 실행기)와 `ukyi-app/aiops-autodeploy-canary`(옛 homelab 공통 워크플로를 호출), GitHub App `ukyi-homelab-aiops`가 남아 있다. NUC에는 호스트 유닛 4종(`aiops-ingress.service`, `aiops-worker.service`·`.timer`, `homelab-aiops-nft.service`, `var-lib-homelab\x2daiops.mount`)과 nft 규칙이 있다. mount 유닛 이름의 `\x2d`는 systemd 경로 이스케이프라서, 셸에서는 작은따옴표로 감싸거나 `systemctl status /var/lib/homelab-aiops`처럼 경로로 지정한다. 이 mount는 2026-10-17에 active다. 그 밖에 `/opt/homelab-aiops`, `/etc/homelab-aiops`(AIOps App 개인 키), 시스템 사용자 8개 등이 있다. 전체 목록은 T06에 있다. 봇에는 교훈 자료이고, 철거에서는 정리 대상이다 (T06, T15, T22). aiops는 쓰지 않으므로 `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App은 제거(삭제)하고, `aiops-autodeploy-canary`는 공개하지 않고 private로 보관한다(삭제도 가능). 둘 다 확정(사용자 2026-10-18)이고 실행은 T22다(D-13, D-29). 새 봇 저장소는 옛 `ukyi-app/aiops`를 재사용하지 않고 `ukyi-app/homelab-bot`을 새로 만든다(D-13).
- **옛 호스트 유닛의 옛 사본 의존:** `files-data-backup`(매일), `systemd-failed-sweep`(5분), `unit-failure-notify@`가 `~/workspace/homelab/scripts/`의 스크립트를 root로 실행하고, `files-data-backup`은 옛 사본의 kubeconfig도 쓴다. T06 전에 옛 사본을 옮기거나 지우면 이 유닛이 실패한다.
- **옛 데이터 경로:** k3s 표준 제거(`k3s-uninstall.sh`)는 `/var/lib/rancher/k3s`만 지우고 `/var/lib/rancher/k3s-storage`(옛 PV 데이터, AdGuard 라이브 설정 포함)를 남긴다. `/mnt/bulk`와 `/var/backups/files-data`도 남는다. T06은 AdGuard 라이브 설정을 먼저 내보낸 뒤(T08a 입력) 이 경로들을 지운다(D-12).
- **NUC 로컬 전용 자료:** 옛 운영 런북은 사용자 결정(2026-06-11)으로 public 저장소 밖에 두었다(`~/workspace/homelab/docs/runbooks/`, `~/workspace/homelab-infra/`). Terraform 자격 파일(`.env.secrets`, `backend.hcl`, `terraform.tfvars`), SOPS age 키, 원격 없는 다른 프로젝트(`~/workspace/polyrelay` 등)도 이 디스크에만 있다. 옛 사본에는 push하지 않은 로컬 브랜치와 워크트리도 있다. 사용 범위는 D-27이다. OS를 유지하므로(D-12) 이 자료는 디스크에 남는다. 예외는 SOPS age 키로, T06 자격 폐기 완료를 확인한 뒤 지운다(D-20). 셋 다 확정(사용자 2026-10-18, T05)이다.
- **옛 장기 자격:** `legacy`의 `policy/credential-expiry.json`에 무만료 자격 11개가 있다(GitHub PAT, Cloudflare 토큰, R2 키, Tailscale OAuth 등). 이 밖에도 옛 App 키와 Telegram 봇 토큰 등이 있다. 새로 발급해도(D-20) 옛 자격은 따로 폐기해야 한다(T06). 삭제하는 앱의 자격(`trip-mate-api`의 Google OAuth client·OXR app id·`BETTER_AUTH_SECRET`, `page` admin token)도 T06 자격 폐기 표에서 폐기한다.
- **옛 외부 감시·알림 자산:** healthchecks.io 데드맨 스위치(Alertmanager Watchdog → relay → ping)와 Telegram 봇이 있다. 철거하면 healthchecks.io가 down 알림을 보낸다. D-10·D-11은 확정(사용자 2026-10-18, T05)이다: healthchecks.io는 계정을 재사용하고 체크는 새로 만들며, 비AI 알림은 Telegram 새 봇이다. 옛 봇·토큰은 T22까지 그대로 둔다. 옛 체크는 T06에서 일시 정지하고, 새 체크가 초록인 것을 확인한 뒤 T08b에서 지운다.
- **배포 중인 앱:** 옛 클러스터의 앱은 `aiops-autodeploy-canary`와 `files`뿐이다. `page`와 `trip-mate-api`는 이미 철거됐고, 쓰지 않으므로 저장소와 GHCR 패키지를 삭제했다(2026-10-18 결정·실행). 남는 앱 저장소는 `files`와 `homelab-app-template`이고, T22의 재연결 대상은 `files`다.
- **문서 보관:** T02(2026-10-17)로 이 폴더가 원격 `rebuild`에 올라갔다. 이후 변경은 §12대로 커밋한다.

---

## 5. 결정

### 5.1 확정

확정된 D-xx는 다른 문서의 참조가 깨지지 않게 ID를 그대로 두고 이 표로 옮긴다.

| ID | 결정 | 근거 |
|---|---|---|
| C-01 | 이름은 `homelab`. 같은 저장소를 재사용하고 내용을 교체 | 사용자 2026-10-17: "homelab 이란 이름으로 진행하고싶음. 재활용할 수 있으면 재활용해도 됨" |
| C-02 | DB 데이터와 pg·cache 백업 폐기 | 사용자: "db 데이터관련해서는 다날려도 상관없음" |
| C-03 | `homelab-media-prod` 버킷과 files 데이터 폐기 | 사용자: "media 제거해도됨", "files 제거해도됨" |
| C-04 | 공유기 DNS 유지 (주 `.15`, 보조 `1.1.1.1`). 2026-10-20 실측: 이 공유기는 주 DNS 장애 때 보조로 넘어가지 않는다(AC-P6 한계 승인) | 사용자 설정 확인 |
| C-05 | Tailscale 전역 DNS에 Cloudflare 임시 추가 | 사용자 수행, 2026-10-17 |
| C-06 | 옛 저장소 Actions 비활성화 | 사용자 요청으로 수행, 2026-10-17 |
| C-07 | 플랫폼 원칙: k3s + Argo CD, 앱 저장소 분리, Infisical Cloud가 시크릿 원본(전달 계층은 ESO 우선 검토), CNPG, 단일 서버 | 플랫폼 프롬프트 §2·§6·§7 (사용자 작성 원문 기준) |
| D-01 | 전체 순서: 플랫폼을 먼저 짓고, 봇은 새 플랫폼의 첫 실제 앱으로 올린다. 봇 DISCOVERY는 플랫폼 결정(T05) 뒤 구축과 병행 | 사용자 2026-10-17: "예, 플랫폼 먼저로 확정해줘" |
| D-02 | 옛 클러스터 철거 시점: T05 결정 확정 뒤, 부트스트랩(T07) 직전. 설계 기간에는 옛 클러스터와 AdGuard가 계속 돈다 | 사용자 2026-10-17: "예" (추천안 수락) |
| D-03 | 저장소 히스토리: 유지. 옛 코드는 `legacy` 태그로 남기고, `rebuild` 브랜치를 main에서 분기해 옛 파일을 지우는 커밋 뒤에 새 내용을 쌓는다. force push 없음. rebuild → main은 squash로 병합한다(D-25). 옛 main은 새 main의 조상으로 남아 히스토리가 유지되고, rebuild의 중간 커밋은 PR 기록에 남는다 | 사용자 2026-10-17: "예" (추천안 수락). 병합 방식 문구는 D-25(사용자 2026-10-18, T05 질문 응답)에 맞췄다 |
| C-08 | 봇 V1 7기능 필수. V1~V3은 운영 읽기 전용 | 사용자가 제공한 봇 문서 패키지 `00` §3·§6 (`00` §9 S2: 대화에서 합의한 범위) |
| D-23 | 저장소 공개 범위: `homelab`은 public을 유지하고, 계획·설계 문서의 공개를 받아들인다. 복구 자산 목록, 토큰 인벤토리, 로컬 런북 같은 운영 민감 문서는 저장소 밖에 둔다 | 사용자 2026-10-17: "public 유지 (추천)" (추천안 수락) |
| D-04 | Infisical Cloud Free. identity는 5개 한도 중 4개: 사람, `eso-homelab`(운영 ESO), `eso-homelab-dev`(VM 시험 ESO), `gha-homelab-deploy`(배포 App 키, OIDC). `gha-homelab-merge`는 만들지 않는다. 병합 App 키는 원본을 Infisical 프로젝트 `homelab-ci-merge`에 두고 Infisical Secret Sync(GitHub, Scope Repository Environment: `ukyi-app/homelab` / `automerge`)로 사본 1개를 만든다. App Connection은 GitHub App이 아니라 `homelab` 하나로 좁힌 fine-grained PAT(Metadata read, Environments RW, Secrets RW, 만료 없음: 사용자 2026-10-21)다. 그 대가: owner 계정에 묶임, Infisical에 PAT 저장, 새면 회수할 때까지 유효함, org가 fine-grained PAT를 허용해야 함. Auto-Sync 켬, Key Schema 비움, 삭제 켬, sync 1/10. environment `automerge`는 배포 브랜치 정책 main, `prevent_destroy`이고 다시 만들면 Sync를 다시 실행한다. `deploy-merge`는 `on: workflow_run`(ci completed)만 쓰고, merge job에 `environment: {name: automerge, deployment: false}`, `actions/create-github-app-token`에 `secrets.HOMELAB_MERGE_KEY`를 준다. Infisical OIDC 단계는 없다. 보강: ci의 workflow-guard(세부는 T10), D-26 조건 (2)를 "environment secret을 쓰는 워크플로는 `workflow_run`만"으로 넓힘, Terraform guard(D-28)가 environment 브랜치 정책 `[main]`·secret 이름 집합(`[]` 또는 `[HOMELAB_MERGE_KEY]`)·repo secret 0개·org secret 0개를 대조. 회전: `homelab github verify` exit 0 확인 → 새 키 발급 → Infisical 값 교체 → environment secret `updated_at`이 교체 시각 이후인지 확인 → 옛 키 삭제. App 키는 만료가 없고 25개까지 동시에 유효해 `deploy-merge` 성공만으로는 새 키 반영을 증명하지 못한다. sync 실패 알림은 프로젝트 Admin 메일로 온다. 배포 키는 OIDC를 유지한다(앱별 sync, homelab 쪽 PR 생성, VM identity 제거는 검토 후 제외, 이유는 설계 문서 F D-04). 옛 비상안 (1)(VM identity를 시험 때만 만듦)은 영구 여유를 만들지 못해 삭제했다. 더 필요하면 Pro(identity당 월 $20 연간, $23 월간). **D-07 의존:** D-07이 배포 digest PR의 자동 병합을 두기로 확정(사용자 2026-10-18, T05)돼 병합 키와 Secret Sync는 유지된다. 참고: CI가 tailnet에 붙어야 하면 Tailscale의 GitHub Actions OIDC(workload identity federation)로 시크릿 없이 된다 | 사용자 2026-10-18: "추천대로" (추천안 수락) |
| D-05 | 공유 PostgreSQL 인스턴스(CNPG Cluster `pg`) + 앱별 DB·역할(봇 포함). 전용 Cluster는 설계 C.5.2의 조건 넷(독립 PITR이나 빠른 복원, 10GB 초과나 쓰기 많음, 다른 PostgreSQL major나 확장, 다른 보존 기간) 중 하나라도 걸릴 때만 둔다. 앱 하나 복원은 임시 클러스터 PITR + 논리 덤프다(설계 C.5.7). Cluster `pg`는 자동 동기화로 두고, 빈 NUC 복구는 root apply 전 복구 PR → 복구 확인 → 정리 PR로 한다(설계 C.6.4). 수동 sync 대안(Cluster를 자동 동기화가 꺼진 별도 Application으로 두기)은 고르지 않았다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-06 | 영속 Valkey는 AOF `everysec` + 하루 1회 RDB를 R2로 보내고 14일 보존한다. 유실 허용 범위는 프로세스·노드 재시작 때 약 1초, 디스크 유실 때 최대 24시간이다. 영속 Valkey는 필요한 앱만 쓰고, 큐의 유실이 치명적이면 그 데이터는 PostgreSQL에 둔다(설계 F D-06) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-07 | 배포 갱신 App(`ukyi-homelab-deploy`)이 앱 기본 브랜치 빌드에서 만든, 한 앱의 `image.yaml` digest·revision만 바뀐 PR만 자동 병합하고 서버 쪽에서 강제한다. 강제 장치는 설계 C.4.7의 조건 9개, ruleset A~D, 앱 저장소·`homelab-app-template`의 `app-main`, main 코드의 `workflow_run` 병합 워크플로(`deploy-merge`), App 2개(갱신·병합)와 키별 Infisical 프로젝트다. 자동 병합은 그 앱의 `app-main`이 active일 때만이다(조건 9). GitHub auto-merge 허용(`allow_auto_merge`)은 끈다. 나머지 PR은 사람이 검토 후 병합한다. 그래서 D-04의 병합 키와 Secret Sync는 유지된다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-08 | 내부 UI 이름은 Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`(UI마다 단독 프록시). `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01 Cloudflare 토큰, traefik-ts는 두지 않는다. Tailscale DNS는 (b′): Override local DNS 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS, AdGuard Home 기본값과 같은 AdGuard DNS filter), C-05 임시 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬, `use_with_exit_node` 기본 끔. 목적과 대가 다섯은 §4.5 "Tailscale DNS". 설정은 Terraform `tailscale_dns_configuration`(provider v0.29.2. 문서상 정식이나 고정 버전의 Read가 `Alpha Resource` 경고를 낸다. T08a에서 import·적용·precondition 동작 확인, U34)으로 관리한다: `data.tailscale_devices`로 hostname이 일치하는 기기를 받아 precondition(정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`)을 걸고, IPv4는 `100.` 대역으로 골라낸다. `tailscale_dns_nameservers`와 함께 쓰지 않는다. 이 자원은 DNS 설정 전체를 소유하므로 첫 apply 전에 콘솔 값을 그대로 옮긴 HCL로 새 state에 import하고 plan 무변경을 확인한 뒤 바꾼다. NUC가 없을 때 ACL apply까지 막히지 않게 DNS는 별도 root `infra/tailscale-dns`에 두고 `prevent_destroy`를 건다(count 없음. 조건부는 NUC가 없는 동안 DNS 설정 전체 삭제를 계획한다). Override를 켠 상태에서 AdGuard가 죽어도 공용 서버가 답하므로 Terraform 실행 기기의 DNS 문제는 작다. NUC는 `tag:nuc`로 태그하므로(D-11 (c), 2026-10-20) `tag:nuc:53` ACL 규칙이 필요하다. AdGuard 노출은 servicelb이고, svclb 출처 MASQUERADE로 ratelimit 버킷을 함께 쓰는지 T08a(설계 E4a)에서 확인한다(필요하면 `ratelimit_whitelist`나 hostNetwork. hostNetwork는 노드 네임스페이스 공격면이 는다). 2026-10-21 확인: 함께 쓴다(LAN `10.42.0.1`, tailnet svclb 파드 IP, 같은 /24). ratelimit을 끈다(사용자 2026-10-21 "1번으로 진행하자", 설계 U32). 시나리오 14에 셀룰러 Tailscale 기기 확인(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상)과 사용자 규칙 적용률 측정(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩)을 더한다. 다른 안 (a) AdGuard 단독, (c) NextDNS, (a+) 자동 전환은 검토 후 제외(설계 문서 F D-08) | 사용자 2026-10-18: "b" |
| D-09 | 관측 스택은 옛 계열 최소 구성이다: VictoriaMetrics single, vmalert, Alertmanager, Grafana, VictoriaLogs single + vector, node-exporter, kube-state-metrics. vmagent와 보조 수집기 4개는 두지 않는다. 핵심 룰 15개 안팎을 단위 시험과 함께 둔다(설계 C.3.7) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-10 | 비AI 알림은 homelab 알림용 Telegram 새 봇(설계 E3에서 생성)이고, 외부 생존 감시는 healthchecks.io다(계정 재사용, 체크 새로). 옛 Telegram 봇·토큰은 그것을 쓰는 `mac-uptime-guard`를 처리하는 T22까지 그대로 둔다. 옛 healthchecks 체크는 새 체크가 초록인 것을 확인한 뒤 지운다(설계 E4b). 옛 봇 토큰을 재발급하는 대안은 고르지 않았다. 그래서 E3(T09)이 옛 봇 토큰 행을 닫는 분기는 쓰이지 않는다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락. 옛 봇 토큰 재발급 대안은 고르지 않음) |
| D-11 | 설계 F D-11 표대로 한다. Cloudflare zone `ukyi.app`, Tailscale tailnet, R2 state 버킷 `homelab-tfstate`만 이어 쓰고, 나머지 옛 외부 자원은 표대로 지우거나 새로 정의한다. 새 root의 state 키 접두는 `v2/`다. zone 설정 9개(HSTS includeSubDomains 180일 포함)는 값을 유지해 새 Terraform으로 가져온다. Tailscale ACL은 (c)다: NUC를 `tag:nuc`로 태그하고, 사람 기기 → NUC는 SSH·kubectl은 운영자(`autogroup:owner`·`autogroup:admin`. Owner는 admin 선택자에 들지 않는다)만, AdGuard DNS는 member만 열고, NUC → 사람 기기 규칙은 두지 않는다. ssh는 `accept`(`autogroup:nonroot` + `root`)이고 src는 운영자다. 2026-10-18~2026-10-20에는 (a)(태그 없는 사용자 기기, self 규칙)였다. 적용은 T08a(규칙 먼저, 태그 나중). 2026-10-21 적용·확인(T08a 결과). NUC는 Tailscale SSH를 켜지 않는다: 원격 SSH는 tailnet 주소의 sshd(키 인증, root 로그인 금지)라 ssh 규칙은 쓰이지 않는다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락). ACL (c) 변경: 사용자 2026-10-20 "없어 c가 나을거같네"(U28에서 파드가 NUC 주소로 운영자 기기에 닿은 뒤). Tailscale SSH 끔 유지: 사용자 2026-10-21 "1번으로 해" |
| D-12 | OS를 유지하고 k3s를 제거하며 호스트를 정리한다(설계 B.4의 H1·H2·H3·H7·H8·H9). H8은 옛 데이터 경로(`/var/lib/rancher/k3s-storage`, `/mnt/bulk`, `/var/backups/files-data`)와 AIOps loop 이미지이고, AdGuard 라이브 설정을 먼저 내보낸다. `/mnt/bulk`는 비우고 fstab 항목을 지운다. 노드 DNS drop-in(H5)과 sshd·journald·tmpfiles drop-in(H4)은 남기고 E2(T07)가 같은 이름으로 덮어쓴다. 빈 NUC 재구축 검증은 VM에서 하고, VM은 설계 E8의 격리 조건 여섯을 지킨다. VM 호스트는 tailnet에 넣지 않는다. H7은 고양이 MOTD(홈랩과 별개인 로컬 설치)를 남기고 k3s 상태 표시와 `motd-refresh`만 지운다(사용자 2026-10-19, T06 실측 뒤 결정) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-13 | 봇 코드 저장소는 `ukyi-app/homelab-bot`(public)이다. 새로 만들고 옛 `ukyi-app/aiops`는 재사용하지 않는다. 앱 이름도 `homelab-bot`이라 namespace `app-homelab-bot`, Infisical `/apps/homelab-bot/`(게시 서버)와 `/apps/homelab-bot/worker`(작업자), 이미지 이름이 이를 따른다. 배포 설정은 homelab(`apps/homelab-bot/`, `data/homelab-bot/`)이다. 운영 산출물(evidence, handoffs, runtime-policies 실제 값, DISCOVERY의 내부 경로, 허용 목록 실제 값)은 봇 저장소에 두지 않는다. 산출물 위치는 셋이다: (1) 공개해도 되는 봇 산출물(`PROJECT_STATUS.md`, `DECISIONS.md`, `VERIFICATION.md` 요약 등 내부 정보 없는 것)은 봇 저장소 `docs/ai-bot/`. (2) 운영 산출물 중 개발 산출물(evidence, handoffs, DISCOVERY의 내부 경로)은 private 저장소 `ukyi-app/homelab-bot-ops`. (3) 봇이 실행 중 읽는 값(runtime-policies 실제 값, 허용 목록 실제 값)은 Infisical `/apps/homelab-bot/`에 두고 봇 저장소에는 키 이름만 둔다. 봇 프롬프트 문서(`00`~`04`)의 최종 위치는 봇 저장소 `docs/ai-bot/prompts/`이고 파일 이름은 그대로다. 2026-10-18에 PR로 옮겼다(§4.3). 옛 `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App은 제거(삭제)한다(실행 T22. `mac-uptime-guard` 제거도 같은 T22에서 한다, D-29) | 가시성·운영 산출물 공개 기준·옛 aiops: 사용자 2026-10-18: "aiops는 사용안할거긴해. 참고해. 제거예정.", 공개 정책은 "추천대로". 나머지: 사용자 2026-10-18, T14 질문 응답. 저장소 이름과 산출물 위치는 권장안 수락. 프롬프트 문서 위치는 권장안(지금 위치 유지)이 아니라 "봇 저장소로 옮김"을 골랐다 |
| D-14 | 봇 모델 계정과 인증은 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME이다. 함께 지킬 조건은 다섯이다. (1) 개인 CODEX_HOME(`~/.codex*`)을 쓰거나 복사하지 않는다. (2) 한도 도달·인증 만료 때 다른 계정이나 다른 인증으로 자동 전환하지 않고 waiting으로 둔다. (3) 작업은 직렬 1개(동시성 1)다. (4) Codex가 갱신한 인증 파일을 되쓰도록 작업자 전용 영속 쓰기 공간을 둔다. 설계 C.8은 작업자 자격을 Infisical `/apps/homelab-bot/worker`에서 ESO로만 받으므로 이 공간은 설계 C.8 변경이고, T08b·T16b가 반영한다. (5) 옛 AIOps의 구독 OAuth 프록시와 다계정 순회는 재사용하지 않는다. 남는 위험(공식 문서의 public 저장소 문구, 되쓰기, 직렬 1개, 한도 예측)은 §10 7번이다 차단 조건(확정(사용자 2026-10-18, PR #3 리뷰)): OpenAI가 이 사용을 허용한다고 확인하거나 API 키 같은 공식 지원 인증으로 바꾸기 전에는 공개 저장소 PR 내용이나 코드로 구독 모델을 부르지 않는다. T17(평가셋·실연동·시범 P-2)과 T18 작업이 여기에 걸리고, 모델을 부르지 않는 로컬·mock 구현은 T16a 뒤 착수할 수 있다. T19는 T17 뒤라 함께 기다린다. 인증 전환은 D-14 변경이라 사용자 결정이 따로 필요하다(§10 7번). | 사용자 2026-10-18, T15 질문 응답. 권장안(OpenAI API 전용 프로젝트 + 서비스 계정 키)이 아니라 봇 전용 ChatGPT 구독 계정을 골랐다 |
| D-15 | 봇은 NUC k3s 클러스터 안에서 돈다. 게시 서버는 ns `app-homelab-bot`, 작업자는 ns `sandbox`의 상주 파드이고 동시성 1이다(D-14). 봇 자리 값은 앱 라벨 `homelab-bot`, 게시 서버 앱 포트 8080, 작업자 포트 8080, 경보 수신 포트 8081이다. 작업자의 코드 읽기는 `codeload.github.com` 압축본만이다. 작업자 egress에서 `github.com`·`api.github.com`·gist를 빼고, 작업자에는 GitHub 자격이 없다. 받은 코드는 작업자가 `git init`으로 한 번 커밋해 `codex exec`의 Git 저장소 요구를 맞추고, diff는 base·head 압축본으로 만든다. push와 PR 생성은 게시 서버가 D-24 App으로 한다. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft로 물러난다. 격리 작업 공간의 기본 방식(설계 C.8 기본값, T05)은 그대로다 | 사용자 2026-10-18, T15 질문 응답. 코드 읽기 축소는 에이전트 설명(작업자에 D-14 구독 인증 파일이 있어 GitHub 호스트를 허용하면 작업 입력에 심긴 남의 토큰으로 gist·push를 만들어 유출할 수 있다)을 듣고 골랐다("좋아 그렇게해"). 나머지는 권장안 수락 |
| D-16 | PR 리뷰는 기본안이다: 전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버(`01` §5). 봇이 리뷰하는 저장소는 저장소별 Codex 설정에서 Codex 자동 리뷰를 끈다(사람 작업. 수동 `@codex review`는 남긴다). Codex Connector 설치 범위는 선택 저장소로 줄이고 private 운영 저장소 `homelab-bot-ops`는 뺀다(사람 작업, D-26의 설치 범위 축소). 축소는 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 사람이 하기로 했고, 2026-10-18 17:45에 완료했다(T15, §11, [approvals.md](approvals.md)). `repository_selection` = `selected`는 API로 확인했다. 남긴 저장소는 사용자 보고로 public 저장소(`homelab`, `homelab-app-template`, `files`, `homelab-bot`)이고, `homelab-bot-ops`와 private 저장소(제거 예정 `aiops`·`mac-uptime-guard`, 보관 `aiops-autodeploy-canary`)는 뺐다. 저장소 목록은 `read:user` 권한이 없어 API로 확인하지 못했다. T17은 축소가 됐는지 확인만 한다. **하위 결정(작성자 확인의 App 예외, 새 결정 ID 없음):** 모델 호출 전 작성자 확인(OWNER·MEMBER·COLLABORATOR, 설계 C.8)에 허용 봇 작성자 목록을 더한다. `pull_request.user.type`이 `Bot`이고 숫자 `user.id`가 목록에 있으면 통과한다. 초기 목록은 호스팅형 Renovate 봇과 D-24 App의 봇 사용자(생성 뒤)다. 배포 갱신 App(`ukyi-homelab-deploy`), Codex Connector, 옛 writer는 넣지 않는다. fork PR은 제외한다. 댓글 트리거는 `comment.author_association`을 보고 Bot 댓글은 무시한다. `CONTRIBUTOR`는 허용하지 않는다. 실제 ID는 Infisical runtime policy(키 이름 예: `review.allowed_bot_author_ids`)에만 둔다. 허용 작성자의 PR 본문도 비신뢰 자료로 다룬다 | 사용자 2026-10-18, T15 질문 응답 (권장안 수락). Connector 축소 시점과 남길 저장소 후보: 사용자 2026-10-18(T15 마무리). 축소 실행: 사람 2026-10-18 17:45(approvals.md). 하위 결정의 실측 근거: App이 연 PR의 `author_association`은 `NONE`이나 `CONTRIBUTOR`였다(T15 GitHub 조사, `gh api` GET) |
| D-17 | 봇 전용 개인 Discord 서버를 새로 만든다. 함께 정한 기본값: `MESSAGE_CONTENT` 특권 intent 켬. 허용 채널에서 멘션이나 `/` 명령으로 공개 스레드를 시작하고, 스레드 안은 멘션 없이 처리한다. 허용 사용자는 owner 1명이다. 채널은 2개(대화, 알림·리뷰·브리핑)다. `auto_archive_duration`은 1440분이다. 관리자·MANAGE_THREADS·MENTION_EVERYONE 권한은 주지 않고, 권한은 허용 채널 overwrite로 준다. Public Bot 끔, 서버 설치만, Interactions Endpoint URL 비움(Gateway로 받음). 모든 봇 메시지는 `allowed_mentions`의 parse를 빈 목록으로 둔다. 실제 서버·채널·사용자 ID는 Infisical `/apps/homelab-bot/`에만 둔다. DM 허용 여부와 브리핑 시각은 T16a에서 정했다(확정(사용자 2026-10-20): DM 끔, 브리핑 매일 08:50 Asia/Seoul) | 사용자 2026-10-18, T15 질문 응답 (권장안 수락) |
| D-18 | 호스팅형 Renovate App을 homelab과 앱 저장소에 저장소별로 설치하고 homelab Actions와 분리한다. 자동 병합은 모두 끈다. Renovate PR은 자동 병합 조건 밖이라 사람이 병합하고, 봇 V1 기능 7의 리뷰 대상이 된다(설계 F D-18) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-19 | `02`·`03`도 T14 정비에 넣는다. 두 문서 머리의 "다시 검토할 문장" 표에 모인 옛 홈랩 전제 문장을 `00`·`01`·`04`와 같은 방식으로 정비하고, 복사용 프롬프트(`02` §0, `03` §0)도 고친다 | 사용자 2026-10-18, T14 질문 응답. 권장안(넣지 않음)이 아니라 "넣음"을 골랐다 |
| D-20 | 시크릿 값은 모두 새로 발급해 Infisical에 등록하고 옛 값은 쓰지 않는다. 옛 자격은 E1(T06)에서 폐기한다. 예외는 둘이다: 옛 Telegram 봇 토큰은 `보류(D-10, T22)`, 옛 healthchecks ping URL은 `보류(D-10, T08b)`다. SOPS age 개인 키는 T06 자격 폐기 완료를 확인한 뒤 지운다. NUC 노드 키(`ts-node-key-nuc`)는 자격이 아니라 기기 등록이라 D-12대로 유지한다(T06 실측 2026-10-18). 새 구조에 대응 자격이 없는 옛 자격(cert-manager DNS-01용 Cloudflare 토큰은 D-08, GHCR pull PAT는 D-29)은 새로 발급하지 않는다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-21 | `homelab-app-template` 저장소와 이름을 재사용하고 내용을 교체한다(설계 F D-21 목록). 새 내용은 Dockerfile, `/healthz`, `CODEOWNERS`, 공통 워크플로를 태그로 호출하는 짧은 `build.yaml`, 로컬 compose, `infisical run` 개발 안내, 마이그레이션 예시, Renovate 설정이다. 옛 SealedSecrets 도구·인증서 사본, `.app-config.yml`, main 스키마 받기 CI는 지운다 | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-22 | 앱 DB 마이그레이션은 Argo CD Sync 단계 hook Job(`BeforeHookCreation`, ExternalSecret 다음 wave) + `pg-rw` 직결로 한다. 앱은 시작 때 스키마 버전 확인만 한다. expand/contract는 필수다. 이미 self-migration으로 짠 앱은 replicas 1에서 선택으로 허용한다(설계 C.5.4) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-24 | 봇 변경 PR(CHANGE_PR)의 `bot/` 브랜치 push와 PR 생성 신원은 봇 전용 쓰기 GitHub App이다. 리뷰 App·배포 App과 분리한다. 권한은 Contents write + Pull requests write + Metadata read이고, Workflows·Actions·Administration·Issues는 없다. webhook은 끄고, 선택 저장소에만 설치하며, 작업마다 저장소 하나로 좁힌 1시간 토큰을 쓴다. 병합 API·`/merges`·`repository_dispatch`·update-branch·GraphQL 병합은 Contents write로 열려 권한으로 막지 못하므로 게시 서버의 API 허용 목록이 막는다. 봇은 `.github/workflows` 변경 PR을 만들 수 없다(받아들인 범위 축소). 이 신원의 PR은 자동 병합 조건(D-07)에 걸리지 않는다(AC-P8). 토큰 분리, ruleset E 여부, App 이름과 설치 저장소, 허용 파일 경로(설정 키 `github.change_writer_allow_paths`)는 미정이고 T19에서 정한다 | 사용자 2026-10-18, T15 질문 응답 (권장안 수락) |
| D-25 | rebuild → main은 squash로 병합한다. 옛 main은 새 main의 조상으로 남아 D-03의 히스토리 유지가 지켜지고, rebuild의 중간 커밋은 PR 기록에 남는다. D-03 문구를 이에 맞췄다. 이 PR은 E1의 임시 ruleset 아래에서 owner가 검토한 뒤 관리자 bypass로 병합한다(설계 F D-25) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-26 | ChatGPT Codex Connector App을 유지하고 설계 F D-26의 조건 다섯을 건다. (1) homelab과 앱 저장소의 어떤 ruleset bypass에도 넣지 않는다. (2) 시크릿을 쓰는 `workflow_dispatch` 워크플로를 두지 않고, environment secret을 쓰는 워크플로는 트리거를 `workflow_run`만 둔다(D-04 보강). (3) 배포 키는 앱 main push의 태그 고정 `app-build` OIDC claim으로만 꺼내고, 병합 키는 environment `automerge`의 secret이라 `deploy-merge`의 merge job만 쓴다. (4) 앱 저장소는 public만 두고(D-29) 그 main과 `homelab-app-template` main에 `app-main`을 건다. 자동 배포는 `app-main`이 active인 앱에서만 일어난다. (5) homelab과 앱 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`, 이후 새 앱)에 Codex 클라우드 작업 환경(environment)을 두지 않는다. 리뷰(`@codex review`, 자동 리뷰)와 로컬 Codex CLI는 환경 없이 쓰고, 환경을 만들게 되면 그 전에 U37을 다시 시험한다(사용자 2026-10-22 "환경 안 둘게", U37 결과). rebuild → main PR의 자동 리뷰는 받아들인다(Draft로 열면 피할 수 있는지는 미검증). 설치 범위 축소는 D-16에서 정했다(확정(사용자 2026-10-18, T15)): 선택 저장소로 줄이고 `homelab-bot-ops`는 뺀다. 사람 작업이고 `homelab-bot-ops` 첫 push 전에 하기로 했으며, 2026-10-18 17:45에 완료했다(§11, approvals.md) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락). (5)는 사용자 2026-10-22 결정(T10 U37, approvals.md 2026-10-22 11:11 행) |
| D-27 | NUC 로컬 전용 자료(옛 런북, `~/workspace/homelab-infra/`)는 T06 목록 작성에만 읽기 전용으로 쓰고, 값과 절차 원문은 저장소 문서에 옮기지 않는다. T04는 읽지 않았다(2026-06-11 로컬 전용 결정 존중. 로컬 자료 없이 판정하지 못한 곳은 설계 B.9) | 사용자 2026-10-18, T05 질문 응답 (설계 권장안 수락) |
| D-28 | GitHub 보호 설정은 Terraform으로 관리한다(개선안 T1). root `infra/github`. 리소스는 `github_repository_ruleset`, `github_repository_environment`(+ deployment policy), `github_actions_repository_permissions`, `github_workflow_repository_permissions`만 쓴다. `github_repository`와 시크릿 리소스는 두지 않는다. 저장소 설정(`allow_auto_merge=false`, squash만, 병합 뒤 삭제 등)은 guard로 확인만 하고 값은 `gh api`로 맞춘다. fork PR 승인 정책은 provider가 지원하지 않아 `gh api` PUT + guard. 실행은 owner 로컬만이고 래퍼(T10의 `tools/tf-github.sh`, T12부터 `homelab github plan·apply·verify`)로 한다. guard는 `check` 블록이 아니라 `github_rest_api` 데이터 소스 postcondition(실패 시 plan 오류)이다. App ID는 숫자 리터럴로 쓴다(private App의 ID는 익명 조회가 안 되는 값이라 공개 HCL에 처음 노출된다. 자격은 아니다). provider 6.13.0 정확 핀(legacy client). state는 R2 `homelab-tfstate`의 `v2/github/terraform.tfstate`, `use_lockfile = true`. 잠금(U02)은 R2 PutObject의 If-None-Match 원자성과 S3 backend lockfile 구현으로 문서·소스상 확인됐고, 동시 실행 시험 1회만 T08a(설계 E4a)에 남았다. R2는 versioning이 없어 래퍼가 백업한다. CI는 fmt -check, init -backend=false, validate, `terraform test`만 하고 plan은 하지 않는다. T06(설계 E1)의 `main-interim`과 옛 브랜치 보호 DELETE, T07(설계 E2)의 `ci` ruleset은 `gh api`로 하고 T10(설계 E5)에서 import한다(`ci` → `main-checks` 제자리 이름 변경). 무인 부분 감시(기본 `GITHUB_TOKEN`으로 ruleset 목록·rules·`updated_at` 비교)는 선택지로만 둔다. JSON + `gh api` 원안과 저장소까지 관리하는 T2는 검토 후 제외(T2는 Free에서 fork가 하나라도 생기면 삭제 복원이 안 돼 방어가 얇다). 래퍼·guard 세부는 T10 | 사용자 2026-10-18: "추천대로" (추천안 수락) |
| D-29 | 앱 저장소는 public만 허용한다. 설계의 private 앱 경로를 모두 지운다: `homelab app new --private` 없음, `homelab app add`는 private 저장소와 익명 GHCR pull이 안 되는 패키지를 거부, deploy-pr의 visibility 분기 없이 attestation 항상, GHCR pull 자격(ghcr-pull classic PAT, imagePullSecrets, ExternalSecret) 없음. 자동 병합 조건 9(public + `app-main` active + `CODEOWNERS` 유효, 설계 C.4.7)는 fail-safe로 유지한다. GHCR 패키지: `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는지 문서끼리 어긋나므로, T10에서 org Package Creation의 Public 허용을 확인한 뒤 `homelab-probe` 첫 push로 시험한다. 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다(비가역. public 패키지는 다시 private이 안 된다). public 앱 저장소 기본 설정: org와 저장소의 fork PR 승인 `all_external_contributors`, secret scanning·push protection 켬, private vulnerability reporting 켬, 로그 보존 단축 검토. interaction limits `collaborators_only`(6개월마다 갱신, 다음 만료 2027-04-22)와 PR 생성 Collaborators only는 Codex 외부 호출 시험(U38) 대신 먼저 건다(사용자 2026-10-22 "대책 먼저 걸자", approvals.md 2026-10-22 11:25 행). org limit은 새 저장소에도 걸리고, PR 생성 정책은 저장소마다라 `homelab app new`가 켠다. 만료 알림 방식은 정하지 않았다. 배포 이미지 빌드(push job)는 캐시 없이 한다. 봇은 모델 호출 전에 `author_association`을 확인한다. D-23 금지 항목(tailnet 이름, Tailscale IP 등)을 앱 저장소 코드·로그·이미지까지 넓히고 템플릿 CI에 금지 패턴 검사를 둔다. 비앱 저장소: `aiops`와 `mac-uptime-guard`는 쓰지 않으며 제거(삭제)한다. `aiops-autodeploy-canary`는 공개하지 않고 private로 보관한다(삭제도 가능). 실행은 T22다. `mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤(D-10) 저장소를 지운다. 앱이 아닌 저장소를 공개하는 일은 없다. `page`와 `trip-mate-api`는 쓰지 않으므로 저장소와 GHCR 패키지를 삭제한다(2026-10-18 실행). 남는 앱 저장소는 `files`와 `homelab-app-template`이다. 두 앱의 옛 자격은 T06 자격 폐기 표에서 폐기한다 | 사용자 2026-10-18: "추천대로" (추천안 수락), "page, trip-mate-api는 제거예정이야. 제거해버리자." `mac-uptime-guard` 제거: 사용자 2026-10-18 17:46 "aiops와 mac-uptime-guard는 제거예정"(그 전에는 private 보관이었다, approvals.md). interaction limit·PR 생성 제한을 시험 전에 거는 것: 사용자 2026-10-22 "대책 먼저 걸자"(T10 U38) |
| D-30 | 내부 UI 짧은 주소: D-08의 `<서비스>.<tailnet>.ts.net`은 그대로 두고 tailnet 전용 리다이렉터 `go`를 둔다. `go/<이름>/<경로>`를 `https://<이름>.<tailnet>.ts.net/<경로>`로 302 보낸다(쿼리 유지. 대상 호스트는 늘 한 라벨 + tailnet 도메인이라 열린 리다이렉트가 아니다). 노출은 operator LoadBalancer Service(`loadBalancerClass: tailscale`, hostname `go`, 태그 `tag:k8s-go`)의 HTTP 80 하나이고 443은 열지 않는다. VM은 `vm-go`가 `vm-<이름>`으로 보낸다. 인증서·DNS 쓰기 자격·PVC가 없고 CT 로그에 새 이름이 실리지 않는다. 이름 풀이는 MagicDNS 짧은 이름이라 AdGuard·공개 DNS와 무관하다. tailnet 도메인 값은 저장소에 두지 않고 실행 때 넣는다(D-23). ACL은 `autogroup:member → tag:k8s-go:80`만 더한다. `go`가 멈춰도 전체 주소는 그대로 열린다. `go`와 `vm-go`는 모든 클러스터에서 앱 내부 이름(`internal.name`)으로 쓸 수 없게 예약한다(T10). 기기 즐겨찾기·홈 화면 등록은 두지 않는다. 입력은 기기·브라우저마다 처음 한 번 `http://go/<이름>`으로 연 뒤 스킴 없는 `go/<이름>`을 쓴다(처음 보는 단일 라벨은 모든 브라우저가 검색어로 보낸다. 사용자 2026-10-21). `*.lab.ukyi.app`(공개 A 레코드 + `_acme-challenge` 위임 + 내부 Traefik), 즐겨찾기만, 사설 CA, Cloudflare Access, WARP private hostname, tailnet fun name, golink는 검토 후 제외(설계 문서 F D-30). 실행은 T08c | 사용자 2026-10-20: 세 에이전트(Claude·Codex·DeepSeek)의 독립 검토를 비교한 뒤 "2번으로 하고싶고 2번하면 즐겨찾기는 안해도 될거같아", 이름은 "1번"(`go`). 입력 방식은 사용자 2026-10-21 "1번으로 되긴하네 그냥 이렇게 하지뭐"(처음 한 번 `http://go/...`) |

**결정 5 (지금 열린 구멍 막기, 사용자 2026-10-18 "추천대로", 2026-10-18 실행):** 설계의 `app-main`을 T10보다 먼저 건다. `files`와 `homelab-app-template`에 `.github/CODEOWNERS`(`* @ukkiee`)와 `app-main` ruleset(PR 필수, 승인 1, code owner 리뷰, 새 push 때 승인 무효화, force push·삭제 금지, bypass는 저장소 관리자 역할 `pull_request` 모드)을 걸고, secret scanning·push protection을 켜고, 저장소와 org의 fork PR 승인을 `all_external_contributors`로 올린다. 자동 권한 검사가 에이전트의 org·저장소 설정 변경을 막아 사람이 스크립트로 실행했다(§11, [approvals.md](approvals.md)). U08 셋째 조건(관리자 역할 bypass가 org owner에게 적용되는지, 설계 문서 부록 1)의 첫 실측인 `current_user_can_bypass`는 두 저장소 모두 `pull_requests_only`였다. 이 값은 API가 알려 주는 우회 가능 여부이고, 실제 bypass 병합은 E1에서 시험한다. 결정 5 목록에는 private vulnerability reporting이 없었다. 설계 C.3.9는 `files`·템플릿에서 결정 5 하드닝이 이것을 먼저 켰다고 적지만, 2026-10-18 실측(`gh api` GET `repos/ukyi-app/<저장소>/private-vulnerability-reporting`)은 `files`·`homelab-app-template` 모두 `enabled:false`이고 `homelab-bot`만 `true`다. D-29 기본 설정(켬)에 맞추는 일은 §11에 있다.

**T15 결정과 함께 정한 것 (확정(사용자 2026-10-18, T15)):** 2026-10-18 T15 질문 응답으로 정했다(권장안 수락). R08 보류는 T15 질문에서 "T18에서 다시 판단"이 추천으로 제시됐고 사용자가 그것을 골랐다. V1 범위 안 3도 에이전트 추천이었다(봇 저장소 `V1_PLAN.md` §4 초안).

- **R08 보류:** R08(V1 기능 3, 사용자가 명시적으로 연결한 기존 Codex 작업)은 요구를 그대로 둔다. 연결 방식은 T18(CODEX_BRIDGE)에서 다시 판단하고, 그때까지 보류한다. herdr를 거치는 연결은 Codex 상태를 화면으로 추정하고 소켓에 인증이 없어 쓰지 않는다는 T15 조사 결과는 근거로 남긴다. 사람의 개인 세션을 `capability=false`로 정한 것은 아니다.
- **V1 범위 조정 (안 3: 시범 운영 + 로컬 선행):** (1) STAGE별 제한 시범 운영. 예를 들어 T16b 뒤 허용 채널에서 읽기 조회만, T17 뒤 시험 저장소에서 PR 리뷰만 실사용한다. 단계마다 사람이 승인하고 [approvals.md](approvals.md)에 기록한다. (2) T16을 T16a(FOUNDATION 로컬·mock, T15 뒤 바로 착수)와 T16b(실연동·첫 배포, T13 뒤)로 나눈다. 기능 수는 줄이지 않는다(C-08 그대로). §8 표·그래프와 티켓 반영은 T15 마무리에서 한다(§12).

**설계 기본값 (확정(사용자 2026-10-18, T05)):** 설계 문서 F의 "추가 확인" 기본값을 T05 질문 응답으로 확정했다. Kubernetes 시크릿 전달 계층은 ESO v2.13.x다(설계 F "Kubernetes 시크릿 전달 계층"). 공개 DNS는 와일드카드 레코드 하나이고, 원격 관리 터널에서 안 되면 host별 Terraform 레코드를 둔다. Argo CD 공개 webhook은 두지 않고 60초 폴링(`timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 0`)으로 한다. 이 항목은 사용자가 설명을 듣고 직접 골랐다("두지않고 폴링으로 하자"). 백업 보존은 PostgreSQL·Valkey 14일이고 R2 버킷은 `homelab-backups` 하나다. 격리 작업 공간 기본 방식은 설계 C.8 기본값이고, 그 라벨·포트와 코드 읽기 호스트 축소는 D-15(확정(사용자 2026-10-18, T15))가 정했다. 작업자 전용 영속 쓰기 공간은 D-14가 더한 설계 C.8 변경이다. CI의 App 키 전달 방식은 이미 D-04로 확정돼 있다. AC-P6 판정 기준은 설계 C.3.6 제안대로다: AdGuard를 멈춘 5분 동안 LAN 기기에서 10초 간격으로 30회 질의해 실패 0회, 질의마다 응답 5초 이하. 못 미치면 시나리오 14를 실패로 기록하고 사용자가 한계로 승인하거나 F D-08을 다시 본다. 이 기준은 T05 질문에서 빠졌다가 같은 날 따로 물어 확정했다.

### 5.2 추천, 확인 대기 (지금 정할 것)

없음. D-01~D-03은 2026-10-17에 확정돼 §5.1로 옮겼고, D-23도 같은 날 확정돼 §5.1로 옮겼다. D-04·D-08, 새 결정 D-28·D-29, D-13의 일부(봇 저장소 가시성, 옛 aiops 처리)는 2026-10-18에 확정돼 §5.1로 옮겼다. T05 결정 게이트의 D-05~D-07, D-09~D-12, D-18, D-20~D-22, D-25~D-27과 설계 "추가 확인" 기본값도 2026-10-18 12:32에 사용자가 T05 질문에 답해 확정했고(전부 설계 권장안) §5.1로 옮겼다. T14 결정 게이트의 D-13 나머지와 D-19도 2026-10-18 13:51에 사용자가 T14 질문에 답해 확정했고 §5.1로 옮겼다. T15 결정 게이트의 D-14~D-17, D-24와 R08 보류, V1 범위 조정도 2026-10-18 16:29에 사용자가 T15 질문에 답해 확정했고 §5.1로 옮겼다(D-14는 권장안이 아닌 선택, D-15의 코드 읽기 축소는 설명을 듣고 고름, 나머지는 권장안). 새 결정 D-30은 2026-10-20 T08a 진행 중 티켓 밖 대화에서 확정해 §5.1에 넣었다. 같은 날 D-11의 ACL 부분을 U28 결과로 (a)에서 (c)로 바꿨다(T08a).

### 5.3 단계 결정 게이트

없음. T05가 정할 게이트(사용자 2026-10-18, T05 질문 응답), T14가 정할 게이트(D-13의 나머지, D-19. 사용자 2026-10-18, T14 질문 응답), T15가 정할 게이트(D-14~D-17, D-24. 사용자 2026-10-18, T15 질문 응답)가 모두 확정돼 §5.1로 옮겼고, 다른 티켓에 배정된 결정 ID는 없다.

확정된 결정 안에 미정으로 남긴 세부는 새 결정 ID 없이 담당 티켓에서 정한다.

- D-24: 토큰 분리, ruleset E 여부, App 이름과 설치 저장소, 허용 파일 경로(설정 키 `github.change_writer_allow_paths`) → T19.
- R08: 연결 방식 → T18.

---

## 6. 단계 개요

| 단계 | 티켓 | 결과 |
|---|---|---|
| P0 정리·준비 | T01, T02 (완료) | 옛 코드 보존, 새 작업 사본 |
| P1 플랫폼 설계 | T03, T02 → T04 → T05 (모두 완료) | 설계 문서 0·A~G, 결정 확정, P2 티켓 재분해 |
| P2 플랫폼 구축 (재분해 T05 2026-10-18) | T06 → T07 → T09 → T08a → T10 → {T08b, T11} → T12 → T13. 이 줄은 권장 순서이고 간선이 아니다: T08b는 T08a·T09만 기다리고(T10과 무관), T11이 T10을 기다린다. T10 착수는 T07 뒤 T09와 병행하고 완료는 T09 뒤다. `infra/github` 첫 apply만 T08a의 R2 잠금 시험(U02) 뒤다. 간선 전체는 §8.2 | 테스트 앱까지 검증된 새 플랫폼 |
| P3 봇 준비 (P2와 병행) | T14 → T15 | 정비된 봇 문서, DISCOVERY 산출물 |
| P4 봇 V1 | T16a → T16b → T17·T18·T20 → T19 → T21. T16a(로컬·mock)는 T15 뒤 P2와 병행하고, T16b(실연동·첫 배포)는 T13 뒤다. T17·T18·T20은 T16a 뒤 착수, T16b 뒤 완료다(V1 범위 조정 안 3, §5.1). 간선 전체는 §8.2 | V1 판정. STAGE별 제한 시범 운영(단계마다 사람 승인) |
| P5 후속 | T22 (T13과 봇 첫 배포 T16b 뒤, 나머지 P4와 병행) | `files`의 새 흐름 배포, 옛 aiops 저장소·App과 `mac-uptime-guard` 삭제(장치 끄기와 옛 Telegram 봇 토큰 폐기 뒤), `aiops-autodeploy-canary` private 보관 |

**범위 밖:** 봇 V2 이후. `04` §9의 전환 기준을 채운 뒤 별도 계획으로 다룬다.

---

## 7. 인수 조건

각 조건의 검증 경계마다 잡아내는 실패와 놓치는 범위를 함께 적는다.

### 플랫폼

- **AC-P1 옛 저장소 보존·동결:** annotated `legacy` 태그가 가리키는 커밋이 동결 당시의 main SHA와 같고, 그 SHA가 T01에 기록돼 있다. 옛 Actions는 T07의 main 교체까지 비활성이다. 옛 저장소의 열린 PR은 T06 전에 모두 닫혀 있다.
  잡는 것: 태그 누락, 동결 중 자동화 재가동, 병합 가능한 옛 PR의 실수 병합. 놓치는 것: 옛 브랜치의 미병합 작업(보존 대상 아님).
- **AC-P2 설계 문서 완결:** 설계 문서에 플랫폼 프롬프트 §1 상태표(0절), §3 교훈 표(§3 완료 기준의 범위 전부), §10 A~F, 검증 시나리오 1~17마다 방법(G절)이 있다.
  잡는 것: 범위 누락. 놓치는 것: 설계 판단의 질(사람 검토 필요).
- **AC-P3 결정 확정:** D-05~D-07, D-09~D-12, D-18, D-20, D-21, D-22, D-25, D-26, D-27이 전부 결정되거나, 이유와 재결정 시점을 단 보류 상태다. D-04와 D-08은 확정(사용자 2026-10-18)이다(§5.1). 보류한 결정에 의존하는 티켓은 그 결정이 날 때까지 시작하지 않는다.
  잡는 것: 미결정 상태로 구축 진입. 놓치는 것: 결정 자체의 타당성.
- **AC-P4 옛 자원 정리:** 옛 자원 목록의 모든 줄이 `삭제됨 / 유지(이유) / import 예정 / 보류(결정 ID 또는 담당 티켓)` 중 하나다. 목록은 외부 자원, 옛 자격, NUC 호스트 잔여물과 데이터 경로를 포함한다. 저장소는 남아 있다.
  잡는 것: 이름·phase 충돌을 낼 잔여 자원, 살아 있는 옛 자격, 새 클러스터에 섞일 옛 데이터. 놓치는 것: 목록에 처음부터 없던 자원. 실측 목록과 `credential-expiry.json`으로 범위를 줄인다.
- **AC-P5 재구축·재부팅:** 빈 환경에서 문서 절차만으로 플랫폼이 다시 서고(시나리오 13), NUC 재부팅 뒤 의존 서비스가 준비된다(시나리오 12).
  잡는 것: 문서에 없는 수동 단계. 놓치는 것: VM으로 검증하면 실제 NUC의 네트워크·hostPort 차이.
- **AC-P6 DNS:** 공유기 설정을 바꾸지 않고 LAN 이름 해석과 광고 차단이 동작한다. AdGuard가 멈추면 LAN 기기는 공유기 보조 DNS로, Tailscale 기기는 AdGuard 공용 DNS로 이름을 풀고, Tailscale 기기의 광고 도메인 차단은 집 Wi-Fi와 셀룰러에서 유지된다(D-08, 시나리오 14). AdGuard Home 사용자 규칙의 적용률을 측정해 남긴다. **2026-10-20 시나리오 14:** LAN은 불합격이다(AdGuard 정지 중 공유기 경유 질의 30회 중 26회 시간 초과, 공유기가 보조 DNS로 넘어가지 않음). 사용자가 한계로 승인했다(approvals.md). 완화는 런북 `docs/runbooks-public/nuc-dns-outage.md`와 T08b의 AdGuard 정지 경보다. Tailscale 기기 쪽은 통과했고, 사용자 규칙 적용률은 셀룰러 19/20, 집 Wi-Fi 20/20(2026-10-21)이다.
  잡는 것: 폴백 누락, 노드 자신의 DNS 루프, AdGuard Home이 tailnet에서 조용히 빠진 상태(질의 0건 경보). 놓치는 것: 기기별 OS의 DNS 캐시 동작, 같은 도메인 광고, 브라우저 보안 DNS·안드로이드 개인 DNS 우회, 질의를 가로채는 망.
- **AC-P7 배포 흐름:** 앱 저장소 push부터 digest 기반 배포 PR, 병합, Argo CD 배포, 실행 확인까지 흐른다(시나리오 1). 늦게 끝난 빌드가 최신 배포를 덮지 않는다(시나리오 11).
  잡는 것: 태그 의존, 경쟁 상태. 놓치는 것: 여러 앱 동시 배포 부하.
- **AC-P8 병합 정책:** 자동 병합 조건(작성 주체·브랜치·내용)이 문서에 있고 서버 쪽에서 강제된다. 조건 밖 PR은 사람 승인 뒤에만 병합된다(시나리오 15). 배포 갱신 주체가 아닌 신원(봇 변경 PR 등)의 PR은 내용이 digest만 바뀌어도 자동 병합되지 않는다. 그런 신원은 main과 배포 브랜치에 직접 쓸 수 없고, 저장소별로 설치할 수 있다(D-24). GitHub 보호 설정은 Terraform github root로 선언하고, guard가 라이브 값을 대조한다(D-28). 토큰 권한·저장소 설정·public 저장소 완결성 같은 guard는 plan 때 늘 평가된다. 관리 자원(ruleset, environment)의 내용 guard는 그 자원에 변경이 예정되면 apply 뒤에 평가되므로 apply 뒤 verify를 다시 돌린다.
  잡는 것: 간접 자동 병합 경로, 작성 주체를 보지 않는 조건, 봇 신원의 보호 브랜치 쓰기. 놓치는 것: 관리자 우회.
- **AC-P9 데이터:** 시나리오 2, 3, 4, 8, 9, 10 (DB·Valkey 추가, 영속 Valkey 백업·복원, 비밀번호 변경 후 접속, 삭제 시 보존, 특정 앱만 복원).
  잡는 것: 수명 혼동, 복원 불가. 놓치는 것: 대용량 데이터 복원 시간.
- **AC-P10 시크릿:** 필수 키가 없으면 명확히 실패하고(시나리오 6), Infisical 장애 중 기존 서비스가 유지된다(시나리오 7). Infisical 접속 복구 자산 목록과 순서가 있다. 저장소가 public이면(D-23) 목록은 저장소 밖 비공개 위치에 있고, 저장소 문서에는 위치와 항목 이름만 있다.
  잡는 것: 빈 값 전달, 장애 전파. 놓치는 것: 장기 장애에서 토큰 만료.
- **AC-P11 비AI 알림·외부 감시:** 봇 없이도 경보가 도착하고(시나리오 16), NUC 전체 중단이 외부에서 감지된다(시나리오 17). 두 시나리오는 플랫폼 프롬프트 §9에 있다.
  잡는 것: 경보 경로의 봇 의존. 놓치는 것: 외부 감시 서비스 자체의 장애.
- **AC-P12 봇을 위한 여지:** 공개 webhook 수신 경로, 관측·Argo CD·Kubernetes 읽기 전용 접근, Alertmanager 외부 수신자, 격리 작업 공간, 리뷰 전용 App의 저장소별 설치가 설계되고 준비돼 있다. 설계 문서에는 자리마다 위치, 권한 범위, 준비 확인 방법이 있다.
  잡는 것: 봇 구현 때 플랫폼을 다시 고쳐야 하는 공백. 놓치는 것: 실제 봇 부하에서의 동작(T16b·T17에서 확인).
- **AC-P13 CLI:** `plan`이 부수효과 없이 읽기만 하고, 같은 등록 명령을 재실행해도 데이터·비밀번호가 바뀌지 않으며(시나리오 5), 사람용 출력과 JSON을 모두 낸다.
  잡는 것: 숨은 쓰기, 재실행 파손. 놓치는 것: 부분 실패의 모든 조합.
- **AC-P14 기존 앱 재연결:** 사용자가 고른 기존 앱이 새 흐름으로 배포된다. 남은 후보는 `files`다(`page`·`trip-mate-api`는 삭제 결정, D-29).
  잡는 것: 옛 공통 워크플로 의존. 놓치는 것: 고르지 않은 앱.

### 봇

- **AC-B1 봇 문서 정비:** 봇 문서에 옛 저장소 스냅샷에 의존하는 문장이 남지 않고, 플랫폼 설계 문서를 가리킨다. 옛 표현을 일부러 남긴 곳은 T14가 만드는 줄 단위 "의도한 언급 목록"(파일:줄, 이유)으로 관리한다. 범주는 교훈 자료, C-08 보호 문장의 본문과 주석, `04` §2 반례 표, `04` §4 시험 문구, `02`·`03` 머리의 처리 기록 표(T14 전 "다시 검토할 문장" 표), 새 플랫폼의 정상 용어(예: D-07의 자동 병합 범위), 철거 대상 표시(옛 자산을 지운다는 문장), 일반 낱말(키워드와 글자만 같은 낱말)이다. 범위는 `00`~`04` 다섯 문서다(D-19 확정(사용자 2026-10-18, T14): `02`·`03`도 넣는다).
- **AC-B2 DISCOVERY:** `01` §3 산출물 6종(`DISCOVERY.md`, `ARCHITECTURE.md`, `DECISIONS.md`, `VERIFICATION.md`(능력표), `V1_PLAN.md`, `PROJECT_STATUS.md`)과 비밀값 없는 설정 초안, HANDOFF가 있고 D-14~D-17, D-24가 결정됐다.
- **AC-B3 FOUNDATION:** AUTH-01·02, EVENT-01~04, CHAT-01·02, READ-01·02, SEC-01, OPS-01·02. 봇이 플랫폼에 처음 배포됐다는 증거.
- **AC-B4 PR_REVIEW:** REVIEW-01~05, SEC-01·02, DATA-01, EVENT-02, 그리고 PR 경로의 AUTH-01·EVENT-01·EVENT-03. 의존성 갱신 PR(D-18)의 리뷰 결과 1건 이상(D-18이 "없음"이면 `not_applicable`과 근거).
- **AC-B5 CODEX_BRIDGE:** TASK-01~03, SEC-02, 질문 경로의 AUTH-02.
- **AC-B6 CHANGE_PR:** CHANGE-01~03, DEPLOY-01, DATA-01, 변경 작업자 경로의 SEC-02, 게시 경로의 EVENT-02.
- **AC-B7 MEMORY_BRIEFING:** MEM-01, BRIEF-01, DATA-02, AUTH-02.
- **AC-B8 V1 판정:** `04` §4의 시험 30개가 모두 `pass / fail / not_run / blocked / not_applicable`로 기록되고, 판정이 `READY_FOR_SCOPED_PILOT` 이상이다.

**단계 AC 공통 완료 규칙 (AC-B3~B7):** 배정된 시험에 `fail`이 없다. `blocked`와 `not_run`은 사유와 해소 티켓을 함께 적는다. 보안 경계 시험(AUTH-01, READ-02, SEC-01·02, DATA-01, REVIEW-04, CHANGE-02)은 그 단계의 경로에서 최소 `mock` 또는 `local_integration` 증거(`04` §3)로 `pass`다.

봇 시험 ID는 `04` §4 정의를 따른다. 여러 단계가 같은 시험에 기여하면(예: SEC-01, DATA-01) 각 단계는 자기 경로만 검증하고, T21이 전체를 다시 확인한다. 시험 경계와 놓치는 범위는 각 단계 HANDOFF 추적 표의 "검증 경계" 칸에 적는다(`04` §7).

### 공통

- **AC-X1 단계 산출물:** 모든 티켓이 끝날 때 산출물 또는 HANDOFF를 티켓에 적힌 경로에 남기고 커밋한다. 공개해도 되는 봇 산출물은 봇 저장소 `ukyi-app/homelab-bot`(public)의 `docs/ai-bot/`에, 그 밖은 homelab `rebuild`(T07 뒤에는 PR로 main)에 둔다. 봇 운영 산출물은 봇 저장소에 두지 않는다(D-13): 개발 산출물(evidence, handoffs, DISCOVERY의 내부 경로)은 private 저장소 `ukyi-app/homelab-bot-ops`에, 봇이 실행 중 읽는 값(runtime-policies 실제 값, 허용 목록 실제 값)은 Infisical `/apps/homelab-bot/`에 두고 봇 저장소에는 키 이름만 둔다. 공개되면 안 되는 그 밖의 자료(D-23)는 저장소 밖이나 private 위치에 두고 위치만 적는다. 다음 티켓이 그것을 입력으로 쓴다.
  잡는 것: 이 디스크에만 남은 산출물, 입력 없는 다음 단계. 놓치는 것: 산출물의 질.
- **AC-X2 외부 변경 승인:** 계정·App·삭제·배포·병합·공개 같은 외부 변경은 매번 사람 승인 기록이 [approvals.md](approvals.md)에 있다 (§11).
  잡는 것: 승인 없는 외부 변경. 놓치는 것: §11 목록에 없는 외부 변경(목록을 갱신해 줄인다).

---

## 8. 티켓

### 8.1 목록

| ID | 제목 | 단계 | Blocked by | 상태 | 수행 |
|---|---|---|---|---|---|
| [T01](issues/T01-legacy-freeze.md) | 옛 저장소 동결·보존 | P0 | 없음 | 완료 (2026-10-17) | 사람 (에이전트 준비) |
| [T02](issues/T02-working-copy.md) | 새 작업 사본 준비 | P0 | 없음 | 완료 (2026-10-17) | 에이전트 + 사람 |
| [T03](issues/T03-platform-prompt-gaps.md) | 플랫폼 설계 프롬프트 보강 | P1 | 없음 | 완료 (2026-10-17) | 에이전트 |
| [T04](issues/T04-platform-design.md) | 플랫폼 설계 실행 | P1 | T02(로컬 단계), T03 | 완료 | 에이전트 |
| [T05](issues/T05-platform-decisions.md) | 플랫폼 결정 확정·구축 티켓 재분해 | P1 | T04 | 완료 (2026-10-18) | 사람 + 에이전트 |
| [T06](issues/T06-teardown.md) | 옛 클러스터 철거·외부 자원 정리 | P2 | T05, T02, T01 | 완료 (2026-10-19, 재부팅 뒤 검증 FAIL 0. 옛 Telegram 봇 토큰 폐기는 사용자 작업 대기) | 사람 |
| [T07](issues/T07-bootstrap.md) | 부트스트랩: main 교체·k3s·Argo CD | P2 | T01, T02, T06 | 완료 (2026-10-19, main `eaf7bb5`, 재부팅 뒤 확인 통과) | 에이전트 + 사람 |
| [T08a](issues/T08a-network.md) | 네트워크·DNS·외부 공개 | P2 | T07, T09 | 완료 (2026-10-21) | 에이전트 + 사람 |
| [T08b](issues/T08b-observability.md) | 관측·알림·봇 자리 | P2 | T08a, T09 | 완료(2026-10-23. 시나리오 17은 ping 차단 대체(물리 차단은 T13), 봇 route는 T16b가 켠다) | 에이전트 + 사람 |
| [T08c](issues/T08c-internal-short-links.md) | 내부 UI 짧은 주소 `go/` | P2 | T08a | 완료(2026-10-22. VM 실접속은 T13 시나리오 13) | 에이전트 + 사람 |
| [T09](issues/T09-secrets.md) | 시크릿 체계 | P2 | T07 | 완료 (2026-10-20. 시나리오 6·7 E3 범위 통과, 플랫폼·Terraform 자격 등록, 복구 자산 두 곳 보관) | 에이전트 + 사람 |
| [T10](issues/T10-cicd.md) | CI/CD | P2 | T07(착수), T09(완료), T08a(`infra/github` 첫 apply만) | 완료(2026-10-26. 15-11·egress 공백 완화는 T13) | 에이전트 + 사람 |
| [T11](issues/T11-data-services.md) | 데이터 서비스 | P2 | T08a, T09, T10 | 완료(2026-10-23. T10 완료 전 착수(사용자 결정), restore.md 2절 후속은 #872·#874·#875) | 에이전트 + 사람 |
| [T12](issues/T12-cli.md) | CLI | P2 | T10, T11 | 완료(2026-10-26. T10 선행 완화(사용자 결정), 운영 통합 검증 통과, 후속은 티켓) | 에이전트 + 사람 |
| [T13](issues/T13-platform-integration.md) | 테스트 앱 통합 검증 | P2 | T08a, T08b, T08c, T10, T11, T12 | 진행 중(2026-10-26 착수, 17 남음) | 에이전트 + 사람 |
| [T14](issues/T14-bot-docs-refresh.md) | 봇 문서 정비 | P3 | T05 | 완료 (2026-10-18) | 에이전트 + 사람 |
| [T15](issues/T15-bot-discovery.md) | 봇 V1 DISCOVERY | P3 | T14 | 완료 (2026-10-18) | 에이전트 + 사람 |
| [T16a](issues/T16a-bot-foundation-local.md) | 봇 FOUNDATION 로컬·mock | P4 | T15 | 완료 (2026-10-20. 봇 저장소 PR #5·#6, DM 끔·브리핑 08:50) | 에이전트 + 사람 |
| [T16b](issues/T16b-bot-foundation-deploy.md) | 봇 FOUNDATION 실연동·첫 배포 | P4 | T13, T16a | 대기 | 에이전트 + 사람 |
| [T17](issues/T17-bot-pr-review.md) | 봇 PR_REVIEW | P4 | T16a(착수), T16b(완료) | 착수 가능 (T16a 완료 2026-10-20) | 에이전트 + 사람 |
| [T18](issues/T18-bot-codex-bridge.md) | 봇 CODEX_BRIDGE | P4 | T16a(착수), T16b(완료) | 착수 가능 (T16a 완료 2026-10-20) | 에이전트 + 사람 |
| [T19](issues/T19-bot-change-pr.md) | 봇 CHANGE_PR | P4 | T17, T18 | 대기 | 에이전트 + 사람 |
| [T20](issues/T20-bot-memory-briefing.md) | 봇 MEMORY_BRIEFING | P4 | T16a(착수), T16b(완료) | 착수 가능 (T16a 완료 2026-10-20) | 에이전트 |
| [T21](issues/T21-bot-release-audit.md) | 봇 V1 RELEASE_AUDIT | P4 | T17, T18, T19, T20 | 대기 | 독립 감사 에이전트 + 사람 |
| [T22](issues/T22-reconnect-apps.md) | 기존 앱 저장소 재연결·옛 저장소 정리 | P5 | T13, T16b | 대기 | 에이전트 + 사람 |
| [T23](issues/T23-platform-followups.md) | 플랫폼 후속(T13에서 넘김: U40 2회차) | P2 | T13 | 대기 | 에이전트 + 사람 |

### 8.2 의존성 그래프

```text
T02 → T04
T03 → T04
T04 → T05
T05 → T06
T05 → T14
T01 → T07
T02 → T07
T06 → T07
T02 → T06
T01 → T06
T07 → T09
T07 → T10    (착수)
T09 → T10    (완료)
T08a → T10   (infra/github 첫 apply만, U02 잠금 시험 뒤)
T07 → T08a
T09 → T08a
T08a → T08b
T09 → T08b
T08a → T08c
T08a → T11
T09 → T11
T10 → T11
T10 → T12
T11 → T12
T08a → T13
T08b → T13
T08c → T13
T10 → T13
T11 → T13
T12 → T13
T14 → T15
T15 → T16a
T13 → T16b
T16a → T16b
T16a → T17   (착수)
T16b → T17   (완료)
T16a → T18   (착수)
T16b → T18   (완료)
T16a → T20   (착수)
T16b → T20   (완료)
T17 → T19
T18 → T19
T17 → T21
T18 → T21
T19 → T21
T20 → T21
T13 → T22
T16b → T22
T13 → T23
```

검사(2026-10-18 T16 분할 뒤, 스크립트): 24개 티켓이 모두 그래프에 있고, 모든 선행 ID가 존재하며, 모든 티켓 머리말의 Blocked by와 §8.1 표가 이 간선과 같고, 순환이 없다. T01·T02·T03은 선행이 없다. 위상 순서 하나: T01, T02, T03, T04, T05, T06, T14, T07, T15, T16a, T09, T08a, T10, T08b, T11, T12, T13, T16b, T17, T18, T20, T19, T21, T22. P2 간선은 설계 E.2 끝 문단과 같고, P4 간선은 T15 산출물 `V1_PLAN.md` §1 초안(봇 저장소 `docs/ai-bot/`에 PR 예정)과 같다.

다시 검사(2026-10-20 T08c 추가 뒤, 스크립트): 25개 티켓이 모두 그래프에 있고, 모든 선행 ID가 존재하며, 티켓 머리말의 Blocked by와 §8.1 표가 이 간선과 같고, 순환이 없다. T08c는 T08a를 기다리고 T13을 막는다(시나리오 13에서 VM의 `vm-go` 실접속을 본다). T10의 `go`·`vm-go` 이름 예약은 문서 규칙이라 간선으로 두지 않는다.

다시 검사(2026-10-29 T23 추가 뒤, 스크립트): 26개 티켓이 모두 그래프에 있고, 모든 선행 ID가 존재하며, 티켓 머리말의 Blocked by와 §8.1 표가 이 간선과 같고, 순환이 없다. T23은 T13이 사용자 결정(2026-10-29)으로 넘긴 U40 2회차를 맡고 T13만 기다린다.

**착수·완료 간선 (재분해 T05 2026-10-18):** T07 → T10은 착수, T09 → T10은 완료 간선이다(설계 C.4.8 "T09 → T10 간선의 답", E.2). T10의 작성 작업(차트, 워크플로, `infra/github` HCL)은 T07 뒤 T09와 병행한다. T09가 먼저 있어야 하는 것은 T10의 종단 시험(CLI 없는 동등 절차)뿐이다. Infisical 프로젝트와 배포 키 OIDC identity가 있어야 배포 PR이 생기기 때문이다. App 키 전달 방식은 D-04(확정(사용자 2026-10-18))대로 배포 키는 Infisical OIDC, 병합 키는 Secret Sync → environment `automerge`다.

**착수·완료 간선 (T16 분할, 2026-10-18):** T16a → T17·T18·T20은 착수, T16b → T17·T18·T20은 완료 간선이다(V1 범위 조정 안 3, §5.1). T16a 뒤에는 T16a 소유 공유 계약에 자기 경로를 더하는 로컬·mock 구현을 시작한다. 실연동(`authorized_external`)과 완료 판정은 봇이 배포된 T16b 뒤다(각 티켓 머리말).

**결정에서 온 간선:** T16b → T22는 D-01(봇이 첫 실제 앱, 확정)을 따른 순서다. 옛 T16 → T22를 첫 배포를 맡은 T16b로 옮겼다. T15 → T16a, T16a → T16b, T13 → T16b는 V1 범위 조정 안 3(확정(사용자 2026-10-18, T15), §5.1)을 따른다. T16a는 플랫폼을 쓰지 않아 T13을 기다리지 않는다.

**부분 선행:** T02는 로컬 단계(할 일 1~7)와 push 단계(8~11, 사람 승인 뒤)로 나뉜다. T02 → T04는 로컬 단계만 기다린다. T04 산출물이 T02의 작업 사본 안에 생기기 때문이다. T02 → T06, T02 → T07은 push까지 기다린다. T01 → T06은 열린 PR 닫기(T01 할 일 3)만 기다린다. T08a → T10은 T10의 `infra/github` 첫 apply만 기다린다. R2 state 잠금 동시 실행 시험(U02)이 T08a에 있어서다(D-28). T10의 작성·CI는 T07 뒤 바로 한다. T12의 읽기 명령(`doctor`, `status`)은 T10 뒤 먼저 착수할 수 있고, 나머지와 완료는 T11 뒤다(설계 E.0). 반대로 T01의 마지막 할 일(실행 기록 커밋)은 T02 로컬 단계 뒤에 한다.

### 8.3 실행 상태

- **완료:** T01, T02, T03 (2026-10-17), T04 (2026-10-18, push 2026-10-18), T05 (2026-10-18, push 2026-10-18), T14 (2026-10-18. 봇 문서는 봇 저장소로 옮김, D-13), T15 (2026-10-18. 공개 산출물은 봇 저장소 PR #3 `2e84c5f`, 운영 산출물은 `homelab-bot-ops`), T06 (2026-10-19), T07 (2026-10-19), T09 (2026-10-20), T16a (2026-10-20. 봇 저장소 PR #5·#6, HANDOFF는 `homelab-bot-ops`), T08a (2026-10-21), T08c (2026-10-22. tailnet 이름 조건은 작업 트리·이미지·로그로 판정, 사용자 결정 18:46. VM 실접속은 T13 시나리오 13), T08b (2026-10-23. 시나리오 17은 ping 차단 대체(사용자 결정, 물리 차단은 T13 시나리오 17), 시나리오 7 경보 부분은 틀린 값 방식(사용자 인정), 봇 경보 route는 시험 뒤 되돌려 T16b가 켠다), T11 (2026-10-23. T10 완료 전 착수(사용자 결정). 시나리오 2·3·4·8·9·10 통과, U15~U18·U26 확인. 데이터 차트 1.0.0 백업 결함은 1.0.1로 고침. 후속: restore.md 2절 보강(#872·#874·#875로 끝), 앱 역할 간 PUBLIC CONNECT 기본값), T10 (2026-10-26. 마지막 Renovate 확인 통과(homelab PR #878), 15-11·egress 공백 완화는 T13), T12 (2026-10-26. 2026-10-23 착수, T10 선행 완화는 사용자 결정. `homelab-probe`·`homelab-probe2`로 운영 검증: 재실행 불변(시나리오 5), plan 전후 상태 같음(AC-P13), 쓰기·읽기 명령 한 번씩, `github verify` = 래퍼, purge로 등록·데이터 정리. 운영에서 찾은 kubectl `-A` 순서(#894)·시험의 저장소 파일 읽기(#908) 고침. 후속: CLI 문구 P3 다섯, restore.md 1절 손 확인 절차, bun 1.4.4(#878), T11에서 넘어온 둘은 T13 전).
- **진행 중:** T13(2026-10-26 착수. 시나리오 1~14·15(15-13 뺌)·16 실행, 17 남음. 결과표 `platform/verification.md`).
- **지금 실행 가능:** T17·T18·T20 착수(선행 T16a 완료. 로컬·mock 구현까지, 완료는 T16b 뒤. T17·T18은 D-14 차단 조건, §5.1).
- **선행 대기:** T16b, T19, T21, T22, T23.
- **통합 검증 담당:** T13은 플랫폼 전체(플랫폼 프롬프트 §9 시나리오 1~17), T21은 봇 V1 전체(`04` §4 시험 30개).

### 8.4 병렬 후보와 소유 범위

| 병렬 묶음 | 조건 | 소유 범위 |
|---|---|---|
| T01 · T02 | 지금 | T01: GitHub 태그·PR(`gh api`, 로컬 사본 불필요). T02: `/home/ukyi/homelab`의 git 설정·`rebuild` 브랜치(문서 내용은 수정하지 않음). 둘이 함께 쓰는 것은 [approvals.md](approvals.md)와 `rebuild` 커밋이다. T01의 기록 커밋은 T02 로컬 단계 뒤에 별도 커밋으로 한다 |
| T09 · T10(착수) | T07 뒤 | 디렉터리는 T04 설계 구조로 나눈다. Argo CD 루트 앱 목록(`platform/root`)은 T07이 T08a·T08b·T09·T10·T11의 자리를 미리 만들어 둔다. T10 완료는 T09 뒤다 |
| T08a · T10 | T09 뒤 | T08a: `infra/cloudflare`, `infra/tailscale`, `infra/tailscale-dns`, `platform/cloudflared`·`traefik`·`tailscale`·`adguard`·`cert-manager`. T10: `platform/charts/app`, `.github/workflows/`, `infra/github`, `tools/tf-github.sh`(설계 E5). R2 state를 처음 쓰는 것은 T08a이고, T10의 `infra/github` 첫 apply는 T08a의 U02 잠금 시험 뒤에 한다 |
| T08b · T11 | T08b는 T08a·T09 뒤, T11은 T08a·T09·T10 뒤 | T08b: `platform/observability`, `platform/sandbox`, `platform/bot-slot`. T11: `platform/cnpg`, `platform/charts/app-data` 등(설계 E6). T08b는 T11의 선행이 아니다 |
| P3(T14·T15) · P2(T06~T13) | T05 뒤 | T14: 봇 문서(완료). T15: 봇 저장소 `homelab-bot`과 운영 산출물 저장소 `homelab-bot-ops`(D-13), 그리고 결정 기록 예외로 spec §5와 봇 저장소 `docs/ai-bot/prompts/`의 D-14~D-17·D-24 자리(봇 저장소 PR). P2: 플랫폼 디렉터리 |
| T16a · P2(T06~T13) | T15 뒤 | T16a: 봇 저장소 `homelab-bot`의 로컬·mock 코드와 시험(변경은 봇 저장소 PR). 실제 Discord·GitHub·플랫폼·모델 연동, 계정 생성, 배포는 하지 않는다. P2: 플랫폼 디렉터리 |
| T17 · T18 · T20 | T16a 뒤 착수, T16b 뒤 완료 | 공유 계약(event·job·outbox 스키마, 게시 서버)은 T16a 소유. 나머지는 추가 변경만. T13 실측으로 계약이 바뀌면 T16b가 고친다 |
| T22 · T17~T21 | T16b 뒤 | T22: 기존 앱 저장소. P4: 봇 저장소 |

### 8.5 추천 구현 전략

**의존 그래프 방식(`implement-spec`)을 추천한다.** 티켓 26개 사이에 실제 선행 관계가 많고, 통합 검증 지점(T13, T21)이 정해져 있기 때문이다.

다만 P2와 P4의 티켓은 각각이 여러 작업 묶음이다. 각 티켓을 시작할 때 그 티켓만 대상으로 다시 계획(feature-plan)을 세워 세부 명세와 하위 티켓을 만든다. P2 티켓 자체는 T05가 설계 결과 E에 맞춰 다시 쪼갰다(2026-10-18, T08 → T08a·T08b). P4의 T16은 T15가 V1 범위 조정 안 3(§5.1)에 따라 T16a·T16b로 나눴다(2026-10-18). T04는 조사 병렬 → 설계 한 세션 → 독립 검토의 세 단으로 한다(T04 티켓).

---

## 9. AC → 티켓 → 검증

| AC | 구현 티켓 | 검증 |
|---|---|---|
| AC-P1 | T01, T07 | `legacy^{}` 커밋과 T01 기록 비교, T07 전까지 Actions API `enabled:false`, T06 전 열린 PR 0개 |
| AC-P2 | T03, T04 | 플랫폼 프롬프트 §1·§3·§10 체크리스트, 교훈 표와 §3 완료 기준 범위를 `git ls-tree` 1단계 항목으로 대조 |
| AC-P3 | T05 | 결정표 빈 칸 없음, 보류 결정에 의존하는 티켓의 대기 표시. T05 완료(2026-10-18): AC-P3 목록 전부 확정(사용자 2026-10-18, T05), 보류 없음(§5.1, [approvals.md](approvals.md) 2026-10-18 12:32 줄) |
| AC-P4 | T06 | Cloudflare·R2·Tailscale·GitHub 목록 재조회 대조, 옛 자격 폐기 표, NUC 잔여 유닛·데이터 경로 부재, 저장소 존속(`archived:false`) |
| AC-P5 | T07, T13, T23 | 시나리오 12, 13(T23은 Infisical 장애가 겹친 재구축 U40) |
| AC-P6 | T08a, T08b, T13 | 시나리오 14(셀룰러 Tailscale 기기 확인, 사용자 규칙 적용률 집 Wi-Fi·셀룰러 20회씩 포함, T08a), tailnet 출처 질의 0건 경보와 그 발화 시험(T08b) |
| AC-P7 | T10, T13 | 시나리오 1, 11 |
| AC-P8 | T10, T13 | 시나리오 15, 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않는지 확인, `homelab github verify`(T12 전에는 `tools/tf-github.sh verify`) exit 0(guard 통과, 변경 없음, D-28) |
| AC-P9 | T11, T13 | 시나리오 2, 3, 4, 8, 9, 10 |
| AC-P10 | T09, T08b, T13, T23 | 시나리오 6, 7(T09는 경보를 뺀 E3 범위, T08b는 경보 부분), 복구 자산 목록 검토, U40(T23: 클러스터 유실과 Infisical 장애가 겹친 복구) |
| AC-P11 | T03, T08b, T13 | 시나리오 16, 17 |
| AC-P12 | T03, T04, T08a, T08b, T10, T13 | 설계 대조(자리마다 위치·권한 범위·준비 확인 방법), 경로·계정·App 설치 가능 여부 확인 (실사용은 T16b·T17). 자리별 담당은 §4.4(설계 E.3): webhook 수신 경로 T08a, 읽기 전용 접근 셋·경보 외부 수신자·격리 작업 공간 T08b, 리뷰 전용 App 구조 T10, 최종 확인 T13 |
| AC-P13 | T12, T13 | 시나리오 5, `plan` 실행 전후 외부 상태 비교 |
| AC-P14 | T22 | 고른 앱마다 시나리오 1 |
| AC-B1 | T14 | 옛 스냅샷 키워드 검색 결과와 줄 단위 의도한 언급 목록 대조 |
| AC-B2 | T15 | `01` §3 완료 조건 |
| AC-B3 | T16a, T16b | `04` §4 시험 (ID 목록은 이 명세 §7), 첫 배포 증거. T16a는 `mock`·`local_integration` 결과(실연동 부분은 `blocked`, 해소 T16b), T16b는 실연동 결과와 첫 배포 증거를 더하고 AC-B3 완료를 판정한다 |
| AC-B4 | T17 | `04` §4 시험 (ID 목록은 이 명세 §7), `04` §6 품질 표 |
| AC-B5 | T18 | `04` §4 시험 (ID 목록은 이 명세 §7) |
| AC-B6 | T19 | `04` §4 시험 (ID 목록은 이 명세 §7) |
| AC-B7 | T20 | `04` §4 시험 (ID 목록은 이 명세 §7) |
| AC-B8 | T21 | `04` §4 전체, §9 판정 |
| AC-X1 | 전체 | 각 티켓 완료 조건의 산출물 경로와 커밋 |
| AC-X2 | 전체 | §11 목록과 [approvals.md](approvals.md) 대조 |

AC-X1·AC-X2는 모든 티켓에 적용된다. 티켓 머리말의 연결 AC에 따로 적지 않아도 적용된다.

---

## 10. 위험과 제약

1. **옛 Argo CD prune.** main을 바꾸면 옛 클러스터 리소스가 지워질 수 있다. 관리자는 브랜치 보호를 우회해 main에 직접 push할 수 있다. 대응: `rebuild` 브랜치, 명시적 refspec push, T06 뒤 T07에서 main 교체.
2. **옛 github root destroy.** `github_repository.homelab`과 `github_repository.app_template`이 지워진다. 대응: destroy 금지. 해당 자원은 state에서 제거하고, 옛 state 객체는 다른 경로로 옮겨 보관한 뒤 새 root는 다른 키를 쓴다 (T06).
3. **`prevent_destroy` 버킷.** `homelab-pg-backups-prod`, `homelab-media-prod`는 Terraform으로 지워지지 않는다. 대응: 콘솔에서 수동 삭제 (T06).
4. **구축 기간 중단.** NUC 한 대라 T06부터 T13까지 홈랩 서비스가 없다. LAN은 공유기 보조 DNS, Tailscale은 Cloudflare 임시 DNS로 인터넷은 유지된다. healthchecks.io 체크는 철거 전에 일시 정지한다 (T06).
5. **Tailscale DNS (D-08의 대가).** 지금(C-05)은 병렬 질의라 Tailscale 기기의 광고 차단과 옛 내부 이름이 불안정하다(철거 기간 감수). D-08 적용 뒤에도 AdGuard Home 사용자 규칙은 AdGuard Home이 먼저 답한 질의에만 걸리고, 공용 경로는 평문 UDP라 질의를 가로채는 망에서 차단이 빠지거나 답이 위조될 수 있으며, AdGuard Home이 tailnet에서 빠져도 증상이 없다. 대응: "tailnet 출처 질의 1시간 0건" 경보(T08b), 시나리오 14의 셀룰러 확인과 사용자 규칙 적용률 측정(T08a). 나머지 대가(로컬 DNS 전용 이름, 같은 도메인 광고, 보안 DNS 우회)는 감수한다(§4.5).
6. **봇 V1 규모.** 일정 위험 1순위. 대응: 한 세션에 STAGE 하나, `LOCAL_VERIFIED_INTEGRATION_PENDING`을 정상 중간 상태로 인정 (`04` §9). 범위 조정은 안 3으로 확정(사용자 2026-10-18, T15)이다: STAGE별 제한 시범 운영(단계마다 사람 승인, approvals.md 기록)과 T16a 로컬·mock 선행(§5.1). 기능 수는 줄이지 않는다.
7. **봇 모델 구독 인증 (D-14의 대가).** 사용자가 권장안(OpenAI API 전용 프로젝트 키)이 아니라 봇 전용 ChatGPT 구독 계정을 골랐다(확정(사용자 2026-10-18, T15)). 남는 위험은 넷이다. (1) 공식 문서(learn.chatgpt.com의 CI/CD 인증 안내)는 구독 인증의 무인 실행을 "advanced workflow for enterprise and other trusted private automation"으로 두고 "Do not use this workflow for public or open-source repositories"라고 적는다 [확인: https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18]. 봇의 리뷰 대상은 public 저장소다(D-29). 이 문구가 실행 위치를 말하는지 다루는 코드를 말하는지는 [미확인]이다. OpenAI에 확인할 항목은 셋이다: 이 문구의 범위, 개인 약관의 자동 추출 조항이 이 사용에 적용되는지, 봇 전용 두 번째 개인 계정의 허용 여부. 셋 다 [미확인]이다. (2) 같은 문서에 따르면 Codex는 `last_refresh`가 약 8일 넘으면 토큰을 갱신해 `auth.json`에 다시 쓴다. 갱신본을 잃거나 파드를 다시 만들 때 처음 시드로 덮으면 회전된 토큰과 어긋나 사람이 다시 로그인해야 한다. 그래서 작업자 전용 영속 쓰기 공간이 필요하다(설계 C.8 변경, T08b·T16b). (3) `auth.json` 하나는 한 기기나 직렬 작업 하나만 쓴다. 작업이 직렬 1개라 PR 리뷰, Codex 작업, 변경 PR이 한 줄로 기다린다. (4) 구독 한도(Plus의 5시간 한도, 플랜에 따라 주간 한도)는 공식 문서가 고정 수치가 아닌 추정치로 적어 예측하기 어렵다 [확인: https://learn.chatgpt.com/docs/pricing , 2026-10-18]. 한도에 닿으면 다른 계정·인증으로 바꾸지 않고 waiting으로 둔다. 그 밖에 Plus·Pro 입력은 기본으로 모델 개선에 쓰일 수 있고 설정에서 끈다 [확인: https://help.openai.com/en/articles/5722486 , 2026-10-18]. 대응: §5.1 D-14의 조건 다섯, OpenAI 확인(위 세 항목), 차단 조건(확정(사용자 2026-10-18, PR #3 리뷰)): 허용 확인이나 공식 지원 인증 전환 전에는 공개 저장소 PR 내용이나 코드로 구독 모델을 부르지 않는다(T17 평가셋·실연동·시범 P-2, T18 작업). T16a·T16b와 대화 레인, 모델을 부르지 않는 로컬·mock 구현은 그대로 진행한다, 시범 운영(§5.1 V1 범위 조정)에서 한도 도달과 대기 시간 기록, 봇 계정의 학습 사용 설정 확인(§11).
8. **단일 호스트 격리.** worktree는 보안 샌드박스가 아니다(`00` §6). 대응: T03에서 격리 실행 공간을 플랫폼 요구로 넣었다. 기본 방식은 설계 C.8 기본값이다(확정(사용자 2026-10-18, T05)). D-15(확정(사용자 2026-10-18, T15))로 작업자의 코드 읽기를 `codeload.github.com` 압축본으로 좁히고 작업자에서 GitHub 자격과 `github.com`·`api.github.com`·gist egress를 뺐다. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft로 물러난다.
9. **부트스트랩 자격증명 유실.** Infisical 접속 자격을 잃으면 모든 시크릿 전달이 멈춘다. 대응: 복구 자산 목록과 별도 암호화 보관 (T09, AC-P10). 저장소가 public이면 복구 자산 목록은 저장소 밖에 둔다 (D-23).
10. **문서 유실.** 이 폴더는 T02(2026-10-17)로 원격 `rebuild`에 올라갔다. 남은 위험은 커밋·push하지 않은 이후 변경이다. 대응: 문서를 만드는 티켓은 끝날 때 커밋하고, 승인받아 push한다 (§12).
11. **옛 AIOps 잔여물.** T07에서 main을 바꾸면 `aiops-autodeploy-canary` 빌드가 깨진다. OS를 유지하므로(D-12, 확정(사용자 2026-10-18, T05)) NUC의 옛 AIOps 유닛과 nft 규칙이 새 네트워크와 부딪칠 수 있다(추측). 대응: T06 정리 목록(D-12의 철거 범위 H1·H2), T22에서 aiops 저장소·App 삭제와 `aiops-autodeploy-canary` private 보관(D-13, D-29), D-12.
12. **옛 tailscale root apply·destroy.** 옛 `infra/tailscale` root를 apply하면 Tailscale 기기의 임시 DNS 폴백(C-05)이 사라진다. ACL을 덮어쓸 때 운영자 원격 접속 규칙이 빠지면 NUC 원격 접속이 끊긴다. 대응: 옛 root는 apply도 destroy도 하지 않는다. 새 ACL은 autogroup:self와 ssh 규칙을 유지한다 (T06, T08a). 2026-10-20 D-11 (c)로 NUC는 `tag:nuc`가 된다. 원격 접속은 `tag:nuc` 포트 규칙(22는 sshd. NUC는 Tailscale SSH를 켜지 않아 ssh 규칙은 쓰이지 않는다)으로 유지하고, 규칙을 먼저 적용한 뒤 태그를 붙인다(T08a, 2026-10-21 적용).
13. **계획 공개.** `homelab`이 public이라 T02 push부터 계획·설계 문서가 공개된다. 대응: 공개를 받아들이고(D-23, 확정) 운영 민감 문서는 저장소 밖에 둔다.
14. **옛 클러스터·데이터 부활.** k3s를 멈추기만 하거나 표준 제거만 하면 옛 datastore나 PV 데이터가 남는다. 그 위에 새 k3s를 설치하면 옛 클러스터나 옛 데이터가 되살아날 수 있다. 대응: T06 검증 강화, T07 시작 조건.
15. **NUC 로컬 전용 자료 유실.** 옛 런북, 자격 파일, 다른 프로젝트가 이 디스크에만 있다. 대응: T06 선행 보존 점검, D-12(OS 유지라 디스크가 남는다), D-27(T06 목록 작성에만 읽기 전용, 값은 저장소에 옮기지 않음). 둘 다 확정(사용자 2026-10-18, T05).
16. **옛 무만료 자격.** 새로 발급해도 옛 PAT, Cloudflare 토큰, R2 키, OAuth 클라이언트가 살아 있다. 대응: T06 자격 폐기 표. state 정리에 필요한 자격은 state 처리 뒤에 폐기한다.
17. **Codex Connector.** org 전체 쓰기 권한의 App이 PR마다 자동 리뷰한다. `files`·템플릿 main 직접 쓰기는 결정 5 하드닝(2026-10-18 실행)이 막는다. 대응: D-29, D-26(유지 + 조건 다섯, 확정(사용자 2026-10-18, T05). 다섯째 Codex 작업 환경 없음은 사용자 2026-10-22), D-16(확정(사용자 2026-10-18, T15): 설치 범위를 선택 저장소로 줄이고 `homelab-bot-ops`는 뺌(2026-10-18 17:45 완료), 봇이 리뷰하는 저장소의 자동 리뷰 끔. 사람 작업 §11).
18. **하드닝 실행 전 공백(해소).** 결정 5 스크립트를 2026-10-18에 사람이 실행해 `files`·`homelab-app-template` main에 보호를 걸었다(approvals.md). 템플릿 main은 모든 새 앱의 첫 main 내용이 된다. `current_user_can_bypass`가 두 저장소 모두 `pull_requests_only`라 설계 문서 F D-07의 대안은 아직 필요 없다. 실제 bypass 병합은 E1에서 시험한다(U08).
19. **GitHub Terraform provider 결함과 state 보호 (D-28).** provider v6.13.0의 ruleset etag 버그(#3519, 수정 #3637 미출시)로 apply가 실패할 수 있다. R2에는 versioning이 없어 state를 잘못 덮으면 되돌릴 수 없다. guard가 실패하면 모든 apply가 막힌다. 대응: 6.13.0 정확 핀, 래퍼의 apply 전 state pull 백업, apply 실패 시 그 plan의 ruleset을 state rm 뒤 import, 비상 경로(-target 재생성 뒤 전체 verify)를 런북에 둔다(T10).
20. **public 앱 저장소 노출 (D-29).** 앱 코드, Actions 로그, 이미지가 공개된다. GHCR 패키지는 public으로 바꾸면 되돌릴 수 없고, `GITHUB_TOKEN`으로 만든 패키지의 가시성 상속은 문서끼리 어긋난다. 대응: D-23 금지 항목을 앱 저장소 코드·로그·이미지까지 넓히고 템플릿 CI에 금지 패턴 검사, push job 캐시 없음, T10에서 `homelab-probe` 첫 push로 시험, public 앱 저장소 기본 설정(§5.1 D-29).
21. **병합 키 sync의 PAT 의존 (D-04).** App Connection의 fine-grained PAT는 owner 계정에 묶이고 만료가 없다(사용자 2026-10-21). 새면 회수할 때까지 homelab의 secret·environment를 바꿀 수 있다. 회수되면 sync가 멈추고, 실패 알림은 Infisical 프로젝트 Admin 메일로만 온다. 대응: 월 1회 verify(environment 정책·secret 범위 변경을 잡는다), 회전 뒤 environment secret `updated_at` 확인(§5.1 D-04).
22. **커밋 작성자 이메일 공개.** public 저장소 커밋에는 작성자 이메일이 남는다. 원격 `rebuild`의 커밋 3개(`56eeb54`, `53fc932`, `4bb61ef`)는 noreply가 아닌 주소이고, force push를 하지 않으므로(D-03) 그대로 남는다. 대응 없음: 사용자가 커밋 작성자 이메일 공개를 받아들였다(2026-10-18). GitHub 이메일 비공개 설정은 하지 않고, 잠시 noreply로 바꿨던 작업 사본의 로컬 git 설정도 지워 개인 이메일로 커밋한다. 이 결정은 커밋 작성자 정보에만 해당한다.

---

## 11. 사람만 하는 일

에이전트는 아래 작업을 준비·확인만 하고, 실행은 사람이 승인한 뒤에 한다. 승인은 [approvals.md](approvals.md)에 시각, 대상, 작업, 명령 또는 링크, 티켓으로 남긴다. 저장소가 public이면 식별자만 쓰고 값은 쓰지 않는다.

| 대상 | 작업 | 티켓 |
|---|---|---|
| GitHub | 결정 5 하드닝 스크립트 실행(`files`·`homelab-app-template`의 `CODEOWNERS`·`app-main`·secret scanning·push protection, 저장소와 org의 fork PR 승인 `all_external_contributors`), `page`·`trip-mate-api` 저장소와 GHCR 패키지 삭제. 자동 권한 검사가 에이전트의 org·저장소 설정 변경을 막아 사람이 실행한다(2026-10-18 결정·실행. GitHub 이메일 비공개와 전역 git 설정은 하지 않기로 했다) | 지금 (티켓 밖) |
| GitHub | `legacy` 태그 생성, 열린 PR 닫기, `rebuild` 브랜치 push, 문서 커밋 push, 브랜치 보호·ruleset·webhook 정리, `allow_auto_merge` 끄기(D-07), environment·저장소 변수·GHCR 패키지 정리, main 교체 squash 병합(D-25), Actions 재활성화 | T01, T02, T04, T05, T06, T07, T14 |
| GitHub | 옛 App 정리(reader, writer, dispatch 등록), 옛 PAT 폐기, 새 App 생성·설치, 호스팅형 Renovate App 저장소별 설치(D-18), 보호 설정의 Terraform apply(owner 로컬, D-28), Actions 허용 범위, GHCR 패키지 Public 전환(D-29, 되돌릴 수 없음), Infisical App Connection용 fine-grained PAT 발급(D-04), 시험 PR 게시, 앱 저장소 병합 | T06, T10, T17, T19, T22 |
| GitHub | 봇 저장소 둘 생성(D-13): `ukyi-app/homelab-bot`(public. 내용을 넣기 전에 결정 5와 같은 하드닝, 설계 C.8)과 `ukyi-app/homelab-bot-ops`(private, 운영 산출물), 옛 aiops 저장소·`ukyi-homelab-aiops` App과 `mac-uptime-guard` 저장소 삭제(`mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤, D-29), `aiops-autodeploy-canary` private 보관 | T14, T22 |
| GitHub | 리뷰 전용 App 생성·설치(D-16. 선택 저장소, 시험 저장소부터)와 키의 Infisical 등록 | T17 |
| GitHub | 봇 쓰기 App 생성·설치(D-24. Contents write + Pull requests write + Metadata read, webhook 끔, 선택 저장소)와 키의 Infisical 등록 | T19 |
| GitHub | Codex Connector 설치 범위를 선택 저장소로 줄이기(D-16·D-26). 완료(사람 2026-10-18 17:45, [approvals.md](approvals.md)). `repository_selection` = `selected`는 API로 확인했다. 남긴 저장소는 사용자 보고로 public 저장소(`homelab`, `homelab-app-template`, `files`, `homelab-bot`)이고 `homelab-bot-ops`와 private 저장소(제거 예정 `aiops`·`mac-uptime-guard`, 보관 `aiops-autodeploy-canary`)는 뺐다. 저장소 목록은 `read:user` 권한이 없어 API로 확인하지 못했다. T17은 축소가 됐는지 확인만 한다 | T15 (`homelab-bot-ops` 첫 push 전. 2026-10-18 완료) |
| GitHub | `files`·`homelab-app-template`의 private vulnerability reporting 켜기(D-29 기본 설정. 설계 C.3.9는 결정 5 하드닝이 켰다고 적지만 2026-10-18 실측은 둘 다 `false`, §5.1 결정 5) | T10 (guard 첫 실행 전) |
| Codex 설정 | 봇이 리뷰하는 저장소의 Codex 자동 리뷰를 저장소별 Codex 설정에서 끄기(수동 `@codex review`는 남김, D-16) | T17 (그 저장소에서 봇 리뷰를 켜기 전) |
| Cloudflare | R2 옛 버킷 삭제, 옛 state 객체 이동·삭제, 옛 터널·DNS·WAF·캐시 규칙 삭제(zone과 zone 설정은 남김, D-11), 옛 API 토큰 폐기, 새 토큰 발급, 새 터널·와일드카드 DNS·버킷 `homelab-backups`, zone 설정 9개를 새 Terraform으로 가져오기(D-11) | T06, T08a, T09 |
| Tailscale | tagged 기기와 OAuth 클라이언트 정리, 노드 키 만료 설정, ACL·DNS 설정(D-08: 첫 Terraform apply 전 콘솔 값을 옮겨 새 state에 import, Override 켬, 전역 nameserver를 NUC + AdGuard 공용 DNS 2개로, C-05 Cloudflare 4개 삭제, MagicDNS·HTTPS 켬), 새 OAuth 발급, ACL에 `tag:k8s-go`와 `autogroup:member → tag:k8s-go:80` apply(D-30) | T06, T08a, T08c, T09 |
| Infisical | 가입, 요금제(Free, D-04), identity 4개, 병합 키 Secret Sync·App Connection 설정, 봇 시크릿 등록(runtime-policies·허용 목록 실제 값 포함, `/apps/homelab-bot/`, D-13), `go` 리다이렉터의 tailnet 도메인 키 등록(`homelab`/prod와 `homelab-dev`/dev의 `/platform/go`, D-30) | T08c, T09, T10, T16b, T17, T18, T19 |
| 외부 감시·알림 | healthchecks.io 옛 체크 일시 정지, 같은 계정에 새 체크 생성, 새 체크 확인 뒤 옛 체크 삭제(D-10), homelab 알림용 Telegram 새 봇 생성(D-10), 옛 Telegram 봇·토큰은 `mac-uptime-guard` 장치를 끈 뒤 삭제 | T06, T08b, T09, T22 |
| NUC | 로컬 자료 보존, 돌아갈 수 없는 지점 확인, k3s 제거·설치, 호스트 정리와 데이터 경로 삭제(OS 유지, `/mnt/bulk`는 비우고 fstab 항목 삭제, D-12) (sudo) | T06, T07 |
| 검증 VM | 시나리오 13용 VM 준비와 VM 전용 자격·R2 버킷(NUC가 아닌 기기 우선, VM 호스트는 tailnet 밖, D-12) | T13 |
| Discord | 봇 전용 개인 서버 생성, Developer Portal 앱·봇 생성과 설정(D-17: `MESSAGE_CONTENT` 켬, Public Bot 끔, 서버 설치만, Interactions Endpoint URL 비움), 봇 토큰 발급과 Infisical 등록, 서버에 봇 추가, 채널 2개와 허용 채널 overwrite. 서버·채널·사용자 ID는 Infisical `/apps/homelab-bot/`에만 둔다 | T15~T16b (늦어도 T16b 실연동 전) |
| 모델 | 봇 전용 ChatGPT 구독 계정 준비(D-14. 사람이 쓰는 계정과 섞지 않음, 학습 사용 설정 확인 §10 7번), 작업자 `auth.json` 첫 시드(Infisical `/apps/homelab-bot/worker`에 등록하고, 작업자는 영속 쓰기 공간에 파일이 없을 때만 복사, 설계 C.8. 개인 `~/.codex*`는 쓰거나 복사하지 않음) | T16b 전(모델을 처음 쓰는 단계 전). 대화 레인이 모델을 써서 T16b가 처음이다, 설계 E9. 이 시점은 에이전트 정리이고 사용자 결정이 아니다 |
| 배포 | 봇 첫 배포 승인 | T16b |
| 봇 시범 운영 | STAGE별 제한 시범 운영 시작 승인(V1 범위 조정 안 3. 예: T16b 뒤 허용 채널 읽기 조회만, T17 뒤 시험 저장소 PR 리뷰만) | T16b~T20 (단계마다) |

---

## 12. 계획 갱신 규칙

- 티켓 상태가 바뀌면 해당 티켓 머리말과 §8.1을 함께 고친다.
- T05가 T06~T13을 설계 문서 E에 맞춰 다시 쪼개고(T08 → T08a·T08b) §8.2 그래프를 갱신했다(2026-10-18). 기준은 설계 E.2·E.3이다.
- T15 마무리에서 T16~T22를 `V1_PLAN.md` 초안에 맞춰 갱신했다(2026-10-18). V1 범위 조정 안 3(확정(사용자 2026-10-18, T15), §5.1)에 따라 T16을 T16a·T16b로 나누고 옛 T16 티켓 파일은 지웠다. 같은 변경에서 §8 표·그래프(T13 → T16 간선은 T16b로)와 티켓 머리말을 고쳤다. STAGE별 시범 운영은 단계마다 사람 승인과 [approvals.md](approvals.md) 기록 뒤에 시작한다.
- 결정이 나면 §5의 해당 줄을 "확정"으로 옮기고 근거(누가, 언제)를 적는다. 같은 변경에서 그 결정 ID로 자리를 둔 문서 위치를 채운다. 봇 저장소 `docs/ai-bot/prompts/` 전체와 플랫폼 프롬프트에서 그 D-ID를 검색해 모두 고친다. 색인이 있는 곳은 `01` §11, `04` §10, 플랫폼 프롬프트 §0·§10-F다. 결정을 정한 티켓이 이 갱신을 맡는다(T15의 D-14~D-17, D-24 포함). 봇 문서의 변경은 봇 저장소 PR로 한다(D-13. 2026-10-18에 옮김).
- 문서를 만들거나 바꾸는 티켓(T01의 SHA 기록, T04, T05, T06, T14, T15 등)은 끝날 때 `rebuild`에 커밋한다. push는 사람 승인 뒤에 한다. T07 뒤에는 PR로 main에 병합하고, 관리자 직접 push는 쓰지 않는다(새 Argo CD가 main을 보면 직접 push가 곧바로 배포된다).
- 문서 경로나 § 번호를 바꾸면 spec, issues, 프롬프트 문서의 복사용 프롬프트, 메모리의 참조를 같은 변경에서 고친다.
- 봇 문서의 참조 규칙(D-13): 봇 문서는 2026-10-18부터 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/prompts/`에 있다. homelab 문서는 봇 문서를 GitHub 주소(main 브랜치)로 가리킨다. 기준 문서(spec.md, platform/design.md, platform/design-prompt.md, issues, approvals.md)는 상대 링크 대신 글로 적는다: "`ukyi-app/homelab` 저장소의 `docs/plans/2026-10-17-homelab-rebuild/<경로>`(T07 전에는 `rebuild` 브랜치, 뒤에는 main)". 처음 한 번은 전체를 쓰고, 같은 문서의 뒤쪽은 "homelab 명세(spec.md)"처럼 줄여도 된다. 이유는 셋이다: 봇 저장소에서는 상대 링크가 깨지고, `rebuild` 브랜치는 T07 squash 병합 때 지워지며, 그 전에는 main에 이 문서가 없다. 봇 문서끼리의 링크는 같은 폴더라 상대 링크로 둔다.
- 새 결정 ID를 만들면(2026-10-18의 D-28, D-29) §5.1과 설계 문서 F에 함께 넣고, 그 ID를 쓰는 티켓 머리말의 선행 결정에 더한다. T15의 작성자 확인 App 예외는 새 ID를 만들지 않고 D-16 안에 두었다(사용자 2026-10-18, T15).
- 2026-10-18 결정(D-04, D-08, D-13 일부, D-28, D-29)은 티켓 밖 대화에서 났다. 그때의 변경은 spec, approvals.md, 티켓, `platform/design.md`(T04 산출물)를 고쳤고 `bot/`과 플랫폼 프롬프트의 자리는 채우지 않았다. 플랫폼 프롬프트 자리는 T05가 2026-10-18에 T05 결정과 함께 채웠다. `bot/` 자리는 T14가 2026-10-18에 채웠다.
- 결정은 났지만 외부 실행이 남은 일(2026-10-18의 `page`·`trip-mate-api` 삭제, 결정 5 하드닝)은 문서에 "실행 대기"로 적고 [approvals.md](approvals.md)에는 결정 줄만 둔다. 실행 줄은 실행한 뒤에 더하고, 같은 변경에서 "실행 대기" 표시를 고친다.
