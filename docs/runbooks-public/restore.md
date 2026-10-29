# 복원: 영속 Valkey, 한 앱의 DB, 빈 NUC

데이터를 되돌리는 순서다. 근거는 설계 [C.5.6](../plans/2026-10-17-homelab-rebuild/platform/design.md)(Valkey), C.5.7(공유 PostgreSQL에서 한 앱만 복원), C.6.4(최초 연결과 재해 복구)다. CLI(`homelab db restore` 등, T12)가 생기기 전에는 사람이 이 문서를 따른다.

- 값은 출력하지 않는다. 비밀번호는 명령행 인자에 넣지 않고 표준 입력으로만 넘긴다(아래 0.3).
- 외부 변경(병합, 삭제)은 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄로 남긴다.
- 실행하다 이 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 공통 규칙

### 0.1 복원 리소스는 GitOps 밖이다

복원 Job, 임시 Cluster `pg-restore-*`, 도우미 Job은 Git에 두지 않는다. 사람이 `kubectl`로 만드는 일회성 객체라 Argo CD가 되돌리지도 치우지도 않는다(설계 C.5.7).

- 이름은 실행마다 고유하게(아래 `RUN`, 1절 Valkey 복원 Job만 예외), 라벨은 `homelab.ukyi.app/restore=<실행 id>`. 어느 앱의 복원인지는 실행 id와 함께 작업 기록에 남긴다.
- 같은 실행에서 다시 시도할 때: 1절의 수동 백업 Job은 시도마다 시도 id(`TRY`, 난수 4자)를 붙인 새 이름으로 만든다. 실패한 시도의 로그를 지우지 않고 남기려는 것이다. 1절의 Valkey 복원 Job은 실행 id와 무관하게 앱마다 이름 하나(`restore-vk`)다. 두 Job이 같은 PVC에 동시에 쓰면 안 되는데, 실행 id를 이름에 넣으면 새 셸에서 RUN을 새로 만들 때 이름이 달라 두 번째 `create`가 성공한다. 이름이 고정이면 API 서버가 같은 이름을 하나만 받으므로 그 자체가 잠금이다. 이미 있으면 `kubectl create`가 실패해 멈춘다. 다시 하려면 앞 Job이 끝났는지(또는 멈췄는지) 사람이 보고 지운 뒤 만든다. 띄워 두고 `exec`하는 도우미 Job(2절의 `-r2`·`-db`)은 이름으로 찾으므로 하나여야 해서, 블록이 먼저 지우고(파드까지) 새로 만든다. 정리는 둘 다 라벨로 한다.
- 명령은 bash와 zsh에서 같게 돌도록 썼다(따옴표 없는 변수의 단어 나누기에 기대지 않는다).
- 끝나면 지우고 0개를 확인한다. 옛 자동 드릴은 고아 클러스터·PVC를 다시 써서 거짓 PASS를 냈다.
- 앱 멈춤·재개와 Valkey 서버 내림·올림만 Git PR이다. selfHeal 때문에 `kubectl scale`은 되돌려진다(설계 B.8 E2).
- 필요한 권한은 사람 kubeconfig(cluster-admin)다. 봇 읽기 계정과 CI에는 없다.

```bash
export KUBECONFIG=~/.kube/homelab.yaml
set -o pipefail                   # 파이프 왼쪽(pg_dump 등)의 실패를 놓치지 않는다. 없으면 오른쪽이 성공하면 전체가 성공이다
APP=<앱 이름>
# 실행 id(22자): 초 단위 UTC 시각 + 난수 6자. 같은 분에 두 앱을 복원하거나 다시 시도해도 이름·라벨이 겹치지 않아
# 정리(라벨로 지우기)가 다른 실행의 PVC를 지우지 않는다. 이름에 앱 이름을 넣지 않는 이유는 2절 머리.
RUN=$(date -u +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
# 이 실행의 확인 표식(ok-<이름>)과 목록 파일. 값(비밀번호·데이터)은 두지 않는다.
W=$(mktemp -d "${TMPDIR:-/tmp}/restore-$RUN.XXXXXX")
need() { for g in "$@"; do [ -f "$W/ok-$g" ] || { echo "멈춤: '$g' 확인이 끝나지 않았다" >&2; return 1; }; done; }
# 2절 단계의 의존 관계. need(앞 표식 확인)와 begin(무효화)이 같은 표를 쓴다. 고칠 때 이 표만 고친다.
deps() { case $1 in
  vars) echo run ;; lock) echo run vars ;; predump|tmp|suspended|auth) echo run vars ;; list) echo tmp auth ;;
  db) echo predump tmp suspended auth list ;; main) echo db list ;; acl) echo main ;; verify) echo acl ;; esac; }
# 블록을 (다시) 시작할 때 그 단계와, 그 단계에 기대는 단계(표의 역방향, 끝까지)의 표식을 지운다.
# 같은 RUN으로 다시 돌릴 때 옛 표식이 남아 실패한 단계를 통과한 것처럼 보이지 않게.
begin() { local g; rm -f "$W/ok-$1"
  for g in vars lock predump tmp suspended auth list db main acl verify; do
    case " $(deps $g) " in *" $1 "*) begin $g ;; esac; done; }
# lock 뒤의 2절 단계는 이 실행이 그 앱 DB의 복원 잠금을 쥐고 있을 때만 돈다(mine, 2절 머리). 표식이 아니라 매번 클러스터에서 본다.
step() { begin "$1"; need $(deps "$1"); case $1 in run|vars|lock) ;; *) mine ;; esac; }
( set -euo pipefail; step run
  out=$(kubectl get cluster,job,pvc,configmap -A -l homelab.ukyi.app/restore=$RUN -o name)
  [ -z "$out" ]
  touch "$W/ok-run" )
[ -f "$W/ok-run" ] && echo "통과: run" || echo "멈춤: 실행 id가 겹치거나 조회에 실패했다. RUN을 다시 만든다"
```

**확인이 실패하면 멈춘다.** 확인 블록은 `( set -euo pipefail ... touch "$W/ok-<이름>" )` 한 줄 뒤에 `[ -f "$W/ok-<이름>" ]`로 판정하는 모양이다. 서브셸이라 블록 안의 명령 하나가 실패하면 그 블록만 끝나고(셸은 남는다), 마지막 줄의 표식이 생기지 않는다. 서브셸 뒤에 `&&`·`||`를 붙이거나 `if`의 조건으로 쓰지 않는다. bash와 zsh는 그 자리의 명령에 `set -e`를 적용하지 않아, 안에서 실패해도 다음 줄로 넘어간다(2a 시험에서 그렇게 DB가 지워지는 것을 봤다). 지우거나 되돌리기 어려운 단계(DB 삭제, 복원, 앱 재개)의 블록은 `need <앞 표식들>`로 시작해, 앞의 확인 하나라도 끝나지 않았으면 아무것도 하지 않는다. 블록 안 변수는 밖으로 나오지 않으므로 다음 블록이 쓸 값은 `$W`의 파일로 넘긴다. 블록은 `step <단계>`로 시작한다. 그 단계와 그 단계에 기대는 단계의 표식을 먼저 지우고(`begin`), 기대는 앞 단계의 표식을 확인한다(`need`). 무효화 범위는 `deps` 표의 의존 관계와 같다. 그래서 4-1·4-2를 3단계(앱 멈춤)보다 먼저 돌려도 3단계가 그 표식을 지우지 않고, 3단계를 다시 돌리면 그에 기대는 4-3 뒤만 다시 돌리면 된다(시나리오 10 실측: 단계 순서로 지우던 이전 모양은 4-3을 `auth` 없음으로 멈췄다). 같은 `RUN`으로 블록을 다시 돌리면 지워진 표식의 블록을 차례로 다시 돌린다.

**DB에서 읽은 이름은 믿지 않는다.** 확장·스키마 이름과 버전은 앱이 만든 값이다(앱 자격이 털렸으면 공격자가 고른 값). `postgres`로 실행하는 SQL에 문자열로 이어 붙이지 않는다. 정규식과 허용 목록으로 거른 뒤 psql 변수로 넘기고, 식별자는 `:"이름"`, 문자열은 `:'값'`으로 psql이 인용하게 한다. psql 변수는 `-c`에서는 치환되지 않아 SQL은 표준 입력으로 보낸다. 화면에 내보낼 때는 `cat -v`로 제어문자를 막는다.

### 0.2 확인은 라벨로

```bash
kubectl -n database get cluster,job,pvc -l homelab.ukyi.app/restore=$RUN       # PostgreSQL 복원 뒤 0개
kubectl -n app-$APP get job,pvc,configmap -l homelab.ukyi.app/restore=$RUN     # Valkey 복원·PostgreSQL 복원(앱 역할 Job, 잠금) 뒤 0개
```

### 0.3 Valkey에 인증해 명령 보내기

서버 컨테이너에는 비밀번호 env가 없다(ACL 파일에 해시만 있다). Secret 값을 표준 입력으로 넘긴다. `-a` 인자는 `ps`에 보인다.

```bash
vk() {  # 사용: vk DBSIZE / vk INFO persistence
  kubectl -n app-$APP get secret $APP-valkey-auth -o jsonpath='{.data.password}' | base64 -d \
    | kubectl -n app-$APP exec -i deploy/$APP-valkey -- sh -c 'IFS= read -r REDISCLI_AUTH || true; export REDISCLI_AUTH; valkey-cli "$@"' sh "$@"
}
```

## 1. 영속 Valkey 복원 (설계 C.5.6, 시나리오 4)

대상은 `data/<앱>/values.yaml`에 `valkey.persistent: true`인 앱이다. 백업은 매일 03:30 KST에 CronJob `<앱>-valkey-backup`이 R2 `valkey/<앱>/dump-<UTC 시각>.rdb`로 올리고 14일 뒤 R2 lifecycle이 지운다.

**왜 복원 모드가 필요한가:** `appendonly yes`인 채 시작하면 AOF가 RDB보다 이긴다. AOF 디렉터리를 지우고 `dump.rdb`만 두어도 Valkey 9.1.2는 RDB를 읽지 않고 빈 데이터로 시작해 빈 AOF를 새로 만든다(U18 로컬 실측, 2026-10-23). 그래서 RDB는 `appendonly no`(복원 모드)로 읽고, 읽은 뒤 실행 중에 AOF를 켠다.

**데이터 확인은 키 수 고정 비교가 아니라 검증 키로 한다.** 복원 뒤에도 TTL 만료와 앱의 정상 쓰기로 키 수는 바뀐다. 그리고 앱은 복원 중에도 돌아(1단계) 키를 새로 쓰므로, 키 수가 0이 아니라는 것만으로는 복원한 데이터가 남았는지 알 수 없다(재시작 때 다 사라져도 앱이 키 하나를 쓰면 0이 아니다). 그래서 3단계가 RDB를 읽은 직후 이 실행의 검증 키 `homelab:restore:<실행 id>`(값 `1`, 비밀 아님, 만료 없음)를 직접 쓴다. 4·5단계는 그 키가 있어야 통과한다. 재시작 뒤 없으면 빈 데이터나 옛 AOF로 뜬 것이다. 6단계에서 지운다. 키 이름은 앱의 키 공간에 잠깐 보인다. 키가 0개가 아닌지와, 운영자가 아는 만료 없는 앱 표식 키(`MARK`, 모르면 비워 둔다)가 있는지도 함께 본다. 복원 직후 키 수(`$W/vk-dbsize`)는 참고로만 보여 준다.

**검증 키는 백업에 섞여 돌아올 수 있다.** 3단계의 `running: true`는 백업 CronJob도 다시 켠다(`restoreMode`와 무관). 6단계 전에 정기 백업이 돌면 검증 키가 R2 백업에 들어가고, 6단계가 서버에서 지워도 그 백업에는 남는다. 그 백업을 다른 `RUN`으로 복원하면 옛 검증 키가 돌아온다. 이번 키만 빼고 세면 앱 키가 0개인 백업도 그 옛 키 하나로 3단계를 통과한다(#891 리뷰). 그래서 이 실행의 키 하나가 아니라 `homelab:restore:*` 전부를 앱 키 수에서 빼고(`vkapp`), 6단계에서 전부 지운다. CLI(`homelab cache restore`)도 같다.

변수 블록과 함수 블록을 차례로 정의한다. 함수 블록은 정의할 때 변수를 읽지 않는다(1.1은 `RUN`을 CLI 기록에서 얻어 함수 블록만 정의한다).

```bash
MARK=''    # 운영자가 아는 만료 없는 앱 표식 키(선택). 모르면 비워 둔다
VKEY="homelab:restore:$RUN"   # 3단계가 쓰는 이 실행의 검증 키. 같은 RUN의 재시도는 같은 키를 쓴다
```

```bash
# 숫자 하나인지. valkey-cli가 오류 문구를 내도 걸린다.
num() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
# 검증 키(homelab:restore:*) 목록, 한 줄에 하나. 이 실행 것만이 아니다(백업에서 돌아온 옛 RUN 것, 위). KEYS는 서버를 막아
# SCAN(valkey-cli --scan)으로 본다. SCAN은 같은 키를 두 번 낼 수 있어 sort -u. 꼴이 다른 줄(오류 문구 등)이 있으면 실패한다.
# grep 종료 코드는 ||로 받는다. set -e 블록에서 정상인 1(모두 맞음)에 끝나지 않게(zsh는 명령 치환 안에도 set -e가 걸린다).
vkmarks() { local s c=0
  s=$(vk --scan --pattern 'homelab:restore:*') || return 1
  s=$(printf '%s\n' "$s" | tr -d '\r' | sed '/^$/d' | LC_ALL=C sort -u) || return 1
  [ -n "$s" ] || return 0
  printf '%s\n' "$s" | LC_ALL=C grep -avqE '^homelab:restore:[a-z0-9][a-z0-9-]*$' || c=$?
  [ "$c" -eq 1 ] || { echo "검증 키 목록에 꼴이 다른 줄이 있다(grep $c)" >&2; return 1; }
  printf '%s\n' "$s"; }
# 앱 키 수: DBSIZE에서 검증 키를 모두 뺀 값. 둘을 한 번에 읽지 않아 그 사이 앱 쓰기만큼 어긋날 수 있다.
vkapp() { local n m k=0; n=$(vk DBSIZE) || return 1
  num "$n" || { echo "DBSIZE가 숫자가 아니다($(printf '%s' "$n" | cat -v))" >&2; return 1; }
  m=$(vkmarks) || return 1; [ -z "$m" ] || k=$(printf '%s\n' "$m" | wc -l | tr -d ' ')
  echo $((n - k)); }
# CONFIG GET appendonly의 값(둘째 줄).
vkaof() { local a; a=$(vk CONFIG GET appendonly) || return 1; printf '%s\n' "$a" | tr -d '\r' | sed -n 2p; }
# AOF가 지금 데이터로 다 쓰였는지(INFO persistence 넷 다). 함정: RDB 저장(BGSAVE, 기본 save 지점) 중에 AOF를 켜면
# Valkey 9.1.2는 첫 AOF 생성을 예약만 해 aof_enabled:1·aof_rewrite_in_progress:0·status ok인 채 aof_rewrite_scheduled:1이다
# (로컬 실측, 저장이 끝나야 rewrite가 시작된다). 이때 재시작하면 AOF가 없거나 옛 것이라 데이터가 비거나 옛 상태로 돌아간다.
# INFO 줄 끝에는 CR이 있다.
aofok() { printf '%s\n' "$1" | tr -d '\r' | awk -F: '{ v[$1] = $2 } END { exit !(v["aof_enabled"] == "1" &&
  v["aof_rewrite_in_progress"] == "0" && v["aof_rewrite_scheduled"] == "0" && v["aof_last_bgrewrite_status"] == "ok") }'; }
# 지금 데이터가 이 복원의 것인지: 키가 0개가 아니고, 검증 키가 있고, 표식 키를 적었으면 그 키도 있다.
# 아니면 지금 값을 알리고 실패한다. 3단계가 검증 키를 쓰기 전에는 부르지 않는다.
vkdata() { local n v m=-; n=$(vk DBSIZE) || return 1; v=$(vk EXISTS "$VKEY") || return 1
  if [ -n "${MARK:-}" ]; then m=$(vk EXISTS "$MARK") || return 1; fi
  if num "$n" && [ "$n" -gt 0 ] && [ "$v" = 1 ] && { [ -z "${MARK:-}" ] || [ "$m" = 1 ]; }; then return 0; fi
  echo "키 수 $(printf '%s' "$n" | cat -v), 검증 키 $(printf '%s' "$v" | cat -v)(1이어야 한다), 표식 키 $(printf '%s' "$m" | cat -v)(적었으면 1). 복원 직후 키 수 $(cat "$W/vk-dbsize" 2>/dev/null || echo '?')" >&2
  return 1; }
```

0. 백업이 있는지 본다. 수동 백업이 필요하면(시나리오 4) 지금 하나 만든다.

   ```bash
   TRY=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')        # 시도마다 새로. 실패 뒤 다시 만들 때 이름이 겹치지 않는다
   # 한 블록이다. 라벨(0.2·6단계의 라벨 확인)은 만드는 요청에 함께 넣는다. 만든 뒤 따로 label하면 그게 실패할 때
   # 백업은 돌고 라벨 없는 Job이 남아 6단계 정리에서 빠진다.
   ( set -euo pipefail
   kubectl -n app-$APP create job --from=cronjob/$APP-valkey-backup backup-$RUN-$TRY --dry-run=client -o yaml \
     | kubectl label --local -f - homelab.ukyi.app/restore=$RUN -o yaml \
     | kubectl -n app-$APP create -f -
   kubectl -n app-$APP wait --for=condition=complete job/backup-$RUN-$TRY --timeout=10m
   kubectl -n app-$APP logs job/backup-$RUN-$TRY -c upload       # "올림: r2:<버킷>/valkey/<앱>/dump-....rdb"
   )
   [ $? -eq 0 ] && echo "수동 백업 끝" || echo "멈춤: 수동 백업 Job을 만들지 못했거나 끝나지 않았다. 'kubectl -n app-$APP get job -l homelab.ukyi.app/restore=$RUN'으로 본다"
   ```

1. **서버 내림(PR):** `data/<앱>/values.yaml`의 `valkey`에 `running: false`. 병합 뒤 Deployment `<앱>-valkey`가 없고 PVC `valkey-data`는 남는지, 백업 CronJob이 `SUSPEND True`인지 본다. 앱은 Valkey 오류를 내지만 계속 돈다.

   ```bash
   kubectl -n app-$APP get deploy,pvc,cronjob
   ```

2. **복원 Job:** PVC에 RDB를 `dump.rdb`로 두고 `appendonlydir`을 지운다. 이 PVC에는 한 번에 파드 하나만 써야 한다. 두 파드가 함께 돌면 `/data/dump.rdb.new` 받기·옮기기와 `appendonlydir` 지우기가 섞인다. `ReadWriteOnce`는 같은 노드의 여러 파드를 막지 않는다. 그래서 두 겹으로 막는다.
   - Job 이름은 실행 id와 무관하게 앱마다 하나(`restore-vk`)다. 앞 Job이 남아 있으면 RUN이 달라도 `kubectl create`가 `AlreadyExists`로 실패한다(API 서버가 이름을 원자적으로 하나만 받는다).
   - 만들기 직전에 그 ns에서 `valkey-data`를 마운트하는 끝나지 않은 파드와, 그 PVC를 마운트하는 끝나지 않은 Job(이름·라벨 무관)이 하나라도 있으면 멈춘다. 이름이 다른 옛 모양(`restore-<실행 id>-vk`, `restore-<실행 id>-vk-<시도 id>`)의 Job, 지우는 중(Terminating)인 파드, 아직 내려가지 않은 서버 파드가 여기에 걸린다.
   - 다시 하려면 `kubectl -n app-$APP get job,pod -L homelab.ukyi.app/restore`로 앞 Job이 끝났는지(또는 멈췄는지)와 어느 실행의 것인지 보고, 로그를 남긴 뒤 지우고(파드가 없어질 때까지) 만든다.

   `OBJECT=latest`면 가장 최근 것이다(이름이 UTC 시각이라 정렬이 시각순). 특정 시점이면 파일 이름을 적는다. 서버가 uid 1000으로 쓴 파일을 지워야 해서 같은 uid로 돈다(local-retain hostPath PV에는 fsGroup이 적용되지 않는다).

   ```bash
   OBJECT=latest
   # 한 블록이다. 앞 확인에 걸리거나 restore-vk가 이미 있으면 이 블록은 거기서 끝난다(뒤의 wait·logs가 앞 Job을 보지 않게).
   ( set -euo pipefail
   # 이 PVC를 쓰는(쓸) 것이 남아 있으면 멈춘다. 이름·라벨로 거르지 않는다(옛 이름의 Job, 서버 파드도 걸리게).
   # 파드: Succeeded·Failed가 아니면(지우는 중 포함) 아직 쓸 수 있다. Job: Complete·Failed 조건이 없으면 파드를 다시 만들 수 있다.
   pods=$(kubectl -n app-$APP get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')
   jobs=$(kubectl -n app-$APP get job -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.status=="True")].type}{"\t"}{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')
   bp=$(printf '%s\n' "$pods" | awk -F'\t' '$2 != "Succeeded" && $2 != "Failed" && (" " $3 " ") ~ / valkey-data / { print "pod/" $1 }')
   bj=$(printf '%s\n' "$jobs" | awk -F'\t' '(" " $2 " ") !~ / (Complete|Failed) / && (" " $3 " ") ~ / valkey-data / { print "job/" $1 }')
   if [ -n "$bp$bj" ]; then printf '%s\n' "$bp" "$bj" | cat -v >&2
     echo "valkey-data를 쓰는 파드·Job이 남아 있다(위). 끝났는지 보고 지운 뒤 다시 한다" >&2; exit 1; fi
   BUCKET=$(kubectl -n app-$APP get cronjob $APP-valkey-backup \
     -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="BUCKET")].value}')
   kubectl create -f - <<EOF
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: restore-vk
     namespace: app-$APP
     labels: { homelab.ukyi.app/restore: "$RUN" }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 900
     template:
       metadata:
         # 백업 Job의 NetworkPolicy(<앱>-valkey-backup, R2 443과 DNS)를 같이 쓴다.
         labels: { homelab.ukyi.app/restore: "$RUN", homelab.ukyi.app/role: valkey-backup }
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: restore
             image: docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
             command: ["/bin/sh", "-c"]
             args:
               - |
                 set -eu
                 dir="r2:\${BUCKET}/valkey/\${APP}"
                 obj="\${OBJECT}"
                 [ "\$obj" = latest ] && obj="\$(rclone lsf "\$dir" | sort | tail -1)"
                 [ -n "\$obj" ] || { echo "백업이 없다: \$dir" >&2; exit 1; }
                 echo "받음: \$dir/\$obj"
                 rclone copyto "\$dir/\$obj" /data/dump.rdb.new
                 test -s /data/dump.rdb.new
                 rm -rf /data/appendonlydir
                 mv /data/dump.rdb.new /data/dump.rdb
                 ls -la /data
             env:
               - { name: APP, value: "$APP" }
               - { name: BUCKET, value: "$BUCKET" }
               - { name: OBJECT, value: "$OBJECT" }
               - { name: HOME, value: /tmp }
               - { name: RCLONE_CONFIG_R2_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_R2_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_R2_REGION, value: auto }
               - { name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_R2_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: $APP-valkey-backup-r2, key: R2_ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: $APP-valkey-backup-r2, key: R2_SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_R2_ENDPOINT, valueFrom: { secretKeyRef: { name: $APP-valkey-backup-r2, key: R2_ENDPOINT } } }
             resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { memory: 64Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts:
               - { name: data, mountPath: /data }
               - { name: tmp, mountPath: /tmp }
         volumes:
           - { name: data, persistentVolumeClaim: { claimName: valkey-data } }
           - { name: tmp, emptyDir: { sizeLimit: 16Mi } }
   EOF
   kubectl -n app-$APP wait --for=condition=complete job/restore-vk --timeout=15m
   kubectl -n app-$APP logs job/restore-vk          # 받은 객체와 /data의 dump.rdb, appendonlydir 없음
   )
   # 서브셸 뒤에 ||·&&를 붙이지 않는다(그 자리에서는 안의 set -e가 꺼진다, 0.1). 종료 코드는 다음 줄에서 본다.
   [ $? -eq 0 ] && echo "복원 Job 끝" || echo "멈춤: 복원 Job을 만들지 못했거나 끝나지 않았다. 'kubectl -n app-$APP get job,pod -L homelab.ukyi.app/restore'로 앞 Job을 본다"
   ```

3. **복원 모드로 올림(PR):** `running: true`와 `restoreMode: true`를 함께. 새 파드가 `appendonly no`로 떠 RDB를 읽는다. 앱 키(검증 키 `homelab:restore:*`를 모두 뺀 수)가 0개가 아닌지, 표식 키를 적었으면 그 키가 있고 만료 시간이 없는지 보고, 복원 직후 키 수를 적어 둔 뒤 검증 키를 쓴다. 다시 돌리면 검증 키를 다시 쓰고 4·5단계 표식도 지운다(그 뒤 단계를 다시 한다). 4단계가 "검증 키 0"으로 멈추면(복원 모드인 채 서버가 다시 떠 RDB를 다시 읽었다) 이 단계부터 다시 한다.

   ```bash
   ( set -euo pipefail
   rm -f "$W/ok-vk-loaded" "$W/ok-vk-aof" "$W/ok-vk-reloaded"
   kubectl -n app-$APP rollout status deploy/$APP-valkey --timeout=5m
   a=$(vkaof); [ "$a" = no ] || { echo "복원 모드가 아니다(appendonly $(printf '%s' "$a" | cat -v)). restoreMode가 반영됐는지 본다" >&2; exit 1; }
   # 검증 키는 모두 빼고 센다. 다시 돌릴 때 앞에서 쓴 이번 키도, 백업에서 돌아온 옛 RUN 키도 앱 데이터가 아니다.
   n=$(vkapp)
   if [ "$n" -le 0 ]; then echo "앱 키가 0개다(검증 키 homelab:restore:*는 빼고 센다). 받은 RDB가 비었거나 읽히지 않았다" >&2; exit 1; fi
   if [ -n "${MARK:-}" ]; then
     m=$(vk EXISTS "$MARK"); [ "$m" = 1 ] || { echo "표식 키가 없다" >&2; exit 1; }
     t=$(vk TTL "$MARK"); [ "$t" = -1 ] || { echo "표식 키에 만료 시간이 있다(TTL $(printf '%s' "$t" | cat -v)). 만료 시간이 없는 키를 고르거나 비워 둔다" >&2; exit 1; }
   fi
   printf '%s\n' "$n" > "$W/vk-dbsize"
   r=$(vk SET "$VKEY" 1); [ "$r" = OK ] || { printf '%s\n' "$r" | cat -v >&2; exit 1; }
   t=$(vk TTL "$VKEY"); [ "$t" = -1 ] || { echo "검증 키의 TTL이 $(printf '%s' "$t" | cat -v)다" >&2; exit 1; }
   vkdata
   touch "$W/ok-vk-loaded" )
   [ -f "$W/ok-vk-loaded" ] && echo "복원 모드로 읽음: 앱 키 $(cat "$W/vk-dbsize")개" || echo "멈춤: 복원 모드로 읽지 못했거나 앱 키가 0개이거나 적은 표식 키가 없다(위)"
   ```

4. **AOF 다시 켜기:** 실행 중에 켜면 지금 데이터로 AOF base를 새로 쓴다. 켜기 전에 데이터(검증 키 포함)를 본다(빈 데이터를 AOF로 굳히지 않게). `CONFIG SET appendonly yes`는 그 자리에서 rewrite를 시작하거나(`aof_rewrite_in_progress:1`) 예약한다(`aof_rewrite_scheduled:1`, 위 함정). 그래서 진행·예약이 모두 0이고 성공했을 때(`aofok`) 그 rewrite가 끝난 것이다. 예약 상태는 RDB 저장이 끝난 뒤 rewrite가 시작될 때까지 기다린다. 10분 안에 끝나지 않으면 멈춘다. 다시 돌려도 된다. 이미 켜져 있으면(예: 서버가 AOF 설정으로 다시 떠 AOF를 읽었다) `CONFIG SET`은 아무것도 바꾸지 않고 상태만 다시 본다. `aof_rewrites` 같은 횟수는 보지 않는다(서버가 다시 뜨면 0으로 돌아간다).

   ```bash
   ( set -euo pipefail
   rm -f "$W/ok-vk-aof" "$W/ok-vk-reloaded"
   [ -f "$W/ok-vk-loaded" ] || { echo "멈춤: 3단계 확인이 끝나지 않았다" >&2; exit 1; }
   vkdata
   r=$(vk CONFIG SET appendonly yes); [ "$r" = OK ] || { printf '%s\n' "$r" | cat -v >&2; exit 1; }
   i=0
   while :; do
     info=$(vk INFO persistence)
     if aofok "$info"; then break; fi
     i=$((i + 1)); [ "$i" -lt 120 ] || { echo "AOF rewrite가 10분 안에 끝나지 않았다" >&2
       printf '%s\n' "$info" | tr -d '\r' | grep -E '^(aof_|rdb_bgsave_in_progress)' | cat -v >&2; exit 1; }
     sleep 5
   done
   vkdata
   touch "$W/ok-vk-aof" )
   [ -f "$W/ok-vk-aof" ] && echo "AOF 다 씀" || echo "멈춤: AOF를 켜지 못했거나 rewrite가 끝나지 않았다(위). 데이터가 없으면 켜지 않았다. 검증 키만 0이면 3단계부터 다시 한다"
   ```

5. **복원 모드 끄기(PR):** `restoreMode`와 `running` 줄을 지운다. ConfigMap만 바뀌고 파드는 그대로다(실행 중 설정은 이미 AOF on). 병합 뒤 서버를 한 번 다시 띄워 AOF에서 다시 읽히는지 본다(검증 키가 있는지, 키가 0개가 아닌지, 표식 키를 적었으면 있는지). 검증 키가 없으면 앱이 새로 쓴 키가 있어도 멈춘다.

   **PR을 기다리는 동안 서버가 다시 떴을 수 있다.** 복원 모드 설정으로 다시 떴으면 `appendonly no`로 돌아가 AOF가 없는 상태다. 그대로 다시 띄우면 데이터가 비거나 옛 상태로 돌아간다. 그래서 다시 띄우기 직전에 ConfigMap에 복원 모드가 없는지, 실행 중 `appendonly`가 yes인지, AOF가 다 쓰였는지(`aofok`), 데이터가 있는지를 다시 본다. `appendonly`나 AOF 상태가 다르면 블록이 4단계 표식을 지우고 멈춘다. 그때는 4단계부터 다시 하고 이 블록을 다시 돌린다. 데이터가 없으면(검증 키 없음, 0개, 또는 적은 표식 키 없음) 다시 띄우지 않고 멈춘다. 원인(언제 다시 떴는지, 파드 로그)을 본 뒤 1단계(서버 내림)부터 다시 한다.

   다시 띄우기는 `rollout restart`(Deployment 업데이트)로 한다. 파드를 직접 지우지 않는다. `Recreate`가 "옛 파드가 모두 끝난 뒤 새 파드를 만든다"를 보장하는 것은 Deployment 업데이트 때뿐이다. 파드를 지우면 ReplicaSet이 옛 파드가 끝나기(Terminating) 전에 새 파드를 만들어, 두 서버가 같은 PVC의 AOF·RDB를 함께 쓴다(로컬 kind 1.37 실측: 직접 삭제는 약 14초 겹침, `rollout restart`는 겹침 없음). Argo CD는 `rollout restart`가 더하는 주석을 되돌리지 않는다(Git에 없는 필드라 비교하지 않는다, rotate.md와 같다).

   ```bash
   ( set -euo pipefail
   rm -f "$W/ok-vk-reloaded"
   [ -f "$W/ok-vk-aof" ] || { echo "멈춤: 4단계 확인이 끝나지 않았다" >&2; exit 1; }
   # 병합이 반영됐는지: 덮어쓰기 ConfigMap에 appendonly no가 남아 있으면 다시 띄울 때 복원 모드로 뜬다.
   ov=$(kubectl -n app-$APP get configmap valkey-overrides -o jsonpath='{.data.overrides\.conf}')
   if printf '%s\n' "$ov" | grep -Eq '^[[:space:]]*appendonly[[:space:]]+no'; then
     echo "ConfigMap valkey-overrides에 아직 복원 모드가 있다. PR 병합과 Argo CD 동기화를 기다린다" >&2; exit 1; fi
   # 재시작 전 다시 보기(PR 대기 중 서버가 다시 떴을 수 있다). 다르면 4단계부터.
   a=$(vkaof)
   if [ "$a" != yes ]; then rm -f "$W/ok-vk-aof"
     echo "appendonly가 $(printf '%s' "$a" | cat -v)다(PR 대기 중 서버가 다시 떴다). 4단계부터 다시 한다" >&2; exit 1; fi
   info=$(vk INFO persistence)
   if ! aofok "$info"; then rm -f "$W/ok-vk-aof"
     printf '%s\n' "$info" | tr -d '\r' | grep -E '^(aof_|rdb_bgsave_in_progress)' | cat -v >&2
     echo "AOF가 다 쓰이지 않았다(진행·예약 중이거나 실패, 위). 4단계부터 다시 한다" >&2; exit 1; fi
   vkdata
   kubectl -n app-$APP rollout restart deploy/$APP-valkey
   kubectl -n app-$APP rollout status deploy/$APP-valkey --timeout=5m
   a=$(vkaof); [ "$a" = yes ] || { echo "다시 띄운 뒤 appendonly가 $(printf '%s' "$a" | cat -v)다" >&2; exit 1; }
   vkdata
   touch "$W/ok-vk-reloaded" )
   [ -f "$W/ok-vk-reloaded" ] && echo "AOF에서 다시 읽음" || echo "멈춤: 위 이유를 본다. '4단계부터'면 4단계와 이 블록을, 데이터가 없으면 더 다시 띄우지 말고 원인을 본 뒤 1단계(서버 내림)부터 한다"
   kubectl -n app-$APP get cronjob $APP-valkey-backup   # SUSPEND False
   ```

6. **정리:** 이 실행의 Job(수동 백업·복원의 모든 시도)을 라벨로 지우고 0.2의 확인이 0개인지 본다. 검증 키는 이 실행 것만이 아니라 남은 `homelab:restore:*`를 전부 지우고(백업에서 돌아온 옛 RUN 것. 남기면 다음 정기 백업이 또 가져간다) 0개인지 본다. 검증 키는 서버가 떠 있을 때만 지울 수 있다. 중간에 그만둔 실행이면 서버가 뜬 뒤 이 블록을 다시 돌린다(다음 복원의 3단계는 남은 키를 빼고 센다).

   ```bash
   ( set -euo pipefail
   rm -f "$W/ok-vk-clean"
   # foreground: 파드까지 없어진 뒤 돌아온다. 기본(background)은 Job만 먼저 지워, 실행 라벨이 없는 수동 백업 파드가
   # 아래 라벨 확인에 걸리지 않은 채 남는다(그 파드 템플릿에는 실행 라벨이 없다). Job이 이미 지워진 재시도에 남은
   # 복원 Job 파드는 직접 지운다. 그때 남은 수동 백업 파드는 이 블록이 찾지 못한다(1.1은 기록의 backup.jobs로 본다).
   kubectl -n app-$APP delete job -l homelab.ukyi.app/restore=$RUN --cascade=foreground --timeout=5m
   kubectl -n app-$APP delete pod -l homelab.ukyi.app/restore=$RUN --timeout=5m
   out=$(kubectl -n app-$APP get job,pod,pvc -l homelab.ukyi.app/restore=$RUN -o name)
   if [ -n "$out" ]; then printf '%s\n' "$out" | cat -v >&2; echo "이 실행의 객체가 남았다(위)" >&2; exit 1; fi
   mk=$(vkmarks)
   # vk 안의 명령이 루프의 입력(키 목록)을 읽지 않게 /dev/null을 준다. DEL의 답은 1(지움)이나 0(이미 없음)이다.
   while IFS= read -r k; do
     [ -n "$k" ] || continue
     r=$(vk DEL "$k" </dev/null); case $r in 0|1) ;; *) printf '%s\n' "$r" | cat -v >&2; exit 1 ;; esac
   done <<<"$mk"
   left=$(vkmarks)
   if [ -n "$left" ]; then printf '%s\n' "$left" | cat -v >&2; echo "검증 키가 남았다(위)" >&2; exit 1; fi
   touch "$W/ok-vk-clean" )
   [ -f "$W/ok-vk-clean" ] && echo "정리 끝: 이 실행의 Job 0개, 검증 키 0개" || echo "멈춤: 위 이유를 본다. 서버가 떠 있지 않아 검증 키를 못 지웠으면 뜬 뒤 다시 돌린다"
   ```

백업 Job의 ACL은 `default` 사용자(`~* &* +@all`)다. 사용자를 나누면 `--rdb`에는 `sync`·`replconf`가 필요하다(U18 실측: 없으면 `NOPERM ... 'sync'`).

### 1.1 CLI `cache restore`가 복원 표식 키를 잃고 멈췄을 때

CLI `homelab cache restore <앱>`은 이 절의 검증 키를 복원 표식 키라 부른다(`homelab:restore:<CLI 실행 id>`). 5단계의 재시작 전이나 뒤에 그 키가 없으면 "복원 표식 키 …이 없다"로 멈추고, 실행 기록(앱 ns의 ConfigMap `restore-vk`)에 `suspect.marker`를 남긴다. 그 뒤로는 같은 명령을 다시 쳐도, `--accept-empty`·`--abort`·`--finish`를 붙여도 모두 멈춘다. 키 수로는 "복원한 키가 다 사라지고 앱이 새 키를 썼다"를 가릴 수 없어 CLI가 판단하지 않는다. 표식 키를 다시 넣어도 기록이 남아 풀리지 않는다. 사람이 데이터를 보고 아래 3의 둘 중 하나로 끝낸다.

1. **기록 읽기.** 값은 비밀이 아니다(실행 id, 받은 객체, 키 수, 끝낸 단계 표시).

   ```bash
   export KUBECONFIG=~/.kube/homelab.yaml
   APP=<앱 이름>
   kubectl -n app-$APP get configmap restore-vk -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' | cat -v
   ```

   - `run`: CLI 실행 id. 표식 키는 `homelab:restore:<run>`, Job 라벨은 `homelab.ukyi.app/restore=<run>`이다.
   - `got`: 복원 Job이 받은 백업 객체(`r2:<버킷>/valkey/<앱>/dump-<UTC>.rdb`).
   - `dbsize`: RDB를 읽은 직후의 앱 키 수(표식 키 제외). `dbsize.pre`: 첫 재시작 직전의 앱 키 수. 없으면 재시작 전에 멈췄다.
   - `suspect.marker=1`이 이 멈춤이다. `suspect.empty=1`이 함께 있으면 앱 키 0개도 본 적이 있다. `ok.*`는 끝낸 단계다.

2. **데이터 확인.** 값은 보지 않는다. 키 수, 표식 키, AOF 상태만 본다. 먼저 CLI 기록의 실행 id를 `RUN`으로 읽고 꼴을 본다. 0.1 블록과 1절 머리의 변수 블록은 돌리지 않는다(0.1은 새 `RUN`을 만든다).

   ```bash
   RUN=$(kubectl -n app-$APP get configmap restore-vk -o jsonpath='{.data.run}')
   case $RUN in ''|*[!a-z0-9]*) echo "멈춤: 기록의 run을 읽지 못했거나 꼴이 아니다. 더 하지 않는다" >&2 ;; *) echo "CLI 실행 id: $RUN" ;; esac
   MARK=''    # 운영자가 아는 만료 없는 앱 표식 키(1절 머리와 같다). 모르면 비워 둔다
   ```

   그다음 0.3의 `vk`와 1절 머리의 함수 블록을 이 셸에 정의하고 확인한다.

   ```bash
   ( set -euo pipefail
   case $RUN in ''|*[!a-z0-9]*) echo "기록의 run 꼴이 아니다" >&2; exit 1 ;; esac
   ov=$(kubectl -n app-$APP get configmap valkey-overrides -o jsonpath='{.data.overrides\.conf}')
   if printf '%s\n' "$ov" | grep -Eq '^[[:space:]]*appendonly[[:space:]]+no'; then echo "ConfigMap: 복원 모드가 남아 있다"; else echo "ConfigMap: 복원 모드 없음"; fi
   a=$(vkaof); echo "실행 중 appendonly: $(printf '%s' "$a" | cat -v)"
   info=$(vk INFO persistence)
   if aofok "$info"; then echo "AOF: 다 씀"; else echo "AOF: 다 쓰이지 않음(아래)"
     printf '%s\n' "$info" | tr -d '\r' | grep -E '^(aof_|rdb_bgsave_in_progress)' | cat -v || true; fi
   n=$(vkapp); echo "앱 키: ${n}개(기록의 dbsize·dbsize.pre와 견준다. TTL 만료와 앱 쓰기로 달라도 된다)"
   mk=$(vkmarks); k=0; [ -z "$mk" ] || k=$(printf '%s\n' "$mk" | wc -l | tr -d ' ')
   v=$(vk EXISTS "homelab:restore:$RUN"); echo "표식 키: 모두 ${k}개, 이 실행 것 $(printf '%s' "$v" | cat -v)"
   if [ -n "${MARK:-}" ]; then m=$(vk EXISTS "$MARK"); t=$(vk TTL "$MARK")
     echo "앱 표식 키: 있음 $(printf '%s' "$m" | cat -v)(1이어야 한다), TTL $(printf '%s' "$t" | cat -v)(-1이어야 한다)"; fi
   kubectl -n app-$APP get cronjob $APP-valkey-backup )    # SUSPEND False
   [ $? -eq 0 ] || echo "멈춤: 확인을 마치지 못했다(위). 판단하지 않는다"
   ```

3. **판단.** 아래가 모두 맞으면 **데이터가 맞다**:
   - ConfigMap에 복원 모드가 없고, 실행 중 `appendonly`가 yes이고, AOF가 다 쓰였다.
   - 앱 키가 0개가 아니다. 앱이 다 지운 것이 정상이라고 알면 0개도 된다.
   - `MARK`를 적었으면 있고 TTL이 -1이다.
   - 앱에서 보이는 데이터(예: 세션, 큐)가 받은 백업 시점에서 이어진다.

   이 실행의 표식 키가 다시 보이는 것은 근거가 아니다(누가 다시 넣었을 수 있다). `MARK`도 없고 앱으로도 가릴 수 없으면 맞지 않은 쪽으로 본다.

   **맞으면:** 4(표식 키 지우기)와 5(기록 지우기)로 끝낸다. CLI가 못 한 판단과 정리를 사람이 대신한다. 나머지는 맞는데 `appendonly`가 no이거나 AOF가 다 쓰이지 않았으면 그대로 끝내지 않는다. 다음 재시작이 디스크의 옛 AOF를 읽어 그사이 쓰기를 잃는다. 4단계처럼 켜고 기다린 뒤 2를 다시 돌린다.

   ```bash
   ( set -euo pipefail
   r=$(vk CONFIG SET appendonly yes); [ "$r" = OK ] || { printf '%s\n' "$r" | cat -v >&2; exit 1; }
   i=0
   while :; do
     info=$(vk INFO persistence)
     if aofok "$info"; then break; fi
     i=$((i + 1)); [ "$i" -lt 120 ] || { echo "AOF rewrite가 10분 안에 끝나지 않았다" >&2; exit 1; }
     sleep 5
   done )
   [ $? -eq 0 ] && echo "AOF 다 씀. 2를 다시 돌린다" || echo "멈춤: AOF를 켜지 못했거나 rewrite가 끝나지 않았다(위)"
   ```

   **맞지 않으면:** 복원한 데이터를 잃었다고 본다. 5로 이 실행의 Job과 기록을 지운 뒤 1절을 처음부터 새 실행으로 한다(CLI든 이 문서든). 백업은 `latest`로 두지 않고 이름으로 고른다(CLI `--object dump-<UTC>.rdb`, 이 문서는 2단계 `OBJECT`). 3단계부터 정기 백업이 다시 돌아, `latest`가 복원 중(데이터를 잃은 뒤일 수 있다)에 찍은 것일 수 있다. 기본은 기록의 `got`보다 앞의 객체다. 표식 키는 복원 과정에서 사라진 것이라 `got`의 내용 탓은 아니다. `got`에 문제가 없었다고 판단하면 `got`을 다시 써도 된다.

4. **표식 키 지우기(맞을 때만).** 6단계 블록을 그대로 돌린다(`RUN`은 2의 값, `$W`가 없으면 먼저 `W=$(mktemp -d)`). "정리 끝"이 나와야 한다. 이번 키와 백업에서 돌아온 옛 키를 모두 지우고 이 실행의 Job도 지운다.

5. **기록 지우기.** 기록은 CLI의 잠금이다. 지우면 새 `cache restore`가 시작할 수 있어, 이 실행의 Job·파드(기록의 `backup.jobs`에 적힌 수동 백업 Job의 파드 포함)가 0개이고 다른 복원이 없을 때만 지운다.

   ```bash
   ( set -euo pipefail
   case $RUN in ''|*[!a-z0-9]*) echo "RUN 꼴이 아니다" >&2; exit 1 ;; esac
   # 2에서 본 그 실행의 기록인지 먼저 본다(수동 백업 Job 이름을 이 기록에서 읽는다). 지우기 직전에 한 번 더 본다.
   r=$(kubectl -n app-$APP get configmap restore-vk -o jsonpath='{.data.run}')
   [ "$r" = "$RUN" ] || { echo "기록의 run이 $(printf '%s' "$r" | cat -v)다(2에서 본 것과 다르다)" >&2; exit 1; }
   bjobs=$(kubectl -n app-$APP get configmap restore-vk -o jsonpath='{.data.backup\.jobs}')
   # 이 실행의 Job(복원 Job restore-vk, 수동 백업 backup-<run>-<시도>). foreground라 파드까지 없어진 뒤 돌아온다.
   # Job이 이미 지워진 재시도(앞에서 background로 지웠다)에는 파드가 남아 있을 수 있어 파드도 직접 지운다(지워질 때까지 기다린다).
   kubectl -n app-$APP delete job -l homelab.ukyi.app/restore=$RUN --cascade=foreground --timeout=5m
   kubectl -n app-$APP delete pod -l homelab.ukyi.app/restore=$RUN --timeout=5m
   # 함정: 수동 백업 파드에는 실행 라벨도 valkey-data도 없어 라벨 확인과 아래 다른 복원 검사에 모두 걸리지 않는다.
   # 기록의 backup.jobs(쉼표 목록)의 Job마다 job-name 라벨로 파드를 지우고 0개인지 본다(CLI의 runObjects와 같다).
   while IFS= read -r j; do
     [ -n "$j" ] || continue
     case $j in "backup-$RUN-"????) ;; *) echo "기록의 backup.jobs 꼴이 아니다" >&2; exit 1 ;; esac
     printf '%s\n' "$j" | LC_ALL=C grep -aqxE 'backup-[a-z0-9]{1,22}-[0-9a-f]{4}' || { echo "기록의 backup.jobs 꼴이 아니다" >&2; exit 1; }
     kubectl -n app-$APP delete job "$j" --cascade=foreground --timeout=5m --ignore-not-found
     kubectl -n app-$APP delete pod -l "job-name=$j" --timeout=5m
     out=$(kubectl -n app-$APP get pod -l "job-name=$j" -o name)
     if [ -n "$out" ]; then printf '%s\n' "$out" | cat -v >&2; echo "수동 백업 파드가 남았다(위)" >&2; exit 1; fi
   done <<<"$(printf '%s' "$bjobs" | tr ',' '\n')"
   out=$(kubectl -n app-$APP get job,pod -l homelab.ukyi.app/restore=$RUN -o name)
   if [ -n "$out" ]; then printf '%s\n' "$out" | cat -v >&2; echo "이 실행의 Job·파드가 남았다(위)" >&2; exit 1; fi
   # 다른 복원: 남은 restore-vk Job(다른 실행 것), valkey-data를 마운트하는 끝나지 않은 Job과 그 파드(1절 2단계와 같은 검사).
   # 파드는 job-name 라벨이 있는 것만 본다. 서버 파드도 valkey-data를 마운트한다.
   x=$(kubectl -n app-$APP get job restore-vk -o name --ignore-not-found)
   pods=$(kubectl -n app-$APP get pod -l job-name -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')
   jobs=$(kubectl -n app-$APP get job -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.status=="True")].type}{"\t"}{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')
   bp=$(printf '%s\n' "$pods" | awk -F'\t' '$2 != "Succeeded" && $2 != "Failed" && (" " $3 " ") ~ / valkey-data / { print "pod/" $1 }')
   bj=$(printf '%s\n' "$jobs" | awk -F'\t' '(" " $2 " ") !~ / (Complete|Failed) / && (" " $3 " ") ~ / valkey-data / { print "job/" $1 }')
   if [ -n "$x$bp$bj" ]; then printf '%s\n' "$x" "$bp" "$bj" | cat -v >&2
     echo "다른 복원의 Job·파드가 있다(위). 그 실행이 끝났는지 보고 다시 한다" >&2; exit 1; fi
   # 지우기 직전에 다시 보고, 그때 본 그 객체(uid)만 지운다(CLI restoreRecordDelete와 같다). 이름으로 지우면 이 확인과
   # 삭제 사이에 다른 셸이 기록을 지우고 새 실행이 같은 이름으로 만든 잠금을 지운다(#914 2라운드). run과 uid는 한 번에 읽는다.
   cur=$(kubectl -n app-$APP get configmap restore-vk -o jsonpath='{.data.run} {.metadata.uid}')
   read -r r uid <<<"$cur"
   [ "$r" = "$RUN" ] || { echo "기록의 run이 $(printf '%s' "$r" | cat -v)다(2에서 본 것과 다르다)" >&2; exit 1; }
   case $uid in ''|*[!0-9a-f-]*) echo "기록의 uid를 읽지 못했다" >&2; exit 1 ;; esac
   # uid가 바뀌었으면 API가 409(Precondition failed)로 거부한다. 그때는 새 실행의 기록이라 건드리지 않고 멈춘다.
   # 404는 이 기록이 이미 지워진 것이라 통과한다. 응답 본문(기록 내용)은 출력하지 않는다.
   if ! err=$(printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s"}}' "$uid" \
       | kubectl delete --raw "/api/v1/namespaces/app-$APP/configmaps/restore-vk" -f - 2>&1 >/dev/null); then
     case $err in
       *"Precondition failed"*|*"(Conflict)"*) echo "기록이 확인 뒤 다른 실행의 것으로 바뀌었다(409). 지우지 않았다" >&2; exit 1 ;;
       *"(NotFound)"*) ;;
       *) printf '%s\n' "$err" | cat -v >&2; exit 1 ;;
     esac
   fi
   # 같은 이름의 새 기록(다른 실행)이 생겼어도 이 실행의 기록(uid)이 없어졌으면 끝이다.
   now=$(kubectl -n app-$APP get configmap restore-vk -o jsonpath='{.metadata.uid}' --ignore-not-found)
   [ "$now" != "$uid" ] )
   [ $? -eq 0 ] && echo "기록 지움" || echo "멈춤: 위 이유를 본다. 기록은 그대로다"
   ```

   맞았으면 여기서 끝이다. 맞지 않았으면 3의 "맞지 않으면"대로 1절을 처음부터 한다.

## 2. 공유 PostgreSQL에서 한 앱의 DB만 복원 (설계 C.5.7, 시나리오 10)

CNPG 복원은 제자리가 아니라 항상 새 클러스터다. 그래서 임시 클러스터를 시각 T1로 PITR하고, 그 DB 하나만 덤프해 공유 Cluster `pg`에 다시 넣는다.

**T1 뒤에 끝난 completed base backup이 있어야 한다.** 그 백업이 WAL이 T1까지 R2에 있다는 근거다(`pg_backup_stop`은 끝 WAL이 아카이브될 때까지 기다린다). CNPG 1.30.1 Cluster에는 마지막 아카이브 시각이 없어 다른 근거가 없고, 그래서 `homelab db restore`는 이 백업이 없으면 멈춘다(T13 시나리오 10). T1 뒤 정기 백업(매일 03:00 KST)이 아직 없으면 온디맨드 Backup CR을 하나 만들고 completed를 기다린 뒤 시작한다.

```bash
B=ondemand-$(date -u +%Y%m%d%H%M%S)   # 이름이 겹치지 않게 시각을 붙인다
kubectl -n database create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: $B, namespace: database }
spec: { cluster: { name: pg }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
EOF
# completed가 될 때까지 다시 본다. STOPPED는 UTC라 T1(+09)과 견줄 때 9시간을 뺀다
kubectl -n database get backups -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STOPPED:.status.stoppedAt
```

복원 객체 이름에는 앱 이름을 넣지 않는다(`pg-restore-<실행 id>`, `restore-<실행 id>-r2`·`-db`, `backup-<실행 id>-<시도 id>`, 1절의 `restore-vk`, 잠금 ConfigMap `restore-pg`, 모두 35자 이하). CNPG는 인스턴스 이름 `<클러스터>-1`을 파드 hostname으로 쓰는데, 앱 이름(최대 53자)을 넣으면 63자를 넘어 임시 클러스터가 뜨지 않는다.

**한 앱 DB에는 복원 하나만.** 두 실행이 같은 앱을 복원하면 임시 Cluster·Job 이름과 `$W`가 달라 둘 다 자기 확인을 통과하고, 한쪽의 `DROP DATABASE ... WITH (FORCE)`가 다른 쪽의 복원 연결을 끊거나 막 복원한 DB를 지운다. 그래서 준비 블록 바로 뒤에 그 앱 ns에 고정 이름 ConfigMap `restore-pg`(값 `run=<실행 id>`)를 잠금으로 만든다. 1절 `restore-vk`처럼 같은 이름은 하나만 만들어져, 동시에 시작해도 한 실행만 잡는다. 그 뒤의 모든 블록(`step`)과 재개 블록이 잠금이 지금 이 실행의 것인지 클러스터에서 다시 본다(`mine`). 잠금은 재개(5단계)까지 쥐고 6단계에서 라벨로 지운다. 다른 실행의 잠금이 남아 있으면 멈춘다. 그 실행이 끝났는지(또는 버렸는지) 사람이 보고, 그 실행의 6단계로 지운 뒤 다시 한다. 잠금이 없던 문서로 시작한 실행은 앱 ns의 끝나지 않은 `restore-<실행 id>-db` Job으로 보고 멈춘다.

**복원은 앱 역할로 한다.** 덤프는 앱이 만든 객체다. 앱 owner 자격이 털린 뒤라면 함수·CHECK 제약 같은 객체에 코드를 심어 둘 수 있고, 슈퍼유저(`postgres`)로 `pg_restore`하면 그 코드가 슈퍼유저 문맥에서 돌아 앱 역할을 승격하고 다른 앱 DB에 닿는다(2a의 로컬 시험에서 재현). 그래서 덤프는 앱 ns의 Job이 앱 연결 Secret(`<앱>-db`)으로 접속해 `--no-owner --no-privileges`로 넣고, 권한(ACL)만 같은 앱 역할로 따로 넣은 뒤 원본과 대조한다(4단계). 앱을 멈추는 것만으로는 저장된 코드를 막지 못한다.

Secret·ObjectStore 이름은 `platform/cnpg/cluster`를 따른다(R2 자격 Secret `r2-backup`, 키 `ACCESS_KEY_ID`·`SECRET_ACCESS_KEY`·`ENDPOINT_URL`, ObjectStore `r2`). 바뀌면 이 절을 함께 고친다.

`database` ns는 PSA restricted다. 아래 도우미 Job처럼 `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`가 없으면 파드가 거부된다. region은 rclone이 자기 설정(`RCLONE_CONFIG_R2_REGION`)으로 읽는다. CNPG plugin(boto3)이 `AWS_DEFAULT_REGION`만 읽는 것과 다르다.

```bash
T1='2026-11-02 10:00:00+09'   # 되돌릴 시각. 마지막 base backup과 WAL 아카이브 범위 안이어야 한다
# 클러스터에서 읽는 값(SRV·IMG·SIZE·BUCKET·PRIMARY)과 임시 클러스터 주 파드(TMP)는 확인 블록 안에서 조회·검증하고
# $W/vars.env·$W/tmp.env로 넘긴다(블록 밖에서 받으면 조회가 값을 낸 뒤 실패해도 막지 못한다). 값을 쓰는 블록은 use로 읽는다.
# 두 파일의 값은 fit(한 줄이고 값 전체가 따옴표 없는 정규식에 맞음)을 통과한 것만 들어가 읽어도 안전하다.
use() { . "$W/vars.env"; if [ -f "$W/tmp.env" ]; then . "$W/tmp.env"; fi; }
# 값 전체가 한 줄이고 정규식에 맞는지. grep은 줄마다 보므로 줄바꿈이 든 값은 한 줄만 맞아도 통과한다. 그러면
# 다음 줄이 vars.env에 따옴표 밖으로 들어가 use가 source할 때 셸 명령으로 돈다. 그래서 제어문자(CR·LF·NUL 등)를
# 먼저 거부한다. NUL: bash는 명령 치환에서 지우지만 zsh는 남기고, GNU grep은 NUL이 든 입력을 바이너리로 보고
# NUL을 줄 경계처럼 다룰 수 있다. 그래서 grep은 -a(늘 텍스트), LC_ALL=C(바이트 그대로)로 부른다.
fit() { case $1 in *[[:cntrl:]]*) echo "제어문자가 든 값이다" >&2; return 1 ;; esac
  printf '%s\n' "$1" | LC_ALL=C grep -aqE "$2"; }
dump() { kubectl -n database exec "$TMP" -c postgres -- pg_dump -U postgres -Fc -d "$APP"; }   # 임시 클러스터의 그 DB
J() { kubectl -n app-$APP exec -i job/restore-$RUN-db -- "$@"; }                                 # 4-1의 앱 역할 복원 Job
# 덤프를 읽는 pg_restore는 소진 셸(PGR)로 감싼다. 함정: --list와 ACL만 고른 -L은 덤프를 끝까지 읽지 않고 끝나, 큰 덤프면
# 쓰던 쪽(pg_dump·rclone cat의 kubectl exec)이 SIGPIPE(141)로 죽어 pipefail이 정상 덤프를 실패로 본다(로컬 실측, 작은 덤프는
# 파이프 버퍼에 다 들어가 통과해 크기·타이밍에 따라 갈린다). 셸이 pg_restore 뒤 남은 입력을 읽어 버리고 pg_restore의 종료 코드를
# 그대로 낸다. 생산자의 141을 성공으로 바꾸지 않는다(진짜 덤프 실패를 숨긴다). CLI의 PG_RESTORE_DRAINED와 같은 꼴이다.
PGR='pg_restore "$@"; rc=$?; cat >/dev/null; exit $rc'
JR() { J sh -c "$PGR" sh "$@"; }                                                                 # 파일·목록으로
JRD() { J sh -c 'pg_restore -d "$PGDATABASE" "$@"; rc=$?; cat >/dev/null; exit $rc' sh "$@"; }   # 그 DB에 넣기(앱 역할)
# 복원 Job이 지금 살아 있는지(jobready), 앱 역할로 그 DB에 접속되는지(jobauth <DB>). 표식(ok-auth)보다
# Job 수명(약 2시간)이 짧을 수 있어 DB를 지우거나 쓰는 블록(4-3·4-4·4-5) 안에서 매번 다시 본다.
jobready() { kubectl -n app-$APP wait --for=condition=ready pod -l job-name=restore-$RUN-db --timeout=60s >/dev/null; }
# 명령 치환은 독립 할당으로 받아 실패면 멈춘 뒤 비교한다. '[ "$(명령)" = 값 ]'은 명령이 값을 낸 뒤 실패해도 비교만 본다.
jobauth() { local u; u=$(J psql -d "$1" -v ON_ERROR_STOP=1 -tAc 'select current_user') || return 1; [ "$u" = "$APP" ]; }
# 그 DB가 지금 있는지(관리자 조회). 0 또는 1만 낸다. 앱 역할 접속은 DB가 없으면 실패하므로 이것으로 길을 나눈다.
dbn() { printf '%s\n' "select count(*) from pg_database where datname = :'app'" \
  | kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tA -v app="$APP"; }
# postgres로 넣을 ACL SQL(4-2에서 만들고 4-5에서 넣는다)의 문장 종류를 줄마다 본다. 허용: GRANT·REVOKE,
# postgres의 기본 권한(ALTER DEFAULT PRIVILEGES FOR ROLE postgres), 앱 역할이 받은 위임 권한을 다시 줄 때 pg_restore가
# 붙이는 SET/RESET SESSION AUTHORIZATION(대상은 앱 역할만), pg_restore의 고정 머리(정해진 설정 이름만. role·
# session_authorization 같은 설정은 받지 않는다). 그 밖의 줄이 있으면 실패한다.
sqlok() { awk -v app="$APP" '
  /^(GRANT|REVOKE) .*;$/ { next }
  /^ALTER DEFAULT PRIVILEGES FOR ROLE postgres (IN SCHEMA [^ ]+ )?(GRANT|REVOKE) .*;$/ { next }
  $0 == "SET SESSION AUTHORIZATION " app ";" || $0 == "SET SESSION AUTHORIZATION \"" app "\";" { next }
  $0 == "RESET SESSION AUTHORIZATION;" { next }
  /^SET (statement_timeout|lock_timeout|idle_in_transaction_session_timeout|transaction_timeout|client_encoding|standard_conforming_strings|check_function_bodies|xmloption|client_min_messages|row_security|default_tablespace|default_table_access_method) = [^;]*;$/ { next }
  $0 == "SELECT pg_catalog.set_config(\047search_path\047, \047\047, false);" { next }
  /^\\(un)?restrict [A-Za-z0-9]+$/ || /^--/ || /^$/ { next }
  { print; bad = 1 } END { exit bad }' "$1"; }
# 확장 목록(4-2가 만든 $W/ext의 내용)의 모든 줄이 네 칸 모양인지: 이름(소문자로 시작, 소문자·숫자·_·-), 스키마(소문자·
# 숫자·_), 버전, 소유자. grep -v의 종료 코드를 나눈다: 0은 맞지 않는 줄이 있음, 1은 없음, 2 이상은 검사 실패.
# "if grep"으로 쓰면 2(읽기 오류)도 "없음"처럼 지나간다. 빈 값(확장 없음)은 통과. -a·LC_ALL=C는 fit과 같은 이유.
extok() { local rc=0 re="^[a-z][a-z0-9_-]{0,62} [a-z_][a-z0-9_]{0,62} [A-Za-z0-9._-]{1,32} (postgres|$APP)\$"
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | LC_ALL=C grep -aqvE "$re" || rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$1" | LC_ALL=C grep -anvE "$re" | cat -v >&2
    echo "이름·버전·소유자 모양이 이상한 확장 줄이 있다(위)" >&2; return 1; fi
  [ "$rc" -eq 1 ] || { echo "확장 목록을 검사하지 못했다(grep 종료 코드 $rc)" >&2; return 1; }; }
# 이 실행이 이 앱 DB의 복원 잠금(app-<앱>의 ConfigMap restore-pg)을 쥐고 있는지. step이 lock 뒤 단계마다 부른다.
# 함수는 set -e에 기대지 않고 실패를 직접 돌려준다(||·if 안에서 불려도 같게).
mine() { local h; h=$(kubectl -n app-$APP get configmap restore-pg -o jsonpath='{.data.run}') || return 1
  [ "$h" = "$RUN" ] || { echo "멈춤: 복원 잠금이 이 실행(${RUN})의 것이 아니다" >&2; return 1; }; }
# 앱이 멈춰 있는지(3단계). 표식(ok-suspended)은 남아도 그 뒤 다른 PR로 앱이 다시 뜰 수 있어, DB를 지우거나 쓰는
# 블록(4-3·4-4·4-5)이 매번 다시 본다. Deployment가 0으로 줄었고 실제로 0개, 끝나지 않은 앱 파드(마이그레이션 포함)가 없다.
# 완료된 <앱>-migrate 파드는 남아도 된다(hook 삭제 정책이 BeforeHookCreation뿐이고 suspended면 새 hook이 없다).
stopped() { local r sr out
  r=$(kubectl -n app-$APP get deploy $APP -o jsonpath='{.spec.replicas}') || return 1
  sr=$(kubectl -n app-$APP get deploy $APP -o jsonpath='{.status.replicas}') || return 1
  out=$(kubectl -n app-$APP get pods -l homelab.ukyi.app/app=$APP --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name) || return 1
  if [ "$r" = 0 ] && { [ "$sr" = "" ] || [ "$sr" = 0 ]; } && [ -z "$out" ]; then return 0; fi
  echo "멈춤: 앱이 멈춰 있지 않다(아래: spec.replicas, status.replicas, 끝나지 않은 앱 파드)" >&2
  printf '%s\n' "$r" "$sr" "$out" | cat -v >&2; return 1; }
# 4-3·4-4·4-5가 쓰는 입력(4-2가 만든 확장 목록, 목록, SQL)이 4-2가 검증을 끝낸 때와 같은지. 없어지거나 바뀌었으면 실패한다.
# 기준(inputs.sha)은 4-2만 만든다. 뒤 단계가 다시 만들면 그 사이 바뀐 내용(예: 주석 한 줄로 잘린 목록)을 새 기준으로 받는다.
same() { ( cd "$W" && sha256sum -c inputs.sha ); }
# 임시 클러스터가 지금도 이 실행의 복원 원본인지(4-3이 DROP 직전에 본다). 표식(ok-tmp)은 남아도 그 뒤 클러스터가
# 죽거나 spec이 바뀔 수 있다(예: U26 patch는 bootstrap.recovery를 지운다). Ready, 주 파드가 TMP, 복구 원본·지점이 2단계와 같다.
srcok() { local c="cluster/pg-restore-$RUN" v k want
  kubectl -n database wait --for=condition=Ready "$c" --timeout=60s >/dev/null || return 1
  for k in status.currentPrimary spec.bootstrap.recovery.source spec.bootstrap.recovery.recoveryTarget.targetTime \
    'spec.externalClusters[?(@.name=="origin")].plugin.name' \
    'spec.externalClusters[?(@.name=="origin")].plugin.parameters.barmanObjectName' \
    'spec.externalClusters[?(@.name=="origin")].plugin.parameters.serverName'; do
    case $k in status.*) want=$TMP ;; *.source) want=origin ;; *.targetTime) want=$T1 ;; *.plugin.name) want=barman-cloud.cloudnative-pg.io ;;
      *barmanObjectName*) want=r2 ;; *serverName*) want=$SRV ;; esac
    v=$(kubectl -n database get "$c" -o jsonpath="{.$k}") || return 1
    [ "$v" = "$want" ] || { echo "멈춤: 임시 클러스터의 ${k}가 2단계와 다르다" >&2; return 1; }
  done; }
( set -euo pipefail; step vars
  # 조회는 독립 할당으로(실패면 set -e가 멈춘다)
  SRV=$(kubectl -n database get cluster pg -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}')
  IMG=$(kubectl -n database get cluster pg -o jsonpath='{.spec.imageName}')
  SIZE=$(kubectl -n database get cluster pg -o jsonpath='{.spec.storage.size}')
  DEST=$(kubectl -n database get objectstore r2 -o jsonpath='{.spec.configuration.destinationPath}')
  BUCKET=$(printf '%s' "$DEST" | sed -E 's#^s3://([^/]+)/.*#\1#')
  PRIMARY=$(kubectl -n database get cluster pg -o jsonpath='{.status.currentPrimary}')
  # SQL·YAML·sed와 vars.env에 들어가는 값의 모양(fit). 검사는 한 줄에 하나("a && b"의 앞쪽 실패에는 set -e가 멈추지 않는다).
  # APP은 앱 차트와 같은 DNS 라벨이다.
  fit "$APP" '^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$'
  fit "$T1" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}(:?[0-9]{2})?)?$'
  fit "$SRV" '^[a-z0-9-]+$'
  fit "$IMG" '^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'
  fit "$SIZE" '^[0-9]+(Mi|Gi|Ti)$'
  fit "$BUCKET" '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
  fit "$PRIMARY" '^pg-[0-9]+$'
  kubectl -n database get backups      # T1 앞과 뒤(위 온디맨드)에 completed base backup이 있는지 눈으로 본다
  # 모든 확인이 끝난 뒤에만 파일을 바꾼다(실패하면 옛 값도 새 값도 남지 않게 먼저 지운다)
  rm -f "$W/vars.env"
  printf "T1='%s'\nSRV='%s'\nIMG='%s'\nSIZE='%s'\nBUCKET='%s'\nPRIMARY='%s'\n" "$T1" "$SRV" "$IMG" "$SIZE" "$BUCKET" "$PRIMARY" > "$W/vars.env.new"
  mv "$W/vars.env.new" "$W/vars.env"
  touch "$W/ok-vars" )
[ -f "$W/ok-vars" ] && echo "통과: vars" || echo "멈춤: 값이 비었거나 조회에 실패했다"
```

**잠금.** 위 "한 앱 DB에는 복원 하나만". 같은 RUN으로 다시 돌리면 이미 쥔 잠금을 그대로 쓴다.

```bash
( set -euo pipefail; step lock
  # 잠금이 없던 문서로 시작한 다른 실행: 앱 ns의 끝나지 않은(Complete·Failed 조건이 없는) restore-<실행 id>-db Job
  jobs=$(kubectl -n app-$APP get job -l homelab.ukyi.app/restore -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.homelab\.ukyi\.app/restore}{"\t"}{.status.conditions[?(@.status=="True")].type}{"\n"}{end}')
  other=$(printf '%s\n' "$jobs" | awk -F'\t' -v run="$RUN" '$1 ~ /^restore-.*-db$/ && $2 != run && (" " $3 " ") !~ / (Complete|Failed) / { print "job/" $1 }')
  # Job을 지운 뒤에도 파드는 남아 돌 수 있다(background 삭제는 파드를 나중에 지운다). 끝나지 않은(지우는 중 포함) 파드도 본다.
  pods=$(kubectl -n app-$APP get pod -l homelab.ukyi.app/restore -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.homelab\.ukyi\.app/restore}{"\t"}{.status.phase}{"\t"}{.metadata.labels.job-name}{"\n"}{end}')
  other="$other$(printf '%s\n' "$pods" | awk -F'\t' -v run="$RUN" '$4 ~ /^restore-.*-db$/ && $2 != run && $3 != "Succeeded" && $3 != "Failed" { print "pod/" $1 }')"
  if [ -n "$other" ]; then printf '%s\n' "$other" | cat -v >&2
    echo "다른 실행의 복원 Job·파드가 이 앱에 남아 있다(위)" >&2; exit 1; fi
  # 없으면 만든다. 동시에 만들면 하나만 성공하고 나머지는 AlreadyExists로 멈춘다. 이름 조회는 없음과 오류를 나눈다(--ignore-not-found).
  held=$(kubectl -n app-$APP get configmap restore-pg --ignore-not-found -o jsonpath='{.data.run}')
  if [ -z "$held" ]; then kubectl create -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: restore-pg
  namespace: app-$APP
  labels: { homelab.ukyi.app/restore: "$RUN" }
data: { run: "$RUN" }
YAML
  elif [ "$held" != "$RUN" ]; then
    # 값만 cat -v로 거른다(문구까지 넣으면 한글이 M- 표기로 깨진다)
    echo "다른 실행이 이 앱의 복원 잠금을 쥐고 있다:" >&2; printf '%s\n' "$held" | cat -v >&2; exit 1; fi
  mine
  touch "$W/ok-lock" )
[ -f "$W/ok-lock" ] && echo "통과: lock" || echo "멈춤: 복원 잠금을 잡지 못했다. 'kubectl -n app-$APP get configmap,job -L homelab.ukyi.app/restore'로 다른 실행을 본다"
```

1. **되돌림용 덤프:** 지금 DB를 R2 `pgdump/<앱>/pre-restore-<실행 id>.dump`에 남긴다. 이 사본은 한 실행에 한 번만 만들고 덮어쓰지 않는다. 같은 RUN으로 다시 돌리면 이미 있는 사본을 검증만 하고, 4-3(DB 삭제)에 들어간 뒤에는 새로 만들지 않는다(그때의 DB는 비었거나 일부만 복원된 상태다). 덤프는 파드 안 `postgres` 로컬 접속으로 하고 도우미 Job(rclone)으로 바로 올린다. 사람 기기에 데이터가 남지 않고, `database` ns의 5432 기본 거부(앱 ns만 허용)도 건드리지 않는다. 올린 사본은 끝까지 읽어 본다. 목록(`--list`)만 보면 앞에 있는 목차만 읽어 잘린 사본도 통과한다. 이 prefix에는 lifecycle이 없어 복원을 확인한 뒤 손으로 지운다.

   ```bash
   ( set -euo pipefail; step predump
     use
     # 같은 RUN으로 다시 돌리면 이름이 겹친다. 파드까지 지운 뒤(foreground) 새로 만든다.
     kubectl -n database delete job restore-$RUN-r2 --ignore-not-found --cascade=foreground --wait=true --timeout=2m
     kubectl create -f - <<YAML
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: restore-$RUN-r2
     namespace: database
     labels: { homelab.ukyi.app/restore: "$RUN" }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 7200
     template:
       metadata:
         labels: { homelab.ukyi.app/restore: "$RUN" }
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: rclone
             image: docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
             command: ["sleep", "7000"]
             env:
               - { name: HOME, value: /tmp }
               - { name: RCLONE_CONFIG_R2_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_R2_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_R2_REGION, value: auto }
               - { name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_R2_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-backup, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-backup, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_R2_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-backup, key: ENDPOINT_URL } } }
             resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { memory: 128Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts: [{ name: tmp, mountPath: /tmp }]
         volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
   YAML
     # --for=create가 먼저다. 없으면 Job 컨트롤러가 파드를 만들기 전에 "no matching resources found"로 --timeout과 무관하게 바로 끝난다
     kubectl -n database wait --for=create --for=condition=ready pod -l job-name=restore-$RUN-r2 --timeout=5m
     KEY="r2:$BUCKET/pgdump/$APP/pre-restore-$RUN.dump"
     # 되돌림 사본은 이 실행에서 처음 한 번만 만든다. 이미 있으면(같은 RUN 재시도) 덮어쓰지 않고 검증만 한다.
     # 4-3에 들어간 뒤($W/dropped, begin이 지우지 않는다)면 지금 DB는 원래 상태가 아니므로 어떤 경우에도 새로 만들지 않는다.
     # 버킷 뿌리에서 그 경로 하나만 거른다(없는 prefix를 나열하면 원격에 따라 오류가 나므로).
     have=$(kubectl -n database exec job/restore-$RUN-r2 -- rclone lsf -R --files-only "r2:$BUCKET" --include "/pgdump/$APP/pre-restore-$RUN.dump")
     if [ -n "$have" ]; then echo "되돌림 사본이 이미 있다: 새로 올리지 않고 검증만 한다"
     elif [ -f "$W/dropped" ]; then echo "4-3에 들어간 뒤라 되돌림 사본을 새로 만들지 않는다. 원래 사본을 찾는다" >&2; exit 1
     else
       kubectl -n database exec "$PRIMARY" -c postgres -- pg_dump -U postgres -Fc -d "$APP" \
         | kubectl -n database exec -i job/restore-$RUN-r2 -- rclone rcat "$KEY"
     fi
     kubectl -n database exec job/restore-$RUN-r2 -- rclone cat "$KEY" \
       | kubectl -n database exec -i "$PRIMARY" -c postgres -- sh -c "$PGR" sh -f /dev/null
     touch "$W/ok-predump" )
   [ -f "$W/ok-predump" ] && echo "되돌림 사본 확인" || echo "멈춤: 되돌림 사본을 확인하지 못했다"
   ```

2. **임시 클러스터:** `bootstrap.recovery`로 T1까지 되감는다. 만들기·기다리기·확인이 한 블록이다. 같은 RUN의 임시 클러스터가 이미 있으면(앞 시도가 만든 것) 재사용하지 않고 멈춘다. 그때는 6단계로 그 RUN의 객체를 지우고 새 RUN으로 0.1부터 다시 시작한다(복구가 30분 안에 Ready가 되지 않은 경우도 같다). WAL 아카이버 plugin을 붙이지 않는다(운영 prefix에 쓰지 않게, 설계 B.8 E6). PVC는 `local-path`(Delete)라 PVC를 지우면 노드의 폴더도 지워진다. `inheritedMetadata`가 실행 id 라벨을 PVC·파드에 물려준다.

   ```bash
   ( set -euo pipefail; step tmp
     use
     rm -f "$W/tmp.env"
     # 같은 RUN의 임시 클러스터가 이미 있으면 재사용하지 않는다. 그 사이 T1·SRV·IMG·SIZE가 바뀌었을 수 있고,
     # 이미 떠 있는 클러스터의 복구 지점은 바꿀 수 없다. 6단계로 지우고 새 RUN으로 0.1부터 다시 시작한다.
     if kubectl -n database get cluster pg-restore-$RUN >/dev/null 2>&1; then
       echo "임시 클러스터 pg-restore-${RUN}이 이미 있다. 재사용하지 않는다: 6단계로 지우고 새 RUN으로 다시 시작한다" >&2; exit 1; fi
     kubectl create -f - <<YAML
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: pg-restore-$RUN
     namespace: database
     labels: { homelab.ukyi.app/restore: "$RUN" }
   spec:
     instances: 1
     imageName: $IMG
     inheritedMetadata:
       labels: { homelab.ukyi.app/restore: "$RUN" }
     storage: { storageClass: local-path, size: $SIZE }
     bootstrap:
       recovery:
         source: origin
         recoveryTarget:
           targetTime: "$T1"
     externalClusters:
       - name: origin
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: r2
             serverName: $SRV
   YAML
     kubectl -n database wait --for=condition=Ready cluster/pg-restore-$RUN --timeout=30m
     TMP=$(kubectl -n database get cluster pg-restore-$RUN -o jsonpath='{.status.currentPrimary}')
     fit "$TMP" "^pg-restore-$RUN-[0-9]+\$"
     kubectl -n database exec "$TMP" -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -tAc 'select count(*) from <표식 테이블>'
     printf "TMP='%s'\n" "$TMP" > "$W/tmp.env.new"
     mv "$W/tmp.env.new" "$W/tmp.env"
     touch "$W/ok-tmp" )
   [ -f "$W/ok-tmp" ] && echo "통과: tmp" || echo "멈춤: 임시 클러스터가 준비되지 않았다"
   ```

   U26 확인(복원 시험의 임시 Cluster에서): 이 클러스터의 `spec.bootstrap`을 `initdb`로 바꾸는 patch가 webhook에 거부되지 않는지, 떠 있는 클러스터에 영향이 없는지 본다. 결과는 설계 부록 1 U26에 적는다. 4-6이 끝난 뒤에 한다. 그 전에 하면 4-3의 원본 확인(`srcok`, 복구 원본·지점)이 멈춘다.

   ```bash
   kubectl -n database patch cluster pg-restore-$RUN --type=merge \
     -p '{"spec":{"bootstrap":{"recovery":null,"initdb":{"database":"app","owner":"app"}}}}'
   kubectl -n database get cluster pg-restore-$RUN     # 계속 healthy, 파드 재시작 없음
   ```

3. **앱 멈춤(PR):** `apps/<앱>/values.yaml`에 `suspended: true`(앱 차트 1.1.0부터. replicas 0, 마이그레이션 Job 없음). 병합 뒤 파드가 없는지 본다.

   ```bash
   ( set -euo pipefail; step suspended
     # 확인 내용은 stopped(2절 머리). 4-3·4-4·4-5가 같은 함수로 다시 본다. Valkey 캐시 파드는 앱 라벨이 없다.
     stopped
     touch "$W/ok-suspended" )
   [ -f "$W/ok-suspended" ] && echo "통과: suspended" || echo "멈춤: 앱 파드가 남아 있거나 조회에 실패했다"
   ```

4. **덤프·복원:** 빈 DB에 넣는다. `--clean`만 쓰면 덤프에 있는 객체만 지워 T1 뒤에 만든 스키마·테이블이 남는다. 그래서 DB를 지우고 다시 만든다. DB DROP·CREATE와 확장 만들기만 `postgres`가 하고(덤프 내용을 실행하지 않는다), 덤프를 넣는 것은 앱 역할이 두 번에 나눠 한다: 본 복원(`--no-privileges`)과 ACL 복원. 4-3(DB 삭제) 앞의 확인 표식이 모두 있어야 4-3이 시작한다. 아래 절차는 2a의 로컬 시험으로 그대로 돌려 봤다.

   **4-1. 앱 ns 복원 Job과 접속 확인.** 이미지는 클러스터와 같은 PostgreSQL 이미지다(`pg_restore` major = 서버 major, uid 26). 앱 차트의 NetworkPolicy가 이 ns에서 `pg` 5432를 열어 둔다(`uses.postgres`). 시작 스크립트가 `DATABASE_URL`에서 비밀번호를 꺼내 메모리 emptyDir의 pgpass로 두고, 이후 `pg_restore`·`psql`은 libpq 환경변수(`PGHOST`·`PGUSER`·`PGDATABASE`·`PGPASSFILE`)로 접속한다. 비밀번호가 명령행 인자(`-d <URL>`)에 들어가지 않는다. 셸 내장만 써서 꺼내 파생 프로세스의 argv에도 없다(로컬 실측 0건). pgpass는 행 단위라 줄바꿈(CR·LF)이 든 비밀번호는 담을 수 없다. 그런 값이면 시작 스크립트가 실패해 Job이 Ready가 되지 않는다(비밀번호는 영숫자로 만든다, `rotate.md` 3c). 마지막으로 지금 DB에 앱 역할로 실제 접속해 본다. `--list`는 접속하지 않으므로, 이 확인이 없으면 비밀번호 문제가 DB를 지운 뒤에야 드러난다. 4-1·4-2는 앱 멈춤(3단계)과 무관해 먼저 돌려도 된다.

   ```bash
   ( set -euo pipefail; step auth
     use
     # 같은 RUN으로 다시 돌리면 Job 이름이 겹친다(시나리오 10 실측). 파드까지 지운 뒤 새로 만든다.
     kubectl -n app-$APP delete job restore-$RUN-db --ignore-not-found --cascade=foreground --wait=true --timeout=2m
     cat <<'YAML' | sed "s/__APP__/$APP/g; s/__RUN__/$RUN/g; s#__IMG__#$IMG#g" | kubectl create -f -
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: restore-__RUN__-db
     namespace: app-__APP__
     labels: { homelab.ukyi.app/restore: "__RUN__" }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 7200
     template:
       metadata:
         labels: { homelab.ukyi.app/restore: "__RUN__" }
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         enableServiceLinks: false
         securityContext: { runAsNonRoot: true, runAsUser: 26, runAsGroup: 26, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: restore
             image: __IMG__
             command: ["bash", "-c"]
             args:
               - |
                 set -euo pipefail
                 umask 077
                 # postgresql://<앱>:<urlquery 비밀번호>@...에서 비밀번호만. pgpass는 : 와 \ 를 이스케이프한다.
                 enc=${DATABASE_URL#*://*:}; enc=${enc%%@*}
                 # pgpass는 행 단위다. 줄바꿈이 든 비밀번호는 담을 수 없어 시작하지 않는다(DB를 지우기 전에 드러나게).
                 case $enc in *%0[AaDd]*) echo "비밀번호에 줄바꿈이 있다. 영숫자로 다시 만든다" >&2; exit 1;; esac
                 pw=$(printf '%b' "${enc//%/\\x}")
                 pw=${pw//\\/\\\\}; pw=${pw//:/\\:}
                 # DB 칸은 *: 지금 DB가 지워진 재시도에서도 postgres DB로 접속을 확인할 수 있게(이 역할의 이 비밀번호뿐이다)
                 printf '%s:%s:*:%s:%s\n' "$PGHOST" "$PGPORT" "$PGUSER" "$pw" > "$PGPASSFILE"
                 unset enc pw
                 exec sleep 7000
             env:
               - { name: HOME, value: /tmp }
               - { name: PGHOST, value: pg-rw.database.svc }
               - { name: PGPORT, value: "5432" }
               - { name: PGUSER, value: __APP__ }
               - { name: PGDATABASE, value: __APP__ }
               - { name: PGSSLMODE, value: require }
               - { name: PGPASSFILE, value: /tmp/pgpass }
               - { name: DATABASE_URL, valueFrom: { secretKeyRef: { name: __APP__-db, key: DATABASE_URL } } }
             resources: { requests: { cpu: 50m, memory: 128Mi }, limits: { memory: 256Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts: [{ name: tmp, mountPath: /tmp }]
         volumes: [{ name: tmp, emptyDir: { medium: Memory, sizeLimit: 16Mi } }]
   YAML
     # --for=create가 먼저다. 없으면 Job 컨트롤러가 파드를 만들기 전에 "no matching resources found"로 --timeout과 무관하게 바로 끝난다
     kubectl -n app-$APP wait --for=create --for=condition=ready pod -l job-name=restore-$RUN-db --timeout=5m
     # 지금 DB가 있으면 그 DB로, 이미 지워졌으면(4-3 뒤 같은 RUN 재시도) postgres DB로 접속해 본다
     n=$(dbn)
     [ "$n" = 0 ] || [ "$n" = 1 ]
     if [ "$n" = 1 ]; then jobauth "$APP"; else jobauth postgres; fi
     touch "$W/ok-auth" )
   [ -f "$W/ok-auth" ] && echo "통과: auth" || echo "멈춤: 복원 Job이 앱 역할로 접속하지 못했다"
   ```

   **4-2. 목록과 확장.** 목록을 못 만들거나(임시 클러스터 접근·덤프 실패) 확장 조회가 실패하면 표식이 생기지 않는다. "확장 없음"은 조회가 성공하고 결과가 비었을 때만이다. 확장은 원본의 스키마·버전·소유자를 그대로 쓴다. 이름만으로 만들면 PostgreSQL이 기본 스키마와 control 파일의 기본 버전을 고르고, 만든 역할이 소유자가 된다. 덤프의 `EXTENSION` 항목은 4-4에서 빼므로 그 차이가 교정되지 않는다. 소유자가 다르면 뒤의 앱 마이그레이션이 `ALTER EXTENSION`(소유자만 가능)에서 실패한다. 소유자는 `postgres`와 앱 역할만 받는다. 앱 역할 소유는 trusted 확장일 때만 생길 수 있다(확장 소유자는 만든 역할이고 바꿀 수 없다). 확장 이름에는 `uuid-ossp`처럼 `-`가 들어간다.

   ACL 항목은 객체 소유자(목록 줄 끝 칸)로 나눈다. 앱 역할과 `pg_database_owner`(PostgreSQL 15부터 `public` 스키마의 소유자, DB owner인 앱 역할이 그 구성원) 소유는 4-5에서 앱 역할이 넣는다. `postgres` 소유(확장에 딸린 객체. trusted 확장도 객체는 슈퍼유저 소유다)는 앱 역할이 바꿀 수 없어 4-5에서 따로 넣는다. 다른 소유자는 이 절차가 다루지 않아 멈춘다.

   ```bash
   ( set -euo pipefail; step list
     use
     rm -f "$W/inputs.sha"      # 이 블록이 끝까지 성공할 때만 기준이 다시 생긴다
     dump | JR --list > "$W/list"
     [ -s "$W/list" ]
     kubectl -n database exec "$TMP" -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -tA -F ' ' -c \
       "select e.extname, n.nspname, e.extversion, pg_get_userbyid(e.extowner) from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname <> 'plpgsql' order by e.oid" > "$W/ext"
     # 앱이 만든 값이다. 네 칸 모양을 거른다(extok). 읽기는 독립 할당으로(실패면 set -e가 멈춘다).
     ext=$(cat "$W/ext")
     extok "$ext"
     # 대상 이미지가 실제로 설치할 수 있는 이름·버전 조합만 받는다. 앱 역할 소유는 trusted일 때만.
     while read -r e sch v own; do
       [ -n "$e" ] || continue
       tr=$(printf '%s\n' "select trusted from pg_available_extension_versions where name = :'e' and version = :'v'" \
         | kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tA -v e="$e" -v v="$v")
       if [ "$tr" != t ] && [ "$tr" != f ]; then echo "대상 이미지에 없는 확장·버전이다" >&2; exit 1; fi
       if [ "$own" = "$APP" ] && [ "$tr" != t ]; then echo "앱 역할 소유인데 trusted가 아닌 확장이다" >&2; exit 1; fi
     done < "$W/ext"
     # 4-4 목록: 미리 만들 확장(EXTENSION, COMMENT - EXTENSION)과 그 확장이 사는 public이 아닌 스키마(SCHEMA)를 주석(;)으로 뺀다.
     # TOC 줄: "<id>; <cat> <oid> EXTENSION - <이름>", "... COMMENT - EXTENSION <이름>"(-가 든 이름은 "uuid-ossp"처럼 따옴표), "... SCHEMA - <이름> <소유자>"
     awk 'FILENAME == ARGV[1] { ext[$1] = 1; ext["\"" $1 "\""] = 1; if ($2 != "public") sch[$2] = 1; next }
          ($4 == "EXTENSION" && $5 == "-" && ($6 in ext)) ||
          ($4 == "COMMENT" && $6 == "EXTENSION" && ($7 in ext)) ||
          ($4 == "SCHEMA" && $5 == "-" && ($6 in sch)) { print ";" $0; next }
          { print }' "$W/ext" "$W/list" > "$W/main.list"
     [ -s "$W/main.list" ]
     # ACL 항목을 객체 소유자(줄 끝 칸)로 나눈다
     grep -E '^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) ' "$W/list" > "$W/acl-all.list" || [ $? -eq 1 ]
     awk -v app="$APP" '$NF == app || $NF == "pg_database_owner"' "$W/acl-all.list" > "$W/acl.list"
     awk '$NF == "postgres"' "$W/acl-all.list" > "$W/acl-su.list"
     # 독립 할당으로 받는다. "if awk ... | grep ."는 awk의 읽기 오류도 "없음"처럼 지나간다.
     odd=$(awk -v app="$APP" '$NF != app && $NF != "pg_database_owner" && $NF != "postgres"' "$W/acl-all.list")
     if [ -n "$odd" ]; then printf '%s\n' "$odd" | cat -v
       echo "앱 역할·pg_database_owner·postgres 밖의 소유자가 있는 ACL 항목이 있다" >&2; exit 1; fi
     # 4-4·4-5가 쓸 SQL을 DB를 지우기 전에 만들어(실행하지 않는다) 본다. 지원하지 않는 모양이면 지금 멈춘다.
     # 본 복원 목록이 덤프와 맞는지
     J sh -c 'cat > /tmp/main.list' < "$W/main.list"
     dump | JR -L /tmp/main.list -f /dev/null
     # 앱 역할 ACL: 앱 역할로 실행한다. 다른 역할이 준 위임 권한이면 pg_restore가 SET SESSION AUTHORIZATION을 붙이는데
     # 앱 역할은 그것을 못 한다. 이 절차가 다루지 않는 모양이라 멈춘다.
     : > "$W/acl.sql"
     if [ -s "$W/acl.list" ]; then
       J sh -c 'cat > /tmp/acl.list' < "$W/acl.list"
       dump | JR -L /tmp/acl.list -f - > "$W/acl.sql"
     fi
     # grep 종료 코드를 나눈다(0 있음, 1 없음, 2 이상 읽기 오류). "if grep"이면 읽기 오류도 "없음"이 된다.
     rc=0; LC_ALL=C grep -aq 'SESSION AUTHORIZATION' "$W/acl.sql" || rc=$?
     if [ "$rc" -eq 0 ]; then LC_ALL=C grep -an 'SESSION AUTHORIZATION' "$W/acl.sql" | cat -v
       echo "앱 역할 ACL에 다른 역할로 바꿔 주는 문장이 있다(앱 역할로는 못 넣는다)" >&2; exit 1; fi
     [ "$rc" -eq 1 ]
     # postgres 소유 ACL: 4-5는 여기서 만들고 검증한 이 파일만 넣는다.
     : > "$W/acl-su.sql"
     if [ -s "$W/acl-su.list" ]; then
       J sh -c 'cat > /tmp/acl-su.list' < "$W/acl-su.list"
       dump | JR -L /tmp/acl-su.list -f - > "$W/acl-su.sql"
     fi
     sqlok "$W/acl-su.sql" | cat -v || { echo "postgres로 넣을 ACL에 허용하지 않는 문장이 있다(위 줄)" >&2; exit 1; }
     # 검증이 모두 끝난 이 내용을 기준으로 고정한다(same). 뒤 단계는 비교만 한다.
     ( cd "$W" && sha256sum ext main.list acl.list acl-su.sql ) > "$W/inputs.sha.new"
     mv "$W/inputs.sha.new" "$W/inputs.sha"
     touch "$W/ok-list" )
   [ -f "$W/ok-list" ] && echo "통과: list" || echo "멈춤: 목록이나 확장 조회에 실패했다(지금 DB는 그대로다)"
   [ -f "$W/ok-list" ] && { cat -v "$W/ext"; [ -s "$W/ext" ] || echo "확장 없음"; }
   ```

   **4-3. DB 다시 만들기.** 여기서 지금 DB를 지운다. 앞의 확인(되돌림 사본, 임시 클러스터, 앱 멈춤, 앱 역할 접속, 목록)이 하나라도 없으면 시작하지 않는다. 지우기 직전에 다시 보는 것: 잠금이 이 실행의 것인지(`step`), 4-4·4-5가 쓸 목록·SQL이 4-2가 검증한 그대로인지(없어지거나 바뀌었으면 DROP 뒤가 아니라 여기서 멈춘다), 임시 클러스터가 지금도 이 실행의 복원 원본이고 덤프가 끝까지 읽히는지, 앱이 지금도 멈춰 있는지(표식 뒤 다른 PR로 다시 떴을 수 있다), 복원 Job이 살아 있고 앱 역할로 접속되는지. 표식(`ok-auth`)은 남아도 Job은 약 2시간(`sleep 7000`, `activeDeadlineSeconds: 7200`) 뒤 끝나므로, 4-1 뒤 오래 지났으면 지운 뒤에야 4-4에서 멈출 수 있다. 확장은 원본 소유자로 만든다. `postgres` 소유는 `postgres`가, 앱 역할 소유(trusted)는 앱 역할(복원 Job)이 만든다. 다시 만든 DB는 PUBLIC CONNECT 기본값이라 데이터 차트 hook과 같은 ACL(PUBLIC CONNECT 없음, 앱 역할과 `cnpg_metrics_exporter`만 CONNECT)로 되돌리고 확인한다.

   ```bash
   ( set -euo pipefail; step db
     use
     # SQL은 표준 입력으로, 값은 psql 변수로(-c에서는 치환되지 않는다). :"x"는 식별자, :'x'는 문자열로 psql이 인용한다.
     q() { kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tA -v app="$APP" "$@"; }
     jobready
     # 4-3·4-4·4-5가 쓸 입력(확장 목록, 본 복원 목록, ACL 목록·SQL)이 4-2가 검증한 그대로인지 DROP 전에 본다.
     # 없어지거나 못 읽거나 바뀌었으면 DROP 뒤가 아니라 여기서 멈춘다. 고치려면 4-2부터 다시 돌린다(기준은 4-2만 만든다).
     same >/dev/null || { echo "4-2 뒤 입력 파일이 없어졌거나 바뀌었다(위). 4-2를 다시 돌린다" >&2; exit 1; }
     # 확장 목록은 한 번 읽고 뒤에서는 이 값만 쓴다(DROP 뒤에 파일을 다시 읽다 실패하지 않게). 모양 검사도 한 번 더.
     ext=$(cat "$W/ext")
     extok "$ext"
     [ -s "$W/main.list" ] || { echo "본 복원 목록 main.list가 비었다. 4-2를 다시 돌린다" >&2; exit 1; }
     sqlok "$W/acl-su.sql" | cat -v || { echo "postgres로 넣을 ACL에 허용하지 않는 문장이 있다(위 줄)" >&2; exit 1; }
     # 복원 원본이 지금도 읽히는지: 임시 클러스터의 spec·상태(srcok)와, 그 목록으로 덤프를 끝까지 읽어 보기(4-2와 같은 확인).
     # 원본이 죽었으면 4-4에서야 덤프 실패로 멈춰 지금 DB만 지운 꼴이 된다.
     srcok
     J sh -c 'cat > /tmp/main.list' < "$W/main.list"
     dump | JR -L /tmp/main.list -f /dev/null
     # 앱이 지금도 멈춰 있는지(표식 뒤 다른 PR로 다시 떴을 수 있다). 떠 있으면 FORCE DROP이 실행 중인 앱의 DB를 지운다.
     stopped
     # 파괴 단계에 들어간다는 표시. ok-가 아니라 begin이 지우지 않는다. 1단계가 이것을 보고 되돌림 사본을 새로 만들지 않는다.
     touch "$W/dropped"
     # DB가 있으면(처음, 또는 앞 실행이 CREATE 뒤 실패) 지우기 직전에 앱 역할 접속을 확인하고 지운다.
     # 없으면(앞 실행이 DROP 뒤 끊김) 앱 역할 접속은 할 수 없으니 건너뛰고 바로 만든다.
     n=$(dbn)
     [ "$n" = 0 ] || [ "$n" = 1 ]
     if [ "$n" = 1 ]; then
       jobauth "$APP"
       printf '%s\n' 'DROP DATABASE IF EXISTS :"app" WITH (FORCE)' | q
     fi
     # CNPG Database 리소스가 먼저 다시 만들 수 있다. 있으면 owner만 보고, 없으면 만든다.
     dbown=$(printf '%s\n' "select pg_get_userbyid(datdba) from pg_database where datname = :'app'" | q)
     if [ -z "$dbown" ]; then printf '%s\n' 'CREATE DATABASE :"app" OWNER :"app"' | q
     elif [ "$dbown" != "$APP" ]; then echo "DB owner가 앱 역할이 아니다" >&2; exit 1; fi
     # 다시 만든 DB는 PUBLIC CONNECT 기본값이다(DB 권한은 덤프에 없다). 데이터 차트 hook(pg-acl, 1.0.3)은 sync 때만 돌아
     # 복원 뒤 저절로 다시 돌지 않는다. 그래서 같은 SQL을 여기서 넣는다. 바꿀 때 차트 templates/postgres.yaml과 함께.
     printf '%s\n' 'REVOKE CONNECT ON DATABASE :"app" FROM PUBLIC;' 'GRANT CONNECT ON DATABASE :"app" TO :"app", cnpg_metrics_exporter;' | q
     pub=$(printf '%s\n' "select has_database_privilege('public', current_database(), 'CONNECT')" | q -d "$APP")
     [ "$pub" = f ] || { echo "PUBLIC CONNECT가 남았다" >&2; exit 1; }
     # 이제 DB가 있다. 앱 역할 소유 확장을 만들기 전에 앱 역할 접속을 본다.
     jobauth "$APP"
     # 확장은 덤프의 SQL을 실행하지 않고 원본의 스키마·버전·소유자로 만든다.
     while read -r e sch v own; do
       [ -n "$e" ] || continue
       if [ "$sch" != public ]; then
         printf '%s\n' 'CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"app"' | q -d "$APP" -v sch="$sch"
       fi
       sql="CREATE EXTENSION :\"e\" SCHEMA :\"sch\" VERSION :'v'"
       if [ "$own" = postgres ]; then printf '%s\n' "$sql" | q -d "$APP" -v e="$e" -v sch="$sch" -v v="$v"
       else printf '%s\n' "$sql" | J psql -v ON_ERROR_STOP=1 -tA -v e="$e" -v sch="$sch" -v v="$v"; fi
     done <<< "$ext"
     touch "$W/ok-db" )
   [ -f "$W/ok-db" ] && echo "통과: db" || echo "멈춤: DB를 다시 만들지 않았다. 위에 '확인이 끝나지 않았다'나 Job 확인 실패가 있으면 그 단계로 돌아간다. DROP 뒤 실패했으면 원인을 고치고 이 블록을 다시 돌린다(빈 DB를 다시 지운다)"
   ```

   **4-4. 본 복원(앱 역할).** 4-3에서 만든 확장의 `EXTENSION`과 `COMMENT - EXTENSION` 항목은 목록에서 뺐다(4-2). 남기면 앱 역할이 `postgres` 소유 확장에 주석을 달다 `must be owner of extension`으로 멈춘다(로컬 실측). `--no-owner`는 모든 객체를 앱 역할 소유로, `--no-privileges`는 GRANT·REVOKE를 건너뛴다. 덤프는 원래 순서 그대로 읽으므로 표준 입력과 `-L`을 함께 쓸 수 있다.

   ```bash
   ( set -euo pipefail; step main
     use
     jobready
     jobauth "$APP"
     stopped
     same
     J sh -c 'cat > /tmp/main.list' < "$W/main.list"
     dump | JRD -L /tmp/main.list --no-owner --no-privileges --exit-on-error
     touch "$W/ok-main" )
   [ -f "$W/ok-main" ] && echo "본 복원됨" || echo "멈춤: 본 복원에 실패했다(되돌림 사본은 1단계)"
   ```

   **4-5. ACL 복원과 대조.** `--no-privileges`만으로 끝내면 원본의 `REVOKE ... FROM PUBLIC`이 사라져, 새 함수는 PostgreSQL 기본값(PUBLIC 실행 가능)으로 돌아간다. 공유 클러스터라 다른 앱 역할이 원래 못 부르던 함수(특히 `SECURITY DEFINER`)를 부를 수 있게 된다. 그래서 ACL 항목(`ACL`, `DEFAULT ACL`)을 따로 넣는다.

   - **앱 역할 소유 객체:** 앱 역할로 넣는다. GRANT·REVOKE는 객체 소유자만 할 수 있어 앱 역할로는 자기 객체 권한만 바뀐다.
   - **`postgres` 소유 객체(확장에 딸린 객체):** 앱 역할은 바꿀 수 없다(원본에서 운영자가 바꾼 권한이 여기 온다). 덤프에서 SQL 텍스트만 만들고(`pg_restore -f -`, 실행하지 않는다), 모든 줄이 `GRANT`·`REVOKE`와 pg_restore가 붙이는 고정 머리(`SET`, `search_path` 비우기, `\restrict`)뿐인지 본 뒤에만 `postgres`로 넣는다. GRANT·REVOKE는 사용자 코드를 실행하지 않으므로 슈퍼유저 문맥에서 덤프를 실행하는 문제(위 "복원은 앱 역할로 한다")가 생기지 않는다. 다른 문장이 섞이면 넣지 않고 멈춘다.

   그다음 임시 클러스터(원본)와 복원본의 ACL(확장에 딸린 객체 포함)이 같은지 본다. DB 단위 권한(CONNECT)은 DB별 덤프에 없어(`--create` 없이 뜬다) 대조하지 않는다. 원본이 데이터 차트 1.0.3 전 시점이면 PUBLIC CONNECT가 남아 있어 대조하면 늘 다르다. 그 값은 4-3이 차트와 같게 두고 확인한다. 두 조회는 각각 성공과 결과가 비어 있지 않음을 확인한 뒤 비교한다(조회가 둘 다 실패해 빈 출력끼리 비교하면 "같음"이 된다). 결과에는 늘 `public` 스키마 줄이 있어 비지 않는다.

   ```bash
   ACL_SQL=$(cat <<'SQL'
   select kind, name, coalesce(acl, '-') from (
     select 'function' kind, p.oid::regprocedure::text name, p.proacl::text acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname not in ('pg_catalog', 'information_schema')
     union all
     select 'relation', c.oid::regclass::text, c.relacl::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%'
     union all
     select 'schema', n.nspname, n.nspacl::text from pg_namespace n where n.nspname not like 'pg\_%' and n.nspname <> 'information_schema'
     union all
     select 'type', t.oid::regtype::text, t.typacl::text from pg_type t join pg_namespace n on n.oid = t.typnamespace
      where t.typacl is not null and n.nspname not in ('pg_catalog', 'information_schema')
     union all
     select 'default', pg_get_userbyid(a.defaclrole) || ' ' || coalesce(a.defaclnamespace::regnamespace::text, '*') || ' ' || a.defaclobjtype::text, a.defaclacl::text from pg_default_acl a
   ) x order by 1, 2;
   SQL
   )
   ( set -euo pipefail; step acl
     use
     jobready
     jobauth "$APP"
     stopped
     # 없어진 ACL 목록·SQL을 "넣을 것 없음"으로 건너뛰지 않게(아래 [ -s ]) 4-3이 읽어 본 것과 같은지 먼저 본다
     same
     if [ -s "$W/acl.list" ]; then
       J sh -c 'cat > /tmp/acl.list' < "$W/acl.list"
       dump | JRD -L /tmp/acl.list --no-owner --exit-on-error
     fi
     # 4-2에서 만들고 검증한 SQL만 넣는다. 그 사이 파일이 바뀌었을 때를 위해 한 번 더 본다.
     if [ -s "$W/acl-su.sql" ]; then
       sqlok "$W/acl-su.sql" | cat -v || { echo "postgres로 넣을 ACL에 허용하지 않는 문장이 있다(위 줄)" >&2; exit 1; }
       kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -q -o /dev/null < "$W/acl-su.sql"
     fi
     acl() { printf '%s\n' "$ACL_SQL" | kubectl -n database exec -i "$1" -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -qAt; }
     acl "$TMP" > "$W/acl-src"
     acl "$PRIMARY" > "$W/acl-dst"
     [ -s "$W/acl-src" ]
     [ -s "$W/acl-dst" ]
     diff "$W/acl-src" "$W/acl-dst" | cat -v      # 이름은 앱이 만든 값이라 제어문자를 막아 보인다
     touch "$W/ok-acl" )
   [ -f "$W/ok-acl" ] && echo "ACL 원본과 같음" || echo "멈춤: ACL 복원·조회에 실패했거나 원본과 다르다(재개하지 않는다)"
   ```

   다르면 차이 줄(`kind|이름|ACL`)을 보고 원본 ACL대로 그 객체의 소유자로 GRANT·REVOKE한 뒤 이 블록을 다시 돌린다.

   **4-6. 확인.**

   ```bash
   ( set -euo pipefail; step verify
     use
     # 명령 치환은 독립 할당으로(실패면 set -e가 멈춘다) 받은 뒤 비교한다
     ap=$(kubectl -n database get database $APP -o jsonpath='{.status.applied}')
     [ "$ap" = true ]   # 재조정이 다시 만든 DB를 건드리지 않음
     # 앱 역할이 승격되지 않았는지
     roles=$(kubectl -n database exec "$PRIMARY" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tAc \
       "select rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls from pg_roles where rolname='$APP'")
     [ "$roles" = "f|f|f|f|f" ]
     touch "$W/ok-verify" )
   [ -f "$W/ok-verify" ] && echo "확인 끝" || echo "멈춤: Database 적용이나 역할 권한이 이상하다(재개하지 않는다)"
   ```

   객체 소유자는 모두 앱 역할이다(4-3에서 만든 확장만 `postgres`). 덤프에 다른 역할 소유의 객체가 있었다면 그 소유는 돌아오지 않는다(앱 역할 하나가 DB owner라 보통 없다).

5. **캐시 비우기와 앱 재개(PR):** `ok-verify`가 없거나 잠금(`restore-pg`)이 이 실행의 것이 아니면 재개 PR을 올리지 않는다. 앱이 캐시 Valkey(`cache.enabled`)를 쓰면 재개 전에 캐시 파드를 지운다. 캐시는 `emptyDir`이라 새 파드는 빈 상태로 뜬다. 지우지 않으면 T1 뒤의 값(되돌린 DB에 없는 행)을 계속 돌려준다.

   ```bash
   ( set -euo pipefail; need verify
     mine
     # 캐시를 쓸 때만
     kubectl -n app-$APP delete pod -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$APP
     kubectl -n app-$APP rollout status deploy/$APP-valkey )
   ```

   그다음 PR로 `suspended` 줄을 지운다. 마이그레이션 Job이 다시 돌고 앱이 뜬다.

6. **정리:** 임시 Cluster, 그 PVC, 도우미 Job 둘, 잠금을 지우고 0개를 본다. 잠금은 앱을 재개한 뒤에 지운다(그 전에 지우면 다른 실행이 DB를 지울 수 있다). 잠금은 이 실행의 파드가 모두 없어진 것을 확인한 뒤 마지막에 지운다. `kubectl delete job`의 기본(background)은 Job 객체를 먼저 없애고 파드를 나중에 지워, 끝나지 않은 `pg_restore`·`psql`이 도는 동안 잠금이 풀릴 수 있다. 그래서 Job은 foreground로 지우고 기다린다. 앞의 삭제·확인이 하나라도 실패하면 잠금은 남는다(다음 실행이 멈춘다). 원인을 고치고 이 블록을 다시 돌린다.

   ```bash
   ( set -euo pipefail
     kubectl -n app-$APP delete job restore-$RUN-db --ignore-not-found --cascade=foreground --wait=true --timeout=5m
     kubectl -n database delete job restore-$RUN-r2 --ignore-not-found --cascade=foreground --wait=true --timeout=5m
     kubectl -n database delete cluster pg-restore-$RUN --ignore-not-found --wait=true --timeout=10m
     kubectl -n database delete pvc -l homelab.ukyi.app/restore=$RUN --wait=true --timeout=10m
     # 잠금 말고는 이 실행의 것이 하나도 없어야 한다(파드 포함). 조회는 독립 할당(실패면 set -e가 멈춘다).
     out=$(kubectl get cluster,job,pvc,pod -A -l homelab.ukyi.app/restore=$RUN -o name)
     if [ -n "$out" ]; then printf '%s\n' "$out" | cat -v >&2
       echo "이 실행의 객체가 남아 있다(위). 없어진 뒤 이 블록을 다시 돌린다(잠금은 그대로)" >&2; exit 1; fi
     kubectl -n app-$APP delete configmap -l homelab.ukyi.app/restore=$RUN       # 잠금 restore-pg(이 실행의 것만)
     out=$(kubectl get cluster,job,pvc,pod,configmap -A -l homelab.ukyi.app/restore=$RUN -o name)
     [ -z "$out" ] )
   # 서브셸 뒤에 ||·&&를 붙이지 않는다(0.1). 종료 코드는 다음 줄에서 본다.
   [ $? -eq 0 ] && echo "정리 끝(0개)" || echo "멈춤: 정리가 끝나지 않았다. 잠금이 남았으면 다음 실행은 멈춘다"
   ```

7. **확인:** 앱 readiness와 표식 행(시나리오 10). 다른 앱 DB(시나리오 10의 `homelab-probe2`)의 T1 뒤 쓰기가 남아 있는지도 본다.

## 2a. 악성 스키마 복원 시험 (로컬)

4단계를 앱 역할로 하는 이유를 확인하는 시험이다. 이 기기 안의 버리는 PostgreSQL에서만 돌린다. 앱 역할이 자기 DB에 "CHECK 제약이 호출하는 함수가 자기 역할을 superuser로 올린다"는 객체를 심고, 그 덤프를 두 방식으로 복원해 역할의 `rolsuper`를 본다. 2026-10-23 결과(postgres 18): 슈퍼유저 복원은 `t`(승격됨), 앱 역할 `--no-owner --no-privileges` 복원은 `f`. 둘 다 행 2개가 돌아왔다. 복원 방식을 바꾸면 다시 돌린다.

```bash
podman run -d --name pgm -e POSTGRES_HOST_AUTH_METHOD=trust docker.io/library/postgres:18-alpine; sleep 6
q(){ podman exec -i pgm psql -v ON_ERROR_STOP=1 -qAt "$@"; }
q -U postgres -c "create role app login password 'apppw'" -c "create database app owner app"
q -U app -d app <<'SQL'
create function evil(int) returns boolean language plpgsql as $f$
begin
  begin execute 'alter role app superuser'; exception when others then null; end;
  return true;
end $f$;
create table t (x int check (evil(x)));
insert into t values (1),(2);
SQL
podman exec pgm sh -c 'pg_dump -U postgres -Fc app > /tmp/app.dump'
for mode in superuser app-role; do
  q -U postgres -c "alter role app nosuperuser" -c "drop database app with (force)" -c "create database app owner app"
  if [ $mode = superuser ]; then podman exec pgm pg_restore -U postgres -d app --exit-on-error /tmp/app.dump
  else podman exec pgm sh -c 'PGPASSWORD=apppw pg_restore -h 127.0.0.1 -U app -d app --no-owner --no-privileges --exit-on-error /tmp/app.dump'; fi
  echo "$mode rolsuper=$(q -U postgres -c "select rolsuper from pg_roles where rolname='app'")"   # superuser t, app-role f
done
podman rm -f pgm
```

0.1과 3·4단계의 블록은 문서에서 그대로 꺼내 zsh로 돌렸다(2026-10-23, 일부는 bash로 다시 확인). 원본·대상 PostgreSQL 18 둘, 복원 Job 대신 CNPG 이미지 컨테이너(uid 26, 읽기 전용 루트)를 썼고 `kubectl`은 `podman` 대역 함수다. 1·2단계 표식은 손으로 만들었다(R2·CNPG 복구는 클러스터에서만 된다). 3단계(앱 멈춤 확인)는 로컬 kind(v0.33.0, Kubernetes 1.37)에서 실제 Deployment·Job으로 돌렸다.

원본에는 다음을 넣었다.
- 위 악성 CHECK
- `postgres` 소유 untrusted 확장 `postgres_fdw`(기본이 아닌 스키마 `ext`, 옛 버전 1.0, 기본 1.2). 그 확장 함수 하나의 ACL을 `postgres`가 바꿈(PUBLIC 회수, 다른 역할 허용)
- 앱 역할이 직접 만든 trusted 확장 `uuid-ossp`(이름에 `-`)
- `postgres`가 앱 역할에 `WITH GRANT OPTION`으로 준 확장 함수 권한과 앱 역할이 그것을 다시 준 권한, `postgres`의 기본 권한(`ALTER DEFAULT PRIVILEGES FOR ROLE postgres`)
- 앱 역할이 바꾼 `public` 스키마 ACL, 전역 `REVOKE EXECUTE ... FROM PUBLIC`, 다른 역할 GRANT
- 특수문자 비밀번호(`@ : / + 공백 % \`)

결과:
- 정상: 모든 표식. 확장은 원본 스키마·버전·소유자 그대로(`postgres_fdw`는 `ext` 1.0 `postgres`, `uuid-ossp`는 `public` 1.1 앱 역할). `postgres` 소유 확장 객체의 ACL은 4-2에서 만들고 검증한 SQL(GRANT·REVOKE, 위임 권한의 `SET SESSION AUTHORIZATION "<앱>"`…`RESET`, `ALTER DEFAULT PRIVILEGES FOR ROLE postgres`)로 넣었고, 확장 객체·`public` 스키마를 포함한 ACL이 원본과 같았다. 권한 없던 역할의 함수 실행 거부, `rolsuper` 등 모두 f, argv의 비밀번호 0건. `COMMENT - EXTENSION`을 목록에 남기면 `must be owner of extension`으로 멈춘다.
- 4-1·4-2를 3단계보다 먼저: 3단계가 `auth`·`list` 표식을 지우지 않아 4-3이 그대로 진행됐다.
- 4-1을 같은 RUN으로 다시: 앞 Job을 지우고 다시 만들어 통과했다.
- 1단계를 4-3 뒤 같은 RUN으로 다시(R2 대신 로컬 `rclone serve s3`): 이미 있는 되돌림 사본을 덮어쓰지 않고 검증만 했다(sha256 같음, 사본에 원래 표식 행). 사본이 없어진 경우는 `dropped` 표시를 보고 새로 만들지 않고 멈췄다.
- 4-3이 DROP 뒤 CREATE 전에 끊긴 상태에서 4-1·4-2·4-3을 다시: 4-1은 `postgres` DB로 접속을 확인하고, 4-3은 DB가 없어 앱 역할 접속 없이 바로 만든 뒤(그다음 접속 확인) 끝까지 갔다.
- 앱 역할 밖의 역할(`third`)이 위임받은 권한을 다시 준 원본: 4-2에서 `SET SESSION AUTHORIZATION third`를 허용하지 않아 멈췄다(DB 삭제 전).
- 4-2 뒤 복원 Job이 끝남: 4-3이 DB를 지우기 전에 Job 확인에서 멈췄다.
- 확장 스키마 이름이 `e";DROP ROLE third;--`: 4-2의 모양 검사에서 멈춰 4-3이 시작하지 않았다(지금 DB·역할 그대로). 검사를 건너뛰고 4-3의 인용 SQL에 같은 이름을 직접 넣으면 그 이름 그대로의 스키마가 생기고 역할은 그대로였다. 버전 값에 `'; DROP ROLE ...`을 넣으면 문자열로 다뤄져 거부됐다.
- 목록 단계에서 임시 클러스터가 죽음, 줄바꿈 든 비밀번호(Job이 시작하지 않음), 되돌림 사본 표식 없음: 셋 다 4-3이 시작하지 않아 지금 DB가 그대로였다.
- 같은 RUN으로 4-3을 다시 돌리다 실패: 블록 시작에서 `ok-db`가 지워져 4-4가 멈췄다.
- 본 복원 뒤 ACL 조회 실패: `ok-acl`이 생기지 않아 4-6과 재개 블록이 멈췄다.
- 3단계: replicas 0 + 완료된 `<앱>-migrate` 파드만 있으면 통과, replicas 1이거나 앱 라벨의 실행 중 파드가 있으면 멈춤.
- 고치기 전 모양 `( set -e ... ) && touch`와 `! grep`은 실패를 찍은 뒤에도 다음 줄로 넘어갔다. `&&`·`||`의 왼쪽과 `!` 뒤에는 `set -e`가 듣지 않기 때문이다(0.1의 규칙).

## 3. 빈 NUC 복구 (설계 C.6.4)

클러스터를 잃었을 때의 전체 순서는 설계 C.6.4 "복구 순서" 표다. 여기는 데이터에 해당하는 두 PR과 확인만 적는다.

VM 시험(시나리오 13, 설계 E8 VM 격리)도 같은 순서다. 다른 점은 단계마다 "VM 시험" 줄에 있다: 값 파일은 `values-vm.yaml`만 고치고, 운영 아카이브는 손으로 넣는 읽기 전용 자격(`r2-source-readonly`)으로만 읽는다. VM 블록은 NUC에서 VM kubeconfig(`~/.kube/homelab-vm.yaml`)로 돌고, 운영 kubeconfig로 새지 않게 블록마다 처음에 `KUBECONFIG`를 고정하고 `host/verify.sh --cluster vm --identity`로 대상을 확인한다.

**복구 PR을 root apply보다 먼저 병합한다.** Git이 평상시 값(`initdb`)인 채 root를 apply하면 Argo CD가 빈 Cluster `pg`를 먼저 만들고, bootstrap은 초기화 때만 읽혀 나중에 Git을 고쳐도 떠 있는 클러스터는 바뀌지 않는다. Cluster에는 보호 주석이 있어 Argo CD가 지우지도 않는다.

1. **복구 PR:** 실제 빈 NUC 복구는 `platform/root/values-prod.yaml`의 `cluster.cnpg`에서(VM 시험은 아래 VM 줄)
   - `recoverySource.serverName`에 지금 Git의 `serverName`을 옮겨 적고,
   - `serverName`을 새 세대 `pg-<복구일 YYYYMMDD>`로 바꾼다.
   - 영속 Valkey가 있는 앱마다 `data/<앱>/values.yaml`에 `valkey.running: false`, `apps/<앱>/values.yaml`에 `suspended: true`(앱 차트 1.1.0 이상)를 같은 PR에 넣는다. root apply가 ApplicationSet을 바로 동기화하므로, 넣지 않으면 빈 PVC 위의 Valkey와 앱이 먼저 떠 빈 큐로 돌거나 새로 쓴 데이터가 RDB 복원에서 사라진다.
   - **VM 시험(시나리오 13)은 위 두 값을 공용 `apps/`·`data/` values에 넣지 않는다**(운영 앱·Valkey도 멈춘다). `platform/root/values-vm.yaml`의 `cluster.restore`에 `suspendedApps: [<앱>]`와 `valkey: {<앱>: stopped}`를 넣는다. 1절 3단계(복원 모드로 올림)는 `valkey: {<앱>: restoreMode}`, 1절 5단계와 아래 5단계의 앱 재개는 그 항목을 지우는 values-vm PR이다. 공용 values를 고치는 CLI(`homelab cache restore`·`db restore`)는 VM에 쓰지 않는다.
   - **VM 시험의 복구 PR은 `values-vm.yaml` 하나만 고친다.** `values-prod.yaml`·`apps/`·`data/`는 그대로라 운영 렌더가 바뀌지 않는다. VM 격리 값은 root 렌더가 단언한다(`platform/root/templates/cluster-check.yaml`: 접두 `vm-`, `homelab-dev`/`dev`, 운영과 다른 버킷, 운영과 다른 `pg-vm-<YYYYMMDD>`).

     ```yaml
     cluster:
       cnpg:
         serverName: pg-vm-<시험일 YYYYMMDD>         # VM 세대. VM 버킷에서 비어 있는 prefix여야 한다
         recoverySource:
           serverName: <values-prod.yaml의 지금 serverName>   # 운영 아카이브(복구 원본)
           bucket: homelab-backups                    # 빠뜨리면 VM 버킷을 읽는다
           credentialsSecret: r2-source-readonly      # 빠뜨리면 VM 자격(r2-backup)으로 운영 버킷을 읽다 거부된다
       restore:
         suspendedApps: [<앱>]
         valkey: {<앱>: stopped}                      # 영속 Valkey가 있는 앱만
     ```

     `r2-source-readonly`는 **운영 백업 버킷 `homelab-backups`에만 한정한** R2 Object Read 토큰이다(복구 자산, Infisical 밖). VM 버킷(`homelab-backups-vm`) 토큰이 아니다(3단계). VM에 운영 버킷에 쓰는 자격이 없게 하려는 것이다. 키 이름은 `r2-backup`과 같은 `ACCESS_KEY_ID`·`SECRET_ACCESS_KEY`·`ENDPOINT_URL`이다(차트가 이 이름으로 읽는다). 같은 Cloudflare 계정이라 `ENDPOINT_URL`은 VM 버킷 자격과 같은 값이다. plugin sidecar는 두 ObjectStore의 env를 이름으로 합치고 먼저 온 값을 쓰므로 다르면 한쪽이 무시된다.

   렌더 결과는 `bootstrap.recovery` + 원본 전용 ObjectStore `r2-source`(옛 serverName) + 아카이브 plugin(새 serverName)이다. 새 serverName을 빠뜨리면 렌더가 실패한다(같은 prefix에 두 세대가 섞이면 되돌릴 수 없다). `cnpg.io/skipEmptyWalArchiveCheck` 주석은 쓰지 않는다.

2. **분기: 실제 빈 NUC 복구 / VM 시험(시나리오 13)**
   - 실제 빈 NUC 복구: Tailscale 콘솔에서 잃은 클러스터의 operator·프록시 기기(`tag:k8s-operator`, `tag:k8s`)를 지운다. OS를 다시 깔았으면 `tailscale up` 전에 옛 NUC 호스트 기기도 지운다(남아 있으면 새 이름에 `-1`이 붙고 되돌아가지 않는다).
   - VM 시험: 이 단계를 건너뛴다. 그 기기들은 살아 있는 운영 클러스터의 것이다. 시험 뒤 `vm-*` 기기만 지운다.
3. [bootstrap.md](bootstrap.md) 순서로 host → k3s → Argo CD → ESO 부트스트랩 Secret → root apply.

   **VM 시험: root apply 전에 복구 원본 자격을 넣고 쓰기 거부를 본다.** bootstrap.md 2.2 vm 분기 3단계와 같은 블록이다(한쪽을 고치면 다른 쪽도). root가 먼저 뜨면 cnpg-cluster(wave -3)가 자격 없는 `r2-source`로 복구를 시작하므로 root apply보다 앞에 둔다. `database` ns는 namespaces(wave -9)가 나중에 PSA 라벨을 붙여 넘겨받는다. 값은 복구 자산의 읽기 전용 토큰에서 `export`로 넣고 출력하지 않는다. 명령행 인자로 넘기지 않는다(`ps`·`/proc`로 보인다).

   **넣는 토큰은 운영 버킷 `homelab-backups`에 묶인 읽기 전용 토큰이다. VM 버킷(`homelab-backups-vm`)에 묶인 토큰을 넣지 않는다.** 둘 다 같은 Cloudflare 계정의 R2 토큰이고 endpoint도 같아 헷갈리기 쉽다. 2026-10-28 시험에서 VM 버킷 토큰을 두 번 넣었고, 아래 쓰기 거부 시험의 읽기 단계가 403으로 막았다. 그때는 운영 버킷 토큰으로 이 블록을 다시 돌려 Secret을 덮어쓰고 쓰기 거부 시험을 다시 한다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   : "${R2_RO_ACCESS_KEY_ID:?R2_RO_ACCESS_KEY_ID가 비었다}" "${R2_RO_SECRET_ACCESS_KEY:?R2_RO_SECRET_ACCESS_KEY가 비었다}" "${R2_RO_ENDPOINT:?R2_RO_ENDPOINT가 비었다}"
   git fetch -q origin main
   src=$(git show origin/main:platform/root/values-vm.yaml | yq -o json '.cluster.cnpg.recoverySource // {}')
   [ "$(jq -r '.credentialsSecret' <<<"$src")" = r2-source-readonly ] && [ "$(jq -r '.bucket' <<<"$src")" = homelab-backups ] \
     || { echo "main의 values-vm.yaml에 복구 PR(recoverySource.bucket·credentialsSecret)이 없다. 먼저 병합한다" >&2; exit 1; }
   kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
   jq -n '{apiVersion: "v1", kind: "Secret", type: "Opaque",
           metadata: {name: "r2-source-readonly", namespace: "database"},
           stringData: {ACCESS_KEY_ID: env.R2_RO_ACCESS_KEY_ID, SECRET_ACCESS_KEY: env.R2_RO_SECRET_ACCESS_KEY, ENDPOINT_URL: env.R2_RO_ENDPOINT}}' \
     | kubectl apply --server-side --field-manager=bootstrap -f -
   EOF
   ```

   쓰기 거부 시험(설계 G 시나리오 13): 같은 자격으로 운영 아카이브를 읽고, 운영 버킷에 시험 객체를 올려 403으로 거부되는지, 객체가 남지 않았는지 본다. `database` ns는 나가는 연결을 막지 않아(인스턴스가 R2 443에 나간다) 일회성 Job도 R2에 닿는다. rclone 오류 문구는 출력하지 않는다(endpoint에 Cloudflare 계정 ID가 들어 있다). 기록에는 결과 줄만 옮긴다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   git fetch -q origin main
   SRV=$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.cnpg.recoverySource.serverName')
   [ "$SRV" = "$(git show origin/main:platform/root/values-prod.yaml | yq '.cluster.cnpg.serverName')" ] \
     || { echo "recoverySource.serverName($SRV)이 운영 serverName과 다르다" >&2; exit 1; }
   J=r2-ro-check-$(date -u +%Y%m%d%H%M%S)
   err=$(mktemp)
   trap 'rm -f "$err"; kubectl -n database delete job "$J" --ignore-not-found --wait=false >/dev/null' EXIT
   kubectl apply -f - <<YAML
   apiVersion: batch/v1
   kind: Job
   metadata: { name: $J, namespace: database }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 1800
     template:
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: rclone
             image: docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
             command: ["sleep", "1700"]
             env:
               - { name: HOME, value: /tmp }
               - { name: RCLONE_CONFIG_SRC_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_SRC_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_SRC_REGION, value: auto }
               - { name: RCLONE_CONFIG_SRC_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_SRC_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_SRC_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ENDPOINT_URL } } }
             resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { memory: 128Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts: [{ name: tmp, mountPath: /tmp }]
         volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
   YAML
   # --for=create가 먼저다. 없으면 Job 컨트롤러가 파드를 만들기 전에 "no matching resources found"로 바로 끝난다
   kubectl -n database wait --for=create --for=condition=ready pod -l job-name="$J" --timeout=5m
   x() { kubectl -n database exec -i "job/$J" -- rclone --retries 1 --low-level-retries 1 "$@"; }
   # 읽기: 운영 아카이브의 base backup 디렉터리가 보인다(복구가 읽을 것)
   n=$(x lsf --dirs-only "src:homelab-backups/pg/$SRV/base/" </dev/null 2>/dev/null | wc -l) \
     || { echo "읽기 실패: 토큰이 운영 버킷 homelab-backups에 묶였는지(VM 버킷 토큰이 아닌지), serverName을 본다" >&2; exit 1; }
   [ "$n" -gt 0 ] || { echo "운영 아카이브 pg/$SRV/base/에 base backup이 없다" >&2; exit 1; }
   # 쓰기: 시험 객체 업로드가 403으로 거부돼야 한다
   KEY="t13-write-check/$J"
   if printf x | x rcat "src:homelab-backups/$KEY" 2>"$err"; then
     x deletefile "src:homelab-backups/$KEY" </dev/null >/dev/null 2>&1 || true
     echo "쓰기가 성공했다: 읽기 전용 토큰이 아니다. 시험 객체를 지우고 토큰을 폐기·재발급한다" >&2; exit 1
   fi
   grep -Eq '403|AccessDenied' "$err" || { echo "쓰기는 실패했지만 403(AccessDenied)이 아니다" >&2; exit 1; }
   # 객체가 남지 않았다. 버킷 뿌리에서 그 키 하나만 거른다(없는 prefix를 나열하면 오류가 날 수 있어서)
   left=$(x lsf -R --files-only "src:homelab-backups" --include "/$KEY" </dev/null 2>/dev/null) \
     || { echo "확인 목록을 읽지 못했다" >&2; exit 1; }
   [ -z "$left" ] || { echo "시험 객체가 남았다: $KEY" >&2; exit 1; }
   echo "읽기 전용 확인: 운영 base backup ${n}개 보임, 쓰기 403 거부, 시험 객체 없음"
   EOF
   ```

   통과한 뒤 bootstrap.md 2.3으로 `root-vm.yaml`을 apply한다.
4. **복구 확인:**

   ```bash
   kubectl -n database get cluster pg                       # Cluster in healthy state
   PRIMARY=$(kubectl -n database get cluster pg -o jsonpath='{.status.currentPrimary}')
   kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -d <앱> -tAc 'select count(*) from <표식 테이블>'
   kubectl -n database create -f - <<EOF                    # 새 serverName의 첫 base backup
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: { name: first-$(date +%Y%m%d), namespace: database }
   spec: { cluster: { name: pg }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
   EOF
   kubectl -n database get backups                          # completed
   ```

   VM 시험은 이 블록 앞에 `export KUBECONFIG=~/.kube/homelab-vm.yaml`과 `host/verify.sh --cluster vm --identity`를 둔다. Cluster가 healthy이고 시험 직전 운영 `homelab-smoke` DB에 넣은 표식 행이 VM에 있으면 **U27 통과**다(운영 버킷에만 한정한 읽기 전용 토큰으로 plugin 복구, 설계 부록 1). 새 base backup은 VM 버킷의 `pg/pg-vm-<시험일>/`에 생긴다.

   **U27 실패 때(VM 시험):** Cluster가 `Setting up primary`에 머물고 복구 파드(`kubectl -n database get pods -l cnpg.io/jobRole=full-recovery`)가 Error이며 로그에 `AccessDenied`·`403`이 있으면, plugin이 읽기 전용 토큰으로 안 되는 요청(예: HeadBucket, R2 Object 토큰은 ListBuckets·HeadBucket이 안 된다, 설계 B.8 E4)을 보낸 것이다. 로그를 기록으로 옮길 때 endpoint(계정 ID)를 빼고 응답 코드만 남긴다. 대안(설계 부록 1 U27)은 같은 읽기 전용 토큰으로 운영 아카이브를 VM 버킷에 복사한 뒤 그 사본에서 복구하는 것이다. rclone은 `no_check_bucket`이라 HeadBucket을 부르지 않는다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   git fetch -q origin main
   SRV=$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.cnpg.recoverySource.serverName')
   VMB=$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.backup.bucket')
   J=r2-ro-copy-$(date -u +%Y%m%d%H%M%S)
   trap 'kubectl -n database delete job "$J" --ignore-not-found --wait=false >/dev/null' EXIT
   # src: 운영 버킷 읽기 전용(r2-source-readonly), dst: VM 버킷 R&W(ESO가 만든 r2-backup)
   kubectl apply -f - <<YAML
   apiVersion: batch/v1
   kind: Job
   metadata: { name: $J, namespace: database }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 7200
     template:
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: rclone
             image: docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
             command: ["sleep", "7000"]
             env:
               - { name: HOME, value: /tmp }
               - { name: RCLONE_CONFIG_SRC_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_SRC_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_SRC_REGION, value: auto }
               - { name: RCLONE_CONFIG_SRC_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_SRC_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_SRC_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ENDPOINT_URL } } }
               - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_DST_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_DST_REGION, value: auto }
               - { name: RCLONE_CONFIG_DST_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-backup, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-backup, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-backup, key: ENDPOINT_URL } } }
             resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { memory: 256Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts: [{ name: tmp, mountPath: /tmp }]
         volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
   YAML
   # --for=create가 먼저다. 없으면 Job 컨트롤러가 파드를 만들기 전에 "no matching resources found"로 바로 끝난다
   kubectl -n database wait --for=create --for=condition=ready pod -l job-name="$J" --timeout=5m
   kubectl -n database exec "job/$J" -- rclone copy "src:homelab-backups/pg/$SRV" "dst:$VMB/pg/$SRV"
   kubectl -n database exec "job/$J" -- rclone check --one-way "src:homelab-backups/pg/$SRV" "dst:$VMB/pg/$SRV"
   echo "복사 확인: 운영 pg/$SRV → VM 버킷 $VMB/pg/$SRV"
   EOF
   ```

   그다음 values-vm PR로 `recoverySource.bucket`을 VM 버킷 이름으로 바꾸고 `credentialsSecret` 줄을 지운다(사본은 VM 버킷이라 VM 자격 `r2-backup`으로 읽는다). Argo CD가 `cnpg-cluster`를 그 값으로 동기화한 뒤, 실패한 Cluster를 VM에서만 지운다. bootstrap은 처음 만들 때만 읽혀 값만 바꿔서는 다시 복구하지 않기 때문이다. 지우면 Argo CD가 새 값으로 다시 만든다. 복구가 또 `Expected empty archive`로 멈추면 VM serverName prefix에 앞 시도가 쓴 것이 있는 것이니 같은 방식의 PR로 VM `serverName` 날짜를 바꾼다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   git fetch -q origin main
   VMB=$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.backup.bucket')
   # 지우기 전에 복구 원본이 사본을 가리키는지 본다. 아니면 selfHeal이 옛 값으로 다시 만든다
   [ "$(kubectl -n database get objectstore r2-source -o jsonpath='{.spec.configuration.destinationPath}')" = "s3://$VMB/pg/" ] \
     || { echo "r2-source가 아직 VM 버킷 사본을 가리키지 않는다. values-vm PR 동기화를 기다린다" >&2; exit 1; }
   kubectl -n database delete cluster pg --wait
   EOF
   ```

5. 영속 Valkey가 있는 앱은 1절로 RDB를 복원한다. 1단계(`running: false`)는 복구 PR이 이미 했으므로 2단계(복원 Job)부터 한다. 1절 5단계까지 끝나 데이터(키 0개 아님, 표식 키를 적었으면 그 키)를 확인한 뒤에 그 앱의 `suspended` 줄을 지우는 PR로 앱을 재개한다. VM 시험은 1절 3·5단계의 PR과 앱 재개를 1단계의 VM 줄대로 `values-vm.yaml`의 `cluster.restore`로 한다.

   **2단계 전까지 `<앱>-data`가 PVC를 기다리는 것은 정상이다.** 빈 클러스터의 새 PVC `valkey-data`는 `local-retain`(WaitForFirstConsumer)이라 쓰는 파드가 생길 때까지 Pending이고, Argo CD는 Pending PVC를 Progressing으로 본다. 2단계 복원 Job이 PVC를 묶으면 풀린다. sync를 끝내거나 PVC를 손대지 않는다. 기다리는 모양은 데이터 차트 버전마다 다르다.
   - **1.0.4부터:** Database(wave 2)와 PUBLIC CONNECT를 막는 Sync hook `pg-acl`(wave 3)이 먼저 끝나고, PVC·서버는 hook 없는 마지막 wave(4)라 sync는 적용만 하고 끝난다. Application health만 PVC가 묶일 때까지 Progressing이다. 앱이 PostgreSQL도 쓰면 각 단계 PR의 Valkey 변경 중 wave 4(영속 Valkey의 PVC·서버 Deployment)의 생성·갱신은 `pg-acl`이 성공한 sync에서만 들어간다. `pg-acl-<앱>` Job이 실패하면(PostgreSQL에 접속 못 함) 그 sync는 실패하고 wave 4를 적용하지 않지만, 앞 wave의 Valkey 리소스(ExternalSecret 2개·Service·ConfigMap·NetworkPolicy는 wave 0, 백업 CronJob은 wave 1)는 이미 적용됐을 수 있다. 4단계 Cluster가 healthy인지 먼저 본다.
   - **1.0.3 이하:** sync가 `waiting for healthy state of PersistentVolumeClaim/valkey-data`로 Running에 머물고 Database CR도 여기서 멈춘다(T13 시나리오 13). 그 사이 데이터 Application은 새 values를 적용하지 않지만, 3단계 PR(복원 모드)은 2단계 뒤라 이 대기가 먼저 풀린다.

   **VM 시험: 1절 2단계 전에 운영 RDB를 VM 버킷으로 가져온다.** 1절 2단계는 백업 CronJob의 `BUCKET`(VM은 VM 버킷)에서 앱 자격(VM 버킷 토큰)으로 `valkey/<앱>/`를 읽는다. VM의 Valkey와 백업 CronJob은 복구 PR부터 멈춰 있어 VM 버킷에는 복원할 RDB가 없다. 그래서 운영 버킷의 RDB 하나를 읽기 전용 원본 자격(`r2-source-readonly`)으로 읽어 VM 버킷의 같은 키에 VM 자격(`r2-backup`)으로 쓰고, 내려받아 바이트를 대조한다. 공용 values와 운영 쓰기 자격은 쓰지 않는다. 운영 백업은 매일 03:30 KST라, 표식 키는 고른 백업 시각 전에 있던 것만 확인할 수 있다. `OBJECT=latest`면 운영의 가장 최근 것, 특정 시점이면 파일 이름(`dump-<UTC>.rdb`)을 적는다. 가져온 이름을 1절 2단계의 `OBJECT`로 쓴다.

   ```bash
   APP=<앱> OBJECT=latest bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   case $APP in ''|*[!a-z0-9-]*) echo "APP이 앱 이름이 아니다" >&2; exit 1 ;; esac
   git fetch -q origin main
   VMB=$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.backup.bucket')
   J=r2-vk-copy-$(date -u +%Y%m%d%H%M%S)
   trap 'kubectl -n database delete job "$J" --ignore-not-found --wait=false >/dev/null' EXIT
   # src: 운영 버킷 읽기 전용(r2-source-readonly), dst: VM 버킷 R&W(ESO가 만든 r2-backup)
   kubectl apply -f - <<YAML
   apiVersion: batch/v1
   kind: Job
   metadata: { name: $J, namespace: database }
   spec:
     backoffLimit: 0
     activeDeadlineSeconds: 1800
     template:
       spec:
         restartPolicy: Never
         automountServiceAccountToken: false
         securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
         containers:
           - name: rclone
             image: docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
             command: ["sleep", "1700"]
             env:
               - { name: HOME, value: /tmp }
               - { name: RCLONE_CONFIG_SRC_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_SRC_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_SRC_REGION, value: auto }
               - { name: RCLONE_CONFIG_SRC_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_SRC_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_SRC_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-source-readonly, key: ENDPOINT_URL } } }
               - { name: RCLONE_CONFIG_DST_TYPE, value: s3 }
               - { name: RCLONE_CONFIG_DST_PROVIDER, value: Cloudflare }
               - { name: RCLONE_CONFIG_DST_REGION, value: auto }
               - { name: RCLONE_CONFIG_DST_NO_CHECK_BUCKET, value: "true" }
               - { name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, valueFrom: { secretKeyRef: { name: r2-backup, key: ACCESS_KEY_ID } } }
               - { name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: r2-backup, key: SECRET_ACCESS_KEY } } }
               - { name: RCLONE_CONFIG_DST_ENDPOINT, valueFrom: { secretKeyRef: { name: r2-backup, key: ENDPOINT_URL } } }
             resources: { requests: { cpu: 10m, memory: 64Mi }, limits: { memory: 256Mi } }
             securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
             volumeMounts: [{ name: tmp, mountPath: /tmp }]
         volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
   YAML
   # --for=create가 먼저다. 없으면 Job 컨트롤러가 파드를 만들기 전에 "no matching resources found"로 바로 끝난다
   kubectl -n database wait --for=create --for=condition=ready pod -l job-name="$J" --timeout=5m
   x() { kubectl -n database exec "job/$J" -- rclone --retries 1 --low-level-retries 1 "$@" </dev/null; }
   obj=$OBJECT
   # 오류 문구는 출력하지 않는다(endpoint에 계정 ID가 들어 있다). 이름이 UTC 시각이라 정렬이 시각순이다
   if [ "$obj" = latest ]; then
     obj=$(x lsf --files-only "src:homelab-backups/valkey/$APP" 2>/dev/null | LC_ALL=C sort | tail -n 1) \
       || { echo "운영 백업 목록을 읽지 못했다: valkey/$APP" >&2; exit 1; }
   fi
   case $obj in dump-*.rdb) ;; *) echo "가져올 백업이 없거나 이름이 dump-<UTC>.rdb 꼴이 아니다: '$obj'" >&2; exit 1 ;; esac
   x copyto "src:homelab-backups/valkey/$APP/$obj" "dst:$VMB/valkey/$APP/$obj" 2>/dev/null \
     || { echo "복사 실패: valkey/$APP/$obj" >&2; exit 1; }
   # 내려받아 바이트를 대조한다(R2 ETag만으로는 multipart 객체를 대조하지 못한다)
   x check --download --one-way --include "/$obj" "src:homelab-backups/valkey/$APP" "dst:$VMB/valkey/$APP" 2>/dev/null \
     || { echo "대조 실패: valkey/$APP/$obj" >&2; exit 1; }
   echo "가져옴: VM 버킷 valkey/$APP/$obj (1절 2단계에 OBJECT=$obj)"
   EOF
   ```
6. 앱이 뜬 뒤 시나리오 1·10을 확인한다.
7. **정리 PR:** `recoverySource`를 지워 렌더 결과를 `initdb`로 되돌린다(새 serverName은 그대로). recovery를 남기면 나중에 볼륨을 잃고 Cluster를 다시 만들 때 옛 아카이브에서 낡은 데이터로 조용히 복구된다. 떠 있는 클러스터에는 영향이 없다(U26).
   - VM 시험: `values-vm.yaml`에서 `recoverySource`를 지우고, `cluster.restore`가 빈 값(`suspendedApps: []`, `valkey: {}`)인지 본다. 이 PR이 동기화되면 ObjectStore `r2-source`가 prune된다. 그 뒤 복구 원본 자격 Secret을 지운다. 컨테이너가 다시 시작될 때 참조하는 Secret이 없으면 `CreateContainerConfigError`가 나므로, 이 Secret을 참조하는 리소스가 0일 때만 지운다. 남아 있으면 그 파드를 VM에서만 지워 지금 spec으로 다시 띄운 뒤(단일 인스턴스라 잠깐 끊긴다) 다시 돌린다. 읽기 전용 토큰 자체는 Cloudflare에서 폐기한다(복구 자산 정리).

     ```bash
     bash -euo pipefail <<'EOF'
     export KUBECONFIG=~/.kube/homelab-vm.yaml
     host/verify.sh --cluster vm --identity
     git fetch -q origin main
     [ "$(git show origin/main:platform/root/values-vm.yaml | yq '.cluster.cnpg | has("recoverySource")')" = false ] \
       || { echo "main의 values-vm.yaml에 recoverySource가 남아 있다. 정리 PR부터" >&2; exit 1; }
     if kubectl -n database get objectstore r2-source >/dev/null 2>&1; then
       echo "ObjectStore r2-source가 아직 있다. 정리 PR 동기화를 기다린다" >&2; exit 1
     fi
     refs=$(kubectl -n database get pods,objectstores.barmancloud.cnpg.io,clusters.postgresql.cnpg.io -o json \
       | jq -r '.items[] | select(tostring | contains("r2-source-readonly")) | .kind + "/" + .metadata.name')
     [ -z "$refs" ] || { printf '아직 r2-source-readonly를 참조한다:\n%s\n' "$refs" >&2; exit 1; }
     kubectl -n database delete secret r2-source-readonly --ignore-not-found
     echo "복구 원본 자격 Secret을 지웠다"
     EOF
     ```

**U40(클러스터 유실과 Infisical 장애가 겹친 복구)은 이번 시나리오 13에서 하지 않았다(한계·후속, T23 할 일 2).** 스위치는 T23 할 일 1에서 만들었다. 복구 PR이 그 클러스터 값 파일의 `cluster.restore`에 `externalSecrets: false`를 넣는다(따옴표 없는 bool. 문자열이면 root 렌더가 실패한다). VM 시험은 `values-vm.yaml`에만 넣고 운영 values는 그대로 둔다. 끄면 ClusterSecretStore 셋과 모든 ExternalSecret이 렌더되지 않고, Store Application(`external-secrets-stores`)과 시험 수신기 `edge-probe`는 Application째 빠지며, ESO operator(wave -8)는 남는다. 같은 이름의 Secret은 암호화 내보내기에서 손으로 만든다. 그 목록은 `bun run ci --only external`이 출력하는 "끌 때 빠지는 것" 줄이다(Argo CD owner 자격은 새 Secret이 아니라 `argocd-secret`에 두 키를 합친다). 등록 앱이 앱 차트 1.2.0·데이터 차트 1.1.0 미만이면 끈 렌더가 schema로 실패하므로 먼저 올린다(VM 시험이면 공용 values라 일반 PR로). 함정: 살아 있는 클러스터에서 끄면 `edge-probe`의 resources-finalizer가 ns `app-edge-probe`까지 지우고, Store와 `argocd-owner`는 추적 없이 남는다. 설계한 쓰임은 빈 클러스터 복구다. 이 스위치로 root가 손 Secret만으로 끝까지 진행하는지, 되돌릴 때 ESO가 같은 이름의 기존 Secret을 넘겨받는지는 아직 VM에서 보지 않았다(T23 할 일 2, `docs/plans/2026-10-17-homelab-rebuild/issues/T23-platform-followups.md`).
