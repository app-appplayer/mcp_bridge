# mcp_bridge — QA-PLAN (Quality Assurance Plan)

> Status: Draft
> Last Updated: 2026-05-04
> Source: `01_SRS/SRS.md`, `04_TEST/TEST.md`

---

## 1. Scope

QA strategy for the mcp_bridge improvement program. Defines quality gates, defect classes, and release criteria. Release scheduling — what ships when — lives in `50_CHANGELOG/CHANGELOG.md`.

---

## 2. Quality Gates

Every release SHALL satisfy ALL of the following before `pub publish`:

### 2.1 Code Quality Gates

| Gate | Threshold | Tool |
|------|-----------|------|
| `dart analyze` | 0 errors, 0 warnings | static analyzer |
| Test pass rate | 100% (no skipped/failing) | `dart test` |
| Line coverage | NFR5.2 | `dart test --coverage` |
| Pubspec dry-run | 0 warnings | `flutter pub publish --dry-run` |
| Public API dartdoc | every public symbol documented | `dart doc --validate-links` |
| Sample compiles | 0 issues on `example/` | `dart analyze example/` (smoke that public surface stays runnable) |

### 2.2 Dependency Hygiene Gates

| Gate | Threshold |
|------|-----------|
| Direct dependencies | ≤ 5 (mcp_client, mcp_server, args, logger… or equivalent) |
| Forbidden deps | NO `mcp_io_*`, NO `flutter`, NO transitive pre-2.0 mcp_client/server |
| Dep range pinning | All deps use `^X.Y.Z` ranges (allow patch + minor up); no `*` or unbounded |

### 2.3 Documentation Gates

| Gate | Threshold |
|------|-----------|
| `CHANGELOG.md` | Entry exists for the new version with breaking-change notes |
| `README.md` | Reflects current public API; transport-author guide present once the registry ships |
| Migration notes | Clear migration block in CHANGELOG for every breaking change |
| `docs/00_PLAN/PRD.md` and downstream docs | Reflect any spec changes; cross-references intact |

### 2.4 Release-Process Gates

| Gate | Threshold |
|------|-----------|
| git working tree | Clean (no uncommitted changes) |
| git tag | Created with version-only message (`X.Y.Z`, no `v` prefix, no Claude attribution per workspace policy) |
| Commit message | Version digits only |
| RELEASE_HISTORY | Workspace-level entry added with state and commit hash |

---

## 3. Defect Classification

| Severity | Definition | Resolution SLA |
|----------|------------|----------------|
| **S0 Critical** | Bridge crashes; protocol violation; data corruption; security flaw | Immediate; block release |
| **S1 Major** | Feature broken (specific transport / specific revision fails); workaround exists | Before next release |
| **S2 Minor** | Feature works but non-ideal (verbose log; inefficient path) | Backlog; bundle into next minor |
| **S3 Cosmetic** | Doc typo; lint nit; non-functional improvement | Best-effort; bundle when convenient |

S0 / S1 SHALL be reflected in `CHANGELOG.md` for the release that fixes them. S2 / S3 may be silent.

---

## 4. Track-Specific Quality Focus

(Tracks per `00_PLAN/PRD.md` §4.)

### 4.1 Dependency Modernization

Critical risk: silent breakage from 2.0-wave semantic changes (sampling reverse, etc.). QA emphasis:

- Compatibility tests: reproduce a previously-published usage pattern and verify it works (or fails with a clear migration message) on 2.0-wave deps.
- Protocol revision matrix: verify each of the 4 revisions handles correctly via `flutter_mcp` 2.0's negotiation patterns.
- Regression sweep: every previously-published test runs and passes after the bump.

### 4.2 Transport Set Broadening

Critical risk: a recognised type-name maps to the wrong underlying factory, or config keys aren't passed through correctly to mcp_client / mcp_server.

- One test per type-name × direction confirming the switch reaches the right factory.
- Config-key pass-through verified — `serverConfig` / `clientConfig` map keys arrive intact at the underlying factory.
- `UnknownTransportTypeException` thrown synchronously at `initialize()` for any unrecognised name, with the supported list in the message.
- `streamableHttp` round-trips at least one frame through a loopback bind + connect.
- Confirm the only place a new transport-type name needs to be added is the bridge's switch — no separate interface, registry, or adapter file required.

### 4.3 Bidirectional Forwarding

Critical risk: sampling / roots / elicitation flows incorrectly mapped — server-initiated requests time out or get lost.

- Each server-initiated request type tested independently.
- ID correlation preserved: the originating endpoint sees its own original `id`.
- Notification forwarding: list-changed / cancelled / progress all flow correctly in both directions.

### 4.4 Stability

Critical risk: shipping with an API surface that consumers later complain about.

- API surface review: every public symbol passes a "would I be ok freezing this" check.
- Breaking-change ledger: changes leading into the stability declaration are minimal, all documented.
- Deprecation flow: any pre-stable experimental APIs that didn't pan out are explicitly removed (not left dangling).

---

## 5. Defect Management

- **Tracking**: GitHub issues on the `mcp_bridge` repo, tagged `S0/S1/S2/S3`.
- **Workspace mirror**: `.claude/work/<slug>.md` in the workspace tracks in-flight bridge work; published bugs against shipped versions stay on GitHub only.
- **Triage**: weekly during active development; bi-weekly during stable maintenance.

---

## 6. Release Criteria

A release is READY when ALL of:

- ✅ All Quality Gates (§2) pass.
- ✅ Track-specific quality focus items relevant to the release (§4) pass.
- ✅ No S0 / S1 open defects against the version.
- ✅ `flutter pub publish --dry-run` succeeds with 0 warnings.
- ✅ Test suite green on CI matrix.
- ✅ Workspace `RELEASE_HISTORY.md` Status table updated.
- ✅ Explicit user `pub publish` approval received (per workspace policy memory `feedback_no_publish_without_approval`).

If ANY criterion fails, the release halts. Fix the issue, re-verify all gates from scratch.

---

## 7. Post-Release Verification

After each `pub publish`:

- ✅ Verify pub.dev shows the new version as `latest` within 10 min.
- ✅ Verify `dart pub global activate mcp_bridge` (or equivalent consumer install) succeeds against the new version.
- ✅ Update workspace `RELEASE_HISTORY.md` with the actual published timestamp from pub.dev API.
- ✅ Verify downstream packages (none yet; future external transport siblings) can resolve the new version.

---

## 8. Quality Metrics

Tracked manually per release in CHANGELOG entry footnotes:

| Metric | Target |
|--------|--------|
| Tests added | ≥ 10 per release |
| Tests removed (deflake / consolidate) | tracked but not gated |
| Coverage delta | non-negative |
| Public API symbols added | tracked, listed in CHANGELOG |
| Public API symbols removed (post-stability) | requires major bump |
| Open S1 defects at release | 0 |

---

## 9. Out of Scope

- Performance regression detection — manual benchmarks, no continuous monitoring (defer if real perf concern emerges).
- Multi-platform CI (Windows beyond best-effort) — defer.
- Security audit — bridge has no auth surface; auth lives in `mcp_server` 2.x (RFC 9728 OAuth). External security review is a 2.x concern.
