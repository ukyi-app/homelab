#!/usr/bin/env bats
# seed-secrets.sh heredoc 산출물 metadata(name/namespace) ↔ 커밋본 *.enc.yaml 평문 metadata 정합 가드.
# 컴포넌트 ns 이동(#102 tailscale 분리 등) 시 seed 스크립트 미동기 → 재시드/DR에서 구 ns로
# 재생성되는 클래스(M3)를 정적으로 차단한다. sops는 metadata를 암호화하지 않으므로 age 키 불필요(CI-safe).
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

sh=scripts/seed-secrets.sh

# write_enc 블록 파서: "path<TAB>name<TAB>namespace" 행 출력 (heredoc 내 첫 name:/namespace:만 — metadata가 최상단)
seed_blocks() {
  awk '
    $1 == "write_enc" && $3 == "<<EOF" { path = $2; inblk = 1; n = ""; ns = ""; next }
    inblk && $1 == "EOF"               { print path "\t" n "\t" ns; inblk = 0; next }
    inblk && $1 == "name:"      && n  == "" { n  = $2 }
    inblk && $1 == "namespace:" && ns == "" { ns = $2 }
  ' "$sh"
}

@test "seed_blocks parser extracts every write_enc heredoc target (>=8, includes operator-oauth)" {
  run seed_blocks
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -ge 8 ]   # 파서 자체가 빈 결과로 침묵 통과하는 것 방지
  echo "$output" | grep -q "platform/tailscale/prod/operator-oauth.enc.yaml"
}

@test "every seed heredoc target matches the committed enc.yaml metadata (name and namespace)" {
  count=0
  while IFS=$'\t' read -r path name ns; do
    count=$((count + 1))
    [ -f "$path" ]   # enc 커밋본은 DR SSOT — seed 블록만 있고 커밋본이 없으면 fail-closed
    committed_name=$(awk '$1 == "name:"      { print $2; exit }' "$path")
    committed_ns=$(awk   '$1 == "namespace:" { print $2; exit }' "$path")
    [ "$name" = "$committed_name" ]
    [ "$ns" = "$committed_ns" ]
  done < <(seed_blocks)
  [ "$count" -ge 8 ]
}
