#!/usr/bin/env bats
# seed-secrets.sh heredoc 산출물 ↔ 커밋본 *.enc.yaml 평문 정합 가드 — metadata(name/namespace) + stringData 키 집합.
# 컴포넌트 ns 이동(#102 tailscale 분리 등) 시 seed 스크립트 미동기 → 재시드/DR에서 구 ns로
# 재생성되는 클래스(M3)를 정적으로 차단한다. sops는 metadata·키 이름을 암호화하지 않으므로 age 키 불필요(CI-safe).
# ⚠️ **키 집합 축도 같은 재시드 경로다** — write_enc는 경로를 통째로 덮어쓰므로 드리프트가 양방향이다:
#    seed에서 키가 빠지면 재시드가 커밋본에서 그 키를 지우고(예: alerting-secrets의 GRAFANA_ADMIN_PASSWORD가
#    사라지면 grafana.yaml:30의 secretKeyRef가 CreateContainerConfigError), make secret-edit으로 키를
#    늘리면 다음 재시드가 그것을 되돌린다. 2026-09-03까지 이 축에 게이트가 0건이었다(뮤테이션 실측: 2/2 ok).
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

sh=scripts/seed-secrets.sh

# write_enc 블록 파서: "path<TAB>name<TAB>namespace<TAB>키 집합" 행 출력
# (heredoc 내 첫 name:/namespace:만 — metadata가 최상단. 키는 stringData: 이후 구간에서만 모은다.)
# ⚠️ 키 술어를 대문자 전용(^[A-Z0-9_]+:$)으로 좁히면 안 된다 — 8블록 중 4개가 소문자 키다(tunnel token,
#    operator-oauth client_id/client_secret, app-credentials username/password,
#    cloudflare-api-token api-token). 좁히면 그 절반이 빈 집합끼리 비교돼 vacuous green이 된다
#    (docs/traps-detail.md 「열거 붕괴 → vacuous green」).
#    heredoc의 # 주석 줄(r2-creds·cache-r2-creds에 실재)은 $1이 #로 시작해 술어에서 자동으로 빠진다.
seed_blocks() {
  awk '
    $1 == "write_enc" && $3 == "<<EOF" { path = $2; inblk = 1; n = ""; ns = ""; keys = ""; ink = 0; next }
    inblk && $1 == "EOF"               { print path "\t" n "\t" ns "\t" keys; inblk = 0; ink = 0; next }
    inblk && $1 == "name:"      && n  == "" { n  = $2 }
    inblk && $1 == "namespace:" && ns == "" { ns = $2 }
    inblk && $1 == "stringData:"            { ink = 1; next }
    ink && $1 ~ /^[A-Za-z0-9_.-]+:$/ {
      k = substr($1, 1, length($1) - 1)
      keys = keys (keys == "" ? "" : " ") k
    }
  ' "$sh"
}

# 커밋본(enc.yaml)의 stringData 키 집합. sops는 키 이름과 **순서**를 보존하므로 정렬 없이 문자열 동등 비교로 충분하다.
# ⚠️ sops footer에서 수집을 끊는 것이 필수다 — 안 끊으면 mac:·lastmodified:·recipient: 같은
#    sops 메타가 같은 술어에 걸린다(대문자만 모으던 판이 우연히 가려주던 자리다).
committed_keys() {
  awk '
    $1 == "stringData:" { i = 1; next }
    i && /^[^ ]/        { i = 0 }
    i && $1 ~ /^[A-Za-z0-9_.-]+:$/ {
      k = substr($1, 1, length($1) - 1)
      s = s (s == "" ? "" : " ") k
    }
    END { print s }
  ' "$1"
}

@test "seed_blocks parser extracts every write_enc heredoc target (>=8, includes operator-oauth)" {
  run seed_blocks
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -ge 8 ]   # 파서 자체가 빈 결과로 침묵 통과하는 것 방지
  echo "$output" | grep -q "platform/tailscale/prod/operator-oauth.enc.yaml"
}

@test "every seed heredoc target matches the committed enc.yaml metadata and stringData key set" {
  count=0
  while IFS=$'\t' read -r path name ns keys; do
    count=$((count + 1))
    [ -f "$path" ]   # enc 커밋본은 DR SSOT — seed 블록만 있고 커밋본이 없으면 fail-closed
    committed_name=$(awk '$1 == "name:"      { print $2; exit }' "$path")
    committed_ns=$(awk   '$1 == "namespace:" { print $2; exit }' "$path")
    [ "$name" = "$committed_name" ]
    [ "$ns" = "$committed_ns" ]
    # 블록별 비공허 바닥값 — 파서가 붕괴하면 양쪽이 빈 집합끼리 일치해 조용히 초록이 된다.
    [ -n "$keys" ]
    committed_k=$(committed_keys "$path")
    [ -n "$committed_k" ]
    # 진단은 키 **이름**만 찍는다(값은 절대 출력하지 않는다).
    echo "seed[$path]=$keys"
    echo "enc [$path]=$committed_k"
    [ "$keys" = "$committed_k" ]
  done < <(seed_blocks)
  [ "$count" -ge 8 ]
}
