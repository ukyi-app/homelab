# T21 봇 V1 RELEASE_AUDIT

- 단계: P4 봇 V1 (봇 V1 통합 검증 담당)
- 상태: 진행 중 (1회차 감사 2026-11-07, 판정 `NOT_READY`. 수정 T25~T29와 승인·연동 T30 뒤 다시 실행)
- 명세: [../spec.md](../spec.md)
- Blocked by: T17, T18, T19, T20, T25, T26, T27, T28, T29, T30(재실행)
- 연결 AC: AC-B8
- 수행: 구현 세션과 다른 독립 감사 에이전트 (`MODE=audit`). 사람은 수용 결정

## 목표

V1을 판정한다. 판정 정의는 `04` §9, end-to-end 흐름은 `01` §9, 시험과 양식은 `04` 전체가 기준이다.

## 할 일

1. `04` §1 감사 프롬프트를 실행한다.
2. `04` §4의 시험 30개 결과를 모두 기록한다.
   - V1 범위 조정 안 3(확정(사용자 2026-10-18, T15))의 STAGE별 시범 운영 기록(승인은 [../approvals.md](../approvals.md), 증거는 `authorized_external`)이 있으면 해당 시험의 증거로 함께 본다. 판정 정의(`04` §9)는 바꾸지 않는다.
3. F01~F09, R01~R18의 구현 위치와 증거를 추적한다.
4. `01` §9의 end-to-end 흐름 5개를 확인한다.
5. 판정을 내린다: `NOT_READY`, `LOCAL_VERIFIED_INTEGRATION_PENDING`, `READY_FOR_SCOPED_PILOT`, `V1_ACCEPTED`.

## 1회차 감사 결과 (2026-11-07)

독립 감사 에이전트(Codex `gpt-6-astra`, `MODE=audit`)가 봇 `dda891f`, homelab `691b532e`, ops `6caf4cb` 기준으로 했다. 감사자는 읽기와 로컬 시험만 했다(운영 접근·외부 쓰기 없음). 공개 산출물은 봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`·`V1_TRACE.md`(봇 #88), 감사 인계·증거·운영 관찰 요청은 `homelab-bot-ops`의 `handoffs/release-audit.md`, `evidence/release-audit/`다.

- **판정 `NOT_READY`.** 출시 차단 두 건을 현재 코드에서 재현했다. A01 `/task` 질문·완료 요약이 비밀 검사 없이 Discord로 나간다. A02 `/revoke`가 끝난 뒤에도 이미 권한 확인을 지난 Discord 발송이 시작될 수 있다. lead가 두 건을 코드로 다시 확인했다.
- **시험:** 수용 시험 30개 pass 21, fail 2(AUTH-02·DATA-01), blocked 7. 봇 전체 시험 2,085개 fail 0·skip 22, SEC-02 감사 이미지 시험 10/10·24/24.
- **발견 8건(high 2, medium 2, low 4)과 티켓:**
  - 결함: A01 → [T25](T25-bot-task-output-scan.md), A02 → [T26](T26-bot-revoke-dispatch-order.md), A03 원문 보존 → [T27](T27-bot-raw-input-retention.md), A04 준비 실패 분류 → [T28](T28-bot-verifier-setup-failure.md), A06 `/retry` 안내 → [T29](T29-bot-change-child-retry-notice.md).
  - 승인·연동: blocked 7건 → [T30](T30-bot-v1-integration-tests.md).
  - 개선 후보(티켓 없음, 재감사에서 다시 본다): A05 승인 digest가 메시지 두 개로 갈릴 수 있음, A07 `reserveUnknownProbes` 첫 50행 고정(도달 조건 미입증), A08 명령 재등록(운영 응답 모양 확인은 T30 INT-03).
- **T19·T20에서 넘긴 것:** 모두 처리했다(보고서 "T19·T20 이관 항목 전수 처리"). 정책 revision 변경 때 진행 중 CHANGE가 막히는 것은 의도된 동작으로 수용, 게시 서버 둘의 간헐 `verification_not_run`은 운영 단일 게시 서버 제약으로 유지, T20 기억 → 모델 경로는 여전히 없다.
- 출시 차단 A01·A02는 T25(봇 #89)·T26(봇 #90)으로 고쳐 2026-11-07 운영에 배포했다(homelab #1175). 남은 것은 T27~T30이다.
- 사람 수용 결정은 아직 없다. 재실행은 T25~T30 뒤다.

## T19에서 넘긴 것 (2026-11-07)

근거는 봇 `docs/ai-bot/VERIFICATION.md` "T19 완료 판정"과 그 앞 T19 절들이다.

- **운영에서 만들지 않은 사례(`not_run`, 로컬 pass):** 질문·`/answer`를 거치는 여러 턴 작성(CHANGE-01), 실제 신원의 `PUT merge`와 워크플로 파일 git push 거부(CHANGE-02), live 경합 PR(CHANGE-03), Argo stale·unready(DEPLOY-01), 실모델이 공개 입력으로 비공개 값을 지어내는 경우(DATA-01), TaskLane 조립 경로의 SEC-02·실모델 악성 시험·실자격 직접 Read(SEC-02), 실제 프로세스 kill·live fault(EVENT-02).
- **알려진 한계·결함(티켓 없음, 감사에서 수정 티켓으로 나눌지 정한다):**
  - 스위치·정책 변경은 게시 서버 재시작 때 반영된다. 종료 중인 프로세스는 진행 중인 바퀴에서 쓰기를 보낼 수 있다. 즉시 중단은 `/revoke`·`/change-cancel`이다.
  - 검증 실행기는 bwrap 설정 실패를 `not_run(sandbox_unavailable)`가 아니라 `failed`로 기록한다.
  - `/task` v1 모델 질문은 비밀 검사 없이 스레드로 나간다(CHANGE 질문·공개 답은 봇 #86에서 막음).
  - CHANGE 단계 전이가 게시 서버 로그에 남지 않아 운영자는 `/change-status`로만 진행을 본다.
  - 승인 안내를 길이로 나눠 digest가 두 메시지로 갈릴 수 있다. 다른 digest는 거부된다.
  - CHANGE 자식 실패에도 "/retry로 재시도" 안내가 나가지만 `/retry`는 자식 job을 되살리지 않는다.
  - `change_request_inputs`와 `codex_questions.answer`의 비공개 원문은 7일 정리 대상이 아니다.
  - 정책 revision을 올리면 진행 중인 CHANGE가 막힌다. `reserveUnknownProbes`(`ORDER BY id LIMIT 50`)는 #85에서 고친 것과 같은 굶주림 모양이다. `registerCommands`는 재시작마다 같은 목록도 다시 쓴다.
  - 게시 서버 둘을 동시에 돌리는 `change-pg` 시험이 부하에서 간헐적으로 `verification_not_run`으로 닫힌다(수정 전 코드에서도 재현, 운영은 게시 서버 하나).
- **운영 상태:** `CHANGE_PR_ENABLED`는 정책의 `homelab-smoke` 하나로 켜져 있다. 시험 앱 `homelab-smoke`는 뺐으므로 smoke 변경의 배포 관측은 `deploy_config_unregistered`로 닫힌다. `ukyi-writer`는 `homelab-smoke`에만 설치돼 있고 homelab의 ruleset E는 남겼다.

## T20에서 넘긴 것 (2026-11-03)

- SEC-01 기억 경로: V1 코드에는 기억을 모델 맥락에 넣는 경로가 없다. 봇 main `dab3de1`에서 `memories` 표는 `src/memory.ts`만 읽고, 그 서비스를 쓰는 곳은 기억 명령과 모델을 부르지 않는 브리핑뿐이다. 감사 때 이 경로가 여전히 없는지 본다. 생겼다면 기억을 비신뢰 자료 블록으로 넘기는지(봇 `ARCHITECTURE.md` 위협 표의 프롬프트 인젝션 행) SEC-01로 확인한다.
- BRIEF-01 인증서·복원 검증 칸은 T24다. 미확인 표시가 V1 규칙이라 판정을 막지 않는다. Codex 작업 상태·질문 대기 칸은 T18이다.
- 허용 밖 채널 거부가 조용하다(감사·로그 없음, owner에게는 Discord 기본 "응답하지 않음" 오류). T16b AUTH-01 live와 같은 한계다.

## 제약

감사자는 사용자 수용을 대신 선언하지 않는다. V2를 시작하지 않는다.

## 완료 조건

`V1_RELEASE_REPORT.md`와 요구사항·시험 추적표가 있고, 판정이 `READY_FOR_SCOPED_PILOT` 이상이다.

판정이 그보다 낮으면 감사는 끝났지만 T21은 완료가 아니다. 차단 사유를 둘로 나눠 티켓을 만들고, 처리 뒤 T21을 다시 실행한다.

- 결함(`fail`, 경계 위반, 필수 범위 누락): 사유마다 수정 티켓을 만든다.
- 사람 승인이 필요한 미실시 실연동(`LOCAL_VERIFIED_INTEGRATION_PENDING`의 원인, spec §11): 승인·연동 티켓을 만든다. 승인은 [../approvals.md](../approvals.md)에 남긴다.

## 검증

`04` §8 보고 양식, §9 판정 기준.
