#!/usr/bin/env python3
"""vmalert-digest-stale-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

라이브 데이터 모델을 그대로 재현한다:
  - digest_exporter_last_success_timestamp  ← digest-exporter CronJob(*/10, 10분 주기) **bare 시리즈**
    (라벨 0, 값 = push 시각 epoch 초 — 타임스탬프-값 하트비트)
  - digest_exporter_apps_configured / _apps_scraped ← 같은 페이로드의 **수집 카운트**(bare 게이지 — 라벨 0)
  - ghcr_latest_digest{app,digest}          ← 같은 페이로드의 수집 결과(디코이 — 판정에 무관)

⚠️ 하트비트는 **bare**여야 한다(라벨 0). `time() - last_over_time(m[W]) > T or absent(last_over_time(m[W]))`
   에서 좌·우 브랜치가 같은 (빈) 라벨셋을 내야 시리즈 만료 시 알림 identity가 유지된다.
⚠️ 카운트 2종도 **bare**여야 한다 — 룰이 on()/ignoring() 없이 1:1 스칼라 비교(scraped < configured)를 하므로
   한쪽에만 라벨이 붙으면 매치가 사라져 빈 벡터 = 조용한 무발화가 된다(producer의 계약과 동형).

⚠️ files_backup_last_success_timestamp는 **어느 시나리오에서도 심지 않는다** — 같은 r4 그룹의 absent 가드
   알림(FilesBackupStale)이 매 replay에서 확실히 발화해 **vacuity 대조군**이 된다(L2/L6처럼 "발화 없음"이
   판정인 음성 레그에서 vmalert가 애초에 아무것도 안 쓴 경우를 가려낸다).

⚠️ 카운트 쌍(configured/scraped)은 **하네스가 argv로 준다**(SSOT는 e2e). 예전엔 시나리오마다 리터럴로
   하드코딩돼 있어 같은 숫자가 gen·셸 sanity·메시지 산문에 3중으로 흩어졌다. 대신 여기서 **시나리오 의미와
   맞는 쌍인지** 되받아 검사한다(healthy=동수 · incomplete=격차 · zeroapp=0/0) — 하네스가 실수로 어긋난
   쌍을 주면 조용히 다른 시나리오를 재생하는 대신 여기서 죽는다(fail-closed).

시나리오(argv[1]):
  healthy    — 하트비트가 replay 전 구간에 걸쳐 push 주기마다 도착(정상). 최대 나이 = push 주기 < 임계.
               카운트는 **같은 비-0 값**(scraped == configured > 0) → 두 알림 모두 침묵해야 한다(L2).
  stale      — 하트비트가 STALE_LAST에서 끊긴다(크론 미실행/push 사망). replay 전 구간에서 나이 > 임계이되
               rollup 윈도 [W] 안에는 남아 있다 → **stale-샘플 가지**(absent 가지가 아니다 — L5와 다른 코드 경로).
  absent     — 하트비트 샘플이 **하나도 없다**(한 번도 push된 적 없음 / [W] 만료) → **absent 가지**의 유일한 증명.
               하네스 생존 확인용 마커 시리즈만 심는다(TSDB 공백 → 무성 무측정 방지).
  bootstrap  — 평가 시작 시점에 하트비트 없음 → 첫 샘플이 **강제 상한**(BOUND_S = cron + 파드예산 + ADS)에
               **정확히** 도착. 최초 배포의 최악 시나리오를 재현한다(거짓 페이지가 구조적으로 불가능함을 증명).
  incomplete — 하트비트는 **정상**(push 경로 생존)인데 카운트가 scraped < configured → 부분 고장
               (GHCR 장애·ghcr-read 만료로 일부 앱만 스킵). DigestExporterScrapeIncomplete가 발화해야 한다(L4).
               하트비트가 정상인 것이 핵심이다 — 이 고장은 Stale이 **원리적으로 못 잡는** 축이다.
  zeroapp    — 하트비트 정상 + 카운트 0/0(마지막 앱 teardown). `0 < 0`이 거짓이라 **무발화**가 정답이다
               (owner 결정 ④ — 의도된 공백). 카운트 시리즈는 **실제로 존재**해야 한다(0 값으로) — 미발행이면
               빈 벡터라 우연히 조용할 뿐이고 레그가 vacuous해진다(L6).

argv: <scenario> <rp_from> <rp_to> <push_s> <bound_s> <stale_last> <backfill_n> <configured> <scraped>
"""
import json
import sys

SCENARIO = sys.argv[1]
RP_FROM = int(sys.argv[2])
RP_TO = int(sys.argv[3])
PUSH_S = int(sys.argv[4])      # digest-exporter 크론 주기(600) — CronJob에서 파생
BOUND_S = int(sys.argv[5])     # 강제된 최악 첫 하트비트 상한(cron + POD_START + activeDeadlineSeconds)
STALE_LAST = int(sys.argv[6])  # stale 시나리오의 마지막 하트비트 시각
BACKFILL_N = int(sys.argv[7])  # replay 이전 백필 샘플 수
CONFIGURED = int(sys.argv[8])  # 설정된 앱 수(= digest_exporter_apps_configured 값) — 하네스가 SSOT
SCRAPED = int(sys.argv[9])     # 수집 성공 앱 수(= digest_exporter_apps_scraped 값)


def bad_counts(msg):
    sys.stderr.write("gen[%s]: 카운트 쌍(configured=%d scraped=%d)이 시나리오 의미와 어긋난다 — %s\n"
                     % (SCENARIO, CONFIGURED, SCRAPED, msg))
    sys.exit(2)


# 시나리오 ↔ 카운트 쌍 정합성(fail-closed): 하네스가 어긋난 쌍을 주면 **다른 시나리오를 조용히 재생**하는
# 대신 여기서 죽는다(예: incomplete에 2/2를 주면 L4가 발화 없음을 정상으로 오판하며 green이 된다).
if SCENARIO == "healthy" and not (CONFIGURED > 0 and SCRAPED == CONFIGURED):
    bad_counts("healthy는 전건 수집 성공(scraped == configured > 0)이어야 한다")
if SCENARIO == "incomplete" and not (0 <= SCRAPED < CONFIGURED):
    bad_counts("incomplete는 부분 고장(0 <= scraped < configured)이어야 한다 — 격차가 없으면 L4가 무측정이다")
if SCENARIO == "zeroapp" and not (CONFIGURED == 0 and SCRAPED == 0):
    bad_counts("zeroapp은 0/0이어야 한다(마지막 앱 teardown)")


def grid(start, end, period):
    """[start, end]를 period 간격으로 — 하트비트 push 격자."""
    return [t for t in range(start, end + 1, period)]


def series(name, values, timestamps, labels=None):
    metric = {"__name__": name}
    metric.update(labels or {})
    return {"metric": metric, "values": values, "timestamps": [t * 1000 for t in timestamps]}


def heartbeat(timestamps):
    # ★ 값 = 그 시각의 epoch 초(타임스탬프-값). time() - last_over_time(...)이 곧 "마지막 push 이후 경과"다.
    return series("digest_exporter_last_success_timestamp", [float(t) for t in timestamps], timestamps)


def decoy(timestamps):
    # 같은 curl 페이로드에 실리는 수집 결과(판정 무관 — 하네스가 살아 있음의 방증).
    return series("ghcr_latest_digest", [1] * len(timestamps), timestamps,
                  {"app": "page", "digest": "sha256:" + "a" * 64})


def counts(timestamps, configured, scraped):
    # 수집 카운트 2종 — **bare**(라벨 0). 값은 replay 전 구간에 걸쳐 상수(고장이 지속되는 상황을 모형화).
    return [series("digest_exporter_apps_configured", [configured] * len(timestamps), timestamps),
            series("digest_exporter_apps_scraped", [scraped] * len(timestamps), timestamps)]


out = []
if SCENARIO == "healthy":
    ts = grid(RP_FROM - BACKFILL_N * PUSH_S, RP_TO, PUSH_S)
    out = [heartbeat(ts), decoy(ts)] + counts(ts, CONFIGURED, SCRAPED)
elif SCENARIO == "stale":
    ts = grid(STALE_LAST - BACKFILL_N * PUSH_S, STALE_LAST, PUSH_S)
    out = [heartbeat(ts), decoy(ts)]
elif SCENARIO == "absent":
    # 하트비트 0개. 마커만 — "TSDB가 비어 아무것도 평가 안 됐다"와 "absent 가지가 실제로 참"을 가른다.
    ts = grid(RP_FROM - BACKFILL_N * PUSH_S, RP_TO, PUSH_S)
    out = [series("harness_alive_marker", [1] * len(ts), ts)]
elif SCENARIO == "bootstrap":
    ts = grid(RP_FROM + BOUND_S, RP_TO, PUSH_S)
    out = [heartbeat(ts), decoy(ts)]
elif SCENARIO == "incomplete":
    # 부분 고장: push 경로는 살아 있고(하트비트 정상) 설정된 앱 중 일부만 수집 성공.
    ts = grid(RP_FROM - BACKFILL_N * PUSH_S, RP_TO, PUSH_S)
    out = [heartbeat(ts), decoy(ts)] + counts(ts, CONFIGURED, SCRAPED)
elif SCENARIO == "zeroapp":
    # zero-app: 앱 0개 → 감시 대상 없음. 0 < 0 = 거짓이라 침묵이 정답(의도된 공백).
    ts = grid(RP_FROM - BACKFILL_N * PUSH_S, RP_TO, PUSH_S)
    out = [heartbeat(ts)] + counts(ts, CONFIGURED, SCRAPED)
else:
    sys.stderr.write("unknown scenario: %s\n" % SCENARIO)
    sys.exit(2)

for o in out:
    if not o["timestamps"]:
        sys.stderr.write("empty series in scenario %s — 시간창 계산 오류\n" % SCENARIO)
        sys.exit(2)
    print(json.dumps(o))

hb = [o for o in out if o["metric"]["__name__"] == "digest_exporter_last_success_timestamp"]
n_hb = len(hb[0]["timestamps"]) if hb else 0
sys.stderr.write("gen[%s]: heartbeats=%d counts=%d/%d (push=%ds bound=%ds) replay=[%d..%d]\n"
                 % (SCENARIO, n_hb, SCRAPED, CONFIGURED, PUSH_S, BOUND_S, RP_FROM, RP_TO))
