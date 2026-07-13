# Verification — digest-exporter-stale

증거 수집: 2026-07-13 · HEAD `3bb6135`(I-1 `5a64480` + I-2 `56cf311` 포함) · 트리 clean(0 dirty)
수집자 = 컨덕터가 **직접 재실행**(서브에이전트 보고는 증거가 아니다). 모든 명령은
`PATH="$HOME/.local/share/mise/installs/bun/1.3.14/bin:$PATH"`(Makefile이 bun 1.3.14 강제)로 실행.

라이브(클러스터) 검증은 **랜딩 후**에만 가능하다(ArgoCD가 `main`만 감시). 그 절차·차단 조건·실패 시
롤백 분기는 PRD "롤아웃·롤백 계약"에 있고, 결과는 랜딩 후 `live-verification.md`에 기록한다.

## 요약

| # | 주장(claim) | 명령 | 결과 |
|---|---|---|---|
| G1 | 기반 게이트(skeleton·원장·sops) + 알림 룰 린터 통과 | `make verify` | **exit 0** |
| G2 | 신규 메트릭 3건 레지스트리 등재, 모드 A/B/C 위반 0 | `bun tools/check-alert-rules.ts` | **exit 0** |
| G3 | 정적 게이트 + producer 행위 테스트(입력 4종의 카운트·하트비트 값) | `bats tests/gates/test_digest-exporter.bats tests/gates/test_digest-exporter-producer.bats` | **exit 0** (19/19) |
| G4 | 발화 e2e 7레그 — 두 알림이 **구조적으로 발화 가능**함의 증명 | `bash tests/gates/vmalert-digest-stale-firing-e2e.sh` | **exit 0** (460s) |
| G5 | 핀된 skopeo가 `--command-timeout`을 **실제로** 강제(순차 예산의 전제) | `bash tests/gates/skopeo-timeout-smoke.sh` | **exit 0** |
| G6 | 공유 lib 변경이 형제 하네스를 깨지 않음(무회귀) | `bash tests/gates/vmalert-bulkssd-firing-e2e.sh` | **exit 0** (159s) |
| G7 | 함정 원장 양방향 tie | `make verify-traps` | **exit 0** |
| G8 | 전체 스위트(required `gate` 로컬 재현) | `make ci` | **exit 0** (bats 1207) |
| **M1** | producer 테스트에 **이빨이 있다** | 뮤테이션 후 `bats …-producer.bats` | **exit 1 (RED — 기대대로)** |
| **M2** | 레지스트리 완전성 가드에 **이빨이 있다** | 뮤테이션 후 `bun tools/check-alert-rules.ts` | **exit 1 (RED — 기대대로)** |
| **M3** | 발화 e2e에 **이빨이 있다**(owner 결정 ④의 락) | 뮤테이션 후 e2e | **exit 1 (RED — 기대대로)** |

뮤테이션은 전부 `git checkout --`으로 복원했고, 최종 트리는 **0 dirty**로 확인했다.

## G2 — 레지스트리·모드 C

```
$ bun tools/check-alert-rules.ts
check-alert-rules OK (43 룰 스캔, push 생산자 5건 / 등록 메트릭 14건[모드 C 대상 14], 룩백 300s, 모드 A/B/C 위반 0)
```

## G4 — 발화 e2e (7레그)

```
$ bash tests/gates/vmalert-digest-stale-firing-e2e.sh
PASS L1 DigestExporterStale fired on a stale heartbeat …
PASS L2 healthy state stays silent for BOTH alerts (firing=0 pending=0; control FilesBackupStale firing=21)
PASS L3 harness has teeth — the frozen bare-reference expr engages (pending) but can never fire
PASS L4 DigestExporterScrapeIncomplete fired on a partial scrape (scraped=1 < configured=2)
       … (DigestExporterStale firing=0) — 축 직교성까지 단언
PASS L5 DigestExporterStale fired with zero heartbeat samples in the TSDB (firing=51) — the
       'or absent(last_over_time(...))' arm is live
PASS L6 zero-app stays silent as decided — counts 0/0 are published yet the strict comparison
       (0 < 0 = false) never engages (firing=0, pending=0), while the control alert proves the replay was live
PASS L7 first deploy cannot false-page — the rule engaged on the empty history (pending=28) but the first
       heartbeat landed at the enforced bound 840s < for: 15m(900s) and reset the hold before it could fire
       (firing=0), with the replay running 2400s past that point
[elapsed] 460s
vmalert-digest-stale-firing-e2e OK (preflight + L1/L2/L3/L4/L5/L6/L7 통과 …)
```

**L7이 이 기능의 핵심 불변식을 증명한다**: 최초 배포 시 이력이 없어 `absent(...)`가 즉시 pending에
들어가지만(pending=28로 비-vacuity 증명), 첫 하트비트가 **강제 상한 840s**에 도착해 `for: 15m`(900s)
안에서 pending을 리셋한다 → **롤아웃이 원인인 거짓 페이지가 구조적으로 불가능**하다.

## G5 — 핀된 skopeo 실물 타임아웃

```
$ bash tests/gates/skopeo-timeout-smoke.sh
[blackhole] host TCP sink :18443 — accept 후 무응답(TLS ServerHello에서 영구 대기) → 진짜 네트워크 블랙홀
PASS S1 pinned skopeo honored --command-timeout=3s against a hanging TLS blackhole (took 4s)
PASS S2 elapsed tracks the flag value (3s → 4s, 9s → 9s) — the timeout, not some unrelated fast failure, governs
PASS S3 the after-subcommand placement does not leave the scrape unbounded (exited in 3s)
skopeo-timeout-smoke OK
```

이 seam이 없으면 순차 스크레이프 예산(`POD_START + N×SKOPEO_TIMEOUT + CURL_MAX_TIME + EXEC_SLACK
< activeDeadlineSeconds`) 전체가 **검증되지 않은 전제** 위에 서게 된다. PATH stub으로는 증명할 수 없다.

## M1 — producer 테스트의 이빨 (RED 증명)

뮤테이션: `SCRAPED=$((SCRAPED+1))`를 `[ -z "$DIGEST" ] && continue` **앞**으로 이동
(= skopeo가 전부 실패해도 `scraped == configured`로 오보고 → US2가 조용히 깨지는 바로 그 결함).

```
$ bats tests/gates/test_digest-exporter-producer.bats
not ok 4 producer counts only the successful scrapes when some skopeo lookups fail
not ok 5 producer reports zero scraped apps while still emitting the heartbeat when every scrape fails
exit=1
```
복원 확인: 0 dirty.

## M2 — 레지스트리 완전성 가드의 이빨 (RED 증명)

뮤테이션: `DEFAULT_REGISTRY`에서 `digest_exporter_apps_scraped` 1건 제거.

```
$ bun tools/check-alert-rules.ts
FAIL: push 메트릭 레지스트리 완전성 위반 — 미등록 메트릭은 모드 C 검사를 빠져나가 죽은 알림으로 배포된다 …
  platform/victoria-stack/prod/digest-exporter.yaml — push하는 메트릭 'digest_exporter_apps_scraped'이
  레지스트리에 없음(기존 exporter에 메트릭 추가 = 모드 C 우회 경로)
exit=1
```
복원 확인: 0 dirty.

## M3 — 발화 e2e의 이빨 · owner 결정 ④의 락 (RED 증명)

뮤테이션: `DigestExporterScrapeIncomplete`의 `<`를 `<=`로 확대(= 정상 상태와 zero-app에서 오발화).

```
$ bash tests/gates/vmalert-digest-stale-firing-e2e.sh
FAIL L2 DigestExporterScrapeIncomplete FIRED (firing=21) while scraped == configured == 2 — false positive.
       The comparison must be strict (<) …
FAIL L6 DigestExporterScrapeIncomplete engaged on a zero-app exporter (firing=21, pending=60) although
       counts are 0/0 … Someone widened the comparison to '<=' or added a 'configured == 0' guard;
       the deliberate gap is documented in the rule comment …
vmalert-digest-stale-firing-e2e: 2 leg(s) FAILED
exit=1
```
복원 확인: 0 dirty(전체 트리).

## 미검증으로 남는 것 (정직한 공백)

- **라이브 동작**(ArgoCD 싱크 → vmalert reload → 실제 하트비트 적재·알림 로드): 랜딩 전에는 관측
  불가능하다. 랜딩 후 `live-verification.md`에 ①싱크 직전 레거시 Job 활성 여부 ②후속 Job UID
  ③**첫 하트비트 실측 지연 vs 강제 상한 840s**를 기록한다(PRD "랜딩 후 라이브 체크포인트").
- **`Replace` 전이의 실물 테스트**(행 상태의 레거시 Job → 제한된 후속 Job): plan 게이트 r7에서 owner가
  **Reject + waive**한 항목(kind 기반 전이 테스트 신설은 비용 비대칭). 보상 통제 = 정적 게이트(`Replace`·
  `activeDeadlineSeconds` 존재) + preflight 불변식 + 랜딩 후 실물 관측.
