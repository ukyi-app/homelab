#!/usr/bin/env bats
# repin-ops-image 도구 가드(fixture — 라이브 무관). 이미지-중립: pg-tools·skopeo를 같은 도구가 재핀한다. ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  FX="$(mktemp -d)"; mkdir -p "$FX/platform/cache/prod" "$FX/platform/cnpg/prod" "$FX/platform/victoria-stack/prod"
  OLD="sha256:$(printf 'a%.0s' {1..64})"; NEW="sha256:$(printf 'b%.0s' {1..64})"
  # pg-tools 사이트(바닥값 5를 넘긴다): 4파일 + backup-cronjob에 2개 = 5
  for f in platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" > "$FX/$f"
  done
  printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\ninit: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" "$OLD" > "$FX/platform/cache/prod/backup-cronjob.yaml"
  # skopeo 사이트(바닥값 2): 소비자 2곳
  printf 'image: ghcr.io/ukyi-app/skopeo:alpine@%s\n' "$OLD" > "$FX/platform/victoria-stack/prod/digest-exporter.yaml"
  printf 'image: ghcr.io/ukyi-app/skopeo:alpine@%s\n' "$OLD" > "$FX/platform/victoria-stack/prod/gha-liveness-exporter.yaml"
  # ⚠️ 도구가 대상을 **레포에서 파생**하므로(하드코딩 목록 폐기 — D-1) 픽스처도 git 레포여야 한다.
  git -C "$FX" init -q
  git -C "$FX" add -A
}
teardown() { rm -rf "$FX"; }

@test "rejects malformed digest" {
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "notadigest" --root "$FX"
  [ "$status" -ne 0 ]
}
@test "rejects an image key not in the catalog" {
  run bun tools/repin-ops-image.ts unknown:tag "$NEW" --root "$FX"
  [ "$status" -eq 2 ]
}
@test "repins every pg-tools site to the new digest" {
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rhoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$FX"
  pins="$output"
  printf '%s' "$pins" | grep -q "$NEW"
  # 🔴 여기 있던 `echo "$output" | grep -qv "$OLD"`는 **라이브 항진명제였다**(2026-08-29 실측).
  #    `-v`는 줄 단위 반전이라 다중 줄 피연산자에서 부재(∀줄 ¬매치)가 아니라 ∃줄 ¬매치를 잰다 —
  #    5사이트 중 **1곳만 OLD로 남은** 출력을 넣어도 `ok`였다(전 사이트가 OLD일 때만 red가 났다).
  #    즉 이 @test가 막겠다고 선언한 회귀(**일부** 사이트 미갱신)를 정확히 그 형태에서 놓쳤다.
  #    피연산자가 사이트 수만큼의 줄이므로 부재는 **건수**로만 닫힌다: OLD를 가진 줄 0건.
  #    (형제 관용구 `run grep -qF … <<<` + `[ "$status" -eq 1 ]`도 같은 주입에서 red다. 여기는
  #     "몇 곳이 남았나"가 진단의 알맹이라 -c를 쓴다. cf. tests/gates/test_host-ports.bats:11)
  run grep -cF "$OLD" <<<"$pins"
  [ "$output" -eq 0 ] || { echo "OLD pg-tools digest가 ${output}곳 남았다:"; printf '%s\n' "$pins"; false; }
}
@test "repins every skopeo site to the new digest (2-site image)" {
  run bun tools/repin-ops-image.ts skopeo:alpine "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rhoE 'skopeo:alpine@sha256:[0-9a-f]{64}' "$FX"
  pins="$output"
  printf '%s' "$pins" | grep -q "$NEW"
  # 이름이 "every"인데 NEW 존재만 보면 2사이트 중 **1곳 미갱신**에 눈이 먼다 — 위 pg-tools 자리와
  # 같은 클래스이고 처방도 같다(OLD를 가진 줄 0건). 2사이트라 부분 미갱신이 1가지뿐이지만,
  # 그 하나가 정확히 이 @test가 막겠다고 선언한 회귀다.
  run grep -cF "$OLD" <<<"$pins"
  [ "$output" -eq 0 ] || { echo "OLD skopeo digest가 ${output}곳 남았다:"; printf '%s\n' "$pins"; false; }
}
@test "repinning one image does not touch the other (per-image isolation)" {
  # pg-tools만 재핀 — skopeo 사이트는 OLD 그대로여야 한다.
  bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX" >/dev/null
  run grep -rhoE 'skopeo:alpine@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$OLD"   # skopeo는 안 바뀜
}
@test "idempotent no-op when already pinned" {
  bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX" >/dev/null
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX"
  [ "$status" -eq 0 ]; echo "$output" | grep -q "no-op"
}
@test "refuses to run when enumeration collapses (silent no-op guard)" {
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d"; git -C "$d" init -q
  run bun tools/repin-ops-image.ts pg-tools:18-rclone --root "$d" "sha256:$(printf '0%.0s' {1..64})"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}
@test "bump.yaml's opstag case set matches the tool CATALOG keys (no silent drift on a new ops image)" {
  # ★ 적대 검증이 잡은 자리. bump.yaml:92 주석이 "test_ops-repin이 강제한다"고 했으나 그런 게이트가
  #   없었다. CATALOG에 새 ops 이미지를 추가하고 bump.yaml의 opstag case를 잊으면 opstag=""가 돼
  #   그 이미지가 재핀되지 않고 조용히 드리프트한다(D-1 클래스). 두 집합을 실제로 대조해 그 갭을 닫는다.
  bump="$ROOT/.github/workflows/bump.yaml"
  tool="$ROOT/tools/repin-ops-image.ts"
  # bump.yaml opstag case 우변(canonical 태그) 집합
  opstags="$(grep -oE 'opstag="[^"]+"' "$bump" | sed 's/opstag="//;s/"//' | LC_ALL=C sort -u)"
  # 도구 CATALOG 키 집합
  catalog="$(grep -oE '"[a-z0-9-]+:[a-z0-9._-]+": \{ minSites' "$tool" | sed 's/": .*//;s/"//' | LC_ALL=C sort -u)"
  # 열거 붕괴 바닥값 — 둘 다 최소 2(pg-tools·skopeo)
  [ "$(printf '%s\n' "$opstags" | grep -c .)" -ge 2 ]
  [ "$(printf '%s\n' "$catalog" | grep -c .)" -ge 2 ]
  [ "$opstags" = "$catalog" ] || {
    echo "bump.yaml opstag case 집합 != 도구 CATALOG 키 집합 — 새 ops 이미지를 한쪽에만 추가했다"
    echo "opstag:"; printf '%s\n' "$opstags"
    echo "catalog:"; printf '%s\n' "$catalog"
    false
  }
}
@test "check-image-ownership's REPINNED_OPS set matches the tool CATALOG keys (no silent drift on a new ops image)" {
  # 세 사본 중 이 쌍만 무증인이었다. (CATALOG ↔ bump.yaml)은 바로 위 @test가 대조하지만
  # (CATALOG ↔ `check-image-ownership.ts`의 REPINNED_OPS)는 **주석뿐이었다**(소비자 2줄, 테스트 참조 0건).
  # 한쪽에만 새 ops 이미지를 넣으면 `resolveOwner`의 REPINNED_OPS 매치가 실패해 `renovateReaches`로
  # 떨어지고, renovate.json의 kubernetes manager가 `^platform/.+\.ya?ml$`를 덮으므로 그 참조가
  # "owner: renovate"로 **초록**이 된다 — 배포 사고가 아니라 **오귀속**이고, 그 가드 헤더가 존재
  # 이유로 적은 실패가 정확히 그것이다. 위 @test와 같은 파서 관용구·같은 바닥값 형태로 그 갭을 닫는다.
  own="$ROOT/tools/check-image-ownership.ts"
  tool="$ROOT/tools/repin-ops-image.ts"
  # REPINNED_OPS 정규식에서 이미지 키(<repo>:<tag>)를 뽑는다 — 표기가 refRe와 동형(`…\/<key>@sha256:…`)
  # 이라 이 파싱이 성립한다. 표기가 다시 갈리면 여기서 먼저 드러난다(바닥값이 그 붕괴를 잡는다).
  repinned="$(grep -oE '\\/[a-z0-9-]+:[a-z0-9._-]+@sha256:' "$own" | sed 's|^\\/||;s|@sha256:$||' | LC_ALL=C sort -u)"
  # 도구 CATALOG 키 집합(위 @test와 동일 관용구)
  catalog="$(grep -oE '"[a-z0-9-]+:[a-z0-9._-]+": \{ minSites' "$tool" | sed 's/": .*//;s/"//' | LC_ALL=C sort -u)"
  # 열거 붕괴 바닥값 — 둘 다 최소 2(pg-tools·skopeo). 양쪽이 함께 0이면 등식은 공허하게 참이다.
  [ "$(printf '%s\n' "$repinned" | grep -c .)" -ge 2 ]
  [ "$(printf '%s\n' "$catalog" | grep -c .)" -ge 2 ]
  [ "$repinned" = "$catalog" ] || {
    echo "check-image-ownership REPINNED_OPS 집합 != 도구 CATALOG 키 집합 — 새 ops 이미지를 한쪽에만 추가했다"
    echo "repinned:"; printf '%s\n' "$repinned"
    echo "catalog:"; printf '%s\n' "$catalog"
    false
  }
}
