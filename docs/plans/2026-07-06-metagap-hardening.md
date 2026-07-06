# 메타갭 하드닝 캠페인 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 2026-07-06 감사 완전성 비평가가 지적한 메타갭 5건(①내부 DNS 링치핀 ②renovate pinDigests 드리프트 ③단일 디스크 상관장애 ④토큰 만료 감시 0 ⑤RBAC 최소권한 미감사)과 **⑥원장 명목 잔여 4Mi 회수(온보딩 차단 해소, owner 확정: right-size 스윕)**를 3웨이브로 해소한다.

**Architecture:** 설계 문서 `docs/plans/2026-07-06-metagap-hardening-design.md`(커밋됨)를 따른다. W1=감시·인벤토리(무위험) → W2=설정·조치(컴포넌트 단위) → W3=구조(관측 데이터 외장 이전). 웨이브별 독립 PR·라이브 검증 후 다음 웨이브. 모든 감시는 fail-closed(absent 가드), 모든 신규 컴포넌트는 기존 패턴(restore-drill push 메트릭·ensure-role-password 텔레그램·check-* 게이트·bulk-ssd PVC) 복제.

**Tech Stack:** k3s/ArgoCD GitOps, vmalert/VictoriaMetrics, bash(3.2 호환)+bats, Bun/TS(tools), SealedSecrets, GitHub Actions.

**공통 규칙(전 태스크):**
- 커밋·PR 규율: 웨이브 내 태스크 묶음별 브랜치→PR→auto-merge(`gate`). 각 PR 전 `make ci` rc=0 필수(bun 1.3.14 PATH 선행: `export PATH="$HOME/.local/share/mise/installs/bun/1.3.14/bin:$PATH"`).
- bats @test 이름 영어, 주석 한국어. `*.enc.yaml` 직접 수정 금지. 시크릿 값 출력 금지.
- 라이브 검증은 `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`(읽기 전용 기본, 변이는 태스크에 명시된 것만).
- 알림룰 함정: VM instant query는 단발 push 샘플을 staleness 윈도 밖에서 못 봄 → `last_over_time(...[윈도])` + `absent()` 가드 필수(r4의 CNPGRestoreDrillStale 패턴).

---

## W1 — 감시·인벤토리

### Task 1: (③) 기존 루트 fs 알림(StandardSSD*) 검토·강화 — 중복 신설 금지

**⚠️ 전제(적대 리뷰 F16, 실측 확인):** r4에 이미 `StandardSSDWarning`(:18)·`StandardSSDFilling`(:27)·`StandardSSDFillingTrend`(:36)가 root fs의 절대 임계 + 추세를 커버한다. **새 룰 3종 신설은 같은 장애 모드의 중복 페이지를 만든다 — 이 태스크는 신설이 아니라 기존 3룰의 계약 검토·필요시 강화다.**

**Files:**
- Modify(필요시): `platform/victoria-stack/prod/rules/r4-storage-backup.yaml` (기존 StandardSSD* 3룰 in-place)
- Test: `tests/gates/test_vmalert-config.bats`

**Steps:**
1. 기존 3룰의 expr/for/severity를 정독하고 설계 요구와 대조: (a) 절대 임계 2단(warn/critical 상당) 존재? (b) 추세(predict/trend) 윈도가 72h 소진을 실용적으로 조기 경보? (c) `absent()` fail-closed 가드 존재? (d) VM 다중 series 함정(min/max 집계) 준수?
2. **부족분만** in-place 강화(룰 이름 유지 — alertmanager 타이틀 매핑·기존 운영 직관 보존). 이름을 바꿔야 할 강한 이유가 있으면 alertmanager.yaml 매핑·inhibit 영향을 같은 커밋에서 이관하고 커밋 메시지에 마이그레이션임을 명시.
3. 중복 방지 회귀 테스트 추가:
```bash
@test "root-fs pressure alerts stay single-sourced (no duplicate threshold/trend rules)" {
  f=platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  # mountpoint="/" 임계·추세 계열은 StandardSSD* 3룰만 — 중복 신설 회귀 차단
  run grep -cE 'alert: (NodeRootFs|RootDisk)' "$f"
  [ "$output" = "0" ] || [ "$status" -ne 0 ]
  grep -q 'StandardSSDWarning' "$f"; grep -q 'StandardSSDFillingTrend' "$f"
}
```
4. 강화가 있었으면 라이브 사전 검증(읽기 전용): 변경 expr을 vmsingle에 직접 질의(`port-forward svc/vmsingle` → `/api/v1/query`)해 값 반환 확인.
5. Commit(변경이 있을 때만) — `fix: 루트 fs 알림 계약 강화 — StandardSSD* in-place (메타갭 ③ W1-A)`

### Task 2: (③) per-PVC du 가시화 CronJob

**Files:**
- Create: `platform/victoria-stack/prod/pvc-du-exporter.yaml`
- Modify: `platform/victoria-stack/prod/kustomization.yaml` (리소스 추가), `platform/victoria-stack/prod/rules/r4-storage-backup.yaml` (staleness 룰)
- Test: `platform/victoria-stack/prod/test_pvc_du_exporter.bats` (신규)

**Step 1: 실패하는 테스트 작성** (`test_pvc_du_exporter.bats`, 파일 헤더는 이웃 test_relay.bats 스타일):

```bash
#!/usr/bin/env bats
f=platform/victoria-stack/prod/pvc-du-exporter.yaml

@test "du exporter is a daily CronJob pushing pvc_dir_size_bytes to vmsingle" {
  grep -q 'kind: CronJob' "$f"
  grep -q 'pvc_dir_size_bytes' "$f"
  grep -q 'api/v1/import/prometheus' "$f"
}
@test "du exporter mounts BOTH provisioner roots read-only (versions.env is the path SSOT)" {
  # 적대 리뷰 F9/F15: 경로 SSOT = infra/k3s-bootstrap/versions.env
  # (INTERNAL_STORAGE_PATH=/var/lib/rancher/k3s-storage/internal + bulk 실측 경로)
  grep -q 'readOnly: true' "$f"
  grep -q '/var/lib/rancher/k3s-storage/internal' "$f"
  grep -q 'storage-bulk' "$f"
}
@test "du exporter never references the stale pre-dual-provisioner path" {
  # 구경로(/var/lib/rancher/k3s/storage) 회귀 시 W3 bulk 신호가 침묵 — 부정 단언
  run grep -q '/var/lib/rancher/k3s/storage' "$f"
  [ "$status" -ne 0 ]
}
@test "du exporter fails loud on empty scan and emits tier capacity metrics" {
  grep -q 'COUNT' "$f"
  grep -q 'storage_tier_avail_bytes' "$f"
}
@test "du exporter is wired into kustomization" {
  grep -q 'pvc-du-exporter.yaml' platform/victoria-stack/prod/kustomization.yaml
}
```

**Step 2: 실패 확인** — `bats platform/victoria-stack/prod/test_pvc_du_exporter.bats` → FAIL.

**Step 3: 구현** — CronJob(observability ns, 일 1회 05:00, busybox 계열이 아닌 curl 보유 이미지 필요 → `ghcr.io/ukyi-app/pg-tools:18-rclone@<현재 digest>` 재사용, digest는 `platform/cnpg/prod/pgdump-hedge-cronjob.yaml`의 핀과 동일 값 복사):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: pvc-du-exporter, namespace: observability }
spec:
  schedule: "0 5 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: du
              image: ghcr.io/ukyi-app/pg-tools:18-rclone@sha256:<pgdump-hedge와 동일 digest>
              securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  TS=$(date +%s)
                  BODY=""
                  # 듀얼 provisioner 루트 둘 다 스캔(적대 리뷰 F9 — 경로는 versions.env가 SSOT:
                  # INTERNAL_STORAGE_PATH=/var/lib/rancher/k3s-storage/internal, bulk=외장 마운트).
                  # local-path PVC 디렉토리명 = pvc-<uid>_<ns>_<pvcname>
                  # ⚠️ F20: 카운트는 티어별 — 전역 카운트는 bulk 경로가 틀려도 internal만으로 녹색이 된다.
                  N_internal=0; N_bulk=0
                  for root in /storage-internal /storage-bulk; do
                    tier=${root#/storage-}
                    for d in "$root"/*_*_*; do
                      [ -d "$d" ] || continue
                      base=$(basename "$d")
                      ns=$(echo "$base" | cut -d_ -f2); pvc=$(echo "$base" | cut -d_ -f3-)
                      bytes=$(du -sb "$d" | cut -f1)
                      BODY="${BODY}pvc_dir_size_bytes{namespace=\"${ns}\",pvc=\"${pvc}\",tier=\"${tier}\"} ${bytes}\n"
                      eval "N_${tier}=\$((N_${tier}+1))"
                    done
                    # 티어별 fs 지표(적대 리뷰 F10) — virtiofs는 node-exporter가 못 본다(k3s-bootstrap
                    # README 명시). 파드 내 statfs(df)로 대체 계측 — W3의 유일한 bulk 용량 신호.
                    read -r fs_size fs_avail <<< "$(df -B1 --output=size,avail "$root" | tail -1)"
                    BODY="${BODY}storage_tier_size_bytes{tier=\"${tier}\"} ${fs_size}\n"
                    BODY="${BODY}storage_tier_avail_bytes{tier=\"${tier}\"} ${fs_avail}\n"
                  done
                  # F9/F20: 티어별 fail-loud — internal은 상주 PVC 다수, bulk에도 알려진 상주 PVC가
                  # 최소 1개 있다(files 데이터·pg-basebackup — 구현 시 실측해 기대 하한을 주석에 기록).
                  # bulk가 0이면 경로/마운트가 틀린 것 — 녹색 하트비트 금지.
                  [ "$N_internal" -ge 1 ] || { echo "internal PVC 0개 — 마운트/경로 확인"; exit 1; }
                  [ "$N_bulk" -ge 1 ] || { echo "bulk PVC 0개 — bulk 경로/외장 마운트 확인(F20)"; exit 1; }
                  BODY="${BODY}pvc_du_last_success_timestamp ${TS}\n"
                  printf "%b" "$BODY" | curl -fsS --connect-timeout 5 --max-time 30 --data-binary @- \
                    "http://vmsingle.observability.svc:8428/api/v1/import/prometheus"
              volumeMounts:
                - { name: storage-internal, mountPath: /storage-internal, readOnly: true }
                - { name: storage-bulk, mountPath: /storage-bulk, readOnly: true }
          volumes:
            - name: storage-internal
              hostPath: { path: /var/lib/rancher/k3s-storage/internal, type: Directory }
            - name: storage-bulk
              # 실제 마운트 지점은 apply-storage.sh가 결정(외장 or fallback /var/lib/rancher/k3s-storage/bulk)
              # — 구현 시 라이브 provisioner ConfigMap에서 실경로 확인 후 기입.
              hostPath: { path: <라이브 bulk 경로 실측 기입>, type: Directory }
```

bats 추가: (a) 두 루트 모두 마운트, (b) `COUNT -ge 1` fail-loud 존재, (c) `storage_tier_avail_bytes` 방출(=W3 신호), (d) 경로가 `/var/lib/rancher/k3s-storage/internal`(구경로 `/var/lib/rancher/k3s/storage` 금지 — 회귀 가드).
주의: df `--output`은 coreutils(pg-tools debian) 전제 — busybox df엔 없음(이미지 확인 필수).

**⚠️ 격리 계약(적대 리뷰 F8 — 전-PVC 읽기 도달성은 명시적 리스크 수용 + 강제 가드로만 허용):**
이 잡은 `/var/lib/rancher/k3s/storage` 전체(무관한 앱·DB 볼륨 포함)를 읽을 수 있다 — per-PVC 커버리지가 목적이라 스코프 축소 대신 아래 가드를 **전부** 강제하고, 매니페스트 주석에 리스크 수용을 명문화한다:
- `automountServiceAccountToken: false` (API 불사용 — 유출 시 토큰 동반 탈취 차단)
- 전용 netpol: 이 잡의 파드셀렉터에 default-deny egress + 허용은 vmsingle:8428·DNS:53만(텔레그램·인터넷 불허 — 유출 경로 봉쇄)
- resources limits(cpu 200m/memory 64Mi) + `readOnly: true`
- 이미지는 레포 기존 digest 핀 이미지 재사용(신규 서드파티 금지)
- bats 단언: 위 4개 가드 각각 grep(readOnly만이 아니라 automount·netpol 셀렉터·limits 전부)

주의: (a) observability ns PSA는 vector(hostPath·root)가 이미 있으므로 hostPath 허용 레벨 — `platform/victoria-stack/prod/namespace.yaml`의 PSA 라벨을 확인하고, restricted면 vector가 어떻게 예외 처리됐는지 동일 패턴을 따른다. (b) netpol: 위 격리 계약의 전용 netpol로 처리(기존 ns-wide 허용에 얹지 않는다).

staleness + bulk 용량 룰(r4, push 메트릭이므로 last_over_time 패턴 — **BulkStorageLow는 W3 착수의 선행 조건이 되는 구체 산출물이다, 적대 리뷰 F18**):
```yaml
          - alert: PvcDuExporterStale
            expr: |
              (time() - last_over_time(pvc_du_last_success_timestamp[3d])) > 172800
              or absent(last_over_time(pvc_du_last_success_timestamp[3d]))
            for: 30m
            labels: { severity: warning }
            annotations: { summary: "per-PVC 용량 수집이 48시간 이상 정체" }
          # bulk(외장 virtiofs)의 유일한 용량 신호 — node-exporter는 virtiofs를 못 본다(F10).
          # 일 1회 push 샘플이라 last_over_time [3d] 윈도 필수(instant staleness 함정).
          - alert: BulkStorageLow
            expr: |
              (last_over_time(storage_tier_avail_bytes{tier="bulk"}[3d])
                / last_over_time(storage_tier_size_bytes{tier="bulk"}[3d])) < 0.15
              or absent(last_over_time(storage_tier_avail_bytes{tier="bulk"}[3d]))
            for: 30m
            labels: { severity: warning }
            annotations: { summary: "외장(bulk-ssd) 여유 15% 미만 또는 신호 소실" }
```
bats: BulkStorageLow의 존재·`tier="bulk"` 라벨·absent 가드·last_over_time 윈도를 grep 단언(test_vmalert-config.bats).

**Step 4: 통과 확인 + `make ci`.**

**Step 5: 라이브 검증(변이 1회)** — 머지 후: `kubectl -n observability create job pvc-du-manual --from=cronjob/pvc-du-exporter` → 로그 OK → vmsingle에서 `pvc_dir_size_bytes` 질의로 series 확인 → job 삭제.

**Step 6: Commit** — `feat: per-PVC 용량 가시화 du exporter + staleness 알림 (메타갭 ③ W1-A)`

### Task 3: (④) credential-expiry 원장 + 주간 만료 경고

**Files:**
- Create: `policy/credential-expiry.json`, `scripts/check-credential-expiry.sh`, `.github/workflows/credential-expiry.yaml`
- Test: `tests/gates/test_credential_expiry.bats` (신규)

**Step 1: 실패하는 테스트 작성**:

```bash
#!/usr/bin/env bats
s=scripts/check-credential-expiry.sh

@test "expiry checker exits 0 when nothing expires within window" {
  tmp=$(mktemp); printf '[{"name":"far","expires":"2099-01-01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -eq 0 ]
}
@test "expiry checker exits 1 and names the credential when inside window" {
  tmp=$(mktemp)
  soon=$(date -v+3d +%Y-%m-%d 2>/dev/null || date -d "+3 days" +%Y-%m-%d)
  printf '[{"name":"ghcr-pull-pat","expires":"%s"}]' "$soon" > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ghcr-pull-pat"
}
@test "expiry checker fails loud on malformed json" {
  tmp=$(mktemp); printf 'not-json' > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -ne 0 ]
}
@test "credential ledger parses and every entry has name+expires" {
  run bash "$s" --file policy/credential-expiry.json --lint
  [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인.**

**Step 3: 구현** — `scripts/check-credential-expiry.sh`(bash 3.2·shellcheck clean, jq 사용 — CI ubuntu에 jq 존재·로컬 brew jq는 `scripts/` 관례 확인, 없으면 python3 fallback 금지하고 jq를 요구사항으로 명시):

```bash
#!/usr/bin/env bash
# 자격증명 만료 원장(policy/credential-expiry.json) 검사 — 값 없음, {name, expires(YYYY-MM-DD), note}만.
# --days N: N일 내 만료 항목이 있으면 목록 출력 + exit 1 (주간 워크플로가 텔레그램으로 중계)
# --lint : 스키마(이름·날짜 형식)만 검증
set -euo pipefail
FILE="policy/credential-expiry.json"; DAYS=14; LINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --lint) LINT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
jq -e 'type=="array" and all(.[]; (.name|type=="string") and (.expires|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))' \
  "$FILE" >/dev/null || { echo "ERROR: credential-expiry.json 형식 위반" >&2; exit 2; }
[ "$LINT" -eq 1 ] && { echo "lint OK"; exit 0; }
now=$(date +%s)
limit=$((now + DAYS*86400))
expiring=$(jq -r --argjson lim "$limit" '
  .[] | select((.expires + "T00:00:00Z" | fromdate) <= $lim) | "\(.name) expires \(.expires)"' "$FILE")
if [ -n "$expiring" ]; then
  echo "만료 임박(${DAYS}일) 자격증명:"; echo "$expiring"; exit 1
fi
echo "만료 임박 없음(${DAYS}일 윈도)"
```

`policy/credential-expiry.json` 초기값 — **실제 만료일은 실행 시 owner가 GitHub 설정에서 확인해 기입**(계획엔 자리표시):
```json
[
  { "name": "ghcr-pull-pat (GHCR_PULL_TOKEN fine-grained)", "expires": "<owner 확인 기입>", "note": "회전: .env.secrets 갱신 후 make seal-ghcr-pull" }
]
```
만료 없는 자격증명(telegram bot·GitHub App key·CF 토큰(무만료 설정)·tailscale OAuth)은 이 원장이 아니라 런북 인벤토리(Task 4)에만 기재.

`.github/workflows/credential-expiry.yaml` — audit.yaml의 스케줄+telegram 패턴 복제(주 1회 월 09:00 KST, `permissions: contents: read`, actor 가드 불필요(읽기 전용), 실패 시 telegram-notify composite — **status/source는 등록 enum만**(함정): source는 기존 enum 중 재사용 가능 값 확인 후 결정, 없으면 composite enum에 신규 등록을 같은 PR에서).

```yaml
name: credential-expiry
on:
  schedule: [{ cron: "0 0 * * 1" }] # 월 09:00 KST
  workflow_dispatch: {}
permissions: { contents: read }
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<기존 워크플로와 동일 sha 핀>
      - id: exp
        # `bash`로 호출 — 실행비트에 의존하지 않는다(적대 리뷰 F4; bats도 bash 호출이라 계약 일치)
        run: bash scripts/check-credential-expiry.sh --days 14
      - if: failure()
        uses: ./.github/actions/telegram-notify
        with:
          # ⚠️ 입력 계약은 audit.yaml의 telegram-notify 호출부를 그대로 복제한다(적대 리뷰 F4) —
          #    bot-token/chat-id 등 필수 입력·이름을 임의 작성하지 말고 실물 대조. status/source는
          #    이중 enum 강제(미등록=exit 2) — 신규 source가 필요하면 composite enum 등록을 같은 PR에.
          status: failure
          source: <audit.yaml 실물 대조 후 기입>
          <bot-token/chat-id 등 audit.yaml과 동일 입력 세트>
```

추가 요구: bats에 워크플로 계약 테스트 1건 — `credential-expiry.yaml`이 `bash scripts/check-credential-expiry.sh`로 호출하고 telegram-notify 호출부가 audit.yaml과 동일 입력 키 세트를 갖는지 grep 단언(기존 test_telegram-callsites.bats에 콜사이트 추가 — 카운트 검사가 있으므로 그 기대값도 동반 갱신).

**Step 4: 통과 확인 + actionlint(워크플로 신규 — make ci에 없음, 로컬 실행 필수) + `make ci`.**

**Step 5: Commit** — `feat: 자격증명 만료 원장·주간 D-14 경고 (메타갭 ④ W1-B)`

### Task 4: (④) 토큰 인벤토리 런북 + tailscale 키만료 실측 (owner-local, 커밋 없음)

**Files:** Create(로컬 전용, gitignored): `docs/runbooks/token-inventory.md`

**Steps:**
1. 인벤토리 표 작성 — 각 자격증명의 이름/보관 위치(.env.secrets 키·GH secret·SealedSecret)/스코프/만료 여부/회전 절차. 소스: `.env.secrets.example` 섹션 ①~⑬, `infra/github/secrets.tf`, seed-secrets.sh.
2. tailscale admin(또는 `tailscale status --json`)에서 `traefik-ts`·`pg-rw` 디바이스 key expiry 확인. tagged 디바이스는 기본 disabled 예상 — **활성이면 admin에서 disable하고 결과를 런북에 기록**(활성이었다면 이 사실을 W2 보고에 포함).
3. `scripts/verify-runbook-index.sh`가 런북 인덱스를 검사하면 AGENTS.md 런북 표에 `token-inventory.md` 행 추가(이건 커밋 대상 — 별도 소커밋 `docs: 런북 인덱스에 token-inventory 추가`).

### Task 5: (⑤) RBAC/automount 전수 감사 리포트

**Files:** Create: `docs/plans/2026-07-06-rbac-audit-report.md` (역사 기록으로 커밋)

**Steps:**
1. 정적 수집: `git grep -l "kind: ClusterRole\|kind: Role\b" platform/` → 각 파일의 rules(verbs/resources) 표. `git grep -n "automountServiceAccountToken" platform/ apps/`.
2. 라이브 수집(읽기 전용): `kubectl get sa -A -o json | jq '...automountServiceAccountToken'`, `kubectl get clusterrolebinding -o wide`.
3. 워크로드별 판정: API 실사용(vmagent/ksm/vector/traefik/argocd/tailscale-operator/cnpg/sealed-secrets/homepage=필요) vs 미사용(adguard, cloudflared, whoami, glances(이미 false), 공유차트 앱, grafana, vmsingle/vlogs/vmalert/alertmanager 등 — 각각 매니페스트·차트 values에서 확인).
4. 리포트 구조: A) automount:false 후보(저위험, W2-C 대상 목록) B) verb 축소 후보(homepage 등) C) 위험/보고-only(사유 명시). 각 항목에 근거 파일:라인.
5. Commit — `docs: RBAC/SA automount 전수 감사 리포트 (메타갭 ⑤ W1-C)`

### Task 5.5: (⑥) 원장 명목 헤드룸 회수 — right-size 스윕

**배경:** tailscale 미계상 정정(#296, +192)으로 명목 잔여 4Mi — verify:ledger 게이트상 신규 앱 온보딩 실질 차단. 실 헤드룸은 충분(동시 peak ≪ allocatable — 원장 산문)하므로 명목치 회수가 목적. **수용 기준: 명목 잔여 ≥ 256Mi(온보딩 1앱 분) + `bun run verify:ledger` green + 행·산문·합계 삼자 일관.** VM 증설(+1GiB)은 이 스윕 후에도 부족할 때의 후속 옵션(owner 확정 2026-07-06 — 설계 문서 W1-D).

**Files:**
- Modify: `docs/memory-ledger.md` (행·합계·산문), `policy/memory-limit-allowlist.txt` (종이 캡 변경 시 산문 정합)
- Modify(2단계 후보 확정 시): 해당 컴포넌트 values/manifest + GOMEMLIMIT 동반
- Test: 기존 ledger 스위트(verify:ledger·test_ledger)가 게이트 — 신규 테스트 불요

**Step 1: 1단계 — 종이 캡 조정(증거 기반 — 적대 리뷰 F24: 무한대 워크로드의 캡 축소는 실측 없이는 거버넌스 약화일 뿐)**
- **선행 실측**: cert-manager 3컨테이너(controller/cainjector/webhook)의 14일 peak working_set을 개별 질의(파드 세대 귀속 함정 준수). 캡 조정은 **측정 peak 합 × ≥2.0x**를 유지하는 값으로만(예: peak 합 120Mi면 288 가능, 160Mi면 336까지만) — 근거 수치·측정일을 원장 산문에 기록. unlimited 파드라 ContainerMemoryNearLimit이 못 지키는 컴포넌트임을 산문에 명시(기존 allowlist 문구와 정합).
- `whoami`(16/16, gateway ns 디버그 에코): **owner 결정 항목** — 철거(teardown류 소PR, +16) 또는 존치. 계획 실행 시 AskUserQuestion 1회로 확정(철거 시 posture 스위트의 whoami 참조 여부를 먼저 grep — 라이브 e2e가 참조하면 존치).

**Step 2: 2단계 — 측정 기반 회수(≥256 도달까지, 후보당 롤백 게이트 — 적대 리뷰 F25)**
- 14일 peak working_set 실측 — **함정 준수**: 파드 세대/containerID 귀속(OOM victim vs survivor), VM 다중 series는 pod 명시 + max, `sum by (namespace)`의 세대 중복 과대 금지(컴포넌트별 컨테이너 단위로).
- 후보 판정 기준(B10 방법론): 현 limit / 실측 peak ≥ 1.5x인 상주 워크로드만, 축소 후에도 ≥1.3x 유지. **repo-server(1.06x UNSAFE 보류)·postgres·최근 OOM 수정분(vector 등)은 제외 목록에 명시.**
- **후보당 절차(직렬, 한 번에 하나)**: ⑴적용 전 기록(구 limit/GOMEMLIMIT/원장 행 — 커밋 메시지에 포함) → ⑵소PR(GOMEMLIMIT 동반 함정 — Go는 limit×0.9, check-resource-limits ≤0.95 게이트가 검증) → ⑶관찰 윈도 24h: Ready 실패·OOMKill·ContainerMemoryNearLimit 발화 중 하나라도 발생하면 **즉시 revert PR(기록해 둔 구 값 복원)**하고 해당 후보를 제외 목록에 사유와 함께 등재 → ⑷이전 후보가 윈도를 통과하기 전에는 다음 후보 착수 금지. **스택 PR 금지(squash 함정) — main에서 순차.**

**Step 3: 검증·Commit**
- `bun run verify:ledger` + `make ci` rc=0. 라이브: 후보당 관찰 윈도(Step 2-⑶)가 검증 그 자체.
- Commit(단계별): `chore: 원장 캡 조정 — cert-manager 예약 <old>→<new> (14d peak <p>Mi 실측, 메타갭 ⑥)` / 후보별 `refactor: <comp> memory right-size <old>→<new> (실측 peak <p>Mi, 메타갭 ⑥)`

**W1 웨이브 게이트(적대 리뷰 F23 — 미달 통과 금지):** W1 PR 전부 머지 + Task 1/2 알림·메트릭 라이브 확인 + **Task 5.5는 다음 중 하나가 충족돼야 W1 완료**: (a) 명목 잔여 ≥256Mi 달성, 또는 (b) 측정상 안전 후보 소진을 증빙한 보고에 대해 **owner가 명시 결정**(VM 증설 착수를 W2 병행 태스크로 편입 / 또는 "당분간 온보딩 차단 수용"을 원장 산문에 명문화). 결정 없이 갭 보고만으로 W2 진행 금지 — 온보딩 차단은 이 태스크의 존재 이유다.

---

## W2 — 설정·조치

### Task 6: (①) adguard API 자격 SealedSecret

**Files:**
- Modify: `tools/seal-batch.ts` 그룹 정의(기존 `ghcr-pull` 그룹 패턴) 또는 `Makefile`의 seal 타겟 — 기존 `make seal-adguard-auth` 경로를 먼저 읽고, **UI 평문 자격을 edge ns Secret으로 봉인하는 기존 산출물이 이미 있으면 재사용하고 이 태스크는 스킵**.
- Create(없을 때만): `platform/adguard/prod/adguard-api-creds.sealed.yaml` (`ADGUARD_USER`/`ADGUARD_PASSWORD`, edge ns)

**Steps:** 기존 `adguard-auth.sealed.yaml` 내용 확인(그 Secret이 bcrypt 해시만 갖는지, 평문도 갖는지) → 평문 부재 시 `make seal-adguard-api`(신규 타겟, seal-batch 재사용)로 봉인 → bats(`test_adguard_auth.bats`에 존재 테스트 추가) → `make ci` → Commit.

### Task 7: (①) rewrite 셀프힐 리컨실러 CronJob

**Files:**
- Create: `platform/adguard/prod/rewrite-reconciler.yaml` (CronJob+SA), `platform/adguard/prod/rewrite-reconciler-rbac.yaml` (gateway ns Role/RoleBinding)
- Modify: `platform/adguard/prod/kustomization.yaml`, `platform/adguard/prod/networkpolicy.yaml`(egress), `platform/adguard/prod/adguardhome.yaml`(시드 주석에 리컨실러 참조 추가), `platform/victoria-stack/prod/rules/r4-storage-backup.yaml`(staleness 룰), `platform/victoria-stack/prod/alertmanager.yaml`(타이틀 매핑)
- Test: `platform/adguard/prod/test_rewrite_reconciler.bats` (신규)

**Step 1: 실패하는 테스트 작성** (핵심 계약만 발췌 — 실행 시 전체 작성):

```bash
#!/usr/bin/env bats
f=platform/adguard/prod/rewrite-reconciler.yaml

@test "reconciler reads traefik-ts svc via apiserver and converges the *.home rewrite" {
  grep -q '/api/v1/namespaces/gateway/services/traefik-ts' "$f"
  grep -q '/control/rewrite' "$f"
  grep -q '\*.home.ukyi.app' "$f"
}
@test "reconciler pushes success timestamp metric (fail-closed staleness)" {
  grep -q 'adguard_rewrite_reconcile_timestamp' "$f"
  grep -q 'api/v1/import/prometheus' "$f"
}
@test "reconciler rbac is scoped to get on the single gateway service" {
  r=platform/adguard/prod/rewrite-reconciler-rbac.yaml
  grep -q 'namespace: gateway' "$r"
  grep -q 'resourceNames: \["traefik-ts"\]' "$r"
  grep -qE 'verbs: \["get"\]' "$r"
}
@test "reconciler carries no telegram credential or direct send path (notify via fix metric only)" {
  # 적대 리뷰 F13: DNS 변이 권한 파드에 발송 자격·인터넷 egress 금지 — 통지는 메트릭→vmalert 경유
  run grep -q 'sendMessage' "$f"
  [ "$status" -ne 0 ]
  run grep -q 'TELEGRAM' "$f"
  [ "$status" -ne 0 ]
  grep -q 'adguard_rewrite_last_fix_timestamp' "$f"
}
@test "reconciler job has concurrency and deadline guards (no overlapping mutation of the linchpin)" {
  # 적대 리뷰 F6: 의존성 정체 시 중첩 실행이 stale 값으로 rewrite를 변이(플래핑)하는 것 차단.
  grep -q 'concurrencyPolicy: Forbid' "$f"
  grep -q 'activeDeadlineSeconds: 120' "$f"
  grep -q 'startingDeadlineSeconds: 300' "$f"
}
@test "reconciler bounds every curl (connect/total timeout)" {
  # 전 curl 호출이 CURL="curl -fsS --connect-timeout 5 --max-time 20" 공용 변수 경유인지.
  # 적대 리뷰 F12: CURL= 대입 라인 자체가 매치되지 않도록 '직접 호출'만 겨냥한다
  # (라인 선두 공백 뒤 curl로 시작 = 직접 호출; 대입은 CURL=로 시작하므로 비매치).
  grep -q 'connect-timeout 5' "$f"
  grep -q 'max-time 20' "$f"
  run grep -cE '^[[:space:]]*curl[[:space:]]' "$f"
  [ "$output" = "0" ] || [ "$status" -ne 0 ]
}
```

**Step 2: 실패 확인.**

**Step 3: 구현** — CronJob(edge ns, `*/10 * * * *`, pg-tools 이미지 digest 핀). **가드 필드 필수(적대 리뷰 F6 — 링치핀을 변이하는 잡은 중첩·무한대기 금지):**

```yaml
spec:
  schedule: "*/10 * * * *"
  concurrencyPolicy: Forbid          # 중첩 실행 금지 — stale have/want로 이중 변이 차단
  startingDeadlineSeconds: 300       # 스케줄 밀림 시 오래된 잡 기동 포기(다음 주기에 맡김)
  jobTemplate:
    spec:
      backoffLimit: 0                # 재시도 없이 다음 주기 — 알림룰이 침묵을 잡는다
      activeDeadlineSeconds: 120     # 주기(600s)보다 훨씬 짧게 — 행 걸림 방지
```

스크립트 핵심(컨테이너 args, curl+sed만 — kubectl 불요, **전 curl은 공용 변수 경유로 타임아웃 바운드**):

```bash
set -euo pipefail
CURL="curl -fsS --connect-timeout 5 --max-time 20"   # F6: 모든 네트워크 호출 바운드
SA=/var/run/secrets/kubernetes.io/serviceaccount
APISERVER="https://kubernetes.default.svc"
TOKEN=$(cat $SA/token)
# 1) 실제 tailscale IP (traefik-ts svc LB ingress)
want=$($CURL --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/gateway/services/traefik-ts" \
  | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1)
[ -n "$want" ] || { echo "traefik-ts LB IP 추출 실패"; exit 1; }
# 2) AdGuard 현재 rewrite
AG="http://adguard-ui.edge.svc"
AUTH="${ADGUARD_USER}:${ADGUARD_PASSWORD}"
have=$($CURL -u "$AUTH" "$AG/control/rewrite/list" \
  | sed -n 's/.*"domain":"\*.home.ukyi.app","answer":"\([0-9.]*\)".*/\1/p' | head -1)
# 3) 수렴 — ⚠️ 비원자성 방어(적대 리뷰 F7): delete 후 add가 실패하면 rewrite가 아예 사라진다.
#    구현 시 라이브 AdGuard 버전에 원자적 PUT /control/rewrite/update가 있으면 그것을 우선 사용
#    (v0.107.45+ — 라이브 버전 실측 후 분기 결정). 없으면 아래 trap 방식이 필수다.
if [ "$have" != "$want" ]; then
  restore_on_fail() {
    # delete는 됐는데 add가 실패한 경우 원값을 되살린다 — 링치핀을 빈 상태로 남기지 않는다.
    $CURL -u "$AUTH" -H 'Content-Type: application/json' \
      -d "{\"domain\":\"*.home.ukyi.app\",\"answer\":\"$have\"}" "$AG/control/rewrite/add" || true
    echo "수렴 실패 — 원값(${have}) 복원 시도 후 종료"; exit 1
  }
  if [ -n "$have" ]; then
    trap restore_on_fail ERR
    $CURL -u "$AUTH" -H 'Content-Type: application/json' \
      -d "{\"domain\":\"*.home.ukyi.app\",\"answer\":\"$have\"}" "$AG/control/rewrite/delete"
  fi
  $CURL -u "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"domain\":\"*.home.ukyi.app\",\"answer\":\"$want\"}" "$AG/control/rewrite/add"
  trap - ERR
  # ⚠️ 텔레그램 직접 발송 금지(적대 리뷰 F13) — 이 파드는 DNS 변이 권한+AdGuard 자격+SA 토큰을
  #    가진 링치핀 변이자다. 인터넷 egress(0.0.0.0/0:443)를 주면 netpol이 호스트명을 못 가리므로
  #    침해 시 자격 일체가 유출된다. 통지는 아래 fix 카운터 메트릭 → vmalert 룰 → alertmanager
  #    경유(발송 자격은 alertmanager에만).
  FIXED=1
fi
# 4) read-back 검증(F7) — 실제 라이브 상태가 want인지 재조회로 확인한 뒤에만 성공 하트비트.
now=$($CURL -u "$AUTH" "$AG/control/rewrite/list" \
  | sed -n 's/.*"domain":"\*.home.ukyi.app","answer":"\([0-9.]*\)".*/\1/p' | head -1)
[ "$now" = "$want" ] || { echo "read-back 불일치: now=${now} want=${want}"; exit 1; }
# 5) 성공 하트비트 + fix 표시(F13: 통지는 메트릭 경유) — read-back 통과 시에만.
#    ⚠️ F19: no-op 런에서 0 샘플을 쓰면 last_over_time의 최신 샘플이 0이 돼 직전 fix 이벤트를
#    지운다(통지 억제) — fix 타임스탬프는 FIXED=1일 때만 방출(희소 샘플, 0 금지).
{ printf 'adguard_rewrite_reconcile_timestamp %s\n' "$(date +%s)"
  if [ "${FIXED:-0}" = 1 ]; then
    printf 'adguard_rewrite_last_fix_timestamp %s\n' "$(date +%s)"
  fi
} | $CURL --data-binary @- "http://vmsingle.observability.svc:8428/api/v1/import/prometheus"
```

**통지 룰(F13 — 발송 자격 분리):** r4에 info 룰 추가 — 수렴이 실제 일어났을 때만 텔레그램(alertmanager 경유, 리컨실러엔 발송 자격 0):
```yaml
          - alert: AdguardRewriteDriftFixed
            expr: |
              (time() - last_over_time(adguard_rewrite_last_fix_timestamp[2h])) < 1200
              and last_over_time(adguard_rewrite_last_fix_timestamp[2h]) > 0
            labels: { severity: info }
            annotations:
              summary: "adguard *.home rewrite 드리프트가 자동 수렴됨"
              description: "리컨실러가 traefik-ts 실 IP로 rewrite를 복구했습니다 — DR 재구축/IP 변경이 있었는지 확인하세요."
```
이에 따라 **리컨실러 envFrom에서 텔레그램 자격 제거**(adguard-api-creds만) — Task 6의 seed-secrets 추가분(reconciler-alerting.enc)도 **불필요해져 제거**(bot token을 edge ns에 두지 않는다). netpol egress는 apiserver(노드서브넷:6443)·adguard-ui·vmsingle:8428·DNS만 — **인터넷(0.0.0.0/0) 불허 + 이를 부정 단언하는 bats**(`run grep -q '0.0.0.0/0' <netpol>` → status≠0, 단 기존 ns 다른 룰은 제외한 리컨실러 전용 블록 기준).

bats 추가(Step 1 파일에): rollback/read-back 계약 —
```bash
@test "reconciler restores the original answer if add fails after delete (no empty rewrite)" {
  grep -q 'restore_on_fail' "$f"
  grep -q 'trap restore_on_fail ERR' "$f"
}
@test "reconciler verifies read-back equals want before pushing the success heartbeat" {
  # read-back 검증이 하트비트 push보다 앞서는지(라인 순서) 확인
  rb=$(grep -n 'read-back' "$f" | head -1 | cut -d: -f1)
  hb=$(grep -n 'adguard_rewrite_reconcile_timestamp' "$f" | head -1 | cut -d: -f1)
  [ "$rb" -lt "$hb" ]
}
```

envFrom: **adguard-api-creds(Task 6)만** — 텔레그램 자격은 mount하지 않는다(적대 리뷰 F13: DNS 변이 권한과 발송 자격의 결합 금지, 통지는 fix 메트릭→vmalert→alertmanager 경유).

RBAC(gateway ns): `Role(get, services, resourceNames: [traefik-ts])` + edge SA 바인딩. netpol egress 추가(adguard networkpolicy.yaml, 리컨실러 전용 파드셀렉터 블록): apiserver=**노드서브넷 192.168.139.0/24:6443(함정 — ClusterIP ipBlock 불가)**, adguard-ui:3000(동일 ns pod-selector), vmsingle(observability):8428, DNS:53. **인터넷 egress 없음(F13)** — 0.0.0.0/0 부정 단언 bats 포함.

staleness 룰(r4):
```yaml
          - alert: AdguardRewriteReconcilerStale
            expr: |
              (time() - last_over_time(adguard_rewrite_reconcile_timestamp[2h])) > 1800
              or absent(last_over_time(adguard_rewrite_reconcile_timestamp[2h]))
            for: 15m
            labels: { severity: warning }
            annotations: { summary: "adguard rewrite 리컨실러가 30분+ 침묵 — *.home 드리프트 무방비" }
```

**Step 4: bats 통과 + `make ci`(+actionlint 불요 — 워크플로 아님).**

**Step 5: 라이브 검증(변이 — 명시적, bounded rollback 필수)** — 머지·싱크 후. **선행 조건: Step 1의 가드 필드 bats(F6)가 통과한 매니페스트만 라이브 드리프트 주입 대상이다. 원칙: 링치핀을 부수는 테스트는 스크립트된 복원 경로를 먼저 확보한 뒤에만 수행한다(적대 리뷰 F1).**
1. **복원 준비(주입 전)**: 현재 answer 캡처 + 복원 커맨드를 셸 함수로 준비:
   ```bash
   AG="http://127.0.0.1:13000"   # kubectl -n edge port-forward svc/adguard-ui 13000:80
   CUR=$(curl -fsS -u "$AUTH" "$AG/control/rewrite/list" | sed -n 's/.*"\*.home.ukyi.app","answer":"\([0-9.]*\)".*/\1/p')
   echo "captured answer=$CUR"   # 비어 있으면 여기서 중단
   restore() { curl -fsS -u "$AUTH" -H 'Content-Type: application/json' \
       -d "{\"domain\":\"*.home.ukyi.app\",\"answer\":\"100.99.99.99\"}" "$AG/control/rewrite/delete" || true; \
     curl -fsS -u "$AUTH" -H 'Content-Type: application/json' \
       -d "{\"domain\":\"*.home.ukyi.app\",\"answer\":\"$CUR\"}" "$AG/control/rewrite/add"; }
   ```
2. **no-op 선행 검증**: `kubectl -n edge create job rr-manual --from=cronjob/adguard-rewrite-reconciler` → 로그에서 "수렴 불필요" no-op + 하트비트 push 확인. **이 단계가 실패하면 드리프트 주입 없이 중단**(리컨실러가 미검증 상태로 링치핀을 건드리지 않는다).
3. **드리프트 주입 + 즉시 트리거**: answer를 `100.99.99.99`로 변경 → 10분 주기를 기다리지 않고 `kubectl -n edge create job rr-manual2 --from=cronjob/...`로 즉시 실행 → 로그에서 수렴 + 텔레그램 통지 확인.
4. **실패/타임아웃(3분) 시**: 준비해 둔 `restore` 즉시 실행해 캡처값 복원 → *.home 라이브 해석 확인(tailscale 기기에서 `dig @<adguard> grafana.home.ukyi.app`) → 리컨실러 디버깅은 복원 후에.
5. vmsingle에서 `adguard_rewrite_reconcile_timestamp` series 확인. 수동 job 2개 삭제.

**Step 6: 런북/시드 주석** — `docs/runbooks/lan-dns.md`에 리컨실러 절 추가(로컬), `adguardhome.yaml` 시드 주석에 "리컨실러가 10분 내 수렴 — 수동 갱신 불요" 추가(커밋).

**Step 7: Commit** — `feat: adguard *.home rewrite 셀프힐 리컨실러 (메타갭 ① W2-A)` (+ seed-secrets 변경은 `chore:` 별도 커밋)

### Task 8: (②-1) 이미지 digest 핀 2-레인 체커 구축 (verify 배선은 보류)

**⚠️ 순서(적대 리뷰 F5):** 체커를 **핀 적용(Task 9)보다 먼저** 만든다 — raw grep은 이 레포에서 무효(아래 F3 제약)이므로, 핀 완료 판정 도구 자체가 체커다. 이 시점에 실 레포는 태그-only라 체커가 **의도적으로 실패**하는 게 정상이며, 따라서 **Makefile verify 배선과 실-레포-통과 단언은 Task 9로 미룬다**(중간 상태에서 CI를 깨지 않기 위함).

Task 9의 "포맷 제약(F3)"·구현 세부(2-레인·scan-floor·픽스처 제외)를 그대로 따르되, 이 태스크의 범위는:
1. `scripts/check-image-pins.sh` + `policy/image-pin-allowlist.txt` 작성.
2. `tests/gates/test_image_pins.bats` — 픽스처 기반 (a)~(e)만(실-레포 통과 (f)는 Task 9에서 추가).
3. 실 레포에 수동 실행해 **현재 태그-only 목록을 출력**시켜 Task 9의 핀 대상 목록으로 확보(이 출력이 Task 9 진단의 입력).
4. Commit — `feat: 이미지 digest 핀 2-레인 체커 (배선은 핀 적용 후 — 메타갭 ② W2-B 1/2)`

### Task 9: (②-2) renovate pinDigests no-op 진단·핀 적용·게이트 배선

**Files:** Modify(진단 결과에 따라): `renovate.json`, `Makefile`(verify 배선), `tests/gates/test_image_pins.bats`(실-레포 통과 단언 추가)

**Steps (진단 우선 — 가설을 코드보다 먼저 검증):**
1. `gh issue list --search "Renovate Dependency Dashboard"` → 대시보드 본문에서 "Pin dependencies" PR 제안이 pending인지 확인.
2. 최근 `renovate.yaml` 런 로그(`gh run list --workflow renovate.yaml` → `gh run view <id> --log`)에서 `kubernetes` manager가 platform 파일에서 image를 추출했는지, pin PR 생성이 스케줄/제한(prConcurrentLimit 5·prHourlyLimit 2)에 걸렸는지 grep.
3. 원인별 처방:
   - 대시보드에 Pin PR이 대기 중 → 체크박스로 트리거하거나 `workflow_dispatch`로 renovate 재실행 → PR 생성.
   - manager가 파일을 안 읽음 → `managerFilePatterns` 정규식 실측 수정(re2 형식 확인).
   - datasource 실패(docker.io rate limit 등) → 로그의 lookup 에러를 근거로 `hostRules` 또는 registry 자격 추가.
4. **대형 Pin PR 리뷰·수동 머지**(automerge 금지 유지). 잔존 판정은 raw grep이 아니라 **Task 8 체커**: `bash scripts/check-image-pins.sh` → exit 0. 남는 정당 예외는 allowlist에 사유 주석과 함께 등재(최소화 — 수용 기준은 allowlist 0).
5. 체커를 `make verify` 체인에 배선 + bats에 실-레포 통과 단언 (f) 추가 → `make ci` rc=0.
6. 라이브: ArgoCD 전 앱 Synced/Healthy 유지 + `ImageDigestDrift` 알림 무발화 확인(digest-exporter와의 상호작용).
7. Commit — `fix: renovate pinDigests 실효화 + 핀 게이트 verify 배선 (메타갭 ② W2-B 2/2)`

#### (②) 체커 사양 — Task 8/9가 참조하는 구현 세부

**⚠️ 포맷 제약(적대 리뷰 F3):** 이 레포의 이미지는 두 포맷이다 — ⑴platform 매니페스트의 **컨테이너 이미지 문자열**(`image: ghcr.io/...@sha256:...`), ⑵apps values·공유 차트의 **구조체**(`image:` 매핑 아래 `repo:`/`tag:`/`digest:` — 문자열 아님). raw `image:` 라인 grep은 ⑵에서 값 없는 매핑 키를 오검출하고, 차트 픽스처(`platform/charts/app/tests/fixtures` 등)·테스트 yaml을 오차단한다. **게이트는 2-레인으로 설계하고, 최종 수용 기준(Task 9)은 "핀 적용 직후의 실 레포를 allowlist 0으로 통과"다.**

픽스처 bats (a)~(e) — Task 8 범위(임시 픽스처 dir 기반, 기존 test_backup-files-data.bats의 tmp 레포 패턴):
- (a) **레인1**: `image: nginx:1.25`(값 있는 문자열, `@sha256` 없음) → exit 1, 파일·라인 지목
- (b) 레인1: `image: nginx:1.25@sha256:abc...` → exit 0
- (c) **레인2**: apps values에 `image:` 매핑이 있는데 `digest:` 키 부재 → exit 1 / `digest: sha256:...` 존재 → 0
- (d) 픽스처·테스트 경로(`*/tests/*`, `*/fixtures/*`, `test_*.yaml`) 제외 확인 — 태그-only여도 무시
- (e) allowlist 등재 시 면제 + 등재 사유 주석 강제(기존 allowlist 관례)
- (f) **실 레포 통과** → Task 9 범위(핀 적용 후에만 성립)

구현(bash 3.2·shellcheck clean):
- 레인1(문자열): `git ls-files 'platform/**/*.yaml'`에서 **제외 경로** 필터 → `image:` 뒤에 **비어 있지 않은 스칼라 값**이 오는 라인만(`image:[[:space:]]*[a-z0-9]`) 추출 → 주석 제거 후 `@sha256:` 부재 검출.
- **제외 경로(적대 리뷰 F14 — renovate ignorePaths·벤더 불변 규약과 정렬)**: 픽스처/테스트(`*/tests/*`,`*/fixtures/*`,`test_*.yaml`) + **벤더**(`platform/cnpg/barman-plugin/**` — 수정 금지 파일이며 태그-only 이미지(manifest.yaml:1027 실측)를 포함, gateway-api CRD 경로). 벤더 제외는 allowlist가 아니라 **스캐너 자체의 제외 목록**으로 하드코딩(renovate.json ignorePaths와 나란히 주석 상호 참조) — "allowlist 0" 수용 기준은 벤더 제외 후 기준으로 유지. 픽스처 테스트에 "벤더 경로의 태그-only는 무시된다" 단언 추가.
- **스코프 경계 명시(적대 리뷰 F22)**: substrate(`infra/k3s-bootstrap/**` — local-path-provisioner 매니페스트 등, apply-storage.sh가 적용)는 **이 게이트의 스코프 밖**이다 — 템플릿 변수 치환(`${LOCAL_PATH_HELPER_IMAGE}` 등)이 있어 raw 스캔이 오탐하고, 버전 앵커는 versions.env + renovate custom manager(helper 이미지는 digest 그룹 존재)가 담당한다. 이 경계를 **게이트 스크립트 헤더 주석과 수용 기준 문구에 명시**("platform/apps 런타임 이미지 allowlist 0 — substrate는 versions.env 관리")하고, **후속 검토 항목**으로 `LOCAL_PATH_PROVISIONER_VERSION`에도 digest 핀을 붙일 수 있는지 renovate custom manager 확장을 W2-B 마무리에 1스텝 추가(가능하면 적용, 불가하면 사유를 versions.env 주석에 기록).
- 레인2(구조체): `apps/*/deploy/prod/values.yaml` 각각에 대해 `image:` 블록 내 `digest:[[:space:]]*sha256:` 존재 검사(values.schema.json의 digest 요구와 이중화 — 스키마는 차트 렌더 시점, 게이트는 커밋 시점).
- charts/ 벤더는 untracked라 ls-files가 자동 제외. **함정: 매치 0 = 통과가 아니라 스캔 무결성 의심 → 레인1 스캔 파일 수 하한(scan-floor, check-resource-limits.ts의 MIN_SCAN 패턴) 적용.**
- Makefile verify 배선은 **Task 9에서만**(중간 상태 CI 보호).

### Task 10: (⑤) 공유 차트 automountServiceAccountToken 기본 false

**Files:**
- Modify: `platform/charts/app/templates/deployment.yaml`(pod spec에 `automountServiceAccountToken: false`), `platform/charts/app/values.schema.json`(선택적 opt-in 필드는 **추가하지 않음** — YAGNI, 필요 앱이 생기면 그때)
- Test: `platform/charts/app/tests/` 기존 스타일로 렌더 단언 추가

**Steps:** 렌더 diff가 "필드 추가"만인지 3 kind 픽스처로 확인(behavior: 앱들은 API 미사용이라 무영향) → `make chart-test` → 라이브 검증은 다음 앱 bump 시 자동 롤링으로 적용(즉시 롤링 불요, 무해 변경) → Commit — `fix: 공유 차트 SA 토큰 automount 기본 차단 (메타갭 ⑤ W2-C)`

### Task 11: (⑤) 플랫폼 워크로드 automount:false 확산 + homepage verb 최소화

**Files:** Task 5 리포트의 A/B 목록이 SSOT — 대표: `platform/adguard/prod/deployment.yaml`, `platform/cloudflared/prod/*.yaml`, `platform/victoria-stack/prod/{grafana,vmsingle,victorialogs,vmalert,alertmanager}.yaml`(각 API 미사용 확인 후), `platform/homepage/prod/rbac.yaml`(verb 축소).

**Steps:** 워크로드당 소커밋(리포트 근거 인용) → 각각 라이브 재시작 후 Ready+기능 확인(특히 grafana 대시보드 로드·alertmanager 발송) → homepage는 verb 축소 후 위젯 동작 확인. `make ci` → PR.

### Task 12: (④) R2_PG 토큰 회전 (owner-local — 데이터 경로 자격)

**Files:** Create(로컬): `docs/runbooks/token-inventory.md`에 회전 절차 절. 레포 변경 없음(값 교체뿐).

**Steps:**
1. CF 대시보드에서 R2 토큰 재발급(Object R&W — **함정: ListBuckets 불가 토큰**, 기존과 동일 스코프).
2. `.env.secrets`의 R2 자격 갱신 → `make seed-secrets` → 영향 enc 재생성 확인(`git status`로 cnpg r2-creds·cache-r2-creds enc 변경 확인) → PR(enc 재암호화 커밋).
3. 소비자 반영: CronJob들은 실행 시점에 Secret을 읽으므로 재시작 불요, **barman 사이드카는 상주 — envFrom 함정** → `kubectl cnpg` 재시작이 아니라 CNPG plugin Secret 참조 방식 확인 후 필요 시 클러스터 재시작 절차(런북 restore.md의 유지보수 절차)로.
4. 검증: WAL 아카이브 메트릭 정상(`R2BackupStale` 무발화) + hedge 수동 1회 + cache-backup 수동 1회 라운드트립 성공.
5. 구 토큰 폐기(재발급 시점이 아니라 **검증 완료 후**).

**W2 웨이브 게이트:** W2 전 항목 라이브 검증 완료 + 1주 soak(알림 무발화) 후 W3 착수.

---

## W3 — 구조: 관측 데이터 bulk-ssd 이전

### Task 13: vmsingle TSDB 이전

**⚠️ 형상 제약(적대 리뷰 F2, 실측 확정):** `vmsingle`·`victorialogs`는 **StatefulSet + `volumeClaimTemplates`**(vmsingle.yaml:12,:54 / victorialogs.yaml:11,:49)다. VCT는 생성 후 **불변**이라 "PVC 교체/volume 스왑"식 in-place 업데이트는 불가능하고, ArgoCD가 immutable-field 에러로 관측 공백 중 OutOfSync 교착에 빠진다. **유일 지원 경로 = standalone PVC로 전환 + StatefulSet delete-orphan 재생성**이며 아래 시퀀스가 전부다.

**Files:**
- Modify: `platform/victoria-stack/prod/vmsingle.yaml`(VCT 블록 제거 → `spec.template.spec.volumes[].persistentVolumeClaim` 참조로 전환 + standalone PVC 오브젝트 추가), `docs/memory-ledger.md` 산문(위치 서술)
- 절차 문서: `docs/runbooks/observability-bootstrap.md`(로컬) 갱신
- **주의(적대 리뷰 F18): bulk 용량 알림은 이 태스크가 아니라 Task 2의 산출물이다** — node_filesystem 룰을 외장 마운트로 "확장"하는 것은 불가능(virtiofs, F10). 아래 선행 조건 (0)만 확인한다.

**Steps (owner-local 오케스트레이션 — 각 단계 명시 변이. ⚠️ F17: 관측 공백은 모든 사전 조건이 green인 뒤에만 시작하고, 각 단계에 중단 체크포인트를 둔다):**
0. **선행 조건(공백 시작 전 전부 충족)**: (a) Task 2의 `BulkStorageLow` 룰(r4: `storage_tier_avail_bytes{tier="bulk"} / storage_tier_size_bytes{tier="bulk"} < 0.15` warn + `absent()` 가드, bats 포함)이 **머지·라이브 발화 가능 상태**이고 `storage_tier_avail_bytes{tier="bulk"}` **및 알려진 bulk PVC의 `pvc_dir_size_bytes{tier="bulk"}`(files 데이터 등 — 티어 스캔이 진짜 bulk 트리를 보고 있다는 증거, F20)** 둘 다 실제 조회됨(df가 virtiofs에서 신뢰 불가 값을 주면 du 합산+용량 상수 기반으로 대체하고 룰 주석에 기록), (b) `kubectl get sc bulk-ssd` 존재·외장 마운트 게이트 통과, (c) 현 VCT PVC 실명(`<vct명>-vmsingle-0`)·용량 실측, (d) **PR-2(아래 4단계 형상 전환)를 미리 작성해 gate green까지 확인**(머지는 보류 — 공백 중 CI/리뷰 실패로 발이 묶이는 것 방지).
1. PR-1: standalone PVC `vmsingle-data-bulk`(storageClassName: bulk-ssd, 동일 용량) 오브젝트 추가·머지. StatefulSet은 미변경. **⚠️ F21: bulk-ssd(local-path)는 WaitForFirstConsumer라 소비자 없는 PVC는 Pending에 머물고, ArgoCD PVC 헬스는 Pending=Progressing이라 앱이 Progressing에 갇힐 수 있다** → 머지 직후 **일회성 바인더 Pod**(신규 PVC만 마운트, `command: ["true"]`, restartPolicy: Never — 구 PVC는 건드리지 않아 vmsingle 무영향)를 수동 실행해 Bound 전환 → victoria-stack 앱이 Healthy로 복귀하는지 확인 후 바인더 Pod 삭제. (Pending 상태로 두는 선택을 하려면 ArgoCD 헬스 영향을 실측해 무해함을 기록한 뒤에만.)
2. 관측 공백 시작: ArgoCD victoria-stack auto-sync 일시 중지(중지·복원 커맨드를 런북에 병기) → `kubectl -n observability scale sts vmsingle --replicas=0` → **`kubectl -n observability wait --for=delete pod/vmsingle-0 --timeout=120s`로 완전 종료 대기**(F17 — 쓰기 중인 TSDB를 복사하지 않는다).
3. 데이터 복사: 구 VCT PVC + 신규 PVC를 모두 마운트하는 임시 Pod에서 `rsync -a --delete /old/ /new/` → 파일 수·용량 스팟 대조 → 임시 Pod 삭제. **[중단 체크포인트] 복사 실패/대조 불일치 시: 임시 Pod 삭제 → `scale sts vmsingle --replicas=1` → auto-sync 복원 → 원상 복귀(공백 종료), 원인 분석은 오프라인에서.**
4. PR-2 머지(0-(d)에서 gate green 확인해 둔 형상 전환: VCT 블록 제거 + `volumes: [{name: vmsingle-data, persistentVolumeClaim: {claimName: vmsingle-data-bulk}}]`, volumeMounts 이름 유지). **[중단 체크포인트] 머지가 불가하면(레포 사정 등) 3의 복귀 절차 실행 — 복사본은 남겨둬도 무해.**
5. **STS 재생성(불변 필드 통과)**: `kubectl -n observability delete sts vmsingle --cascade=orphan` → auto-sync 복원(또는 명시 sync) → ArgoCD가 새 형상으로 STS 재생성 → orphan 파드가 남아 있으면 `kubectl delete pod vmsingle-0`로 재생성 유도(새 파드가 bulk PVC 마운트).
6. 검증: (a) 이전 이전 시점 메트릭 질의로 데이터 연속성, (b) vmalert/alertmanager 파이프(watchdog deadman 하트비트 — healthchecks 외부 경로), (c) `BulkStorageLow` 대상 series가 이전 후에도 정상 갱신되는지 질의.
7. **스왑백 경로(soak 기간 상시 유효, RPO 명시 — 적대 리뷰 F11)**: 구 VCT PVC는 보존. 실패 시 기본 절차는 **역방향 rsync 포함**: `scale sts --replicas=0` → 임시 Pod로 `rsync -a --delete /new/ /old/`(컷오버 이후 유입분 보존) → PR-2 revert 머지 → `delete sts --cascade=orphan` → 재생성으로 구 볼륨 복귀. 긴급(신규 볼륨 자체가 읽기 불가 등)으로 역rsync를 생략하면 **컷오버 이후 유입 샘플은 유실됨을 인지하고 진행**(그 시점을 텔레그램/런북에 기록 — "데이터 그대로"가 아님). soak 1주 후에만 구 PVC 삭제(별도 PR — **수동 머지**, 데이터 파괴 경계).

### Task 14: victorialogs 이전

vmsingle(Task 13)과 **동일한 STS delete-orphan 시퀀스**(standalone PVC `vlogs-bulk` → VCT 제거+volumes 참조 → `delete sts --cascade=orphan` → 재생성, 스왑백 경로 동일) — 로그는 보존 요구 낮아 **rsync 생략하고 신규 빈 볼륨으로 교체(retention 재축적)**를 기본으로 하되, 실행 시 owner가 보존 필요를 판단해 rsync 여부 선택. 검증: 신규 로그 유입(`vlogs` 질의) + VictoriaLogs 디스크 계열 알림 정상.

### Task 15: 캠페인 마감

1. `docs/plans/2026-07-06-metagap-hardening-design.md`에 결과 요약 추가 없이 — 대신 완료 보고를 메모리에 기록(관례).
2. 원장 산문·runbooks(observability-bootstrap/restore/external-ssd/lan-dns) 갱신 확인 스윕.
3. `make verify-posture`(라이브 스위트) + ArgoCD 전 앱 Synced/Healthy + 알림 무발화 24h 확인.

---

## 리스크·롤백 요약

| 항목 | 리스크 | 롤백 |
|---|---|---|
| W2-A 리컨실러 | AdGuard API 인증 실패/오수렴 | CronJob suspend(1커맨드) — rewrite는 수동 절차(기존 런북)로 복구 가능, staleness 알림이 침묵 감지 |
| W2-B 핀 PR | 대량 digest 핀이 잘못된 이미지 고정 | 태그는 그대로라 revert PR 1개로 복원, ArgoCD Healthy 게이트가 즉시 검출 |
| W2-C automount | API 쓰는 워크로드 오분류 | 워크로드당 소커밋이라 개별 revert, 라이브 기능 확인이 태스크에 포함 |
| W3 이전 | 외장 SSD 장애 시 관측 스택 다운 | dead-man switch(healthchecks)는 외부 경로 생존, 구 PVC를 soak 기간 보존(즉시 스왑백 가능) |
| W2-D 회전 | 새 토큰 스코프 실수 | 구 토큰을 검증 완료까지 폐기하지 않음(무중단 롤백) |

---

## Adversarial review dispositions

codex 적대 리뷰 7패스(1~3차 기본 캡 + owner 승인 연장 4~7차), 발견 22건 전원 **Accepted·반영**, Rejected 0. 최종(7차) verdict: `needs-attention` — 7차 발견 3건(F20~F22)까지 반영한 뒤 owner가 오픈 항목 0 상태에서 확정(8차 생략 결정: 핵심 구조는 각 2~3회 재검증, 잔여 디테일은 실행 단계 TDD·웨이브 게이트가 백스톱).

| # | 패스 | 심각도 | 요지 | 처분 |
|---|---|---|---|---|
| F1 | 1 | high | 프로덕션 rewrite 드리프트 주입 테스트에 롤백 부재 | Accepted — 캡처·restore 함수·no-op 선행·즉시 트리거·타임아웃 복원 절차 |
| F2 | 1 | high | vmsingle/vlogs가 StatefulSet+VCT(불변)인데 "PVC 스왑" 서술 | Accepted — standalone PVC + delete-orphan 재생성 시퀀스로 전면 교체(실측 확인) |
| F3 | 1 | medium | 핀 게이트가 구조체 image 포맷·픽스처와 불일치 | Accepted — 2-레인 설계 + 픽스처 제외 + 수용 기준 명시 |
| F4 | 2 | high | credential-expiry 워크플로 실행비트·telegram 입력 계약 누락 | Accepted — bash 호출 + audit.yaml 입력 계약 복제 + 콜사이트 bats |
| F5 | 2 | high | Task 8 잔존 검증이 raw grep — Task 9와 자기모순 | Accepted — 체커 선행 구축으로 순서 재배치, 수용 기준=체커 exit 0 |
| F6 | 2 | medium | 리컨실러 CronJob 동시성/데드라인/curl 타임아웃 미명시 | Accepted — Forbid·activeDeadline 120·startingDeadline 300·CURL 공용 변수 + bats |
| F7 | 3 | high | delete→add 비원자 — 실패 시 rewrite 소실 | Accepted — 원자 update 우선 검토 + ERR trap 복원 + read-back 후 하트비트 + bats |
| F8 | 3 | high | du exporter의 전-PVC 읽기 도달성(유출 반경) | Accepted — automount:false·전용 default-deny egress·limits·리스크 수용 명문화 + bats |
| F9 | 4 | high | 스토리지 루트 경로 오류 + 빈 스캔 녹색 | Accepted — versions.env SSOT 경로(실측)·듀얼 루트·fail-loud |
| F10 | 4 | high | W3가 의존하는 외장 fs 알림이 물리적으로 불가(virtiofs) | Accepted — storage_tier_* 메트릭 신설, W3 선행 조건화(실측 확인) |
| F11 | 4 | medium | 스왑백이 컷오버 후 유입분 유실인데 "데이터 그대로" | Accepted — 역rsync 기본 + 유실 윈도 명시 |
| F12 | 4 | medium | curl bats 술어 자기모순 | Accepted — 직접 호출 앵커로 교정 |
| F13 | 5 | high | DNS 변이 파드에 발송 자격+인터넷 egress 결합(유출 벡터) | Accepted — 통지를 fix 메트릭→vmalert→alertmanager로 분리, egress 봉쇄(설계 문서 동반 개정 d9bb74a) |
| F14 | 5 | high | 벤더 barman-plugin(태그-only·수정 금지)과 allowlist-0 모순 | Accepted — 스캐너 벤더 제외 하드코딩(실측 확인) |
| F15 | 5 | medium | du exporter bats가 구경로 단언(자기모순) | Accepted — SSOT 경로 + 구경로 부정 단언 |
| F16 | 5 | medium | 기존 StandardSSD* 3룰과 중복 신설 | Accepted — Task 1을 in-place 검토·강화로 재작성(실측 확인) |
| F17 | 6 | high | W3가 PR-2 미머지 상태로 공백 시작·종료 대기 없음 | Accepted — PR-2 사전 gate green·wait --for=delete·중단 체크포인트 |
| F18 | 6 | medium | bulk 알림 계약 자기모순(룰 확장 지시 잔존) | Accepted — BulkStorageLow를 Task 2 구체 산출물로 이동 |
| F19 | 6 | medium | no-op 런의 0 샘플이 fix 통지 억제 | Accepted — 희소 샘플(FIXED=1시만 방출) |
| F20 | 7 | high | 전역 카운트로 bulk 오경로에도 녹색 | Accepted — 티어별 fail-loud + 알려진 bulk PVC series를 W3 조건에 |
| F21 | 7 | medium | WaitForFirstConsumer PVC Pending으로 ArgoCD 헬스 교착 | Accepted — 일회성 바인더 Pod 절차 |
| F22 | 7 | medium | substrate 이미지가 게이트 스코프 밖인데 allowlist-0 주장 | Accepted — 스코프 경계 명시 + provisioner digest 핀 검토 스텝 |

**개정(2026-07-06, ⑥ 원장 헤드룸 회수 Task 5.5 추가 — owner 요청·right-size 스윕 방향 확정)** — 개정분 diff에 대한 추가 패스 1회, 발견 3건 전원 Accepted:

| # | 패스 | 심각도 | 요지 | 처분 |
|---|---|---|---|---|
| F23 | 개정1 | high | ≥256 미달이어도 "갭 보고"만으로 W1 통과 — 목표(온보딩 차단 해소)와 자기모순 | Accepted — W1 게이트를 "≥256 달성 or owner 명시 결정(VM 증설 편입/차단 수용 명문화)"로 경성화 |
| F24 | 개정1 | medium | unlimited 워크로드의 종이 캡 축소를 실측 없이 회수로 계상 | Accepted — cert-manager 3컨테이너 14d peak 실측 선행, 캡은 peak합×≥2.0x로만, 근거 산문 기록 |
| F25 | 개정1 | medium | 라이브 right-size PR에 롤백 경로 부재 | Accepted — 후보당 직렬 절차(구값 기록→24h 관찰→Ready/OOM/NearLimit 시 즉시 revert→통과 전 다음 후보 금지) |

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/metagap-hardening-plan`).
- **Run continuously:** do NOT stop between batches for routine review. Stop ONLY on a genuine blocker — missing dependency, a verification that keeps failing, an unclear/contradictory instruction, or a critical plan gap. **웨이브 게이트(W1→W2→W3)와 owner-local 단계(Task 4·12·13·14의 라이브 변이)는 예외 — 해당 지점에선 명시된 라이브 검증을 마치고 진행.**
- **Commits — apply these rules directly; do NOT invoke `Skill(commit)`** (its interactive confirmation would break continuous execution):
  - **Language:** commit message in **Korean**. **No AI markers** — never include `🤖 Generated with`, `Co-Authored-By: Claude`, or similar.
  - **Format:** `<type>: 한국어 설명` (optional `- 상세` body lines below).
  - **Type — use ONLY these:** `feat`(새 기능), `fix`(버그 수정), `refactor`(리팩토링/성능), `docs`(문서), `style`(포맷팅), `test`(테스트), `chore`(빌드/설정).
  - **Grouping:** 태스크 단위 소커밋(계획의 Commit 스텝), 같은 목적 파일 함께 — 설정/테스트/문서는 목적이 다르면 분리.
  - **Where:** commit at each plan `Commit` step, directly on this worktree branch. **main 반영은 PR-first + auto-merge(gate)** — 웨이브별 PR 묶음, push 전 `make ci` rc=0 (bun 1.3.14 PATH 선행).
