#!/usr/bin/env python3
"""vmalert-jobfailed-firing-e2e 하네스용 픽스처 검사기 — 미래 타임스탬프 부재를 단언한다.

타임스탬프-값 메트릭(kube_*_time)은 `값 ≤ 그 샘플의 시각`이어야 한다. 산술 preflight로는
못 잡으므로 생성된 JSONL을 직접 본다(R-2 회귀 앵커).

usage: vmalert-jobfailed-assert.py <jsonl>

⚠️ 독립 파일인 이유: 셸 heredoc에 python을 내장하면 typecheck·lint 사각이 된다 —
   CONTRIBUTING.md 「새 코드 배치 규칙」의 명시적 금지. 형제 관용구 = vmalert-drift-gen.py.
   (2026-09-01 이관 — 종전 하네스의 인라인 블록과 동일한 코드이며,
    하네스 전건 통과가 산출물 동일성의 증인이다.)
"""
import json, sys
# 값이 epoch 타임스탬프인 메트릭 — 이들만 "미래 금지"가 의미를 갖는다(카운터/게이지는 무관).
TS_VALUED = {"kube_cronjob_status_last_successful_time", "kube_job_status_start_time"}
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    s = json.loads(line)
    name = s["metric"].get("__name__", "")
    if name not in TS_VALUED:
        continue
    for v, t_ms in zip(s["values"], s["timestamps"]):
        t = t_ms / 1000
        if v > t:
            bad.append(f"{name}{ {k: x for k, x in s['metric'].items() if k != '__name__'} }: "
                       f"값 {int(v)} > 샘플 시각 {int(t)} (미래 {int(v - t)}s)")
            break
if bad:
    print("\n".join(bad))
    sys.exit(1)
