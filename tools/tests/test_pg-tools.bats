#!/usr/bin/env bats
DF="ops/pg-tools/Dockerfile"

@test "pg-tools Dockerfile installs kubectl, psql(18), rclone, curl" {
  run grep -iE 'kubectl' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'postgresql-client-18' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'rclone' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'curl' "$DF"; [ "$status" -eq 0 ]
}

@test "pg-tools kubectl pin equals the k3s release pin in versions.env (no floating channel)" {
  # kubectl은 독립 freshness 소유자를 갖지 않는다 — versions.env의 K3S_VERSION에서 `+k3sN`을 뗀 값이
  # SSOT다. 갈리면 이미지의 kubectl이 서버 minor와 표류하고(±1 정책), 부동 채널로 돌아가면 같은
  # 커밋의 두 빌드가 다른 바이너리를 담는다(restore-drill 8/22·8/25 실사고).
  # ⚠️ versions.env 파생은 **리더를 지난다**(infra/k3s-bootstrap/versions-read.sh). 옛 sed 한 줄은
  #    파일 부재·키 부재·줄 포맷 변경을 전부 빈 문자열로 접어 이 등식을 공허하게 만든다.
  VR="infra/k3s-bootstrap/versions-read.sh"
  [ -x "$VR" ]
  k3s="$("$VR" K3S_VERSION)"
  [ -n "$k3s" ]
  pin="$(grep -oE '^ARG KUBECTL_VERSION=v[0-9.]+' "$DF" | cut -d= -f2)"
  [ -n "$pin" ]
  [ "${k3s%%+k3s*}" = "$pin" ]
  # 부동 참조 재발 차단(파일 피연산자 — 정확한 무매치는 rc 1이다).
  # `^[^#]*`로 주석 줄을 판정 밖에 둔다 — 부동 채널을 **설명한** 주석이 자기 가드를 red로 만들면
  # 다음 사람이 근거를 지우게 된다(가드가 자기 도메인의 표기법에 눈멀지 않도록 코드 줄만 본다).
  run grep -nE '^[^#]*release/stable\.txt' "$DF"; [ "$status" -eq 1 ]
  run grep -nE '^[^#]*rclone-current' "$DF"; [ "$status" -eq 1 ]
}

@test "pg-tools is in the CI build matrix (canonical 18-rclone tag)" {
  run yq '.jobs.build.strategy.matrix.app' .github/workflows/build.yaml
  [[ "$output" == *"pg-tools"* ]]
}
