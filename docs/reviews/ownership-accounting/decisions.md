# 트리아지 결정 — ownership-accounting

### design r1

아티팩트: `docs/reviews/ownership-accounting/design-r1.json`
(`ok: true` · `verdict: needs-attention` · `codexStatus: 0` · `triageMode: human` · findings 3)

- **R-1 accept — The `apps` scope hides the invalid state it must detect**; 정확하다.
  `apps` scope의 `values.yaml` 필터를 `audit-orphans.ts:56-58`에서 가져왔는데, 거기선 정당하지만
  `check-app-deploy`는 그 파일의 **존재 자체를 검사**하므로 열거자가 미리 거르면 위반이 사라진다
  (배포를 깨뜨리는 false green). 적용: scope에서 필터 제거(tracked `apps/*/deploy/prod` 열거) +
  의미론적 필터는 소비자 쪽으로 + **워커 바닥값은 "열거 붕괴"만 본다**로 모델 축소.
  이에 따라 초안의 "scan-floor가 vacuous pass 3건을 일괄 해소한다"는 주장을 **철회**했다.
- **R-2 accept — Execution venues are not a mutually exclusive ownership dimension**; 정확하다.
  `check-skeleton.sh`는 `ci.yaml:51`과 `make verify` 양쪽에서 실제로 돌고, `bun run verify:ledger`는
  전이 해소가 필요하며, `check-credential-expiry.sh`는 cron이 직접 호출한다(스캔 리포트의 "고아" 판정은
  오류였다). 적용: 술어를 `count == 1` → **`authoritative >= 1`**로. venue를 권위 경로(→`gate`)와
  비권위 mirror/wrapper/테스트 호출로 분리하고 별칭은 전이적으로 해소.
- **R-3 accept — G2's exact-one calculation cannot detect its motivating pg-tools skew**; 가장 아픈
  지적이고 계산해보면 정확히 반대 결과가 나온다. `renovate.json:29-32`가 `^platform/.+\.ya?ml$`를 덮으므로
  `CONSUMERS` 등록 4파일은 소유자 2개(이중소유 오탐), 누락 2파일은 소유자 1개(통과)다.
  적용: 아티팩트별 권위 우선순위 도입(pg-tools → `repin-pgtools.ts`), Renovate 도달성은 소유권 매치가
  아니라 **freshness 채널**로 강등, D-1 탐지는 **"모든 pg-tools 참조가 `CONSUMERS`에 등장해야 한다"**는
  별도 완전성 불변식으로 이전.

**공통 뿌리**: R-2와 R-3은 같은 오류의 두 사례다 — 소유권을 "집합 멤버십 + 정확히 하나"로 모델링했으나
실제 구조는 "권위 있는 소유자 1 + 도달 가능한 비권위 경로 N"이다. Q5의 "선언하지 않고 계산한다"는
유지되고 계산하는 술어만 바뀐다. R-1은 별개 뿌리(열거자 필터가 불변식을 파괴).

사용자 결정: `as proposed` (세 건 모두 Accept).

### design r2

아티팩트: `docs/reviews/ownership-accounting/design-r2.json`
(`ok: true` · `verdict: needs-attention` · `codexStatus: 0` · `triageMode: human` · findings 2)

r1 세 건은 **전부 해소 확인**됨(리뷰어: R-1 resolved / R-2 resolved / R-3 resolved). 새 finding 2건은
모두 **r1 수정의 부작용**이다.

- **R-4 accept — G1 treats a vacuous Bats invocation as authoritative enforcement**; 정확하다.
  R-2를 고치며 mirror를 비권위로 강등했는데, 도메인이 CI에 없는 가드에겐 owner-local이 유일한 실제
  평가처다. 게다가 `tests/gates/test_verify-runbook-index.bats:9`의 `[ "$status" -eq 0 ]`을
  `verify-runbook-index.sh:9`의 **skip 경로(exit 0)가 만족**하므로 bats 래퍼가 거짓 권위를 준다.
  적용: 권위의 정의를 "어느 venue냐"에서 **"불변식이 실제 도메인에 평가됐는가"**로 교체 ·
  owner-local 엔트리포인트를 권위 클래스로 승격 · 픽스처/스모크/skip-only bats 호출을 비권위로 분류 ·
  구현 요구사항으로 "가드가 skip을 성공과 구분해 신호해야 한다"를 명시(없으면 정적 근사만 가능).
- **R-5 accept — G2 assigns Renovate ownership without proving update applicability**; 정확하다.
  R-3을 고치며 Renovate를 **과잉 강등**해, 서드파티 이미지가 분류표만으로 "소유자 있음" 통과하게 됐다
  (`ignorePaths` 변경·manager 패턴 공백 시 조용한 stale-pin 노출). D-2 탐지도 "Renovate가 도달 불가함을
  증명"하는 것이 핵심인데 도달성을 판정에서 빼면 증명 대상이 사라진다. 적용: Renovate가 지정 권위
  소유자인 아티팩트에 **차단성 적용성 검사**(추출/dry-run 증거, 또는 fail-closed 근사 + 센티넬 테스트) 요구 ·
  강등은 pg-tools·앱 핀에만 유지.

**WAIVED by user: round 2 상한 도달 후 두 건 모두 Accept·적용했고, 재검증(round 3)은 면제한다.
수정 내용이 명확하고 국소적이며(권위의 정의 1곳·Renovate 적용성 검사 1곳), 실제 구현은 `/feature`·
`/bugfix`가 각자의 게이트에서 다시 검증받는다.**

