#!/usr/bin/env bats
# GH Actions secret ↔ 분류 정책 전단사 가드의 **변별력** 테스트.
# 검출기가 조용히 죽어도 "전단사 성립 OK"는 그대로 나온다 — 그 초록이 거짓말이 되지 않게 픽스처로
# 양성·음성 대조를 매 실행 건다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  S="$ROOT/scripts/check-gh-secret-coverage.sh"
  CLASS="$ROOT/policy/gh-secret-classification.json"
}

# 실 트리를 복사해 픽스처 루트를 만든다 — 열거 규칙이 실제 워크플로 모양에 붙어 있어서
# 합성 트리로는 재현이 안 된다(그리고 합성으로 하면 규칙 ③④가 무측정이 된다).
_fixture() {
  d="$BATS_TEST_TMPDIR/fx"
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$ROOT" && git archive HEAD ) | tar -x -C "$d"
  cp "$ROOT/policy/gh-secret-classification.json" "$d/policy/" 2>/dev/null || true
  cp "$ROOT/policy/credential-expiry.json" "$d/policy/"
  ( cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fx >/dev/null )
  echo "$d"
}

@test "the real repository satisfies the bijection" {
  run bash "$S"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:workflows: [0-9]+$'
  echo "$output" | grep -qE '^SCAN: check-gh-secret-coverage:secrets: [0-9]+$'
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

@test "a stale declaration fails closed (reverse direction)" {
  d="$(_fixture)"
  python3 - "$d/policy/gh-secret-classification.json" <<'PY'
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
  python3 - "$d/policy/gh-secret-classification.json" <<'PY'
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
  python3 - "$d/policy/gh-secret-classification.json" <<'PY'
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
  python3 - "$d/policy/gh-secret-classification.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for e in d["secrets"]:
    if e["name"] == "TELEGRAM_BOT_TOKEN": e["class"] = "provided"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY2
  # 가드 자신은 통과한다(그게 이 구멍의 성질이다) — 잡는 것은 위 핀이다.
  run bash "$S" --root "$d"
  [ "$status" -eq 0 ]
  got="$(jq -r '[.secrets[] | select(.class=="provided") | .name] | sort | join(",")' "$d/policy/gh-secret-classification.json")"
  [ "$got" != "GITHUB_TOKEN" ]
}

@test "the policy file is a mandatory read (absence is never zero entries)" {
  d="$(_fixture)"
  rm -f "$d/policy/gh-secret-classification.json"
  run bash "$S" --root "$d"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '분류 정책 없음'
}

@test "the enumeration floor engages when the domain collapses" {
  run env GH_SECRET_MIN_SECRETS=99999 bash "$S"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '열거 붕괴'
}

@test "lowercase filename and prose matches are not counted as secrets" {
  # `<app>-secrets.sealed.yaml` · 산문 `secrets.tf` 등 — 표현식 컨텍스트가 아니면 secret이 아니다.
  # 실 트리가 이미 그런 문자열을 담고 있으므로, 통과하는 것 자체가 규칙 ①의 양성 증거다.
  run bash "$S"
  [ "$status" -eq 0 ]
  # 소문자 토큰이 분류 정책에 새어 들어오지 않았는지 — 들어왔다면 규칙 ①이 깨진 것이다.
  run grep -E '"name": "[a-z]' "$CLASS"
  [ "$status" -ne 0 ]
}
