// homelab CLI 사람용 렌더 — **셸 소유 프레젠테이션 모듈**(lib/mcp.ts와 같은 층: 계약 파생이 아니라
// 표현). op는 Envelope만 반환하고 표현은 여기가 소유한다는 경계가 이 파일의 존재 이유다 — 동사
// descriptor에서 파생하지 않으므로 ADR-0001(verb descriptor 파생 기각)과 무관하다.
//
// homelab.ts에서 분리한 이유는 둘이다: (a) bin 모듈은 import 시 main이 실행돼 테스트가 렌더러를
// 직접 호출할 수 없었고, 그래서 골든 22건 전수를 렌더에 통과시키는 스윕이 **원리적으로** 불가능했다.
// (b) 렌더러가 --json 모드에서도 즉시 평가돼(어댑터가 `human: renderX(envelope)`) 사람용 렌더의
// 결함이 기계 채널(JSON)까지 죽였다 — 지금은 셸이 thunk로 받아 envelope를 먼저 낸다.
//
// 총체성: renderFor는 verb를 전수 분기하고 미지 verb는 throw(계약 파손), renderStatus는 mode를
// switch로 받고 default가 throw다. 조용한 폴백은 늦은 실패를 만든다 — 합성 mode "resource"에서
// `undefined is not an object (evaluating 'r.pr.number')`로 죽던 자리가 그 실증이다.
import type { Envelope } from "./contract.ts";
import type { DoctorCheck, DoctorSummary } from "./doctor.ts";

export const MARK: Record<string, string> = { pass: "✓", fail: "✗", warn: "⚠" };
export const OX: Record<string, string> = { true: "켜짐", false: "꺼짐" };

export function renderDoctor(envelope: Envelope): string[] {
  const r = envelope.result as { checks: DoctorCheck[]; summary: DoctorSummary };
  return [
    ...r.checks.map((c) => `${MARK[c.status]} ${c.id} — ${c.detail}`),
    "",
    `진단 결과: pass ${r.summary.pass} · fail ${r.summary.fail} · warn ${r.summary.warn}`,
  ];
}

export function renderStatus(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  if (typeof r.error === "string") {
    const lines = [`오류: ${r.error}`];
    // 산출물 부재 분기의 부가 관측 — 진행 중인 create-app PR(수동 머지 대기)이 있으면 좌표를 준다.
    if (Array.isArray(r.createPrs)) lines.push(`진행 중인 create-app PR: ${r.createPrs.map((p: Record<string, unknown>) => `#${p.number} ${p.url}`).join(" · ")}`);
    return lines;
  }
  switch (r.mode) {
    case "list": {
      if (r.count === 0) return ["온보딩된 앱이 없다(그린필드)"];
      return [
        `앱 ${r.count}개`,
        ...r.apps.map((a: Record<string, unknown>) =>
          `• ${a.name} — tag ${a.tag ?? "(핀 없음)"} · autoDeploy ${OX[String(a.autoDeploy)] ?? "미기록"} · repo ${a.sourceRepo ?? "(인레포)"}`),
      ];
    }
    case "app": {
      const lines = [
        `앱: ${r.app.name}`,
        `배포 핀: tag ${r.app.tag ?? "(없음)"} · digest ${r.app.digest ?? "(없음)"}`,
        `autoDeploy: ${OX[String(r.app.autoDeploy)] ?? "미기록"} · source repo: ${r.app.sourceRepo ?? "(인레포)"} · 메모리 원장: ${r.app.ledgerMi !== undefined ? `limit ${r.app.ledgerMi}Mi` : "행 없음"}`,
        r.runs.length === 0 ? "최근 run: 없음"
          : `최근 run: ${r.runs.map((x: Record<string, unknown>) => `${x.name}[${x.status}${x.conclusion ? `/${x.conclusion}` : ""}]`).join(" · ")}`,
        r.openPrs.length === 0 ? "열린 PR: 없음"
          : `열린 PR: ${r.openPrs.map((p: Record<string, unknown>) => `#${p.number}(${p.head})`).join(" · ")}`,
      ];
      if (envelope.omitted.includes("live")) lines.push("라이브(ArgoCD): 생략 — KUBECONFIG 미설정");
      else if (r.live?.error) lines.push(`라이브(ArgoCD): 조회 실패 — ${r.live.error}`);
      else lines.push(`라이브(ArgoCD): sync ${r.live.argocd.sync} · health ${r.live.argocd.health}${r.live.argocd.revision ? ` · rev ${r.live.argocd.revision}` : Array.isArray(r.live.argocd.revisions) ? ` · revisions ${r.live.argocd.revisions.join(",")}(미확정)` : ""}`);
      return lines;
    }
    case "run": {
      const lines = [`run: ${r.run.name ?? "(이름 없음)"} — status ${r.run.status}${r.run.conclusion ? ` · conclusion ${r.run.conclusion}` : " · 진행 중"}`];
      // --branch 좌표 조회 — PR 부재(아직 안 났거나 no-op)와 실재를 구별해 보고한다.
      if (r.run.branch) lines.push(r.run.pr ? `레인 PR(${r.run.branch}): #${r.run.pr.number} ${r.run.pr.url} · merged ${OX[String(r.run.pr.merged)]}` : `레인 PR(${r.run.branch}): 없음`);
      return lines;
    }
    case "pr":
      return [`PR #${r.pr.number} — ${r.pr.state} · merged ${OX[String(r.pr.merged)]} · auto-merge ${OX[String(r.pr.autoMerge)]}`];
    default:
      throw new Error(`계약 파손: status 렌더 미지원 mode — ${String(r.mode)}`);
  }
}

export function renderMutation(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  const lines = [`${envelope.verb} ${r.name}${r.correlation ? ` — correlation ${r.correlation}` : ""}`];
  if (r.chain) {
    // sealSkipped 3상 — undefined는 false가 아니다. 진입 게이트 거부(브랜치·더티 트리·비-canonical
    // remote)는 chain={mode:"chain"}만 돌려주므로 seal이 **돌지 않았다**. 2상 렌더는 그 자리를
    // "seal 실행"으로 보고했다(shell-5 실측 — 거부인데 실행됐다고 말한다).
    const seal = r.chain.sealSkipped === true ? "재봉인 생략(--no-seal)"
      : r.chain.sealSkipped === false ? "seal 실행"
        : "seal 미도달(선행 조건 거부)";
    lines.push(r.chain.mode === "chain"
      ? `연쇄: 앱 레포 안 — ${seal} · ${r.chain.pushed === true ? "봉인본 갱신 커밋 push됨" : r.chain.pushed === false ? "커밋 없음" : "선행 조건 단계"}${r.chain.headSha ? ` · HEAD ${String(r.chain.headSha).slice(0, 7)}` : ""}`
      : "연쇄: 앱 레포 밖 — 디스패치만");
  }
  if (r.run?.url) lines.push(`run: ${r.run.url}${r.run.conclusion ? ` (${r.run.conclusion})` : ""}${r.run.failedJobs ? ` · 실패 잡: ${r.run.failedJobs.join(", ")}` : ""}`);
  if (r.pr?.url) lines.push(`PR: ${r.pr.url} · merged ${OX[String(r.pr.merged)]}${r.pr.mergeSha ? ` · merge SHA ${r.pr.mergeSha}` : ""}`);
  if (Array.isArray(r.applications)) {
    for (const a of r.applications) {
      if (a.error) lines.push(`Application ${a.name}: 조회 실패 — ${a.error}`);
      // teardown(absence): 존재/부재 판정 — sync/health가 아니라 present 필드를 쓴다.
      else if (a.present !== undefined) lines.push(`Application ${a.name}: ${a.present ? "아직 존재 — prune 진행 중" : "부재 — prune 완료"}`);
      // rev: 확정 리비전 하나 · revisions: 멀티소스 skew/비-SHA(미확정 — 관측 원본 그대로) · "-": 관측 0.
      else lines.push(`Application ${a.name}: sync ${a.sync} · health ${a.health} · rev ${a.revision ?? (Array.isArray(a.revisions) ? `${a.revisions.join(",")}(미확정)` : "-")} · 후손 ${OX[String(a.descendant)]}${a.surfaceOk !== undefined ? ` · 표면 ${OX[String(a.surfaceOk)]}` : ""}`);
    }
  }
  if (r.dnsReclaim) lines.push(`DNS 회수: ${r.dnsReclaim} 소관(이 명령의 관측 대상 아님)`);
  if (envelope.omitted.includes("live")) lines.push("라이브(ArgoCD) 수렴: 생략 — KUBECONFIG 미설정(머지까지만 확인)");
  if (r.pendingReason) lines.push(`대기: ${r.pendingReason}`);
  if (r.error) lines.push(`오류: ${r.error}`);
  lines.push(`결과: ${envelope.variant}`);
  return lines;
}

export function renderInit(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  const lines = [`app init ${r.app} — 아키타입 ${r.archetype} · ${r.public ? "public" : "private"} · repo ${r.repo}`];
  if (r.error) {
    lines.push(`체크포인트: ${r.checkpoint ?? "?"}`);
    lines.push(`오류: ${r.error}`);
  } else {
    const st: string[] = [];
    if (r.created) st.push("레포 생성");
    if (r.adopted) st.push("입양");
    if (r.scaffolded) st.push("스캐폴드");
    if (r.pushed) st.push("첫 push");
    lines.push(`단계: ${st.length ? st.join(" · ") : "변경 없음(이미 완료)"}`);
  }
  if (r.secrets) lines.push(`디스패치 시크릿: App ID ${OX[String(r.secrets.appId)]} · private key ${OX[String(r.secrets.privateKey)]}`);
  lines.push(`결과: ${envelope.variant}`);
  return lines;
}

// url 동사 공용 렌더러 — 값은 결과에 존재하지 않으므로(비출력 계약) 계획/기록 보고만 그린다.
export function renderUrl(envelope: Envelope): string[] {
  const r = envelope.result as { mode?: string; secretRef?: string; envKey?: string; envFile?: string; note?: string; dryRun?: boolean; error?: string };
  if (typeof r.error === "string") return [`오류: ${r.error}`];
  if (r.dryRun === true) {
    return [`계획: mode=${r.mode} · secretRef=${r.secretRef} · envKey=${r.envKey} · envFile=${r.envFile}`, ...(r.note ? [r.note] : [])];
  }
  if (envelope.variant === "skip") return [`생략: ${r.note ?? "사유 미기록"}`, `결과: ${envelope.variant}`];
  return [`${r.envFile}에 ${r.envKey} 기록(mode=${r.mode}) — 값은 출력하지 않음`];
}

// verb → 렌더러. 셸 어댑터도 골든 스윕도 이 한 지점을 지난다 — 테스트 전용 우회로가 없어야
// 스윕이 프로덕션 경로를 증명한다. 미지 verb는 조용히 접지 않고 throw(계약 파손).
export function renderFor(envelope: Envelope): string[] {
  switch (envelope.verb) {
    case "doctor": return renderDoctor(envelope);
    case "status": return renderStatus(envelope);
    case "db url":
    case "cache url": return renderUrl(envelope);
    case "app init": return renderInit(envelope);
    case "db create":
    case "cache create":
    case "app create":
    case "app secrets":
    case "app teardown": return renderMutation(envelope);
    default: throw new Error(`계약 파손: 동사 '${envelope.verb}'의 사람용 렌더러가 없다`);
  }
}
