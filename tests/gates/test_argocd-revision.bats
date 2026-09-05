#!/usr/bin/env bats
# scripts/check-argocd-revision.sh 의 게이트.
#
# ⚠️ 이 파일의 설계 원칙: **가드의 모든 규칙에 그것을 죽이는 @test가 하나씩 있어야 한다.**
#    규칙을 지우거나 무력화했을 때 초록이면 그건 "아무도 대조하지 않는 주장"이다
#    (tools/lib/repo-walk.ts:142-145가 같은 판정을 명문화한다 — 죽은 규칙은 지운다).
#    아래 음성 @test 9건이 각각 다른 규칙을 겨냥한다. 하나를 지우면 대응 규칙이 죽은 규칙이 된다.
#
# ⚠️ `[[ ]]`·중간 `! ` 금지(scripts/check-bats-style.sh:3 — bats가 errexit 면제로 침묵 통과시킨다).
#    단언은 `printf | grep -q` 같은 평범한 명령으로 쓴다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$ROOT/scripts/check-argocd-revision.sh"
  FX="$BATS_TEST_TMPDIR/fx"
  # 픽스처는 **실 트리의 아카이브**다 — 손으로 만든 최소 트리는 4가지 소스 모양과 generator를
  # 재현하지 못해, 정작 이 가드가 잡아야 할 모양을 테스트가 못 본다.
  mkdir -p "$FX"
  git -C "$ROOT" archive HEAD | tar -x -C "$FX"
  git -C "$FX" init -q .
  git -C "$FX" add -A
}

# 픽스처를 원상태로 (뮤테이션 간 오염 차단)
fx_reset() { git -C "$FX" checkout -q -- . ; git -C "$FX" clean -qfd ; }

# ⚠️ 기준 리비전을 **리터럴로 쓰지 않는다.** 이 파일이 사는 브랜치마다 값이 다르다 —
#    main에서는 `main`, NUC 마이그레이션 브랜치에서는 `nuc-migration`이다. 리터럴 'main'을 쓰면
#    그 브랜치에서 sed가 **no-op이 되어** 음성 @test는 red, 양성 @test는 **조용히 vacuous green**이
#    된다(실측: nuc-migration에서 4 red + 3 vacuous). 앵커에서 파생한다.
fx_rev() { yq -r '.spec.source.targetRevision' "$FX/platform/argocd/root/root-app.yaml"; }
# fx_rewrite <old> <new> — 자기레포 리비전 참조 전건(targetRevision + generator revision)을 바꾼다.
fx_rewrite() {
  for f in $(git -C "$FX" grep -l "evision: $1" -- 'platform/argocd'); do
    sed -i.bak "s|targetRevision: $1\$|targetRevision: $2|; s|^\\( *\\)revision: $1\$|\\1revision: $2|" "$FX/$f"
  done
}

@test "real repo: every self-repo ArgoCD reference pins the same revision" {
  run "$GUARD"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'check-argocd-revision OK'
}

@test "structural enumeration agrees with an independent text lane (completeness witness)" {
  # ⚠️ 이 @test가 열거 **완전성**의 유일한 증인이다. 위 @test들은 "가드가 자기가 찾은 것을 옳게
  #    판정하는가"만 보고, 가드가 **조용히 덜 찾는** 축은 못 본다(바닥값은 큰 붕괴만 잡는다).
  #    두 레인은 진짜로 독립이다 — 하나는 `grep`(텍스트), 하나는 yq 재귀 하강(구조).
  #    ⚠️ 텍스트 레인은 `repoURL:` **키 위치**만 센다(리스트 마커 `- ` 허용). 주석에 걸리는 grep은
  #       #441이 이미 밟은 함정이라 반복하지 않는다 — 주석 줄에 이 키가 없음도 함께 단언한다.
  #    ⚠️ 여기서 `bash -c "cd … && …"`을 쓰지 않는다 — cd 실패도 rc 1이라 무매치와 구별이 안 된다.
  #       `git -C`(이 파일의 다른 자리와 같은 관용구)면 rc가 git grep의 것 그대로 온다.
  run git -C "$ROOT" grep -cnE '^[[:space:]]*#.*repoURL:' -- '*.yaml' '*.yml'
  # `-ne 0`이 아니라 `-eq 1`이다 — git grep rc는 0=매치 / 1=무매치 / **128**=치명적(비-레포 ·
  # pathspec magic 오타). 128은 grep의 rc 2와 **다른 값**이니 grep 규약을 옮겨 적지 말 것.
  # `-ne 0`이면 128이 '주석 오염 없음'으로 읽힌다(docs/traps-detail.md ③ 부정 카운트).
  [ "$status" -eq 1 ]   # 정확히 무매치 = 주석 오염 없음
  # 양성 대조 — 같은 pathspec에서 주석 줄 자체는 잡힌다(패턴/경로가 죽어 0건이 된 것을 '오염 없음'으로
  # 오독하지 않는다). git grep은 pathspec이 추적 파일과 하나도 안 맞아도 128이 아니라 rc 1이다(실측).
  # `repoURL:` 쪽 절반의 증인은 바로 아래 text 레인이다(0건이면 struct와 어긋나 red).
  git -C "$ROOT" grep -qE '^[[:space:]]*#' -- '*.yaml' '*.yml'
  text="$(cd "$ROOT" && git grep -hE '^[[:space:]]*(- )?repoURL:' -- '*.yaml' '*.yml' | grep -c .)"
  struct="$("$GUARD" | sed -n 's/^SCAN: check-argocd-revision:repourls: \([0-9]*\)$/\1/p')"
  printf '%s' "$struct" | grep -qxF "$text"
}

@test "real repo: the enumeration reaches the whole domain, not a subset" {
  run "$GUARD"
  [ "$status" -eq 0 ]
  # 건수를 단언하지 않는다(도메인은 정당하게 변한다). 두 마커가 **함께** 나오는지만 본다 —
  # 하나만 나오면 열거는 살았는데 자기레포 필터가 죽은 상태다(그 반대도 마찬가지).
  printf '%s' "$output" | grep -q '^SCAN: check-argocd-revision:repourls: [0-9]'
  printf '%s' "$output" | grep -q '^SCAN: check-argocd-revision:refs: [0-9]'
}

@test "fixture baseline is green (mutation tests below are meaningful only if this passes)" {
  run "$GUARD" --root "$FX"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "[fixture]"
}

# ── (A) 정합 ────────────────────────────────────────────────────────────────────────────────
@test "partial edit: one targetRevision moved to a branch is rejected (skew)" {
  sed -i.bak "s|targetRevision: $(fx_rev)|targetRevision: OTHER-BRANCH|" \
    "$FX/platform/argocd/root/apps/namespaces.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '리비전이 갈렸다'
}

@test "ApplicationSet git generator revision is in the domain (a targetRevision-alone edit is rejected)" {
  # ⚠️ 이 @test가 이 가드의 존재 이유에 가장 가깝다. generator는 `targetRevision`이 아니라
  #    `revision`이라, 마이그레이션 편집이 **구조적으로 빠뜨리는** 자리다. 재귀 열거가 아니라
  #    모양을 하나씩 적었다면 여기가 조용히 빠진다.
  base="$(fx_rev)"
  for f in $(git -C "$FX" grep -l "targetRevision: $base" -- 'platform/argocd'); do
    sed -i.bak "s|targetRevision: $base|targetRevision: OTHER-BRANCH|" "$FX/$f"
  done
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '리비전이 갈렸다'
}

@test "a self-repo source with no revision pin at all is rejected (ArgoCD would follow HEAD)" {
  sed -i.bak "/targetRevision: $(fx_rev)\$/d" "$FX/platform/argocd/root/apps/victoria-stack.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '리비전 핀이 없다'
}

# ── (B) 고정 · (A)/(B) 분리 계약 ────────────────────────────────────────────────────────────
@test "migration-branch shape is GREEN without --expect (so gate survives on that branch)" {
  # 이 계약이 깨지면 마이그레이션 브랜치에서 gate와 test_scan-floor가 같이 죽어 G4를 못 한다.
  fx_rewrite "$(fx_rev)" OTHER-BRANCH
  run "$GUARD" --root "$FX"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "OTHER-BRANCH"
}

@test "migration-branch shape is REJECTED with --expect <original> (the merge guard itself)" {
  base="$(fx_rev)"           # 뒤집기 **전에** 잡는다 — 뒤집은 뒤엔 fx_rev가 새 값을 낸다
  fx_rewrite "$base" OTHER-BRANCH
  run "$GUARD" --root "$FX" --expect "$base"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '라이브 ArgoCD가 그 브랜치를 따라간다'
}

@test "EXPECT_REVISION env is honored the same as --expect (ci.yaml uses the env form)" {
  base="$(fx_rev)"
  fx_rewrite "$base" OTHER-BRANCH
  EXPECT_REVISION="$base" run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  # 형제 @test 9와 같은 문구 대조 — `-ne 0` 단독은 가드 부재(rc 127)도 "거부"로 읽는다.
  printf '%s' "$output" | grep -q '라이브 ArgoCD가 그 브랜치를 따라간다'   # check-argocd-revision.sh:133
}

# ── 자기레포 판정 ───────────────────────────────────────────────────────────────────────────
# ⚠️ 아래 두 @test는 **앵커(root-app.yaml)의 표기는 그대로 두고** 나머지만 비-`.git`으로 바꾼다.
#    양쪽을 같이 바꾸면 정규화 없이도 문자열이 일치해 이 규칙이 **죽은 규칙이 된다**(역방향 뮤테이션
#    실측: `.git` 스트립을 제거해도 전 테스트 green이었다). 실제 사고 형태도 혼합 표기다 —
#    누군가 새 Application을 다른 스펠링으로 적는 것.
@test "self-repo match survives MIXED .git spelling (literal URL compare goes blind here)" {
  # ⚠️ 적대 검증이 CRITICAL로 지목한 자리다: 리터럴 URL 대조 가드는 `.git` 없는 표기에서
  #    눈이 멀어, 막으려던 사고가 초록으로 통과했다. ArgoCD는 두 스펠링을 같은 repo로 취급하고
  #    이 레포의 renovate.json도 두 스펠링을 나란히 열거한다.
  before="$("$GUARD" --root "$FX" | sed -n 's/^SCAN: check-argocd-revision:refs: \([0-9]*\)$/\1/p')"
  for f in $(git -C "$FX" grep -l 'ukyi-app/homelab.git' -- 'platform/argocd'); do
    printf '%s' "$f" | grep -q 'root-app.yaml' && continue   # 앵커는 `.git`인 채로 둔다
    sed -i.bak 's|https://github.com/ukyi-app/homelab.git|https://github.com/ukyi-app/homelab|g' "$FX/$f"
  done
  # 표기만 갈렸을 뿐이니 도메인 크기가 유지돼야 한다(줄면 자기레포 필터가 눈이 먼 것이다).
  run "$GUARD" --root "$FX"
  [ "$status" -eq 0 ]
  after="$("$GUARD" --root "$FX" | sed -n 's/^SCAN: check-argocd-revision:refs: \([0-9]*\)$/\1/p')"
  printf '%s' "$after" | grep -qxF "$before"
}

@test "mixed .git spelling still catches a branch-pinned generator (the exact accident)" {
  for f in $(git -C "$FX" grep -l 'ukyi-app/homelab.git' -- 'platform/argocd'); do
    printf '%s' "$f" | grep -q 'root-app.yaml' && continue
    sed -i.bak 's|https://github.com/ukyi-app/homelab.git|https://github.com/ukyi-app/homelab|g' "$FX/$f"
  done
  sed -i.bak "s|^\\( *\\)revision: $(fx_rev)\$|\\1revision: OTHER-BRANCH|" "$FX/platform/argocd/root/appset.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  # ⚠️ 거부 문구 대조 — `-ne 0` 단독이면 이 레인이 자기 이름을 오보한다. 실측 2026-09-03:
  #    check-argocd-revision.sh:60의 `.git` 정규화를 no-op으로 바꾸면 이 레인은 (A)정합 판정이
  #    아니라 **열거 붕괴**(`스캔 1건 < 10`)로 죽는데 `-ne 0`은 그것을 "사고를 잡았다"로 읽었다.
  printf '%s' "$output" | grep -q '리비전이 갈렸다'   # check-argocd-revision.sh:124
}

@test "a missing anchor fails loudly instead of matching nothing" {
  # 앵커가 죽으면 SELF가 빈 문자열이 되고 자기레포 참조가 0건 → 조용한 초록이 되는 자리.
  rm -f "$FX/platform/argocd/root/root-app.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '앵커를 읽지 못했다'
}

@test "an anchor without repoURL fails loudly (empty SELF would match nothing)" {
  # 파일은 있는데 필드가 없는 경우 — yq는 rc=0에 `null`을 낸다. 위 @test와 **다른 분기**다.
  yq -i 'del(.spec.source.repoURL)' "$FX/platform/argocd/root/root-app.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'repoURL'
}

# ── 열거 건전성 ─────────────────────────────────────────────────────────────────────────────
@test "unparseable YAML in the domain aborts instead of silently dropping the file" {
  # `|| true`로 yq rc를 삼키면 파싱 불가 파일 하나가 도메인에서 조용히 빠진다 — 이 레포가
  # 과거에 실제로 겪은 dead-green 클래스다.
  printf 'repoURL: [\n' >> "$FX/platform/argocd/root/appset.yaml"
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'yq 파싱 실패'
}

@test "enumeration collapse trips the scan floor instead of passing green" {
  for f in argocd-extras cnpg-barman-plugin cnpg-data namespaces sealed-secrets victoria-stack; do
    rm -f "$FX/platform/argocd/root/apps/$f.yaml"
  done
  run "$GUARD" --root "$FX"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'check-argocd-revision:refs'
}

# ── CI 배선 ─────────────────────────────────────────────────────────────────────────────────
@test "ci.yaml fills EXPECT_REVISION conditionally for main-bound runs, not unconditionally" {
  # 무조건 켜면 마이그레이션 브랜치의 gate가 영구 red다. 조건식이 두 진입 경로(PR base_ref ·
  # push ref)를 **둘 다** 덮는지 구조로 단언한다 — 텍스트 grep은 주석에 걸린다(#441의 교훈).
  y="$ROOT/.github/workflows/ci.yaml"
  expr="$(yq -r '.jobs.gate.steps[] | select(.run == "bash scripts/check-argocd-revision.sh") | .env.EXPECT_REVISION' "$y")"
  printf '%s' "$expr" | grep -qF "github.base_ref == 'main'"
  printf '%s' "$expr" | grep -qF "github.ref == 'refs/heads/main'"
}
