#!/usr/bin/env bash
# SealedSecrets 컨트롤러 sealing key 백업 (DR 불변식).
#
# 이 키 없이는 git에 커밋된 SealedSecret을 아무도 복호화 못 한다 — 클러스터 유실 = 시크릿 유실.
# 그래서 (1) 평문 private key를 디스크에 남기지 않고(kubectl→sops 파이프 직행),
# (2) 같은 파일시스템 임시파일에 암호화 → 복호화 검증 → 원자적 rename(실패 시 직전 백업 무손상),
# (3) 버전드 보관(기존 백업 절대 truncate 금지), (4) git 작업트리 안 보관을 거부한다.
#
# 사용:
#   scripts/backup-sealed-secrets-key.sh <outdir>            # 백업 생성 (outdir는 git 밖 — 외장 SSD 등)
#   scripts/backup-sealed-secrets-key.sh --verify <outdir>   # 최신 백업이 라이브 키 셋을 담는지 (회전 게이트)
#
# 키 회전 게이트: 컨트롤러가 sealing key를 회전하면 --verify가 실패한다 → 백업 재생성 +
# 복구 드릴(tests/sealed-secrets-restore.bats + 런북 restore.md)을 다시 통과해야 한다.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL='sealedsecrets.bitnami.com/sealed-secrets-key'

verify=0
if [ "${1:-}" = "--verify" ]; then verify=1; shift; fi
outdir="${1:?usage: backup-sealed-secrets-key.sh [--verify] <outdir(git 밖)>}"

mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"

# git 안 보관 금지: 암호화돼 있어도 키 백업은 레포 밖 매체(외장 SSD/패스워드 매니저)에만 둔다.
if (cd "$outdir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  echo "ERROR: outdir($outdir)가 git 작업트리 안이다 — 레포 밖에 보관하라" >&2
  exit 1
fi

# .sops.yaml(catch-all *.enc.yaml 규칙, age 2-recipient) 매칭은 레포 루트 기준
cd "$ROOT"

# 파일명은 ss-keys.<epoch>.enc.yaml로 통제돼 비알파뉴메릭 위험 없음 — ls가 의도된 정렬 선택
# shellcheck disable=SC2012
latest_backup() { ls -1 "$outdir"/ss-keys.*.enc.yaml 2>/dev/null | sort | tail -1; }
live_keys() {
  kubectl -n sealed-secrets get secret -l "$LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

if [ "$verify" -eq 1 ]; then
  latest="$(latest_backup)"
  [ -n "$latest" ] || { echo "ERROR: 백업 없음 — 먼저 백업을 생성하라" >&2; exit 1; }
  live="$(live_keys)"
  [ -n "$live" ] || { echo "ERROR: 라이브 sealing key 0개 — 컨트롤러/라벨 점검" >&2; exit 1; }
  backed="$(sops -d --input-type binary --output-type binary "$latest" | grep -oE 'name: sealed-secrets-key[a-z0-9]+' | sed 's/^name: //' | sort -u)"
  if [ "$live" != "$backed" ]; then
    echo "ERROR: sealing key 회전 감지 — 라이브 키 셋과 최신 백업($latest) 불일치." >&2
    echo "       백업을 재생성하고 복구 드릴을 다시 통과하라." >&2
    exit 1
  fi
  echo "OK: 최신 백업($latest)이 라이브 sealing key 셋과 일치"
  exit 0
fi

# ⚠️ 기존 백업을 검증 전에 truncate하면 안 된다: 같은 파일시스템 임시파일에 쓰고,
#    복호화 검증을 통과한 다음에만 버전드 이름으로 rename한다.
tmp="$(mktemp "$outdir/ss-keys.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# 평문은 파이프로만 흐른다(디스크 비접촉). binary 모드로 통째 암호화한다 —
# sealing key Secret의 data 키(tls.crt/tls.key)는 점을 포함하는데, sops의 selective(yaml)
# 암호화는 점을 경로 구분자로 오해해 복호화가 깨진다(라이브 검증된 sops 함정). binary는
# 전체를 불투명 blob으로 암호화해 이 문제를 회피한다. --filename-override는 .sops.yaml
# catch-all 규칙에서 age recipient를 고르는 데 여전히 필요(encrypted_regex는 binary라 무시됨).
kubectl -n sealed-secrets get secret -l "$LABEL" -o yaml \
  | sops --encrypt --filename-override ss-keys.enc.yaml \
      --input-type binary --output-type binary /dev/stdin > "$tmp"

# 복구 검증(평문은 메모리만): 실제로 복호화되고 Secret을 담는지 — 키 0개(빈 List)도 여기서 거른다
sops -d --input-type binary --output-type binary "$tmp" | grep -q "kind: Secret"

dest="$outdir/ss-keys.$(date +%s).enc.yaml"
mv -f "$tmp" "$dest"
trap - EXIT
echo "OK: $dest (기존 백업 보존 — 버전드, git 밖 보관)"
