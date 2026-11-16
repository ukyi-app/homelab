#!/usr/bin/env python3
"""O25 claude 변형의 완료 조건 (4) 판정. 쓰는 법:
  claude-judge.py <파드 UID> <세대> <핀 sha256> <핀 버전> <claude-ui 결과 파일> <본체 로그 파일>

두 출처를 묶는다.
  제어 쪽 결과(run.sh show claude-ui, show claude-term): 키를 보낸 시각·종료 코드, 그 뒤 읽은 화면의 해시·비어 있지 않은 줄 수,
    종료 요청 뒤 제어 쪽 relay-serve가 본 중계 닫힘 시각.
  본체 PID 1의 로그(o25c 줄): 자격 전 고정 파일 대조, pty 자식의 실행 파일 대조·시작 크기, 종료 요청을 보낸 시각, 프로그램 종료
    상태와 시각.
두 쪽 시각은 같은 노드의 CLOCK_REALTIME(ns)이다. 본체 로그는 같은 uid의 본체 프로그램도 쓸 수 있는 보조 증거다.
고정-50x200 한 줄만은 제어 쪽에서 pty 크기를 볼 수단이 없어 본체 로그 하나(prog-launch)로 낸다. 나머지 "됨"은 제어 쪽 사실과 묶인다.
화면 문구는 판정에 쓰지 않는다(버전마다 바뀐다). 볼 대상이 없거나 읽지 못하면 "판단 필요"다.

끝내기는 두 줄이다. 끝내기-키는 앱이 끝내기 키(Ctrl-C 두 번)로 스스로 끝났는가, 종료-요청은 본체 PID 1이 자기 자식인 프로그램에
SIGTERM을 보냈을 때 상한 안에 끝났는가다. 완료 조건 (4)(4.claude.대화형)는 관리자 결정(2026-11-16)으로 끝내기-키 대신 종료-요청을
쓴다. 첫 실행 화면에서 끝내기 키로는 끝나지 않는 것이 알려진 앱 동작이라서이고, (4)의 "끝내기"를 한 부분 약하게 읽는 것이다.
끝내기-키 결과는 숨기지 않고 판정 줄과 사실 줄로 함께 낸다.
"""
import re
import sys

KEYS = ("2.claude.첫-화면", "2.claude.입력-반영", "2.claude.Ctrl-C", "2.claude.끝내기-키", "2.claude.종료-요청",
        "2.claude.고정-50x200")
EXIT_KEY, TERM_KEY = KEYS[3], KEYS[4]
# (4)의 묶음. 끝내기-키는 빠지고 종료-요청이 들어간다(관리자 결정 2026-11-16).
BUNDLE = tuple(k for k in KEYS if k != EXIT_KEY)
MARK_KEY = "2.claude.화면-표식-없음"
UI_RE = re.compile(r"claude-ui (first|idle|down|ctrlc|exit) t_ns=([0-9]+) rc=([0-9]+) t_read_ns=([0-9]+) read_rc=([0-9]+) "
                   r"h=([0-9a-f]{16}) nonblank=([0-9]+) maxw=([0-9]+)")
TERM_RE = re.compile(r"claude-term t_ns=([0-9]+) relay_closed_ns=([0-9]+) closed_n=([0-9]+)")
MARK_RE = re.compile(r"결과 2\.claude\.화면-표식-없음 (됨|안 됨|판단 필요) — .*\(이유 ([a-z-]+)\)$")
# 판정에 쓰는 o25c 줄은 이 모양뿐이다(본체 PID 1의 prog_line). 본체는 같은 표준 출력에 쓸 수 있으므로 보조 증거이고,
# 같은 종류가 두 번 나오면 고르지 않고 판단 필요로 닫는다.
O25C_RE = re.compile(r"o25c (\S+) ([0-9a-f]{12}) (prog-check|prog-launch|prog-term|prog-exit)((?: [a-z_]+=[A-Za-z0-9._:?-]*)+)$")
SLACK_NS = 30 * 10**9
# 종료 요청의 상한. 리허설 실측(R2-EXIT 실험 2a~2f·4c)은 SIGTERM·SIGHUP·pty 닫기 뒤 0.2~0.5초였다. 노드의 CPU 상한(500m)과
# 앱의 정리 시간을 넉넉히 보고 실측 최대의 열 배로 둔다. 넘으면 응하지 않은 것으로 본다(SIGKILL로 넘어가 됨을 만들지 않는다).
TERM_LIMIT_NS = 5 * 10**9
# 본체 PID 1은 종료 시각을 적은 뒤 중계 연결을 닫으므로, 제어 쪽 relay-serve가 본 닫힘은 본체 종료 시각보다 앞설 수 없다
# (같은 노드의 같은 시계). 앞선 닫힘은 다른 원인(제어 쪽 relay 끝, hc kill)이라 됨의 근거로 쓰지 않는다.
# 뒤쪽 허용 차이: 둘 사이에는 select 한 바퀴(1초)가 들어갈 수 있다.
CLOSE_SLACK_NS = 2 * 10**9
# SIGTERM에 응한 종료로 보는 상태. Claude Code는 SIGTERM에 핸들러가 있어 exit 143으로 끝났다(실측). 기본 처리면 signal:15다.
TERM_OK = ("exit:143", "signal:15")


def parse_ui(text):
    ui, mark = {}, None
    for line in text.splitlines():
        line = line.strip()
        m = TERM_RE.fullmatch(line)
        if m:
            ui["term"] = "dup" if "term" in ui else {"t": int(m.group(1)), "closed": int(m.group(2)), "n": int(m.group(3))}
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

    chk, lau, ext, pt = body.get("prog-check"), body.get("prog-launch"), body.get("prog-exit"), body.get("prog-term")
    if "dup" in (chk, lau, ext, pt) or "dup" in ui.values():
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
        # mismatch만 다른 파일을 실행한 증거다. not-yet(기한 안에 exec를 보지 못함)·gone·읽기 실패는 판단하지 않는다.
        bad = lau.get("exe", "-")
        code = {"mismatch": "exe-mismatch", "not-yet": "exe-not-yet"}.get(bad, "exe-unread")
        put(KEYS[0], "안 됨" if bad == "mismatch" else "판단 필요", code, f"pty 자식의 실행 파일 대조: {bad}")
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

    # 종료 요청(본체 PID 1의 prog-term 줄). 요청 뒤의 종료는 끝내기 키로 끝난 것이 아니다.
    sent = int(pt["t_ns"]) if pt and pt.get("t_ns", "").isdigit() else None
    status = ext.get("status", "unknown") if ext else "unknown"

    # 4. 끝내기-키: 키 뒤, 종료 요청 전에 정상 종료(exit:0)했을 때만 됨. 신호로 죽은 것은 앱이 스스로 끝낸 것이 아니다.
    if not ok1:
        put(EXIT_KEY, "판단 필요", "prereq", "첫 화면이 됨이 아니다")
    elif not ex:
        put(EXIT_KEY, "판단 필요", "not-run", "끝내기 키를 보낸 기록이 없다")
    elif res[KEYS[2]][1] == "exited":
        put(EXIT_KEY, "판단 필요", "exited-on-ctrlc", "Ctrl-C 한 번에 끝났다. 끝내기는 새 세대에서 잰다")
    elif ex["rc"] != 0:
        put(EXIT_KEY, "판단 필요", "key-send-failed", f"hc keys 종료 {ex['rc']}")
    elif exit_t is not None and exit_t < ex["t"]:
        put(EXIT_KEY, "판단 필요", "already-exited", "끝내기 키 전에 프로그램이 끝나 있었다")
    elif exit_t is None or (sent is not None and exit_t >= sent):
        until = "종료 요청까지" if sent is not None else f"{(ex['tr'] - ex['t']) // 10**9}초 동안"
        put(EXIT_KEY, "안 됨", "not-exited", f"끝내기 키 뒤 {until} 본체 PID 1이 종료를 보지 못했다")
    elif exit_t > ex["tr"] + SLACK_NS:
        put(EXIT_KEY, "판단 필요", "late-exit", "끝내기 키 한참 뒤에 끝났다")
    elif status == "unknown":
        put(EXIT_KEY, "판단 필요", "status-unknown", "종료는 봤지만 상태를 받지 못했다")
    elif status.startswith("signal:"):
        put(EXIT_KEY, "안 됨", "killed", f"끝내기 키 뒤 {status}로 죽었다(앱이 스스로 끝낸 것이 아니다)")
    elif status != "exit:0":
        put(EXIT_KEY, "판단 필요", "exit-nonzero", f"끝내기 키 뒤 {status}로 끝났다(정상 끝내기인지 모른다)")
    else:
        put(EXIT_KEY, "됨", "exited", f"끝내기 키 뒤 {(exit_t - ex['t']) // 10**6}ms에 exit:0으로 끝났다")

    # 5. 종료-요청: 끝내기 화면을 읽은 뒤 본체 PID 1이 SIGTERM을 보냈고, 상한 안에 SIGTERM 응답 상태로 끝났으며,
    #    제어 쪽 relay-serve가 그 무렵 본체 쪽 중계 닫힘을 봤을 때만 됨.
    term = ui.get("term")
    if not ok1:
        put(TERM_KEY, "판단 필요", "prereq", "첫 화면이 됨이 아니다")
    elif not pt:
        put(TERM_KEY, "판단 필요", "not-requested", "본체 PID 1의 종료 요청 줄이 없다(run.sh submit prog-term)")
    elif not term:
        put(TERM_KEY, "판단 필요", "no-control-fact", "제어 쪽 확인(claude-term)이 없다. 본체 로그만으로는 내지 않는다")
    elif pt.get("state") == "already-exited" or (exit_t is not None and sent is not None and exit_t < sent):
        put(TERM_KEY, "판단 필요", "already-exited", "종료 요청 전에 프로그램이 끝나 있었다(잴 대상이 없다)")
    elif pt.get("state") != "sent" or sent is None or pt.get("sig") != "15":
        put(TERM_KEY, "판단 필요", "not-sent", f"본체 PID 1이 신호를 보내지 못했다(state={pt.get('state')})")
    elif not ex or not ex["tr"] < sent < term["t"]:
        put(TERM_KEY, "판단 필요", "order", "요청이 끝내기 화면 읽기와 제어 쪽 확인 사이에 있지 않다")
    elif term["n"] > 1:
        put(TERM_KEY, "판단 필요", "relay-dup", f"제어 쪽 중계 닫힘 줄이 {term['n']}개다")
    elif exit_t is None:
        if term["n"] == 0:
            put(TERM_KEY, "안 됨", "no-exit", "SIGTERM 뒤 본체 PID 1이 종료를 보지 못했고 제어 쪽 중계도 열려 있다")
        else:
            put(TERM_KEY, "판단 필요", "relay-closed-no-exit", "제어 쪽은 중계 닫힘을 봤는데 본체 PID 1의 종료 줄이 없다")
    elif exit_t > sent + TERM_LIMIT_NS:
        put(TERM_KEY, "안 됨", "late-exit", f"SIGTERM 뒤 {(exit_t - sent) // 10**6}ms에 끝났다(상한 {TERM_LIMIT_NS // 10**9}초)")
    elif term["n"] == 0:
        put(TERM_KEY, "판단 필요", "relay-open", "본체 PID 1은 종료를 냈는데 제어 쪽 중계가 닫히지 않았다")
    elif not sent < term["closed"] <= term["t"] or not 0 <= term["closed"] - exit_t <= CLOSE_SLACK_NS:
        put(TERM_KEY, "판단 필요", "relay-mismatch", "제어 쪽 중계 닫힘이 본체의 종료 시각 뒤 2초 안이 아니다")
    elif status == "unknown":
        put(TERM_KEY, "판단 필요", "status-unknown", "종료는 봤지만 상태를 받지 못했다")
    elif status not in TERM_OK:
        put(TERM_KEY, "판단 필요", "other-status", f"SIGTERM 뒤 {status}로 끝났다(SIGTERM에 응한 상태인지 모른다)")
    else:
        put(TERM_KEY, "됨", "exited",
            f"SIGTERM 뒤 {(exit_t - sent) // 10**6}ms에 {status}로 끝났고 제어 쪽이 {(term['closed'] - sent) // 10**6}ms에 중계 닫힘을 봤다")

    # 6. 고정 50x200: 본체 로그 한 출처뿐이다(제어 쪽에서 pty 크기를 볼 수단이 없다).
    if not lau:
        put(KEYS[5], "판단 필요", "no-launch", "본체 PID 1이 프로그램을 띄운 줄이 없다")
    elif lau.get("rows") == "50" and lau.get("cols") == "200" and lau.get("sync") == "before-exec":
        put(KEYS[5], "됨", "fixed-size", "본체 PID 1의 로그만으로: exec 전에 pty 크기 50×200을 정하고 다시 읽어 확인했다"
            "(제어 쪽 증거 없음. 화면이 깨지지 않았는지는 사실 줄)")
    else:
        put(KEYS[5], "안 됨", "size-mismatch", f"pty {lau.get('rows')}×{lau.get('cols')} sync={lau.get('sync')}")
    return finish(res, mark, ui)


def exit_fact(res):
    v, code, why = res[EXIT_KEY]
    if v == "됨":
        return ("사실 앱의 끝내기 키로 끝났다(exit:0). 그래서 종료 요청을 잴 대상이 없었다. 관리자 결정(2026-11-16)으로 (4)는"
                " 2.claude.종료-요청으로 판정하므로 이 세대로는 (4)가 됨이 아니다. 사람이 본다")
    # "알려진 앱 동작"은 끝나지 않음(not-exited)에만 맞는 설명이다. 신호로 죽은 것(killed)은 OOM·충돌일 수 있다.
    if code == "not-exited":
        head = "앱의 끝내기 키로는 끝나지 않았다(첫 실행 화면의 알려진 앱 동작)"
    elif v == "안 됨":
        head = f"앱의 끝내기 키 결과는 안 됨이지만 알려진 앱 동작이 아니다({why}, 이유 {code}). OOMKilled·이벤트를 본다"
    else:
        head = f"앱의 끝내기 키 결과를 가리지 못했다(판단 필요, 이유 {code})"
    return (f"사실 {head}. 관리자 결정(2026-11-16)으로 (4)는 본체 PID 1의 종료 요청에 응하는지(2.claude.종료-요청)로"
            " 판정했다. (4)의 끝내기를 한 부분 약하게 읽은 것이다")


def finish(res, mark, ui=None):
    out = [f"결과 {k} {v} — {why} (이유 {code})" for k, (v, code, why) in ((k, res[k]) for k in KEYS)]
    if mark in (None, "dup"):
        out.append(f"결과 {MARK_KEY} 판단 필요 — claude-ui의 표식 판정 줄이 없거나 두 번이다 (이유 no-mark-line)")
    else:
        out.append(f"결과 {MARK_KEY} {mark[0]} — claude-ui 결과 그대로 (이유 {mark[1]})")
    if ui:
        w = [f"{n}={v['w']}" for n, v in ui.items() if isinstance(v, dict) and "w" in v]
        out.append(f"사실 hc 화면 줄 최대 바이트 {' '.join(w)}(상자 글자는 3바이트라 열 수가 아니다). 본체 pty는 50×200이고"
                   " hc 격자 크기는 claude-ui의 hc get 줄(rows·cols)")
    out.append(exit_fact(res))
    done = all(res[k][0] == "됨" for k in BUNDLE) and mark not in (None, "dup") and mark[0] == "됨"
    out.append(f"결과 4.claude.대화형 {'됨' if done else '판단 필요' if not any(res[k][0] == '안 됨' for k in BUNDLE) else '안 됨'}"
               f" — 끝내기-키를 뺀 다섯 줄(종료-요청 포함)과 표식 줄이 모두 됨일 때만 됨 (이유 {'all' if done else 'not-all'})")
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
