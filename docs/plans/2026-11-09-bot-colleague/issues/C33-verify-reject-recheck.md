# C33 시험 거절 뒤 다시 확인(게시 서버 둘 경합)

- 단계: 1 기반
- 상태: integrated (봇 #136 병합 `ef27723`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/ARCHITECTURE.md` "16. T19 CHANGE_PR 계약"의 흐름·전이 표·"끝 상태와 재시작", "16.4 작업 레인 v2: artifact와 무자격 검증 (B1)", "16.5 조립과 꺼짐 배포 (B5)"의 EVENT-02 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 동료 봇 명세의 AC가 아니라 그 전(봇 #85)부터 있던 결함의 수정이다(사용자 2026-11-10 "그래 그렇게 진행해").
- Blocked by: 없음
- 연결 AC: 없음(기존 T19 B5 EVENT-02 "게시 서버 둘이 같은 부모를 동시에 밀어도 모델·시험·PR이 하나다")
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/change-verifier.ts`(`WorkerChangeVerification.run`의 거절 처리)
  - 연결 파일, 소유 C09: 봇 `src/claude-task-bridge.ts`의 `verificationWorker`(verify 전송·재시도 자리만)
  - 시험: `test/change-pg.test.ts`, `test/change-verifier*.test.ts`나 그 경계의 기존 시험, 새 시험
  - 봇 `docs/ai-bot/VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만
  - 고치지 않음: 봇 `src/task-contracts.ts`·`src/worker.ts`의 capability 모양(근본 수정은 작업자 배포가 먼저라 이 티켓 밖)
- 설계 계약: 위 명세 줄의 절, 봇 ARCHITECTURE §12 "T18 작업 레인 계약"의 capability·재사용 거부 문단, DECISIONS "T19" 구현 절의 시험 영수증(command마다 하나) 규칙.

## 원인 (조사 2026-11-10, 확정)

두 게시 서버가 같은 밀리초에 같은 `/v2/task/verify` 요청을 서명하면 토큰이 같아진다(`TaskWorkerSigner.issue`의 claims에 무작위 값이 없고 nonce는 payload의 sha256, Ed25519 서명도 결정적). 작업자는 늦게 온 쪽을 재사용으로 보고 403으로 거절한다. `verificationWorker`의 재시도(`expectedWorker: null`)는 verify 요청 스키마가 null을 받지 않아 보내기 전에 실패한다. `WorkerChangeVerification.run`은 거절을 로컬 `not_run` 영수증으로 확정하고, 그 기록이 이긴 서버의 `passed`보다 먼저 들어가 부모가 `verifying → blocked (verification_not_run)`으로 닫힌다. 영수증이 command마다 하나라 같은 generation으로는 되살릴 수 없다. 재현: 시험 "T19 B5 EVENT-02 실제 PostgreSQL: 게시 서버 둘이 …"를 반복하면 55번 중 5번(main `9377c33`), 이 시험이 들어온 봇 #85에서도 30번 중 2번.

## 목표

게시 서버 둘이 겹친 순간(배포 교체)에 한쪽의 시험 요청이 거절돼도 그 변경이 막히지 않는다. 거절당한 쪽은 작업자에게 실제 상태를 다시 물어, 다른 쪽이 돌리는 시험이 있으면 그 결과를 기다리거나 물러난다. 시험이 정말 시작되지 않았을 때만 지금처럼 `not_run`이다.

## 할 일

1. 같은 밀리초 충돌을 결정적으로 만드는 시험을 먼저 쓴다(두 런타임에 같은 시계를 주거나 서명 시각을 고정). 지금 코드에서 빨강인지 본다.
2. `WorkerChangeVerification.run`이 거절을 받으면 바로 `not_run`으로 확정하지 않는다. 먼저 `/v2/task/verification`으로 그 command의 상태를 물어 `running`·`done`이면 그 결과를 따르고(다른 쪽이 낸 요청), 시작되지 않았다는 답일 때만 `not_run`으로 기록한다. 물어도 모르면 확정하지 않고 다음 바퀴에 다시 본다(같은 변경을 영원히 붙잡지 않게 기존 기한·시도 상한을 따른다).
3. `verificationWorker`의 `send(null)` 재시도는 스키마 때문에 성공할 수 없는 경로다. 없애거나 통하는 모양으로 고친다. 파드 교체로 `worker_mismatch`가 났을 때의 동작을 시험으로 고정한다.
4. 이긴 쪽의 `passed` 기록이 `receipt_conflict`가 되지 않는지, 모델·시험·PR이 하나인지(기존 EVENT-02 단언)를 반복 시험으로 본다.
5. 기록: 봇 `docs/ai-bot/DECISIONS.md`에 원인과 고른 방법, 근본 수정(capability에 무작위 nonce, 작업자를 먼저 배포)을 뒤로 미룬 이유, `docs/ai-bot/VERIFICATION.md`에 "C33" 절, ARCHITECTURE 해당 문단에 한 줄. 이 계획 폴더 `README.md`의 C33 상태 줄 갱신.

## 완료 조건

- [x] 같은 밀리초에 두 게시 서버가 verify를 보내도 변경이 `awaiting_publish_approval`까지 가고 모델·시험·PR이 하나다(결정적 시험).
- [x] 시험이 정말 시작되지 않았을 때는 지금처럼 `verification_not_run`으로 닫힌다.
- [x] 기존 EVENT-02 실제 PostgreSQL 시험이 반복 실행에서 실패하지 않는다.

## 검증

- 경계: S1(변경 런타임·시험 영수증, PGlite와 실제 PostgreSQL 두 연결). 앞선 시험 예: `change-pg`, `change-assembly`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체는 통합 담당.
- 잡는 실패: 거절을 `not_run`으로 확정, 죽은 재시도 경로. 못 잡는 범위: 토큰이 같아지는 것 자체(근본 수정, 작업자 배포 뒤), 실제 배포 교체 순간(C24 S5).

## 결과

- 봇 PR #136, 병합 `ef27723`(2026-11-10). 거부를 받으면 `/v2/task/verification`에 다시 묻고 `running`·`done`이면 그 결과를 따른다. `absent`면 verify를 한 번만 다시 보내고 그것도 거부될 때만 `not_run`, 기한까지 모르면 `unknown`.
- 완료 조건 3개 충족(S1): `test/change-verify-recheck.test.ts`, `change-pg`의 같은 밀리초 결정적 시험, `change-verification` port 시험. 기존 EVENT-02 실제 PostgreSQL 시험은 반복 90번 중 실패 0(고치기 전 55번 중 5).
- 검사: 결과 `b566712`에서 전체 2,511개 중 통과 2,489, 실패 0, skip 22. CI `build / test`는 무관한 C28 시험의 러너 시간 초과로 1회 실패 뒤 재실행 통과.
- Codex: 지적 없음.
- 한계: 토큰이 같아지는 것 자체는 남는다(근본 수정: capability에 무작위 nonce, 작업자 먼저 배포). 작업자에 닿지 않을 때는 최대 약 3분 다시 물은 뒤 `verification_unknown`으로 막힌다. 실제 배포 교체 순간은 C24 S5.
