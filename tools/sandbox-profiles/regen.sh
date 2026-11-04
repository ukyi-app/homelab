#!/usr/bin/env bash
# containerd 기본값(base/)을 다시 뽑고 host/sandbox-profiles/의 프로필을 다시 만든다.
#
# 사용: tools/sandbox-profiles/regen.sh [--check]
#   인자 없음  base/와 프로필을 쓴다.
#   --check   쓰지 않고 커밋한 base/·프로필과 대조하고 AppArmor 문법을 본다(커널에 올리지 않는다).
#
# NUC에서 sudo 없이, 제한 없는(unconfined) 셸로 실행한다. 기본값이 그 호스트의 /etc/apparmor.d와 이 셸의 AppArmor 라벨에
# 따라 달라진다(containerd-defaults/main.go). ci에 넣지 않은 까닭이기도 하다: CI에는 Go·apparmor_parser가 없다.
# ci는 Go 없이 되는 뒤 단계(generate.ts --check)만 돈다.
#
# k3s를 올릴 때 순서:
#   1. 새 k3s가 쓰는 containerd를 확인한다. kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'
#      또는 k3s 저장소 해당 태그 go.mod의 containerd replace.
#   2. host/versions.env의 SANDBOX_PROFILE_K3S·SANDBOX_PROFILE_CONTAINERD와 containerd-defaults/go.mod를 옮긴다(go mod tidy).
#   3. 이 스크립트를 인자 없이 돌린다. 기본값 차이로 generate.ts가 멈추면 변경을 그 판에 맞게 고친다.
#   4. git diff host/sandbox-profiles/. 내용이 바뀌었으면 generate.ts의 VERSION을 올려 새 이름으로 만들고, 옛 파일은 되돌린다.
#      새 이름은 sudo host/install.sh --cluster <이름> --sandbox-profiles로 깔고, 다시 잰 뒤 platform/sandbox에서 참조를 옮긴다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GEN="$HERE/containerd-defaults"

check=false
case "${1:-}" in
  "") ;;
  --check) check=true ;;
  *) echo "사용: tools/sandbox-profiles/regen.sh [--check]" >&2; exit 2 ;;
esac

for c in go bun apparmor_parser cmp; do
  command -v "$c" >/dev/null 2>&1 || { echo "FAIL: 명령 ${c}가 없다" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

go -C "$GEN" run . seccomp >"$TMP/seccomp.json"
go -C "$GEN" run . apparmor >"$TMP/apparmor.txt"

fails=0
for f in seccomp.json apparmor.txt; do
  if [ "$check" = true ]; then
    if cmp -s "$TMP/$f" "$HERE/base/$f"; then
      echo "ok   base/${f}가 containerd 기본값과 같다"
    else
      echo "FAIL base/${f}가 containerd 기본값과 다르다. NUC의 제한 없는 셸에서 돌렸는지 본다" >&2
      fails=$((fails + 1))
    fi
  else
    cp "$TMP/$f" "$HERE/base/$f"
    echo "씀   base/${f}"
  fi
done

if [ "$check" = true ]; then
  bun "$HERE/generate.ts" --check || fails=$((fails + 1))
else
  bun "$HERE/generate.ts"
fi

# -Q: 커널에 올리지 않는다. -K -T: 캐시를 쓰지도 읽지도 않고 매번 컴파일한다.
for f in "$ROOT"/host/sandbox-profiles/apparmor/*; do
  if apparmor_parser -Q -K -T "$f"; then
    echo "ok   apparmor_parser 문법 ${f#"$ROOT"/}"
  else
    echo "FAIL apparmor_parser가 ${f#"$ROOT"/}를 거부했다" >&2
    fails=$((fails + 1))
  fi
done

[ "$fails" -eq 0 ] || { echo "FAIL: sandbox-profiles ${fails}건" >&2; exit 1; }
