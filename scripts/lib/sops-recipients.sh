# shellcheck shell=bash
# SOPS recipient 추출 SSOT — sops-guard.sh·verify-secrets.sh 공유(canonical↔파일 recipient 신원 검증 일원화).
# source 전용(top-level 실행 없음). yq만 필요(age 키 불요). 두 소비자의 바이트-동형 중복을 제거해
# 한쪽만 하드닝될 때의 드리프트(DR 복호 불능 가드가 갈라짐)를 차단한다.
sops_yaml_path() {
  local p
  p="$(git rev-parse --show-toplevel 2>/dev/null)/.sops.yaml"
  [ -f "$p" ] || p=".sops.yaml"
  printf '%s' "$p"
}
# canonical: .sops.yaml의 _recipients 앵커(cluster+recovery 공개키 집합).
sops_canonical_recipients() { yq '._recipients[]' "$(sops_yaml_path)" 2>/dev/null | sort; }
# 파일별: 대상 *.enc.yaml의 sops.age[].recipient.
sops_file_recipients() { yq '.sops.age[].recipient' "$1" 2>/dev/null | sort; }
