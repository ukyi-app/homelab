#!/usr/bin/env python3
"""O25 시험의 고정 도우미. 쓰는 법: o25.py <이름> [인자...]. 이름은 아래 COMMANDS뿐이다.

제어 쪽(uid 10001)
  relay-serve <소켓> <기록>   hc 터미널 프로그램. 중계 소켓을 듣고 본체 uid의 연결 하나만 받아 바이트를 잇는다.
  cred-serve <소켓> <장부>    표준 입력의 가짜 자격을 본체 uid의 연결 하나에게만 주고 끝난다.
본체 쪽(uid 10002)
  body-init -- <명령...>      본체 컨테이너 PID 1. 자격을 받고, 중계에 붙고, pty에서 본체 자리 명령을 띄워 바이트를 잇는다.
  spy <꼬리표>                심어 두는 첩자. 살아 있다는 표시를 남기고, 다른 세대의 자격·중계에 붙어 보려 한다.
검사
  connect <경로>              Unix 소켓에 연결만 해 본다(@로 시작하면 abstract).
  peer <경로>                 연결해서 상대의 uid를 SO_PEERCRED로 읽는다.
  trycreate <경로>            파일 만들기를 시도해 ok 또는 errno 이름을 찍는다.
  sanitize                    표준 입력의 제어·서식 문자를 지운다.
  sha                         표준 입력의 sha256 앞 16자.

중계는 바이트와 닫기만 나른다. 명령·인자·환경·크기 변경을 받지 않는다. 화면 크기는 ROWS×COLS로 고정이다.
중계 소켓과 자격 소켓은 제어 쪽이 만든다. 중계 폴더는 본체에 읽기 전용으로 붙어, 본체는 거기에 소켓을 만들거나 바꿔치기하지 못하고
연결만 한다(Podman 실측에서 본체가 쓸 수 있는 폴더에 소켓을 두자 바꿔치기가 됐다).
"""
import errno
import hashlib
import os
import pty
import select
import signal
import socket
import struct
import sys
import time
import unicodedata

CONTROL_UID = 10001
BODY_UID = 10002
ROWS, COLS = 50, 200
DROP_CATEGORIES = ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")
MAX_CRED = 4096


def now_ns():
    return time.time_ns()


def sha16(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def sanitize_text(data: bytes) -> str:
    text = data.decode("utf-8", errors="replace")
    return "".join(c for c in text if c in "\n\t" or unicodedata.category(c) not in DROP_CATEGORIES)


def append(path, line):
    # 한 줄을 한 번의 write로 붙인다. 여러 프로세스가 같은 장부에 쓰므로 O_APPEND에 기댄다.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (line.rstrip("\n") + "\n").encode())
    finally:
        os.close(fd)


def peer_cred(sock):
    # (pid, uid, gid). 상대가 다른 PID 네임스페이스면 pid는 0으로 온다.
    data = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", data)


def unix_addr(path):
    return "\0" + path[1:] if path.startswith("@") else path


def listen_once(path, want_uid, log):
    """path에 소켓을 만들고 want_uid의 연결 하나를 받는다. 받으면 듣기를 닫고 경로를 지운다.

    다른 uid의 연결은 기록하고 끊은 뒤 계속 기다린다. 소켓 파일은 0666이다: 연결 권한은 파일이 아니라 SO_PEERCRED로 가린다
    (파드의 uid는 둘뿐이고, 본체에게는 폴더 자체가 읽기 전용이라 바꿔치기는 폴더 권한이 막는다).
    """
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o111)
    try:
        srv.bind(path)
    finally:
        os.umask(old)
    os.chmod(path, 0o666)
    srv.listen(4)
    log(f"listen {path}")
    while True:
        conn, _ = srv.accept()
        pid, uid, gid = peer_cred(conn)
        if uid != want_uid:
            log(f"rejected peer uid={uid} gid={gid} pid={pid}")
            conn.close()
            continue
        log(f"accepted peer uid={uid} gid={gid} pid={pid}")
        srv.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return conn


def logger(path):
    def log(msg):
        append(path, f"{now_ns()} {msg}")

    return log


def pump(a_in, a_out, sock, on_sock_eof):
    """a_in(fd) → sock, sock → a_out(fd). sock이 끝나면 on_sock_eof()를 부르고 돌아간다."""
    a_open = True
    while True:
        rl = [sock] + ([a_in] if a_open else [])
        r, _, _ = select.select(rl, [], [], 1.0)
        if sock in r:
            try:
                data = sock.recv(65536)
            except OSError:
                data = b""
            if not data:
                on_sock_eof()
                return
            os.write(a_out, data)
        if a_open and a_in in r:
            try:
                data = os.read(a_in, 65536)
            except OSError:
                data = b""
            if not data:
                a_open = False
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            sock.sendall(data)


def cmd_relay_serve(args):
    path, logpath = args[0], args[1]
    log = logger(logpath)
    conn = listen_once(path, BODY_UID, log)
    if os.isatty(0):
        import tty

        # hc의 pty가 줄 편집·에코를 하면 본체 쪽 pty와 겹친다. 이쪽은 날 바이트만 넘긴다.
        tty.setraw(0)
    pump(0, 1, conn, lambda: log("body closed"))
    log("relay end")


def cmd_cred_serve(args):
    path, ledger = args[0], args[1]
    gen = os.path.basename(os.path.dirname(path))
    value = sys.stdin.buffer.read(MAX_CRED)
    sys.stdin.close()
    log = logger(ledger + ".cred-serve.log")
    conn = listen_once(path, BODY_UID, log)
    conn.sendall(value)
    conn.close()
    # 값은 장부에 적지 않는다. sha 앞 16자만으로 본체가 받은 것과 대조한다.
    append(ledger, f"{now_ns()} cred-delivered gen={gen} sha={sha16(value)} peer_uid={BODY_UID}")


def wait_path(path, sock_only, timeout=None):
    t0 = time.monotonic()
    while True:
        try:
            st = os.stat(path)
            if not sock_only or (st.st_mode & 0o170000) == 0o140000:
                return True
        except OSError:
            pass
        if timeout is not None and time.monotonic() - t0 > timeout:
            return False
        time.sleep(0.25)


def connect_checked(path, want_uid):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    pid, uid, gid = peer_cred(s)
    if uid != want_uid:
        s.close()
        raise PermissionError(f"peer uid {uid} != {want_uid}")
    return s


class BodyState:
    """본체 쪽 상태 파일(/b/state). 본체 컨테이너의 단계(bctl.sh)가 읽는다. 자격 값은 적지 않는다."""

    def __init__(self, path):
        self.path = path
        self.v = {}

    def set(self, **kw):
        self.v.update(kw)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            for k, v in self.v.items():
                f.write(f"{k}={v}\n")
        os.replace(tmp, self.path)


def cmd_body_init(args):
    if "--" not in args or args.index("--") == len(args) - 1:
        print("body-init: -- 뒤에 본체 자리 명령이 없다", file=sys.stderr)
        sys.exit(2)
    command = args[args.index("--") + 1:]
    stop = {"now": False}
    # PID 1은 핸들러가 없는 신호를 받지 않는다. TERM에 끝나도록 핸들러를 건다(파드 삭제가 유예를 다 쓰지 않게).
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True) or sys.exit(0))
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    st = BodyState("/b/state")
    st.set(pid1_started_ns=now_ns(), gen="?", phase="wait-gen", relay="none", cred="none", program="none")
    while True:
        try:
            gen, init_ns = open("/relay/current").read().split()[:2]
            break
        except (OSError, ValueError):
            time.sleep(0.5)
    st.set(gen=gen, gen_init_ns=init_ns, phase="wait-cred")
    gdir = f"/relay/{gen}"
    cred = b""
    while not stop["now"]:
        if wait_path(f"{gdir}/cred.sock", True, 5):
            try:
                s = connect_checked(f"{gdir}/cred.sock", CONTROL_UID)
                chunks = []
                while sum(map(len, chunks)) < MAX_CRED:
                    d = s.recv(MAX_CRED)
                    if not d:
                        break
                    chunks.append(d)
                s.close()
                cred = b"".join(chunks)
                break
            except OSError as e:
                st.set(cred_error=type(e).__name__)
                time.sleep(1)
        reap()
    st.set(cred=f"sha={sha16(cred)}" if cred else "empty", cred_received_ns=now_ns(), phase="wait-relay")
    while True:
        wait_path(f"{gdir}/r.sock", True)
        try:
            sock = connect_checked(f"{gdir}/r.sock", CONTROL_UID)
            break
        except OSError as e:
            st.set(relay_error=type(e).__name__)
            time.sleep(1)
    home, tmp = f"/b/{gen}/home", f"/b/{gen}/tmp"
    for d in (home, tmp):
        os.makedirs(d, mode=0o700, exist_ok=True)
    env = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": home,
        "TMPDIR": tmp,
        "TERM": "xterm-256color",
        "O25_GEN": gen,
    }
    if cred:
        env["O25_FAKE_CRED"] = cred.decode("utf-8", errors="replace")
    pid, master = pty.fork()
    if pid == 0:
        os.chdir(home)
        os.execvpe(command[0], command, env)
    del cred, env
    import fcntl
    import termios

    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    st.set(phase="running", relay="open", program=f"pid={pid}", relay_open_ns=now_ns())
    child = {"alive": True}

    def on_relay_eof():
        st.set(relay="closed", relay_closed_ns=now_ns())

    # 중계가 끊겨도 본체 자리 프로그램을 끝내지 않는다. 본체를 끝내는 것은 전체 재시작뿐이다(hc kill로는 세션이 끝나지 않는다).
    # 다시 붙지도 않는다. 제어 쪽은 세대마다 연결 하나만 받는다.
    while child["alive"]:
        try:
            pump_child(master, sock, on_relay_eof, child, pid, st)
        except OSError:
            pass
        break
    # 프로그램이 끝난 뒤에도 PID 1은 남는다(컨테이너가 혼자 다시 떠서 새 자격을 기다리는 일을 만들지 않는다).
    while True:
        reap()
        time.sleep(1)


def reap():
    while True:
        try:
            p, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if p == 0:
            return


def pump_child(master, sock, on_relay_eof, child, pid, st):
    relay_open = True
    while True:
        rl = [master] + ([sock] if relay_open else [])
        r, _, _ = select.select(rl, [], [], 1.0)
        if relay_open and sock in r:
            try:
                data = sock.recv(65536)
            except OSError:
                data = b""
            if not data:
                relay_open = False
                on_relay_eof()
                sock.close()
            else:
                os.write(master, data)
        if master in r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if not data:
                break
            if relay_open:
                try:
                    sock.sendall(data)
                except OSError:
                    relay_open = False
                    on_relay_eof()
        try:
            p, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            p, status = pid, 0
        if p == pid:
            break
        reap()
    child["alive"] = False
    st.set(program=f"exited pid={pid}", program_exit_ns=now_ns())
    if relay_open:
        sock.close()
        st.set(relay="closed-by-body", relay_closed_ns=now_ns())


def cmd_spy(args):
    tag = args[0]
    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, signal.SIG_IGN)
    born = os.environ.get("O25_GEN") or open("/relay/current").read().split()[0]
    os.makedirs("/b/spy", exist_ok=True)
    hb = f"/b/spy/{tag}.hb"
    caught = f"/b/spy/{tag}.caught"
    tried = set()
    while True:
        with open(hb + ".tmp", "w") as f:
            f.write(f"born={born} pid={os.getpid()} now_ns={now_ns()}\n")
        os.replace(hb + ".tmp", hb)
        try:
            gens = [g for g in os.listdir("/relay") if g not in ("current", born)]
        except OSError:
            gens = []
        for g in gens:
            for name in ("cred.sock", "r.sock"):
                p = f"/relay/{g}/{name}"
                if not os.path.exists(p):
                    continue
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(1.0)
                try:
                    s.connect(p)
                    try:
                        data = s.recv(MAX_CRED)
                    except socket.timeout:
                        data = b""
                    append(caught, f"{now_ns()} connected {p} got_len={len(data)} sha={sha16(data) if data else '-'}")
                except OSError as e:
                    key = (p, e.errno)
                    if key not in tried:
                        tried.add(key)
                        append(caught + ".tries", f"{now_ns()} {p} {errno.errorcode.get(e.errno, e.errno)}")
                finally:
                    s.close()
        # 같은 컨테이너의 다른 프로세스 환경에서 다른 세대의 자격 표식을 찾는다(옛 컨테이너가 살아남은 경우에만 의미가 있다).
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                env = open(f"/proc/{d}/environ", "rb").read()
            except OSError:
                continue
            for item in env.split(b"\0"):
                if item.startswith(b"O25_FAKE_CRED=") and f"-{born}-".encode() not in item:
                    append(caught, f"{now_ns()} environ pid={d} sha={sha16(item[14:])}")
        time.sleep(0.2)


def cmd_connect(args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(unix_addr(args[0]))
        print("connected")
        return 0
    except OSError as e:
        print(f"refused {errno.errorcode.get(e.errno, e.errno)}")
        return 1
    finally:
        s.close()


def cmd_peer(args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(unix_addr(args[0]))
        pid, uid, gid = peer_cred(s)
        print(f"peer uid={uid} gid={gid} pid={pid}")
        return 0
    except OSError as e:
        print(f"refused {errno.errorcode.get(e.errno, e.errno)}")
        return 1
    finally:
        s.close()


def cmd_trycreate(args):
    try:
        fd = os.open(args[0], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        os.unlink(args[0])
        print("ok")
    except OSError as e:
        print(errno.errorcode.get(e.errno, str(e.errno)))


def cmd_tcp(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect((args[0], int(args[1])))
        print("connected")
    except OSError as e:
        print(f"refused {errno.errorcode.get(e.errno, e.errno) if e.errno else type(e).__name__}")
    finally:
        s.close()


def cmd_sanitize(_args):
    sys.stdout.write(sanitize_text(sys.stdin.buffer.read()))


def cmd_sha(_args):
    print(sha16(sys.stdin.buffer.read()))


COMMANDS = {
    "relay-serve": cmd_relay_serve,
    "cred-serve": cmd_cred_serve,
    "body-init": cmd_body_init,
    "spy": cmd_spy,
    "connect": cmd_connect,
    "peer": cmd_peer,
    "trycreate": cmd_trycreate,
    "tcp": cmd_tcp,
    "sanitize": cmd_sanitize,
    "sha": cmd_sha,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("o25.py: 모르는 이름", file=sys.stderr)
        sys.exit(2)
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]) or 0)
