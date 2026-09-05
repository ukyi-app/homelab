#!/usr/bin/env bats
# `cache`(Valkey) 컴포넌트의 CI-safe 정적 검증 — 원본 yaml을 직접 읽는다(kustomize build 불요).
# 전체 KSOPS 렌더(cache-r2-creds 복호)는 age 키 의존이라 test_ksops_render.bats(.ci-exclude)가 담당한다.
# 주의: macOS bash 3.2에서 mid-test `[[ ]]`/`! cmd` 실패는 bats가 못 잡는다 —
# 단언은 전부 grep 파이프라인/`[ ]`/카운트 비교로 쓴다.

DIR="${BATS_TEST_DIRNAME}"
ROOT="$(cd "$DIR/../../.." && pwd)"
NP="$DIR/networkpolicy.yaml"
CJ="$DIR/backup-cronjob.yaml"

@test "cache namespace is default-deny in BOTH directions with no pod-CIDR ipBlock" {
  policy="$(yq 'select(.metadata.name=="cache-default-deny-all")' "$NP")"
  [ "$(echo "$policy" | yq '.spec.podSelector | length')" -eq 0 ]   # {} = 모든 pod
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Ingress
  echo "$policy" | yq -e '.spec.policyTypes' | grep -q Egress
  # ⚠️ 10.42.0.0/16(pod CIDR)을 ipBlock cidr로 쓰면 "전체 파드 허용" — default-deny 무력화(라이브 검증 함정).
  #    실제 cidr: 값만 검사(경고 주석의 10.42 언급은 제외).
  [ "$(grep -cE 'cidr:.*10\.42\.0\.0/16' "$NP")" -eq 0 ]
  # 상한 — 위 grep들은 전부 하한이라 광역 egress(0.0.0.0/0 ipBlock) 정책 한 건이 통째로
  # 통과했다(실측 2026-09-03: 12/12). 이름 정확 집합 + ipBlock 전칭으로 막는다.
  [ "$(yq ea '[select(.kind=="NetworkPolicy") | .metadata.name] | sort | join(",")' "$NP")" = \
    "cache-allow-backup-egress,cache-allow-dns-egress,cache-allow-ingress-backup,cache-allow-ingress-from-prod,cache-allow-ingress-kubelet-probes,cache-default-deny-all" ]
  [ "$(yq ea '[select(.kind=="NetworkPolicy") | .. | select(has("ipBlock")) | .ipBlock.cidr] | sort | join(",")' "$NP")" = "10.42.0.1/32" ]
}

@test "ingress allows are prod:6379, intra-ns backup:6379, and node probes only" {
  p="$(yq 'select(.metadata.name=="cache-allow-ingress-from-prod")' "$NP")"
  echo "$p" | grep -q "kubernetes.io/metadata.name: prod"
  echo "$p" | grep -q "port: 6379"
  b="$(yq 'select(.metadata.name=="cache-allow-ingress-backup")' "$NP")"
  echo "$b" | grep -q "cache-backup"
  echo "$b" | grep -q "port: 6379"
  probes="$(yq 'select(.metadata.name=="cache-allow-ingress-kubelet-probes")' "$NP")"
  echo "$probes" | grep -q "cidr: 10.42.0.1/32"   # 노드(cni0)만
}

@test "egress is DNS for all pods plus a backup-job-scoped allowance" {
  dns="$(yq 'select(.metadata.name=="cache-allow-dns-egress")' "$NP")"
  echo "$dns" | grep -q "kubernetes.io/metadata.name: kube-system"
  echo "$dns" | grep -q "k8s-app: kube-dns"
  echo "$dns" | grep -q "port: 53"
  be="$(yq 'select(.metadata.name=="cache-allow-backup-egress")' "$NP")"
  echo "$be" | grep -q "app.kubernetes.io/name: cache-backup"   # podSelector 스코프 — NS 전체가 아니다
}

@test "backup chain declares cronjob with a dedicated service account and minimal rbac" {
  grep -q "kind: CronJob" "$CJ"
  grep -q "serviceAccountName: cache-backup" "$CJ"
  grep -q "kind: Role" "$DIR/backup-rbac.yaml"
  grep -q "kind: RoleBinding" "$DIR/backup-rbac.yaml"
  # 디스커버리 조인 — CronJob의 셀렉터와 인스턴스 Service의 라벨이 어긋나면 백업이 0건 no-op으로
  # **성공**하고(Job은 Complete) r4-storage-backup의 CacheBackupStale은 완료 시각만 보므로 무성이다.
  # 실측 2026-09-03: trip-mate/service.yaml의 라벨만 valkey-cache로 바꿔도 12/12 초록이었다.
  # ⚠️ 셀렉터 추출에서 주석줄을 배제한다 — 위 :37 주석이 component=valkey를 설명하고 있다.
  sel="$(grep -oE '^[^#]*app\.kubernetes\.io/component=[a-z-]+' "$CJ" | grep -oE '=[a-z-]+$' | tr -d = | head -1)"
  [ "$sel" = valkey ]
  # 인스턴스 디렉토리 수 바닥값은 두지 않는다 — audit-orphans의 FLOOR_CONNS min:0(캐시 0개는
  # 정당)과 CronJob의 optional:true 0-인스턴스 결정을 CI-red로 만든다. 비공허 증인은 생산자
  # 쪽(tools/tests/test_provision-cache.bats)에 둔다.
  for s in "$DIR"/*/service.yaml; do
    [ -e "$s" ] || continue
    [ "$(yq '.metadata.labels."app.kubernetes.io/component"' "$s")" = "$sel" ] \
      || { echo "인스턴스 Service의 component 라벨이 CronJob 셀렉터($sel)와 다르다: $s"; false; }
    # ⚠️ 인스턴스 kustomization 멤버십 — 부모(위 :67-70)만 닫혔고 인스턴스 자신은 무증인이었다.
    #    파일명을 손 로스터로 재타이핑하지 않고 디렉토리에서 유도한다(향후 리소스 종류가 늘어도
    #    자동 커버 — tools/lib/resource-layout.ts 손 사본 금지 규약과 정합). 인스턴스 0개면 이
    #    루프 자체가 공허(형제 백업 루프와 같은 성질) — 비공허 증인은 생산자 쪽
    #    tools/tests/test_provision-cache.bats에 있다.
    d="$(dirname "$s")"; K="$d/kustomization.yaml"
    [ -f "$K" ]
    for f in "$d"/*.yaml; do
      b="$(basename "$f")"
      case "$b" in kustomization.yaml) continue ;; esac
      yq '.resources[]' "$K" | grep -qxF "$b" \
        || { echo "인스턴스 kustomization($K)에 $b 미등록 — 렌더에서 빠지면 라이브가 prune된다"; false; }
    done
  done
  # 파일 실재 ≠ 렌더 포함 — ArgoCD가 싱크하는 진실은 kustomize 렌더 결과다. 위 grep들은 전부 파일을
  # 직접 읽으므로 kustomization의 resources에서 두 줄을 지워도 초록이었다(실측 2026-09-03: 12/12).
  # prune:true·selfHeal:true라 그 삭제는 라이브에서 실제로 CronJob+RBAC을 없앤다.
  # ⚠️ 건수 바닥값(`.resources | length -ge N`)이 아니라 **멤버십**이다 — 인스턴스 디렉토리는
  #    teardown-cache로 정당하게 사라져 래칫이 오탐이 된다. 여기 두 줄은 r4-storage-backup의
  #    CacheBackupStale absent 설계가 전제하는 "상주 컴포넌트" 불변식과 같은 주장이다.
  for r in backup-cronjob.yaml backup-rbac.yaml; do
    yq '.resources[]' "$DIR/kustomization.yaml" | grep -qxF "$r" \
      || { echo "kustomization resources에 $r 가 없다 — 렌더에서 빠지면 라이브가 프룬된다"; false; }
  done
}

@test "backup r2-creds secret is optional so a no-cache cluster no-ops instead of failing" {
  # 캐시 인스턴스 0개면 cache-r2-creds 봉인이 없어도 upload 컨테이너가 CreateContainerConfigError로
  # 못 뜨지 않게 optional 유지(KubeJobFailed 노이즈 방지). cache-r2-creds가 시드된 지금도 방어적 유지.
  opt="$(yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name=="upload") | .envFrom[] | select(.secretRef.name=="cache-r2-creds") | .secretRef.optional' "$CJ")"
  [ "$opt" = "true" ]
}

@test "backup upload round-trips the RDB: re-reads the uploaded copy and re-checks sha256, not just size" {
  # size>0만으론 전송 중 절삭/비트플립을 못 잡는다 — rclone cat으로 되읽어 로컬 원본 sha256과 재대조해야 한다.
  up="$(yq 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name=="upload") | .args[0]' "$CJ")"
  echo "$up" | grep -q 'rclone cat'    # 업로드 사본 되읽기(GetObject)
  echo "$up" | grep -q 'sha256sum'     # 되읽은 사본 재해싱
  echo "$up" | grep -q 'REMOTE_SHA'    # 로컬 원본과 대조할 원격 해시
  echo "$up" | grep -q 'exit 1'        # 불일치 시 fail-loud
}

@test "cache-r2-creds is KSOPS-wired: secret-generator lists the enc file and kustomization loads it" {
  grep -q "cache-r2-creds.enc.yaml" "$DIR/secret-generator.yaml"
  grep -q "secret-generator.yaml" "$DIR/kustomization.yaml"
  # 고정 이름 유지(CronJob envFrom가 cache-r2-creds를 참조 — 해시 접미사 금지)
  grep -q "disableNameSuffixHash: true" "$DIR/kustomization.yaml"
}

@test "cache-r2-creds enc file targets ns cache with the rclone R2 key schema (encrypted)" {
  F="$DIR/cache-r2-creds.enc.yaml"
  run yq '.metadata.name' "$F"; [ "$output" = "cache-r2-creds" ]
  run yq '.metadata.namespace' "$F"; [ "$output" = "cache" ]
  # 값은 SOPS 암호화(ENC[]) — 키 이름만 검증(rclone이 읽는 정본 스키마)
  grep -q "RCLONE_CONFIG_R2_ENDPOINT" "$F"
  grep -q "RCLONE_CONFIG_R2_ACCESS_KEY_ID" "$F"
  grep -q "sops:" "$F"  # 암호화됨
}

@test "prod namespace opens egress to cache:6379 and namespaces owns the cache namespace" {
  grep -q "allow-egress-to-cache" "$ROOT/platform/network-policies/prod/networkpolicies.yaml"
  grep -q "name: cache" "$ROOT/platform/namespaces/prod/namespaces.yaml"
}

@test "instance deployment.yaml pins container hardening + probes (values, not just presence)" {
  # spec-others-4(round8) — trip-mate/deployment.yaml은 provision-cache.ts 산출물이지만 파일
  # 헤더가 손 편집을 허용하는 git-SSOT다. 값 witness는 tools/tests/test_provision-cache.bats에만
  # 있고(코드생성기가 방금 찍어낸 tmp fixture 검사) 여기(실제로 배포되는 커밋 파일)엔 0건이었다.
  # 뮤테이션 재현(2026-09-05): allowPrivilegeEscalation: false -> true 치환 후 이 파일 9/9 ok
  # (변화 없음) — 값이 약화돼도 이 스위트가 못 잡는다는 뜻이다.
  # 인스턴스 디렉토리 개수 바닥값은 두지 않는다(0개도 정당 — 위 :55-58 규약과 같은 성질,
  # service.yaml 루프(:61-78)와 동일 어휘로 디렉토리에서 파일을 유도한다). 비공허 증인은
  # tools/tests/test_provision-cache.bats에 있다.
  for f in "$DIR"/*/deployment.yaml; do
    [ -e "$f" ] || continue
    grep -q 'allowPrivilegeEscalation: false' "$f"
    grep -q 'readOnlyRootFilesystem: true' "$f"
    grep -q 'runAsNonRoot: true' "$f"
    grep -qF 'capabilities: { drop: [ALL] }' "$f"
    grep -q 'livenessProbe' "$f"
    grep -q 'readinessProbe' "$f"
  done
}
