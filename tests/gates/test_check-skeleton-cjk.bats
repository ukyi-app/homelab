#!/usr/bin/env bats
# CJK @test 이름 가드 — 한글/CJK는 bats 디렉토리 실행 시 침묵스킵(검증된 함정).
# em-dash·trailing 한국어 주석은 bats OK라 제외 — @test "이름"의 **이름만** 검사. ⚠️ 중간 단언 [ ]만.
#
# ⚠️ 이 스위트는 **실 체크아웃을 전혀 건드리지 않는다**. 종전 음성 대조는 실 `tests/gates/`에 CJK 이름
#    픽스처를 만들고 `git add -N`으로 **공유 `.git/index`**에 올렸다 — 파일 단위 병렬 bats에서 그 창을
#    밟은 다른 프로세스의 가드(check-skeleton·check-doc-index…)가 거짓 red를 냈다(docs/traps-detail.md
#    「파일 단위 병렬 bats에서 실 체크아웃을 잠깐 바꾸는 스위트는 …」). 처방은 가드를 **픽스처 사본
#    레포**에서 돌리는 것이다: 가드가 ROOT를 자기 위치(BASH_SOURCE/../..)에서 파생하므로 사본 가드는
#    사본 트리를 검사하고, 인덱스 쓰기도 사본 레포의 것이 된다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# CJK = Unicode 스크립트 속성(무브래킷 fragment — [$CJK]로 1회 감쌈). Han/Hangul/Hiragana/Katakana는
# Ext-A(㐀 U+3400)·compat 이데오그래프·Hangul 확장까지 모두 포함(하드코딩 범위 누락 방지, F7).
CJK='\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}'
CJK_FIX="tests/gates/test_zzz_cjk_neg_fixture.bats"   # 음성 픽스처 경로(**사본 레포 안**)

# check-skeleton이 초록으로 돌 수 있는 **최소 사본 레포**를 $BATS_TEST_TMPDIR 아래에 짓는다.
# 담는 것은 가드가 실제로 읽는 것뿐이다: 가드 + lib 커널 + 유닛 열거 워커(bun) + 스켈레톤 디렉토리 +
# README 컴포넌트 표 + 추적된 bats 1건. 바닥값은 공용 어휘 `--floor <도메인>=<n>`으로 낮춘다
# (실 레포 기준값 150/10/200은 사본에서 성립할 수 없다 — 도메인 이름은 check-skeleton.sh의 take_floors 선언).
# node_modules는 **심볼릭 링크**다(repo-walk.ts가 `yaml`을 import한다) — 사본에 실물을 복사하지 않는다.
skeleton_fixture() {
  fx="$1"
  mkdir -p "$fx/scripts/lib" "$fx/tools/lib" "$fx/tests/gates" \
    "$fx/infra/cloudflare" "$fx/infra/github" "$fx/infra/tailscale" "$fx/infra/k3s-bootstrap" \
    "$fx/platform/argocd/root" "$fx/platform/charts/app" "$fx/apps"
  cp "$ROOT/scripts/check-skeleton.sh" "$fx/scripts/check-skeleton.sh"
  cp "$ROOT/scripts/lib/guard.sh" "$fx/scripts/lib/guard.sh"
  cp "$ROOT/scripts/lib/scan-floor.sh" "$fx/scripts/lib/scan-floor.sh"
  cp "$ROOT/tools/lib/repo-walk.ts" "$fx/tools/lib/repo-walk.ts"
  cp "$ROOT/tools/lib/exec.ts" "$fx/tools/lib/exec.ts"
  # 의존 부재를 여기서 시끄럽게 잡는다 — 링크가 끊겨 있으면 `yaml` import가 죽어 platform 레인이
  # 열거 실패로 넘어가고, 그 red가 "CJK 레인이 고장났다"로 오독된다(bun install 선행 조건).
  [ -d "$ROOT/node_modules" ]
  ln -s "$ROOT/node_modules" "$fx/node_modules"
  printf 'node_modules\n' > "$fx/.gitignore"
  # README 지도 — platform/argocd(유일한 컴포넌트 유닛; charts/는 스코프가 제외한다)의 표 행.
  printf '# fixture\n\n### platform 컴포넌트\n\n| 컴포넌트 | 역할 |\n|---|---|\n| `argocd` | fixture component |\n\n## end\n' > "$fx/README.md"
  printf '@test "ascii only name" {\n  true\n}\n' > "$fx/tests/gates/test_fx_clean.bats"
  git -C "$fx" init -q
  git -C "$fx" add -A
}

# 사본 가드 실행 — 바닥값 3종을 사본 크기로 낮춘 고정 argv(콜사이트 중복 제거).
run_fixture_guard() {
  run bash "$1/scripts/check-skeleton.sh" \
    --floor check-skeleton:bats=1 --floor check-skeleton:platform=1 --floor check-skeleton:nul-scan=1
}

@test "CJK detector flags Hangul AND CJK-extension @test NAMES only (script properties; ignores em-dash/ascii/comment)" {
  TMP="$(mktemp -d)"
  printf '  @test "%s" {\n  @test "%s extA" {\n  @test "ascii name" { # %s\n  @test "drill %s PVC" {\n  # @test "%s" mention\n' \
    "한글 이름" "㐀" "한글 주석" "—" "한글" > "$TMP/test_fx.bats"
  # 이름만 캡처 후 $1 검사(F2) — trailing 주석·em-dash·주석언급 제외. 한글(1)+Ext-A 㐀(2)만 HIT.
  run perl -CSDA -ne 'print "$ARGV:$.\n" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$TMP/test_fx.bats"
  [ "$status" -eq 0 ]
  # ⚠️ `grep -c .`(모든 줄)이 아니라 **결과 형태(`파일:행번호`)에 맞는 줄만** 센다. bats의 `run`은
  #    stderr를 $output에 합치는데, perl은 로케일이 불완전하면 경고를 19줄쯤 쏟는다
  #    (맥에서 ssh할 때 `LC_CTYPE=UTF-8`이 전달되면 리눅스엔 그런 로케일이 없어 그렇게 된다 —
  #     2026-08-19 NUC 이관에서 실측). 그러면 잡음이 카운트에 섞여 이 가드가 **환경 탓으로** 빨개진다.
  #    형태를 특정해도 fail-loud는 유지된다: perl이 진짜로 죽으면 매칭 줄이 0이라 여전히 실패한다.
  [ "$(printf '%s' "$output" | grep -cE ':[0-9]+$')" -eq 2 ]   # 정확히 2줄(한글·㐀 이름 선언)
  echo "$output" | grep -q ':1$'                      # 한글(라인1)
  echo "$output" | grep -q ':2$'                      # Ext-A 㐀(라인2) — 하드코딩 범위면 놓침
}

@test "check-skeleton FAILS (exit!=0) on a tracked CJK @test name — black-box negative (F5)" {
  # 토큰 grep이 아니라 실제 실행: CJK @test 픽스처를 git ls-files에 보이게(add -N) 한 뒤 check-skeleton 실행.
  # 실행 대상은 **사본 레포의 가드**다 — 실 체크아웃에는 파일 생성도 인덱스 쓰기도 일어나지 않는다.
  fx="$BATS_TEST_TMPDIR/fx-cjk"
  skeleton_fixture "$fx"
  # 양성 대조 — CJK 이름이 없는 사본에서는 가드가 초록이다. 이게 없으면 아래 음성은 vacuous하다
  # (사본이 다른 이유로 늘 red여도 `status != 0`은 만족된다).
  run_fixture_guard "$fx"
  [ "$status" -eq 0 ]
  # 음성 — CJK @test 이름 하나를 추적시키면 그 레인이 rc=1로 막는다.
  printf '@test "%s" {\n  true\n}\n' "한글이름테스트" > "$fx/$CJK_FIX"
  git -C "$fx" add -N "$CJK_FIX"
  run_fixture_guard "$fx"
  [ "$status" -eq 1 ]                                     # CJK @test 때문에 비-0 종료(rc=1 배선 증명)
  echo "$output" | grep -q 'CJK'                          # CJK 메시지로 실패(다른 이유 아님)
  echo "$output" | grep -q "$CJK_FIX"                     # 위반 파일을 지목한다
}

@test "current repo has zero CJK @test names (immediate-green)" {
  bad=""
  while IFS= read -r f; do
    h="$(perl -CSDA -ne 'print "x" if /^\s*\@test\s+"([^"]*)"/ && $1 =~ /['"$CJK"']/' "$f")"
    if [ -n "$h" ]; then bad="$bad $f"; fi
  done < <(git ls-files '*test_*.bats')
  [ -z "$bad" ]
}
