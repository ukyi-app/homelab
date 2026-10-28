# 홈랩 신규 구축 + AI 봇: 문서 지도

이 폴더 하나에 새 홈랩과 AI 봇의 계획, 에이전트용 프롬프트, 티켓이 모두 있다.

## 무엇이 어디 있나

| 경로 | 무엇 | 기준이 되는 것 |
|---|---|---|
| [spec.md](spec.md) | 전체 계획 | 현재 상태, 결정(C-xx와 §5.1로 옮긴 D-xx는 확정, §5.2·§5.3의 D-xx는 미정), 단계 순서, 인수 조건, 티켓 그래프 |
| [issues/](issues/) | 티켓 T01~T23, 26개(T08은 T05 재분해로 [T08a](issues/T08a-network.md)·[T08b](issues/T08b-observability.md)로 나뉘고 2026-10-20 D-30으로 [T08c](issues/T08c-internal-short-links.md)가 더해짐, T16은 T15의 V1 범위 조정으로 [T16a](issues/T16a-bot-foundation-local.md)·[T16b](issues/T16b-bot-foundation-deploy.md)로 나뉨. 2026-10-29 T13 후속으로 [T23](issues/T23-platform-followups.md)이 더해짐) | 각 작업의 범위, 선행 관계, 완료 조건. 목록과 상태는 [spec.md](spec.md) §8.1 |
| [approvals.md](approvals.md) | 외부 변경 승인 기록 | 계정·App·삭제·배포·병합·공개 같은 외부 변경의 승인과 그 전제가 되는 사용자 결정 (AC-X2) |
| [platform/design-prompt.md](platform/design-prompt.md) | 플랫폼 설계 프롬프트 (T04가 실행) | 플랫폼 설계 지시, 검증 시나리오 1~17 |
| [platform/design.md](platform/design.md) | 플랫폼 설계 결과 (T04 산출물, T05 결정 반영) | 새 플랫폼의 실제 구성, 구축 단계(E절)와 티켓 대응 |
| [platform/verification.md](platform/verification.md) | 플랫폼 검증 결과표 (T13 산출물) | 설계 G 시나리오 1~17과 봇 자리(AC-P12·AC-P8·AC-P11)의 실행 결과·판정·증거 |
| [00-start.md](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/00-start.md) | 봇 시작점 (`00`) | 제품 정의, V1 필수 기능, 보안 경계, 공통 규칙 |
| [01-v1-build.md](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/01-v1-build.md) | 봇 V1 (`01`) | STAGE 7개, F01~F09, R01~R18 |
| [02-v2-v3.md](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/02-v2-v3.md) | 봇 V2·V3 (`02`) | V2-01~V2-12, V3-01~V3-09 |
| [03-v4-v5.md](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/03-v4-v5.md) | 봇 V4·V5 (`03`) | V4-01~V4-07, V5-01~V5-06 |
| [04-audit-handoff.md](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/04-audit-handoff.md) | 감사·인수인계 (`04`) | 수용 시험 30개, HANDOFF 양식, V1 판정 |

두 문서가 어긋날 때 어느 쪽을 따를지는 [spec.md](spec.md) §4.1 "역할 규칙"에 있다.

## 읽는 순서

- **사람:** spec.md §1 → §5 결정 → §8 티켓 목록.
- **플랫폼 설계 에이전트 (T04):** platform/design-prompt.md 머리말이 함께 읽을 곳을 알려 준다.
- **플랫폼 구축 에이전트 (T06~T13):** 해당 티켓 → platform/design.md E.1의 같은 단계 표(E1~E8) → 티켓이 가리키는 설계 절.
- **봇 에이전트:** T15(DISCOVERY)는 `00-start.md` §2의 복사용 프롬프트, T16a~T20은 `01-v1-build.md` §0의 프롬프트(STAGE 지정. T16a·T16b는 둘 다 `STAGE=FOUNDATION`), T21(감사)은 `04-audit-handoff.md` §1의 감사 프롬프트에서 시작한다. 봇 문서는 2026-10-18부터 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/prompts/`에 있다(D-13).

## 고칠 때

문서 경로, § 번호, 결정 상태를 바꿀 때의 규칙은 [spec.md](spec.md) §12에 있다.
