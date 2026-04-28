## Overview

Snapshot-based undo/redo in `PdfAnnotationController` (in-memory, per-session); thin facade on `PdfViewerController`; new toolbar buttons in music_viewer.

**Spec**: `ai_specs/annotation-undo-redo.md` (read for full requirements)

## Context

- **Structure**: monorepo; primary package `packages/pdfrx`
- **State management**: `ChangeNotifier` + `ValueNotifier`s; idempotent setters (`if (notifier.value == newValue) return;`)
- **Reference implementations**:
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` (state owner; see `setStrokeColor` for idempotent pattern, `setAll`/`clear` for mutation)
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` lines ~5346-5464 (facade pattern; thin delegators, `ValueListenable<T>` getters)
  - `packages/pdfrx/example/music_viewer/lib/main_page.dart` lines 94-145 (`_buildAnnotationToolbar`; existing dividers, IconButton (plain) pattern at lines 131-140)
  - `packages/pdfrx/test/pdf_annotation_controller_test.dart` (TDD style; pure in-memory, no mocks)
- **Assumptions/Gaps**:
  - Spec referenced `test/widgets/annotations/...` path; actual layout is flat: `test/pdf_annotation_controller_test.dart` and `test/pdf_viewer_controller_annotation_test.dart`. Extend these directly (no new dirs).
  - Spec lists `addStroke` as a snapshot site (req 4); existing `addStroke` is a public-but-not-facade API. Snapshot before append, matching `commitStroke` semantics.

## Plan

### Phase 1: Controller history + facade + toolbar (vertical slice)

- **Goal**: end-to-end pen flow: draw → undo → redo working through UI; lifecycle resets covered.
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — add `_undoStack`, `_redoStack`, `_canUndo`, `_canRedo`; getters `canUndoListenable`, `canRedoListenable`; helpers `_pushUndoSnapshot()`, `_refreshHistoryListenables()`; methods `undo()`, `redo()`; snapshot calls in `commitStroke` (only when ≥2 points), `addStroke`, `startErase`; stack-clear in `enterMode` (false→true only), `clear` (skip when empty), `setAll`; dispose new notifiers (Phase 1: snapshot in `commitStroke` + helpers + listenables + dispose; remaining mutation sites covered in Phase 2)
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — `undo()`, `redo()`, `canUndoListenable`, `canRedoListenable` on `PdfViewerController`; doc-comments matching surrounding style; note "stacks reset on `enterAnnotationMode` mode-flip"
- [x] `packages/pdfrx/example/music_viewer/lib/main_page.dart` — insert Undo/Redo section in `_buildAnnotationToolbar`; section order `[drag] [Pen] [Eraser] | [color?] [thickness] | [Undo] [Redo] | [reset] [close]`; three `VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8)`; plain `IconButton` (not filledTonal); `ValueListenableBuilder<bool>` wrapping each; `onPressed: null` when stack empty; tooltips `'Undo'` / `'Redo'` (extracted as public `AnnotationUndoRedoButtons` widget for direct widget testability; takes listenables + callbacks)
- [x] TDD: fresh controller → `canUndoListenable.value == false`, `canRedoListenable.value == false`
- [x] TDD: `commitStroke` with ≥2 points → undo enabled, redo disabled
- [x] TDD: `commitStroke` with <2 points (degenerate) → both stay disabled (no snapshot pushed)
- [x] TDD: `undo()` from one-stroke state → strokes empty, undo disabled, redo enabled
- [x] TDD: `redo()` from previous → original stroke restored, undo enabled, redo disabled
- [x] TDD: `commitStroke A; commitStroke B; undo(); commitStroke C` → strokes `[A, C]`, redo disabled (branch invalidation)
- [x] TDD: `undo()` / `redo()` on empty stack → no-op, no listener fires, no throw
- [x] TDD: listenables fire only on boolean flip (push second entry onto non-empty stack does NOT re-notify `canUndoListenable`)
- [x] TDD (facade): `PdfViewerController.canUndoListenable.value == false`, `canRedoListenable.value == false` pre-mount; `controller.undo()` / `controller.redo()` are no-ops pre-mount (extends `test/pdf_viewer_controller_annotation_test.dart`)
- [x] Robot/widget journey test: `packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart` (new) — pump `AnnotationUndoRedoButtons` widget directly; verify both buttons disabled (`onPressed == null`) initially; flip listenables and verify the buttons enable + that taps fire `onUndo`/`onRedo`. Stable selectors = tooltip strings + icon (`find.widgetWithIcon(IconButton, Icons.undo)`).
- [x] Verify: `cd packages/pdfrx && flutter analyze && flutter test` (analyze: 9 pre-existing baseline issues, 0 new; tests: 51 passing, 1 pre-existing pdfium-download failure unrelated to this change)

### Phase 2: Eraser + lifecycle coverage + edge cases + manual verify

- **Goal**: complete spec coverage; eraser, multi-mutation lifecycle, manual walkthrough.
- [x] TDD: `startErase` pushes one snapshot; `continueErase` pushes none. Draw + 1 erase pan with N continue samples → undo stack depth = 2 (one for commit, one for startErase)
- [x] TDD: eraser pan splits stroke into pieces; `undo()` restores original (`pointsInPdfSpace`, `lineWidth`, `strokeColor` equal)
- [x] TDD: eraser pan touching no strokes still pushes snapshot at `startErase` (accepted no-op trade-off per spec edge case 19)
- [x] TDD: first `enterMode` (false→true) clears both stacks; second `enterMode` while already in mode preserves stacks (populate stacks, call again, assert depths unchanged)
- [x] TDD: `clear()` empties strokes AND stacks (both listenables go false); calling `clear()` when already empty is still a no-op (no notify)
- [x] TDD: `setAll(...)` clears both stacks
- [x] TDD: `addStroke(stroke)` pushes a snapshot before appending (treat as user-driven append)
- [x] TDD: `importJson(...)` clears stacks transitively (delegates to `setAll`); cover with one test
- [ ] Manual verify (spec validation steps 15-23): run `cd packages/pdfrx/example/music_viewer && flutter run`; walk the golden path — toolbar layout, dividers, disabled states, draw/undo/redo, eraser undo, reset clears stacks, exit/re-enter clears stacks while keeping prior strokes on canvas — **BLOCKER**: requires user to run the app on a device; cannot be performed by the agent. All automated coverage of this surface is in place via the controller-level TDD suite + the music_viewer toolbar widget tests.
- [x] Verify: `cd packages/pdfrx && flutter analyze && flutter test` (analyze: same 9 pre-existing baseline issues, 0 new; pdfrx tests: 47 passing of 48 — the single failure is the pre-existing `pdf_viewer_test.dart` `PdfViewer.uri` test that needs to download pdfium binaries from GitHub, unrelated to this change. music_viewer: clean analyze; 9/9 tests pass.)

## Risks / Out of scope

- **Risks**:
  - `clear()` early-return optimization must be preserved (skip stack-clear + notify when `_strokes.isEmpty`); regression risk for callers relying on no-notify
  - `_refreshHistoryListenables()` must use compare-then-assign — naive `.value =` would re-notify on every push
  - Dispose order: dispose new notifiers in `dispose()` before `super.dispose()`, alongside existing
- **Out of scope**:
  - Persistence of undo history (in-memory only)
  - Undo/redo for style-only changes (`setTool`, `setStrokeColor`, etc.)
  - Robot/journey cross-screen tests (single-screen interaction; widget test sufficient)
  - Generic command-pattern abstraction
  - Bounding stack size (per spec: unbounded)
