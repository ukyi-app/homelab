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
4. 공통 `.github/actions/telegram-notify/`와 위임 통지에서 비민감 사건 artifact를 만든다.
   NUC pull은 workflow 신원·event·실행 revision·원본 run을 검증한다. 성공 run도 조회하며,
   fork PR이 만든 임의 artifact를 신뢰된 main 생산자 사건으로 받아들이지 않는다.
5. healthchecks read-only API의 상태·전이 이력을 cursor로 수집한다. 각 생산자의 마지막
   성공 수집·지연·누락 범위를 기록하고 알림 경로 실패가 모델 실행을 무한 유발하지 않게 한다.

내부 포트·인증·NetworkPolicy는 실제 호스트 포트 규약과 CIDR을 대조해 정한다. 기존 통지
함수에서 추가 전송이 실패해도 원래 통지의 시도와 종료 의미를 보존한다. 외부 공개 수신 endpoint는
이 수집 구조의 요구 사항이 아니다.

## 완료 증거

생산자별 payload fixture와 실제 임시 수신함을 연결해 firing/resolved/경고/반복을 검증한다.
ArgoCD Healthy+Synced 상태의 hook 실패, CNPG 직접 실패, GHA success+warning을 필수로
포함한다. 추가 송신 실패가 기존 Telegram 경로를 막지 않는 회귀 검사를 둔다. 실제 외부
자격이 필요한 전송 시험은 05번에서 수행하고 여기의 fixture 통과와 구분한다.

## Comments

- 2026-09-12: 첫 파일럿부터 모든 장애 알림이라는 Q5를 유지한다.
