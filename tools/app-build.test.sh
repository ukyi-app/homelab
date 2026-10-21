#!/usr/bin/env bash
# app-build.yaml deploy-pr의 "배포 PR(deploy/<앱>)" 블록 시험(bun run ci의 한 단계). 블록을 워크플로에서 그대로 꺼내
# 가짜 gh·git으로 돌린다. 사본을 두지 않아 워크플로를 고치면 시험도 그 코드를 돈다.
# 가짜 gh는 진짜 gh처럼 실패 때 응답 본문을 stdout에, "gh: ... (HTTP <코드>)"를 stderr에 내고 exit 1이다(gh 2.102.0 실측).
# 실제 GitHub·토큰은 쓰지 않는다.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
wf="$here/../.github/workflows/app-build.yaml"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# yq는 CI가 받지 않는다. ci와 같은 bun 내장 YAML 파서로 꺼낸다.
bun -e 'const w = Bun.YAML.parse(await Bun.file(process.argv[1]).text());
const s = (w.jobs?.["deploy-pr"]?.steps ?? []).filter((x) => x.name === "배포 PR(deploy/<앱>)");
if (s.length === 1 && typeof s[0].run === "string") process.stdout.write(s[0].run);' "$wf" >"$t/step.sh"
[[ -s $t/step.sh ]] || { echo "app-build.test.sh: 배포 PR 단계를 찾지 못했다" >&2; exit 1; }

old_rev=1111111111111111111111111111111111111111
new_rev=2222222222222222222222222222222222222222
branch_sha=3333333333333333333333333333333333333333
digest=sha256:4444444444444444444444444444444444444444444444444444444444444444

mkdir -p "$t/bin"
# 시험 값은 STUB_REF(배포 브랜치 ref 응답: 404 | 200 | 500)로 고른다. 호출은 $t/calls에 남는다.
cat >"$t/bin/gh" <<EOF
#!/usr/bin/env bash
t=$t old_rev=$old_rev branch_sha=$branch_sha
EOF
cat >>"$t/bin/gh" <<'EOF'
echo "gh $*" >>"$t/calls"
fail() { printf '{"message":"%s","status":"%s"}' "$2" "$1"; echo "gh: $2 (HTTP $1)" >&2; exit 1; }
image() { printf 'repository: ghcr.io/ukyi-app/probe\ndigest: sha256:%064d\nrevision: %s\nhold: false\n' 0 "$1"; }
path=""
for a in "$@"; do [[ $a == repos/* || $a == /users/* ]] && path=$a; done
case $path in
  "repos/ukyi-app/homelab/contents/apps/probe/image.yaml?ref=main") image "$old_rev" ;;
  "repos/ukyi-app/homelab/contents/apps/probe/image.yaml?ref=deploy/probe") image "$old_rev" ;;
  repos/ukyi-app/probe/compare/*) echo ahead ;;
  "/users/ukyi-homelab-deploy%5Bbot%5D") echo 345583640 ;;
  repos/ukyi-app/homelab/git/ref/heads/deploy/probe)
    case $STUB_REF in
      404) fail 404 "Not Found" ;;
      200) echo "$branch_sha" ;;
      500) fail 500 "Server Error" ;;
    esac ;;
  "repos/ukyi-app/homelab/pulls?head=ukyi-app:deploy/probe&state=open") ;;
  repos/ukyi-app/homelab/pulls) echo 7 ;;
  *) echo "gh stub: 모르는 호출 $*" >&2; exit 2 ;;
esac
EOF
# 가짜 git: 네트워크 없이 init·add·commit은 진짜 git으로 하고 fetch·checkout은 건너뛴다. push는 인수를 남기고,
# lease 기대값이 빈 값이나 40자 SHA가 아니면 진짜 git처럼 128로 끝난다("cannot parse expected object name").
real_git=$(command -v git)
cat >"$t/bin/git" <<EOF
#!/usr/bin/env bash
t=$t real=$real_git
EOF
cat >>"$t/bin/git" <<'EOF'
args=("$@")
[[ ${args[0]} == -C ]] && sub=${args[2]} || sub=${args[0]}
case $sub in
  fetch) exit 0 ;;
  checkout) exit 0 ;;
  push)
    echo "git $*" >>"$t/pushes"
    for a in "$@"; do
      if [[ $a == --force-with-lease=* ]]; then
        want=${a#*=}; want=${want#*:}
        [[ -z $want || $want =~ ^[0-9a-f]{40}$ ]] || { echo "error: cannot parse expected object name '$want'" >&2; exit 128; }
      fi
    done
    exit 0 ;;
  *) exec "$real" "$@" ;;
esac
EOF
chmod +x "$t/bin/gh" "$t/bin/git"

pass=0 failn=0
run_case() {
  local name=$1 ref=$2 want_rc=$3 want_lease=$4
  : >"$t/calls"; : >"$t/pushes"; : >"$t/summary"
  local rc=0
  env -i PATH="$t/bin:$PATH" HOME="$t" STUB_REF="$ref" \
    APP=probe DIGEST="$digest" HOMELAB_TOKEN=stub-homelab APP_REPO_TOKEN=stub-app NEW_REV="$new_rev" \
    APP_SLUG=ukyi-homelab-deploy GITHUB_STEP_SUMMARY="$t/summary" GITHUB_REPOSITORY=ukyi-app/probe \
    GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -e "$t/step.sh" >"$t/out" 2>&1 || rc=$?
  local ok=1
  [[ $rc == "$want_rc" ]] || ok=0
  if [[ $want_lease == none ]]; then
    [[ ! -s $t/pushes ]] || ok=0
  else
    grep -qxF -- "--force-with-lease=refs/heads/deploy/probe:${want_lease}" <(tr ' ' '\n' <"$t/pushes") || ok=0
  fi
  if [[ $ok == 1 ]]; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    failn=$((failn + 1)); echo "FAIL $name (rc $rc, 기대 $want_rc)"; sed 's/^/     /' "$t/out" "$t/pushes"
  fi
}

# 1. 앱의 첫 배포 PR: 브랜치가 없다(404). lease는 빈 값("없어야 한다")이고 PR을 만든다. app-build-v1.0.0은 여기서 404 JSON을 lease로 썼다.
run_case "브랜치 없음(404) → 빈 lease로 push" 404 0 ""
# 2. 열린 배포 PR이 있다(200). 그 SHA가 lease다.
run_case "브랜치 있음(200) → 그 SHA로 push" 200 0 "$branch_sha"
# 3. 404가 아닌 실패는 push 없이 멈춘다(실패 본문을 lease로 쓰지 않는다).
run_case "ref 조회 500 → push 없이 실패" 500 1 none

echo "app-build.test.sh: 통과 ${pass}, 실패 ${failn}"
[[ $failn == 0 ]]
