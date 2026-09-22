#!/usr/bin/env python3
"""AIOPS-FIREWALL-VERSIONED-SOURCE-0922 — AIOps ingress 21980 nft 방화벽 helper(독립 모듈).

reviewed root helper(`ingress_provision.py`, AIOPS-INGRESS-PROVISION-0922)에서 **방화벽 관련 함수만**
추출한 표준라이브러리 모듈이다. 토큰 발급·봉인(kubeseal)·설정 읽기·report 상태기계는 들어 있지 않다.

적용 판정(원본 의미 유지, fail-closed):
  - 일치 → no-op: nft 조회 2회(list tables/list table), 쓰기 0회(문법검사·적용 호출 없음).
  - 부재 → 설치 파일==렌더 확인 → `nft -c`(문법검사 1회) → `nft -f`(쓰기 1회) → 사후 재대조 ==match.
  - 표류·조회 실패·조회 불일치·파일 표류 → 중단(덮어쓰기·flush·delete 금지).

binary와 명령 파일은 검증한 nofollow FD에 결속한다 — argv[0]=`/proc/self/fd/<fd>`,
`-f /proc/self/fd/<file_fd>`, 같은 FD를 pass_fds로 넘긴다. 검사–실행 사이 경로를 교체해도
실행·적용 바이트는 검증한 inode 그대로다.

CLI(고정 — fixture 예외 옵션 없음):
  render  비-root 가능 — nft/unit/drop-in을 stdout JSON으로 렌더(파일 미기록)
  verify  root 전용 — 읽기 전용, 라이브 table ==reviewed 렌더(match) 필수
  apply   root 전용 — /usr/sbin/nft + /etc/nftables.d/homelab-aiops.nft 고정

설치 경로(호출자 몫): /usr/local/libexec/homelab-aiops-ingress-firewall.py (root:root 0644).
"""

from __future__ import annotations

import argparse
import errno
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys

__all__ = [
    "FirewallError",
    "ProvisionError",
    "ROOT_REQUIRED",
    "apply_nft",
    "check_nft",
    "main",
    "render_nft",
    "run_apply_nft",
    "run_render",
    "run_verify_nft",
]

# ── 고정 계약 ────────────────────────────────────────────────────────────────
NFT_TABLE = "homelab_aiops"
NFT_PORT = 21980
NFT_PRIORITY = -5
NFT_FILE = "/etc/nftables.d/homelab-aiops.nft"
NFT_UNIT = "/etc/systemd/system/homelab-aiops-nft.service"
NFT_UNIT_NAME = "homelab-aiops-nft.service"
NFT_BINARY = "/usr/sbin/nft"
NFTABLES_UNIT = "nftables.service"
INGRESS_UNIT = "aiops-ingress.service"
INGRESS_DROP_IN = "/etc/systemd/system/aiops-ingress.service.d/homelab-aiops-nft.conf"
HELPER_INSTALL_PATH = "/usr/local/libexec/homelab-aiops-ingress-firewall.py"
PYTHON_BINARY = "/usr/bin/python3"
INGRESS_ADDRESS = "192.168.117.15"
POD_CIDR = "10.42.0.0/24"
LOOPBACK = "127.0.0.1"
NFT_ENV = {"PATH": "/usr/sbin:/usr/bin:/bin", "LANG": "C.UTF-8"}
NFT_TIMEOUT = 60
ROOT_REQUIRED = "ingress-firewall-root-required"
LISTED_TABLE_RE = re.compile(r"table\s+(\w+)\s+([A-Za-z0-9_.:-]+)")


class FirewallError(Exception):
    """비밀값 없는 오류 코드. detail은 규칙·경로 같은 비밀이 아닌 식별자만 담는다."""

    def __init__(self, code: str, detail: str | None = None):
        super().__init__(code)
        self.code = code
        self.detail = detail


ProvisionError = FirewallError  # 원본 helper 호출자 호환 alias


def get_euid() -> int:
    return os.geteuid()


def _require_root() -> None:
    if get_euid() != 0:
        raise FirewallError(ROOT_REQUIRED)


def _trusted_uids() -> frozenset[int]:
    """운영(CLI는 euid 0 고정)에서는 {0}, fixture venue에서는 실행 uid도 신뢰한다.

    `_require_root`가 변이 CLI(verify/apply)를 봉인하므로 이 완화는 rooted fixture에서만 실효다.
    운영 우회 옵션/환경변수는 노출하지 않는다.
    """
    return frozenset({0, os.getuid()})


# ── FD 유틸 (nofollow·소유자·부모 검증 후 FD 결속) ───────────────────────────
def _absolute(path: str, code: str = "nft-path-invalid") -> str:
    if not isinstance(path, str) or not os.path.isabs(path):
        raise FirewallError(code)
    return path


def _open_verified_file(
    path: str,
    *,
    code: str,
    executable: bool = False,
    exec_code: str = "nft-not-executable",
) -> tuple[int, bytes, os.stat_result]:
    """경로를 FD로 열어 소유자·부모·모드·nofollow를 검증하고, 같은 FD로 바이트를 읽는다.

    반환한 FD를 실행(`/proc/self/fd`)과 `-f` 인자에 그대로 결속해 검사–사용 사이 경로 교체를
    무력화한다.
    """
    path = _absolute(path, code)
    if os.path.normpath(path) != path:
        raise FirewallError(code)
    parent = os.path.dirname(path) or "/"
    name = os.path.basename(path)
    if not name:
        raise FirewallError(code)
    try:
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        raise FirewallError(code)
    except NotADirectoryError:
        raise FirewallError(code)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise FirewallError(code)
        raise
    try:
        pinfo = os.fstat(parent_fd)
        if pinfo.st_uid not in _trusted_uids() or stat.S_IMODE(pinfo.st_mode) & 0o022:
            raise FirewallError(code, detail="parent")
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise FirewallError(code, detail="symlink")
            raise FirewallError(code)
    finally:
        os.close(parent_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise FirewallError(code)
        if before.st_uid not in _trusted_uids() or stat.S_IMODE(before.st_mode) & 0o022:
            raise FirewallError(code, detail="owner")
        if executable and not stat.S_IMODE(before.st_mode) & 0o111:
            raise FirewallError(exec_code)
        raw = bytearray()
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk
        after = os.fstat(fd)
        if (
            (before.st_ino, before.st_size, before.st_mtime_ns)
            != (after.st_ino, after.st_size, after.st_mtime_ns)
            or len(raw) != after.st_size
        ):
            raise FirewallError(code, detail="changed")
        return fd, bytes(raw), after
    except BaseException:
        os.close(fd)
        raise


# ── 렌더 (table + oneshot unit + ingress gate drop-in) ──────────────────────
def _nft_address(address: str) -> str:
    try:
        parsed = ipaddress.IPv4Address(address)
    except (TypeError, ValueError):
        raise FirewallError("nft-address-invalid")
    if not parsed.is_private or parsed.is_loopback or parsed.is_link_local or parsed.is_unspecified:
        raise FirewallError("nft-address-invalid")
    return str(parsed)


def _nft_pod_network(pod_cidr: str, address: str) -> ipaddress.IPv4Network:
    try:
        network = ipaddress.IPv4Network(pod_cidr, strict=True)
    except (TypeError, ValueError):
        raise FirewallError("nft-pod-cidr-invalid")
    if not network.is_private or network.is_loopback or network.num_addresses < 2:
        raise FirewallError("nft-pod-cidr-invalid")
    if not 16 <= network.prefixlen <= 30:
        raise FirewallError("nft-pod-cidr-invalid")
    if ipaddress.IPv4Address(address) in network or ipaddress.IPv4Address(LOOPBACK) in network:
        raise FirewallError("nft-pod-cidr-invalid")
    return network


def render_nft(address: str = INGRESS_ADDRESS, pod_cidr: str = POD_CIDR) -> dict[str, str]:
    address = _nft_address(address)
    network = _nft_pod_network(pod_cidr, address)
    allowed = f"{LOOPBACK}, {address}, {network}"
    nft = (
        "# homelab-aiops 21980 인입 전용 — helper 렌더 산출물. 수동 편집 금지.\n"
        "# 기존 k3s/tailscale 등의 table은 건드리지 않는다.\n"
        "table inet homelab_aiops {\n"
        "  chain input {\n"
        f"    type filter hook input priority {NFT_PRIORITY}; policy accept;\n"
        f"    ip saddr {{ {allowed} }} tcp dport {NFT_PORT} accept\n"
        f"    tcp dport {NFT_PORT} drop\n"
        "  }\n"
        "}\n"
    )
    # nftables.service는 After만 — Requires로 끌어오면 기존 table flush 위험이 있다.
    # network-pre/network.target 선행을 두지 않는다(조기부팅 ordering cycle 회피) — ingress
    # gate는 drop-in의 Requires+After가 담당한다(단순 Before는 방화벽 실패를 전파하지 못한다).
    service = (
        "[Unit]\n"
        "Description=Homelab AIOps 21980 ingress nftables rules\n"
        f"After={NFTABLES_UNIT}\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "RemainAfterExit=yes\n"
        f"ExecStart={PYTHON_BINARY} {HELPER_INSTALL_PATH} apply\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    ingress_drop_in = (
        "# aiops-ingress.service drop-in — 방화벽 실패 시 ingress 기동을 막는 gate.\n"
        "# 단순 Before와 달리 Requires가 실패를 전파한다. ingress unit 본문은 건드리지 않는다.\n"
        "[Unit]\n"
        f"Requires={NFT_UNIT_NAME}\n"
        f"After={NFT_UNIT_NAME}\n"
    )
    return {
        "nft": nft,
        "service": service,
        "ingressDropIn": ingress_drop_in,
        "allowed": allowed,
        "address": address,
        "podCidr": str(network),
        "ingressDropInPath": INGRESS_DROP_IN,
    }


def _extract_block(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text)
    if match is None:
        return None
    start = text.find("{", match.start())
    depth = 0
    for position in range(start, len(text)):
        char = text[position]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:position]
    raise FirewallError("nft-live-invalid")


def check_nft(text: str, address: str = INGRESS_ADDRESS, pod_cidr: str = POD_CIDR) -> str:
    """라이브 ruleset 텍스트와 reviewed 렌더를 정확 등식 대조한다. 부재 → absent, 일치 → match.

    AIOps table은 내용 전체를 소비한다 — 단일 `chain input` + header + rule 2줄 외의
    chain/set/rule/주석/요소가 하나라도 있으면 drift다. 다른 이름의 table은 건드리지 않는다.
    정당 정규화는 priority 표기('filter - 5'/'filter -5'/'-5')와 주소 순서뿐이고,
    주소는 값 집합이 reviewed 3개와 정확히 같아야 한다(중복·누락·추가·오프셋 network 거부).
    """
    address = _nft_address(address)
    network = _nft_pod_network(pod_cidr, address)
    forms = re.findall(r"table\s+(\w+)\s+homelab_aiops\s*\{", text)
    if not forms:
        return "absent"
    if forms != ["inet"]:
        raise FirewallError("nft-drift", detail="table-form")
    table = _extract_block(text, r"table\s+inet\s+homelab_aiops\s*\{")
    if table is None:
        raise FirewallError("nft-drift", detail="table-form")
    # reviewed 5줄(chain open/header/rule 2줄/chain close)만 소비한다 — 그 밖의 내용은 drift다.
    lines = [line.strip() for line in table.splitlines() if line.strip()]
    if len(lines) != 5:
        raise FirewallError("nft-drift", detail="table-content")
    if lines[0] != "chain input {":
        raise FirewallError("nft-drift", detail="chain-form")
    if lines[4] != "}":
        raise FirewallError("nft-drift", detail="table-content")
    header = re.fullmatch(
        r"type\s+filter\s+hook\s+input\s+priority\s+([^;]+);\s*policy\s+(accept|drop);",
        lines[1],
    )
    if header is None or header.group(2) != "accept":
        raise FirewallError("nft-drift", detail="chain-header")
    priority = re.sub(r"\s+", "", header.group(1))
    if priority.startswith("filter"):
        priority = priority[len("filter"):]
    try:
        priority_value = int(priority) if priority else 0
    except ValueError:
        raise FirewallError("nft-drift", detail="chain-priority")
    if priority_value != NFT_PRIORITY:
        raise FirewallError("nft-drift", detail="chain-priority")
    accept = re.fullmatch(r"ip\s+saddr\s+\{([^}]*)\}\s+tcp\s+dport\s+(\d+)\s+accept", lines[2])
    drop = re.fullmatch(r"tcp\s+dport\s+(\d+)\s+drop", lines[3])
    if accept is None or int(accept.group(2)) != NFT_PORT:
        raise FirewallError("nft-drift", detail="accept-rule")
    if drop is None or int(drop.group(1)) != NFT_PORT:
        raise FirewallError("nft-drift", detail="drop-rule")
    parts = [part.strip() for part in accept.group(1).split(",")]
    if not all(parts):
        raise FirewallError("nft-drift", detail="address-set")
    try:
        members = [ipaddress.ip_network(part, strict=True) for part in parts]
    except ValueError:
        raise FirewallError("nft-drift", detail="address-set")
    expected = {ipaddress.ip_network(LOOPBACK), ipaddress.ip_network(address), network}
    if len(members) != len(expected) or len(set(members)) != len(members) or set(members) != expected:
        raise FirewallError("nft-drift", detail="address-set")
    return "match"


def _reject_forbidden(text: str) -> None:
    for token in ("flush", "delete", "iptables"):
        if token in text:
            raise FirewallError("nft-render-invalid", detail=token)


def run_render(address: str = INGRESS_ADDRESS, pod_cidr: str = POD_CIDR) -> dict:
    """nft/unit/drop-in을 렌더하고 자체 대조한다 — 파일은 쓰지 않는다(비-root 가능)."""
    rendered = render_nft(address, pod_cidr)
    for key in ("nft", "service", "ingressDropIn"):
        _reject_forbidden(rendered[key])
    if check_nft(rendered["nft"], address, pod_cidr) != "match":
        raise FirewallError("nft-render-invalid", detail="self-check")
    return {
        "status": "rendered",
        "table": f"inet {NFT_TABLE}",
        "priority": NFT_PRIORITY,
        "port": NFT_PORT,
        "allowed": [LOOPBACK, rendered["address"], rendered["podCidr"]],
        "address": rendered["address"],
        "podCidr": rendered["podCidr"],
        "nft": rendered["nft"],
        "service": rendered["service"],
        "ingressDropIn": rendered["ingressDropIn"],
        "ingressDropInPath": INGRESS_DROP_IN,
        "install": {
            "helper": HELPER_INSTALL_PATH,
            "helperMode": "0644",
            "nft": NFT_FILE,
            "nftMode": "0644",
            "unit": NFT_UNIT,
            "unitMode": "0644",
            "ingressDropIn": INGRESS_DROP_IN,
            "ingressDropInMode": "0644",
            "note": (
                "unit은 nft를 직접 실행하지 않는다 — 문법검사·적용 판정은 설치된 helper의 apply "
                "하나뿐이다. no-op도 nft 조회 2회(list tables/list table)만 수행하고 쓰기 0회다."
            ),
        },
        "apply": {
            "noopOnExactMatch": True,
            "noopQueries": 2,
            "noopWrites": 0,
            "syntaxCheckOnlyWhenAbsent": True,
            "flushOrDeleteOtherTables": False,
        },
        "hostModified": False,
    }


# ── nft 실행 (FD 결속) ──────────────────────────────────────────────────────
def _run_nft(runner, argv: list[str], pass_fds: tuple[int, ...] = ()):
    run = runner or subprocess.run
    kwargs = dict(
        capture_output=True,
        env=dict(NFT_ENV),
        timeout=NFT_TIMEOUT,
        check=False,
    )
    if pass_fds:
        kwargs["pass_fds"] = tuple(pass_fds)
    try:
        return run(argv, **kwargs)
    except subprocess.TimeoutExpired:
        raise FirewallError("nft-run-failed", detail="timeout")
    except OSError:
        raise FirewallError("nft-run-failed", detail="spawn")


def _stdout_text(result) -> str | None:
    raw = getattr(result, "stdout", None)
    if raw is None:
        return None
    if isinstance(raw, str):
        return raw
    try:
        return raw.decode("utf-8")
    except (UnicodeDecodeError, AttributeError):
        return None


def _listed_present(call) -> bool:
    """`nft list tables` 결과에서 AIOps table 존재 여부를 판정한다.

    rc0 출력은 비었거나(정상 absence) `table <family> <name>` 줄들의 나열이어야 한다.
    malformed 비어있지 않은 줄은 부재로 접지 않고, 동명 table의 다른 family는 drift다.
    """
    listing = call(["list", "tables"])
    listing_text = _stdout_text(listing)
    if listing.returncode != 0 or listing_text is None:
        raise FirewallError("nft-query-failed", detail="list-tables")
    present = False
    for line in listing_text.splitlines():
        entry = line.strip()
        if not entry:
            continue
        match = LISTED_TABLE_RE.fullmatch(entry)
        if match is None:
            raise FirewallError("nft-query-failed", detail="list-tables")
        family, name = match.group(1), match.group(2)
        if name != NFT_TABLE:
            continue  # 무관 table은 허용한다.
        if family != "inet":
            raise FirewallError("nft-drift", detail="table-form")
        present = True
    return present


def run_apply_nft(
    address: str = INGRESS_ADDRESS,
    pod_cidr: str = POD_CIDR,
    *,
    nft: str = NFT_BINARY,
    nft_file: str = NFT_FILE,
    runner=None,
) -> dict:
    """라이브 table과 reviewed 렌더를 정확 등식 대조해 적용 상태를 수렴시킨다(root 전용 CLI).

    - 일치: no-op(재적용 없음 — 규칙 중복 삽입 금지). 조회 2회/쓰기 0회.
    - 부재: 파일 지문==렌더 확인 → `nft -c` → `nft -f` → 사후 재대조 ==match.
    - 표류·조회 실패·조회 불일치·파일 표류: 중단(덮어쓰기·flush·delete 금지).

    실행 파일과 명령 파일은 검증한 FD에 결속한다 — argv[0]와 `-f`가 `/proc/self/fd/<fd>`이고
    같은 FD를 pass_fds로 넘긴다. 검사–실행 사이 경로를 교체해도 실행·적용 바이트는 검증한 inode 그대로다.
    `runner` 주입은 호출자가 실커널 namespace probe를 연결하기 위한 fixture 계약이다.
    """
    expected = render_nft(address, pod_cidr)["nft"]
    nft_fd, _raw, _info = _open_verified_file(
        nft, code="nft-binary-invalid", executable=True, exec_code="nft-not-executable"
    )
    try:
        file_fd, file_raw, _file_info = _open_verified_file(nft_file, code="nft-file-invalid")
        try:
            try:
                file_text = file_raw.decode("utf-8")
            except UnicodeDecodeError:
                raise FirewallError("nft-file-invalid")
            if file_text != expected:
                raise FirewallError("nft-file-drift")
            binary_path = f"/proc/self/fd/{nft_fd}"
            command_file = f"/proc/self/fd/{file_fd}"
            pass_fds = (nft_fd, file_fd)

            def call(args: list[str]):
                return _run_nft(runner, [binary_path, *args], pass_fds=pass_fds)

            if _listed_present(call):
                current = call(["list", "table", "inet", NFT_TABLE])
                current_text = _stdout_text(current)
                if current.returncode != 0 or current_text is None:
                    raise FirewallError("nft-query-failed", detail="list-table")
                # rc0이어도 조회 결과가 reviewed 등식이 아니면 absent/drift 모두 중단한다.
                if check_nft(current_text, address, pod_cidr) != "match":
                    raise FirewallError("nft-query-failed", detail="list-table")
                return {
                    "status": "no-op",
                    "table": f"inet {NFT_TABLE}",
                    "action": "noop",
                    "exactMatch": True,
                    "queries": 2,
                    "syntaxChecks": 0,
                    "writes": 0,
                    "hostModified": False,
                    "note": (
                        "일치 → no-op: nft 조회 2회(list tables/list table), 쓰기 0회 — "
                        "문법검사(-c)·적용(-f) 호출 없음."
                    ),
                }
            syntax = call(["-c", "-f", command_file])
            if syntax.returncode != 0:
                raise FirewallError("nft-apply-failed", detail="syntax-check")
            applied = call(["-f", command_file])
            if applied.returncode != 0:
                raise FirewallError("nft-apply-failed", detail="apply")
            verify = call(["list", "table", "inet", NFT_TABLE])
            verify_text = _stdout_text(verify)
            if verify.returncode != 0 or verify_text is None:
                raise FirewallError("nft-query-failed", detail="post-apply")
            # 적용 직후 readback도 ==match만 통과한다 — 부재/불일치를 성공으로 접지 않는다.
            if check_nft(verify_text, address, pod_cidr) != "match":
                raise FirewallError("nft-apply-failed", detail="post-apply")
            return {
                "status": "applied",
                "table": f"inet {NFT_TABLE}",
                "action": "create",
                "exactMatch": True,
                "queries": 2,
                "syntaxChecks": 1,
                "writes": 1,
                "hostModified": True,
                "note": (
                    "부재 → 생성: nft 조회 2회(list tables/사후 list table), "
                    "문법검사 1회(-c), 쓰기 1회(-f)."
                ),
            }
        finally:
            os.close(file_fd)
    finally:
        os.close(nft_fd)


apply_nft = run_apply_nft  # 원본 호출자 호환 alias


def run_verify_nft(
    address: str = INGRESS_ADDRESS,
    pod_cidr: str = POD_CIDR,
    *,
    nft: str = NFT_BINARY,
    runner=None,
) -> dict:
    """root 전용·읽기 전용 — 라이브 table이 reviewed 렌더와 ==match일 때만 성공한다.

    table 부재는 `nft-verify-failed`(detail=absent)다 — 배포 전 상태를 성공으로 접지 않는다.
    어떤 경우에도 문법검사(`-c`)·적용(`-f`) 호출과 쓰기는 없다.
    """
    render_nft(address, pod_cidr)  # 입력 검증(주소/CIDR) — 파일 접촉 전에 거부한다.
    nft_fd, _raw, _info = _open_verified_file(
        nft, code="nft-binary-invalid", executable=True, exec_code="nft-not-executable"
    )
    try:
        binary_path = f"/proc/self/fd/{nft_fd}"

        def call(args: list[str]):
            return _run_nft(runner, [binary_path, *args], pass_fds=(nft_fd,))

        if not _listed_present(call):
            raise FirewallError("nft-verify-failed", detail="absent")
        current = call(["list", "table", "inet", NFT_TABLE])
        current_text = _stdout_text(current)
        if current.returncode != 0 or current_text is None:
            raise FirewallError("nft-query-failed", detail="list-table")
        if check_nft(current_text, address, pod_cidr) != "match":
            raise FirewallError("nft-query-failed", detail="list-table")
        return {
            "status": "verified",
            "table": f"inet {NFT_TABLE}",
            "exactMatch": True,
            "queries": 2,
            "syntaxChecks": 0,
            "writes": 0,
            "hostModified": False,
            "note": "읽기 전용: nft 조회 2회(list tables/list table), 쓰기 0회.",
        }
    finally:
        os.close(nft_fd)


# ── CLI (render / verify / apply — 고정 경로, fixture 우회 없음) ─────────────
def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aiops_ingress_firewall.py",
        description=(
            "AIOps ingress 21980 nft 방화벽 helper — "
            "render(비-root) / verify(root, 읽기 전용) / apply(root)"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "render",
        help="nft 파일·oneshot unit·ingress gate drop-in을 stdout JSON으로 렌더(파일 미기록, 비-root 가능)",
    )
    sub.add_parser(
        "verify",
        help="라이브 table ==reviewed 렌더 정확 등식 검증(root 전용, 읽기 전용, match 필수)",
    )
    sub.add_parser(
        "apply",
        help=(
            "라이브 table 대조 후 부재일 때만 생성(root 전용, 고정 "
            "/usr/sbin/nft + /etc/nftables.d/homelab-aiops.nft)"
        ),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "render":
            summary = run_render()
        elif args.command == "verify":
            _require_root()
            summary = run_verify_nft(nft=NFT_BINARY)
        else:
            _require_root()
            summary = run_apply_nft(nft=NFT_BINARY, nft_file=NFT_FILE)
    except FirewallError as error:
        failure = {"status": "failed", "error": error.code}
        if error.detail:
            failure["detail"] = error.detail
        print(json.dumps(failure, ensure_ascii=False))
        return 1
    except OSError:
        print(json.dumps({"status": "failed", "error": "unexpected-io-error"}))
        return 1
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
