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
#   이미지(traefik/sealed-secrets/tailscale/cnpg-operator 등 — 레포에 image: 스칼라로 없음, Renovate pinDigests 관할).
# 제외(스캐너 하드코딩 — allowlist 아님): 벤더 수정금지(platform/cnpg/barman-plugin/** · gateway-api CRD),
#   테스트/픽스처(**/tests/** · **/fixtures*/** — fixtures-bad 포함 접미 와일드카드). 픽스처 글롭은 라이브 실측 확정:
#   */fixtures/*는 fixtures-bad를 놓치고 */tests/*는 루트 tests/를 놓친다 → **/tests/** + **/fixtures*/**.
# 예외: policy/image-pin-allowlist.txt(라인당 이미지 값 또는 app:<name>, # 사유 주석 **강제** — 인라인 또는 직전 줄).
#   수용 기준 = allowlist 0(핀 후).
#
# make verify 배선됨(Task 9, 핀 적용 후) — 기본 --min-scan 20(scan-floor 유효, 배선부에 넘기지 않는다).
#   24 tag-only 이미지를 수동 digest 핀(renovate pin-dependencies 배치가 Issues:write gap으로 엉켜 결정적 경로 선택)
#   완료 후 실 레포는 allowlist 0으로 통과한다. 신규 미핀 이미지는 이 게이트가 fail-closed로 차단.
# bash 3.2 호환: [[ ]]·mapfile 금지(중간 단언 [ ]/grep). --root로 픽스처 tmp git 레포 지정 가능.
set -euo pipefail

ROOT=""; ALLOWLIST=""; MIN_SCAN=20
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    --min-scan) MIN_SCAN="$2"; shift 2 ;;   # scan-floor(글롭/제외 파손 감지). 픽스처만 낮춰 호출.
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$ROOT" ]; then ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
[ -z "$ALLOWLIST" ] && ALLOWLIST="$ROOT/policy/image-pin-allowlist.txt"

# 앵커된 이미지 키 정규식 — `logo_image:`·경로 내 `my-image:` 부분매치 방지(리스트 아이템 `- ` 허용).
IMG_KEY='^[[:space:]]*(-[[:space:]]+)?(image|imageName):[[:space:]]*'
# 제외 경로(repo-relative). 벤더 + 테스트/픽스처.
EXCLUDE_RE='(^|/)tests/|(^|/)fixtures[^/]*/|^platform/cnpg/barman-plugin/|gateway-api-crds\.yaml$'

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

# --- 레인1: platform 문자열 이미지(git ls-files=추적 파일만, untracked helm 캐시 자동 제외) ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *.yaml|*.yml) : ;; *) continue ;; esac
  echo "$f" | grep -qE "$EXCLUDE_RE" && continue
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    printf '%s' "$val" | grep -qE '^[a-z0-9]' || continue
    scanned=$((scanned + 1))
    printf '%s' "$val" | grep -q '@sha256:' && continue
    allow_has "$val" && continue
    echo "UNPINNED(lane1): $f — $val"
    fail=$((fail + 1))
  done < <(extract_string_images "$ROOT/$f")
done < <(cd "$ROOT" && git ls-files -- 'platform' 2>/dev/null || true)

# --- 레인2: apps 구조체 이미지 ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */deploy/prod/values.yaml) : ;; *) continue ;; esac
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
done < <(cd "$ROOT" && git ls-files -- 'apps' 2>/dev/null || true)

# --- scan-floor: 스캔이 의심스럽게 적으면(글롭/제외 파손) fail-loud ---
if [ "$scanned" -lt "$MIN_SCAN" ]; then
  echo "ERROR: 스캔 무결성 의심 — 이미지 ${scanned}건(<${MIN_SCAN}). 글롭/제외 경로 파손 가능(scan-floor)." >&2
  exit 2
fi

if [ "$fail" -gt 0 ]; then
  echo "핀 안 된 이미지 ${fail}건 (스캔 ${scanned}건). @sha256 digest 핀 또는 allowlist 등재(사유 주석) 필요."
  exit 1
fi
echo "스캔된 platform/apps 런타임 이미지 전부 digest 핀됨 (스캔 ${scanned}건). [helm 차트 내부=Renovate·substrate=versions.env 관할]"
