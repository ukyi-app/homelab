#!/usr/bin/env bash
# CNPG **아카이브 serverName** 분리 가드 — R2의 barman 아카이브 prefix를 결정하는 값이
# (A) 읽기와 쓰기로 갈려 있는지, (B) (CI에서 main으로 들어갈 때) 라이브가 기대하는 값인지 강제한다.
#
# 왜: `serverName` **한 줄**이 `s3://<bucket>/<serverName>/{base,wals}/`를 통째로 정한다.
# 두 primary(라이브 Mac + NUC)가 같은 값을 쓰면 타임라인이 섞여 오프사이트 PITR 경로가 망가지고,
# R2에 버저닝이 없어(`infra/cloudflare/r2.tf`) **되돌릴 수 없다**(계획서 §3.4의 ❌ 항목).
# ObjectStore CRD는 `serverName`을 CEL로 금지하므로 분리 지점은 Cluster의 plugin parameter뿐이다.
#
# 두 검사는 `check-argocd-revision.sh`와 **같은 이유로** 분리돼 있다:
#   (A) 정합  — 쓰기 serverName이 있고, 복구 원본(externalClusters)이 있다면 그것과 **다르다**.
#              인자 없이 항상. 마이그레이션 브랜치에서도 main에서도 green이어야 한다.
#   (B) 고정  — 쓰기 serverName이 `EXPECT_PG_SERVERNAME`과 일치. env가 비면 **건너뛴다**.
# (B)를 기본으로 켜면 마이그레이션 브랜치의 gate가 영구 red가 된다 — ci.yaml이 main 진입 시에만 채운다.
#
# ⚠️ **컷오버 때 이 가드가 강제로 알려준다.** Mac이 살아 있는 동안 `pg-nuc`가 main에 들어가면
#    Mac의 ArgoCD가 selfHeal로 라이브 Cluster의 아카이브를 갈아탄다 — 체인이 그 자리에서 갈라진다.
#    컷오버 시점에는 ci.yaml의 기대값을 `pg-nuc`로 바꾸는 **같은 PR**이어야 통과한다.
#    지금 이걸 막고 있는 것은 `check-argocd-revision.sh`의 부수효과일 뿐 설계된 방어가 아니었다.
#
# yq(mikefarah) 필요. bash 3.2 호환. shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-pg-servername

CLUSTER_YAML="${PG_CLUSTER_YAML:-$ROOT/platform/cnpg/prod/cluster.yaml}"
PLUGIN="barman-cloud.cloudnative-pg.io"

fail() { echo "FAIL: check-pg-servername: $*" >&2; exit 1; }

# ⚠️ **yq 함정**: `yq -e`는 결과가 null이면 non-zero로 종료하면서도 **stdout에 리터럴 `null`을 찍는다.**
#    `|| true`로 rc를 삼키면 변수에 `null`이라는 **비어 있지 않은 문자열**이 담겨, `[ -n "$x" ]`
#    형태의 부재 검사가 통과한다(실측: 이 가드의 첫 판이 정확히 그렇게 새서 @test 6이 잡았다).
#    모든 yq 결과는 이 정규화를 거친다.
_nz() { case "$1" in null|"~"|"") printf '' ;; *) printf '%s' "$1" ;; esac; }

command -v yq >/dev/null 2>&1 || fail "yq가 PATH에 없다"
[ -r "$CLUSTER_YAML" ] || fail "${CLUSTER_YAML}을 읽지 못했다"

# ── (A) 정합 ───────────────────────────────────────────────────────────────────────────────
# ⚠️ 텍스트 grep을 쓰지 않는다 — 이 파일의 주석이 두 값을 **설명하느라** 그대로 담고 있어서
#    파일 전체 grep은 자기 주석에 걸린다(이 레포가 반복해서 밟은 클래스). yq 구조 비교만 쓴다.
write_sn="$(_nz "$(yq -e ".spec.plugins[] | select(.name == \"${PLUGIN}\") | .parameters.serverName" "$CLUSTER_YAML" 2>/dev/null || true)")"
[ -n "$write_sn" ] \
  || fail "쓰기 serverName을 찾지 못했다 — .spec.plugins[name==${PLUGIN}].parameters.serverName (${CLUSTER_YAML}). 열거가 0건이면 '분리됨'이 아니라 '검사하지 못함'이다"

# 복구 원본은 **선택적**이다: main(라이브 Mac)은 initdb 형태라 externalClusters가 없고,
# 이전 브랜치는 recovery 형태라 있다. 있을 때만 분리를 강제한다.
read_sn="$(_nz "$(yq -e ".spec.externalClusters[] | select(.plugin.name == \"${PLUGIN}\") | .plugin.parameters.serverName" "$CLUSTER_YAML" 2>/dev/null || true)")"
ext_n="$(_nz "$(yq '.spec.externalClusters | length' "$CLUSTER_YAML" 2>/dev/null || echo 0)")"
[ -n "$ext_n" ] || ext_n=0

if [ "$ext_n" -gt 0 ]; then
  [ -n "$read_sn" ] \
    || fail "externalClusters가 ${ext_n}건 있는데 복구 원본의 serverName을 찾지 못했다 — 무엇을 복구할지 모른 채 통과시킬 수 없다"
  # ⚠️ yq가 여러 항목에 매치하면 값이 **다중행**이 되고 아래 비교가 조용히 다른 뜻이 된다.
  #    (`grep -qxF "$x"`로 자기 자신을 검사하는 건 동어반복이라 못 잡는다 — 처음에 그렇게 썼다.)
  #    줄 수로 센다: awk는 0건에서도 rc=0이라 `set -e` 함정이 없다.
  n_w="$(printf '%s\n' "$write_sn" | awk 'NF { n++ } END { print n+0 }')"
  [ "$n_w" -eq 1 ] || fail "쓰기 serverName이 ${n_w}건이다(1이어야 한다) — plugins에 barman 항목이 둘 이상인지 확인할 것"
  if printf '%s' "$write_sn" | grep -qxF -- "$read_sn"; then
    fail "쓰기와 읽기 serverName이 같다('${write_sn}') — 두 primary가 같은 R2 prefix에 아카이브하면 타임라인이 섞이고 오프사이트 PITR 경로가 망가진다. R2에 버저닝이 없어 되돌릴 수 없다"
  fi
fi

# ── (B) 고정 (ci.yaml이 main 진입 시에만 채운다) ──────────────────────────────────────────
expect="${EXPECT_PG_SERVERNAME:-}"
if [ -n "$expect" ]; then
  printf '%s' "$write_sn" | grep -qxF -- "$expect" \
    || fail "쓰기 serverName이 '${write_sn}'인데 이 브랜치로 들어갈 때 기대값은 '${expect}'다 — 라이브 클러스터가 selfHeal로 아카이브를 갈아탄다. 컷오버라면 ci.yaml의 EXPECT_PG_SERVERNAME을 같은 PR에서 바꿀 것"
fi

if [ "$ext_n" -gt 0 ]; then
  echo "OK: check-pg-servername (쓰기=${write_sn} · 읽기=${read_sn} · 분리됨${expect:+ · 고정=${expect}})"
else
  echo "OK: check-pg-servername (쓰기=${write_sn} · 복구 원본 없음(initdb 형태)${expect:+ · 고정=${expect}})"
fi
