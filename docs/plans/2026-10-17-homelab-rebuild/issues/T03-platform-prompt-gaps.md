# T03 플랫폼 설계 프롬프트 보강

- 단계: P1 플랫폼 설계
- 상태: 완료 (2026-10-17, 문서 이관 때 반영)
- 명세: [../spec.md](../spec.md) §4.2, §4.4
- Blocked by: 없음
- 연결 AC: AC-P2, AC-P11, AC-P12
- 수행: 에이전트 (문서 작성), 독립 검토 에이전트

## 목표

플랫폼 프롬프트에 봇이 필요로 하는 빈 칸 5개와 옛 함정·교훈 문서를 입력으로 넣는다.

## 결과

옛 `docs/cicd-simplification-prompt.md`를 [../platform/design-prompt.md](../platform/design-prompt.md)로 새로 쓰면서 아래를 모두 넣었다.

1. §2 "봇을 위한 여지": 공개 HTTPS webhook 수신 경로, Alertmanager 외부 webhook 수신자, 격리 작업 실행 공간, 비AI 알림 경로, 외부 생존 감시, Argo CD 배포 상태 읽기.
2. §3 교훈 입력: 옛 `docs/traps.md`, `docs/traps-detail.md`, `docs/decisions/`, `docs/adr/`, `docs/bespoke-component-checklist.md`, `docs/memory-ledger.md`, `docs/runbooks-public/`, `CONTEXT.md`, 옛 AIOps 기록. 완료 기준 범위에 tests/, docs/, .github/actions/, 루트 설정 파일, 호스트 수준 구성을 더했다.
3. §9 시나리오 16(봇 없이 비AI 경보 도착), 17(NUC 전체 중단을 외부에서 감지).
4. §10-F에 D-10, D-11, D-12, D-18, D-20, D-21, D-22.
5. 머리말 금지 목록에 원본의 "DB 변경, 시크릿 변경"과 "옛 클러스터·Argo CD·Cloudflare·Tailscale 설정 변경"을 넣었다.

## 검증

- 명세 §4.2 표의 다섯 칸이 플랫폼 프롬프트 §2·§9에 있는지 대조했다.
- 독립 검토 에이전트가 옛 문서와 줄 단위로 대조했고, 요구 ID·숫자·URL 대조 스크립트에서 빠진 항목이 없었다.
