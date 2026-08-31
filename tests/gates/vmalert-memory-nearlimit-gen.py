#!/usr/bin/env python3
"""vmalert-memory-nearlimit-firing-e2e 하네스용 합성 시계열 생성기 — VictoriaMetrics /api/v1/import(JSON lines).

라이브 데이터 모델을 그대로 재현한다 — 전부 **scrape 메트릭**이라 push 구멍(모드 C) 축이 없다:
  - container_memory_{usage_bytes,cache,working_set_bytes}            ← kubelet cAdvisor
  - container_memory_total_{inactive,active}_file_bytes               ← 같은 cAdvisor(파일 LRU 두 축)
  - kube_pod_container_resource_limits{resource="memory"}             ← kube-state-metrics

세 컨테이너를 **한 픽스처에** 심는다. 같은 replay에서 어느 쪽이 울고 어느 쪽이 침묵하는지의 대조가
이 알림 결함들의 가장 선명한 증거이고, 시나리오를 갈라 replay하면 그 대조가 사라진다.

  cachebound — glances 라이브 실측 형상(2026-08-31 cgroup raw). 회수 가능한 clean page cache가
               working_set을 밀어올렸을 뿐 회수 불가는 limit의 67%다. **발화하면 안 된다.**
  anonbound  — 진짜 OOM 임박. 캐시가 거의 없고 anon 자체가 limit의 95%다. **발화해야 한다.**
  shmembound — postgres 계열 형상(shared_buffers). anon은 작지만 **shmem이 limit의 78%**다.
               호스트는 swap이 0이라 shmem은 회수될 수 없다. **발화해야 한다.**

⚠️ shmembound가 이 하네스에서 가장 미묘한 레그다. cgroup v2의 `memory.stat:file`은 tmpfs·shared
   memory를 **포함**하므로 `usage − cache`를 분자로 쓰면 그 78%가 통째로 빠져 15.6%로 평가된다
   (r1 리뷰 F1 — 라이브에서 database/pg-1이 shmem 38Mi를 그렇게 잃었다: 7.6% → 3.9%).
   `usage − inactive_file − active_file`은 파일 LRU의 회수 가능분만 빼므로 shmem이 남는다.

⚠️ 파생 메트릭은 **독립 상수로 적지 않는다** — 커널 항등식으로 계산해 넣는다:
       cache        = inactive_file + active_file + shmem     (라이브 40+ cgroup에서 1페이지 오차 내 성립)
       working_set  = usage − inactive_file
   손으로 따로 적으면 서로 모순된 형상(working_set > usage 같은)이 되어 하네스가 물리적으로 불가능한
   상태를 검증하게 된다.

vacuity 대조군으로 `up == 0`을 심어 같은 replay에서 core의 TargetDown이 확실히 발화하게 한다
(발화 부재가 판정인 레그에서 "vmalert가 애초에 아무것도 안 썼다"를 가려낸다).

argv: <out> <from_epoch> <to_epoch> <step_s>
"""
import json
import sys

OUT = sys.argv[1]
FROM = int(sys.argv[2])
TO = int(sys.argv[3])
STEP = int(sys.argv[4])

MI = 1048576
LIMIT = 128 * MI          # 134217728 — glances 매니페스트 limit과 동일

# ── cachebound: 라이브 실측(2026-08-31, observability/glances cgroup raw) ──────────────────────────
# $ cat memory.current → 132878336   $ cat memory.max → 134217728
# $ grep -E '^(file|inactive_file|shmem) ' memory.stat → file 42930176 / inactive_file 14307328 / shmem 0
# active_file은 항등식으로 42930176 − 14307328 − 0 = 28622848. 파생 working_set 118571008은 VM이
# 관측한 값과 **바이트 단위로 일치**했다.
CB_USAGE, CB_INACTIVE, CB_ACTIVE, CB_SHMEM = 132878336, 14307328, 28622848, 0

# ── anonbound: 진짜 OOM 임박 — 값은 실측이 아니라 **구성**이다(이 형상의 상주 워크로드가 지금 없다).
#    working_set·회수 불가 두 축 모두 임계를 넘도록 잡아, 처방이 참양성을 죽이지 않았음을 잰다.
AB_USAGE, AB_INACTIVE, AB_ACTIVE, AB_SHMEM = 124 * MI, 1 * MI, 1 * MI, 0

# ── shmembound: postgres 계열(shared_buffers). anon 20Mi인데 shmem 100Mi — swap 0이라 회수 불가.
#    ★ 이 조합이 F1의 회귀 앵커다: usage−cache는 15.6%(침묵·버그), usage−inactive−active는 93.8%(발화).
SB_USAGE, SB_INACTIVE, SB_ACTIVE, SB_SHMEM = 123 * MI, 2 * MI, 1 * MI, 100 * MI

SCENARIOS = [
    # (pod, container, usage, inactive_file, active_file, shmem)
    ("glances-cachebound-0", "cachebound", CB_USAGE, CB_INACTIVE, CB_ACTIVE, CB_SHMEM),
    ("worker-anonbound-0", "anonbound", AB_USAGE, AB_INACTIVE, AB_ACTIVE, AB_SHMEM),
    ("db-shmembound-0", "shmembound", SB_USAGE, SB_INACTIVE, SB_ACTIVE, SB_SHMEM),
]

# 룰의 namespace 제외 목록(kube-system|kube-public|kube-node-lease) 밖이어야 셀렉터에 잡힌다.
NS = "observability"

ts = list(range(FROM, TO + 1, STEP))
if not ts:
    sys.exit("gen: 타임스탬프 격자가 비었다 — 창/step 산술 오류")

lines = []


def series(name, value, labels):
    metric = {"__name__": name}
    metric.update(labels)
    lines.append(json.dumps({
        "metric": metric,
        "values": [value] * len(ts),
        "timestamps": [t * 1000 for t in ts],
    }))


for pod, container, usage, inactive, active, shmem in SCENARIOS:
    cache = inactive + active + shmem          # 커널 항등식 — 독립 상수로 적지 않는다
    working_set = usage - inactive             # 〃
    if not (cache <= usage and working_set <= usage):
        sys.exit("gen: %s 형상이 물리적으로 불가능하다(cache=%d ws=%d usage=%d)"
                 % (container, cache, working_set, usage))
    cadvisor = {"namespace": NS, "pod": pod, "container": container,
                "job": "kubelet-cadvisor", "instance": "k3s"}
    series("container_memory_usage_bytes", usage, cadvisor)
    series("container_memory_cache", cache, cadvisor)
    series("container_memory_working_set_bytes", working_set, cadvisor)
    series("container_memory_total_inactive_file_bytes", inactive, cadvisor)
    series("container_memory_total_active_file_bytes", active, cadvisor)
    series("kube_pod_container_resource_limits", LIMIT, {
        "namespace": NS, "pod": pod, "container": container,
        "resource": "memory", "unit": "byte",
        "job": "pod-annotations", "instance": "10.42.0.12:8080", "node": "k3s",
    })

# vacuity 대조군 — 같은 replay에서 TargetDown(up == 0, for: 5m)이 반드시 발화한다.
series("up", 0, {"job": "harness-vacuity", "instance": "k3s"})

open(OUT, "w").write("\n".join(lines) + "\n")

for _, c, u, i, a, s in SCENARIOS:
    sys.stderr.write(
        "gen[%s]: working_set=%.4f  usage-cache=%.4f  usage-inactive-active=%.4f\n"
        % (c, (u - i) / LIMIT, (u - (i + a + s)) / LIMIT, (u - i - a) / LIMIT)
    )
sys.stderr.write("gen: samples=%d step=%ds\n" % (len(ts), STEP))
