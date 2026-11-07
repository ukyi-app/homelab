# T28 봇 검증 실행기의 샌드박스 준비 실패 분류

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 현 버전 필수 수정)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-B8 (CHANGE-01, F06·R13)
- 수행: 에이전트

## 목표

CHANGE 검증 실행기가 bwrap 준비 실패(마운트·chdir·namespace)를 후보 시험 실패(`failed`)로 기록한다. payload는 실행되지 않았는데 변경 코드가 시험에 실패한 것처럼 보여 작성 쪽을 잘못 이끈다. T21 1회차 감사 A04(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`, 결함 후보 FIX-04)이다. 준비 실패를 `not_run(sandbox_unavailable)`로 가른다.

## 메모

- 위치(봇 `dda891f`): `src/change-verifier.ts`. `spawnSandbox`는 `child-pid`가 나오면 `started:true`를 돌려준다. `child-pid`는 payload exec 성공의 증거가 아니다. 감사 이미지에서 없는 cwd를 주면 `Can't chdir` 준비 오류인데 `started:true`, `exitCode:1`이었다.
- 실패 쪽으로 닫히므로 시험 미실행을 통과로 만드는 우회는 확인되지 않았다.

## 할 일

1. payload 시작을 확인하는 별도 신호나 상태를 두고, 준비 실패를 `not_run(sandbox_unavailable)`로 분류한다.
2. 마운트·chdir·namespace 준비 실패, 실제 assertion 실패, timeout·취소를 구분하는 컨테이너 시험을 더한다(감사 이미지 방식, 봇 `VERIFICATION.md` "SEC-02 1단계").
3. 봇 저장소 PR, 작업자 이미지 갱신(homelab `platform/sandbox/values.yaml` 사람 PR), 봇 `VERIFICATION.md` 기록.

## 완료 조건

- 준비 실패는 `not_run(sandbox_unavailable)`, payload 실패는 `failed`로 기록된다.
- 감사 재현(ops `evidence/release-audit/` `bwrap-probe.mjs`)이 `not_run`으로 나온다.

## 검증

`04` §4 CHANGE-01(검증 상태 하위 사례).
