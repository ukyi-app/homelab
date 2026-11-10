# C22 계정 등록·전환(구독)과 토큰 만료 알림

- 단계: 5 멈춤과 계정
- 상태: 진행 중 (2026-11-11 01:3x 착수, 선행 모두 integrated)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.7 "토큰 만료 알림", §4.8 "계정 등록"·"계정 전환"·"계정 목록"·"D-14 변경", §5 AC-19·AC-21, §8 "`setup-token` 출력 수집"·"약관"·"구독 계정 공유" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C05, C10, C19, C21, C32
- 연결 AC: AC-19, AC-21
- 수행: 에이전트 + 사람(약관 재확인 결과 수용, 실토큰 등록(브라우저 로그인), 운영 전환 1회 승인)
- 저장소·PR: 둘(봇 PR → 봇 이미지 배포 → homelab PR)
- 파일 소유:
  - 봇 관리 진입점(C05가 만든 파일): 계정 기록·목록·전환 뒤 해제 동작을 더하는 자리. C05 소유(README 5절). 이 티켓은 계정 동작만 더한다.
  - 봇 `migrations/`: 순번 공유. 계정 이름·방식·발급일·현재 표시(값 없음).
  - 봇 `src/briefing.ts`: 연결 파일, 소유 C10. 토큰 만료 줄 하나만 더한다.
  - 봇 `src/ops-metrics.ts`: C21이 만든 지금 계정 이름·방식 지표 칸을 채우는 자리. 소유 C21(연결 표에 없는 공유, README 5절에 반영).
  - 봇 `docs/ai-bot/DECISIONS.md`: 약관 재확인 결과 문단(추가만).
  - homelab `cli/src/commands/`의 `homelab bot account add|use|list` 명령 파일과 `cli/src/registry.ts` 등록 줄: 연결 파일(`homelab bot` 명령 묶음), 소유 C05.
  - homelab `cli/src/core/`(가려진 입력, Infisical 쓰기, kubectl exec·annotate 도우미): 기존 도우미(`infisical.ts`의 쓰기, `input.ts`, `kubectl.ts`, `podops.ts`)를 쓰기만 하고, 새 도우미가 필요하면 그 함수만 더한다. 연결 표에 없는 공유 자리다(C05와 겹친다).
  - homelab `cli/test/`: 새 명령 시험.
  - homelab `cli/README.md`, [설계 C.7](../../2026-10-17-homelab-rebuild/platform/design.md)의 명령 표: 새 명령 줄(계획 문서는 rebuild `spec.md` §12 규칙대로 고친다).
  - homelab `docs/runbooks-public/rotate.md` 3e: 소유(연결 파일, 뒤에 C23이 고친다).
- 설계 계약:
  - 봇 관리 진입점·계정 기록: 봇 ARCHITECTURE "6. 보안 경계"의 즉시 철회 경계 문단(C05가 CLI 계약으로 고친 판), "5. 자격 배치 (키 이름만, 값은 Infisical)", "5.1 작업자에 구독 인증 파일이 있는 구조 (D-14·D-15)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 봇 DECISIONS "D-14 봇 모델 계정과 인증"의 "함께 지킬 조건 (결정의 일부)" 조건 2·5와 "변경(사용자 2026-11-09…)" 문단, "동료 봇 전환 (사용자 2026-11-09)" 7·8 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/briefing.ts`: 봇 DECISIONS "T20 기억·삭제 원장·브리핑 (로컬·mock, 2026-10-29)".
  - `src/ops-metrics.ts`: 봇 ARCHITECTURE "13. 개선안 v2 적용"의 "지표 (`/metrics`, DB gauge)".
  - homelab CLI: [설계 C.7 CLI와 운영 경험](../../2026-10-17-homelab-rebuild/platform/design.md)(얇은 CLI, 기본 `plan`·`--apply`, 자체 상태 저장소 없음), `cli/README.md` "동작 규칙"·"명령 더하기", 값 입력 규칙은 `cli/src/commands/secret-set.ts` 머리 주석(값은 stdin·tty, argv·출력·파일에 두지 않음).
  - 자격 반영: homelab [설계 C.8 봇을 위한 여지](../../2026-10-17-homelab-rebuild/platform/design.md), `platform/sandbox/templates/worker-externalsecret.yaml` 머리 주석(실행마다 Secret 파일을 다시 읽음, 재시작 없음), [rotate.md](../../../runbooks-public/rotate.md) 0절·3e.

## 목표

owner가 `homelab bot account add <이름>`으로 구독 계정을 브라우저 로그인만으로 등록하고, `homelab bot account use <이름>`으로 봇이 쓰는 계정을 바꾸며, `homelab bot account list`로 등록된 계정과 지금 계정, 토큰 만료일, 마지막 사용률을 본다. 값은 어디에도 보이지 않는다. 전환하면 대화·리뷰·작업 두 레인이 함께 바뀌고, 작업자 반영을 확인한 뒤 멈춘 일이 이어진다. 구독 토큰 만료 30일 전부터 브리핑이 알린다. 봇은 스스로 계정을 바꾸지 않는다.

봇 PR(계정 기록·브리핑 줄)은 병합하면 바로 운영에 나가지만 등록된 계정이 없으면 보이는 변화가 없다. homelab CLI는 owner가 실행할 때만 동작한다.

## 할 일

1. 시작할 때 Anthropic 새 이용 정책(2026-11-12 시행)과 에이전트 사용 안내("보호 장치를 피하려는 여러 계정" 금지)를 다시 읽고 결과를 봇 `DECISIONS.md`에 적는다. 다른 구독 계정으로 바꾸는 것이 금지로 읽히면 구현을 멈추고 owner에게 알린다(같은 계정 안의 토큰 교체와 API 크레딧 방식은 따로 판단해 적는다).
2. 봇 쪽: 관리 진입점에 계정 기록 동작을 더한다(이름, 방식(구독), 발급일, 현재 표시. 값은 없음). 마이그레이션을 더한다(순번 공유). 감사 기록 행위자는 CLI다. 목록 동작은 이름·방식·현재 계정·만료일(발급일 + 1년)·C19가 기록한 마지막 사용률과 풀리는 시각을 돌려준다.
3. 봇 쪽: 브리핑에 "Claude 토큰(<계정 이름>)이 N일 뒤 만료돼요" 줄을 더한다. 만료 30일 전부터만, 등록된 구독 토큰마다. C21 지표의 지금 계정 이름·방식 칸을 채운다.
4. homelab `account add <이름>`(구독): CLI가 `claude setup-token`을 띄우고 owner는 브라우저 로그인만 한다. 레인이 둘이라(대화+리뷰, 작업) 두 번 받는다. 출력에서 토큰을 자동으로 집을 수 있는지는 구현 때 확인한다(미확인). 안 되면 화면에 보이지 않는 입력으로 받는다. `claude` 실행 파일이 CLI를 돌리는 기기에 있어야 한다는 전제를 명령 안내에 적는다.
5. 값은 Infisical의 작업자가 읽지 않는 폴더에 둔다. sandbox store(`infisical-sandbox`)는 `/apps/homelab-bot/worker`만 읽으므로 그 밖이어야 하고, 봇 앱 ExternalSecret이 그 폴더를 읽지 않는지도 확인한다(재귀로 읽는지 미확인). 쓰기는 `homelab secret set`의 입력 경로(stdin·tty, 해시 앞부분으로만 확인)를 재사용하고 argv·출력·파일에 남기지 않는다. 등록이 끝나면 관리 진입점(kubectl exec)으로 봇 DB에 계정 정보를 적는다.
6. homelab `account use <이름>`: (1) 고른 계정의 두 레인 값을 작업자 키(`/apps/homelab-bot/worker`의 `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_TASK`)로 옮긴다. 한 레인만 바뀐 채 멈추지 않게, 둘 다 쓴 뒤에만 다음으로 간다. (2) 두 ExternalSecret을 즉시 동기화한다. (3) Secret 해시가 Infisical 해시와 같아진 뒤, 두 작업자 볼륨의 파일 지문이 같아질 때까지 기다린다(rotate.md 3e 4단계의 지문 확인. `worker-task`의 exec가 정리 sweep에 죽을 수 있는 함정을 다룬다). (4) 관리 진입점 해제로 멈춘 일을 재개하고 봇 DB의 현재 표시를 바꾼다. 반영 전에는 해제하지 않는다. 대략 2분 안에 끝나는지 본다. 이미 돌던 실행은 옛 자격으로 끝난다.
7. homelab `account list`: 봇 DB의 값 아닌 정보만 보인다. 값과 크레딧 잔액은 보이지 않는다.
8. CLI 시험(가짜 infisical·kubectl): 값이 argv·출력·파일에 없음, 두 레인 모두 바뀜, 반영 전 해제 없음, 목록에 값 없음, 잘못된 파드·네임스페이스 대상 거부.
9. `rotate.md` 3e를 CLI 절차로 고친다(drain → `account add`/`account use` → 반영 확인 → 해제, 옛 토큰 철회). `cli/README.md`와 설계 C.7 명령 표에 새 명령 줄을 더한다.
10. 사람 단계: owner가 실토큰으로 계정 하나를 등록하고, 승인 뒤 운영에서 전환을 1회 한다. 결과를 homelab [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)와 봇 `VERIFICATION.md`에 적는다. 봇 구독 계정이 owner 개인 사용과 같은 계정인지(명세 8절, 미확인)도 이때 owner에게 물어 적는다.
11. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C22 계정 등록·전환" 절, `docs/ai-bot/DECISIONS.md`에 약관 재확인 결과와 계정 폴더·전환 순서 문단을 더한다. 이 계획 폴더 `README.md`의 C22 상태 줄을 갱신한다.

## 완료 조건

- [ ] 약관 재확인 결과가 봇 `DECISIONS.md`에 있고, 금지로 읽히지 않았다(읽혔다면 owner 결정이 적혀 있다).
- [ ] `account add`가 구독 토큰(레인 둘)을 받고 값을 argv·출력·파일에 남기지 않는다.
- [ ] `account use`가 두 레인 자격을 바꾸고, 작업자 반영을 지문으로 확인한 뒤 멈춘 일을 해제한다(대략 2분 안).
- [ ] `account list`가 이름·방식·현재 계정·만료일·마지막 사용률을 보이고 값은 보이지 않는다.
- [ ] 등록된 구독 토큰의 만료 30일 전부터 브리핑에 계정 이름과 남은 날수가 나오고, 30일보다 많이 남았으면 나오지 않는다.
- [ ] `rotate.md` 3e가 CLI 절차다.

## 검증

- 경계: S3(CLI, 가짜 infisical·kubectl, 입력 경로 시험), S1(브리핑 조립과 계정 기록, 가짜 시계), S2(작업자가 바뀐 자격 파일을 다음 실행에서 읽음, 기존 시험 확인). 앞선 예: homelab `cli/test`의 `secret set` 시험, 봇 `memory-briefing` 시험.
- 명령: 봇 `npm run check`, `npm test`(바뀐 파일 관련 시험만). homelab `pre-commit run --all-files`, `bun run ci`.
- 잡는 실패: 값 노출, 한 레인만 바뀌는 것, 반영 전 해제, 목록의 값 노출, 날수 계산 오류, 계정 누락. 못 잡는 범위: `claude setup-token` 출력 자동 수집의 실제 동작(구현 때 확인), 실제 ESO·kubelet 반영 시간(S5, C24), 발급일을 CLI 밖에서 바꾼 경우(CLI로 등록한 토큰만 안다).

## 결과

- 봇 PR #142, 병합 `8437d95`(2026-11-11): migration 028 `model_accounts`(이름·방식·발급일·지금 계정·`switched_at`, 값 칸 없음), `src/model-accounts.ts`, 관리 진입점 `account record|use|list`(결과 이름 `recorded`·`accounts`·`switched`·`unknown_account`), 브리핑 토큰 만료 줄, `homelab_bot_model_account{account,method}`. 전체 검사(결과 `80a1325`, `FPB_TEST_TIMEOUT=2400 .fpb/test.sh wt-c22 c22-full --pg -- full`): 2,579개 중 통과 2,557, 실패 0, skip 22. `build / test` 통과.
- homelab PR #1252(head `18a2e50`, owner 검토 대기): `homelab bot account add|use|list`, `rotate.md` 3e CLI 절차, `cli/README.md`·설계 C.7 표. `bun run test:cli` 786개 통과, `bun run ci` 30단계 통과, `ci` 통과. Codex 1차 P2 1(로그인 출력과 토큰이 결과 stdout에 섞임) 수정, 재리뷰 지적 없음.
- 약관 재확인(할 일 1): 봇 `DECISIONS.md` "C22 약관 재확인". 2026-11-12 시행 이용 정책에서 다른 구독 계정으로 바꾸는 것은 금지로 확정되지 않았으나 애매하다(한도를 "제품 내 제한 사항"으로 보면 우회로 읽힐 수 있음). 같은 계정 토큰 교체와 API 크레딧 방식은 허용으로 읽었다. **owner 판단 대기.** 금지로 정하면 경보 문구(homelab `vmalert/rules/bot.yaml`)의 할 일 3과 명세 §4.7을 고치는 후속을 연다.
- 리뷰: 봇 Codex 1차 P2 3(잠금 순서, 전환 전 실행의 한도 관측 분리, 돌아온 계정의 마지막 관측 표시) 수정. 2차 P2 1(관측 확인과 쓰기 사이의 전환 경합)은 C23 할 일 4a로 넘김.
- 구현 선택: 계정을 바꾸면 한도 관측과 리뷰 미루기 기한을 옛 계정 행으로 옮기고 비운다. 전환보다 먼저 시작한 실행의 관측은 적지 않는다(전환 직후 잠깐 새 계정의 경고를 놓칠 수 있음). 목록에는 종류별 멈춘 작업 수만 보이고 작업 ID는 없다. 결제 멈춤은 `account use`(같은 계정도 됨)가 푼다. `--by api`는 사용법 오류 64(C23). `claude setup-token` 출력 자동 수집은 하지 않고 가려진 입력으로 받는다(토큰이 owner 터미널 스크롤에 한 번 남는다). stderr가 터미널이 아니면 로그인을 띄우지 않고 종료 1로 끝난다.
- 남은 것: homelab #1252 owner 검토·병합, 봇 배포 확인, 약관 판단, 사람 단계(할 일 10: 실토큰 등록, 운영 전환 1회, 봇 구독 계정이 owner 개인 계정과 같은지 확인). 완료 조건의 운영 항목(`account use` 2분, 지문 확인)은 사람 단계와 C24 S5에서 본다.
- 남은 위험: 계정 폴더 `/bot-accounts`는 복구 자산의 손 Secret 지도에 없다(재해 뒤 재등록). 운영 RBAC로 `sandbox` 작업자 exec가 되는지는 미확인(S5).
