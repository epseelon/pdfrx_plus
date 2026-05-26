<goal>
Bring this fork of `pdfrx` up to date with upstream `espresso3389/pdfrx` at the **`pdfrx-v2.4.1`** tag (resolved 2026-05-26: no `pdfrx-v2.4.2` tag exists in upstream — `pdfrx-v2.4.1` is the highest available `pdfrx-v2.4.x` tag, commit `654fc94`) — and whatever versions of `pdfrx_engine`, `pdfium_flutter`, and `pdfium_dart` are present at that commit — **without regressing** the annotation customizations the fork has accumulated on top of 2.2.24 (pen, highlighter, eraser, stamp manipulation, hand navigation tool, Instant JSON import/export, undo/redo, ownership model).

Upstream uses **per-package tag names** (`pdfrx-vX.Y.Z`, `pdfrx_engine-vX.Y.Z`, `pdfium_flutter-vX.Y.Z`, `pdfium_dart-vX.Y.Z`); there is no single tag that captures "all packages at the 2.4.x release simultaneously." Treat the `pdfrx-v2.4.1` commit as the authoritative merge target; the other packages' versions at that commit are whatever they are.

The fork (`epseelon/pdfrx_plus`) has diverged from upstream over multiple phases of annotation work. We need the latest upstream bug fixes and features (pluggable scroll/zoom architecture, pluggable sizing/layout, native-assets PDFium packaging, `PdfOverlayInteractionRegion`, `underflowAnchor`, text selection fixes) without disturbing the annotation API surface or behavior exported from `packages/pdfrx/lib/pdfrx.dart`.

Outcome: the fork continues to expose the same annotation public API and behavior, internal hooks adapt to upstream's reworked extension points, all existing tests pass, and the music_viewer example exercises every annotation tool successfully.
</goal>

<background>
**Repository:** `/Users/sarbogast/dev/pdfrx_plus` — a Dart/Flutter monorepo, 5 packages defined in workspace `@pubspec.yaml`.

**Current versions (baseline, verified from pubspec files):**
- `pdfrx` 2.2.24 — `@packages/pdfrx/pubspec.yaml` (declares `pdfrx_engine: ^0.3.9`, `pdfium_flutter: ^0.1.8`)
- `pdfrx_engine` 0.3.9 — `@packages/pdfrx_engine/pubspec.yaml` (declares `pdfium_dart: ^0.1.2`)
- `pdfium_flutter` 0.1.9 — `@packages/pdfium_flutter/pubspec.yaml` (declares `pdfium_dart: ^0.1.2`)
- `pdfium_dart` 0.1.3 — `@packages/pdfium_dart/pubspec.yaml`
- `pdfrx_coregraphics` 0.1.16 — `@packages/pdfrx_coregraphics/pubspec.yaml` (declares `pdfrx_engine: ^0.3.9`)

**Target versions:**
- `pdfrx`: whatever the merge target tag declares — `pdfrx-v2.4.1` resolves to commit `654fc94` "Prepare pdfrx 2.4.1 release"; expect `2.4.1` (no `pdfrx-v2.4.2` exists in upstream)
- `pdfrx_engine`, `pdfium_flutter`, `pdfium_dart`: whatever versions are present at the chosen `pdfrx` tag commit (expected `pdfrx_engine 0.4.x`, `pdfium_flutter 0.2.x`, `pdfium_dart 0.2.x` per upstream changelog research, but verify against the actual merged pubspecs)

**Upstream:** `https://github.com/espresso3389/pdfrx` (resolved 2026-05-26: now configured as remote `upstream`). Upstream tags are per-package: `pdfrx-vX.Y.Z`, `pdfrx_engine-vX.Y.Z`, `pdfium_flutter-vX.Y.Z`, `pdfium_dart-vX.Y.Z`. There is no single tag for "the 2.4.x release of everything"; merge target is the `pdfrx-v2.4.1` commit (`pdfrx-v2.4.2` never tagged), accepting whatever state the other packages are in at that commit.

**This is a private fork.** The fork retains upstream `homepage`/`repository`/`issue_tracker` pubspec metadata pointing to `espresso3389/pdfrx`; it is not published to pub.dev under a different name. CHANGELOG and version bumps in this work are upgrade plumbing, not a release event.

**Fork-specific annotation surface (must not regress):**
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` (~950 lines)
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` (~700 lines)
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart`
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_annotation.dart`
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_definition.dart`
- `@packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` (~600 lines)
- Annotation integration points in `@packages/pdfrx/lib/src/widgets/pdf_viewer.dart` and `@packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart`
- Public exports in `@packages/pdfrx/lib/pdfrx.dart` (12 export lines verified)
- `@packages/pdfrx_engine/lib/src/pdf_annotation.dart`
- Example apps: `@packages/pdfrx/example/music_viewer/lib/` (annotation toolbar, stamp library/picker, storage, color/thickness/eraser popups)

**Fork-specific non-annotation surface (also must not regress — added during initial review):**
- `@packages/pdfrx/lib/src/utils/fixed_overscroll_physics.dart` — fork-only `FixedOverscrollPhysics` class, exported via `lib/pdfrx.dart` and referenced from `pdf_viewer_params.dart`
- Other files under `@packages/pdfrx/lib/src/utils/` (`double_extensions.dart`, `edge_insets_extensions.dart`) — provenance unverified; audit before merge to confirm fork-only vs upstream
- `executables:` block in `@packages/pdfrx/pubspec.yaml` (`remove_wasm_modules`, `remove_darwin_pdfium_modules`) — provenance unverified; preserve unless confirmed obsolete

**Known upstream changes 2.2.24 → 2.4.2 most likely to conflict:**
1. **2.3.0** — pluggable scroll/zoom interaction delegates (touches gesture routing the annotation layer hooks into)
2. **2.3.0** — pluggable sizing/layout delegates (changes page-to-viewport math that annotation coordinates depend on); several `PdfViewerParams` sizing params deprecated
3. **2.3.0 + engine 0.4.0** — PDFium native-assets packaging (build infrastructure rewrite)
4. **2.4.0** — `PdfOverlayInteractionRegion` widget (overlaps with annotation-layer pointer pass-through)
5. **2.4.0** — `PdfViewerParams.underflowAnchor`
6. **2.4.0** — `scaleEnabled: false` now also disables Ctrl+wheel/pointer zoom
7. **2.3.4** — text selection crash fix when `PdfTextSelectionParams.enabled = false`
8. Additive: `PdfViewerController.maxScale`, `goToPosition()`, `PdfFontManager`, WASM `preferRangeAccess`

**Strategy chosen (from clarification):**
- Add `upstream` remote → `git merge` upstream `pdfrx-v2.4.2` (or fallback if absent) → resolve conflicts preserving annotation behavior
- Upgrade all five packages in lockstep (they couple via inter-package version constraints)
- **Minimal opt-in**: do not refactor onto new upstream APIs in this work; record opportunities as follow-ups
- Verification: existing test suite + manual smoke in `music_viewer`
</background>

<user_flows>
This is a maintenance upgrade — the only "user" is a developer (current user) executing the upgrade. The downstream user-facing behavior must remain identical.

**Primary flow (developer):**
1. Confirm working tree is clean (no uncommitted changes); confirm `master` contains all current annotation work (recent commits 52ea2ae, 9b9d0ba, 88ca0bd, 303e6f3, a1048f8 are already on `master`)
2. Switch to `master`; pull latest; then create upgrade branch `chore/upgrade-pdfrx-2.4.2` from `master` (not from a feature branch)
3. Add `upstream` remote, fetch tags
4. Verify the exact tag to merge: list upstream tags matching `pdfrx-v2.4.*` and pick the highest available (target `pdfrx-v2.4.2`; fall back to `pdfrx-v2.4.1` if 2.4.2 was never tagged because upstream's 2.4.2 was doc-only)
5. Merge the chosen tag into the upgrade branch
6. Resolve conflicts file-by-file, preserving annotation behavior and fork-only files (utilities, executables, examples)
7. Reconcile build glue for PDFium native-assets packaging (native platforms only — `pdfium_flutter/{android,darwin,linux,windows}/`); WASM assets in `packages/pdfrx/assets/` are a separate concern
8. Run `flutter pub get` at workspace root; resolve any version-constraint conflicts in example pubspecs
9. Run all tests across all packages; iterate on failures
10. Smoke-test `music_viewer` manually with every annotation tool
11. Commit, push, open PR (single PR preferred; split along package boundaries if diff is too large to review — see Boundaries)

**Behavior preservation flow (end user of the library):**
- Existing consumers of the fork's public API (`PdfAnnotationTool`, `PdfStampDefinition`, `applyAnnotationsFromJson`, `exportAnnotationsAsJson`, `setAnnotationTool`, etc.) see no breaking changes
- Annotation rendering, gesture handling, undo/redo, and Instant JSON round-trip behave identically before and after

**Error / abort flow:**
- If any conflict cannot be mechanically resolved (i.e., requires a design decision about how the annotation layer should compose with new upstream architecture), **stop and surface the conflict for human review** rather than guess
- If post-merge tests reveal regressions that can't be fixed without architectural changes, scope those out as follow-up tickets and document them in the PR
</user_flows>

<requirements>

**Functional:**

1. After the upgrade, `@packages/pdfrx/pubspec.yaml` `version:` matches the merged upstream `pdfrx` package's declared version (expected `2.4.2`; verify against the merged pubspec). Other package versions (`pdfrx_engine`, `pdfium_flutter`, `pdfium_dart`, `pdfrx_coregraphics`) match whatever is declared at the same upstream commit — do not impose specific version expectations beyond "matches upstream at that commit."

2. A new git remote named `upstream` points to `https://github.com/espresso3389/pdfrx.git`. The merge commit references the exact upstream ref used (e.g., `pdfrx-v2.4.2`) in its message.

3. The public API in `@packages/pdfrx/lib/pdfrx.dart` retains every existing export line (12 lines verified at baseline) and they all resolve successfully. Symbols re-exported by those files keep their public names; no fork-added export is dropped. In particular, `src/utils/fixed_overscroll_physics.dart` remains exported.

4. `PdfViewerParams` continues to accept all fork-added annotation parameters (verified at baseline): `annotationRenderingMode`, `onAnnotationsChanged`, `highlighterOpacity`, `stampCategories`, `stampImageBuilder`, `selectedStampInterfaceColor`, `selectedStampPadding`. Their assertions (e.g., `stampImageBuilder` required when `stampCategories` non-null) are preserved. Any fork-only reference to `FixedOverscrollPhysics` from `PdfViewerParams` is preserved.

5. `PdfViewer` continues to instantiate `PdfAnnotationController`, mount `PdfAnnotationLayer` per visible page, and route the controller methods (`enterAnnotationMode`, `exitAnnotationMode`, `setAnnotationTool`, undo/redo, JSON import/export, etc.) through its public controller. The fork's hand-tool pointer routing (commit 9b9d0ba) keeps working: when annotation mode is active and the hand tool selected, pan/zoom navigation continues to function.

6. PDFium native-assets packaging from upstream 2.3.0+ is adopted for **native platforms only** (Android, Darwin = iOS+macOS, Linux, Windows). Each native target builds and loads PDFium correctly through the new mechanism. **Web (WASM) is separate**: the WASM assets in `packages/pdfrx/assets/` (`pdfium.wasm`, `pdfium_worker.js`, `pdfium_client.js`) are updated to whatever upstream ships at the merge commit; verify the Web build still loads PDFium. The fork's `cancel pending renderings` fix (commit a1048f8) is preserved or, if upstream resolved the same issue, the fork-side patch is removed in favor of upstream's fix (document which).

7. Page-to-viewport coordinate math used by `PdfAnnotationLayer` continues to place strokes and stamps correctly under the new pluggable sizing/layout architecture. If the layer's coordinate transforms relied on now-deprecated `PdfViewerParams` sizing fields, they're updated to use the new `sizeDelegateProvider` (Legacy delegate, to preserve current behavior).

8. The annotation layer's pointer routing continues to function under the new pluggable scroll/zoom interaction delegates. If the fork was intercepting gestures via mechanisms that the new architecture replaces, the interception is rewired to the equivalent extension point — without switching to `PdfOverlayInteractionRegion` (that's a follow-up opt-in).

9. `PdfViewerController` retains its annotation-related delegating methods and listenables.

**Error Handling:**

10. If `git ls-remote --tags upstream` shows no `v2.4.2` tag (e.g., upstream uses a different naming scheme), surface the discrepancy and ask for confirmation before proceeding with a different ref.

11. If the working tree is not clean when the upgrade starts, abort and surface the dirty files; do not auto-stash without explicit confirmation.

12. If conflict resolution in any file requires a non-mechanical choice (i.e., the fork's code and the upstream code have both been substantially rewritten in overlapping regions and reconciliation requires a design decision), stop and surface the conflict for human review with the specific file and a summary of both sides.

13. If post-upgrade tests fail in ways that suggest a regression in annotation behavior, do not paper over them by disabling tests; investigate, fix, or scope out (with a clearly documented follow-up ticket in the PR description) — but do not silently skip.

14. Build failures on any platform (Android, iOS, macOS, Linux, Windows, Web) caused by the PDFium native-assets migration must be resolved or explicitly flagged as out-of-scope follow-ups; never commit a known-broken platform.

**Edge Cases:**

15. The fork's `PdfStampAttachment` SHA-256 deduplication and Instant JSON round-trip behavior must survive: a stamp annotation exported and re-imported must produce an identical in-memory representation, byte-for-byte attachment match included.

16. Multi-creator ownership semantics survive: eraser only removes own-creator strokes; foreign-creator stamps render but cannot be selected/moved/deleted; export filters by creator.

17. The fork's recent additions — `selectedStampPadding` (commit 52ea2ae) and the annotation-layer pointer pass-through for hand tool (commit 9b9d0ba) — both continue to work.

**Repository hygiene:**

18. CHANGELOG.md files in each package: accept upstream entries verbatim from the merge; do not add fork-specific entries unless the user explicitly requests publishing. Per `AGENTS.md`, release artifacts (CHANGELOG, version, tags) are not modified outside of publishing — version pin bumps in this work are upgrade plumbing, not a release.

19. Pubspec metadata (`homepage`, `repository`, `issue_tracker`) continues to point at upstream `espresso3389/pdfrx`. Do not change these as part of this work.

20. The `executables:` block in `@packages/pdfrx/pubspec.yaml` is preserved as-is unless the merge removes entries and investigation confirms they were upstream-only and are now obsolete.

21. Each example app's `pubspec.yaml` (`@packages/pdfrx/example/viewer/pubspec.yaml`, `@packages/pdfrx/example/music_viewer/pubspec.yaml`, `@packages/pdfrx/example/pdf_combine/pubspec.yaml`) resolves cleanly under the new constraint set. If `flutter pub get` fails due to constraint conflicts (e.g., transitive deps requiring different versions of `crypto`, `path`, etc.), relax or align the example's constraints with upstream's. Do not add new dependencies.

**Validation:**

22. Every test file under `@packages/pdfrx/test/` and `@packages/pdfrx/example/music_viewer/test/` runs and passes — in particular: `pdf_annotation_controller_test.dart`, `pdf_annotation_layer_painter_test.dart`, `pdf_ink_annotation_test.dart`, `pdf_viewer_controller_annotation_test.dart`, `widgets/annotations/pdf_annotation_controller_stamp_test.dart`, `widgets/annotations/pdf_annotation_controller_stamp_drag_test.dart`, `widgets/annotations/instant_json_stamp_test.dart`, and music_viewer integration tests (`stamp_journey_test.dart`, `stamp_picker_panel_test.dart`, `stamp_library_test.dart`, `stamp_layer_selection_test.dart`, `stamp_layer_cross_page_drag_test.dart`, `stamp_foreign_creator_test.dart`, `annotation_storage_test.dart`, `main_page_annotation_toolbar_test.dart`).

23. Manual smoke in `music_viewer` covers: open PDF, switch to pen → draw stroke → undo/redo → save → reload; switch to highlighter → draw → opacity correct; switch to eraser → erase own strokes; switch to stamp → place stamp → drag → resize via each handle → rotate; switch to hand → pan/zoom while in annotation mode; multi-page navigation while annotating.

24. `flutter analyze` clean across all packages.

</requirements>

<boundaries>

**Edge cases:**

- **Deprecated upstream params**: the fork is still allowed to pass deprecated sizing params on `PdfViewerParams` (they continue to function in 2.4.2 via the Legacy size delegate). Migration to `sizeDelegateProvider` is preferred only where it's needed to make the annotation layer's coordinate math work — not as a sweeping refactor.

- **`scaleEnabled: false` behavior change (2.4.0)**: if any fork code or example relies on Ctrl+wheel still zooming while `scaleEnabled` is false, that path must be re-examined. If used, switch to explicit zoom controls.

- **Tag naming**: upstream may have published 2.4.2 without a `v` prefix, or as a moved branch tip rather than a tag. Verify before merging; document the exact ref used.

- **Empty changelog entries**: upstream changelog entries for 2.2.25 and 2.4.2 are reportedly empty/missing. The actual diff is what counts; rely on `git log upstream/master ^v2.2.24` (or equivalent) for the authoritative list of changes.

- **Native-assets transition**: if the fork has any custom build steps (CMake patches, custom Podspec, custom Gradle tasks) layered on the old packaging, they need to be re-applied or made obsolete by the new packaging. Inspect:
  - `@packages/pdfium_flutter/` build files (Android, iOS, macOS, Linux, Windows)
  - `@packages/pdfrx/` example apps' platform folders
  - Any `tool/`, `scripts/`, or root-level build automation

**Error scenarios:**

- **Merge conflict in annotation files**: extremely unlikely (upstream did not modify `lib/src/widgets/annotations/`), but if it happens, prefer the fork's version and re-examine the surrounding context manually.

- **Merge conflict in `pdf_viewer.dart` / `pdf_viewer_params.dart`**: highly likely. Strategy: take upstream's new structural changes as the base; re-apply the fork's annotation hooks on top; keep diff minimal.

- **PDFium binaries fail to load on a platform**: do not commit until resolved. If unresolvable in this session, surface as a blocker.

- **Flaky tests after upgrade**: distinguish between (a) actual regression caused by the upgrade vs (b) pre-existing flakiness exposed by reordering. Annotate accordingly; do not auto-skip.

**Limits:**

- **Scope is upgrade-only**: no new annotation features, no API surface changes, no opt-in to `PdfOverlayInteractionRegion`/`underflowAnchor`/`PdfFontManager` in this work. Each is logged as a separate follow-up.

- **No upstream contributions**: this work does not push anything back upstream.

- **PR sizing**: single PR is preferred for atomic review. However, this is the fork's first upstream sync and spans three minor-version jumps plus a packaging overhaul — the diff may be too large for practical review. After the post-merge diff is visible, if it's unreviewable, split into stacked PRs along package boundaries (e.g., engine + pdfium_* first, pdfrx + examples second). Make this decision based on actual diff size, not upfront.

</boundaries>

<implementation>

**Files most likely to need conflict resolution / hand editing:**

- `@packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — re-apply annotation controller mounting and layer wiring on top of upstream's new pluggable architecture
- `@packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — re-apply six fork-added annotation parameters alongside upstream's new `underflowAnchor` and deprecated-with-migration sizing params
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — verify page-to-viewport math under new sizing delegate; rewire any gesture interception if upstream changed the interception surface
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — only if it touches viewer internals upstream rewrote
- `@packages/pdfrx/lib/pdfrx.dart` — ensure all fork exports survive

**Files that should accept upstream verbatim (then verify nothing breaks):**

- Native build glue in `@packages/pdfium_flutter/{android,darwin,linux,windows}/` (iOS+macOS share `darwin/` via `sharedDarwinSource: true`) and each example app's platform folders. `pdfium_dart` is pure Dart and has no native build glue.
- `@packages/pdfrx_engine/lib/src/...` core engine files (the fork's only addition here is `pdf_annotation.dart`, which is additive)
- New upstream files (overlay interaction region, size/scroll delegates) — copy in, do not modify
- CHANGELOG.md in each package — accept upstream entries from the merge; do not edit

**Version pins to update (most will come in via the merge; verify after):**

- `@packages/pdfrx/pubspec.yaml` — `version:`, `pdfrx_engine:` constraint, `pdfium_flutter:` constraint
- `@packages/pdfrx_engine/pubspec.yaml` — `version:` and `pdfium_dart:` constraint
- `@packages/pdfium_flutter/pubspec.yaml` — `version:` and `pdfium_dart:` constraint
- `@packages/pdfium_dart/pubspec.yaml` — `version:`
- `@packages/pdfrx_coregraphics/pubspec.yaml` — align with new `pdfrx_engine` constraint
- Three example pubspecs: `@packages/pdfrx/example/viewer/pubspec.yaml`, `@packages/pdfrx/example/music_viewer/pubspec.yaml`, `@packages/pdfrx/example/pdf_combine/pubspec.yaml`
- Pubspec metadata fields (`homepage`, `repository`, `issue_tracker`): leave pointing at upstream

**Patterns to follow:**

- Resolve conflicts so the diff vs upstream 2.4.2 is *only* the annotation-related code. Upstream files should match upstream exactly when no fork modification touched them.
- Preserve fork commit history; do not squash the merge.
- When a fork-added line and an upstream-changed line collide, prefer integrating the upstream change first and re-applying the fork's intent on top.

**Things to avoid:**

- **Do not** opt into `PdfOverlayInteractionRegion` for the annotation layer in this work — that's a deliberate follow-up.
- **Do not** migrate away from deprecated `PdfViewerParams` sizing params unless required for correctness of the annotation layer.
- **Do not** refactor the annotation layer architecturally; keep changes minimal and reversible.
- **Do not** drop or rename any fork-added public symbol.
- **Do not** modify tests to make them pass; fix the production code instead.

**Helpful upstream references:**

- Upstream pdfrx CHANGELOG: `https://raw.githubusercontent.com/espresso3389/pdfrx/master/packages/pdfrx/CHANGELOG.md`
- Upstream pdfrx_engine CHANGELOG: `https://raw.githubusercontent.com/espresso3389/pdfrx/master/packages/pdfrx_engine/CHANGELOG.md`
- Upstream issues referenced in changelog: #581 (scroll), #582 (sizing), #376 (overlay), #111 (underflow), #603 (scaleEnabled), #644 (text selection)

</implementation>

<stages>

**Stage 1 — Preflight, branch setup, tag resolution**
- Verify `git status` is clean. If not, surface and abort.
- Switch to `master`, `git pull`. Confirm recent annotation commits (52ea2ae, 9b9d0ba, 88ca0bd, 303e6f3, a1048f8) are present on `master`.
- Create branch from master: `git checkout -b chore/upgrade-pdfrx-2.4.2`
- Add `upstream` remote: `git remote add upstream https://github.com/espresso3389/pdfrx.git`
- Fetch: `git fetch upstream --tags`
- Resolve merge target: `git ls-remote --tags upstream | grep -E 'pdfrx-v2\.4\.'`. Prefer `pdfrx-v2.4.2`; if it does not exist, fall back to highest available `pdfrx-v2.4.*`. Surface which tag is being used.
- Inventory fork-only `lib/src/utils/` files via `git log` to confirm provenance (specifically `fixed_overscroll_physics.dart`, `double_extensions.dart`, `edge_insets_extensions.dart`).
- **Verify completion**: branch created off `master`, upstream remote shows in `git remote -v`, exact merge ref identified and surfaced, utility-file provenance documented.

**Stage 2 — Merge**
- `git merge <upstream-pdfrx-v2.4.x-ref>` (do not `--squash`)
- Initial conflict survey: list all files with conflict markers; categorize as (a) take upstream, (b) take fork, (c) hand-merge.
- **Verify completion**: merge commit exists (with conflict markers still present in conflicted files), conflict survey saved for PR description.

**Stage 3 — Resolve conflicts (annotation + utility surface)**
- Hand-merge `pdf_viewer.dart` and `pdf_viewer_params.dart`: take upstream's structural changes; re-apply annotation hooks; preserve `FixedOverscrollPhysics` reference.
- Verify `pdf_annotation_layer.dart` page-coordinate math under the new sizing delegate (Legacy delegate to keep current behavior).
- Verify pointer routing in annotation layer still functions under new pluggable scroll/zoom delegates.
- Confirm all 12 export lines in `lib/pdfrx.dart` survive — including `src/utils/fixed_overscroll_physics.dart`.
- Verify `executables:` block in `packages/pdfrx/pubspec.yaml` is intact.
- After conflict resolution, verify pubspec metadata (`homepage`, `repository`, `issue_tracker`) still points at upstream and version pins reflect merged upstream values.
- Run `flutter pub get` at workspace root; resolve any constraint conflicts in the three example pubspecs.
- **Verify completion**: no remaining conflict markers; `flutter pub get` succeeds; `flutter analyze` clean across all packages.

**Stage 4 — Native-assets PDFium migration**
- Inspect upstream's new native-assets packaging in `pdfium_flutter/{android,darwin,linux,windows}/`.
- Reconcile any fork-side build customizations.
- Verify Web WASM assets (`packages/pdfrx/assets/pdfium.wasm` + worker scripts) are updated to upstream's version at the merge commit.
- Verify each platform actually builds via the example apps. Confirm with user which platforms are mandatory if time is short; default to iOS/macOS (via `darwin/`) + Android + Web as the baseline.
- **Verify completion**: `flutter build` succeeds for each in-scope platform target; no platform is silently broken.

**Stage 5 — Test pass**
- Run `flutter test` in `packages/pdfrx`.
- Run `flutter test` in `packages/pdfrx/example/music_viewer`.
- Run any other package test suites.
- Fix regressions in production code (not by editing tests).
- **Verify completion**: all green; no skipped tests except those that were skipped before the upgrade.

**Stage 6 — Manual smoke**
- Launch `music_viewer` example.
- Exercise each annotation tool per requirement 23.
- Verify save + reload round-trip via Instant JSON.
- **Verify completion**: all tools work; user has visually confirmed.

**Stage 7 — Commit, PR, follow-ups**
- Commit message references upstream version, lists fork-specific files touched, links follow-up opportunities.
- Open PR documenting: scope, conflict resolution decisions, follow-up tickets (PdfOverlayInteractionRegion adoption, sizeDelegateProvider migration, scaleEnabled audit, etc.), platforms manually verified.
- **Verify completion**: PR open; CI green (or known-failures documented).

</stages>

<validation>

**Automated:**

- `flutter pub get` succeeds at workspace root.
- `flutter analyze` clean across every package and example.
- `flutter test` passes in `packages/pdfrx`.
- `flutter test` passes in `packages/pdfrx/example/music_viewer`.
- `flutter test` passes in any other package that has tests (`pdfrx_engine`, `pdfium_dart`, `pdfium_flutter`, `pdfrx_coregraphics`).
- No tests skipped that weren't skipped before; no tests modified solely to pass.

**Manual smoke in `music_viewer`:**

1. **Pen tool** — select pen, draw stroke, verify color/width, undo, redo.
2. **Highlighter tool** — select highlighter, draw, verify translucency (`highlighterOpacity`).
3. **Eraser tool** — erase own-creator strokes; foreign-creator strokes (if seeded) are not erased.
4. **Stamp tool** — open stamp picker, place stamp, drag, resize via each of the 8 handles, rotate via rotation affordance; verify `selectedStampPadding` visual.
5. **Hand tool** — confirm pan/zoom works while in annotation mode with hand selected (the recent commit 9b9d0ba behavior).
6. **Persistence** — save annotations via storage callback, close, reopen, verify Instant JSON round-trip is identical (strokes, stamps, attachments).
7. **Multi-page navigation** — page through document while annotating; annotations stay anchored to correct pages.
8. **Undo/redo** — verify undo/redo across mixed operations (place stamp, draw stroke, move stamp, erase).
9. **Multi-creator** — if seedable, verify foreign-creator stamps render but cannot be selected/moved; export filtered by creator.

**Test-type mapping:**

- **Unit/widget tests (existing)** — annotation controller, ink/stamp models, instant_json round-trip, layer painter math. These cover logic and rendering correctness.
- **Integration / journey tests (existing in music_viewer)** — stamp journey, picker, library, cross-page drag, foreign creator. These cover critical user flows.
- **No new automated tests required for this upgrade** unless a regression surfaces that's not currently covered. If a regression is fixed during the upgrade, add a regression test as part of the fix.

**Risks to call out explicitly in the PR:**

- Page-coordinate math under new sizing delegate may have subtle off-by-pixel differences at certain zoom levels — manual smoke covers the obvious cases, but consumers integrating the fork may see edge cases.
- Pointer routing under new scroll/zoom delegate may behave differently with the hand tool at extreme zoom; smoke covers normal zoom levels.
- Native-assets migration may surface platform-specific build issues on platforms not manually tested.

</validation>

<done_when>

1. All five package `pubspec.yaml` `version:` fields match whatever the merged upstream commit declares (expected `pdfrx 2.4.2`, `pdfrx_engine 0.4.x`, `pdfium_flutter 0.2.x`, `pdfium_dart 0.2.x`, `pdfrx_coregraphics` aligned to `pdfrx_engine` — verify post-merge, do not assert beforehand).
2. `git remote -v` shows `upstream` remote configured; current branch contains merge commit referencing the exact upstream ref used (e.g., `pdfrx-v2.4.2`).
3. `git diff <upstream-ref> -- packages/pdfrx packages/pdfrx_engine packages/pdfium_flutter packages/pdfium_dart packages/pdfrx_coregraphics` shows changes only in fork-specific files (annotation surface, integration points in `pdf_viewer.dart`/`pdf_viewer_params.dart`, `lib/src/utils/fixed_overscroll_physics.dart`, fork-only example app files); upstream-only files are byte-identical to upstream.
4. `flutter pub get` succeeds at workspace root; `flutter analyze` clean across all packages and examples.
5. All previously-passing tests still pass; no tests were modified or skipped to achieve green.
6. Manual smoke (requirement 23 / validation steps 1-9) all pass in `music_viewer`.
7. CHANGELOG.md files are not modified beyond what the merge brought in; pubspec metadata (`homepage`, `repository`, `issue_tracker`) still points at upstream; `executables:` block in `packages/pdfrx/pubspec.yaml` intact.
8. PR opened with description listing: upstream changes pulled in, conflict resolution decisions, follow-up opportunities deferred (PdfOverlayInteractionRegion, sizeDelegateProvider, PdfFontManager, scaleEnabled audit), platforms manually verified.
9. No silently-broken platform; any unverified platform is explicitly listed as such in the PR.

</done_when>