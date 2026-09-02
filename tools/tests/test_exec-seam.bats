#!/usr/bin/env bats
# 실행 seam(tools/lib/exec.ts, lib-convergence d6①)의 계약 테스트 — 명명 adapter 4종(gh/git/
# kubeseal/sh) + errKind(실행 실패 종류) + env 주입 원장(HOMELAB_EXEC_LEDGER).
# 판정 정책(무엇이 실패인가)은 콜사이트 소유 — seam은 실행·캡처·관측만 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1   # git ls-files는 cwd 상대다(sops-guard와 같은 관례)
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
  // git adapter는 cwd-우선 시그니처다(#541 엔진 계약 유지 — -C <cwd> 전치). 나머지 adapter는 args-우선.
  console.log("git=" + git(".", ["--version"]).ok);
} else if (mode === "spawnkind") {
  const r = sh("/etc/hostname", []);
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none"));
} else if (mode === "ledger") {
  sh("cat", [], { input: "SECRET-PLAINTEXT-7f3a" });
  git(".", ["--version"]);
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
  #    rc 2(원장 파일 미생성)를 "평문 미기록"으로 읽지 않는다 — 위 [ -f "$L" ]와 cmd 단언들이 원장의
  #    실재·비공허를 증언한다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -q 'SECRET-PLAINTEXT-7f3a' "$L"
  [ "$status" -eq 1 ]
}

@test "a broken ledger path never blocks execution (observation must not gate the run)" {
  FX_MODE=named HOMELAB_EXEC_LEDGER="$BATS_TEST_TMPDIR/no-such-dir/ledger.jsonl" run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^git=true$'
}

@test "child_process lives in exec.ts alone across tools (repo-derived, one declared exemption)" {
  # d6 완결(16) — tools/의 subprocess 실행은 전부 seam(명명 adapter)을 경유한다. 직접 사용이
  # 되살아나면 maxBuffer/timeout/원장 계약이 그 사이트만 조용히 빠진다(ENOBUFS 죽음이 spawn 오류로만
  # 보이는 클래스). 열거는 레포에서 파생한다(CONTRIBUTING — 소비처 하드코딩 금지; 14·15의 이행기
  # 목록을 이 완결형이 대체한다). 주석을 걷어낸 소스에서 `child_process` 단어 자체를 센다.
  # 예외 1: tools/seal-secret.mts — app-shared 양립 파일(bun + node strip-types, 외부 앱 레포에서
  # node로 돈다)이라 bun 전용 lib(exec.ts)을 import하지 않고 자체 블록을 유지한다(Pass1 F3 결정).
  n=0
  for f in $(git ls-files 'tools/*.ts' 'tools/*.mts' 'tools/lib/*.ts' 'tools/lib/*.mts'); do
    case "$f" in
      tools/lib/exec.ts) n=$((n + 1)); continue ;;       # seam 자신 — 유일한 정당 보유처
      tools/seal-secret.mts) n=$((n + 1)); continue ;;   # 선언된 예외(위 근거)
    esac
    # bun 런타임의 자연 우회 경로(Bun.spawn/Bun.spawnSync/Bun.$)도 같은 그물로 잡는다.
    run bash -c "sed 's|//.*||' '$ROOT/$f' | grep -cE 'child_process|Bun\.(spawn|\\\$)'"
    [ "$output" = "0" ] || { echo "seam bypass: $f가 subprocess를 직접 쓴다(${output}곳 — child_process/Bun.spawn)"; false; }
    n=$((n + 1))
  done
  [ "$n" -ge 40 ]   # 열거 붕괴 바닥값 — glob이 깨지면 루프가 vacuous해진다(실측 건수는 여기 베끼지 않는다)
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
