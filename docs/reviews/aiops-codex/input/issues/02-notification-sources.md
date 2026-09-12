# 02 — 기존 장애·경고 생산자 전체 연결

Status: needs-info
Blocked by: Q13, 01
Design: [알림 수집](../design.md#3-모든-장애-통지의-정의와-수집)

## 결과

Alertmanager만으로 발견할 수 없는 ArgoCD hook 실패, CNPG 직접 실패, 성공한 GHA 안의
경고까지 사건으로 수집한다. AIOps 중단 중에도 기존 Telegram 통지가 작동한다.

## 구현 범위

1. Alertmanager의 firing/resolved 그룹 webhook을 내부 수신 경로에 연결한다.
   Watchdog는 계속 관측 경로 증거로 다루고 매번 AI 사건을 만들지 않는다.
2. ArgoCD의 health-degraded와 sync-failed를 각각 연결한다. 기준 설정은
   `platform/argocd/bootstrap-values.yaml`이며 실제 수렴 설정/SSOT를 구현 전에 다시 확인한다.
3. CNPG `restore-drill-script.sh`와 `ensure-role-password.sh`의 직접 실패 지점을
   공통 사건 계약에 연결한다. KubeJobFailed 배선만으로 완료를 주장하지 않는다.
4. GHA의 기존 통지 생산자와 위임 통지를 열거해 Telegram 조건과 독립된 공통 검사 결과
   작성기에 연결한다. 완료한 정상 검사도 비민감 artifact를 만든다. NUC pull은 workflow
   신원·event·실행 revision·원본 run/attempt와 artifact 소속을 검증하고 fork PR 입력을 거부한다.
5. healthchecks read-only API의 상태·전이 이력을 cursor로 수집한다. 각 생산자의 마지막
   성공 수집·지연·누락 범위를 기록하고 알림 경로 실패가 모델 실행을 무한 유발하지 않게 한다.

내부 포트·인증·NetworkPolicy는 실제 호스트 포트 규약과 CIDR을 대조해 정한다. 기존 통지
함수에서 추가 전송이 실패해도 원래 통지의 시도와 종료 의미를 보존한다. 외부 공개 수신 endpoint는
이 수집 구조의 요구 사항이 아니다.

GHA 결과 계약은 check ID·대상 범위·run ID/attempt·revision·관측 시각·검사 완료 여부와
`healthy|warning|unobservable`을 포함한다. 완료된 검사에서 해당 대상의 경고 부재를 확인한
경우만 healthy다. 일부 실패·DNS transient·미실행/취소는 정상으로 합치지 않는다. upload를
Telegram 조건 안에 넣지 않으며 추가 결과 전송 실패가 기존 통지를 막지 않도록 구성한다.
job skip·취소·runner 손실·artifact 누락/만료는 원본 run과 대조해 관측 불가로 기록한다.
성공 run·무통지·artifact 부재만으로 경고를 해소하지 않는다. 같은 check/대상의 더 최신인
정상 결과는 SHA가 같아도 대기 사건을 해소하고, 이전 attempt/다른 대상 결과는 새 경고를 덮지 않는다.

## 완료 증거

생산자별 payload fixture와 실제 임시 수신함을 연결해 firing/resolved/경고/반복을 검증한다.
ArgoCD Healthy+Synced 상태의 hook 실패, CNPG 직접 실패, GHA success+warning을 필수로
포함한다. 추가 송신 실패가 기존 Telegram 경로를 막지 않는 회귀 검사를 둔다. 실제 외부
자격이 필요한 전송 시험은 05번에서 수행하고 여기의 fixture 통과와 구분한다.

GHA는 resolved fixture를 직접 주입하는 시험만으로 완료하지 않는다. 실제 workflow의 검사
출력→결과 작성 조건→artifact→NUC 수집 경로를 대역 실행한다. tf-reconcile의 같은 SHA에서
경고→owner 로컬 수렴 이후 정상, dns-drift/credential-expiry의 무통지 정상 복귀를 포함한다.
artifact 유실·성공 run의 미실행·DNS transient·일부 대상 실패에서는 해소되지 않아야 한다.
역순 attempt와 다른 대상의 정상 결과도 대조하고, 생산자별 정상/경고/관측 불가 연결 누락을 검사한다.

## Comments

- 2026-09-12: 첫 파일럿부터 모든 장애 알림이라는 Q5를 유지한다.
