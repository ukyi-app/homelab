# O04 검증: 실제 한도·API 소진 때의 신호 모양

- 단계: 0 끄기와 검증
- 상태: 대기
- 명세: `spec.md` §8.2 2번·5번
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
- [확인] API 지출 한도는 HTTP 400 `invalid_request_error`, 일반 속도 제한은 429.
- [확인] `autoContinueAtUsageLimit` 기본값은 true다. 감독형 실행에서는 false로 고정한다.
- [미확인] 실제 한도·소진 때의 정확한 값과 순서.
- [미확인] OpenCode(D-14의 크레딧 작업자 도구)가 API 지출 한도·소진을 어떤 모양으로 알리는지. 조사에서는 Claude Code의 `StopFailure`·SDK와 같은 수준의 계약을 확인하지 못했다.

## 할 일

1. 관측 장치를 준비한다: 대화형은 `StopFailure` 훅과 상태줄 명령이 받은 JSON을 비식별해 파일로 남기고, `-p`는 stream-json을 남긴다. 계정명·세션 ID·토큰은 남기지 않는다.
2. 올리브 전용 계정이 실제로 한도에 걸렸을 때(인위로 소진하지 않는다. 자연히 걸리는 때를 기다린다) 위 신호를 모은다.
3. API 쪽은 올리브 전용 workspace에 낮은 지출 한도를 걸어 둔 상태에서 한도 도달 응답을 모은다(관리자가 Console에서 설정). `claude -p`와 OpenCode(`run --format json`) 둘 다 모은다. OpenCode의 신호를 감독이 결정적으로 읽을 수 없으면 `spec.md` B-08의 "막히면"을 따른다.
4. 결과로 판정표를 만든다: 신호 → 처리(넘어감/대기/잠금/미상).
5. 경고만으로 넘어가지 않는지, 한도 뒤 정상 성공(Usage credits 등)이 섞이는지 적는다.

## 완료 조건

- [ ] 구독 한도, API 지출 한도 두 경우의 신호 샘플(비식별)과 판정표가 있다. API 쪽은 OpenCode의 샘플을 포함한다.
- [ ] `spec.md` §8.2 2번이 실측에 맞게 고쳐졌다.

## 검증

- 경계: 실제 한도 상황 관측. 한도를 일부러 태우는 호출은 하지 않는다.
- 잡는 실패: 경고를 한도로 오판, 400을 모두 결제로 오판. 못 잡는 범위: 버전이 바뀐 뒤의 모양(O17이 버전 고정과 시험 고정값으로 관리).

## 결과

(검증 뒤 채운다)
