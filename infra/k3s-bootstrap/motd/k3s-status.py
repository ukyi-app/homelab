#!/usr/bin/env python3
"""MOTD용 Ready 노드·파드, 미해소 문제, 복구된 CronJob 실패 집계."""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def timestamp(value):
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("타임존 없는 시각")
    return parsed


def ready(item):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in item.get("status", {}).get("conditions", []))


def owner(item, kind, objects):
    namespace = item["metadata"].get("namespace")
    for ref in item["metadata"].get("ownerReferences", []):
        if ref.get("kind") != kind or ref.get("controller") is not True:
            continue
        candidate = objects.get((namespace, ref["name"]))
        if candidate and ref.get("uid") and candidate["metadata"].get("uid") == ref["uid"]:
            return candidate
    return None


def recovered(pod, jobs, cronjobs, now):
    job = owner(pod, "Job", jobs)
    if job is None:
        return False
    cronjob = owner(job, "CronJob", cronjobs)
    if cronjob is None:
        return False
    success = timestamp(cronjob.get("status", {}).get("lastSuccessfulTime"))
    # 생성 시각만으로는 실패 이후 성공인지 알 수 없다. 종료/실패 시각이 필요하다.
    times = []
    for field in ("initContainerStatuses", "containerStatuses"):
        times.extend(timestamp(c.get("state", {}).get("terminated", {}).get("finishedAt"))
                     for c in pod.get("status", {}).get(field, []))
    times.extend(timestamp(c.get("lastTransitionTime"))
                 for c in job.get("status", {}).get("conditions", [])
                 if c.get("type") == "Failed" and c.get("status") == "True")
    times = [t for t in times if t is not None]
    if not times:
        return False
    created = timestamp(pod["metadata"].get("creationTimestamp"))
    if created:
        times.append(created)
    return bool(success and times and max(times) < success <= now)


def summarize(data):
    if data.get("kind") != "List" or not isinstance(data.get("items"), list):
        raise ValueError("잘못된 List 응답")
    groups = {kind: [] for kind in ("Node", "Pod", "Job", "CronJob")}
    for item in data["items"]:
        groups[item["kind"]].append(item)
    nodes = groups["Node"]
    if not nodes:
        raise ValueError("노드 조회 공백")
    jobs, cronjobs = ({(i["metadata"].get("namespace"), i["metadata"]["name"]): i
                      for i in groups[kind]} for kind in ("Job", "CronJob"))
    now = datetime.now(timezone.utc)
    healthy = bad = history = 0
    for pod in groups["Pod"]:
        phase = pod["status"]["phase"]
        if phase == "Succeeded":
            continue
        if phase == "Failed" and recovered(pod, jobs, cronjobs, now):
            history += 1
        elif phase == "Running" and ready(pod) and not pod["metadata"].get("deletionTimestamp"):
            healthy += 1
        else:
            bad += 1
    return sum(ready(n) for n in nodes), len(nodes), healthy, bad, history


def main():
    try:
        # 다중 GET 중 하나라도 실패하면 부분 stdout을 정상 스냅샷으로 쓰지 않는다.
        result = subprocess.run(
            [os.environ.get("K3S_BIN", "/usr/local/bin/k3s"), "kubectl", "get",
             "nodes,pods,jobs,cronjobs", "-A", "-o", "json", "--request-timeout=5s"],
            check=True, capture_output=True, text=True, timeout=10,
        )
        print(*summarize(json.loads(result.stdout)))
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError):
        # API 응답·오류는 자격이나 파드 환경을 포함할 수 있으므로 출력하지 않는다.
        print("unreachable")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
