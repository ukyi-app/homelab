#!/usr/bin/env bats
# 이미지 digest 핀 2-레인 체커(메타갭 ② W2-B) 픽스처 테스트 (a)-(e) + scan-floor + 비-컨테이너 경로.
# 실-레포 통과 단언 (f)는 Task 9(핀 적용 후)에서 추가 — Task 8은 픽스처만(중간 CI 파손 방지).
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩), 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 침묵통과).
# tmp git 레포 픽스처 패턴(체커가 git ls-files 사용 — staged면 충분, commit 불요).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CHK="$ROOT/scripts/check-image-pins.sh"
  command -v git >/dev/null || skip "git required"
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name tester
}
teardown() { rm -rf "$REPO"; }

# wf <path> ; 내용은 stdin(here-doc). mkdir -p + git add(staged면 ls-files에 뜬다).
wf() { mkdir -p "$REPO/$(dirname "$1")"; cat > "$REPO/$1"; git -C "$REPO" add -A; }

@test "(a) lane1 flags a tag-only string image and names the file" {
  wf platform/x/deployment.yaml <<'EOF'
spec:
  containers:
    - image: nginx:1.25
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'platform/x/deployment.yaml'
  echo "$output" | grep -q 'nginx:1.25'
}

@test "(b) lane1 passes a digest-pinned string image" {
  wf platform/x/deployment.yaml <<'EOF'
spec:
  containers:
    - image: nginx:1.25@sha256:abcdef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
}

@test "(c) lane2 flags apps values image struct without a digest" {
  wf apps/myapp/deploy/prod/values.yaml <<'EOF'
image:
  repo: ghcr.io/x/y
  tag: v1
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'lane2'
}

@test "(c) lane2 passes apps values image struct with a digest" {
  wf apps/myapp/deploy/prod/values.yaml <<'EOF'
image:
  repo: ghcr.io/x/y
  tag: v1
  digest: sha256:abcdef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
}

@test "(d) fixtures(+fixtures-bad) and vendor paths are excluded (tag-only ignored)" {
  wf platform/ok/deployment.yaml <<'EOF'
image: nginx:1.0@sha256:abcdef
EOF
  wf platform/charts/app/tests/fixtures/web.yaml <<'EOF'
image: foo:1.0
EOF
  wf platform/charts/app/tests/fixtures-bad/caps.yaml <<'EOF'
image: bar:1.0
EOF
  wf platform/cnpg/barman-plugin/manifest.yaml <<'EOF'
image: baz:1.0
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
  # 제외가 동작하면 tag-only 3개는 UNPINNED로 안 잡힌다(부정 단언 — 마지막 줄).
  [ -z "$(echo "$output" | grep 'UNPINNED' || true)" ]
}

@test "(e) allowlist exempts a listed image" {
  wf platform/x/deployment.yaml <<'EOF'
image: nginx:1.25
EOF
  printf '# reason: 상류가 이미 digest 고정\nnginx:1.25\n' > "$REPO/allow.txt"
  run bash "$CHK" --root "$REPO" --min-scan 1 --allowlist "$REPO/allow.txt"
  [ "$status" -eq 0 ]
}

@test "scan-floor fails loud (exit 2) when the scan finds too few images" {
  wf platform/x/deployment.yaml <<'EOF'
image: nginx:1.0@sha256:abcdef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 99
  [ "$status" -eq 2 ]
}

@test "non-container image path (leading slash) is not treated as a registry ref" {
  wf platform/homepage/config/settings.yaml <<'EOF'
image: /images/background.jpg
EOF
  wf platform/ok/deployment.yaml <<'EOF'
image: nginx:1.0@sha256:abcdef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | grep 'background' || true)" ]
}

@test "lane1 scans imageName: (CNPG Cluster DB image), not just image:" {
  # 적대 리뷰 HIGH: imageName은 CNPG Cluster CR의 DB 본체 런타임 이미지 — 반드시 핀 검사 대상.
  wf platform/cnpg/prod/cluster.yaml <<'EOF'
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'postgresql:18.4'
}

@test "lane1 does not bypass a quoted tag-only image" {
  # 적대 리뷰 HIGH: image: \"nginx:1.25\"(따옴표)가 게이트를 우회하면 안 된다.
  wf platform/x/deployment.yaml <<'EOF'
containers:
  - image: "nginx:1.25"
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'nginx:1.25'
}

@test "lane1 does not false-positive on suffixed keys like logo_image/bg_image" {
  # 적대 리뷰 MED: 앵커된 키 매칭 — logo_image:/bg_image: 설정값은 컨테이너 이미지가 아니다.
  wf platform/y/config.yaml <<'EOF'
settings:
  logo_image: gravatar
  bg_image: default
EOF
  wf platform/ok/deployment.yaml <<'EOF'
image: nginx:1.0@sha256:abcdef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | grep -E 'gravatar|default' || true)" ]
}

@test "lane1 does not truncate a repo path that contains the substring image" {
  # 적대 리뷰 MED: greedy sed가 ghcr.io/foo/my-image:v1를 v1로 절단하면 안 된다(라벨·allowlist 파손).
  wf platform/z/deployment.yaml <<'EOF'
containers:
  - image: ghcr.io/foo/my-image:v1
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'ghcr.io/foo/my-image:v1'
  [ -z "$(echo "$output" | grep -E '— v1$' || true)" ]
}

@test "allowlist entry without a reason comment fails loud (exit 2)" {
  # 적대 리뷰 MED: 사유 주석 강제 — 무단 면제 방지.
  wf platform/x/deployment.yaml <<'EOF'
image: nginx:1.25
EOF
  printf 'nginx:1.25\n' > "$REPO/allow.txt"   # 사유 주석 없음
  run bash "$CHK" --root "$REPO" --min-scan 1 --allowlist "$REPO/allow.txt"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q '사유 주석'
}

@test "lane2 digest must be inside the image block (not anywhere in the file)" {
  # 적대 리뷰 LOW: 파일 전역 digest grep 회피 방지 — 블록 밖 digest는 무효.
  wf apps/myapp/deploy/prod/values.yaml <<'EOF'
image:
  repo: ghcr.io/x/y
  tag: v1
someOtherField:
  digest: sha256:deadbeef
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'lane2'
}

@test "(f) real repo passes — all runtime images digest-pinned (default scan-floor, Task 9)" {
  # Task 9: 24 tag-only 이미지 수동 핀 적용 후 실 레포가 allowlist 0으로 통과(기본 min-scan=20 scan-floor 유효).
  run bash "$ROOT/scripts/check-image-pins.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '전부 digest 핀됨'
}

@test "lane2 flow-style image without digest is flagged; with digest passes" {
  # 적대 리뷰 LOW: flow-style image: {repo,tag} 도 digest 강제(계약 완결).
  wf apps/flowbad/deploy/prod/values.yaml <<'EOF'
image: { repo: ghcr.io/x/y, tag: v1 }
EOF
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'lane2-flow'
  wf apps/flowgood/deploy/prod/values.yaml <<'EOF'
image: { repo: ghcr.io/x/y, tag: v1, digest: sha256:abc }
EOF
  # flowbad 제거 후 flowgood만 → 통과
  rm -rf "$REPO/apps/flowbad"; git -C "$REPO" add -A
  run bash "$CHK" --root "$REPO" --min-scan 1
  [ "$status" -eq 0 ]
}
