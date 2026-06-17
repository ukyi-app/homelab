#!/usr/bin/env bats
# build.yaml은 telegram-notify로 빌드 결과를 알린다(source=배포, if: always()).
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD="$ROOT/.github/workflows/build.yaml"
}

@test "build.yaml invokes the telegram-notify composite" {
  grep -q './.github/actions/telegram-notify' "$BUILD"
}

@test "build.yaml notify step runs on always() so failures are visible" {
  grep -q 'if: always()' "$BUILD"
}

@test "build.yaml notify uses the deploy source label and job.status" {
  grep -q 'source: 배포' "$BUILD"
  grep -q 'status: ' "$BUILD"
  grep -q 'job.status' "$BUILD"
}

@test "build notify source label is a member of the notify.sh enum" {
  # notify.sh enum 건초더미에 '배포'가 있어야 한다(dead label 송신 차단).
  grep -q ' 배포 ' "$ROOT/.github/actions/telegram-notify/notify.sh"
}
