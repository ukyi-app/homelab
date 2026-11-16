# O04 검증: 실제 한도·API 소진 때의 신호 모양

- 단계: 0 끄기와 검증
- 상태: 구독 한도 표본 완료(2026-11-16, 주간 한도와 틀린 키 401). API 표본(지출 한도, 크레딧 소진, OpenCode의 한도 신호)은 대기(O05의 실행과 관리자의 Console 준비 뒤)
- 명세: `spec.md` §8.2 2번·5번, `accounts.md` §2(판정표의 출발점)
- Blocked by: 없음
- 연결 AC: AC-03
- 수행: 에이전트 + 사람(한도 상태를 기다려 관측)
- 저장소·PR: 이 계획 문서 PR(결과와 비식별 샘플)
- 파일 소유: 이 티켓의 "결과" 절, `spec.md` §8.2
- 설계 계약: 계정 전환 조사 5절(아래 요약)

## 목표

설치된 Claude Code(2.1.323 기준, 실행 때 버전 고정)에서 실제 구독 한도와 API 지출 한도·소진 때 감독이 받을 신호를 기록한다. 감독의 판정표(O17)가 추측이 아닌 실측에 기대게 한다.

## 알려진 사실

- [확인] 대화형: `StopFailure` 훅이 `error` 종류(rate_limit, authentication_failed, billing_error 등)를 준다. 어느 구독 창이 소진됐는지는 다 주지 않는다. 상태줄 stdin JSON에 `rate_limits.five_hour/seven_day.{used_percentage, resets_at}`가 있다(첫 응답 전에는 없음).
- [확인] `-p`·SDK: `rate_limit_event`(allowed, allowed_warning, rejected), assistant error, result의 `is_error`. result subtype이 success여도 `is_error: true`일 수 있다.
- [확인] API 지출 한도는 HTTP 400 `invalid_request_error`, 일반 속도 제한은 429. 429에는 분당 제한 말고도 ramp 제한, Claude Code workspace의 지출 한도, 등급의 월 지출 상한이 있다.
- [확인] 헤드리스 `stream-json`은 재시도 전에 `system/api_retry`를 낸다(`attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error`).
- [확인] OpenCode v2.1.0 소스에서 `run --format json`의 최종 오류에는 `type`, `message`, 있으면 `status`와 `response.body`만 있고 응답 헤더는 없다. 등급 상한 429는 `provider.quota`로, 직접 건 지출 한도 400은 `provider.invalid-request`로 묶인다. 소스를 읽은 것이고 실측이 아니다.
- [확인] `autoContinueAtUsageLimit` 기본값은 true다. 감독형 실행에서는 false로 고정한다.
- [미확인] 실제 한도·소진 때의 정확한 값과 순서.
- [미확인] OpenCode(D-14의 크레딧 작업자 도구)가 API 지출 한도·소진을 어떤 모양으로 알리는지. 조사에서는 Claude Code의 `StopFailure`·SDK와 같은 수준의 계약을 확인하지 못했다.

## 할 일

1. 관측 장치를 준비한다: 대화형은 `StopFailure` 훅과 상태줄 명령이 받은 JSON을 비식별해 파일로 남기고, `-p`는 stream-json을 남긴다. 계정명·세션 ID·토큰은 남기지 않는다.
2. 올리브 전용 계정이 실제로 한도에 걸렸을 때(인위로 소진하지 않는다. 자연히 걸리는 때를 기다린다) 위 신호를 모은다.
3. API 쪽은 올리브 전용 workspace에 낮은 지출 한도를 걸어 둔 상태에서 한도 도달 응답을 모은다(관리자가 Console에서 설정). `claude -p`와 OpenCode(`run --format json`) 둘 다 모은다. OpenCode의 신호를 감독이 결정적으로 읽을 수 없으면 `spec.md` B-08의 "막히면"을 따른다.
4. 결과로 판정표를 만든다: 신호 → 처리(넘어감/대기/잠금/미상). 출발점은 `accounts.md` §2다. 아래 표본을 따로 나눠 적는다(자연히 만난 것만. 못 만난 것은 "못 봄"으로 남긴다).
   - 경고만, 거절(`rejected`) 뒤 같은 턴 성공, 구독의 실제 실패.
   - 400 셋: 일반 요청 오류, 조직·workspace 지출 한도, 모르는 본문. 400은 목록에 없는 다른 4XX에도 쓰일 수 있어서 모르는 본문은 요청 문제로 닫지 않고 미상으로 둔다.
   - 401 키 오류, 402 결제 오류.
   - 429 넷: 분당 제한, `ramp_limit_exceeded`(`retry-after` 있음), Claude Code workspace의 지출 한도(`retry-after` 있음), 등급의 월 지출 상한 `enforced_spend_limit_reached`(`retry-after` 없음). `retry-after`가 있다는 것만으로 분당 제한이라 하지 않는다.
   - 실제 크레딧 소진. 공식 문서에 소진의 상태 코드·종류가 없어서 이 표본이 있어야 소진과 결제 장애를 가를 수 있다. 못 가르면 O17은 미상 보류로 다룬다(B-17).
   - 헤드리스의 `system/api_retry`(재시도 중)와 최종 실패가 어떻게 갈리는지. `rate_limit_event`와 함께 오는 순서.
   - OpenCode의 최종 `error.type`별 샘플: `provider.auth`, `provider.quota`, `provider.rate-limit`, `provider.invalid-request`, 그리고 계정 문제가 아닌 것(`provider.content-filter`, `provider.unsupported-operation`, `provider.no-route`, `permission.rejected`, `tool.execution`). 최종 JSON의 `response.body`에 `error.details.error_code`와 조직·workspace를 가르는 문구가 남는지, 안에서 재시도하는 동안 무엇이 보이는지, 종료 코드와 error 사건이 겹치는지 적는다.
5. 경고만으로 넘어가지 않는지, 한도 뒤 정상 성공(Usage credits 등)이 섞이는지 적는다.
6. 훅·상태줄이 어느 턴의 것인지 감독이 이을 수 있는지(늦은 훅과 새 입력의 구별), 모델이 낸 출력이 신호로 섞여 들지 않는지 적는다.

## 완료 조건

- [ ] 구독 한도, API 지출 한도 두 경우의 신호 샘플(비식별)과 판정표가 있다. API 쪽은 OpenCode의 샘플을 포함한다. (구독 한도는 있다. API 지출 한도와 그 OpenCode 샘플은 아직 없다)
- [x] 할 일 4번의 표본마다 "봄(샘플 있음)/못 봄"이 적혀 있고, 못 본 표본은 O17에서 미상으로 다룬다는 것이 판정표에 있다. (결과 "표본별 봄/못 봄", `accounts.md` §2.6·§10. API 표본을 모으면 다시 채운다)
- [x] 소진과 결제 장애를 신호로 가를 수 있는지(됨/안 됨)가 적혀 있다. (지금은 안 됨: 표본이 하나도 없다)
- [ ] `spec.md` §8.2 2번이 실측에 맞게 고쳐졌다. (구독 쪽은 고쳤다. API 쪽 문장은 표본이 없어 그대로다)

## 검증

- 경계: 실제 한도 상황 관측. 한도를 일부러 태우는 호출은 하지 않는다.
- 잡는 실패: 경고를 한도로 오판, 400을 모두 결제로 오판. 못 잡는 범위: 버전이 바뀐 뒤의 모양(O17이 버전 고정과 시험 고정값으로 관리).

## 결과

**구독 주간 한도와 틀린 키(401)의 신호는 봤다. API 지출 한도와 크레딧 소진은 못 봤다. 완료 조건은 반만 찼고, API 표본은 O05의 실행과 관리자의 Console 준비를 기다린다.**

구독 주간 한도에 걸린 계정은 재시도 없이 약 0.6초 만에 최종 실패한다. 헤드리스는 `rate_limit_event`(`rejected`) → assistant(`error: rate_limit`, 429, `usage_limit_reached`) → result(`subtype: success`, `is_error: true`) → `StopFailure` 훅 순서이고 종료 코드는 1이다. `accounts.md` §2의 처리 방향이 틀린 곳은 없었고, 고친 곳은 넷이다(아래 "판정표와 다른 곳").

### 돌린 조건

- 돌린 날: 2026-11-16. Claude Code 2.1.325, OpenCode v2.1.0(틀린 키 표본 하나만 돌렸다).
- 아래의 표시: [확인, 실측]은 이번에 돌려 본 것, [확인, 문서]는 같은 날 다시 읽은 공식 문서, [추론]은 실측에서 낸 판단이다.
- 한도 계정: 주간 한도에 자연히 걸린 구독 계정(일부러 태우지 않았다). 비교 계정: 한도에 걸리지 않은 구독 계정.
- 모델 호출: 한도 계정 4번(헤드리스 1, 대화형 3. 모두 거절됨), 비교 계정 2번(헤드리스 1, 대화형 1. 짧은 답 하나씩).
- 환경: 새로 만든 환경(HOME, PATH, TERM, LANG, USER, 계정 폴더 지정만)과 빈 작업 폴더. 훅 여섯(SessionStart, UserPromptSubmit, Stop, StopFailure, Notification, SessionEnd)과 상태줄을 임시 설정으로 걸어 받은 JSON을 남겼다. 계정 폴더의 사용자 설정은 읽지 않게 했고 고치지 않았다. 관리 설정은 없는 상태다.
- 비식별 표본 일곱 개와 관측 장치는 저장소 밖 검증 기록에 있다. 이 PR에는 표본 파일을 넣지 않았고, 아래에 필요한 칸만 옮겼다.

### 공식 문서와 설치본의 차이 [확인, 문서와 실측]

| 문서 | 설치본(2.1.325)과 맞는가 |
|---|---|
| 훅 `StopFailure`: 입력은 공통 칸 + `error`(12종) + 선택 `error_details` + 선택 `last_assistant_message` | 맞다. 한도에서는 `error_details`가 오지 않았다 |
| 훅 공통 칸의 `prompt_id`(사용자 입력마다의 UUID, 첫 입력 전에는 없음) | 맞다. `accounts.md`에 없던 칸이다 |
| 상태줄의 `rate_limits.five_hour`·`seven_day`(첫 API 응답 뒤에만, 창마다 따로 없을 수 있다) | 맞다. 두 계정 모두 `five_hour`는 없고 `seven_day`만 왔다 |
| 헤드리스 `system/api_retry`(재시도할 수 있는 오류일 때) | 한도 거절에서는 한 번도 나오지 않았다 |
| SDK `rate_limit_event.rate_limit_info`: `status`, 선택 `resetsAt`·`utilization`·`errorCode` 등 | **다르다.** 문서에 없는 칸이 다섯 개 더 오고 `utilization`·`errorCode`는 오지 않았다 |
| SDK result의 `is_error`, `api_error_status`, `terminal_reason` | 맞다 |
| `autoContinueAtUsageLimit`(기본 true, false여도 한도 메뉴에서 기다리기를 직접 고를 수 있다) | 이번 상황에서는 true와 false의 차이가 없었다(아래) |

### 헤드리스: 구독 주간 한도 [확인, 실측]

`claude -p "ok" --output-format stream-json --verbose` 한 번. 시각은 실행 시작부터의 ms다.

| ms | 어디서 | 사건 |
|---|---|---|
| 264 | 훅 | `SessionStart` |
| 645 | 훅 | `UserPromptSubmit`(`prompt_id` 생김) |
| 665 | stream | `system/init` |
| 1279 | stream | `rate_limit_event`, `status: rejected` |
| 1282 | stream | assistant, `error: rate_limit` |
| 1290 | stream | result, `subtype: success`, `is_error: true` |
| 1291 | 훅 | `StopFailure`, `error: rate_limit` |
| 1305 | 훅 | `SessionEnd`, `reason: other` |
| 2071 | 프로세스 | 종료 코드 1 |

- `system/api_retry`는 없다. 거절은 첫 요청에서 바로 최종 실패가 된다. stderr는 비어 있다.
- `rate_limit_event.rate_limit_info`: `status: rejected`, `resetsAt`(Unix epoch 초, 화면 문구의 리셋 시각과 같다). 문서에 없는 칸: `rateLimitType: seven_day`, `overageStatus`, `overageDisabledReason`, `isUsingOverage: false`, `unifiedWindows`(창마다 `utilization`, `status`, `surpassedThreshold`, `resetsAt`). 거절된 턴 안에서도 `unifiedWindows`의 한 칸은 `allowed_warning`이었다.
- assistant: `message.model: "<synthetic>"`, 토큰 사용 0, 본문은 화면 문구 한 줄. 최상위에 `error: "rate_limit"`, `is_api_error_message: true`, `api_error_status: 429`, `api_error: "usage_limit_reached"`, `api_error_type: "rate_limit_error"`, `api_error_origin: "first_party"`.
- result: `subtype: "success"`, `is_error: true`, `terminal_reason: "api_error"`, `api_error_status: 429`, `api_error: "usage_limit_reached"`, `num_turns: 1`, `duration_api_ms: 0`.
- `StopFailure` 훅 입력: `error: "rate_limit"`, `last_assistant_message`(화면 문구), `prompt_id`(같은 턴의 `UserPromptSubmit`과 같은 값). `error_details`는 없다.

비교 계정의 정상 턴 [확인, 실측]:

- 순서: `init` → assistant(실제 모델) → `rate_limit_event` → `Stop` 훅 → result(`subtype: success`, `is_error: false`, `terminal_reason: completed`) → `SessionEnd` → 종료 코드 0.
- `rate_limit_event`는 성공한 턴에도 온다(`status: allowed`, `rateLimitType: seven_day`).
- 이 정상 턴에도 `overageStatus: "rejected"`가 실려 있다. **`overageStatus`는 한도 신호가 아니다.**
- 순서가 실패 때와 다르다. 실패는 `rate_limit_event` → assistant, 성공은 assistant → `rate_limit_event`다. 훅도 실패는 result 뒤(1ms), 성공은 result 앞(12ms)이었다. [추론] 표본이 하나씩이고 간격이 짧아서 순서에 기대면 안 된다.

### 대화형: 구독 주간 한도 [확인, 실측]

| ms | 어디서 | 사건 |
|---|---|---|
| 6243 | 훅 | `SessionStart` |
| 6435 | 상태줄 | 첫 실행. `rate_limits` 없음 |
| 6461 | 훅 | `UserPromptSubmit`(첫 입력, `prompt_id` A) |
| 7004 | 훅 | `StopFailure`, `error: rate_limit`, `prompt_id` A(입력 0.54초 뒤) |
| 약 7000~32600 | 화면 | 선택 메뉴가 떠 있음. 이 26초 동안 상태줄은 돌지 않았다 |
| 32605 | 상태줄 | Esc로 메뉴를 닫은 직후. `rate_limits.seven_day`(`used_percentage: 100`, `resets_at`), `prompt_id`는 A가 아닌 새 값 B |
| 51446 | 훅 | `UserPromptSubmit`(둘째 입력, `prompt_id` C) |
| 51853 | 훅 | `StopFailure`, `error: rate_limit`, `prompt_id` C |
| 52162 | 상태줄 | `rate_limits.seven_day` 같음, `prompt_id` C |

- `Notification` 훅은 어느 실행에서도 돌지 않았다. 상태줄에는 걸린 창(`seven_day`)만 있고 `five_hour`는 없다.
- 화면: 첫 입력이 거절되면 답 자리에 한도 문구가 뜨고 그 아래에 고르는 메뉴가 열린다. hc는 이때 상태를 `blocked`("dialog open")로 본다.

```text
❯ ok
  ⎿  You've hit your weekly limit · resets <시각>

   What do you want to do?
   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at <시각>
     3. Switch to usage credits
   Enter to confirm · Esc to cancel
```

- Esc 또는 1번을 고르면 빈 입력창으로 돌아오고 hc 상태는 `error`가 된다. 메뉴를 닫은 뒤 같은 세션에 다시 입력하면 메뉴는 다시 뜨지 않는다.
- **메뉴가 열린 동안 터미널에 들어온 글자는 프롬프트가 아니라 메뉴 조작이 된다.** [추론, 미검증] 3번은 유료 사용 크레딧으로 바꾸는 선택이라 일부러 시험하지 않았다. 감독은 `StopFailure`를 받으면 그 세션에 아무것도 넣지 않고 끝내야 한다(`accounts.md` §5의 1번 "입력 정지"와 같은 방향).
- `autoContinueAtUsageLimit`: 기본값(true)과 false에서 같은 메뉴(선택지 셋, 2번 포함)가 뜨고 훅·상태줄 신호도 같았다. 기본값에서도 26초 동안 기다리기가 저절로 시작되지 않았다. [추론] 문서는 자동 이어가기를 "작업 도중에 한도로 멈췄을 때"로 적는데, 이번 표본은 첫 요청이 바로 거절된 경우라 그 길을 타지 않은 것으로 보인다. 작업 도중 멈춤은 못 봤다. 그래서 "false면 자동 대기가 시작되지 않는다"는 아직 문서 근거뿐이다. false여도 메뉴의 2번은 남는다.
- 사용자 설정을 빼고 띄운 실행 하나에서는 한도 메뉴를 닫은 뒤 한도와 무관한 다른 물음 화면이 한 번 떴다. 감독형 실행에서도 뜰 수 있는 대화상자다.

### API 키 쪽: 틀린 키(401) [확인, 실측]

실행 스크립트를 확인하려고 일부러 틀린 가짜 키로 한 번씩 돌렸다. 비밀도 비용도 들지 않는다. 빈 계정 폴더와 빈 OpenCode 데이터 경로에서 `ANTHROPIC_API_KEY` 하나만 준 환경이다.

- `claude -p`: `system/init`의 `apiKeySource: "ANTHROPIC_API_KEY"`. assistant는 `model: "<synthetic>"`, `error: "authentication_failed"`, `api_error_status: 401`, `api_error_type: "authentication_error"`. result는 `subtype: "success"`, `is_error: true`, `terminal_reason: "api_error"`, `api_error_status: 401`, `result: "Invalid API key · Fix external API key"`. `StopFailure` 훅은 `error: "authentication_failed"`(`error_details` 없음). 종료 코드 1. `system/api_retry`도 `rate_limit_event`도 없고 0.25초 만에 최종 실패했다.
- OpenCode `run --standalone --format json`: stdout은 사건 하나뿐이다. `type: "error"`이고 `error`는 `type: "provider.auth"`, `message: "invalid x-api-key"`, `status: 401`, `response.body`(API 오류 JSON 문자열)다. `response.body` 안에 `error.type: "authentication_error"`와 요청 ID가 그대로 남고 응답 헤더는 없다. 종료 코드 1, stderr 비어 있음. error 사건과 종료 코드가 함께 온다. `accounts.md` §2.5가 소스에서 읽은 모양과 같다.

### 판정표와 다른 곳

처리 방향(무엇을 다음 후보로 넘기고 무엇을 기다리는지)이 틀린 곳은 없다. 아래 넷을 `accounts.md`에 고쳤다.

| 어디 | 옛 문구 | 실측 | 고친 것 |
|---|---|---|---|
| §2.4 | "어느 창인지 알려 주는 공개 칸은 없다" | 문서에는 없지만 `rate_limit_info.rateLimitType`과 `unifiedWindows`가 온다. `resetsAt`도 걸린 창의 것이다 | 문서에 없는 칸이 2.1.325에서 온다. 있으면 창과 리셋 시각으로 쓰고, 없으면 미관측. 버전 고정과 시험 고정값에 넣는다(O17) |
| §2.4 | 최종 실패 + `error=rate_limit` → 구독 한도 | 맞다. 더 좁은 값이 같이 온다(`api_error_status: 429`, `api_error: "usage_limit_reached"`, `terminal_reason: "api_error"`) | 구독 한도의 확정 조건을 assistant `error=rate_limit` 그리고 result의 `is_error: true`·`api_error: usage_limit_reached`로 좁혔다. `usage_limit_reached`가 아니면 미상 |
| §2.4 | `system/api_retry`는 재시도 중 | 구독 한도에서는 아예 나오지 않는다 | 구독 한도 거절은 `api_retry` 없이 바로 최종 실패다. `api_retry`가 보이면 한도가 아닌 다른 오류다 |
| §2.3 | `five_hour`·`seven_day`에 값이 있다 | 두 계정 모두 `seven_day`만 왔다. 대화형에서는 한도 메뉴가 닫힐 때까지 상태줄이 돌지 않는다 | 창 하나만 올 수 있다. 감독은 한도 직후의 상태줄을 기다리지 않는다. 대화형에서 리셋 시각을 모르면 "모름"(30분 규칙) |

틀린 곳은 아니지만 함께 적은 것:

- §2.1: 감독의 턴 ID는 여전히 없지만 Claude Code가 주는 `prompt_id`가 있다(아래).
- §2.2: `StopFailure`의 `error: rate_limit`는 실측과 같다. `error_details`는 오지 않았다. 창은 훅만으로 모른다는 문구도 그대로 맞다(`last_assistant_message`에 "weekly"가 있지만 규칙대로 신호로 쓰지 않는다).
- §2.4의 "오류 종류 없음 + 429 + 마지막 `rejected`": 이 모양은 못 봤다. 오류 종류가 있었다.
- §2.4의 `credits_required`: 오지 않았다. [추론] 이 계정은 사용 크레딧이 꺼져 있어서 그런 것으로 보인다.
- `spec.md` §8.2 2번: 문구는 실측과 어긋나지 않았다. 구독 쪽 세 가지를 더했고 API 쪽 문장은 표본이 없어 그대로 뒀다.

### 훅·상태줄을 어느 턴의 것으로 이을 수 있는가(할 일 6)

**이을 수 있다. 조건은 입력을 한 번에 하나만 넣는 것이다.**

- [확인, 실측] `UserPromptSubmit`과 그 턴의 `StopFailure`(정상이면 `Stop`)는 같은 `prompt_id`를 갖는다. 같은 세션에 두 번 입력했을 때 값이 서로 달랐고, 각 `StopFailure`는 자기 입력의 값과 같았다.
- [추론] 감독의 연결법: 입력을 넣는다 → `UserPromptSubmit` 훅에서 `prompt_id`를 받아 감독의 턴 ID에 묶는다 → 같은 `session_id`·`prompt_id`의 `StopFailure`/`Stop`만 그 턴의 결과로 받는다. 묶이지 않는 값이 오면 미상이다.
- [확인, 실측] 늦은 훅: `StopFailure`는 입력 0.4~0.5초 뒤, 다음 입력 전에 왔다. 헤드리스에서는 result 줄이 나온 뒤 1ms에 훅이 돌았고 프로세스는 그 0.8초 뒤에 끝났다. [추론] 감독은 result를 읽자마자 판정을 닫지 말고 프로세스 종료까지 훅을 기다려야 한다.
- [확인, 실측] 상태줄의 `prompt_id`는 턴 귀속에 못 쓴다. 한도 메뉴를 닫으면 `UserPromptSubmit` 훅 없이 새 `prompt_id`가 생기고 상태줄과 `SessionEnd`가 그 값을 싣는다. 상태줄은 "가장 최근 값"으로만 읽는다.
- [확인, 실측] hc로 넣은 입력은 훅의 `prompt` 칸에 `<hc from="…">글</hc>` 꼴로 감싸여 온다. 훅의 `prompt` 글로 턴을 맞추면 어긋난다.

모델이 낸 출력이 신호로 섞이는가:

- [확인, 실측] 한도 오류는 구조로 구별된다. 훅은 `hook_event_name: StopFailure`, 헤드리스는 assistant의 `message.model: "<synthetic>"` + `is_api_error_message: true` + 최상위 `error`, result의 `is_error: true` + `api_error_status`. 정상 턴은 `Stop` 훅, 실제 모델 이름, `is_error: false`다.
- [추론] 그래서 모델이 한도 문구 같은 글을 답으로 내도 `Stop`·`is_error: false`로 온다. 감독이 글(`result`, `last_assistant_message`, 화면)을 읽지 않는 한 섞이지 않는다. 모델에게 그 글을 일부러 쓰게 하는 시험은 하지 않았다.

### 표본별 봄 / 못 봄

| 표본(할 일 4) | 결과 |
|---|---|
| 구독의 실제 실패: 주간 한도, 첫 요청에서 거절 | 봄(헤드리스 1, 대화형 2) |
| 구독의 실제 실패: 5시간 창 | 못 봄 |
| 구독의 실제 실패: 작업 도중 멈춤(자동 이어가기) | 못 봄 |
| 경고만(`allowed_warning`) | 못 봄(정상 `allowed`만 봄) |
| 거절 뒤 같은 턴 성공 | 못 봄 |
| `system/api_retry`와 최종 실패의 갈림 | 반만 봄: 구독 한도는 `api_retry` 없이 최종 실패. `api_retry`가 나오는 경우는 못 봄 |
| `rate_limit_event`와의 순서 | 봄(실패·성공 한 번씩) |
| 400 셋(요청 오류, 지출 한도, 모르는 본문) | 못 봄 |
| 401 키 오류 | 봄(일부러 틀린 가짜 키. 철회·만료된 진짜 키는 못 봄) |
| 402 결제 오류 | 못 봄 |
| 429 넷(분당, `ramp_limit_exceeded`, workspace 지출 한도, `enforced_spend_limit_reached`) | 못 봄. 본 429는 구독의 `usage_limit_reached`뿐이다 |
| 실제 크레딧 소진 | 못 봄 |
| OpenCode `provider.auth` | 봄 |
| OpenCode의 나머지 `error.type`(`provider.quota`, `provider.rate-limit`, `provider.invalid-request`, 계정 문제가 아닌 것들) | 못 봄 |

- 못 본 표본은 O17에서 **미상**으로 다룬다.
- **소진과 결제 장애를 신호로 가를 수 있는가: 아직 안 됨.** 표본이 하나도 없다. B-17의 미상 보류가 그대로 적용된다.
- 경고만으로 넘어가지 않는가(할 일 5): 최상위 `status`가 `rejected`이고 턴이 최종 실패일 때만 한도로 본다는 규칙은 실측과 맞는다. 거절된 턴 안에서도 `unifiedWindows`의 한 칸이 `allowed_warning`이었으므로 안쪽 칸의 상태로 판정하면 안 된다. 한도 뒤 정상 성공(사용 크레딧)이 섞이는 경우는 못 봤다(`isUsingOverage: false`).
- OpenCode의 한도·지출 한도 신호를 감독이 결정적으로 읽을 수 있는지(B-08의 "막히면")는 `provider.auth` 하나만 봐서 아직 답하지 못한다. 크레딧 후보는 계속 꺼 둔다(D-15).

### 남은 일

| 표본 | 필요한 것 | 누가 |
|---|---|---|
| API 지출 한도(400, workspace 429), `claude -p`와 OpenCode 둘 다 | 올리브 전용 Console workspace의 키(O05와 같은 키)와 낮은 지출 한도. O05의 작은 실행(크레딧 차감 확인)이 먼저 끝나야 한다(한도를 먼저 낮추면 O05의 실행이 막힌다). 그 뒤 지출 한도를 이미 쓴 양 이하로 낮추면 추가 사용 없이 다음 요청이 한도 응답을 받는다. Console이 그렇게 낮은 값을 받지 않으면 모자란 만큼을 호출로 채워야 하는데, 그것은 일부러 태우는 호출이라 관리자가 따로 정한다 | 관리자(Console, 자격 보관), 그 뒤 에이전트 |
| 크레딧 소진, 402, `enforced_spend_limit_reached`, `ramp_limit_exceeded` | 자연히 만날 때를 기다린다. 일부러 만들지 않는다 | 기다림 |
| 5시간 창, 작업 도중 멈춤, `allowed_warning`, 거절 뒤 같은 턴 성공 | 자연히 만날 때 같은 관측 장치로 다시 모은다 | 기다림 |

2026-11-16 기준 상태:

- 관리자가 두 계정 모두 전용 workspace·지출 한도·키의 준비를 마쳤다고 답했다.
- 첫 시도는 모델 호출까지 가지 못했다(자격을 읽는 CLI가 로그인돼 있지 않았다).
- O05의 실행이 아직 돌지 않아 workspace의 사용량이 0이다. 지금 돌리면 한도 응답이 아니라 정상 응답이 와서 크레딧을 쓰고 O05의 차감 확인과 섞인다. O05가 끝나고 한도가 쓴 양 이하로 낮춰질 때까지 돌리지 않는다.
- 자격 조회가 남기는 암호화된 백업 폴더(`infra/README.md` 2절)가 쓰기 불가인지는 검증 작업자가 확인하지 못했다. 관리자나 O05 쪽에서 확인한다.

### 이 결과로 고친 곳

- `accounts.md` §2.1(`prompt_id`), §2.2, §2.3, §2.4, §2.5, §2.6(본 범위), §10(O04 줄).
- `spec.md` §8.2 2번(구독 쪽), §8.3(OpenCode 신호의 미확인 범위), §13(계정 전환 줄).
- O09 5번·O10 5번(한도 메뉴와 입력 정지), O17 2번(판정 조건과 턴 귀속).
