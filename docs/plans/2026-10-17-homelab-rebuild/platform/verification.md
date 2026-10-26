# 플랫폼 검증 결과표

T13(테스트 앱 통합 검증)의 결과표다. 기준은 [design.md](design.md) G절의 시나리오 1~17과 C.8의 봇 자리 표다. 봇·병합·알림 자리의 최종 확인은 [T13](../issues/T13-platform-integration.md) 할 일 4다.

표의 빈칸은 아직 실행하지 않았다는 뜻이다. T13이 실행하면서 실행 명령, 시각, 판정, 증거 위치, 메모를 채운다. 결과표는 PR로 main에 병합한다(AC-X1).

## 판정 값

| 판정 | 뜻 |
|---|---|
| 실제 검증 완료 | 실행했고 기대 결과를 만족했다. 실행 명령·시각·증거 위치가 있다. |
| 설계상 기대 | 실행하지 않았다. 설계 G의 기대 결과만 있고 증거는 없다. |
| 실패 | 실행했고 기대 결과를 만족하지 못했다. 수정 티켓을 만들거나 한계 승인을 받는다(T13 완료 조건). |
| 승인된 한계 | 실행했고 기대에 못 미치지만 사용자가 승인했다. 승인 기록은 [approvals.md](../approvals.md)에 있고, 메모에 완화책을 적는다. 시나리오 1·14에 선례가 있다. |

## 증거

- 공개해도 되는 증거는 이 문서와 T13 PR에 적는다: 명령과 출력 요약, PR·커밋 SHA, HTTP 응답 코드, 시크릿의 `sha256`.
- 공개하면 안 되는 증거는 저장소 밖에 두고 위치만 적는다(D-23). tailnet 이름, Tailscale IP, 개인 이메일, 계정 ID, 시크릿 값, 복구 자산 목록, 내부 경로가 그렇다. 증거 위치 칸에는 `저장소 밖: 개인 보관`처럼 종류만 적고 실제 경로·호스트 이름·계정은 쓰지 않는다.
- 시크릿은 값 대신 `sha256`만 비교하고 값·토큰을 출력하지 않는다(설계 G 공통 전제).

## 환경 값

| 값 | 뜻 |
|---|---|
| 운영 | 운영 클러스터(NUC)와 그 주변(GitHub·Infisical·R2). |
| VM | 시나리오 13의 VM 클러스터. VM 호스트는 tailnet 밖이다(D-12). |
| 현장 | NUC 앞에서 하는 물리 작업(전원·네트워크 차단). |
| 기기 | 판정에 사용자 기기에서의 확인이 필요한 경우: Telegram 수신, tailnet·LAN 질의, `vm-go` 접속. |

## 시나리오 1~17

기대 결과와 명령 수준 검증 방법은 [design.md](design.md) G절 표에 있다. 여기에는 시나리오 이름과 환경만 옮겼다.

| # | 시나리오 | 환경 | 실행 명령 | 시각(KST) | 판정 | 증거 위치 | 메모 |
|---|---|---|---|---|---|---|---|
| 1 | DB 없는 작은 웹앱을 새 저장소에서 처음 배포 | 운영·기기 | | | | | |
| 2 | 기존 앱에 PostgreSQL 추가 | 운영 | | | | | |
| 3 | 기존 앱에 캐시용 Valkey 추가 | 운영 | | | | | |
| 4 | 영속 작업용 Valkey의 백업과 복원 | 운영 | | | | | |
| 5 | 같은 등록 명령을 재실행해도 데이터·비밀번호 불변 | 운영 | | | | | |
| 6 | 필수 시크릿이 없으면 잘못된 값 적용 없이 명확히 실패 | 운영·기기 | | | | | |
| 7 | Infisical 장애·인증 만료 중 기존 서비스와 신규 배포 | 운영·기기 | | | | | |
| 8 | DB 비밀번호 변경 후 실제 앱 접속까지 확인 | 운영 | | | | | |
| 9 | 앱을 삭제해도 DB·영속 데이터 보존 | 운영 | | | | | |
| 10 | 공유 PostgreSQL에서 특정 앱만 복원 | 운영 | | | | | |
| 11 | 빌드 완료 순서가 바뀌어도 과거 이미지로 배포되지 않음 | 운영 | | | | | |
| 12 | NUC 재부팅 후 의존 서비스 준비 | 운영·기기 | | | | | |
| 13 | 빈 NUC에서 문서 절차만으로 재구축 후 테스트 앱 배포 | VM·기기 | | | | | |
| 14 | AdGuard가 멈췄을 때 LAN·Tailscale 기기의 이름 해석 | 운영·기기 | | | | | |
| 15 | 자동 병합 조건 밖의 PR은 사람 승인 뒤에만 병합 | 운영 | | | | | |
| 16 | 봇이 없거나 멈춘 상태에서 테스트 경보가 비AI 경로로 도착 | 운영·기기 | | | | | |
| 17 | NUC 전체가 멈추면 외부 생존 감시가 감지해 알림 | 현장·기기 | | | | | |

## 봇 자리 확인

AC-P12 다섯 자리와 AC-P8·AC-P11 자리다. 자리·준비 티켓·확인 방법은 spec §4.4, T13 할 일 4, 설계 C.8·E.3을 따른다. 여기서는 자리의 존재·경로·권한을 보고, 실사용 검증은 T16b·T17이 한다. 확인 명령의 전문은 설계 C.8 표에 있다.

### AC-P12

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 |
|---|---|---|---|
| 공개 HTTPS webhook 수신 경로 | T08a | C.8 `공개 HTTPS webhook 수신 경로` 행: `https://hooks.ukyi.app/github`의 GET·다른 경로 POST·서명이 틀린 POST 응답 코드, 시험 webhook ping의 Recent Deliveries 200. | |
| 읽기 전용 접근(Kubernetes·관측·Argo CD) | T08b | C.8 `읽기 전용 접근` 행: SA `bot-reader`로 `kubectl auth can-i` yes·no, `argocd admin settings rbac can` get Yes·sync No, Grafana 토큰으로 `GET /api/search` 200·`POST /api/dashboards/db` 403. | |
| 경보 외부 수신자 | T08b | C.8 `경보 외부 수신자` 행: `amtool config routes test`에 `bot` 포함, `amtool alert add`의 수신 로그와 `alertmanager_notifications_total{integration="webhook"}` 증가, Telegram 수신. | |
| 격리 작업 실행 공간 | T08b | C.8 `격리 작업 실행 공간` 행: 작업자 SA 토큰 미마운트·RBAC 없음, `infisical-sandbox` 경로 고정, DNS 없이 `HTTPS_PROXY`만으로 `codeload.github.com` 접근·`github.com` 거부, `CODEX_HOME` 영속 공간이 파드 재생성 뒤 유지. | |
| 리뷰 전용 App 저장소별 설치 구조 | T10 | C.8 `리뷰 전용 GitHub App` 행: 설치 `repository_selection`이 `selected`, 설치 토큰의 `GET /installation/repositories`가 저장소 하나, bypass 목록에 없음, 대상 저장소의 `CODEOWNERS` 오류 0과 code owner 리뷰·승인 무효화 규칙 `true`. | |

### AC-P8

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 |
|---|---|---|---|
| 병합 조건 공개 | T10 | C.8 `병합 조건 공개` 행: 시나리오 15, `homelab github verify` exit 0(guard 통과, plan 무변경). | |
| 봇 변경 PR의 자동 병합 차단 | T10(시험 신원. 실제 신원은 T19) | C.8 `봇 변경 PR 작성 자격` 행과 T13 할 일 5: 시험 App(예: `ukyi-homelab-bot-standin-2`)으로 `bot/x` push 성공, homelab main·`deploy/x`·앱 main push 거부, digest만 바꾼 PR이 `deploy-merge`의 "조건 1 불일치"로 병합되지 않음. 시나리오 15. | |

### AC-P11

| 자리 | 준비 티켓 | 확인 방법(설계 C.8) | 판정 |
|---|---|---|---|
| 비AI 알림 경로 | T08b | C.8 `비AI 알림 경로` 행: 시나리오 16. 봇 없이 Telegram에 2분 안 도착, `alertmanager_notifications_total{integration="telegram"}` 증가, 실패 지표 불변. | |
| 외부 생존 감시 | T08b | C.8 `외부 생존 감시` 행: 시나리오 17. Period+Grace(10분) 뒤 healthchecks.io가 down으로 바꾸고 NUC를 거치지 않는 경로로 알림, 복구 뒤 up. | |
