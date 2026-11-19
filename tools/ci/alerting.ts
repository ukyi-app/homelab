// 관측 스택의 경보 검사(설계 C.3.7, U11). 룰 단위 시험(vmalert-tool), 룰마다 발화 시험이 있는지, Alertmanager 설정.
// 도구는 PATH에서 찾는다: vmalert-tool-prod(vmutils), amtool(alertmanager). 로컬은 mise install, CI는 ci.yaml이 깐다.
import { basename, dirname, join } from "node:path";
import { type Violation, ROOT, gitFiles, parseAll, readText, run } from "./lib";
import { OLIVE_TARGETS_FILE, readOliveTargets, targetList } from "./olive";

const STACK = "platform/observability/stack";
const RULES = `${STACK}/vmalert/rules`;
const TESTS = `${STACK}/vmalert/tests`;
const AM_CONFIG = `${STACK}/alertmanager/alertmanager.yml`;
// Telegram은 "nuc-dns-outage.md" 같은 상대 경로를 .md(몰도바) 도메인으로 자동 링크한다(라이브 실측). 그래서 전체 URL만 받는다.
const RUNBOOK_BASE = "https://github.com/ukyi-app/homelab/blob/main/";

const OLIVE_RULE_FILE = `${RULES}/olive.yaml`;
const OLIVE_ALERT_FIXTURES = "tools/ci/fixtures/alerting/*.yaml";
const OLIVE_MARKER_LABEL = "annotation_homelab_ukyi_app_olive_started";
const OLIVE_LOCK_NAME = "olive-stop";
const OLIVE_LOCK_OWNER_LABEL = "label_homelab_ukyi_app_olive_stop";
const OLIVE_LOCK_OWNER_VALUE = "lock";

type Rule = { alert?: string; record?: string; expr?: string; labels?: Record<string, string>; annotations?: { runbook?: string } };
type RuleFile = { groups?: { name: string; labels?: Record<string, string>; rules?: Rule[] }[] };
type TestFile = { rule_files?: string[]; tests?: { alert_rule_test?: { alertname: string; exp_alerts?: unknown[] }[] }[] };
type Matcher = { op: string; value: string };

// 연산자까지 읽는다. =~가 =로 바뀌면 값은 같아 보여도 실제 파드 이름에 맞지 않아 경보가 조용해진다.
function selectors(expr: string, metric: string): Record<string, Matcher>[] {
  return [...expr.matchAll(new RegExp(`\\b${metric}\\{([^}]*)\\}`, "g"))].map((m) => Object.fromEntries([...m[1].matchAll(/([a-zA-Z_]+)(=~|!~|!=|=)"([^"]*)"/g)].map((l) => [l[1], { op: l[2], value: l[3] }])));
}
const val = (m?: Matcher) => m?.value ?? "";
const is = (m: Matcher | undefined, op: string, value: string) => m?.op === op && m.value === value;

// 경보의 대상과 targets.yaml이 어긋나면 정지·꺼짐을 놓치거나 정지 대상이 아닌 파드로 거짓 경보가 난다.
export function checkOliveAlerts(oliveText: string, rawTargets: unknown, others: { file: string; text: string }[]): Violation[] {
  const out: Violation[] = [];
  const bad = (message: string) => out.push({ rule: "olive-alert-targets", where: OLIVE_RULE_FILE, message });
  const same = (what: string, got: Set<string>, want: Set<string>) => {
    for (const w of want) if (!got.has(w)) bad(`${what}에 ${w}가 빠졌다(${OLIVE_TARGETS_FILE})`);
    for (const g of got) if (!want.has(g)) bad(`${what}의 ${g}가 ${OLIVE_TARGETS_FILE}의 대상이 아니다`);
  };
  const rules = ((parseAll(oliveText)[0] as RuleFile).groups ?? []).flatMap((g) => g.rules ?? []);
  const expr = (name: string) => {
    const r = rules.find((x) => x.alert === name);
    if (!r) bad(`경보 ${name}가 없다`);
    return r?.expr ?? "";
  };
  for (const r of rules) if (r.alert && r.labels?.olive_self !== "true") bad(`${r.alert}에 olive_self: "true" 라벨이 없다. 봇 receiver로 샌다`);
  for (const o of others) {
    for (const g of (parseAll(o.text)[0] as RuleFile).groups ?? []) {
      // vmalert는 그룹 공통 라벨을 규칙마다 합친다. 그룹에 달아도 그 경보들이 봇 receiver를 건너뛴다.
      if (g.labels?.olive_self !== undefined) out.push({ rule: "olive-alert-targets", where: o.file, message: `규칙 그룹 ${g.name}의 공통 olive_self 라벨은 쓸 수 없다. ${OLIVE_RULE_FILE}의 경보만 단다` });
      for (const r of g.rules ?? []) if (r.labels?.olive_self !== undefined) out.push({ rule: "olive-alert-targets", where: o.file, message: `${r.alert}의 olive_self 라벨은 ${OLIVE_RULE_FILE}의 경보만 단다` });
    }
  }

  const targets = targetList(rawTargets);
  const pair = (t: { namespace: string; deployment: string }) => `${t.namespace}/${t.deployment}`;
  const startable = targets.filter((t) => t.start === true);
  const stoppable = targets.filter((t) => t.stop === true);

  const down = expr("OliveDownWhileEnabled");
  const ready = selectors(down, "kube_deployment_status_replicas_ready");
  same("OliveDownWhileEnabled의 켤 수 있는 대상", new Set(ready.map((s) => `${val(s.namespace)}/${val(s.deployment)}`)), new Set(startable.map(pair)));
  for (const s of ready) if (s.namespace?.op !== "=" || s.deployment?.op !== "=") bad(`OliveDownWhileEnabled의 ${val(s.namespace)} 선택자는 네임스페이스와 Deployment를 =로 맞춰야 한다`);
  const markers = selectors(down, "kube_namespace_annotations");
  same("OliveDownWhileEnabled의 표식 네임스페이스", new Set(markers.map((s) => val(s.namespace))), new Set(startable.map((t) => t.namespace)));
  for (const m of markers) {
    if (!is(m[OLIVE_MARKER_LABEL], "=", "true")) bad(`OliveDownWhileEnabled의 표식 선택자(${val(m.namespace)})는 ${OLIVE_MARKER_LABEL}="true"까지 맞춰야 한다`);
    if (m.namespace?.op !== "=") bad(`OliveDownWhileEnabled의 표식 선택자(${val(m.namespace)})는 네임스페이스를 =로 맞춰야 한다`);
  }

  const pods = selectors(expr("OlivePodsUpWhileStopped"), "kube_pod_info");
  for (const p of pods) {
    if (val(p.created_by_kind) !== "ReplicaSet" || !/^.+-\[a-z0-9\]\+$/.test(val(p.created_by_name))) bad(`OlivePodsUpWhileStopped의 ${val(p.namespace)} 선택자는 ReplicaSet과 <Deployment>-[a-z0-9]+로 골라야 한다`);
    if (p.namespace?.op !== "=" || p.created_by_kind?.op !== "=" || p.created_by_name?.op !== "=~") bad(`OlivePodsUpWhileStopped의 ${val(p.namespace)} 선택자는 namespace·created_by_kind를 =로, created_by_name을 =~로 맞춰야 한다`);
  }
  same("OlivePodsUpWhileStopped의 정지 대상", new Set(pods.map((p) => `${val(p.namespace)}/${val(p.created_by_name).replace(/-\[a-z0-9\]\+$/, "")}`)), new Set(stoppable.map(pair)));

  const locks = selectors(expr("OliveStopEngaged"), "kube_resourcequota").filter((l) => is(l.resource, "=", "pods"));
  same("OliveStopEngaged의 네임스페이스", new Set(locks.flatMap((l) => val(l.namespace).split("|"))), new Set(stoppable.map((t) => t.namespace)));
  for (const l of locks) if (l.namespace?.op !== "=~") bad("OliveStopEngaged의 네임스페이스는 =~로 맞춰야 한다");

  // 세 경보가 자물쇠를 같은 조건으로 봐야 한다. 하나만 넓으면 CLI가 자물쇠로 인정하지 않는 quota가 꺼짐을 가리거나 정지로 알려진다.
  for (const name of ["OliveDownWhileEnabled", "OlivePodsUpWhileStopped", "OliveStopEngaged"]) {
    const e = expr(name);
    if (!selectors(e, "kube_resourcequota").some((s) => is(s.resourcequota, "=", OLIVE_LOCK_NAME) && is(s.resource, "!=", "pods") && is(s.type, "=", "hard"))) bad(`${name}의 자물쇠 판정은 pods 밖의 hard 자원이 있는 quota를 빼야 한다`);
    if (!selectors(e, "kube_resourcequota_labels").some((s) => is(s.resourcequota, "=", OLIVE_LOCK_NAME) && is(s[OLIVE_LOCK_OWNER_LABEL], "!=", OLIVE_LOCK_OWNER_VALUE))) bad(`${name}의 자물쇠 판정은 소유 라벨이 다른 quota를 빼야 한다`);
  }
  return out;
}

// 음성 fixture: 실제 규칙 파일에 replace를 얹거나 other 규칙 파일을 더하면 # match:의 위반이 나야 한다.
function checkOliveAlertFixtures(oliveText: string, rawTargets: unknown): Violation[] {
  const out: Violation[] = [];
  const files = gitFiles(OLIVE_ALERT_FIXTURES);
  if (files.length === 0) out.push({ rule: "fixture", where: OLIVE_ALERT_FIXTURES, message: "음성 fixture가 없다" });
  for (const f of files) {
    const text = readText(f);
    const match = text.match(/^# match: (.+)$/m)?.[1].trim();
    const doc = parseAll(text)[0] as { replace?: { from: string; to: string }[]; other?: string };
    if (!match) {
      out.push({ rule: "fixture", where: f, message: "머리 주석 # match:가 필요하다" });
      continue;
    }
    let mutated = oliveText;
    for (const r of doc.replace ?? []) {
      if (!mutated.includes(r.from)) out.push({ rule: "fixture", where: f, message: `규칙 파일에 없는 문자열이다: ${r.from}` });
      mutated = mutated.replace(r.from, () => r.to);
    }
    const got = checkOliveAlerts(mutated, rawTargets, doc.other ? [{ file: f, text: doc.other }] : []);
    if (!got.some((v) => v.message.includes(match))) out.push({ rule: "fixture", where: f, message: `기대한 위반이 나지 않았다(나온 것: ${got.map((v) => v.message).join(" / ") || "없음"})` });
  }
  return out;
}

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

  const oliveText = readText(OLIVE_RULE_FILE);
  const oliveTargets = readOliveTargets();
  out.push(...checkOliveAlerts(oliveText, oliveTargets, ruleFiles.filter((f) => f !== OLIVE_RULE_FILE).map((f) => ({ file: f, text: readText(f) }))));
  out.push(...checkOliveAlertFixtures(oliveText, oliveTargets));

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
    // 봇 모델 멈춤(봇 C21)은 원인을 Telegram으로만 알린다. 봇 receiver에도 가지만 service 라벨이 없어 봇이 버린다(Discord에 안 감).
    // 종류마다 경보 이름이 다르다. 이 이름·kind 라벨로 Telegram을 빼는 route가 생기면 여기서 막힌다.
    [["alertname=HomelabBotModelPausedRateLimit", "severity=warning", "kind=rate_limit"], "bot,telegram"],
    [["alertname=HomelabBotModelPausedAuthExpired", "severity=warning", "kind=auth_expired"], "bot,telegram"],
    [["alertname=HomelabBotModelPausedBilling", "severity=warning", "kind=billing"], "bot,telegram"],
    [["alertname=Watchdog", "severity=none"], "healthchecks"],
    // 올리브 자신의 경보는 심각도와 상관없이 Telegram으로만 간다. 봇 receiver가 끼면 올리브가 자기 장애 알림을 받는 되먹임이 된다.
    [["alertname=OliveDownWhileEnabled", "severity=warning", "olive_self=true"], "telegram"],
    [["alertname=OlivePodsUpWhileStopped", "severity=critical", "olive_self=true"], "telegram"],
    [["alertname=OliveStopEngaged", "severity=info", "olive_self=true"], "telegram"],
    // 라벨 값이 다르면 올리브 route에 들지 않는다.
    [["alertname=OliveDownWhileEnabled", "severity=warning", "olive_self=false"], "bot,telegram"],
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
