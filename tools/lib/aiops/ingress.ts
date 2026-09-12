import { timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";
import { readBounded, record, requireCondition } from "./input.ts";
import { normalizeProducer } from "./sources.ts";
import type { Incidents } from "./incidents.ts";

export function serveIncidents(incidents: Incidents, input: unknown) {
  const config = record(input), ingress = record(config.ingress), files = record(ingress.tokens);
  requireCondition(typeof ingress.address === "string" && isIP(ingress.address) === 4 && /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)\d/.test(ingress.address), "ingress-must-use-private-address");
  requireCondition(Number.isInteger(ingress.port) && (ingress.port === 21980 || config.mode === "replay" && ingress.address === "127.0.0.1" && ingress.port === 0), "invalid-ingress-port");
  const tokens = new Map<string, Buffer>();
  for (const source of ["alertmanager", "argocd", "cnpg"]) {
    requireCondition(typeof files[source] === "string", "ingress-token-file-missing");
    const token = readBounded(files[source], 1024).trim();
    requireCondition(token.length >= 16 && !/\s/.test(token), "invalid-ingress-token");
    tokens.set(source, Buffer.from(`Bearer ${token}`));
  }
  const server = Bun.serve({
    hostname: ingress.address, port: Number(ingress.port), maxRequestBodySize: 256 * 1024, idleTimeout: 10,
    async fetch(request) {
      const source = /^\/sources\/(alertmanager|argocd|cnpg)$/.exec(new URL(request.url).pathname)?.[1];
      if (request.method !== "POST" || !source) return Response.json({ error: "not-found" }, { status: 404 });
      const supplied = Buffer.from(request.headers.get("authorization") ?? ""), expected = tokens.get(source)!;
      if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return Response.json({ error: "unauthorized" }, { status: 401 });
      try {
        const observations = normalizeProducer(source, await request.json());
        incidents.receive(source, observations);
        return Response.json({ accepted: observations.length });
      } catch {
        return Response.json({ error: "invalid-or-not-persisted" }, { status: 503 });
      }
    },
  });
  return server;
}
