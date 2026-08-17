#!/usr/bin/env bats
# Valkey 캐시 백업의 R2 경로 계약. 이 파일이 생긴 이유는 계획서 §3.4가 **캐시를 아예 열거하지
# 않았고**, 그래서 병행 운용 중 라이브 데이터를 지우는 경로가 무방비였기 때문이다.
f=platform/cache/prod/backup-cronjob.yaml

@test "cache backup writes a CLUSTER-SPECIFIC R2 prefix (last_success.json is a FIXED key)" {
  # ⚠️ `last_success.json`은 고정 키다 — prefix를 공유하면 두 클러스터가 같은 객체를 덮어쓴다.
  #    그 파일은 `teardown-resource --delete-data`의 **파괴 게이트 입력**이라, 라이브의 신선도 메타가
  #    NUC 값으로 바뀌면 라이브 백업이 실제로 낡았는데도 파괴가 통과한다.
  grep -qE '^[^#]*CACHE_PREFIX=' "$f"
  grep -q 'homelab-cache-backups-prod/nuc' "$f"
  grep -q '${CACHE_PREFIX}/${name}/last_success.json' "$f"
}

@test "the 14d prune targets only this cluster's prefix" {
  grep -qE 'rclone delete "\$\{CACHE_PREFIX\}/\$\{name\}/rdb/" --min-age 14d' "$f"
  # 공유 prefix 직접 참조가 남아 있으면 red (비-주석 줄만 — 주석이 옛 경로를 설명한다)
  run grep -nE '^[^#]*"r2:homelab-cache-backups-prod/\$\{name\}' "$f"
  [ "$status" -ne 0 ]
}

@test "the roundtrip integrity check re-READS the uploaded copy (not just any sha256 variable)" {
  # prefix를 옮기면서 무결성 검사를 같이 잃기 쉽다 — 그 회귀를 여기서 막는다.
  # ⚠️ `grep -q REMOTE_SHA` + `grep -q sha256sum`만으로는 부족하다: `REMOTE_SHA="$SHA"`로 바꿔
  #    검사를 공허하게 만들어도 두 단언이 다 통과한다(뮤테이션으로 실측 — 처음 작성했을 때 그랬다).
  #    불변식은 "원격 사본을 **되읽어** 해시한다"이므로 그 파이프라인 자체를 단언한다.
  grep -qE 'REMOTE_SHA="\$\(rclone cat .*\| *sha256sum' "$f"
  grep -q '업로드 사본 sha256 불일치' "$f"
  # 로컬 원본과 대조하는 분기가 실재한다
  grep -qE 'if \[ "\$REMOTE_SHA" != "\$SHA" \]' "$f"
}
