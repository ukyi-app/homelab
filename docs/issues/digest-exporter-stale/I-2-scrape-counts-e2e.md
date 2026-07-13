---
id: I-2
title: 수집 카운트 end-to-end — apps_configured/apps_scraped push + DigestExporterScrapeIncomplete 발화 증명
status: open
blocked-by: [I-1]
prd: docs/prds/digest-exporter-stale.md
created: 2026-07-13
closed:
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
