// 노드에서 하는 정지 확인(supervisor.md §7.4, spec D-39). cgroup은 sudo 없이 파일로 읽고(cgroup.events는 0444),
// 컨테이너 목록만 sudo로 부른다(containerd 소켓은 root 전용). 경로 꼴과 sudo argv는 여기 고정이고 명령은 UID만 넘긴다.
// 읽지 못한 것은 unreadable·unknown으로 내고 "없음"으로 바꾸지 않는다.
import { readFileSync, statSync } from "node:fs";
import type { NodeHost, NodeRead, PodCgroup, RuntimeContainer, RuntimeList } from "./command";
import type { Exec } from "./exec";
import { isArray, jsonParse } from "./intrinsics";
import { kubectlArgv } from "./kubectl";
import { POD_UID } from "./olive";
import { RUNTIME_LIST_ARGV } from "./writes";

// 시험만 다른 뿌리를 준다(runtime.ts는 이 기본값만 쓴다).
export type NodePaths = { cgroup: string; machineId: string };
export const NODE_PATHS: NodePaths = { cgroup: "/sys/fs/cgroup", machineId: "/etc/machine-id" };

const MACHINE_ID = /^[0-9a-f]{32}$/;
const CONTAINER_STATES = new Set(["CONTAINER_CREATED", "CONTAINER_RUNNING", "CONTAINER_EXITED", "CONTAINER_UNKNOWN"]);
const SUDO_AUTH = /a password is required|a terminal is required|may not run sudo|is not in the sudoers/;

type Stat = "dir" | "missing" | "other" | "error";

function stat(path: string): Stat {
  try {
    return statSync(path).isDirectory() ? "dir" : "other";
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ENOENT" ? "missing" : "error";
  }
}

// k3s(systemd cgroup 드라이버)의 파드 cgroup 꼴. QoS 등급마다 하나다(Guaranteed는 등급 slice가 없다).
// UID의 -는 _로 바뀐다(O25 노드 관측: kubepods-burstable-pod<UID의 -를 _로>.slice).
export function podCgroupDirs(root: string, uid: string): string[] {
  if (typeof uid !== "string" || !POD_UID.test(uid)) throw new Error("파드 UID는 소문자 UUID 꼴만");
  const u = uid.replaceAll("-", "_");
  const base = `${root}/kubepods.slice`;
  return [`${base}/kubepods-pod${u}.slice`, `${base}/kubepods-burstable.slice/kubepods-burstable-pod${u}.slice`, `${base}/kubepods-besteffort.slice/kubepods-besteffort-pod${u}.slice`];
}

export function nodeRead(exec: Exec, paths: NodePaths = NODE_PATHS): NodeRead {
  return {
    host(): NodeHost {
      let id: string | null;
      try {
        id = readFileSync(paths.machineId, "utf8").trim();
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ENOENT") return { state: "unknown", reason: "machine-id를 읽지 못했다" };
        id = null;
      }
      if (id !== null && !MACHINE_ID.test(id)) return { state: "unknown", reason: "machine-id 형식이 아니다" };
      const r = exec(kubectlArgv(["get", "nodes", "-o", "json"]));
      if (r.errKind === "timeout") return { state: "unknown", reason: "Node 목록: 시간 초과" };
      if (r.code !== 0) return { state: "unknown", reason: "Node 목록을 읽지 못했다" };
      let items: any[];
      try {
        const doc = jsonParse(r.stdout);
        if (!isArray(doc?.items)) return { state: "unknown", reason: "Node 목록 응답에 items가 없다" };
        items = doc.items;
      } catch {
        return { state: "unknown", reason: "Node 목록 응답이 JSON이 아니다" };
      }
      if (id === null) return { state: "not-node" };
      const hits = items.filter((n) => n?.status?.nodeInfo?.machineID === id);
      if (hits.length === 0) return { state: "not-node" };
      if (hits.length > 1) return { state: "unknown", reason: "machine-id가 같은 Node가 여럿이다" };
      const name = hits[0]?.metadata?.name;
      if (typeof name !== "string" || !name) return { state: "unknown", reason: "Node 이름을 읽지 못했다" };
      // 노드인데 파드 cgroup 뿌리가 없으면 cgroup 꼴이 다른 것이다(드라이버 변경 등). 노드 확인을 할 수 없다.
      if (stat(`${paths.cgroup}/kubepods.slice`) !== "dir") return { state: "unknown", reason: "kubepods.slice가 없다(cgroup 꼴이 다르다)" };
      return { state: "node", node: name };
    },
    podCgroup(uid): PodCgroup {
      const dirs = podCgroupDirs(paths.cgroup, uid);
      if (stat(`${paths.cgroup}/kubepods.slice`) !== "dir") return "unreadable";
      const found: string[] = [];
      for (const d of dirs) {
        const s = stat(d);
        if (s === "dir") found.push(d);
        else if (s !== "missing") return "unreadable";
      }
      if (found.length === 0) return "absent";
      if (found.length > 1) return "unreadable";
      let text: string;
      try {
        text = readFileSync(`${found[0]}/cgroup.events`, "utf8");
      } catch {
        // 그사이 cgroup이 사라졌으면 없음이다. 폴더가 그대로인데 못 읽었으면 모름이다.
        return stat(found[0]) === "missing" ? "absent" : "unreadable";
      }
      const lines = text.split("\n").filter((l) => l.startsWith("populated "));
      if (lines.length !== 1) return "unreadable";
      if (lines[0] === "populated 0") return "empty";
      if (lines[0] === "populated 1") return "populated";
      return "unreadable";
    },
    runtimeContainers(): RuntimeList {
      const r = exec([...RUNTIME_LIST_ARGV]);
      if (r.errKind === "not-found") return { state: "unreadable", reason: "no-sudo" };
      if (r.errKind === "timeout") return { state: "unreadable", reason: "timeout" };
      if (r.code !== 0) return { state: "unreadable", reason: SUDO_AUTH.test(r.stderr) ? "sudo-auth" : "failed" };
      try {
        const doc = jsonParse(r.stdout);
        if (!isArray(doc?.containers)) return { state: "unreadable", reason: "format" };
        const out: RuntimeContainer[] = [];
        for (const c of doc.containers) {
          const labels = c?.labels ?? {};
          const uid = labels["io.kubernetes.pod.uid"];
          const container = c?.metadata?.name;
          if (typeof container !== "string" || typeof c?.state !== "string" || !CONTAINER_STATES.has(c.state)) return { state: "unreadable", reason: "format" };
          if (uid !== undefined && (typeof uid !== "string" || !POD_UID.test(uid))) return { state: "unreadable", reason: "format" };
          const str = (v: unknown) => (typeof v === "string" ? v : null);
          out.push({ podUid: uid ?? null, podNamespace: str(labels["io.kubernetes.pod.namespace"]), podName: str(labels["io.kubernetes.pod.name"]), container, state: c.state });
        }
        return { state: "ok", containers: out };
      } catch {
        return { state: "unreadable", reason: "format" };
      }
    },
  };
}
