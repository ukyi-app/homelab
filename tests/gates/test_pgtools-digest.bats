#!/usr/bin/env bats
# PG 메이저 3-이미지 함정 가드: `pg-tools:18-rclone` 참조가 **레포 전역**에서 단일 digest인지.
# 부분 갱신(skew)이 PgDumpHedgeStale를 재발시킨다. 순수 grep(CI-safe). ⚠️ [ ]만.
#
# ⚠️ **하드코딩 파일 목록을 쓰지 않는다**(D-1). 예전 이 파일은 `FILES=`에 4개 경로를 박아 두고
# "all consumers pin one identical digest"를 단언했는데, 그 4개는 `tools/repin-ops-image.ts`가
# 재핀하는 **바로 그 집합**이었다 — 이미 일치하도록 갱신된 닫힌 집합 안에서만 일치를 확인한 셈이다.
# 실측(2026-07-28): 목록 **밖**의 `platform/adguard/prod/rewrite-reconciler.yaml`와
# `platform/victoria-stack/prod/pvc-du-exporter.yaml`가 낡은 digest에 묶여 있었는데 이 가드는 초록이었다.
# 두 번째 @test는 이름이 "registry drift guard"였지만 목록에 **없는** 사이트가 새로 생기는 것을
# 원리적으로 탐지할 수 없었다 — 서술이 코드와 다른 전형이다.
# ⇒ 열거를 레포에서 파생하고, 바닥값으로 열거 붕괴를 막는다.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# 이미지별 인라인 핀 전수(테스트 하네스 제외 — repo-walk `image-ownership` 스코프와 같은 의미).
# $1 = 정규식 조각(예: `pg-tools:18-rclone` · `skopeo:alpine`).
refs() { git ls-files -- 'platform/**.yaml' 'platform/**.yml' 'apps/**.yaml' 'ops/**.yaml' \
  | grep -vE '(^|/)tests?/|(^|/)fixtures|(^|/)test_[^/]*$|\.bats$' \
  | xargs grep -hoE "$1@sha256:[0-9a-f]{64}" 2>/dev/null; }

@test "every pg-tools:18-rclone reference in the repo pins one identical digest (major-skew guard)" {
  all="$(refs 'pg-tools:18-rclone')"
  total="$(printf '%s\n' "$all" | grep -c . || true)"
  # 열거 붕괴 바닥값 — 0건이면 '위반 없음'이 아니라 글롭이 깨진 것이다(이 가드가 vacuous해진다).
  [ "$total" -ge 5 ]
  n="$(printf '%s\n' "$all" | LC_ALL=C sort -u | grep -c . || true)"
  [ "$n" -eq 1 ] || { echo "digest가 ${n}종으로 갈렸다:"; printf '%s\n' "$all" | LC_ALL=C sort | uniq -c; false; }
}

@test "every skopeo:alpine reference in the repo pins one identical digest (mirror-skew guard)" {
  # 소비자 둘(digest-exporter·gha-liveness-exporter)이 같은 digest를 가리켜야 한다 — 한쪽만 재핀되면
  # "같은 태그 다른 digest"가 되고, digest-exporter가 자기 소스와 어긋난 skopeo로 앱 digest를 조회한다.
  all="$(refs 'ghcr\.io/[a-z0-9-]+/skopeo:alpine')"
  total="$(printf '%s\n' "$all" | grep -c . || true)"
  [ "$total" -ge 2 ]   # 소비자 2곳 — 이 아래는 열거 붕괴다
  n="$(printf '%s\n' "$all" | LC_ALL=C sort -u | grep -c . || true)"
  [ "$n" -eq 1 ] || { echo "skopeo digest가 ${n}종으로 갈렸다:"; printf '%s\n' "$all" | LC_ALL=C sort | uniq -c; false; }
}

@test "the repin tool targets every skopeo site the repo actually has (derived, not hardcoded)" {
  tool="$(bun -e 'import {findSites} from "./tools/repin-ops-image.ts"; console.log(findSites("skopeo:alpine").reduce((a,e)=>a+e.sites,0))')"
  grepn="$(refs 'ghcr\.io/[a-z0-9-]+/skopeo:alpine' | grep -c . || true)"
  [ "$tool" -eq "$grepn" ] || { echo "도구 파생 ${tool}건 != grep ${grepn}건"; false; }
  [ "$tool" -ge 2 ]
}

@test "the repin tool targets every reference site the repo actually has (no hardcoded registry)" {
  # 재핀 도구가 파생하는 사이트 집합 == 위 grep이 보는 사이트 수. 도구가 목록을 다시 하드코딩하면
  # (또는 스코프가 좁아지면) 두 수가 갈려 red가 된다 — 그게 D-1의 재발 경로다.
  tool="$(bun -e 'import {findSites} from "./tools/repin-ops-image.ts"; console.log(findSites("pg-tools:18-rclone").reduce((a,e)=>a+e.sites,0))')"
  grepn="$(refs 'pg-tools:18-rclone' | grep -c . || true)"
  [ "$tool" -eq "$grepn" ] || { echo "도구 파생 ${tool}건 != grep ${grepn}건 — 재핀 대상이 레포와 어긋난다"; false; }
  [ "$tool" -ge 5 ]
}

@test "the repin tool refuses to run when its enumeration collapses (silent no-op guard)" {
  # 참조 0건은 '재핀할 게 없다'가 아니라 붕괴다. 빈 트리에서 비-0이어야 한다.
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d"; git -C "$d" init -q
  run bun "$ROOT/tools/repin-ops-image.ts" pg-tools:18-rclone --root "$d" sha256:0000000000000000000000000000000000000000000000000000000000000000
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the repin tool rewrites a drifted site outside the old hardcoded list (D-1 regression)" {
  # 옛 목록 밖 경로(victoria-stack)를 픽스처로 두고, 재핀이 실제로 그걸 고치는지 본다.
  d="$BATS_TEST_TMPDIR/fx"; mkdir -p "$d/platform/victoria-stack/prod" "$d/platform/cnpg/prod"
  old="sha256:9c4cb3572d07c495647be713bf8bbc58a2bf15bbcdd3fc4fc4ae387239cadecf"
  new="sha256:e73682bbb1905f0e7a9800e11cd6f7658842b0c909bc53d7605e3292c0c50eef"
  # 바닥값(5)을 넘기도록 옛 목록 안쪽 사이트도 함께 둔다.
  printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$old" > "$d/platform/victoria-stack/prod/pvc-du-exporter.yaml"
  : > "$d/platform/cnpg/prod/x.yaml"
  for i in 1 2 3 4; do printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$new" >> "$d/platform/cnpg/prod/x.yaml"; done
  git -C "$d" init -q; git -C "$d" add -A
  run bun "$ROOT/tools/repin-ops-image.ts" pg-tools:18-rclone --root "$d" "$new"
  [ "$status" -eq 0 ]
  # ⚠️ `-ne 0`은 grep rc **2**(대상 파일 부재/읽기불가)도 통과로 읽는다 — 무매치는 정확히 rc 1이다.
  #    (재핀이 파일을 지워버려도 옛 digest 부재가 '통과'로 보이던 자리다. 아래 양성 대조가 짝이다.)
  run grep -qF "$old" "$d/platform/victoria-stack/prod/pvc-du-exporter.yaml"
  [ "$status" -eq 1 ]
  run grep -qF "$new" "$d/platform/victoria-stack/prod/pvc-du-exporter.yaml"
  [ "$status" -eq 0 ]
}

@test "no consumer whitelist survives anywhere in the bump path (the fourth-copy regression)" {
  # 이 목록은 **네 번** 하드코딩돼 있었다: repin 도구의 CONSUMERS · 이 파일의 옛 FILES · 도구 헤더 주석 ·
  # 그리고 `.github/workflows/bump.yaml`의 `git add` 화이트리스트. 앞의 셋을 고친 뒤에도 네 번째가 남아
  # **도구는 6파일을 고치는데 4개만 커밋**됐고, 그러면 재빌드마다 드리프트가 그대로 되돌아온다
  # (적대 검토가 실측). 파일 열거가 어디에도 없어야 그 클래스가 닫힌다.
  run grep -nE 'platform/(cache|cnpg)/prod/[a-z-]+\.yaml' "$ROOT/.github/workflows/bump.yaml"
  # rc 2(bump.yaml 부재)를 통과로 읽지 않는다 — 워크플로가 사라지면 이 가드가 vacuous해진다.
  [ "$status" -eq 1 ] || { echo "bump.yaml에 소비처 파일 열거가 남아 있다(또는 파일을 읽을 수 없다):"; echo "$output"; false; }
  # 그리고 재핀 산출물이 실제로 스테이지되는 경로가 있어야 한다(위 검사가 '전부 지우기'로 만족되면 안 된다).
  run grep -qE '^ +git add .*platform' "$ROOT/.github/workflows/bump.yaml"
  [ "$status" -eq 0 ] || { echo "bump.yaml이 platform 변경을 스테이지하지 않는다 — 재핀이 커밋되지 않는다"; false; }
}

@test "no live site-count claim remains in the bump path (a number here becomes the next stale copy)" {
  # "5-site" 같은 건수 주장은 파생 모델에서 곧 낡은 사본이 된다(실측: bump.yaml에 2곳 남아 있었다).
  # ⚠️ 대상은 **bump.yaml만**이다. `tools/repin-ops-image.ts` 헤더는 옛 주장을 **따옴표로 인용해** 무엇이
  #    왜 틀렸는지 설명한다 — 그건 살아 있는 주장이 아니라 기록이고, 지우면 재발 방지 근거가 사라진다.
  #    (처음엔 두 파일을 함께 검사했다가 그 인용을 오탐으로 잡아 이 경계를 명시하게 됐다.)
  run grep -nE '[0-9]+-site|[0-9]+개 소비처' "$ROOT/.github/workflows/bump.yaml"
  # rc 2(bump.yaml 부재)를 통과로 읽지 않는다 — 이 @test는 부정 단언 하나뿐이라 더 그렇다.
  [ "$status" -eq 1 ] || { echo "낡은 건수 주장이 남아 있다(또는 파일을 읽을 수 없다):"; echo "$output"; false; }
}
