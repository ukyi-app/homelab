#!/usr/bin/env bats
# tf-r2-init composite — backend.hcl 작성 + init -lockfile=readonly를 SSOT화.
# 5콜사이트(iac×2, tf-reconcile×3) 중복 제거. -lockfile=readonly 불변식이 한 곳에 산다.
#
# **state key는 입력이 아니라 root에서 파생된다.** 그래서 이 파일의 증인은 두 층이다:
#   ① action-로컬 — action의 run 본문을 격리 픽스처에서 **실제로 실행**해 파생 결과를 리터럴로
#      앵커한다. 호출부 형태만 보는 증인은 action이 키를 하드코딩/오타 내도 전건 통과하는데,
#      그 상태에서 `terraform init`은 잘못된 기존 state에 성공하고 plan/apply가 다른 루트의
#      리소스를 관리한다 — 이 파일이 막으려는 실패 그 자체다.
#   ② 호출부 — yq 셀렉터로 열거해 `state-key` 잔존 0 · root 비공허·화이트리스트 소속을 본다.
#      셀렉터 부분 실명은 yq 매치 수 == grep 리터럴 수 교차검증으로 막는다
#      (선례: tests/gates/test_telegram-callsites.bats).
#
# ⚠️ actionlint는 ①의 자리를 대신하지 못한다. 실측(2026-08-29): `state-key` 입력만 제거하면 남은
#    `with: state-key:` 5곳이 전부 red(rc 1)지만, action.yml의 `ROOT: ${{ inputs.root }}`를
#    `${{ inputs.bogus }}`로 바꾸거나 리터럴 `cloudflare`로 하드코딩해도 **무경고**다 —
#    actionlint는 .github/workflows/만 린트하고 composite action의 자기 env는 안 본다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  A="$REPO/.github/actions/tf-r2-init/action.yml"
  WF="$REPO/.github/workflows"
  [ -f "$A" ]
}

# 격리 픽스처를 만든다. $1=레인 이름. 호출자가 $FX를 받는다.
# ⚠️ `run run_action …`은 서브셸이라 그 안의 변수 할당이 호출자에게 안 보인다 — 실측: FX를
#    run_action 안에서 잡았더니 호출자에서 빈 문자열이 되어 `find "$FX/infra"`가 0건을 내고
#    거부 레인이 **공허하게 초록**이었다. 그래서 FX는 호출자가 소유한다.
fx_new() {
  FX="$BATS_TEST_TMPDIR/fx.$1"
  rm -rf "$FX"
  mkdir -p "$FX/bin" "$FX/infra/cloudflare" "$FX/infra/github" "$FX/infra/tailscale"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$TF_ARGV"\n' > "$FX/bin/terraform"
  chmod +x "$FX/bin/terraform"
  yq -r '.runs.steps[0].run' "$A" > "$FX/body.sh"
  # 추출 붕괴 바닥값 — 빈 본문이면 거부 레인의 부정 단언이 공허해진다.
  [ -s "$FX/body.sh" ]
  [ -d "$FX/infra" ]
}

# action의 run 본문을 $FX에서 실제로 실행한다. $1=root 값.
# 산출물: $FX/infra/<root>/backend.hcl · $FX/tf.argv(terraform 스텁이 남긴 argv).
# ⚠️ 반드시 픽스처 루트로 cd 한다 — run 본문의 `infra/…`는 상대 경로라 실 레포에 쓴다(gitignored
#    backend.hcl을 덮어쓴다). 서브셸 cd로 격리한다.
run_action() {
  (
    cd "$FX" || exit 1
    PATH="$FX/bin:$PATH" TF_ARGV="$FX/tf.argv" ROOT="$1" \
      R2_ACCOUNT_ID=acct R2_ACCESS_KEY_ID=akid R2_SECRET_ACCESS_KEY=skey \
      bash -e -o pipefail body.sh
  )
}

@test "action declares root as its only input and wires it into ROOT" {
  # `state-key` 입력이 되살아나면 이 등식이 먼저 red다(actionlint는 입력 *추가*를 못 잡는다 —
  # 남는 것은 콜사이트의 `with:`뿐인데 그건 다시 합법이 된다).
  [ "$(yq -r '[.inputs | keys | .[]] | join(",")' "$A")" = "root" ]
  # 스텝이 하나라는 것이 ①의 전제다 — 픽스처는 steps[0]만 실행하므로, 스텝이 늘면 파생이
  # 증인 밖으로 새 나갈 수 있다. 늘릴 때 run_action을 함께 고치라는 락이다.
  [ "$(yq -r '.runs.steps | length' "$A")" -eq 1 ]
  [ "$(yq -r '.runs.steps[0].env.ROOT' "$A")" = '${{ inputs.root }}' ]
  # 옛 STATE_KEY 배선 잔존 0 (rc 1 = 무매치. 파일 실재는 setup의 [ -f ]가 증언한다)
  run grep -F 'STATE_KEY' "$A"
  [ "$status" -eq 1 ]
}

@test "action derives the backend key from root, anchored per supported root" {
  seen=0
  while read -r root want; do
    [ -n "$root" ] || continue
    seen=$(( seen + 1 ))
    fx_new "$root"
    run run_action "$root"
    [ "$status" -eq 0 ] || { echo "root=$root rc=$status: $output"; false; }
    hcl="$FX/infra/$root/backend.hcl"
    [ -f "$hcl" ] || { echo "root=$root: backend.hcl이 infra/${root}에 없다"; false; }
    # key 줄은 정확히 하나이고 그 값이 리터럴로 앵커된다(정렬 공백만 자유)
    [ "$(grep -c '^key' "$hcl")" -eq 1 ]
    run grep -Eq "^key[[:space:]]*= \"$want\"\$" "$hcl"
    [ "$status" -eq 0 ] || { echo "root=$root: key 파생 불일치 — $(grep '^key' "$hcl")"; false; }
    # 다른 루트 디렉토리에는 아무것도 쓰지 않는다(경로 하드코딩 검출)
    [ "$(find "$FX/infra" -name backend.hcl | wc -l | tr -d ' ')" -eq 1 ]
    # init 호출도 같은 root를 향하고 -lockfile=readonly를 단다
    [ -f "$FX/tf.argv" ]
    run grep -Fx -- "-chdir=infra/$root" "$FX/tf.argv"
    [ "$status" -eq 0 ]
    run grep -Fx -- "-lockfile=readonly" "$FX/tf.argv"
    [ "$status" -eq 0 ]
  done <<EOF
cloudflare cloudflare/prod/terraform.tfstate
github github/prod/terraform.tfstate
tailscale tailscale/prod/terraform.tfstate
EOF
  # 루프 공허 차단 — 표가 비면 위 단언이 0회 평가된다
  [ "$seen" -eq 3 ]
}

@test "action rejects a root outside the whitelist (no state object is created)" {
  bad=0
  for root in bogus '' cloudflare/prod/terraform.tfstate ../cloudflare CLOUDFLARE; do
    bad=$(( bad + 1 ))
    fx_new "lane$bad"
    run run_action "$root"
    [ "$status" -ne 0 ] || { echo "root='$root'가 수락됐다"; false; }
    # 거부는 아무것도 쓰지 않아야 한다 — 새 state 오브젝트가 조용히 생기는 자리다
    [ "$(find "$FX/infra" -name backend.hcl | wc -l | tr -d ' ')" -eq 0 ]
    # rc 1 = 부재. `[ -f … ] && { … }` 형태는 set -e 아래서 판정이 모호해 run으로 명시한다.
    run test -f "$FX/tf.argv"
    [ "$status" -eq 1 ] || { echo "root='$root'인데 terraform이 불렸다"; false; }
  done
  [ "$bad" -eq 5 ]
}

@test "root whitelist equals the live tf roots (infra/*/backend.tf, _-prefixed template excluded)" {
  # 손 관리 목록의 드리프트를 막는다. ⚠️ LC_ALL=C — en_US 콜레이션은 구분자를 무시해 다른 토큰을
  #    같다고 보고 sort -u가 하나를 버린다(docs/traps-detail.md).
  wl="$(yq -r '.runs.steps[0].run' "$A" \
        | sed -n 's/^[[:space:]]*\([a-z|]\{1,\}\))[[:space:]]*;;[[:space:]]*$/\1/p' \
        | tr '|' '\n' | LC_ALL=C sort)"
  live="$(cd "$REPO" && for d in infra/*/; do
            r="${d#infra/}"; r="${r%/}"
            case "$r" in _*) continue ;; esac
            [ -f "infra/$r/backend.tf" ] && echo "$r"
          done | LC_ALL=C sort)"
  [ -n "$wl" ]
  [ -n "$live" ]
  [ "$wl" = "$live" ] || { echo "화이트리스트 [$wl] != 실제 tf 루트 [$live]"; false; }
}

@test "tf-r2-init enforces -lockfile=readonly in init" {
  # ⚠️ 술어를 **호출 줄**에 앵커한다. 실측(2026-08-29): 옛 형태 `init .*-lockfile=readonly`는
  #    action.yml의 `description:` 산문("terraform init (-lockfile=readonly)")에 매치해,
  #    실제 `terraform … init` 줄에서 플래그를 통째로 지워도 초록이었다 — 산문이 기전의 증인
  #    노릇을 하던 자리다. 런타임 증인은 위 파생 @test의 tf.argv 대조가 따로 진다.
  run grep -E '^[[:space:]]*terraform .*init .*-lockfile=readonly' "$A"
  [ "$status" -eq 0 ]
}

@test "iac and tf-reconcile adopt the composite (no inline backend.hcl heredoc)" {
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$WF/iac.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/tf-r2-init' "$WF/tf-reconcile.yaml"
  [ "$status" -eq 0 ]
  # 인라인 heredoc(cat > infra/.../backend.hcl)이 두 워크플로에서 제거됐는지
  # rc 2(그 워크플로가 리네임/삭제)를 "heredoc 제거됨"으로 읽지 않는다 — 위 두 uses 단언이 같은 두
  # 파일의 실재를 증언한다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -E 'cat > infra/.*backend\.hcl' "$WF/iac.yaml"
  [ "$status" -eq 1 ]
  run grep -E 'cat > infra/.*backend\.hcl' "$WF/tf-reconcile.yaml"
  [ "$status" -eq 1 ]
}

@test "every call site passes root only, and yq sees every grep-visible one" {
  # 부정 단언(state-key 0건)과 **같은 셀렉터**에서 파생한다. 셀렉터가 콜사이트를 놓치면 그 스텝의
  # 계약이 조용히 0건 평가되므로, yq 매치 수 == grep 리터럴 수 교차검증이 그 다리를 잇는다
  # (선례 tests/gates/test_telegram-callsites.bats — substring grep에는 그 다리가 없었다).
  # ⚠️ 절대값은 **콜사이트가 소유한다**(scripts/lib/scan-floor.sh: 바닥값 수치는 소비자 소유).
  #    콜사이트를 늘/줄이면 아래 표를 같은 커밋에서 고친다.
  EXPECTED="$(cat <<'EOF'
iac.yaml 2
tf-reconcile.yaml 3
EOF
)"
  total=0
  while read -r wf n; do
    [ -n "$wf" ] || continue
    [ -r "$WF/$wf" ] || { echo "$wf 없음"; false; }
    got=$(grep -cF 'uses: ./.github/actions/tf-r2-init' "$WF/$wf" || true)
    [ "${got:-0}" -eq "$n" ] || { echo "$wf: want $n got ${got:-0}"; false; }
    total=$(( total + ${got:-0} ))
  done <<EOF
$EXPECTED
EOF
  [ "$total" -eq 5 ]

  yqn=0; viol=0; roots=""
  for f in "$WF"/*.yaml "$WF"/*.yml; do
    [ -e "$f" ] || continue
    # ⚠️ 2>/dev/null·|| true 금지 — yq 하드 실패는 여기서 죽어야 한다
    n=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/tf-r2-init")] | length' "$f")
    yqn=$(( yqn + n ))
    # ⓑ with 키 union에 state-key 0건 · ⓒ root 비공허
    v=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/tf-r2-init")
                | select(((.with // {}) | has("state-key")) or ((.with.root // "") == ""))] | length' "$f")
    viol=$(( viol + v ))
    r=$(yq -r '[.jobs[].steps[]? | select(.uses=="./.github/actions/tf-r2-init") | .with.root] | .[]' "$f")
    roots="$roots$r
"
  done
  # 부분 실명 대책: 셀렉터가 grep 리터럴 전부를 봐야 한다
  [ "$yqn" -eq "$total" ] || { echo "yq 매치 $yqn != grep 리터럴 $total — 셀렉터가 콜사이트를 놓쳤다(아래 계약이 0건 평가된다)"; false; }
  [ "$viol" -eq 0 ]
  # ⓓ 각 root가 action 화이트리스트 소속 — 런타임 거부보다 앞선 정적 red
  seen=0
  while read -r r; do
    [ -n "$r" ] || continue
    seen=$(( seen + 1 ))
    case "$r" in
      cloudflare|github|tailscale) ;;
      *) echo "지원되지 않는 root: '$r'"; false ;;
    esac
  done <<EOF
$roots
EOF
  [ "$seen" -eq "$total" ]
}
