# T22 기존 앱 저장소 재연결·옛 저장소 정리

- 단계: P5 후속 (P4와 병행)
- 상태: 대기 (T16b. T13 완료 2026-10-29)
- 명세: [../spec.md](../spec.md)
- Blocked by: T13, T16b (봇 첫 배포 증거)
- 선행 결정: D-10 (확정(사용자 2026-10-18, T05): 옛 Telegram 봇·토큰은 `mac-uptime-guard`를 처리하는 이 티켓까지 둔다), D-13 (확정(사용자 2026-10-18). 이 티켓에 걸리는 것은 옛 aiops 저장소·App 제거), D-18 (의존성 업데이트 방식. 확정(사용자 2026-10-18, T05): 호스팅형 Renovate App 저장소별 설치, 자동 병합 모두 끔), D-21 (확정(사용자 2026-10-18, T05): `homelab-app-template` 재사용, 내용 교체는 T10), D-28 (확정(사용자 2026-10-18): 보호 설정 대조), D-29 (확정(사용자 2026-10-18): 앱 저장소 public만, 비앱 저장소는 `aiops`·`mac-uptime-guard` 제거와 `aiops-autodeploy-canary` private 보관, `page`·`trip-mate-api` 삭제. `mac-uptime-guard` 제거는 사용자 2026-10-18 17:46)
- 연결 AC: AC-P14
- 수행: 에이전트 + 사람 (재연결 확인, 병합, `mac-uptime-guard` 장치 끄기, 저장소 삭제·보관, App 정리)

## 목표

남은 앱 저장소 `files`를 새 CI/CD 흐름으로 다시 배포하고, `homelab-app-template`이 새 구조를 따르는지 확인한다. 옛 `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App, `mac-uptime-guard` 저장소를 삭제하고(`mac-uptime-guard`는 장치를 끄고 옛 Telegram 봇 토큰을 폐기한 뒤), `aiops-autodeploy-canary`는 공개하지 않고 private로 보관한다.

## 배경

- `page`와 `trip-mate-api`는 쓰지 않으므로 저장소와 GHCR 패키지를 삭제했다(2026-10-18 결정·실행, D-29). 이 티켓의 대상이 아니다. 두 앱의 옛 자격은 T06 자격 폐기 표에서 폐기한다.
- `files`와 `aiops-autodeploy-canary`는 `ukyi-app/homelab/.github/workflows/reusable-app-build.yaml@main`을 호출한다(2026-10-17 실측. 삭제할 `page`·`trip-mate-api`도 호출했다).
- `homelab-app-template`은 두 경로로 의존한다. 자기 CI(`template-ci.yaml`)가 매주 homelab main의 `tools/app-config-schema.json`을 받아 오고, scaffold가 새 앱 저장소에 reusable@main 호출을 심는다.
- `aiops`에는 의존이 없다.
- main을 교체하면(T07) reusable 호출과 스키마 가져오기가 모두 깨진다. `homelab-app-template`의 내용 교체는 T10(D-21)이 한다. `aiops-autodeploy-canary`는 private로 보관한다(D-29).
- 옛 homelab Actions가 꺼진 뒤(C-06) 다른 저장소의 Renovate도 멈췄다. 다른 저장소에 열린 renovate PR은 29개다(`page` 10, `trip-mate-api` 10, `homelab-app-template` 5, `aiops-autodeploy-canary` 4. 2026-10-17 실측, D-18). `page`·`trip-mate-api`를 지우면 9개(`homelab-app-template` 5, `aiops-autodeploy-canary` 4)가 남는다.
- 옛 SealedSecrets 사본이 저장소에 남아 있다(2026-10-17 `gh api repos/ukyi-app/<repo>/git/trees/main?recursive=1`로 경로 확인). 봉인본 `deploy/*-secrets.sealed.yaml`은 `page`, `trip-mate-api`에 있고 두 저장소와 함께 지워진다. 공개 인증서 `tools/sealed-secrets-cert.pem`과 `tools/seal-secret.mts`는 `aiops-autodeploy-canary`에 있고(삭제할 두 저장소에도 있다), `homelab-app-template`에는 `scaffold/common/tools/` 아래에 있다. 봉인 키는 T06에서 k3s와 함께 사라지므로 새 구조에서는 쓸 수 없다.
- 앱 저장소 main 보호: 2026-10-17에는 `files`, `homelab-app-template`(public)에 보호도 ruleset도 없었고, org 전체에 쓰기 권한이 있는 Codex Connector가 main에 직접 쓸 수 있었다(명세 §4.5). 결정 5(명세 §5.1)로 2026-10-18에 두 저장소에 `CODEOWNERS`와 `app-main` ruleset을 걸었다. `aiops-autodeploy-canary`는 private라 Free에서 보호할 수 없고, 앱이 아니므로 공개하지 않는다(D-29).

## 순서

봇이 새 플랫폼의 첫 실제 앱이므로(D-01, 확정) 실제 배포는 봇의 첫 배포 뒤, 곧 [T16b](T16b-bot-foundation-deploy.md)의 배포 증거가 나온 뒤에 한다. 재연결 확인과 워크플로 수정 준비는 T13 뒤 바로 해도 된다.

## 할 일

1. `files`를 재연결할지 사용자가 확인한다. 남은 재연결 후보는 `files`뿐이다. files 데이터는 폐기됐다 (C-03).
2. 재연결하면 옛 워크플로 호출을 새 공통 워크플로로 바꾸고(옛 SealedSecrets 산출물이 있으면 함께 지운다) CLI로 등록한다. 결정 5로 건 `CODEOWNERS`·`app-main`이 그대로인지 `homelab github verify`(D-28)로 대조한다.
3. `homelab-app-template`이 T10에서 바뀐 새 구조(main 의존과 SealedSecrets 사본 없음, 공통 워크플로 태그 호출)를 따르는지 확인한다.
4. 열린 renovate PR(`homelab-app-template` 5, `aiops-autodeploy-canary` 4)은 D-18 결정에 따라 닫거나 새 방식으로 다시 연다. 옛 봉인본을 건드리는 PR은 병합하지 않는다.
5. 옛 `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App을 삭제한다(D-13 확정). T06에서 넘겨받은 일이다. App 키 폐기(T06 자격 폐기 표의 `보류(D-13, T22)` 줄)를 함께 닫는다. 삭제는 되돌릴 수 없다. 옛 AIOps를 교훈 자료로 읽는 T15는 이 티켓의 선행(T16b)보다 앞이다. **2026-10-19 실제:** App은 T06 할 일 5.7에서 사용자 결정으로 먼저 지웠고 App 키 줄도 닫혔다(approvals). 이 티켓은 `aiops` 저장소만 지운다.
6. `aiops-autodeploy-canary`는 공개하지 않고 private로 보관한다. 삭제해도 된다(D-29).
7. `mac-uptime-guard`(private, 옛 맥 미니용)는 제거한다(D-29. 사용자 2026-10-18 17:46, 그 전에는 private 보관이었다). 이 저장소는 옛 Telegram 봇 토큰을 쓴다. 아래 순서로 한다.
   1. 장치 쪽 `mac-uptime-guard`를 끈다.
   2. 옛 Telegram 봇 토큰을 폐기하고 옛 봇을 삭제한다. 이것으로 T06 자격 폐기 표의 `보류(D-10, T22)` 줄을 닫는다(설계 E10, D-10).
   3. `mac-uptime-guard` 저장소를 삭제한다. 삭제는 되돌릴 수 없다.

## 제약

- 한 앱에 옛 이미지 갱신 자동화(옛 공통 워크플로 호출)와 새 공통 워크플로를 동시에 두지 않는다. 근거는 [플랫폼 프롬프트](../platform/design-prompt.md) §5의 "앱별 이미지 변경의 단일 갱신 주체"다.
- 저장소 삭제·보관과 App 정리는 매번 사람 승인으로 하고, [../approvals.md](../approvals.md)에 기록한다 (명세 §11). 저장소·App 삭제는 되돌릴 수 없다.
- 앱이 아닌 저장소는 공개하지 않는다(D-29).

## 완료 조건

- `files`를 재연결했으면 시나리오 1(첫 배포)을 통과하고, `homelab github verify`가 차이 없음이다(`CODEOWNERS` 존재, `codeowners/errors` 빈 결과, code owner 리뷰·승인 무효화 규칙 포함). 재연결하지 않기로 했으면 그 결정과 이유가 기록돼 있다.
- 할 일 5~7의 저장소와 App마다 처리(삭제, private 보관, 유지와 이유)가 실행됐고, approvals.md에 승인 기록이 있다.
- `aiops`와 `mac-uptime-guard` 저장소가 404이고, `aiops-autodeploy-canary`는 private다(지웠으면 404).
- T06 자격 폐기 표의 옛 Telegram 봇 토큰 줄(`보류(D-10, T22)`)이 닫혔다(`mac-uptime-guard` 장치를 끈 뒤 토큰 폐기와 옛 봇 삭제).

## 검증

- 앱별 배포 결과와 실행 확인 기록.
- `gh api repos/ukyi-app/<repo>`로 삭제(404), `archived`, `visibility`(`private`)를 다시 조회하고, `gh api orgs/ukyi-app/installations`로 App 설치 목록을 다시 조회해 approvals.md와 대조한다.
