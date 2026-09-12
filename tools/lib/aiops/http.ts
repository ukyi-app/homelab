import { requireCondition } from "./input.ts";

export class JsonApi {
  readonly base: URL;
  private deadline: number;
  private headers: Record<string, string>;
  constructor(base: string, headers: Record<string, string>, allowedOrigin: string, replay: boolean, milliseconds = 120_000) {
    this.base = new URL(base);
    requireCondition(this.base.origin === allowedOrigin || replay && this.base.protocol === "http:" && this.base.hostname === "127.0.0.1", "api-origin-not-allowed");
    requireCondition(!this.base.username && !this.base.password && !this.base.search && !this.base.hash, "invalid-api-base");
    this.headers = headers; this.deadline = Date.now() + milliseconds;
  }
  async request(path: string, options?: { method?: "GET" | "POST" | "PATCH"; body?: unknown; limit?: number }): Promise<unknown> {
    const url = new URL(path, this.base);
    requireCondition(url.origin === this.base.origin && url.pathname.startsWith(this.base.pathname), "api-path-escaped");
    const remaining = this.deadline - Date.now();
    requireCondition(remaining > 0, "api-stage-timeout");
    const response = await fetch(url, { method: options?.method ?? "GET", headers: { ...this.headers, "Content-Type": "application/json" },
      body: options?.body === undefined ? undefined : JSON.stringify(options.body), redirect: "error", signal: AbortSignal.timeout(Math.min(10_000, remaining)) });
    requireCondition(response.ok, `api-http-${response.status}`);
    requireCondition(response.body, "api-empty-body");
    const reader = response.body.getReader(), chunks: Uint8Array[] = [];
    let bytes = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read(); if (done) break;
        bytes += value.length;
        requireCondition(bytes <= (options?.limit ?? 2 * 1024 * 1024), "api-output-limit");
        chunks.push(value);
      }
    } finally { await reader.cancel(); }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  }
  async archive(path: string): Promise<Buffer> {
    const url = new URL(path, this.base);
    requireCondition(url.origin === this.base.origin && url.pathname.startsWith(this.base.pathname), "archive-path-escaped");
    const remaining = this.deadline - Date.now(); requireCondition(remaining > 0, "api-stage-timeout");
    const signal = AbortSignal.timeout(Math.min(10_000, remaining));
    let response = await fetch(url, { headers: this.headers, redirect: "manual", signal });
    if (response.status === 302) {
      const location = response.headers.get("location"); requireCondition(location, "archive-location-missing");
      const destination = new URL(location);
      requireCondition(destination.protocol === "https:" && (destination.hostname.endsWith(".blob.core.windows.net") || destination.hostname.endsWith(".actions.githubusercontent.com")), "archive-origin-not-allowed");
      // GitHub 자격은 서명된 보관소 URL로 전달하지 않는다.
      response = await fetch(destination, { redirect: "error", signal });
    }
    requireCondition(response.ok && response.body, `archive-http-${response.status}`);
    const reader = response.body.getReader(), chunks: Uint8Array[] = [];
    let bytes = 0;
    try {
      for (;;) { const { done, value } = await reader.read(); if (done) break; bytes += value.length; requireCondition(bytes <= 4 * 1024 * 1024, "archive-size-limit"); chunks.push(value); }
    } finally { await reader.cancel(); }
    return Buffer.concat(chunks);
  }
}
