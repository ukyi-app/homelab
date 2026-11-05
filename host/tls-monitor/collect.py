#!/usr/bin/env python3
"""tailnet TLS 인증서 확인. homelab-tls-monitor.timer가 5분마다 돌린다.

tailscale status에서 tag:k8s 기기(Tailscale operator의 Ingress 프록시)를 찾아 실제로 내주는 인증서를 검증하고,
결과를 node-exporter textfile 형식으로 쓴다. 대상을 저장소에 적지 않아 tailnet UI가 늘어도 고칠 것이 없다.

표준 라이브러리만 쓴다. 호스트의 /usr/bin/python3로 돌고 설치할 것이 없다.
지표와 로그에 전체 이름과 주소를 넣지 않는다(tailnet 이름 비공개). tls_host는 이름의 첫 부분이고 Ingress의
spec.tls.hosts와 같은 값이다. 경보가 이 값으로 kube_ingress_tls와 잇는다.
"""
import argparse
import json
import os
import re
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import time

TAG = "tag:k8s"
# 지표 라벨에 그대로 들어간다. 벗어나면 파일 전체가 파싱 오류로 버려진다.
HOST_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


def targets(status_cmd):
    """(tls_host, 전체 이름, 주소) 목록. 호스트 이름이 아니라 DNSName의 첫 부분을 쓴다. tailnet 안에서 유일해 라벨이 겹치지 않는다."""
    out = subprocess.run(shlex.split(status_cmd), capture_output=True, text=True, timeout=30, check=True).stdout
    found = []
    for peer in (json.loads(out).get("Peer") or {}).values():
        if TAG not in (peer.get("Tags") or []):
            continue
        fqdn = (peer.get("DNSName") or "").rstrip(".")
        addrs = peer.get("TailscaleIPs") or []
        host = fqdn.split(".")[0]
        if not fqdn or not addrs or not HOST_LABEL.match(host):
            raise ValueError("peer 형식이 기대와 다르다")
        found.append((host, fqdn, addrs[0]))
    return sorted(found)


def not_after(addr, fqdn, port, timeout, context):
    """주소로 붙고 전체 이름으로 검증한다. NUC는 accept-dns=false라 이름을 풀지 않는다. 검증에 실패하면 예외다."""
    with socket.create_connection((addr, port), timeout=timeout) as raw:
        with context.wrap_socket(raw, server_hostname=fqdn) as tls:
            return int(ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"]))


def reason(error):
    """로그 줄. 예외 메시지에는 전체 이름이 들어갈 수 있어 종류와 코드만 남긴다."""
    code = getattr(error, "verify_code", None)
    return type(error).__name__ + (f"({code})" if code is not None else "")


def render(results, collected, now):
    lines = []
    for name, kind, value in (
        ("homelab_tailnet_tls_probe_success", "1이면 인증서 검증 통과", lambda r: 1 if r[1] is not None else 0),
        ("homelab_tailnet_tls_not_after_seconds", "인증서 만료 시각(검증 통과 때만)", lambda r: r[1]),
    ):
        rows = [(r[0], value(r)) for r in results if value(r) is not None]
        if rows:
            lines += [f"# HELP {name} {kind}", f"# TYPE {name} gauge"]
            lines += [f'{name}{{tls_host="{host}"}} {v}' for host, v in rows]
    lines += [
        "# HELP homelab_tailnet_tls_collect_success 1이면 대상 목록을 읽음",
        "# TYPE homelab_tailnet_tls_collect_success gauge",
        f"homelab_tailnet_tls_collect_success {1 if collected else 0}",
        "# HELP homelab_tailnet_tls_collect_timestamp_seconds 마지막 실행 시각",
        "# TYPE homelab_tailnet_tls_collect_timestamp_seconds gauge",
        f"homelab_tailnet_tls_collect_timestamp_seconds {now}",
    ]
    return "\n".join(lines) + "\n"


def write_atomic(path, text):
    """node-exporter가 쓰는 중인 파일을 읽지 않게 같은 디렉터리에서 바꿔 넣는다. node-exporter는 다른 uid라 0644다."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tailnet_tls.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--status-cmd", default="/usr/bin/tailscale status --json")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--cafile")
    args = parser.parse_args()

    context = ssl.create_default_context(cafile=args.cafile)
    results = []
    collected = True
    try:
        found = targets(args.status_cmd)
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError) as error:
        print(f"대상 목록을 못 읽었다: {reason(error)}", file=sys.stderr)
        collected = False
        found = []
    for host, fqdn, addr in found:
        try:
            results.append((host, not_after(addr, fqdn, args.port, args.timeout, context)))
        except (OSError, ValueError, KeyError) as error:
            print(f"{host}: {reason(error)}", file=sys.stderr)
            results.append((host, None))
    # 실패도 파일에 남긴다. 성공만 쓰면 옛 값이 그대로 남아 경보가 조용해진다.
    # 파일을 못 쓰면 예외로 끝나 유닛이 failed가 되고 NodeSystemdUnitFailed가 본다.
    write_atomic(args.out, render(results, collected, int(time.time())))


if __name__ == "__main__":
    main()
