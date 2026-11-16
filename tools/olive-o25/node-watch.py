#!/usr/bin/env python3
"""올리브 계획 O25: 노드에서 옛 본체의 소멸을 재시작 전부터 지켜보고, 그 시각을 새 세대의 시각과 견준다.

  node-watch.py watch <파드 ID> <세대> <기록.json> [최대 초]
      재시작 요청 전에 띄운다. 그 세대에 심은 다섯 역할(p-<세대>-setsid·nohup·daemon·stubborn·spy)과 본체 PID 1을
      파드 cgroup 안에서 찾아 pid·시작 시각·컨테이너 cgroup으로 고정한다(준비 영수증). 다 찾지 못하거나 첩자가 움직이지
      않으면 고정 실패로 끝난다. 고정하면 "armed" 줄을 찍고, 대상이 모두 사라질 때까지 짧은 간격으로 본다.
  node-watch.py judge <기록.json> <새 init ns> <새 자격 제공 ns>
      watch 기록과 제어 쪽 장부의 시각(after-restart의 "노드 판정 입력" 줄)을 견준다.

시각의 뜻(모두 같은 커널의 CLOCK_REALTIME ns):
  last_alive  대상 하나라도 살아 있음을 본 검사의 시작 시각. 그때 이후에 죽었다(하한).
  gone        모든 대상이 없음을 본 첫 검사의 끝 시각. 그 전에 죽었다(상한).
  됨          gone < 새 init, gone < 새 자격 제공 (소멸이 먼저라는 독립 증거)
  안 됨       last_alive >= 새 init(또는 자격 제공) (겹침의 증거). 노드가 본 새 프로세스의 커널 시작 시각이
              옛 대상이 살아 있던 시각보다 앞이어도 안 됨.
  판단 필요   그 사이(소멸을 본 검사와 살아 있음을 본 검사 사이)에 새 시각이 끼거나, watch가 재시작 뒤에 시작됐거나, 기록이 없다.
첩자가 멈춰 있거나(SIGSTOP) 기록 전에 죽는 것과 무관하다. 프로세스와 컨테이너 cgroup의 존재만 본다.
파드 안 프로세스의 명령줄은 믿지 않는 입력이다. 출력은 부르는 쪽(node-cgroup.sh)이 sanitize.py에 통과시킨다.
"""
import json
import os
import sys
import time

CG = "/sys/fs/cgroup"
PROC = "/proc"
ROLES = ("setsid", "nohup", "daemon", "stubborn", "spy")
TICK_NS = 10**9 // os.sysconf("SC_CLK_TCK")
POLL_S = 0.005


def verdict(k, v, why):
    print(f"결과 {k} {v} — {why}", flush=True)


def fact(s):
    print(f"사실 {s}", flush=True)


def argv(pid):
    try:
        with open(f"{PROC}/{pid}/cmdline", "rb") as f:
            a = f.read().split(b"\0")
    except OSError:
        return None
    if a and a[-1] == b"":
        a = a[:-1]
    return [x.decode("utf-8", "replace") for x in a]


def stat(pid):
    """(상태, 시작 tick) 또는 None. 좀비는 끝난 것으로 본다."""
    try:
        with open(f"{PROC}/{pid}/stat") as f:
            s = f.read()
    except OSError:
        return None
    f = s[s.rindex(")") + 2:].split()
    if f[0] in ("Z", "X"):
        return None
    return f[0], int(f[19])


def cgroup_of(pid):
    try:
        with open(f"{PROC}/{pid}/cgroup") as f:
            for line in f:
                if line.startswith("0::"):
                    return line[3:].strip()
    except OSError:
        pass
    return None


def classify(a):
    if not a:
        return "none"
    a0 = a[0]
    if a0.startswith("/opt/hc/"):
        return "core" if "serve" in a[1:] else ("holder" if "hold" in a[1:] else "client")
    key = " ".join([a0.rsplit("/", 1)[-1]] + a[1:3])
    table = {
        "python3 /opt/o25/o25.py relay-serve": "relay",
        "python3 /opt/o25/o25.py cred-serve": "credsrv",
        "python3 /opt/o25/o25.py body-init": "bodyinit",
        "python3 /opt/o25/o25.py spy": "spy",
        "bash /opt/o25/plant.sh sleeper": "plant",
        "bash /opt/o25/plant.sh stubborn": "plant",
        "bash /opt/o25/control.sh": "control",
        "bash /opt/o25/gen.sh": "gen",
    }
    if key in table:
        return table[key]
    if key.startswith("bash /opt/o25/control.sh"):
        return "control"
    return "other" if any("/opt/o25/" in x or "/opt/hc/" in x for x in a) else "none"


def find_pod_dir(pod):
    names = (f"pod{pod.replace('-', '_')}", f"pod{pod}", f"pod_{pod}", f"pod-{pod}")
    for dirpath, dirnames, _ in os.walk(CG):
        depth = dirpath[len(CG):].count("/")
        if depth >= 7:
            dirnames[:] = []
            continue
        for d in dirnames:
            if any(n in d for n in names):
                return os.path.join(dirpath, d)
    return None


def pod_pids(pod_dir):
    out = []
    for dirpath, _, files in os.walk(pod_dir):
        if "cgroup.procs" in files:
            try:
                with open(os.path.join(dirpath, "cgroup.procs")) as f:
                    out += [int(x) for x in f.read().split()]
            except OSError:
                pass
    return out


def populated(cg_dir):
    try:
        with open(os.path.join(cg_dir, "cgroup.events")) as f:
            for line in f:
                if line.startswith("populated "):
                    return line.split()[1] == "1"
    except FileNotFoundError:
        return False
    except OSError:
        return None
    return None


def moving(pid):
    """첩자가 실제로 돈다: 1초 사이 CPU 시간이나 자발적 문맥 전환이 늘고 멈춤(T) 상태가 아니다."""
    def sample():
        try:
            with open(f"{PROC}/{pid}/stat") as f:
                s = f.read()
            fs = s[s.rindex(")") + 2:].split()
            with open(f"{PROC}/{pid}/status") as f:
                v = [line.split()[1] for line in f if line.startswith("voluntary_ctxt_switches")]
            return fs[0], int(fs[11]) + int(fs[12]), int(v[0]) if v else 0
        except (OSError, ValueError, IndexError):
            return None
    a = sample()
    time.sleep(1)
    b = sample()
    return bool(a and b and b[0] not in ("T", "t") and (b[1] > a[1] or b[2] > a[2]))


def cmd_watch(pod, gen, out_path, limit_s):
    pod_dir = find_pod_dir(pod)
    rec = {"pod": pod, "gen": gen, "armed": False, "pod_dir": pod_dir}
    if not pod_dir:
        verdict("3.node.준비-대상-고정", "판단 필요", f"파드 cgroup 폴더를 찾지 못했다({pod})")
        json.dump(rec, open(out_path, "w"))
        return 0
    targets, bodyinit = {}, []
    for pid in pod_pids(pod_dir):
        a = argv(pid)
        role = classify(a)
        st = stat(pid)
        if not st:
            continue
        if role in ("plant", "spy") and len(a) >= 4:
            for r in ROLES:
                if a[3] == f"p-{gen}-{r}":
                    targets.setdefault(r, []).append((pid, st[1], cgroup_of(pid)))
        elif role == "bodyinit":
            bodyinit.append((pid, st[1], cgroup_of(pid)))
    missing = [r for r in ROLES if len(targets.get(r, [])) != 1]
    cgs = {t[0][2] for t in targets.values() if t}
    body_pid1 = [b for b in bodyinit if b[2] in cgs]
    if missing or len(cgs) != 1 or len(body_pid1) != 1:
        verdict("3.node.준비-대상-고정", "판단 필요",
                f"세대 {gen}의 다섯 역할을 하나씩 찾지 못했다(없음·겹침: {' '.join(missing) or '없음'}, 컨테이너 cgroup {len(cgs)}개, "
                f"그 cgroup의 본체 PID 1 {len(body_pid1)}개). 세대 인자가 맞는지, plant 영수증이 있는지 본다")
        json.dump(rec, open(out_path, "w"))
        return 0
    spy_pid = targets["spy"][0][0]
    if not moving(spy_pid):
        verdict("3.node.준비-대상-고정", "판단 필요", f"첩자(pid {spy_pid})가 움직이지 않는다(멈춤 상태이거나 끝남)")
        json.dump(rec, open(out_path, "w"))
        return 0
    body_cg = cgs.pop()
    fixed = [(r, p, s) for r in ROLES for (p, s, _) in targets[r]] + [("bodyinit", body_pid1[0][0], body_pid1[0][1])]
    rec.update(armed=True, armed_ns=time.time_ns(), body_cgroup=body_cg,
               targets=[{"role": r, "pid": p, "start": s} for r, p, s in fixed])
    known = set(pod_pids(pod_dir))
    # 고정 시점에 있던 컨테이너 cgroup의 새 프로세스(옛 sleeper의 sleep 등)는 새 세대가 아니다. 새 컨테이너는 새 cgroup을 받는다.
    old_cgs = {cgroup_of(p) for p in known} - {None}
    verdict("3.node.준비-대상-고정", "됨",
            f"세대 {gen}: {' '.join(f'{r}={p}@{s}' for r, p, s in fixed)}, 본체 컨테이너 cgroup {body_cg}")
    print("armed", flush=True)
    cg_dir = CG + body_cg
    last_alive = gone = None
    polls, max_gap, prev_t = 0, 0, None
    new = {}
    deadline = time.monotonic() + limit_s
    gone_seen_mono = None
    while time.monotonic() < deadline:
        t0 = time.time_ns()
        alive = [r for r, p, s in fixed if (stat(p) or (None, None))[1] == s]
        pop = populated(cg_dir)
        for pid in pod_pids(pod_dir):
            if pid in known:
                continue
            if pid in new:
                # 처음 본 때는 런타임이 exec하기 전일 수 있다. 시작 tick은 exec로 바뀌지 않으므로 역할만 다시 붙인다.
                if new[pid]["role"] in ("none", "other"):
                    new[pid]["role"] = classify(argv(pid))
                continue
            st = stat(pid)
            cg = cgroup_of(pid)
            if not st or cg is None:
                continue
            if cg in old_cgs:
                known.add(pid)
                continue
            new[pid] = {"role": classify(argv(pid)), "start": st[1], "seen_ns": t0, "cgroup": cg}
        t1 = time.time_ns()
        polls += 1
        if prev_t is not None:
            max_gap = max(max_gap, t0 - prev_t)
        prev_t = t1
        if alive or pop is not False:
            last_alive = t0
            if gone is not None:
                # 사라졌다가 다시 보이면(같은 pid·시작 시각은 다시 생길 수 없다) cgroup 읽기가 흔들린 것이다. 소멸 시각을 버린다.
                gone = None
                gone_seen_mono = None
            rec["alive_roles"] = alive + (["cgroup"] if pop is not False else [])
        elif gone is None:
            gone = t1
            gone_seen_mono = time.monotonic()
        if gone is not None and time.monotonic() - gone_seen_mono > 3 and any(v["role"] == "bodyinit" for v in new.values()):
            break
        time.sleep(POLL_S)
    # 커널 시작 tick → 실시간 ns. 부팅 뒤 경과(CLOCK_BOOTTIME)와 실시간의 차이로 바꾼다(tick 단위 10ms 오차).
    off = time.time_ns() - time.clock_gettime_ns(time.CLOCK_BOOTTIME)
    for v in new.values():
        v["start_ns_lo"] = off + v["start"] * TICK_NS
        v["start_ns_hi"] = off + (v["start"] + 1) * TICK_NS
        # 끝날 때 cgroup이 남은 컨테이너만 새 세대로 본다. 재시작 도중 사라진 컨테이너(실행기만 혼자 다시 떠 곧 86으로 끝난
        # control, 끝난 init)는 겹침의 독립 증거로 쓰지 않는다. init과의 순서는 장부 시각과의 비교가 본다.
        v["cgroup_at_end"] = os.path.isdir(CG + v["cgroup"])
    rec.update(last_alive_ns=last_alive, gone_ns=gone, polls=polls, max_gap_ns=max_gap,
               new=[dict(pid=k, **v) for k, v in sorted(new.items())], ended_ns=time.time_ns())
    json.dump(rec, open(out_path, "w"))
    fact(f"검사 {polls}회, 검사 사이 최대 {max_gap // 1000000}ms, 마지막 살아 있음 {last_alive}, 모두 없음 {gone}")
    if gone is None:
        verdict("3.node.옛-본체-소멸-관측", "안 됨", f"{limit_s}초 동안 옛 대상이 남았다: {' '.join(rec.get('alive_roles', []))}")
    else:
        verdict("3.node.옛-본체-소멸-관측", "됨", "고정한 다섯 대상·본체 PID 1이 모두 없고 본체 컨테이너 cgroup이 비었거나 없어졌다")
    return 0


def cmd_judge(path, init_ns, cred_ns):
    keys = ("3.node.옛-본체-소멸이-새-init-앞", "4.node.옛-본체-소멸이-새-자격-앞")
    try:
        rec = json.load(open(path))
    except (OSError, ValueError):
        for k in keys:
            verdict(k, "판단 필요", f"watch 기록이 없다({os.path.basename(path)}). 재시작 전에 watch를 띄웠는가, 세대 인자가 맞는가")
        return 0
    if not rec.get("armed"):
        for k in keys:
            verdict(k, "판단 필요", "watch가 대상을 고정하지 못했다(준비 영수증 없음)")
        return 0
    la, gone, armed = rec.get("last_alive_ns"), rec.get("gone_ns"), rec["armed_ns"]
    early = [n for n in rec.get("new", []) if la is not None and n.get("cgroup_at_end") and n["start_ns_hi"] <= la]
    fact(f"watch 고정 {armed}, 마지막 살아 있음 {la}, 모두 없음 {gone}, 새 init {init_ns}, 새 자격 제공 {cred_ns}")
    if rec.get("new"):
        first = min(rec["new"], key=lambda n: n["start"])
        fact(f"노드가 본 새 프로세스 {len(rec['new'])}개, 가장 이른 것 {first['role']} pid {first['pid']} 시작 ≥{first['start_ns_lo']}")
    for k, t in zip(keys, (init_ns, cred_ns)):
        if t is None:
            verdict(k, "판단 필요", "견줄 새 시각이 없다(제어 쪽 장부에 기록이 없다)")
        elif t <= armed:
            verdict(k, "판단 필요", "watch가 그 시각 뒤에 대상을 고정했다(재시작 전에 띄워야 한다)")
        elif early or (la is not None and la >= t):
            why = []
            if la is not None and la >= t:
                why.append(f"옛 대상이 새 시각보다 {(la - t) // 1000000}ms 뒤에도 살아 있었다")
            if early:
                e = early[0]
                why.append(f"노드가 본 새 컨테이너 프로세스({e['role']} pid {e['pid']})의 커널 시작 시각이 옛 대상의 마지막 생존 관측보다 앞이다")
            verdict(k, "안 됨", ". ".join(why))
        elif gone is not None and gone < t:
            verdict(k, "됨", f"옛 본체 소멸 확인(≤{gone})이 새 시각보다 {(t - gone) // 1000000}ms 앞이다")
        else:
            verdict(k, "판단 필요", "옛 본체가 사라진 구간에 새 시각이 낀다(살아 있음과 소멸 확인 사이)")
    return 0


def main(a):
    if len(a) >= 4 and a[0] == "watch":
        return cmd_watch(a[1], a[2], a[3], int(a[4]) if len(a) > 4 else 180)
    if len(a) == 4 and a[0] == "judge":
        num = lambda s: int(s) if s.isdigit() else None  # noqa: E731
        return cmd_judge(a[1], num(a[2]), num(a[3]))
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
