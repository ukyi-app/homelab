#!/usr/bin/env bats
load test_helper

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all required versions are pinned and non-empty" {
  [ -n "$K3S_VERSION" ]
  [ -n "$LOCAL_PATH_PROVISIONER_VERSION" ]
  [ -n "$LOCAL_PATH_PROVISIONER_IMAGE" ]
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

@test "the node-subnet allow sites carry the /24 derived from K3S_NODE_IP" {
  # SSOT(versions.env)와 platform 리터럴을 대조하는 실행 로스터가 0건이었다 — 산문 로스터만
  # 네 곳에서 반복됐다(versions.env · verify-cluster.sh · assert-cluster-identity.sh ·
  # platform/argocd/test_argocd_values.bats). 핀과 라이브를 **함께** 옮긴 커밋은
  # verify-cluster.sh [7]도 통과하므로, 정적 전건 초록 뒤에 6개 컴포넌트가 apiserver egress를
  # 잃는다(NetworkPolicy egress는 ClusterIP가 아니라 노드 CIDR:6443이라 우회로가 없다).
  # ⚠️ **파일 이름으로** 잠근다 — `git grep … | wc -l >= 6` 수치 바닥값은 test_11의
  #    "개수가 아니라 파일 이름으로 잠근다 — 손 관리 수치 금지"와 충돌한다. 루프도 쓰지 않는다
  #    (목록이 비면 반복 0회가 초록이 된다 — 열거 붕괴).
  # ⚠️ needle은 키 없이 **CIDR만**이다. sealed-secrets의 키는 `kubeapiCidr:`라
  #    `cidr: $p` 형태로 잠그면 그 파일에서 영구 red다.
  # 각 매니페스트의 값 ↔ 렌더 결합은 컴포넌트 자기 bats가 이미 잠근다 — 여기서 SSOT ↔ 매니페스트
  # 한 축만 더하면 전이적으로 닫힌다.
  p="${K3S_NODE_IP%.*}.0/24"
  printf '%s' "$p" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.0/24$'   # 양성 대조: 파생이 실제로 돌았다
  R="$(cd "$BOOTSTRAP_DIR/../.." && pwd)"
  grep -qF -- "$p" "$R/platform/adguard/prod/rewrite-reconciler.yaml"
  grep -qF -- "$p" "$R/platform/argocd/bootstrap-values.yaml"
  grep -qF -- "$p" "$R/platform/tailscale/prod/networkpolicy.yaml"
  grep -qF -- "$p" "$R/platform/cert-manager-netpol/prod/networkpolicy.yaml"
  grep -qF -- "$p" "$R/platform/homepage/prod/networkpolicy.yaml"
  grep -qF -- "$p" "$R/platform/sealed-secrets/prod/values-sealed-secrets.yaml"
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

@test "provisioner image is pinned by immutable digest and its tag equals LOCAL_PATH_PROVISIONER_VERSION" {
  # 티켓 60 prov-1~2 — digest 소유자 승격(헬퍼와 같은 형태, 위 @test 형제). 매니페스트는 이제
  # ${LOCAL_PATH_PROVISIONER_IMAGE} 플레이스홀더뿐이라(렌더 결과 검사는 test_07-apply-storage.bats)
  # 여기서는 SSOT 두 값의 계약만 잰다.
  # ⚠️ 태그 소유자(이 변수, freshness·github-releases)와 digest 소유자(LOCAL_PATH_PROVISIONER_IMAGE,
  #    docker datasource)는 renovate.json의 서로 다른 customManager다 — 별도 PR로 부분 머지되면
  #    태그가 갈린다. 아래 등식이 그 갈림을 잡는다(tests/gates/test_vmalert-config.bats도 같은 축을 잰다).
  case "$LOCAL_PATH_PROVISIONER_IMAGE" in rancher/local-path-provisioner:*) ;; *) false ;; esac
  printf '%s' "$LOCAL_PATH_PROVISIONER_IMAGE" | grep -qF '@sha256:'
  tag="${LOCAL_PATH_PROVISIONER_IMAGE#*:}"; tag="${tag%%@*}"
  [ "$tag" = "$LOCAL_PATH_PROVISIONER_VERSION" ]
}
