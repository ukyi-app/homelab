# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists: it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/decisions/`** (이 레포의 ADR 위치 — MADR-lite, append-only): read ADRs that touch the area you're about to work in. 새 ADR은 여기에 쓴다 — 맨 번호 `ADR-NNNN`은 이 시리즈 전용이다.
- **`docs/adr/`** (아키텍처 리뷰의 기각·유보 기록 — decisions와 번호가 독립이다): 같은 후보를 재제안하기 전에 읽는다. 인용은 **항상 경로로**(`docs/adr/0005`).

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo (most repos):

```
/
├── CONTEXT.md
├── docs/decisions/          ← 이 레포의 ADR (README 인덱스 포함) — 맨 번호 ADR-NNNN이 여기다
│   ├── 0001-secret-management-hybrid.md
│   └── ...
├── docs/adr/                ← 아키텍처 리뷰의 기각·유보 기록 (번호 독립 — 항상 경로로 인용)
│   ├── 0001-verb-descriptor-derivation-rejected.md
│   └── ...
└── ...
```

Multi-context repo (presence of `CONTEXT-MAP.md` at the root):

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
