#!/usr/bin/env bash
# GH Actions secret ↔ 자격 원장 전단사 가드 — "워크플로가 쓰는 자격 중 원장에 없는 것"을 fail-closed로 잡는다.
#
# 병(라이브 2026-08-18~20): R2 terraform-state 자격이 유출→회전됐는데, 그 자격은 두 달간
# policy/credential-expiry.json에 **없었다**. 부재를 잡는 가드가 0건이었다 — check-credential-expiry.sh는
# 스키마와 항목 수 바닥값만 본다(원장 안을 볼 뿐, 원장 **밖**을 보지 않는다).
#
# 이 가드는 두 집합의 **전단사**를 강제한다:
#   ENUM  = 워크플로가 실제로 참조하는 homelab 소유 secret 이름
#   DECL  = policy/gh-secret-var-classification.json이 분류한 이름(4갈래 중 정확히 하나)
# ENUM \ DECL = 미분류 secret(추가하고 어디에도 안 적음) · DECL \ ENUM = stale 선언(워크플로에서 사라짐).
# 양방향이라 "선언만 하고 안 쓰는" 죽은 행도 잡힌다.
#
# ★ **분류가 원장 등재와 같지 않다.** 런북 token-inventory.md가 §A(원장 등재)와 §B(인벤토리 전용,
#   **의도적 원장 비대상**)를 나눠 두었다 — TELEGRAM_BOT_TOKEN·App private key 3종은 owner가
#   2026-07-08에 §B로 분류한 것이라 원장에 넣으면 그 결정을 뒤집는 것이 된다. 그래서 이 가드는
#   "자격이면 원장에 있어야"가 아니라 "**어느 갈래인지 근거와 함께 선언돼 있어야**"를 강제하고,
#   `ledger` 갈래만 원장 행과 기계 대조한다. 런북은 gitignored라 게이트가 못 읽으므로 **분류만**
#   tracked 정책 파일로 끌어올렸다(owner 결정 2026-08-20) — 값도 절차도 없이 갈래와 사유뿐이다.
#   ⚠️ 원장 스키마는 **건드리지 않는다**. gh_secrets 같은 필수 필드를 더하면 기존 픽스처 3건이
#      rc=2로 죽고(실측) `expires` 형식 가드가 항진명제가 된다 — 그 대가를 치를 이유가 없다.
#
# ⚠️ **열거 규칙 4조 — 왜 단순 grep이 틀리는가**:
#  ① 표현식 컨텍스트(`${{ … secrets.X … }}`)만 센다. 파일명(`<app>-secrets.sealed.yaml`)·산문
#     (`secrets.tf`)이 걸려 lowercase 유령 4건이 잡혔다(실측: sealed/tf/ts/yaml).
#  ② `GITHUB_TOKEN`은 GitHub 제공·run별 임시라 회전 대상이 아니다 — 제외(하드코딩 1건, 아래 자기검사 있음).
#  ③ **reusable의 `on.workflow_call.secrets`는 입력 *선언*이지 이 레포의 secret이 아니다.**
#     실측: reusable-app-build.yaml의 HOMELAB_DISPATCH_APP_ID/_PRIVATE_KEY는 **앱 레포**가 넘기고
#     homelab secret 목록엔 0건이다. 구별 못 하면 갖지도 않은 자격에 원장 행을 요구하는 거짓 red가 난다.
#  ④ **호출자 컨텍스트가 소유자를 정한다.** called 워크플로의 `secrets.X`는 *caller* 레포에서 해소된다.
#     · 로컬 호출(`uses: ./.github/workflows/_*.yaml` + `secrets: inherit`) → caller=homelab → 소유.
#     · 외부 호출(reusable-*.yaml, 로컬 호출 0건)              → caller=앱 레포   → 도메인 밖(파일 통째).
#     두 신호(로컬 호출 여부 ↔ `_*`/`reusable-*` 네이밍 규약)가 **어긋나면 fail-loud** — 조용한 오분류 대신.
#
# ⚠️ composite action(.github/actions/*)은 도메인 밖이다 — composite에는 secrets 컨텍스트가 **없고**
#    호출 워크플로가 `with:`로 넘긴 입력을 env로 받는다(telegram-notify가 bot-token 입력을 받는 구조).
#    그 action.yml의 `secrets.TELEGRAM_BOT_TOKEN`은 **설명 문자열**이고 ①이 이미 걸러낸다.
#    실측: `.github/actions/**`에 표현식 컨텍스트 `secrets.` 참조 0건.
# ⚠️ `vars.X`는 **자격이 아니다**(공개 설정값 — 유출·회전 축이 없다). 그래서 `secrets`와 **같은 배열에 넣지 않는다** —
#    섞이면 ledger 갈래와 뒤엉키고 원장 대조가 무의미해진다. 다만 **tracked 원장이 필요한 것은 같다**:
#    `vars.HOMELAB_OWNER`는 15사본 actor 가드의 유일한 신뢰 앵커인데 `github_actions_variable` 리소스가
#    0건이라 drift-github의 `-target` 목록에 원리적으로 못 들어간다(감시 범위 밖 — workflow-readiness가
#    그 갭을 선언한다). ⇒ 별도 배열 `vars`로 **이름·갈래·근거만** 두고 워크플로 참조와 양방향 대조한다.
#    ⚠️ `vars`에는 `ledger` 갈래를 허용하지 않는다 — 만료 원장의 도메인은 자격이지 설정값이 아니다.
#
# 종료코드: 0=전단사 성립 · 1=위반(미등재/stale/이중분류)·열거 붕괴(fail-loud) · 2=사용법·정책파일 부재/형식.
# bash 3.2 호환(mapfile·[[ ]] 금지). shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT 기본값·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-gh-secret-coverage
SCOPE_NARROWED=0
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 02 — 구 GH_SECRET_*
# env 폐지). 붕괴 종료코드도 1로 수렴한다(2는 사용법 전용 — check-image-pins 선례와 같은 근거).
take_floors "check-gh-secret-coverage:workflows check-gh-secret-coverage:secrets check-gh-secret-coverage:vars" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; SCOPE_NARROWED=1; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
LEDGER="policy/credential-expiry.json"
CLASS="policy/gh-secret-var-classification.json"


command -v jq >/dev/null 2>&1 || { echo "ERROR: jq 필요" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq 필요" >&2; exit 2; }
# 정책 파일은 **필수 읽기**(부재=FAIL). 없으면 "검사할 게 없다"가 아니라 전제 붕괴다.
[ -f "$LEDGER" ] || { echo "ERROR: 원장 없음: $ROOT/$LEDGER" >&2; exit 2; }
[ -f "$CLASS" ]  || { echo "ERROR: 분류 정책 없음: $ROOT/$CLASS" >&2; exit 2; }

# GitHub 제공(run별 임시 토큰) — 인벤토리/회전 대상이 아니다.
# ⚠️ 이 집합을 **하드코딩하지 않는다** — 정책 파일의 `class:"provided"`에서 파생한다. 하드코딩하면
#    같은 사실의 SSOT가 둘이 되고, 스크립트 쪽만 늘려서 조용히 면제를 넓히는 경로가 생긴다.
#    (정책 파일 쪽은 why 20자+ 강제라 근거 없이 못 늘린다.)
PROVIDED="$(jq -r '.secrets[] | select(.class=="provided") | .name' "$CLASS" | LC_ALL=C sort -u)"
[ -n "$PROVIDED" ] || { echo "ERROR: ${CLASS}에 class=provided 항목이 0건 — GITHUB_TOKEN 제외가 사라졌다(열거 붕괴)" >&2; exit 2; }

# ── 열거 ────────────────────────────────────────────────────────────────────
files="$(git ls-files '.github/workflows/*.yaml' || true)"
nfiles="$(scan_count "$files")"
# 픽스처(--root)엔 기본 바닥값을 적용하지 않는다 — 단 --floor를 **명시하면** 적용한다(floor_set,
# check-image-pins 선례). 아니면 명시 플래그가 조용한 no-op이 된다(조용히 꺼진 바닥값과 같은 관측).
# 판정만 한다(quiet) — 마커는 **전 도메인 판정 뒤** 아래에서 일괄 방출한다. 뒤 도메인이 붕괴한
# 실행이 앞 도메인의 "N건 검사했다"를 내면 소비자가 정반대로 읽는다(TS guardMain과 동형).
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-gh-secret-coverage:workflows; then
  scan_floor check-gh-secret-coverage:workflows "$nfiles" "$(floor_of check-gh-secret-coverage:workflows 18)" quiet || exit 1
fi

# 로컬 호출되는 reusable 집합 — 네이밍이 아니라 **실제 호출**에서 파생한다.
local_called="$(printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] && grep -ohE 'uses:[[:space:]]*\./\.github/workflows/[A-Za-z0-9._-]+\.yaml' "$f" || true
done | sed 's|.*/||' | LC_ALL=C sort -u)"

owned=""; bad=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  b="$(basename "$f")"
  refs="$(grep -ohE '\$\{\{[^}]*\bsecrets\.[A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/.*secrets\.//' | LC_ALL=C sort -u || true)"
  # 열거자 자기검사: 표현식 컨텍스트로 잡히지 않은 **대문자** secrets.X 잔여물 = 정규식이 놓친 형태.
  allrefs="$(grep -ohE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/secrets\.//' | LC_ALL=C sort -u || true)"
  residue="$(comm -23 <(printf '%s\n' "$allrefs" | grep -v '^$' || true) \
                      <(printf '%s\n' "$refs" | grep -v '^$' || true) | grep -E '^[A-Z][A-Z0-9_]*$' || true)"
  [ -z "$residue" ] || bad="${bad}FAIL: ${f}: 표현식 밖 대문자 secrets 참조(열거자가 놓친 형태): $(printf '%s' "$residue" | tr '\n' ' ')
"
  decl="$(yq -r '.on.workflow_call.secrets // {} | keys | .[]' "$f" 2>/dev/null | LC_ALL=C sort -u || true)"
  iscall="$(yq -r '.on | has("workflow_call")' "$f" 2>/dev/null || echo false)"
  islocal=0
  grep -qx "$b" <<<"$local_called" && islocal=1 || true
  if [ "$iscall" = "true" ] && [ "$islocal" -eq 0 ]; then
    # 외부 caller 컨텍스트 → 이 레포의 자격이 아니다. 두 신호가 어긋나면 fail-loud.
    case "$b" in reusable-*) ;; *) bad="${bad}FAIL: ${f}: 로컬 호출 0건인 workflow_call인데 이름이 reusable-*가 아니다(네이밍 규약 ↔ 실제 호출 불일치).
" ;; esac
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      grep -qx "$r" <<<"$PROVIDED" && continue
      grep -qx "$r" <<<"$decl" || bad="${bad}FAIL: ${f}: cross-repo reusable이 미선언 secret '${r}'을 참조한다(caller가 넘길 수 없는 죽은 참조).
"
    done <<EOT
$refs
EOT
    continue
  fi
  if [ "$iscall" = "true" ] && [ "$islocal" -eq 1 ]; then
    case "$b" in _*) ;; *) bad="${bad}FAIL: ${f}: 로컬 호출되는 workflow_call인데 이름이 _*가 아니다(네이밍 규약 ↔ 실제 호출 불일치).
" ;; esac
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qx "$r" <<<"$PROVIDED" && continue
    grep -qx "$r" <<<"$decl" && continue   # 자기 파일의 workflow_call 입력명 = 파라미터
    owned="${owned}${r}
"
  done <<EOT
$refs
EOT
done <<EOT
$files
EOT

enum="$(printf '%s' "$owned" | grep -v '^$' | LC_ALL=C sort -u || true)"

# ── vars 열거(별도 도메인) ──────────────────────────────────────────────────
# secret과 달리 workflow_call 입력 개념이 없다 — `vars.X`는 항상 레포/org variable로 해소된다.
# cross-repo reusable도 **caller가 아니라 자기 레포**의 variable을 읽으므로 파일을 가리지 않는다.
vars_enum="$(printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] && grep -ohE 'vars\.[A-Z][A-Z0-9_]*' "$f" || true
done | sed 's/^vars\.//' | LC_ALL=C sort -u || true)"
nvars="$(scan_count "$vars_enum")"
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-gh-secret-coverage:vars; then
  scan_floor check-gh-secret-coverage:vars "$nvars" "$(floor_of check-gh-secret-coverage:vars 2)" quiet || exit 1
fi
n="$(scan_count "$enum")"
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-gh-secret-coverage:secrets; then
  scan_floor check-gh-secret-coverage:secrets "$n" "$(floor_of check-gh-secret-coverage:secrets 12)" quiet || exit 1
fi

# ── 마커 일괄 방출 — 전 도메인이 바닥값을 통과한 뒤에만 나간다 ──
# 순서는 종전과 같다(workflows → secrets). 면제 모드에서도 신호는 낸다 — 신호가 아예 없으면
# "좁혀진 호출"과 "가드 미실행"을 구별할 수 없다.
scan_signal check-gh-secret-coverage:workflows "$nfiles"
scan_signal check-gh-secret-coverage:secrets "$n"
scan_signal check-gh-secret-coverage:vars "$nvars"

# ── 분류 읽기(스키마 강제 — 사유 없는 선언 금지) ────────────────────────────
[ -f "$CLASS" ] || { echo "ERROR: 분류 정책 부재: ${CLASS} — 부재를 '분류 0건'으로 위장시키지 않는다" >&2; exit 2; }
jq -e '(.vars|type=="array") and all(.vars[];
         (.name|type=="string" and test("^[A-Z][A-Z0-9_]*$"))
     and (.class|type=="string" and (. == "inventory-only" or . == "identifier"))
     and (.why|type=="string" and (length>=20))
     and (.since|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))' \
  "$CLASS" >/dev/null 2>&1 || {
  echo "ERROR: ${CLASS}의 vars 형식 위반 — 각 항목에 name·class(identifier|inventory-only)·why(20자+)·since 필수." >&2
  echo "       ⚠️ vars에는 class=ledger를 쓸 수 없다(만료 원장의 도메인은 자격이지 공개 설정값이 아니다)." >&2
  exit 2
}
jq -e '(.secrets|type=="array") and all(.secrets[];
         (.name|type=="string" and test("^[A-Z][A-Z0-9_]*$"))
     and (.class|type=="string" and (. == "ledger" or . == "inventory-only" or . == "identifier" or . == "provided"))
     and (.why|type=="string" and (length>=20))
     and (.since|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
     and (if .class == "ledger" then (.ledger_name|type=="string" and (length>0)) else true end))' \
  "$CLASS" >/dev/null 2>&1 || {
  echo "ERROR: ${CLASS} 형식 위반 — 각 항목에 name·class(ledger|inventory-only|identifier|provided)·why(20자+)·since 필수," >&2
  echo "       class=ledger면 ledger_name도 필수. 무근거 분류는 금지다(모드 A/D와 같은 규율)." >&2
  exit 2
}

# ⚠️ 비교 집합에서 `provided`를 뺀다 — ENUM이 그것들을 제외하므로(위 규칙 ②) 여기 남기면
#    영원히 stale로 잡힌다. 제외의 SSOT는 정책 파일 하나이고 양쪽이 그것을 함께 읽는다.
decl_all="$(jq -r '.secrets[] | select(.class!="provided") | .name' "$CLASS" | LC_ALL=C sort -u)"
# 중복 선언 — 같은 이름이 두 번 나오면 어느 갈래인지 모호해진다.
dupdecl="$(jq -r '.secrets[].name' "$CLASS" | LC_ALL=C sort | uniq -d || true)"

missing="$(comm -23 <(printf '%s\n' "$enum") <(printf '%s\n' "$decl_all") || true)"

vars_decl="$(jq -r '.vars[].name' "$CLASS" | LC_ALL=C sort -u)"
vars_dup="$(jq -r '.vars[].name' "$CLASS" | LC_ALL=C sort | uniq -d || true)"
vars_missing="$(comm -23 <(printf '%s\n' "$vars_enum") <(printf '%s\n' "$vars_decl") || true)"
vars_stale="$(comm -13 <(printf '%s\n' "$vars_enum") <(printf '%s\n' "$vars_decl") || true)"
stale="$(comm -13 <(printf '%s\n' "$enum") <(printf '%s\n' "$decl_all") || true)"

# `ledger` 갈래는 원장 행과 기계 대조한다 — 이 갈래만 원장이 SSOT다.
# ⚠️ 원장 name은 `<슬러그> (<괄호 설명>)` 형태라 슬러그를 **먼저 잘라** 고정문자열 전행 대조를 한다.
#    종전 구현은 `grep -q "^${ln}"` — 앵커 없는 **접두 정규식**이라 잘리거나 오타난 ledger_name이
#    조용히 통과했다(실측: `r2`·`g`·`g.*` 전부 MATCH). 그러면 분류는 `ledger`인데 어떤 원장 행도
#    그 자격을 지지하지 않는 상태가 되어 이 가드의 존재 이유가 그 자격에 대해 무효가 된다.
#    형제 가드 scripts/verify-credential-inventory.sh:48-50이 쓰는 슬러그 파생·대조 형태와 같다.
ledger_names="$(jq -r '.[] | ((.name // "") | tostring | split(" ")[0])' "$LEDGER" | LC_ALL=C sort -u)"
unbacked=""
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  ln="${pair#*=}"
  grep -Fqx -- "$ln" <<<"$ledger_names" \
    || unbacked="${unbacked}${pair%%=*} → ledger_name='${ln}'가 ${LEDGER}에 없다
"
done <<EOT
$(jq -r '.secrets[] | select(.class=="ledger") | "\(.name)=\(.ledger_name)"' "$CLASS")
EOT

nled="$(jq -r '[.secrets[] | select(.class=="ledger")] | length' "$CLASS")"
ninv="$(jq -r '[.secrets[] | select(.class=="inventory-only")] | length' "$CLASS")"
nide="$(jq -r '[.secrets[] | select(.class=="identifier")] | length' "$CLASS")"
npro="$(jq -r '[.secrets[] | select(.class=="provided")] | length' "$CLASS")"

rc=0
[ -z "$bad" ] || { printf '%s' "$bad" >&2; rc=1; }
if [ -n "$dupdecl" ]; then
  echo "FAIL: ${CLASS}에 같은 secret이 두 번 선언됐다(갈래 모호):" >&2; printf '%s\n' "$dupdecl" | sed 's/^/  /' >&2; rc=1
fi
if [ -n "$missing" ]; then
  echo "FAIL: 워크플로가 쓰는데 ${CLASS}에 분류가 없는 secret:" >&2; printf '%s\n' "$missing" | sed 's/^/  /' >&2
  echo "  → **기본값은 없다.** ledger(원장 등재) / inventory-only(런북 §B — 의도적 원장 비대상) /" >&2
  echo "     identifier(자격 아님) / provided(GitHub 발급) 중 하나를 **사유와 함께** 선언하라." >&2; rc=1
fi
if [ -n "$stale" ]; then
  echo "FAIL: 분류돼 있는데 워크플로 어디서도 안 쓰는 secret(stale):" >&2; printf '%s\n' "$stale" | sed 's/^/  /' >&2; rc=1
fi
if [ -n "$vars_dup" ]; then
  echo "FAIL: ${CLASS}의 vars에 같은 이름이 두 번 선언됐다(갈래 모호):" >&2; printf '%s\n' "$vars_dup" | sed 's/^/  /' >&2; rc=1
fi
if [ -n "$vars_missing" ]; then
  echo "FAIL: 워크플로가 쓰는데 ${CLASS}의 vars에 분류가 없는 variable:" >&2; printf '%s\n' "$vars_missing" | sed 's/^/  /' >&2
  echo "  → identifier(자격 아님) / inventory-only 중 하나를 **사유와 함께** 선언하라. 기본값은 없다." >&2; rc=1
fi
if [ -n "$vars_stale" ]; then
  echo "FAIL: vars에 분류돼 있는데 워크플로 어디서도 안 쓰는 variable(stale):" >&2; printf '%s\n' "$vars_stale" | sed 's/^/  /' >&2; rc=1
fi
if [ -n "$unbacked" ]; then
  echo "FAIL: class=ledger인데 원장에 행이 없다:" >&2; printf '%s' "$unbacked" | sed 's/^/  /' >&2; rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "check-gh-secret-coverage: ENUM ${n}건 == 분류 $(scan_count "$decl_all")건 (ledger ${nled} · inventory-only ${ninv} · identifier ${nide} · provided ${npro}) · vars ${nvars}건 == 분류 $(scan_count "$vars_decl")건 OK"
fi
exit "$rc"
