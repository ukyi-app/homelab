# C01 동료 기능 스위치

- 단계: 1 기반
- 상태: integrated (봇 #111 병합 `bfdb5d9`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.9, §5 AC-23 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: 없음
- 연결 AC: AC-23(배선)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유: 소유 `src/policy.ts`(정책 입력 스키마 `PolicyFields`·`RuntimePolicyInputSchema`에 스위치 칸), `src/config.ts`(`PublisherConfig`로 스위치 값 노출), `docs/ai-bot/config/runtime-policy.example.json`(예시 칸), 시험 `test/publisher-policy.test.ts`·`test/publisher-config.test.ts`. 봇 `docs/ai-bot/VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만(자기 절).
- 설계 계약:
  - `src/policy.ts`, `src/config.ts`: ARCHITECTURE §11 "저장·권한·게시"의 "runtime policy는 env `RUNTIME_POLICIES`를 기동 때 한 번 읽는다(D1)" 문단, §5 "자격 배치" 표의 `RUNTIME_POLICIES` 행 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 9 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `docs/ai-bot/config/runtime-policy.example.json`: 같은 §5 표 `RUNTIME_POLICIES` 행("모양은 이 예시").

## 목표

owner가 Infisical의 `RUNTIME_POLICIES`에 동료 기능 스위치를 켜고 봇을 다시 띄우면 뒤 티켓의 말로 실행하는 기능과 '/' 이름 없는 고정 문구 판이 열릴 수 있는 배선이 생긴다. 이 티켓만으로는 동작이 바뀌지 않는다(prefactor). 병합하면 바로 운영에 나가지만, 값이 없으면 꺼짐이라 운영 동작은 그대로다.

## 할 일

1. 런타임 정책 입력에 동료 기능 스위치 칸을 더한다(`src/policy.ts`). 없으면 꺼짐, 참·거짓만 받는다. 기존 정책처럼 기동 때 한 번 읽고 얼린다.
2. 값이 잘못되면 기존 정책 오류 규칙을 따른다: 기동하지 않고, 오류에는 알려진 필드 경로만 남기고 값은 남기지 않는다(`loadRuntimePolicy`의 `runtime_policies_invalid`).
3. 게시 서버 설정(`src/config.ts` `PublisherConfig`)에서 스위치 값을 한 곳으로 읽을 수 있게 노출한다. 뒤 티켓(C09·C10·C11의 surface 선택·C13·C15·C16·C17·C18)은 이 값만 읽는다.
4. 예시 파일(`docs/ai-bot/config/runtime-policy.example.json`)에 꺼진 값으로 칸을 보인다.
5. 시험: 칸 없음(꺼짐), 꺼짐, 켜짐, 잘못된 값(문자열·숫자 등, 기동 오류이고 오류 문자열에 값이 없음).
6. 기록: 봇 `ARCHITECTURE.md` §5 표 `RUNTIME_POLICIES` 행에 스위치 한 줄, `VERIFICATION.md`에 "C01 동료 기능 스위치" 절, `DECISIONS.md` "동료 봇 전환" 9에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C01 상태 줄 갱신.

## 완료 조건

- [x] 스위치 칸이 없거나 꺼진 정책으로 기동하면 설정의 스위치 값이 꺼짐이고, 켜진 정책이면 켜짐이다.
- [x] 잘못된 값이면 게시 서버가 기동하지 않고 오류에 필드 경로만 있다.
- [x] 이 티켓의 diff만으로 바뀐 Discord·작업자 동작이 0이다(기존 시험 통과).

## 검증

- 경계: S1(게시 서버 설정 로드). 앞선 시험 예: `publisher-policy`, `publisher-config`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`publisher-policy`, `publisher-config`). 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 스위치 값 읽기 오류와 잘못된 값의 조용한 꺼짐이다. 두 상태의 실제 동작 차이(AC-23의 버튼·문구)는 그 기능을 만드는 뒤 티켓의 두 상태 시험이 잡는다. 못 잡는 범위: 없음(설정 분기).

## 결과

- 봇 PR #111(`feat/colleague-c01-switch`, 결과 head `fffae32`), 병합 `bfdb5d9`(2026-11-10). 구현: `src/policy.ts` `PolicyFields.colleagueEnabled`(참·거짓만), `src/config.ts` `PublisherConfig.colleagueEnabled`(`policy.colleagueEnabled === true`, 선택 칸이라 없으면 꺼짐), 예시 정책 칸 `false`. 뒤 티켓은 `config.colleagueEnabled === true`로만 읽는다.
- 완료 조건 근거: 시험 `C01 동료 기능 스위치: 정책에 칸이 없거나 false면 꺼짐, true면 켜짐`, `…잘못된 값이면 게시 서버가 기동하지 않고 오류에는 필드 경로만 있음(조용히 꺼지지 않음)`(값 `"true"`·비밀처럼 보이는 문자열·`1`·`null` 등 8가지 → `runtime_policies_invalid: colleagueEnabled`). 이 값을 읽는 코드가 없어 동작 변경 0.
- 검사: 작업자 관련 시험 65 통과·0 실패·0 skip(`publisher-policy`·`publisher-config`·`publisher-main`·`github-review-app`). 통합 담당 전체 검사(`fffae32`, node 24.22.0, 실제 PostgreSQL): 2162 tests / 2140 pass / 0 fail / 22 skip(SEC02_IMAGE 컨테이너 시험). Codex 코드·보안 지적 없음(`8a9bcb6`, `fffae32`), `build / test` 통과.
- 남은 것: 봇 DECISIONS "동료 봇 전환" 9 대신 파일 끝 "C01 동료 기능 스위치" 절에 구현 위치를 적었다(명세 PR보다 먼저 갈라진 브랜치).
