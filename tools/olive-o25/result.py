#!/usr/bin/env python3
"""요청 결과의 회수. 쓰는 법: result.py <파드 UID> <세대> <요청 ID> <작업>  (표준 입력: kubectl logs 출력)

컨테이너 로그에서 이 파드·세대·요청 ID의 묶음(begin … end)을 하나 찾는다. 완료는 다음이 모두 맞을 때뿐이다.
- begin·end가 한 번씩, 그 사이 판정 줄 수가 end의 n과 같다.
- 이 작업의 필수 키가 한 번씩 모두 있고, 판정 낱말이 됨·안 됨·판단 필요 중 하나다.
- 같은 요청 ID의 묶음이 둘 이상이 아니다(본체 쪽은 같은 uid의 본체 프로그램이 로그 줄을 흉내 낼 수 있다).
아니면 미완료이고 필수 키를 모두 "판단 필요"로 찍는다. 종료 코드 0은 완료(판정은 결과 줄로 본다), 1은 미완료.

찍는 것은 잡은 필드로 새로 만든 줄뿐이다. 로그 원문을 옮기지 않는다.
"""
import re
import sys

# 파드 쪽(platform/olive-o25/files/o25.py)의 같은 표와 함께 바꾼다.
JOB_KEYS = {
    "cred": ["6.hc-상태-없음", "6.제어-argv-environ-없음", "6.제어-로그-장부-없음", "6.중계-폴더-없음", "6.hc-화면-없음"],
    "body-cred": ["6.본체-프로세스에-있음", "6.본체-쪽-파일-argv-없음"],
    "body-hide": ["5.body.hc-socket", "5.body.hc-ls", "5.body.state", "5.body.proc", "5.body.netns", "5.body.relay-dir"],
}
CODES = frozenset((
    "no-mark", "scan-failed", "not-delivered", "unreadable", "hit", "clean", "no-state-files", "no-procs",
    "screen-unread", "screen-hit", "screen-clean",
    "submitter-unseen", "submitter-alive", "submitter-unread", "job-failed",
    "program-unknown", "env-open-failed", "absent", "sha-mismatch", "present", "program-changed", "not-checked",
))
BODY_JOBS = ("body-cred", "body-hide")
# 묶음 안 줄의 종류별 모양. 파드 쪽 publish_lines가 내는 모양 그대로이고, 하나라도 어긋나면 그 묶음은 미완료다.
# 표식 모양 글이 섞일 수 있는 자유 글자 필드는 라벨 하나뿐이다(아래 MARK_SEEN으로 한 번 더 닫는다).
ERRNO = r"(?:E[A-Z0-9]{1,15}|\d{1,5})"
ROOT = r"(?:hc-state|ctl-record|relay|body|other)"
LINE_RX = {
    "begin": re.compile(r"begin job=([a-z-]{1,16}) run=(\d{1,20})"),
    "verdict": re.compile(r"결과 ([0-9a-z.가-힣-]{1,60}) (됨|안 됨|판단 필요) code=([a-z0-9-]{1,40}) why=([0-9a-f]{16})"),
    "gate": re.compile(r"gate state=(gone|undecided) code=(gone|reused|submitter-unseen|submitter-alive|submitter-unread) "
                       r"pid=\d{1,10} start=\d{1,20} waited_ms=\d{1,10}"),
    "fact": re.compile(r"fact (?:(?:sig0|ack)=(?:OK|E[A-Z0-9]{1,15})|(?:label-self|label-submitter)="
                       r"(?:[A-Za-z0-9._/&()+:-]{1,80}|h:[0-9a-f]{16})|(?:cred-sha|body-sha)=[0-9a-f]{16})"),
    "scan": re.compile(r"scan files=\d{1,10} procs=\d{1,10} gone=\d{1,10} unreadable=\d{1,10} self=\d{1,10}"),
    "unread": re.compile(rf"unread kind=(?:(?:cmdline|environ) pid=\d{{1,10}}|(?:file|dir) root={ROOT} h=[0-9a-f]{{16}}) "
                         rf"errno={ERRNO}"),
    "hit": re.compile(rf"hit kind=(?:file root={ROOT} h=[0-9a-f]{{16}}|(?:argv|environ) pid=\d{{1,10}} who=(?:executor|proc))"),
    "job": re.compile(r"job state=(done|timeout|failed) rc=-?\d{1,4}"),
    "end": re.compile(r"end n=(\d{1,4}) dropped=(\d{1,6})"),
}
# re.A: \d가 ASCII 숫자만 받게 한다(기본은 모든 유니코드 숫자를 받는다).
LINE_RX = {k: re.compile(rx.pattern, re.A) for k, rx in LINE_RX.items()}
MARK_SEEN = "o25fake"


def collect(text, pod, gen, req, job):
    """(상태 "complete"|"incomplete", 이유 코드, 찍을 줄 목록).

    줄은 LF로만 나눈다(U+2028 등에서 나누면 한 줄 안에 숨긴 글이 따로 선 줄이 된다). 묶음은 begin으로 시작해 end로 끝나야 하고,
    이 요청의 줄이 그 밖에 있으면 미완료다. 문지기 줄은 판정 줄보다 앞에 한 번, 소멸을 확인하지 못했으면(undecided) 판정은
    모두 판단 필요여야 한다. 본체 작업은 소멸 확인 뒤 job state=done 줄이 한 번 있어야 한다.
    """
    head = f"o25r {pod} {gen} {req} "
    keys = JOB_KEYS.get(job)
    if keys is None:
        return "incomplete", "bad-job", []
    rows, verdicts, end_n, phase, bad = [], {}, None, "before", None
    gates, jobs = [], []
    found = False
    for raw in text.split("\n"):
        if not raw.startswith(head):
            continue
        found = True
        rest = raw[len(head):]
        kind = next((k for k, rx in LINE_RX.items() if rx.fullmatch(rest)), None)
        if kind is None or MARK_SEEN in rest:
            # 원문을 찍지 않는다. 모양이 어긋난 줄이 있었다는 사실만 남는다.
            bad = bad or ("mark-seen" if kind is not None else "bad-line")
            continue
        m = LINE_RX[kind].fullmatch(rest)
        if kind == "begin":
            if phase != "before":
                bad = bad or "dup-block"
            elif m[1] != job:
                bad = bad or "bad-line"
            phase = "in" if phase == "before" else phase
        elif phase != "in":
            bad = bad or ("dup-block" if kind == "end" and phase == "after" else "out-of-block")
        if kind == "end" and phase == "in":
            phase, end_n = "after", int(m[1])
        elif kind == "gate":
            gates.append(m[1])
        elif kind == "job":
            jobs.append(m[1])
        elif kind == "verdict":
            if m[1] not in keys or (m[3] != "-" and m[3] not in CODES) or m[1] in verdicts:
                bad = bad or "bad-line"
                continue
            if len(gates) != 1:
                bad = bad or "verdict-before-gate"
            elif gates[0] != "gone" and m[2] != "판단 필요":
                bad = bad or "undecided-gate-verdict"
            verdicts[m[1]] = m[2]
            rows.append(f"결과 {m[1]} {m[2]} code={m[3]} why={m[4]}")
            continue
        rows.append(rest)
    if not found:
        return "incomplete", "not-found", rows
    if bad:
        return "incomplete", bad, rows
    if phase == "before":
        return "incomplete", "no-begin", rows
    if end_n is None:
        return "incomplete", "no-end", rows
    if len(gates) != 1:
        return "incomplete", "no-gate" if not gates else "dup-gate", rows
    if job in BODY_JOBS and gates[0] == "gone" and jobs != ["done"]:
        return "incomplete", "job-not-done", rows
    if [k for k in keys if k not in verdicts]:
        return "incomplete", "missing-key", rows
    if end_n != len(verdicts):
        return "incomplete", "count-mismatch", rows
    return "complete", "ok", rows


def main(argv):
    if len(argv) != 5 or not re.fullmatch(r"[0-9a-f-]{1,64}", argv[1]) or not re.fullmatch(r"[0-9a-f]{12}", argv[2]) \
            or not re.fullmatch(r"[0-9a-f]{12}", argv[3]) or argv[4] not in JOB_KEYS:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    state, code, rows = collect(text, argv[1], argv[2], argv[3], argv[4])
    for r in rows:
        print(f"  {r}")
    if state == "complete":
        print(f"회수 완료 req={argv[3]} job={argv[4]}")
        return 0
    print(f"회수 미완료 req={argv[3]} job={argv[4]} 이유={code}")
    for k in JOB_KEYS[argv[4]]:
        print(f"결과 {k} 판단 필요 — 회수 미완료({code})")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
