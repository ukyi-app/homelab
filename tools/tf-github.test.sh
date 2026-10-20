#!/usr/bin/env bash
# tools/tf-github.sh 시험(bun run ci의 한 단계). 실제 GitHub·R2·Infisical 없이 gh·infisical·terraform을 가짜로 바꿔
# 래퍼의 거부 규칙만 본다(설계 E5 검증: delete_repo 토큰, 빈 범위, 만료 없는 PAT, delete plan, 미추적 override).
# 실제 plan·apply 경로는 owner가 첫 apply 때 확인한다.
set -euo pipefail
export LC_ALL=C

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
git -C "$t/seed" add -A
git -C "$t/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
git -C "$t/seed" push -q "$t/origin.git" main
git clone -q -b main "$t/origin.git" "$t/work"

mkdir -p "$t/bin" "$t/home"
cat >"$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token") echo "$STUB_TOKEN" ;;
  "api -i user") cat "$STUB_HEADERS" ;;
  "api repos/ukyi-app/homelab --jq .permissions.admin") echo "$STUB_ADMIN" ;;
  *) echo "gh stub: $*" >&2; exit 2 ;;
esac
EOF
cat >"$t/bin/infisical" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
shift
export AWS_ACCESS_KEY_ID=stub AWS_SECRET_ACCESS_KEY=stub
exec "$@"
EOF
cat >"$t/bin/terraform" <<'EOF'
#!/usr/bin/env bash
dir=${1#-chdir=}
shift
echo "$*" >>"$STUB_LOG"
# 래퍼가 지워야 하는 환경과 읽지 말아야 할 파일.
for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PEM_FILE TF_CLI_ARGS TF_CLI_ARGS_plan TF_VAR_homelab_merge_app_id TF_LOG; do
  [[ -z ${!v:-} ]] || { echo "terraform stub: $v가 남아 있다" >&2; exit 9; }
done
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

printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo, read:org\r\n\r\n{}\n' >"$t/h-ok"
printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo, delete_repo\r\n\r\n{}\n' >"$t/h-delete"
printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: \r\n\r\n{}\n' >"$t/h-empty"
printf 'HTTP/2.0 200 OK\r\nGitHub-Authentication-Token-Expiration: 2026-12-01 00:00:00 UTC\r\n\r\n{}\n' >"$t/h-pat"
printf 'HTTP/2.0 200 OK\r\nX-Github-Request-Id: x\r\n\r\n{}\n' >"$t/h-pat-noexp"
echo '{"resource_changes":[]}' >"$t/p-none"
echo '{"resource_changes":[{"address":"github_repository_ruleset.app_main[\"files\"]","change":{"actions":["delete"]}}]}' >"$t/p-delete"

fails=0
# expect <설명> <기대 exit(0|nonzero)> <env...> -- <args>
expect() {
  local desc=$1 want=$2
  shift 2
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  local rc=0 out
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
expect "범위 머리글이 빈 classic 토큰 거부" nonzero STUB_HEADERS="$t/h-empty" -- verify
expect "만료 없는 fine-grained PAT 거부" nonzero STUB_TOKEN=github_pat_stub STUB_HEADERS="$t/h-pat-noexp" -- verify
expect "만료 있는 fine-grained PAT 허용" 0 STUB_TOKEN=github_pat_stub STUB_HEADERS="$t/h-pat" -- verify
expect "모르는 토큰 종류 거부" nonzero STUB_TOKEN=ghs_stub -- verify
expect "admin이 아닌 토큰 거부" nonzero STUB_ADMIN=false -- verify
expect "delete plan은 --allow-destroy 없이 멈춤" nonzero STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan
expect "delete plan은 --allow-destroy로 통과" 2 STUB_PLAN_EXIT=2 STUB_PLAN_JSON="$t/p-delete" -- plan --allow-destroy

# 작업 사본의 미추적 override는 임시 worktree에 없다. 가짜 terraform이 override를 보면 exit 9다.
echo 'resource "x" "y" {}' >"$t/work/infra/github/zz_override.tf"
expect "작업 사본의 미추적 zz_override.tf를 읽지 않음" 0 -- verify
rm "$t/work/infra/github/zz_override.tf"

# origin/main에 커밋된 override는 사본 검사에서 거부한다.
echo '# x' >"$t/seed/infra/github/zz_override.tf"
git -C "$t/seed" add -A
git -C "$t/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m override
git -C "$t/seed" push -q "$t/origin.git" main
expect "origin/main의 override 파일 거부" nonzero -- verify

grep -q -- '-lock=false' "$t/log" || { echo "FAIL: verify가 -lock=false로 돌지 않았다"; fails=$((fails + 1)); }

if [[ $fails -gt 0 ]]; then
  echo "tf-github.test.sh: 실패 ${fails}건"
  exit 1
fi
echo "tf-github.test.sh: 통과"
