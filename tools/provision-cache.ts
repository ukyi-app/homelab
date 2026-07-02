// create-cache 프로비저너 — 앱별 경량 Valkey 인스턴스(cache NS)와 prod 소비용 conn
// SealedSecret 핸들을 산출한다 (_create-cache.yaml이 호출; --dry-run은 계획 JSON만 출력).
//
// 산출물:
//   platform/cache/prod/<name>/                     Deployment·Service·PVC·ConfigMap·ACL SealedSecret
//   platform/cache/prod/kustomization.yaml          인스턴스 디렉토리 멱등 등록(없으면 최초 생성)
//   platform/data-conn/prod/cache-<name>-conn.sealed.yaml      <NAME>_REDIS_URL (default user)
//   platform/data-conn/prod/cache-<name>-ro-conn.sealed.yaml   <NAME>_REDIS_RO_URL (+@read 전용)
//   docs/memory-ledger.md                           cache-<name> 행 + 합계 프로즈 (예산 초과 시 거부)
//
// 비밀번호는 crypto로 생성해 kubeseal stdin으로만 흐른다 — stdout/플랜/디스크에 평문 금지.
// data-conn kustomization은 다른 작업자(Task 5.1) 소유 — 있으면 resources만 추가, 없으면
// 생성하지 않고 plan JSON checklist에 기재한다.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { randomBytes, createHash } from "node:crypto";
import { parseDocument } from "yaml";
import { analyzeLedger, appendRowWithTotals, budgetViolation, type LedgerAgg } from "./lib/ledger-budget.ts";
import { resourceNameError } from "./lib/identity.ts";
import { sealManifest } from "./lib/seal.ts";
import { addResource } from "./lib/kustomization.ts";
import { parseFlags } from "./lib/cli.ts";

// 버전 핀 — latest 금지. backup-cronjob.yaml의 snapshot 컨테이너와 같은 태그를 유지한다.
const VALKEY_IMAGE = "valkey/valkey:9.1.0-alpine";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed(arg()가 미지정 플래그를 조용히 무시하던 것 차단). 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--name", "--repo-root", "--cert", "--maxmemory-mi"], bool: ["--dry-run"] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --dry-run --name --repo-root --cert --maxmemory-mi`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const name = arg("--name");
const ROOT = arg("--repo-root", ".");
const CERT = arg("--cert", `${ROOT}/tools/sealed-secrets-cert.pem`)!;
const rawMaxmemory = arg("--maxmemory-mi", "64")!;
const maxmemoryMi = Number(rawMaxmemory);

function fail(msg: string): never { console.error(`::error::provision-cache: ${msg}`); process.exit(1); }
if (!name) {
  console.error("usage: provision-cache --name <cache> [--maxmemory-mi 16..1024] [--repo-root <dir>] [--cert <pem>] [--dry-run]");
  process.exit(2);
}
// 형식 + '-ro' 접미사를 공유 정책으로 단일 검사(디스패처 validate-mutation과 동일)
const nameErr = resourceNameError("cache", name);
if (nameErr) fail(nameErr);
if (!/^\d+$/.test(rawMaxmemory) || !Number.isInteger(maxmemoryMi) || maxmemoryMi < 16 || maxmemoryMi > 1024)
  fail(`maxmemory-mi는 16..1024 정수여야 한다: '${rawMaxmemory}'`);

// ---------- 사이징 ----------
// limit는 maxmemory보다 여유를 둔다: BGSAVE fork COW + allocator 단편화 + 클라이언트 버퍼.
const reqMi = maxmemoryMi + 32;
const limitMi = Math.ceil(maxmemoryMi * 1.5) + 64;

// ---------- 중복/예산 검증 (쓰기 전 전부) ----------
const instDir = `${ROOT}/platform/cache/prod/${name}`;
if (existsSync(instDir)) fail(`platform/cache/prod/${name} 이미 존재`);
const connPath = `${ROOT}/platform/data-conn/prod/cache-${name}-conn.sealed.yaml`;
const roConnPath = `${ROOT}/platform/data-conn/prod/cache-${name}-ro-conn.sealed.yaml`;
if (existsSync(connPath) || existsSync(roConnPath)) fail(`data-conn에 cache-${name} conn sealed가 이미 존재`);

const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
if (!existsSync(ledgerPath)) fail(`메모리 원장 없음: ${ledgerPath}`);
const ledger = readFileSync(ledgerPath, "utf8");
const component = `cache-${name}`;
let agg: LedgerAgg;
try { agg = analyzeLedger(ledger); } catch (e) { fail(e instanceof Error ? e.message : String(e)); }
const viol = budgetViolation(agg, component, limitMi, "maxmemory를 줄여라");
if (viol) fail(viol);
const { sumReq, sumLimit, budget } = agg;

// ---------- 자격 생성 (비출력 — kubeseal stdin 전용) ----------
const NAME = name.replaceAll("-", "_").toUpperCase();
const pw = randomBytes(24).toString("base64url");
const pwRo = randomBytes(24).toString("base64url");
const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
// users.acl에는 sha256 해시(#...)만 — 평문은 conn URL과 VALKEY_PASSWORD(백업 잡 인증용) 키로만.
const usersAcl = [
  `user default on #${sha256(pw)} ~* &* +@all`,
  `user ro on #${sha256(pwRo)} ~* &* +@read -@write -@dangerous`,
  "",
].join("\n");

// ---------- 인스턴스 manifest ----------
const labels = (indent: string) => [
  `${indent}app.kubernetes.io/name: ${name}`,
  `${indent}app.kubernetes.io/component: valkey`,
  `${indent}app.kubernetes.io/part-of: cache`,
].join("\n");

const deploymentYaml = `# ${name} — 앱별 경량 Valkey 인스턴스 (provision-cache.ts 산출 — 수정은 의도적 커밋으로만).
# limit(${limitMi}Mi)는 maxmemory(${maxmemoryMi}Mi)에 BGSAVE fork COW·단편화·클라이언트 버퍼 여유를 더한 값.
# namespace는 상위 kustomization(namespace: cache)이 부여한다.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
${labels("    ")}
spec:
  replicas: 1
  strategy:
    type: Recreate # RWO PVC — RollingUpdate면 신구 파드가 같은 볼륨을 두고 교착
  selector:
    matchLabels:
      app.kubernetes.io/name: ${name}
  template:
    metadata:
      labels:
${labels("        ")}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999 # valkey 이미지의 기본 user(valkey)
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: valkey
          image: ${VALKEY_IMAGE}
          command: ["valkey-server", "/etc/valkey/valkey.conf"]
          ports:
            - { name: redis, containerPort: 6379 }
          resources:
            requests: { cpu: 50m, memory: ${reqMi}Mi }
            limits: { cpu: 250m, memory: ${limitMi}Mi }
          securityContext:
            allowPrivilegeEscalation: false # valkey는 setcap 바이너리가 아니라 양립 가능 (AdGuard와 다름)
            readOnlyRootFilesystem: true # 쓰기는 /data(PVC)뿐
            capabilities: { drop: [ALL] }
          # ACL 인증이 걸려 있어 exec PING 대신 tcpSocket — NOAUTH와 무관하게 기동/생존만 본다
          livenessProbe:
            tcpSocket: { port: 6379 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 6379 }
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - { name: config, mountPath: /etc/valkey, readOnly: true }
            - { name: acl, mountPath: /etc/valkey-acl, readOnly: true }
            - { name: data, mountPath: /data }
      volumes:
        - name: config
          configMap: { name: ${name}-config }
        - name: acl
          secret:
            secretName: ${name}-acl
            items: [{ key: users.acl, path: users.acl }] # VALKEY_PASSWORD 키는 마운트하지 않는다
        - name: data
          persistentVolumeClaim: { claimName: ${name}-data }
`;

const configmapYaml = `# ${name} valkey.conf — 비밀 없음(ACL은 SealedSecret ${name}-acl의 users.acl).
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}-config
  labels:
${labels("    ")}
data:
  valkey.conf: |
    bind 0.0.0.0
    port 6379
    # 캐시 시맨틱: maxmemory 도달 시 LRU 퇴출
    maxmemory ${maxmemoryMi}mb
    maxmemory-policy allkeys-lru
    # 백업 체인: AOF off, RDB 스냅샷만 (cache-backup CronJob이 BGSAVE 후 R2 업로드)
    appendonly no
    save 900 1
    save 300 100
    dir /data
    # ACL: default(전체 권한) + ro(+@read -@write -@dangerous)
    aclfile /etc/valkey-acl/users.acl
`;

const serviceYaml = `# DNS: ${name}.cache.svc(.cluster.local):6379 — conn 핸들의 host와 일치.
# component=valkey 라벨은 cache-backup CronJob의 인스턴스 디스커버리 셀렉터.
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  labels:
${labels("    ")}
spec:
  selector:
    app.kubernetes.io/name: ${name}
  ports:
    - { name: redis, port: 6379, targetPort: 6379 }
`;

const pvcYaml = `# RDB 스냅샷(dump.rdb) 저장 — 기본 1Gi (maxmemory ≤ 1Gi 전제).
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}-data
  labels:
${labels("    ")}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: { storage: 1Gi }
`;

const instKustomization = `apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - acl.sealed.yaml
`;

// ---------- kubeseal (평문은 stdin으로만 — 봉인 SSOT = lib/seal.ts) ----------
function seal(manifest: object) {
  try { return sealManifest(manifest, CERT); }
  catch (e) { fail(e instanceof Error ? e.message : String(e)); } // strict catch(F11)·기존 exit 코드 보존
}
const secret = (ns: string, secretName: string, stringData: any) => ({
  apiVersion: "v1", kind: "Secret",
  metadata: { name: secretName, namespace: ns },
  type: "Opaque", stringData,
});

// ---------- kustomization 멱등 등록 ----------
function registerResource(file: string, entry: string) {
  const cur = readFileSync(file, "utf8");
  const updated = addResource(cur, entry);   // 멱등 SSOT(이미 있으면 동일 문자열)
  return updated === cur ? null : updated;   // 기존 계약 보존: 변화 없으면 null
}

const checklist = [
  `valkey 이미지 태그(${VALKEY_IMAGE}) 실존/arm64 확인 후 필요 시 digest 핀`,
  `apps/<app>/deploy/prod/values.yaml envFrom에 secretRef 'cache-${name}-conn' 배선 필요 — 미배선 시 앱이 캐시 없이 그대로 배포된다(#211 재발 클래스). envFrom 변경(회전 포함) 반영은 파드 재시작 필요`,
  "cache NS의 R2 백업 자격 cache-r2-creds가 아직 없으면 kubeseal로 봉인 필요 (platform/cache/prod/backup-cronjob.yaml 참고)",
];
const dataConnKustomization = `${ROOT}/platform/data-conn/prod/kustomization.yaml`;
const dataConnExists = existsSync(dataConnKustomization);
if (!dataConnExists)
  checklist.unshift(
    `platform/data-conn/prod/kustomization.yaml(namespace: prod)에 cache-${name}-conn.sealed.yaml·cache-${name}-ro-conn.sealed.yaml 등록 필요 — kustomization 생성은 Task 5.1 작업자 소유, 등록 전까지 prod에 conn Secret이 만들어지지 않는다`,
  );

const files = [
  `platform/cache/prod/${name}/kustomization.yaml`,
  `platform/cache/prod/${name}/configmap.yaml`,
  `platform/cache/prod/${name}/pvc.yaml`,
  `platform/cache/prod/${name}/deployment.yaml`,
  `platform/cache/prod/${name}/service.yaml`,
  `platform/cache/prod/${name}/acl.sealed.yaml`,
  `platform/data-conn/prod/cache-${name}-conn.sealed.yaml`,
  `platform/data-conn/prod/cache-${name}-ro-conn.sealed.yaml`,
  "platform/cache/prod/kustomization.yaml",
  "docs/memory-ledger.md",
];

const plan = {
  name,
  namespace: "cache",
  maxmemoryMi,
  reqMi,
  limitMi,
  image: VALKEY_IMAGE,
  service: `${name}.cache.svc.cluster.local:6379`,
  secrets: { conn: `cache-${name}-conn`, roConn: `cache-${name}-ro-conn`, acl: `${name}-acl` },
  envKeys: [`${NAME}_REDIS_URL`, `${NAME}_REDIS_RO_URL`],
  ledger: { before: sumLimit, after: sumLimit + limitMi, budget },
  files,
  checklist,
};

if (!DRY) {
  const host = `${name}.cache.svc.cluster.local`;
  // 봉인 먼저(실패 시 디스크 무변경), 쓰기는 마지막에 일괄.
  const sealedAcl = seal(secret("cache", `${name}-acl`, {
    "users.acl": usersAcl, // 해시만 포함
    VALKEY_PASSWORD: pw, // cache-backup CronJob의 BGSAVE/--rdb 인증용 (cache NS 밖으로 안 나간다)
  }));
  const sealedConn = seal(secret("prod", `cache-${name}-conn`, {
    [`${NAME}_REDIS_URL`]: `redis://:${pw}@${host}:6379`,
  }));
  const sealedRoConn = seal(secret("prod", `cache-${name}-ro-conn`, {
    [`${NAME}_REDIS_RO_URL`]: `redis://ro:${pwRo}@${host}:6379`,
  }));

  mkdirSync(instDir, { recursive: true });
  mkdirSync(`${ROOT}/platform/data-conn/prod`, { recursive: true });
  writeFileSync(`${instDir}/kustomization.yaml`, instKustomization);
  writeFileSync(`${instDir}/configmap.yaml`, configmapYaml);
  writeFileSync(`${instDir}/pvc.yaml`, pvcYaml);
  writeFileSync(`${instDir}/deployment.yaml`, deploymentYaml);
  writeFileSync(`${instDir}/service.yaml`, serviceYaml);
  writeFileSync(`${instDir}/acl.sealed.yaml`, sealedAcl);
  writeFileSync(connPath, sealedConn);
  writeFileSync(roConnPath, sealedRoConn);

  // cache 컴포넌트 kustomization: 있으면 멱등 등록, 없으면 최초 생성(namespace: cache)
  const cacheKustomization = `${ROOT}/platform/cache/prod/kustomization.yaml`;
  if (existsSync(cacheKustomization)) {
    const updated = registerResource(cacheKustomization, name);
    if (updated !== null) writeFileSync(cacheKustomization, updated);
  } else {
    writeFileSync(cacheKustomization, `apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Valkey 캐시 계층 — platform-components appset이 cache-prod로 자동 발견한다.
# 인스턴스 디렉토리는 tools/provision-cache.ts가 resources에 멱등 등록한다.
namespace: cache
resources:
  - ${name}
`);
  }

  // data-conn kustomization은 생성하지 않는다(Task 5.1 소유) — 있으면 등록만
  if (dataConnExists) {
    for (const entry of [`cache-${name}-conn.sealed.yaml`, `cache-${name}-ro-conn.sealed.yaml`]) {
      const updated = registerResource(dataConnKustomization, entry);
      if (updated !== null) writeFileSync(dataConnKustomization, updated);
    }
  }

  // 원장: 행 추가 + Totals 프로즈 동반 갱신(ledger-budget SSOT — create-app.ts와 동일)
  writeFileSync(ledgerPath, appendRowWithTotals(agg, { name: component, env: "cache", reqMi, limitMi }));
}

console.log(JSON.stringify(plan, null, 2));
