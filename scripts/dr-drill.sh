#!/usr/bin/env bash
# DR drill (R5, POST-M6 수락): 전체 플랫폼이 git + R2 + age 키만으로 재구축됨을 증명한다.
# 노드를 DESTROY하고(scripts/destroy-node.sh) RECREATE한 뒤, 플랫폼을 git에서 재부트스트랩하고,
# 워크로드가 돌아오며, 재구축된 노드에서 R2로 DB가 복구됨을(canary 일치) 확인한다.
#
# 안전 설계: 파괴 BEFORE에 canary를 캡처하고 온디맨드 백업을 받아 "복구 가능"을 먼저
# 증명한다 — 복구가 증명되지 않으면 라이브 노드를 절대 파괴하지 않는다. 신선한 prod `pg`는
# bootstrap.initdb로 EMPTY로 뜨며, 실제 prod 데이터는 R2에서 복구된다(docs/runbooks/restore.md).
#
# 노드 유실에도 살아남아야 하는 외부 입력: M0 클러스터 age 키(~/.config/sops/age/keys.txt)와
# Terraform state + R2 백업(둘 다 R2). 네임스페이스만 ArgoCD 재설치는 스모크 체크지 DR이 아니다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── bulk 국면 A(D4 한시) 동안에는 드릴 자체를 거부한다 ─────────────────────────────────────
# ⚠️ 이 드릴의 안전 설계 전체가 **"파괴 대상 밖에 bulk가 있다"**는 전제 위에 서 있다([6.5]의
#    주석이 "bulk 디스크는 노드 파괴에도 살아남는다"고 명시한다). 국면 A는 정확히 그 전제를 깬다 —
#    bulk가 부트 디스크 위의 bind 마운트라 노드 파괴가 **files-data를 실제로 지운다.**
#    복구 증명([0.5])은 CNPG/R2만 덮으므로 이 손실을 잡지 못한다.
# ⚠️ 다른 어떤 검사보다 먼저 둔다(yq 파생·클러스터 변이·백업 생성 전부보다 앞). 그래야 거부가
#    부작용 0으로 끝난다. `. sealing-key-dr-gate.sh` 소스보다도 앞이다.
# ⚠️ **옛 sed 한 줄은 여기서 fail-open이었다** — `… 2>/dev/null || true`가 파일 부재 · 키 부재 ·
#    줄 포맷 변경을 전부 빈 문자열로 접었고, 아래 `[ -n ]`이 그 셋을 모두 "국면 B, 드릴 진행"으로
#    읽었다. 리더는 그 셋을 rc 1(판정 불가)로 내고 **선언된 빈 값만** rc 0으로 통과시킨다.
#    (리더는 versions.env를 **source하지 않는다** — destroy-node.sh와 같은 근거를 승계한다.)
VERSIONS_READ="$REPO_ROOT/infra/k3s-bootstrap/versions-read.sh"
if [ ! -x "$VERSIONS_READ" ]; then
  echo "DR ABORT: versions.env 리더가 실행 가능하지 않다: ${VERSIONS_READ}. 부재/비실행은 '국면 B'가 아니라 판정 불가다." >&2
  exit 1
fi
if ! _bulk_window="$("$VERSIONS_READ" BULK_MIGRATION_WINDOW_UNTIL)"; then
  echo "DR ABORT: versions.env에서 BULK_MIGRATION_WINDOW_UNTIL을 판정하지 못했다(사유는 바로 위 versions-read 줄)." >&2
  echo "          국면 A인지 모른 채로는 노드를 파괴하는 드릴을 시작하지 않는다 — 판정 불가는 '창이 비었다'가 아니다." >&2
  exit 1
fi
if [ -n "$_bulk_window" ]; then
  echo "DR ABORT: 국면 A(D4 한시) 진행 중 — bulk가 파괴 대상과 같은 디스크에 있다(만료 ${_bulk_window})." >&2
  echo "          이 드릴은 노드를 파괴하고, 그 파괴가 bulk의 사용자 데이터(files-data)를 함께 지운다." >&2
  echo "          [0.5]의 복구 증명은 CNPG/R2만 덮으므로 이 손실을 막지 못한다." >&2
  echo "          국면 B(2TB M.2를 /mnt/bulk에 마운트) 후 versions.env의" >&2
  echo "          BULK_MIGRATION_WINDOW_UNTIL을 비우면 다시 열린다." >&2
  exit 1
fi

# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/sealing-key-dr-gate.sh"
SEALED_KEY_BACKUP_DIR="${SEALED_KEY_BACKUP_DIR:-}"  # 소비자 ≥1 또는 committed cert 존재 시 필요(git 밖 백업)
# 노드 권한 명령 시임 — 베어메탈에서는 **여기가 곧 노드**라 로컬 sudo다(k3s-install.sh·apply-storage.sh와
# 같은 규약). [6.5]가 bulk 백킹 디렉토리를 읽을 때 쓴다. 테스트는 argv 기록기를 꽂는다.
K3S_RUN="${K3S_RUN:-sudo}"
# ⚠️ **kubeconfig 전환은 첫 kubectl보다 앞이어야 한다.** 아래 ARCHIVE_SERVER 파생이 이 드릴의 첫
#    라이브 조회인데, 그때 KUBECONFIG가 아직 호출 셸의 것이면 증명 대상과 파괴 대상이 어긋난다:
#    미설정이면(런북의 정본 호출이 그렇다) 조회가 실패해 「serverName을 파생하지 못했다」로 거짓
#    abort하고, 반대편 클러스터의 kubeconfig가 남아 있으면 **남의 아카이브**로 복구 가능성을
#    증명한 뒤 이 노드를 파괴한다. 형제 reset-pg-r2-archive.sh·netpol-rehearsal.sh가 D-i로 닫은
#    바로 그 클래스다. (2026-08-17에 ARCHIVE_SERVER 파생이 이 두 줄 **앞**에 삽입돼 뒤집혔다.)
KUBECONFIG_PATH="$REPO_ROOT/infra/k3s-bootstrap/kubeconfig"
use_live_kubeconfig() { export KUBECONFIG="$KUBECONFIG_PATH"; }
use_live_kubeconfig

NS="database"
LIVE_CLUSTER="pg"
# ⚠️ k8s Cluster 이름과 아카이브 serverName은 다른 것이다(restore-drill-script.sh와 같은 이유).
#    [0.5]의 "파괴 전 복구 가능성 증명"이 **엉뚱한 아카이브**를 복구하면, 그 증명이 통과한 뒤
#    노드를 파괴한다 — 증명 대상과 파괴 대상이 어긋난다.
ARCHIVE_SERVER="$(kubectl -n "$NS" get cluster "$LIVE_CLUSTER" \
  -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}' 2>/dev/null || true)"
[ -n "$ARCHIVE_SERVER" ] || { echo "DR DRILL FAIL: Cluster ${LIVE_CLUSTER}에서 아카이브 serverName을 파생하지 못했다 — 무엇을 복구할지 모른 채 파괴할 수 없다" >&2; exit 1; }
DB="app"

# PG 이미지는 cluster.yaml(SSOT)에서 파생 — 하드코딩 핀은 PG 메이저 갱신 시 cross-major
# 물리복구 불가로 드릴을 조용히 죽인다(M6). 인클러스터 소비자(basebackup·restore-drill)는
# 런타임에 레포가 없어 파생 불가 → tests/test_pg-image-pin.bats가 핀 정합을 강제한다.
command -v yq >/dev/null || { echo "DR DRILL FAIL: yq 필요(docs/runbooks/toolchain.md 핀)"; exit 1; }
PG_IMAGE="$(yq '.spec.imageName' platform/cnpg/prod/cluster.yaml)"
case "$PG_IMAGE" in
  ghcr.io/cloudnative-pg/postgresql:[0-9]*) ;; # yq 버전차 방어 — 값 형태를 직접 검증
  *) echo "DR DRILL FAIL: cluster.yaml에서 PG 이미지 파생 실패 (got: '${PG_IMAGE}')"; exit 1 ;;
esac

: "${SOPS_AGE_KEY_FILE:?export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt (노드 유실에도 살아남는 out-of-band 입력)}"
test -s "$SOPS_AGE_KEY_FILE" || { echo "DR DRILL FAIL: age key missing at $SOPS_AGE_KEY_FILE"; exit 1; }

echo "==> [0] DR 입력이 노드 유실에도 살아남는지 확인: Terraform state + R2 백업은 R2에 있다"
terraform -chdir=infra/cloudflare state list >/dev/null \
  || { echo "DR DRILL FAIL: TF state(R2 backend) 도달 불가"; exit 1; }

# recover_and_check NAME → R2에서 verify 클러스터를 복구하고 canary count를 echo한 뒤 정리한다.
# drill-ssd(reclaimPolicy=Delete)라 PVC 삭제 시 PV 자동 제거 — 누수 없음, PV RBAC 불필요.
#
# ⚠️ **M17과 같은 기전이 여기에도 있었다(2026-08-17 수정).** 정리가 함수 말미에만 있어서 비정상
#    종료(스크립트 중단·노드 재부팅·타임아웃) 시 고아 Cluster가 남고, 다음 실행의 `kubectl apply`가
#    그 생존자에 대해 **no-op**이 된다 → phase 루프가 첫 폴링에 통과 → 생존자에서 canary를 읽어
#    **R2를 만지지 않은 채 "복구 가능"으로 보고**한다.
#    🔴 여기서는 결과가 restore-drill보다 무겁다: `[0.5]`의 PRE 판정이 **노드 파괴를 승인**한다
#    (`:126-128`). 거짓 증거로 라이브 노드를 파괴하는 경로다.
#    처방은 restore-drill과 동일하다 — apply 이전 pre-flight 정리 + 복구가 실제로 일어났다는
#    양성 증인(SAW_NONHEALTHY). 상세 근거는 platform/cnpg/prod/restore-drill-script.sh와
#    docs/traps-detail.md의 「드릴의 정리가 EXIT trap뿐이면…」 항목.
# ⚠️ 이름별로 돈다 — 이 함수는 pg-dr-precheck과 pg-dr-verify 두 이름으로 호출된다.
_purge_drill_cluster() {
  kubectl -n "$NS" delete cluster "$1" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pvc -l "cnpg.io/cluster=$1" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  # 라벨이 빗나가도 지워지도록 이름으로도 지운다(라벨 셀렉터는 '0건=정상' 구조라 빗나가도 조용하다).
  kubectl -n "$NS" get pvc -o name 2>/dev/null | grep -x -E "persistentvolumeclaim/$1(-.*)?" \
    | while IFS= read -r p; do kubectl -n "$NS" delete "$p" --ignore-not-found --wait=true >/dev/null 2>&1 || true; done
  # 사라짐을 확인한다 — 삭제 호출의 rc는 `--ignore-not-found` 때문에 "지웠다"를 증명하지 못한다.
  local left
  left="$(kubectl -n "$NS" get cluster -o name 2>/dev/null | grep -c -x -E "cluster[^/]*/$1" || true)"
  [ "$left" = "0" ]
}

recover_and_check() {
  # pre-flight: 이전 실행의 잔여물을 지운 뒤에만 apply한다. 생존자 위의 apply는 no-op이고,
  # 그 no-op이 곧 "R2 미접촉 거짓 PASS"다.
  _purge_drill_cluster "$1" \
    || { echo "DR ABORT: 이전 드릴 클러스터 $1을 정리하지 못했다 — 생존자 위의 apply는 no-op(=거짓 복구 증명)이 된다" >&2; return 1; }
  kubectl apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: $1, namespace: ${NS}, labels: { cnpg.io/drill: "true" } }
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage: { size: 40Gi, storageClass: drill-ssd }
  walStorage: { size: 10Gi, storageClass: drill-ssd }
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits:   { cpu: "1", memory: 1Gi }
  bootstrap: { recovery: { source: r2-source } }
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: pg-r2, serverName: ${ARCHIVE_SERVER} }
YAML
  local phase="" saw_nonhealthy=0
  for _ in $(seq 1 80); do
    phase="$(kubectl -n "$NS" get cluster "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Cluster in healthy state" ] && break
    saw_nonhealthy=1
    sleep 15
  done
  # ⚠️ **복구가 실제로 일어났다는 양성 증인.** 판정에 쓰이는 관측은 `.status.phase`와 canary 행 수뿐인데,
  #    전자는 생존자에게 즉시 참이고 후자는 시드가 initdb 1회성이라 상수다(라이브는 영구히 1행).
  #    R2에서의 진짜 복구는 첫 폴링에 healthy가 될 수 없으므로, healthy가 아닌 phase를 한 번도
  #    못 봤다는 것 자체가 생존자 재사용의 증거다. 무-RBAC·무지연.
  if [ "$saw_nonhealthy" != "1" ]; then
    echo "DR ABORT: $1이 **첫 폴링에 이미 healthy**였다 — R2 복구가 일어나지 않았다(생존자 재사용 의심). pre-flight가 무엇을 놓쳤는지 확인할 것" >&2
    return 1
  fi
  local n
  n=$(kubectl -n "$NS" exec "${1}-1" -c postgres -- psql -U postgres -d "$DB" -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo 0)
  _purge_drill_cluster "$1" || echo "  경고: $1 정리 미완 — 다음 실행의 pre-flight가 잡는다" >&2
  echo "$n"
}

echo "==> [0.5] canary 캡처 + 검증된 백업 + 파괴 BEFORE 복구 가능성 증명"
EXPECTED=$(kubectl -n "$NS" exec "${LIVE_CLUSTER}-1" -c postgres -- psql -U postgres -d "$DB" -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo "")
{ [ -n "$EXPECTED" ] && [ "$EXPECTED" -ge 0 ]; } || { echo "DR ABORT: 라이브 canary를 읽을 수 없음"; exit 1; }
# 온디맨드 백업 → 고정 sleep이 아니라 실제 COMPLETE를 기다린 뒤 신뢰한다.
BK="dr-pre-$(kubectl -n "$NS" get backup -o name 2>/dev/null | wc -l | tr -d ' ')"
kubectl -n "$NS" create -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: ${BK}, namespace: ${NS} }
spec: { cluster: { name: ${LIVE_CLUSTER} }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
YAML
for _ in $(seq 1 80); do
  [ "$(kubectl -n "$NS" get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] && break
  sleep 15
done
[ "$(kubectl -n "$NS" get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] \
  || { echo "DR ABORT: 백업 ${BK}가 COMPLETE되지 않음 — 라이브 노드 파괴 거부"; exit 1; }
# 여전히 살아있는 노드에서 그 백업을 verify 클러스터로 복구: R2 복구 가능성이 증명되기
# 전에는 prod를 절대 파괴하지 않는다.
PRE=$(recover_and_check pg-dr-precheck)
{ [ "${PRE:-0}" -ge "$EXPECTED" ] && [ "${PRE:-0}" -gt 0 ]; } \
  || { echo "DR ABORT: 파괴 전 복구 실패(recovered=$PRE < $EXPECTED) — 라이브 노드 파괴 안 함"; exit 1; }
echo "    canary=$EXPECTED, 백업 ${BK} completed, 복구 가능성 증명됨(recovered=$PRE). 파괴 안전."

echo "==> [0.6] sealing-key DR: 도구 + fail-closed 검출 + 키 연속성(--verify·키쌍 암호·라이브 canary 리허설) 증명"
assert_recoverable_before_destroy "$REPO_ROOT" "$SEALED_KEY_BACKUP_DIR" "origin/main" \
  || { echo "DR ABORT: sealing key 복구 가능성 미증명 — 라이브 노드 파괴 거부"; exit 1; }

echo "==> [1] 노드 파괴(k3s 전손 + /var/lib/rancher 소멸) — 전체 노드 유실 시뮬레이션"
# ⚠️ 확인 env를 여기서 자동 주입한다. 그 env의 목적은 **직접 실행/복붙 오발사 차단**이고,
#    이 지점은 [0.5]·[0.6]이 복구 가능성을 이미 증명하고 위쪽 국면 A 게이트를 통과한 뒤다.
# ⚠️ `|| true`를 붙이지 않는다. 파괴 실패를 삼키면 [2] 이후가 '재구축'이 아니라 멀쩡한 노드
#    재확인이 되고, 드릴이 아무것도 증명하지 않은 채 PASS를 찍는다. 그것이 예전 한 줄
#    (`orb delete -f k3s || true`)의 정확한 고장 모드였다.
DR_DRILL_DESTROY_CONFIRM=1 bash "$REPO_ROOT/scripts/destroy-node.sh"

echo "==> [2] 커밋된 host-config/install에서 노드 + k3s + StorageClass 재구축(M1)"
bash infra/k3s-bootstrap/host-up.sh
use_live_kubeconfig # host-up.sh가 kubeconfig를 재생성한다

echo "==> [3] make bootstrap — ArgoCD + sops-age Secret + root app, 전부 git에서"
make bootstrap

echo "==> [3.5] sealing-key DR: 컨트롤러 대기 → 백업 키 복원 + committed cert 일치(항상)"
restore_sealing_key "$REPO_ROOT" "$SEALED_KEY_BACKUP_DIR" || { echo "DR DRILL FAIL: 복원 실패"; exit 1; }
assert_committed_cert_matches_live "$REPO_ROOT" || { echo "DR DRILL FAIL: cert stale — 복구책 후 재시도"; exit 1; }

echo "==> [4] 플랫폼 계층 수렴 대기(root + cnpg operator + data Healthy)"
for app in root cnpg-operator cnpg-data; do
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy "application/$app" --timeout=900s
done

echo "==> [4.4] 모든 ArgoCD Application Healthy 대기 (소비자 App data-conn·apps의 SealedSecret CR 싱크 보장)"
wait_all_applications_healthy 900s || { echo "DR DRILL FAIL: 일부 Application Healthy 수렴 실패"; exit 1; }
echo "==> [4.5] sealing-key DR: 라이브 ∪ origin/main 전수 unseal 검증(수렴 후)"
verify_all_sealedsecrets_unsealed "$REPO_ROOT" "origin/main" || { echo "DR DRILL FAIL: 일부 unseal 실패"; exit 1; }

echo "==> [5] 재구축된 노드에서 R2로 DB 복구, 파괴 전 canary 검증"
ACTUAL=$(recover_and_check pg-dr-verify)
{ [ "${ACTUAL:-0}" -ge "$EXPECTED" ] && [ "${ACTUAL:-0}" -gt 0 ]; } \
  || { echo "DR DRILL FAIL: recovered canary=$ACTUAL < pre-loss $EXPECTED — R2가 데이터를 복구하지 못함"; exit 1; }
echo "    recovered canary = $ACTUAL (>= pre-loss $EXPECTED) — 재구축 노드에서 R2 데이터 복구 증명됨"

echo "==> [6] 재구축된 플랫폼의 코어 워크로드가 실제 서빙되는지 검증 (인-레포 앱 0 — keystone 엣지 서비스 adguard)"
kubectl -n edge rollout status deploy/adguard --timeout=300s

echo "==> [6.5] files 데이터 재결합 검증: files pod Ready + 재바운드 PV 백킹 디렉토리 비어있지 않음(침묵 빈-복귀 모드 차단, M14)"
# bulk 디스크(국면 B의 별도 2TB M.2)는 노드 파괴에도 살아남지만, 동적 PV 메타데이터는 k3s 데이터스토어에
# 있어 `/var/lib/rancher`와 함께 사라진다 → 신규 PVC가 bulk 위에 **빈 디렉토리를 새로 파** 조용히
# '빈 카탈로그'로 정상 복귀할 수 있다. owner는 재구축 후 기존 bulk 데이터 디렉토리에 정적 PV를
# 바인딩하는 재결합을 수행해야 하며, 이 단언이 그 수행 여부를 fail-loud로 검증한다.
# ✅ **정본 절차는 `docs/runbooks/external-ssd.md` §3 「DR 재결합」이다** (2026-08-17 감사 16으로
#    두 스토리지 런북을 베어메탈 재작성하면서 이 주석의 요건을 그리로 옮겼다). 요지만 남긴다:
#      기존 `/mnt/bulk/<pvc-dir>`를 가리키는 `hostPath` PV를 `claimRef`로 files/files-data에
#      **정적 바인딩**한 뒤 PVC를 만든다(동적 프로비저닝에 맡기면 빈 디렉토리를 새로 판다).
#    ⚠️ 그 런북은 gitignored라 CI가 못 본다 — 이 단언이 수행 여부를 검증하는 유일한 기계다.
kubectl -n files rollout status deploy/files --timeout=300s
FILES_PVPATH="$(kubectl get pv -o json | yq -r '.items[] | select(.spec.claimRef.namespace=="files" and .spec.claimRef.name=="files-data") | (.spec.hostPath.path // .spec.local.path // "")' | head -1)"
[ -n "$FILES_PVPATH" ] || { echo "DR DRILL FAIL: files-data PV 미바운드 — 정적 PV 재결합 미수행"; exit 1; }
# ⚠️ **권한 상승해서 센다.** `/mnt/bulk`는 0700 root다(infra/k3s-bootstrap/README.md의 국면 A 절차가
#    `install -d -m 0700 -o root -g root`로 만든다) — owner 신원으로 읽으면 EACCES가 빈 출력으로 둔갑해
#    "읽을 수 없었다"가 "비어 있다"가 된다. apply-storage.sh가 probe를 $BULK_RUN으로 돌리는 것과 같은 이유다.
# ⚠️ `ls`가 아니라 `find`인 이유: 파이프 파싱 경고(SC2012)와 파일명 함정을 함께 피한다.
# ⚠️ `|| true`를 붙이지 않는다. 열거 실패(경로 부재·권한)는 '비어 있음'과 **다른 사건**이고,
#    아래 두 분기가 그 둘을 갈라 각각 다른 메시지로 죽는다.
FILES_ENTRIES="$($K3S_RUN find "$FILES_PVPATH" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" \
  || { echo "DR DRILL FAIL: PV 백킹 디렉토리를 열거하지 못했다($FILES_PVPATH) — 경로 부재 또는 권한(위 find 오류 참조). '비어 있음'과 다른 사건이다."; exit 1; }
[ "$FILES_ENTRIES" -gt 0 ] \
  || { echo "DR DRILL FAIL: files 카탈로그 비어있음($FILES_PVPATH, 항목 0) — 재결합이 기존 데이터를 복원하지 못했다(침묵 유실 모드)"; exit 1; }
echo "    files 카탈로그 항목 ${FILES_ENTRIES}건 — bulk 데이터 재결합 확인"

echo "DR DRILL PASS — 노드 재구축; 플랫폼 + 워크로드가 git에서 복귀, 재구축 노드에서 R2 데이터 복구 증명됨(prod 데이터는 docs/runbooks/restore.md로 복구)"
