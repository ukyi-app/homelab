// 리소스 산출물 레이아웃 커널 — kind+name에서 db/cache 산출물의 명명·배치 전부를 유도한다
// (cli-deepening 심화 4, CONTEXT.md "산출물 레이아웃"). 지금까지 이 지식은 7개 module
// (provision-db/cache · teardown-resource purgeArtifacts · audit-orphans 정규식 · verbs ·
// db-url/cache-url)이 각자 재유도했다 — 생성·철거·감사·관측이 같은 레이아웃을 읽게 하는
// 단일 소유자다(선례: identity.ts·sealed-contract.ts readSealed).
//
// 원칙:
//   - 순수 문자열 유도만 — yaml 편집·파일 I/O는 흡수하지 않는다(provision-db의 doc-배치
//     직렬화 결정 존중). 경로는 전부 레포 상대가 정준형이다 — ROOT 결합은 소비자 몫.
//   - scope 태그가 인터페이스의 일부다: teardown purge는 의도된 부분집합이다 — purge-제거 /
//     공유-잔존(파일은 남고 엔트리·행만 제거될 수 있음) / 수동-이연(cluster.yaml managed.roles
//     제거는 별도 수동 커밋). 이 scoping은 지금까지 teardown 구현에만 암묵적으로 살았다.
//     cache의 purge 권위는 instanceDir 디렉토리째 제거다 — files의 인스턴스 6파일 열거는
//     provision 산출 계약의 앵커이고, 7번째 파일이 생기면 이 행도 함께 갱신해야 한다
//     (provision이 커널을 소비하게 되는 후속 티켓에서 드리프트가 기계 검출된다).
//   - 양방향이 인터페이스다(설계 게이트 r1 D2): audit은 소스가 사라진 고아 conn처럼 임의
//     산출물에서 출발하므로, classifyArtifact가 역방향 판정을 커널 안에서 소유한다. 경로
//     문맥이 있으면 그 role의 정위치 디렉토리까지 검증한다 — 잘못 놓인 봉인본(databases/
//     아래의 conn 등)을 정상 산출물로 귀속하면 왕복 불변식이 깨진다(리뷰 실측 반례).
//   - 역방향 접미 파싱의 무결성 근거는 이름 정책이다: 판정은 identity.resourceNameError를
//     그대로 소비한다(분기 금지 — 콜사이트마다 다르면 우회 표면. '-ro' 접미 예약 덕에
//     db-x-ro-conn은 "x의 ro-conn"으로만 해석되고, 예약 이름은 provision이 거부하므로
//     그 이름의 산출물은 존재할 수 없다 — 분류도 같은 이유로 거부한다).
import { resourceNameError } from "./identity.ts";

export type ResourceKind = "db" | "cache";
export type ArtifactScope = "purge-제거" | "공유-잔존" | "수동-이연";

export type LayoutFile = { path: string; scope: ArtifactScope };
export type LayoutKustEntry = { kust: string; entry: string; scope: ArtifactScope };
// 핸들 = prod NS conn SealedSecret. envKeys로 키→시크릿 귀속을 명시한다 — MIGRATE 키가
// rw conn "안에" 산다는 사실이 인터페이스 밖이면 소비자가 위치를 재유도한다(리뷰 S4).
export type LayoutHandle = { name: string; envKeys: readonly string[] };

type LayoutBase = {
  files: readonly LayoutFile[];
  kustomizationEntries: readonly LayoutKustEntry[];
  handles: { rw: LayoutHandle; ro: LayoutHandle };
  tombstoneKey: string; // "<kind>:<name>" — .tombstones.json 키
};
// kind별 발산은 판별 union으로 못 박는다 — optional 필드는 테스트가 지키지만 union은
// 컴파일러가 지킨다(리뷰 S3).
export type DbLayout = LayoutBase & {
  kind: "db";
  envKeys: { rw: string; migrate: string; ro: string }; // role → 키 조회(설계 §심화 4)
  roles: { owner: string; ro: string };                 // cluster.yaml managed.roles 이름
};
export type CacheLayout = LayoutBase & {
  kind: "cache";
  envKeys: { rw: string; ro: string };
  instanceDir: string; // purge가 디렉토리째 제거하는 권위 경로
  ledgerRow: string;   // 메모리 원장 행 이름 cache-<name>
};
export type ResourceLayout = DbLayout | CacheLayout;

// kebab → UPPER_SNAKE (env 키 규약 — provision-db/cache의 ENV 유도와 동일)
function envName(name: string): string {
  return name.replaceAll("-", "_").toUpperCase();
}

const DB_DIR = "platform/cnpg/prod/databases";
const CNPG_DIR = "platform/cnpg/prod";
const CONN_DIR = "platform/data-conn/prod";
const CACHE_DIR = "platform/cache/prod";
const LEDGER = "docs/memory-ledger.md";

// cache 인스턴스 디렉토리 내용물 — provision-cache 산출 6파일(이름 고정).
const CACHE_INSTANCE_FILES = ["configmap.yaml", "pvc.yaml", "deployment.yaml", "service.yaml", "acl.sealed.yaml", "kustomization.yaml"] as const;

export function layoutFor(kind: "db", name: string): DbLayout;
export function layoutFor(kind: "cache", name: string): CacheLayout;
export function layoutFor(kind: ResourceKind, name: string): ResourceLayout;
export function layoutFor(kind: ResourceKind, name: string): ResourceLayout {
  const ENV = envName(name);
  if (kind === "db") {
    return {
      kind: "db",
      files: [
        { path: `${DB_DIR}/${name}.yaml`, scope: "purge-제거" },                        // CNPG Database CR
        { path: `${DB_DIR}/db-${name}-owner.sealed.yaml`, scope: "purge-제거" },        // 비밀번호(owner)
        { path: `${DB_DIR}/db-${name}-ro.sealed.yaml`, scope: "purge-제거" },           // 비밀번호(ro)
        { path: `${CONN_DIR}/db-${name}-conn.sealed.yaml`, scope: "purge-제거" },       // 앱 소비 conn(rw)
        { path: `${CONN_DIR}/db-${name}-ro-conn.sealed.yaml`, scope: "purge-제거" },    // 디버깅 conn(ro)
        { path: `${DB_DIR}/kustomization.yaml`, scope: "공유-잔존" },
        { path: `${CNPG_DIR}/kustomization.yaml`, scope: "공유-잔존" },
        { path: `${CNPG_DIR}/cluster.yaml`, scope: "수동-이연" },                        // managed.roles — 별도 수동 커밋
        { path: `${CONN_DIR}/kustomization.yaml`, scope: "공유-잔존" },
      ],
      kustomizationEntries: [
        { kust: `${DB_DIR}/kustomization.yaml`, entry: `${name}.yaml`, scope: "purge-제거" },
        { kust: `${DB_DIR}/kustomization.yaml`, entry: `db-${name}-owner.sealed.yaml`, scope: "purge-제거" },
        { kust: `${DB_DIR}/kustomization.yaml`, entry: `db-${name}-ro.sealed.yaml`, scope: "purge-제거" },
        { kust: `${CNPG_DIR}/kustomization.yaml`, entry: "databases/", scope: "공유-잔존" },
        { kust: `${CONN_DIR}/kustomization.yaml`, entry: `db-${name}-conn.sealed.yaml`, scope: "purge-제거" },
        { kust: `${CONN_DIR}/kustomization.yaml`, entry: `db-${name}-ro-conn.sealed.yaml`, scope: "purge-제거" },
      ],
      handles: {
        rw: { name: `db-${name}-conn`, envKeys: [`${ENV}_DATABASE_URL`, `${ENV}_MIGRATE_DATABASE_URL`] },
        ro: { name: `db-${name}-ro-conn`, envKeys: [`${ENV}_RO_DATABASE_URL`] },
      },
      envKeys: { rw: `${ENV}_DATABASE_URL`, migrate: `${ENV}_MIGRATE_DATABASE_URL`, ro: `${ENV}_RO_DATABASE_URL` },
      roles: { owner: name, ro: `${name}_ro` },
      tombstoneKey: `db:${name}`,
    };
  }
  return {
    kind: "cache",
    files: [
      ...CACHE_INSTANCE_FILES.map((f): LayoutFile => ({ path: `${CACHE_DIR}/${name}/${f}`, scope: "purge-제거" })),
      { path: `${CONN_DIR}/cache-${name}-conn.sealed.yaml`, scope: "purge-제거" },
      { path: `${CONN_DIR}/cache-${name}-ro-conn.sealed.yaml`, scope: "purge-제거" },
      { path: `${CACHE_DIR}/kustomization.yaml`, scope: "공유-잔존" },
      // data-conn kustomization은 provision-cache plan.files 밖이다(생성은 다른 소유자) —
      // 그러나 teardown이 엔트리를 제거하는 레이아웃의 일부이므로 커널은 포함한다.
      { path: `${CONN_DIR}/kustomization.yaml`, scope: "공유-잔존" },
      { path: LEDGER, scope: "공유-잔존" },                                             // 파일 잔존, 행(ledgerRow)만 제거
    ],
    kustomizationEntries: [
      { kust: `${CACHE_DIR}/kustomization.yaml`, entry: name, scope: "purge-제거" },
      { kust: `${CONN_DIR}/kustomization.yaml`, entry: `cache-${name}-conn.sealed.yaml`, scope: "purge-제거" },
      { kust: `${CONN_DIR}/kustomization.yaml`, entry: `cache-${name}-ro-conn.sealed.yaml`, scope: "purge-제거" },
    ],
    handles: {
      rw: { name: `cache-${name}-conn`, envKeys: [`${ENV}_REDIS_URL`] },
      ro: { name: `cache-${name}-ro-conn`, envKeys: [`${ENV}_REDIS_RO_URL`] },
    },
    envKeys: { rw: `${ENV}_REDIS_URL`, ro: `${ENV}_REDIS_RO_URL` },
    instanceDir: `${CACHE_DIR}/${name}`,
    ledgerRow: `cache-${name}`,
    tombstoneKey: `cache:${name}`,
  };
}

// ── 역방향(설계 게이트 r1 D2) ──────────────────────────────────────────────────
// role 어휘: conn(rw 핸들) · ro-conn(ro 핸들) · owner-secret/ro-secret(비밀번호) · cr · instance.
export type ArtifactRole = "conn" | "ro-conn" | "owner-secret" | "ro-secret" | "cr" | "instance";
export type ArtifactClass = { kind: ResourceKind; name: string; role: ArtifactRole };

// 이름 판정 — identity SSOT를 그대로 소비한다(형식·'-ro' 예약·db 예약 이름까지 동일 정책).
function validName(kind: ResourceKind, name: string): boolean {
  return resourceNameError(kind, name) === null;
}

// 접미 role의 정위치 디렉토리 — 경로 문맥이 있으면 여기까지 검증한다(오배치 = 산출물 아님).
const ROLE_DIR: Record<Exclude<ArtifactRole, "cr" | "instance">, string> = {
  "conn": CONN_DIR,
  "ro-conn": CONN_DIR,
  "owner-secret": DB_DIR,
  "ro-secret": DB_DIR,
};

// 경로 또는 kustomization 엔트리를 판정한다. 이름 무귀속 산출물(공유 kustomization·cluster.yaml·
// 원장)과 문맥 없는 엔트리(<name>.yaml·<name> 단독)는 null — 판정 불가를 귀속으로 접지 않는다.
export function classifyArtifact(pathOrEntry: string): ArtifactClass | null {
  const p = pathOrEntry.replace(/\/+$/, "");
  const slash = p.lastIndexOf("/");
  const base = p.slice(slash + 1);
  const dirCtx = slash >= 0 ? p.slice(0, slash) : null; // 경로 문맥(엔트리 단독이면 없음)

  // 접미가 가장 특정한 것부터 — -ro-conn을 -conn보다 먼저 대조해야 하이픈 이름이 오귀속되지
  // 않는다. kind는 arity 스니핑이 아니라 캡처로 받는다(리뷰 S2).
  const suffix: Array<[RegExp, ArtifactRole]> = [
    [/^(db|cache)-(.+)-ro-conn\.sealed\.yaml$/, "ro-conn"],
    [/^(db|cache)-(.+)-conn\.sealed\.yaml$/, "conn"],
    [/^(db)-(.+)-owner\.sealed\.yaml$/, "owner-secret"],
    [/^(db)-(.+)-ro\.sealed\.yaml$/, "ro-secret"],
  ];
  for (const [re, role] of suffix) {
    const m = base.match(re);
    if (m) {
      const kind = m[1] as ResourceKind;
      const name = m[2]!;
      if (!validName(kind, name)) return null;
      // 오배치 거부 — databases/ 아래의 conn, data-conn 아래의 비밀번호는 산출물이 아니다.
      if (dirCtx !== null && !dirCtx.endsWith(ROLE_DIR[role as Exclude<ArtifactRole, "cr" | "instance">])) return null;
      return { kind, name, role };
    }
  }

  // 디렉토리 문맥 판정 — CR(databases/<name>.yaml)과 cache 인스턴스.
  const dbIdx = p.indexOf(`${DB_DIR}/`);
  if (dbIdx >= 0) {
    const rest = p.slice(dbIdx + DB_DIR.length + 1);
    if (!rest.includes("/") && rest.endsWith(".yaml") && rest !== "kustomization.yaml") {
      const name = rest.slice(0, -".yaml".length);
      return validName("db", name) ? { kind: "db", name, role: "cr" } : null;
    }
    return null;
  }
  const cacheIdx = p.indexOf(`${CACHE_DIR}/`);
  if (cacheIdx >= 0) {
    const rest = p.slice(cacheIdx + CACHE_DIR.length + 1);
    const name = rest.split("/")[0]!;
    if (name === "kustomization.yaml") return null;
    return validName("cache", name) ? { kind: "cache", name, role: "instance" } : null;
  }
  return null;
}
