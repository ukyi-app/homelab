# T30 봇 V1 승인·연동 시험 (T21 blocked 7건)

- 단계: P4 후속 (T21 1회차 감사에서 나옴)
- 상태: 완료 (2026-11-09. 7항목: INT-02·03·04·05·06·07 pass, INT-01 기존 증거 수용. 판정은 T21 재실행)
- 명세: [../spec.md](../spec.md)
- Blocked by: T25(INT-04·INT-07만), T26(INT-04만)
- 연결 AC: AC-B8 (SEC-02, EVENT-02, TASK-01, CHANGE-01, CHANGE-02, CHANGE-03, DEPLOY-01, DATA-01)
- 수행: 에이전트 + 사람(항목마다 승인)

## 목표

T21 1회차 감사에서 수용 시험 7개가 `blocked`였다. 로컬 시험은 통과했지만 실제 연동 증거가 없거나, 실행하려면 사람 승인이 필요한 항목이다. 항목마다 실제로 실행하거나, 사람이 제외 범위와 대체 증거 수용을 정해 기록한다. 감사자는 이 결정을 추정해 `blocked`를 지우지 않는다(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md` "승인·연동 티켓 후보").

## 메모

- 정확한 질의, 필요 승인, 완료 조건은 비공개 ops 저장소 `evidence/release-audit/OBSERVATION-REQUESTS.md` O01~O07에 있다. 여기에는 범위만 적는다.
- 각 항목은 시작 전에 대상·효과·자격·예산·정리·중단 조건을 사용자 승인으로 받고 [../approvals.md](../approvals.md)에 남긴다. 한 항목의 승인이 다른 항목으로 넓어지지 않는다.
- 실제 자격 값이나 비공개 원문을 시험 입력에 넣지 않는다. 합성 표식을 쓴다.

## 할 일

| 항목 | 시험 | 범위 | 선행 |
|---|---|---|---|
| INT-01 (O01) | SEC-02 | 운영 TaskLane 전체 조립에서 악성 Read·Write·Bash·설치 스크립트 격리. 실제 키를 읽지 않는 동등 경로 합성 시험 우선 | 없음 |
| INT-02 (O02) | EVENT-02 | 시험 스레드·시험 PR에서 외부 게시 성공 뒤 로컬 확인 직전 장애 한 번, 게시 서버 한 프로세스 재기동, 중복 0 | 없음 |
| INT-03 (O03) | TASK-01 | 실제 Codex notify → R08 수신 → 고정 알림, detach·복원 fence, 시험 키 폐기. 명령 등록 응답 모양 확인(A08) 포함 | 없음 |
| INT-04 (O04) | CHANGE-01, CHANGE-03 | 질문·답을 거치는 여러 턴 CHANGE, base 이동·사람 commit 경합에서 덮어쓰기 0 | T25, T26 |
| INT-05 (O05) | CHANGE-02 | 실제 writer 신원의 merge·workflow push 거부와 원인 계층. 실패하지 않으면 실제 효과가 생기므로 대상·정리·복구를 따로 승인 | 없음 |
| INT-06 (O06) | DEPLOY-01 | 기존 읽기 관찰 기록 먼저, 없으면 시험 앱 재등록으로 stale·unready·미등록이 성공으로 보이지 않음 확인 | 없음 |
| INT-07 (O07) | DATA-01 | 공개 입력과 합성 표식으로 실모델 출력이 공개 경계에서 막히는지. 모델 출력 유무와 실행기 거부를 따로 기록 | T25 |

## 진행 (2026-11-07~)

실행안은 NUC `/home/ukyi/t21/t30/T30-PLAN.md`(읽기 전용 Codex 조사, 2026-11-07), 원본 기록은 `homelab-bot-ops` `evidence/t30/`. 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T30 승인·연동 시험 진행".

| 항목 | 상태 |
|---|---|
| INT-05 (CHANGE-02) | **pass**(2026-11-08, `authorized_external`). writer 신원의 `PUT merge` → 405 ruleset 거부, workflow 파일 `git push` → GH013(`workflows` 권한 없음). main 불변, 정리 끝 |
| INT-01 (SEC-02) | **기존 증거 수용**(사용자 결정 2026-11-08), live `not_run`. 남은 제약: 서명된 작업 레인 전체 경로의 운영 프로필 실측 없음. 격리 하네스는 Claude 작업자 두 번 모두 모델 안전 분류기에 막혀 만들지 못했고, 만들어도 진입 래퍼 때문에 운영과 다르다 |
| INT-06 (DEPLOY-01) | **pass**(2026-11-08, `authorized_external`), `argo_compare_stale` 단독 `not_run`. 운영 코드 `DeploymentReader`로 시험 앱 `homelab-smoke`를 H0 재등록(#1185) → H3 전환(#1186) 직후 `argo_config_stale` 2회 → readiness `/healthz/db` 실패(#1187) `pod_unready` 9회 → 제거(#1188) 뒤 `blocked(deploy_config_unregistered)`. 잘못된 `observed` 0. 제약: values만 바뀐 병합은 stale로 보이지 않음, unready는 파드 단위에서만 잡힘. 시험 앱 `KubePodNotReady` 1회(제거 뒤 2분 32초 해소) |
| INT-02 (EVENT-02) | **pass**(2026-11-08, `authorized_external`, fixture `mock`). NUC 격리 시험 게시자(운영과 같은 코드, 로컬 시험 DB)로 Discord 시험 스레드 `T30-INT-02`의 메시지 A 게시 성공과 `homelab-smoke` PR #20 생성 201 뒤 로컬 confirm 전에 SIGKILL 1회 → 재기동 1회. A는 검색으로, PR은 대조로 확정, 재전송 0, 뒤 메시지 B는 A 확정 뒤. 제약: wire 응답 손실 아님, 시험 PR만 draft(운영은 non-draft, 모델 0을 위해). 정리 끝(PR 닫음, ref·메시지 삭제) |
| INT-07 (DATA-01) | **pass**(2026-11-08, `authorized_external`). 운영 봇 `/task` 2건에서 실제 모델이 합성 `sk-` 조합을 질문·완료 요약에 넣었고 둘 다 `secret_detected`로 막힘(질문 작업은 `failed(task_question_sensitive)`, 요약은 고정 문구), Discord 노출 0, 모델 2회. 발견: 대문자 `SK-`·U+2011 대시 변형은 탐지기를 통과(T21 재감사 판정) |
| INT-03 (TASK-01) | **pass**(2026-11-09, `authorized_external`). iMac 실제 Codex notify → R08 수신 accepted → Discord 알림 1건, 재전달 duplicate·알림 0, detach 뒤 401. 복원 fence는 로컬(`local_integration`), A08은 guild 명령 32개 필드 없음·재시작마다 재등록. 첫 턴 notify 2회, seed 붙여넣기 실패로 재연결(연결·키 2, Codex 3턴, 사용자 승인) |
| INT-04 (CHANGE-01·03) | **pass**(2026-11-09). A(운영 실모델): 질문→답→resume→`smoke-unit` passed(T28 표식 운영 첫 실측)→digest 승인→smoke PR #22(tree·부모 일치)→닫은 뒤 `cancelled(closed_unmerged)`. B·C·D(격리 시험 게시자, 실제 smoke GitHub, receipt `mock`): 승인 뒤 base 이동 `superseded(base_moved)`(사람 PR smoke #21, 문서 한 줄 시험 흔적), 새 generation·옛 digest 거부, 예정 ref 다른 SHA `blocked(head_changed)`. 25 검사, 모델 5회. 제약: 작성 도구 상한은 job 합계 8회, D는 gate 경우만 실측 |

## 완료 조건

- 7개 항목마다 실행 결과(증거 등급과 리비전) 또는 사람이 정한 제외 범위·대체 증거 수용이 봇 `VERIFICATION.md`와 [../approvals.md](../approvals.md)에 있다.

## 검증

`04` §4의 해당 시험 7개. 결과는 T21 재실행이 다시 판정한다.
