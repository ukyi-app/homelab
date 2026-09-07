#!/usr/bin/env bats
# 실행 seam(tools/lib/exec.ts, lib-convergence d6①)의 계약 테스트 — 명명 adapter 4종(gh/git/
# kubeseal/sh) + errKind(실행 실패 종류) + env 주입 원장(HOMELAB_EXEC_LEDGER).
# 판정 정책(무엇이 실패인가)은 콜사이트 소유 — seam은 실행·캡처·관측만 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1   # git ls-files는 cwd 상대다(sops-guard와 같은 관례)
  FX="$BATS_TEST_TMPDIR/x.ts"
  # 자기 자신을 SIGKILL하는 헬퍼 — TS 본문에서 `kill -9 $$`를 쓰면 **비인용 heredoc이 그 자리에서
  # bats의 PID로 확장**해 버린다(같은 클래스: 함정 「인용하지 않은 heredoc」). 인용 heredoc으로 뺀다.
  FX_KILLER="$BATS_TEST_TMPDIR/killer.sh"
  export FX_KILLER
  cat > "$FX_KILLER" <<'SH'
#!/usr/bin/env bash
kill -9 $$
SH
  chmod +x "$FX_KILLER"
  # ⚠️ heredoc 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { firstReason, pushReason, sh, gh, git, kubeseal } from "$ROOT/tools/lib/exec.ts";
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
} else if (mode === "timeout") {
  const r = sh("bash", ["-c", "echo why >&2; sleep 5"], { timeoutMs: 200 });
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none") + " why=" + r.err.includes("why") + " signal=" + (r.signal ?? "none"));
} else if (mode === "overflow") {
  const r = sh("bash", ["-c", "echo partial >&2; head -c 65536 /dev/urandom | base64"], { maxBuffer: 1024 });
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none") + " partial=" + r.err.includes("partial"));
} else if (mode === "killed") {
  const r = sh(process.env.FX_KILLER ?? "", []);
  console.log("ok=" + r.ok + " errKind=" + (r.errKind ?? "none") + " signal=" + (r.signal ?? "none"));
} else if (mode === "reason") {
  const push = ["To https://github.com/ukyi-app/x.git", " ! [rejected] HEAD -> main (fetch first)", "error: failed to push some refs", "hint: Updates were rejected"].join("\n");
  console.log("push=" + firstReason(push));
  console.log("clone=" + firstReason("Cloning into 'x'...\nfatal: repository not found"));
  console.log("gh=" + firstReason("gh: Not Found (HTTP 404)"));
  console.log("empty=[" + firstReason("") + "]");
} else if (mode === "ledger") {
  sh("cat", [], { input: "SECRET-PLAINTEXT-7f3a" });
  git(".", ["--version"]);
  gh(["--version"]);
  kubeseal(["--version"]);
  console.log("done");
} else if (mode === "gitdir") {
  // GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE 하이재킹 아래에서 adapter가 cwd 레포를 보는가(티켓 27).
  const b = process.env.FX_B ?? "";
  const head = git(b, ["rev-parse", "HEAD"]);
  const add = git(b, ["add", "-A"]);
  const staged = git(b, ["diff", "--cached", "--name-only"]);
  console.log("head=" + head.out.trim());
  console.log("addok=" + add.ok + " staged=" + staged.out.trim().split("\n").join(","));
} else if (mode === "envecho") {
  // 스텁 git이 자기 env를 찍는다 — adapter 경로와 sh("git", …) 직접 경로(클론이 이 형태다) 둘 다.
  const viaAdapter = git(".", ["rev-parse", "HEAD"]);
  const viaClone = sh("git", ["clone", "https://example.invalid/x.git", "/nonexistent/dest"]);
  const nonGit = sh("bash", ["-c", "echo TP=" + "\${GIT_TERMINAL_PROMPT:-unset}"]);
  console.log("adapter " + viaAdapter.out.trim());
  console.log("clone " + viaClone.out.trim());
  console.log("nongit " + nonGit.out.trim());
} else if (mode === "credfill") {
  // 자격 helper가 없을 때 실제 git이 내는 줄 — 프롬프트가 봉인돼 있으면 즉시 이 문구로 죽는다.
  const r = sh("git", ["credential", "fill"], { input: "protocol=https\nhost=github.example.invalid\n\n" });
  console.log("ok=" + r.ok);
  console.log("reason=" + pushReason(r.err));
} else if (mode === "pushreason") {
  const cred = ["To https://github.com/ukyi-app/x.git", "fatal: could not read Username for 'https://github.com': terminal prompts disabled"].join("\n");
  const reject = ["To https://github.com/ukyi-app/x.git", " ! [rejected] HEAD -> main (fetch first)", "error: failed to push some refs"].join("\n");
  console.log("cred=" + pushReason(cred));
  console.log("reject=" + pushReason(reject));
}
EOF
  # env 에코 스텁 git — PATH를 **대체**해 실제 git 대신 이것이 뽑힌다(형제 하네스 cli_stub과 같은 원칙).
  # bash·printenv는 심링크로 들여온다(sh("bash", …) 대조군이 그것을 쓴다).
  ESTUB="$BATS_TEST_TMPDIR/estub"
  mkdir -p "$ESTUB"
  ln -sf "$(command -v bash)" "$ESTUB/bash"
  cat > "$ESTUB/git" <<'SH'
#!/usr/bin/env bash
printf 'TP=%s DIR=%s WT=%s IX=%s CFG=%s\n' \
  "${GIT_TERMINAL_PROMPT:-unset}" "${GIT_DIR:-unset}" "${GIT_WORK_TREE:-unset}" \
  "${GIT_INDEX_FILE:-unset}" "${GIT_CONFIG_GLOBAL:-unset}"
SH
  chmod +x "$ESTUB/git"
}

# 실물 레포 두 개 — a(하이재킹 소스) · b(호출 대상). 커밋 신원은 로컬 config로만 심는다.
make_two_repos() {
  A="$BATS_TEST_TMPDIR/repo-a"; B="$BATS_TEST_TMPDIR/repo-b"
  for d in "$A" "$B"; do
    mkdir -p "$d"
    git init -q -b main "$d"
    git -C "$d" config user.email t@example.invalid
    git -C "$d" config user.name t
  done
  echo a > "$A/a.txt"; git -C "$A" add -A; git -C "$A" commit -q -m a
  echo b > "$B/b.txt"; git -C "$B" add -A; git -C "$B" commit -q -m b
  echo new > "$B/only-in-b.txt"
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

@test "a timed-out child yields errKind timeout AND keeps the partial stderr it wrote before dying" {
  # 종전에는 ETIMEDOUT·ENOBUFS·기타 spawn 실패가 전부 errKind "spawn" 한 값으로 접혀 원인이 지워졌고,
  # 자식이 죽기 전에 쓴 stderr(유일한 단서)는 통째로 버려졌다. 실측(Bun 1.3.14): status null·SIGTERM.
  FX_MODE=timeout run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=timeout why=true signal=SIGTERM$'
}

@test "a maxBuffer overflow yields errKind overflow (not the catch-all spawn) and keeps the partial stderr" {
  FX_MODE=overflow run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=overflow partial=true$'
}

@test "a child killed by a signal carries that signal on the result (empty stderr is not 'no reason')" {
  # SIGKILL 사망은 r.error가 없어 정상 분기로 온다(ok:false·status null·stderr "") — 시그널을
  # 나르지 않으면 콜사이트의 사유가 빈 문자열이 되고 '실패했는데 이유가 없다'가 된다.
  FX_MODE=killed run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false errKind=none signal=SIGKILL$'
}

@test "firstReason picks the rejection line git push hides on line 2, and leaves one-line tools unchanged" {
  FX_MODE=reason run bun "$FX"
  [ "$status" -eq 0 ]
  # git push non-fast-forward: 1행은 `To <url>`(사유 아님) — 사유는 2행이다.
  echo "$output" | grep -q '^push=! \[rejected\] HEAD -> main (fetch first)$'
  echo "$output" | grep -q '^clone=fatal: repository not found$'
  echo "$output" | grep -q '^gh=gh: Not Found (HTTP 404)$'
  # 빈 입력은 빈 문자열(콜사이트가 폴백 문구를 고른다) — 예외로 죽지 않는다.
  echo "$output" | grep -q '^empty=\[\]$'
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
    [ "$output" = "0" ] || { echo "seam bypass: ${f}가 subprocess를 직접 쓴다(${output}곳 — child_process/Bun.spawn)"; false; }
    n=$((n + 1))
  done
  [ "$n" -ge 40 ]   # 열거 붕괴 바닥값 — glob이 깨지면 루프가 vacuous해진다(실측 건수는 여기 베끼지 않는다)
}

@test "the git adapter sees the cwd repo even when GIT_DIR and friends are exported (hijack scrub)" {
  # 티켓 27 — 이 셋이 상속되면 `git -C <cwd>`가 **다른 레포**를 본다. secrets의 선행 조건 판정
  # (브랜치·클린 트리·staged 완전성·HEAD)과 init의 커밋이 전부 이 adapter 위에 있어, git hook
  # (pre-commit·post-checkout이 이 셋을 export한다) 안에서 CLI를 띄우면 판정 대상이 cwd가 아니다.
  make_two_repos
  a_head="$(git -C "$A" rev-parse HEAD)"
  b_head="$(git -C "$B" rev-parse HEAD)"
  [ "$a_head" != "$b_head" ]
  # 양성 대조 — 스크럽이 없으면 실제로 하이재킹된다(같은 env로 raw git을 돌려 a의 HEAD가 나온다).
  # 이게 없으면 아래 단언이 'env가 애초에 무해했다'와 구별되지 않는다(무증인 통과).
  run env GIT_DIR="$A/.git" GIT_WORK_TREE="$A" git -C "$B" rev-parse HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$a_head" ]
  # seam 경유 — 두 케이스(읽기 rev-parse · 인덱스 쓰기 add) 모두 b를 본다.
  FX_MODE=gitdir FX_B="$B" GIT_DIR="$A/.git" GIT_WORK_TREE="$A" GIT_INDEX_FILE="$A/.git/index" \
    run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^head=$b_head\$"
  echo "$output" | grep -q '^addok=true staged=only-in-b.txt$'
  # a의 인덱스는 손대지 않았다 — 하이재킹된 add였다면 a에 스테이징이 남는다.
  [ -z "$(git -C "$A" diff --cached --name-only)" ]
}

@test "GIT_TERMINAL_PROMPT=0 rides every git exec including the direct sh(git, clone) callsite" {
  # 티켓 27 — adapter만 감싸면 init의 템플릿 클론(sh("git", ["clone", …]))이 규약 밖에 남는다.
  # PATH 전치로 스텁 git이 자기 env를 찍는다(부재 시나리오가 없어 전치가 안전한 자리다).
  FX_MODE=envecho run env PATH="$ESTUB:$PATH" GIT_DIR=/hijack/.git GIT_WORK_TREE=/hijack \
    GIT_INDEX_FILE=/hijack/.git/index GIT_CONFIG_GLOBAL=/dev/null bun "$FX"
  [ "$status" -eq 0 ]
  # adapter 경로 · 직접 sh("git", …) 경로 둘 다 봉인 + 스크럽. GIT_CONFIG_GLOBAL은 **유지**다
  # (하네스가 그것으로 호스트 전역 설정을 격리한다 — 삭제 allowlist만 두는 이유).
  echo "$output" | grep -q '^adapter TP=0 DIR=unset WT=unset IX=unset CFG=/dev/null$'
  echo "$output" | grep -q '^clone TP=0 DIR=unset WT=unset IX=unset CFG=/dev/null$'
  # 대조군 — git이 아닌 자식에는 주입하지 않는다(주입이 cmd==="git"으로 좁혀져 있다는 증인).
  echo "$output" | grep -q '^nongit TP=unset$'
}

@test "with no credential helper a git exec dies on 'terminal prompts disabled' and the reason names gh auth setup-git" {
  # 실물 git으로 재는 자리 — push 레인은 401을 내는 서버가 있어야 재현되므로, 같은 자격 서브시스템을
  # 직접 두드린다(`git credential fill`: helper가 없으면 사용자명을 터미널에서 묻는다).
  # 호스트 gitconfig의 credential.helper가 결과를 뒤집지 못하게 전역·시스템 설정을 격리한다 —
  # 그 두 변수는 seam이 스크럽하지 않으므로(하네스 의존) 그대로 자식에 도달한다.
  FX_MODE=credfill GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok=false$'
  echo "$output" | grep -q 'terminal prompts disabled'
  echo "$output" | grep -q 'gh auth setup-git'
}

@test "pushReason appends the credential pointer only to credential-family reasons" {
  # 문구 SSOT는 seam의 pushReason 하나다 — 콜사이트 둘(init 첫 push · secrets chain push)이 손으로
  # 복사하면 한쪽만 고쳐진다. 무조건 붙이면 non-fast-forward·DNS 실패까지 자격 문제로 오진한다.
  FX_MODE=pushreason run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^cred=fatal: could not read Username.*terminal prompts disabled.*gh auth setup-git'
  # 대조군 — 거부(rejected) 사유는 사유만 남고 포인터가 붙지 않는다.
  echo "$output" | grep -q '^reject=! \[rejected\] HEAD -> main (fetch first)$'
  reject_line="$(echo "$output" | grep '^reject=')"
  [ -n "$reject_line" ]
  [ "$(printf '%s\n' "$reject_line" | grep -c 'gh auth setup-git')" = "0" ]
}

@test "both push callsites take their reason from the seam helper (no hand-copied wording)" {
  # 정적 증인 — 문구 사본이 콜사이트로 복귀하면 red다. 판정은 **주석을 걷어낸 코드**에서만 한다
  # (형제 가드 child_process와 같은 `sed 's|//.*||'` 관용구): 콜사이트 주석이 SSOT를 지목하는 것은
  # 사본이 아니라 근거다. 양성 대조는 아래 seam 쪽 등식이 진다(같은 술어가 거기서는 매치한다).
  [ "$(grep -c 'GIT_CRED_HINT' tools/lib/exec.ts)" -ge 1 ]
  n=0
  for f in tools/lib/init.ts tools/lib/secrets.ts; do
    [ "$(grep -c 'pushReason(push.err)' "$f")" = "1" ]
    [ "$(grep -c 'firstReason(push.err)' "$f")" = "0" ]
    # 문구 리터럴이 콜사이트 **코드**에 복제되지 않았다(SSOT는 seam 하나).
    [ "$(sed 's|//.*||' "$f" | grep -c 'gh auth setup-git')" = "0" ]
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]   # 열거 바닥값 — 콜사이트 둘이 실제로 돌았다
  [ "$(sed 's|//.*||' tools/lib/exec.ts | grep -c 'gh auth setup-git')" = "1" ]
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
