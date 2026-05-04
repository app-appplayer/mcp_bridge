# mcp_bridge — Design Document Set

Workspace-internal design documents for the `mcp_bridge` improvement program. Per `Product document guide.md`, software-only package layout; HW / firmware / cert / manufacturing / manual sections omitted.

## Layout

```
docs/
├── 00_PLAN/
│   └── PRD.md                  ← Product Requirements (vision · goals · scope · risks)
├── 01_SRS/
│   └── SRS.md                  ← Software Requirements (FR1–FR5 + NFRs + traceability)
├── 02_SDD/
│   └── SDD.md                  ← System Design (modules · sequences · phase mapping)
├── 03_DDD/
│   ├── core-bridge.md          ← McpBridge orchestrator + transport selection
│   ├── core-transport.md       ← Built-in transport contracts + per-transport detail
│   ├── core-router.md          ← MessageRouter forwarding logic
│   ├── core-lifecycle.md       ← Inline lifecycle in McpBridge
│   └── core-config.md          ← McpBridgeConfig
├── 04_TEST/
│   └── TEST.md                 ← Test pyramid · phase coverage · CI
├── 05_QA/
│   └── QA-PLAN.md              ← Quality gates · defect classes · release criteria
└── 50_CHANGELOG/
    └── CHANGELOG.md            ← Workspace mirror (planned + published)
```

## Reading Order

For a new contributor:

1. `00_PLAN/PRD.md` — why we're improving the package (vision, pain, scope).
2. `01_SRS/SRS.md` — what the package must do (FR1–FR5).
3. `02_SDD/SDD.md` — how the package is structured (modules, sequences).
4. `03_DDD/*` — per-module detail.
5. `04_TEST/TEST.md` — how we verify it.
6. `05_QA/QA-PLAN.md` — how we ship it.

## Truth Chain

Per `DOC_IMPROVEMENT_GUIDE.md` §1.1:

```
PRD       ← intent (00_PLAN)
 └→ SRS   ← functional requirements (01_SRS, traces to PRD G1–G5)
    └→ SDD ← architecture (02_SDD, traces to SRS FR1–FR5)
       └→ DDD ← module detail (03_DDD/*, traces to SDD §2.x)
          └→ TEST ← coverage (04_TEST, traces to DDD test hooks)
                └→ QA ← gates and release criteria (05_QA)
```

Inconsistencies are resolved upward: SDD must mirror SRS, DDD must mirror SDD, etc.

## Status

All docs are **Draft**. They reflect the proposed improvement program at 2026-05-04. Release status — what has shipped to pub.dev, what is planned next — lives in `50_CHANGELOG/CHANGELOG.md`.

## Runnable Reference

A CLI smoke harness lives at `dart/example/mcp_bridge_example.dart` — exercises every public surface (config, the four callbacks, auto-reconnect, shutdown) across `stdio` / `sse` combinations. Used as the manual end-to-end sanity check before release. See `04_TEST/TEST.md` §2.4.
