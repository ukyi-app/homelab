# Verification — digest-exporter-stale

증거 수집: 2026-07-13 · HEAD `ea444d7`(I-1 `5a64480` + I-2 `56cf311` + release 게이트 R-1/R-3/R-4 수정)
· 트리 clean(0 dirty). 수집자 = **컨덕터가 직접 재실행**(서브에이전트 보고는 증거가 아니다).
모든 명령은 `PATH="$HOME/.local/share/mise/installs/bun/1.3.14/bin:$PATH"`로 실행(Makefile이 bun 1.3.14 강제).

라이브(클러스터) 검증은 **랜딩 후**에만 가능하다(ArgoCD가 `main`만 감시). 절차·차단 조건·원인별 롤백은
PRD "랜딩 후 라이브 체크포인트"에 있고, 결과는 `live-verification.md`에 기록한다.

## 요약

| # | 주장(claim) | 명령 | 결과 |
|---|---|---|---|
| G1 | 기반 게이트(skeleton·원장·sops) + 알림 룰 린터 | `make verify` | **exit 0** |
| G2 | 신규 메트릭 3건 등재 · 모드 A/B/C 위반 0 | `bun tools/check-alert-rules.ts` | **exit 0** |
| G3 | 정적 게이트 + producer 행위 테스트 | `bats tests/gates/test_digest-exporter{,-producer}.bats` | **exit 0** |
| G4 | 발화 e2e 7레그 — 두 알림이 **구조적으로 발화 가능**함의 증명 | `bash tests/gates/vmalert-digest-stale-firing-e2e.sh` | **exit 0** (458s) |
| G5 | 핀된 skopeo가 `--command-timeout`을 **실제로** 강제 | `bash tests/gates/skopeo-timeout-smoke.sh` | **exit 0** |
| G6 | 공유 lib 변경이 형제 하네스를 깨지 않음 | `bash tests/gates/vmalert-bulkssd-firing-e2e.sh` | **exit 0** (157s) |
| G7 | 함정 원장 양방향 tie | `make verify-traps` | **exit 0** |
| G8 | 전체 스위트(required `gate` 로컬 재현) | `make ci` | **exit 0** |
| **M1** | producer 테스트에 이빨이 있다 | 뮤테이션 후 producer bats | **exit 1 (RED)** |
| **M2** | 레지스트리 완전성 가드에 이빨이 있다 | 뮤테이션 후 린터 | **exit 1 (RED)** |
| **M3** | 발화 e2e에 이빨이 있다(owner 결정 ④ 락) | 뮤테이션 후 e2e | **exit 1 (RED)** |
| **M4** | **하트비트 순서 락**에 이빨이 있다(release R-1) | 뮤테이션 후 producer bats | **exit 1 (RED, 정확히 2건만)** |

뮤테이션은 전부 복원했고 최종 트리 **0 dirty**(md5 대조 확인).

## G2 — 레지스트리·모드 C

```
$ bun tools/check-alert-rules.ts
check-alert-rules OK (43 룰 스캔, push 생산자 5건 / 등록 메트릭 14건[모드 C 대상 14], 룩백 300s, 모드 A/B/C 위반 0)
```

## G4 — 발화 e2e (7레그)

```
$ bash tests/gates/vmalert-digest-stale-firing-e2e.sh
PASS L1 DigestExporterStale fired on a stale heartbeat
PASS L2 healthy state stays silent for BOTH alerts (firing=0 pending=0; control FilesBackupStale firing=21)
PASS L3 harness has teeth — the frozen bare-reference expr engages (pending) but can never fire
PASS L4 DigestExporterScrapeIncomplete fired on a partial scrape (scraped=1 < configured=2)
       … (DigestExporterStale firing=0) — 축 직교성까지 단언
PASS L5 DigestExporterStale fired with zero heartbeat samples (firing=51) — the 'or absent(...)' arm is live
PASS L6 zero-app stays silent as decided (0 < 0 = false; control alert proves the replay was live)
PASS L7 first deploy cannot false-page — the rule engaged on the empty history (pending=28) but the first
       heartbeat landed at the enforced bound 840s < for: 15m(900s) and reset the hold before it could fire
[elapsed] 458s
vmalert-digest-stale-firing-e2e OK (preflight + L1/L2/L3/L4/L5/L6/L7 통과)
```

**L7이 핵심 불변식을 증명한다**: 최초 배포 시 이력이 없어 `absent(...)`가 즉시 pending에 들어가지만
(pending=28 = 비-vacuity 증명), 첫 하트비트가 **강제 상한 840s**에 도착해 `for: 15m`(900s) 안에서
pending을 리셋한다 → **롤아웃이 원인인 거짓 페이지가 구조적으로 불가능**하다.

## G5 — 핀된 skopeo 실물 타임아웃

```
$ bash tests/gates/skopeo-timeout-smoke.sh
[blackhole] host TCP sink :18443 — accept 후 무응답(TLS ServerHello에서 영구 대기)
PASS S1 pinned skopeo honored --command-timeout=3s against a hanging TLS blackhole (took 4s)
PASS S2 elapsed tracks the flag value (3s → 4s, 9s → 9s)
PASS S3 the after-subcommand placement does not leave the scrape unbounded (exited in 3s)
skopeo-timeout-smoke OK
```

이 seam이 없으면 순차 스크레이프 예산 부등식 전체가 **검증되지 않은 전제** 위에 선다(PATH stub으로는
증명 불가 — release 게이트 이전 라운드의 지적).

## M4 — 하트비트 순서 락 (release 게이트 R-1의 픽스 검증)

뮤테이션: 하트비트 블록(`TS=` + `OUT=`)을 **카운트 앞으로** 되돌림 = **유효한 재정렬**(스크립트는 정상
동작). 이것이 R-1이 지적한 상태다 — 스트리밍 절단 시 접두부(하트비트)만 적재되고 카운트가 유실되면
**두 알림 모두 침묵**한다.

```
$ bats tests/gates/test_digest-exporter-producer.bats
ok 1..10   (다른 모든 단언은 통과 — 스크립트는 정상 동작한다)
not ok 11 producer emits the heartbeat as the LAST payload line (post-commit marker)
not ok 12 a truncated push loses the heartbeat first so DigestExporterStale can still fire (fail-closed)
ok 13 producer names the failing app on stderr when a skopeo scrape fails
exit=1
```

정확히 **순서 락과 절단 시나리오 2건만** RED → 이 두 테스트가 그 결함만 겨냥함이 증명됐다.
복원 확인: md5 `12af29d2b08dd421284f73d56d4d107b`, 트리 0 dirty.

## M1 — producer 테스트의 이빨

뮤테이션: `SCRAPED=$((SCRAPED+1))`를 실패 검사 **앞**으로 이동(= 전건 실패에도 `scraped == configured`
오보고 → US2가 조용히 깨지는 결함).

```
not ok 4 producer counts only the successful scrapes when some skopeo lookups fail
not ok 5 producer reports zero scraped apps while still emitting the heartbeat when every scrape fails
exit=1
```

## M2 — 레지스트리 완전성 가드의 이빨

뮤테이션: `DEFAULT_REGISTRY`에서 `digest_exporter_apps_scraped` 1건 제거.

```
FAIL: push 메트릭 레지스트리 완전성 위반 — 미등록 메트릭은 모드 C 검사를 빠져나가 죽은 알림으로 배포된다 …
  digest-exporter.yaml — push하는 메트릭 'digest_exporter_apps_scraped'이 레지스트리에 없음
exit=1
```

## M3 — 발화 e2e의 이빨 · owner 결정 ④의 락

뮤테이션: `DigestExporterScrapeIncomplete`의 `<`를 `<=`로 확대.

```
FAIL L2 DigestExporterScrapeIncomplete FIRED (firing=21) while scraped == configured == 2 — false positive.
FAIL L6 DigestExporterScrapeIncomplete engaged on a zero-app exporter (firing=21, pending=60) …
        Someone widened the comparison to '<=' or added a 'configured == 0' guard
vmalert-digest-stale-firing-e2e: 2 leg(s) FAILED
exit=1
```

## 미검증으로 남는 것 (정직한 공백)

- **라이브 동작**(ArgoCD 싱크 → vmalert reload → 하트비트 적재 → 알림 로드 → alertmanager 재기동 후
  제목 매핑 적용): 랜딩 전에는 관측 불가능. 랜딩 후 `live-verification.md`에 ①싱크 직전 레거시 Job
  활성 여부 ②후속 Job UID ③**첫 하트비트 실측 지연 vs 강제 상한 840s** ④alertmanager 재기동·매핑
  확인을 기록한다.
- **vmsingle이 부분 스트림을 실제로 적재하는가**(R-1의 서버측 전제): 절단 테스트는 **유실 순서**를
  증명하지 hermetic하게 서버 동작을 증명하지 않는다. 하트비트를 마지막에 두는 설계는 어느 쪽이든
  fail-closed다(절단 → 하트비트 유실 → Stale 발화).
- **`Replace` 전이의 실물 테스트**: plan 게이트 r7에서 owner가 **Reject + waive**(비용 비대칭). 보상
  통제 = 정적 게이트 + preflight 불변식 + 랜딩 후 실물 관측.
- **startup 60초 예산**(R-2): 매니페스트 파생이 아닌 **가정**(k8s에 startup 상한이 없다). Follow-up
  **F-7**. 현재 N=2에서 여유 60초이고, 초과 시 Job이 데드라인에 죽어 **하트비트 미발행 → Stale 발화**
  (fail-closed — 최악은 거짓 페이지지 침묵이 아니다).
