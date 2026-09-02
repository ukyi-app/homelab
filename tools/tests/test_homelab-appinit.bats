#!/usr/bin/env bats
# homelab app init — 앱 레포 시작 로컬 체인의 프로세스 경계 계약(멱등·재개 가능).
# 이 동사는 불가역 외부 부수효과를 여럿 건넌다(레포 생성·클론·스캐폴드·첫 push·시크릿). 계약:
#   - preflight 실패 시 부수효과 0 (gh repo create·scaffold·secret set 원장 0건).
#   - 소유 증명 = invocation marker(.homelab-init). 마커 없는 기존 레포는 fail-closed(--adopt로만).
#   - 각 부수효과 직후 실패를 주입해도 재실행이 그 지점부터 수렴(멱등).
#   - 시크릿 쌍은 원자적 — 절반 상태를 결과에 명시하고 재실행이 나머지를 수렴. private key 값은 비노출.
# 보조 심: 실물 git(insteadOf로 canonical→로컬 bare) + init 전용 gh stub(make_init_stub).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_init_stub
  # 디스패치 시크릿 키 경로 픽스처 — app-id(비밀 아님) + private-key.pem(CANARY, 출력 금지 단언용).
  SECRETS_DIR="$BATS_TEST_TMPDIR/app-keys"
  mkdir -p "$SECRETS_DIR"
  printf '123456\n' > "$SECRETS_DIR/app-id"
  printf 'PRIVATE-KEY-%s\n' "$CANARY" > "$SECRETS_DIR/private-key.pem"
}

# 하네스는 insteadOf로 canonical→로컬 bare 재배선을 쓰므로, push 라우팅 검사(fail-closed)를
# 명시 플래그로만 완화한다 — 적대 테스트는 이 플래그 없이 돌아 production 기본 경로를 검증한다.
run_init() {
  run --separate-stderr env -C "$INIT_PARENT" PATH="$STUB" \
    GIT_CONFIG_GLOBAL="$INIT_GCFG" GIT_CONFIG_SYSTEM=/dev/null HOME="$BATS_TEST_TMPDIR" \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    "$BUN" "$ROOT/tools/homelab.ts" app init "$@"
}

@test "a fresh init creates a PRIVATE repo, scaffolds, and pushes the marker (default private)" {
  run_init myapp --archetype api --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "app init" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.public')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.created')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.pushed')" = "true" ]
  # 기본 private: repo create argv에 --private(정확), --public 부재.
  run python3 "$LEDGER_PY" exact "$CALLS" gh repo create ukyi-app/myapp --template ukyi-app/homelab-app-template --private
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create ukyi-app/myapp --template ukyi-app/homelab-app-template --public)" = "0" ]
  # 스캐폴더 비대화형 계약 argv(정확).
  run python3 "$LEDGER_PY" exact "$CALLS" scaffold --archetype api --name myapp --yes
  [ "$status" -eq 0 ]
  # 마커가 원격 main에 실재한다(재개 소유 술어의 근거).
  run git -C "$INIT_REMOTES/myapp.git" show main:.homelab-init
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "homelab-app-init"
}

@test "--public opts into a public repo (argv ledger)" {
  run_init mypublic --archetype site --public --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.public')" = "true" ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh repo create ukyi-app/mypublic --template ukyi-app/homelab-app-template --public
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create ukyi-app/mypublic --template ukyi-app/homelab-app-template --private)" = "0" ]
}

@test "a bad archetype is a usage error before any side effect" {
  run_init myapp --archetype bogus --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
}

@test "preflight refuses a missing dispatch-secrets key path with ZERO side effects" {
  run_init myapp --archetype api --dispatch-secrets "$BATS_TEST_TMPDIR/nonexistent" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.checkpoint')" = "preflight" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set)" = "0" ]
}

@test "an existing repo WITHOUT the marker is fail-closed (refused) unless --adopt" {
  # 마커 없는 bare를 미리 만든다(우리가 안 만든 동명 레포 시뮬).
  git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/foreign.git"
  run_init foreign --archetype api --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.checkpoint')" = "preflight" ]
  echo "$output" | jq -r '.result.error' | grep -q -- "--adopt"
  # 소유 미증명 레포에는 어떤 부수효과도 없다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "0" ]
}

@test "a repo carrying a DIFFERENT app's marker is refused (name collision, no adoption)" {
  # myapp 마커를 담은 bare를 다른 이름(collide)에 심는다.
  git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/collide.git"
  wt="$BATS_TEST_TMPDIR/mk"; git clone -q "$INIT_REMOTES/collide.git" "$wt"
  git -C "$wt" config user.name x; git -C "$wt" config user.email x@x
  printf '{"tool":"homelab-app-init","app":"myapp"}\n' > "$wt/.homelab-init"
  git -C "$wt" add -A; git -C "$wt" commit -q -m mark; git -C "$wt" push -q origin HEAD:main
  run_init collide --archetype api --adopt --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "myapp"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "0" ]
}

@test "failure right after repo create (scaffold fails) resumes to convergence with --adopt" {
  # run1: 스캐폴드 실패 주입 → 레포는 생성됐으나 마커 없음(push 전).
  run --separate-stderr env -C "$INIT_PARENT" PATH="$STUB" GIT_CONFIG_GLOBAL="$INIT_GCFG" \
    GIT_CONFIG_SYSTEM=/dev/null HOME="$BATS_TEST_TMPDIR" STUB_SCAFFOLD_FAIL=1 \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    "$BUN" "$ROOT/tools/homelab.ts" app init myapp --archetype api --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.created')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.checkpoint')" = "cloned" ]
  # 마커 미존재(push 전).
  run git -C "$INIT_REMOTES/myapp.git" show main:.homelab-init
  [ "$status" -ne 0 ]
  # run2: 마커 없는 기존 레포라 --adopt로 재개 → 수렴(스캐폴드 성공·push).
  run_init myapp --archetype api --adopt --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.adopted')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.created')" = "null" ]
  [ "$(echo "$output" | jq -r '.result.pushed')" = "true" ]
  run git -C "$INIT_REMOTES/myapp.git" show main:.homelab-init
  [ "$status" -eq 0 ]
}

@test "adding dispatch secrets after a push resumes without re-scaffolding" {
  run_init myapp --archetype api --json
  [ "$status" -eq 0 ]
  # run2: --dispatch-secrets — 마커 존재(소유)라 스캐폴드/push 건너뛰고 시크릿 쌍만 설정.
  run_init myapp --archetype api --dispatch-secrets "$SECRETS_DIR" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.secrets.appId')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.secrets.privateKey')" = "true" ]
  # 두 시크릿 모두 설정됐고, 두 번째 실행에서는 재-스캐폴드가 없다(scaffold 총 1회).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set HOMELAB_DISPATCH_APP_ID)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set HOMELAB_DISPATCH_APP_PRIVATE_KEY)" = "1" ]
}

@test "a half-set secret pair is reported and a re-run converges the missing one" {
  # run1: private key 설정 실패 주입 → App ID만 설정된 절반 상태.
  run --separate-stderr env -C "$INIT_PARENT" PATH="$STUB" GIT_CONFIG_GLOBAL="$INIT_GCFG" \
    GIT_CONFIG_SYSTEM=/dev/null HOME="$BATS_TEST_TMPDIR" STUB_GH_SECRET_FAIL=HOMELAB_DISPATCH_APP_PRIVATE_KEY \
    HOMELAB_TEST_ALLOW_PUSH_REWRITE=1 \
    "$BUN" "$ROOT/tools/homelab.ts" app init myapp --archetype api --dispatch-secrets "$SECRETS_DIR" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.secrets.appId')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.secrets.privateKey')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.checkpoint')" = "pushed" ]
  # run2: 나머지(private key)만 수렴. App ID는 이미 설정돼 재설정하지 않는다.
  run_init myapp --archetype api --dispatch-secrets "$SECRETS_DIR" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.secrets.privateKey')" = "true" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set HOMELAB_DISPATCH_APP_ID)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set HOMELAB_DISPATCH_APP_PRIVATE_KEY)" = "2" ]
}

@test "the private key value never appears in any output or the argv ledger" {
  run_init myapp --archetype api --dispatch-secrets "$SECRETS_DIR" --json
  [ "$status" -eq 0 ]
  # stdout·stderr·NUL 원장 어디에도 CANARY(private key 값)가 없다. ⚠️ `grep -q … && false || true`는
  # 항상 exit 0이라 vacuous(유출돼도 green) — 레포 SSOT 관용구 grep -c=0으로 단언한다(test_homelab-secrets.bats).
  [ "$(printf '%s' "$output" | grep -c "$CANARY")" = "0" ]
  [ "$(printf '%s' "$stderr" | grep -c "$CANARY")" = "0" ]
  run python3 "$LEDGER_PY" dump "$CALLS"
  [ "$(printf '%s' "$output" | grep -c "$CANARY")" = "0" ]
  # 키는 --body-file로만 전달된다(값 아님) — argv에 파일 경로만.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh secret set HOMELAB_DISPATCH_APP_PRIVATE_KEY --repo ukyi-app/myapp --body-file "$SECRETS_DIR/private-key.pem")" = "1" ]
}

@test "ensureClone is owner-aware: a foreign clone ending in the same app name is NOT reused" {
  # cwd에 남의 동명 클론(origin=github.com/someone/myapp)이 있다 — 앱명은 같지만 소유자가 다르다.
  mkdir -p "$INIT_PARENT/myapp"; git -C "$INIT_PARENT/myapp" init -q
  git -C "$INIT_PARENT/myapp" remote add origin https://github.com/someone/myapp.git
  run_init myapp --archetype api --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "수동 확인"
  # 마커·push가 새로 만든 ukyi-app/myapp에 흘러가지 않았다(엉뚱한 레포 오염 방지).
  run git -C "$INIT_REMOTES/myapp.git" show main:.homelab-init
  [ "$status" -ne 0 ]
}

@test "a half-scaffolded clone (config present but scaffold/ remains) re-scaffolds on resume" {
  # 마커 없는 bare(스캐폴드 미완 상태)를 만들고, canonical origin을 가진 클론에 .app-config.yml만
  # 심되 scaffold/는 남긴다(스캐폴더가 config 쓴 뒤 self-delete 전 실패한 반쪽 상태).
  git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/myapp.git"
  git -c "url.$INIT_REMOTES/.insteadOf=https://github.com/ukyi-app/" \
    clone -q https://github.com/ukyi-app/myapp.git "$INIT_PARENT/myapp"
  [ -d "$INIT_PARENT/myapp/scaffold" ]           # 템플릿의 scaffold/ 잔존(미완 표지)
  printf 'kind: web\n' > "$INIT_PARENT/myapp/.app-config.yml"
  # --adopt로 재개 — config가 있어도 scaffold/가 남아 있으면 스캐폴드를 다시 돌려야 한다(2부 사후조건).
  run_init myapp --archetype api --adopt --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  # 스캐폴드가 실제로 (재)실행됐다 — config-only 스킵이면 이 카운트가 0이라 red.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold --archetype api --name myapp --yes)" -ge 1 ]
  # 재실행 후 scaffold/는 제거됐다(스캐폴드 완료).
  run git -C "$INIT_REMOTES/myapp.git" show main:scaffold/scaffold.ts
  [ "$status" -ne 0 ]
}

@test "a half-scaffolded clone that lost scripts.scaffold still re-scaffolds (entry point, not npm script)" {
  # 04 인계의 별건: 스캐폴더는 자기 실행 중에 **package.json을 재작성한다**. 그 뒤 어떤 이유로든
  # (타임아웃·중단·스캐폴더 오류) 죽으면 `scripts.scaffold`가 사라진 채 scaffold/가 남는데, 재개가
  # `bun run scaffold`였다면 그 재호출이 "Script not found"로 **영구히** 실패해 바로 위 재실행 계약이
  # 깨졌다(timeoutMs: 0은 트리거 하나를 없앴을 뿐이다). init은 preflight가 검증한 **진입점 파일**을
  # 직접 부르므로 재개가 package.json 상태에 의존하지 않는다.
  git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/myapp.git"
  git -c "url.$INIT_REMOTES/.insteadOf=https://github.com/ukyi-app/" \
    clone -q https://github.com/ukyi-app/myapp.git "$INIT_PARENT/myapp"
  [ -d "$INIT_PARENT/myapp/scaffold" ]           # 진입점은 살아 있다(계약이 검증한 그 파일)
  printf 'kind: web\n' > "$INIT_PARENT/myapp/.app-config.yml"
  # 스캐폴더가 재작성하고 죽은 상태를 그대로 만든다 — scaffold script만 소실.
  printf '{"name":"myapp","scripts":{"dev":"bun src/index.ts"}}\n' > "$INIT_PARENT/myapp/package.json"
  run grep -qF '"scaffold"' "$INIT_PARENT/myapp/package.json"
  [ "$status" -eq 1 ]                            # 픽스처 실재 — script가 정말 없다(없어야 이 레인이 증언한다)
  run_init myapp --archetype api --adopt --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold --archetype api --name myapp --yes)" -ge 1 ]
  run git -C "$INIT_REMOTES/myapp.git" show main:scaffold/scaffold.ts
  [ "$status" -ne 0 ]                            # 수렴 완료(scaffold/ 제거 후 push)
}

@test "a foreign pushInsteadOf is observed and refused before scaffold and push (no bypass flag)" {
  # 레포는 이미 존재(마커 없음) — --adopt 재개 시나리오로 canonical origin 클론을 준비한다.
  git clone -q --bare "$INIT_REMOTES/homelab-app-template.git" "$INIT_REMOTES/myapp.git"
  git -c "url.$INIT_REMOTES/.insteadOf=https://github.com/ukyi-app/" \
    clone -q https://github.com/ukyi-app/myapp.git "$INIT_PARENT/myapp"
  # 적대 설정: 전역 pushInsteadOf가 canonical 접두를 **실물** evil bare로 재배선한다.
  # origin.url(원본 설정값)은 canonical 그대로라 구성 신원 판정만으로는 이 축이 안 보인다(D1).
  EVIL="$BATS_TEST_TMPDIR/evil-remotes"; mkdir -p "$EVIL"
  git init -q --bare "$EVIL/myapp.git"
  EVIL_GCFG="$BATS_TEST_TMPDIR/evil-gitconfig"
  cat "$INIT_GCFG" > "$EVIL_GCFG"
  printf '[url "%s/"]\n\tpushInsteadOf = https://github.com/ukyi-app/\n' "$EVIL" >> "$EVIL_GCFG"
  # 우회 플래그 없이 실행 — production 기본(fail-closed) 경로.
  run --separate-stderr env -C "$INIT_PARENT" PATH="$STUB" \
    GIT_CONFIG_GLOBAL="$EVIL_GCFG" GIT_CONFIG_SYSTEM=/dev/null HOME="$BATS_TEST_TMPDIR" \
    "$BUN" "$ROOT/tools/homelab.ts" app init myapp --archetype api --adopt --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.checkpoint')" = "cloned" ]
  # 관측된 경로가 pushInsteadOf 전개 결과다 — fetch 지향 질의(ls-remote --get-url)는 이걸 못 본다.
  echo "$output" | jq -r '.result.error' | grep -qF "$EVIL/myapp"
  # 거부는 스캐폴드 이전이다 — 부수효과 0.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "0" ]
  # 오귀속 push 0 — evil 원격은 빈 채로 남는다(미구현이면 마커가 여기 실려 red).
  run git -C "$EVIL/myapp.git" rev-parse main
  [ "$status" -ne 0 ]
  run git -C "$INIT_REMOTES/myapp.git" show main:.homelab-init
  [ "$status" -ne 0 ]
}

@test "a fully complete repo is an idempotent no-op on re-run" {
  run_init myapp --archetype api --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  # 재실행: 이미 완료(마커 존재·시크릿 미요청) → no-op, 부수효과 없음.
  run_init myapp --archetype api --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh repo create)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" scaffold)" = "1" ]
}

@test "app init goldens pin fresh-success, preflight-refusal, and no-op variants (floor 3)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  run_init myapp --archetype api --json
  echo "$output" > "$OUTDIR/g-success.json"
  run_init myapp --archetype api --json
  echo "$output" > "$OUTDIR/g-noop.json"
  # preflight 거부(키 경로 부재) — 결정적.
  run_init other --archetype api --dispatch-secrets /nonexistent-keys --json
  echo "$output" > "$OUTDIR/g-refusal.json"
  n=0
  for g in success noop refusal; do
    diff -u "tools/tests/fixtures/homelab/app-init-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "noop", "refusal"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-init-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "app init prints usage on --help" {
  run bun tools/homelab.ts app init --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--archetype"
  echo "$output" | grep -q -- "--adopt"
  echo "$output" | grep -q -- "--dispatch-secrets"
}

@test "the usage archetype choices derive from platform ARCHETYPES (parity, hand-pinned floor)" {
  run bun -e '
    const { ARCHETYPES } = await import(process.argv[1] + "/tools/lib/platform.ts");
    console.log(ARCHETYPES.join("|"));
  ' "$ROOT"
  [ "$status" -eq 0 ]
  want="$output"
  [ "$want" = "api|fullstack|site|worker" ]
  run bun tools/homelab.ts app init --help
  [ "$status" -eq 0 ]
  # 사용법 줄과 옵션 설명 줄 둘 다 SSOT 순서 그대로다.
  echo "$output" | grep -q -- "--archetype $want "
  echo "$output" | grep -q -- "--archetype <a>    $want "
  # 리터럴 사본 소멸 — homelab.ts에 어휘 리터럴이 없다(양성 대조: SSOT에서는 매치).
  [ "$(grep -c "fullstack" tools/lib/platform.ts)" -ge 1 ]
  [ "$(grep -c "fullstack" tools/homelab.ts)" = "0" ]
}

@test "the scaffold and network call sites of init/secrets pin timeoutMs: 0 (the seam default would SIGTERM them)" {
  # exec seam 기본은 30s이고 "느린 경로는 콜사이트가 올린다"가 그 계약인데, 이 다섯 자리는 결정된
  # 적이 없었다. 스캐폴드는 lock 재생성 `bun install`을 품어 30s를 넘으면 SIGTERM이 scaffold.ts의
  # rollback **전에** 트리를 죽이고 package.json이 재작성된 채 남는다(그 상태에서의 재개는 이제 위
  # "lost scripts.scaffold" 레인이 증언한다 — 진입점 직접 호출). clone/push/`gh repo create`도 같은 망 왕복이다.
  # 증인이 정적 대조인 이유: bun 스텁 sleep 레인은 스위트 벽시계를 늘리고 timeoutMs 주입 심이 없어
  # stub-env 흉내가 된다(원 처방이 그 레인을 기각했다).
  # 첫 줄은 비공허 바닥값 — 네 콜사이트가 실재해야 아래 등식이 뜻을 갖는다(리네임되면 red).
  [ "$(grep -cE '(sh\("gh", \["repo", "create"|sh\("bun", \[SCAFFOLD_ENTRY|sh\("git", \["clone"|git\(dest, \["push")' tools/lib/init.ts)" -eq 4 ]
  [ "$(grep -cE '(sh\("gh", \["repo", "create"|sh\("bun", \[SCAFFOLD_ENTRY|sh\("git", \["clone"|git\(dest, \["push").*timeoutMs: 0' tools/lib/init.ts)" -eq 4 ]
  [ "$(grep -cE 'git\(cwd, \["push".*timeoutMs: 0' tools/lib/secrets.ts)" -eq 1 ]
}
