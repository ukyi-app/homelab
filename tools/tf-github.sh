#!/usr/bin/env bash
# infra/github(GitHub 보호 설정) 래퍼(설계 C.3.9, E5). owner 로컬에서만 실행한다. CI는 plan·apply하지 않는다.
# T12부터 homelab github plan·apply·verify가 같은 규칙으로 감싼다.
#
#   tools/tf-github.sh verify                 plan -lock=false. exit 0 같음, 2 차이, 1 guard 실패·오류
#   tools/tf-github.sh plan [--allow-destroy]  plan -lock=false, delete가 있으면 --allow-destroy 없이는 멈춤
#   tools/tf-github.sh apply [--allow-destroy] state 백업 → 잠금 잡은 plan → 확인 → apply → verify
#
# 자격:
# - GITHUB_TOKEN 환경변수(없으면 gh auth token). classic·OAuth 토큰은 repo·admin:org가 있고 delete_repo가 없어야 한다.
#   fine-grained PAT는 만료가 있어야 한다. 그 경로에는 저장소 삭제 방어가 없다(ruleset에 필요한 Administration
#   write가 삭제 권한도 준다). 리소스 소유자 ukyi-app, 대상 저장소만 선택, 만료 지정, 저장소 Administration RW·
#   Environments RW·Secrets R·Actions R, org Administration R·Secrets R은 사람이 지킨다(래퍼가 머리글로 볼 수 없다).
# - R2 state 키는 Infisical homelab-admin /terraform/state에서만 infisical run으로 받는다. 이 경로에는 R2 키만 둔다.
#
# 작업 사본에서 돌지 않는다. github.com의 main을 임시 디렉터리에 새로 clone해 그 사본만 실행한다. plan도 HCL과 provider를 실행하고,
# .gitignore가 숨기는 *override.tf·*.tfvars는 git status에도 안 보인다. 같은 작업 사본을 AI 에이전트도 편집한다.
set -euo pipefail
export LC_ALL=C

die() { printf 'tf-github: %s\n' "$*" >&2; exit 1; }
say() { printf 'tf-github: %s\n' "$*" >&2; }

usage() { sed -n '4,7p' "$0" >&2; exit 64; }

cmd=${1:-}
[[ $cmd == plan || $cmd == apply || $cmd == verify ]] || usage
shift
allow_destroy=false
for a in "$@"; do
  case $a in
    --allow-destroy) allow_destroy=true ;;
    *) usage ;;
  esac
done

for t in git gh jq terraform infisical; do
  command -v "$t" >/dev/null || die "$t가 없다(mise install)"
done

# 실행 결과를 바꾸는 환경을 지운다.
# - GITHUB_APP_* 셋이 모두 있으면 provider가 토큰보다 App 인증을 먼저 쓴다.
# - TF_CLI_ARGS*는 숨은 인수(-var, -target 등)를, TF_VAR_*는 App ID 같은 변수를 바꾼다.
# - TF_LOG*는 요청 내용을 로그로 남긴다.
unset GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PEM_FILE GITHUB_OWNER GITHUB_ORGANIZATION GITHUB_BASE_URL
unset AWS_PROFILE AWS_SESSION_TOKEN TF_WORKSPACE TF_DATA_DIR TF_PLUGIN_CACHE_DIR
for name in $(compgen -e); do
  case $name in
    TF_CLI_ARGS | TF_CLI_ARGS_* | TF_LOG | TF_LOG_* | TF_VAR_*) unset "$name" ;;
  esac
done
export TF_IN_AUTOMATION=1

# 1. main의 깨끗한 사본. 자격을 읽기 전에 만든다. 작업 사본의 .git(설정, remote URL, URL rewrite, hook)을 쓰지 않는다.
#    같은 작업 사본을 AI 에이전트도 편집하므로 .git/config의 origin을 바꾸거나 hook을 심으면 다른 코드가 돈다.
#    그래서 고정 URL에서 새로 clone한다. git은 env -i로 띄워 환경 기반 설정(GIT_CONFIG_COUNT/KEY/VALUE, insteadOf)과
#    전역·시스템 설정, hook을 모두 끊는다. git에는 토큰을 넘기지 않는다(public 저장소라 익명 clone).
#    그다음 그 사본의 이 래퍼로 다시 실행한다(exec). 작업 사본의 래퍼는 사본을 만들기까지만 돈다. 그 부분까지 못 믿으면
#    런북 0절처럼 래퍼 자체를 새 clone에서 실행한다.
repo_root=$(git rev-parse --show-toplevel)
if [[ -n ${TF_GITHUB_CLONE:-} && $(cd "$(dirname "$0")/.." && pwd) == "$TF_GITHUB_CLONE/tree" && -d $TF_GITHUB_CLONE/tree/.git ]]; then
  work=$TF_GITHUB_CLONE
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/tf-github.XXXXXX")
  mkdir -p "$work/nohooks" "$work/home"
  env -i PATH="$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git -c core.hooksPath="$work/nohooks" -c protocol.allow=never -c protocol.https.allow=always \
    clone -q --depth 1 --branch main --no-tags https://github.com/ukyi-app/homelab.git "$work/tree" ||
    { rm -rf "$work"; die "main을 clone하지 못했다"; }
  [[ -f $work/tree/tools/tf-github.sh ]] || { rm -rf "$work"; die "main에 tools/tf-github.sh가 없다"; }
  # 처음 호출한 작업 사본의 루트도 넘긴다. state 백업이 그 안에 생기지 않게 둘 다 거부한다.
  TF_GITHUB_CLONE=$work TF_GITHUB_ORIGIN_ROOT=$repo_root exec bash "$work/tree/tools/tf-github.sh" "$cmd" "$@"
fi
trap 'rm -rf "$work"' EXIT
origin_root=${TF_GITHUB_ORIGIN_ROOT:-$repo_root}
unset TF_GITHUB_CLONE TF_GITHUB_ORIGIN_ROOT
sha=$(git -C "$work/tree" rev-parse HEAD)
say "실행 사본: github.com/ukyi-app/homelab main ${sha}"
bad=$(find "$work/tree" -path "$work/tree/.git" -prune -o \( -name '*override.tf*' -o -name '*.tfvars*' \) -print)
[[ -z $bad ]] || die "사본에 override·tfvars 파일이 있다: ${bad}"
root="$work/tree/infra/github"
[[ -d $root ]] || die "main에 infra/github가 없다"

# 2. 토큰 종류와 범위. 머리글은 응답 전체를 변수로 받은 뒤 본다. grep -q로 파이프를 끊으면 pipefail 아래 SIGPIPE로
#    범위가 있는데도 놓친다(2026-10-18 실측: 15회 중 1회).
if [[ -z ${GITHUB_TOKEN:-} ]]; then
  GITHUB_TOKEN=$(gh auth token) || die "GITHUB_TOKEN이 없고 gh auth token도 실패했다"
fi
export GITHUB_TOKEN
headers=$(GH_TOKEN=$GITHUB_TOKEN gh api -i user 2>/dev/null) || die "토큰으로 GET /user가 실패했다"
header() { printf '%s\n' "$headers" | tr -d '\r' | awk -v h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
  /^$/ { exit }
  { i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == h) { print substr($0, i + 1); found = 1 } }
  END { if (!found) exit 1 }'; }
case $GITHUB_TOKEN in
  ghp_* | gho_*)
    scopes=$(header x-oauth-scopes) || die "classic 토큰인데 X-OAuth-Scopes 머리글이 없다"
    scopes=${scopes// /}
    [[ -n $scopes ]] || die "토큰 범위가 비어 있다(익명과 같은 권한). 거부한다"
    [[ ,$scopes, != *,delete_repo,* ]] || die "토큰에 delete_repo 범위가 있다. 그 범위 없는 토큰을 쓴다(gh auth refresh -r delete_repo 반대로)"
    # guard 7(org fork PR 정책)과 guard 9(org secret)는 org 조회라 admin:org가 있어야 한다. 없으면 plan이 403으로 멈춘다.
    [[ ,$scopes, == *,repo,* ]] || die "토큰에 repo 범위가 없다"
    [[ ,$scopes, == *,admin:org,* ]] || die "토큰에 admin:org 범위가 없다(org Actions 권한·secret 조회). gh auth refresh -h github.com -s admin:org"
    say "토큰: classic/OAuth, 범위 ${scopes}"
    ;;
  github_pat_*)
    expiry=$(header github-authentication-token-expiration) || die "fine-grained PAT에 만료가 없다. 만료를 지정해 다시 발급한다"
    say "토큰: fine-grained PAT, 만료${expiry}. 이 경로에는 저장소 삭제 방어가 없다"
    ;;
  *) die "모르는 토큰 종류다(ghp_, gho_, github_pat_만)" ;;
esac

# guard 1과 같은 확인을 plan 전에 한 번 더 한다.
admin=$(GH_TOKEN=$GITHUB_TOKEN gh api repos/ukyi-app/homelab --jq .permissions.admin 2>/dev/null) || die "repos/ukyi-app/homelab을 읽지 못했다"
[[ $admin == true ]] || die "토큰이 ukyi-app/homelab의 admin이 아니다"

# ~/.terraformrc의 dev_overrides·암묵 로컬 미러가 provider 바이너리를 바꾸지 못하게 한다. unset하면 ~/.terraformrc로
# 돌아가므로 지우지 않고 이 파일을 가리킨다. registry에서 받은 provider는 .terraform.lock.hcl 해시로 확인한다.
cat >"$work/terraformrc" <<'EOF'
provider_installation {
  direct {}
}
EOF
export TF_CLI_CONFIG_FILE="$work/terraformrc"

# 3. R2 자격(Infisical). infra/README.md 2절과 같다: 로그인 사용자의 infisical run이 값을 백업 폴더에 쓰지 못하게 한다.
mkdir -p ~/.infisical
if [[ -d ~/.infisical/secrets-backup ]]; then chmod 0700 ~/.infisical/secrets-backup; find ~/.infisical/secrets-backup -type f -delete; fi
mkdir -p ~/.infisical/secrets-backup && chmod 0500 ~/.infisical/secrets-backup
if touch ~/.infisical/secrets-backup/.probe 2>/dev/null; then
  rm -f ~/.infisical/secrets-backup/.probe
  die "Infisical 백업 폴더가 쓰기 가능하다"
fi
: "${HOMELAB_ADMIN_PROJECT_ID:=}"
: "${R2_ENDPOINT:=}"
[[ -n $HOMELAB_ADMIN_PROJECT_ID ]] || read -r -p 'homelab-admin project ID: ' HOMELAB_ADMIN_PROJECT_ID
[[ -n $R2_ENDPOINT ]] || read -r -p 'R2 S3 API endpoint (https://...r2.cloudflarestorage.com): ' R2_ENDPOINT
[[ $R2_ENDPOINT =~ ^https://[a-z0-9]+\.r2\.cloudflarestorage\.com$ ]] || die "R2 endpoint 형식이 아니다"
token_sum=$(printf '%s' "$GITHUB_TOKEN" | sha256sum | cut -d' ' -f1)
export TOKEN_SUM=$token_sum

# terraform을 R2 자격과 함께 돈다. /terraform/state에 같은 이름의 키가 있어 GITHUB_TOKEN을 덮으면 멈춘다(값은 비교만).
tf() {
  local rc=0
  # 안쪽 스크립트는 infisical이 넣은 환경에서 펼쳐야 해서 작은따옴표다.
  # shellcheck disable=SC2016
  infisical run --silent --log-level=error --projectId="$HOMELAB_ADMIN_PROJECT_ID" --env=prod --path=/terraform/state -- \
    bash -c '[[ "$(printf "%s" "$GITHUB_TOKEN" | sha256sum | cut -d" " -f1)" == "$TOKEN_SUM" ]] || { echo "tf-github: Infisical이 GITHUB_TOKEN을 덮었다" >&2; exit 1; }
             [[ -n ${AWS_ACCESS_KEY_ID:-} && -n ${AWS_SECRET_ACCESS_KEY:-} ]] || { echo "tf-github: R2 자격이 없다" >&2; exit 1; }
             # Infisical이 넣은 값 중 R2 키만 넘긴다. 그 밖의 이름(TF_CLI_ARGS*, TF_VAR_*, TF_LOG*, TF_CLI_CONFIG_FILE,
             # GITHUB_APP_* 등)은 terraform에 닿지 않는다. CLI 설정 파일은 래퍼가 만든 것으로 다시 고정한다.
             # 값을 env의 argv로 넘기지 않으려고(프로세스 목록에 보인다) 허용 목록 밖 변수를 지운다.
             for n in $(compgen -e); do
               case $n in PATH | HOME | LANG | LC_ALL | TMPDIR | GITHUB_TOKEN | AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY) ;; *) unset "$n" ;; esac
             done
             export TF_IN_AUTOMATION=1 TF_CLI_CONFIG_FILE="$1"
             exec terraform -chdir="$0" "${@:2}"' "$root" "$work/terraformrc" "$@" || rc=$?
  if [[ $(find ~/.infisical/secrets-backup -type f 2>/dev/null | wc -l) -ne 0 ]]; then
    find ~/.infisical/secrets-backup -type f -delete 2>/dev/null
    die "Infisical 백업 파일이 생겼다. 지우고 중단한다"
  fi
  return "$rc"
}

tf init -input=false -reconfigure -lockfile=readonly "-backend-config=endpoints={s3=\"$R2_ENDPOINT\"}" >/dev/null

# 낡은 tfplan으로 판단하지 않는다. 종료 코드는 0(같음)·2(차이)만 정상이다. 1은 guard 실패를 포함한다.
plan() {
  rm -f "$root/tfplan"
  local rc=0
  tf plan -input=false -detailed-exitcode -out=tfplan "$@" || rc=$?
  [[ $rc == 0 || $rc == 2 ]] || { say "plan 실패(exit ${rc}). guard 오류면 메시지의 guard 번호를 본다"; return 1; }
  return "$rc"
}

deletes() {
  tf show -json tfplan | jq -r '.resource_changes[]? | select(.change.actions | index("delete")) | .address'
}

check_deletes() {
  local d
  d=$(deletes)
  if [[ -n $d ]]; then
    say "plan에 삭제가 있다:"
    printf '  %s\n' "${d//$'\n'/$'\n'  }" >&2
    $allow_destroy || die "--allow-destroy 없이는 멈춘다(app-main 삭제, environment 교체 방어)"
  fi
}

case $cmd in
  verify)
    # 잠금을 쓰지 않는다(AC-P13: plan은 읽기 전용). 미뤄진 guard(3·4·9)도 변경이 없으면 plan 때 평가된다.
    rc=0
    plan -lock=false || rc=$?
    say "verify: main ${sha}, exit ${rc}"
    exit "$rc"
    ;;
  plan)
    rc=0
    plan -lock=false || rc=$?
    [[ $rc == 0 || $rc == 2 ]] || exit 1
    check_deletes
    say "plan: main ${sha}, exit ${rc}. 미뤄진 guard 결과는 plan에 없어 apply 뒤 verify가 본다"
    exit "$rc"
    ;;
  apply)
    # R2는 versioning이 없다. apply 전 state를 저장소 밖에 남긴다.
    : "${TF_STATE_BACKUP_DIR:=}"
    [[ -n $TF_STATE_BACKUP_DIR ]] || read -r -p '저장소 밖 state 백업 디렉터리: ' TF_STATE_BACKUP_DIR
    for r in "$repo_root" "$origin_root" "$work"; do
      case $(realpath -m "$TF_STATE_BACKUP_DIR") in "$r" | "$r"/*) die "백업은 저장소(작업 사본·실행 사본) 밖에 둔다" ;; esac
    done
    mkdir -p "$TF_STATE_BACKUP_DIR" && chmod 700 "$TF_STATE_BACKUP_DIR"
    backup="$TF_STATE_BACKUP_DIR/github-$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}.tfstate"
    (umask 077 && tf state pull >"$backup") || die "state pull이 실패했다"
    if [[ -s $backup ]]; then
      say "state 백업: ${backup}"
    else
      # 새 backend 키에 아직 state가 없다(첫 apply). 빈 파일은 유효한 사본이 아니라 지운다.
      rm -f "$backup"
      backup=""
      say "원격 state가 아직 없다(첫 apply). 백업을 건너뛴다"
    fi

    rc=0
    plan || rc=$?
    [[ $rc == 0 || $rc == 2 ]] || exit 1
    if [[ $rc == 0 ]]; then say "변경 없음: main ${sha}"; exit 0; fi
    check_deletes
    tf show -no-color tfplan
    read -r -p "main ${sha}의 위 plan을 적용한다. 계속하려면 yes: " answer
    [[ $answer == yes ]] || die "멈췄다"

    # 갱신이 실패한 ruleset은 state에 계획값이 남고 etag가 그대로라 드리프트가 영구히 안 보인다(#3519).
    # 그 plan에 있던 ruleset을 state rm 뒤 import로 다시 편입한다.
    rulesets=$(tf show -json tfplan | jq -r '.resource_changes[]? | select(.type == "github_repository_ruleset") |
      select(.change.actions | index("update")) | "\(.address)\t\(.change.before.repository):\(.change.before.ruleset_id)"')
    if ! tf apply -input=false tfplan; then
      say "apply 실패. 이 plan의 갱신 ruleset을 state rm 뒤 다시 import한다(#3519)"
      if [[ -n $rulesets ]]; then
        # rm은 됐는데 import가 실패하면(같은 장애) 주소만 state에서 사라져 다음 plan이 기존 ruleset을 새로 만들려 한다.
        # 그래서 rm 직전 state를 받아 두고, import가 하나라도 실패하면 그 state로 되돌린 뒤 멈춘다.
        while IFS=$'\t' read -r addr id; do
          [[ -n $addr ]] || continue
          if tf state rm "$addr" >/dev/null && tf import -input=false "$addr" "$id" >/dev/null; then
            say "재편입: ${addr} (${id})"
          else
            # 실패 뒤 state를 되돌리지 않는다. 되돌릴 state가 바로 #3519로 낡은 계획값을 담은 것이다.
            # 남은 주소를 import로 마치기 전에는 plan·apply하지 않는다(그 주소를 새로 만들려 한다).
            say "재편입 실패: ${addr}. 장애가 끝나면 아래를 마친 뒤에만 다시 plan한다(런북 3절):"
            say "  terraform import '${addr}' '${id}'  (이 줄과 남은 줄 모두)"
            remaining=1
          fi
        done <<<"$rulesets"
      fi
      [[ -z ${remaining:-} ]] || die "재편입을 다 마치지 못했다. 위 import를 먼저 끝낸다. state 백업: ${backup:-없음}"
      die "apply가 실패했다. 원인을 고친 뒤 다시 plan한다. state 백업: ${backup:-없음}"
    fi
    # 미뤄진 guard는 plan 출력에 없었다. 적용한 상태를 다시 본다. postcondition은 적용한 변경을 되돌리지 않는다.
    rc=0
    plan -lock=false || rc=$?
    say "apply 뒤 verify: main ${sha}, exit ${rc}"
    exit "$rc"
    ;;
esac
