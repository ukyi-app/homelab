#!/usr/bin/env python3
"""올리브 계획 O25: 노드에서 옛 본체의 소멸을 재시작 전부터 지켜보고, 그 시각을 새 세대의 시작과 견준다.

  node-watch.py watch <파드 ID> <세대> <기록.json> [최대 초]
      재시작 요청 전에 띄운다. 그 세대에 심은 다섯 역할(p-<세대>-setsid·nohup·daemon·stubborn·spy)과 본체 PID 1을
      파드 cgroup 안에서 찾아 pid·시작 시각·컨테이너 cgroup으로 고정한다(준비 영수증). 다 찾지 못하거나 첩자가 움직이지
      않으면 고정 실패로 끝난다. 고정하면 "armed" 줄을 찍고, 대상이 모두 사라질 때까지 짧은 간격으로 본다.
      그동안 새로 생긴 컨테이너 cgroup의 프로세스는 끝나거나 cgroup이 지워져도 기록에 남긴다(끝난 init도 증거다).
  node-watch.py judge <기록.json> <파드 ID> <세대> <새 init ns> <새 자격 제공 ns>
      watch 기록과 제어 쪽 장부의 시각(after-restart의 "노드 판정 입력" 줄)을 견준다.

시각의 뜻:
  last_alive  대상 하나라도 살아 있음을 본 검사의 시작 시각. 그때 이후에 죽었다(하한).
  gone        모든 대상이 없음을 본 첫 검사의 끝 시각. 그 전에 죽었다(상한).
  둘 다 부팅 기준 시계(CLOCK_BOOTTIME, _b)로 견준다. 새 프로세스의 커널 시작 시각(/proc/<pid>/stat의 starttime)은 부팅
  기준 tick이라 _b와 바로 견준다(시계 변환 없음). 제어 쪽 장부는 실시간이라, 관측 내내 잰 "실시간 - 부팅" 차이 구간
  [off_lo, off_hi]를 거쳐 부팅 시계로 옮겨 견준다. 구간이 조금이라도 어긋나면(관측 중 실시간 시계가 움직임) 장부와 견주지 않는다.
  새 세대의 시작 = 첫 init(fetch-hc) 컨테이너의 커널 시작 시각. 장부의 init 시각(gen.sh가 세대를 만든 뒤)보다 앞이다.

  init 줄    안 됨: 옛 대상 생존 중 시작한 fetch·gen·body 컨테이너가 있다, 또는 장부 init 때 옛 대상이 살아 있었다
             됨: 새 컨테이너가 모두 소멸 확인 뒤에 시작했고(첫 init 포함) 소멸 확인 + off_hi < 장부 init
             판단 필요: 그 밖 모두. 생존 중 시작한 control·정체 모를(unknown·mixed) 컨테이너, 소멸 구간에 걸친 시작 포함
  자격 줄    안 됨: 장부 자격 제공 때 옛 대상이 살아 있었다 / 됨: 소멸 확인 + off_hi < 장부 자격 제공 / 판단 필요: 그 밖
  두 줄 공통 판단 필요: 첫 init을 보지 못함, 관측 중 실시간 시계 변화, 입력이 기록과 맞지 않음(다른 파드·세대·회차),
             watch가 재시작 뒤에 시작됨, 기록 없음
ctl-crash 회차의 실행기 단독 재시작(옛 본체 생존 중 control)도 새 세대 control과 노드에서 가를 독립 증거가 없어 init 줄은 판단 필요다.
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
# 역할 → 컨테이너. 한 컨테이너 cgroup에서 본 역할이 한 컨테이너로 모이지 않으면 정체를 모르는 것으로 둔다.
KIND = {
    "fetch": "fetch", "gen": "gen",
    "control": "control", "core": "control", "holder": "control", "client": "control", "relay": "control", "credsrv": "control",
    "bodyinit": "body", "plant": "body", "spy": "body",
}


def verdict(k, v, why):
    print(f"결과 {k} {v} — {why}", flush=True)


def fact(s):
    print(f"사실 {s}", flush=True)


def boot_ns():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


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
    # 첫 init(차트의 fetch-hc): sh -euc <스크립트> o25-fetch-hc. 마지막 낱말은 셸의 $0이라 스크립트 동작에 영향이 없다.
    if len(a) == 4 and a0.rsplit("/", 1)[-1] in ("sh", "bash", "dash") and a[1] == "-euc" and a[3] == "o25-fetch-hc":
        return "fetch"
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


class Offset:
    """실시간 - 부팅 시계 차이의 구간. 앞뒤로 읽어 두 읽기 사이의 지연이 구간을 넓히기만 하게 한다.

    부팅 시계를 먼저 읽고 실시간을 읽으면 그 차이는 참값 이상, 실시간을 먼저 읽고 부팅 시계를 읽으면 참값 이하다.
    차이가 고정이면 모든 구간이 참값을 품어 lo <= hi다. NTP의 느린 보정은 두 시계의 빠르기를 함께 바꿔 차이를 움직이지 않는다.
    lo > hi면 크기와 상관없이 관측 중 실시간 시계가 건너뛴 것(settimeofday, NTP step)이다. 허용 폭을 두면 그 폭 안의 이동이
    장부 비교의 오차로 들어가지 않으므로 두지 않는다.
    """

    def __init__(self):
        self.lo, self.hi = None, None

    def add(self, r_after_b, b_before_r, r_before_b, b_after_r):
        hi, lo = r_after_b - b_before_r, r_before_b - b_after_r
        self.hi = hi if self.hi is None else min(self.hi, hi)
        self.lo = lo if self.lo is None else max(self.lo, lo)

    def sample(self):
        b0 = boot_ns()
        r0 = time.time_ns()
        r1 = time.time_ns()
        b1 = boot_ns()
        self.add(r0, b0, r1, b1)


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
    off = Offset()
    off.sample()
    rec.update(armed=True, armed_ns=time.time_ns(), armed_b=boot_ns(), body_cgroup=body_cg,
               targets=[{"role": r, "pid": p, "start": s} for r, p, s in fixed])
    # pid만으로 가리면 옛 프로세스가 끝난 뒤 같은 pid를 받은 새 프로세스를 놓친다. (pid, 시작 tick)으로 가린다.
    known = set()
    old_cgs = set()
    for p in pod_pids(pod_dir):
        st, cg = stat(p), cgroup_of(p)
        if st:
            known.add((p, st[1]))
        if cg is not None:
            old_cgs.add(cg)
    verdict("3.node.준비-대상-고정", "됨",
            f"세대 {gen}: {' '.join(f'{r}={p}@{s}' for r, p, s in fixed)}, 본체 컨테이너 cgroup {body_cg}")
    print("armed", flush=True)
    cg_dir = CG + body_cg
    la_r = la_b = gone_r = gone_b = None
    polls, max_gap, prev_b = 0, 0, None
    new = {}
    deadline = time.monotonic() + limit_s
    gone_seen_mono = None
    while time.monotonic() < deadline:
        # 하한은 검사 전에, 상한은 검사 뒤에 읽는다. 두 시계를 따로 읽어 어느 쪽도 다른 시계로 바꾸지 않는다.
        b0 = boot_ns()
        r0 = time.time_ns()
        alive = [r for r, p, s in fixed if (stat(p) or (None, None))[1] == s]
        pop = populated(cg_dir)
        for pid in pod_pids(pod_dir):
            st = stat(pid)
            if not st or (pid, st[1]) in known:
                continue
            key = (pid, st[1])
            if key in new:
                # 처음 본 때는 런타임이 exec하기 전일 수 있다. 시작 tick은 exec로 바뀌지 않으므로 역할만 다시 붙인다.
                v = new[key]
                if v["role"] in ("none", "other"):
                    v["role"] = classify(argv(pid))
                # 런타임이 프로세스를 만든 자리(예: Podman의 conmon cgroup)에서 컨테이너 cgroup으로 옮긴다. 마지막 자리를 쓴다.
                cg = cgroup_of(pid)
                if cg is not None and cg not in old_cgs:
                    v["cgroup"] = cg
                v["last_b"] = b0
                continue
            cg = cgroup_of(pid)
            if cg is None:
                continue
            if cg in old_cgs:
                known.add(key)
                continue
            new[key] = {"role": classify(argv(pid)), "start": st[1], "seen_b": b0, "last_b": b0, "cgroup": cg}
        r1 = time.time_ns()
        b1 = boot_ns()
        off.add(r0, b0, r1, b1)
        polls += 1
        if prev_b is not None:
            max_gap = max(max_gap, b0 - prev_b)
        prev_b = b1
        if alive or pop is not False:
            la_r, la_b = r0, b0
            if gone_b is not None:
                # 사라졌다가 다시 보이면(같은 pid·시작 시각은 다시 생길 수 없다) cgroup 읽기가 흔들린 것이다. 소멸 시각을 버린다.
                gone_r = gone_b = None
                gone_seen_mono = None
            rec["alive_roles"] = alive + (["cgroup"] if pop is not False else [])
        elif gone_b is None:
            gone_r, gone_b = r1, b1
            gone_seen_mono = time.monotonic()
        if gone_b is not None and time.monotonic() - gone_seen_mono > 3 and any(v["role"] == "bodyinit" for v in new.values()):
            break
        time.sleep(POLL_S)
    off.sample()
    rec.update(last_alive_ns=la_r, last_alive_b=la_b, gone_ns=gone_r, gone_b=gone_b, polls=polls, max_gap_ns=max_gap,
               off_lo=off.lo, off_hi=off.hi, tick_ns=TICK_NS,
               new=[dict(pid=k[0], **v) for k, v in sorted(new.items())], ended_ns=time.time_ns(), ended_b=boot_ns())
    json.dump(rec, open(out_path, "w"))
    fact(f"검사 {polls}회, 검사 사이 최대 {max_gap // 1000000}ms, 마지막 살아 있음 {la_r}, 모두 없음 {gone_r}, "
         f"실시간-부팅 시계 차이 구간 {off.hi - off.lo}ns")
    if gone_b is None:
        verdict("3.node.옛-본체-소멸-관측", "안 됨", f"{limit_s}초 동안 옛 대상이 남았다: {' '.join(rec.get('alive_roles', []))}")
    else:
        verdict("3.node.옛-본체-소멸-관측", "됨", "고정한 다섯 대상·본체 PID 1이 모두 없고 본체 컨테이너 cgroup이 비었거나 없어졌다")
    return 0


def containers(rec):
    """새 컨테이너 cgroup마다 (종류, 가장 이른 시작 tick, 마지막으로 본 부팅 시각, 프로세스 수)."""
    out = {}
    paths = {n["cgroup"] for n in rec.get("new", [])}

    # 새 cgroup 아래의 하위 cgroup은 같은 컨테이너다(런타임에 따라 컨테이너 scope 아래에 container 같은 하위 폴더를 둔다).
    # 나눠 세면 런타임 쪽 프로세스만 있는 상위 폴더가 정체 모를 새 컨테이너로 보인다.
    def top(p):
        best = p
        for q in paths:
            if len(q) < len(best) and p.startswith(q.rstrip("/") + "/"):
                best = q
        return best

    for n in rec.get("new", []):
        key = top(n["cgroup"])
        # Podman 리허설의 컨테이너 감시 프로세스(conmon) 자리. 컨테이너가 아니고 그 컨테이너보다 먼저 뜬다. k3s에는 이 이름이 없다.
        if key.rsplit("/", 1)[-1].startswith("libpod-conmon-"):
            continue
        c = out.setdefault(key, {"kinds": set(), "start": n["start"], "last_b": n["last_b"], "n": 0, "cgroup": key})
        k = KIND.get(n["role"])
        if k:
            c["kinds"].add(k)
        c["start"] = min(c["start"], n["start"])
        c["last_b"] = max(c["last_b"], n["last_b"])
        c["n"] += 1
    for c in out.values():
        c["kind"] = next(iter(c["kinds"])) if len(c["kinds"]) == 1 else ("mixed" if c["kinds"] else "unknown")
    return sorted(out.values(), key=lambda c: c["start"])


def valid_rec(rec):
    ints = ("armed_ns", "armed_b", "ended_ns", "ended_b", "off_lo", "off_hi", "tick_ns")
    if not all(isinstance(rec.get(k), int) for k in ints):
        return False
    for k in ("last_alive_ns", "last_alive_b", "gone_ns", "gone_b"):
        if rec.get(k) is not None and not isinstance(rec[k], int):
            return False
    for n in rec.get("new", []):
        if not (isinstance(n, dict) and isinstance(n.get("start"), int) and isinstance(n.get("last_b"), int)
                and isinstance(n.get("cgroup"), str) and isinstance(n.get("role"), str)):
            return False
    return isinstance(rec.get("new", []), list)


def cmd_judge(path, pod, gen, init_ns, cred_ns):
    keys = ("3.node.옛-본체-소멸이-새-init-앞", "4.node.옛-본체-소멸이-새-자격-앞")

    def all_undecided(why):
        for k in keys:
            verdict(k, "판단 필요", why)
        return 0

    try:
        rec = json.load(open(path))
    except (OSError, ValueError):
        return all_undecided(f"watch 기록이 없다({os.path.basename(path)}). 재시작 전에 watch를 띄웠는가, 세대 인자가 맞는가")
    if not isinstance(rec, dict) or rec.get("pod") != pod or rec.get("gen") != gen:
        return all_undecided("watch 기록의 파드·세대가 인자와 다르다(다른 회차의 기록이다)")
    if not rec.get("armed"):
        return all_undecided("watch가 대상을 고정하지 못했다(준비 영수증 없음)")
    if not valid_rec(rec):
        return all_undecided("watch 기록의 필드가 모자라거나 형식이 다르다(관측기가 중간에 끝났거나 다른 판의 기록이다)")
    T = rec["tick_ns"]
    la_r, la_b, gone_r, gone_b = rec["last_alive_ns"], rec["last_alive_b"], rec["gone_ns"], rec["gone_b"]
    armed, ended = rec["armed_ns"], rec["ended_ns"]
    off_lo, off_hi = rec["off_lo"], rec["off_hi"]
    jump = off_lo - off_hi
    conts = containers(rec)
    fetches = [c for c in conts if c["kind"] == "fetch"]
    first = fetches[0] if fetches else None

    # 커널 시작은 tick 구간 [s*T, (s+1)*T) 어딘가다. 그 구간 전체가 마지막 생존 관측 앞이면 생존 중 시작, 소멸 확인 뒤면 소멸 뒤 시작.
    def when(c):
        if la_b is not None and (c["start"] + 1) * T <= la_b:
            return "alive"
        if gone_b is not None and gone_b < c["start"] * T:
            return "after"
        return "edge"

    # 생존 중 시작한 init·본체는 새 세대뿐이라 겹침의 증거다. control은 ctl-crash의 실행기 단독 재시작(옛 세대)일 수 있고,
    # 정체 모를 것은 역할을 못 붙인 첫 init 시도일 수 있다. 노드에서 둘을 가를 독립 증거가 없어 예외로 빼지 않고 판단 필요로 둔다.
    # 나중에 뜬 fetch를 첫 init으로 삼아 그 앞의 것을 통과시키면 실패한 첫 시도의 겹침을 놓친다.
    overlap = [c for c in conts if c["kind"] in ("fetch", "gen", "body") and when(c) == "alive"]
    unsure = [c for c in conts if c not in overlap and when(c) != "after"]
    fact(f"watch 고정 {armed}, 마지막 살아 있음 {la_r}, 모두 없음 {gone_r}, 장부 init {init_ns}, 장부 자격 제공 {cred_ns}")
    tags = {"alive": " (옛 대상 생존 중 시작)", "edge": " (시작이 마지막 생존 관측~소멸 확인 구간에 걸침)", "after": ""}
    for c in conts:
        tag = tags[when(c)] + (" (첫 init)" if c is first else "")
        fact(f"새 컨테이너 {c['kind']}{tag}: 시작 ≥{c['start'] * T + off_lo} (부팅 tick {c['start']}), 프로세스 {c['n']}개")
    if jump > 0:
        fact(f"관측 중 실시간 시계가 움직였다(실시간-부팅 시계 차이 구간이 {jump}ns 어긋남)")
    # 장부 시각이 이 회차의 것인가: 첫 init이 시작한 뒤, 관측이 끝나기 전.
    inconsistent = None
    if init_ns is not None and first is not None and init_ns < first["start"] * T + off_lo:
        inconsistent = "장부 init 시각이 노드가 본 첫 init 시작보다 앞이다(다른 회차의 시각이거나 잘못 옮겼다)"
    elif init_ns is not None and init_ns > ended:
        inconsistent = "장부 init 시각이 관측이 끝난 뒤다(다른 회차의 시각이거나 잘못 옮겼다)"
    elif init_ns is not None and cred_ns is not None and cred_ns <= init_ns:
        inconsistent = "장부 자격 제공 시각이 init 시각보다 앞이다"
    for k, t in zip(keys, (init_ns, cred_ns)):
        # 장부 시각 t의 부팅 시각은 [t - off_hi, t - off_lo] 안이다(차이가 고정일 때). 됨은 그 앞끝, 안 됨은 그 뒤끝과 견준다.
        if t is None:
            verdict(k, "판단 필요", "견줄 새 시각이 없다(제어 쪽 장부에 기록이 없다)")
        elif t <= armed:
            verdict(k, "판단 필요", "watch가 그 시각 뒤에 대상을 고정했다(재시작 전에 띄워야 한다)")
        elif k == keys[0] and overlap:
            c = overlap[0]
            verdict(k, "안 됨", f"새 {c['kind']} 컨테이너의 커널 시작이 옛 대상의 마지막 생존 관측보다 "
                    f"{(la_b - (c['start'] + 1) * T) // 1000000}ms 이상 앞이다(부팅 기준 시계)")
        elif jump > 0:
            verdict(k, "판단 필요", "관측 중 실시간 시계가 움직여 장부(실시간)와 견줄 수 없다")
        elif la_b is not None and la_b + off_lo >= t:
            verdict(k, "안 됨", f"옛 대상이 장부 시각보다 {(la_b + off_lo - t) // 1000000}ms 이상 뒤에도 살아 있었다")
        elif first is None:
            verdict(k, "판단 필요", "노드가 첫 init(fetch-hc)의 시작을 보지 못했다(새 세대의 시작을 확인하지 못함)")
        elif k == keys[0] and unsure:
            verdict(k, "판단 필요", "소멸 확인 뒤에 시작했다고 증명하지 못한 새 컨테이너가 있다: "
                    + " ".join(f"{c['kind']}({'생존 중 시작' if when(c) == 'alive' else '소멸 구간에 걸침'})" for c in unsure))
        elif inconsistent:
            verdict(k, "판단 필요", inconsistent)
        elif k == keys[0] and gone_b is not None and gone_b < first["start"] * T and gone_b + off_hi < t:
            lead = (first["start"] * T - gone_b) // 1000000
            verdict(k, "됨", f"옛 본체 소멸 확인이 첫 init 시작보다 {lead}ms 이상, 장부 init보다 {(t - gone_b - off_hi) // 1000000}ms 이상 앞이다")
        elif k == keys[1] and gone_b is not None and gone_b + off_hi < t:
            verdict(k, "됨", f"옛 본체 소멸 확인이 장부 자격 제공보다 {(t - gone_b - off_hi) // 1000000}ms 이상 앞이다")
        else:
            verdict(k, "판단 필요", "옛 본체가 사라진 구간(살아 있음과 소멸 확인 사이)에 첫 init 시작이나 장부 시각이 낀다")
    return 0


def main(a):
    if len(a) >= 4 and a[0] == "watch":
        return cmd_watch(a[1], a[2], a[3], int(a[4]) if len(a) > 4 else 180)
    if len(a) == 6 and a[0] == "judge":
        num = lambda s: int(s) if s.isdigit() else None  # noqa: E731
        return cmd_judge(a[1], a[2], a[3], num(a[4]), num(a[5]))
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
