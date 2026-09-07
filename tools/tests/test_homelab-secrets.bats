#!/usr/bin/env bats
# homelab app secrets — 이중 모드 변이의 프로세스 경계 계약.
# 앱 레포 안(마커 .app-config.yml + canonical remote): 선행 조건(main·클린 트리·canonical) 전부 통과해야
# seal(벤더 tools/seal-secret.mts 위임)→봉인본만 커밋→push→원격 main 도달성 증명→update-secrets
# 디스패치. 하나라도 실패면 **디스패치 없이** 거부. 밖: 디스패치만. 재실행 수렴은 --no-seal(재봉인 없이
# 이미 커밋·push된 봉인본을 재디스패치 — kubeseal 암호문은 매번 달라 "재봉인 후 동일성"으로는 수렴
# 불가). no-op: run 성공 + PR 0 = 정당한 no-op,
# --wait 검증은 main 기준 표면 blob 동치(머지 SHA·PR 요구 없음). 평문 값은 어떤 채널에도 없다.
# 심: 앱 레포 = 임시 실물 git 레포(helpers make_app_repo_fixture), 외부 명령 = PATH stub + NUL 원장.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_kubectl_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  echo "apiVersion: v1" > "$KC"
  make_app_repo_fixture myapp
  # update-secrets 브랜치 PR(미머지) — pulls?head 케이스는 공유라 파일만 덮는다
  printf '[{"number":41,"html_url":"https://github.com/ukyi-app/homelab/pull/41","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
}

# cwd를 인자로 받는 호출 — SEAL_VERSION 기본 2(갱신 경로).
# 하네스는 insteadOf로 canonical→로컬 bare 재배선을 쓰므로 push 라우팅 검사(fail-closed)를 명시
# 플래그로만 완화한다 — 적대 테스트는 플래그 없이 돌아 production 기본 경로를 검증한다.
run_secrets_in() {
  dir="$1"; shift
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    bash -c "cd '$dir' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 $*"
}

@test "in-repo chain: seal, commit only the sealed file, push, prove reachability, then dispatch" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "app secrets" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "chain" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  # 커밋은 봉인본 파일만 — 원격 main이 로컬 HEAD와 같다(도달성)
  [ "$(git -C "$APP_WORK" show --name-only --format= HEAD)" = "deploy/myapp-secrets.sealed.yaml" ]
  [ "$(git -C "$APP_REMOTE" rev-parse main)" = "$(git -C "$APP_WORK" rev-parse HEAD)" ]
  [ "$(echo "$output" | jq -r '.result.chain.headSha')" = "$(git -C "$APP_WORK" rev-parse HEAD)" ]
  [ "$(echo "$output" | jq -r '.result.chain.sealSkipped')" = "false" ]
  # seal 위임 argv = 벤더 도구 계약(tools/README.md seal-secret.mts 절) 그대로 — 드리프트면 red
  run python3 "$LEDGER_PY" exact "$CALLS" seal-secret --config .app-config.yml --env .env --app myapp
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run update-secrets.yaml -R ukyi-app/homelab -f "app=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
  # 브랜치 명명(update-secrets/<app>-<run_id>) 원장 — 다른 4 레인(db·cache·app create·teardown)은
  # 엔진 경로에서 이 조회를 핀하는데 secrets만 빠져 있었다. 값 자체는 단위 테스트가 덮으므로 이 줄이
  # 메우는 공백은 '엔진이 실제로 그 브랜치로 조회한다'는 프로세스 경계 증인이다(run id 701 = 픽스처).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:update-secrets/myapp-701" --jq)" -ge 1 ]
}

@test "chain-mode success and precondition refusal envelopes validate against the schema (floor 2)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/chain.json" 2>/dev/null || true
  printf 'junk\n' > "$APP_WORK/scratch.txt"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/refused.json" 2>/dev/null || true
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const f of ["chain", "refused"]) {
      const env = JSON.parse(readFileSync(process.env.OUTDIR + "/" + f + ".json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(f + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "a dirty tree is refused before seal and before dispatch" {
  printf 'junk\n' > "$APP_WORK/scratch.txt"
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "깨끗"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "a non-main branch is refused without dispatch" {
  git -C "$APP_WORK" checkout -q -b feature/x
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "main"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "a precondition refusal renders seal as not-reached, never as executed (three-state sealSkipped)" {
  # shell-5: 진입 게이트 거부는 chain={mode:"chain"}만 돌려주므로 sealSkipped가 undefined다 —
  # 2상 렌더는 그것을 false와 같이 취급해 seal이 돌지도 않았는데 "seal 실행"이라고 보고했다.
  # 사람용 채널(--json 없음)에서 stdout으로 확인한다.
  git -C "$APP_WORK" checkout -q -b feature/x
  run_secrets_in "$APP_WORK"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "seal 미도달"
  # 구분자까지 포함한 부재 단언 — "seal 실행"이 다른 문맥에서 되살아나도 잡힌다
  [ "$(printf '%s' "$output" | grep -c -- "— seal 실행 ·")" = "0" ]
  # 양성 대조 — 부재 판정이 무증인이 아니다: 같은 렌더가 '연쇄:' 줄 자체는 실제로 낸다
  [ "$(printf '%s' "$output" | grep -c "^연쇄: 앱 레포 안 — ")" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "an app-looking repo with a non-canonical remote is refused fail-closed (no dispatch)" {
  git -C "$APP_WORK" remote set-url origin https://github.com/ukyi-app/otherapp.git
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "canonical"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
}

@test "push-route check is fail-closed by default: the harness rewrite itself is refused without the bypass flag" {
  # run_secrets_in은 우회 플래그를 켠다 — 여기서는 플래그 없이 돌려 production 기본 경로를 검증한다.
  # 하네스의 insteadOf(canonical→로컬 bare)가 push 지향 질의에 그대로 관측되므로 거부여야 한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "push 경로"
  # 거부는 seal 이전·디스패치 이전이다 — 부수효과 0, 원격도 그대로.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "1" ]
}

@test "multiple push destinations are enumerated and a foreign pushurl is refused before seal and dispatch" {
  # 하네스 insteadOf를 걷어내 foreign pushurl 축을 단독 분리한다 — 첫 pushurl(canonical 텍스트)은
  # 재배선 없이 canonical로 관측되므로, 거부의 원인은 오직 두 번째(evil) 목적지다. 관측은 로컬
  # config뿐이라 네트워크 접촉 없이 거부가 성립한다(every 판정도 함께 증명: 하나 통과+하나 실패=거부).
  git -C "$APP_WORK" config --unset-all "url.$APP_REMOTE.insteadOf"
  EVIL_BARE="$BATS_TEST_TMPDIR/evil-remote.git"
  git init -q --bare "$EVIL_BARE"
  git -C "$APP_WORK" config remote.origin.pushurl "https://github.com/ukyi-app/myapp.git"
  git -C "$APP_WORK" config --add remote.origin.pushurl "$EVIL_BARE"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  # 열거가 실재한다 — 오류에 foreign 목적지가 그대로 나타난다.
  echo "$output" | jq -r '.result.error' | grep -qF "$EVIL_BARE"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  # 오귀속 push 0 — evil 원격은 빈 채로 남는다(미구현이면 봉인본 커밋이 여기 실려 red).
  run git -C "$EVIL_BARE" rev-parse main
  [ "$status" -ne 0 ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "1" ]
}

@test "canonical push routes pass the gate without the bypass flag (refusal advances to the next precondition)" {
  # false-positive 회귀 차단 — 재배선을 걷어내면 canonical 경로가 그대로 관측되고, 플래그 없이도
  # 게이트를 '통과'해 다음 선행 조건(클린 트리)에서 거부돼야 한다. 관측은 로컬 config뿐이라
  # push·ls-remote 이전에 거부가 나므로 네트워크 접촉이 없다.
  git -C "$APP_WORK" config --unset-all "url.$APP_REMOTE.insteadOf"
  printf 'junk\n' > "$APP_WORK/scratch.txt"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "깨끗"
  [ "$(echo "$output" | jq -r '.result.error' | grep -c "push 경로")" = "0" ]
}

# ── 연쇄 거부 4레인(티켓 20) — staged-completeness '원형'의 자기 테스트 ────────────────────────
# 손해 모델을 그대로 판정 조건에 옮긴다: foreign 가드가 막는 것은 '잡파일 커밋'이 아니라 **커밋·push가
# 통째로 건너뛰어져 낡은 봉인본으로 디스패치되는 것**이다. 그래서 네 레인 공통 단언은
# 「`gh workflow run` 원장 0건 + 원격 main rev-list 불변」이고, 원격 불변을 재려면 원격이 살아 있어야
# 한다(그래서 push 실패 레인은 rm이 아니라 실행 동안만 옮긴다).

@test "a seal that writes outside the sealed file is refused before commit, push, and dispatch" {
  before="$(git -C "$APP_REMOTE" rev-list --count main)"
  [ "$before" = "1" ]
  export STUB_SEAL_FOREIGN=1
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "봉인본 외"
  # 양성 대조 — env 이름 오타로 '다른 이유의 red'가 되는 것을 막는다(잡파일이 실제로 쓰였다).
  [ -f "$APP_WORK/deploy/junk.yaml" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "$before" ]
  [ "$(git -C "$APP_WORK" rev-list --count HEAD)" = "1" ]
}

@test "a failing seal and a seal that produces no output are both refused without dispatch" {
  before="$(git -C "$APP_REMOTE" rev-list --count main)"
  export STUB_SEAL_FAIL=1
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "seal 실패"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "$before" ]
  unset STUB_SEAL_FAIL
  # 무산출 레인은 봉인본이 **아직 없는** 첫 봉인 상태에서만 도달 가능하다(있으면 existsSync가 참).
  # 로컬 커밋만 하고 push는 하지 않는다 — 그래야 원격 불변 단언이 그대로 산다.
  git -C "$APP_WORK" rm -q "deploy/myapp-secrets.sealed.yaml"
  git -C "$APP_WORK" commit -q -m "drop sealed"
  : > "$CALLS"
  export STUB_SEAL_NO_OUTPUT=1
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "seal 후 봉인본"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "$before" ]
}

@test "a push failure is refused without dispatch and leaves the commit made but unpushed" {
  before="$(git -C "$APP_REMOTE" rev-list --count main)"
  # insteadOf 대상(로컬 bare)을 실행 동안만 치운다 — `rm -rf`면 원격 불변 단언 자체가 불가능해진다.
  mv "$APP_REMOTE" "$APP_REMOTE.hold"
  run_secrets_in "$APP_WORK" --json
  mv "$APP_REMOTE.hold" "$APP_REMOTE"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "git push 실패"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  # 커밋은 됐고 push만 실패한 트리 — 재실행 --no-seal 수렴 경로의 전제다.
  [ "$(git -C "$APP_WORK" rev-list --count HEAD)" = "2" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "$before" ]
}

@test "a local HEAD the remote main does not carry is refused as unproven reachability (no dispatch)" {
  before="$(git -C "$APP_REMOTE" rev-list --count main)"
  # 훅 없이 구성한다(훅은 $STUB 대체 PATH에서 무실행 vacuous가 되기 쉽다): --no-seal은 커밋·push를
  # 건너뛰므로 로컬에만 있는 커밋 하나가 곧 도달성 불일치다.
  git -C "$APP_WORK" commit -q --allow-empty -m "local only"
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "도달성 미증명"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "$before" ]
}

@test "a polluted global git config cannot reach the engine (the same file breaks the chain when honored)" {
  # 형제 appinit는 격리하는데 이 스위트는 안 했다 — 호스트의 commit.gpgsign·url.insteadOf·
  # status.showUntrackedFiles가 엔진의 git 호출에 그대로 스미면 초록이 venue 의존이 된다.
  # 격리는 하네스(cli_stub_init의 GIT_CONFIG_GLOBAL/SYSTEM=/dev/null)가 지고, 이 @test가 그 증인이다.
  POLLUTED="$BATS_TEST_TMPDIR/polluted-gitconfig"
  {
    printf '[commit]\n\tgpgsign = true\n'
    printf '[url "https://evil.invalid/"]\n\tinsteadOf = https://github.com/\n'
    printf '[status]\n\tshowUntrackedFiles = no\n'
  } > "$POLLUTED"
  cp "$POLLUTED" "$BATS_TEST_TMPDIR/.gitconfig"
  # 격리 경로 — HOME에 오염 파일이 있어도 연쇄가 초록이다(격리가 없으면 gpgsign이 커밋을 죽인다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 HOME="$BATS_TEST_TMPDIR" \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  # 양성 대조 — 같은 파일을 GIT_CONFIG_GLOBAL로 **명시**하면 연쇄가 실제로 깨진다(오염이 무해한 게 아니다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 GIT_CONFIG_GLOBAL="$POLLUTED" \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "git commit 실패"
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
}

@test "outside an app repo (no marker) only the dispatch runs — no seal, no git mutation" {
  run_secrets_in "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "dispatch-only" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "1" ]
  # 마커 없는 git 레포(homelab 디렉토리류)도 디스패치만
  OTHER="$BATS_TEST_TMPDIR/other-repo"; git init -q "$OTHER"
  run_secrets_in "$OTHER" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "dispatch-only" ]
}

@test "push succeeded but dispatch failed: rerun with --no-seal converges by dispatching only (no second commit)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_DISPATCH_FAIL=1 \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.chain.sealSkipped')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "false" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "2" ]
}

@test "rerunning WITH reseal is never a silent no-op: a fresh ciphertext means a new commit (reality of kubeseal)" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "3" ]
  # 이름이 약속한 판정 — 엔진 variant가 no-op이 아니다(티켓 04: pushed=true면 no-op 금지).
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result | has("pr")')" = "true" ]
}

@test "a pushed sealed secret can never be reported as no-op: PR listing fixed empty is a failure (exit 1), not exit 0" {
  # 교차 증인(티켓 04): chain이 push했으면 kubeseal 비결정 암호문 = 바이트 변경 = 반드시 PR이다. PR 목록이
  # 계속 []이면(낡은 스냅샷·명명 드리프트) 그것은 no-op의 증거가 아니라 fail-loud 대상이다 — 현행은 no-op exit 0.
  printf '[]\n' > "$FIX/db-prs.json"
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  echo "$output" | jq -r '.result.error' | grep -q "no-op"
  # push와 디스패치는 실제로 일어났다 — 실패는 관측 단계(PR 특정)의 것이다.
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "1" ]
  # 재조회는 여기서도 유한하다(1 + 3).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:update-secrets/myapp-701" --jq)" = "4" ]
}

@test "--no-seal without a committed sealed secret is refused without dispatch" {
  git -C "$APP_WORK" rm -q deploy/myapp-secrets.sealed.yaml
  git -C "$APP_WORK" commit -q -m "drop sealed"
  git -C "$APP_WORK" push -q origin main
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q -- "--no-seal"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "an already-wired sealed secret (--no-seal, dispatcher reports no change) is a no-op: exit 0, no PR, no merge SHA" {
  printf '[]\n' > "$FIX/db-prs.json"
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.result | has("pr")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "false" ]
  # 사람용 렌더의 no-op·chain 분기(티켓 13) — sealSkipped=true·pushed=false가 문구로 실린다.
  echo "$stderr" | grep -q "재봉인 생략(--no-seal)"
  echo "$stderr" | grep -q "커밋 없음"
  echo "$stderr" | grep -q "^결과: no-op$"
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "1" ]
}

@test "no-op with --wait verifies the surface against main at the synced revision (no merge SHA required)" {
  printf '[]\n' > "$FIX/db-prs.json"
  run_secrets_in "$APPS_ROOT" --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].name')" = "myapp-prod" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].surfaceOk')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.applications[0] | has("descendant")')" = "false" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/apps/myapp/deploy/prod/myapp-secrets.sealed.yaml?ref=main" --jq .sha)" -ge 1 ]
  # 바닥값(티켓 01): 이 no-op 경로(mergeSha 없음)가 밟는 픽스처는 **멀티소스** 형상이다 — revisions[]만 있고
  # revision 키 부재. 단일소스로 되돌아가면 이 @test는 앱 레인의 실제 결함을 못 본다(수정 전 red의 자리).
  [ "$(jq -r '.status.sync | has("revisions") and (has("revision") | not)' "$FIX/argocd-app.json")" = "true" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].revision')" = "abc1234" ]
}

@test "no-op with --wait and no KUBECONFIG omits the live section (exit 0)" {
  printf '[]\n' > "$FIX/db-prs.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --wait --json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
}

@test "the secret value never appears on stdout, stderr, or the argv ledger" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "$CANARY")" = "0" ]
  [ "$(printf '%s' "$stderr" | grep -c "$CANARY")" = "0" ]
  [ "$(grep -c "$CANARY" "$CALLS")" = "0" ]
  # 바닥값: 평문 파일에는 실제로 카나리가 있다(단언이 빈 파일을 검사하는 vacuous green 차단)
  [ "$(grep -c "$CANARY" "$APP_WORK/.env")" = "1" ]
}

@test "app secrets goldens pin success, no-op, and omitted variants and validate against the schema (floor 3)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/g-success.json" 2>/dev/null || true
  printf '[]\n' > "$FIX/db-prs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/g-noop.json" 2>/dev/null || true
  env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --wait --json" > "$OUTDIR/g-omitted.json" 2>/dev/null || true
  n=0
  for g in success noop omitted; do
    diff -u "tools/tests/fixtures/homelab/app-secrets-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "noop", "omitted"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-secrets-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "a non-fast-forward push reports the rejection reason, not git's 'To <url>' first line" {
  # 티켓 08 — git push의 stderr는 1행이 `To <url>`(사유 아님)이고 거부 이유는 2행 ` ! [rejected] …`이다.
  # 첫 줄만 자르던 규약이 gh(1행 완결)에는 맞지만 여기서만 틀렸다: 원격이 앞선 상태를 만든다.
  AHEAD="$BATS_TEST_TMPDIR/ahead"
  # bare의 HEAD는 init.defaultBranch 소유(CI 러너는 master) — 픽스처는 main만 push하므로 브랜치를 명시해야 venue 무관.
  git clone -q --branch main "$APP_REMOTE" "$AHEAD"
  git -C "$AHEAD" config user.name "fixture"
  git -C "$AHEAD" config user.email "fixture@example.com"
  git -C "$AHEAD" commit -q --allow-empty -m "remote ahead"
  git -C "$AHEAD" push -q origin main
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "git push 실패"
  echo "$output" | jq -r '.result.error' | grep -q "rejected"
  # 부정 단언(사유 자리에 `To <url>`이 오지 않는다) + 같은 @test 안 양성 대조(같은 검출기가
  # 착지 전 문구 모양에서는 1건을 센다 — 0건이 '검출기 사망'이 아님을 증명).
  [ "$(echo "$output" | jq -r '.result.error' | grep -c "실패 — To ")" = "0" ]
  [ "$(printf '%s\n' "git push 실패 — To https://github.com/ukyi-app/myapp.git" | grep -c "실패 — To ")" = "1" ]
  # 디스패치는 일어나지 않았다(연쇄 실패 = 디스패치 없이 거부).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run update-secrets.yaml)" = "0" ]
}

@test "app secrets rejects a bad app name as a usage error and prints usage on --help" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts app secrets "Bad_Name" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bun tools/homelab.ts app secrets --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--wait"
}
