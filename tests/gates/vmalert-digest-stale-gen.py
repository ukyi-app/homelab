#!/usr/bin/env python3
"""vmalert-digest-stale-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

라이브 데이터 모델을 그대로 재현한다:
  - digest_exporter_last_success_timestamp  ← digest-exporter CronJob(*/10, 10분 주기) **bare 시리즈**
    (라벨 0, 값 = push 시각 epoch 초 — 타임스탬프-값 하트비트)
  - ghcr_latest_digest{app,digest}          ← 같은 페이로드의 수집 결과(디코이 — 판정에 무관)

⚠️ 하트비트는 **bare**여야 한다(라벨 0). `time() - last_over_time(m[W]) > T or absent(last_over_time(m[W]))`
   에서 좌·우 브랜치가 같은 (빈) 라벨셋을 내야 시리즈 만료 시 알림 identity가 유지된다.

⚠️ files_backup_last_success_timestamp는 **어느 시나리오에서도 심지 않는다** — 같은 r4 그룹의 absent 가드
   알림(FilesBackupStale)이 매 replay에서 확실히 발화해 **vacuity 대조군**이 된다(L2처럼 "발화 없음"이
   판정인 음성 레그에서 vmalert가 애초에 아무것도 안 쓴 경우를 가려낸다).

시나리오(argv[1]):
  healthy   — 하트비트가 replay 전 구간에 걸쳐 push 주기마다 도착(정상). 최대 나이 = push 주기 < 임계.
  stale     — 하트비트가 STALE_LAST에서 끊긴다(크론 미실행/push 사망). replay 전 구간에서 나이 > 임계이되
              rollup 윈도 [W] 안에는 남아 있다 → **stale-샘플 가지**(absent 가지가 아니다 — L5와 다른 코드 경로).
  absent    — 하트비트 샘플이 **하나도 없다**(한 번도 push된 적 없음 / [W] 만료) → **absent 가지**의 유일한 증명.
              하네스 생존 확인용 마커 시리즈만 심는다(TSDB 공백 → 무성 무측정 방지).
  bootstrap — 평가 시작 시점에 하트비트 없음 → 첫 샘플이 **강제 상한**(BOUND_S = cron + 파드예산 + ADS)에
              **정확히** 도착. 최초 배포의 최악 시나리오를 재현한다(거짓 페이지가 구조적으로 불가능함을 증명).

argv: <scenario> <rp_from> <rp_to> <push_s> <bound_s> <stale_last> <backfill_n>
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


out = []
if SCENARIO == "healthy":
    ts = grid(RP_FROM - BACKFILL_N * PUSH_S, RP_TO, PUSH_S)
    out = [heartbeat(ts), decoy(ts)]
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
sys.stderr.write("gen[%s]: heartbeats=%d (push=%ds bound=%ds) replay=[%d..%d]\n"
                 % (SCENARIO, n_hb, PUSH_S, BOUND_S, RP_FROM, RP_TO))
