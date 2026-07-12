# Verification — files-bulk-ssd-low-never-fires

**증거의 출처는 스크립트의 재실행이다.** `bugfix-status.mjs --verify-flip`이 `red.sha`/`green.sha`를 각각
throwaway 워크트리로 체크아웃해 락에 핀된 명령을 **직접 다시 돌린** 결과다(컨덕터의 주장이 아니다).

> **release-gate R-4 교정**: 최초 verification.md는 **R-1(주석 축소) 이전의 green.sha**를 증거로 내세우고
> 있었다. R-1 반영 후 `--verify-flip`을 다시 돌렸으면서 이 문서를 갱신하지 않은 것은
> capturing-evidence 하드룰(검증 후 변경 = 문서도 갱신) 위반이다. 아래는 **최종 락 상태**의 기록이다.

| | 값 |
|---|---|
| `red.sha` | `ffa1797` |
| `green.sha` | `8b2f521` (R-1 주석 반영본 = 최종) |
| RED 기록 | `bugfix-verify-red-28db868a9d3a23fee410c4741e9130f7f3415390.json` (treeSha `28db868a9d3a`) |
| GREEN 기록 | `bugfix-verify-green-cd6f1e6f5b25f8ea48670f7cb487792e058b5044.json` (treeSha `cd6f1e6f5b25`) |

## Claim 1 — 단일 flip 증명 (FAIL@red → PASS@green)

핀된 명령(`bugfix-lock.json`):

```bash
# regressionCmd (증거 보존 래퍼 — 하네스는 동결, 실패 레그를 출력 끝에 재출력)
bash tests/gates/vmalert-bulkssd-firing-e2e.sh > /tmp/bulkssd-verify.log 2>&1; rc=$?; cat /tmp/bulkssd-verify.log
echo "--- failed legs (symptom) ---"; grep -E "^FAIL " /tmp/bulkssd-verify.log || echo "(none - all legs passed)"; exit $rc

# characterizationCmd (주변 보존 — 방금 머지한 ImageDigestDrift 게이트를 포함시켜 무회귀를 못박는다)
bats tests/test_alert_rules.bats tests/gates/test_vmalert-config.bats \
  && bash tests/gates/vmalert-rules-validate.sh \
  && bash tests/gates/vmalert-drift-firing-e2e.sh
```

| | `red.sha` (픽스 전) | `green.sha` (최종) |
|---|---|---|
| regression exit | **1** (`failed: true`) | **0** (`passed: true`) |
| symptomToken `FilesBulkSSDLow did not fire despite` | **존재**(red-for-the-right-reason) | 사라짐 |
| characterization exit | **0** (`green: true`) | **0** (`green: true`) |

**판정: PASS** — `flipOk: true`. 관측 행위 하나만 뒤집혔다(발화 불가 → 발화). `scope[]` 밖 non-test 변경 0.

### RED 기록의 outputTail 끝(증상 토큰이 보존된 증거에 실재)

```
vmalert-bulkssd-firing-e2e: 1 leg(s) FAILED
--- failed legs (symptom) ---
FAIL L1 FilesBulkSSDLow did not fire despite 120 minutes of the bulk SSD sitting at 5% free (threshold 10%) — firing=0, pending=2 (it engages, then loses the series and resets). The rule reads the once-a-day (86400s) host push metric with NO rollup, so in production the series is only visible for the 5m instant-query lookback after each push (11 consecutive evals at 30s) while the for: 30m hold needs 61 consecutive evals — structurally unreachable. Wrap both operands in a rollup that spans the push period (the sibling BulkStorageLow, which fired in this very same replay, wears last_over_time(...[3d]))
```

### GREEN 기록의 outputTail 끝

```
vmalert-bulkssd-firing-e2e OK (preflight + L1~L4 통과 — FilesBulkSSDLow가 실제 결핍에 발화하고, 정상 매체엔 침묵하며, 결함 expr은 여전히 못 운다)
--- failed legs (symptom) ---
(none - all legs passed)
```

## Claim 2 — 회귀 하네스가 증명하는 것 (preflight + 4레그, `green.sha`에서 exit 0)

| 레그 | 증명 | green |
|---|---|---|
| preflight | `2×push(172800s) ≤ W(3d) ≤ 7×push(604800s)` 산술 강제 · `for: 30m` 계약 고정 | OK |
| **L1** | **증상**: 여유율 5%(임계 10% 미만) 120분 지속 → 발화 | firing=181, pending=60(= 정확히 30m/30s hold) |
| L2 | 정상 매체(99% 여유)엔 침묵 | 시리즈 0 |
| L3 | **하네스 이빨**: 동결된 결함 표현식(맨 참조)은 pending(2)에 갇혀 **영원히 못 운다** | firing=0 |
| **L4** | **결정적 대조**: 같은 replay·같은 매체·같은 5% 결핍인데 rollup 착용한 형제 `BulkStorageLow`는 **발화한다** → 하네스가 못 울리는 게 아니라 **이 알림만** 못 울렸다 | firing=181 |

## Claim 3 — 보존 계약 (특히 방금 머지한 알림)

characterizationCmd에 **드리프트 게이트를 포함**시켜, 직전에 고친 `ImageDigestDrift`가 이 변경으로
회귀하지 않음을 매 검증마다 못박는다. `green.sha`에서 전건 GREEN:

```
bats (test_alert_rules + test_vmalert-config)  → rc=0
vmalert-rules-validate.sh (dryRun)             → rc=0
vmalert-drift-firing-e2e.sh                    → rc=0 (L1~L8)
make verify                                    → rc=0 (check-alert-rules 41룰 위반 0)
make verify-traps                              → rc=0
scripts/run-bats.sh gate                       → 1167 ok / 0 not-ok
```

## 미증명 항목 (정직한 공개)

- **`reproCmd` waive**: 원본 repro가 라이브 클러스터 질의라 `green.sha` 워크트리에서도 여전히 재현된다
  (클러스터는 머지+싱크 전까지 옛 룰을 돈다) → 락에 넣으면 거짓 실패. 증상은 hermetic L1이 고정한다.
- **`max_lookback` 핀은 이 하네스에선 load-bearing이 아니다**(일 단위 간격이라 replay 보간이 24시간 갭을
  못 건넌다 — 구현자가 빼고 돌려 동일 판정 실증). 거짓 GREEN 방어의 권위는 **L3**다.
- **새로 도달 가능해진 오귀속 경로(release-gate R-1)**: `backup-files-data.sh`가 df 실패 시 0을 대입한 채
  성공 하트비트를 발행하므로, 값 오염 시 이 알림이 "여유 0%"로 **오귀속 페이지**를 낼 수 있다. 픽스 전엔
  발화 자체가 불가해 가려져 있던 경로다. **해법은 쓰는 쪽**(F-3) — expr 가드는 금지(중복 페이지이거나
  진짜 결핍 avail=0을 억제해 알림을 다시 죽인다). 룰 주석에 명시했다.
- **라이브 효과는 배포 후 확인**: ① 로드된 expr에 rollup 반영, ② 가시성 직접 증명(마지막 push 후 5분이
  지난 시점 = 하루의 99.65%에 instant 질의로 `last_over_time(files_data_bulk_avail_bytes[3d])`가 비어
  있지 않음 — 맨 참조는 0개), ③ 현재 여유율 99.9%라 오발화 0.
