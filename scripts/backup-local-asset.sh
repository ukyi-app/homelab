#!/usr/bin/env bash
# 로컬 전용 자산(런북) 백업 (DR 불변식) — sealing key 백업과 대칭.
# docs/runbooks/(gitignored)는 단일 Mac 디스크 단일 사본이라 매체 유실에 무방비다. tarball을 age(sops
# binary)로 암호화해 git 밖 매체에 버전드 보관하고 --verify로 신선도를 게이트한다.
#   scripts/backup-local-asset.sh <outdir>          # 백업 생성(outdir는 git 밖 — 외장 SSD 등)
#   scripts/backup-local-asset.sh --verify <outdir> # 최신 백업이 현재 런북 셋을 담는지(신선도 게이트)
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/runbooks"

verify=0
if [ "${1:-}" = "--verify" ]; then verify=1; shift; fi
outdir="${1:?usage: backup-local-asset.sh [--verify] <outdir(git 밖)>}"
mkdir -p "$outdir"; outdir="$(cd "$outdir" && pwd)"

if (cd "$outdir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  echo "ERROR: outdir($outdir)가 git 작업트리 안이다 — 레포 밖에 보관하라" >&2; exit 1
fi
{ [ -d "$SRC" ] && ls "$SRC"/*.md >/dev/null 2>&1; } || { echo "ERROR: 런북 부재($SRC) — owner 머신에서만 실행" >&2; exit 1; }
cd "$ROOT"

# 파일명은 runbooks.<epoch>.enc.tar로 통제 — ls 정렬 안전
# shellcheck disable=SC2012
latest_backup() { ls -1 "$outdir"/runbooks.*.enc.tar 2>/dev/null | sort | tail -1; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
# 내용 인지 매니페스트(codex pass3 P3-3): '<sha256> <파일명>'. 파일명 셋 비교만으로는
# 내용만 바뀐 stale 백업이 OK 통과한다 — 신선도 게이트가 무력해지는 구멍.
src_hash_manifest() { (cd "$SRC" && for f in *.md; do printf '%s %s\n' "$(sha256 "$f" | awk '{print $1}')" "$f"; done | sort -k2); }

if [ "$verify" -eq 1 ]; then
  latest="$(latest_backup)"; [ -n "$latest" ] || { echo "ERROR: 백업 없음 — 먼저 생성하라" >&2; exit 1; }
  tmpv="$(mktemp -d)"; trap 'rm -rf "$tmpv"' EXIT
  sops -d --input-type binary --output-type binary "$latest" | tar -xf - -C "$tmpv"
  [ -f "$tmpv/runbooks.sha256" ] || { echo "ERROR: 백업에 매니페스트(runbooks.sha256) 부재 — 구형/불완전 백업. 재생성하라." >&2; exit 1; }
  if [ "$(src_hash_manifest)" != "$(sort -k2 "$tmpv/runbooks.sha256")" ]; then
    echo "ERROR: 런북 드리프트(파일명+내용 sha256) — 최신 백업($latest)이 현재 런북과 불일치. 재생성하라." >&2; exit 1
  fi
  echo "OK: 최신 백업($latest)이 현재 런북과 일치(파일명+내용 sha256 대조)"; exit 0
fi

# ⚠️ 기존 백업 truncate 금지: 임시파일에 쓰고 복호 검증 후에만 버전드 rename.
tmp="$(mktemp "$outdir/runbooks.tmp.XXXXXX")"; stage="$(mktemp -d)"; trap 'rm -f "$tmp"; rm -rf "$stage"' EXIT
# 매니페스트 동봉(P3-3): 스테이징에 runbooks.sha256('<sha> <파일명>')을 넣어 --verify가 내용 대조 가능하게.
cp -a "$ROOT/docs/runbooks" "$stage/runbooks"
src_hash_manifest > "$stage/runbooks.sha256"
# --filename-override runbooks.enc.yaml: .sops.yaml catch-all(*.enc.yaml, age 2-recipient) 규칙으로 recipient
# 선택(backup-sealed-secrets-key.sh와 동일 패턴). binary라 encrypted_regex 무시, 전체를 불투명 blob 암호화.
tar -cf - -C "$stage" runbooks runbooks.sha256 \
  | sops --encrypt --filename-override runbooks.enc.yaml --input-type binary --output-type binary /dev/stdin > "$tmp"
# 복구 검증(평문 메모리만): 실제 복호되고 tar가 온전한지
sops -d --input-type binary --output-type binary "$tmp" | tar -tf - >/dev/null
dest="$outdir/runbooks.$(date +%s).enc.tar"
mv -f "$tmp" "$dest"; trap - EXIT
echo "OK: $dest (기존 백업 보존 — 버전드, git 밖 보관)"
