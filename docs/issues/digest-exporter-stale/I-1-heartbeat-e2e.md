---
id: I-1
title: digest-exporter 하트비트 end-to-end — 자기관측 push + 지연 상한 강제 + DigestExporterStale 발화 증명
status: done
blocked-by: [none]
prd: docs/prds/digest-exporter-stale.md
created: 2026-07-13
closed: 2026-07-13
---

## What to build

digest-exporter가 **자기 생존을 알리는 하트비트**를 push하고, 그 하트비트가 끊기면
`DigestExporterStale`이 **실제로 발화함을 CI가 증명**하는 경로를 端에서 端까지 세운다. 이 슬라이스가
walking skeleton이다 — 모드 C 레지스트리(양방향 가드), POSIX sh 제어흐름, exposition 정적 추출,
push 메트릭 rollup 룰 형태, hermetic replay 하네스의 `max_lookback` 핀, 부트스트랩 지연 상한이
**전부 여기서 처음으로 맞물린다**.

**producer** — `platform/victoria-stack/prod/digest-exporter.yaml`의 `run.sh`가 기존 단일 curl
페이로드에 `digest_exporter_last_success_timestamp`(bare 시리즈, epoch 초)를 함께 싣는다. 하트비트의
의미론은 **"push 경로 생존"**이지 "수집 성공"이 아니다(수집 성공은 I-2의 카운트가 본다). 같은 페이로드에
실리므로 curl이 실패하면 하트비트도 미적재된다(fail-closed).

**지연 상한 강제**(알림의 정확성이 여기 의존한다 — PRD "부트스트랩 안전성") — CronJob에
`concurrencyPolicy: Replace`(레거시 무제한 Job이 새 Job을 막는 경로 차단) + `activeDeadlineSeconds: 180`,
`run.sh`에 skopeo `--command-timeout`(⚠️ **글로벌 옵션이므로 `inspect` 앞에** 와야 한다)과
curl `--max-time`. 두 부등식이 성립해야 한다:

- **부트스트랩**: `for(900s) > cron(600s) + activeDeadlineSeconds(180s) + 컨트롤러 여유(60s) = 840s`
- **인-데드라인(엄격)**: `POD_START(60s) + N_apps × SKOPEO_TIMEOUT + CURL_MAX_TIME + EXEC_SLACK(10s) < activeDeadlineSeconds`
  → 현재 값으로 `N_MAX = 7`(앱 8개부터 CI red — `activeDeadlineSeconds` 상향을 강제)

**알림** — `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`에 `DigestExporterStale`:
`(time() - last_over_time(hb[2h])) > 900 or absent(last_over_time(hb[2h]))`, `for: 15m`,
`severity: warning`(→ T0+30분 발화). push 주기 600s > 룩백 300s라 **rollup 필수**이고 `absent`는
반드시 `absent(last_over_time(...))` 형태다.

**증명** — 신규 발화 e2e(`tests/gates/vmalert-digest-stale-firing-e2e.sh`, `.sh` + ci.yaml `gate`
명시 스텝, 복사 원본은 bulkssd). 배포 ConfigMap에서 룰을 바이트 추출하고, preflight가 위 부등식들을
매니페스트에서 파생해 강제하며(위반 = exit 2), `vme_replay`가 `?max_lookback`을 주입한다.

## Acceptance criteria

- [ ] `run.sh`가 `digest_exporter_last_success_timestamp`를 bare 시리즈로 push하고, 레지스트리
      (`tools/check-alert-rules.ts`의 `DEFAULT_REGISTRY`)에 등재돼 `make verify`가 통과한다
- [ ] CronJob이 `concurrencyPolicy: Replace` + `activeDeadlineSeconds: 180`을 갖고, `run.sh`가
      skopeo `--command-timeout`(argv **순서**: `inspect` 앞) + curl `--max-time`을 쓴다
- [ ] `DigestExporterStale`이 r4에 추가되고 모드 C 린터(rollup·윈도 하한)를 통과한다.
      summary/description은 한국어
- [ ] **producer 행위 테스트**(신규 bats, 비-docker): ConfigMap에서 `run.sh`를 추출해 stub `skopeo` +
      `curl` 페이로드 캡처로 실행 — stub이 **argv 순서를 단언**하고, skopeo 성공/실패 양쪽에서
      **하트비트가 발행됨**을 증명한다
- [ ] **정적 게이트**(`tests/gates/test_digest-exporter.bats` 확장): `Replace`·`activeDeadlineSeconds`·
      타임아웃 플래그 순서·**카디널리티 엄격 부등식**(8번째 앱 = red)
- [ ] **skopeo 실물 타임아웃 스모크**(`tests/gates/skopeo-timeout-smoke.sh`, docker, ci.yaml 스텝):
      핀된 skopeo 이미지를 제어된 블랙홀에 대고 돌려 `t + 여유` 안에 종료함을 증명(이미지 digest는
      매니페스트에서 파생 — 하드코딩 금지)
- [ ] **발화 e2e**(`tests/gates/vmalert-digest-stale-firing-e2e.sh`, ci.yaml 스텝): L1 stale → 발화 /
      L2 정상 → 두 알림 침묵 + **대조 알림 `FilesBackupStale` firing>0**(vacuity 차단) / L3 **동결 결함
      픽스처**(맨 참조 expr) → `firing==0 && pending>0` / L5 하트비트 전무(`absent` 가지) → 발화 /
      L7 **부트스트랩**(첫 샘플이 강제 상한 840s에 도착) → **무발화**(그 이전 pending>0로 비-vacuity 증명,
      발화 경계 넘겨 replay)
- [ ] preflight가 부트스트랩·인-데드라인 부등식을 **매니페스트에서 파생**해 강제(위반 = exit 2)
- [ ] 함정 원장 tie(`docs/traps.md` 행 45의 guard 셀 + `docs/traps-detail.md`의 `> 가드:` 줄에 신규
      게이트 경로 추가 — 새 `### ` 섹션은 만들지 않는다)
- [ ] `make verify` + required `gate` 경로가 green

## Blocked by

None - can start immediately

## Result

커밋 `5a64480`. 하트비트 → 룰 → 발화 증명 경로가 end-to-end로 섰다.

- **producer**: `run.sh`가 bare `digest_exporter_last_success_timestamp`를 기존 push 페이로드에 실어
  보낸다(fail-closed — curl 실패 시 하트비트도 미적재). 지연 상한을 매니페스트로 강제:
  `concurrencyPolicy: Forbid → Replace`(레거시 무제한 Job 구멍 차단) + `activeDeadlineSeconds: 180`
  + skopeo `--command-timeout`(글로벌 플래그, `inspect` 앞) + curl `--max-time`.
- **알림**: r4 `DigestExporterStale` — `last_over_time[2h]` rollup + `absent(last_over_time(...))` 가드,
  `T=900s`·`for: 15m` → **T0+30분 발화**. `for(900s) > 강제 상한 840s`라 최초 배포 거짓 페이지가
  구조적으로 불가능하다.
- **seam 4종**: 모드 C 레지스트리(양방향) · producer 행위 테스트(stub이 argv 순서 단언) ·
  발화 e2e 5레그(L1 stale→발화 / L2 정상→침묵+대조알림 / L3 동결 결함픽스처→`firing==0 && pending>0` /
  L5 absent 가지→발화 / L7 **부트스트랩**: 첫 샘플이 강제 상한 840s에 도착 → 무발화, pending=28로
  비-vacuity 증명) · 핀된 skopeo **실물** 타임아웃 스모크(호스트 TCP sink 블랙홀, 실측 `3s→3초`·`9s→9초`).
- **예산 SSOT**: `tests/gates/lib/digest-exporter-budget.sh` — 상수 정의 1곳, 파생 실패는 fail-closed.
- **`?max_lookback` 핀은 load-bearing으로 실측 확정**: 핀을 빼면 L3(결함 픽스처)가 `pending=0`이 되어
  거짓 GREEN이 난다(VM range 질의가 600s 구멍을 보간). 하네스 헤더에 기록.

### 코드리뷰 발견 → 수정
- **[HARD·fail-open]** 정적 게이트의 중간 복합 단언(`[ -n "$ST" ] && [ -n "$CT" ]`)이 `set -e`에서 침묵
  통과 → 파생이 빈 값이어도 `BUDGET=70 < 180`으로 **green**이 되던 구멍(이 테스트가 막겠다던 바로 그
  fail-open). fail-closed `deb_load`로 교체하고 **red 증명** 완료.
- **[HARD·표준]** 스모크가 python을 셸 heredoc에 내장 → `tests/gates/tcp-blackhole-sink.py`로 분리
  (`CONTRIBUTING.md` 금지 항목, 형제 관용구 `mock-telegram.py`).
- **[중복]** 하네스 공통 코드(~40줄)를 `lib/vmalert-e2e.sh`로 승격(`vme_` 접두) — bulkssd/drift 게이트는
  **0줄 변경**(F-5 범위 보존), 무회귀 실행 확인.
- **[결합]** 프로덕션 argv를 구속하던 인접 grep을 순서-무관 존재 단언으로 완화.

### 계획 전제 1건이 실측으로 반증됨
plan 게이트 r9(N-4)의 "skopeo `--command-timeout`을 `inspect` 뒤에 두면 무효"는 **거짓**이다 —
핀된 v1.22.2에서 그것은 **cobra persistent flag**라 서브커맨드가 상속한다(실측 `=3s`→3초, `=9s`→9초).
argv 순서 계약은 유지하되(스모크가 실제로 증명한 배치이고, 뒤 배치의 수용은 CLI 재구성 한 번에 사라질 수
있는 구현 세부다) PRD의 근거를 실측으로 교체했다.

검증: `make ci` exit 0(bats 1203) · 신규 e2e 292s PASS · 스모크 PASS · bulkssd 무회귀 PASS.
