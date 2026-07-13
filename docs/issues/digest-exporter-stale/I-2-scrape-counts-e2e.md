---
id: I-2
title: 수집 카운트 end-to-end — apps_configured/apps_scraped push + DigestExporterScrapeIncomplete 발화 증명
status: done
blocked-by: [I-1]
prd: docs/prds/digest-exporter-stale.md
created: 2026-07-13
closed: 2026-07-13
---

## What to build

하트비트(I-1)는 "push 경로가 살아 있다"만 증명한다. push는 됐는데 **앱 일부(또는 전부)의 skopeo 조회가
실패한 부분 고장**은 여전히 조용하다 — 지금 코드는 `[ -z "$DIGEST" ] && continue`로 그 앱을 스킵할 뿐이다.
이 슬라이스는 **수집 성공을 별도 축으로 관측**해 그 침묵을 없앤다(US2).

**producer** — `run.sh`가 같은 payload에 게이지 2개를 더 싣는다(둘 다 bare 시리즈):
`digest_exporter_apps_configured`(= `APPS` 엔트리 수 = 루프 반복 수)와
`digest_exporter_apps_scraped`(= skopeo digest 획득 성공 앱 수). 카운터는 POSIX sh 제약상
`N=$((N+1))` 대입 형태만 쓴다(`((N++))`·`<<<`·배열·임시파일 불가).

**알림** — r4에 `DigestExporterScrapeIncomplete`:
`last_over_time(digest_exporter_apps_scraped[2h]) < last_over_time(digest_exporter_apps_configured[2h])`,
`for: 30m`(3주기 관용 — 단발 GHCR 블립 흡수), `severity: warning`. bare끼리의 1:1 매치라
`on()`/`ignoring()`이 불필요하다(모드 B 비대상). **`absent` 가드는 달지 않는다** — 전면 침묵(push 사망)은
`DigestExporterStale`이 이미 fail-closed로 잡으므로 같은 고장에 두 번 페이징하지 않는다.

**zero-app은 의도된 공백**(owner 결정 ④): 마지막 앱을 teardown하면 `configured=0`·`scraped=0` →
`0 < 0`이 false라 침묵한다. 앱이 0개면 감시 대상 자체가 없다 — 룰 주석에 이 공백을 명시해 다음 사람이
"왜 안 잡히지"로 헤매지 않게 한다.

## Acceptance criteria

- [ ] `run.sh`가 `digest_exporter_apps_configured`·`digest_exporter_apps_scraped`를 bare 게이지로
      push하고, 둘 다 `DEFAULT_REGISTRY`에 등재돼 `make verify`가 통과한다(양방향 완전성 가드)
- [ ] `DigestExporterScrapeIncomplete`가 r4에 추가되고 모드 C(rollup·윈도 하한)·모드 B를 통과한다.
      summary/description은 한국어이고, 룰 주석이 zero-app 공백을 명시한다
- [ ] **producer 행위 테스트 확장**(I-1의 하네스 재사용): 입력 4종에 대해 카운트 출력값을 정확히 단언 —
      전건성공(`scraped == configured`) / 부분실패(`scraped < configured`) / 전건실패(`scraped == 0`,
      **하트비트는 여전히 발행**) / zero-app(`configured == 0 && scraped == 0`)
- [ ] **발화 e2e 레그 추가**(I-1의 게이트에): L4 `scraped < configured` → `DigestExporterScrapeIncomplete`
      발화 / L6 `configured=0, scraped=0` → **무발화**(owner 결정 ④를 락 — `<`를 `<=`로 바꾸거나
      zero-app 가드를 추가하면 여기서 죽는다)
- [ ] I-1의 L2(정상) 레그가 **두 알림 모두** `firing==0 AND pending==0`을 단언하도록 확장된다
      (카운트가 같은 비-0 값)
- [ ] Alertmanager 한국어 제목 매핑 2건(`DigestExporterStale`·`DigestExporterScrapeIncomplete`) 추가
- [ ] `make verify` + required `gate` 경로가 green

## Blocked by

- I-1 (레지스트리 관용구·룰 파일·발화 e2e 하네스·producer 행위 테스트 하네스를 세운다)

## Result

커밋 `56cf311`. 수집 성공을 하트비트와 **직교하는 축**으로 관측해 부분 고장의 침묵을 없앴다.

- **producer**: `run.sh`가 bare 게이지 `digest_exporter_apps_configured`(루프 반복 수)/`_scraped`
  (skopeo 성공 수)를 같은 payload에 싣는다. `SCRAPED` 증가는 `[ -z "$DIGEST" ] && continue` **뒤** —
  앞에 두면 전건 실패에도 `scraped == configured`로 오보고되어 모든 게이트를 통과하면서 US2가 조용히
  깨진다(그 위치가 곧 의미론이라 주석·테스트로 못박음).
- **알림**: r4 `DigestExporterScrapeIncomplete` — 양변 rollup 스칼라 비교(`on()`/`ignoring()` 없음 →
  모드 B 비대상), `for: 30m`, warning. **`absent` 미착용**(전면 침묵은 `DigestExporterStale`이 이미
  fail-closed로 잡는다 — 중복 페이지 금지). zero-app 공백(owner 결정 ④)을 룰 주석에 명시.
- **e2e**: L4(부분 실패 → 발화, 같은 replay에서 `DigestExporterStale firing=0`으로 **축 직교성까지 단언**)
  · L6(0/0 → 무발화, 결정 ④를 락) 추가, L2를 두 알림 모두 `firing==0 AND pending==0`으로 확장.
  **뮤테이션 검증**: `<`를 `<=`로 바꾸면 L2·L6이 죽는다(이빨 확인).
- **producer 행위 테스트**: 입력 4종의 카운트 값을 정확히 단언(전건성공 2/2 · 부분실패 2/1 ·
  전건실패 2/0 + 하트비트 발행 · zero-app 0/0).

### 코드리뷰 발견 → 수정 (하드 위반 0)
- **[fail-open]** `vme_to_s`가 빈 값을 받으면 산술에서 **0으로 평가돼 부등식이 조용히 참**이 되던 구멍 →
  fail-closed(빈 값·비수치 = `vme_fault`). 형제 하네스 무회귀 확인.
- **[fail-closed 구멍]** `for:` 추출에 가드가 없어 룰에서 `for:`가 사라지면 잡음 크래시 → `vme_alert_for`
  신설 + 3곳 가드. red 증명(`for:` 삭제 → exit 2 HARNESS FAULT).
- **[중복]** preflight rollup 3검사 → `vme_assert_rollup_ok`로 SSOT화, 레그 판정 뼈대 7중 복제 →
  헬퍼 3개로 접음(진단 산문은 인자로 보존).
- **[계약]** L4가 "하트비트 정상"을 **주장만** 하던 것을 단언으로 승격(오귀속 시 red).
- **[잠복 버그]** `$VAR한글` 언바운드 트랩(bash가 멀티바이트를 변수명에 흡수) 인스턴스 제거.

검증: `make ci` exit 0(bats 1207) · e2e **L1~L7 전부 PASS**(460s) · 스모크 PASS · bulkssd 무회귀 PASS.
