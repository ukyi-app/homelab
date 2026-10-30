// 관측 스택의 경보 검사(설계 C.3.7, U11). 룰 단위 시험(vmalert-tool), 룰마다 발화 시험이 있는지, Alertmanager 설정.
// 도구는 PATH에서 찾는다: vmalert-tool-prod(vmutils), amtool(alertmanager). 로컬은 mise install, CI는 ci.yaml이 깐다.
import { basename, dirname, join } from "node:path";
import { type Violation, ROOT, gitFiles, parseAll, readText, run } from "./lib";

const STACK = "platform/observability/stack";
const RULES = `${STACK}/vmalert/rules`;
const TESTS = `${STACK}/vmalert/tests`;
const AM_CONFIG = `${STACK}/alertmanager/alertmanager.yml`;
// Telegram은 "nuc-dns-outage.md" 같은 상대 경로를 .md(몰도바) 도메인으로 자동 링크한다(라이브 실측). 그래서 전체 URL만 받는다.
const RUNBOOK_BASE = "https://github.com/ukyi-app/homelab/blob/main/";

type RuleFile = { groups?: { name: string; rules?: { alert?: string; record?: string; annotations?: { runbook?: string } }[] }[] };
type TestFile = { rule_files?: string[]; tests?: { alert_rule_test?: { alertname: string; exp_alerts?: unknown[] }[] }[] };

export function checkAlerting(): Violation[] {
  const out: Violation[] = [];
  const ruleFiles = gitFiles(`${RULES}/*.yaml`);
  const testFiles = gitFiles(`${TESTS}/*.test.yaml`);
  if (ruleFiles.length === 0) out.push({ rule: "alert-rules", where: RULES, message: "룰 파일이 0개다(L40)" });
  if (testFiles.length === 0) out.push({ rule: "alert-rules", where: TESTS, message: "단위 시험 파일이 0개다(L40)" });

  // kustomization의 vmalert-rules 목록과 rules/ 파일이 같아야 한다. 빠진 파일은 시험만 통과하고 배포되지 않는다.
  const kust = parseAll(readText(`${STACK}/kustomization.yaml`))[0];
  const listed: string[] = (kust.configMapGenerator ?? []).find((g: { name: string }) => g.name === "vmalert-rules")?.files ?? [];
  const want = ruleFiles.map((f) => f.slice(STACK.length + 1)).sort();
  if (JSON.stringify([...listed].sort()) !== JSON.stringify(want)) {
    out.push({ rule: "alert-rules", where: `${STACK}/kustomization.yaml`, message: `vmalert-rules 목록(${listed.join(", ")})이 ${RULES}의 파일(${want.join(", ")})과 다르다` });
  }

  // 경보 룰마다 발화를 기대하는 시험이 하나 이상 있어야 한다(비어 있지 않은 exp_alerts). 이름이 겹치면 어느 쪽을 시험했는지 모른다.
  const alerts = new Map<string, string>();
  for (const f of ruleFiles) {
    for (const g of (parseAll(readText(f))[0] as RuleFile).groups ?? []) {
      for (const r of g.rules ?? []) {
        if (!r.alert) continue;
        if (alerts.has(r.alert)) out.push({ rule: "alert-rules", where: f, message: `경보 이름 ${r.alert}가 ${alerts.get(r.alert)}에도 있다` });
        alerts.set(r.alert, f);
        const rb = r.annotations?.runbook;
        // gitFiles는 pathspec이라 디렉터리·glob도 여러 파일에 맞는다. 결과가 그 경로 하나여야 파일이다.
        const rbPath = rb?.slice(RUNBOOK_BASE.length);
        if (rb !== undefined && (!rb.startsWith(RUNBOOK_BASE) || JSON.stringify(gitFiles(rbPath!)) !== JSON.stringify([rbPath]))) {
          out.push({ rule: "alert-rules", where: f, message: `경보 ${r.alert}의 runbook(${rb})은 ${RUNBOOK_BASE}로 시작하고 저장소에 있는 파일을 가리켜야 한다` });
        }
      }
    }
  }
  const fired = new Set<string>();
  const testedRuleFiles = new Set<string>();
  for (const f of testFiles) {
    const t = parseAll(readText(f))[0] as TestFile;
    for (const rf of t.rule_files ?? []) testedRuleFiles.add(join(dirname(f), rf));
    for (const tc of t.tests ?? []) for (const a of tc.alert_rule_test ?? []) if ((a.exp_alerts ?? []).length > 0) fired.add(a.alertname);
  }
  for (const [name, f] of alerts) if (!fired.has(name)) out.push({ rule: "alert-rules", where: f, message: `경보 ${name}의 발화 시험이 없다(${TESTS})` });
  for (const f of ruleFiles) if (!testedRuleFiles.has(f)) out.push({ rule: "alert-rules", where: f, message: `어느 시험의 rule_files에도 없다` });

  // 시험 파일의 rule_files는 그 파일 기준 상대 경로라 tests 폴더에서 돌린다.
  const vt = run(["vmalert-tool-prod", "unittest", ...testFiles.flatMap((f) => ["-files", basename(f)])], { cwd: join(ROOT, TESTS) });
  const vtOut = (vt.stdout + vt.stderr).trim();
  if (vtOut) console.log(vtOut);
  if (vt.code !== 0) out.push({ rule: "alert-rules", where: TESTS, message: `vmalert-tool unittest exit ${vt.code}` });

  const am = run(["amtool", "check-config", AM_CONFIG], { cwd: ROOT });
  console.log((am.stdout + am.stderr).trim());
  if (am.code !== 0) out.push({ rule: "alertmanager-config", where: AM_CONFIG, message: `amtool check-config exit ${am.code}` });

  // 라벨별 receiver(설계 C.8, D-10). check-config는 route 결과를 보지 않는다. 봇 route의 continue만 남고 Telegram 형제
  // route가 빠지면 warning·critical이 봇에만 가서, 봇이 멈출 때 아무 데도 안 온다. 기대 순서는 amtool 출력(route 순서) 그대로다.
  const ROUTES: [string[], string][] = [
    [["severity=warning"], "bot,telegram"],
    [["severity=critical"], "bot,telegram"],
    [["severity=info"], "telegram"],
    [["alertname=Watchdog", "severity=none"], "healthchecks"],
  ];
  for (const [labels, want] of ROUTES) {
    const r = run(["amtool", "config", "routes", "test", `--config.file=${AM_CONFIG}`, `--verify.receivers=${want}`, ...labels], { cwd: ROOT });
    if (r.code !== 0) {
      out.push({ rule: "alertmanager-routes", where: AM_CONFIG, message: `${labels.join(" ")}: ${(r.stdout + r.stderr).trim().split("\n")[0]}(기대 ${want})` });
    }
  }

  console.log(`경보 룰 ${alerts.size}개, 시험 파일 ${testFiles.length}개`);
  return out;
}
