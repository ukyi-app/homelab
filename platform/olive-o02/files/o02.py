#!/usr/bin/env python3
"""O02 시험의 고정 프로그램과 도우미. 표준 라이브러리만 쓴다.

터미널 안에서 도는 것: inputlog(받은 입력을 기록), emit(제어 문자 표본), hog·burn(상한 시험).
실행기가 부르는 것: view(보기 흉내), viewcheck·ctrlcount(판정), apirun(API로 env override), connect, sanitize,
trycreate(읽기 전용 root 확인), nodepath(노드 API 경로에 닿는지).
"""
import errno
import fcntl
import ipaddress
import json
import os
import select
import signal
import socket
import struct
import sys
import termios
import time
import tty
import unicodedata

HC = "/opt/hc/hc"

# 보기 흉내가 넣는 표식. 터미널 안 프로그램이 이 바이트를 받으면 보기 경로가 입력을 넘긴 것이다.
KEY = b"O02KEY"
PASTE = b"O02PASTE"
CPR_REPLY = b"\x1b[97;89R"  # 커서 위치 질의의 답. core가 스스로 낼 일이 없는 좌표를 쓴다.
OSC_REPLY = b"\x1b]11;rgb:1234/5678/9abc\x07"  # 배경색 질의의 답
FOCUS_IN = b"\x1b[I"
FOCUS_OUT = b"\x1b[O"
MARKS = {
    "키": KEY,
    "붙여넣기": PASTE,
    "커서 위치 답": b"[97;89R",
    "배경색 답": b"1234/5678",
    # hc 0.1.21은 붙은 단말의 배경색 답을 그대로 넘기지 않는다. 채널마다 상위 8비트를 두 번 쓴 값으로 다시 써서
    # 터미널 안 프로그램의 질의에 답하고, 분리한 뒤에도 그 값을 유지한다. 원래 표식만 보면 이 경로를 놓친다.
    "배경색 답(hc가 다시 씀)": b"1212/5656/9a9a",
    "포커스 들어옴": FOCUS_IN,
    "포커스 나감": FOCUS_OUT,
}


# 버리는 유니코드 범주: 제어(Cc: C0, DEL, C1), 서식(Cf: 방향 뒤집기, 폭 없는 문자, 태그), 대리·사용자 정의·미배정(Cs, Co, Cn),
# 줄·문단 구분자(Zl, Zp). tools/olive-o02/sanitize.py와 같은 목록이다(바꾸면 함께 바꾼다).
DROP_CATEGORIES = ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")


def unsafe_char(c: str) -> bool:
    return c not in "\n\t" and unicodedata.category(c) in DROP_CATEGORIES


def sanitize_text(data: bytes) -> str:
    """관리자 단말에 찍기 전의 정제 표본: 탭·줄바꿈을 뺀 제어 문자(C0, DEL, C1)와 서식 문자를 버린다.

    UTF-8이 아닌 바이트는 U+FFFD로 바뀐다. 날것의 0x80~0x9F 바이트를 C1로 읽는 단말이 있어서다.
    """
    text = data.decode("utf-8", errors="replace")
    return "".join(c for c in text if not unsafe_char(c))


def cmd_sanitize(_args):
    sys.stdout.write(sanitize_text(sys.stdin.buffer.read()))


def cmd_connect(args):
    """Unix 소켓에 연결만 해 본다. @로 시작하면 abstract 소켓이다. hc client와 달리 core를 띄우지 않는다."""
    path = args[0]
    addr = "\0" + path[1:] if path.startswith("@") else path
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(addr)
    except OSError as e:
        print("fail", e.__class__.__name__, e.errno)
        sys.exit(1)
    print("ok")


def cmd_trycreate(args):
    """파일 하나를 만들어 보고 결과를 한 낱말로 낸다: ok, 또는 errno 이름(EROFS, EACCES ...). 만들었으면 바로 지운다."""
    try:
        fd = os.open(args[0], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as e:
        print(errno.errorcode.get(e.errno, f"errno{e.errno}"))
        return
    os.close(fd)
    os.unlink(args[0])
    print("ok")


def tcp_reach(host, port, timeout=4.0):
    """TCP 연결만 해 보고 결과를 말로 돌려준다. 아무것도 보내지 않는다."""
    try:
        socket.create_connection((host, port), timeout=timeout).close()
    except ConnectionRefusedError:
        return "거절됨(RST가 왔다. 패킷은 닿았고 듣는 쪽이 없다)"
    except (socket.timeout, TimeoutError):
        return "안 닿음(시간 초과)"
    except OSError as e:
        return f"안 닿음({errno.errorcode.get(e.errno, e.errno)})"
    return "닿음(TCP 연결됨)"


def cmd_nodepath(args):
    """노드 IP의 kube API(6443)·kubelet(10250)과 kubernetes Service에 닿는지 잰다. 판정이 아니라 사실 줄로 낸다.

    주소 값은 찍지 않는다. 노드 IP는 파드 env의 O02_NODE_IP(status.hostIP)에서 받는다.
    """
    label = args[0]
    targets = []
    try:
        node = str(ipaddress.ip_address(os.environ.get("O02_NODE_IP", "")))
        targets += [("노드 IP:6443(kube API)", node, 6443), ("노드 IP:10250(kubelet)", node, 10250)]
    except ValueError:
        print(f"사실 노드경로.{label} 노드 IP를 모른다(환경에 O02_NODE_IP가 없다). 노드 IP 경로는 재지 못했다")
    try:
        svc = str(ipaddress.ip_address(os.environ.get("KUBERNETES_SERVICE_HOST", "")))
        targets.append(("kubernetes Service(노드 IP:6443으로 바뀌는 길)", svc, int(os.environ.get("KUBERNETES_SERVICE_PORT", "443"))))
    except ValueError:
        print(f"사실 노드경로.{label} kubernetes Service 주소를 모른다(환경에 없다). 그 경로는 재지 못했다")
    for name, host, port in targets:
        print(f"사실 노드경로.{label} {name} {tcp_reach(host, port)}")


def winsize(fd):
    try:
        rows, cols = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
        return [cols, rows]
    except OSError:
        return None


def cmd_inputlog(args):
    """받은 입력 바이트와 크기 변경을 줄마다 기록한다. 1초마다 단말 질의를 내고 그때 tick 한 줄을 남긴다.

    tick은 "이 구간에 기록기가 살아 있었다"는 증거다. 입력이 없는 구간에는 input·winch 줄이 없으므로,
    tick이 없으면 "입력이 없었다"와 "기록기가 죽었다"를 가를 수 없다.
    """
    log, phasefile = args

    def phase():
        try:
            with open(phasefile) as f:
                return f.read().strip()
        except OSError:
            return "?"

    out = open(log, "a", buffering=1)

    def w(kind, **kw):
        out.write(json.dumps({"t": round(time.monotonic(), 2), "phase": phase(), "kind": kind, **kw}) + "\n")

    signal.signal(signal.SIGWINCH, lambda *_: w("winch", size=winsize(1)))
    old = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        # 붙여넣기 묶음과 포커스 알림을 켠다. 실제 단말이라면 이 뒤로 포커스 알림을 입력으로 보낸다.
        os.write(1, b"\x1b[?2004h\x1b[?1004h")
        w("start", size=winsize(1))
        last = 0.0
        while True:
            now = time.monotonic()
            if now - last >= 1.0:
                last = now
                w("tick")
                # 장치 속성, 커서 위치, 배경색, 단말 버전 질의
                os.write(1, b"\x1b[c\x1b[6n\x1b]11;?\x07\x1b[>q")
            ready, _, _ = select.select([0], [], [], 0.25)
            if ready:
                data = os.read(0, 4096)
                if not data:
                    w("eof")
                    return
                w("input", hex=data.hex())
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)


def cmd_emit(_args):
    """제목, 링크, 클립보드 쓰기, 벨의 무해한 표본을 1초마다 화면에 낸다. 파드 안 pty에만 쓴다."""
    seqs = (
        b"\x1b]0;O02-TITLE-SAMPLE\x07"
        b"\x1b]8;;https://example.invalid/o02\x1b\\O02-LINK-SAMPLE\x1b]8;;\x1b\\"
        b"\x1b]52;c;TzAyLUNMSVAtU0FNUExF\x07"  # base64("O02-CLIP-SAMPLE")
        b"\x07"
        b"\x1b[31mO02-COLOR-SAMPLE\x1b[0m\r\n"
    )
    while True:
        os.write(1, seqs)
        time.sleep(1)


def cmd_view(args):
    """관리자의 보기 흉내: pty 안에서 hc attach를 띄우고, 단말이 보낼 법한 입력을 넣고, 나온 바이트를 파일에 받는다.

    mode observe: hc attach --observe. 넣은 입력이 프로그램에 가면 안 된다.
    mode control: hc attach(보기 전용 아님). 같은 입력이 프로그램에 가야 한다. 검사가 잡을 수 있는지 보는 대조군이다.
    """
    import pty

    mode, term, outfile, secs = args[0], args[1], args[2], float(args[3])
    argv = [HC, "attach"] + (["--observe"] if mode == "observe" else []) + [term]
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)

    def setsize(cols, rows):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    setsize(132, 50)
    plan = [
        (1.0, lambda: os.write(fd, KEY + b"\r")),
        (2.0, lambda: os.write(fd, b"\x1b[200~" + PASTE + b"\x1b[201~")),
        (3.0, lambda: os.write(fd, FOCUS_IN)),
        (3.4, lambda: os.write(fd, FOCUS_OUT)),
        (4.0, lambda: setsize(91, 33)),
        (5.0, lambda: setsize(77, 21)),
        (6.0, lambda: os.write(fd, CPR_REPLY + OSC_REPLY)),
        (secs, lambda: os.write(fd, b"\x1c")),  # ctrl+\ : attach의 분리 키
    ]
    start = time.monotonic()
    got = bytearray()
    alive = True
    with open(outfile, "wb") as out:
        while alive and time.monotonic() - start < secs + 2:
            now = time.monotonic() - start
            while plan and plan[0][0] <= now:
                try:
                    plan.pop(0)[1]()
                except OSError:
                    plan.clear()
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    alive = False
                    break
                out.write(data)
                got += data
                # 단말 흉내: 질의가 보이면 답한다. 보기 전용이면 이 답이 프로그램에 가면 안 된다.
                try:
                    if b"\x1b[6n" in data:
                        os.write(fd, CPR_REPLY)
                    if b"]11;?" in data:
                        os.write(fd, OSC_REPLY)
                except OSError:
                    pass
    status = "살아 있어 끝냄"
    done, code = os.waitpid(pid, os.WNOHANG)
    if done == 0:
        os.kill(pid, signal.SIGTERM)
        time.sleep(1)
        done, code = os.waitpid(pid, os.WNOHANG)
        if done == 0:
            os.kill(pid, signal.SIGKILL)
            _, code = os.waitpid(pid, 0)
    else:
        status = "스스로 끝남"
    print(f"view {mode} {term}: 받은 바이트 {len(got)}, attach 프로세스 {status}, 종료 상태 {code}")
    print("끝 200바이트(정제):", sanitize_text(bytes(got[-200:])).replace("\n", " ")[:200])
    # 화면을 한 바이트도 받지 못했으면 붙지 못한 것이다. 그 구간의 "무입력"은 증거가 아니다.
    if not got:
        sys.exit(3)


def read_phases(path):
    """inputlog 기록을 구간별로 모은다. ticks는 그 구간에 기록기가 살아 있었다는 표시의 수다."""
    phases = {}
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict) or "kind" not in e:
                continue
            p = phases.setdefault(e.get("phase", "?"), {"input": bytearray(), "winch": [], "ticks": 0})
            if e["kind"] == "input":
                p["input"] += bytes.fromhex(e.get("hex", ""))
            elif e["kind"] in ("winch", "start"):
                p["winch"].append((e["kind"], e.get("size")))
            elif e["kind"] == "tick":
                p["ticks"] += 1
    return phases


def judge_view(phases, read_ok, observe_ok, control_attached):
    """보기 판정. (키, 판정, 근거) 목록을 돌려준다.

    무입력 "됨"의 조건: 그 읽기 경로가 실제로 돌았고, 그 구간에 기록기가 살아 있었고(tick), 표식·크기 변경이 없고,
    대조군에서는 같은 입력이 닿았다(검사가 잡을 수 있다는 증거).
    """

    def hits_of(p):
        return [label for label, mark in MARKS.items() if mark in p["input"]]

    out = []
    control = phases.get("control")
    control_hits = hits_of(control) if control else []
    control_ok = bool(control_attached and control_hits)

    def clean_phase(key, phase, path_ok, path_why):
        p = phases.get(phase)
        if p is None or p["ticks"] == 0:
            out.append((key, "판단 필요", f"구간 {phase}에 기록기가 살아 있었다는 표시(tick)가 없다. 입력이 없었는지 기록기가 죽었는지 가를 수 없다"))
            return
        hits = hits_of(p)
        resized = any(kind == "winch" for kind, _ in p["winch"])
        detail = f"닿은 표식 {hits or '없음'}, 크기 변경 {'있음' if resized else '없음'}, tick {p['ticks']}번"
        if hits or resized:
            out.append((key, "안 됨", detail))
        elif not path_ok:
            out.append((key, "판단 필요", f"{path_why}. {detail}"))
        elif not control_ok:
            out.append((key, "판단 필요", f"대조군에서 입력이 닿는 것을 보지 못해 이 무입력을 믿을 수 없다. {detail}"))
        else:
            out.append((key, "됨", detail))

    clean_phase("7.read-무입력", "read", read_ok, "hc read가 실패했다")
    clean_phase("7.observe-무입력", "observe", observe_ok, "hc attach --observe가 화면을 받지 못했다(붙지 못했다)")
    if control_ok:
        out.append(("7.대조군-입력이-닿음", "됨", f"대조군에서 표식이 닿았다(검사가 잡을 수 있다): {control_hits}"))
    elif not control_attached:
        out.append(("7.대조군-입력이-닿음", "판단 필요", "대조군 attach가 화면을 받지 못했다(붙지 못했다)"))
    else:
        out.append(("7.대조군-입력이-닿음", "판단 필요", "대조군에서도 표식이 닿지 않았다. 위 무입력 결과를 믿을 수 없다"))
    return out


def nonempty(path):
    try:
        return os.path.getsize(path) > 0
    except OSError:
        return False


def cmd_viewcheck(args):
    """viewcheck <inputlog 기록> <hc read의 종료 코드> <observe가 받은 파일> <대조군이 받은 파일>"""
    log, read_rc, observe_file, control_file = args
    try:
        phases = read_phases(log)
    except OSError:
        phases = {}
        print("입력 기록 파일을 읽지 못했다")
    for name, p in phases.items():
        hits = [label for label, mark in MARKS.items() if mark in p["input"]]
        sizes = [s for kind, s in p["winch"] if kind == "winch"]
        print(f"구간 {name}: tick {p['ticks']}번, 받은 입력 {len(p['input'])}바이트, 표식 {hits or '없음'}, 크기 변경 {len(sizes)}번 {sizes[:4]}")
    for key, word, why in judge_view(phases, read_rc == "0", nonempty(observe_file), nonempty(control_file)):
        print(f"결과 {key} {word} — {why}")


def cmd_ctrlcount(args):
    """읽기 경로가 낸 바이트에 제어 문자가 얼마나 들었는지, 정제 표본을 거치면 0이 되는지 센다."""
    key, path = args
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        raw = b""
    # 표본 프로그램(emit)이 내는 보이는 글자가 없으면 이 읽기 경로가 화면을 가져오지 못한 것이다.
    # 그때 "제어 문자가 없다"는 출력이 비었거나 오류 문구라는 뜻이지 걸러졌다는 뜻이 아니다.
    if b"O02-COLOR-SAMPLE" not in raw:
        why = f"{path}에 표본 글자(O02-COLOR-SAMPLE)가 없다({len(raw)}바이트). 이 읽기 경로가 화면을 가져오지 못했다"
        print(f"결과 {key}.원시-제어문자-없음 판단 필요 — {why}")
        print(f"결과 {key}.정제-뒤-0개 판단 필요 — {why}")
        return
    counts = {
        "ESC": raw.count(b"\x1b"),
        "BEL": raw.count(b"\x07"),
        "제목(OSC 0)": raw.count(b"\x1b]0;"),
        "링크(OSC 8)": raw.count(b"\x1b]8;"),
        "클립보드 쓰기(OSC 52)": raw.count(b"\x1b]52;"),
        "JSON에 실린 ESC(\\u001b)": raw.lower().count(b"\\u001b"),
    }
    clean = sanitize_text(raw)
    left = sum(1 for c in clean if unsafe_char(c))
    print(f"{path}: {len(raw)}바이트, {counts}")
    passes_raw = counts["ESC"] + counts["BEL"] + counts["JSON에 실린 ESC(\\u001b)"] > 0
    print(f"결과 {key}.원시-제어문자-없음 {'안 됨' if passes_raw else '됨'} — 이 읽기 경로의 출력에 제어 문자가 {'들어 있다' if passes_raw else '없다'}")
    print(f"결과 {key}.정제-뒤-0개 {'됨' if left == 0 else '안 됨'} — 정제 표본 뒤 남은 제어 문자 {left}개")


def check_reply(line: bytes, want_id):
    """JSON-RPC 응답 한 줄을 본다. (상태, 이유)를 돌려준다. 상태는 ok | skip(다른 줄이라 넘긴다) | fail."""
    if not line:
        return "fail", "응답 없이 연결이 끝났다"
    try:
        obj = json.loads(line)
    except ValueError:
        return "fail", "응답이 JSON이 아니다"
    if not isinstance(obj, dict):
        return "fail", "응답이 JSON 객체가 아니다"
    if "id" not in obj:
        return "skip", "id가 없는 줄(알림)"
    if obj["id"] != want_id or isinstance(obj["id"], bool):
        return "fail", f"응답의 id가 다르다(기대 {want_id})"
    if obj.get("error") is not None:
        return "fail", "error 응답이다"
    if "result" not in obj:
        return "fail", "result가 없다"
    return "ok", "result를 받았다"


def cmd_apirun(args):
    """API(terminal.run)의 env override로 가짜 표식을 넘겨 프로그램을 띄운다.

    호출마다 응답의 id·error·result를 본다. 하나라도 어긋나면 0이 아닌 값으로 끝난다.
    실패한 호출을 성공으로 넘기면, 표식이 전달되지 않았는데 "상태에 남지 않았다"는 판정이 나온다.
    """
    sock, name, marker, tag = args
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    try:
        s.connect(sock)
    except OSError as e:
        print("소켓에 연결하지 못했다:", e.__class__.__name__, e.errno)
        sys.exit(3)
    f = s.makefile("rwb", buffering=0)
    calls = [
        ("hello", {}),
        (
            "terminal.run",
            {
                "argv": ["bash", "/opt/o02/prog.sh", "envdump", tag],
                "name": name,
                "no_parent": True,
                "env": {"O02_FAKE_OVERRIDE": marker},
            },
        ),
    ]
    for i, (method, params) in enumerate(calls):
        try:
            f.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
            # 응답 앞에 id 없는 알림 줄이 올 수 있어 몇 줄까지 넘긴다.
            for _ in range(20):
                reply = f.readline()
                state, why = check_reply(reply, i)
                if state != "skip":
                    break
            else:
                state, why = "fail", "id가 맞는 응답이 오지 않았다"
        except OSError as e:
            reply, state, why = b"", "fail", f"주고받다 실패했다({e.__class__.__name__})"
        print(method, "->", sanitize_text(reply)[:300].strip())
        if state != "ok":
            print(f"API 호출 실패: {method}: {why}")
            sys.exit(3)
    print("API 호출 성공: 모든 응답에 result가 있다")


def cmd_hog(args):
    """상한을 넘길 때까지 메모리를 잡는다. 상한이 걸리지 않으면 cap(MiB)에서 스스로 멈춘다."""
    cap = int(args[0])
    held = []
    while len(held) * 8 < cap:
        block = bytearray(8 << 20)
        for i in range(0, len(block), 4096):
            block[i] = 1
        held.append(block)
        print(len(held) * 8, "MiB", flush=True)
        time.sleep(0.2)
    with open("/s/out/hog-cap-reached", "w") as f:
        f.write(f"{cap}\n")
    print("CAP REACHED: 상한이 걸리지 않았다", flush=True)


def cmd_burn(args):
    end = time.monotonic() + float(args[0])
    while time.monotonic() < end:
        pass
    print("burn done", flush=True)


COMMANDS = {
    "sanitize": cmd_sanitize,
    "connect": cmd_connect,
    "trycreate": cmd_trycreate,
    "nodepath": cmd_nodepath,
    "inputlog": cmd_inputlog,
    "emit": cmd_emit,
    "view": cmd_view,
    "viewcheck": cmd_viewcheck,
    "ctrlcount": cmd_ctrlcount,
    "apirun": cmd_apirun,
    "hog": cmd_hog,
    "burn": cmd_burn,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("o02.py: 모르는 이름", file=sys.stderr)
        sys.exit(2)
    COMMANDS[sys.argv[1]](sys.argv[2:])
