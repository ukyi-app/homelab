#!/usr/bin/env bats
# check-doc-index 게이트 — 두 레인의 증인.
#   [1] 등재: scripts/·tools/·workflows README 등재 드리프트 차단.
#   [2] 스코프: scripts/README.md의 **가드 bullet**이 계산 가능한 사실(실행 경로)을 주장하지 않는지.
#
# ⚠️ [2]는 **부재 단언**이다 — "이 문자열이 0건"류 가드는 스코프가 조금만 어긋나도 무증인 초록이
#    된다(이 캠페인이 닫는 병소 형태). 그래서 여기 단언은 전부 두 겹이다: 뮤테이션이 red를 내는지와,
#    같은 픽스처의 **양성 대조**가 green인지를 함께 잰다. 양성 대조가 없으면 "원래부터 red"와
#    "뮤테이션 때문에 red"를 구별할 수 없다.
# ⚠️ 픽스처 bullet 이름은 **가드 모양**(`check-*`)이어야 한다 — 레인 [2]의 스코프가 가드 bullet뿐이라
#    `a.sh` 같은 이름은 원리적으로 위반이 될 수 없다(그 경계 자체도 아래에서 잰다).
# ⚠️ @test 이름은 영어만 — 디렉토리 단위 실행에서 CJK 이름이 침묵 스킵된다(AGENTS.md).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패가 침묵 통과한다(AGENTS.md).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  GUARD="$ROOT/scripts/check-doc-index.sh"
  README="$ROOT/scripts/README.md"
  BT='`'
  # 실재 단언 — 대상이 사라지면 아래 판정 전부가 자기 자신 vacuous다.
  [ -x "$GUARD" ]
  [ -s "$README" ]
}

@test "check-doc-index passes on the current tree (all artifacts registered)" {
  run ./scripts/check-doc-index.sh
  [ "$status" -eq 0 ]
}

@test "check-doc-index FAILS when a script is missing from scripts/README.md" {
  tmp="scripts/zz_docindex_probe.sh"; : > "$tmp"; chmod +x "$tmp"
  run ./scripts/check-doc-index.sh
  rm -f "$tmp"
  # `-ne 0`이 아니라 `-eq 1`이다 — 사용법 오류(2)·검출기 사망도 비-0이라 `-ne 0`은 "미등재를 잡았다"와
  # "가드가 딴 데서 죽었다"를 구별하지 못한다(01의 처방과 같은 축).
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "zz_docindex_probe.sh"
}

@test "a prose mention alone does not satisfy registration for a non-guard script (bullet head anchor required)" {
  # grep-a-7 — 가드 모양 스크립트(check-*/verify-*/*-guard/*-check)는 레인 [2]의 등식
  # (아래 "the guard-shaped bullet count equals …")이 이미 삭제를 잡는다(bullet 수가 줄면 그
  # 등식이 깨진다). 이 축이 실제로 새로 닫는 것은 **비-가드** 스크립트(bootstrap.sh·destroy-node.sh·
  # dr-drill.sh·notify-unit-failure.sh·sealing-key-dr-gate.sh·teardown.sh)다 — 그것들엔 그 백스톱이
  # 없다. probe는 그래서 가드 모양이 아닌 이름을 쓴다.
  # ⚠️ 정리(git checkout/rm)는 항상 run 직후·단언 **이전**에 둔다 — 단언이 실패하면 bats가 그
  #    자리에서 테스트를 중단해, 뒤에 둔 정리가 실행 안 된 채 README·프로브 파일이 실 트리에
  #    남는다(실측: 이 순서를 뒤집어 두면 이후 @test 1이 오염된 상태로 죽는다).
  tmp="scripts/zz_docindex_bullet_probe.sh"; : > "$tmp"; chmod +x "$tmp"
  printf '\n산문 언급 — `zz_docindex_bullet_probe.sh`는 등재 목적이 아니라 그냥 언급이다.\n' >> "$README"
  run ./scripts/check-doc-index.sh
  git checkout -- "$README"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "zz_docindex_bullet_probe.sh"
  # 양성 대조 — 같은 파일에 진짜 bullet 머리를 달면 green이다(원인이 "산문 vs bullet 머리"임을 고정).
  printf '\n- **`zz_docindex_bullet_probe.sh`** — 프로브(테스트 전용, 실행 없음).\n' >> "$README"
  run ./scripts/check-doc-index.sh
  git checkout -- "$README"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "a bullet-decorated decoy inside mid-sentence prose does not satisfy registration (line anchor required)" {
  # reg-a1-bats-guards-1 — grep-a-7(56d0aad)은 「형제 bullet의 산문 언급이 등재 증인으로
  # 오인된다」를 고쳤다고 주장했지만 실제 검색이 grep -Fq(무앵커 부분문자열)라 그 취약점이
  # 그대로 남았다 — 「- **`name`**」 장식이 줄 **어디에** 있든(줄 시작이 아니어도) 매치했다.
  # 이 픽스처는 그 정확한 형태(장식은 재현하되 줄 시작은 '-'가 아닌 순수 산문)로 재발을 잡는다.
  tmp="scripts/zz_docindex_anchor_probe.sh"; : > "$tmp"; chmod +x "$tmp"
  printf '반례를 인용한다: 예전엔 %s- **%s%s%s**%s 처럼 산문 안에서도 매치됐다.\n' \
    "$BT" "$BT" "zz_docindex_anchor_probe.sh" "$BT" "$BT" >> "$README"
  run ./scripts/check-doc-index.sh
  git checkout -- "$README"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "zz_docindex_anchor_probe.sh"
}

# ── 레인 [2] 추출의 비공허 바닥값 ─────────────────────────────────────────────────────────────
# 검출기가 bullet을 실제로 몇 개 봤는지가 SCAN 마커로 나온다 — 이 수가 붕괴하면 "위반 0"은
# 무의미하다. 추출 자체의 양성 대조다.
@test "the scope lane reports a non-vacuous bullet count on the real README" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  n="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-doc-index:readme-bullets: //p')"
  [ -n "$n" ]
  [ "$n" -ge 40 ]
}

# ── 스코프의 SSOT 대조 ────────────────────────────────────────────────────────────────────────
# 가드 이름 모양 판정은 tools/lib/repo-walk.ts의 `guards` 스코프를 손으로 옮긴 사본이다. 사본을
# 남기되 **대조되지 않게 두지 않는다** — 권위 도구가 실제로 계산한 scripts/ 가드 수와 가드 bullet
# 수가 같아야 한다. 어긋나면 (a) 모양 규칙이 드리프트했거나 (b) README 등재가 빠진 것이다.
@test "the guard-shaped bullet count equals what the authority tool actually computes" {
  [ -n "$(command -v bun)" ]
  n_auth="$(bun tools/check-guard-authority.ts --json 2>/dev/null \
            | jq -r '.report[].guard' | grep -c '^scripts/')"
  [ "$n_auth" -ge 20 ]
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  n_bullet="$(printf '%s\n' "$output" | sed -n 's/.*가드 \([0-9][0-9]*\)건.*/\1/p')"
  [ -n "$n_bullet" ]
  [ "$n_bullet" -eq "$n_auth" ]
}

# ── 뮤테이션 ① 절 리네임 우회 소멸 + 추출 붕괴는 명시 FAIL ────────────────────────────────────
# 옛 처방(「## CI 게이트」 절 스코프 hard-zero)은 절 이름 한 줄로 통째로 우회됐다. 판정 단위를
# bullet으로 올리면 리네임은 **아무것도 바꾸지 않고**(green 유지) 그 절 안의 주장은 여전히 red다.
@test "renaming the section does not move the scope (the claim inside still goes red)" {
  f="$BATS_TEST_TMPDIR/renamed.md"
  sed 's/^## CI 게이트.*$/## 검사 모음 (절 이름 바꿈)/' "$README" > "$f"
  # 양성 대조 — 리네임만으로는 green이어야 한다(절 제목은 부류 라벨일 뿐이다).
  run bash "$GUARD" --readme "$f"
  [ "$status" -eq 0 ]
  # 리네임한 절 안에 잘못된 권위 주장을 하나 되살린다.
  line="- **${BT}check-zz-probe.sh${BT}** — **${BT}make verify${BT}**가 호출."
  awk -v L="$line" '{ print } /^## 검사 모음/ { print ""; print L }' "$f" > "$f.bad"
  run bash "$GUARD" --readme "$f.bad"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "check-zz-probe.sh"
}

@test "an extraction that yields zero bullets is an explicit FAIL, not a pass" {
  f="$BATS_TEST_TMPDIR/nobullet.md"
  printf '%s\n' '# t' '' '## X' '' 'bullet이 하나도 없는 문서.' > "$f"
  run bash "$GUARD" --readme "$f"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

# ── 뮤테이션 ② 잘못된 권위 주장 부활 ──────────────────────────────────────────────────────────
@test "reviving a non-authoritative wiring claim turns the scope lane red" {
  ok="$BATS_TEST_TMPDIR/claim-ok.md"
  bad="$BATS_TEST_TMPDIR/claim-bad.md"
  printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — 순수 검사(읽기 전용). 잘못 쓰면 아무 일도 없다." > "$ok"
  printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — 순수 검사. **${BT}make verify${BT}** 배선됨." > "$bad"
  # 양성 대조 — 주장이 없는 같은 모양의 bullet은 green이다(도메인 산문은 두 어휘를 쓰지 않는다).
  run bash "$GUARD" --readme "$ok"
  [ "$status" -eq 0 ]
  run bash "$GUARD" --readme "$bad"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "계산 가능한 실행 경로 주장"
}

# ── 뮤테이션 ③ 옛 판정을 빠져나갔던 base README 자신의 표기 ───────────────────────────────────
# 리뷰 실측: 옛 판정(서술어 리터럴 6개)에서는 이 문장들을 **되돌려도 초록**이었다 — 저자가 손으로
# 지운 문장을 가드는 보지 못했다. VENUE 어휘가 그 자리를 문다(주장은 venue를 지목해야 성립한다).
@test "notations that escaped the old predicate list now go red" {
  ok="$BATS_TEST_TMPDIR/esc-ok.md"
  printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — 순수 검사(읽기 전용)." > "$ok"
  run bash "$GUARD" --readme "$ok"
  [ "$status" -eq 0 ]
  bad=""
  # base README:29 · :97 · :103의 실제 문장에서 뽑은 표기. 어느 것도 옛 서술어 6종을 쓰지 않는다.
  for s in "${BT}make ci${BT}·${BT}ci.yaml${BT}(gate)이 공통 호출" \
           "${BT}tests/gates/test_floor-vocab.bats${BT}가 게이트" \
           "${BT}tests/gates/test_image_pins.bats${BT}가 픽스처+실-레포로 가드"; do
    f="$BATS_TEST_TMPDIR/esc.md"
    printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — 순수 검사. ${s}." > "$f"
    run bash "$GUARD" --readme "$f"
    [ "$status" -eq 1 ] || bad="${bad} [${s}]"
  done
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}

# 두 어휘의 리터럴이 **전부** 판정에 참여하는지 — 테스트 이름은 인터페이스가 아니다. 픽스처가 밟지
# 않는 리터럴은 사라져도 무증인이다(라이브 양성 대조는 어휘 단위까지만 증인이다).
@test "every literal in both vocabularies is load-bearing" {
  bad=""
  for p in "make " "ci.yaml" "bun run " "tests/gates/test_" "tests/test_" \
           "가 호출" "이 호출" "호출 아님" "가 부른" "이 부른" \
           "배선됨" "배선 아님" "배선 없" "배선되어" \
           "진입점" "실행자" "밟는" "직접 실행" \
           "가 게이트" "이 게이트" "가 가드" "이 가드" "중계" "source한"; do
    f="$BATS_TEST_TMPDIR/pred.md"
    printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — 어쩌고 ${p} 저쩌고." > "$f"
    run bash "$GUARD" --readme "$f"
    [ "$status" -eq 1 ] || bad="${bad} [${p}]"
  done
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}

@test "a claim in prose outside any bullet goes red (the header is not an exit)" {
  f="$BATS_TEST_TMPDIR/prose.md"
  printf '%s\n' '# t' '' "헤더 산문에 **${BT}make verify${BT}**가 호출한다고 적어 둔다." '' '## X' '' \
    "- **${BT}check-a.sh${BT}** — 순수 검사." > "$f"
  run bash "$GUARD" --readme "$f"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "bullet 밖 산문"
  # 산문 레인은 두 어휘 전건이다 — venue 이름 없는 관계 주장도 같은 자리에서 죽는다.
  g="$BATS_TEST_TMPDIR/prose-rel.md"
  printf '%s\n' '# t' '' '이 셋은 Makefile에 배선 없음이라 직접 부른다.' '' '## X' '' \
    "- **${BT}check-a.sh${BT}** — 순수 검사." > "$g"
  run bash "$GUARD" --readme "$g"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "bullet 밖 산문"
}

# ── 스코프 경계: 비-가드 bullet은 스코프 밖이자 **상시 양성 대조**다 ──────────────────────────
# 권위 계산의 도메인은 `guards` 스코프뿐이다. bootstrap.sh 류의 실행 경로는 계산하는 것이 레포에
# 없으므로 README가 SSOT이고, 지우면 정보 손실이 0이 아니다(리뷰 실측). 같은 문장이 가드 bullet에선
# red, 비-가드 bullet에선 green — 그 비대칭이 스코프의 증인이다.
@test "the same claim is red on a guard bullet and green on a non-guard one" {
  g="$BATS_TEST_TMPDIR/scope-guard.md"
  n="$BATS_TEST_TMPDIR/scope-nonguard.md"
  printf '%s\n' '# t' '' '## X' '' "- **${BT}check-a.sh${BT}** — **${BT}make verify${BT}**가 호출." > "$g"
  printf '%s\n' '# t' '' '## X' '' "- **${BT}bootstrap.sh${BT}** — **${BT}make bootstrap${BT}**이 호출." > "$n"
  run bash "$GUARD" --readme "$g"
  [ "$status" -eq 1 ]
  run bash "$GUARD" --readme "$n"
  [ "$status" -eq 0 ]
}

@test "the live README carries enough non-guard witnesses for both vocabularies" {
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  v="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-doc-index:witness-venue: //p')"
  r="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-doc-index:witness-rel: //p')"
  [ -n "$v" ]
  [ -n "$r" ]
  [ "$v" -ge 5 ]
  [ "$r" -ge 8 ]
  # 어휘가 통째로 깨지면 이 두 수가 0으로 무너진다 — 검출기 사망을 무는 라이브 대조가 여기다.
  # 실 README에서 비-가드 문장을 전부 지우면 대조군이 사라진다는 것도 같은 등식이 잡는다.
}

# ── 면제 레지스트리 ───────────────────────────────────────────────────────────────────────────
# 상한이 0이므로 면제는 **한 건도** 통과하지 않는다(스코프를 좁히면서 옛 면제 3건이 전부 비-가드로
# 판명됐다). 기계 자체는 살아 있어야 한다 — 면제된 bullet은 "주장" 위반을 내지 않고 **상한**에서
# 죽는다. 그 구별이 없으면 "상한 0 = 면제 코드 삭제"와 구별되지 않는다.
@test "an exemption is caught by the cap, not by the claim lane (the mechanism is still alive)" {
  f="$BATS_TEST_TMPDIR/ex1.md"
  printf '%s\n' '# t' '' '## X' '' \
    "- **${BT}check-x.sh${BT}** — [계산-밖] **${BT}make verify${BT}**가 호출. 왜 계산이 못 보는가: venue 밖이다." > "$f"
  run bash "$GUARD" --readme "$f"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "면제 1건 > 상한 0"
  # 중간 부정(`! `)은 bash 3.2에서 침묵 통과한다 — 카운트를 변수로 받아 `[ ]`로 잰다(AGENTS.md).
  claims="$(printf '%s\n' "$output" | grep -c "계산 가능한 실행 경로 주장" || true)"
  [ "$claims" -eq 0 ]
}

@test "an exemption without a reason, and a dead exemption, both go red" {
  noreason="$BATS_TEST_TMPDIR/noreason.md"
  dead="$BATS_TEST_TMPDIR/dead.md"
  printf '%s\n' '# t' '' '## X' '' \
    "- **${BT}check-a.sh${BT}** — [계산-밖] **${BT}make verify${BT}**가 호출." > "$noreason"
  printf '%s\n' '# t' '' '## X' '' \
    "- **${BT}check-a.sh${BT}** — [계산-밖] 왜 계산이 못 보는가: venue 밖이다. (주장은 적지 않았다)" > "$dead"
  run bash "$GUARD" --readme "$noreason"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "면제에 사유가 없다"
  run bash "$GUARD" --readme "$dead"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "죽은 면제"
}

@test "an exemption on a non-guard bullet is dead weight and goes red" {
  f="$BATS_TEST_TMPDIR/ex-nonguard.md"
  printf '%s\n' '# t' '' '## X' '' \
    "- **${BT}bootstrap.sh${BT}** — [계산-밖] **${BT}make bootstrap${BT}**이 호출. 왜 계산이 못 보는가: venue 밖이다." > "$f"
  run bash "$GUARD" --readme "$f"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "면제가 필요 없다"
}

@test "unknown arguments exit 2 (no operand off-switch for the scope lane)" {
  run bash "$GUARD" --bogus
  [ "$status" -eq 2 ]
  run bash "$GUARD" --readme
  [ "$status" -eq 2 ]
  run bash "$GUARD" "$README"
  [ "$status" -eq 2 ]
}
