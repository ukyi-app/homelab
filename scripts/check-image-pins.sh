#!/usr/bin/env bash
# 이미지 digest 핀 2-레인 게이트(메타갭 ② W2-B) — 런타임 컨테이너 이미지가 @sha256 digest로 고정됐는지 강제.
# mutable 태그는 재빌드 때마다 움직여 의도치 않은 이미지로 실행될 수 있다(핀 = 재현성·공급망 무결성).
#
#   레인1(platform 문자열 이미지): platform/**/*.yaml의 `image:`/`imageName:` 스칼라 값이 `@sha256:` 포함해야.
#     (imageName: = CNPG Cluster CR의 DB 본체 런타임 이미지 — image:와 동일 취급, 적대 리뷰 확인.)
#   레인2(apps 구조체 이미지): apps/*/deploy/prod/values.yaml의 image 블록이 `digest: sha256:`(블록 스코프) 보유,
#     또는 인라인 문자열 image가 @sha256 핀.
#
# 스코프 한계(성공 메시지도 이 경계를 반영): (a) substrate(infra/k3s-bootstrap/** — versions.env + renovate
#   custom manager 관할, LOCAL_PATH_PROVISIONER digest 핀은 Task 9 후속), (b) helmrelease 차트-내부 기본
#   이미지(traefik/sealed-secrets/tailscale/cnpg-operator 등 — 레포에 image: 스칼라로 없음).
#   ⚠️ **"Renovate pinDigests 관할"이라고 적혀 있었는데 그건 절반만 참이었다.** 차트 tarball은
#   platform/*/prod/charts/에 캐시되고 그 경로는 gitignored이며 renovate.json ignorePaths의
#   `**/charts/**`에도 걸린다 — Renovate는 **없는 파일을 핀할 수 없다**. 차트 **버전**은 Renovate가
#   소유하지만(helmrelease/CHART_VERSION/argocd manager) 내부 이미지는 렌더 시점 mutable tag라
#   **digest 소유자가 없다**. 그 구분과 각 차트의 근거는 policy/image-ownership.json 원장에 있고
#   tools/check-image-ownership.ts가 선언을 강제한다(미선언 = red).
# 열거·제외는 **공유 워커의 스코프**가 소유한다(tools/lib/repo-walk.ts) — 이 파일에 제외 어휘의 사본이
#   없다. 레인1=`platform-image-refs`(추적된 차트 소스 **포함**), 레인2=`apps-values`.
#   제외 내역(벤더 barman-plugin/·gateway-api CRD, 테스트/픽스처 tests?/·fixtures*/)과 그 글롭이
#   라이브 실측으로 확정된 경위는 스코프 정의의 주석이 SSOT다.
# 예외: policy/image-pin-allowlist.txt(라인당 이미지 값 또는 app:<name>, # 사유 주석 **강제** — 인라인 또는 직전 줄).
#   수용 기준 = allowlist 0(핀 후).
#
# make verify 배선됨(Task 9, 핀 적용 후) — 기본 --min-scan 20(scan-floor 유효, 배선부에 넘기지 않는다).
#   24 tag-only 이미지를 수동 digest 핀(renovate pin-dependencies 배치가 Issues:write gap으로 엉켜 결정적 경로 선택)
#   완료 후 실 레포는 allowlist 0으로 통과한다. 신규 미핀 이미지는 이 게이트가 fail-closed로 차단.
# bash 3.2 호환: [[ ]]·mapfile 금지(중간 단언 [ ]/grep). --root로 픽스처 tmp git 레포 지정 가능.
set -euo pipefail

# ⚠️ MIN_SCAN_APPS 바닥값 0 — 인-레포 배포 앱이 **0개**다(page #455 · trip-mate-api 이 PR로 철거).
#    앱이 0개인 동안은 레인2 열거 0건이 정당해 붕괴와 구별되지 않는다. 앱 온보딩 시 1로 되돌릴 것.
ROOT=""; ALLOWLIST=""; MIN_SCAN=20; MIN_SCAN_APPS=0; ROOT_OVERRIDDEN=0; MIN_SCAN_APPS_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; ROOT_OVERRIDDEN=1; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    --min-scan) MIN_SCAN="$2"; shift 2 ;;   # scan-floor(글롭/제외 파손 감지). 픽스처만 낮춰 호출.
    --min-scan-apps) MIN_SCAN_APPS="$2"; MIN_SCAN_APPS_SET=1; shift 2 ;;   # 레인2 전용 바닥값(아래 참조)
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# shellcheck source=scripts/lib/scan-floor.sh
. "$(dirname "$0")/lib/scan-floor.sh"
if [ -z "$ROOT" ]; then ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
[ -z "$ALLOWLIST" ] && ALLOWLIST="$ROOT/policy/image-pin-allowlist.txt"

# 앵커된 이미지 키 정규식 — `logo_image:`·경로 내 `my-image:` 부분매치 방지(리스트 아이템 `- ` 허용).
IMG_KEY='^[[:space:]]*(-[[:space:]]+)?(image|imageName):[[:space:]]*'

# 열거는 공유 워커(tools/lib/repo-walk.ts)가 소유한다 — tracked 열거·제외 어휘·열거 붕괴 바닥값이
# 전부 스코프 정의 안에 있다. 여기서 추가 제외를 하지 않으므로 제외 어휘의 사본이 존재하지 않는다.
# 레인1은 `platform-image-refs`(추적된 **차트 소스 포함** — 공유 차트 values.yaml에 리터럴 이미지가
# 생기면 잡아야 한다. cf. `platform-manifests`는 렌더 전 템플릿이 YAML 파싱 불가라 차트를 뺀다).
# 값 추출(grep/sed/awk)은 셸이 그대로 소유한다 — CONTRIBUTING이 라인 지향 필터를 셸 영역으로 규정.
walk_scope() { bun "$(dirname "$0")/../tools/lib/repo-walk.ts" --manifests "$1" --root "$ROOT"; }

# --- allowlist: 사유 주석 강제(config lint) + 멤버십 ---
# 각 비주석·비공백 엔트리는 인라인 `# 사유` 또는 직전 줄 `#` 주석을 가져야 한다.
lint_allowlist() {
  [ -f "$ALLOWLIST" ] || return 0
  prev_comment=0; n=0; bad=0
  while IFS= read -r ln || [ -n "$ln" ]; do
    n=$((n + 1))
    case "$ln" in
      '#'*) prev_comment=1; continue ;;
      ''|' '*'') : ;;
    esac
    # 공백-only?
    if printf '%s' "$ln" | grep -qE '^[[:space:]]*$'; then prev_comment=0; continue; fi
    # 엔트리 라인 — 인라인 주석 or 직전 주석 필요
    if printf '%s' "$ln" | grep -q '#'; then :
    elif [ "$prev_comment" -eq 1 ]; then :
    else echo "ERROR: allowlist:${n} '${ln}' — 사유 주석(# ...) 필요(인라인 또는 직전 줄)" >&2; bad=1; fi
    prev_comment=0
  done < "$ALLOWLIST"
  [ "$bad" -eq 0 ]
}
allow_has() {  # 인라인 주석·공백 스트립 후 정확 일치
  [ -f "$ALLOWLIST" ] || return 1
  grep -v '^[[:space:]]*#' "$ALLOWLIST" 2>/dev/null \
    | sed -E 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | grep -qxF "$1"
}

# 파일에서 앵커된 문자열 이미지 값 추출(따옴표·주석·경로/템플릿 제외). 각 값 한 줄(개행 유지).
# grep의 개행 종료 출력을 단일 sed로 변환 — printf '%s'(개행 없음)+BSD sed는 종료 개행이 없어
# 상위 `while read`가 EOF-without-newline으로 본문을 건너뛴다(검증된 함정).
extract_string_images() {
  grep -hE "${IMG_KEY}[\"']?[a-z0-9]" "$1" 2>/dev/null \
    | sed -E "s#${IMG_KEY}##; s/[[:space:]]*#.*//; s/^[\"']//; s/[\"']\$//; s/[[:space:]]*\$//"
}

# apps values의 value-less `image:` 블록에 digest: sha256: 가 있는지(블록 스코프 — 파일 전역 아님).
image_block_has_digest() {
  awk '
    /^[[:space:]]*image:[[:space:]]*$/ { s=$0; sub(/[^ ].*/,"",s); ind=length(s); blk=1; next }
    blk==1 {
      if ($0 ~ /^[[:space:]]*$/) next
      c=$0; sub(/[^ ].*/,"",c); cur=length(c)
      if (cur <= ind) { blk=0; next }
      if ($0 ~ /digest:[[:space:]]*sha256:/) { found=1; exit }
    }
    END { exit(found?0:1) }
  ' "$1"
}

lint_allowlist || exit 2

scanned=0
fail=0

# ⚠️ 열거를 **변수로** 받는다 — `done < <(walk_scope …)` 프로세스 치환은 워커(bun) 실패를
# `set -euo pipefail`로 전파하지 않는다. 실측: walk_scope가 경로를 못 찾아 죽자 두 레인이 조용히
# 0건이 됐다(그때 합계 바닥값이 잡아 주긴 했지만, 그건 우연히 큰 레인이 함께 죽었기 때문이다).
platform_files="$(scan_enumerate check-image-pins:platform walk_scope platform-image-refs)" || exit 1
apps_files="$(scan_enumerate check-image-pins:apps walk_scope apps-values)" || exit 1

# --- 레인1: platform 문자열 이미지 (열거·제외는 platform-image-refs 스코프 소유) ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    printf '%s' "$val" | grep -qE '^[a-z0-9]' || continue
    scanned=$((scanned + 1))
    printf '%s' "$val" | grep -q '@sha256:' && continue
    allow_has "$val" && continue
    echo "UNPINNED(lane1): $f — $val"
    fail=$((fail + 1))
  done < <(extract_string_images "$ROOT/$f")
done <<< "$platform_files"
scanned_lane1="$scanned"

# --- 레인2: apps 구조체 이미지 (열거는 apps-values 스코프 소유) ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # (a) 인라인 문자열 image가 있으면 @sha256 강제(struct 규약 이탈 대비).
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    printf '%s' "$val" | grep -qE '^[a-z0-9]' || continue
    scanned=$((scanned + 1))
    printf '%s' "$val" | grep -q '@sha256:' && continue
    app=$(printf '%s' "$f" | sed -E 's#^apps/([^/]+)/.*#\1#')
    allow_has "app:$app" && continue
    echo "UNPINNED(lane2-string): $f — $val"
    fail=$((fail + 1))
  done < <(extract_string_images "$ROOT/$f")
  # (b) value-less image 블록이면 블록 스코프 digest: sha256: 강제.
  if grep -qE '^[[:space:]]*image:[[:space:]]*$' "$ROOT/$f" 2>/dev/null; then
    scanned=$((scanned + 1))
    image_block_has_digest "$ROOT/$f" && continue
    app=$(printf '%s' "$f" | sed -E 's#^apps/([^/]+)/.*#\1#')
    allow_has "app:$app" && continue
    echo "UNPINNED(lane2): $f — image 블록에 digest: sha256: 부재"
    fail=$((fail + 1))
  fi
  # (c) flow-style image: { repo:.., digest:.. } — 같은 줄에 digest sha256 없으면 미핀(빌드가 안 쓰지만 계약 완결).
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    scanned=$((scanned + 1))
    printf '%s' "$fl" | grep -q 'digest:[[:space:]]*sha256:' && continue
    app=$(printf '%s' "$f" | sed -E 's#^apps/([^/]+)/.*#\1#')
    allow_has "app:$app" && continue
    echo "UNPINNED(lane2-flow): $f — flow-style image에 digest: sha256: 부재"
    fail=$((fail + 1))
  done < <(grep -hE '^[[:space:]]*image:[[:space:]]*\{' "$ROOT/$f" 2>/dev/null || true)
done <<< "$apps_files"
scanned_lane2=$((scanned - scanned_lane1))

# --- scan-floor: 스캔이 의심스럽게 적으면(글롭/제외 파손) fail-loud ---
# ⚠️ 종료코드는 1이다. 2는 CONTRIBUTING이 **사용법/파싱 오류**로 예약했고(위 `unknown arg`가 그 용법),
# 같은 scan-floor 클래스의 다른 가드는 전부 1이다(check-resource-limits·check-alert-rules·
# check-guard-authority·check-skip-signalling·scripts/lib/scan-floor.sh). 여기만 2였다 — 같은 클래스에
# 두 코드를 남기는 것이 정확히 이 캠페인이 지우는 병이라 1로 수렴시켰다.
if [ "$scanned" -lt "$MIN_SCAN" ]; then
  echo "ERROR: 스캔 무결성 의심 — 이미지 ${scanned}건(<${MIN_SCAN}). 글롭/제외 경로 파손 가능(scan-floor)." >&2
  exit 1
fi
# ⚠️ **합계 바닥값은 작은 레인의 붕괴를 원리적으로 못 잡는다.** 실측 분해(앱 철거 전): 레인1
# (platform) 34건 · 레인2(apps) 2건. 레인2가 0이 돼도 레인1만으로 34 ≥ 20이라 위 검사는 절대 발화하지 않는다 —
# 그동안 apps 레인의 digest 핀 강제가 통째로 사라져도 초록이었다는 뜻이다. 레인마다 자기 바닥값이 필요하다.
# (레인1은 합계 바닥값이 사실상 전담한다 — 레인2 최대치가 한 자릿수라 34가 무너지면 합계가 먼저 걸린다.)
# 픽스처 모드(--root)엔 **기본값을** 적용하지 않는다 — 픽스처는 정당하게 한 레인만 만든다
# (선례: check-app-netpol). 단 `--min-scan-apps`를 **명시하면** 픽스처에서도 적용한다 —
# 그렇지 않으면 이 바닥값 자체를 red-green으로 실증할 방법이 없다(가드가 자기 검증을 못 받는 자리).
if [ "$ROOT_OVERRIDDEN" -eq 0 ] || [ "$MIN_SCAN_APPS_SET" -eq 1 ]; then
  scan_floor check-image-pins:apps "$scanned_lane2" "$MIN_SCAN_APPS" || exit 1
else
  scan_signal check-image-pins:apps "$scanned_lane2"
fi
# 레인1은 자기 바닥값이 없다(합계 MIN_SCAN이 사실상 전담 — 레인2 최대치가 한 자릿수다).
# 그래도 실행 관측 신호는 내야 한다 — 06이 "이 호출이 실 도메인에 닿았는가"를 판정하는 입력이다.
scan_signal check-image-pins:platform "$scanned_lane1"

if [ "$fail" -gt 0 ]; then
  echo "핀 안 된 이미지 ${fail}건 (스캔 ${scanned}건). @sha256 digest 핀 또는 allowlist 등재(사유 주석) 필요."
  exit 1
fi
# 성공 메시지도 헤더의 경계를 그대로 반영한다(헤더 10행이 그걸 계약으로 건다) — 차트 내부는
# "Renovate 관할"이 아니라 **digest 소유자 없음(원장 선언)** 이다.
echo "스캔된 platform/apps 런타임 이미지 전부 digest 핀됨 (스캔 ${scanned}건 = platform ${scanned_lane1} + apps ${scanned_lane2}). [helm 차트 내부=digest 소유자 없음(policy/image-ownership.json 선언)·substrate=versions.env 관할]"
