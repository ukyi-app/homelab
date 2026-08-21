#!/usr/bin/env python3
# Telegram sendMessage mock — AM이 보낸 POST 본문을 디코드해 인자 파일에 기록하고 200(ok:true)을 반환한다.
# ⚠️ AM telegram sender는 sendMessage를 application/x-www-form-urlencoded로 보낼 수 있어 raw 본문엔
#    <b>/이모지가 percent-encoded다(교차검증 Pass4 Finding 3). content-type을 보고 form이면 parse_qs,
#    json이면 json.loads로 디코드해 분리 기록한다(parse_mode=...\ntext=<디코드된 본문>).
#
# 사용: python3 tests/gates/mock-telegram.py <출력파일> <포트>
#       기동 완료 시 stderr에 "mock-telegram: listening on <port>"를 쓴다(호출자가 이 줄을 기다린다).
# ⚠️ 이 readiness 줄이 **계약이다.** 이 mock은 호출자가 `&`로 띄우므로 `set -euo pipefail`이 종료코드를
#    보지 않는다 — 바인드가 EADDRINUSE로 실패해도 하네스는 그냥 진행하고, 30초 뒤 "no telegram capture
#    within timeout"으로 죽어 **진단이 포트가 아니라 메시지 템플릿을 가리킨다**(실측 2026-08-21).
#    형제 tests/gates/tcp-blackhole-sink.py가 같은 이유로 같은 줄을 갖고 있다.
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

# ⚠️ argc 가드 — 인자가 모자라면 IndexError 트레이스백이 background job의 stderr로만 나가고 호출자는
#    그걸 못 본다(형제 sink와 같은 처방).
if len(sys.argv) != 3:
    sys.stderr.write("usage: mock-telegram.py <out-file> <port>\n")
    sys.exit(2)

OUT = sys.argv[1]
PORT = int(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0) or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        ctype = self.headers.get("content-type", "") or ""
        text, parse_mode = "", ""
        if "application/json" in ctype:
            d = json.loads(raw) if raw else {}
            text = d.get("text", "")
            parse_mode = d.get("parse_mode", "")
        else:  # form-urlencoded (telegram bot api 기본)
            q = parse_qs(raw, keep_blank_values=True)
            text = (q.get("text") or [""])[0]
            parse_mode = (q.get("parse_mode") or [""])[0]
        with open(OUT, "w") as f:
            f.write("parse_mode=%s\ntext=%s" % (parse_mode, text))
        # ⚠️ AM v0.27 telegram notifier(tgbotapi)는 응답을 Message로 언마샬한다 — result.chat/date/message_id가
        #    없으면 nil 역참조로 panic해 AM 프로세스가 죽는다(검증됨). 완전한 sendMessage 성공 응답을 모방한다.
        body = json.dumps({
            "ok": True,
            "result": {
                "message_id": 1,
                "date": 1700000000,
                "chat": {"id": -1001234567890, "type": "channel", "title": "mock"},
                "text": text or "ok",
            },
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # 조용히
        pass


if __name__ == "__main__":
    # 컨테이너가 host-gateway로 붙으므로 루프백 전용 바인드는 불가능하다(0.0.0.0 필수).
    srv = HTTPServer(("0.0.0.0", PORT), Handler)
    sys.stderr.write("mock-telegram: listening on %d\n" % PORT)
    sys.stderr.flush()
    srv.serve_forever()
