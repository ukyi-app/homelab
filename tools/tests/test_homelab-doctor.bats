#!/usr/bin/env bats
# homelab doctor — 플랫폼 전제 진단의 프로세스 경계 계약.
# 하네스: PATH stub(gh + 시스템 도구 심링크) + argv 원장(NUL 구분·RS 종단) — helpers/cli_stub.bash.
# 네트워크 0: gh 응답은 전부 stub이 낸다. 골든 JSON은 tools/tests/fixtures/homelab/이 SSOT이고
# 스키마 검증은 test_homelab-cli.bats(계약)와 이 파일(골든)이 나눠 가진다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
#
# ── git venue 고정(티켓 14) ────────────────────────────────────────────────────────────────────
# doctor는 커밋 신원·https 자격 helper를 **실물 git**에 물어본다. 그 답은 호스트 ~/.gitconfig와
# GIT_AUTHOR_*/GIT_COMMITTER_* env에 종속이라, 고정하지 않으면 "내 노트북에서는 초록, CI에서만 red"가
# 된다. 그래서 모든 레인이 `$GITENV`를 앞에 달아 전역/시스템 config를 격리 파일로 고정하고 env 신원
# 4종을 지운다. ⚠️ `env`의 옵션(-u)은 할당보다 **앞**이어야 한다 — 뒤에 두면 GNU env가 `-u`를 명령
# 이름으로 읽어 exit 127로 죽는다(실측).
# 로컬 config(레포 .git/config)까지 배제해야 하는 레인(신원/자격 **부재** 판정)은 레포 밖에서 돈다 —
# 체크아웃에 user.email이 있으면 부재 레인이 조용히 pass로 뒤집힌다.
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_git_stub
  make_kubeseal_stub
  make_kubectl_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  echo "apiVersion: v1" > "$KC"
  # 초록 레인의 git 전제 — 커밋 신원 + GitHub https 자격 helper를 격리 전역 config에 심는다.
  DOC_GCFG="$BATS_TEST_TMPDIR/doctor-gitconfig"
  {
    printf '[user]\n\tname = doctor-fixture\n\temail = doctor@example.invalid\n'
    printf '[credential "https://github.com"]\n\thelper = doctor-fixture-helper\n'
  } > "$DOC_GCFG"
  GITENV=(-u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL
    GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL="$DOC_GCFG")
}

@test "doctor human mode reports every check with a status mark on stdout and exits 0 when green" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor
  [ "$status" -eq 0 ]
  n=0
  for id in gh-auth gh-version gh-owner gh-scopes bun git kubeseal kubectl git-identity git-credential kubeconfig template-access template-scaffold-contract template-targetarch; do
    echo "$output" | grep -q "^✓ $id"
    n=$((n+1))
  done
  # 열거 바닥값: 점검 14항목 전부 확인(루프 붕괴 → vacuous green 차단)
  [ "$n" -eq 14 ]
  echo "$output" | grep -q "진단 결과"
}

@test "doctor --json emits exactly one schema-valid object on stdout with human text on stderr" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.exitCode')" = "$status" ]
  [ "$(echo "$output" | jq -r '.result.checks | length')" = "14" ]
  [ "$(echo "$output" | jq -r '[.result.checks[].status] | unique | join(",")')" = "pass" ]
  echo "$stderr" | grep -q "진단 결과"
}

@test "doctor --json all-green output matches the golden success fixture byte-for-byte" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/actual.json"
  diff -u tools/tests/fixtures/homelab/doctor-success.golden.json "$BATS_TEST_TMPDIR/actual.json"
}

@test "doctor --json failure scenario matches golden and exits 1 (owner mismatch, kubeseal missing, fullstack un-parameterized, KUBECONFIG unset)" {
  rm -f "$STUB/kubeseal"
  printf 'FROM oven/bun:1\nRUN bun build --compile --target=bun-linux-arm64\n' > "$FIX/Dockerfile.fullstack"
  run --separate-stderr env -u KUBECONFIG "${GITENV[@]}" PATH="$STUB" STUB_OWNER="other-owner" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.exitCode')" = "$status" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .status')" = "fail" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeseal") | .status')" = "fail" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "warn" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="template-targetarch") | .detail' | grep -q "fullstack"
  # 티켓 33 — detail은 '다음에 무엇을 하나'를 지목한다: 도구 부재는 호스트 도구 핀 런북,
  # KUBECONFIG 미설정은 레포 루트 기준 export 한 줄(결정성 규약대로 절대경로 대신 $PWD 상대).
  echo "$output" | jq -r '.result.checks[] | select(.id=="kubeseal") | .detail' | grep -q "docs/runbooks/toolchain.md"
  echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .detail' | grep -q 'export KUBECONFIG=\$PWD/infra/k3s-bootstrap/kubeconfig'
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/actual.json"
  diff -u tools/tests/fixtures/homelab/doctor-failure.golden.json "$BATS_TEST_TMPDIR/actual.json"
}

@test "golden fixtures validate against the checked-in result schema (envelope + doctorResult, floor 2)" {
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const f of ["doctor-success", "doctor-failure"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/" + f + ".golden.json", "utf8"));
      const errs = [
        ...schemaErrors(env, sch, sch),
        ...schemaErrors(env.result, sch.definitions.doctorResult, sch),
      ];
      if (errs.length) { console.error(f + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "golden details carry no run-varying value (no absolute path, epoch, or address)" {
  # 결정적 출력 계약(doctor.ts 헤더) — detail에 절대경로·시각·지문·이메일이 섞이면 골든이 환경마다
  # 달라지고, 그 순간 골든은 계약이 아니라 잡음이 된다. 양성 대조는 아래 floor 2 + 라벨 매치.
  n=0
  for g in doctor-success doctor-failure; do
    jq -r '.result.checks[].detail' "tools/tests/fixtures/homelab/$g.golden.json" > "$BATS_TEST_TMPDIR/details-$g.txt"
    # 비공허 바닥값 + 양성 대조 — 이 파일에 실제로 detail이 들어 있다(부재 단언이 빈 파일 위에서
    # 공허해지지 않게). 바닥값이 없으면 골든이 통째로 비어도 아래 부재 판정이 초록으로 남는다.
    [ -s "$BATS_TEST_TMPDIR/details-$g.txt" ]
    grep -q "PATH" "$BATS_TEST_TMPDIR/details-$g.txt"
    run grep -nE '(^|[^$])/(home|Users|tmp|var)/|@[A-Za-z0-9.-]+\.(com|invalid|local)|[0-9]{10}' "$BATS_TEST_TMPDIR/details-$g.txt"
    [ "$status" -eq 1 ]
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
}

@test "gh auth failure fail-closes dependent checks without further gh calls" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_GH_UNAUTH=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .status')" = "fail" ]
  n=0
  for id in gh-version gh-owner gh-scopes template-access template-scaffold-contract template-targetarch; do
    [ "$(echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .status')" = "fail" ]
    echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .detail' | grep -q "판정 불가"
    n=$((n+1))
  done
  [ "$n" -eq 6 ]
  # 상한이 이 @test의 본론이다 — gh가 못 쓰는 상태에서 doctor가 추가 gh 호출을 만들지 않는다
  # (오프라인·rate limit 소진에서 같은 실패를 반복하지 않는다). gh-version이 blocked인 이유가 이것이다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
}

@test "a missing gh binary is diagnosed as installation, never as missing authentication" {
  rm -f "$STUB/gh"
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .status')" = "fail" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .detail' > "$BATS_TEST_TMPDIR/gh-auth.txt"
  grep -q "설치 필요" "$BATS_TEST_TMPDIR/gh-auth.txt"
  # 배타성 — 부재를 '인증 부재'로 뭉개면 처방이 통째로 틀린다(gh auth login은 설치가 먼저다).
  run grep -qF "인증 부재" "$BATS_TEST_TMPDIR/gh-auth.txt"
  [ "$status" -eq 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
}

@test "a server-answered gh failure is not prescribed as gh auth login (unauth lane is the control)" {
  # 서버가 응답한 실패(401·403 rate limit 소진·권한)는 '자격 부재'가 아니다 — `gh api -i`는 비-2xx에서도
  # 상태줄을 stdout에 낸다(라이브 실측). 그 형상이 두 진단을 가르는 유일한 원료다.
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_GH_HTTP_ERR=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .detail' > "$BATS_TEST_TMPDIR/http-err.txt"
  grep -q "Bad credentials" "$BATS_TEST_TMPDIR/http-err.txt"
  grep -q "서버가 응답" "$BATS_TEST_TMPDIR/http-err.txt"
  run grep -qF "gh auth login" "$BATS_TEST_TMPDIR/http-err.txt"
  [ "$status" -eq 1 ]
  # 양성 대조(같은 @test) — rc 4 + stdout 공백 레인은 정확히 반대다.
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_GH_UNAUTH=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .detail' > "$BATS_TEST_TMPDIR/unauth.txt"
  grep -q "gh auth login" "$BATS_TEST_TMPDIR/unauth.txt"
  run grep -qF "Bad credentials" "$BATS_TEST_TMPDIR/unauth.txt"
  [ "$status" -eq 1 ]
}

@test "gh-owner 404 names the org-level variable possibility (not a blanket permission error)" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_OWNER_404=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .status')" = "fail" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .detail' > "$BATS_TEST_TMPDIR/owner-404.txt"
  grep -q "org" "$BATS_TEST_TMPDIR/owner-404.txt"
  grep -q "404" "$BATS_TEST_TMPDIR/owner-404.txt"
}

@test "an outdated gh warns because the contract surfaces are version-bound" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_GH_VERSION=2.20.0 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-version") | .status')" = "warn" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-version") | .detail' | grep -q "2.40"
  # 양성 대조 — 기본 스텁 버전은 pass다(경고가 항상 켜져 있는 게 아니다).
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-version") | .status')" = "pass" ]
}

@test "missing scopes header degrades to warn (fine-grained PAT is statically undecidable)" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_NO_SCOPES_HEADER=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .status')" = "warn" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
}

@test "insufficient token scopes fail naming the missing ones" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_SCOPES="gist, read:org" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .status')" = "fail" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .detail' | grep -q "repo"
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .detail' | grep -q "workflow"
}

@test "empty HOMELAB_OWNER variable fails closed (actor-guard parity)" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_OWNER="" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .status')" = "fail" ]
}

@test "KUBECONFIG pointing at a missing file is a fail (misconfiguration, not omission)" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$BATS_TEST_TMPDIR/no-such-file" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "fail" ]
}

@test "a colon-separated KUBECONFIG list is read the way kubectl reads it (all, some, empty segment)" {
  # kubectl은 KUBECONFIG를 `a:b` 병합 목록으로 읽는다 — existsSync("a:b")는 false라 단일 경로 판정은
  # 정당한 설정을 red로 만든다(observe-5·exec-11).
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC:$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "pass" ]
  # 빈 세그먼트(끝의 콜론)는 경로가 아니다 — 제거하지 않으면 "" 가 부재 경로로 세어진다.
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC:" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "pass" ]
  # 일부만 부재 = kubectl은 그 항목을 건너뛰고 나머지로 동작한다 → warn(전부 부재의 fail과 층이 다르다).
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC:$BATS_TEST_TMPDIR/absent-kc" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "warn" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .detail' > "$BATS_TEST_TMPDIR/kc-detail.txt"
  grep -q "일부" "$BATS_TEST_TMPDIR/kc-detail.txt"
  # 결정적 출력 계약 — 경로는 detail에 싣지 않는다(양성 대조는 바로 위 '일부' 매치).
  run grep -qF "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/kc-detail.txt"
  [ "$status" -eq 1 ]
}

@test "a missing kubectl is a fail under KUBECONFIG and a warn without it (live consumers are all gated)" {
  rm -f "$STUB/kubectl"
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubectl") | .status')" = "fail" ]
  run --separate-stderr env -u KUBECONFIG "${GITENV[@]}" PATH="$STUB" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubectl") | .status')" = "warn" ]
}

@test "a missing git fails and blocks the two git-derived checks (fail-closed, not silently passing)" {
  rm -f "$STUB/git"
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git") | .status')" = "fail" ]
  n=0
  for id in git-identity git-credential; do
    [ "$(echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .status')" = "fail" ]
    echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .detail' | grep -q "판정 불가"
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
}

@test "commit identity and https credential helper are each diagnosed, with a both-present control" {
  # 레포 밖에서 돈다 — 체크아웃 .git/config의 user.email이 있으면 '신원 부재' 레인이 조용히 뒤집힌다.
  cd "$BATS_TEST_TMPDIR"
  ID_ONLY="$BATS_TEST_TMPDIR/gc-id-only"
  printf '[user]\n\tname = a\n\temail = a@example.invalid\n' > "$ID_ONLY"
  CRED_ONLY="$BATS_TEST_TMPDIR/gc-cred-only"
  printf '[credential "https://github.com"]\n\thelper = only-helper\n' > "$CRED_ONLY"
  # ① 둘 다 부재
  run --separate-stderr env "${GITENV[@]}" GIT_CONFIG_GLOBAL=/dev/null PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-identity") | .status')" = "warn" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-credential") | .status')" = "warn" ]
  # ② 신원만 있고 helper 부재
  run --separate-stderr env "${GITENV[@]}" GIT_CONFIG_GLOBAL="$ID_ONLY" PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-identity") | .status')" = "pass" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-credential") | .status')" = "warn" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="git-credential") | .detail' | grep -q "gh auth setup-git"
  # ③ helper만 있고 신원 부재
  run --separate-stderr env "${GITENV[@]}" GIT_CONFIG_GLOBAL="$CRED_ONLY" PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-identity") | .status')" = "warn" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-credential") | .status')" = "pass" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="git-identity") | .detail' > "$BATS_TEST_TMPDIR/git-id.txt"
  grep -q "커밋" "$BATS_TEST_TMPDIR/git-id.txt"
  # 값 비노출 — 신원 문자열(이메일)은 detail에 싣지 않는다(양성 대조는 바로 위 '커밋' 매치).
  run grep -qF "@" "$BATS_TEST_TMPDIR/git-id.txt"
  [ "$status" -eq 1 ]
  # ④ 대조군 — 둘 다 있으면 둘 다 pass
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-identity") | .status')" = "pass" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="git-credential") | .status')" = "pass" ]
}

@test "template repo that is not a template fails template-access" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" STUB_IS_TEMPLATE=false "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="template-access") | .status')" = "fail" ]
}

@test "scaffolder without the non-interactive contract markers fails template-scaffold-contract" {
  printf 'const interactiveOnly = true;\n' > "$FIX/scaffold.ts"
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="template-scaffold-contract") | .status')" = "fail" ]
}

@test "doctor is observation-only: gh calls are reads and git calls are read verbs" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" observation-only "$CALLS"
  [ "$status" -eq 0 ]
  # 바닥값 — git 레코드가 실제로 원장에 있다(래퍼가 죽으면 위 판정이 공허해진다).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" git)" = "2" ]
}

@test "doctor fetches exactly 4 template files and never the site Dockerfile (arch-neutral exclusion)" {
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api repos/ukyi-app/homelab-app-template/contents/scaffold/scaffold.ts --jq .content)" = "1" ]
  n=0
  for a in api fullstack worker; do
    c="$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/$a/Dockerfile" --jq .content)"
    [ "$c" = "1" ]
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/site/Dockerfile --jq .content)" = "0" ]
  # 총 호출 상한 겸 바닥값: user 1 + 버전 1 + owner 변수 1 + 템플릿 메타 1 + 컨텐츠 4 = 8 (미지의 추가 호출 차단)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "8" ]
}

@test "doctor works from outside the repository (resolves its own location)" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr env "${GITENV[@]}" PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
}
