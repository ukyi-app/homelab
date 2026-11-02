// 앱 볼륨 검사(T20 봇 기억 삭제 원장, 설계 C.5.5·C.8). 원장 계약 v1의 StorageClass·PV·PVC가 서로 맞는지, 원장을 게시 서버
// Deployment 하나만 붙이는지, 공유 차트 앱이 PVC를 붙이면 Recreate인지(단일 작성자), 앱 ns에 직접 hostPath가 없는지 본다.
// 렌더 맥락(클러스터)마다 따로 잇는다. 운영과 VM은 같은 이름의 리소스를 따로 갖는다(policy.ts context).
import { type Doc, type Violation } from "./lib";
import { WORKLOAD_KINDS, context, expand, id, podSpec } from "./policy";

const SC = "local-ledger";
const CLAIM = "deletion-ledger";
// 원장 계약 v1의 호스트 경로. platform/bot-slot/values.schema.json의 deletionLedger.path와 같다.
const HOST_PATH = "/mnt/bulk/homelab-bot/deletion-ledger";
const SYNC_OPTIONS = "argocd.argoproj.io/sync-options";
// 이 클러스터에서는 원장 PVC에 PV가 꼭 있어야 한다. VM은 운영 SSD가 없어 PV 없이 PVC가 Pending인 것을 받아들인다
// (platform/root/values-vm.yaml deletionLedger 주석). 클러스터 이름 분기는 리소스를 내지 않는 검사에만 둔다(cluster-check.yaml과 같다).
const PV_REQUIRED_CLUSTERS = new Set(["prod"]);

const nsOf = (d: Doc): string | undefined => d.obj.metadata?.namespace ?? d.ns;
const clusterOf = (origin: string): string | undefined => origin.match(/\[([a-z0-9-]+)\]/)?.[1];
const protectedRes = (d: Doc): boolean => {
  const opts = String(d.obj.metadata?.annotations?.[SYNC_OPTIONS] ?? "").split(",").map((s) => s.trim());
  return opts.includes("Prune=false") && opts.includes("Delete=false");
};

// Kubernetes 수량(Ki·Mi·Gi·Ti만). 모르는 단위는 NaN이라 비교가 실패로 드러난다.
function bytes(q: unknown): number {
  const m = String(q ?? "").match(/^([0-9]+)(Ki|Mi|Gi|Ti)$/);
  if (!m) return Number.NaN;
  return Number(m[1]) * 1024 ** { Ki: 1, Mi: 2, Gi: 3, Ti: 4 }[m[2] as "Ki" | "Mi" | "Gi" | "Ti"];
}

export function checkVolumes(input: Doc[]): Violation[] {
  const docs = expand(input);
  const out: Violation[] = [];
  const push = (d: Doc | string, message: string) => out.push({ rule: "volume", where: typeof d === "string" ? d : id(d), message });
  const byCtx = new Map<string, Doc[]>();
  for (const d of docs) {
    const c = context(d.origin);
    byCtx.set(c, [...(byCtx.get(c) ?? []), d]);
  }

  for (const [ctx, ds] of byCtx) {
    const scs = ds.filter((d) => d.obj.kind === "StorageClass" && d.obj.metadata?.name === SC);
    const pvs = ds.filter((d) => d.obj.kind === "PersistentVolume");
    const pvcs = ds.filter((d) => d.obj.kind === "PersistentVolumeClaim");
    const ledgerPvs = pvs.filter((d) => d.obj.spec?.storageClassName === SC);
    const ledgerPvcs = pvcs.filter((d) => d.obj.spec?.storageClassName === SC);

    // StorageClass: 동적 생성 없음, 소비자 대기, Retain, 확장 불가, Argo CD가 지우지 않음.
    for (const d of scs) {
      const o = d.obj;
      if (o.provisioner !== "kubernetes.io/no-provisioner") push(d, `provisioner가 kubernetes.io/no-provisioner가 아니다(${o.provisioner}). 동적 생성이 원장을 다른 디스크에 만든다`);
      if (o.volumeBindingMode !== "WaitForFirstConsumer") push(d, `volumeBindingMode가 WaitForFirstConsumer가 아니다(${o.volumeBindingMode})`);
      if (o.reclaimPolicy !== "Retain") push(d, `reclaimPolicy가 Retain이 아니다(${o.reclaimPolicy})`);
      if (o.allowVolumeExpansion === true) push(d, "allowVolumeExpansion을 켜지 않는다(local 볼륨은 확장되지 않는다)");
      if (!protectedRes(d)) push(d, `${SYNC_OPTIONS}에 Prune=false,Delete=false가 없다`);
    }
    if (scs.length > 1) push(`${ctx} StorageClass/${SC}`, "같은 렌더 맥락에 둘 이상이다");

    // 원장 PV: SSD 디렉터리의 local 볼륨, Retain, 노드 고정, 예약은 이름·ns만, 보호.
    for (const d of ledgerPvs) {
      const s = d.obj.spec ?? {};
      if (s.hostPath !== undefined) push(d, "hostPath PV를 쓰지 않는다. local(정적, 노드 고정)이어야 한다");
      if (s.local?.path !== HOST_PATH) push(d, `local.path가 원장 계약 경로 ${HOST_PATH}가 아니다(${s.local?.path})`);
      if (s.persistentVolumeReclaimPolicy !== "Retain") push(d, `persistentVolumeReclaimPolicy가 Retain이 아니다(${s.persistentVolumeReclaimPolicy})`);
      if (JSON.stringify(s.accessModes) !== JSON.stringify(["ReadWriteOnce"])) push(d, `accessModes는 [ReadWriteOnce]다(${JSON.stringify(s.accessModes)})`);
      if (s.volumeMode !== "Filesystem") push(d, `volumeMode가 Filesystem이 아니다(${s.volumeMode})`);
      const terms: any[] = s.nodeAffinity?.required?.nodeSelectorTerms ?? [];
      const exprs: any[] = terms[0]?.matchExpressions ?? [];
      const e = exprs[0];
      if (terms.length !== 1 || exprs.length !== 1 || e?.key !== "kubernetes.io/hostname" || e?.operator !== "In" || !Array.isArray(e?.values) || e.values.length !== 1) {
        push(d, "nodeAffinity는 kubernetes.io/hostname In [노드 하나] 하나여야 한다");
      }
      const ref = s.claimRef ?? {};
      const refKeys = Object.keys(ref).sort().join(",");
      if (refKeys !== "name,namespace") push(d, `claimRef는 name·namespace만 적는다(지금 ${refKeys || "없음"}). uid를 고정하면 재구축 때 새 PVC에 묶이지 않는다`);
      if (ref.name !== CLAIM) push(d, `claimRef.name이 ${CLAIM}이 아니다(${ref.name})`);
      if (!protectedRes(d)) push(d, `${SYNC_OPTIONS}에 Prune=false,Delete=false가 없다`);
      if (scs.length === 0) push(d, `같은 렌더 맥락에 StorageClass ${SC}가 없다`);
    }

    // 원장 PVC: 미리 묶은 PV와 서로 가리키는지, 보호, 용량.
    for (const d of ledgerPvcs) {
      const s = d.obj.spec ?? {};
      if (d.obj.metadata?.name !== CLAIM) push(d, `${SC} PVC 이름은 ${CLAIM}이다`);
      if (JSON.stringify(s.accessModes) !== JSON.stringify(["ReadWriteOnce"])) push(d, `accessModes는 [ReadWriteOnce]다(${JSON.stringify(s.accessModes)})`);
      if (typeof s.volumeName !== "string" || s.volumeName === "") push(d, "volumeName으로 원장 PV를 정확히 고른다(다른 PV에 묶이지 않게)");
      if (!protectedRes(d)) push(d, `${SYNC_OPTIONS}에 Prune=false,Delete=false가 없다. 원장은 앱·데이터 Application 삭제에도 남아야 한다`);
      const cluster = clusterOf(d.origin);
      if (cluster === undefined) continue; // 차트 시험 values 렌더에는 PV가 없다
      const pv = pvs.find((p) => p.obj.metadata?.name === s.volumeName);
      if (!pv) {
        if (PV_REQUIRED_CLUSTERS.has(cluster)) push(d, `같은 클러스터(${cluster})에 PV ${s.volumeName}가 없다. 원장 PVC가 Pending으로 남는다(platform/root/values-${cluster}.yaml의 cluster.deletionLedger)`);
        continue;
      }
      if (pv.obj.spec?.storageClassName !== s.storageClassName) push(d, `PV ${s.volumeName}의 storageClassName(${pv.obj.spec?.storageClassName})이 PVC(${s.storageClassName})와 다르다`);
      const ref = pv.obj.spec?.claimRef ?? {};
      if (ref.name !== d.obj.metadata?.name || ref.namespace !== nsOf(d)) push(d, `PV ${s.volumeName}의 claimRef(${ref.namespace}/${ref.name})가 이 PVC(${nsOf(d)}/${d.obj.metadata?.name})가 아니다`);
      const want = bytes(s.resources?.requests?.storage);
      const have = bytes(pv.obj.spec?.capacity?.storage);
      if (!(want <= have)) push(d, `요청 용량 ${s.resources?.requests?.storage}이 PV 용량 ${pv.obj.spec?.capacity?.storage}보다 크다(묶이지 않는다)`);
    }
    // PV가 예약한 PVC가 같은 맥락에 있으면 그 PVC도 이 PV를 골라야 한다(SC가 다른 PVC가 같은 이름을 쓰는 실수).
    for (const pv of ledgerPvs) {
      const ref = pv.obj.spec?.claimRef ?? {};
      const pvc = pvcs.find((p) => p.obj.metadata?.name === ref.name && nsOf(p) === ref.namespace);
      if (pvc && (pvc.obj.spec?.storageClassName !== SC || pvc.obj.spec?.volumeName !== pv.obj.metadata?.name)) {
        push(pv, `예약한 PVC ${ref.namespace}/${ref.name}가 이 PV를 고르지 않는다(storageClassName ${pvc.obj.spec?.storageClassName}, volumeName ${pvc.obj.spec?.volumeName})`);
      }
    }

    // 워크로드. 원장 claim은 이름(deletion-ledger)이나 같은 맥락의 local-ledger PVC로 알아본다. 차트 시험 values는 PVC 없이 렌더된다.
    const ledgerNames = new Set(ledgerPvcs.map((p) => `${nsOf(p)}/${p.obj.metadata?.name}`));
    const users: Doc[] = [];
    for (const d of ds) {
      if (!WORKLOAD_KINDS.has(d.obj.kind)) continue;
      const spec = podSpec(d.obj) ?? {};
      const ns = nsOf(d);
      const vols: any[] = spec.volumes ?? [];
      // 직접 hostPath는 앱 ns에 두지 않는다(PSA restricted가 거부하지만 렌더에서 먼저 막는다). sandbox는 policy.ts checkSandbox가 본다.
      if (ns?.startsWith("app-")) for (const v of vols) if (v?.hostPath) push(d, `앱 ns에 hostPath 볼륨 ${v.name}을 두지 않는다. 데이터는 PVC로 붙인다`);
      const claims = vols.filter((v) => v?.persistentVolumeClaim).map((v) => String(v.persistentVolumeClaim.claimName));
      const ledger = claims.some((c) => c === CLAIM || ledgerNames.has(`${ns}/${c}`));
      const role = d.obj.spec?.template?.metadata?.labels?.["homelab.ukyi.app/role"];
      const sharedApp = String(d.obj.metadata?.labels?.["homelab.ukyi.app/chart"] ?? "").match(/^app-[0-9]/) !== null;
      // 공유 차트 앱의 영속 볼륨은 단일 작성자다. RollingUpdate는 새 파드가 Ready가 될 때까지 옛 파드와 함께 쓴다.
      if (d.obj.kind === "Deployment" && sharedApp && claims.length > 0 && d.obj.spec?.strategy?.type !== "Recreate") {
        push(d, `PVC(${claims.join(", ")})를 붙인 앱은 strategy Recreate여야 한다(단일 작성자, 지금 ${d.obj.spec?.strategy?.type})`);
      }
      if (!ledger) continue;
      users.push(d);
      if (d.obj.kind !== "Deployment") push(d, `원장 PVC는 게시 서버 Deployment만 붙인다(${d.obj.kind}). 마이그레이션·백업·복원 Job에는 붙이지 않는다`);
      if (ns === "sandbox" || !ns?.startsWith("app-")) push(d, `원장 PVC를 ${ns ?? "ns 없음"} 워크로드에 붙이지 않는다(작업자에는 원장이 보이지 않아야 한다, 설계 C.8)`);
      if (role !== undefined) push(d, `원장 PVC를 role ${role} 파드에 붙이지 않는다`);
      if (d.obj.kind === "Deployment") {
        if (d.obj.spec?.strategy?.type !== "Recreate") push(d, `원장 PVC를 붙인 Deployment는 strategy Recreate여야 한다(지금 ${d.obj.spec?.strategy?.type})`);
        if (typeof d.obj.spec?.replicas !== "number" || d.obj.spec.replicas > 1) push(d, `원장 PVC를 붙인 Deployment는 replicas 0 또는 1이다(지금 ${d.obj.spec?.replicas})`);
      }
      // fsGroup이 있으면 kubelet이 볼륨을 g+rw·setgid로 바꿔 원장 계약 권한(0600·0750)이 깨진다(공유 차트 _helpers.tpl app.podSecurity).
      if (spec.securityContext?.fsGroup !== undefined) push(d, "원장 PVC를 붙인 파드에 fsGroup을 두지 않는다(볼륨 권한이 0660·2770으로 바뀐다)");
    }
    if (users.length > 1) push(`${ctx} PVC/${CLAIM}`, `원장 PVC를 붙인 워크로드가 ${users.length}개다(${users.map((u) => `${u.obj.kind}/${u.obj.metadata?.name}`).join(", ")}). 게시 서버 하나만`);
  }
  return out;
}
