#!/usr/bin/env python3
"""vmalert-bulkssd-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

라이브 데이터 모델을 그대로 재현한다 — 둘 다 **하루 1회 단발 push**(라벨 없음/tier 라벨만):
  - files_data_bulk_{avail,size}_bytes          ← 호스트 launchd(scripts/backup-files-data.sh, 04:30, 일 1회)
  - storage_tier_{avail,size}_bytes{tier="bulk"} ← in-cluster pvc-du-exporter CronJob(05:00, 일 1회)
두 pusher는 **같은 물리 매체(2TB 외장 SSD)**를 본다(라이브: size 2000293007360 바이트 일치). 그래서
같은 결핍을 먹였을 때 rollup을 착용한 BulkStorageLow는 발화하고, 맨 참조인 FilesBulkSSDLow는 못 하는
**대조**가 성립한다 — 이게 이 버그의 가장 선명한 증거다(L4).

시나리오(argv[1]):
  low     — 여유율 5%(FilesBulkSSDLow 임계 10%·BulkStorageLow 임계 15% 양쪽 미만) 지속.
  healthy — 여유율 99%(정상) — 어떤 bulk 용량 알림도 발화하면 안 된다.

⚠️ 두 pusher 모두 값(avail/size)만 다르고 **타임스탬프 격자는 동일**(일 1회) — 버그는 값이 아니라
   **가시성**의 문제이므로 두 시나리오의 격자는 반드시 같아야 한다(교란변수 제거).

argv: <scenario> <t_last_host_push> <push_period_s> <days> <du_period_s> <du_offset_s>
"""
import json
import sys

SCENARIO = sys.argv[1]
T_LAST = int(sys.argv[2])       # 마지막 호스트 push 시각(replay 창 안 — 가시 5분을 재현)
PUSH_S = int(sys.argv[3])       # 호스트 push 주기(86400)
DAYS = int(sys.argv[4])         # 백필 일수
DU_S = int(sys.argv[5])         # du exporter push 주기(CronJob에서 파생)
DU_OFF = int(sys.argv[6])       # du exporter 오프셋(05:00 − 04:30 = +1800s)

# 라이브 실측 bulk SSD 총량(2TB 외장) — 절대값이 그럴듯해야 실패 메시지가 읽힌다.
SIZE = 2000293007360

RATIO = {"low": 0.05, "healthy": 0.99}
if SCENARIO not in RATIO:
    sys.stderr.write("unknown scenario: %s\n" % SCENARIO)
    sys.exit(2)
AVAIL = int(SIZE * RATIO[SCENARIO])


def daily_grid(t_last, period, days, offset=0):
    """t_last(+offset) 기준으로 period 간격 days개 — 과거로 거슬러 심는다."""
    return sorted((t_last + offset - k * period) * 1000 for k in range(days))


def series(name, value, timestamps, labels=None):
    metric = {"__name__": name}
    metric.update(labels or {})
    return {"metric": metric, "values": [value] * len(timestamps), "timestamps": timestamps}


host_ts = daily_grid(T_LAST, PUSH_S, DAYS)
du_ts = daily_grid(T_LAST, DU_S, DAYS, DU_OFF)
BULK = {"tier": "bulk"}

out = [
    # 호스트 launchd push(라벨 없음 — /api/v1/import/prometheus, extra_label 미사용).
    series("files_data_bulk_avail_bytes", AVAIL, host_ts),
    series("files_data_bulk_size_bytes", SIZE, host_ts),
    # in-cluster du exporter push(tier 라벨만).
    series("storage_tier_avail_bytes", AVAIL, du_ts, BULK),
    series("storage_tier_size_bytes", SIZE, du_ts, BULK),
]
# ⚠️ files_backup_last_success_timestamp / pvc_du_last_success_timestamp는 **의도적으로 심지 않는다** —
#    같은 r4 그룹의 absent 가드 알림(FilesBackupStale)이 매 replay에서 확실히 발화해 **vacuity 대조군**
#    역할을 한다("발화 없음"이 판정인 음성 레그에서 vmalert가 애초에 아무것도 안 쓴 경우를 가려낸다).

for o in out:
    if not o["timestamps"]:
        sys.stderr.write("empty series in scenario %s — 시간창 계산 오류\n" % SCENARIO)
        sys.exit(2)
    print(json.dumps(o))

sys.stderr.write(
    "gen[%s]: ratio=%.2f avail=%d size=%d host_pushes=%d du_pushes=%d\n"
    % (SCENARIO, RATIO[SCENARIO], AVAIL, SIZE, len(host_ts), len(du_ts))
)
