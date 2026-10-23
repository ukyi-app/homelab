// 버전 표시와 doctor의 기대 도구 버전. 빌드(cli/build.ts)가 HOMELAB_BUILD를 --define으로 박는다.
// 실행 파일은 저장소 밖에서 돌므로 .tool-versions를 실행 때 읽을 수 없다. 개발 실행(bun cli/src/main.ts)만 저장소 파일을 읽는다.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const VERSION = "0.1.0";

type BuildInfo = { sha: string; dirty: boolean; tools: Record<string, string> };
declare const HOMELAB_BUILD: BuildInfo | undefined;
const BUILD: BuildInfo | null = typeof HOMELAB_BUILD !== "undefined" ? HOMELAB_BUILD : null;

export function versionLine(): string {
  if (!BUILD) return `homelab ${VERSION} (dev)`;
  return `homelab ${VERSION} (${BUILD.sha.slice(0, 12)}${BUILD.dirty ? "-dirty" : ""})`;
}

export function parseToolVersions(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const [tool, version] = t.split(/\s+/);
    if (tool && version) out[tool] = version;
  }
  return out;
}

export function expectedTools(): Record<string, string> {
  if (BUILD) return BUILD.tools;
  return parseToolVersions(readFileSync(join(import.meta.dir, "..", "..", "..", ".tool-versions"), "utf8"));
}
