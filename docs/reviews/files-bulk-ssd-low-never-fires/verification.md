# Verification — files-bulk-ssd-low-never-fires

**증거의 출처는 스크립트의 재실행이다.** `bugfix-status.mjs --verify-flip`이 `red.sha`/`green.sha`를
각각 throwaway 워크트리로 체크아웃해 락에 핀된 명령을 **직접 다시 돌린** 결과다(컨덕터의 주장이 아니다).
원본 기록: `bugfix-verify-red-*.json` · `bugfix-verify-green-*.json`.

## Claim 1 — 단일 flip 증명 (FAIL@red → PASS@green)

| | `red.sha` = `ffa1797` (픽스 전) | `green.sha` = `b2b3dc0` (픽스) |
|---|---|---|
| regression exit | **1** (failed) | **0** (passed) |
| symptomToken `FilesBulkSSDLow did not fire despite` | **존재**(red-for-the-right-reason) | 사라짐 |
| characterization exit | **0** (green) | **0** (green) |

**판정: PASS** — `flipOk: true`. 관측 행위 하나만 뒤집혔다.

## Claim 2 — 회귀 하네스가 증명하는 것 (4레그 + preflight)

`green.sha`에서 `bash tests/gates/vmalert-bulkssd-firing-e2e.sh` → **exit 0**.

| 레그 | 증명 | green |
|---|---|---|
| preflight | `2×push(172800s) ≤ W(3d) ≤ 7×push(604800s)` 산술 강제 · `for: 30m` 계약 고정 | OK |
| **L1** | **증상**: 여유율 5%(임계 10% 미만)가 120분 지속 → 발화 | firing=181, pending=60(= 정확히 30m/30s hold) |
| L2 | 정상 매체(99% 여유)엔 침묵 | 시리즈 0 |
| L3 | **하네스 이빨**: 동결된 결함 표현식(맨 참조)은 pending(2)에 갇혀 **영원히 못 운다** | firing=0 |
| **L4** | **결정적 대조**: 같은 replay·같은 매체·같은 5% 결핍인데 rollup 착용한 형제 `BulkStorageLow`는 **발화한다** → 하네스가 못 울리는 게 아니라 **이 알림만** 못 울렸다 | firing=181 |

## Claim 3 — 보존 계약 (특히 방금 머지한 알림)

characterizationCmd에 **드리프트 게이트를 포함**시켜, 직전에 고친 `ImageDigestDrift`가 이 변경으로
회귀하지 않음을 매 검증마다 못박는다.

```
bats tests/test_alert_rules.bats tests/gates/test_vmalert-config.bats  → rc=0
bash tests/gates/vmalert-rules-validate.sh                              → rc=0
bash tests/gates/vmalert-drift-firing-e2e.sh                            → rc=0 (L1~L8 통과)
make verify                                                            → rc=0 (check-alert-rules 41룰 위반 0)
make verify-traps                                                      → rc=0
scripts/run-bats.sh gate                                               → 1167 ok / 0 not-ok
```

## 미증명 항목 (정직한 공개)

- **`reproCmd` waive**: 원본 repro가 라이브 클러스터 질의라 `green.sha` 워크트리에서도 여전히 재현된다
  (클러스터는 머지+싱크 전까지 옛 룰을 돈다) → 락에 넣으면 거짓 실패. 증상은 hermetic L1이 고정한다.
- **라이브 효과는 배포 후 확인**: ArgoCD 싱크 → vmalert reload(30s) 후 ① 로드된 expr에 rollup 반영,
  ② **가시성 직접 증명**: 마지막 push 후 5분이 지난 시점(하루의 99.65%)에 instant 질의로
  `last_over_time(files_data_bulk_avail_bytes[3d])`가 **비어 있지 않음**(맨 참조는 0개), ③ 현재 여유율
  99.9%라 **오발화 0**.
- **`max_lookback` 핀은 이 하네스에선 load-bearing이 아니다**(일 단위 간격이라 replay 보간이 24시간 갭을
  못 건넌다 — 구현자가 빼고 돌려 동일 판정 실증). 거짓 GREEN 방어의 권위는 **L3**다.
