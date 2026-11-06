// values YAML 편집. 사람이 쓴 주석이 있는 파일이라 다시 직렬화하지 않고, 바꿀 최상위 키 블록만
// 한 줄 flow 꼴(`uses: { postgres: true }`)로 바꾸거나 지우거나 끝에 더한다(setTopLevel). 맵 블록 안의 키 한 줄만 고칠 수도 있다
// (setMapString). 다른 줄과 주석은 그대로 둔다.
// 결과를 다시 parse해 "원래 객체 + 편집"과 다르면 던진다(블록 경계를 잘못 읽었거나 직렬화가 틀린 경우의 그물).
// 명령이 import할 수 있는 core 모듈이다(정적 시험의 허용 목록).
import { isArray, jsonStringify } from "./intrinsics";
import { isSecret } from "./secret";

const KEY = /^[A-Za-z_][A-Za-z0-9_-]*$/;
const TOP_KEY = /^([A-Za-z_][A-Za-z0-9_-]*):(?=\s|$)/;
// 따옴표 없이 써도 문자열로 읽히는 꼴. 예약어·숫자처럼 보이는 것은 뺀다(YAML 1.1·1.2 둘 다에서 문자열이 아닐 수 있다).
const PLAIN = /^[A-Za-z][A-Za-z0-9._/-]*$/;
const RESERVED = /^(true|false|null|yes|no|on|off|y|n|~|nan|inf)$/i;

export function parseYaml(text: string): unknown {
  return Bun.YAML.parse(text);
}

// chartVersion 같은 semver(점 둘)는 YAML에서 수가 아니라 문자열이다. 사람이 쓴 꼴(chartVersion: 1.1.0)을 지킨다.
const SEMVER = /^[0-9]+\.[0-9]+\.[0-9]+$/;

function scalar(v: string): string {
  return (PLAIN.test(v) && !RESERVED.test(v)) || SEMVER.test(v) ? v : jsonStringify(v);
}

// 한 줄 flow 꼴. JSON 문자열 이스케이프는 YAML 큰따옴표 문자열과 같다.
export function flow(v: unknown): string {
  if (v === null) return "null";
  if (typeof v === "boolean") return String(v);
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error("values: 유한한 수만 쓴다");
    return String(v);
  }
  if (typeof v === "string") return scalar(v);
  if (isSecret(v)) throw new Error("values: 시크릿 객체는 저장소 파일에 넣지 않는다");
  if (isArray(v)) return `[${v.map(flow).join(", ")}]`;
  if (typeof v === "object") {
    const parts = Object.entries(v as Record<string, unknown>).map(([k, x]) => {
      if (x === undefined) throw new Error("values: 값이 undefined인 키가 있다");
      return `${KEY.test(k) && !RESERVED.test(k) ? k : jsonStringify(k)}: ${flow(x)}`;
    });
    return parts.length ? `{ ${parts.join(", ")} }` : "{}";
  }
  throw new Error("values: 쓸 수 없는 값이다");
}

// 키를 정렬한 JSON. 객체 키 순서와 무관하게 같은지 본다.
function canonical(v: unknown): string {
  const sort = (x: unknown): unknown => {
    if (isArray(x)) return x.map(sort);
    if (x && typeof x === "object") return Object.fromEntries(Object.keys(x as object).sort().map((k) => [k, sort((x as Record<string, unknown>)[k])]));
    return x;
  };
  return jsonStringify(sort(v));
}

function asObject(parsed: unknown): Record<string, unknown> {
  if (parsed === null || parsed === undefined) return {};
  if (typeof parsed !== "object" || isArray(parsed)) throw new Error("values: 최상위가 매핑이 아니다");
  return parsed as Record<string, unknown>;
}

// 최상위 키의 블록 [시작, 끝) 줄 번호. 블록은 키 줄과, 뒤따르는 들여쓴 줄·`-` 줄(그 사이 빈 줄 포함)이다.
// 0열 주석·빈 줄 뒤 0열 줄은 다음 키의 몫이다.
function blocks(lines: string[]): Map<string, [number, number]> {
  const out = new Map<string, [number, number]>();
  for (let i = 0; i < lines.length; i++) {
    const m = TOP_KEY.exec(lines[i]);
    if (!m) continue;
    let end = i + 1;
    let j = i + 1;
    while (j < lines.length) {
      const l = lines[j];
      if (/^[ \t]/.test(l) || /^-(\s|$)/.test(l)) end = j + 1;
      else if (l.trim() !== "") break;
      j++;
    }
    if (out.has(m[1])) throw new Error(`values: 최상위 키 ${m[1]}가 두 번 있다`);
    out.set(m[1], [i, end]);
  }
  return out;
}

// edits의 키를 바꾼다. 값이 undefined면 지운다. 바뀐 원문을 돌려준다.
export function setTopLevel(text: string, edits: Record<string, unknown>): string {
  if (/^(---|\.\.\.)(\s|$)/m.test(text.replace(/^---\s*\n/, ""))) throw new Error("values: 여러 문서 YAML은 고치지 않는다");
  const original = asObject(parseYaml(text));
  const lines = text.split("\n");
  const found = blocks(lines);
  const replaced = new Map<number, string | null>();
  const appended: string[] = [];
  for (const [key, value] of Object.entries(edits)) {
    if (!KEY.test(key)) throw new Error(`values: 최상위 키 이름 형식이 아니다: ${jsonStringify(key)}`);
    const b = found.get(key);
    if (Object.hasOwn(original, key) && !b) throw new Error(`values: ${key} 블록을 찾지 못했다(따옴표 키·flow 문서는 고치지 않는다)`);
    const line = value === undefined ? null : `${key}: ${flow(value)}`;
    if (b) {
      replaced.set(b[0], line);
      for (let k = b[0] + 1; k < b[1]; k++) replaced.set(k, null);
    } else if (line !== null) appended.push(line);
  }
  const kept = lines.flatMap((l, i) => (replaced.has(i) ? (replaced.get(i) === null ? [] : [replaced.get(i) as string]) : [l]));
  // 끝 줄바꿈을 지킨다. 더할 줄은 마지막 내용 뒤에.
  while (kept.length > 0 && kept[kept.length - 1] === "") kept.pop();
  const out = `${[...kept, ...appended].join("\n")}\n`;

  const want: Record<string, unknown> = { ...original };
  for (const [k, v] of Object.entries(edits)) {
    if (v === undefined) delete want[k];
    else want[k] = v;
  }
  if (canonical(asObject(parseYaml(out))) !== canonical(want)) throw new Error("values: 고친 결과를 다시 읽은 값이 기대와 다르다(파일을 고치지 않았다)");
  return out;
}

// 최상위 맵 안의 문자열 키 하나만 고치거나 더한다. setTopLevel은 블록 전체를 한 줄 flow로 다시 써 안쪽 주석을 지우므로,
// 사람이 주석을 단 블록(env 등)은 이 함수로 그 줄만 바꾼다. 없던 키는 블록 끝에 더한다.
// 값은 늘 큰따옴표로 쓴다. 숫자처럼 보이는 값이 수로 읽히면 차트 schema(env 값은 문자열만)가 거부한다.
export function setMapString(text: string, parent: string, key: string, value: string): string {
  if (isSecret(value)) throw new Error("values: 시크릿 객체는 저장소 파일에 넣지 않는다");
  if (typeof value !== "string") throw new Error("values: 문자열만 쓴다");
  if (!KEY.test(key)) throw new Error(`values: 키 이름 형식이 아니다: ${jsonStringify(key)}`);
  if (/^(---|\.\.\.)(\s|$)/m.test(text.replace(/^---\s*\n/, ""))) throw new Error("values: 여러 문서 YAML은 고치지 않는다");
  const original = asObject(parseYaml(text));
  const map = original[parent];
  if (map === null || typeof map !== "object" || isArray(map)) throw new Error(`values: ${parent}가 맵이 아니다`);
  if ((map as Record<string, unknown>)[key] === value) return text;
  const merged = { ...(map as Record<string, unknown>), [key]: value };
  const lines = text.split("\n");
  const b = blocks(lines).get(parent);
  if (!b) throw new Error(`values: ${parent} 블록을 찾지 못했다(따옴표 키·flow 문서는 고치지 않는다)`);
  // 한 줄 flow 블록은 안쪽 주석이 없다.
  if (b[1] - b[0] === 1) return setTopLevel(text, { [parent]: merged });

  const child = lines.slice(b[0] + 1, b[1]).find((l) => l.trim() !== "" && !l.trimStart().startsWith("#"));
  const indent = /^ +/.exec(child ?? "")?.[0];
  if (!indent) throw new Error(`values: ${parent} 블록의 들여쓰기를 읽지 못했다`);
  const line = `${indent}${key}: ${jsonStringify(value)}`;
  const at = lines.findIndex((l, i) => i > b[0] && i < b[1] && l.startsWith(`${indent}${key}:`));
  if (at >= 0) lines[at] = line;
  else lines.splice(b[1], 0, line);
  const out = lines.join("\n");
  if (canonical(asObject(parseYaml(out))) !== canonical({ ...original, [parent]: merged })) throw new Error("values: 고친 결과를 다시 읽은 값이 기대와 다르다(파일을 고치지 않았다)");
  return out;
}
