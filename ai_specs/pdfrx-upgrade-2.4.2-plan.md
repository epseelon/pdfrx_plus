# Plan: pdfrx upstream upgrade 2.2.24 → 2.4.1

## Overview

Merge `upstream/pdfrx-v2.4.1` into fork (no `2.4.2` exists). Preserve annotation surface; absorb pluggable scroll/size/zoom delegates + native-assets PDFium repackaging.

**Spec**: `ai_specs/pdfrx-upgrade-2.4.2.md` (read this file for full requirements)

## Context

- **Structure**: monorepo workspace, 5 packages — `pdfium_dart`, `pdfium_flutter`, `pdfrx_engine`, `pdfrx`, `pdfrx_coregraphics`
- **State management**: N/A — this is an infra upgrade, not a feature
- **Reference (fork-only files)**: `packages/pdfrx/lib/src/widgets/annotations/*`, `packages/pdfrx/lib/src/utils/fixed_overscroll_physics.dart`, `packages/pdfrx_engine/lib/src/pdf_annotation.dart`
- **Conflict zones (line-mapped)**:
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — fork hooks at L18-19 (imports), L26-35 (helper), L255-258 + L314-341 + L356-361 + L391 (state plumbing), L548-552 (outer `Listener`), L571-572 (`_effectivePan/ScaleEnabled`), L1245/L3024/L3085/L3101/L3172/L3184 (6 navigation early-returns), L2317-2334 (annotation layer mount), L2513-2519 (`paintPageInkAnnotations` hook), L4965-4999 (annotation controller lifetime), L5425-5619 (public annotation API). Upstream rewrote this file: +962/-322
  - `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — fork: 7 params (L28, L77-82), assert (L93-97), 6 field docs (L105-162, L318-319), `FixedOverscrollPhysics` helper (L725-733), 3 places × 6 entries in `doChangesRequireReload` / `==` / `hashCode` (L748, L783, L831-835, L849, L897-901). Upstream: +178/-15 (mostly additive + `@Deprecated` on legacy sizing params)
- **Upstream new files (accept verbatim, all re-exported)**: 10 files in `pdfrx/lib/src/widgets/{scroll_interaction,sizing,zoom_steps}/` + `pdf_viewer_layout_metrics.dart`
- **Annotations dir**: zero upstream presence — no file-level conflicts inside `lib/src/widgets/annotations/`
- **Assumptions / gaps**:
  - Target ref is `pdfrx-v2.4.1` (not `2.4.2` — does not exist). Spec needs note.
  - Hard floor bump: Dart `^3.10.0`, Flutter `>=3.41.0`. Local toolchain must satisfy.
  - `double_extensions.dart`, `edge_insets_extensions.dart`, `platform.dart`, `native/`, `web/` in `lib/src/utils/` are upstream (confirmed via CHANGELOG + import-graph); will be touched by merge.
  - `pdfium_flutter` android/linux/windows plugin scaffolding is **deleted** upstream; binaries come from `pdfium_dart` build hook (`code_assets` + `hooks`).
  - WASM rebuild: `pdfium.wasm` 3.9MB → 5.2MB, `pdfium_worker.js` +847/-84.
  - `PdfOverlayInteractionRegion` is declared inside `pdf_viewer.dart` (not a separate file). Out-of-scope for this work.
  - This is an upgrade, not feature work — standard TDD/robot phases don't apply; rely on existing test suite + manual smoke.

## Plan

### Phase 1: Preflight, branch, tag resolution

- **Goal**: clean baseline + upstream wired + confirmed target ref
- [x] Verify `git status` clean; abort if dirty (only untracked plan file; tracked tree clean)
- [x] `git checkout master && git pull` — confirm recent annotation commits (52ea2ae, 9b9d0ba, 88ca0bd, 303e6f3, a1048f8) present (verified on master via `git log master`)
- [x] `git checkout -b chore/upgrade-pdfrx-2.4.1` from master (deviation: reused existing branch `feature/pdfrx-upgrade` which was already created one commit ahead of master with the spec doc; same intent)
- [x] `git remote add upstream https://github.com/espresso3389/pdfrx.git && git fetch upstream --tags`
- [x] Confirm `pdfrx-v2.4.1` exists (`pdfrx-v2.4.2` does not); surface ref to user (target tag: `pdfrx-v2.4.1` → commit 654fc94)
- [x] Verify local Dart/Flutter ≥ 3.10 / 3.41; surface to user if not (Flutter 3.44.0, Dart 3.12.0 — both above floor)
- [x] Verify: `git log -1 upstream/pdfrx-v2.4.1` resolves; `flutter --version` ≥ 3.41 (tag resolved via `git log pdfrx-v2.4.1` since tags aren't `upstream/`-prefixed)
- [x] **Update spec**: change target from `pdfrx-v2.4.2` → `pdfrx-v2.4.1` in `ai_specs/pdfrx-upgrade-2.4.2.md`

### Phase 2: Merge + conflict survey

- **Goal**: merge committed (with conflict markers), full file-level map of conflicts
- [ ] `git merge --no-ff --no-commit upstream/pdfrx-v2.4.1` (or commit immediately with markers — pick one)
- [ ] Capture `git status --short` output → save as conflict survey for PR description
- [ ] Categorize each conflicted file: (a) take upstream, (b) take fork, (c) hand-merge
- [ ] Expected hand-merge files: `packages/pdfrx/lib/src/widgets/pdf_viewer.dart`, `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart`, `packages/pdfrx/lib/pdfrx.dart`, possibly `packages/pdfrx/pubspec.yaml` (executables block + version), example pubspecs
- [ ] Verify: merge commit exists; conflict survey saved

### Phase 3: Resolve conflicts (`pdf_viewer.dart`, `pdf_viewer_params.dart`, exports, utility)

- **Goal**: clean tree, fork hooks re-applied on upstream's new structure
- [ ] `pdf_viewer.dart`: take upstream as base; re-apply each fork hook by reference (use line-map in Context)
  - imports (annotation controller + layer)
  - `navigationSuppressedByAnnotation` top-level helper
  - `_annotationController` getter + listeners
  - `_effectivePanEnabled` / `_effectiveScaleEnabled` gates on whatever upstream's new pan/scale surface is
  - outer `Listener` wrapping `InteractiveViewer` (this is the hand-tool pointer pass-through)
  - annotation layer mount in page overlay builder (preserve `rectExternal` consumer)
  - `paintPageInkAnnotations(...)` call right after `pagePaintCallbacks` in page painter
  - 6 navigation early-return gates (`_goTo`, `_goToArea`, `_goToPage`, `_goToRectInsidePage`, `_goToDest`, `_goToManipulated`)
  - `annotationRenderingMode` passed to `page.render()` (2 sites)
  - `PdfViewerController._annotationController` field + `_attach` listener set + `dispose()` + public API methods (L5425-5619 worth of surface)
- [ ] `pdf_viewer_params.dart`: re-apply 7 fork params + assert + field docs + `FixedOverscrollPhysics.getScrollPhysics` helper + entries in `doChangesRequireReload` / `==` / `hashCode`. Co-exist with upstream's new delegate-provider params + `@Deprecated` legacy sizing params (do not migrate)
- [ ] `lib/pdfrx.dart`: confirm all 12 export lines remain; in particular L12-17 fork-added block (instant_json, annotation_controller `show` clause, ink/stamp/definition, fixed_overscroll_physics). Accept upstream's 10 new exports for scroll/size/zoom delegates + layout_metrics
- [ ] `lib/src/utils/fixed_overscroll_physics.dart`: untouched
- [ ] `lib/src/utils/{double_extensions,edge_insets_extensions,platform}.dart` + `native/` + `web/`: take upstream
- [ ] `packages/pdfrx/pubspec.yaml`: take upstream version + constraints; preserve `executables:` block if it survives upstream
- [ ] Pubspec metadata (`homepage`, `repository`, `issue_tracker`): leave pointing to upstream — no change
- [ ] Three example pubspecs: take upstream constraints; relax fork-side example constraints only if `flutter pub get` errors
- [ ] Run `flutter pub get` at workspace root; resolve any constraint conflicts
- [ ] Verify: no conflict markers (`rg '<<<<<<<' packages/`), `flutter pub get` clean, `flutter analyze` clean across all packages and examples

### Phase 4: Native-assets PDFium build verification

- **Goal**: each platform actually builds + loads PDFium under new packaging
- [ ] Inspect `packages/pdfium_flutter/hook/link.dart` + `packages/pdfium_dart/hook/build.dart` (new upstream files) — understand the new flow
- [ ] Confirm `packages/pdfium_flutter/{android,linux,windows}/` plugin scaffolding is gone (upstream deletes); only `darwin/` remains
- [ ] `cd packages/pdfrx/example/viewer && flutter build apk` (Android)
- [ ] `flutter build macos` (Darwin path)
- [ ] `flutter build ios --no-codesign` (Darwin path)
- [ ] `flutter build web --wasm` (verify WASM assets load — new `pdfium.wasm` is 5.2MB)
- [ ] Linux + Windows: build if available locally; otherwise mark explicitly as unverified in PR
- [ ] Verify: each attempted platform builds cleanly; PDFium binary loads at runtime (smoke open of a sample PDF on each platform)

### Phase 5: Tests + manual smoke

- **Goal**: existing test suite green + every annotation tool works in music_viewer
- [ ] `cd packages/pdfrx && flutter test` — full suite green
- [ ] `cd packages/pdfrx/example/music_viewer && flutter test` — full suite green (annotation controller, stamp journey/picker/library/layer, foreign creator, storage, toolbar)
- [ ] `cd packages/pdfrx_engine && dart test`
- [ ] `cd packages/pdfium_dart && dart test`
- [ ] `cd packages/pdfium_flutter && flutter test`
- [ ] `cd packages/pdfrx_coregraphics && flutter test` (if any tests)
- [ ] Fix regressions in production code only — do NOT modify or skip tests
- [ ] Manual smoke `music_viewer`: pen → highlighter → eraser → stamp (drag, 8 resize handles, rotate, `selectedStampPadding`) → hand (pan/zoom in annotation mode) → save/reload Instant JSON round-trip → multi-page navigation while annotating → undo/redo mixed ops → foreign-creator semantics (if seedable)
- [ ] Verify: all green; manual smoke checklist complete

### Phase 6: Commit, PR, follow-ups

- **Goal**: PR open with full context
- [ ] If diff is unreviewably large, split into stacked PRs along package boundaries (engine + pdfium_* first, pdfrx + examples second) — decide after seeing diff
- [ ] PR description: upstream changes pulled in, conflict resolution decisions, deferred follow-ups (`PdfOverlayInteractionRegion` adoption, `sizeDelegateProvider` migration, `PdfFontManager` opt-in, `scaleEnabled` Ctrl+wheel audit), platforms manually verified vs unverified
- [ ] Verify: PR open; CI green or known-failures documented in PR

## Risks / Out of scope

- **Risks**:
  - `pdf_viewer.dart` rewrite is large (+962/-322). Outer `Listener` placement and page painter structure may have moved; surgical re-application of 6 navigation gates + ink paint hook is error-prone. Read the merged file end-to-end before declaring victory.
  - Native-assets migration kills Android/Linux/Windows plugin scaffolding. If fork CI or any developer relied on the old CMake-based build, expect breakage.
  - Dart 3.10 / Flutter 3.41 floor jump. Local toolchain or CI runners may not satisfy.
  - Annotation layer's `pageRect` contract: layer is decoupled from `PdfViewerParams`, but caller must keep feeding it the correct `rectExternal` after upstream's sizing-delegate rework. Verify stamps/strokes land correctly at non-1x zoom in manual smoke.
- **Out of scope** (explicit):
  - Adoption of `PdfOverlayInteractionRegion` for annotation pointer routing — follow-up
  - Migration off deprecated `PdfViewerParams` sizing fields → `sizeDelegateProvider` — follow-up (Legacy delegate keeps current behavior)
  - `PdfFontManager` opt-in — follow-up
  - WASM `preferRangeAccess` opt-in — follow-up
  - Pushing changes back upstream
  - Updating fork CHANGELOG with fork-specific entries
  - Updating pubspec `homepage`/`repository`/`issue_tracker` metadata
