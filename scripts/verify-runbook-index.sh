#!/usr/bin/env bash
# 런북 인덱스 드리프트 로컬 가드 — docs/runbooks/(gitignored)에 .md가 있으면 AGENTS.md 런북 인덱스와 일치.
# 런북은 비공개 로컬이라 CI/repo엔 부재 → **SKIP 신호**(exit 4 + `SKIP:` 마커, CONTRIBUTING 규약).
# exit 0이면 "인덱스를 실제로 대조했고 정합"이라는 뜻이다 — 부재로 건너뛴 것과 절대 같은 코드를 쓰지 않는다.
# ⚠️ 정방향도 절 **안**만 본다(감사 6라운드 grep-c-5) — AGENTS.md 전문을 grep하면 런북 파일명이
#   다른 절의 산문·표·HTML 주석에 한 번만 등장해도 통과한다. 역방향과 같은 절 추출(idx_md) 결과에
#   완전 일치로 대조해야 절 밖 언급이 인덱스로 둔갑하지 않는다.
# cf. verify-runbooks=DR bats 러너(별도, 불변).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init verify-runbook-index
RB="$ROOT/docs/runbooks"
shopt -s nullglob
files=("$RB"/*.md)
# skip 방출(마커+exit 4 원자)은 guard_skip(scripts/lib/guard.sh)이 소유한다.
if [ ${#files[@]} -eq 0 ]; then guard_skip verify-runbook-index "docs/runbooks/*.md 0건(gitignored 로컬 전용) — 인덱스 정합 미평가"; fi
# 「## 런북」 절 추출 — 정방향·역방향 둘 다 **이 결과 하나**를 쓴다(순서 이동, 로직 무변경).
# 절 추출은 다음 `## ` 헤딩에서 멈춰야 한다 — `,$p`(파일 끝까지)는 「## 런북」 뒤에 절이
# 추가되는 순간 그 절의 백틱 .md 참조를 인덱스로 오인한다(실측: 「## Agent skills」).
# shellcheck disable=SC2016  # grep 패턴 속 백틱은 의도적 리터럴(ERE) — 확장 아님
idx_md="$(awk '/^## 런북/{s=1;next} /^## /{s=0} s' "$ROOT/AGENTS.md" | { grep -oE '`[A-Za-z0-9./-]+\.md`' || true; } | tr -d '`' | sed 's#.*/##' | LC_ALL=C sort -u)"
# 추출 0건 = 「## 런북」 절 부재/개명/강등 의심 — 역방향 레인이 errexit로 무언 종료하는 대신
# 명시 FAIL을 낸다. (위 `|| true`는 바로 이 판정이 뒤따를 때만 허용 — 검출기 죽음을 삼키는
# fail-open 금지 규약과 충돌하지 않는다.)
if [ -z "$idx_md" ]; then
  echo "FAIL: AGENTS.md 「## 런북」 절에서 인덱스 항목을 하나도 추출하지 못했다 — 절 개명/강등 의심"
  exit 1
fi
fail=0
for f in "${files[@]}"; do
  b="$(basename "$f")"
  case "$b" in test_*) continue;; esac
  # herestring 완전일치 — 절 **안**에서만 찾는다(파일 전체 grep이면 절 밖 언급도 인덱스로 오인한다).
  grep -Fqx -- "$b" <<<"$idx_md" || { echo "FAIL: AGENTS 런북 인덱스에 누락: $b"; fail=1; }
done
# 역방향(AGENTS 인덱스 → 런북 파일): 인덱스에 나열된 각 *.md가 docs/runbooks/에 실재하는지.
# owner 머신(런북 실재)에서만 도달 — 위 skip 가드가 CI/fresh-checkout 배제. fail-closed(양방향).
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -f "$RB/$m" ] || { echo "FAIL: AGENTS 인덱스에 있으나 런북 파일 부재: $m"; fail=1; }
done <<< "$idx_md"
[ "$fail" -eq 0 ] && echo "verify-runbook-index: 런북 인덱스 양방향 정합 OK"
exit "$fail"
