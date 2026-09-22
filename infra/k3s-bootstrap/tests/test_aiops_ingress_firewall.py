#!/usr/bin/env python3
"""AIOPS-FIREWALL-VERSIONED-SOURCE-0922 — 추출 모듈 시험.

reviewed 소스(ingress_provision.py + 기존 firewall 시험, 80건 고정)의 방화벽 의미를 새 모듈에서
재현한다: check_nft 양/음성(정확 등식·table 전체 소비), render 계약과 gate dependency,
apply no-op/부재 생성/표류·조회 실패 fail-closed, nofollow·소유자·FD 결속(경로 교체 — 실제
subprocess 포함), verify 읽기 전용 성공/실패, root CLI 거부와 fixture 우회 옵션 부재.

실제 root·/usr/sbin/nft·커널·systemd에는 접촉하지 않는다 — 모든 경로는 임시 fixture root 안이다.
"""

import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import importlib.util

# 작업 트리의 버전 관리 소스를 직접 읽어 복사본만 시험하는 우회를 막는다.
_source = Path(__file__).resolve().parent.parent / "aiops-ingress-firewall.py"
_spec = importlib.util.spec_from_file_location("aiops_ingress_firewall", _source)
fw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fw)

NFT_MATCH = (
    "table ip filter {\n"
    "\tchain INPUT {\n"
    "\t\ttype filter hook input priority filter; policy accept;\n"
    "\t}\n"
    "}\n"
    "\n"
    "table inet homelab_aiops {\n"
    "\tchain input {\n"
    "\t\ttype filter hook input priority filter - 5; policy accept;\n"
    "\t\tip saddr { 127.0.0.1, 192.168.117.15, 10.42.0.0/24 } tcp dport 21980 accept\n"
    "\t\ttcp dport 21980 drop\n"
    "\t}\n"
    "}\n"
)
AIOPS_TABLE = NFT_MATCH[NFT_MATCH.index("table inet homelab_aiops"):]


def run_cli(*argv):
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        code = fw.main(list(argv))
    return code, stdout.getvalue()


class NftRecorder:
    """nft runner 대역 — 호출별 (rc, stdout) 시나리오를 순서대로 소비한다.

    호출 시점에 pass_fds 바이트(pread)와 `/proc/self/fd/` 인자의 재열기 결과를 보존한다 —
    경로가 아니라 검증한 inode가 실행/명령 파일에 쓰이는지 witness로 남긴다.
    """

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.pass_fds = []
        self.contents = []
        self.reopened = []

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), dict(kwargs)))
        fds = tuple(kwargs.get("pass_fds") or ())
        self.pass_fds.append(fds)
        self.contents.append(tuple(os.pread(fd, 1 << 20, 0) for fd in fds))
        reopened = {}
        for arg in argv:
            if isinstance(arg, str) and arg.startswith("/proc/self/fd/"):
                with open(arg, "rb") as stream:  # 자식 프로세스의 재열기(offset 0) 대역
                    reopened[arg] = stream.read()
        self.reopened.append(reopened)
        if not self.responses:
            raise AssertionError(f"unexpected nft call: {argv}")
        returncode, stdout = self.responses.pop(0)
        if isinstance(stdout, str):
            stdout = stdout.encode()
        return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=b"")


class ContractPinTests(unittest.TestCase):
    def test_contract_pins(self):
        self.assertEqual(fw.NFT_TABLE, "homelab_aiops")
        self.assertEqual(fw.NFT_PORT, 21980)
        self.assertEqual(fw.NFT_PRIORITY, -5)
        self.assertEqual(fw.INGRESS_ADDRESS, "192.168.117.15")
        self.assertEqual(fw.POD_CIDR, "10.42.0.0/24")
        self.assertEqual(fw.LOOPBACK, "127.0.0.1")
        self.assertEqual(fw.NFT_BINARY, "/usr/sbin/nft")
        self.assertEqual(fw.NFT_FILE, "/etc/nftables.d/homelab-aiops.nft")
        self.assertEqual(fw.NFT_UNIT, "/etc/systemd/system/homelab-aiops-nft.service")
        self.assertEqual(fw.NFT_UNIT_NAME, "homelab-aiops-nft.service")
        self.assertEqual(fw.NFTABLES_UNIT, "nftables.service")
        self.assertEqual(fw.INGRESS_UNIT, "aiops-ingress.service")
        self.assertEqual(
            fw.INGRESS_DROP_IN,
            "/etc/systemd/system/aiops-ingress.service.d/homelab-aiops-nft.conf",
        )
        self.assertEqual(fw.HELPER_INSTALL_PATH, "/usr/local/libexec/homelab-aiops-ingress-firewall.py")
        self.assertEqual(fw.PYTHON_BINARY, "/usr/bin/python3")
        self.assertEqual(fw.ROOT_REQUIRED, "ingress-firewall-root-required")

    def test_error_and_alias_contract(self):
        self.assertIs(fw.ProvisionError, fw.FirewallError)
        self.assertIs(fw.apply_nft, fw.run_apply_nft)
        error = fw.FirewallError("nft-drift", detail="table-form")
        self.assertEqual((error.code, error.detail, str(error)), ("nft-drift", "table-form", "nft-drift"))


class CheckNftTests(unittest.TestCase):
    def test_check_nft_match_absent_and_drift(self):
        self.assertEqual(fw.check_nft(NFT_MATCH), "match")
        self.assertEqual(fw.check_nft("table ip filter {\n\tchain INPUT {\n\t}\n}\n"), "absent")
        drifts = {
            "address-set": NFT_MATCH.replace("10.42.0.0/24", "10.42.1.0/24"),
            "port": NFT_MATCH.replace("dport 21980 accept", "dport 21981 accept"),
            "drop-rule": NFT_MATCH.replace("tcp dport 21980 drop", "tcp dport 21980 accept"),
            "rule-count": NFT_MATCH.replace("\t\ttcp dport 21980 drop\n", ""),
            "extra-rule": NFT_MATCH.replace(
                "\t\ttcp dport 21980 drop\n", "\t\ttcp dport 21980 drop\n\t\ttcp dport 22 accept\n"
            ),
            "chain-priority": NFT_MATCH.replace("priority filter - 5", "priority filter"),
            "chain-policy": NFT_MATCH.replace(
                "priority filter - 5; policy accept;", "priority filter - 5; policy drop;"
            ),
            "table-form": NFT_MATCH.replace("table inet homelab_aiops", "table ip homelab_aiops"),
        }
        for label, text in drifts.items():
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.check_nft(text)
            self.assertEqual(context.exception.code, "nft-drift", label)

    def test_check_nft_rejects_extra_aiops_table_content(self):
        # reviewed 5줄 밖의 AIOps table 내용은 전부 drift다 — 단일 chain 소비를 증명해야 한다.
        drifts = {
            "extra-chain": AIOPS_TABLE.replace("\t}\n}", "\t}\n\tchain extra {\n\t}\n}"),
            "extra-rule": AIOPS_TABLE.replace(
                "\t\ttcp dport 21980 drop\n",
                "\t\ttcp dport 21980 drop\n\t\ttcp dport 22 accept\n",
            ),
            "extra-set": AIOPS_TABLE.replace(
                "\tchain input {", "\tset extra {\n\t\ttype ipv4_addr;\n\t}\n\tchain input {"
            ),
            "comment": AIOPS_TABLE.replace("\tchain input {", "\t# drift\n\tchain input {"),
            "dangling-element": AIOPS_TABLE.replace("\t}\n}", "\t}\n\tquota q {}\n}"),
        }
        for label, text in drifts.items():
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.check_nft(text)
            self.assertEqual(context.exception.code, "nft-drift", label)
            self.assertEqual(context.exception.detail, "table-content", label)

    def test_check_nft_rejects_duplicate_and_missing_addresses(self):
        reviewed = "127.0.0.1, 192.168.117.15, 10.42.0.0/24"
        cases = {
            "duplicate": "127.0.0.1, 127.0.0.1, 192.168.117.15, 10.42.0.0/24",
            "duplicate-cidr": "127.0.0.1, 127.0.0.1/32, 192.168.117.15, 10.42.0.0/24",
            "empty-member": "127.0.0.1,, 192.168.117.15, 10.42.0.0/24",
            "missing": "127.0.0.1, 192.168.117.15",
            "extra": "127.0.0.1, 192.168.117.15, 10.42.0.0/24, 10.43.0.0/24",
            "offset-network": "127.0.0.1, 192.168.117.15, 10.42.0.1/24",
        }
        for label, replacement in cases.items():
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.check_nft(AIOPS_TABLE.replace(reviewed, replacement))
            self.assertEqual(context.exception.code, "nft-drift", label)
            self.assertEqual(context.exception.detail, "address-set", label)

    def test_check_nft_normalizes_only_priority_form_and_address_order(self):
        for header in ("priority -5", "priority filter -5", "priority filter - 5"):
            self.assertEqual(
                fw.check_nft(AIOPS_TABLE.replace("priority filter - 5", header)), "match", header
            )
        reordered = AIOPS_TABLE.replace(
            "{ 127.0.0.1, 192.168.117.15, 10.42.0.0/24 }",
            "{ 10.42.0.0/24, 192.168.117.15, 127.0.0.1 }",
        )
        self.assertEqual(fw.check_nft(reordered), "match")

    def test_check_nft_consumes_entire_aiops_table_only(self):
        # 일반 ruleset의 무관 table은 앞뒤 어디에 있어도 보존된다.
        unrelated_before = "table ip filter {\n\tchain INPUT {\n\t}\n}\n\n"
        unrelated_after = "\ntable ip6 nat {\n\tchain POSTROUTING {\n\t}\n}\n"
        self.assertEqual(fw.check_nft(unrelated_before + AIOPS_TABLE + unrelated_after), "match")
        # 이름이 접두 일치하는 다른 table은 AIOps table로 세지 않는다.
        lookalike = "table inet homelab_aiops_extra {\n\tchain input {\n\t}\n}\n"
        self.assertEqual(fw.check_nft(lookalike + AIOPS_TABLE), "match")
        self.assertEqual(fw.check_nft(lookalike), "absent")
        # table은 존재하지만 내용이 빈 경우 — absent가 아니라 drift다.
        with self.assertRaises(fw.FirewallError) as context:
            fw.check_nft("table inet homelab_aiops {\n}\n")
        self.assertEqual(context.exception.code, "nft-drift")
        self.assertEqual(context.exception.detail, "table-content")

    def test_check_nft_rejects_repeated_or_malformed_table_blocks(self):
        with self.assertRaises(fw.FirewallError) as context:
            fw.check_nft(NFT_MATCH + AIOPS_TABLE)
        self.assertEqual(context.exception.code, "nft-drift")
        self.assertEqual(context.exception.detail, "table-form")
        with self.assertRaises(fw.FirewallError) as context:
            fw.check_nft("table inet homelab_aiops {\n  chain input {\n")
        self.assertEqual(context.exception.code, "nft-live-invalid")


class RenderTests(unittest.TestCase):
    def test_render_nft_exact_contract(self):
        rendered = fw.render_nft()
        self.assertIn("table inet homelab_aiops {\n", rendered["nft"])
        self.assertIn("    type filter hook input priority -5; policy accept;\n", rendered["nft"])
        self.assertIn(
            "    ip saddr { 127.0.0.1, 192.168.117.15, 10.42.0.0/24 } tcp dport 21980 accept\n",
            rendered["nft"],
        )
        self.assertIn("    tcp dport 21980 drop\n", rendered["nft"])
        self.assertEqual(rendered["allowed"], "127.0.0.1, 192.168.117.15, 10.42.0.0/24")
        self.assertEqual(rendered["podCidr"], "10.42.0.0/24")
        self.assertEqual(rendered["address"], "192.168.117.15")
        self.assertEqual(fw.check_nft(rendered["nft"]), "match")
        for banned in ("flush", "delete", "iptables"):
            self.assertNotIn(banned, rendered["nft"] + rendered["service"] + rendered["ingressDropIn"])

    def test_render_nft_rejects_bad_inputs(self):
        for address in ("0.0.0.0", "8.8.8.8", "127.0.0.1", "not-an-address"):
            with self.subTest(address=address), self.assertRaises(fw.FirewallError) as context:
                fw.render_nft(address)
            self.assertEqual(context.exception.code, "nft-address-invalid")
        for pod_cidr in ("8.8.8.0/24", "127.0.0.0/24", "192.168.117.0/24", "10.42.0.0/31", "10.42.0.0/8"):
            with self.subTest(pod_cidr=pod_cidr), self.assertRaises(fw.FirewallError) as context:
                fw.render_nft(pod_cidr=pod_cidr)
            self.assertEqual(context.exception.code, "nft-pod-cidr-invalid")

    def test_render_unit_dependency_gate(self):
        rendered = fw.render_nft()
        service = rendered["service"]
        drop_in = rendered["ingressDropIn"]
        self.assertEqual(rendered["ingressDropInPath"], fw.INGRESS_DROP_IN)
        # gate: drop-in이 Requires+After — 단순 Before와 달리 방화벽 실패를 ingress에 전파한다.
        self.assertIn("[Unit]\n", drop_in)
        self.assertIn("Requires=homelab-aiops-nft.service\n", drop_in)
        self.assertIn("After=homelab-aiops-nft.service\n", drop_in)
        # 기존 nftables 뒤 ordering만 유지 — Requires로 시작시키면 기존 tables flush 위험.
        self.assertIn("After=nftables.service\n", service)
        self.assertNotIn("Requires=", service)
        # 조기부팅 cycle 회피: network.target/network-pre.target 선행이 없다.
        self.assertNotIn("network.target", service)
        self.assertNotIn("Before=", service)
        # gate는 drop-in sole — service는 ingress unit을 참조하지 않는다.
        self.assertNotIn("aiops-ingress.service", service)
        # unit은 설치된 고정 helper CLI 하나만 실행한다 — nft 직접 호출·ExecStartPre/Post 없음.
        execs = [line for line in service.splitlines() if line.startswith("Exec")]
        self.assertEqual(
            execs,
            [
                "ExecStart=/usr/bin/python3 "
                "/usr/local/libexec/homelab-aiops-ingress-firewall.py apply"
            ],
        )
        self.assertNotIn("/usr/sbin/nft", service)
        self.assertIn("Type=oneshot\n", service)
        self.assertIn("RemainAfterExit=yes\n", service)
        self.assertIn("WantedBy=multi-user.target\n", service)

    def test_run_render_reports_install_modes_and_apply_scope(self):
        doc = fw.run_render()
        self.assertEqual(doc["status"], "rendered")
        self.assertEqual(doc["table"], "inet homelab_aiops")
        self.assertEqual((doc["priority"], doc["port"]), (-5, 21980))
        self.assertEqual(doc["allowed"], ["127.0.0.1", "192.168.117.15", "10.42.0.0/24"])
        self.assertFalse(doc["hostModified"])
        for key in ("nft", "service", "ingressDropIn"):
            self.assertIn(key, doc)
            self.assertTrue(doc[key].endswith("\n"))
        self.assertEqual(doc["install"]["helper"], fw.HELPER_INSTALL_PATH)
        self.assertEqual(doc["install"]["helperMode"], "0644")
        self.assertEqual(doc["install"]["nft"], fw.NFT_FILE)
        self.assertEqual(doc["install"]["unit"], fw.NFT_UNIT)
        self.assertEqual(doc["install"]["ingressDropIn"], fw.INGRESS_DROP_IN)
        # 문서 정확성: no-op도 조회 2회를 수행한다 — 'nft 호출조차 없음'이 아니다.
        note = doc["install"]["note"]
        self.assertIn("조회", note)
        self.assertIn("쓰기 0회", note)
        self.assertNotIn("호출조차", note)
        self.assertEqual(doc["apply"]["noopQueries"], 2)
        self.assertEqual(doc["apply"]["noopWrites"], 0)
        self.assertTrue(doc["apply"]["noopOnExactMatch"])
        self.assertFalse(doc["apply"]["flushOrDeleteOtherTables"])


class FirewallCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="aiops-firewall-source-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.binary = self.root / "nft"
        self.rules = self.root / "homelab-aiops.nft"
        self.expected = fw.render_nft()["nft"]
        self.write_binary()
        self.write_rules()

    def write_binary(self, source="#!/bin/sh\nexit 0\n", mode=0o755):
        self.binary.write_text(source)
        os.chmod(self.binary, mode)

    def write_rules(self, text=None, mode=0o644):
        self.rules.write_text(self.expected if text is None else text)
        os.chmod(self.rules, mode)

    def apply(self, responses):
        recorder = NftRecorder(responses)
        result = fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=recorder)
        return result, recorder

    def verify(self, responses):
        recorder = NftRecorder(responses)
        result = fw.run_verify_nft(nft=str(self.binary), runner=recorder)
        return result, recorder

    def assert_inputs_untouched(self):
        self.assertEqual(self.rules.read_text(), self.expected)
        self.assertEqual(self.binary.read_bytes(), b"#!/bin/sh\nexit 0\n")


class ApplyNftTests(FirewallCase):
    def test_apply_nft_noop_when_exact_match(self):
        result, recorder = self.apply([
            (0, "table ip filter\ntable inet homelab_aiops\n"),
            (0, self.expected),
        ])
        self.assertEqual(result["status"], "no-op")
        self.assertEqual(result["action"], "noop")
        self.assertTrue(result["exactMatch"])
        self.assertFalse(result["hostModified"])
        self.assertEqual((result["queries"], result["syntaxChecks"], result["writes"]), (2, 0, 0))
        self.assertIn("조회 2회", result["note"])
        self.assertIn("쓰기 0회", result["note"])
        self.assertEqual(len(recorder.calls), 2)
        self.assertEqual(recorder.calls[0][0][1:], ["list", "tables"])
        self.assertEqual(recorder.calls[1][0][1:], ["list", "table", "inet", "homelab_aiops"])
        # 검증한 FD가 argv·pass_fds·재열기 전부에 결속된다(경로 재실행 금지).
        for index, (argv, _kwargs) in enumerate(recorder.calls):
            fds = recorder.pass_fds[index]
            self.assertEqual(len(fds), 2)
            self.assertEqual(argv[0], f"/proc/self/fd/{fds[0]}")
            self.assertEqual(recorder.contents[index], (self.binary.read_bytes(), self.expected.encode()))
            self.assertEqual(recorder.reopened[index][f"/proc/self/fd/{fds[0]}"], self.binary.read_bytes())
            self.assertNotIn(str(self.binary), argv)
            self.assertNotIn(str(self.rules), argv)
            self.assertNotIn("-f", argv)
            self.assertNotIn("flush", argv)
            self.assertNotIn("delete", argv)
        self.assert_inputs_untouched()

    def test_apply_nft_creates_only_when_absent(self):
        result, recorder = self.apply([
            (0, "table ip filter\n"),
            (0, ""),  # -c -f
            (0, ""),  # -f
            (0, self.expected),  # 사후 재대조
        ])
        self.assertEqual(result["status"], "applied")
        self.assertEqual(result["action"], "create")
        self.assertTrue(result["hostModified"])
        self.assertEqual((result["queries"], result["syntaxChecks"], result["writes"]), (2, 1, 1))
        self.assertIn("쓰기 1회", result["note"])
        self.assertEqual(recorder.calls[0][0][1:], ["list", "tables"])
        self.assertEqual(recorder.calls[3][0][1:], ["list", "table", "inet", "homelab_aiops"])
        applied = [argv for argv, _kwargs in recorder.calls if "-f" in argv]
        self.assertEqual(len(applied), 2)
        command_files = [argv[argv.index("-f") + 1] for argv in applied]
        self.assertEqual(command_files[0], command_files[1])  # 문법검사와 적용은 같은 FD다
        self.assertTrue(command_files[0].startswith("/proc/self/fd/"))
        for index, (argv, _kwargs) in enumerate(recorder.calls):
            fds = recorder.pass_fds[index]
            self.assertEqual(argv[0], f"/proc/self/fd/{fds[0]}")
            self.assertEqual(recorder.contents[index][0], self.binary.read_bytes())
            self.assertNotIn(str(self.binary), argv)
            self.assertNotIn(str(self.rules), argv)
            if "-f" in argv:
                self.assertEqual(recorder.reopened[index][command_files[0]], self.expected.encode())
        self.assert_inputs_untouched()

    def test_apply_nft_stops_on_drift_and_query_failure(self):
        drift = NftRecorder([
            (0, "table inet homelab_aiops\n"),
            (0, self.expected.replace("10.42.0.0/24", "10.42.9.0/24")),
        ])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=drift)
        self.assertEqual(context.exception.code, "nft-drift")
        self.assertEqual(len(drift.calls), 2)  # 덮어쓰기 없음
        query_fail = NftRecorder([(1, b"")])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=query_fail)
        self.assertEqual(context.exception.code, "nft-query-failed")
        list_table_fail = NftRecorder([(0, "table inet homelab_aiops\n"), (1, b"")])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=list_table_fail)
        self.assertEqual(context.exception.code, "nft-query-failed")
        syntax_fail = NftRecorder([(0, ""), (1, b"syntax error")])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=syntax_fail)
        self.assertEqual(context.exception.code, "nft-apply-failed")
        apply_fail = NftRecorder([(0, ""), (0, ""), (1, b"apply error")])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=apply_fail)
        self.assertEqual(context.exception.code, "nft-apply-failed")
        # 조회/드리프트/문법/적용 실패는 전부 nft 적용 호출 없이 끝난다.
        for label, recorder in (
            ("drift", drift),
            ("query-fail", query_fail),
            ("list-table-fail", list_table_fail),
        ):
            self.assertFalse(any("-f" in argv for argv, _kwargs in recorder.calls), label)
        self.assert_inputs_untouched()

    def test_apply_nft_list_tables_must_be_wellformed(self):
        cases = (
            ("malformed", "garbage\n", "nft-query-failed"),
            ("malformed-mixed", "table ip filter\nnot-a-table\n", "nft-query-failed"),
            ("wrong-family", "table ip homelab_aiops\n", "nft-drift"),
            ("wrong-family-mixed", "table ip filter\ntable ip6 homelab_aiops\n", "nft-drift"),
        )
        for label, stdout, code in cases:
            recorder = NftRecorder([(0, stdout)])
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=recorder)
            self.assertEqual(context.exception.code, code, label)
            self.assertEqual(len(recorder.calls), 1, label)  # 적용 호출 없음
            self.assertFalse(any("-f" in argv for argv, _kwargs in recorder.calls), label)
        # 공백뿐인 출력과 무관 table 나열은 정상 absence다 — 부재 생성 경로가 그대로 돈다.
        result, recorder = self.apply([(0, "\n  \n"), (0, ""), (0, ""), (0, NFT_MATCH)])
        self.assertEqual(result["status"], "applied")
        self.assertEqual(len(recorder.calls), 4)
        result, _recorder = self.apply([
            (0, "table ip filter\ntable ip6 nat\n"),
            (0, ""),
            (0, ""),
            (0, NFT_MATCH),
        ])
        self.assertEqual(result["status"], "applied")
        self.assert_inputs_untouched()

    def test_apply_nft_present_readback_requires_exact_match(self):
        cases = (
            ("empty", b"", "nft-query-failed"),
            ("wrong-table", "table ip filter {\n}\n", "nft-query-failed"),
            ("aiops-empty", "table inet homelab_aiops {\n}\n", "nft-drift"),
            ("drifted", self.expected.replace("10.42.0.0/24", "10.42.9.0/24"), "nft-drift"),
        )
        for label, stdout, code in cases:
            recorder = NftRecorder([(0, "table inet homelab_aiops\n"), (0, stdout)])
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=recorder)
            self.assertEqual(context.exception.code, code, label)
            self.assertEqual(len(recorder.calls), 2, label)  # -f/-c 호출 없음
            self.assertFalse(any("-f" in argv for argv, _kwargs in recorder.calls), label)
        self.assert_inputs_untouched()

    def test_apply_nft_post_apply_readback_requires_exact_match(self):
        cases = (
            ("empty", b"", "nft-apply-failed"),
            ("wrong-table", "table ip filter {\n}\n", "nft-apply-failed"),
            ("aiops-empty", "table inet homelab_aiops {\n}\n", "nft-drift"),
            ("drifted", self.expected.replace("10.42.0.0/24", "10.42.9.0/24"), "nft-drift"),
        )
        for label, stdout, code in cases:
            recorder = NftRecorder([
                (0, "table ip filter\n"),
                (0, ""),  # -c -f
                (0, ""),  # -f
                (0, stdout),  # post-apply 재대조
            ])
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=recorder)
            self.assertEqual(context.exception.code, code, label)
            self.assertEqual(len(recorder.calls), 4, label)  # 재적용 없음
            self.assertEqual(len([1 for argv, _ in recorder.calls if "-f" in argv]), 2, label)
        self.assert_inputs_untouched()

    def test_apply_nft_binds_verified_fds_against_path_swap(self):
        expected_file = self.expected.encode()
        original_binary = self.binary.read_bytes()
        recorder = NftRecorder([
            (0, "table inet homelab_aiops\n"),
            (0, self.expected),
        ])
        swapped = []

        def runner(argv, **kwargs):
            result = recorder(argv, **kwargs)
            if not swapped:
                swapped.append(True)
                self.binary.rename(self.binary.with_name("nft.swapped"))
                self.binary.write_bytes(b"#!/bin/sh\nexit 1\n")
                os.chmod(self.binary, 0o755)
                hostile = self.rules.with_name("hostile.nft")
                hostile.write_text("# hostile\n")
                os.chmod(hostile, 0o644)
                hostile.replace(self.rules)
            return result

        result = fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=runner)
        self.assertEqual(result["status"], "no-op")
        self.assertTrue(swapped)
        self.assertNotEqual(self.binary.read_bytes(), original_binary)  # 경로는 교체됐다
        self.assertNotEqual(self.rules.read_bytes(), expected_file)
        for index, (argv, _kwargs) in enumerate(recorder.calls):
            fds = recorder.pass_fds[index]
            self.assertEqual(argv[0], f"/proc/self/fd/{fds[0]}")
            self.assertEqual(recorder.contents[index], (original_binary, expected_file))
            self.assertEqual(recorder.reopened[index][f"/proc/self/fd/{fds[0]}"], original_binary)
            self.assertNotIn(str(self.binary), argv)
            self.assertNotIn(str(self.rules), argv)

    def test_apply_nft_reopens_command_file_from_verified_fd(self):
        # helper가 EOF까지 읽은 FD라도 `-f /proc/self/fd/<fd>`는 offset 0에서 원본 inode를 연다 —
        # 검증 뒤 경로가 교체돼도 적용되는 바이트는 검증한 파일 그대로다.
        expected_file = self.expected.encode()
        recorder = NftRecorder([
            (0, ""),  # 부재
            (0, ""),  # -c -f
            (0, ""),  # -f
            (0, self.expected),  # post-apply 재대조
        ])
        swapped = []

        def runner(argv, **kwargs):
            result = recorder(argv, **kwargs)
            if not swapped:
                swapped.append(True)
                hostile = self.rules.with_name("hostile.nft")
                hostile.write_bytes(b"# hostile\n")
                os.chmod(hostile, 0o644)
                hostile.replace(self.rules)
            return result

        result = fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=runner)
        self.assertEqual(result["status"], "applied")
        self.assertTrue(swapped)
        command_files = []
        for index, (argv, _kwargs) in enumerate(recorder.calls):
            if "-f" not in argv:
                continue
            command_file = argv[argv.index("-f") + 1]
            command_files.append(command_file)
            self.assertEqual(recorder.reopened[index][command_file], expected_file)
            self.assertNotIn(str(self.rules), argv)
        self.assertEqual(len(command_files), 2)
        self.assertEqual(command_files[0], command_files[1])

    def test_apply_nft_fd_bound_exec_survives_path_replacement(self):
        # 실제 subprocess 경로: 검증 직후 binary/명령 파일 경로가 둘 다 교체돼도
        # 실행되는 바이트와 `-f`가 여는 내용은 검증한 inode 그대로다.
        source = (
            "#!/usr/bin/python3\n"
            "import sys\n"
            "from pathlib import Path\n"
            f"expected = {self.expected!r}\n"
            "if '-f' in sys.argv:\n"
            "    assert Path(sys.argv[sys.argv.index('-f') + 1]).read_text() == expected\n"
            "elif sys.argv[1:] == ['list', 'table', 'inet', 'homelab_aiops']:\n"
            f"    print({NFT_MATCH!r})\n"
        )
        self.write_binary(source, mode=0o500)
        calls = []

        def runner(argv, **kwargs):
            if not calls:
                self.binary.unlink()
                self.binary.write_text("#!/usr/bin/python3\nraise SystemExit(42)\n")
                os.chmod(self.binary, 0o500)
                self.rules.unlink()
                self.rules.write_text("changed\n")
            calls.append(argv)
            return subprocess.run(argv, **kwargs)

        result = fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=runner)
        self.assertEqual(result["status"], "applied")
        self.assertEqual(len(calls), 4)
        self.assertEqual(self.binary.read_text(), "#!/usr/bin/python3\nraise SystemExit(42)\n")
        self.assertEqual(self.rules.read_text(), "changed\n")

    def test_apply_nft_rejects_file_drift_before_any_call(self):
        self.write_rules(self.expected.replace("21980", "21981"))
        recorder = NftRecorder([])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=recorder)
        self.assertEqual(context.exception.code, "nft-file-drift")
        self.assertEqual(recorder.calls, [])

    def test_apply_nft_rejects_unsafe_binary_and_rules(self):
        real_binary = self.root / "real-nft"
        real_binary.write_text("#!/bin/sh\nexit 0\n")
        os.chmod(real_binary, 0o755)
        binary_link = self.root / "nft-link"
        binary_link.symlink_to(real_binary)
        rules_link = self.root / "rules-link"
        rules_link.symlink_to(self.rules)
        hardlink = self.root / "nft-hardlink"

        cases = (
            ("binary-symlink", str(binary_link), str(self.rules), "nft-binary-invalid", "symlink"),
            ("rules-symlink", str(self.binary), str(rules_link), "nft-file-invalid", "symlink"),
        )
        for label, binary, rules, code, detail in cases:
            recorder = NftRecorder([])
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.run_apply_nft(nft=binary, nft_file=rules, runner=recorder)
            self.assertEqual(context.exception.code, code, label)
            self.assertEqual(context.exception.detail, detail, label)
            self.assertEqual(recorder.calls, [], label)
        # owner/group-other write·비실행·nlink≠1은 전부 fail-closed다.
        os.chmod(self.binary, 0o775)
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=NftRecorder([]))
        self.assertEqual(context.exception.code, "nft-binary-invalid")
        os.chmod(self.binary, 0o644)
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=NftRecorder([]))
        self.assertEqual(context.exception.code, "nft-not-executable")
        os.chmod(self.binary, 0o755)
        os.link(self.binary, hardlink)
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=NftRecorder([]))
        self.assertEqual(context.exception.code, "nft-binary-invalid")
        hardlink.unlink()
        self.write_rules(mode=0o664)
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_apply_nft(nft=str(self.binary), nft_file=str(self.rules), runner=NftRecorder([]))
        self.assertEqual(context.exception.code, "nft-file-invalid")


class VerifyNftTests(FirewallCase):
    def test_verify_nft_success_is_read_only_match(self):
        result, recorder = self.verify([(0, "table inet homelab_aiops\n"), (0, NFT_MATCH)])
        self.assertEqual(result["status"], "verified")
        self.assertTrue(result["exactMatch"])
        self.assertFalse(result["hostModified"])
        self.assertEqual((result["queries"], result["syntaxChecks"], result["writes"]), (2, 0, 0))
        self.assertIn("쓰기 0회", result["note"])
        self.assertEqual(len(recorder.calls), 2)
        self.assertEqual(recorder.calls[0][0][1:], ["list", "tables"])
        self.assertEqual(recorder.calls[1][0][1:], ["list", "table", "inet", "homelab_aiops"])
        for index, (argv, _kwargs) in enumerate(recorder.calls):
            self.assertEqual(argv[0], f"/proc/self/fd/{recorder.pass_fds[index][0]}")
            self.assertNotIn(str(self.binary), argv)
        self.assertFalse(any("-f" in argv for argv, _ in recorder.calls))
        self.assert_inputs_untouched()

    def test_verify_nft_fails_when_absent(self):
        recorder = NftRecorder([(0, "table ip filter\n")])
        with self.assertRaises(fw.FirewallError) as context:
            fw.run_verify_nft(nft=str(self.binary), runner=recorder)
        self.assertEqual(context.exception.code, "nft-verify-failed")
        self.assertEqual(context.exception.detail, "absent")
        self.assertEqual(len(recorder.calls), 1)
        self.assertFalse(any("-f" in argv for argv, _ in recorder.calls))
        self.assert_inputs_untouched()

    def test_verify_nft_fails_on_drift_and_query_failures(self):
        cases = (
            ("query-fail", [(1, b"")], "nft-query-failed"),
            ("malformed", [(0, "garbage\n")], "nft-query-failed"),
            ("wrong-family", [(0, "table ip homelab_aiops\n")], "nft-drift"),
            ("empty-readback", [(0, "table inet homelab_aiops\n"), (0, "")], "nft-query-failed"),
            (
                "drifted",
                [
                    (0, "table inet homelab_aiops\n"),
                    (0, NFT_MATCH.replace("10.42.0.0/24", "10.42.9.0/24")),
                ],
                "nft-drift",
            ),
        )
        for label, responses, code in cases:
            recorder = NftRecorder(responses)
            with self.subTest(label=label), self.assertRaises(fw.FirewallError) as context:
                fw.run_verify_nft(nft=str(self.binary), runner=recorder)
            self.assertEqual(context.exception.code, code, label)
            self.assertFalse(any("-f" in argv for argv, _ in recorder.calls), label)
        self.assert_inputs_untouched()


class CliTests(FirewallCase):
    def cli_as_root(self, *argv):
        stdout = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(fw, "get_euid", return_value=0))
            stack.enter_context(mock.patch.object(fw, "NFT_BINARY", str(self.binary)))
            stack.enter_context(mock.patch.object(fw, "NFT_FILE", str(self.rules)))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            code = fw.main(list(argv))
        return code, stdout.getvalue()

    def fixture_script(self, marker):
        return (
            "#!/usr/bin/python3\n"
            "import sys\n"
            "from pathlib import Path\n"
            f"EXPECTED = {self.expected!r}\n"
            f"MARKER = Path({str(marker)!r})\n"
            "args = sys.argv[1:]\n"
            'if args[:2] == ["list", "tables"]:\n'
            '    print("table inet homelab_aiops" if MARKER.exists() else "table ip filter")\n'
            'elif args[:2] == ["list", "table"]:\n'
            f"    print({NFT_MATCH!r})\n"
            "elif '-f' in args:\n"
            "    path = Path(args[args.index('-f') + 1])\n"
            "    assert path.read_text() == EXPECTED\n"
            "    MARKER.write_text('present\\n')\n"
            "else:\n"
            "    raise SystemExit(2)\n"
        )

    def test_cli_render_is_non_root_and_writes_nothing(self):
        before = sorted(path.name for path in self.root.iterdir())
        with mock.patch.object(fw, "get_euid", return_value=4242):
            code, stdout = run_cli("render")
        self.assertEqual(code, 0)
        doc = json.loads(stdout)
        self.assertEqual(doc["status"], "rendered")
        for key in ("nft", "service", "ingressDropIn"):
            self.assertIn(key, doc)
        self.assertFalse(doc["hostModified"])
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), before)

    def test_cli_verify_and_apply_refuse_non_root_fail_closed(self):
        # fixture root/uid 예외 CLI는 없다 — root가 아니면 파일 접촉 전에 거부한다.
        guarded = mock.Mock(side_effect=AssertionError("must not be called before root check"))
        with mock.patch.object(fw, "get_euid", return_value=4242), \
                mock.patch.object(fw, "_open_verified_file", guarded), \
                mock.patch.object(fw, "_run_nft", guarded):
            for command in ("verify", "apply"):
                with self.subTest(command=command):
                    code, stdout = run_cli(command)
                    self.assertEqual(code, 1)
                    self.assertEqual(json.loads(stdout)["error"], fw.ROOT_REQUIRED)
        self.assertFalse(guarded.called)

    def test_cli_rejects_unknown_verbs_and_fixture_options(self):
        for argv in (
            [],
            ["check-nft", "--live", "/tmp/ruleset.txt"],
            ["apply", "--nft", "/tmp/x"],
            ["apply", "--file", "/tmp/x"],
            ["verify", "--live", "/tmp/x"],
            ["render", "--public-dir", "/tmp/x"],
            ["render", "--address", "10.1.1.1"],
        ):
            with self.subTest(argv=argv), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()):
                fw.main(argv)

    def test_cli_apply_verify_real_subprocess(self):
        # runner=None → 실제 subprocess. 검증한 FD로 실행/`-f`가 결속되는지 실제 커널 경로로 확인한다.
        marker = self.root / "applied"
        self.write_binary(self.fixture_script(marker), mode=0o500)

        code, stdout = self.cli_as_root("apply")
        self.assertEqual(code, 0)
        summary = json.loads(stdout)
        self.assertEqual(summary["status"], "applied")
        self.assertEqual((summary["queries"], summary["syntaxChecks"], summary["writes"]), (2, 1, 1))
        self.assertTrue(marker.exists())
        self.assertEqual(self.rules.read_text(), self.expected)  # apply는 파일을 쓰지 않는다

        code, stdout = self.cli_as_root("apply")
        self.assertEqual(code, 0)
        summary = json.loads(stdout)
        self.assertEqual(summary["status"], "no-op")
        self.assertEqual((summary["queries"], summary["syntaxChecks"], summary["writes"]), (2, 0, 0))
        self.assertIn("조회 2회", summary["note"])
        self.assertIn("쓰기 0회", summary["note"])

        code, stdout = self.cli_as_root("verify")
        self.assertEqual(code, 0)
        summary = json.loads(stdout)
        self.assertEqual(summary["status"], "verified")
        self.assertEqual((summary["queries"], summary["syntaxChecks"], summary["writes"]), (2, 0, 0))

        marker.unlink()
        code, stdout = self.cli_as_root("verify")
        self.assertEqual(code, 1)
        failure = json.loads(stdout)
        self.assertEqual(failure["error"], "nft-verify-failed")
        self.assertEqual(failure["detail"], "absent")
        self.assertEqual(self.rules.read_text(), self.expected)


if __name__ == "__main__":
    unittest.main()
