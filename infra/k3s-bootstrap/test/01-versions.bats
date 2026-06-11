#!/usr/bin/env bats
load test_helper

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all required versions are pinned and non-empty" {
  [ -n "$K3S_VERSION" ]
  [ -n "$DEBIAN_RELEASE" ]
  [ -n "$LOCAL_PATH_PROVISIONER_VERSION" ]
  [ -n "$LOCAL_PATH_HELPER_IMAGE" ]
}

@test "k3s version is a pinned channel tag, not 'stable' or 'latest'" {
  [[ "$K3S_VERSION" == v1.* ]]
  [[ "$K3S_VERSION" != *latest* ]]
  [[ "$K3S_VERSION" != stable ]]
}

@test "helper pod image is arch-pinned to arm64 by digest or arm64 tag" {
  [[ "$LOCAL_PATH_HELPER_IMAGE" == *busybox* ]]
  # digest(@sha256)로 고정돼 있어야 한다 — 떠다니는 태그는 cattle 재구축을 깨뜨린다.
  [[ "$LOCAL_PATH_HELPER_IMAGE" == *@sha256:* ]]
}
