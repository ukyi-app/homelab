// homelab olive stop status|verify. 읽기만 한다. 증거의 이름은 supervisor.md 7.3·7.4절을 따른다.
// 끝 상태는 그 실행이 읽은 것만으로 정한다. 읽지 못한 것은 미상이고, 미상이 있으면 정지됨과 0을 내지 않는다.
// 소멸 확인은 Kubernetes에서 보는 기본 단계뿐이다. 노드에서의 확인과 런타임 대조는 이 CLI에 없어 "노드 미확인"이라고 말한다.
import { INTAKE_UNKNOWN, anyUnread, countPods, forcedPods, lockSummary, podWords, readAll, replicasWords, stopTargets, targetLine, unreadWhy, type Action, type Outcome, type TargetView } from "./olive-state";

const VERIFY_SCOPE = "확인 범위: 이미 걸려 있는 자물쇠와 Kubernetes에서 본 파드 소멸까지다. replicas가 0으로 유지되는지는 보지 않는다. 노드에서의 확인은 이 CLI에 아직 없다";
const NO_SPACES = "확인할 네임스페이스가 하나도 없다";
const CHECK_SPACES = "대상 목록과 클러스터를 확인한다";
// 강제 삭제는 kubelet의 종료 확인 없이 API에서 파드를 지운다. 기다리거나 다시 읽어도 종료의 증거가 생기지 않는다.
const FORCED_NEXT = "강제 삭제된 파드가 있었다. Kubernetes의 목록만으로는 프로세스의 종료를 알 수 없고 이 CLI에는 아직 노드에서의 확인이 없다. 노드에서 직접 확인한다";

const verboseLines = (views: TargetView[], verbose: boolean) => (verbose ? views.map(targetLine) : []);

export function stopStatus(verbose: boolean): Action {
  return {
    command: "olive stop status",
    target: "올리브 정지 상태",
    title: "homelab olive stop status",
    plan(c) {
      const views = readAll(c, stopTargets());
      const locks = lockSummary(views);
      const pods = podWords(countPods(views));
      if (anyUnread(views)) return { status: "failed", label: "읽지 못함", headline: `확인 실패: ${unreadWhy(views)}. ${locks.words}, ${pods}`, lines: views.map(targetLine), next: "kubectl 접속과 대상의 Deployment를 확인한 뒤 다시: homelab olive stop status" };
      const state = locks.held === 0 ? "정지 아님" : locks.held === locks.present ? "정지 중" : "일부만 정지";
      return { status: "same", label: state, headline: `${state}: ${locks.words}, ${pods}`, lines: [INTAKE_UNKNOWN, replicasWords(views), ...verboseLines(views, verbose)], next: null };
    },
  };
}

export function stopVerify(verbose: boolean): Action {
  return {
    command: "olive stop verify",
    target: "올리브 정지 확인",
    title: "homelab olive stop verify",
    plan(c) {
      const views = readAll(c, stopTargets());
      const locks = lockSummary(views);
      const pods = countPods(views);
      const forced = forcedPods(views);
      const raised = views.filter((v) => v.deployment.state === "present" && (v.deployment.replicas ?? 0) > 0);
      // 자물쇠가 걸려 있다고 읽은 대상만 "새 파드만 막고 있다"고 말한다.
      const blocked = raised.filter((v) => v.lock === "same").map((v) => v.target.id);
      const raisedLine = raised.length ? [`주의: replicas가 0이 아닌 대상 ${raised.map((v) => v.target.id).join(", ")}${blocked.length ? `. 이 가운데 ${blocked.join(", ")}는 자물쇠가 새 파드만 막고 있다` : ""}`] : [];
      const forcedLine = forced.length ? [`강제 삭제 중인 파드: ${forced.join(", ")}`] : [];
      const base = [INTAKE_UNKNOWN, `차단: ${locks.words}`, replicasWords(views), VERIFY_SCOPE, ...raisedLine, `소멸: ${podWords(pods)}`, ...forcedLine, ...verboseLines(views, verbose)];
      const fail = (label: string, why: string, next: string): Outcome => ({ status: "failed", label, headline: `${label}: ${why}`, lines: base, next: forced.length && next !== FORCED_NEXT ? `${next}. ${FORCED_NEXT}` : next });
      if (anyUnread(views)) return fail("확인 실패", unreadWhy(views), "kubectl 접속과 대상의 Deployment를 확인한 뒤 다시 실행한다");
      if (locks.present === 0) return fail("확인 실패", NO_SPACES, CHECK_SPACES);
      if (locks.held < locks.present) return fail("차단 미완", `자물쇠가 ${locks.present - locks.held}곳에 걸려 있지 않다`, "대상별 자물쇠를 다시 읽는다: homelab olive stop verify --verbose");
      if (pods.forced > 0) return fail("확인 실패", `강제 삭제 중인 파드 ${pods.forced}개. API에서 사라져도 종료의 증거가 아니다`, FORCED_NEXT);
      if (pods.live > 0) return { status: "waiting", label: "종료 대기", headline: `종료 대기: ${podWords(pods)}`, lines: base, next: "잠시 뒤 다시: homelab olive stop verify" };
      return { status: "same", label: "정지됨(노드 미확인)", headline: `정지됨(노드 미확인): ${locks.words}, ${podWords(pods)}`, lines: base, next: null };
    },
  };
}
