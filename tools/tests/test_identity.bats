#!/usr/bin/env bats
# dry-6: 앱-이름 regex SSOT(tools/lib/identity.ts). 4종 분기 regex를 validator 정책으로 수렴.
# trailing hyphen 금지(`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`). 모든 mutator 콜사이트가 동일 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정.
# ⚠️ 부재 단언("인라인 잔존 0")은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 tools/*.ts
#    단일·다중 **파일**이라 그것으로 닫힌다. 이 파일의 술어는 전부 "콜사이트에서 사라졌는가"라
#    콜사이트가 리네임되면 `-ne 0`이 SSOT 수렴을 증명하지 않고도 초록이 된다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
# ⚠️ **SSOT 축은 닫혔다**(감사 3라운드): setup()이 identity.ts 실재를, 정적 로스터 레인(#2·#6·#7·#15)이
#    각자 인용하는 **심볼의 export 실재**를 진다. 남은 열린 축은 콜사이트 로스터(파일 목록)가
#    손 관리라는 점 하나다 — 열거 파생은 별건.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  # SSOT 실재 — 이 파일의 술어는 전부 identity.ts를 전제한다. 정적 로스터 레인(#2·#6·#7·#15)은
  # "콜사이트에서 인라인 regex가 사라졌는가"만 보므로 SSOT가 통째로 없어도 초록이었다(실측).
  [ -f "$ROOT/tools/lib/identity.ts" ]
}

@test "identity exports APP_NAME_RE with the validator policy (no trailing hyphen, 2..40)" {
  run bun -e '
    import { APP_NAME_RE } from "./tools/lib/identity.ts";
    const ok = ["ab", "blog", "my-app", "a"+"b".repeat(38)+"c"];        // 길이 2..40, 유효
    const bad = ["a", "-bad", "bad-", "Bad", "ab_c", "x".repeat(41)];   // 1글자/선후행 하이픈/대문자/언더스코어/길이초과
    for (const s of ok)  if (!APP_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (APP_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "every mutator callsite imports APP_NAME_RE from lib/identity (no inline app-name regex left)" {
  # 6 콜사이트가 분기 regex 대신 SSOT를 쓴다 — 인라인 `[a-z][a-z0-9-]{1,29}`/`{0,40}` 잔존 0.
  # lib/status.ts는 mutator가 아니지만 app으로 경로·리소스명을 조립하는 리더라 같은 게이트를 지난다
  # (identity.ts 헤더 소유 — 앱-이름 소비자 중 APP_NAME_RE 밖은 0곳이어야 한다).
  run grep -nE 'a-z0-9-\]\{1,29\}|a-z0-9-\]\{0,40\}' \
    tools/create-app.ts tools/teardown-app.ts tools/bump-tag.ts
  [ "$status" -eq 1 ]   # grep이 아무것도 못 찾아야(=잔존 0) status==1
  # ⚠️ 이 레인이 인용하는 **심볼**의 export 실재 — 부재 단언과 import 줄만으로는 SSOT가
  #    `APP_NAME_RE_X`로 리네임돼도 초록이다(실측). `\b`가 `_X` 접미를 가른다.
  run grep -qE '^export const APP_NAME_RE\b' tools/lib/identity.ts
  [ "$status" -eq 0 ]
  for f in tools/create-app.ts tools/teardown-app.ts tools/validate-mutation.ts tools/activate-app.ts tools/bump-tag.ts tools/lib/status.ts; do
    # ⚠️ 피연산자를 **import 줄**로 좁힌다 — `grep -q identity.ts`는 그 파일의 *주석* 한 줄에도
    #    매치해, 인라인 regex로 되돌린 뮤테이션에서 초록이 났다(실측). cf. 「정적 증인의 두 함정」
    run grep -qE '^import .*from "[./a-z]*identity\.ts";' "$f"
    [ "$status" -eq 0 ]
  done
}

@test "teardown-app now rejects a trailing-hyphen app name (policy tightened)" {
  # ⚠️ `-ne 0`만으로는 「정책이 거부했다」와 「도구/SSOT가 사라져 bun이 죽었다」가 겹친다(실측:
  #    tools/lib/identity.ts를 지워도 이 레인이 초록이었다). 피연산자 실재 + 거부 문구로 가른다.
  [ -f tools/teardown-app.ts ]
  run bun tools/teardown-app.ts --app bad- --dry-run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'usage: teardown-app --app'
}

@test "identity exports RESOURCE_NAME_RE (no trailing hyphen, 1..30, single-char ok)" {
  run bun -e '
    import { RESOURCE_NAME_RE } from "./tools/lib/identity.ts";
    const ok  = ["a", "db1", "my-cache", "x".repeat(30)];          // 1자/kebab/30자 유효
    const bad = ["-x", "x-", "Bad", "a_b", "x".repeat(31)];        // 선후행 하이픈/대문자/언더스코어/31자
    for (const s of ok)  if (!RESOURCE_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (RESOURCE_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "identity exports EXT_RE (postgres extension names allow underscore)" {
  run bun -e '
    import { EXT_RE } from "./tools/lib/identity.ts";
    const ok  = ["pg_trgm", "uuid-ossp", "postgis"];
    const bad = ["-x", "Bad", "a b", "a;b"];
    for (const s of ok)  if (!EXT_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (EXT_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "resource callsites import RESOURCE_NAME_RE (no inline loose resource regex left)" {
  # 느슨한 ^[a-z][a-z0-9-]*$ 가 리소스 검증 파일에서 사라졌는지(seal-secret.mts는 secret 키名이라 제외)
  run grep -nE '\^\[a-z\]\[a-z0-9-\]\*\$' \
    tools/db-url.ts tools/cache-url.ts tools/teardown-resource.ts tools/validate-mutation.ts
  [ "$status" -eq 1 ]
  # 인용 심볼의 export 실재(#2와 같은 형태) — 로스터 레인은 SSOT 리네임에 눈이 멀다.
  run grep -qE '^export const RESOURCE_NAME_RE\b' tools/lib/identity.ts
  [ "$status" -eq 0 ]
  for f in teardown-resource validate-mutation provision-db provision-cache; do
    run grep -q "lib/identity.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
  # db-url/cache-url은 엔진 껍데기(티켓 08) — 이름 검증은 conn-url 엔진 술어가 identity SSOT를
  # 소유하고, bin은 엔진을 경유한다(직수입 대신 위임 — 분기 없는 단일 판정은 유지된다).
  for f in db-url cache-url; do
    run grep -q "lib/conn-url.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
}

@test "EXT_RE has no inline duplicate left (validate-mutation, provision-db)" {
  # 이 @test에는 형제 단언이 없다 — `-ne 0`이면 두 파일이 함께 리네임돼도 혼자 초록으로 남는다
  run grep -nE 'a-z0-9_-\]\*\$/' tools/validate-mutation.ts tools/provision-db.ts
  [ "$status" -eq 1 ]
  # 인용 심볼의 export 실재(#2와 같은 형태) — 형제 단언이 없는 레인이라 더 필요하다.
  run grep -qE '^export const EXT_RE\b' tools/lib/identity.ts
  [ "$status" -eq 0 ]
}

@test "provision-cache now rejects a >30-char name (29->30 tightening consistent)" {
  [ -f tools/provision-cache.ts ]
  run bun tools/provision-cache.ts --name "$(printf 'a%.0s' {1..31})" --dry-run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '::error::provision-cache: 이름 형식 불량'
}

@test "teardown-resource now rejects a trailing-hyphen resource name" {
  [ -f tools/teardown-resource.ts ]
  run bun tools/teardown-resource.ts --db bad- --dry-run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'teardown-resource: 이름 형식 불량'
}

@test "provision-db still validates --cluster after NAME_RE removal (F10)" {
  [ -f tools/provision-db.ts ]
  run bun tools/provision-db.ts --name blog --cluster 'Bad Cluster' --dry-run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '::error::provision-db: cluster 형식 불량'
}

@test "resourceNameError flags db reserved names and cache -ro suffix" {
  run bun -e '
    import { resourceNameError } from "./tools/lib/identity.ts";
    if (resourceNameError("db", "blog") !== null) { console.error("valid db rejected"); process.exit(1); }
    if (resourceNameError("db", "postgres") === null) { console.error("reserved db accepted"); process.exit(1); }
    if (resourceNameError("cache", "widget") !== null) { console.error("valid cache rejected"); process.exit(1); }
    if (resourceNameError("cache", "foo-ro") === null) { console.error("cache -ro accepted"); process.exit(1); }
    if (resourceNameError("db", "foo-ro") === null) { console.error("db -ro accepted (F8)"); process.exit(1); }
    if (resourceNameError("db", "bad-") === null) { console.error("trailing hyphen accepted"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "isCanonicalClone anchors host+scheme and rejects every divergence axis" {
  run bun -e '
    import { isCanonicalClone } from "./tools/lib/identity.ts";
    const O = "ukyi-app", A = "myapp";
    const ok = [
      "https://github.com/ukyi-app/myapp",          // https
      "https://github.com/ukyi-app/myapp.git",      // https + .git
      "git@github.com:ukyi-app/myapp.git",          // scp-like ssh
      "ssh://git@github.com/ukyi-app/myapp",        // ssh scheme
      "  https://github.com/ukyi-app/myapp.git\n",  // 관측값 trim
    ];
    const bad = [
      "https://gitlab.com/ukyi-app/myapp.git",           // foreign host
      "git@gitlab.com:ukyi-app/myapp.git",                // foreign host (ssh)
      "https://github.com/someone/myapp.git",             // foreign owner
      "https://github.com/foo/ukyi-app/myapp.git",        // 경로 중첩(접미 매치가 통과시키던 축)
      "https://user@github.com/ukyi-app/myapp.git",       // credential 포함
      "ssh://git@github.com:2222/ukyi-app/myapp.git",     // 포트 명시
      "https://github.com/ukyi-app/myapp2.git",           // 다른 앱
      "/srv/mirrors/ukyi-app/myapp.git",                  // 로컬 경로(재배선 산물)
      "",
    ];
    for (const s of ok)  if (!isCanonicalClone(O, A, s)) { console.error("FALSE NEG:", JSON.stringify(s)); process.exit(1); }
    for (const s of bad) if (isCanonicalClone(O, A, s))  { console.error("FALSE POS:", JSON.stringify(s)); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "isSafePushRoute requires every route canonical and is fail-closed on zero routes" {
  run bun -e '
    import { isSafePushRoute } from "./tools/lib/identity.ts";
    const O = "ukyi-app", A = "myapp";
    const C = "https://github.com/ukyi-app/myapp.git";
    if (isSafePushRoute(O, A, []))                       { console.error("0개 경로 통과(fail-open)"); process.exit(1); }
    if (!isSafePushRoute(O, A, [C]))                     { console.error("canonical 단일 거부"); process.exit(1); }
    if (!isSafePushRoute(O, A, [C, "git@github.com:ukyi-app/myapp.git"])) { console.error("canonical 복수 거부"); process.exit(1); }
    if (isSafePushRoute(O, A, [C, "/tmp/evil/myapp.git"])) { console.error("foreign 섞임 통과 — every가 아니다"); process.exit(1); }
    if (isSafePushRoute(O, A, ["/tmp/evil/myapp.git"]))    { console.error("foreign 단일 통과"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "pushRouteError distinguishes observation failure from non-canonical and passes canonical routes" {
  run bun -e '
    import { pushRouteError } from "./tools/lib/identity.ts";
    const O = "ukyi-app", A = "myapp";
    const C = "https://github.com/ukyi-app/myapp.git";
    if (pushRouteError(O, A, [C]) !== null)            { console.error("canonical 거부"); process.exit(1); }
    const obs = pushRouteError(O, A, null);
    if (obs === null || !obs.includes("관측 실패"))     { console.error("null 진단 불량"); process.exit(1); }
    const bad = pushRouteError(O, A, [C, "/tmp/evil.git"]);
    if (bad === null || !bad.includes("/tmp/evil.git")) { console.error("foreign 경로 미표기"); process.exit(1); }
    if (pushRouteError(O, A, []) === null)              { console.error("0개 통과(fail-open)"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "executors use shared reserved policy (no local RESERVED/-ro check left)" {
  # 인용 심볼의 export 실재(#2와 같은 형태) — 콜사이트가 `resourceNameError`를 부른다는 증인은
  # SSOT 쪽에 그 이름의 export가 남아 있을 때만 "공유 정책"을 뜻한다.
  run grep -qE '^export function resourceNameError\b' tools/lib/identity.ts
  [ "$status" -eq 0 ]
  run grep -Fq 'resourceNameError' tools/provision-db.ts;        [ "$status" -eq 0 ]
  run grep -Fq '"streaming_replica"' tools/provision-db.ts;      [ "$status" -eq 1 ]   # 로컬 RESERVED 리터럴 제거
  run grep -Fq '/-ro$/' tools/provision-db.ts;                   [ "$status" -eq 1 ]   # provision-db 로컬 -ro 제거(F8)
  # ⚠️ provision-cache.ts는 이 @test에서 여기서만 읽힌다 — 형제 양성 단언(resourceNameError)이 없어
  #    `-ne 0`에서는 그 파일이 사라져도 "로컬 -ro 제거됨"으로 읽혔다
  run grep -Fq '/-ro$/' tools/provision-cache.ts;                [ "$status" -eq 1 ]   # provision-cache 로컬 -ro 제거
  run grep -Fq 'resourceNameError' tools/validate-mutation.ts;   [ "$status" -eq 0 ]
}
