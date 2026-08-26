#!/usr/bin/env bats
# 동명 app/bespoke target의 신원 관통 e2e(lib-convergence 08, design r2-1) —
# **진짜 러너(run-bump-plan) → 진짜 실행기(ensure-bump-pr) → --reconcile-only**를 한 시나리오로 관통한다.
# 같은 이름(files)의 app target과 bespoke target이 한 plan에 공존할 때:
#   ① 두 target은 **다른 브랜치**(kind 인코딩)로 갈라져 서로의 PR을 덮어쓰지 못하고,
#   ② 레인이 verbatim으로 관통해 **app(bump)만 무장**되고 bespoke(propose-pr)는 무장되지 않으며,
#   ③ reconcile-only가 **각자의 인가 소스**(.bindings.json vs .image-pin.json)로만 판정해
#      교차 오염(잘못된 자동 arm·잘못된 회수)이 일어나지 않는다.
# 하네스: git은 원격 표면(ls-remote·push)만 stub하고 나머지는 진짜 git으로 passthrough —
# worktree 격리·커밋은 실제로 일어난다. gh는 픽스처 라우팅(테스트별 원장 = $CALLS).
# ⚠️ 비-보장(non-goal): digest-exporter APPS 동기(bump-tag.syncDigestExporter)는 **이름 키**라 동명
#    두 레인이 같은 줄을 다툰다 — 그 표면의 분리는 이 e2e의 주장 밖이다(bump-tag.ts의 F-1 주석 참조).
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과) · @test 이름은 영어(CJK 함정).
bats_require_minimum_version 1.5.0

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
OLD_DIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OID_A="1111111111111111111111111111111111111111"   # app 브랜치 head(reconcile 픽스처)
OID_B="2222222222222222222222222222222222222222"   # bespoke 브랜치 head
BR_APP="bump-poll/app/files-sha-deadbee"
BR_BSP="bump-poll/bespoke/files-sha-feedbee"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1

  # ── 동명 표면 픽스처 — 같은 이름 files가 두 레인에 실재한다(각자의 autoDeploy가 서로 다르다) ──
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name seed
  git -C "$REPO" config user.email seed@t
  mkdir -p "$REPO/apps/files/deploy/prod" "$REPO/platform/files/prod" "$REPO/platform/victoria-stack/prod"
  printf 'image:\n  repo: ghcr.io/ukyi-app/files\n  tag: sha-0000000\nkind: web\n' > "$REPO/apps/files/deploy/prod/values.yaml"
  printf '{ "db": [], "redis": [], "autoDeploy": true }\n' > "$REPO/apps/files/deploy/prod/.bindings.json"
  printf '{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": false }\n' \
    > "$REPO/platform/files/prod/.image-pin.json"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: files\n          image: ghcr.io/ukyi-app/files:sha-0000000@%s\n' \
    "$OLD_DIG" > "$REPO/platform/files/prod/deployment.yaml"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: digest-exporter\n          env:\n            - name: APPS\n              value: "files=ghcr.io/ukyi-app/files:sha-0000000"\n' \
    > "$REPO/platform/victoria-stack/prod/digest-exporter.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init

  # 두 레인이 섞인 plan(계약 형식) — app은 자동 레인(bump), bespoke는 승인 레인(propose-pr).
  cat > "$REPO/plan.json" <<EOF
[
 {"target":{"kind":"app","name":"files"},"action":"bump","reason":"","src":"ukyi-app/files","candidate":{"gitsha":"deadbee","tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/files/deploy/prod/values.yaml"},
 {"target":{"kind":"bespoke","name":"files"},"action":"propose-pr","reason":"autoDeploy 아님","src":"ukyi-app/files","candidate":{"gitsha":"feedbee","tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"platform/files/prod/deployment.yaml","pin":"platform/files/prod/.image-pin.json"}
]
EOF

  # ── stub — 원격 표면만. 원장은 평탄화 줄이다(argv 배열 계약은 test_ensure-bump-pr.bats가 못박는다 —
  # 이 e2e의 단언은 브랜치 문자열·호출 횟수라 경계 보존이 필요 없다).
  STUB="$BATS_TEST_TMPDIR/bin"
  E2E_DIR="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$STUB" "$E2E_DIR"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export E2E_DIR
  export E2E_HEADS="$E2E_DIR/heads"   # git ls-remote가 뱉을 원격 ref 상태(phase별로 갈아끼운다)
  : > "$CALLS"

  REAL_GIT="$(command -v git)"
  cat > "$STUB/git" <<GIT
#!/bin/sh
case "\$1" in
  ls-remote)
    echo "git \$*" >> "\$CALLS"
    if [ "\$#" -ge 4 ]; then
      [ -f "\$E2E_HEADS" ] && awk -v r="refs/heads/\$4" '\$2==r' "\$E2E_HEADS"
    else
      [ -f "\$E2E_HEADS" ] && cat "\$E2E_HEADS"
    fi
    exit 0 ;;
  push)
    echo "git \$*" >> "\$CALLS"
    # push된 ref는 이후 열거에 **실제로 나타난다** — 이게 없으면 두 번째 항목(bespoke)의 형제 스윕이
    # 방금 생긴 app 브랜치를 아예 못 봐, 교차 스윕 부재 단언이 vacuous가 된다(스윕 코드 경로 미도달).
    for a in "\$@"; do case "\$a" in
      HEAD:refs/heads/*) printf '%s\t%s\n' "4444444444444444444444444444444444444444" "\${a#HEAD:}" >> "\$E2E_HEADS" ;;
    esac; done
    exit 0 ;;
  *)
    exec "$REAL_GIT" "\$@" ;;
esac
GIT

  cat > "$STUB/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$CALLS"
case "$1:$2" in
  api:graphql)
    q=""; ref=""; oid=""
    for a in "$@"; do case "$a" in query=*) q="$a" ;; ref=*) ref="${a#ref=}" ;; oid=*) oid="${a#oid=}" ;; esac; done
    case "$q" in
      *"object(oid:"*)
        f="$E2E_DIR/commit-$oid.json"
        if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"object":null}}}'; fi ;;
      *)
        b="${ref#refs/heads/}"
        f="$E2E_DIR/prs-$(printf '%s' "$b" | tr '/' '_').json"
        if [ -f "$f" ]; then cat "$f"; else printf '{"data":{"repository":{"ref":null}}}'; fi ;;
    esac ;;
  pr:create)
    # 번호는 **--head 브랜치에 결속**한다(단조 카운터 금지) — 카운터면 번호↔target 결속이 plan 순서에
    # 매달려, 순서와 arming이 함께 뒤집히는 회귀(cross-arming)가 초록으로 통과한다.
    head=""; prev=""
    for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
    case "$head" in
      bump-poll/app/*)     echo "https://github.com/ukyi/homelab/pull/901" ;;
      bump-poll/bespoke/*) echo "https://github.com/ukyi/homelab/pull/902" ;;
      *) echo "stub gh: pr create의 --head를 결속할 수 없다: '$head'" >&2; exit 3 ;;
    esac ;;
  pr:merge) : ;;
  pr:view) echo CLEAN ;;
  *) echo "stub gh: 예상치 못한 호출(도구의 gh 표면이 넓어졌다): $*" >&2; exit 3 ;;
esac
exit 0
GH

  cat > "$STUB/bash" <<'BASH'
#!/bin/sh
if [ -n "${CALLS:-}" ]; then echo "bash $*" >> "$CALLS"; fi
exec /bin/bash "$@"
BASH
  chmod +x "$STUB/git" "$STUB/gh" "$STUB/bash"
  export PATH="$STUB:$PATH"
}

teardown() { [ -n "${REPO:-}" ] && rm -rf "$REPO"; }

# reconcile phase의 원격 상태: 두 신형 브랜치가 열린 PR(둘 다 무장)을 들고 있다.
seed_reconcile_remote() {
  printf '%s\trefs/heads/%s\n' "$OID_A" "$BR_APP"  > "$E2E_HEADS"
  printf '%s\trefs/heads/%s\n' "$OID_B" "$BR_BSP" >> "$E2E_HEADS"
  node_common='"isCrossRepository":false,"isDraft":false,"baseRefName":"main","author":{"login":"ukyi-homelab-writer","__typename":"Bot"},"autoMergeRequest":{"enabledAt":"2026-07-13T06:35:20Z"},"labels":{"totalCount":0,"nodes":[]},"assignees":{"totalCount":0},"reviewRequests":{"totalCount":0},"reviews":{"totalCount":0},"comments":{"totalCount":0,"nodes":[]},"timelineItems":{"totalCount":0}'
  printf '{"data":{"repository":{"ref":{"target":{"oid":"%s"},"associatedPullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":901,"createdAt":"2026-07-13T06:34:00Z","headRefOid":"%s",%s}]}}}}}' \
    "$OID_A" "$OID_A" "$node_common" > "$E2E_DIR/prs-$(printf '%s' "$BR_APP" | tr '/' '_').json"
  printf '{"data":{"repository":{"ref":{"target":{"oid":"%s"},"associatedPullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":902,"createdAt":"2026-07-13T06:35:00Z","headRefOid":"%s",%s}]}}}}}' \
    "$OID_B" "$OID_B" "$node_common" > "$E2E_DIR/prs-$(printf '%s' "$BR_BSP" | tr '/' '_').json"
  # app target의 무장을 **유지**하려면 head 소유 증명이 필요하다 — 그 브랜치 자신의 (target, tag) 메시지.
  printf '{"data":{"repository":{"object":{"oid":"%s","message":"chore: files 이미지를 sha-deadbee(digest 핀)로 갱신 (GHCR 폴링)","author":{"name":"ukyi-homelab-writer[bot]","email":"293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"},"committer":{"name":"ukyi-homelab-writer[bot]","email":"293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"}}}}}' \
    "$OID_A" > "$E2E_DIR/commit-$OID_A.json"
}

@test "same-name app and bespoke targets traverse runner → ensure-bump-pr → reconcile-only without identity cross-contamination" {
  # ── phase 1: 러너 → 진짜 실행기(원격 부재 → 두 target 모두 create 경로) ──────────────────────
  run bun tools/run-bump-plan.ts --plan "$REPO/plan.json" --repo-root "$REPO"
  [ "$status" -eq 0 ] || { echo "$output"; cat "$CALLS"; false; }

  # ① 브랜치 분리 — 같은 이름인데도 kind 세그먼트가 갈라 서로의 PR을 덮어쓸 수 없다.
  run grep -c "git push origin HEAD:refs/heads/$BR_APP" "$CALLS"
  [ "$output" = "1" ] || { echo "app 브랜치 push가 1회가 아니다"; cat "$CALLS"; false; }
  run grep -c "git push origin HEAD:refs/heads/$BR_BSP" "$CALLS"
  [ "$output" = "1" ] || { echo "bespoke 브랜치 push가 1회가 아니다(동명 브랜치 공유 = 덮어쓰기 표면)"; cat "$CALLS"; false; }

  # ② 레인 관통 — app(bump)의 PR #901만 무장되고, bespoke(propose-pr)의 #902는 무장되지 않는다.
  run grep -c "gh pr merge --auto --squash 901" "$CALLS"
  [ "$output" = "1" ] || { echo "app target의 auto-merge 무장이 없다"; cat "$CALLS"; false; }
  run grep -c "gh pr merge --auto --squash 902" "$CALLS"
  [ "$output" = "0" ] || { echo "cross-arming: 승인 레인(bespoke) PR이 무장됐다 — app의 autoDeploy를 빌려 썼다"; cat "$CALLS"; false; }

  # ②-b 교차 스윕 부재 — 두 번째 항목(bespoke)의 형제 스윕은 첫 항목이 push한 app 브랜치를
  #     네임스페이스에서 **실제로 관측한다**(git stub이 push를 열거에 반영). 다른 kind의 target이므로
  #     형제가 아니고, 어떤 무장 회수도 일어나지 않아야 한다.
  run grep -c "gh pr merge --disable-auto" "$CALLS"
  [ "$output" = "0" ] || { echo "cross-sweep: 동명 다른-kind 브랜치를 형제로 오인해 회수했다"; cat "$CALLS"; false; }

  # ③ 러너의 공간 격리 부산물 검증 — main은 그대로고 worktree/로컬 브랜치 잔류가 없다.
  run bash -c "git -C '$REPO' status --porcelain --untracked-files=no"
  [ -z "$output" ]
  run bash -c "git -C '$REPO' branch --list 'bump-poll/*'"
  [ -z "$output" ]

  # ── phase 2: reconcile-only — 두 브랜치 모두 무장된 원격 상태에서 각자의 SSOT로만 판정한다 ──────
  : > "$CALLS"
  seed_reconcile_remote
  run --separate-stderr bun tools/ensure-bump-pr.ts --reconcile-only --root "$REPO"
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; cat "$CALLS"; false; }
  JSON="$output"

  # ④ 교차 오염 없음 — bespoke(승인 레인)의 무장만 회수되고 app(자동 레인)의 무장은 유지된다.
  run grep -c "gh pr merge --disable-auto 902" "$CALLS"
  [ "$output" = "1" ] || { echo "stale authorization survives: bespoke target의 승인 레인 무장이 남았다"; cat "$CALLS"; false; }
  run grep -c "gh pr merge --disable-auto 901" "$CALLS"
  [ "$output" = "0" ] || { echo "cross-revocation: app target의 인가된 무장을 동명 bespoke의 레인이 회수했다"; cat "$CALLS"; false; }
  echo "$JSON" | jq -e '[.subjects[] | select(.kind == "app")     | .lane] == ["bump"]' > /dev/null
  echo "$JSON" | jq -e '[.subjects[] | select(.kind == "bespoke") | .lane] == ["propose-pr"]' > /dev/null
  echo "$JSON" | jq -e '[.subjects[] | select(.kind == "bespoke") | .disarmed] == [true]' > /dev/null
}
