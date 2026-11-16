#!/usr/bin/env python3
"""O02 시험의 고정 프로그램과 도우미. 표준 라이브러리만 쓴다.

터미널 안에서 도는 것: inputlog(받은 입력을 기록), emit(제어 문자 표본), hog·burn(상한 시험).
실행기가 부르는 것: view(보기 흉내), viewcheck·ctrlcount(판정), apirun(API로 env override), connect, sanitize.
"""
import fcntl
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
    "포커스 들어옴": FOCUS_IN,
    "포커스 나감": FOCUS_OUT,
}


def sanitize_text(data: bytes) -> str:
    """관리자 단말에 찍기 전의 정제 표본: 탭·줄바꿈을 뺀 제어 문자(C0, DEL, C1)와 서식 문자를 버린다."""
    text = data.decode("utf-8", errors="replace")
    return "".join(c for c in text if c in "\n\t" or unicodedata.category(c) not in ("Cc", "Cf"))


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


def winsize(fd):
    try:
        rows, cols = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
        return [cols, rows]
    except OSError:
        return None


def cmd_inputlog(args):
    """받은 입력 바이트와 크기 변경을 줄마다 기록한다. 1초마다 단말 질의를 낸다."""
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


def cmd_viewcheck(args):
    """inputlog 기록을 구간별로 읽어, 보기 흉내가 넣은 표식이 프로그램에 닿았는지 판정한다."""
    phases = {}
    with open(args[0]) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            p = phases.setdefault(e.get("phase", "?"), {"input": bytearray(), "winch": []})
            if e["kind"] == "input":
                p["input"] += bytes.fromhex(e["hex"])
            elif e["kind"] in ("winch", "start"):
                p["winch"].append((e["kind"], e.get("size")))
    for name, p in phases.items():
        hits = [label for label, mark in MARKS.items() if mark in p["input"]]
        sizes = [s for kind, s in p["winch"] if kind == "winch"]
        print(f"구간 {name}: 받은 입력 {len(p['input'])}바이트, 표식 {hits or '없음'}, 크기 변경 {len(sizes)}번 {sizes[:4]}")

    def judge(key, phase, want_clean):
        p = phases.get(phase)
        if p is None:
            print(f"결과 {key} 판단 필요 — 구간 {phase}의 기록이 없다")
            return
        hits = [label for label, mark in MARKS.items() if mark in p["input"]]
        resized = any(kind == "winch" for kind, _ in p["winch"])
        if want_clean:
            ok = not hits and not resized
            print(f"결과 {key} {'됨' if ok else '안 됨'} — 닿은 표식 {hits or '없음'}, 크기 변경 {'있음' if resized else '없음'}")
        else:
            ok = bool(hits)
            why = "대조군에서 표식이 닿았다(검사가 잡을 수 있다)" if ok else "대조군에서도 표식이 닿지 않았다. 위 무입력 결과를 믿을 수 없다"
            print(f"결과 {key} {'됨' if ok else '판단 필요'} — {why}: {hits or '없음'}")

    judge("7.read-무입력", "read", True)
    judge("7.observe-무입력", "observe", True)
    judge("7.대조군-입력이-닿음", "control", False)


def cmd_ctrlcount(args):
    """읽기 경로가 낸 바이트에 제어 문자가 얼마나 들었는지, 정제 표본을 거치면 0이 되는지 센다."""
    key, path = args
    with open(path, "rb") as f:
        raw = f.read()
    counts = {
        "ESC": raw.count(b"\x1b"),
        "BEL": raw.count(b"\x07"),
        "제목(OSC 0)": raw.count(b"\x1b]0;"),
        "링크(OSC 8)": raw.count(b"\x1b]8;"),
        "클립보드 쓰기(OSC 52)": raw.count(b"\x1b]52;"),
        "JSON에 실린 ESC(\\u001b)": raw.lower().count(b"\\u001b"),
    }
    clean = sanitize_text(raw)
    left = sum(1 for c in clean if c not in "\n\t" and unicodedata.category(c) == "Cc")
    print(f"{path}: {len(raw)}바이트, {counts}")
    passes_raw = counts["ESC"] + counts["BEL"] + counts["JSON에 실린 ESC(\\u001b)"] > 0
    print(f"결과 {key}.원시-제어문자-없음 {'안 됨' if passes_raw else '됨'} — 이 읽기 경로의 출력에 제어 문자가 {'들어 있다' if passes_raw else '없다'}")
    print(f"결과 {key}.정제-뒤-0개 {'됨' if left == 0 else '안 됨'} — 정제 표본 뒤 남은 제어 문자 {left}개")


def cmd_apirun(args):
    """API(terminal.run)의 env override로 가짜 표식을 넘겨 프로그램을 띄운다."""
    sock, name, marker, tag = args
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(sock)
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
        f.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
        reply = f.readline()
        print(method, "->", sanitize_text(reply)[:300].strip())


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
