<goal>
Add undo/redo support for ink annotations.

Two deliverables:
1. New public APIs on `PdfViewerController` (`undo`, `redo`, `canUndoListenable`, `canRedoListenable`) backed by snapshot-based history inside `PdfAnnotationController`.
2. A new undo/redo section in the music_viewer example's annotation toolbar (`packages/pdfrx/example/music_viewer/lib/main_page.dart`) bracketed by `VerticalDivider`s, wired to the new listenables.

Why: users currently lose accidental pen strokes irreversibly and can lose erased content with no recovery short of reloading the file. Undo/redo is a baseline expectation for any drawing surface.

Who benefits: end users of any pdfrx app that exposes annotation mode (the music_viewer example app first; the API is reusable by any consumer of the package).
</goal>

<background>
Stack: Flutter / Dart. Annotation state already lives in `PdfAnnotationController` (a `ChangeNotifier`) and is exposed publicly via methods/listenables on `PdfViewerController`.

Files to examine:
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — owns `_strokes: List<PdfInkAnnotation>`, the in-flight stroke buffer, mode/tool/style listenables, and all stroke mutations (`commitStroke`, `_applyEraseSegment`, `clear`, `setAll`, `importJson`, `setTool`, etc.).
- `@packages/pdfrx/lib/src/widgets/pdf_viewer.dart` (lines ~5346–5464) — `PdfViewerController` annotation method facade that delegates to the internal `PdfAnnotationController`.
- `@packages/pdfrx/example/music_viewer/lib/main_page.dart` (lines 94–145) — `_buildAnnotationToolbar` defines the existing toolbar with three sections separated by two `VerticalDivider`s (drag+tools | styling | reset+close).

Relevant existing patterns:
- All public annotation getters on `PdfViewerController` return `ValueListenable`s (`annotationModeListenable`, `annotationToolListenable`, `annotationStrokeColorListenable`, etc.). Follow this pattern.
- All public annotation setters on `PdfViewerController` are thin delegators to `PdfAnnotationController`.
- The toolbar uses `IconButton` (not `IconButton.filledTonal`) for non-toggle action buttons — see the existing reset/close buttons at lines 131–140.
</background>

<user_flows>
**Primary (pen)**:
1. User enters annotation mode and draws stroke A — undo button enables, redo stays disabled.
2. User draws stroke B — both stacks update (undo: [A0, A1], redo: []).
3. User taps undo — stroke B disappears from canvas; redo button enables.
4. User taps undo again — stroke A disappears; undo button disables, redo button still enabled.
5. User taps redo twice — strokes A then B reappear.

**Eraser**:
1. User draws stroke A (one undo entry pushed).
2. User performs an eraser pan that splits A into two sub-strokes A1 + A2 (one undo entry pushed at pan start).
3. User taps undo — A1/A2 are replaced by the original A.
4. User taps redo — A1/A2 reappear.

**Branch (redo invalidation)**:
1. User draws A, B. Undoes B (now: [A], redo:[B]).
2. User draws C. Redo stack is cleared. State: [A, C], no redo possible.

**Stack reset on session start**:
1. User exits annotation mode.
2. User re-enters annotation mode (with same or different `creatorName`).
3. Both stacks are empty; undo/redo buttons disabled. Strokes drawn in the prior session are still on canvas but cannot be undone.

**Mid-session style/creator updates do NOT clear history**:
- A caller that invokes `enterAnnotationMode(strokeColor: ...)` while annotation mode is already active applies the override but leaves the undo/redo stacks intact. Only the false→true mode transition is a session boundary.

**Reset-annotations stays destructive**:
1. User taps the existing reset (delete-all) button → confirmation dialog appears unchanged.
2. On confirm, all strokes are cleared AND both undo/redo stacks are cleared.
3. Both undo and redo buttons go disabled.

**Disabled-state UX**:
- Undo button visually disabled (greyed) when undo stack is empty.
- Redo button visually disabled when redo stack is empty.
- Calls to `controller.undo()` / `controller.redo()` while the corresponding stack is empty are no-ops (do not throw, do not notify).
</user_flows>

<requirements>
**Functional — controller layer (`PdfAnnotationController`)**:
1. Add `final List<List<PdfInkAnnotation>> _undoStack = []` and `final List<List<PdfInkAnnotation>> _redoStack = []`. Each entry is an immutable snapshot of `_strokes` taken **before** a mutation.
2. Add `final ValueNotifier<bool> _canUndo = ValueNotifier<bool>(false)` and `final ValueNotifier<bool> _canRedo = ValueNotifier<bool>(false)`. Expose them as `ValueListenable<bool> get canUndoListenable` and `ValueListenable<bool> get canRedoListenable`. Update them whenever the stacks change.
3. Add a private `_pushUndoSnapshot()` helper that snapshots the current `_strokes` (`List<PdfInkAnnotation>.unmodifiable(_strokes)`) onto `_undoStack`, clears `_redoStack`, and refreshes the two listenables.
4. Call `_pushUndoSnapshot()` immediately before any mutation that changes the committed stroke list as a result of user drawing or erasing:
   - `commitStroke()` — only when the in-flight stroke has ≥ 2 points (i.e., would actually be appended). Do **not** snapshot when the in-flight is discarded.
   - `startErase(...)` — once per pan, before invoking `_applyEraseSegment`.
   - `continueErase(...)` — **do not** snapshot here; one pan = one undo step.
   - `addStroke(stroke)` — push a snapshot before appending. Treat any external append as an undoable user-driven action, on the same footing as a successful `commitStroke`.
5. Add public `undo()`:
   - If `_undoStack` is empty, no-op.
   - Otherwise: snapshot current `_strokes` onto `_redoStack`, pop the top of `_undoStack` and replace `_strokes` with that snapshot's contents, refresh listenables, `notifyListeners()`.
6. Add public `redo()`:
   - If `_redoStack` is empty, no-op.
   - Otherwise: snapshot current `_strokes` onto `_undoStack`, pop the top of `_redoStack` and replace `_strokes` with that snapshot's contents, refresh listenables, `notifyListeners()`.
7. Clear both stacks (and refresh listenables) in:
   - `enterMode(...)` — **only on the false→true mode transition** (i.e., inside the existing `if (_modeListenable.value) return` early-return guard, before flipping the flag). Mid-session calls that only update style/creator/tool overrides must NOT clear undo history. Per-session clean slate happens at session start.
   - `clear()` — destructive reset; cannot be undone. Skip the stack-clear (and listenable refresh) when `_strokes.isEmpty` so the existing early-return optimization still holds and no spurious notifications fire.
   - `setAll(...)` — wholesale replacement (used by importers and external callers).
   - `importJson(...)` — already calls `setAll`, so this is covered transitively. Verify.
8. Dispose `_canUndo` and `_canRedo` in `dispose()`.

**Functional — public facade (`PdfViewerController`)**:
9. Add `void undo()` that delegates to `_annotationController.undo()`.
10. Add `void redo()` that delegates to `_annotationController.redo()`.
11. Add `ValueListenable<bool> get canUndoListenable => _annotationController.canUndoListenable`.
12. Add `ValueListenable<bool> get canRedoListenable => _annotationController.canRedoListenable`.
13. Place the new methods/getters together with the existing annotation methods (`enterAnnotationMode`, `exitAnnotationMode`, `setAnnotationTool`, etc.) following the surrounding doc-comment style. Document that the stacks reset on `enterAnnotationMode`.

**Functional — music_viewer toolbar (`main_page.dart`)**:
14. In `_buildAnnotationToolbar`, insert a new section between the existing styling group (color/thickness) and the existing reset/close group. Final section order, left → right:
    `[drag handle] [Pen] [Eraser] | [color if pen] [thickness] | [Undo] [Redo] | [reset] [close]`
15. The new section is bracketed by **two** `VerticalDivider`s using the existing styling: `VerticalDivider(width: 16, thickness: 1, indent: 8, endIndent: 8)`. The first divider replaces (i.e., reuses) the existing divider that currently separates styling from reset/close; the second divider is new and sits between Redo and the reset button. Net result: three dividers in the toolbar (one after Pen/Eraser, one after styling, one after Undo/Redo).
16. The two new buttons:
    - Undo: `IconButton` (plain, not filledTonal — matches the existing reset/close buttons), `tooltip: 'Undo'`, `icon: Icon(Icons.undo)`. `onPressed`: `() => controller.undo()` when undo is possible, otherwise `null` (which auto-disables the button).
    - Redo: `IconButton`, `tooltip: 'Redo'`, `icon: Icon(Icons.redo)`. `onPressed`: `() => controller.redo()` when redo is possible, otherwise `null`.
17. Wrap each button in a `ValueListenableBuilder<bool>` listening to `controller.canUndoListenable` / `controller.canRedoListenable` so the disabled state tracks the stack state without manual `setState`.

**Edge Cases**:
18. `commitStroke()` with < 2 points (degenerate) — must NOT push a snapshot (no real change happened).
19. Eraser pan/tap that touches no strokes (`startErase` finds nothing to remove) — snapshot is still pushed at pan start. This means an undo can pop a snapshot that restores to identical state (cosmetic no-op). Accepted as a tradeoff: the snapshot stays at `startErase` (one place, simple), versus hoisting it into `_applyEraseSegment` to skip pushes when `changed == false`. The simpler placement wins; user impact is tapping eraser on empty area then tapping undo and seeing nothing change, which is rare.
20. `setAll(...)` called externally during a session — clears both stacks. The currently-displayed strokes become the new baseline.
21. `clear()` called via the existing reset button — clears both stacks. The user cannot undo a reset.
22. Undo while a pen stroke is mid-pan: out of scope. Drawing locks input so `undo()` can't be called concurrently from the toolbar; if a caller invokes `undo()` programmatically during an in-flight stroke, the in-flight buffer remains untouched (we only mutate `_strokes`), so the next `commitStroke` will still push its own snapshot capturing the pre-undo state. No special handling required.
23. Foreign-creator strokes (multi-user mode) are part of every snapshot, but the eraser already preserves them — undoing/redoing eraser pans naturally restores them whether or not the current creator owned them.

**Validation**:
24. New listenables fire only when their boolean value actually flips (no spurious notifications when pushing a second entry onto an already-non-empty stack).
25. After `undo()` / `redo()`, `notifyListeners()` runs so the painter layer repaints.
</requirements>

<boundaries>
**Edge cases**:
- Undo with empty stack: no-op, no notify, no throw.
- Redo with empty stack: no-op, no notify, no throw.
- `enterMode` while already in mode: stacks are preserved. Only the false→true transition clears them. This protects callers that use `enterAnnotationMode(...)` mid-session to update creator/style.
- `exitMode` does not clear stacks. They survive the mode flip and are reset on the next false→true `enterMode`. The minor memory holdover between sessions is bounded by what the user accumulated in the just-ended session.
- Snapshots store immutable references (`List.unmodifiable`); `PdfInkAnnotation` is already an immutable model so individual stroke objects can be safely shared between snapshots.

**Error scenarios**:
- None expected. All operations are pure in-memory list manipulation. No I/O, no async.

**Limits**:
- Unbounded stack (per user direction). Memory cost: each snapshot is a `List<PdfInkAnnotation>` — references only, since `PdfInkAnnotation` instances are immutable and shared across snapshots. Practical cost is negligible until a single session contains thousands of mutations.
- Undo history is purely in-memory and per-session (cleared on `enterMode`). Not persisted to disk; reloading the document or re-entering annotation mode discards history.
</boundaries>

<implementation>
**Files to modify** (no new files):
1. `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart`
   - Add private fields: `_undoStack`, `_redoStack`, `_canUndo`, `_canRedo`.
   - Add public getters: `canUndoListenable`, `canRedoListenable`.
   - Add private helper: `_pushUndoSnapshot()`, `_refreshHistoryListenables()`.
   - Modify: `commitStroke` (snapshot before adding), `startErase` (snapshot before applying), `clear` (clear stacks), `setAll` (clear stacks), `enterMode` (clear stacks).
   - Add public methods: `undo()`, `redo()`.
   - Update `dispose()` to dispose the two new ValueNotifiers.

2. `packages/pdfrx/lib/src/widgets/pdf_viewer.dart`
   - Add four new public members on `PdfViewerController` (two methods + two getters), grouped with existing annotation members. Follow the surrounding doc-comment style.

3. `packages/pdfrx/example/music_viewer/lib/main_page.dart`
   - In `_buildAnnotationToolbar(...)`, insert the undo/redo section between the styling group (color/thickness) and the reset/close group, flanked by `VerticalDivider`s on both sides.

**Patterns to follow**:
- `List<PdfInkAnnotation>.unmodifiable(_strokes)` for snapshots — same pattern already used in the controller for read-only views.
- Restore via `_strokes..clear()..addAll(snapshot)` — the `_strokes` field is `final List<PdfInkAnnotation>` and must keep its reference. Do not reassign.
- Idempotent `ValueNotifier` updates: in `_refreshHistoryListenables()`, compute `_undoStack.isNotEmpty` / `_redoStack.isNotEmpty` and assign to the notifiers using the same compare-then-assign pattern as `setStrokeColor` (`if (notifier.value == newValue) return;`). This keeps listener notifications limited to actual flips.
- `ValueListenableBuilder<bool>` in the toolbar drives disabled state by passing `null` to `onPressed`.

**What to avoid**:
- Do **not** snapshot inside `appendPoint`, `continueErase`, `cancelStroke`, or any in-flight tick path — those fire on every pointer move and would explode the stack with intermediate states.
- Do **not** add undo/redo to style-only setters (`setTool`, `setStrokeColor`, `setStrokeWidth`, `setEraserRadius`) — they don't change the stroke list.
- Do **not** push a snapshot when `commitStroke` discards the in-flight (< 2 points). The committed list didn't change.
- Do **not** call `onAnnotationsChanged` from `undo()` / `redo()`. Persistence still happens on `exitAnnotationMode` as today; no behavioral change to the persistence callback.
- Do **not** introduce a new dependency or a generic command-pattern abstraction. Snapshot stack is the simplest correct design for this state shape.
</implementation>

<validation>
**Unit tests** — `packages/pdfrx/test/` (new file `annotation_undo_redo_test.dart` or extend an existing annotation test file if one exists; verify by listing `packages/pdfrx/test/`):

Behavior-first slices, written one at a time RED → GREEN → REFACTOR:
1. Fresh controller → `canUndoListenable.value == false`, `canRedoListenable.value == false`.
2. After `commitStroke` with ≥ 2 points → undo enabled, redo disabled.
3. After `commitStroke` with < 2 points → both still disabled (snapshot was not pushed).
4. After `undo()` from one-stroke state → strokes empty, undo disabled, redo enabled.
5. After `redo()` from previous state → original stroke restored, undo enabled, redo disabled.
6. `commitStroke A; commitStroke B; undo(); commitStroke C` → `_strokes == [A, C]`, redo disabled (branch invalidation).
7. `startErase` snapshot: draw a stroke, eraser pan splits it, `undo()` restores the original stroke exactly (`pointsInPdfSpace`, `lineWidth`, `strokeColor` equal).
8. `continueErase` does not push additional snapshots: drawing one stroke + one eraser pan with multiple `continueErase` samples yields stack depth of 2 (one for `commitStroke`, one for `startErase`), not more.
9. First `enterMode(...)` (false→true transition) clears both stacks. A subsequent `enterMode(strokeColor: ..., strokeWidth: ...)` call while still in mode applies the overrides but preserves the existing undo/redo stacks (verify by populating the stacks first, calling `enterMode` again, and asserting depth is unchanged).
10. `clear()` empties strokes AND empties stacks (both listenables go false).
11. `setAll(...)` clears both stacks.
12. `undo()` / `redo()` on empty stack are no-ops (no listener fires, no throw).

Mocking policy: zero mocks needed — `PdfAnnotationController` is pure in-memory state. Tests construct it directly and assert on `strokes` / listenable values.

**Public-surface tests** — extend `packages/pdfrx/test/widgets/annotations/pdf_viewer_controller_annotation_test.dart` (currently a single 11-line test verifying pre-mount listenable accessibility):
13a. `canUndoListenable.value == false` and `canRedoListenable.value == false` on a fresh `PdfViewerController` before mount.
13b. `controller.undo()` and `controller.redo()` on a fresh controller are no-ops (no throw, listenable values remain false). Guards against the delegation breaking silently if internal wiring drifts.

**Widget test** — annotation toolbar in music_viewer (or a thin reusable harness if one exists in `packages/pdfrx/example/music_viewer/test/`):
13. Enter annotation mode, simulate a `commitStroke` via the controller, find the Undo `IconButton` by tooltip, verify it is enabled, tap it, verify the canvas state cleared.
14. Initial state of the toolbar (no strokes drawn) → both Undo and Redo `IconButton`s have `onPressed == null` (disabled).

Stable selectors: use the existing tooltip strings (`'Undo'`, `'Redo'`) as `find.byTooltip(...)` selectors. Document this so future toolbar refactors keep the tooltips stable.

Deterministic seams: `PdfAnnotationController` is constructible without any platform/IO dependencies — no test seams needed beyond what already exists.

**Robot test** — out of scope. The undo/redo flow is a single-screen interaction inside an existing mode; the behavior is fully exercised by the unit + widget tests above. No cross-screen journey to script.

**Manual verification** (golden path):
15. Run `flutter run -d <device>` from `packages/pdfrx/example/music_viewer/`.
16. Open a PDF, tap the annotate FAB.
17. Confirm the new Undo/Redo buttons render between the styling section (color/thickness) and the reset/close section, with vertical dividers on both sides matching the existing dividers.
18. Verify both buttons are initially disabled.
19. Draw two strokes — Undo enables. Tap Undo twice — both strokes disappear; Undo disables, Redo enables.
20. Tap Redo twice — strokes reappear in order.
21. Erase part of a stroke — Undo enables; tap Undo — full stroke restored.
22. Draw a stroke, tap Undo (Redo enables). Tap reset (delete-all) and confirm — both Undo and Redo go disabled.
23. Exit and re-enter annotation mode — both buttons disabled even though strokes from the previous session still render.
</validation>

<done_when>
- `PdfViewerController.undo()`, `redo()`, `canUndoListenable`, `canRedoListenable` exist and are documented.
- `PdfAnnotationController` maintains undo/redo stacks with the lifecycle described above.
- The music_viewer annotation toolbar shows an Undo/Redo section flanked by `VerticalDivider`s with the exact styling used elsewhere in the toolbar.
- Both buttons reflect their stack state via the new listenables (disabled when empty).
- All unit tests in the validation list pass.
- `flutter analyze` is clean for `packages/pdfrx` and `packages/pdfrx/example/music_viewer`.
- Manual verification walkthrough (steps 15–23) succeeds.
</done_when>
