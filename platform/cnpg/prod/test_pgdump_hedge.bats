#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
# ⚠️ **DBS↔databases/ 정합은 하한이 아니라 등식이다(2026-09-09 발견 · 티켓 53).** 착지 전 판정은
#    databases/*.yaml의 Database CR을 **순회**하며 'present면 DBS에 포함 · absent면 부재'만 쟀다 —
#    분모가 CR 쪽이라 **CR 파일이 아예 없는 DBS 토큰**(유령 DB, 예: DBS="app ghostdb")은 어느 DB
#    개수에서도 통과했다(반박자 재현: CR 0건 · absent 1건 · present 1건 세 트리 전부 10/10 ok).
#    헤지 잡은 `set -euo pipefail`이라 존재하지 않는 DB의 pg_dump 하나가 잡 전체를 죽여 **뒤에 선
#    DB의 덤프까지** 잃는다 — 티켓 46이 막으려던 장애 클래스(등록 누락)의 정확한 반대 방향(잔존)이다.
#    ⇒ 판정은 이제 양방향 등식이다: DBS 토큰 집합 == {app} ∪ {`ensure: absent`가 아닌 Database CR의
#    metadata.name}. cf. AGENTS.md 함정 「이름 있는 집합의 상한 부재」.
# ⚠️ **그래서 판정이 인자화돼 있다** — 실 트리(DBS="app" · CR 0건) 고정이면 유령 토큰을 원리적으로
#    재현할 수 없어 상한 레인이 영원히 무증인이 된다. `hedge_dbs_findings`가 (헤지 매니페스트,
#    Database CR 디렉토리) 두 인자를 받고, 실 트리 단언과 픽스처 단언이 **같은 함수**를
#    통과한다(실 트리 @test가 CI의 실 도메인 권위, 픽스처가 판정 조건의 증인).
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
d=platform/cnpg/prod/databases

# DBS 토큰 집합 ↔ Database CR 집합 정합 판정 — 위반을 한 줄씩 stdout으로 낸다(0건이면 무출력).
#   $1 = 헤지 CronJob 매니페스트 · $2 = Database CR 디렉토리
# 진단 접두가 위반 클래스다:
#   missing:       — 기대 원소(부트스트랩 app 또는 `ensure: present` CR)가 DBS에 없다   [하한]
#   absent-in-dbs: — `ensure: absent` CR 이름이 DBS에 남았다                            [상한]
#   ghost:         — CR이 아예 없는 DBS 토큰                                            [상한 · 티켓 53]
hedge_dbs_findings() {
  local hf=$1
  local hd=$2
  local dbs
  local want
  local absent
  local y
  local name
  local w
  local t
  dbs=$(sed -n 's/^ *DBS="\([^"]*\)".*/\1/p' "$hf")
  if [ -z "$dbs" ]; then
    echo "no-dbs-line: $hf"
    return 0
  fi
  # 기대 집합 — 하한이자 **상한**의 정본이다. 부트스트랩 app DB(restore_canary 보유)는 CR 없이 늘 원소다.
  want=" app "
  # `ensure: absent`는 purge 상태머신(teardown-resource --step drop)이 DROP한 DB다 — 실체가 없으므로
  # 기대 집합 **밖**이고, DBS에 남으면 아래 상한 레인이 잡는다. 유령과 구별해 진단하려고 따로 모은다.
  absent=" "
  for y in "$hd"/*.yaml; do
    [ -f "$y" ] || continue   # 글롭 무매치(빈 디렉토리)의 리터럴 — 판정이 아니라 stderr 잡음 차단
    grep -q '^kind: Database$' "$y" || continue
    name=$(sed -n 's/^  name: \(.*\)$/\1/p' "$y" | head -1)
    if [ -z "$name" ]; then
      echo "no-name: $y"
      continue
    fi
    if grep -q '^  ensure: absent' "$y"; then
      absent="${absent}${name} "
      continue
    fi
    want="${want}${name} "
  done
  # 하한 — 기대 원소가 전부 DBS에 있는가. 누락된 DB는 barman 실패 시 복구 수단이 없는데
  # 알림은 녹색(job 완료 기반)인 무성 커버리지 갭이 된다.
  for w in $want; do
    case " $dbs " in *" $w "*) ;; *) echo "missing: $w";; esac
  done
  # 상한 — DBS 토큰이 전부 기대 집합 안인가. **분모가 DBS 쪽**이라 CR 순회로는 원리적으로 못 보던
  # 잔존 토큰을 여기서 잡는다(티켓 53). 실체 없는 DB 하나의 pg_dump 실패가 `set -euo pipefail`
  # 아래 잡 전체를 죽여 뒤에 선 DB의 덤프까지 잃는 것이 이 레인이 막는 장애다.
  for t in $dbs; do
    case "$want" in *" $t "*) continue;; esac
    case "$absent" in *" $t "*) echo "absent-in-dbs: $t"; continue;; esac
    echo "ghost: $t"
  done
  return 0
}

# 위반 건수 — 판정을 건수 등식으로 닫기 위한 셈. `grep -c`는 0건에서 rc 1이라 `|| true`가 필수다
# (없으면 정상 상태에서 대입 자체가 죽는다). 파이프가 아니라 herestring이라 SIGPIPE 레이스도 없다.
hedge_dbs_count() {
  grep -c . <<<"$1" || true
}

@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -eq 1 ]
}
@test "hedge writes a CLUSTER-SPECIFIC R2 prefix and prunes only that prefix" {
  # ⚠️ 프루닝(`--min-age 14d`)이 prefix 전체를 훑는다. 라이브 Mac과 prefix를 공유하면 **상대편의
  #    덤프를 지운다** — 파일명이 `${DB}-${TS}`라 두 클러스터를 구별할 수 없다.
  #    계획서 §3.4의 공유 자원 표에 빠져 있던 충돌이다(pgdump·캐시 2건 누락).
  grep -qE '^[^#]*DUMP_PREFIX=' "$f"
  grep -q 'pgdump-nuc' "$f"
  grep -qE 'rclone delete .*\$\{DUMP_PREFIX\}.*--min-age 14d' "$f"
  # 공유 prefix로 되돌아가면 red — 비-주석 줄만 본다(주석이 옛 경로를 설명한다).
  run grep -nE '^[^#]*r2:homelab-pg-backups-prod/pgdump/' "$f"
  [ "$status" -eq 1 ]
}
@test "hedge pulls rclone+aws creds from cnpg-r2-creds secret" {
  grep -q 'name: cnpg-r2-creds' "$f"
}
@test "the manifest is wired into the kustomization (prune would delete it otherwise)" {
  # ⚠️ cnpg-data App은 prune:true + selfHeal:true라 resources에서 한 줄이 사라지는 것이 곧
  #    클러스터에서의 삭제다. 위 @test들은 파일을 직접 grep할 뿐 배선을 안 봐서, 배선을 지워도
  #    PR 게이트가 전건 초록이었다(실측). 사후 검출은 PgDumpHedgeStale뿐이다.
  # ⚠️ 원문 grep이 아니라 파싱된 resources를 본다 — 주석 줄·들여쓰기 어긋난 줄이 통과한다
  #    (tests/gates의 victoria-stack 배선 대조 @test가 세운 레포 관례).
  run yq '.resources | contains(["pgdump-hedge-cronjob.yaml"])' platform/cnpg/prod/kustomization.yaml
  printf '%s' "$output" | grep -qxF -- 'true'
}

@test "hedge dumps as the managed superuser so it captures all objects (not just app-owned)" {
  # app 롤은 postgres 소유 객체(restore_canary 등)를 LOCK/덤프하지 못해 실패한다(라이브 검증).
  # 완전한 논리 백업은 superuser로 떠야 한다 — pg-app-credentials가 아니라 pg-superuser를 쓴다.
  grep -q 'name: pg-superuser' "$f"
  run grep -q 'name: pg-app-credentials' "$f"
  [ "$status" -eq 1 ]
}
@test "hedge uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/ukyi-app/pg-tools:18-rclone' "$f"
}

@test "the live DBS token set equals exactly bootstrap app plus the present Database CRs" {
  # 헤지는 DB 단위 논리 백업이다 — databases/*.yaml의 Database CR이 DBS 목록에 빠지면
  # 그 DB는 barman 실패 시 복구 불가인데 알림은 녹색(job 완료 기반)인 무성 갭이 된다.
  # 새 DB 온보딩 시 이 테스트가 DBS 갱신을 강제한다. 실 도메인 권위는 이 @test다(픽스처는
  # 판정 함수의 감도를 재고, 여기가 실제 배포 대상을 잰다).
  dbs=$(sed -n 's/^ *DBS="\([^"]*\)".*/\1/p' "$f")
  [ -n "$dbs" ]   # DBS 줄 소실은 '정합'이 아니라 '못 읽었다'는 뜻이다
  findings=$(hedge_dbs_findings "$f" "$d")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 0 ]
}

@test "hedge waits for pg-rw to be reachable before pg_dump (kube-router rule-install gap)" {
  # libpq는 첫 연결 거부에서 즉시 포기 — 새 파드의 첫 ClusterIP 접속이 kube-router 룰 설치 전
  # 갭에 떨어지면 RST(Connection refused)로 job이 실패한다(라이브 검증). 도달 대기 루프가 필요.
  grep -q '/dev/tcp/pg-rw.database.svc/5432' "$f"
}
@test "hedge container is hardened (no privesc, all caps dropped, seccomp RuntimeDefault)" {
  grep -q 'allowPrivilegeEscalation: false' "$f"
  grep -qF 'drop: [ALL]' "$f"
  grep -q 'type: RuntimeDefault' "$f"
}

@test "the r4 hedge alert names the SAME prefix the cronjob writes to (drift guard)" {
  # 2026-08-18: r4의 PgDumpHedgeStale description이 Mac 시대 `pgdump/`를 가리킨 채 남아 있었다.
  # #0006이 경로 B를 `pgdump-nuc/`로 정정할 때 런북은 고쳤지만 알림 문구는 놓쳤다 — 온콜이
  # 새벽에 읽는 문장이 존재하지 않는 prefix를 가리키면 "덤프가 하나도 없다"는 오진으로 이어진다.
  # 리터럴을 유지하되(문장 가독성) 정본에서 파생해 대조한다.
  seg=$(sed -n 's|^ *DUMP_PREFIX="[^"]*/\([^"/]*\)".*|\1|p' "$f" | head -1)
  [ -n "$seg" ]
  r4=platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  desc=$(grep -n 'alert: PgDumpHedgeStale' -A8 "$r4" | grep 'description:')
  [ -n "$desc" ]
  case "$desc" in *"$seg/"*) ;; *) echo "r4 description이 DUMP_PREFIX의 마지막 세그먼트($seg/)를 안 담는다: $desc"; return 1;; esac
}

# ── 픽스처 레인 — 판정 함수의 감도를 재는 합성 트리 ────────────────────────────────────────────
# 실 트리는 DBS="app" · CR 0건이라 세 위반 클래스 어느 것도 밟지 못한다(그 자체가 초록의 근거이지
# 판정이 산다는 증거는 아니다). 픽스처가 각 클래스를 하나씩 깨워 판정 조건 전부에 증인을 붙인다.
#   $1 = 트리 이름 · $2 = DBS 토큰 목록(공백 구분)
hedge_fixture() {
  FX="$BATS_TEST_TMPDIR/$1"
  rm -rf "$FX"
  mkdir -p "$FX/databases"
  # 들여쓰기·인용은 실물과 같은 줄 문법이다(tools/lib/hedge-dbs.ts의 DBS_RE가 소유하는 형태).
  printf '                  DBS="%s"\n' "$2" > "$FX/hedge.yaml"
  # 실 databases/ 처럼 kustomization.yaml을 함께 둔다 — `kind: Database` 필터가 사라지면 이 행이
  # 이름 없는 CR로 읽혀 픽스처 전건이 red가 된다(필터의 증인이 실 트리 @test 하나뿐이지 않게 한다).
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: database\nresources: []\n' > "$FX/databases/kustomization.yaml"
}
# Database CR 하나 — $1 = metadata.name · $2 = spec.ensure(present|absent) · $3 = spec.name(기본 $1)
# ⚠️ **spec.name을 분리해서 받는다**(2026-09-09 적대 검토). 착지 전 픽스처는 두 이름에 같은 값을 써서
#    판정이 `head -1`(metadata.name)을 집는지 `tail -1`(spec.name)을 집는지에 **증인이 없었다** —
#    실측으로 추출을 `tail -1`로 뒤집어도 18건 전건 ok였다(무증인 판정 조건: AGENTS 함정 「테스트
#    이름은 인터페이스가 아니다」). 아래 name-mismatch 픽스처가 그 자리의 증인이다.
hedge_fixture_cr() {
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  name: %s\nspec:\n  ensure: %s\n  name: %s\n' "$1" "$2" "${3:-$1}" > "$FX/databases/$1.yaml"
}

@test "fixture: a consistent DBS and CR set yields no findings (positive control)" {
  hedge_fixture consistent "app shared"
  hedge_fixture_cr shared present
  hedge_fixture_cr dropped absent
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 0 ]
}

@test "fixture: a DBS token with no Database CR at all is caught as a ghost" {
  # 티켓 53의 축 — 상한 레인을 되돌리면 이 트리가 어느 DB 개수에서도 통과한다(반박자 재현
  # 2026-09-09: CR 0건 · absent 1건 · present 1건 세 트리 전부 10/10 ok). 뮤테이션 증인이다.
  hedge_fixture ghost "app ghostdb"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'ghost: ghostdb' <<<"$findings"
}

@test "fixture: a present Database CR missing from DBS is caught (lower bound)" {
  hedge_fixture lower "app"
  hedge_fixture_cr shared present
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'missing: shared' <<<"$findings"
}

@test "fixture: an absent Database CR still listed in DBS is caught (upper bound)" {
  hedge_fixture absent "app dropped"
  hedge_fixture_cr dropped absent
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'absent-in-dbs: dropped' <<<"$findings"
}

@test "fixture: the three violation classes are reported independently, not masked" {
  # 한 트리에 셋을 동시에 넣는다 — 클래스끼리 서로를 가리면(예: 유령 레인이 absent 잔존을 삼키면)
  # 진단이 한 줄로 뭉개져 위 세 @test가 각각 초록이어도 실 사고에서 원인을 못 가른다.
  hedge_fixture mixed "app dropped ghostdb"
  hedge_fixture_cr shared present
  hedge_fixture_cr dropped absent
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 3 ]
  grep -qxF -- 'missing: shared' <<<"$findings"
  grep -qxF -- 'absent-in-dbs: dropped' <<<"$findings"
  grep -qxF -- 'ghost: ghostdb' <<<"$findings"
}

@test "fixture: a missing bootstrap app token is caught" {
  # app은 CR 없이 항상 기대 집합에 있는 원소다 — 그 자리를 재는 증인이 픽스처에도 필요하다.
  hedge_fixture noapp "shared"
  hedge_fixture_cr shared present
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'missing: app' <<<"$findings"
}

@test "fixture: a Database CR with no metadata.name is reported, not silently skipped" {
  # 이름을 못 읽은 CR을 조용히 건너뛰면 그 DB가 기대 집합에서 통째로 빠져 하한이 vacuous가 된다 —
  # 열거 붕괴를 '정합'으로 읽는 자리라 판정이 red여야 한다.
  hedge_fixture noname "app"
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  labels: {}\nspec:\n  ensure: present\n' > "$FX/databases/broken.yaml"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'no-name: ' <<<"$findings"
}

@test "fixture: a vanished DBS line is a failure, not a silent pass" {
  # DBS 줄이 사라지면 헤지는 아무것도 덤프하지 않는데 job은 성공한다 — 무성 갭이라 판정도 red여야 한다.
  hedge_fixture nodbs "app"
  printf 'spec: {}\n' > "$FX/hedge.yaml"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'no-dbs-line:' <<<"$findings"
}

# ── 피연산자 바닥값 레인 — 열거가 붕괴하면 '정합'이 아니라 '못 읽었다'다 ───────────────────────
# 2026-09-09 적대 검토 실측: 판정 두 루프의 분모가 모두 피연산자에서 나오는데 그 실재를 재는
# 앵커가 없었다. `d=`를 없는 경로로 한 줄 바꾸면 18건 전건 ok(rc 0)였고, databases/를 리네임한
# 트리에서는 **DBS에 없는 present CR**이 있는데도 rc 0이었다 — 디렉토리 이름 변경 한 번이 상·하한을
# 통째로 끄고 @test 이름이 선언한 등식의 분모를 0으로 만든다.
# cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」 · scripts/check-bats-style.sh 「비공허 바닥값」

@test "fixture: a vanished hedge manifest is reported, not read as an empty token set" {
  hedge_fixture nomanifest "app"
  findings=$(hedge_dbs_findings "$FX/nope.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'no-hedge-manifest: ' <<<"$findings"
}

@test "fixture: a vanished Database CR directory is reported, not read as zero CRs" {
  # 이 트리는 present CR이 실재하는데 디렉토리 인자만 어긋난다 — 착지 전 판정은 여기서 위반 0건
  # (초록)을 냈다. 리팩터·이동·오타 한 번이 하한과 absent 레인을 함께 끄는 자리다.
  hedge_fixture nocrdir "app"
  hedge_fixture_cr shared present
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/nope")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'no-cr-dir: ' <<<"$findings"
}

@test "fixture: a second DBS line is diagnosed as a half-update, not as a set mismatch" {
  # 셸은 **마지막 대입**이 이기는데 sed는 매치를 전부 이어 붙인다 — 착지 전 판정은 2줄 트리에서
  # `missing: app` + `ghost: shared`를 냈다(원인은 '정합 위반'이 아니라 'DBS 줄이 2개'인데
  # 온콜이 읽는 문장이 엉뚱한 토큰을 가리킨다). tools/lib/hedge-dbs.ts matchDbs는 같은 상태를
  # throw로 내며 「절반 갱신은 조용히 지나가면 안 되는 부류」라고 못 박는다 — 손 편집된 실
  # 매니페스트에 대해서는 이 bats가 마지막 방어선이라 같은 실패 클래스를 표현해야 한다.
  hedge_fixture twolines "app"
  printf '                  DBS="app shared"\n' >> "$FX/hedge.yaml"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'dbs-lines: ' <<<"$findings"
}

# ── 이름 계약 레인 — DBS 토큰이 가리키는 것은 spec.name이다 ────────────────────────────────────
# 헤지가 실제로 실행하는 것은 `pg_dump --dbname="${DB}"`(pgdump-hedge-cronjob.yaml)이고, 그 DB는
# CNPG Database CR의 **spec.name**이다(형제 커널의 계약: tools/lib/resource-layout.ts의 hedgeEntry
# 주석 「DBS 토큰 = DB 이름(CR spec.name과 동일)」). provision-db가 두 이름에 같은 값을 쓰므로 정상
# 경로에서는 갈리지 않지만, 손 편집으로 갈리는 순간 판정이 **뒤집힌다** — 착지 전 실측:
#   metadata.name=objname · spec.name=realdb 일 때
#   DBS="app realdb"(pg_dump가 실제로 성공하는 목록) → missing:objname + ghost:realdb  = red
#   DBS="app objname"(pg_dump가 잡 전체를 죽이는 목록) → 위반 0건                       = green
# 즉 티켓 53이 막으려던 장애 형상을 초록으로 통과시키고 안전한 형상을 red로 만든다.

@test "fixture: a Database CR whose metadata.name and spec.name diverge is caught" {
  # 이 @test가 `head -1`/`tail -1` 선택의 증인이기도 하다 — 두 이름이 같은 픽스처만 있으면 추출을
  # 어느 쪽으로 뒤집어도 전건 초록이었다(2026-09-09 실측 18/18 ok).
  hedge_fixture divergent "app realdb"
  hedge_fixture_cr objname present realdb
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'name-mismatch: ' <<<"$findings"
  grep -qF -- '(objname != realdb)' <<<"$findings"
}

# ── 열거 폭 레인 — 분모가 실제로 CR 전부를 덮는가 ──────────────────────────────────────────────

@test "fixture: a present Database CR in a .yml file is inside the denominator" {
  # kustomize는 `.yaml`과 `.yml`을 둘 다 받는다. 글롭이 `*.yaml`뿐이면 `.yml` CR이 분모 밖이라
  # 그 DB가 DBS에 없어도 하한이 침묵한다(착지 전 실측: 위반 0건).
  hedge_fixture ymlcr "app"
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  name: ymldb\nspec:\n  ensure: present\n  name: ymldb\n' > "$FX/databases/ymldb.yml"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'missing: ymldb' <<<"$findings"
}

@test "fixture: two Database CRs in one file are rejected instead of silently losing the second" {
  # 이름 추출이 파일당 첫 도큐먼트만 집으므로 두 번째 CR은 **존재 자체가 사라진다** — 그 DB는
  # 논리 백업 0인데 판정은 초록인, 티켓 46이 막으려던 무성 커버리지 갭 그대로다(착지 전 실측:
  # a1+a2 한 파일 · DBS="app a1" → 위반 0건). 다중 도큐먼트 파서를 셸에 들이는 대신 fail-closed 한다.
  hedge_fixture multidoc "app a1"
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  name: a1\nspec:\n  ensure: present\n  name: a1\n---\napiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  name: a2\nspec:\n  ensure: present\n  name: a2\n' > "$FX/databases/multi.yaml"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qF -- 'multi-doc: ' <<<"$findings"
}

# ── 토큰 위생 레인 — 이름이 'equals exactly'를 선언하는 자리의 나머지 상한 ─────────────────────

@test "fixture: a DBS token repeated twice is caught (the equation is a multiset, not just a set)" {
  # 헤지 루프가 같은 DB를 두 번 pg_dump해 R2에 `${DB}-${TS}` 객체가 중복 생성되고 잡 시간이 는다.
  # 치명적이진 않지만 이름이 상한을 선언하는 자리라 무언(無言)으로 두지 않는다.
  hedge_fixture dup "app app"
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'dup: app' <<<"$findings"
}

@test "fixture: a DBS token holding a glob metacharacter is not expanded against the cwd" {
  # 토큰 루프가 무인용 확장이라 word splitting뿐 아니라 **pathname expansion**도 탄다. 착지 전
  # 실측: 레포 루트를 cwd로 DBS="app *"를 돌리면 저장소 엔트리 21건이 전부 `ghost: <파일명>`으로
  # 나왔다 — 진단이 무의미할 뿐 아니라 **판정 결과가 cwd의 파일 목록에 의존**한다(같은 매니페스트가
  # venue마다 다른 findings를 낸다). 정답은 위반 1건: 토큰 `*`는 CR이 없으므로 유령이다.
  hedge_fixture globtoken 'app *'
  findings=$(hedge_dbs_findings "$FX/hedge.yaml" "$FX/databases")
  n=$(hedge_dbs_count "$findings")
  echo "$findings"
  [ "$n" -eq 1 ]
  grep -qxF -- 'ghost: *' <<<"$findings"
}
