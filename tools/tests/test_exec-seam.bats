#!/usr/bin/env bats
# 실행 seam(tools/lib/exec.ts, lib-convergence d6①)의 계약 테스트 — 명명 adapter 4종(gh/git/
# kubeseal/sh) + errKind(실행 실패 종류) + env 주입 원장(HOMELAB_EXEC_LEDGER).
# 판정 정책(무엇이 실패인가)은 콜사이트 소유 — seam은 실행·캡처·관측만 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/x.ts"
  # ⚠️ heredoc 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { sh, gh, git, kubeseal } from "$ROOT/tools/lib/exec.ts";
const mode = process.env.FX_MODE ?? "";
if (mode === "notfound") {
  const r = sh("hlb-definitely-missing-cmd-xyz", []);
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none"));
} else if (mode === "rc") {
  const r = sh("bash", ["-c", "exit 3"]);
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none"));
} else if (mode === "input") {
  const r = sh("cat", [], { input: "SECRET-PLAINTEXT-7f3a" });
  console.log("out=" + r.out);
} else if (mode === "named") {
  console.log("git=" + git(["--version"]).ok);
} else if (mode === "spawnkind") {
  const r = sh("/etc/hostname", []);
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none"));
} else if (mode === "ledger") {
  sh("cat", [], { input: "SECRET-PLAINTEXT-7f3a" });
  git(["--version"]);
  gh(["--version"]);
  kubeseal(["--version"]);
  console.log("done");
}
EOF
}

@test "a missing binary yields errKind not-found (the callsite keeps the judgment)" {
  FX_MODE=notfound run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=not-found$'
}

@test "a non-zero exit is a plain failure with no errKind (rc semantics stay callsite-owned)" {
  FX_MODE=rc run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=none$'
}

@test "stdin input is delivered to the child (the kubeseal plaintext channel)" {
  FX_MODE=input run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^out=SECRET-PLAINTEXT-7f3a$'
}

@test "the named adapters exist and route through the seam" {
  FX_MODE=named run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^git=true$'
}

@test "a non-ENOENT spawn failure yields errKind spawn (measured: EACCES on a non-executable)" {
  FX_MODE=spawnkind run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=spawn$'
}

@test "the env ledger records cmd and args but never the stdin input" {
  L="$BATS_TEST_TMPDIR/ledger.jsonl"
  FX_MODE=ledger HOMELAB_EXEC_LEDGER="$L" run bun "$FX"
  [ "$status" -eq 0 ]
  [ -f "$L" ]
  # 명명 adapter 3종 전부 원장에 남는다 — 바이너리 부재(kubeseal 등)와 무관하게 seam 경유가
  # 증명된다(typeof 단언은 import 성공만으로 참이 되는 vacuous라 이 방식으로 잰다).
  grep -q '"cmd":"cat"' "$L"
  grep -q '"cmd":"git"' "$L"
  grep -q '"cmd":"gh"' "$L"
  grep -q '"cmd":"kubeseal"' "$L"
  grep -q -- '--version' "$L"
  # ⚠️ 평문(stdin)은 원장에 절대 남지 않는다 — kubeseal 봉인 경로의 비밀 미기록 계약.
  run grep -q 'SECRET-PLAINTEXT-7f3a' "$L"
  [ "$status" -ne 0 ]
}

@test "a broken ledger path never blocks execution (observation must not gate the run)" {
  FX_MODE=named HOMELAB_EXEC_LEDGER="$BATS_TEST_TMPDIR/no-such-dir/ledger.jsonl" run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^git=true$'
}
