#!/usr/bin/env bats
# GH Actions secret ↔ 분류 정책 전단사 가드의 **변별력** 테스트.
# 검출기가 조용히 죽어도 "전단사 성립 OK"는 그대로 나온다 — 그 초록이 거짓말이 되지 않게 픽스처로
# 양성·음성 대조를 매 실행 건다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

# ⚠️ **피연산자 실재 증인.** `run bash "$S"`는 가드가 없으면 rc **127**로 죽고, `_fixture`의 조립
#    (git archive + 두 `cp`)은 커맨드 치환 안이라 실패가 삼켜진다(bats는 `inherit_errexit` off).
#    실측(2026-09-02, 격리 트리 — 가드 삭제 · 원장 리네임 · `.git` 부재 세 뮤테이션): 이 파일은
#    12건 중 11건이 red라 **현재는** 공허한 거부 레인이 없다(살아남은 #6은 가드를 아예 부르지 않는
#    jq 핀이다). 그래도 형제 자리와 같은 두 줄을 세운다 — 조립이 조용히 반쯤 성공하는 날 이 레인들이
#    "거부했다"를 다른 이유로 만족하는 것이 이 클래스의 도달 경로다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-gh-secret-coverage.sh"
  [ -f "$S" ]
  CLASS="$ROOT/policy/gh-secret-var-classification.json"
  [ -f "$CLASS" ]
}

# 실 트리를 복사해 픽스처 루트를 만든다 — 열거 규칙이 실제 워크플로 모양에 붙어 있어서
# 합성 트리로는 재현이 안 된다(그리고 합성으로 하면 규칙 ③④가 무측정이 된다).
_fixture() {
  d="$BATS_TEST_TMPDIR/fx"
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$ROOT" && git archive HEAD ) | tar -x -C "$d"
  cp "$ROOT/policy/gh-secret-var-classification.json" "$d/policy/" 2>/dev/null || true
  cp "$ROOT/policy/credential-expiry.json" "$d/policy/"
  ( cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fx >/dev/null )
  # 픽스처 무결성 — 아카이브 추출과 `cp`의 실패는 커맨드 치환이 삼킨다(치환의 rc는 마지막 `echo`의
  # 0이다). `echo` **앞에서** 판정해야 호출부 `d="$(_fixture)"`의 rc가 bats errexit에 닿는다.
  [ -f "$d/.github/workflows/ci.yaml" ] || return 1
  [ -f "$d/policy/credential-expiry.json" ] || return 1
  echo "$d"
}

@test "the real repository satisfies the bijection" {
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:workflows: [0-9]+$'
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:secrets: [0-9]+$'
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:vars: [0-9]+$'
  echo "$output" | grep -q 'ENUM'
}

@test "an undeclared secret reference fails closed" {
  d="$(_fixture)"
  # ci.yaml에 새 secret 참조를 심는다(표현식 컨텍스트 — 규칙 ①을 통과해야 열거된다).
  printf '\n# probe\nname-probe: "${{ secrets.NEW_LEAKY_TOKEN }}"\n' >> "$d/.github/workflows/ci.yaml"
  ( cd "$d" && git add -A >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'NEW_LEAKY_TOKEN'
  echo "$output" | grep -q '기본값은 없다'
}

@test "index notation for secrets or vars is rejected (the enumerator only counts dot notation)" {
  # 규칙 ⑤ — `secrets['X']`는 열거자에도 residue 자기검사에도 안 잡힌다(둘 다 점 표기 정규식).
  # 열거를 넓히는 대신 표기를 거부하는 것이 처방이므로, 그 거부가 사라지면 이 레인이 red다.
  d="$(_fixture)"
  printf '\n# probe\nbrk-probe: "${{ secrets[%s] }}"\n' "'R2_UNCLASSIFIED_KEY'" >> "$d/.github/workflows/ci.yaml"
  ( cd "$d" && git add -A >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '인덱스 표기'
  # 대괄호는 ENUM을 늘리지 않는다(점 표기였다면 secrets 18) — 미분류 대조가 아니라 **표기 거부**가
  # red의 이유임을 SCAN 등식으로 고정한다.
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:secrets: 17$'
}

@test "index notation on the vars lane is rejected by the same predicate" {
  # vars 레인엔 residue 자기검사가 아예 없다 — 같은 한 grep이 두 레인을 덮는지 고정한다.
  d="$(_fixture)"
  printf '\n# probe\nbrk-probe: "${{ vars[%s] }}"\n' "'HOMELAB_OWNER'" >> "$d/.github/workflows/ci.yaml"
  ( cd "$d" && git add -A >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '인덱스 표기'
}

@test "a stale declaration fails closed (reverse direction)" {
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-var-classification.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
d["secrets"].append({"name": "GONE_FROM_WORKFLOWS", "class": "identifier",
                     "why": "픽스처 — 워크플로 어디에서도 참조되지 않는 죽은 선언이다", "since": "2026-08-20"})
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'GONE_FROM_WORKFLOWS'
  echo "$output" | grep -q 'stale'
}

@test "a reason shorter than the floor is rejected (no unreasoned exemption)" {
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-var-classification.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for e in d["secrets"]:
    if e["name"] == "TELEGRAM_CHAT_ID": e["why"] = "식별자"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  run bash "$S" --root "$d"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '형식 위반'
}

@test "class=ledger without a matching ledger row fails closed" {
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-var-classification.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for e in d["secrets"]:
    if e["name"] == "R2_ACCESS_KEY_ID": e["ledger_name"] = "does-not-exist-in-ledger"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'class=ledger인데 원장에 행이 없다'
}

@test "a truncated ledger_name that is only a prefix of a real slug fails closed too" {
  # ⚠️ 형제 레인(`does-not-exist-in-ledger`)은 실 슬러그와 접두를 전혀 공유하지 않아 대조의
  #    **느슨함**을 밟지 않는다. 종전 구현은 앵커 없는 접두 정규식(`grep -q "^${ln}"`)이라
  #    `r2`·`g`·`g.*` 같은 잘린 값이 전부 통과했다(실측) — 분류는 ledger인데 어떤 원장 행도
  #    그 자격을 지지하지 않는 상태가 조용히 초록이었다. 여기가 그 축의 유일한 증인이다.
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-var-classification.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for e in d["secrets"]:
    if e["name"] == "R2_ACCESS_KEY_ID": e["ledger_name"] = "r2"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ledger_name='r2'"
}

@test "the provided class is pinned to exactly GITHUB_TOKEN (widening it is an exemption hole)" {
  # 🔴 **실측된 fail-open**: `provided`는 열거에서 빠지므로, 자격을 그 갈래로 옮기면 대조 집합에서도
  #    함께 빠져 **전단사가 그대로 성립한 채 조용히 면제**된다(2026-08-20 실측: TELEGRAM_BOT_TOKEN을
  #    provided로 바꾸니 ENUM 17→16, 분류 17→16, rc=0). 스크립트는 SSOT를 하나로 두려고 정책에서
  #    파생하는데, 그 파생이 곧 넓히기 경로다.
  # ⇒ **값 자체는 여기서 못박는다.** 동작(파생)과 값(고정)의 분리가 이 가드의 계약이다.
  got="$(jq -r '[.secrets[] | select(.class=="provided") | .name] | sort | join(",")' "$CLASS")"
  [ "$got" = "GITHUB_TOKEN" ] \
    || { echo "provided 갈래가 'GITHUB_TOKEN' 하나가 아니다: '$got' — 넓히려면 그것이 정말 GitHub이 run별로 발급하는 것인지 근거를 대고 이 단언을 함께 고쳐라"; false; }
}

@test "moving a real credential into the provided class is caught by the pin" {
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-var-classification.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for e in d["secrets"]:
    if e["name"] == "TELEGRAM_BOT_TOKEN": e["class"] = "provided"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY2
  # 가드 자신은 통과한다(그게 이 구멍의 성질이다) — 잡는 것은 위 핀이다.
  run bash "$S" --root "$d"
  [ "$status" -eq 0 ]
  got="$(jq -r '[.secrets[] | select(.class=="provided") | .name] | sort | join(",")' "$d/policy/gh-secret-var-classification.json")"
  [ "$got" != "GITHUB_TOKEN" ]
}

@test "the policy file is a mandatory read (absence is never zero entries)" {
  d="$(_fixture)"
  rm -f "$d/policy/gh-secret-var-classification.json"
  run bash "$S" --root "$d"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '분류 정책 없음'
}

@test "the enumeration floor engages when the domain collapses" {
  # 붕괴는 검증 실패(1)다 — 2는 사용법 전용(CONTRIBUTING 종료코드 규약, exit 2 잔존을 1로 수렴).
  run bash "$S" --floor secrets=99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '열거 붕괴'
}

@test "lowercase filename and prose matches are not counted as secrets" {
  # `<app>-secrets.sealed.yaml` · 산문 `secrets.tf` 등 — 표현식 컨텍스트가 아니면 secret이 아니다.
  # 실 트리가 이미 그런 문자열을 담고 있으므로, 통과하는 것 자체가 규칙 ①의 양성 증거다.
  run bash "$S"
  [ "$status" -eq 0 ]
  # 소문자 토큰이 분류 정책에 새어 들어오지 않았는지 — 들어왔다면 규칙 ①이 깨진 것이다.
  # 양성 대조 — 정책에 대문자 name이 실재한다. 이게 없으면 $CLASS가 비거나 스키마가 바뀌어
  # "name" 키가 통째로 사라져도 아래 부정 단언이 공허하게 초록이다.
  run grep -cE '"name": "[A-Z]' "$CLASS"
  [ "$status" -eq 0 ]
  [ "$output" -ge 10 ]
  # rc 2(대상 부재)를 통과로 읽지 않는다 — 무매치는 정확히 rc 1이다.
  run grep -E '"name": "[a-z]' "$CLASS"
  [ "$status" -eq 1 ]
}

@test "the retired GH_SECRET env floors are inert (kernel-followups 02)" {
  # env 재유입 회귀 증인 — 폐지 env가 되살아나면 99999가 바닥값이 되어 rc가 갈린다.
  run env GH_SECRET_MIN_SECRETS=99999 GH_SECRET_MIN_WORKFLOWS=99999 bash "$S"
  [ "$status" -eq 0 ]
}

@test "a later-domain collapse withholds EVERY domain marker (batch emission)" {
  # 종전엔 :workflows 마커가 먼저 나가서, :secrets가 붕괴한 실행이 "워크플로 N건 검사했다"를
  # 그대로 냈다. 붕괴한 실행의 어떤 건수도 "검사했다"로 읽히면 안 된다(TS guardMain과 동형).
  run bash "$ROOT/scripts/check-gh-secret-coverage.sh" --floor check-gh-secret-coverage:secrets=9999
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "check-gh-secret-coverage:secrets.*열거 붕괴"
  out="$output"
  run grep -q "^SCAN: check-gh-secret-coverage:" <<<"$out"
  [ "$status" -ne 0 ]
}

# ── vars 도메인(repo Actions variable) ──────────────────────────────────────
# `vars.X`는 자격이 아니라 공개 설정값이지만, `HOMELAB_OWNER`는 15사본 actor 가드의 유일한
# 신뢰 앵커이고 terraform 밖이라(github_actions_variable 0건 → drift-github `-target` 밖)
# tracked 원장이 이 파일뿐이다. 그 원장이 워크플로 참조와 **양방향으로** 묶여 있는지 잰다.

@test "an undeclared workflow variable reference fails closed" {
  d="$(_fixture)"
  jq '.vars |= map(select(.name != "HOMELAB_OWNER"))' "$CLASS" > "$d/policy/gh-secret-var-classification.json"
  ( cd "$d" && git add -A && git -c user.email=t@t -c user.name=t commit -qm mut >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'vars에 분류가 없는 variable'
  echo "$output" | grep -q 'HOMELAB_OWNER'
}

@test "a declared variable that no workflow references is stale" {
  d="$(_fixture)"
  jq '.vars += [{name:"ZZZ_PROBE",class:"identifier",why:"뮤테이션 프로브 — 워크플로가 참조하지 않는 이름이다.",since:"2026-09-03"}]' \
    "$CLASS" > "$d/policy/gh-secret-var-classification.json"
  ( cd "$d" && git add -A && git -c user.email=t@t -c user.name=t commit -qm mut >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'variable(stale)'
  echo "$output" | grep -q 'ZZZ_PROBE'
}

@test "the ledger class is rejected inside the vars array" {
  # 만료 원장의 도메인은 자격이다 — 공개 설정값에 ledger 갈래를 허용하면 원장 대조가 무의미해진다.
  d="$(_fixture)"
  jq '.vars[0].class = "ledger"' "$CLASS" > "$d/policy/gh-secret-var-classification.json"
  ( cd "$d" && git add -A && git -c user.email=t@t -c user.name=t commit -qm mut >/dev/null )
  run bash "$S" --root "$d"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'vars 형식 위반'
}
