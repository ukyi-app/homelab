#!/usr/bin/env bats
# R2 아카이브 리셋 도구(④)의 안전 불변식을 오프라인에서 강제한다 — 실제 R2 삭제 없이.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일(`$sh`)이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」 ③·③-a
sh=scripts/reset-pg-r2-archive.sh

@test "reset-pg-r2-archive exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "reset is dry-run by default and requires --purge to actually delete (destructive guard)" {
  grep -q -- '--purge' "$sh"
  grep -qi 'dry-run' "$sh"
  grep -q 'rclone purge' "$sh"
  # ⚠️ 위 세 줄은 **토큰 실재**만 잰다 — 기본값이 파괴로 뒤집혀도(`purge=0`→`purge=1`) 전건 초록이었다
  #    (2026-09-03 뮤테이션 실측: 8/8 ok). 이름이 약속한 「dry-run 기본」의 형태 증인을 아래에 건다.
  # ⚠️ `^` 앵커가 필수다 — 이 스크립트의 헤더 주석(:7·:15-17)이 --purge·dry-run 규약을 **설명하느라**
  #    담고 있어서, 앵커 없는 grep은 자기 주석에 걸린다(이 파일 @test 6이 이미 밟은 클래스).
  grep -qE '^purge=0$' "$sh"                      # 기본값이 dry-run
  grep -qE '^if \[ "\$purge" -eq 0 \]; then$' "$sh"  # 그 기본값이 실제 분기 조건이다
}

@test "reset DERIVES the archive serverName from the live Cluster (never hardcodes it)" {
  # ⚠️ 예전 단언은 `grep -q 'SERVER=pg'`였다 — 앵커가 없어 `SERVER=pg-nuc`도 substring으로 통과하는
  #    **거짓 초록**이었고, 동시에 올바른 수정(하드코딩 제거)을 red로 만들어 옳은 방향을 막고 있었다.
  # ⚠️ 하드코딩이 위험한 이유: bucket/endpoint는 라이브에서 파생되므로 NUC에서 실행해도 **같은 버킷**을
  #    가리킨다. serverName만 박혀 있으면 NUC에서 `--purge`가 라이브 Mac의 prefix를 지운다.
  #    R2에 버저닝이 없어(infra/cloudflare/r2.tf) 되돌릴 수 없다.
  grep -q 'parameters.serverName' "$sh"
  grep -q 'get cluster' "$sh"
  # 파생 실패 시 fail-closed — 어느 prefix를 지울지 모른 채 진행하면 안 된다.
  grep -q '어느 prefix를 지울지 알 수 없으므로 중단' "$sh"
  # 리터럴 대입이 남아 있으면 안 된다(`SERVER=pg`·`SERVER="pg"` 등, 파생 대입은 `SERVER="$(`).
  # 양성 대조: 위 파생 단언들이 같은 피연산자(`$sh`)의 실재를 증언한다.
  run grep -nE '^[[:space:]]*SERVER=(["'"'"']?)[A-Za-z0-9_-]+\1[[:space:]]*$' "$sh"
  [ "$status" -eq 1 ]
}

@test "purging ANOTHER cluster's archive needs a second, distinct flag (PONR 1 must be deliberate)" {
  # PG_ARCHIVE_SERVER만으로는 안 열린다 — --purge-foreign이 함께 있어야 한다.
  grep -q 'PG_ARCHIVE_SERVER' "$sh"
  grep -q -- '--purge-foreign' "$sh"
  grep -q '남의 아카이브를 지우는 행위다' "$sh"
  # ⚠️ 위 세 줄도 토큰 실재뿐이다 — 인터록을 항상-참으로 바꿔도(`-eq 1`→`-ge 0`) 8/8 초록이었다.
  #    기본값 축(`purge_foreign=0`)과 비교 연산자 축(인터록)을 따로 잰다: 전자만으로는 후자를 못 잡는다.
  grep -qE '^purge_foreign=0$' "$sh"                          # 기본값은 닫힘
  grep -qE '^ *\[ "\$purge_foreign" -eq 1 \] \|\|' "$sh"       # 인터록이 실제로 -eq 1이다
}

@test "reset never purges sibling prefixes (pgdump hedge = restore path B stays offsite)" {
  grep -q 'rclone purge' "$sh"                # 양성 대조: 삭제 명령이 실재한다
  # 바로 위 양성 대조가 같은 피연산자(`$sh`)를 들어 부재 단언과 한 쌍을 이룬다.
  run grep -qE '(purge|delete).*pgdump' "$sh"
  [ "$status" -eq 1 ]
}

@test "the k8s Cluster name and the archive serverName are separate variables" {
  # 예전엔 `SERVER` 하나가 R2 prefix·파드 이름·Cluster 이름 셋을 겸직했다. NUC에서 그 겸직이 깨진다
  # (k8s Cluster는 `pg`, 아카이브는 `pg-nuc`) — 겸직이 남아 있으면 엉뚱한 파드를 exec한다.
  # ⚠️ `^[^#]*` — 이 스크립트의 헤더 주석이 옛 겸직을 **설명하느라** `${SERVER}-1`을 담고 있다.
  #    전체 줄 grep은 자기 주석에 걸려 거짓 red를 낸다(이 세션에서 세 번째로 밟은 클래스).
  grep -qE '^CLUSTER=' "$sh"
  grep -q '"${CLUSTER}-1"' "$sh"
  # 양성 대조: 위 CLUSTER 단언들이 같은 피연산자(`$sh`)의 실재를 증언한다.
  run grep -nE '^[^#]*\$\{SERVER\}-1' "$sh"
  [ "$status" -eq 1 ]
}

@test "reset derives bucket and endpoint from the live ObjectStore (not hardcoded)" {
  grep -q 'get objectstore' "$sh"
  grep -q 'destinationPath' "$sh"
  grep -q 'endpointURL' "$sh"
}

@test "reset reads R2 creds from the cnpg-r2-creds secret and skips the bucket head check" {
  grep -q 'cnpg-r2-creds' "$sh"
  grep -qiE 'no_check_bucket' "$sh"
}
