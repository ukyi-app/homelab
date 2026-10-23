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
  vars) echo run ;; predump|tmp|suspended|auth) echo run vars ;; list) echo tmp auth ;;
  db) echo predump tmp suspended auth list ;; main) echo db list ;; acl) echo main ;; verify) echo acl ;; esac; }
# 블록을 (다시) 시작할 때 그 단계와, 그 단계에 기대는 단계(표의 역방향, 끝까지)의 표식을 지운다.
# 같은 RUN으로 다시 돌릴 때 옛 표식이 남아 실패한 단계를 통과한 것처럼 보이지 않게.
begin() { local g; rm -f "$W/ok-$1"
  for g in vars predump tmp suspended auth list db main acl verify; do
    case " $(deps $g) " in *" $1 "*) begin $g ;; esac; done; }
step() { begin "$1"; need $(deps "$1"); }
( set -euo pipefail; step run
  out=$(kubectl get cluster,job,pvc -A -l homelab.ukyi.app/restore=$RUN -o name)
  [ -z "$out" ]
  touch "$W/ok-run" )
[ -f "$W/ok-run" ] && echo "통과: run" || echo "멈춤: 실행 id가 겹치거나 조회에 실패했다. RUN을 다시 만든다"
```

**확인이 실패하면 멈춘다.** 확인 블록은 `( set -euo pipefail ... touch "$W/ok-<이름>" )` 한 줄 뒤에 `[ -f "$W/ok-<이름>" ]`로 판정하는 모양이다. 서브셸이라 블록 안의 명령 하나가 실패하면 그 블록만 끝나고(셸은 남는다), 마지막 줄의 표식이 생기지 않는다. 서브셸 뒤에 `&&`·`||`를 붙이거나 `if`의 조건으로 쓰지 않는다. bash와 zsh는 그 자리의 명령에 `set -e`를 적용하지 않아, 안에서 실패해도 다음 줄로 넘어간다(2a 시험에서 그렇게 DB가 지워지는 것을 봤다). 지우거나 되돌리기 어려운 단계(DB 삭제, 복원, 앱 재개)의 블록은 `need <앞 표식들>`로 시작해, 앞의 확인 하나라도 끝나지 않았으면 아무것도 하지 않는다. 블록 안 변수는 밖으로 나오지 않으므로 다음 블록이 쓸 값은 `$W`의 파일로 넘긴다. 블록은 `step <단계>`로 시작한다. 그 단계와 그 단계에 기대는 단계의 표식을 먼저 지우고(`begin`), 기대는 앞 단계의 표식을 확인한다(`need`). 무효화 범위는 `deps` 표의 의존 관계와 같다. 그래서 4-1·4-2를 3단계(앱 멈춤)보다 먼저 돌려도 3단계가 그 표식을 지우지 않고, 3단계를 다시 돌리면 그에 기대는 4-3 뒤만 다시 돌리면 된다(시나리오 10 실측: 단계 순서로 지우던 이전 모양은 4-3을 `auth` 없음으로 멈췄다). 같은 `RUN`으로 블록을 다시 돌리면 지워진 표식의 블록을 차례로 다시 돌린다.

**DB에서 읽은 이름은 믿지 않는다.** 확장·스키마 이름과 버전은 앱이 만든 값이다(앱 자격이 털렸으면 공격자가 고른 값). `postgres`로 실행하는 SQL에 문자열로 이어 붙이지 않는다. 정규식과 허용 목록으로 거른 뒤 psql 변수로 넘기고, 식별자는 `:"이름"`, 문자열은 `:'값'`으로 psql이 인용하게 한다. psql 변수는 `-c`에서는 치환되지 않아 SQL은 표준 입력으로 보낸다. 화면에 내보낼 때는 `cat -v`로 제어문자를 막는다.

### 0.2 확인은 라벨로

```bash
kubectl -n database get cluster,job,pvc -l homelab.ukyi.app/restore=$RUN       # PostgreSQL 복원 뒤 0개
kubectl -n app-$APP get job,pvc -l homelab.ukyi.app/restore=$RUN               # Valkey 복원·PostgreSQL 복원(앱 역할 Job) 뒤 0개
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

3. **복원 모드로 올림(PR):** `running: true`와 `restoreMode: true`를 함께. 새 파드가 `appendonly no`로 떠 RDB를 읽는다. 키 수와 표식 키를 본다.

   ```bash
   kubectl -n app-$APP rollout status deploy/$APP-valkey
   vk CONFIG GET appendonly          # no
   vk DBSIZE
   vk GET <표식 키>
   ```

4. **AOF 다시 켜기:** 실행 중에 켜면 지금 데이터로 AOF base를 새로 쓴다. rewrite가 끝날 때까지 기다린다.

   ```bash
   vk CONFIG SET appendonly yes
   vk INFO persistence | grep -E 'aof_enabled|aof_rewrite_in_progress|aof_last_bgrewrite_status'
   # aof_enabled:1, aof_rewrite_in_progress:0, aof_last_bgrewrite_status:ok가 될 때까지 다시 본다
   ```

5. **복원 모드 끄기(PR):** `restoreMode`와 `running` 줄을 지운다. ConfigMap만 바뀌고 파드는 그대로다(실행 중 설정은 이미 AOF on). 병합 뒤 서버를 한 번 다시 띄워 AOF에서 다시 읽히는지 본다. 키 수가 4번과 같아야 한다.

   다시 띄우기는 `rollout restart`(Deployment 업데이트)로 한다. 파드를 직접 지우지 않는다. `Recreate`가 "옛 파드가 모두 끝난 뒤 새 파드를 만든다"를 보장하는 것은 Deployment 업데이트 때뿐이다. 파드를 지우면 ReplicaSet이 옛 파드가 끝나기(Terminating) 전에 새 파드를 만들어, 두 서버가 같은 PVC의 AOF·RDB를 함께 쓴다(로컬 kind 1.37 실측: 직접 삭제는 약 14초 겹침, `rollout restart`는 겹침 없음). Argo CD는 `rollout restart`가 더하는 주석을 되돌리지 않는다(Git에 없는 필드라 비교하지 않는다, rotate.md와 같다).

   ```bash
   kubectl -n app-$APP rollout restart deploy/$APP-valkey
   kubectl -n app-$APP rollout status deploy/$APP-valkey
   vk CONFIG GET appendonly          # yes
   vk DBSIZE
   kubectl -n app-$APP get cronjob $APP-valkey-backup   # SUSPEND False
   ```

6. **정리:** 이 실행의 Job(수동 백업·복원의 모든 시도)을 라벨로 지우고 0.2의 확인이 0개인지 본다.

   ```bash
   kubectl -n app-$APP delete job -l homelab.ukyi.app/restore=$RUN
   kubectl -n app-$APP get job,pvc -l homelab.ukyi.app/restore=$RUN    # No resources
   ```

백업 Job의 ACL은 `default` 사용자(`~* &* +@all`)다. 사용자를 나누면 `--rdb`에는 `sync`·`replconf`가 필요하다(U18 실측: 없으면 `NOPERM ... 'sync'`).

## 2. 공유 PostgreSQL에서 한 앱의 DB만 복원 (설계 C.5.7, 시나리오 10)

CNPG 복원은 제자리가 아니라 항상 새 클러스터다. 그래서 임시 클러스터를 시각 T1로 PITR하고, 그 DB 하나만 덤프해 공유 Cluster `pg`에 다시 넣는다.

복원 객체 이름에는 앱 이름을 넣지 않는다(`pg-restore-<실행 id>`, `restore-<실행 id>-r2`·`-db`, `backup-<실행 id>-<시도 id>`, 1절의 `restore-vk`, 모두 35자 이하). CNPG는 인스턴스 이름 `<클러스터>-1`을 파드 hostname으로 쓰는데, 앱 이름(최대 53자)을 넣으면 63자를 넘어 임시 클러스터가 뜨지 않는다.

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
# 다음 줄이 vars.env에 따옴표 밖으로 들어가 use가 source할 때 셸 명령으로 돈다. 그래서 CR·LF를 먼저 거부한다.
fit() { case $1 in *$'\n'*|*$'\r'*) echo "줄바꿈이 든 값이다" >&2; return 1 ;; esac; printf '%s\n' "$1" | grep -qE "$2"; }
dump() { kubectl -n database exec "$TMP" -c postgres -- pg_dump -U postgres -Fc -d "$APP"; }   # 임시 클러스터의 그 DB
J() { kubectl -n app-$APP exec -i job/restore-$RUN-db -- "$@"; }                                 # 4-1의 앱 역할 복원 Job
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
# "if grep"으로 쓰면 2(읽기 오류)도 "없음"처럼 지나간다. 빈 값(확장 없음)은 통과.
extok() { local rc=0 re="^[a-z][a-z0-9_-]{0,62} [a-z_][a-z0-9_]{0,62} [A-Za-z0-9._-]{1,32} (postgres|$APP)\$"
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | grep -qvE "$re" || rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$1" | grep -nvE "$re" | cat -v >&2
    echo "이름·버전·소유자 모양이 이상한 확장 줄이 있다(위)" >&2; return 1; fi
  [ "$rc" -eq 1 ] || { echo "확장 목록을 검사하지 못했다(grep 종료 코드 $rc)" >&2; return 1; }; }
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
  kubectl -n database get backups      # T1 앞에 completed base backup이 있는지 눈으로 본다
  # 모든 확인이 끝난 뒤에만 파일을 바꾼다(실패하면 옛 값도 새 값도 남지 않게 먼저 지운다)
  rm -f "$W/vars.env"
  printf "T1='%s'\nSRV='%s'\nIMG='%s'\nSIZE='%s'\nBUCKET='%s'\nPRIMARY='%s'\n" "$T1" "$SRV" "$IMG" "$SIZE" "$BUCKET" "$PRIMARY" > "$W/vars.env.new"
  mv "$W/vars.env.new" "$W/vars.env"
  touch "$W/ok-vars" )
[ -f "$W/ok-vars" ] && echo "통과: vars" || echo "멈춤: 값이 비었거나 조회에 실패했다"
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
     kubectl -n database wait --for=condition=ready pod -l job-name=restore-$RUN-r2 --timeout=5m
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
       | kubectl -n database exec -i "$PRIMARY" -c postgres -- pg_restore -f /dev/null
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

   U26 확인(복원 시험의 임시 Cluster에서): 이 클러스터의 `spec.bootstrap`을 `initdb`로 바꾸는 patch가 webhook에 거부되지 않는지, 떠 있는 클러스터에 영향이 없는지 본다. 결과는 설계 부록 1 U26에 적는다.

   ```bash
   kubectl -n database patch cluster pg-restore-$RUN --type=merge \
     -p '{"spec":{"bootstrap":{"recovery":null,"initdb":{"database":"app","owner":"app"}}}}'
   kubectl -n database get cluster pg-restore-$RUN     # 계속 healthy, 파드 재시작 없음
   ```

3. **앱 멈춤(PR):** `apps/<앱>/values.yaml`에 `suspended: true`(앱 차트 1.1.0부터. replicas 0, 마이그레이션 Job 없음). 병합 뒤 파드가 없는지 본다.

   ```bash
   ( set -euo pipefail; step suspended
     # Deployment가 0으로 줄었고 실제로 0개다. 완료된(Succeeded) <앱>-migrate 파드는 남아 있어도 된다.
     # hook 삭제 정책이 BeforeHookCreation뿐이라 다음 hook 직전에만 지워지고, suspended면 새 hook도 없다.
     # 명령 치환은 독립 할당으로(실패면 set -e가 멈춘다) 받은 뒤 비교한다
     r=$(kubectl -n app-$APP get deploy $APP -o jsonpath='{.spec.replicas}')
     [ "$r" = 0 ]
     sr=$(kubectl -n app-$APP get deploy $APP -o jsonpath='{.status.replicas}')
     [ "$sr" = "" ] || [ "$sr" = 0 ]
     # 돌고 있거나 뜨려는 앱 파드(마이그레이션 포함)가 없다. Valkey 캐시 파드는 이 라벨이 없다.
     out=$(kubectl -n app-$APP get pods -l homelab.ukyi.app/app=$APP --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name)
     [ -z "$out" ]
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
     kubectl -n app-$APP wait --for=condition=ready pod -l job-name=restore-$RUN-db --timeout=5m
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
     dump | J pg_restore --list > "$W/list"
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
     if awk -v app="$APP" '$NF != app && $NF != "pg_database_owner" && $NF != "postgres"' "$W/acl-all.list" | cat -v | grep .; then
       echo "앱 역할·pg_database_owner·postgres 밖의 소유자가 있는 ACL 항목이 있다" >&2; exit 1; fi
     # 4-4·4-5가 쓸 SQL을 DB를 지우기 전에 만들어(실행하지 않는다) 본다. 지원하지 않는 모양이면 지금 멈춘다.
     # 본 복원 목록이 덤프와 맞는지
     J sh -c 'cat > /tmp/main.list' < "$W/main.list"
     dump | J pg_restore -L /tmp/main.list -f /dev/null
     # 앱 역할 ACL: 앱 역할로 실행한다. 다른 역할이 준 위임 권한이면 pg_restore가 SET SESSION AUTHORIZATION을 붙이는데
     # 앱 역할은 그것을 못 한다. 이 절차가 다루지 않는 모양이라 멈춘다.
     : > "$W/acl.sql"
     if [ -s "$W/acl.list" ]; then
       J sh -c 'cat > /tmp/acl.list' < "$W/acl.list"
       dump | J pg_restore -L /tmp/acl.list -f - > "$W/acl.sql"
     fi
     if grep -n 'SESSION AUTHORIZATION' "$W/acl.sql" | cat -v; then
       echo "앱 역할 ACL에 다른 역할로 바꿔 주는 문장이 있다(앱 역할로는 못 넣는다)" >&2; exit 1; fi
     # postgres 소유 ACL: 4-5는 여기서 만들고 검증한 이 파일만 넣는다.
     : > "$W/acl-su.sql"
     if [ -s "$W/acl-su.list" ]; then
       J sh -c 'cat > /tmp/acl-su.list' < "$W/acl-su.list"
       dump | J pg_restore -L /tmp/acl-su.list -f - > "$W/acl-su.sql"
     fi
     sqlok "$W/acl-su.sql" | cat -v || { echo "postgres로 넣을 ACL에 허용하지 않는 문장이 있다(위 줄)" >&2; exit 1; }
     touch "$W/ok-list" )
   [ -f "$W/ok-list" ] && echo "통과: list" || echo "멈춤: 목록이나 확장 조회에 실패했다(지금 DB는 그대로다)"
   [ -f "$W/ok-list" ] && { cat -v "$W/ext"; [ -s "$W/ext" ] || echo "확장 없음"; }
   ```

   **4-3. DB 다시 만들기.** 여기서 지금 DB를 지운다. 앞의 확인(되돌림 사본, 임시 클러스터, 앱 멈춤, 앱 역할 접속, 목록)이 하나라도 없으면 시작하지 않는다. 지우기 직전에 복원 Job이 살아 있고 앱 역할로 접속되는지 다시 본다. 표식(`ok-auth`)은 남아도 Job은 약 2시간(`sleep 7000`, `activeDeadlineSeconds: 7200`) 뒤 끝나므로, 4-1 뒤 오래 지났으면 지운 뒤에야 4-4에서 멈출 수 있다. 확장은 원본 소유자로 만든다. `postgres` 소유는 `postgres`가, 앱 역할 소유(trusted)는 앱 역할(복원 Job)이 만든다.

   ```bash
   ( set -euo pipefail; step db
     use
     # SQL은 표준 입력으로, 값은 psql 변수로(-c에서는 치환되지 않는다). :"x"는 식별자, :'x'는 문자열로 psql이 인용한다.
     q() { kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tA -v app="$APP" "$@"; }
     jobready
     # 확장 목록은 DROP 전에 한 번 읽고 뒤에서는 이 값만 쓴다. 파일이 없어지거나 못 읽으면 DROP 전에 멈춘다
     # (DROP 뒤에 파일을 다시 읽다 실패하지 않게). 4-2와 같은 모양 검사를 한 번 더 한다(그 사이 파일이 바뀌었을 때).
     ext=$(cat "$W/ext")
     extok "$ext"
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
     J sh -c 'cat > /tmp/main.list' < "$W/main.list"
     dump | J sh -c 'pg_restore -L /tmp/main.list --no-owner --no-privileges --exit-on-error -d "$PGDATABASE"'
     touch "$W/ok-main" )
   [ -f "$W/ok-main" ] && echo "본 복원됨" || echo "멈춤: 본 복원에 실패했다(되돌림 사본은 1단계)"
   ```

   **4-5. ACL 복원과 대조.** `--no-privileges`만으로 끝내면 원본의 `REVOKE ... FROM PUBLIC`이 사라져, 새 함수는 PostgreSQL 기본값(PUBLIC 실행 가능)으로 돌아간다. 공유 클러스터라 다른 앱 역할이 원래 못 부르던 함수(특히 `SECURITY DEFINER`)를 부를 수 있게 된다. 그래서 ACL 항목(`ACL`, `DEFAULT ACL`)을 따로 넣는다.

   - **앱 역할 소유 객체:** 앱 역할로 넣는다. GRANT·REVOKE는 객체 소유자만 할 수 있어 앱 역할로는 자기 객체 권한만 바뀐다.
   - **`postgres` 소유 객체(확장에 딸린 객체):** 앱 역할은 바꿀 수 없다(원본에서 운영자가 바꾼 권한이 여기 온다). 덤프에서 SQL 텍스트만 만들고(`pg_restore -f -`, 실행하지 않는다), 모든 줄이 `GRANT`·`REVOKE`와 pg_restore가 붙이는 고정 머리(`SET`, `search_path` 비우기, `\restrict`)뿐인지 본 뒤에만 `postgres`로 넣는다. GRANT·REVOKE는 사용자 코드를 실행하지 않으므로 슈퍼유저 문맥에서 덤프를 실행하는 문제(위 "복원은 앱 역할로 한다")가 생기지 않는다. 다른 문장이 섞이면 넣지 않고 멈춘다.

   그다음 임시 클러스터(원본)와 복원본의 ACL(확장에 딸린 객체 포함)이 같은지 본다. 두 조회는 각각 성공과 결과가 비어 있지 않음을 확인한 뒤 비교한다(조회가 둘 다 실패해 빈 출력끼리 비교하면 "같음"이 된다). 결과에는 늘 `public` 스키마 줄이 있어 비지 않는다.

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
     if [ -s "$W/acl.list" ]; then
       J sh -c 'cat > /tmp/acl.list' < "$W/acl.list"
       dump | J sh -c 'pg_restore -L /tmp/acl.list --no-owner --exit-on-error -d "$PGDATABASE"'
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

5. **캐시 비우기와 앱 재개(PR):** `ok-verify`가 없으면 재개 PR을 올리지 않는다. 앱이 캐시 Valkey(`cache.enabled`)를 쓰면 재개 전에 캐시 파드를 지운다. 캐시는 `emptyDir`이라 새 파드는 빈 상태로 뜬다. 지우지 않으면 T1 뒤의 값(되돌린 DB에 없는 행)을 계속 돌려준다.

   ```bash
   ( set -euo pipefail; need verify
     # 캐시를 쓸 때만
     kubectl -n app-$APP delete pod -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$APP
     kubectl -n app-$APP rollout status deploy/$APP-valkey )
   ```

   그다음 PR로 `suspended` 줄을 지운다. 마이그레이션 Job이 다시 돌고 앱이 뜬다.

6. **정리:** 임시 Cluster, 그 PVC, 도우미 Job 둘을 지우고 0개를 본다.

   ```bash
   kubectl -n database delete cluster pg-restore-$RUN
   kubectl -n database delete job restore-$RUN-r2
   kubectl -n app-$APP delete job restore-$RUN-db
   kubectl -n database delete pvc -l homelab.ukyi.app/restore=$RUN
   kubectl -n database get cluster,job,pvc -l homelab.ukyi.app/restore=$RUN    # No resources
   kubectl -n app-$APP get job -l homelab.ukyi.app/restore=$RUN                 # No resources
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

**복구 PR을 root apply보다 먼저 병합한다.** Git이 평상시 값(`initdb`)인 채 root를 apply하면 Argo CD가 빈 Cluster `pg`를 먼저 만들고, bootstrap은 초기화 때만 읽혀 나중에 Git을 고쳐도 떠 있는 클러스터는 바뀌지 않는다. Cluster에는 보호 주석이 있어 Argo CD가 지우지도 않는다.

1. **복구 PR:** `platform/root/values-prod.yaml`의 `cluster.cnpg`에서
   - `recoverySource.serverName`에 지금 Git의 `serverName`을 옮겨 적고,
   - `serverName`을 새 세대 `pg-<복구일 YYYYMMDD>`로 바꾼다.
   - 영속 Valkey가 있는 앱마다 `data/<앱>/values.yaml`에 `valkey.running: false`, `apps/<앱>/values.yaml`에 `suspended: true`(앱 차트 1.1.0 이상)를 같은 PR에 넣는다. root apply가 ApplicationSet을 바로 동기화하므로, 넣지 않으면 빈 PVC 위의 Valkey와 앱이 먼저 떠 빈 큐로 돌거나 새로 쓴 데이터가 RDB 복원에서 사라진다.

   렌더 결과는 `bootstrap.recovery` + 원본 전용 ObjectStore `r2-source`(옛 serverName) + 아카이브 plugin(새 serverName)이다. 새 serverName을 빠뜨리면 렌더가 실패한다(같은 prefix에 두 세대가 섞이면 되돌릴 수 없다). `cnpg.io/skipEmptyWalArchiveCheck` 주석은 쓰지 않는다.

2. **분기: 실제 빈 NUC 복구 / VM 시험(시나리오 13)**
   - 실제 빈 NUC 복구: Tailscale 콘솔에서 잃은 클러스터의 operator·프록시 기기(`tag:k8s-operator`, `tag:k8s`)를 지운다. OS를 다시 깔았으면 `tailscale up` 전에 옛 NUC 호스트 기기도 지운다(남아 있으면 새 이름에 `-1`이 붙고 되돌아가지 않는다).
   - VM 시험: 이 단계를 건너뛴다. 그 기기들은 살아 있는 운영 클러스터의 것이다. 시험 뒤 `vm-*` 기기만 지운다.
3. [bootstrap.md](bootstrap.md) 순서로 host → k3s → Argo CD → ESO 부트스트랩 Secret → root apply.
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

5. 영속 Valkey가 있는 앱은 1절로 RDB를 복원한다. 1단계(`running: false`)는 복구 PR이 이미 했으므로 2단계(복원 Job)부터 한다. 1절 5단계까지 끝나 키 수를 확인한 뒤에 그 앱의 `suspended` 줄을 지우는 PR로 앱을 재개한다.
6. 앱이 뜬 뒤 시나리오 1·10을 확인한다.
7. **정리 PR:** `recoverySource`를 지워 렌더 결과를 `initdb`로 되돌린다(새 serverName은 그대로). recovery를 남기면 나중에 볼륨을 잃고 Cluster를 다시 만들 때 옛 아카이브에서 낡은 데이터로 조용히 복구된다. 떠 있는 클러스터에는 영향이 없다(U26).
