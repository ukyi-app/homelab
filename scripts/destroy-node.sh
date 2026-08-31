#!/usr/bin/env bash
# 베어메탈 노드 파괴 프리미티브 (D-j, owner 확정). k3s를 전손시키고 `/var/lib/rancher`를 지워
# **"노드를 잃었다"를 실제로 만든다** — `dr-drill.sh`의 [1]이 부르는 유일한 파괴 지점이다.
#
# ⚠️ OrbStack 시절의 `orb delete -f k3s` 한 줄을 대체한다. 그 줄은 값싼 전손이었다(VM은 cattle).
#    물리 노드는 cattle이 아니다 — 여기서 사라지는 것은 **standard 클래스 PV 전량**이고
#    (`/var/lib/rancher/k3s-storage/internal`), 되돌릴 수 없다.
# ⚠️ **왜 전용 파일인가.** 파괴가 드릴 본문의 한 줄로 숨어 있으면 "그 줄만 떼어 돌려보는" 경로가
#    생긴다. 2026-08-16 감사 중 에이전트 3개가 `orb delete -f k3s`가 조용히 통과하는지 **실증하려고**
#    실제로 실행해 라이브 클러스터를 파괴했다. 파일을 나누고 확인 env를 요구하면, 그 한 줄을
#    복붙해도 아무 일이 일어나지 않는다.
#
# 안전 설계 — 세 겹, 전부 fail-closed. **순서가 곧 설계다**(싼 거부부터 — 거부가 부작용 0으로 끝난다):
#   (1) 확인 env `DR_DRILL_DESTROY_CONFIRM=1` 부재 = 거부. 인자가 아니라 env인 이유는
#       `teardown.sh`의 confirm과 같다 — 디스패처/복붙 오발사 가드다.
#   (2) 국면 A(D4 한시) 창이 열려 있으면 거부. 그 동안 bulk는 부트 디스크의 bind 마운트라
#       이 파괴가 files-data(git+R2+age로 재구축 **불가**한 유일 자산)를 함께 지운다.
#       ⚠️ `dr-drill.sh`가 같은 게이트를 이미 갖고 있어도 **여기 또 둔다.** 이 스크립트는 드릴을
#          거치지 않고 직접 실행될 수 있고, 그때 드릴의 게이트는 아무것도 지키지 않는다.
#   (3) `k3s-uninstall.sh` 부재 = fail-loud. 부재는 "지울 게 없다"가 아니라 "k3s가 예상과 다르게
#       설치돼 있다"는 뜻이고, 그 상태에서 `/var/lib/rancher`만 지우면 반쯤 산 노드가 남는다.
#
# ⚠️ **`|| true` 금지.** 예전 한 줄은 `orb delete -f k3s || true`였다 — 파괴가 실패해도 드릴이
#    계속 진행됐다. 그러면 [2] 이후 전부가 "재구축"이 아니라 **멀쩡한 노드 재확인**이 되고,
#    드릴은 아무것도 증명하지 않은 채 PASS를 찍는다. 실패는 여기서 멈춰야 한다.
#
# ⚠️ **bulk를 건드리지 않는다는 것은 조건부 사실이다 — 그래서 (2b)로 실측한다.**
#    국면 B에서 `/mnt/bulk`가 별도 디스크라는 사실이 이 드릴의 안전 설계 전체를 떠받치는데,
#    국면 A에서는 그 bind **소스가 `/var/lib/rancher/k3s-storage/bulk`**다(versions.env 실측:
#    `/dev/mapper/ubuntu--vg-ubuntu--lv[/var/lib/rancher/k3s-storage/bulk]`). 즉 아래 `rm -rf`가
#    files-data를 **실제로 지운다.** 경로 문자열(`/mnt/bulk`)만 보면 이 위험이 안 보인다.
#
# 시임 (테스트가 꽂는다):
#   K3S_RUN        권한 상승 명령. 기본 `sudo`. 테스트는 argv 기록기를 꽂는다(k3s-install.sh 규약).
#                  ⚠️ **모든 권한 명령이 이 시임을 지난다** — 하나라도 새면 그 테스트가 진짜로 파괴한다.
#   K3S_UNINSTALL  k3s 언인스톨러 경로. 기본 `/usr/local/bin/k3s-uninstall.sh`.
#
# 사용:  DR_DRILL_DESTROY_CONFIRM=1 scripts/destroy-node.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_RUN="${K3S_RUN:-sudo}"
K3S_UNINSTALL="${K3S_UNINSTALL:-/usr/local/bin/k3s-uninstall.sh}"
RANCHER_DIR=/var/lib/rancher
# versions.env 단일 값 리더. **직접 실행**한다(`bash <경로>`가 아니다) — 실행 비트가 계약이라
# 644로 떨어지면 아래 `[ -x ]`가 먼저 fail-loud한다.
VERSIONS_READ="$REPO_ROOT/infra/k3s-bootstrap/versions-read.sh"

fail() { echo "DESTROY ABORT: $*" >&2; exit 1; }

# ── (1) 확인 env ───────────────────────────────────────────────────────────────────────────
[ "${DR_DRILL_DESTROY_CONFIRM:-}" = "1" ] \
  || fail "DR_DRILL_DESTROY_CONFIRM=1 없이는 파괴하지 않는다. 이 스크립트는 노드를 전손시킨다(k3s-uninstall.sh + ${RANCHER_DIR} 삭제 = standard 클래스 PV 전량 소멸, 복구 불가). 의도했다면: DR_DRILL_DESTROY_CONFIRM=1 $0"

# ── (2) bulk 국면 A(D4 한시) 거부 게이트 ───────────────────────────────────────────────────
# ⚠️ 파생 방식은 dr-drill.sh와 같다: versions.env를 **source하지 않는다.** source하면 그 파일의
#    다른 export가 이 셸에 새어 들어오고, 파괴 직전 스크립트가 자기 환경을 남의 파일에 맡기게 된다.
# ⚠️ **옛 sed 한 줄은 여기서 fail-open이었다.** `sed -n 's/^export KEY="\(.*\)"$/\1/p' … || true`는
#    파일 부재 · 키 부재 · 줄 포맷 변경을 **전부 빈 문자열로 접었고**, 아래 `[ -n ]`이 그 셋을 모두
#    "국면 B — 파괴해도 좋다"로 읽었다. 실측(2026-08-29, argv 기록기 픽스처 · findmnt이 국면 B 응답):
#    키 부재 · `export …UNTIL=2026-12-31`(따옴표 없음) · `export …UNTIL = "…"`(등호 공백) 셋 다
#    **rc 0으로 `rm -rf ${RANCHER_DIR}`까지 완주했다** — 창이 열려 있다고 선언돼 있어도 그랬다.
#    파일 부재만 거부됐는데, 그것은 국면 A 게이트가 아니라 아래 (2b)의 형제 키 `BULK_STORAGE_PATH`가
#    같은 sed로 실패해 잡은 것이다(우연이다 — 한 파일 안의 그 비대칭이 티켓 07의 병소였다).
#    리더는 그 셋을 rc 1(판정 불가)로 내고 **선언된 빈 값만** rc 0으로 통과시킨다.
[ -x "$VERSIONS_READ" ] \
  || fail "versions.env 리더가 실행 가능하지 않다: ${VERSIONS_READ}. 부재/비실행은 '국면 B'가 아니라 판정 불가다."
if ! _bulk_window="$("$VERSIONS_READ" BULK_MIGRATION_WINDOW_UNTIL)"; then
  fail "versions.env에서 BULK_MIGRATION_WINDOW_UNTIL을 판정하지 못했다(사유는 바로 위 versions-read 줄) — 국면 A인지 모른 채로는 파괴하지 않는다. 판정 불가는 '창이 비었다'가 아니다."
fi
if [ -n "$_bulk_window" ]; then
  echo "DESTROY ABORT: 국면 A(D4 한시) 진행 중 — bulk가 파괴 대상과 같은 디스크에 있다(만료 ${_bulk_window})." >&2
  echo "               이 파괴는 bulk의 사용자 데이터(files-data)를 함께 지운다 — git+R2+age로 재구축 불가다." >&2
  echo "               국면 B(2TB M.2를 /mnt/bulk에 마운트) 후 versions.env의" >&2
  echo "               BULK_MIGRATION_WINDOW_UNTIL을 비우면 다시 열린다." >&2
  exit 1
fi

# ── (2b) bind 소스 실측 게이트 — 선언이 아니라 디바이스 사실을 본다 ────────────────────────
# ⚠️ (2)는 **선언**만 본다. 그런데 레포 자신이 SSOT에 이렇게 못박았다(versions.env):
#      "두 국면의 구별은 경로가 아니라 **디바이스 정체성**으로 한다 — 루트와 같은 디바이스면 국면 A다."
#    창을 비웠는데 국면 B를 **실제로 하지 않으면** (2)는 통과한다. 그 상태에서 `/mnt/bulk`의 bind
#    소스는 파괴 대상 트리 안이므로 아래 `rm -rf`가 files-data(git+R2+age로 재구축 불가)를 지운다.
#    (2)만 있으면 그 사고를 잡는 가드가 레포 전체에 0건이다.
# ⚠️ `findmnt` 부재는 '안전'이 아니라 '판정 불가'다 — (3)과 같은 이유로 fail-loud.
if ! _bulk_path="$("$VERSIONS_READ" BULK_STORAGE_PATH)"; then
  fail "versions.env에서 BULK_STORAGE_PATH를 판정하지 못했다(사유는 바로 위 versions-read 줄) — bulk가 파괴 대상 안에 있는지 판정할 수 없다."
fi
# ⚠️ 리더의 rc와 **이 `[ -n ]`은 다른 것을 본다.** rc는 "선언을 읽었는가", 여기는 "그 값이 경로로
#    쓸 수 있는가"다. `BULK_STORAGE_PATH=""`는 정본 선언이라 rc 0이지만 findmnt에 줄 경로가 아니다.
[ -n "$_bulk_path" ] || fail "versions.env의 BULK_STORAGE_PATH가 빈 값으로 선언돼 있다 — bulk가 파괴 대상 안에 있는지 판정할 수 없다."
$K3S_RUN command -v findmnt >/dev/null 2>&1 \
  || fail "findmnt가 없다 — bulk의 bind 소스를 확인할 수 없다. 부재는 '안전'이 아니라 '판정 불가'다(util-linux 설치 후 재시도)."
# bind 마운트의 SOURCE는 `<device>[<subpath>]` 꼴이다. subpath가 파괴 대상 트리 안이면 거부한다.
# ⚠️ `|| true`로 삼키지 않는다. findmnt이 답하지 못하는 상태는 '안전'이 아니라 **더 위험**할 수 있다 —
#    국면 A의 bind가 풀려 있으면 `${_bulk_path}`는 빈 디렉토리이고 실데이터는 ${RANCHER_DIR} 밑에
#    그대로 남아 아래 `rm -rf`에 지워진다. 그 경우가 정확히 여기서 조용히 통과하면 안 되는 자리다.
if ! _bulk_src="$($K3S_RUN findmnt -n -o SOURCE "$_bulk_path" 2>/dev/null)"; then
  fail "findmnt이 ${_bulk_path}의 마운트 소스를 답하지 못했다(마운트 안 됨 또는 경로 부재). 판정 불가는 '안전'이 아니다 — 국면 A의 bind가 풀려 있으면 실데이터는 ${RANCHER_DIR} 밑에 남아 있고 아래 삭제가 그것을 지운다. 마운트 상태를 확인한 뒤 재시도하라."
fi
case "$_bulk_src" in
  *"[${RANCHER_DIR}/"*|*"[${RANCHER_DIR}]"*)
    fail "bulk(${_bulk_path})의 bind 소스가 파괴 대상 안에 있다: ${_bulk_src}. ${RANCHER_DIR} 삭제가 files-data를 함께 지운다 — 국면 B(별도 디바이스)가 실제로 끝난 뒤에만 파괴할 수 있다. (창을 비우는 것만으로는 국면 B가 되지 않는다.)" ;;
esac

# ── (3) 언인스톨러 실재 확인 ───────────────────────────────────────────────────────────────
[ -x "$K3S_UNINSTALL" ] \
  || fail "k3s 언인스톨러가 없다: ${K3S_UNINSTALL}. 부재는 '지울 게 없다'가 아니라 'k3s가 예상과 다르게 설치돼 있다'는 뜻이다 — ${RANCHER_DIR}만 지우면 반쯤 산 노드가 남는다."

# ── 파괴 ───────────────────────────────────────────────────────────────────────────────────
echo "==> [1/2] k3s 전손: ${K3S_UNINSTALL} (권한 상승 ${K3S_RUN})"
$K3S_RUN "$K3S_UNINSTALL"

# ⚠️ 언인스톨러는 `/var/lib/rancher/k3s`만 지운다 — `k3s-storage/internal`(standard 클래스 PV의
#    백킹 디렉토리, versions.env의 INTERNAL_STORAGE_PATH)은 남는다. 그것이 남으면 "노드 유실"이
#    거짓이 되고, 재구축 후 워크로드가 **옛 로컬 PV 데이터 위에서** 되살아난 것을 드릴이
#    "git에서 복귀했다"로 오독한다.
echo "==> [2/2] ${RANCHER_DIR} 삭제 — standard 클래스 PV 전량 소멸(노드 유실을 진짜로 만든다)"
$K3S_RUN rm -rf "$RANCHER_DIR"

# 파괴됐는지 **확인한다** — 성공을 가정하지 않는다(0으로 끝나고도 남기는 경우가 있다).
if $K3S_RUN test -e "$RANCHER_DIR"; then
  fail "${RANCHER_DIR}가 아직 남아 있다 — 파괴가 완료되지 않았다. 이 상태로 드릴을 계속하면 '재구축'이 아니라 잔존 상태 재확인이 된다."
fi

echo "OK: 노드 파괴 완료 — k3s 제거 + ${RANCHER_DIR} 소멸."
echo "    bulk(${_bulk_path})는 파괴 대상 밖이다 — (2b)가 bind 소스로 확인했다(SOURCE=${_bulk_src:-<미마운트>})."
