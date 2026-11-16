#!/usr/bin/env python3
"""O25 claude 변형의 완료 조건 (4) 판정. 쓰는 법:
  claude-judge.py <파드 UID> <세대> <핀 sha256> <핀 버전> <claude-ui 결과 파일> <본체 로그 파일>

두 독립 출처를 묶는다. 어느 하나만으로 "됨"을 내지 않는다.
  제어 쪽 claude-ui 결과(run.sh show claude-ui): 키를 보낸 시각·종료 코드, 그 뒤 읽은 화면의 해시·비어 있지 않은 줄 수.
  본체 PID 1의 로그(o25c 줄): 자격 전 고정 파일 대조, pty 자식의 실행 파일 대조·시작 크기, 프로그램 종료 상태와 시각.
두 쪽 시각은 같은 노드의 CLOCK_REALTIME(ns)이다.
화면 문구는 판정에 쓰지 않는다(버전마다 바뀐다). 볼 대상이 없거나 읽지 못하면 "판단 필요"다.
완료 조건 (4)는 아래 다섯 줄(화면-표식-없음 제외)이 모두 "됨"일 때만 닫힌다.
"""
import re
import sys

KEYS = ("2.claude.첫-화면", "2.claude.입력-반영", "2.claude.Ctrl-C", "2.claude.끝내기", "2.claude.고정-50x200")
MARK_KEY = "2.claude.화면-표식-없음"
UI_RE = re.compile(r"claude-ui (first|idle|down|ctrlc|exit) t_ns=([0-9]+) rc=([0-9]+) t_read_ns=([0-9]+) read_rc=([0-9]+) "
                   r"h=([0-9a-f]{16}) nonblank=([0-9]+) maxw=([0-9]+)")
MARK_RE = re.compile(r"결과 2\.claude\.화면-표식-없음 (됨|안 됨|판단 필요) — .*\(이유 ([a-z-]+)\)$")
# 판정에 쓰는 o25c 줄은 이 모양뿐이다(본체 PID 1의 prog_line). 본체는 같은 표준 출력에 쓸 수 있으므로 보조 증거이고,
# 같은 종류가 두 번 나오면 고르지 않고 판단 필요로 닫는다.
O25C_RE = re.compile(r"o25c (\S+) ([0-9a-f]{12}) (prog-check|prog-launch|prog-exit)((?: [a-z_]+=[A-Za-z0-9._:?-]*)+)$")
SLACK_NS = 30 * 10**9


def parse_ui(text):
    ui, mark = {}, None
    for line in text.splitlines():
        line = line.strip()
        m = UI_RE.fullmatch(line)
        if m:
            if m.group(1) in ui:
                ui[m.group(1)] = "dup"
            else:
                ui[m.group(1)] = {"t": int(m.group(2)), "rc": int(m.group(3)), "tr": int(m.group(4)),
                                  "rr": int(m.group(5)), "h": m.group(6), "nb": int(m.group(7)), "w": int(m.group(8))}
        m = MARK_RE.fullmatch(line)
        if m:
            mark = "dup" if mark else (m.group(1), m.group(2))
    return ui, mark


def parse_body(text, pod, gen):
    out = {}
    for line in text.splitlines():
        m = O25C_RE.fullmatch(line.strip())
        if not m or m.group(1) != pod or m.group(2) != gen:
            continue
        kv = dict(p.split("=", 1) for p in m.group(4).split())
        out[m.group(3)] = "dup" if m.group(3) in out else kv
    return out


def judge(pod, gen, pin_sha, pin_ver, ui_text, body_text):
    ui, mark = parse_ui(ui_text)
    body = parse_body(body_text, pod, gen)
    res = {}

    def put(k, v, code, why):
        res[k] = (v, code, why)

    chk, lau, ext = body.get("prog-check"), body.get("prog-launch"), body.get("prog-exit")
    if "dup" in (chk, lau, ext) or "dup" in ui.values():
        for k in KEYS:
            put(k, "판단 필요", "dup-evidence", "같은 종류의 증거 줄이 두 번 있다(어느 것이 이 실행인지 모른다)")
        return finish(res, mark)
    exit_t = int(ext["t_ns"]) if ext and ext.get("t_ns", "").isdigit() else None

    def alive_until(t):
        return exit_t is None or exit_t > t

    first = ui.get("first")
    # 1. 첫 화면
    if not chk:
        put(KEYS[0], "판단 필요", "no-prog-check", "본체 PID 1의 자격 전 대조 줄이 없다")
    elif chk.get("check") != "ok" or chk.get("sha") != pin_sha or chk.get("version") != pin_ver:
        put(KEYS[0], "안 됨", "prog-mismatch", f"고정 파일 대조 {chk.get('check')}, 버전 {chk.get('version')}")
    elif not lau:
        put(KEYS[0], "판단 필요", "no-launch", "본체 PID 1이 프로그램을 띄운 줄이 없다")
    elif lau.get("exe") != "match":
        bad = lau.get("exe", "-")
        put(KEYS[0], "안 됨" if bad == "mismatch" else "판단 필요", "exe-" + ("mismatch" if bad == "mismatch" else "unread"),
            f"pty 자식의 실행 파일 대조: {bad}")
    elif not first or first["rr"] != 0 or first["nb"] < 3:
        put(KEYS[0], "판단 필요", "screen-empty", "hc 화면이 비어 있거나 읽지 못했다")
    elif not alive_until(first["tr"]):
        put(KEYS[0], "안 됨", "program-dead", "첫 화면을 읽기 전에 프로그램이 끝났다")
    else:
        put(KEYS[0], "됨", "first-screen",
            f"버전 {chk['version']}·sha 핀 일치, pty 자식 exe가 그 파일(pid {lau.get('pid')}), 화면 {first['nb']}줄, 읽을 때 살아 있음")
    ok1 = res[KEYS[0]][0] == "됨"

    # 2. 입력 반영
    idle, down = ui.get("idle"), ui.get("down")
    if not ok1:
        put(KEYS[1], "판단 필요", "prereq", "첫 화면이 됨이 아니다")
    elif not idle or not down or idle["rr"] or down["rr"]:
        put(KEYS[1], "판단 필요", "screen-unread", "키 전후 화면이 없다")
    elif down["rc"] != 0:
        put(KEYS[1], "판단 필요", "key-send-failed", f"hc keys 종료 {down['rc']}")
    elif idle["h"] != first["h"]:
        put(KEYS[1], "판단 필요", "screen-unstable", "손대지 않은 4초 사이에도 화면이 바뀌었다(키 전후 비교를 믿지 못한다)")
    elif not alive_until(down["tr"]):
        put(KEYS[1], "안 됨", "program-dead", "키 뒤 화면을 읽기 전에 프로그램이 끝났다")
    elif down["h"] == idle["h"]:
        put(KEYS[1], "안 됨", "no-change", "아래 화살표 뒤 화면이 그대로다")
    else:
        put(KEYS[1], "됨", "changed", "멈춰 있던 화면이 아래 화살표 뒤에만 바뀌었고 프로그램이 살아 있다")

    # 3. Ctrl-C
    cc, ex = ui.get("ctrlc"), ui.get("exit")
    if not ok1:
        put(KEYS[2], "판단 필요", "prereq", "첫 화면이 됨이 아니다")
    elif not cc or not down or cc["rr"] or down["rr"]:
        put(KEYS[2], "판단 필요", "screen-unread", "Ctrl-C 전후 화면이 없다")
    elif cc["rc"] != 0:
        put(KEYS[2], "판단 필요", "key-send-failed", f"hc keys 종료 {cc['rc']}")
    elif exit_t is not None and cc["t"] <= exit_t and (not ex or exit_t < ex["t"]):
        put(KEYS[2], "됨", "exited", "Ctrl-C 뒤 프로그램이 끝났다(끝내기는 새 세대에서 따로 잰다)")
    elif not alive_until(cc["t"]):
        put(KEYS[2], "판단 필요", "already-exited", "Ctrl-C 전에 프로그램이 끝나 있었다")
    elif cc["h"] != down["h"]:
        put(KEYS[2], "됨", "changed", "Ctrl-C 뒤 화면이 바뀌었고 프로그램이 살아 있다")
    else:
        put(KEYS[2], "안 됨", "no-change", "Ctrl-C 뒤 화면도 프로그램 상태도 그대로다")

    # 4. 끝내기
    if not ok1:
        put(KEYS[3], "판단 필요", "prereq", "첫 화면이 됨이 아니다")
    elif not ex:
        put(KEYS[3], "판단 필요", "not-run", "끝내기 키를 보낸 기록이 없다")
    elif res[KEYS[2]][1] == "exited":
        put(KEYS[3], "판단 필요", "exited-on-ctrlc", "Ctrl-C 한 번에 끝났다. 끝내기는 새 세대에서 잰다")
    elif ex["rc"] != 0:
        put(KEYS[3], "판단 필요", "key-send-failed", f"hc keys 종료 {ex['rc']}")
    elif exit_t is not None and exit_t < ex["t"]:
        put(KEYS[3], "판단 필요", "already-exited", "끝내기 키 전에 프로그램이 끝나 있었다")
    elif exit_t is None:
        put(KEYS[3], "안 됨", "not-exited", f"끝내기 키 뒤 {(ex['tr'] - ex['t']) // 10**9}초 동안 본체 PID 1이 종료를 보지 못했다")
    elif exit_t > ex["tr"] + SLACK_NS:
        put(KEYS[3], "판단 필요", "late-exit", "끝내기 키 한참 뒤에 끝났다")
    elif ext.get("status", "unknown") == "unknown":
        put(KEYS[3], "판단 필요", "status-unknown", "종료는 봤지만 상태를 받지 못했다")
    else:
        put(KEYS[3], "됨", "exited", f"끝내기 키 뒤 {(exit_t - ex['t']) // 10**6}ms에 끝났고 본체 PID 1이 {ext['status']}로 받았다")

    # 5. 고정 50x200
    if not lau:
        put(KEYS[4], "판단 필요", "no-launch", "본체 PID 1이 프로그램을 띄운 줄이 없다")
    elif lau.get("rows") == "50" and lau.get("cols") == "200" and lau.get("sync") == "before-exec":
        put(KEYS[4], "됨", "fixed-size", "exec 전에 pty 크기 50×200을 정하고 다시 읽어 확인했다(화면이 깨지지 않았는지는 사실 줄)")
    else:
        put(KEYS[4], "안 됨", "size-mismatch", f"pty {lau.get('rows')}×{lau.get('cols')} sync={lau.get('sync')}")
    return finish(res, mark, ui)


def finish(res, mark, ui=None):
    out = [f"결과 {k} {v} — {why} (이유 {code})" for k, (v, code, why) in ((k, res[k]) for k in KEYS)]
    if mark in (None, "dup"):
        out.append(f"결과 {MARK_KEY} 판단 필요 — claude-ui의 표식 판정 줄이 없거나 두 번이다 (이유 no-mark-line)")
    else:
        out.append(f"결과 {MARK_KEY} {mark[0]} — claude-ui 결과 그대로 (이유 {mark[1]})")
    if ui:
        w = [f"{n}={v['w']}" for n, v in ui.items() if isinstance(v, dict)]
        out.append(f"사실 hc 화면 줄 최대 바이트 {' '.join(w)}(상자 글자는 3바이트라 열 수가 아니다). 본체 pty는 50×200이고"
                   " hc 격자 크기는 claude-ui의 hc get 줄(rows·cols)")
    done = all(res[k][0] == "됨" for k in KEYS) and mark not in (None, "dup") and mark[0] == "됨"
    out.append(f"결과 4.claude.대화형 {'됨' if done else '판단 필요' if not any(res[k][0] == '안 됨' for k in KEYS) else '안 됨'}"
               f" — 위 다섯 줄과 표식 줄이 모두 됨일 때만 됨 (이유 {'all' if done else 'not-all'})")
    return out


def main(argv):
    if len(argv) != 7 or not re.fullmatch(r"[0-9a-f]{64}", argv[3]):
        print(__doc__.splitlines()[1], file=sys.stderr)
        return 2
    pod, gen, sha, ver = argv[1], argv[2], argv[3], argv[4]
    with open(argv[5], encoding="utf-8", errors="replace") as f:
        ui_text = f.read()
    with open(argv[6], encoding="utf-8", errors="replace") as f:
        body_text = f.read()
    for line in judge(pod, gen, sha, ver, ui_text, body_text):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
