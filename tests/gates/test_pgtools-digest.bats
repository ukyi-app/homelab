#!/usr/bin/env bats
# PG 메이저 3-이미지 함정 가드: `pg-tools:18-rclone` 참조가 **레포 전역**에서 단일 digest인지.
# 부분 갱신(skew)이 PgDumpHedgeStale를 재발시킨다. 순수 grep(CI-safe). ⚠️ [ ]만.
#
# ⚠️ **하드코딩 파일 목록을 쓰지 않는다**(D-1). 예전 이 파일은 `FILES=`에 4개 경로를 박아 두고
# "all consumers pin one identical digest"를 단언했는데, 그 4개는 `tools/repin-pgtools.ts`가
# 재핀하는 **바로 그 집합**이었다 — 이미 일치하도록 갱신된 닫힌 집합 안에서만 일치를 확인한 셈이다.
# 실측(2026-07-28): 목록 **밖**의 `platform/adguard/prod/rewrite-reconciler.yaml`와
# `platform/victoria-stack/prod/pvc-du-exporter.yaml`가 낡은 digest에 묶여 있었는데 이 가드는 초록이었다.
# 두 번째 @test는 이름이 "registry drift guard"였지만 목록에 **없는** 사이트가 새로 생기는 것을
# 원리적으로 탐지할 수 없었다 — 서술이 코드와 다른 전형이다.
# ⇒ 열거를 레포에서 파생하고, 바닥값으로 열거 붕괴를 막는다.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# 추적된 platform/apps/ops YAML의 인라인 핀 전수(테스트 하네스 제외 — repo-walk `image-ownership` 스코프와 같은 의미).
refs() { git ls-files -- 'platform/**.yaml' 'platform/**.yml' 'apps/**.yaml' 'ops/**.yaml' \
  | grep -vE '(^|/)tests?/|(^|/)fixtures|(^|/)test_[^/]*$|\.bats$' \
  | xargs grep -hoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' 2>/dev/null; }

@test "every pg-tools:18-rclone reference in the repo pins one identical digest (major-skew guard)" {
  all="$(refs)"
  total="$(printf '%s\n' "$all" | grep -c . || true)"
  # 열거 붕괴 바닥값 — 0건이면 '위반 없음'이 아니라 글롭이 깨진 것이다(이 가드가 vacuous해진다).
  [ "$total" -ge 5 ]
  n="$(printf '%s\n' "$all" | sort -u | grep -c . || true)"
  [ "$n" -eq 1 ] || { echo "digest가 ${n}종으로 갈렸다:"; printf '%s\n' "$all" | sort | uniq -c; false; }
}

@test "the repin tool targets every reference site the repo actually has (no hardcoded registry)" {
  # 재핀 도구가 파생하는 사이트 집합 == 위 grep이 보는 사이트 수. 도구가 목록을 다시 하드코딩하면
  # (또는 스코프가 좁아지면) 두 수가 갈려 red가 된다 — 그게 D-1의 재발 경로다.
  tool="$(bun -e 'import {findSites} from "./tools/repin-pgtools.ts"; console.log(findSites().reduce((a,e)=>a+e.sites,0))')"
  grepn="$(refs | grep -c . || true)"
  [ "$tool" -eq "$grepn" ] || { echo "도구 파생 ${tool}건 != grep ${grepn}건 — 재핀 대상이 레포와 어긋난다"; false; }
  [ "$tool" -ge 5 ]
}

@test "the repin tool refuses to run when its enumeration collapses (silent no-op guard)" {
  # 참조 0건은 '재핀할 게 없다'가 아니라 붕괴다. 빈 트리에서 비-0이어야 한다.
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d"; git -C "$d" init -q
  run bun "$ROOT/tools/repin-pgtools.ts" --root "$d" sha256:0000000000000000000000000000000000000000000000000000000000000000
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
  run bun "$ROOT/tools/repin-pgtools.ts" --root "$d" "$new"
  [ "$status" -eq 0 ]
  run grep -qF "$old" "$d/platform/victoria-stack/prod/pvc-du-exporter.yaml"
  [ "$status" -ne 0 ]
  run grep -qF "$new" "$d/platform/victoria-stack/prod/pvc-du-exporter.yaml"
  [ "$status" -eq 0 ]
}
