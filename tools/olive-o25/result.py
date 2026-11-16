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
FIELD = r"[A-Za-z0-9._/&()+:=-]"
BODY = [
    re.compile(r"begin job=([a-z-]{1,16}) run=(\d{1,20})"),
    re.compile(r"결과 (\S{1,60}) (됨|안 됨|판단 필요) code=([a-z0-9-]{1,40}) why=([0-9a-f]{16})"),
    re.compile(rf"(gate|fact|scan|unread|hit|job) ({FIELD}{{1,120}}( {FIELD}{{1,120}}){{0,6}})"),
    re.compile(r"end n=(\d{1,4}) dropped=(\d{1,6})"),
]


def collect(text, pod, gen, req, job):
    """(상태 "complete"|"incomplete", 이유 코드, 찍을 줄 목록)."""
    head = f"o25r {pod} {gen} {req} "
    keys = JOB_KEYS.get(job)
    if keys is None:
        return "incomplete", "bad-job", []
    rows, verdicts, n_begin, n_end, end_n, bad = [], {}, 0, 0, None, False
    for raw in text.splitlines():
        if not raw.startswith(head):
            continue
        rest = raw[len(head):]
        if BODY[0].fullmatch(rest):
            m = BODY[0].fullmatch(rest)
            n_begin += 1
            if m[1] != job:
                bad = True
            rows.append(f"begin job={m[1]} run={m[2]}")
            continue
        m = BODY[1].fullmatch(rest)
        if m:
            if m[1] not in keys or (m[3] != "-" and m[3] not in CODES) or m[1] in verdicts:
                bad = True
                continue
            verdicts[m[1]] = m[2]
            rows.append(f"결과 {m[1]} {m[2]} code={m[3]} why={m[4]}")
            continue
        m = BODY[3].fullmatch(rest)
        if m:
            n_end += 1
            end_n = int(m[1])
            rows.append(f"end n={m[1]} dropped={m[2]}")
            continue
        m = BODY[2].fullmatch(rest)
        if m:
            rows.append(f"{m[1]} {m[2]}")
            continue
        if rest.startswith("결과 "):
            bad = True
    if n_begin == 0 and end_n is None:
        return "incomplete", "not-found", rows
    if n_begin > 1 or n_end > 1:
        return "incomplete", "dup-block", rows
    if end_n is None:
        return "incomplete", "no-end", rows
    if bad:
        return "incomplete", "bad-line", rows
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
