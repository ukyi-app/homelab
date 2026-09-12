import { join, resolve } from "node:path";
import { readBounded, record, requireCondition, observationInput } from "./input.ts";
import { digest } from "./git.ts";

// 정답 파일은 Git 사본 밖에 둔다. 키워드 검사는 수동 품질 리뷰를 위한 신호일 뿐이다.
export function evaluateCases(casesPath: string, answersPath: string, reportsDirectory: string) {
  const casesText = readBounded(casesPath, 1024 * 1024), answersText = readBounded(answersPath, 1024 * 1024);
  const value = record(JSON.parse(casesText)), answers = record(record(JSON.parse(answersText)).answers);
  requireCondition(Array.isArray(value.cases) && value.cases.length >= 12, "evaluation-cases-incomplete");
  const cases = value.cases.map(record), ids = cases.map(item => String(item.id));
  requireCondition(ids.every(id => /^[a-z0-9-]+$/.test(id)) && new Set(ids).size === ids.length, "evaluation-case-id-invalid");
  const sources = [...new Set(cases.map(item => observationInput(item.observation).source))].sort();
  requireCondition(sources.length === 5, "evaluation-source-coverage-incomplete");
  const results = cases.map(item => {
    let report: Record<string, unknown>;
    try { const value = record(JSON.parse(readBounded(join(resolve(reportsDirectory), `${item.id}.json`), 2 * 1024 * 1024))); report = record(value.report ?? record(value.incident ?? {}).report ?? value); }
    catch { return { id: item.id, status: "missing-report", simulated: false }; }
    const answer = answers[String(item.id)];
    if (!answer) return { id: item.id, status: "missing-reference", simulated: report.simulated === true };
    const reference = record(answer), diagnosis = record(report.diagnosis ?? {});
    const text = JSON.stringify({ summary: diagnosis.summary, causes: diagnosis.causes }).toLowerCase();
    const expected = Array.isArray(reference.keywords) ? reference.keywords : [];
    const outcome = diagnosis.outcome === reference.outcome, keyword = expected.length === 0 || expected.some(word => typeof word === "string" && text.includes(word.toLowerCase()));
    const allowedIds = new Set((record(item.evidence).items as { id: string }[]).map(e => e.id));
    const causes = Array.isArray(diagnosis.causes) ? diagnosis.causes.map(record) : [];
    const grounded = causes.every(cause => Array.isArray(cause.evidenceIds) && cause.evidenceIds.length > 0 && cause.evidenceIds.every(id => allowedIds.has(String(id))));
    return { id: item.id, status: outcome && keyword && grounded ? "review-required" : "reference-mismatch", simulated: report.simulated === true };
  });
  return { cases: cases.length, sources, casesHash: digest(casesText), answersHash: digest(answersText), results, missingReports: results.filter(r => r.status === "missing-report").length,
    quality: results.every(r => r.status === "review-required" && !r.simulated) ? "human-review-required" : "unverified", boundaryOnly: results.some(r => r.simulated) };
}
