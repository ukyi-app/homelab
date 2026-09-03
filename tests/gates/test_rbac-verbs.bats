#!/usr/bin/env bats
# 레포 RBAC verb 화이트리스트 게이트 — 손으로 쓴 ClusterRole/Role **전부**(platform + substrate)의
# verb가 read-only 집합 안에 있는지. 쓰기 verb는 파일 단위 면제 로스터로만 산다. @test 이름은 영어.
#
# 🔴 왜 게이트 레벨인가: 이 판정은 착지 전까지 **컴포넌트 하나(homepage)에만** 있었다.
#    실측 2026-09-03 — `platform/victoria-stack/prod/vmagent.yaml`의 ClusterRole verbs에
#    `delete`를 더하고(nodes·pods·services·endpoints 클러스터 전역) `./scripts/run-bats.sh`를 돌리면
#    2672 ok / **0 not ok**였다. 즉 관측 스택에 클러스터 전역 삭제 권한을 붙이는 변경이 required
#    게이트를 그대로 지나갔다. 규범은 있었고(homepage 파일의 화이트리스트), 없던 것은 **도달**이다.
#
# ⚠️ 판정은 **yq가 파싱한 verb 목록**에만 한다 — 파일 전체 grep은 이 헤더 자신이 `delete`를 담고 있어
#    부재 단언을 무력화한다(레포의 「규약을 설명한 파일이 그 규약에서 면제된다」 클래스).
# ⚠️ 파일 프리필터를 두지 않는다 — kind 판정을 grep으로 좁히면 표기가 바뀐 문서가 조용히 판정 밖이
#    된다(docs/traps-detail.md 「파일 프리필터를 함께 넓히지 않으면 kind 추가가 vacuous green으로
#    착지한다」). 168개 매니페스트 전수 yq가 0.6초라 좁힐 이유도 없다(실측).
# ⚠️ 중간 단언은 `[ ]`만 — bash 3.2에서 중간 `[[ ]]` 실패는 침묵 통과한다.
#
# 계층 관계: `platform/homepage/prod/test_homepage_rbac.bats`의 verb/resource 화이트리스트는 남는다.
#   저건 그 컴포넌트의 **resources 표면까지** 닫는 로컬 규율이고(여기는 verb 축만 본다), 이 게이트는
#   컴포넌트가 자기 bats를 안 쓰거나 새로 생겨도 도달하는 전역 바닥이다. 중복이 아니라 계층이다.

# 최소권한 표면의 **전칭 화이트리스트**. 확대는 이 줄이나 아래 면제 로스터를 고쳐야만 통과하므로
# 리뷰에 반드시 보인다. ⚠️ 리터럴 동사 블랙리스트로 되돌리지 마라 — `verbs: ["*"]`·`deletecollection`·
# `escalate`·`bind`·`impersonate`가 전부 그 사각이다(티켓 21 r1-15의 실측).
RO_VERBS="get list watch"

# ── 쓰기 verb 면제 로스터 ─────────────────────────────────────────────────────────────────────
# 한 줄 = `<추적 경로> <그 파일에서만 허용하는 추가 verb…>`. 파일 단위이고, 여기 적히지 않은 verb는
# 그 파일에서도 위반이다. **로스터에 있다는 것만으로는 통과하지 않는다** — 아래 @test가 각 항목이
# 실제로 쓰이는지(= 죽은 면제가 아닌지)를 되묻는다.
# ⚠️ 상한(EXEMPT_MAX)은 손 관리 수치지만 **단방향**이다: 줄이는 방향은 그냥 통과하고, 늘리려면 같은
#    PR에서 이 상수를 고쳐야 해서 리뷰에 보인다(형제 scripts/check-bats-accounting.sh의 EXCL_MAX와
#    같은 성격). 목표 상태는 0이다.
EXEMPT_MAX=4
EXEMPT="platform/traefik/prod/rbac-gateway.yaml update patch
platform/cnpg/prod/ensure-role-password-rbac.yaml create update patch
platform/cnpg/prod/restore-drill-rbac.yaml create delete
infra/k3s-bootstrap/storage/local-path-provisioner.yaml * create patch"
# 사유(로스터 순서대로):
#  · traefik rbac-gateway — `*/status` 서브리소스에만 update/patch. Gateway API 컨트롤러가 자기가
#    조정한 리소스의 status를 되쓰는 계약이라 read-only로는 Programmed가 서지 않는다.
#  · cnpg ensure-role-password — clusters patch는 비번 값이 아니라 annotate nudge, configmaps
#    create/update/patch는 per-DB freshness 마커 upsert(apply = get + create/patch)다.
#  · cnpg restore-drill — drill 전용 Cluster/Pod를 만들고 지운다. delete가 없으면 실행당 ~50GiB PVC가
#    누수된다(파일 주석의 실측). 대상이 drill 네임스페이스 Role이라 클러스터 전역이 아니다.
#  · local-path-provisioner(substrate) — 상류 rancher/local-path-provisioner 원문 그대로다. PV 프로비저닝
#    계약이 helper 파드·PV 생성/삭제·이벤트 기록을 요구해 `endpoints/persistentvolumes/pods`에 `*`,
#    `events`에 create/patch를 갖는다. 재벤더(버전 bump)마다 이 줄을 다시 검토할 것.
#    ⚠️ 이 게이트는 **verb 축 전용**이다 — `*` 면제 뒤로는 이 파일의 *resources* 확대(예: `secrets` 추가)가
#      증인 없이 통과한다. 그 축은 여전히 사각이고, 좁히려면 상류 포크 자체를 좁히는 별건이 필요하다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  # 파일 열거 = `tools/lib/repo-walk.ts`의 `platform-manifests` + `substrate-manifests` 두 스코프와
  # 같은 어휘다(추적 platform/infra yaml − 벤더 `charts/`·`barman-plugin/`·gateway-api CRD 번들 −
  # 테스트 하네스). 사본이 아니라 어휘 일치다 — bats는 bun을 부르지 않는 CI-safe 정적 가드로 유지한다.
  # ⚠️ `infra`가 분모에 있는 이유: 레포에서 `verbs: ["*"]`를 가진 **유일한** cluster-scoped ClusterRole이
  #    `infra/k3s-bootstrap/storage/local-path-provisioner.yaml`이고, 분모가 `platform`에서 끝나던 동안
  #    그 파일에 `delete`·`escalate`를 더해도 이 게이트는 3/3 ok였다(실측 2026-09-03).
  #    `storage/`만 집지 않는 이유는 미래 substrate 매니페스트도 같은 사각에 빠지지 않게 하려는 것이다.
  MANIFESTS="$(git ls-files -- platform infra \
    | grep -E '\.ya?ml$' \
    | grep -vE '(^|/)charts/|(^|/)barman-plugin/|(^|/)gateway-api-crds\.yaml$|(^|/)tests?/|(^|/)fixtures[^/]*/|(^|/)test_[^/]*$' \
    | LC_ALL=C sort)"
  NMANIFEST="$(printf '%s\n' "$MANIFESTS" | grep -c . || true)"
  # 바닥값 ① 파일 열거 — 이게 없으면 제외 정규식이 넓어져 0건을 스캔하고도 "위반 0"으로 초록이다.
  # 붕괴 경계 120(현재 168): 컴포넌트를 정당하게 철거할 여유를 두되 붕괴는 못 넘긴다.
  [ "$NMANIFEST" -ge 120 ] || { echo "platform+infra 매니페스트 열거가 ${NMANIFEST}건으로 붕괴했다(기대 >=120)"; false; }
  local f
  RBACFILES=""
  for f in $MANIFESTS; do
    if [ -n "$(yq 'select(.kind=="ClusterRole" or .kind=="Role") | .kind' "$f" 2>/dev/null)" ]; then
      RBACFILES="$RBACFILES $f"
    fi
  done
  NRBAC="$(printf '%s\n' $RBACFILES | grep -c . || true)"
  # 바닥값 ② RBAC 문서를 가진 파일 수 — kind 판정이 드리프트하면(yq 경로·표기 변경) 여기서 먼저 죽는다.
  # 붕괴 경계 6(현재 10): 도메인 크기를 굳히면 컴포넌트를 철거할 때마다 red가 난다.
  [ "$NRBAC" -ge 6 ] || { echo "ClusterRole/Role 파일 열거가 ${NRBAC}건으로 붕괴했다(기대 >=6)"; false; }
}

# 해당 파일의 면제 verb 목록을 stdout으로(없으면 빈 문자열).
exempt_verbs_of() {
  printf '%s\n' "$EXEMPT" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line " in
      "$1 "*) printf '%s' "${line#"$1" }" ;;
    esac
  done
}

@test "the RBAC enumeration does not collapse and still reaches the substrate root (scan floor)" {
  echo "SCAN: rbac-verbs:manifests: $NMANIFEST"
  echo "SCAN: rbac-verbs:rbac-files: $NRBAC"
  [ "$NMANIFEST" -ge 120 ]
  [ "$NRBAC" -ge 6 ]
  # 분모가 다시 `platform`으로 좁혀지면 여기서 red가 난다 — 바닥값만으로는 못 잡는다(platform만으로도
  # 165/9라 120/6을 넘는다). 레포 유일의 `verbs: ["*"]` cluster-scoped ClusterRole이 이 파일이다.
  case " $RBACFILES " in
    *" infra/k3s-bootstrap/storage/local-path-provisioner.yaml "*) ;;
    *) echo "substrate RBAC 매니페스트가 열거 밖이다 — setup의 git ls-files root에 infra가 있는지 확인"; false;;
  esac
  # 각 RBAC 파일이 verb를 **하나 이상** 내놓는가 — `.rules[].verbs[]` 경로가 드리프트하면 파일은
  # 그대로 열거되는데 verb 집합만 공집합이 돼 아래 전칭이 vacuous green이 된다.
  local f v n bare=""
  for f in $RBACFILES; do
    v="$(yq 'select(.kind=="ClusterRole" or .kind=="Role") | (.rules // [])[] | (.verbs // [])[]' "$f" 2>/dev/null | grep . || true)"
    n="$(printf '%s\n' "$v" | grep -c . || true)"
    [ "$n" -ge 1 ] || bare="$bare $f"
  done
  [ -z "$bare" ] || { echo "verb 열거가 공집합인 RBAC 파일:$bare"; false; }
}

# ★ 이 파일의 이유.
@test "every ClusterRole and Role verb is inside the read-only whitelist or its file exemption" {
  local f v ex bad=""
  for f in $RBACFILES; do
    ex="$(exempt_verbs_of "$f")"
    # ⚠️ `for v in $v`(비인용 확장) 금지 — 정작 잡아야 할 `*`가 pathname expansion으로 레포 디렉토리
    #    목록이 돼 위반 verb가 사라진다. heredoc 루프는 글로빙·단어분리 둘 다 없고, 파이프와 달리
    #    서브셸이 아니라 $bad가 전파된다(선례: platform/homepage/prod/test_homepage_rbac.bats).
    v="$(yq 'select(.kind=="ClusterRole" or .kind=="Role") | (.rules // [])[] | (.verbs // [])[]' "$f" 2>/dev/null | grep . || true)"
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      case " $RO_VERBS " in *" $w "*) continue;; esac
      case " $ex " in *" $w "*) continue;; esac
      bad="$bad ${f}:${w}"
    done <<EOF
$v
EOF
  done
  [ -z "$bad" ] || { echo "read-only 화이트리스트 밖 verb(면제 로스터에도 없음):$bad"; false; }
}

@test "every exemption entry is load-bearing (path is enumerated and the verb is actually used)" {
  # 죽은 면제는 게이트의 실제 표면을 가린다 — 리네임으로 경로가 어긋나거나 쓰기 verb가 제거됐는데
  # 로스터만 남으면, 다음 사람이 그 줄을 보고 "여긴 원래 쓰기가 있다"고 읽는다.
  local line path verbs w v n=0 stale=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    path="${line%% *}"
    verbs="${line#"$path" }"
    case " $RBACFILES " in
      *" $path "*) ;;
      *) stale="$stale ${path}(열거밖)"; continue;;
    esac
    v="$(yq 'select(.kind=="ClusterRole" or .kind=="Role") | (.rules // [])[] | (.verbs // [])[]' "$path" 2>/dev/null | grep . || true)"
    # ⚠️ `set -f` 없이는 이 비인용 확장이 면제 verb `*`를 **레포 루트 파일 목록**으로 글로빙한다
    #    (실측: AGENTS.md·CLAUDE.md…가 verb 자리에 들어와 전건 "미사용"으로 red). 위 ★ @test의 주석이
    #    메인 레인에 대해 경고한 바로 그 클래스인데 이 레인만 안 닫혀 있었다. 루프 구간만 껐다 켠다.
    set -f
    for w in $verbs; do
      # 면제가 read-only 집합과 겹치면 세탁이다 — 화이트리스트가 이미 통과시키는 verb다.
      case " $RO_VERBS " in *" $w "*) stale="$stale ${path}:${w}(read-only와 중복)"; continue;; esac
      printf '%s\n' "$v" | grep -qxF -- "$w" || stale="$stale ${path}:${w}(미사용)"
    done
    set +f
  done <<EOF
$EXEMPT
EOF
  [ -z "$stale" ] || { echo "죽은 면제 항목:$stale"; false; }
  # 로스터가 통째로 비면 위 루프가 0회라 이 @test가 vacuous green이 된다.
  [ "$n" -ge 1 ] || { echo "면제 로스터가 비었다 — 항목이 0건이면 이 @test는 아무것도 증언하지 않는다"; false; }
  echo "SCAN: rbac-verbs:exemptions: $n"
  # 단방향 상한 — 늘리려면 같은 PR에서 EXEMPT_MAX를 고쳐야 한다(헤더 참조).
  [ "$n" -le "$EXEMPT_MAX" ] || { echo "면제 ${n}건 > 상한 ${EXEMPT_MAX} — 쓰기 verb가 늘었다"; false; }
}
