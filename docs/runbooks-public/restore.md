# 복원: 영속 Valkey, 한 앱의 DB, 빈 NUC

데이터를 되돌리는 순서다. 근거는 설계 [C.5.6](../plans/2026-10-17-homelab-rebuild/platform/design.md)(Valkey), C.5.7(공유 PostgreSQL에서 한 앱만 복원), C.6.4(최초 연결과 재해 복구)다. CLI(`homelab db restore` 등, T12)가 생기기 전에는 사람이 이 문서를 따른다.

- 값은 출력하지 않는다. 비밀번호는 명령행 인자에 넣지 않고 표준 입력으로만 넘긴다(아래 0.3).
- 외부 변경(병합, 삭제)은 [approvals.md](../plans/2026-10-17-homelab-rebuild/approvals.md)에 줄로 남긴다.
- 실행하다 이 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 공통 규칙

### 0.1 복원 리소스는 GitOps 밖이다

복원 Job, 임시 Cluster `pg-restore-*`, 도우미 Job은 Git에 두지 않는다. 사람이 `kubectl`로 만드는 일회성 객체라 Argo CD가 되돌리지도 치우지도 않는다(설계 C.5.7).

- 이름은 실행마다 고유하게(아래 `RUN`), 라벨은 `homelab.ukyi.app/restore=<실행 id>`. 어느 앱의 복원인지는 실행 id와 함께 작업 기록에 남긴다.
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
kubectl get cluster,job,pvc -A -l homelab.ukyi.app/restore=$RUN    # No resources여야 한다
```

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
   kubectl -n app-$APP create job --from=cronjob/$APP-valkey-backup manual-$RUN
   kubectl -n app-$APP wait --for=condition=complete job/manual-$RUN --timeout=10m
   kubectl -n app-$APP logs job/manual-$RUN -c upload       # "올림: r2:<버킷>/valkey/<앱>/dump-....rdb"
   kubectl -n app-$APP delete job manual-$RUN
   ```

1. **서버 내림(PR):** `data/<앱>/values.yaml`의 `valkey`에 `running: false`. 병합 뒤 Deployment `<앱>-valkey`가 없고 PVC `valkey-data`는 남는지, 백업 CronJob이 `SUSPEND True`인지 본다. 앱은 Valkey 오류를 내지만 계속 돈다.

   ```bash
   kubectl -n app-$APP get deploy,pvc,cronjob
   ```

2. **복원 Job:** PVC에 RDB를 `dump.rdb`로 두고 `appendonlydir`을 지운다. `OBJECT=latest`면 가장 최근 것이다(이름이 UTC 시각이라 정렬이 시각순). 특정 시점이면 파일 이름을 적는다. 서버가 uid 1000으로 쓴 파일을 지워야 해서 같은 uid로 돈다(local-retain hostPath PV에는 fsGroup이 적용되지 않는다).

   ```bash
   OBJECT=latest
   BUCKET=$(kubectl -n app-$APP get cronjob $APP-valkey-backup \
     -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="BUCKET")].value}')
   kubectl create -f - <<EOF
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: restore-$RUN-vk
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
   kubectl -n app-$APP wait --for=condition=complete job/restore-$RUN-vk --timeout=15m
   kubectl -n app-$APP logs job/restore-$RUN-vk          # 받은 객체와 /data의 dump.rdb, appendonlydir 없음
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

5. **복원 모드 끄기(PR):** `restoreMode`와 `running` 줄을 지운다. ConfigMap만 바뀌고 파드는 그대로다(실행 중 설정은 이미 AOF on). 병합 뒤 파드를 한 번 지워 AOF에서 다시 읽히는지 본다. 키 수가 4번과 같아야 한다.

   ```bash
   kubectl -n app-$APP delete pod -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$APP
   kubectl -n app-$APP rollout status deploy/$APP-valkey
   vk CONFIG GET appendonly          # yes
   vk DBSIZE
   kubectl -n app-$APP get cronjob $APP-valkey-backup   # SUSPEND False
   ```

6. **정리:** `kubectl -n app-$APP delete job restore-$RUN-vk` 뒤 0.2의 확인이 0개.

백업 Job의 ACL은 `default` 사용자(`~* &* +@all`)다. 사용자를 나누면 `--rdb`에는 `sync`·`replconf`가 필요하다(U18 실측: 없으면 `NOPERM ... 'sync'`).

## 2. 공유 PostgreSQL에서 한 앱의 DB만 복원 (설계 C.5.7, 시나리오 10)

CNPG 복원은 제자리가 아니라 항상 새 클러스터다. 그래서 임시 클러스터를 시각 T1로 PITR하고, 그 DB 하나만 덤프해 공유 Cluster `pg`에 다시 넣는다.

복원 객체 이름에는 앱 이름을 넣지 않는다(`pg-restore-<실행 id>`, `restore-<실행 id>-r2`·`-db`·`-vk`, 모두 33자 이하). CNPG는 인스턴스 이름 `<클러스터>-1`을 파드 hostname으로 쓰는데, 앱 이름(최대 53자)을 넣으면 63자를 넘어 임시 클러스터가 뜨지 않는다.

**복원은 앱 역할로 한다.** 덤프는 앱이 만든 객체다. 앱 owner 자격이 털린 뒤라면 함수·CHECK 제약 같은 객체에 코드를 심어 둘 수 있고, 슈퍼유저(`postgres`)로 `pg_restore`하면 그 코드가 슈퍼유저 문맥에서 돌아 앱 역할을 승격하고 다른 앱 DB에 닿는다(2a의 로컬 시험에서 재현). 그래서 덤프는 앱 ns의 Job이 앱 연결 Secret(`<앱>-db`)으로 접속해 `--no-owner --no-privileges`로 넣고, 권한(ACL)만 같은 앱 역할로 따로 넣은 뒤 원본과 대조한다(4단계). 앱을 멈추는 것만으로는 저장된 코드를 막지 못한다.

Secret·ObjectStore 이름은 `platform/cnpg/cluster`를 따른다(R2 자격 Secret `r2-backup`, 키 `ACCESS_KEY_ID`·`SECRET_ACCESS_KEY`·`ENDPOINT_URL`, ObjectStore `r2`). 바뀌면 이 절을 함께 고친다.

`database` ns는 PSA restricted다. 아래 도우미 Job처럼 `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`가 없으면 파드가 거부된다. region은 rclone이 자기 설정(`RCLONE_CONFIG_R2_REGION`)으로 읽는다. CNPG plugin(boto3)이 `AWS_DEFAULT_REGION`만 읽는 것과 다르다.

```bash
T1='2026-11-02 10:00:00+09'   # 되돌릴 시각. 마지막 base backup과 WAL 아카이브 범위 안이어야 한다
SRV=$(kubectl -n database get cluster pg -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}')
IMG=$(kubectl -n database get cluster pg -o jsonpath='{.spec.imageName}')
SIZE=$(kubectl -n database get cluster pg -o jsonpath='{.spec.storage.size}')
BUCKET=$(kubectl -n database get objectstore r2 -o jsonpath='{.spec.configuration.destinationPath}' | sed -E 's#^s3://([^/]+)/.*#\1#')
PRIMARY=$(kubectl -n database get cluster pg -o jsonpath='{.status.currentPrimary}')
kubectl -n database get backups      # T1 앞에 completed base backup이 있는지
```

1. **되돌림용 덤프:** 지금 DB를 R2 `pgdump/<앱>/pre-restore-<실행 id>.dump`에 남긴다. 덤프는 파드 안 `postgres` 로컬 접속으로 하고 도우미 Job(rclone)으로 바로 올린다. 사람 기기에 데이터가 남지 않고, `database` ns의 5432 기본 거부(앱 ns만 허용)도 건드리지 않는다. 이 prefix에는 lifecycle이 없어 복원을 확인한 뒤 손으로 지운다.

   ```bash
   kubectl create -f - <<EOF
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
   EOF
   kubectl -n database wait --for=condition=ready pod -l job-name=restore-$RUN-r2 --timeout=5m
   KEY="r2:$BUCKET/pgdump/$APP/pre-restore-$RUN.dump"
   kubectl -n database exec $PRIMARY -c postgres -- pg_dump -U postgres -Fc -d "$APP" \
     | kubectl -n database exec -i job/restore-$RUN-r2 -- rclone rcat "$KEY" \
     && echo "덤프 올림"                                                            # 0.1의 pipefail로 pg_dump 실패도 여기서 멈춘다
   # 올린 사본을 끝까지 읽어 본다. 목록(--list)만 보면 앞에 있는 목차만 읽어 잘린 사본도 통과한다.
   kubectl -n database exec job/restore-$RUN-r2 -- rclone cat "$KEY" \
     | kubectl -n database exec -i $PRIMARY -c postgres -- pg_restore -f /dev/null \
     && echo "되돌림 사본 확인"
   ```

   **"되돌림 사본 확인"이 나오지 않으면 여기서 멈춘다.** 4단계가 지금 DB를 지운다.

2. **임시 클러스터:** `bootstrap.recovery`로 T1까지 되감는다. WAL 아카이버 plugin을 붙이지 않는다(운영 prefix에 쓰지 않게, 설계 B.8 E6). PVC는 `local-path`(Delete)라 PVC를 지우면 노드의 폴더도 지워진다. `inheritedMetadata`가 실행 id 라벨을 PVC·파드에 물려준다.

   ```bash
   kubectl create -f - <<EOF
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
   EOF
   kubectl -n database wait --for=condition=Ready cluster/pg-restore-$RUN --timeout=30m
   TMP=$(kubectl -n database get cluster pg-restore-$RUN -o jsonpath='{.status.currentPrimary}')
   kubectl -n database exec $TMP -c postgres -- psql -U postgres -d "$APP" -tAc 'select count(*) from <표식 테이블>'
   ```

   U26 확인(복원 시험의 임시 Cluster에서): 이 클러스터의 `spec.bootstrap`을 `initdb`로 바꾸는 patch가 webhook에 거부되지 않는지, 떠 있는 클러스터에 영향이 없는지 본다. 결과는 설계 부록 1 U26에 적는다.

   ```bash
   kubectl -n database patch cluster pg-restore-$RUN --type=merge \
     -p '{"spec":{"bootstrap":{"recovery":null,"initdb":{"database":"app","owner":"app"}}}}'
   kubectl -n database get cluster pg-restore-$RUN     # 계속 healthy, 파드 재시작 없음
   ```

3. **앱 멈춤(PR):** `apps/<앱>/values.yaml`에 `suspended: true`(앱 차트 1.1.0부터. replicas 0, 마이그레이션 Job 없음). 병합 뒤 파드가 없는지 본다.

   ```bash
   kubectl -n app-$APP get pods -l homelab.ukyi.app/app=$APP     # No resources
   ```

4. **덤프·복원:** 빈 DB에 넣는다. `--clean`만 쓰면 덤프에 있는 객체만 지워 T1 뒤에 만든 스키마·테이블이 남는다. 그래서 DB를 지우고 다시 만든다. DB DROP·CREATE와 확장 만들기만 `postgres`가 하고(덤프 내용을 실행하지 않는다), 덤프를 넣는 것은 앱 역할이 두 번에 나눠 한다: 본 복원(`--no-privileges`)과 ACL 복원. 아래 절차는 2a의 로컬 시험으로 그대로 돌려 봤다.

   **4-1. 앱 ns 복원 Job.** 이미지는 클러스터와 같은 PostgreSQL 이미지다(`pg_restore` major = 서버 major, uid 26). 앱 차트의 NetworkPolicy가 이 ns에서 `pg` 5432를 열어 둔다(`uses.postgres`). 시작 스크립트가 `DATABASE_URL`에서 비밀번호를 꺼내 메모리 emptyDir의 pgpass로 두고, 이후 `pg_restore`는 libpq 환경변수(`PGHOST`·`PGUSER`·`PGDATABASE`·`PGPASSFILE`)로 접속한다. 비밀번호가 명령행 인자(`-d <URL>`)에 들어가지 않는다. 셸 내장만 써서 꺼내 파생 프로세스의 argv에도 없다(로컬 실측 0건).

   ```bash
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
                 pw=$(printf '%b' "${enc//%/\\x}")
                 pw=${pw//\\/\\\\}; pw=${pw//:/\\:}
                 printf '%s:%s:%s:%s:%s\n' "$PGHOST" "$PGPORT" "$PGDATABASE" "$PGUSER" "$pw" > "$PGPASSFILE"
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
   J() { kubectl -n app-$APP exec -i job/restore-$RUN-db -- "$@"; }
   dump() { kubectl -n database exec $TMP -c postgres -- pg_dump -U postgres -Fc -d "$APP"; }
   ```

   **4-2. 목록과 확장.** 목록을 못 만들면(임시 클러스터 접근·덤프 실패) 여기서 멈춘다. "확장 없음"은 목록 안에서 못 찾았을 때만이다. 덤프 실패를 "없음"으로 바꾸지 않는다.

   ```bash
   if ! LIST=$(dump | J pg_restore --list); then echo "목록 실패: 여기서 멈춘다(지금 DB는 그대로다)"; fi
   EXT=$(printf '%s\n' "$LIST" | awk '$4=="EXTENSION" && $5=="-" {print $6}')
   echo "확장: ${EXT:-없음}"
   printf '%s\n' "$LIST" | grep -cE '^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) '     # ACL 항목 수(4-5에서 쓴다)
   ```

   **4-3. DB 다시 만들기(`postgres`).**

   ```bash
   kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
     -c "DROP DATABASE \"$APP\" WITH (FORCE)"
   # CNPG Database 리소스가 먼저 다시 만들 수 있다. 있으면 owner만 보고, 없으면 만든다.
   kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -tAc \
     "select pg_get_userbyid(datdba) from pg_database where datname='$APP'"
   kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
     -c "CREATE DATABASE \"$APP\" OWNER \"$APP\""          # 위가 비었을 때만
   # 확장은 앱 역할이 만들 수 없다. 이름으로만 만들고 덤프의 SQL은 실행하지 않는다
   printf '%s\n' "$EXT" | while IFS= read -r e; do
     [ -n "$e" ] || continue
     kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION \"$e\""
   done
   ```

   **4-4. 본 복원(앱 역할).** 4-3에서 만든 확장의 `EXTENSION`과 `COMMENT - EXTENSION` 항목은 목록에서 뺀다. 남기면 앱 역할이 `postgres` 소유 확장에 주석을 달다 `must be owner of extension`으로 멈춘다(로컬 실측). `--no-owner`는 모든 객체를 앱 역할 소유로, `--no-privileges`는 GRANT·REVOKE를 건너뛴다. 덤프는 원래 순서 그대로 읽으므로 표준 입력과 `-L`을 함께 쓸 수 있다.

   ```bash
   printf '%s\n' "$LIST" | sed -E 's/^([0-9]+; [0-9]+ [0-9]+ (EXTENSION|COMMENT - EXTENSION) )/;\1/' | J sh -c 'cat > /tmp/main.list'
   printf '%s\n' "$LIST" | grep -E '^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) ' | J sh -c 'cat > /tmp/acl.list'
   dump | J sh -c 'pg_restore -L /tmp/main.list --no-owner --no-privileges --exit-on-error -d "$PGDATABASE"' && echo "본 복원됨"
   ```

   **4-5. ACL 복원(앱 역할)과 대조.** `--no-privileges`만으로 끝내면 원본의 `REVOKE ... FROM PUBLIC`이 사라져, 새 함수는 PostgreSQL 기본값(PUBLIC 실행 가능)으로 돌아간다. 공유 클러스터라 다른 앱 역할이 원래 못 부르던 함수(특히 `SECURITY DEFINER`)를 부를 수 있게 된다. 그래서 ACL 항목(`ACL`, `DEFAULT ACL`)만 앱 역할로 따로 넣는다. GRANT·REVOKE는 객체 소유자만 할 수 있어 앱 역할로는 자기 DB의 자기 객체 권한만 바뀐다. 슈퍼유저 문맥에서 덤프를 실행하는 문제(위 "복원은 앱 역할로 한다")가 생기지 않는다. 그다음 임시 클러스터(원본)와 복원본의 ACL이 같은지 본다.

   ```bash
   dump | J sh -c 'pg_restore -L /tmp/acl.list --no-owner --exit-on-error -d "$PGDATABASE"' && echo "ACL 복원됨"
   ACL_SQL=$(cat <<'SQL'
   select kind, name, coalesce(acl, '-') from (
     select 'function' kind, p.oid::regprocedure::text name, p.proacl::text acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname not in ('pg_catalog', 'information_schema') and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
     union all
     select 'relation', c.oid::regclass::text, c.relacl::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%' and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
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
   acl() { printf '%s\n' "$ACL_SQL" | kubectl -n database exec -i "$1" -c postgres -- psql -U postgres -d "$APP" -v ON_ERROR_STOP=1 -qAt; }
   diff <(acl $TMP) <(acl $PRIMARY) && echo "ACL 원본과 같음"
   ```

   다르면 앱을 재개하지 않는다. 차이 줄(`kind|이름|ACL`)을 보고 원본 ACL대로 앱 역할로 GRANT·REVOKE한 뒤 다시 대조한다.

   **4-6. 확인.**

   ```bash
   kubectl -n database get database $APP -o jsonpath='{.status.applied}{"\n"}'   # true(재조정이 다시 만든 DB를 건드리지 않음)
   # 앱 역할이 승격되지 않았는지. 모두 f여야 한다
   kubectl -n database exec $PRIMARY -c postgres -- psql -U postgres -tAc \
     "select rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls from pg_roles where rolname='$APP'"
   ```

   객체 소유자는 모두 앱 역할이다(4-3에서 만든 확장만 `postgres`). 덤프에 다른 역할 소유의 객체가 있었다면 그 소유는 돌아오지 않는다(앱 역할 하나가 DB owner라 보통 없다).

5. **캐시 비우기와 앱 재개(PR):** 앱이 캐시 Valkey(`cache.enabled`)를 쓰면 재개 전에 캐시 파드를 지운다. 캐시는 `emptyDir`이라 새 파드는 빈 상태로 뜬다. 지우지 않으면 T1 뒤의 값(되돌린 DB에 없는 행)을 계속 돌려준다.

   ```bash
   kubectl -n app-$APP delete pod -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$APP   # 캐시를 쓸 때만
   kubectl -n app-$APP rollout status deploy/$APP-valkey
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

같은 날 4단계(4-1의 시작 스크립트, 4-2~4-6의 명령 그대로)도 로컬에서 돌렸다. 원본·대상 PostgreSQL 18 둘, 복원 Job 대신 CNPG 이미지 컨테이너(uid 26, 읽기 전용 루트), zsh, `kubectl exec`는 `podman exec` 대역이다. 원본에는 위 악성 CHECK, untrusted 확장(`postgres_fdw`, `postgres` 소유), `REVOKE EXECUTE ... FROM PUBLIC`(전역 기본 권한), 다른 역할 GRANT, 특수문자 비밀번호(`@ : / + 공백 % \`)를 넣었다. 결과: argv의 비밀번호 0건, 덤프 실패 때 목록 단계에서 멈춤, 본 복원 직후에는 ACL이 기본값(PUBLIC 실행 가능)으로 넓어졌다가 ACL 복원 뒤 원본과 같음, 원래 권한 없는 역할의 함수 실행 거부, `rolsuper` 등 모두 f. `COMMENT - EXTENSION`을 목록에 남기면 `must be owner of extension`으로 멈췄다.

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
