# edge-audit.md — ctxe-only resolved edges, site-M (2026-09-18)

Question: ctxe's site-M index has ~2.4x more resolved edges than swctx's.
Is that surplus real signal or noise?

## Aggregate numbers (both DBs read directly)

| | swctx `~/.swctx/indexes/a4fc8115d18a/index.db` | ctxe `~/.ctxe/indexes/a4fc8115d18a/index.db` |
|---|---|---|
| files | 444 | 535 |
| chunks | 2,475 | 4,950 active |
| edges total | 51,151 | 50,624 |
| **edges resolved** (dst/target_chunk set) | **15,619** | **37,097** (2.38x) |
| resolved by kind | calls 9,287 · instantiates 3,416 · uses_type 2,762 · implements 144 · imports 10 | calls 16,034 · field_of 12,296 · uses_type 8,089 · imports 456 · implements 218 · extends 4 |

**Diff method.** A ctxe resolved edge is "absent from swctx" when swctx has
*no* edge (resolved or not) from the same source **file** to the same
`dst_name`/`target_name` (loose match, kind ignored — deliberately
conservative). Result: **15,684 of ctxe's 37,097 resolved edges (42%) are
absent**: `field_of` 11,792 (75%), `calls` 2,164 (14%), `uses_type` 1,704
(11%), `imports` 19, `implements` 5. (`field_of` dominates because swctx
emits only calls/imports/implements/instantiates/uses_type — it has no
member-field edge kind; per CTXE_SPEC.md ctxe has 11 edge kinds.)

## Sample classification (n=100, stratified by edge_type, seed 42)

Each sampled edge was judged by reading the src chunk usage lines and the
dst chunk source (scripts: `bench/edge_audit.py`, `bench/edge_classify.py`;
adjudicated verdicts: `bench/edge_sample_verdicts.json`).

| verdict | count | meaning |
|---|---|---|
| **real** | **2** | genuine non-type edge swctx lacks |
| **type_ref** | **38** | legit type/member-kind edge swctx deliberately doesn't extract (28 `field_of` with verified plausible member binding, 8 `uses_type` → `extension String/URL` file convention, 2 `implements` that are really `enum X: String` raw-value) |
| **phantom** | **60** | resolved to a wrong or implausible target |

Phantom breakdown: 43/71 field_of, 10/12 calls, 3/3 imports, 3/11
uses_type, 1/3 implements. Two distinct phantom failure modes:

- **Wrong binding (47)** — the dst chunk declares *a* `name`, but the
  src's `x.name` belongs to a different receiver type. ctxe's resolver
  picks an arbitrary candidate type that merely has the member. Worst on
  generic member names (`id`, `key`, `path`, `status`, `title`) and
  stdlib call names (`map`, `contains`, `append`, `print`).
- **Stale/fabricated src ref (13)** — `target_name` does not appear
  anywhere in the src chunk text (verified both in the DB content and on
  disk, e.g. `level` absent from ContentStore+RepurposeFormatting.swift
  lines 20–118).

## Illustrative examples

| # | verdict | edge | file:line | reasoning |
|---|---|---|---|---|
| 1 | phantom | calls `contains` | src `Sources/SiteM/DashboardService.swift:524` → dst `Sources/SiteM/AuditSustainability+.swift:74` | src calls `snapshots.contains(where:)` — stdlib `Sequence.contains`; dst is an unrelated `func contains(_ url: URL)` URL-prefix matcher on a crawler type |
| 2 | phantom | calls `map` | src `Sources/SiteM/GoogleAuth.swift:185` → dst `Sources/SiteM/Metrics.swift:589` | `.map { URLQueryItem(...) }` stdlib; dst is struct `GA4PropertyMapEnvelope` which merely *has a property named `map`*. Same pattern ×4 (`map` always → this struct) |
| 3 | phantom | calls `append` | src `Sources/SiteM/KeywordSnapshotStore.swift:102` → dst `Sources/SiteM/PageSpeedService.swift:88` | src `all[siteID, default: []].append(entry)` is `Array.append`; dst is `static func append(siteID:mobile:desktop:…)` history-appender — wrong receiver kind entirely |
| 4 | phantom | calls `resolve` | src `plan/sinh_bang_so_sanh.py:20` → dst `Sources/SiteM/EngineLocator.swift:12` | Python `Path(__file__).resolve()` bound to a Swift function — cross-language name collision |
| 5 | phantom | calls `group` | src `engines/p8-core/scripts/p8_link_health.py:205` → dst `artifacts/dod/mutant_L11_dut_day.swift:200` | Python `re.Match.group(0)` bound to a `Section` chunk inside a DoD mutant artifact |
| 6 | phantom | field_of `shared` | src `Sources/SiteM/AutomationCapabilityView.swift:338` → dst `Sources/SiteM/AIVisibilityStore.swift:26` | src literally names the receiver: `AutomationCapabilityService.shared` — yet the edge binds to `AIVisibilityStore.shared`. Even explicit-receiver cases mis-resolve |
| 7 | phantom | field_of `id` | src `Sources/SiteM/DesignStudioStore.swift:339` → dst `Sources/SiteM/AILocalStore.swift:24` (`LocalAgentStatus.id`) | src uses `$0.id == spec.format` (a `DesignFormat`) and `doc.id`; every struct has `id`, ctxe picked an arbitrary one |
| 8 | phantom | field_of `auditAlertsEnabled` | src `Tests/SiteMTests/LocalAutomationTest.swift:263` → dst `Sources/SiteM/NotificationStore.swift:31` | name absent from the src chunk entirely (and from those file lines on disk) — stale or fabricated edge; 13/100 sampled edges show this |
| 9 | phantom | field_of `pages` | src `Sources/SiteM/App+CLI.swift:60` → dst `artifacts/dod/mutant_S2_host_sitemap.swift:54` | src `savedDetail.pages` is `AuditRunDetail.pages` — but resolved to the *mutant-artifact copy* of `AuditRunDetail`, not the canonical `Sources/SiteM/AuditStore.swift:91` decl. ctxe indexes 224 artifact/output files vs swctx's 121, feeding duplicate-decl ambiguity |
| 10 | phantom | imports `re` | src `engines/p8-core/scripts/p8_daily_report.py:680` → dst `engines/p8-core/scripts/p8_ai_visibility.py:1` | `import re` resolved to *another file's* `import argparse` header chunk — stdlib module edges bound to arbitrary import-statement chunks |
| 11 | type_ref | uses_type `String` | src `Sources/SiteM/AutomationCapabilityService.swift:54` → dst `Sources/SiteM/DuongDanDuLieu.swift:32` | convention: all `String` refs resolve to the file holding `extension String`. Defensible, but a deliberately-skipped stdlib-type edge, not code-graph signal |
| 12 | type_ref | field_of `phone` | src `Sources/SiteM/GoogleBusinessStore.swift:647` → dst `Sources/SiteM/GoogleBusinessModels.swift:32` | `loc.phone` where `loc` is a GMB location → `GMBLocation.phone`. Correct member binding in a kind swctx doesn't emit — the strongest "real" flavor of the surplus, still just type metadata |
| 13 | real | calls `invalidStore` | src `outputs/implementation/T18/wip-1400/AssetStore.swift:260` → dst `Sources/SiteM/SchemaMigration.swift:24` | `throw SchemaMigrationError.invalidStore("asset_collections.json", …)` → real enum `case invalidStore`. Correct call resolution swctx lacks |
| 14 | real | calls `readCollections` | src `outputs/implementation/T18/wip-1400/AssetStore.swift:304` → same file :249 | private `readCollections()` call correctly resolved. Both real hits sit in `outputs/` artifact copies, not live sources |

## Verdict on the 2.38x surplus

Mostly noise, in this sample:

- ~75% of the absent-edge mass is `field_of` — an edge kind swctx
  deliberately does not extract. Where it's correctly bound (~40% of the
  sampled field_of), it's real *type metadata* (useful for "who reads
  field x"), not call-graph signal — hence `type_ref`, not `real`.
- 60% of sampled absent edges are phantom resolutions: generic-name
  binding (`x.id`/`x.key`/`.map`/`.contains` → an arbitrary type having
  that member), cross-language collisions, stdlib imports → unrelated
  import chunks, and 13% name-not-in-source at all.
- Extrapolated loosely (per-kind phantom rates): of 15,684 absent edges,
  roughly ~9–10k phantom, ~5.5k type_ref (mostly field_of), and only a
  few hundred genuine call/type edges — concentrated in artifact dirs.

## Caveats

- "Absent" = no swctx edge with same src-file+dst_name (kind-insensitive).
  A stricter (src_file, dst_name, dst_file) match would count more edges
  absent; a kind-aware match would count fewer `uses_type` misses.
- field_of "correct binding" for ~15 of the 28 type_ref verdicts is
  inferred from same-file membership + receiver text (`self.x`,
  `model.y`, `snapshot.z`) rather than full type inference — a few may
  actually be phantom; conversely a couple of "phantom" generic-name
  bindings may coincidentally be the right type.
- Some phantom-looking edges may be stale-vs-current-file artifacts:
  ctxe indexes more artifact/mutant/output files (224 vs 121), so its
  resolver faces more duplicate declarations.
- Edge audit is resolution-quality only; it says nothing about which
  engine's *smaller* edge set hurts downstream tools (find_usages,
  get_impact) — the recall bench measures that separately.
