# Verification — image-digest-drift-never-fires

**증거의 출처는 스크립트의 재실행이다.** `bugfix-status.mjs --verify-flip`이 `red.sha`와 `green.sha`를
각각 throwaway 워크트리로 체크아웃해 락에 핀된 명령을 **직접 다시 돌린** 결과이며, 컨덕터가 주장한
문장이 아니다. 원본 기록:

- `docs/reviews/image-digest-drift-never-fires/bugfix-verify-red-158e7e26….json`
- `docs/reviews/image-digest-drift-never-fires/bugfix-verify-green-d963ecb3….json`

> **release-gate R-1 교정 후 재생성됨.** 기록의 `outputTail`은 마지막 2000자로 잘리는데, 하네스가
> 8레그로 늘면서 symptomToken이 tail 경계에서 반토막 나 **기록이 자기 검증 불가**였다(“토큰이 있다”고
> 주장하면서 증거엔 안 보임). 하네스는 **바이트 동결** 그대로 두고 락의 `regressionCmd`가 출력 전문을
> 찍은 뒤 **실패 레그 줄을 맨 끝에 재출력**하도록 감쌌다(exit 코드 그대로 전달, 단언 무변경).
> 결과: RED 기록의 tail이 정확한 토큰을 담은 `FAIL L1 …` 줄로 끝나고, GREEN은
> `(none - all legs passed)`로 끝난다 — 양쪽 다 감사 가능.

## Claim 1 — 단일 flip 증명 (FAIL@red → PASS@green)

핀된 명령(`bugfix-lock.json`):

```bash
# regressionCmd (플립 테스트 단독 — 증거 보존 래퍼, 하네스 자체는 동결)
bash tests/gates/vmalert-drift-firing-e2e.sh > /tmp/idd-verify.log 2>&1; rc=$?; cat /tmp/idd-verify.log
echo "--- failed legs (symptom) ---"; grep -E "^FAIL " /tmp/idd-verify.log || echo "(none - all legs passed)"; exit $rc

# characterizationCmd (주변 보존 스위트)
bats tests/test_alert_rules.bats tests/gates/test_vmalert-config.bats tests/gates/test_digest-exporter.bats \
  && bash tests/gates/vmalert-rules-validate.sh
```

| | `red.sha` = `f4497d2` (픽스 전) | `green.sha` = `a1f7d21` (픽스) |
|---|---|---|
| regression exit | **1** (`failed: true`) | **0** (`passed: true`) |
| symptomToken `ImageDigestDrift did not fire despite` | **존재** (red-for-the-right-reason) | 사라짐 |
| characterization exit | **0** (`green: true`) | **0** (`green: true`) |
| treeSha | `158e7e26…` | `d963ecb3…` |

**판정: PASS** — `flipOk: true`. 정확히 하나의 관측 행위가 뒤집혔고(발화 불가 → 발화), 주변 스위트는
양쪽 모두 GREEN이다. 락의 `scope[]` 밖 non-test 변경 0(B4).

## Claim 2 — 회귀 하네스가 실제로 무엇을 증명하는가 (8레그)

`green.sha`에서 `bash tests/gates/vmalert-drift-firing-e2e.sh` → **exit 0, preflight + L1~L8 전부 PASS**.

| 레그 | 증명하는 것 | green 결과 |
|---|---|---|
| preflight | `push(10m) ≤ W(15m) < for(20m)` 산술 강제 · `for: 20m` 고정 · 우변 rollup 금지 | OK |
| **L1** | **증상**: 115분 지속 드리프트에 ImageDigestDrift **발화** | firing=191 (red에선 0) |
| L2 | 드리프트 없을 때 오발화 금지 | 시리즈 0 |
| L3 | 이미지 bump 직후 phantom 무발화 | firing=0 |
| L4 | **하네스 이빨**: 동결된 결함 표현식 픽스처는 여전히 pending에 갇힘 | firing=0 |
| L5 | **하네스 이빨**: rollup 밖 `or absent()` 가짜 픽스 거부 | firing=0 |
| L6 | **하네스 생존**: 같은 replay에서 ArgoCDOutOfSync는 발화 | firing=201 |
| L7 | **KSM 장애 시 무발화**(오늘의 행위 보존) — 가드 없는 rollup은 여기서 전 앱 오발화 | 시리즈 0 |
| L8 | **하네스 이빨(상한)**: 과대 윈도(W=30m)는 phantom 발화함을 매 실행 증명 | firing=19 |

anti-cheat: L4/L5/L8 결함 픽스처와 하네스 자체는 red.sha 이후 **바이트 무변경**(구조 게이트가 독립 확인).

## Claim 3 — 레포 전역 게이트 무회귀

`green.sha` 트리에서 실행:

```
characterization (bats 3스위트 + vmalert -dryRun) → 43/43 ok, rc=0
make verify                                        → rc=0  (check-alert-rules OK — 41 룰, 모드 A/B 위반 0)
make verify-traps                                  → rc=0  (원장 guard 실재 + SSOT 가드주석↔원장 일치)
scripts/run-bats.sh gate (CI required check SSOT)  → 1167 ok / 0 not-ok, rc=0
```

**판정: PASS.**

## 미증명 항목 (정직한 공개)

- **`reproCmd` 미선언 → 독립 repro-gone 체크는 waive됐다**(스크립트도 `reproNote`로 이를 명시).
  사유: 원본 repro가 **라이브 클러스터 PromQL 질의**인데, 클러스터는 머지 + ArgoCD 싱크 전까지 옛 룰을
  계속 돌린다 — `green.sha` 워크트리에서 돌려도 여전히 재현되므로 락에 넣으면 거짓 실패가 된다.
  증상은 hermetic 회귀 테스트 L1이 대신 고정한다(같은 증상 문자열을 단언).
- **라이브 효과는 아직 미증명**: 이 픽스는 배포되어야 vmalert가 룰을 reload한다
  (`--configCheckInterval=30s`). 머지 후 라이브 검증 항목 — ① 로드된 룰 expr에 `last_over_time` 반영
  (`/api/v1/rules`), ② **구멍이 메워졌다는 직접 증명**: push +6분 시점 instant 질의에서
  `last_over_time(ghcr_latest_digest[15m])`가 **비어 있지 않음**(픽스 전 바로 그 지점에서 0개였다),
  ③ 현재 드리프트 0 상태이므로 **오발화 0**(20분+ 관찰).
