#!/usr/bin/env bats
# check-sigpipe-writers.sh 의 판정 증인. @test 이름은 영어.
#
# ⚠️ 이 파일이 존재하는 이유(2026-09-01): 가드는 #565/#574로 21곳을 고치고 세워졌는데 **증인이
#    0건이었다.** 그 사이 정규식에 접두 `^[[:space:]]*[^#].*`가 있어 `[^#]`가 컬럼 0 줄의 첫
#    글자를 소비했고, 같은 취약 코드가 **들여쓰면 red · 컬럼 0이면 초록**이었다. 즉 가드가
#    고친 21곳 중 컬럼 0으로 회귀하는 것은 아무도 못 봤다. 뮤테이션을 밟는 증인이 없으면
#    가드의 판정 조건은 무증인으로 남는다(traps 「테스트 이름은 인터페이스가 아니다」).
#
# ⚠️ 판정은 **실 체크아웃이 아니라 $BATS_TEST_TMPDIR의 사본 레포**에서 잰다(2026-09-09). 종전 판은
#    실 `scripts/`·`scripts/lib/`에 픽스처 `.sh`를 만들고 실 레포의 **공유 인덱스**를 썼다 — 파일 단위
#    병렬 bats에서 그 창을 밟은 다른 프로세스의 가드(check-skeleton·check-doc-index·
#    `make ci-guard-tracked`…)가 거짓 red를 낸다(docs/traps-detail.md 「파일 단위 병렬 bats에서 실
#    체크아웃을 잠깐 바꾸는 스위트는 …」). 가드는 ROOT를 자기 위치(`BASH_SOURCE/../..`)에서 파생하므로,
#    가드 + 커널 둘을 복사한 빈 git 레포가 곧 **그 사본 가드의 실 도메인**이 된다(선례:
#    tests/gates/test_bats-style.bats · tests/gates/test_check-doc-index.bats의 docindex_fixture).
#    바닥값(기본 10)은 공용 어휘 `--floor check-sigpipe-writers:files=1`로 낮춘다 — take_floors는
#    바닥값 **수치만** 바꾸고 위반 검출 경로는 건드리지 않는다(scripts/lib/scan-floor.sh).
#    사본 트리의 분모에는 가드 자신과 커널 둘도 들어간다(실 트리에서 이미 통과하는 파일들) — 그래서
#    아래 control 레그가 "기저가 깨끗하다"를 매 실행 다시 확인하고, 양성 레그는 그 위의 델타를 잰다.
#    가드가 **실 도메인에 닿는다**는 사실은 사본으로 증명되지 않으므로 마지막 레그가 실 체크아웃을
#    기본 바닥값 그대로 한 번 돈다(읽기 전용 — 가드는 열거·grep만 한다).
#
# ⚠️ 중간 단언은 `[ ]`만 쓴다(bash 3.2에서 중간 `[[ ]]`는 침묵 통과한다).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$ROOT/scripts/check-sigpipe-writers.sh"
  # 사본 레포. $BATS_TEST_TMPDIR는 @test마다 새로 만들어졌다가 지워지므로 unseed/teardown이 필요 없다.
  FX="$BATS_TEST_TMPDIR/fx"
  FXGUARD="$FX/scripts/check-sigpipe-writers.sh"
  FIX="$FX/scripts/fixture.sh"
  LIBFIX="$FX/scripts/lib/fixture.sh"
  mkdir -p "$FX/scripts/lib"
  cp "$GUARD" "$FXGUARD"
  cp "$ROOT/scripts/lib/guard.sh" "$ROOT/scripts/lib/scan-floor.sh" "$FX/scripts/lib/"
  git -C "$FX" init -q
  # `-f` — 사용자 전역 excludesFile이 사본 파일명을 무시 대상으로 잡는 경우까지 닫는다.
  git -C "$FX" add -f -A
}

# 픽스처를 **사본 레포**의 인덱스에 올린다 — 가드가 `git ls-files '*.sh'`로 열거하기 때문이다
# (traps 「tracked 열거 게이트는 untracked 파일을 아예 안 본다」 — 그래서 add가 필수다).
seed() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%b' "$1" > "$FIX"
  git -C "$FX" add -f -- "$FIX"
}

@test "guard exists, is executable and is registered in the local ledger" {
  [ -x "$GUARD" ]
  run grep -q 'check-sigpipe-writers.sh' "$ROOT/policy/ci-parity.json"
  [ "$status" -eq 0 ]
}

# control — 기저(가드 자신 + 커널 2)가 깨끗해야 아래 양성 레그의 비-0이 **씨앗의 델타**를 뜻한다.
# 이게 없으면 기저가 오염된 순간 모든 양성 레그가 이유 없이 red로 남아 무증인이 된다.
# 이 레그는 `--floor` 표기 자체의 증인이기도 하다 — 라벨을 오타 내면 take_floors가 exit 2를 내는데,
# 그러면 `[ "$status" -ne 0 ]` 양성 레그 전부가 **위반을 안 잡고도** 통과한다. 여기서만 rc 0 +
# 통과 메시지를 함께 요구해 그 자리를 닫는다.
@test "the unseeded fixture repo passes (control for the positive legs below)" {
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
  grep -q 'check-sigpipe-writers OK' <<<"$output"
}

@test "flags a vulnerable multiline writer at column 0" {
  seed "printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "flags the same writer when indented" {
  seed "  printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "flags an echo writer at column 0" {
  seed "echo \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "does not flag a whole-line comment that documents the idiom" {
  seed "# printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag an indented whole-line comment either" {
  # 이 레그는 옛 정규식에서도 통과했다(거짓양성 재현 안 됨 — ERE는 leftmost-longest라
  # `[^#]`가 공백을 먹는 백트래킹이 기대만큼 열리지 않는다). 회귀 방지로 남긴다.
  seed "  # echo \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag the prescribed herestring form" {
  seed "grep -q x <<<\"\$list\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "ignores a file that does not enable pipefail (scope rule 1)" {
  # ⚠️ 이 레그는 **무증인이었다**(2026-09-09 뮤테이션 실측). 종전 픽스처 본문은
  # `printf '…\nprintf %s\\\\n "$list" | grep -q x\n'`이었는데, 바깥 printf가 그 `%s`를 자기
  # 변환 지정자로 먹어(인자 0개 → 빈 문자열) 파일에 실제로 쓰인 줄은 `printf \\n "$list" | grep -q x`,
  # 즉 레인 (a) 패턴(`printf '%s\n'` — 따옴표 포함)에 **애초에 안 걸리는 모양**이었다. 스코프
  # 규칙 ①(pipefail 필터)을 통째로 떼도 초록이었다 — 이름만 규칙을 말하고 본문은 아무것도
  # 재지 않았다(이 파일 헤더의 「테스트 이름은 인터페이스가 아니다」를 이 레그 자신이 밟았다).
  # 처방: 본문을 **한 변수로** 소유하고 헤더만 갈아 끼워 양성/음성을 같은 @test에서 짝짓는다.
  body="printf '%s\\\\n' \"\$list\" | grep -q x\n"
  # 양성 대조 — 같은 본문에 pipefail 헤더면 red다(본문이 실제로 위반이라는 증인).
  seed "$body"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  # 판정 — 헤더에서 pipefail 리터럴만 빼면 스코프 밖이라 초록이다.
  printf '#!/usr/bin/env bash\nset -eu\n%b' "$body" > "$FIX"
  git -C "$FX" add -f -- "$FIX"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "flags a sourced-not-executed lib with no pipefail literal in its own text (lib scope rule)" {
  # pipefail은 호출자 셸의 런타임 옵션이지 파일의 텍스트 속성이 아니다 — source 전용 lib
  # (scripts/lib/*.sh, 자기 원문에 pipefail 리터럴이 없다)이 pipefail 아래에서 source되는 형태는
  # scripts/lib/sops-recipients.sh(sops-guard.sh:24·verify-secrets.sh:22가 pipefail 아래서 source)가
  # 실제로 그 모양이다. 픽스처는 lib 표기 아래 pipefail 원문 없이 다중행 writer를 파이프한다.
  cat > "$LIBFIX" <<'FIXEOF'
v="$(printf 'a\nb\n')"
printf '%s\n' "$v" | grep -q y
FIXEOF
  git -C "$FX" add -f -- "$LIBFIX"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  # 위반 자리가 그 lib 픽스처임을 못박는다 — 기저 오염이 이 레그를 대신 통과시키지 못한다.
  grep -qF 'scripts/lib/fixture.sh' <<<"$output"
}

@test "the guard prescribes herestring in its failure output" {
  seed "printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  grep -q '<<<' <<<"$output"
}

# ── 분모 ② 확장(파일/명령 writer) — 검출기 자기-뮤테이션 증인 ────────────────────────────────────
# 2026-09-05 실증: 옛 분모(printf/echo만)는 `sed … "$f" | grep -qE 'guard_init'`(scripts/netpol-
# rehearsal.sh·tests/gates/vmalert-meta-firing-e2e.sh의 kubectl/grep -oE 실측 형태와 동형)에 rc 0을
# 냈다(레인 D — PR #641 gate red 원인). 아래는 넓힌 분모가 그 클래스를 잡고, 주석/grep -c(소비-완료)/
# herestring 재작성 형태는 그대로 살리는지를 함께 증언한다.

@test "flags a sed file-writer piped into grep -q (c71-3 denominator expansion)" {
  seed "sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "flags the same sed writer when indented (c71-3)" {
  seed "  sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "flags a kubectl multiline writer piped into grep -q (c71-3 denominator expansion)" {
  # scripts/netpol-rehearsal.sh 실측 형태(2026-09-05, 이 티켓이 herestring으로 전환) 재현.
  seed "kubectl -n prod get netpol x -o yaml | grep -q \"\$NEEDLE\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

# ⚠️ 다단 파이프(예: `kubectl … | sort | grep -q NEEDLE`)는 이 레인의 사각이다.
#    키워드-바로-다음-파이프 인접만 보는 정규식이라 목록 밖 중간 명령(sort·tr·uniq·column 등)이 하나만
#    끼어도 무증인이다. 의도적으로 미대상 — 코드를 넓히면 무관 파이프가 오탐으로 뒤집힌다(check-sigpipe-writers.sh
#    헤더 ②(b) 참고). 전수 열거 라이브 위반 0건이라 확장 대상이 아니며, 새 사례가 나오면 개별 케이스로 추가한다.

@test "does not flag a whole-line comment that documents the command-writer idiom (c71-3)" {
  seed "# sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag a command writer consumed by grep -c instead of -q (safe consume-to-completion form, c71-3)" {
  seed "sed 's/x//' \"\$f\" | grep -c 'guard_init'\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag the prescribed herestring rewrite of a command writer (c71-3)" {
  seed "v=\"\$(sed 's/x//' \"\$f\")\"\ngrep -qE 'guard_init' <<<\"\$v\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "flags an awk early-exit consumer fed by a pipe at column 0 (lane c, ticket 49)" {
  seed "idx=\"\$(ip -o -4 addr show | awk -v ip=\"\$K3S_NODE_IP\" '\$4 ~ ip { print \$1; exit }')\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  grep -qF -- "awk '… exit'" <<<"$output"
}

@test "flags the same awk early-exit consumer when indented (lane c)" {
  seed "  d=\"\$(lsblk -nso NAME,TYPE \"\$src\" | awk '\$2 == \"disk\" { print \$1; exit }')\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "does not flag the prescribed capture-then-herestring form of an awk early-exit consumer (lane c)" {
  seed "addrs=\"\$(ip -o -4 addr show)\"\nidx=\"\$(awk '\$4 ~ ip { print \$1; exit }' <<<\"\$addrs\")\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag an awk pipe consumer without exit, nor a whole-line comment documenting the idiom (lane c)" {
  seed "n=\"\$(ip -o -4 addr show | awk '{ print \$4 }' | cut -d/ -f1)\"\n# 옛 형태: ip … | awk '{ print \$1; exit }' 는 SIGPIPE 함정\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

# ── 레인 (d): `| head` 조기 종료 소비자 ─────────────────────────────────────────────────────────
# restore-drill의 `_live_psql … | head -1`이 성공한 쓰기를 실패로 보고하던 클래스(2026-09-09). writer를 가리지 않는다.

@test "flags a head consumer fed by a pipe at column 0 (lane d)" {
  seed "x=\"\$(kubectl get pods | head -1)\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  grep -qF '| head -1' <<<"$output"
}

@test "flags an indented head consumer with the -n form and a scalar printf writer (lane d measures the consumer)" {
  seed "  first=\"\$(printf '%s' \"\$v\" | head -n 1)\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
}

@test "does not flag the prescribed capture-then-herestring form of a head consumer (lane d)" {
  seed "out=\"\$(kubectl get pods)\" || out=''\nfirst=\"\$(head -n1 <<<\"\$out\" | cut -d' ' -f1)\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
}

@test "does not flag a whole-line comment documenting the head idiom, and names lane d in the prescription (lane d)" {
  seed "# 예전 형태: cmd | head -1 (금지)\nx=1\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -eq 0 ]
  seed "x=\"\$(sed -n 's/^a=//p' f | head -1)\"\n"
  run bash "$FXGUARD" --floor check-sigpipe-writers:files=1
  [ "$status" -ne 0 ]
  grep -qF '레인 d' <<<"$output"
}

# 사본 레포는 "패턴이 무엇을 잡는가"만 증명한다 — 그 가드 호출이 **실 도메인에 닿았는가**는 다른
# 사실이고 텍스트로는 갈리지 않는다(scripts/lib/scan-floor.sh의 SCAN 신호 규약: 실측 반례 2건이
# "루트 인자가 실 레포를 가리키거나, 한 파일에 픽스처 호출과 실 트리 호출이 섞여 있다"였다).
# 그래서 실 체크아웃을 기본 바닥값 그대로 한 번 돈다 — 이 레그는 열거·grep뿐이라 쓰기가 없다.
@test "the guard evaluates the real checkout at its default floor and emits its SCAN marker" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  grep -qE '^SCAN: check-sigpipe-writers:files: [0-9]+$' <<<"$output"
}
