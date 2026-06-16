#!/usr/bin/env python3
# Telegram sendMessage mock — AM이 보낸 POST 본문을 디코드해 인자 파일에 기록하고 200(ok:true)을 반환한다.
# ⚠️ AM telegram sender는 sendMessage를 application/x-www-form-urlencoded로 보낼 수 있어 raw 본문엔
#    <b>/이모지가 percent-encoded다(교차검증 Pass4 Finding 3). content-type을 보고 form이면 parse_qs,
#    json이면 json.loads로 디코드해 분리 기록한다(parse_mode=...\ntext=<디코드된 본문>).
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

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
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
