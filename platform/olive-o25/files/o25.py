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
  tryop <create|symlink|bind|rename> <경로>  그 조작을 시도해 ok 또는 errno 이름을 찍는다.
  tcpscan                     /proc/net/tcp·tcp6의 모든 수신점에 그 주소·계열 그대로 붙어 본다.
  scan <뿌리...>              표준 입력의 표식을 파일·프로세스 argv·환경에서 찾는다(표식은 인자로 받지 않는다).
  sanitize                    표준 입력의 제어·서식 문자를 지운다.
  sha                         표준 입력의 sha256 앞 16자.
요청 통로(자격·가림 검사를 원래 PID 1 계통에서 돌린다)
  submit <작업>               관리자가 kubectl exec로 바로 부르는 제출자. 고정 필드 한 줄을 FIFO에 쓰고 인수 표시를 기다린 뒤 끝난다.
  accept <세대> <받은 목록>    제어 PID 1이 요청 줄(표준 입력)을 검사한다. "ok ..." 또는 "reject <코드> <요청|->".
  gate <인수 폴더> <요청> <pid> <시작>  제출자가 보이는지 확인하고 신호 0을 재고 인수 표시를 쓴 뒤, 사라질 때까지 기다린다.
  publish <작업> <파드> <세대> <요청>   표준 입력(검사 결과)에서 정해진 모양의 줄만 골라 컨테이너 로그용 줄로 낸다.
  body-job <작업> <세대> <요청> <pid> <시작>  본체 PID 1이 띄우는 자식. gate → 고정 검사 → publish.

검사 결과는 종료 코드와 함께 읽는다. errno 이름이 아닌 출력(traceback, 빈 출력)은 차단의 증거가 아니다.

요청 통로를 두는 이유: 이 노드에서 kubectl exec로 들어온 프로세스는 AppArmor 라벨이 겹쳐져(…//&unconfined) 원래 프로세스가
그 환경을 읽지 못한다. 검사하는 순간 exec 계통이 컨테이너 안에 살아 있으면 검사가 읽지 못한 대상으로 남는다. 그래서 제출자는
쓰고 끝나며, PID 1 계통이 그 PID·시작 시각이 실제로 사라진 것을 본 뒤에만 검사하고, 결과는 PID 1의 표준 출력(컨테이너 로그)으로
낸다. 회수는 exec 없이 kubectl logs로 한다(tools/olive-o25/result.py). 로그에는 고정 키·판정 낱말·고정 이유 코드·개수·errno·
PID·시작 시각·해시·요청 식별자만 싣는다(원시 환경·argv·화면·파일 내용·파일 이름·traceback은 싣지 않는다).

중계는 바이트와 닫기만 나른다. 명령·인자·환경·크기 변경을 받지 않는다. 화면 크기는 ROWS×COLS로 고정이다.
중계 소켓과 자격 소켓은 제어 쪽이 만든다. 중계 폴더는 본체에 읽기 전용으로 붙어, 본체는 거기에 소켓을 만들거나 바꿔치기하지 못하고
연결만 한다(Podman 실측에서 본체가 쓸 수 있는 폴더에 소켓을 두자 바꿔치기가 됐다).
"""
import errno
import hashlib
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import unicodedata

CONTROL_UID = 10001
BODY_UID = 10002
ROWS, COLS = 50, 200
DROP_CATEGORIES = ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")
MAX_CRED = 4096

# 요청 통로의 작업과 그 작업이 꼭 내야 하는 판정 키. 회수 쪽(tools/olive-o25/result.py)의 같은 표와 함께 바꾼다.
CONTROL_JOBS = ("cred",)
BODY_JOBS = ("body-cred", "body-hide")
JOB_KEYS = {
    "cred": ["6.hc-상태-없음", "6.제어-argv-environ-없음", "6.제어-로그-장부-없음", "6.중계-폴더-없음", "6.hc-화면-없음"],
    "body-cred": ["6.본체-프로세스에-있음", "6.본체-쪽-파일-argv-없음"],
    "body-hide": ["5.body.hc-socket", "5.body.hc-ls", "5.body.state", "5.body.proc", "5.body.netns", "5.body.relay-dir"],
}
# 판정 줄 끝의 "(이유 <코드>)"로 쓸 수 있는 코드. 이 목록 밖의 코드가 붙은 줄은 로그로 내지 않는다(그 키가 빠져 회수가 미완료가 된다).
CODES = frozenset((
    "no-mark", "scan-failed", "not-delivered", "unreadable", "hit", "clean", "no-state-files", "no-procs",
    "screen-unread", "screen-hit", "screen-clean",
    "submitter-unseen", "submitter-alive", "submitter-unread", "job-failed",
    "program-unknown", "env-open-failed", "absent", "sha-mismatch", "present", "program-changed", "not-checked",
))
REQ_MAX = 200
REQ_RE = re.compile(r"req1 ([a-z-]{1,16}) ([0-9a-f]{12}) ([0-9a-f]{12}) ([0-9]{1,10}) ([0-9]{1,20})")
LABEL_RE = re.compile(r"[A-Za-z0-9._/&()+:-]{1,80}")
GATE_LIMIT_S = 20
ACK_WAIT_S = 10
JOB_LIMIT_S = 180


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


# ---- 본체 자리 프로그램의 실행 증거(claude 변형). 본체 PID 1이 자기 표준 출력(본체 컨테이너 로그)에 "o25c" 줄로 낸다.
# 판정은 밖의 tools/olive-o25/claude-judge.py가 제어 쪽 claude-ui 단계 결과와 묶어서 한다. 줄에는 고정 키와 숫자·해시·고정 낱말만 싣는다.

PROG_VER_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def prog_check(path, want_sha, want_ver, env, runner=subprocess.run, sha=file_sha256):
    """자격을 받기 전: 고정 파일의 sha256과 --version 첫 낱말을 핀과 대조한다. (check 낱말, 필드 사전).

    check는 ok, sha-mismatch, version-mismatch, error-<무엇> 중 하나다. 판정 근거는 sha이고 --version은 보조다
    (따로 띄운 --version은 pty 자식이 같은 파일이라는 증거가 아니다. 그것은 exe_check가 본다).
    """
    f = {"sha": "-", "version": "-", "ino": "-"}
    try:
        st = os.stat(path)
        f["ino"] = f"{st.st_dev}:{st.st_ino}"
        f["sha"] = sha(path)
    except OSError as e:
        return f"error-{errname(e.errno).lower()}", f
    if f["sha"] != want_sha:
        return "sha-mismatch", f
    try:
        out = runner([path, "--version"], env=env, cwd=env.get("HOME", "/"), stdin=subprocess.DEVNULL,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60, close_fds=True).stdout
    except (OSError, subprocess.SubprocessError):
        return "error-version-run", f
    first = out.decode("ascii", errors="replace").split()[:1]
    f["version"] = first[0] if first and PROG_VER_RE.fullmatch(first[0]) else "unparsed"
    if f["version"] != want_ver:
        return "version-mismatch", f
    return "ok", f


def exe_check(pid, path, limit_s=5.0, stat=os.stat, clock=time.monotonic, sleep=time.sleep):
    """pty 자식의 /proc/<pid>/exe가 고정 파일(같은 장치·inode)인지. match, mismatch, gone, unreadable-<errno>.

    exec 전에는 exe가 python이므로 limit_s 동안 다시 본다. 읽지 못하면 판정하지 않는다(밖에서 판단 필요).
    """
    try:
        want = stat(path)
    except OSError as e:
        return f"unreadable-{errname(e.errno).lower()}"
    end = clock() + limit_s
    while True:
        try:
            st = stat(f"/proc/{pid}/exe")
        except OSError as e:
            if e.errno in (errno.ENOENT, errno.ESRCH):
                return "gone"
            return f"unreadable-{errname(e.errno).lower()}"
        if (st.st_dev, st.st_ino) == (want.st_dev, want.st_ino):
            return "match"
        if clock() >= end:
            return "mismatch"
        sleep(0.05)


def exit_word(status):
    if status is None:
        return "unknown"
    if os.WIFEXITED(status):
        return f"exit:{os.WEXITSTATUS(status)}"
    if os.WIFSIGNALED(status):
        return f"signal:{os.WTERMSIG(status)}"
    return "unknown"


def prog_line(pod, gen, kind, **kw):
    """o25c 줄. 값은 [A-Za-z0-9._:-]만 남긴다(본체가 고를 수 있는 글이 섞여도 줄 모양이 안 바뀌게)."""
    vals = " ".join(f"{k}={re.sub(r'[^A-Za-z0-9._:-]', '?', str(v))[:80]}" for k, v in kw.items())
    return f"o25c {pod} {gen} {kind} {vals}"


# reap()이 먼저 거둔 자식의 종료 상태. 본체 자리 프로그램의 종료 상태를 잃지 않게 한다.
REAPED = {}


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
    # 본체 컨테이너가 뜬 세대의 차례. bctl.sh after-restart가 "바로 앞 세대"(이번 재시작으로 끝났어야 할 세대)를 여기서 읽는다.
    append("/b/boots", f"{gen} {now_ns()}")
    reqs = ReqServer.open_fifo(BODY_JOBS, gen)
    gdir = f"/relay/{gen}"
    pod = os.environ.get("O25_POD_UID", "?")
    home, tmp = f"/b/{gen}/home", f"/b/{gen}/tmp"
    want_sha = os.environ.get("O25_PROG_SHA256", "")
    prog_env = {}
    if want_sha:
        # claude 변형: 자격을 받기 전에 고정 파일을 대조한다. --version도 프로그램 환경과 같은 세대 HOME·TMPDIR로 띄운다
        # (읽기 전용 root에서 쓰기 자리가 없으면 끝나 버린다). 다르면 자격을 받지 않고 요청만 받으며 머문다.
        for d in (home, tmp):
            os.makedirs(d, mode=0o700, exist_ok=True)
        prog_env = {"DISABLE_AUTOUPDATER": "1", "LINES": str(ROWS), "COLUMNS": str(COLS)}
        venv = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": home, "TMPDIR": tmp,
                "TERM": "xterm-256color", **prog_env}
        check, f = prog_check(command[0], want_sha, os.environ.get("O25_PROG_VERSION", ""), venv)
        st.set(prog_check=check, prog_sha=f["sha"], prog_version=f["version"], prog_ino=f["ino"])
        emit(prog_line(pod, gen, "prog-check", check=check, sha=f["sha"], version=f["version"], ino=f["ino"],
                       t_ns=now_ns()))
        if check != "ok":
            st.set(phase="prog-refused")
            while True:
                reqs.service(1.0)
                reap()
    cred = b""
    while not stop["now"]:
        reqs.service(0)
        if wait_path(f"{gdir}/cred.sock", True, 1):
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
        reqs.service(0)
        if not wait_path(f"{gdir}/r.sock", True, 1):
            continue
        try:
            sock = connect_checked(f"{gdir}/r.sock", CONTROL_UID)
            break
        except OSError as e:
            st.set(relay_error=type(e).__name__)
            time.sleep(1)
    for d in (home, tmp):
        os.makedirs(d, mode=0o700, exist_ok=True)
    env = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": home,
        "TMPDIR": tmp,
        "TERM": "xterm-256color",
        "O25_GEN": gen,
        "O25_POD_UID": os.environ.get("O25_POD_UID", "?"),
        **prog_env,
    }
    if cred:
        env["O25_FAKE_CRED"] = cred.decode("utf-8", errors="replace")
    import fcntl
    import termios

    # 자식은 부모가 화면 크기를 정할 때까지 exec하지 않는다. 그래야 프로그램이 처음 읽는 크기가 고정 50×200이다.
    sync_r, sync_w = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.close(sync_w)
        os.read(sync_r, 1)
        os.close(sync_r)
        os.chdir(home)
        os.execvpe(command[0], command, env)
    del cred, env
    os.close(sync_r)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    rows, cols = struct.unpack("HHHH", fcntl.ioctl(master, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    os.write(sync_w, b"g")
    os.close(sync_w)
    st.set(phase="running", relay="open", program=f"pid={pid}", relay_open_ns=now_ns(), pty_size=f"{rows}x{cols}")
    if want_sha:
        exe = exe_check(pid, command[0])
        try:
            p = stat_start(read_stat(pid))
        except OSError:
            p = None
        st.set(prog_exe=exe)
        emit(prog_line(pod, gen, "prog-launch", pid=pid, start=p[1] if p else "-", exe=exe, rows=rows, cols=cols,
                       sync="before-exec", t_ns=now_ns()))
    child = {"alive": True}

    def on_relay_eof():
        st.set(relay="closed", relay_closed_ns=now_ns())

    # 중계가 끊겨도 본체 자리 프로그램을 끝내지 않는다. 본체를 끝내는 것은 전체 재시작뿐이다(hc kill로는 세션이 끝나지 않는다).
    # 다시 붙지도 않는다. 제어 쪽은 세대마다 연결 하나만 받는다.
    while child["alive"]:
        try:
            pump_child(master, sock, on_relay_eof, child, pid, st, reqs)
        except OSError:
            pass
        break
    if want_sha:
        emit(prog_line(pod, gen, "prog-exit", pid=pid, status=child.get("status", "unknown"),
                       t_ns=child.get("exit_ns", now_ns())))
    # 프로그램이 끝난 뒤에도 PID 1은 남는다(컨테이너가 혼자 다시 떠서 새 자격을 기다리는 일을 만들지 않는다).
    while True:
        reqs.service(1.0)
        reap()


def reap():
    while True:
        try:
            p, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if p == 0:
            return
        REAPED[p] = status


def pump_child(master, sock, on_relay_eof, child, pid, st, reqs):
    relay_open = True
    while True:
        rl = [master] + ([sock] if relay_open else []) + reqs.fds()
        r, _, _ = select.select(rl, [], [], 1.0)
        if reqs.fds() and reqs.fds()[0] in r:
            reqs.on_readable()
        reqs.poll()
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
            p, status = pid, REAPED.pop(pid, None)
        if p == pid:
            child["status"] = exit_word(status)
            break
        reap()
    if "status" not in child:
        # pty가 먼저 닫혔다(EOF). 프로그램이 곧 끝나는 것을 잠깐 기다려 종료 상태를 남긴다. 못 받으면 unknown이다.
        for _ in range(50):
            try:
                p, status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                p, status = pid, REAPED.pop(pid, None)
            if p == pid:
                child["status"] = exit_word(status)
                break
            time.sleep(0.1)
    child["alive"] = False
    child["exit_ns"] = now_ns()
    st.set(program=f"exited pid={pid}", program_exit_ns=child["exit_ns"], program_exit=child.get("status", "unknown"))
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
    return cmd_tryop(["create", args[0]])


def _op_create(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    os.unlink(path)


def _op_symlink(path):
    os.symlink("/b", path)
    os.unlink(path)


def _op_bind(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(path)
    finally:
        s.close()
    os.unlink(path)


def _op_rename(path):
    os.rename(path, path + ".x")
    os.rename(path + ".x", path)


OPS = {"create": _op_create, "symlink": _op_symlink, "bind": _op_bind, "rename": _op_rename}


def cmd_tryop(args):
    # 출력은 ok 또는 errno 이름 하나. 종료 코드 0은 조작 성공, 1은 errno로 실패. 그 밖의 예외는 traceback이 찍히므로
    # 부르는 쪽은 첫 줄이 기대한 errno 이름일 때만 차단으로 읽는다.
    try:
        OPS[args[0]](args[1])
    except OSError as e:
        print(errno.errorcode.get(e.errno, str(e.errno)) if e.errno else type(e).__name__)
        return 1
    print("ok")
    return 0


def _hex_addr(h):
    # /proc/net/tcp의 주소는 32비트 낱말마다 호스트 바이트 순서(x86은 little-endian)다.
    raw = b"".join(bytes.fromhex(h[i:i + 8])[::-1] for i in range(0, len(h), 8))
    if len(raw) == 4:
        return socket.AF_INET, socket.inet_ntop(socket.AF_INET, raw)
    return socket.AF_INET6, socket.inet_ntop(socket.AF_INET6, raw)


def listeners():
    out = []
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        with open(path) as f:
            next(f)
            for line in f:
                p = line.split()
                if len(p) < 4 or p[3] != "0A":
                    continue
                h, port = p[1].split(":")
                fam, addr = _hex_addr(h)
                out.append((fam, addr, int(port, 16)))
    return sorted(set(out))


def cmd_tcpscan(_args):
    # 수신 주소를 버리지 않는다. Pod IP 전용·::1 전용 수신점은 127.0.0.1로 붙으면 거절되어 "없다"로 잘못 읽힌다.
    # wildcard(0.0.0.0, ::)만 같은 계열의 loopback으로 바꾼다. IPv4-mapped(::ffff:a.b.c.d)는 IPv6 그대로 붙는다.
    blocked = ("ECONNREFUSED",)
    try:
        ls = listeners()
    except OSError as e:
        print(f"summary error=read-proc-net-{errno.errorcode.get(e.errno, e.errno)}")
        return 1
    n_conn = n_block = n_unk = 0
    for fam, addr, port in ls:
        target = addr
        if fam == socket.AF_INET and addr == "0.0.0.0":
            target = "127.0.0.1"
        elif fam == socket.AF_INET6 and addr == "::":
            target = "::1"
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(2)
        try:
            s.connect((target, port))
            res = "connected"
            n_conn += 1
        except OSError as e:
            name = errno.errorcode.get(e.errno, "") if e.errno else type(e).__name__
            res = f"refused {name}"
            if name in blocked:
                n_block += 1
            else:
                n_unk += 1
        finally:
            s.close()
        fam_name = "inet6" if fam == socket.AF_INET6 else "inet"
        print(f"tcp {fam_name} listen={addr} port={port} target={target} -> {res}")
    print(f"summary listen={len(ls)} connected={n_conn} blocked={n_block} unknown={n_unk}")
    return 0


def cmd_scan(args):
    """표준 입력의 표식을 뿌리 아래 일반 파일과 모든 프로세스의 argv·환경에서 찾는다.

    표식을 argv·환경·임시 파일로 받지 않는다(검사기 자신이 노출 경로가 된다). 검사기 자신(self)만 빼고, PID 1은 executor로
    따로 표시한다. 그새 끝난 프로세스는 gone으로 세고, 읽기 실패(EACCES 등)는 unreadable로 세어 성공과 구별한다.
    """
    mark = sys.stdin.buffer.read(MAX_CRED)
    sys.stdin.close()
    if len(mark) < 8:
        print("summary error=short-mark")
        return 2
    me = os.getpid()
    n_files = n_procs = n_gone = n_unread = 0
    # os.walk는 열지 못한 폴더(뿌리 포함: 없음, EACCES)를 onerror로 알리고 건너뛴다. 세지 않으면 그 안의 파일이 '없음'으로 통과한다.
    dir_errs = []

    # 파일 이름과 comm은 본체가 고를 수 있다. 줄바꿈 하나로 가짜 "결과" 줄을 만들 수 있으므로 인쇄되지 않는 글자는 \xNN으로 바꿔
    # 한 줄로 찍는다. 앞부분(뿌리 경로)은 그대로라 분류가 바뀌지 않는다.
    def one_line(s):
        return "".join(c if c.isprintable() else f"\\x{ord(c):02x}" for c in str(s))

    def dir_err(e):
        dir_errs.append(e)
        print(f"unreadable dir {one_line(e.filename)} {errno.errorcode.get(e.errno, e.errno)}")

    for root in args:
        for dirpath, dirnames, filenames in os.walk(root, onerror=dir_err):
            for name in filenames:
                p = os.path.join(dirpath, name)
                try:
                    st = os.lstat(p)
                    # 일반 파일만 연다. FIFO(실행기의 /c/ctl/in)를 열면 쓰는 쪽이 올 때까지 멈춘다.
                    if (st.st_mode & 0o170000) != 0o100000:
                        continue
                    with open(p, "rb") as f:
                        data = f.read()
                except OSError as e:
                    if e.errno == errno.ENOENT:
                        continue
                    n_unread += 1
                    print(f"unreadable file {one_line(p)} {errno.errorcode.get(e.errno, e.errno)}")
                    continue
                n_files += 1
                if mark in data:
                    print(f"file {one_line(p)}")
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        label = "executor" if d == "1" else "proc"
        n_procs += 1
        for what in ("cmdline", "environ"):
            try:
                with open(f"/proc/{d}/{what}", "rb") as f:
                    data = f.read()
            except OSError as e:
                if e.errno in (errno.ENOENT, errno.ESRCH):
                    n_gone += 1
                    break
                n_unread += 1
                try:
                    with open(f"/proc/{d}/comm") as f:
                        comm = f.read().strip()
                except OSError:
                    comm = "?"
                print(f"unreadable {what} {d} {errno.errorcode.get(e.errno, e.errno)} comm={one_line(comm)}")
                continue
            if mark in data:
                print(f"{'argv' if what == 'cmdline' else 'environ'} {d} {label}")
    n_unread += len(dir_errs)
    print(f"summary files={n_files} procs={n_procs} gone={n_gone} unreadable={n_unread} self={me}")
    return 0


# ---- 요청 통로

def errname(no):
    return errno.errorcode.get(no, str(no)) if no else "E?"


def read_stat(pid):
    with open(f"/proc/{pid}/stat", "rb") as f:
        return f.read()


def stat_start(raw):
    """/proc/<pid>/stat에서 (상태, 시작 시각 tick). comm에 공백·괄호가 있을 수 있어 마지막 ')' 뒤를 센다. 못 읽으면 None."""
    s = raw.decode("ascii", errors="replace")
    i = s.rfind(")")
    if i < 0:
        return None
    f = s[i + 1:].split()
    if len(f) < 20 or not f[19].isdigit():
        return None
    return f[0], int(f[19])


def submitter_state(pid, start, reader=read_stat):
    """("alive"|"gone"|"unknown", 자세히). 없음(ENOENT·ESRCH)과 같은 PID의 다른 시작 시각(재사용)만 소멸이다.

    좀비는 아직 있는 것으로 센다. 읽기 실패·해석 실패는 모름이다(없음으로 읽지 않는다).
    """
    try:
        raw = reader(pid)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ESRCH):
            return "gone", None
        return "unknown", errname(e.errno)
    p = stat_start(raw)
    if p is None:
        return "unknown", "parse"
    if p[1] != start:
        return "gone", "reused"
    return "alive", p[0]


def wait_gone(pid, start, limit_s, reader=read_stat, clock=time.monotonic, sleep=time.sleep):
    """(소멸 확인 여부, 코드, 기다린 ms, 자세히). 기한을 넘기거나 읽지 못하면 확인 못 함이다."""
    t0 = clock()
    while True:
        state, detail = submitter_state(pid, start, reader)
        waited = int((clock() - t0) * 1000)
        if state == "gone":
            return True, detail or "gone", waited, detail
        if state == "unknown":
            return False, "submitter-unread", waited, detail
        if clock() - t0 >= limit_s:
            return False, "submitter-alive", waited, detail
        sleep(0.1)


def read_label(pid):
    with open(f"/proc/{pid}/attr/current", "rb") as f:
        return f.read(256).decode("ascii", errors="replace")


def label_word(text):
    v = text.strip().replace(" ", "_")
    return v if LABEL_RE.fullmatch(v) else "h:" + sha16(text.encode("utf-8", errors="replace"))


def gate(ackdir, req, pid, start, reader=read_stat, kill=os.kill, label=read_label, clock=time.monotonic,
         sleep=time.sleep, limit_s=GATE_LIMIT_S):
    """제출자 문지기. (소멸 확인 여부, 줄 목록). 마지막 줄은 늘 "gate state=…".

    1. 제출자가 그 PID·시작 시각으로 지금 보여야 한다(요청 줄의 PID가 실제 제출자였다는 증거). 안 보이면 인수하지 않는다.
    2. 원래 계통 → exec 계통 신호 0을 한 번 잰다(판정이 아니라 사실). 두 계통의 라벨도 사실로 남긴다.
    3. 인수 표시를 쓰면 제출자가 끝난다. 그 PID·시작 시각이 사라질 때까지 기다린다.
    """
    lines = []

    def lab(who, p):
        try:
            lines.append(f"gate-fact label-{who}={label_word(label(p))}")
        except OSError as e:
            lines.append(f"gate-fact label-{who}={errname(e.errno)}")

    def done(ok, code, waited):
        lines.append(f"gate state={'gone' if ok else 'undecided'} code={code} pid={pid} start={start} waited_ms={waited}")
        return ok, lines

    lab("self", "self")
    state, _ = submitter_state(pid, start, reader)
    if state != "alive":
        return done(False, "submitter-unseen", 0)
    try:
        kill(pid, 0)
        lines.append("gate-fact sig0=OK")
    except OSError as e:
        lines.append(f"gate-fact sig0={errname(e.errno)}")
    lab("submitter", pid)
    try:
        fd = os.open(os.path.join(ackdir, req), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    except OSError as e:
        lines.append(f"gate-fact ack={errname(e.errno)}")
    ok, code, waited, _ = wait_gone(pid, start, limit_s, reader, clock, sleep)
    return done(ok, code, waited)


def parse_req(line, jobs):
    """요청 줄 "req1 <작업> <세대> <요청 ID> <제출자 pid> <시작 시각>"을 검사한다. (사전, None) 또는 (None, 거절 코드)."""
    if len(line) > REQ_MAX:
        return None, "bad-form"
    m = REQ_RE.fullmatch(line.rstrip("\n"))
    if not m:
        return None, "bad-form"
    if m.group(1) not in jobs:
        return None, "bad-job"
    return {"job": m.group(1), "gen": m.group(2), "req": m.group(3), "pid": int(m.group(4)), "start": int(m.group(5))}, None


def accept_req(line, jobs, cur_gen, seen):
    """받는 쪽의 인수 조건. 다른 세대·이미 받은 요청 ID는 거절한다. 인수하면 seen에 넣는다."""
    rec, code = parse_req(line, jobs)
    if rec is None:
        return None, code
    if rec["gen"] != cur_gen:
        return rec, "gen"
    if rec["req"] in seen:
        return rec, "dup"
    seen.add(rec["req"])
    return rec, "ok"


def pid1_start():
    try:
        p = stat_start(read_stat(1))
    except OSError:
        p = None
    return str(p[1]) if p else "0"


def root_class(p):
    if p.startswith("/c/g/"):
        return "hc-state"
    if p.startswith("/c/"):
        return "ctl-record"
    if p == "/relay" or p.startswith("/relay/"):
        return "relay"
    if p.startswith("/b/"):
        return "body"
    return "other"


_PUB = [
    (re.compile(r"gate state=(gone|undecided) code=(gone|reused|submitter-unseen|submitter-alive|submitter-unread) "
                r"pid=(\d{1,10}) start=(\d{1,20}) waited_ms=(\d{1,10})"),
     lambda m: f"gate state={m[1]} code={m[2]} pid={m[3]} start={m[4]} waited_ms={m[5]}"),
    (re.compile(r"gate-fact (sig0|ack)=(OK|E[A-Z0-9]{1,15})"), lambda m: f"fact {m[1]}={m[2]}"),
    (re.compile(r"gate-fact (label-self|label-submitter)=(\S+)"),
     lambda m: f"fact {m[1]}={m[2] if LABEL_RE.fullmatch(m[2]) else 'h:' + sha16(m[2].encode())}"),
    (re.compile(r"\s*summary files=(\d{1,10}) procs=(\d{1,10}) gone=(\d{1,10}) unreadable=(\d{1,10}) self=(\d{1,10})"),
     lambda m: f"scan files={m[1]} procs={m[2]} gone={m[3]} unreadable={m[4]} self={m[5]}"),
    (re.compile(r"\s*unreadable (cmdline|environ) (\d{1,10}) (E[A-Z0-9]{1,15}|\d{1,5})( comm=.*)?"),
     lambda m: f"unread kind={m[1]} pid={m[2]} errno={m[3]}"),
    (re.compile(r"\s*unreadable (file|dir) (.+) (E[A-Z0-9]{1,15}|\d{1,5})"),
     lambda m: f"unread kind={m[1]} root={root_class(m[2])} h={sha16(m[2].encode())} errno={m[3]}"),
    (re.compile(r"\s*file (.+)"), lambda m: f"hit kind=file root={root_class(m[1])} h={sha16(m[1].encode())}"),
    (re.compile(r"\s*(argv|environ) (\d{1,10}) (executor|proc)"), lambda m: f"hit kind={m[1]} pid={m[2]} who={m[3]}"),
    (re.compile(r"사실 (cred-sha|body-sha) ([0-9a-f]{16})"), lambda m: f"fact {m[1]}={m[2]}"),
    (re.compile(r"job state=(done|timeout|failed) rc=(-?\d{1,4})"), lambda m: f"job state={m[1]} rc={m[2]}"),
]
_VERDICT = re.compile(r"결과 (\S+) (됨|안 됨|판단 필요) — (.*)")
_CODE = re.compile(r" \(이유 ([a-z0-9-]{1,40})\)$")


def publish_lines(job, pod, gen, req, run, text):
    """검사 결과 글에서 정해진 모양의 줄만 골라 로그 줄로 바꾼다. 원문을 옮기지 않고 잡은 필드로 줄을 새로 만든다.

    판정 줄은 이 작업의 키와 정해진 이유 코드일 때만 내고, 근거 글은 sha 앞 16자로만 낸다. 경로는 뿌리 분류와 해시로만 낸다.
    모양에 안 맞는 줄은 개수(dropped)만 센다. 회수 쪽은 끝 줄의 결과 줄 수와 필수 키가 모두 맞아야 완료로 본다.
    """
    if not re.fullmatch(r"[0-9a-f-]{1,64}", pod or ""):
        pod = "?"
    if not re.fullmatch(r"[0-9a-f]{12}", gen) or not re.fullmatch(r"[0-9a-f]{12}", req) or job not in JOB_KEYS:
        return []
    if not run.isdigit():
        run = "0"
    head = f"o25r {pod} {gen} {req} "
    out = [head + f"begin job={job} run={run}"]
    n_v = dropped = 0
    keys = JOB_KEYS[job]
    for line in text.splitlines():
        m = _VERDICT.fullmatch(line)
        if m:
            c = _CODE.search(m[3])
            code = c[1] if c else "-"
            if m[1] in keys and (code == "-" or code in CODES):
                out.append(head + f"결과 {m[1]} {m[2]} code={code} why={sha16(line.encode())}")
                n_v += 1
            else:
                dropped += 1
            continue
        for rx, fmt in _PUB:
            m = rx.fullmatch(line)
            if m:
                out.append(head + fmt(m))
                break
        else:
            dropped += 1
    out.append(head + f"end n={n_v} dropped={dropped}")
    return out


def emit(line):
    # 한 줄을 한 번의 write로. 같은 표준 출력에 PID 1과 그 자식이 함께 쓴다.
    os.write(1, (line + "\n").encode("utf-8", errors="replace"))


class ReqServer:
    """본체 PID 1의 요청 통로. 본체 전용 /b/req FIFO에서 고정 작업 코드만 받는다. 한 번에 하나, 같은 세대, 처음 보는 요청 ID.

    이 통로는 신뢰의 근거가 아니다. 같은 uid의 본체 프로그램도 이 FIFO에 쓰고, 읽고, 로그 줄을 흉내 낼 수 있다. 그래서 본체가 낸
    결과는 보조 증거이고, 자격 발급·제어 쪽 조작·세대 교체의 권한은 이 통로에 없다. 작업은 PID 1의 자식으로 띄우고 기다리지 않는다
    (중계 입출력을 막지 않는다).
    """

    def __init__(self, jobs, gen, spawn, emit=emit, fd=None):
        self.jobs, self.gen, self.spawn, self.emit, self.fd = jobs, gen, spawn, emit, fd
        self.seen, self.job, self.buf = set(), None, b""

    @classmethod
    def open_fifo(cls, jobs, gen, path="/b/req", ackdir="/b/ack"):
        fd = None
        try:
            os.makedirs(ackdir, mode=0o700, exist_ok=True)
            try:
                os.mkfifo(path, 0o600)
            except FileExistsError:
                pass
            st = os.lstat(path)
            if (st.st_mode & 0o170000) == 0o010000 and st.st_uid == os.getuid():
                # O_RDWR: 쓰는 쪽이 없어도 EOF가 되풀이되지 않게 이쪽이 쓰는 끝도 쥔다(Linux).
                fd = os.open(path, os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW)
            else:
                emit(f"o25r {os.environ.get('O25_POD_UID', '?')} {gen} - reqfifo refused")
        except OSError as e:
            emit(f"o25r {os.environ.get('O25_POD_UID', '?')} {gen} - reqfifo {errname(e.errno)}")
        return cls(jobs, gen, spawn_body_job, emit, fd)

    def fds(self):
        return [self.fd] if self.fd is not None else []

    def busy(self):
        return self.job is not None and self.job.poll() is None

    def poll(self):
        if self.job is not None and self.job.poll() is not None:
            self.job = None

    def reject(self, req, code):
        self.emit(f"o25r {os.environ.get('O25_POD_UID', '?')} {self.gen} {req} reject code={code}")
        return code

    def handle_line(self, line):
        rec, code = parse_req(line, self.jobs)
        if rec is None:
            return self.reject("-", code)
        if self.busy():
            return self.reject(rec["req"], "busy")
        rec, code = accept_req(line, self.jobs, self.gen, self.seen)
        if code != "ok":
            return self.reject(rec["req"], code)
        self.job = self.spawn(rec)
        return "ok"

    def on_readable(self):
        try:
            data = os.read(self.fd, 4096)
        except OSError:
            return
        self.buf += data
        while b"\n" in self.buf:
            raw, self.buf = self.buf.split(b"\n", 1)
            self.handle_line(raw.decode("ascii", errors="replace"))
        if len(self.buf) > REQ_MAX:
            self.buf = b""
            self.reject("-", "bad-form")

    def service(self, timeout):
        self.poll()
        if self.fd is None:
            if timeout:
                time.sleep(timeout)
            return
        r, _, _ = select.select([self.fd], [], [], timeout)
        if r:
            self.on_readable()


BODY_JOB_ARGV = {
    "body-cred": ["/bin/bash", "/opt/o25/bctl.sh", "cred"],
    "body-hide": ["/bin/bash", "/opt/o25/probe.sh", "body"],
}


def spawn_body_job(rec):
    # 새 python으로 띄운다(PID 1의 메모리를 물려받지 않게). 환경은 고정 사전이다: 자격이 없고, PID 1의 환경은 검사 대상으로 남는다.
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/b", "LC_ALL": "C",
           "O25_POD_UID": os.environ.get("O25_POD_UID", "?")}
    argv = [sys.executable, "/opt/o25/o25.py", "body-job", rec["job"], rec["gen"], rec["req"], str(rec["pid"]), str(rec["start"])]
    return subprocess.Popen(argv, env=env, cwd="/b", stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)


def cmd_body_job(args):
    job, gen, req, pid, start = args[0], args[1], args[2], int(args[3]), int(args[4])
    pod = os.environ.get("O25_POD_UID", "?")
    os.makedirs("/b/out", mode=0o700, exist_ok=True)
    ok, lines = gate("/b/ack", req, pid, start)
    text = list(lines)
    if ok:
        out = f"/b/out/req-{req}.txt"
        with open(out, "wb") as f:
            p = subprocess.Popen(BODY_JOB_ARGV[job], stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT, cwd="/b",
                                 close_fds=True)
            try:
                rc = p.wait(timeout=JOB_LIMIT_S)
                state = "done"
            except subprocess.TimeoutExpired:
                p.kill()
                rc = p.wait()
                state = "timeout"
        with open(out, "rb") as f:
            text += f.read(256 * 1024).decode("utf-8", errors="replace").splitlines()
        text.append(f"job state={state} rc={rc}")
    else:
        code = lines[-1].split()[2].split("=", 1)[1]
        text += [f"결과 {k} 판단 필요 — 제출자 소멸을 확인하지 못했다 (이유 {code})" for k in JOB_KEYS[job]]
    for line in publish_lines(job, pod, gen, req, pid1_start(), "\n".join(text)):
        emit(line)
    return 0


def cmd_accept(args):
    """제어 PID 1용. 표준 입력의 요청 줄 하나를 검사하고, 인수하면 받은 목록 파일에 요청 ID를 더한다."""
    gen, seen_path = args[0], args[1]
    line = sys.stdin.buffer.read(REQ_MAX + 1).decode("ascii", errors="replace").split("\n", 1)[0]
    try:
        with open(seen_path) as f:
            seen = {s.strip() for s in f}
    except FileNotFoundError:
        seen = set()
    rec, code = accept_req(line, CONTROL_JOBS, gen, seen)
    if code != "ok":
        print(f"reject {code} {rec['req'] if rec else '-'}")
        return 1
    append(seen_path, rec["req"])
    print(f"ok {rec['job']} {rec['req']} {rec['pid']} {rec['start']}")
    return 0


def cmd_gate(args):
    ok, lines = gate(args[0], args[1], int(args[2]), int(args[3]))
    print("\n".join(lines))
    return 0 if ok else 1


def cmd_publish(args):
    job, pod, gen, req = args[:4]
    text = sys.stdin.buffer.read(256 * 1024).decode("utf-8", errors="replace")
    for line in publish_lines(job, pod, gen, req, pid1_start(), text):
        emit(line)
    return 0


def cmd_submit(args):
    """제출자. 셸·timeout·sleep을 띄우지 않는다. 고정 필드만 쓴다: 작업, 세대, 요청 ID, 자기 PID와 시작 시각.

    제출 성공은 검사 성공이 아니다. 결과는 kubectl logs에서 이 요청 ID로 회수한다(run.sh result).
    """
    job = args[0] if args else ""
    if job in CONTROL_JOBS:
        fifo, ackdir = "/c/ctl/in", "/c/ctl/ack"
        gen_src = "/c/boot/current"
    elif job in BODY_JOBS:
        fifo, ackdir = "/b/req", "/b/ack"
        gen_src = "/relay/current"
    else:
        print("submit: 모르는 작업", file=sys.stderr)
        return 2
    try:
        gen = open(gen_src).read().split()[0]
        start = stat_start(read_stat("self"))[1]
    except (OSError, IndexError, TypeError):
        print("submit: 세대나 자기 시작 시각을 읽지 못했다", file=sys.stderr)
        return 3
    req = os.urandom(6).hex()
    line = f"req1 {job} {gen} {req} {os.getpid()} {start}\n"
    try:
        print(f"사실 라벨 제출자(exec 계통) {label_word(read_label('self'))}")
    except OSError as e:
        print(f"사실 라벨 제출자(exec 계통) {errname(e.errno)}")
    try:
        st = os.lstat(fifo)
        if (st.st_mode & 0o170000) != 0o010000:
            raise OSError(errno.EINVAL, "not a fifo")
    except OSError as e:
        print(f"제출 실패: 요청 통로 {errname(e.errno)}")
        return 3
    t0 = time.monotonic()
    while True:
        try:
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            break
        except OSError as e:
            # ENXIO: 받는 쪽이 지금 FIFO를 열고 있지 않다(다른 단계가 도는 중이거나 루프 사이).
            if e.errno != errno.ENXIO or time.monotonic() - t0 > 5:
                print(f"제출 실패: 받는 쪽 없음 {errname(e.errno)} (다른 단계가 도는 중일 수 있다)")
                return 4
            time.sleep(0.1)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
    print(f"제출 req={req} gen={gen} job={job} pid={os.getpid()} start={start}", flush=True)
    t0 = time.monotonic()
    while time.monotonic() - t0 < ACK_WAIT_S:
        if os.path.exists(os.path.join(ackdir, req)):
            print("인수 확인. 이 제출자가 끝난 뒤 검사가 돈다. 결과는 run.sh result로 회수한다")
            return 0
        time.sleep(0.05)
    print("인수 확인 없음(거절·중복·바쁨일 수 있다. 컨테이너 로그의 reject 줄을 본다)")
    return 5


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
    "tryop": cmd_tryop,
    "tcpscan": cmd_tcpscan,
    "scan": cmd_scan,
    "sanitize": cmd_sanitize,
    "sha": cmd_sha,
    "submit": cmd_submit,
    "accept": cmd_accept,
    "gate": cmd_gate,
    "publish": cmd_publish,
    "body-job": cmd_body_job,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("o25.py: 모르는 이름", file=sys.stderr)
        sys.exit(2)
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]) or 0)
