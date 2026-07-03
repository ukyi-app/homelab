// 동봉 계약(vendored 사본) 드리프트 리컨실러. homelab SSOT ↔ 다운스트림 사본 정규화 diff.
// alert-and-report: 하드 실패 아님 — {drift, errors} JSON 출력, contract-drift.yaml이 telegram 알림.
// 라이브 raw fetch는 이 CLI에서만(게이트 bats는 --self-test 오프라인 유닛만 검증).
import { readFileSync } from "node:fs";

type Norm = "typescript" | "exact";
type Target = { repo: string; ref: string; path: string; normalize: Norm };
type Entry = { source: string; targets: Target[] };
type Manifest = { owner: string; vendored: Entry[] };

// 정규화: exact=CRLF만 통일(그 외 바이트 일치), typescript=공백 + 닫는 괄호/브레이스/대괄호 앞의 trailing ;/, 만 제거.
// ⚠️ 공백-only로는 부족(prettier가 멀티라인 리터럴 마지막 멤버에 trailing ;/, 를 붙임 — 라이브 실측: trip-mate
//    사본이 `out?: string; }` vs SSOT `out?: string }`로 세미콜론 1개만 달랐다). 반대로 ;/, 전면 제거나 "줄끝
//    기준" 제거는 과함/버그다: 전면 제거는 문자열 내부 `join(", ")`↔`join(";")` 실드리프트를 마스킹하고, 줄끝($)
//    기준은 멀티라인의 멤버 세미콜론(줄끝)을 단일라인(mid-line)과 비대칭 제거해 거짓 드리프트를 낸다. 그래서
//    "닫는 구분자 바로 앞" 위치의 trailing 만 제거하고 내부 ;/, 는 보존한다(실식별자/문자열/구분자 드리프트는 검출).
const normalize = (s: string, mode: Norm) =>
  mode === "exact"
    ? s.replace(/\r\n/g, "\n")
    : s.replace(/[;,](?=\s*[)\]}])/g, "").replace(/\s+/g, "");

if (process.argv.includes("--self-test")) {
  const ok =
    // 멀티라인 type 리터럴(prettier) === 단일라인(compact): 닫는 } 앞 trailing ; 흡수 + 공백 무시 (trip-mate 실측 케이스)
    normalize("type A = {\n  a: string;\n  b: string;\n};", "typescript") === normalize("type A = { a: string; b: string };", "typescript") &&
    normalize("[1, 2, 3,]", "typescript") === normalize("[1, 2, 3]", "typescript") &&    // 포매터 trailing , 흡수
    normalize("const a = 1", "typescript") !== normalize("const a = 2", "typescript") && // 실내용 드리프트는 검출
    normalize('a.join(", ")', "typescript") !== normalize('a.join(";")', "typescript") && // 내부 구분자 드리프트는 보존(마스킹 금지)
    normalize("AAAA\r\nBBBB\n", "exact") === "AAAA\nBBBB\n" &&
    normalize("AAAA\nBBBB\n", "exact") !== normalize("AAAAx\nBBBB\n", "exact");
  process.exit(ok ? 0 : 1);
}

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const mf: Manifest = JSON.parse(readFileSync(arg("--manifest", "tools/vendored-contract.json"), "utf8"));
const raw = (o: string, t: Target) => `https://raw.githubusercontent.com/${o}/${t.repo}/${t.ref}/${t.path}`;

const drift: unknown[] = [];
const errors: unknown[] = [];
for (const e of mf.vendored) {
  const src = readFileSync(e.source, "utf8");
  for (const t of e.targets) {
    const url = raw(mf.owner, t);
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
      if (!res.ok) { errors.push({ url, status: res.status }); continue; }
      const remote = await res.text();
      if (normalize(src, t.normalize) !== normalize(remote, t.normalize))
        drift.push({ source: e.source, repo: t.repo, path: t.path });
    } catch (err) { errors.push({ url, error: String(err) }); }
  }
}
process.stdout.write(JSON.stringify({ drift, errors }, null, 2) + "\n");
