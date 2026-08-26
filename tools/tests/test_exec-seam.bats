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

@test "the bump cluster imports no child_process directly (execution routes through the seam)" {
  # d6② — bump 계열의 subprocess 실행은 전부 seam(명명 adapter)을 경유한다. 직접 import가 되살아나면
  # maxBuffer/timeout/원장 계약이 그 사이트만 조용히 빠진다(ENOBUFS 죽음이 spawn 오류로만 보이는 클래스).
  # 주석을 걷어낸 소스에서 `child_process` 단어 자체를 센다 — `from "child_process"`(node: 접두 생략)·
  # 동적 import까지 한 그물로 잡고, ENOBUFS 실측 근거를 서술한 주석의 언급만 정당하게 남긴다.
  # ⚠️ 5파일 열거는 이행기 표식이다(CONTRIBUTING의 소비처 하드코딩 금지 대상): 16(exec-remainder)이
  #    착지하면 "tools/ 전체에서 child_process는 exec.ts 하나"의 **레포 파생** 증인으로 교체한다.
  n=0
  for f in tools/poll-ghcr.ts tools/run-bump-plan.ts tools/ensure-bump-pr.ts tools/bump-tag.ts tools/repin-ops-image.ts; do
    [ -f "$ROOT/$f" ] || { echo "roster drift: $f가 없다(개명/이동 — 증인 목록을 갱신하라)"; false; }
    run bash -c "sed 's|//.*||' '$ROOT/$f' | grep -c 'child_process'"
    [ "$output" = "0" ] || { echo "seam bypass: $f가 child_process를 직접 쓴다(${output}곳)"; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 5 ]   # 열거 붕괴 바닥값 — 루프가 굴러가지 않으면 여기서 죽는다
}

@test "the exit status rides the Cmd result (callsites keep rc semantics without touching child_process)" {
  FX="$BATS_TEST_TMPDIR/st.ts"
  cat > "$FX" <<EOF
import { sh } from "$ROOT/tools/lib/exec.ts";
const r = sh("bash", ["-c", "exit 3"]);
console.log("ok=" + r.ok + " status=" + String(r.status));
const n = sh("hlb-definitely-missing-cmd-xyz", []);
console.log("nf-status=" + String(n.status));
EOF
  run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false status=3$'
  echo "$output" | grep -q '^nf-status=null$'
}
