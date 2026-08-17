#!/usr/bin/env bats
load test_helper

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all required versions are pinned and non-empty" {
  [ -n "$K3S_VERSION" ]
  [ -n "$LOCAL_PATH_PROVISIONER_VERSION" ]
  [ -n "$LOCAL_PATH_HELPER_IMAGE" ]
  # 베어메탈 호스트 좌표 — 없으면 k3s가 잘못된 주소/SAN으로 설치된다(사후 교정이 비싸다).
  [ -n "$K3S_NODE_IP" ]
  [ -n "$K3S_TLS_SANS" ]
}

@test "k3s version is a pinned channel tag, not 'stable' or 'latest'" {
  case "$K3S_VERSION" in v1.*) ;; *) false ;; esac
  case "$K3S_VERSION" in *latest*) false ;; *) true ;; esac
  [[ "$K3S_VERSION" != stable ]]
}

@test "helper pod image is pinned by immutable digest" {
  # ⚠️ 이 테스트의 옛 이름은 "arch-pinned to arm64"였고 versions.env 주석도 그렇게 주장했지만
  #    **둘 다 거짓이었다** — 이 digest는 amd64를 포함한 9플랫폼 인덱스다(실측:
  #    `docker buildx imagetools inspect busybox:1.38@sha256:fd8d9aa6…` → amd64·arm64·arm/v5·v6·v7·
  #    386·ppc64le·riscv64·s390x). 검사한 적 없는 보장을 이름으로 주장하면 다음 사람이 그것을 믿는다.
  #    실제 계약은 **불변 digest 핀** 하나다. arch 중립인 것은 NUC(amd64) 이전에 오히려 필요한 성질이다.
  case "$LOCAL_PATH_HELPER_IMAGE" in *busybox*) ;; *) false ;; esac
  # digest(@sha256)로 고정돼 있어야 한다 — 떠다니는 태그는 cattle 재구축을 깨뜨린다.
  # `[[ ]]` 대신 평범한 명령을 쓴다(중간 `[[ `는 errexit 면제로 침묵 통과 — check-bats-style.sh:3).
  printf '%s' "$LOCAL_PATH_HELPER_IMAGE" | grep -qF '@sha256:'
}
