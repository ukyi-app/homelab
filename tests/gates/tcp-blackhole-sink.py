#!/usr/bin/env python3
# TCP 블랙홀 sink — accept만 하고 바이트를 하나도 보내지 않고 닫지도 않는 소켓 서버.
#
# 용도: tests/gates/skopeo-timeout-smoke.sh가 핀된 skopeo 이미지의 `--command-timeout`이 **실제로 강제되는지**
#       증명하는 데 쓴다. 여기 붙으면 TCP 3-way handshake는 **성공**하고 그 다음 TLS ServerHello에서
#       **영원히 매달린다** → 네트워크 블랙홀(GHCR 장애·중간 방화벽 침묵 드롭)의 정확한 재현이다.
#
# ⚠️ 왜 "미라우팅 IP"가 아닌가: 브리지 서브넷의 미할당 IP는 ARP 미해결로 커널이 ~3초 뒤 EHOSTUNREACH를
#    반환한다(빠른 실패) → 타임아웃이 강제되는지 **증명하지 못한다**. 매달리는 sink만이 상한을 시험한다.
#
# 사용: python3 tests/gates/tcp-blackhole-sink.py <port>
#       기동 완료 시 stderr에 "sink: listening on <port>"를 쓴다(호출자가 이 줄을 기다린다).
import socket
import sys

if len(sys.argv) != 2:
    sys.stderr.write("usage: tcp-blackhole-sink.py <port>\n")
    sys.exit(2)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", int(sys.argv[1])))  # 컨테이너가 host-gateway로 붙는다 → 루프백 바인드 불가
srv.listen(16)
sys.stderr.write("sink: listening on %s\n" % sys.argv[1])
sys.stderr.flush()

conns = []  # 참조 유지 — GC가 소켓을 닫아 RST를 보내면 블랙홀이 아니게 된다
while True:
    c, _ = srv.accept()
    conns.append(c)  # accept만 하고 **읽지도 쓰지도 닫지도 않는다** → 상대는 TLS 핸드셰이크에서 매달린다
