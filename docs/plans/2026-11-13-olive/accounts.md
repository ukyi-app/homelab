# 올리브의 계정 전환

계정 전환(O17)과 그 앞의 검증 셋(O03·O04·O05)의 구현 기준이다. 이 문서는 조사 초안(저장소 밖)을 줄인 것이고, 관리자 결정은 `spec.md` §5.1이 기준이다. 초안과 §5.1이 다르면 §5.1이 이긴다. 감독·실행기·hc는 `supervisor.md`, Discord 글은 `discord.md`를 따른다.

- 상태: 구현 전. D-40(구독 토큰 인증 실패 때의 전환)과 D-41(수동 선택의 유지 기간)은 관리자 결정이다. §9의 여섯 항목은 기본값(관리자 미확정, `spec.md` §5.2 B-17)이다. 표의 처리·시각·상태 이름은 따로 적지 않으면 [추론]이다.
- 표시: [확인] 공식 문서, 저장소, OpenCode v2.1.0 소스를 읽은 것(조사 초안의 대조가 맞다고 적은 것만. 돌려 본 것이 아니다), [추론] 그 근거에서 낸 설계, [미확인] 실제로 돌려 봐야 아는 것. "[확인, O03 실측]"과 "[확인, O04 실측]"만 실제로 돌려 본 것이다(2026-11-16, Claude Code 2.1.325, OpenCode v2.1.0. 범위는 그 티켓의 "결과"). "[확인, O05]"는 실제로 돌린 뒤 관리자가 Console·claude.ai 화면에서 보고 답한 것이다(2026-11-16. 에이전트는 화면을 보지 않았다).
- 검증 상태(2026-11-16): O03은 돌려 본 다섯 경우를 마쳤고 `claude-work` → `claude-sub` 쌍과 장기 토큰이 남았다. O04는 끝났다: 구독 주간 한도, 틀린 키(401), API workspace 지출 한도(400, `claude -p`와 OpenCode)를 봤고 크레딧 소진·402·API의 429는 못 봤다. O05는 끝났다: 두 계정 모두 `claude -p`와 OpenCode의 사용이 포함 크레딧에서 차감됐다. 두 검증이 끝나 D-15의 "검증 전에는 `claude-work`부터" 조건은 찼다(관리자 확인 2026-11-16). 크레딧 후보를 실제로 켜는 것은 O17이다.
- 근거: `homelab`의 `5f85a642`, 옛 봇 `ukyi-app/homelab-bot`의 `02f5f3ff`, 2026-11-14에 읽은 공식 문서(끝의 링크).
- 명령·상태 이름과 숫자는 초안이다. 예시의 계정 상태·시각·건수는 모두 가짜다.

## 1. 한눈에 보기

감독이 계정과 방식을 실행마다 고정한다. 실제 실패가 확인됐을 때만 옛 실행을 끝내고 다음 후보로 넘긴다. 모델의 글이나 기억으로 계정을 바꾸지 않는다.

| 역할 | 순서 | 크레딧 단계의 실행 도구 |
|---|---|---|
| 오케스트레이터 | `claude-work` → `claude-sub` → `claude` (크레딧 단계 없음) | 해당 없음 |
| 하위 에이전트 | 포함 API 크레딧(`claude-sub` 것 → `claude` 것) → `claude-work` → `claude-sub` → `claude` | OpenCode(그 계정의 Console API 키) |

`spec.md` §8.3과 같다(D-09, D-14, D-15). O04·O05의 검증 전에는 하위 에이전트도 `claude-work`부터 쓰기로 했고, 두 검증은 2026-11-16에 끝났다. Codex로 도는 조사·PR 리뷰 작업자는 순서 밖이다(B-08).

| 일어난 일 | 하는 일 | Telegram | 기준 |
|---|---|---|---|
| 한도 경고, 거절 뒤 같은 턴이 정상 완료 | 그대로 둔다 | 없음 | §2 |
| 구독 한도로 턴이 실패 | 한도로 적고 다음 후보로. 리셋 + 1분(모르면 30분)에 실제 일로 확인 | 넘어감·돌아옴, 구간마다 한 번씩 | D-09 |
| 크레딧 소진(O04가 입증한 모양만) | 다음 후보로. 그 계정의 다음 지급 예정일 뒤 실제 일로 확인 | 두 크레딧이 다 떨어져 구독으로 갈 때 한 번 | D-16 |
| API 결제 오류(입증된 모양만), API 키 인증 실패 | 그 계정의 API만 잠그고 다음 후보로 | 바로 | D-16 |
| 구독 토큰 인증 실패 | 그 구독만 잠그고 다음 후보로 | 바로 | D-40 |
| 접근 정책 거절 | 넘어가지 않고 기다린다 | 바로 | D-40 |
| 소진인지 결제 장애인지 못 가른 API 오류 | 잠그지 않고 "미상 보류", 다음 후보로 | 한 번 | B-17 |
| 지출 상한 | 그 계정·그 한도 범위만 기다리고 다음 후보로 | 넘어감에 합침 | B-17 |
| 분당 제한, 과부하, 요청 오류, 취소, 미상 | 같은 계정에서 기다린다. 계정 상태는 그대로 | 없음 | §2 |
| 쓸 후보가 없음 | 기다린다. Discord는 자리 비움 | 역할마다 한 번 | §8 |
| 관리자의 수동 선택 | 다음 안전 경계부터 정한 시간(기본 24시간)까지 | 고른 계정이 한도에 걸리면 | D-41 |

잠금은 관리자가 CLI로 풀 때까지다. 비상 정지 중에는 자동 전환·재확인·복귀를 모두 멈춘다(D-21).

## 2. 판정표

### 2.1 신호를 받는 규칙

- 판정 단위는 한 턴이다. 신호를 감독이 낸 실행 ID·세대·턴·계정·방식에 묶는다. 옛 세대나 다른 실행의 신호는 근거가 아니다.
- 같은 턴에 경고·거절·완료가 섞이면 최종 결과를 기다린다. 최종 실패면 그 실행의 새 입력을 먼저 막고 원인을 가른다. 순서는 검증된 구체 원인 → 일반 오류 종류 → 미상이다.
- 취소, 강제 종료, 훅 누락, 종료 코드만으로는 한도가 아니다. 모델이 낸 출력, 화면 글자, `last_assistant_message`는 신호가 아니다. 오류 원문은 저장하지 않는다. 예외는 하나다: 도구가 구조로 API 오류라고 표시한 줄(§2.4의 `is_api_error_message` assistant·`is_error` result, §2.5의 `response.body`)에 한해 API 오류 문구가 정해진 접두어로 시작하는지만 본다. 지출 한도는 상태 코드와 오류 종류가 일반 요청 오류와 같아 이것으로만 갈린다 [확인, O04 실측]. 접두어가 안 맞으면 미상이다. 이 예외는 관리자가 2026-11-16에 받았다.
- 대화형 훅에는 감독의 턴 ID가 없다. 입력을 한 번에 하나만 처리하고 순번·세션·세대로 잇는다. 가르지 못하면 미상이다(O04·O09).
- [확인, O04 실측] Claude Code가 주는 `prompt_id`(사용자 입력마다의 UUID, 훅의 공통 칸)로 턴을 이을 수 있다. `UserPromptSubmit`과 그 턴의 `StopFailure`(정상이면 `Stop`)가 같은 값을 갖는다. [추론] 감독은 입력을 넣고 `UserPromptSubmit`에서 받은 `prompt_id`를 자기 턴 ID에 묶은 뒤, 같은 `session_id`·`prompt_id`의 `StopFailure`/`Stop`만 그 턴의 결과로 받는다. 묶이지 않는 값은 미상이다.
- [확인, O04 실측] 상태줄의 `prompt_id`는 턴 귀속에 쓰지 않는다. 한도 메뉴를 닫으면 `UserPromptSubmit` 없이 새 값이 생긴다. hc로 넣은 입력은 훅의 `prompt` 칸에 감싸여 오므로 그 글로 턴을 맞추지도 않는다.
- [확인, O04 실측] 헤드리스에서 `StopFailure` 훅은 result 줄 뒤에 돌았고 프로세스는 그 뒤에 끝났다. [추론] 감독은 result를 읽자마자 판정을 닫지 말고 프로세스 종료까지 훅을 기다린다. 사건의 앞뒤 순서(성공과 실패에서 달랐다)에는 기대지 않는다.
- 한쪽 방식의 잠금·소진을 같은 계정의 다른 방식에 복사하지 않는다.

### 2.2 Claude Code 대화형: `StopFailure`

[확인] API 오류로 턴이 끝날 때의 알림 훅이다. 출력이나 종료 코드로 다음 실행을 정하지 않는다. `error`는 아래 12종이다([훅][hooks]). [확인, O04 실측] 구독 주간 한도에서는 입력 약 0.5초 뒤에 `error: rate_limit`가 오고 `error_details`는 오지 않았다. 틀린 API 키에서는 `authentication_failed`가 왔다. API 키의 workspace 지출 한도(400)에서는 `unknown`이 왔다(헤드리스의 훅. 그래서 훅만으로는 지출 한도를 가를 수 없고, API 키는 대화형에 쓰지 않는다, B-08). [미확인] 나머지 값과 5시간 창·작업 도중 멈춤의 순서(O04의 남은 표본).

[확인, O04 실측] 대화형에서 구독 한도로 턴이 거절되면 화면에 고르는 메뉴가 열리고, 그동안 터미널에 들어온 글자는 프롬프트가 아니라 메뉴 조작이 된다(선택지에 유료 사용 크레딧으로 바꾸기가 있다). 그래서 감독은 `StopFailure`를 받으면 그 세션에 아무것도 넣지 않고 끝낸다(§5의 1번).

| `error` | 처리 |
|---|---|
| `rate_limit` | 구독 한도. 다음 후보로. 어느 창(5시간·주간)인지는 이 값만으로 모른다 |
| `authentication_failed` | 그 구독만 잠그고 다음 후보로(D-40). 만료인지 철회인지는 모른다 |
| `oauth_org_not_allowed`, `account_on_hold` | 접근 정책 거절. 넘어가지 않고 그 역할이 기다린다(D-40) |
| `billing_error` | 구독 쪽 결제 장애. 기다리고 알린다. 같은 계정의 API는 잠그지 않는다 |
| `overloaded`, `server_error` | 일시 장애. 도구의 재시도가 끝난 뒤 판단한다 |
| `invalid_request`, `model_not_found`, `max_output_tokens` | 요청·모델·출력 길이 문제. 그 일만 기다리고 계정은 그대로 |
| `cloud_credential_error`, `unknown` | 미상으로 기다린다 |

### 2.3 상태줄: 보조 관측

- [확인] `rate_limits.five_hour`·`seven_day`에 `used_percentage`(0~100)와 `resets_at`(Unix epoch 초)이 있다. 첫 응답 전이나 리셋 시각 뒤에는 칸이 없을 수 있다([상태줄][statusline]). `rate_limits.spend_limit.*`는 Console 크레딧 잔액이 아니다.
- 사용률만으로 넘어가지 않는다. 실패 뒤 어느 창인지와 다시 확인할 시각을 정하는 데만 쓴다. 칸이 없으면 "미관측"이다.
- [확인, O04 실측] 창이 하나만 올 수 있다(본 두 계정 모두 `seven_day`만 왔다). 대화형에서는 한도 메뉴가 닫힐 때까지 상태줄이 돌지 않았다(26초). 그래서 감독은 한도 직후의 상태줄을 기다리지 않는다. 대화형에서 리셋 시각을 모르면 "모름"으로 두고 30분 규칙(§3)을 쓴다.

### 2.4 Claude 헤드리스(`claude -p`, SDK)

| 신호 | 처리 |
|---|---|
| `rate_limit_event`의 `allowed`, `allowed_warning` | 관측만 적는다 |
| `rejected` 뒤 같은 턴이 정상 완료 | 완료로 본다 |
| `system/api_retry` | 재시도 중이다. 최종 실패가 아니다. 감독이 밖에서 재시도를 더하지 않는다. 구독 한도 거절에서는 나오지 않으므로(아래), 이것이 보이면 한도가 아닌 다른 오류다 |
| 구독 턴의 최종 실패: assistant `error=rate_limit` 그리고 result의 `is_error: true`·`api_error: usage_limit_reached` | 구독 한도 → 다음 후보 |
| 구독 턴의 최종 실패 + assistant `error=rate_limit`인데 `api_error`가 `usage_limit_reached`가 아님(분당 제한 등 못 본 모양) | 미상 |
| 구독 턴의 최종 실패 + 오류 종류 없음 + 429 + 마지막 이벤트 `rejected` | O04가 이 모양을 보지 못했다. 표본이 생기기 전에는 미상 |
| 최종 실패 + assistant `error=authentication_failed` + result의 `is_error: true`·`api_error_status: 401` | 구독이면 §2.2의 `authentication_failed`, API 키면 §2.6의 401로 가른다 |
| API 키 턴의 최종 실패: assistant `message.model: "<synthetic>"`·`is_api_error_message: true`, result의 `is_error: true`·`api_error_status: 400`·`api_error_type: invalid_request_error`, 그리고 result 글이 `API Error: 400 You have reached your specified workspace API usage limits`로 시작 | workspace 지출 한도 → §2.6. 구조 칸이 맞아도 접두어가 다르면 §2.6의 400 줄로 가른다 |

- [확인] 결과의 `subtype`이 `success`여도 `is_error`가 참일 수 있다. `error_max_turns`·`error_max_budget_usd`는 로컬 실행 상한이다([SDK][sdk]).
- [확인] `stream-json`은 재시도 전에 `system/api_retry`를 낸다(`attempt`, `max_retries`, `retry_delay_ms`, `error_status`, 위 12종의 `error`). `rate_limit_event`는 SDK 참조에만 있다([헤드리스][headless]).
- [확인] `errorCode`의 공개 값 `credits_required`는 구독의 포함 사용량이 떨어져 사용 크레딧을 사야 이어진다는 뜻이다. Console 크레딧과 무관하다. 어느 창인지 알려 주는 칸은 공식 문서에 없다.
- API 키로 돈 헤드리스의 `error=rate_limit`는 §2.6으로 가른다.

[확인, O04 실측] 구독 주간 한도에 걸린 계정의 첫 요청(2.1.325, 표본 하나):

- 재시도 없이 약 0.6초 만에 최종 실패한다. 순서는 `rate_limit_event`(`rejected`) → assistant(`error: rate_limit`, `api_error_status: 429`, `api_error: "usage_limit_reached"`, `message.model: "<synthetic>"`) → result(`subtype: success`, `is_error: true`, `terminal_reason: "api_error"`) → `StopFailure` 훅이고 종료 코드는 1이다. `system/api_retry`는 한 번도 나오지 않았다.
- 문서에 없는 칸이 온다: `rate_limit_info.rateLimitType`(`seven_day`)과 `unifiedWindows`(창마다의 `status`·`resetsAt`). `resetsAt`도 걸린 창의 것이다. 있으면 창과 리셋 시각으로 쓰고, 없으면 미관측이다. 문서에 없는 칸이라 버전을 고정하고 시험 고정값에 넣는다(O17).
- 판정은 최상위 `status`와 턴의 최종 결과로만 한다. 거절된 턴 안에서도 `unifiedWindows`의 한 칸은 `allowed_warning`이었다.
- 성공한 턴에도 `rate_limit_event`(`allowed`)가 온다. `overageStatus`는 정상 턴에도 `rejected`로 실려 있어 판정에 쓰지 않는다.
- `utilization`·`errorCode`(`credits_required`)는 오지 않았다.
- [미확인] 5시간 창, 작업 도중의 멈춤, 경고만 온 턴(`allowed_warning`), 거절 뒤 같은 턴의 성공, `system/api_retry`가 나오는 경우.

[확인, O04 실측] API 키의 workspace 지출 한도(2.1.325, `claude -p` 두 번, 같은 응답):

- 재시도 없이 init 뒤 약 0.35초에 최종 실패한다. 순서는 assistant(`message.model: "<synthetic>"`, `is_api_error_message: true`, `error: "unknown"`, `api_error_status: 400`, `api_error_type: "invalid_request_error"`, 토큰 0) → result(`subtype: success`, `is_error: true`, `terminal_reason: "api_error"`, 같은 400 칸) → `StopFailure`(`error: "unknown"`) 훅이고 종료 코드는 1, stderr는 비어 있다.
- 글(assistant 본문과 result의 `result`): `API Error: 400 You have reached your specified workspace API usage limits. You will regain access on <날짜> at 00:00 UTC.` 이번 날짜는 다음 달 1일이었다.
- `system/api_retry`, `rate_limit_event`, `api_error` 칸은 없다. `rate_limit_event`는 API 키의 정상 턴에도 오지 않았다(구독 턴에만 온다).
- Claude Code의 `error` 분류는 `unknown`이다(`invalid_request`가 아니다). 그래서 `error`만 보면 미상이고, 위 표의 구조 칸 + 접두어로만 지출 한도가 된다.

[확인, O03·O04 실측] 인증 실패(틀린 API 키)는 result가 `subtype: success`인 채 `is_error: true`, `api_error_status: 401`로 오고 종료 코드는 1이다. 재시도도 `rate_limit_event`도 없다. 이어 연 세션에서 실패하면 **실패한 턴도 기록에 덧붙는다.** 그래서 감독은 `subtype`이 아니라 `is_error`를 보고, 실패할 수 있는 이어 열기는 기록의 복사본에서 연다.

### 2.5 OpenCode

[확인] v2.1.0 소스에서 `run --format json`은 실패를 `type: "error"` 사건으로 내고 종료 코드 1로 끝난다. `error`에는 `type`, `message`, 있으면 `status`와 `response.body`만 있고 응답 헤더와 `retryAfterMs`는 없다([소스][oc]). 아래 "뜻"도 소스를 읽은 것이고 실측이 아니다.

| 최종 `error.type` | 소스에서의 뜻 | 처리 |
|---|---|---|
| `provider.auth` | 인증 오류(통합 인증 오류 포함) | status·본문으로 키 인증 실패를 확정하면 API 잠금 → 다음 후보 |
| `provider.quota` | 402, billing 코드, "usage limits" 문구의 429(등급 상한). 재시도 없음 | 이 값만으로 소진이라 하지 않고 §2.6으로 가른다 |
| `provider.rate-limit` | 분당 429. 안에서 최대 10회 재시도 | 같은 계정에서 기다린다 |
| `provider.invalid-request` | 직접 건 지출 한도의 400도 이 값 [확인, O04 실측] | `response.body`의 `error.message` 접두어로 가르고(아래), 모르면 미상 |
| `provider.internal`·`transport`·`timeout`·`invalid-output`·`unknown`, `aborted` | 일시 장애, 미상, 취소 | 기다린다 |
| `provider.content-filter`·`unsupported-operation`·`no-route`, `permission.rejected`, `tool.execution` | 계정 문제가 아니다 | 계정 상태를 바꾸지 않는다 |

- [확인] OpenCode는 `error.details.error_code`를 읽지 않으므로 감독이 `response.body`에서 꺼낸다. 조직 한도와 workspace 한도는 본문의 접두어("specified API…" 대 "specified workspace API…")로만 갈린다. 요청된 대기는 15분으로 잘리고 시간 초과 재시도는 3회까지다.
- 감독은 도구가 낸 최상위 사건만 스키마 검사 뒤 읽는다. 본문은 메모리에서만 보고 사유 코드와 시각만 남긴다.
- [확인, O04 실측] 틀린 키에서 설치본(v2.1.0)은 위 모양을 냈다: stdout에 `type: "error"` 사건 하나(`error.type: "provider.auth"`, `status: 401`, `response.body`에 API 오류 JSON), 응답 헤더 없음, 종료 코드 1. error 사건과 종료 코드가 함께 온다.
- [확인, O04 실측] workspace 지출 한도에서 설치본(v2.1.0)은 stdout에 약 0.9초 만에 `type: "error"` 사건 하나를 내고 종료 코드 1로 끝났다(두 번, 같은 응답). `error.type: "provider.invalid-request"`(`provider.quota`가 아니다), `status: 400`, `message`는 API 문구 그대로, `response.body`는 API 오류 JSON 문자열(`error.type: "invalid_request_error"`, `error.message`, 요청 ID). `error.details.error_code`와 응답 헤더는 없고 안에서 재시도한 흔적도 없다. stderr는 비어 있다.
- [확인, O04 실측] **감독은 이 신호를 결정적으로 읽을 수 있다.** 조건: 최상위 `type: "error"` + `error.type: "provider.invalid-request"` + `status: 400`, 그리고 `response.body`를 JSON으로 읽어 `error.type: "invalid_request_error"`이고 `error.message`가 `You have reached your specified workspace API usage limits`로 시작한다. 하나라도 어긋나면 미상이다. `error.type`과 `status`만으로는 일반 요청 오류와 같아서 가를 수 없다. 복귀 시각은 문구의 `You will regain access on <날짜> at 00:00 UTC`에서 읽고(§3), 꼴이 다르면 모름이다 [추론].
- [미확인] `provider.quota`(402, 등급 상한 429), `provider.rate-limit`, 조직 지출 한도의 문구, 계정 문제가 아닌 `error.type`을 설치본이 실제로 이 모양으로 내는지(자연히 만날 때). 그 전에는 미상으로 다룬다.

### 2.6 HTTP: 직접 Anthropic API

프록시가 낸 401·429와 도구가 출력한 JSON은 이 표 밖이다. 신호 열은 [확인]이다([오류][errors], [한도][limits]).

| 신호 | 처리 |
|---|---|
| 400 + 문서에 있는 조직·workspace 지출 한도 문구 | 지출 한도. 그 계정·그 범위만 기다리고 다음 후보로(B-17). [확인, O04 실측] workspace 쪽은 `invalid_request_error` + `You have reached your specified workspace API usage limits. You will regain access on <날짜> at 00:00 UTC.`로 왔다. 조직 쪽 문구는 못 봤다 |
| 400, 알려진 요청 오류 | 그 일만 기다린다 |
| 400, 모르는 본문(400은 목록에 없는 다른 4XX에도 쓰일 수 있다) | 미상. O04 샘플 전에는 요청 문제로 닫지 않는다 |
| 401 `authentication_error` | 키 인증 실패가 확인되면 API 잠금 → 다음 후보. 경로·설정 오류면 미상 |
| 402 `billing_error`(결제 정보의 문제) | O04의 소진 샘플과 같으면 소진 규칙. O04가 결제 장애로 입증한 모양이면 API 잠금 → 다음 후보. 어느 쪽인지 가르지 못하면 잠그지 않고 미상 보류(B-17) |
| 429, 분당 요청·토큰 제한 또는 `ramp_limit_exceeded`(`retry-after` 있음) | 같은 계정에서 기다린다. 계정을 돌리지 않는다 |
| 429, Claude Code workspace의 지출 한도(`retry-after` 있음) | 지출 한도 |
| 429, `enforced_spend_limit_reached`(등급의 월 지출 상한. `retry-after` 없음, 다음 달 1일 00:00 UTC에 풀림) | 지출 한도 → 다음 후보. 크레딧 소진과 다른 시계다 |
| 429뿐이고 세부 원인이 없음 | 미상. `retry-after`가 있다는 것만으로 분당 제한이라 하지 않는다 |

[미확인] 실제 크레딧 소진의 모양. 공식 문서에 소진의 상태 코드·종류가 없다 [확인]. O04·O05가 샘플로 입증한 모양만 소진으로 적는다. 가르지 못한 것은 미상 보류다(B-17).

O04는 2026-11-16에 이 표의 줄 가운데 401(일부러 틀린 가짜 키. 철회·만료된 진짜 키는 아니다)과 400 workspace 지출 한도(`claude -p`·OpenCode 두 번씩)를 봤다. 도구 출력에는 응답 헤더가 없어 `retry-after`는 어느 경우에도 볼 수 없다. 조직 지출 한도 400, 일반 요청 오류 400, 402, API의 429, 크레딧 소진은 표본이 하나도 없다. 그래서 소진과 결제 장애를 신호로 가를 수 있는지는 "안 됨"이고, 못 본 줄은 O17에서 미상으로 다룬다.

## 3. 상태와 복귀 시각

- 역할은 순서만 갖고, 쓸 수 있는지는 공용 계정 장부에서 읽는다. 작업자가 확인한 `claude-work`의 한도는 오케스트레이터도 안다.
- 후보에서 빼는 조건: 미등록·꺼짐, 자격 묶음 불일치, 잠금, 풀리지 않은 한도·소진·미상 보류·지출 한도, API 검증 게이트(O04·O05. 둘 다 2026-11-16에 끝났다), 비상 정지. 한 번의 전환에서 후보마다 한 번만 시도한다. 등록되지 않은 계정·다른 모델·다른 실행 도구로 바꾸지 않는다.

| 원인 | 첫 재확인 | 그 뒤 |
|---|---|---|
| 구독 한도, 리셋을 앎 | 걸린 창이 모두 풀리는 가장 늦은 시각 + 1분 | 실제 일의 성공으로만 복귀 |
| 구독 한도, 리셋을 모름 | 실패를 본 때 + 30분 | 일이 있을 때만 한 번. 또 실패하면 새로 예약 |
| 크레딧 소진 | 그 계정의 다음 지급 예정일 뒤 | 늦으면 일이 있을 때 30분 간격, 24시간 뒤에도 없으면 한 번 알림(B-17) |
| 미상 보류 | 하루 한 번, 그리고 다음 지급 예정일 뒤 | CLI로 앞당길 수 있다(B-17) |
| 지출 한도, 분당 제한 | 그 한도가 풀리는 시각, `retry-after`. workspace 지출 한도는 API 문구의 `You will regain access on <날짜> at 00:00 UTC`(O04에서 다음 달 1일), 꼴이 다르면 모름(30분) | 크레딧 지급 예정일을 대신 넣지 않는다 |
| 잠김 | 없음 | CLI로 푼 뒤 다음 실제 일로 확인 |

- **복귀는 타이머가 아니라 실제 일의 성공으로 확정한다.** 빈 확인용 호출을 만들지 않는다. 기동·Ready는 증거가 아니다. 확인은 계정·방식마다 한 실행만 맡는다.
- 작업자는 지금 일을 마친 뒤 다음 일부터 앞 후보를 쓴다. 오케스트레이터는 턴 경계에서 바꾼다.
- [확인] 크레딧은 구독 결제 주기마다, 결제가 처리된 뒤 곧 들어온다. 연간 플랜도 매달 들어오고 이월되지 않는다. 달력의 1일이라는 말은 없다([크레딧][credits]). 지급이 결제 성공에 달려 있어서 오래 안 들어오면 알린다.

## 4. 장부

감독 장부의 일부다(`supervisor.md` §8). 자격 값, 이메일, 조직 ID, 오류 원문, 잔액은 넣지 않는다.

| 묶음 | 칸 |
|---|---|
| 등록 | 계정 별칭, 켜짐, 등록된 방식, 자격 revision·참조, 등록 단계. 같은 실제 계정을 다른 이름으로 두 번 등록하지 못한다 |
| 구독 | 상태(쓸 수 있음, 한도, 잠김, 대기), 창마다 리셋·관측 시각, 다음 확인, 마지막 성공, 잠금 사유와 시각, 토큰 발급일과 만료일(확인·추정) |
| API | 상태(쓸 수 있음, 소진, 잠김, 미상 보류), **다음 지급 예정일**(값, 정밀도, 출처, 확인한 날), 다음 확인, 잠금 사유와 시각 |
| 선택 제한 | 분당 대기의 끝, 지출 한도의 끝, 보류 사유, 검증 게이트 |
| 수동 선택 | 역할, 계정과 방식, 시작, 끝(D-41. 끝이 없는 줄은 만들지 않는다) |
| 실행 선택 | 일 ID, 실행 ID, 세대, 역할, 계정, 방식, 자격 revision, 실행 도구 버전, 모델, 정책 revision |
| 전환 | 전환 ID, 시도한 후보, 확인을 맡은 실행, 한도 구간 ID, 인계 참조, 알림 발송함과 전송 상태 |

- API의 칸은 "소진 월"이 아니라 계정별 다음 지급 예정일이다. 관리자가 O05에서 확인한 날짜를 넣는다. 30일을 더해 추정하지 않고, 날짜만 알면 정밀도를 날짜로 적는다. 예정일은 지급을 보증하지 않는다.
- [확인, O05] Console → Billing에는 포함 크레딧의 만료일이 시각(UTC)까지 보였다. 계정별 값은 O05의 "결과"에 있다. 새 크레딧이 그 무렵 결제 처리 뒤 들어온다는 것은 공식 안내에서 낸 [추론]이므로, 장부에는 출처를 "Console 만료일", 정밀도를 "시각"으로 적고 실제 지급은 §3대로 실제 일로 확인한다.
- [확인] 계정은 Console 조직 하나만 연결할 수 있고, Console 조직 하나는 플랜 하나에서만 크레딧을 받는다. 그래서 두 계정의 API는 서로 다른 조직이고 한쪽 한도가 다른 후보를 막지 않는다. [확인, O05] 두 계정에 연결된 Console 조직은 서로 다르다.
- 계정이나 방식이 바뀌면 새 실행 ID다. 같은 프로세스 안에서 자격을 바꾸지 않는다. 일 ID와 남은 예산은 이어받는다(전환이 예산을 새로 채우지 않는다).
- [확인] 옛 봇의 `ExecutionSelection`(계정·자격 revision·방식·실행 ID를 묶고 안 맞으면 `not_run`)에서 출발한다.

재시작 뒤 복원(`supervisor.md` §8의 순서):

- 되살리는 것: 잠금, 소진과 다음 확인, 미상 보류, 수동 선택과 그 끝, 진행 중이던 전환, 알림 발송함. 장부를 읽지 못하면 빈 상태로 시작하지 않고 새 실행을 닫는다.
- 새 자격 revision, 재시작, 지급 예정일 경과는 잠금을 풀지 않는다. 소진만 확인 대상으로 오른다.
- 백업 복원은 재시작과 다르다. 잠금과 영수증이 옛 시점일 수 있어 새 실행을 보류하고 관리자가 대조한다.
- 계정 상태·잠금·등록 이력은 기한으로 지우지 않는다. 원문이 만료된 세션(168시간, D-22)은 이어 열지 않는다.

## 5. 넘어가기 한 번의 절차

하나의 전환 ID로 잇는다. 감독이 도중에 재시작해도 장부의 마지막 확정 지점부터 한다.

1. **입력 정지.** 그 세션에 새 턴을 넣지 않는다. 현관은 계속 접수한다.
2. **상태 확정.** 실패한 턴, 도구 호출, 부분 파일, 게시 영수증, 남은 자식을 적는다. 효과를 모르는 일은 다시 실행하지 않는다.
3. **옛 실행 종료.** 실행기가 남은 프로세스 0개의 영수증을 낸다. 시간 초과, 화면 소멸, `hc kill`은 증거가 아니다. 확인하지 못하면 새 실행을 시작하지 않는다.
4. **새 선택 확정.** 후보, 자격 revision, 실행 도구, 권한, 남은 예산을 한 번에 고정한다.
5. **이어 열기 또는 인계.** O03이 통과시킨 조합만 `--resume`한다. 그 밖은 인계 문서로 새 세션을 연다(B-17). 통과한 조합은 아래 "O03이 확인한 범위"다.
6. **실제 진행 확인.** 입력이 한 번만 처리되고 정상 턴이 성공한 뒤에 전환을 확정한다. 인계로 연 세션은 목적·끝난 단계·영수증 위치·남은 예산을 정해진 키로 되적게 하고, 감독이 장부와 비교한 뒤에 확정한다(O03의 인계 시험에서 받은 쪽의 되적기가 인계 문서와 같았다).

O03이 확인한 범위 [확인, O03 실측. 헤드리스, 짧은 세션(턴 2~3개, 압축 전), `/login` 자격, 모델은 `claude-sonnet-5-5`]:

| 조합 | 결과 | 조건 |
|---|---|---|
| 구독 → 구독(서로 다른 조직의 두 계정, 양방향) | 조건부 됨 | 기록 파일 하나만 옮기면 열리고 대화·도구 기록이 이어진다. 앞 계정의 thinking은 넘어가지 않는다(경고 사건이 나온다). 시험한 한 쌍뿐이다 |
| 구독 ↔ 같은 계정의 API 키(`-p`, 양방향) | 됨 | thinking 경고가 없었다(실제로 다시 쓰였는지는 재지 않았다) |
| 끊긴 턴(SIGINT, SIGTERM) 뒤 이어 열기 | 됨 | 끊긴 도구가 다시 돌지 않았다. 프롬프트가 무관한 한 줄일 때의 결과다 |
| OpenCode ↔ Claude Code(양방향) | 됨(인계 문서) | 기록은 옮기지 않았다. 작은 일, 같은 모델, OpenCode는 모두 허용으로 돈 경우다 |
| OpenCode의 API 계정 사이 | 됨(인계 문서) | 새 상태 폴더와 새 전용 서버 |

- [미확인] `claude-work` → `claude-sub` 쌍(올리브의 첫 전환), `claude setup-token`의 장기 토큰으로 이어 열기, 압축된 긴 세션, background 자식이 있던 세션, 부속 폴더의 큰 출력 전문, 올리브가 실제로 쓸 모델. 통과 전까지 이 조합은 인계 문서를 쓴다(O03 "못 한 경우", 장기 토큰은 O17).
- 옮기는 것은 기록 파일 하나(`<config 폴더>/projects/<project>/<세션 ID>.jsonl`)다. 자격과 계정 설정은 옮기지 않는다. 기록에는 큰 도구 출력의 절대 경로(옛 config 폴더 아래)가 박혀 있어서 옛 폴더를 지우면 전문은 다시 읽을 수 없다.
- 기록의 소유자 줄(`session-owner`)에는 앞 계정의 식별자가 남는다. 열기를 막지는 않았다.
- 계정을 넘긴 이어 열기에도 짧은 인계를 붙인다. thinking에만 있던 판단(배제한 원인 등)은 체크포인트에 글로 남아 있어야 한다.

옛 실행을 끝내는 방법:

- 대화형 세션은 세션 실행기가 Claude, MCP 연결부, 훅, hc holder와 core를 끝낸다(`supervisor.md` §6).
- [확인] `claude -p`는 SIGTERM을 받으면 143으로 끝나고 하던 턴의 결과를 남기지 않는다. 턴을 마무리하려면 SIGINT(SDK는 `interrupt()`)를 먼저 보낸다([헤드리스][headless]). 그래서 SIGINT → 유예 → TERM → KILL 순서다.
- [확인, O03 실측] SIGINT로 끊으면 종료 코드가 0이다. 끊긴 것은 종료 코드가 아니라 `result` 사건(`subtype: error_during_execution`, `is_error: true`, `terminal_reason: aborted_tools`)으로 가린다. SIGTERM은 `result` 없이 143이다. 두 신호 모두 도구의 프로세스 트리를 1초 안에 정리했다(짧은 명령 하나의 경우다).
- [확인, O03 실측] SIGINT 뒤의 기록은 사실과 다르게 읽힌다. 명령은 시작해 부작용을 남겼는데 기록에는 "거절됐다"는 뜻의 문장이 남는다. 그래서 끊긴 도구의 효과는 기록이 아니라 감독이 본 상태(파일, 영수증)로 판정하고, 모르면 "효과를 모르는 도구"로 넘긴다. SIGTERM 뒤의 기록(`Exit code 137`)은 죽었다는 사실만 전한다.
- [확인] 이어 열 때 끊긴 턴은 그대로 두는 것이 기본이고 `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1`이면 이어서 실행한다. 이 변수를 실행 환경에서 막는다.
- [확인] 같은 세션을 두 곳에서 열면 기록이 섞인다. `--resume`은 살아 있는 background 세션에 다시 붙는 경우도 있다.
- [확인] `autoContinueAtUsageLimit`의 기본값은 true다. 관리 설정에서 false로 고정한다(B-09).

오케스트레이터:

- 전환 직전에 모델에게 요약을 부탁하지 않는다(그 호출도 한도로 실패한다). 정상 턴마다 남긴 체크포인트와 장부를 쓴다.
- 구독 → 구독의 이어 열기는 O03이 통과시킨 계정 쌍·방향·버전만 쓴다. 기록과 필요한 부속만 옮기고 자격·계정 설정은 옮기지 않는다. 2026-11-16 기준 통과한 것은 시험한 한 쌍(2.1.325)뿐이고, 첫 전환인 `claude-work` → `claude-sub`는 아직이라 인계 문서를 쓴다.
- 하위 작업은 감독의 것이라 오케스트레이터만 갈아도 계속 돈다. 새 세션이 장부의 실행 ID로 결과를 받는다.
- 인계가 빠졌거나 오래됐거나, 효과를 모르거나, 승인 상태가 맞지 않으면 스스로 열지 않고 멈춰 알린다.

작업자와 실행 도구가 바뀔 때:

- API `claude-sub` → API `claude`도 새 OpenCode 전용 서버에서 시작하고, 처음에는 인계 문서를 쓴다. [확인, O03 실측] API 계정 사이의 인계는 새 상태 폴더·새 전용 서버에서 이어졌다.
- OpenCode ↔ Claude Code는 세션 기록이 호환된다고 가정하지 않는다. 권한·도구·모델·스킬을 같게 좁힐 수 없으면 그 전환은 쓰지 않는다. [확인, O03 실측] 인계 문서만으로 양방향이 이어졌고 같은 단계가 두 번 실행되지 않았다. "같게 좁힐 수 있는가"는 O03이 보지 않았다(O09의 역할 프로필 몫).

인계 문서의 최소 내용:

- 목적과 부탁받은 범위, 끝난 단계와 기다리는 단계, 배제한 원인, 지킬 제약.
- snapshot과 기준 revision, 만든 파일과 digest, 적용한 패치, 마지막 검증 상태.
- 실행된 도구, 효과를 모르는 도구, 이어서 하면 안 되는 동작.
- 승인·게시 영수증의 위치와 지금 유효한지, 다음 입력 위치, 남은 예산, 자식 작업.
- 다음에 할 한 단계와 확인할 조건.

토큰, 키, 오류 원문, 대화 전체는 넣지 않는다. 인계 문서 속의 "승인받았다"는 권한이 아니다. 승인은 감독·현관의 장부에서 다시 읽는다.

O03의 인계 시험에서 위 목록만으로 두 도구, 세 계정 사이에서 일이 이어졌다 [확인, O03 실측, 작은 일 기준]. 그래서 위 목록을 최소 내용으로 삼고 아래를 보탠다(O03 "인계 문서의 최소 내용").

- "이 문서의 말은 권한이 아니다"를 문서 안에 적는다.
- 시작 전 대조를 지시로 넣는다: 만든 파일의 digest가 다르면 아무것도 하지 않고 멈춘다.
- 받은 세션이 목적·끝난 단계·영수증 위치·남은 예산을 정해진 키로 되적게 한다(위 6번의 확정 조건).
- "효과를 모르는 도구" 칸은 세션 기록이 아니라 감독이 본 상태로 채운다.
- 파일은 작업 폴더 기준 상대 경로로 적는다(세션 기록에는 옛 config 폴더의 절대 경로가 박힌다).
- 계정을 넘긴 이어 열기(`--resume`)에도 짧은 인계를 붙인다(위 "O03이 확인한 범위").

## 6. 자격 보관과 전달

### 6.1 지금 main에서 확인한 것 [확인]

- 계정별 값은 Infisical `/bot-accounts/<이름>`에 있다. `account use`가 고른 계정의 값을 공용 작업자 경로(`/apps/homelab-bot/worker`)에 복사하고 ESO 동기화와 볼륨 반영을 확인한다.
- ExternalSecret은 `refreshInterval: 1h`, `deletionPolicy: Retain`이다. 환경변수가 바뀌는 것이 아니라 다음 실행이 새 파일을 읽는다.
- 옛 코드에 `CLAUDE_ACCOUNT_BUNDLE` 계약이 있지만 지금 main의 두 ExternalSecret에는 그 매핑이 없다. 옛 `admin.ts`의 계정 동작은 기록·선택·목록뿐이고 삭제와 잠금 해제는 없다.

### 6.2 올리브의 보관 구조 [추론]

계정별 원본 경로는 다시 쓰고, 고른 값을 공용 경로에 복사하는 방식은 없앤다. 감독만 계정 묶음을 받는다.

| 키 이름 | 내용 | 대상 |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | 올리브 전용으로 발급한 구독 장기 토큰 | 세 구독 계정 |
| `ANTHROPIC_API_KEY` | 올리브 전용 Console workspace의 키 | `claude-sub`, `claude` |
| `CLAUDE_ACCOUNT_BUNDLE` | v2 메타데이터: 계정, revision, 등록된 방식, 방식별 지문 | 계정마다 |

- v2 묶음은 등록된 방식만 검사한다. 옛 v1은 두 방식이 다 있어야 해서 구독만 있는 `claude-work`가 뜨지 못한다.
- 계정별 ExternalSecret이 그 계정의 것만 감독 네임스페이스로 옮긴다. 없는 키를 먼저 매핑하면 Ready가 깨지므로 값을 넣은 뒤 선언을 켠다(O17의 배포 PR, 보호 경로 B-12).
- CLI는 새 값을 넣고 마지막에 묶음을 쓴다. 감독은 지문을 대조해 섞인 묶음을 거부한다. 자동 전환은 ESO 동기화를 기다리지 않는다.
- 감독과 작업자에게 Infisical 자격을 주지 않는다.

### 6.3 실행에 자격 하나만(D-37, D-47)

- **오케스트레이터:** 세션 파드의 실행기가 세션마다(하루 교체와 계정 세대가 바뀔 때마다) 새 hc core를 띄운다. [확인] `hc run`은 core의 환경을 프로그램에 넘기고, argv나 env override로 넘긴 값은 hc 상태 파일에 남는다(`supervisor.md` §2.1). 그래서 같은 core에서 자격만 바꾸지 않는다. D-47 뒤에는 본체가 hc와 다른 uid의 본체 컨테이너에서 돌고 hc의 터미널 프로그램은 중계이므로, 이번 자격 하나는 core 환경이 아니라 새 세대가 확인된 뒤 중계와 다른 통로로 본체에게만 준다(`supervisor.md` §2.2 규칙 3, §2.4. 통로는 O25·O10이 정한다). 계정을 바꿀 때는 새 core만이 아니라 본체 컨테이너 세대·HOME·인증 캐시·자격 통로도 함께 바뀐다. 옛 본체가 남았을 가능성이 있으면 새 계정의 자격을 보내지 않는다.
- **작업자:** 역할별 파드의 실행기가 hc 없이 직접 띄운다. 자식의 환경은 물려받아 지우는 것이 아니라 허용 목록에서 새로 만든다. 구독 Claude에는 `CLAUDE_CODE_OAUTH_TOKEN` 하나, API로 도는 OpenCode 서버에는 `ANTHROPIC_API_KEY` 하나만 준다.
- 자격을 argv, 프롬프트, 결과, 남는 파일에 쓰지 않는다(`supervisor.md` §9.2).
- [확인] Claude는 API 키나 helper가 OAuth 토큰보다 앞설 수 있고, OpenCode는 저장된 계정이 환경변수보다 앞선다([Claude 인증][auth], [OpenCode 인증][oc-auth]). 그래서 다른 인증 변수·helper·저장 계정을 막고, OpenCode는 실행별 전용 서버·DB·데이터 경로와 `--standalone`을 쓴다.
- 감독의 Secret 볼륨, 다른 계정, 개인 HOME, hc 소켓을 모델의 파일 도구가 닿는 곳에 두지 않는다. 환경변수를 지운 것만으로 `/proc`이나 물려받은 FD를 막았다고 보지 않는다.
- [확인] `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`은 보강 수단일 뿐이고([환경 정리][scrub]), `--bare`는 OAuth와 설정의 훅을 건너뛰므로 쓰지 않는다.
- [미확인] OpenCode의 모든 셸·도구 경로가 자격 제거와 파일 격리를 지키는지(O09·O13). 안 되면 코드 작성에 API 후보를 켜지 않는다.

### 6.4 개인 계정 등록과 남는 위험

- `claude`와 `claude-sub`는 계정 별칭이지 개인 폴더가 아니다. 개인 계정 폴더의 자격·세션·설정을 복사하거나 마운트하지 않는다. 관리자가 올리브 전용 발급 흐름에서 직접 로그인한다.
- 구독은 `claude setup-token`과 가려진 입력으로 등록한다. [확인] 이 토큰의 유효 기간은 1년이다([Claude 인증][auth]). 장부에 발급일과 만료일을 두고 만료 30일 전부터 미리 알린다(D-40). 발급 시각을 모르면 "추정 만료일"이다.
- [확인] 지금 등록기의 `makeTerminalLogin`은 부모 환경을 그대로 넘기고 전용 발급 폴더를 만들지 않는다. [추론] 발급 환경까지 나눈다.
- API는 관리자가 그 구독에 연결된 Console 조직에서 올리브 전용 workspace와 키를 만든다. [확인] default workspace에는 지출 한도를 걸 수 없다. [확인, O05] 2026-11-16에 두 계정 모두 전용 workspace, 그 workspace의 월 지출 한도, 그 workspace에 묶인 키를 만들었다. 구독 로그인을 OpenCode에 넣지 않는다(B-08).

남는 위험:

- [확인] 같은 계정의 개인 Claude 사용과 올리브의 구독 사용은 같은 한도를 나눠 쓴다. 토큰이나 폴더를 따로 둬도 한도가 따로 생기지 않는다.
- 개인 API 작업도 같은 Console 조직의 잔액을 줄이고, 그 조직에 구매 잔액·자동 충전을 더하면 올리브의 키도 그 잔액을 쓴다. [확인] 영업 계약으로 청구받는 조직이면 크레딧을 넘는 사용이 평소처럼 청구된다. [확인, O05] 2026-11-16에 두 계정 모두 그런 조직이 아니었고 구매 잔액·자동 충전도 없었다. 관리자가 뒤에 이 설정을 바꾸면 이 확인은 다시 해야 한다.
- D-40에 따라 `claude-work`의 토큰이 인증에 실패하면 올리브는 개인 계정으로 넘어간다. 토큰을 일부러 철회했으면(유출 등) 비상 정지를 함께 건다.
- [미확인] 올리브용 토큰의 발급·철회가 관리자의 개인 로그인이나 다른 토큰에 미치는 범위.

## 7. `homelab olive account` 명령 [추론, 초안]

아직 없는 명령이다. 입력 검증과 가려진 입력은 옛 `homelab bot account`(`cli/src/commands/bot-account-*.ts`)에서 가져온다. 옛 명령을 새 대상으로 돌리는 별칭은 만들지 않는다. 출력은 모두 가짜 예시다.

| 명령 | 기본 출력 한 줄(가짜 값) |
|---|---|
| `account list` | `계정 3개 · 본체 claude-work(구독) · 작업자 claude-sub(API) · 잠김 0 · 수동 선택 없음` |
| `account status claude-sub` | `claude-sub · 구독 관측 없음 · API 소진 · 다음 확인 12-14 09:01 KST` |
| `account add claude-sub --by subscription\|api` | `claude-sub API 등록 완료 · O04·O05 확인 전 사용 대기` |
| `account use claude-sub [main\|worker] [--for 6h]` | `전환 예약 · 다음 안전한 턴부터 claude-sub(구독) · 24시간 뒤 자동 순서로(11-15 10:20 KST)` |
| `account auto [main\|worker]` | `수동 선택 해제 · 다음 안전한 턴부터 자동 순서` |
| `account unlock claude-work --by subscription` | `구독 잠금 해제 · 다음 실제 일로 확인 예정` |
| `account recheck claude-sub --by api` | `미상 보류 재확인 예약 · 잠금은 그대로` |
| `account grant-date claude-sub --next 2026-12-14` | `다음 지급 예정일 12-14(날짜까지만)` |
| `account remove claude-sub --by api` | `삭제 예약 · 새 API 실행 차단 · 사용 중 1건이 끝난 뒤 정리` |

- [확인] 지금 `homelab bot account list`도 `kubectl exec` 관리 진입점을 거쳐서 `--apply`가 있어야 실행한다. 첫 판은 이 규칙을 지키고(없으면 계획만 보인다) 표에서는 줄였다.
- `--verbose`: 역할별 후보와 빠진 이유, 복귀 예약, 잠금 사유, 토큰 만료일, 수동 선택의 남은 시간. 값, 지문, 조직 ID, 이메일, 오류 원문, 잔액은 어디에도 내지 않는다.
- **대상의 이름:** 대상은 `main`(본체, 오케스트레이터)과 `worker`(작업자) 두 낱말로 받는다. 빼면 CLI가 어디에 쓸지와 얼마나 쓸지를 묻는다. 방식(`--by`)은 본체면 구독뿐이라 받지 않고, 작업자는 빼면 묻는다. 출력 글에서는 "오케스트레이터" 대신 "본체"라고 쓴다. 관리자가 `--role orchestrator`가 길다고 해서 줄인 초안이다(2026-11-14).
- **`use`와 `auto`(D-41):** `use`는 다음 안전 경계부터 적용된다. 정한 시간까지 유지하며 기본은 24시간, `--for`로 줄이거나 늘린다. 지나면 자동 순서로 돌아간다. 기한 없는 고정은 없다(`--for`의 상한은 O17이 정한다). 남은 시간은 `account list`에 보이고 하루 한 번 오는 글에 "수동 선택 중"이 실린다. `auto`는 바로 자동 순서로 돌린다. 고른 계정이 한도에 걸리면 자동 순서로 넘어가며 알린다.
- `use`가 거절하는 것: 오케스트레이터의 API, 조사·PR 리뷰 작업자에 Claude 강제, O04·O05 게이트를 넘는 API 선택, 잠긴 방식.
- **등록:** 자격 보관 → 배포 매핑 준비 → 감독의 묶음 반영 확인 → 켜기. 매핑 PR이 필요하면 "배포 반영 대기"로 끝낸다. `--replace`는 새 revision을 만들고 잠금·소진은 그대로 둔다.
- **`unlock`:** 구독 잠금(D-40)과 API 잠금(D-16)만 푼다. 소진, 미상 보류, 비상 정지, 검증 게이트는 풀지 않는다. 다음 실제 일이 다시 인증·결제 오류면 다시 잠근다. `recheck`는 미상 보류의 재확인만 앞당긴다(B-17).
- **삭제(B-17):** 새 실행을 바로 막는다 → 지금 실행이 끝나면 감독이 쥔 자격을 버린다 → 배포 PR로 매핑을 없앤다 → 남은 Kubernetes Secret과 Infisical 원본을 치운다. [확인] `deletionPolicy: Retain`이라 원본 키만 지워서는 끝나지 않는다. 공급자 쪽 철회는 관리자가 따로 한다. 유출 사고의 즉시 중지는 비상 정지다.
- 가져오지 않는 옛 동작 [확인]: 전역 `current` 하나, API 429를 결제 오류로 보는 분류, `use`가 결제 대기를 함께 푸는 것.
- 이 명령은 `homelab` CLI에만 있다. Discord에서 같은 부탁을 받으면 현관이 CLI를 안내하고 거절한다(D-09, O08).

## 8. 알림

### 8.1 Telegram: 사건마다 한 번

알림은 모델이 아니라 감독의 전환 장부에서 만든다. 상태 변경과 발송함 적재를 한 트랜잭션으로 하고 한도 구간·계정·방식·사건 종류로 유일 키를 둔다. 언제 오는지는 §1 표의 Telegram 열이다. 넘어감·돌아옴은 새 후보에서 실제 진행을 확인한 뒤에, 잠김과 접근 정책 거절은 원인을 확정해 장부에 적은 직후에 보낸다. 지급 지연(§3)도 한 번 알린다.

문구 예시(가짜 값):

> 두 계정의 이번 주기 API 크레딧이 다 떨어져 작업자는 claude-work 구독으로 이었어요. 다음 지급 예정일 뒤에 다시 확인해요.
>
> claude-work 구독 인증이 막혀 그 구독만 잠그고 claude-sub 구독으로 이었어요. 토큰을 확인한 뒤 homelab olive account unlock claude-work --by subscription으로 풀어 주세요.

- 알리지 않는 것: 평소에 첫 크레딧 후보로 시작하는 것, 첫 크레딧에서 둘째 크레딧으로 가는 것, 같은 구간에서 더 낮은 후보로 또 넘어가는 것, 재확인의 실패.
- 실제로 가른 원인만 쓴다. 지출 한도면 "설정한 API 지출 한도에 닿았어요", 리셋을 모르면 "풀리는 시각"이 아니라 "다시 확인할 시각"이다.
- "이번 달", "다음 달"을 쓰지 않고 "이번 주기", "다음 지급 예정일 뒤"로 쓴다.
- 본 적 없는 무료 여부·잔액·청구액을 말하지 않는다. "포함분 사용 중", "청구 0원" 같은 문구를 쓰지 않는다(O05).

### 8.2 전달 경로(B-17)

- 감독의 영속 발송함에서 Alertmanager로 짧게 사는 경보를 보내 기존 Telegram 경로로 내보낸다. 옛 봇 명세의 관리자 결정(전환 알림을 Alertmanager → Telegram으로, 한도 구간마다 한 번씩)과 같은 길이다 [확인].
- [확인] 지금 Alertmanager는 4시간마다 다시 보낸다(`platform/observability/stack/alertmanager/alertmanager.yml`). 이 문서를 쓰며 같은 파일에서 직접 읽은 것: Telegram 수신자는 해소 글도 보내고, severity가 warning·critical인 경보는 봇 수신 경로로도 간다.
- O17이 확인할 것: 사건 하나에 글이 한 번만 오는지(반복과 해소 글), Telegram으로만 가는지(D-28), 재시작에서 빠지거나 겹치지 않는지. 안 되면 초안의 안(발송함을 읽는 모델 없는 전달기, Telegram 자격은 전달기에만)으로 바꾸고 관리자에게 알린다.
- "한 번"은 같은 사건을 한 번 만들고 한 번 전송 완료로 적는다는 계약이다. 응답만 잃은 경우의 드문 중복은 남는다.

### 8.3 Discord

- Discord에는 자리 비움만 보인다. 계정 이름, 방식, 오류, 리셋 시각, 만료일, 세션 ID를 쓰지 않는다(`spec.md` §8.1).
- 대화를 받지 못하는 동안은 새 호출에 💤를 달고, 스레드마다 그 구간의 첫 호출에만 자리 비움 한 줄을 답한다(`discord.md`). 옛 자리 비움의 멱등 키와 5분 유예를 가져온다(값은 O21이 본다).
- 작업자만 기다리고 오케스트레이터가 답할 수 있으면 자리 비움이 아니다. 그 일의 상태 글만 "잠시 기다리고 있어요"로 고친다.
- 하루 한 번 오는 글(D-33)에는 "계정을 수동으로 골라 둔 상태"(D-41)와 "구독 토큰의 만료가 30일 안"(D-40)만 실린다. [추론] 계정 이름과 날짜는 쓰지 않고 `homelab olive account list`를 안내한다. 첫 줄의 규칙과 맞춘 것이고 관리자가 정한 것은 아니다.

## 9. 결정과 기본값

관리자 결정(전문은 `spec.md` §5.1):

- **D-40**(§1, §2.2, §6.4): 구독 토큰 인증 실패면 그 구독만 잠그고 넘어간다. 이유: D-16의 API 규칙(인증 실패면 그 API만 잠그고 다음 후보)과 같은 규칙으로 맞춘다. 조사 초안의 추천(멈추고 기다림)과 반대다.
- **D-41**(§7): 수동 선택은 정한 시간까지(기본 24시간)다. 조사 초안의 추천(딱 한 번만)과 다르다.

기본값(관리자 미확정, B-17). 관리자가 정하면 §5.1로 옮긴다.

| 항목 | 기본값 | 이유 |
|---|---|---|
| 못 가른 API 오류 | 잠그지 않고 미상 보류(§3) | 잠금이나 CLI 확인 대기는 주기마다 관리자 손이 가서 D-16의 자동 복귀와 어긋난다 |
| 지출 상한 | 그 계정·그 한도 범위만 기다리고 다음 후보 | 두 계정의 API는 서로 다른 Console 조직이다 |
| 지급 예정일 | 계정마다 O05에서 등록. 늦을 때는 §3 | 지급은 구독 결제 성공에 달려 있다 |
| 쓰는 중인 계정 삭제 | 새 실행을 바로 막고 지금 실행이 끝난 뒤 지운다 | 일을 잃지 않는다. 즉시 중지는 비상 정지가 맡는다 |
| 이어 열기가 안 될 때 | O03이 검증한 인계 경로로 새 세션을 스스로 연다 | `spec.md` §8.2 4번에 이미 있다 |
| 전환 알림의 길 | §8.2. O17에서 검증하고 안 되면 초안의 안으로 | 새 전달기는 Telegram 자격을 쥐는 자리가 하나 더 생긴다 |

## 10. 실제로 돌려 봐야 아는 것

아래는 [미확인]이다. 문서와 소스를 읽은 것만으로 통과로 치지 않는다. O03은 2026-11-16에 일부를 돌려 봤고 O04와 O05는 같은 날 끝났다. 표에는 남은 것만 적었다(본 것은 §2·§4·§5·§6.4, 그 티켓의 "결과").

| 티켓 | 돌려 볼 것 | 통과 전에는 |
|---|---|---|
| O03(남은 것) | `claude-work` → `claude-sub` 쌍(`claude-sub`의 주간 한도가 풀리는 2026-11-19 뒤), 압축된 긴 세션과 background 자식이 있던 세션, 부속 폴더의 큰 출력 전문, 올리브가 실제로 쓸 모델. 장기 토큰(`claude setup-token`)으로 이어 열기는 O17에서 본다 | 그 조합은 인계 문서를 쓴다 |
| O04(못 본 것) | 티켓은 끝났다(2026-11-16). 자연히 만날 때 모을 것: 크레딧 소진, 402, 조직 지출 한도 400, Claude Code workspace 지출 한도·등급 상한·ramp 제한의 429, 5시간 창, 작업 도중의 멈춤, 경고만 온 턴, 거절 뒤 같은 턴의 성공. OpenCode의 `provider.auth`·`provider.invalid-request` 밖 `error.type` | 못 본 표본은 미상으로 다룬다(소진과 결제 장애는 B-17의 미상 보류) |
| O05(남은 것) | 다음 지급 때 새 크레딧이 실제로 들어오는지(첫 예정일 2026-11-20 UTC, `claude`). O05는 지급을 보지 못했다. 확인 방법은 O17이 정한다(§3의 "실제 일의 성공으로 복귀") | 지급이 늦으면 §3의 늦을 때 규칙을 따른다 |
| O09·O17·O21 | 훅 사건의 턴 귀속과 가짜 신호 방어, 도는 작업자의 회수, OpenCode 환경의 격리, 섞인 묶음의 거부, 삭제 뒤 남는 Secret, 장부 복원 뒤의 잠금, Alertmanager 경로의 "한 번" | 해당 기능을 켜지 않는다 |

O17의 시험 고정값은 그 티켓의 완료 조건에 있다.

[hooks]: https://code.claude.com/docs/en/hooks#stopfailure
[statusline]: https://code.claude.com/docs/en/statusline#available-data
[sdk]: https://code.claude.com/docs/en/agent-sdk/typescript#sdkresultmessage
[headless]: https://code.claude.com/docs/en/headless
[credits]: https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-ultra-and-team-plans
[errors]: https://platform.claude.com/docs/en/api/errors
[limits]: https://platform.claude.com/docs/en/api/rate-limits
[auth]: https://code.claude.com/docs/en/authentication
[scrub]: https://code.claude.com/docs/en/env-vars#what-the-subprocess-environment-scrub-removes
[oc-auth]: https://opencode.ai/docs/cli/providers/#environment
[oc]: https://github.com/anomalyco/opencode/blob/v2.1.0/packages/ai/src/provider-error.ts
