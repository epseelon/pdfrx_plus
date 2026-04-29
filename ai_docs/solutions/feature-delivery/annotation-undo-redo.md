---
title: Snapshot-based undo/redo for PDF ink annotations
date: 2026-04-29
work_type: feature
tags: [pdfrx, annotations, undo-redo, snapshot-stack, change-notifier, value-listenable]
confidence: high
references:
  - ai_specs/annotation-undo-redo.md
  - ai_specs/annotation-undo-redo-plan.md
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart
  - packages/pdfrx/lib/src/widgets/pdf_viewer.dart
  - packages/pdfrx/example/music_viewer/lib/main_page.dart
  - packages/pdfrx/test/pdf_annotation_controller_test.dart
  - packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart
---

## Summary

Added in-memory, per-session undo/redo for ink annotations:
two `List<List<PdfInkAnnotation>>` snapshot stacks on
`PdfAnnotationController`, two `ValueNotifier<bool>` flags driving
button-disabled state, and a four-symbol facade
(`undo`, `redo`, `canUndoListenable`, `canRedoListenable`) on
`PdfViewerController`. Music_viewer toolbar gained an Undo/Redo
section flanked by `VerticalDivider`s, extracted as a public
`AnnotationUndoRedoButtons` widget for direct widget testability.
Zero new dependencies; zero I/O; pure in-memory list manipulation.

## Reusable Insights

### Pick snapshot stacks over command pattern when state is small and immutable

- For a stroke list whose elements are immutable
  (`PdfInkAnnotation`), a snapshot stack
  (`List<List<PdfInkAnnotation>>`) is the simplest correct design.
- Each snapshot is `List<PdfInkAnnotation>.unmodifiable(_strokes)` —
  references only, no deep copy. The stroke instances are shared
  across snapshots; memory cost is negligible until thousands of
  mutations.
- A generic command-pattern abstraction would multiply code paths,
  require per-mutation inverse logic, and add no value here. Resist
  introducing it speculatively.

### Snapshot only at user-driven mutation entry points

- Snapshot **before** the mutation, not after. The undo stack stores
  *prior* states.
- Snapshot at:
  - `commitStroke()` — only when in-flight has ≥ 2 points (so
    discarded degenerate strokes don't push a snapshot).
  - `startErase(...)` — once per pan.
  - `addStroke(stroke)` — external append is on the same footing as
    a successful commit.
- **Never** snapshot in per-tick paths: `appendPoint`,
  `continueErase`, `cancelStroke`, in-flight notifier ticks. One
  pan = one undo step.
- **Never** snapshot for style-only setters (`setTool`,
  `setStrokeColor`, `setStrokeWidth`, `setEraserRadius`). They don't
  change the stroke list.

### Lifecycle: clear stacks at session start, not on every `enterMode`

- Stacks are cleared **only on the false→true mode transition**
  inside `enterMode`'s existing `if (_modeListenable.value) return`
  early-return path. Mid-session `enterMode` calls (used to update
  style/creator overrides) **preserve** stacks.
- `exitMode` does **not** clear stacks. The next `enterMode` does.
  This bounds the holdover memory to whatever the last session
  accumulated.
- `clear()` and `setAll(...)` are wholesale resets — they clear
  stacks **and** strokes. Undoing a reset is intentionally
  impossible.
- `importJson(...)` clears stacks transitively (it delegates to
  `setAll`); cover with one test rather than duplicating the
  invariant.

### Idempotent boolean listenables (compare-then-assign)

- `_refreshHistoryListenables()` must compare before assigning:
  ```dart
  final canUndo = _undoStack.isNotEmpty;
  if (_canUndo.value != canUndo) _canUndo.value = canUndo;
  ```
- A naive `_canUndo.value = _undoStack.isNotEmpty` re-notifies on
  every push, even when the boolean didn't change. The toolbar
  would rebuild on every stroke instead of only on enable/disable
  transitions.
- This is the same pattern as `setStrokeColor`, `setStrokeWidth`,
  etc. on the same controller.

### Restore the strokes list in place, don't reassign

- `_strokes` is `final List<PdfInkAnnotation>`; the painter and
  other listeners depend on the **same** list reference.
- Restore via `_strokes..clear()..addAll(snapshot)`, never
  `_strokes = ...`. Reassignment would silently break any
  downstream code holding the prior reference.

### Empty-stack `undo()` / `redo()` are no-ops with no notify

- Calling `undo()` when `_undoStack.isEmpty` must:
  - return immediately,
  - not throw,
  - not call `notifyListeners()` (no spurious repaint),
  - not flip the listenables (they were already `false`).
- The pattern keeps callers safe even when invoked from
  `onPressed: null`-disabled UI states or pre-mount.

### Branch invalidation: clear redo on every new push

- `_pushUndoSnapshot()` clears `_redoStack` and refreshes
  `canRedoListenable` to `false`. After
  `commitStroke A; commitStroke B; undo(); commitStroke C` →
  `_strokes == [A, C]`, redo disabled. This matches the user mental
  model (a new edit kills the redo branch).

### Pre-mount safety on the public facade

- `PdfViewerController.canUndoListenable` /
  `canRedoListenable` must be readable **before** the viewer mounts.
  The facade getters return `_annotationController.canUndoListenable`
  on a controller that's instantiated up front — same pattern as
  `annotationModeListenable`.
- Pre-mount `undo()` / `redo()` must be no-ops, exercised by a
  one-line test in
  `test/pdf_viewer_controller_annotation_test.dart`. Guards against
  silent wire breakage.

### Toolbar disable via `onPressed: null` + `ValueListenableBuilder<bool>`

- Wrap each button in `ValueListenableBuilder<bool>(canUndoListenable, ...)`
  and pass `null` to `onPressed` when the bool is `false`. Flutter
  handles the disabled visual automatically; no manual `setState`,
  no theme work.
- Use plain `IconButton` (not `IconButton.filledTonal`) for
  non-toggle action buttons — matches existing reset/close. Tooltips
  `'Undo'` / `'Redo'` are stable selectors for widget tests.

### Extract toolbar widgets for direct widget tests

- The Undo/Redo group was extracted as a public top-level
  `AnnotationUndoRedoButtons(toolListenable, canUndoListenable,
  canRedoListenable, onUndo, onRedo)`. The widget test pumps it
  directly with `ValueNotifier<bool>` fakes — no `MainPage`, no
  `PdfDocumentRef`.
- This precedent later carried the highlighter journey test
  (`AnnotationToolButtons`). Whenever a toolbar group is testable in
  isolation, extract it and write the test against the extracted
  widget rather than against the full screen.

### Eraser policy: snapshot at `startErase`, accept the no-op-undo trade-off

- `startErase` pushes a snapshot. If the eraser pan touched no
  strokes, the snapshot still exists and an undo would replay an
  identical state (cosmetic no-op).
- The alternative — hoist the snapshot into `_applyEraseSegment`
  guarded by `changed == true` — moves the snapshot point off the
  pan boundary and complicates reasoning. Simpler placement wins;
  user impact is rare.

## Decisions

- **Unbounded stacks**. Memory cost is references-only because
  `PdfInkAnnotation` is immutable. Bounding adds complexity for
  little gain at typical session sizes.
- **No persistence of undo history**. In-memory and per-session
  only; document reload or `enterMode` discards it. Persistence is
  out of scope and would require non-trivial format work.
- **Undo/redo do not call `onAnnotationsChanged`.** Persistence
  still happens on `exitAnnotationMode` as before. Treat undo/redo
  as session-local state, not a write trigger.
- **No undo for style-only setters.** Style changes don't mutate
  the stroke list; bundling them into the history would surprise
  users (and require deciding whether `setTool` is undoable, etc.).

## Pitfalls

- **Forgetting compare-then-assign in `_refreshHistoryListenables`**.
  Re-fires the listenable on every push → toolbar rebuilds 60 fps
  during heavy editing. Always assert "listener fires only on
  flip" in a test.
- **Pushing a snapshot when `commitStroke` discarded the in-flight
  (< 2 points)**. The committed list didn't change; pushing
  pollutes the stack with no-op entries.
- **Calling `notifyListeners()` from no-op `undo()` / `redo()`**.
  Spurious repaints; user-perceptible if the painter is heavy.
- **Reassigning `_strokes`**. Silent breakage of any code holding
  the prior list reference. Always mutate in place.
- **Forgetting to dispose the new `ValueNotifier`s**. Add the two
  new disposes alongside the existing ones in `dispose()`.
- **Not clearing `_redoStack` on `_pushUndoSnapshot`**. Branch
  invalidation breaks; users see a stale redo arrow that, when
  tapped, would replace their just-drawn stroke.

## Validation

- Pure-Dart unit tests in
  `packages/pdfrx/test/pdf_annotation_controller_test.dart` cover:
  fresh state, commit (≥2 / <2 points), undo + redo, branch
  invalidation, empty-stack no-op, listenable-only-on-flip,
  `enterMode` false→true vs already-in-mode, `clear()` /
  `setAll()` / `importJson()` reset, eraser snapshot at
  `startErase`, `continueErase` pushes nothing, eraser-pan-touches-no-strokes
  still snapshots.
- Pre-mount facade test in
  `packages/pdfrx/test/pdf_viewer_controller_annotation_test.dart`:
  listenables readable, methods are no-ops.
- Toolbar widget test in
  `packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart`:
  pumps the extracted `AnnotationUndoRedoButtons` directly with
  fake `ValueNotifier<bool>`s; asserts initial disabled state,
  enables on flip, taps fire the callbacks. Selectors:
  `find.byTooltip('Undo')`, `find.widgetWithIcon(IconButton, Icons.undo)`.
- Verify: `cd packages/pdfrx && flutter analyze && flutter test`
  and the same in `packages/pdfrx/example/music_viewer`.
- Manual smoke test (left for the user to run on macOS):
  draw → undo twice → redo twice → erase → undo restores; reset →
  both disabled; exit/re-enter mode → both disabled while strokes
  remain on canvas.

## Follow-ups

- Persistence of undo history (out of scope for v1; would need a
  format and a size budget).
- Undo/redo for style-only changes (out of scope; design decision
  to keep history scoped to stroke-list mutations).
- Bounded stack with FIFO eviction — only worth implementing if a
  real session demonstrates memory pressure.
