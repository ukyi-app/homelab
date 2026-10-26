#!/usr/bin/env bash
# tools/tf-github.sh 시험(bun run ci의 한 단계). 실제 GitHub·R2·Infisical 없이 gh·infisical·terraform을 가짜로 바꿔
# 래퍼의 거부 규칙만 본다(설계 E5 검증: delete_repo 토큰, 빈 범위, 만료 없는 PAT, delete plan, 미추적 override).
# 가짜 terraform은 자기 환경이 허용 목록뿐인지, 가짜 infisical은 이름 조회만 받는지 본다.
# 실제 plan·apply 경로는 owner가 첫 apply 때 확인한다.
set -euo pipefail
export LC_ALL=C

# 래퍼는 Infisical 백업 폴더를 쓰기 불가(0500)로 두고 실제로 못 쓰는지 확인한다. root는 그 모드를 무시해 래퍼가
# 늘 멈춘다(의도). 그래서 이 시험은 비특권 사용자로만 돈다. CI 러너와 owner 기기는 비특권이다.
if [[ $(id -u) == 0 ]]; then
  echo "tf-github.test.sh: root에서는 돌릴 수 없다. 비특권 사용자로 실행한다" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
wrapper="$here/tf-github.sh"
t=$(mktemp -d)
trap 'chmod -R u+w "$t" 2>/dev/null; rm -rf "$t"' EXIT

# origin(main에 infra/github)과 작업 사본.
# 러너의 git 기본 브랜치는 master일 수 있다. main을 명시한다.
git init -q --bare -b main "$t/origin.git"
git init -q -b main "$t/seed"
mkdir -p "$t/seed/infra/github"
echo 'terraform {}' >"$t/seed/infra/github/main.tf"
# 래퍼는 clone한 사본의 자기 자신으로 다시 실행한다. 사본에도 같은 래퍼를 둔다.
mkdir -p "$t/seed/tools"
cp "$wrapper" "$t/seed/tools/tf-github.sh"
git -C "$t/seed" add -A
git -C "$t/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
git -C "$t/seed" push -q "$t/origin.git" main
git clone -q -b main "$t/origin.git" "$t/work"

mkdir -p "$t/bin" "$t/home"
# 래퍼는 github.com에서 새로 clone한다. 시험에서는 그 clone만 로컬 bare 저장소로 돌린다(그 밖의 git 호출은 진짜 git).
# 가짜 git은 래퍼가 넘긴 환경(전역 설정 끔, hook 끔)을 그대로 확인한다.
real_git=$(command -v git)
cat >"$t/bin/git" <<EOF
#!/usr/bin/env bash
args=("\$@")
for i in "\${!args[@]}"; do
  if [[ \${args[\$i]} == https://github.com/ukyi-app/homelab.git ]]; then
    [[ \${GIT_CONFIG_GLOBAL:-} == /dev/null && -n \${GIT_CONFIG_NOSYSTEM:-} && -z \${GITHUB_TOKEN:-} && -z \${GIT_CONFIG_COUNT:-} ]] || { echo "git stub: clone 환경이 격리되지 않았다" >&2; exit 9; }
    printf '%s\\n' "\$*" | grep -q 'core.hooksPath=' || { echo "git stub: hook을 끄지 않았다" >&2; exit 9; }
    args[\$i]="file://$t/origin.git"
    # 래퍼는 https만 허용한다. 시험의 로컬 원격만 file을 연다.
    args=(-c protocol.file.allow=always "\${args[@]}")
    break
  fi
done
exec "$real_git" "\${args[@]}"
EOF
cat >"$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token") echo "$STUB_TOKEN" ;;
  "api -i user") cat "$STUB_HEADERS" ;;
  "api repos/ukyi-app/homelab --jq .permissions.admin") echo "$STUB_ADMIN" ;;
  *) echo "gh stub: $*" >&2; exit 2 ;;
esac
EOF
# 시험 값은 파일에서 읽는다(래퍼가 환경을 비운 뒤 불려도 주입 흉내가 켜져 있게).
printf '#!/usr/bin/env bash\nt=%q\nsource %q\n' "$t" "$t/stub.env" >"$t/bin/infisical"
cat >>"$t/bin/infisical" <<'EOF'
echo "$*" >>"$t/infisical-calls"
# /terraform/state 흉내. R2 키 둘과 함께, 실수나 변조로 들어간 실행 환경 이름(STUB_INJECT)이 있다.
# 래퍼가 infisical run으로 돌아가면 그 이름이 자식 환경에 들어가 아래 가짜 terraform이 잡는다.
case $1 in
  run)
    while [[ $# -gt 0 && $1 != -- ]]; do shift; done
    shift
    export AWS_ACCESS_KEY_ID=stub-r2-id AWS_SECRET_ACCESS_KEY=stub-r2-key
    case ${STUB_INJECT:-} in
      path) export PATH="$t/evil:$PATH" ;;
      shell) export BASH_ENV="$t/evil.sh" ENV="$t/evil.sh" ;;
      ld) export LD_PRELOAD="$t/evil.so" LD_LIBRARY_PATH="$t/evil" ;;
      tf) export TF_VAR_homelab_merge_app_id=9 TF_CLI_ARGS_plan=-target=x GITHUB_APP_ID=1 TF_LOG=DEBUG TF_CLI_CONFIG_FILE=/tmp/evil.tfrc ;;
      token) export GITHUB_TOKEN=ghp_other ;;
    esac
    exec "$@"
    ;;
  secrets)
    [[ $2 == get ]] || exit 2
    # 키가 없을 때(STUB_NO_AWS) CLI가 내는 모양은 확인하지 못했다. 빈 출력과 "*not found*"를 둘 다 본다.
    if [[ -n ${STUB_NO_AWS:-} ]]; then printf '%s\n' "${STUB_MISSING:-}"; exit 0; fi
    case $3 in
      AWS_ACCESS_KEY_ID) echo stub-r2-id ;;
      AWS_SECRET_ACCESS_KEY) echo stub-r2-key ;;
      *) echo "infisical stub: 모르는 이름 $3" >&2; exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
mkdir -p "$t/evil"
for c in bash env terraform; do printf '#!/bin/sh\ntouch %q\nexit 1\n' "$t/evil-ran" >"$t/evil/$c"; done
printf 'touch %q\n' "$t/evil-ran" >"$t/evil.sh"
chmod +x "$t/evil/"*
# 래퍼가 terraform 앞에서 환경을 허용 목록으로 줄이므로, 가짜 terraform은 시험 값을 파일에서 읽는다.
printf '#!/usr/bin/env bash\nsource %q\n' "$t/stub.env" >"$t/bin/terraform"
cat >>"$t/bin/terraform" <<'EOF'
dir=${1#-chdir=}
shift
echo "$*" >>"$STUB_LOG"
# 환경은 허용 목록뿐이어야 한다(PWD·SHLVL·_는 이 가짜 terraform을 띄운 bash가 더한다). 함수(BASH_FUNC_*)도 없다.
extra=$(/usr/bin/env | cut -d= -f1 | grep -vxE 'PATH|HOME|LC_ALL|TMPDIR|GITHUB_TOKEN|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|TF_IN_AUTOMATION|TF_CLI_CONFIG_FILE|PWD|SHLVL|_' || true)
[[ -z $extra ]] || { echo "terraform stub: 허용 목록 밖 환경: ${extra//$'\n'/ }" >&2; exit 9; }
[[ $GITHUB_TOKEN == "$STUB_EXPECT_TOKEN" ]] || { echo "terraform stub: GITHUB_TOKEN이 호출 때 값이 아니다" >&2; exit 9; }
[[ $AWS_ACCESS_KEY_ID == stub-r2-id && $AWS_SECRET_ACCESS_KEY == stub-r2-key ]] || { echo "terraform stub: R2 키가 Infisical 값이 아니다" >&2; exit 9; }
[[ $LC_ALL == C && $TF_IN_AUTOMATION == 1 ]] || { echo "terraform stub: LC_ALL·TF_IN_AUTOMATION이 없다" >&2; exit 9; }
# 값은 argv에 없다(프로세스 목록에 보인다).
[[ "$*" != *stub-r2-* && "$*" != *"$GITHUB_TOKEN"* ]] || { echo "terraform stub: 자격이 argv에 있다" >&2; exit 9; }
grep -q 'direct' "$TF_CLI_CONFIG_FILE" || { echo "terraform stub: CLI 설정이 래퍼 것이 아니다" >&2; exit 9; }
if find "$dir" -name '*override.tf*' | grep -q .; then echo "terraform stub: override를 읽었다" >&2; exit 9; fi
case $1 in
  init) exit 0 ;;
  plan) : >"$dir/tfplan"; exit "$STUB_PLAN_EXIT" ;;
  show) cat "$STUB_PLAN_JSON" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$t/bin/"*

printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: admin:org, repo, workflow\r\n\r\n{}\n' >"$t/h-ok"
printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, read:org, repo\r\n\r\n{}\n' >"$t/h-noadminorg"
printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo, delete_repo\r\n\r\n{}\n' >"$t/h-delete"
printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: \r\n\r\n{}\n' >"$t/h-empty"
printf 'HTTP/2.0 200 OK\r\nGitHub-Authentication-Token-Expiration: 2026-12-01 00:00:00 UTC\r\n\r\n{}\n' >"$t/h-pat"
printf 'HTTP/2.0 200 OK\r\nX-Github-Request-Id: x\r\n\r\n{}\n' >"$t/h-pat-noexp"
echo '{"resource_changes":[]}' >"$t/p-none"
echo '{"resource_changes":[{"address":"github_repository_ruleset.app_main[\"files\"]","change":{"actions":["delete"]}}]}' >"$t/p-delete"
# app new 판정용(T12): 생성 하나, no-op 하나, import(no-op + importing) 하나, 미뤄진 guard 읽기 하나. after에 값 표식을 둔다.
cat >"$t/p-app" <<'EOF2'
{"resource_changes":[
 {"address":"github_repository_ruleset.app_main[\"smoke\"]","mode":"managed","change":{"actions":["create"],"after":{"name":"VALUEMARK"}}},
 {"address":"github_repository_ruleset.main_checks","mode":"managed","change":{"actions":["no-op"],"before":{"name":"VALUEMARK"}}},
 {"address":"github_repository_ruleset.app_main[\"files\"]","mode":"managed","change":{"actions":["no-op"],"importing":{"id":"files:1"}}},
 {"address":"data.github_rest_api.rulesets_app[\"smoke\"]","mode":"data","change":{"actions":["read"],"after":{"body":"VALUEMARK"}}},
 {"address":"github_repository_ruleset.main_review_v2","previous_address":"github_repository_ruleset.main_review","mode":"managed","change":{"actions":["no-op"],"before":{"name":"VALUEMARK"}}}
],
"output_changes":{
 "ruleset_ids":{"actions":["update"],"before":"VALUEMARK","after":"VALUEMARK"},
 "unchanged":{"actions":["no-op"],"before":"VALUEMARK","after":"VALUEMARK"}
}}
EOF2
mkdir -p "$t/out"

fails=0
# expect <설명> <기대 exit(0|nonzero)> <env...> -- <args>
expect() {
  local desc=$1 want=$2
  shift 2
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  local rc=0 out
  # 가짜 terraform이 읽는 시험 값(기본값 뒤에 이 시험의 값).
  {
    printf 'STUB_LOG=%q\nSTUB_PLAN_EXIT=0\nSTUB_PLAN_JSON=%q\n' "$t/log" "$t/p-none"
    printf 'STUB_EXPECT_TOKEN=ghp_stub\n'
    for e in "${envs[@]}"; do
      [[ $e == STUB_PLAN_* || $e == STUB_INJECT=* || $e == STUB_NO_AWS=* || $e == STUB_MISSING=* ]] && printf '%s=%q\n' "${e%%=*}" "${e#*=}"
      [[ $e == STUB_TOKEN=* ]] && printf 'STUB_EXPECT_TOKEN=%q\n' "${e#*=}"
    done
  } >"$t/stub.env"
  out=$(cd "$t/work" && env -i PATH="$t/bin:$PATH" HOME="$t/home" STUB_LOG="$t/log" \
    STUB_TOKEN=ghp_stub STUB_HEADERS="$t/h-ok" STUB_ADMIN=true STUB_PLAN_EXIT=0 STUB_PLAN_JSON="$t/p-none" \
    HOMELAB_ADMIN_PROJECT_ID=stub R2_ENDPOINT=https://abc123.r2.cloudflarestorage.com \
    GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PEM_FILE=/dev/null TF_CLI_ARGS=-var=x TF_CLI_ARGS_plan=-target=x \
    TF_VAR_homelab_merge_app_id=9 TF_LOG=DEBUG \
    "${envs[@]}" bash "$wrapper" "$@" 2>&1) || rc=$?
  if [[ $want == 0 && $rc != 0 ]] || [[ $want != 0 && $rc == 0 ]] || [[ $want =~ ^[0-9]+$ && $want != 0 && $rc != "$want" ]]; then
    echo "FAIL: $desc (exit $rc)"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    fails=$((fails + 1))
  else
    echo "ok: $desc (exit $rc) $(printf "%s" "$out" | grep -E "tf-github: |stub" | tail -1)"
  fi
}

expect "classic 토큰, 정상 범위, 변경 없음" 0 -- verify
expect "verify 차이는 exit 2" 2 STUB_PLAN_EXIT=2 -- verify
expect "guard 실패(plan exit 1)는 exit 1" 1 STUB_PLAN_EXIT=1 -- verify
expect "delete_repo 범위 토큰 거부" nonzero STUB_HEADERS="$t/h-delete" -- verify
expect "admin:org 없는 gh 기본 범위 토큰 거부" nonzero STUB_HEADERS="$t/h-noadminorg" -- verify
expect "범위 머리글이 빈 classic 토큰 거부" nonzero STUB_HEADERS="$t/h-empty" -- verify
expect "만료 없는 fine-grained PAT 거부" nonzero STUB_TOKEN=github_pat_stub STUB_HEADERS="$t/h-pat-noexp" -- verify
expect "만료 있는 fine-grained PAT 허용" 0 STUB_TOKEN=github_pat_stub STUB_HEADERS="$t/h-pat" -- verify
expect "모르는 토큰 종류 거부" nonzero STUB_TOKEN=ghs_stub -- verify
expect "admin이 아닌 토큰 거부" nonzero STUB_ADMIN=false -- verify
# /terraform/state에 실행 환경 이름이 들어가도 래퍼는 이름 둘만 값으로 읽으므로 terraform 환경에 없다.
for k in path shell ld tf token; do
  expect "/terraform/state의 주입 이름($k)이 terraform 환경에 없음" 0 STUB_INJECT=$k -- verify
  [[ ! -e $t/evil-ran ]] || { echo "FAIL: 주입($k)이 실행됐다"; fails=$((fails + 1)); rm -f "$t/evil-ran"; }
done
expect "호출 셸의 제어 변수·함수가 terraform 환경에 없음" 0 'BASH_FUNC_evil%%=() { :; }' TF_DATA_DIR=/tmp/x MY_SECRET=x -- verify
expect "/terraform/state에 R2 키가 없으면(빈 출력) 멈춤, 호출 셸 키로 진행하지 않음" nonzero STUB_NO_AWS=1 AWS_ACCESS_KEY_ID=ambient AWS_SECRET_ACCESS_KEY=ambient -- verify
expect "/terraform/state에 R2 키가 없으면(*not found*) 멈춤" nonzero STUB_NO_AWS=1 'STUB_MISSING=*not found*' -- verify
expect "호출 셸에 AWS 키가 있어도 Infisical 값을 씀" 0 AWS_ACCESS_KEY_ID=ambient AWS_SECRET_ACCESS_KEY=ambient -- verify
expect "delete plan은 --allow-destroy 없이 멈춤" nonzero STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan
expect "delete plan은 --allow-destroy로 통과" 2 STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan --allow-destroy

# --plan-json(T12 app new): 주소·동작만 남기고 종료 코드는 그대로다.
expect "plan --plan-json은 exit 2를 그대로" 2 STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-app" -- plan --plan-json "$t/out/a.json"
if [[ -f $t/out/a.json ]]; then
  got=$(jq -c '[.schema, (.sha | test("^[0-9a-f]{40}$")), [.changes[] | [.address, .mode, (.actions | join(",")), .importing]]]' "$t/out/a.json")
  want='["tf-github-plan/v1",true,[["github_repository_ruleset.app_main[\"smoke\"]","managed","create",false],["github_repository_ruleset.app_main[\"files\"]","managed","no-op",true],["data.github_rest_api.rulesets_app[\"smoke\"]","data","read",false],["github_repository_ruleset.main_review_v2","managed","no-op",false],["output.ruleset_ids","managed","update",false]]]'
  [[ $got == "$want" ]] || { echo "FAIL: plan JSON 내용: $got"; fails=$((fails + 1)); }
  ! grep -q VALUEMARK "$t/out/a.json" || { echo "FAIL: plan JSON에 값이 있다"; fails=$((fails + 1)); }
  [[ $(stat -c %a "$t/out/a.json") == 600 ]] || { echo "FAIL: plan JSON 권한이 600이 아니다"; fails=$((fails + 1)); }
else
  echo "FAIL: plan JSON 파일이 없다"
  fails=$((fails + 1))
fi
expect "--plan-json 변경 없음은 exit 0, 빈 목록" 0 -- plan --plan-json "$t/out/none.json"
[[ $(jq -c .changes "$t/out/none.json" 2>/dev/null) == "[]" ]] || { echo "FAIL: 변경 없음의 plan JSON"; fails=$((fails + 1)); }
expect "--plan-json은 --allow-destroy와 함께 받는다" 2 STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan --allow-destroy --plan-json "$t/out/d.json"
expect "verify --plan-json은 사용법 오류" 64 -- verify --plan-json "$t/out/v.json"
expect "apply --plan-json은 사용법 오류" 64 -- apply --plan-json "$t/out/p.json"
expect "--plan-json 값 없음은 사용법 오류" 64 -- plan --plan-json
expect "--plan-json 두 번은 사용법 오류" 64 -- plan --plan-json "$t/out/x.json" --plan-json "$t/out/y.json"
expect "--plan-json 상대 경로 거부" 1 -- plan --plan-json out.json
expect "--plan-json 폴더 없음 거부" 1 -- plan --plan-json "$t/nodir/a.json"
echo keep >"$t/out/exists.json"
expect "--plan-json 이미 있는 파일은 덮지 않음" 1 -- plan --plan-json "$t/out/exists.json"
[[ $(cat "$t/out/exists.json") == keep ]] || { echo "FAIL: 있던 파일을 덮었다"; fails=$((fails + 1)); }
ln -s "$t/out/target.json" "$t/out/link.json"
expect "--plan-json 끊긴 링크도 거부" 1 -- plan --plan-json "$t/out/link.json"
[[ ! -e $t/out/target.json ]] || { echo "FAIL: 링크를 따라 썼다"; fails=$((fails + 1)); }
expect "--plan-json 작업 사본 안 경로 거부" 1 -- plan --plan-json "$t/work/plan.json"
expect "delete plan이면 --plan-json을 쓰지 않고 멈춤" 1 STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan --plan-json "$t/out/del.json"
[[ ! -e $t/out/del.json ]] || { echo "FAIL: 멈춘 plan이 JSON을 썼다"; fails=$((fails + 1)); }

# 작업 사본의 hook과 remote URL은 쓰지 않는다. 심어 둔 hook이 돌면 표식 파일이 생긴다.
mkdir -p "$t/work/.git/hooks"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$t" >"$t/work/.git/hooks/post-checkout"
chmod +x "$t/work/.git/hooks/post-checkout"
"$real_git" -C "$t/work" remote set-url origin "$t/nowhere.git"
expect "작업 사본의 remote 변경·hook을 쓰지 않음" 0 -- verify
expect "환경 기반 git 설정(insteadOf)을 clone에 넘기지 않음" 0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://attacker.invalid/.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ukyi-app/ -- verify
[[ ! -e $t/hook-ran ]] || { echo "FAIL: 작업 사본의 hook이 돌았다"; fails=$((fails + 1)); }

# 작업 사본의 미추적 override는 새 clone에 없다. 가짜 terraform이 override를 보면 exit 9다.
echo 'resource "x" "y" {}' >"$t/work/infra/github/zz_override.tf"
expect "작업 사본의 미추적 zz_override.tf를 읽지 않음" 0 -- verify
rm "$t/work/infra/github/zz_override.tf"

# main에 커밋된 override는 사본 검사에서 거부한다.
echo '# x' >"$t/seed/infra/github/zz_override.tf"
git -C "$t/seed" add -A
git -C "$t/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m override
git -C "$t/seed" push -q "$t/origin.git" main
expect "main에 커밋된 override 파일 거부" nonzero -- verify

# Infisical은 정확한 이름 둘의 조회로만 부른다(infisical run 없음).
bad_calls=$(grep -vE '^secrets get (AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY) --plain --silent .*--env=prod --path=/terraform/state$' "$t/infisical-calls" || true)
[[ -s $t/infisical-calls && -z $bad_calls ]] || { echo "FAIL: Infisical 호출이 이름 조회 둘이 아니다: ${bad_calls}"; fails=$((fails + 1)); }

grep -q -- '-lock=false' "$t/log" || { echo "FAIL: verify가 -lock=false로 돌지 않았다"; fails=$((fails + 1)); }

if [[ $fails -gt 0 ]]; then
  echo "tf-github.test.sh: 실패 ${fails}건"
  exit 1
fi
echo "tf-github.test.sh: 통과"
