# Spec: Highlighter annotation tool

<context>
Today the music_viewer example only exposes pen + eraser annotation tools (`PdfAnnotationTool { pen, eraser }`). Musicians using the viewer have asked for a third tool: a highlighter that lays down a **thicker, translucent** stroke for marking up bars / lyrics / dynamics without obscuring the underlying notation.

The work is a **vertical slice through pdfrx + the example app**: the highlighter is a real first-class tool in the pdfrx public API (so any consumer of the library gets it), and the music_viewer toolbar wires it up as the user-facing surface. Rendering, persistence, undo/redo, and ownership-aware erasing must all behave consistently.
</context>

<goal>
Add a third annotation tool — `PdfAnnotationTool.highlighter` — to pdfrx and surface it in the `music_viewer` example toolbar.

A highlighter stroke is visually distinct from a pen stroke in three ways:
- **Translucent** color, default opacity `0.35` — configured by the integrator at construction time via `PdfViewerParams.highlighterOpacity` (no toolbar UI for it in v1; not user-mutable mid-session).
- **Much thicker** default range (8 / 12 / 16 / 24 pt vs pen 1–8 pt).
- **Flat (butt) stroke caps** for the classic rectangular-end highlighter look (vs pen's round caps).

The user can independently change the highlighter's **color** (from a classic palette: yellow / green / pink / orange / blue) and **thickness**. The active color and thickness are remembered separately for pen and highlighter, so toggling tools does not clobber the other tool's settings.

Erasing, undo/redo, ownership filtering, and JSON persistence must work for highlighter strokes the same as pen strokes.
</goal>

<background>
**Codebase**: Dart 3.9+, Flutter, pubspec workspace. Annotation system lives in `packages/pdfrx`.

**Files central to this change** (read these first):
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — owns `enum PdfAnnotationTool`, per-tool state, undo/redo, eraser geometry, in-flight stroke buffer.
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — per-page widget; pan handlers dispatch on tool, `_InkPainter._paintStroke` renders strokes.
- `@packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart` — immutable stroke model (no kind discriminator today).
- `@packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — `pspdfkit/ink` JSON round-trip. Encoder/decoder live here.
- `@packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — public `PdfViewerController` annotation methods + listenables (lines ~5351–5486). Forwards to the controller.
- `@packages/pdfrx/lib/pdfrx.dart` — public re-exports.
- `@packages/pdfrx/example/music_viewer/lib/main_page.dart` — toolbar UI to extend (the `_buildAnnotationToolbar`, `_buildColorButton`, `_buildThicknessButton` methods plus the constants `_annotationColorPalette`, `_penThicknesses`, `_eraserSizes`).

**Existing facts the design relies on**:
- `PdfInkAnnotation` already carries `opacity`. The pen hard-codes opacity=1.0 in `pdf_annotation_layer.dart:86`.
- The Instant JSON schema already round-trips `opacity`, `lineWidth`, `strokeColor`, `creatorName`.
- The eraser is geometry-based and tool-agnostic (`_applyEraseSegment` in the controller). It already erases any owned stroke regardless of how it was drawn — **no eraser changes are required**.
- The undo/redo system snapshots the full stroke list; new tools plug in for free as long as they go through `commitStroke` / `addStroke` / `_pushUndoSnapshot`.
- `_paintStroke` currently hard-codes `StrokeCap.round` and `StrokeJoin.round`. This must become per-stroke.

**Taxonomy note** (design intent — read before extending):
`PdfInkAnnotationKind.highlighter` (introduced below) means a **freehand highlighter pen** — a styled ink stroke. It is **not** the PDF `/Highlight` text-attached annotation type, which uses rectangle quads anchored to selected text. A real PDF highlight annotation would require a different model class entirely and is **out of scope** for this spec. Future contributors extending `PdfInkAnnotationKind` should restrict themselves to additional *freehand* variants (e.g. marker, brush) — anything text-attached belongs in a separate type.
</background>

<user_flows>

**Primary flow — drawing a highlight**
1. User taps the **Annotate** FAB → `enterAnnotationMode(creatorName: 'alice')`.
2. Toolbar appears showing Pen / Highlighter / Eraser buttons. Default tool = pen.
3. User taps **Highlighter** → toolbar swaps the color popup to the highlighter palette and the thickness popup to the highlighter range. The pen's previously-selected color/thickness are remembered but hidden.
4. User drags across a bar of music. A translucent yellow stroke (12 pt default) is drawn live with butt caps. The page text underneath remains readable.
5. On pan-end, the stroke is committed; undo becomes enabled.
6. User taps **Pen** → swatch & thickness popups revert to the pen's remembered settings.
7. User exits annotation mode → `onAnnotationsChanged` fires with Instant JSON containing both pen and highlighter strokes.

**Alternative flow — re-loading a saved document**
1. App starts, calls `controller.applyAnnotationsFromJson(savedJson)`.
2. Strokes saved as highlighter (with whatever opacity was configured when they were drawn — typically `0.35`, but whatever value `PdfViewerParams.highlighterOpacity` carried at draw time) decode back as highlighter strokes — translucent, butt-capped — without the user re-selecting any tool.
3. Pen strokes (opacity `1.0`) decode as pen — opaque, round-capped.

**Alternative flow — switching tools mid-session**
1. User sets pen color = red, pen thickness = 2 pt.
2. User switches to highlighter; selects yellow @ 12 pt; draws.
3. User switches back to pen; toolbar shows red @ 2 pt (preserved); user draws.
4. User switches to highlighter again; toolbar shows yellow @ 12 pt (preserved).

**Erasing flow**
1. User has a mix of pen + highlighter strokes from this session.
2. User taps **Eraser**, drags over a highlighter stroke. The highlighter stroke is split / removed by the same geometry the pen uses. Foreign-creator strokes are untouched, exactly as today.

**Undo/redo flow**
- A committed highlighter stroke pushes a snapshot. Undo removes it; redo restores it. Switching tools does **not** affect the undo stack (it's mode-scoped, not tool-scoped).

**Error / boundary flows**
- Imported JSON missing the `pdfrx:kind` field but with `opacity < 1.0`: decoded as highlighter (back-compat inference for legacy data written before the explicit field existed). With `opacity == 1.0`: decoded as pen.
- Imported JSON with malformed `pdfrx:kind` (wrong type, unknown string): ignored, fall back to opacity-based inference.
- User presses & releases (zero-length pan) with highlighter: nothing committed (same `< 2 points` rule as pen).
- User starts a highlighter stroke and the page rebuilds (e.g. layout flip): the in-flight stroke is cancelled (existing pen behavior — must apply unchanged).

</user_flows>

<requirements>

**Functional — data model**
1. Add `enum PdfInkAnnotationKind { pen, highlighter }` in `pdf_ink_annotation.dart`.
2. Add `final PdfInkAnnotationKind kind` field to `PdfInkAnnotation`. Default to `pen` in the constructor for backwards compatibility with existing callers.
3. The `_splitStrokeByEraserSegment` reconstruction (in `pdf_annotation_controller.dart`) must propagate `kind` to every emitted sub-stroke.

**Functional — tool enum & controller state**
4. Add `highlighter` to `enum PdfAnnotationTool` in `pdf_annotation_controller.dart`.
5. Add separate `ValueNotifier`s on `PdfAnnotationController`:
   - `_highlighterColor` — default `Color(0xFFFFFF00)` (yellow).
   - `_highlighterWidth` — default `12.0` (PDF points).
6. Add accessors: `highlighterColor`, `highlighterWidth`, `highlighterColorListenable`, `highlighterWidthListenable`, `setHighlighterColor`, `setHighlighterWidth`. Each setter is idempotent (no-op when value unchanged).
7. Existing `_strokeColor` / `_strokeWidth` keep their semantics — they are now retroactively scoped to the **pen** tool. Document this in dartdoc.
8. `enterMode` accepts new optional named parameters `highlighterColor` and `highlighterWidth` (mirroring the existing pen / eraser overrides). Null = preserve previous value. Overrides apply to controller state regardless of the active tool; visible UI changes only when the user (or a `tool:` override on the same call) selects that tool. Document this behavior in `enterAnnotationMode`'s dartdoc.
9. Highlighter opacity is configured by the integrator via a new `PdfViewerParams.highlighterOpacity` field — a `double` with default `0.35`, clamped to `[0.0, 1.0]` (assert in the `PdfViewerParams` constructor or clamp on read in the layer; pick one and document). The annotation layer reads this value at stroke-start time and stamps it onto the new stroke's `opacity`. There is **no** controller setter, **no** `ValueListenable`, and **no** `enterAnnotationMode` parameter for opacity in v1 — runtime mutation requires rebuilding `PdfViewer` with new params (acceptable: opacity is treated as an integrator-level styling decision, not a user-tunable per-session knob; toolbar UI for it is explicitly out of scope per the original spec choices). Already-committed strokes retain their committed `opacity`; only newly-drawn strokes see a changed value after a params rebuild.

**Functional — stroke commit path**
10. In `pdf_annotation_layer.dart`, `_onPanStart` / `_onPanUpdate` / `_onPanEnd` / `_onPanCancel` add a `case PdfAnnotationTool.highlighter:` branch that mirrors the pen branch but passes:
    - `lineWidth: controller.highlighterWidth`
    - `strokeColor: controller.highlighterColor`
    - `opacity: highlighterOpacity` — a new constructor parameter on `PdfAnnotationLayer` whose value is sourced from `PdfViewerParams.highlighterOpacity` at the call site in `pdf_viewer.dart` (the layer is rebuilt on params changes anyway; constructor-injection is preferred over inherited-widget plumbing for this single value).
    - `kind: PdfInkAnnotationKind.highlighter`
11. `PdfAnnotationController.startStroke` and `_InFlightStroke` gain a `kind` parameter/field. `commitStroke` propagates it onto the produced `PdfInkAnnotation`. `inFlightStrokesFor` propagates it onto the transient annotation.

**Functional — rendering**
12. `_InkPainter._paintStroke` selects `StrokeCap`/`StrokeJoin` based on `stroke.kind`:
    - `pen` → `StrokeCap.round`, `StrokeJoin.round` (unchanged).
    - `highlighter` → `StrokeCap.butt`, `StrokeJoin.miter`.
13. Color blending stays alpha-only (no `BlendMode` change). The translucent appearance comes from `withValues(alpha: stroke.opacity)`.

**Functional — JSON round-trip**
14. Encoder (`_encodeInkEntry`) writes `'pdfrx:kind': 'pen' | 'highlighter'` when `kind != pen` (omit for pen to keep the default emission compact and 100% backwards-compatible with files written before this feature shipped).
15. Decoder (`_decodeInkEntry`) reads kind in this order, first match wins:
    1. Explicit `pdfrx:kind` string field — accepts `"pen"` or `"highlighter"`.
    2. Inference from opacity: `opacity < 1.0` → `highlighter`, else `pen`.
16. Round-trip property: `decodeInstantJson(encodeInstantJson(strokes), …)` produces a list whose `kind` field on every entry equals the input's `kind`.

**Functional — public API surface**
17. `PdfViewerController` (in `pdf_viewer.dart`) gains:
    - `Color get annotationHighlighterColor` + `setAnnotationHighlighterColor(Color)` + `annotationHighlighterColorListenable`.
    - `double get annotationHighlighterWidth` + `setAnnotationHighlighterWidth(double)` + `annotationHighlighterWidthListenable`.
    - `enterAnnotationMode` gains `Color? highlighterColor` and `double? highlighterWidth` named parameters that forward to `enterMode`.

    `PdfViewerParams` (also in `pdf_viewer.dart`, or wherever the params class lives) gains:
    - `final double highlighterOpacity` — default `0.35`. Clamped to `[0.0, 1.0]` at construction (or on read in the layer — implementer's call). Set-once by the integrator; not user-mutable in v1.
18. `packages/pdfrx/lib/pdfrx.dart` re-exports `PdfInkAnnotationKind` (already exports `PdfInkAnnotation` from the same file).

**Functional — music_viewer toolbar**
19. Add a `Highlighter` `IconButton.filledTonal` between Pen and Eraser, using `Icons.highlight_outlined` / `Icons.highlight` (selected). Tooltip: `"Highlighter"`.
20. The selection state of all three buttons is driven by `tool` from `annotationToolListenable`. Selecting any button calls `controller.setAnnotationTool(<tool>)`.
21. When `tool == highlighter`, render two popups in place of the pen's:
    - **Color popup** bound to `controller.annotationHighlighterColorListenable` and `setAnnotationHighlighterColor`. Palette: `_highlighterColorPalette = [yellow #FFFF00, green #00FF00, pink #FF69B4, orange #FFA500, blue #00BFFF]`. Default selection = yellow.
    - **Thickness popup** bound to `controller.annotationHighlighterWidthListenable` and `setAnnotationHighlighterWidth`. Presets: `_highlighterThicknesses = [8.0, 12.0, 16.0, 24.0]`. The icon preview uses the current highlighter color rendered translucent (alpha ~0.35) inside the existing `_penThicknessPreview` helper (parameterize the helper to accept opacity, or add a `_highlighterThicknessPreview` mirror — implementer's choice).
22. When `tool == eraser`, only the eraser-radius popup shows (existing behavior, unchanged).
23. Color name lookup (`_colorName`) extends with the highlighter palette names: `"Yellow", "Green", "Pink", "Orange", "Blue"`. Add to the existing list — do **not** create a parallel function.

**Error handling**
24. `setAnnotationHighlighterColor` / `setAnnotationHighlighterWidth` are idempotent and never throw.
25. JSON decoding with an unknown `pdfrx:kind` string (e.g. `"marker"`): silently fall back to opacity-based inference. Do not skip the annotation.
26. Decoding old JSON with no `pdfrx:kind` and `opacity == 1.0` continues to round-trip as `pen`. **Existing fixture-based decoder tests must not regress.**

**Edge cases**
27. Switching tool while a stroke is in flight: the in-flight stroke is owned by the page widget that started it; the gesture detector for the new tool only takes effect on the **next** pan. Existing single-in-flight invariant (`controller.inFlightPageIndex`) covers this — no new logic needed, but verify in a widget test.
28. Highlighter stroke with fewer than 2 points (zero-length pan): discarded by `commitStroke`'s existing `points.length < 2` guard. No new code; verify in a unit test.
29. Eraser splits a highlighter stroke into two sub-strokes: both sub-strokes inherit `kind == highlighter` (covered by Requirement 3).
30. `clearAnnotations` removes highlighter strokes alongside pen strokes (existing behavior; verify).
31. `enterAnnotationMode(tool: PdfAnnotationTool.highlighter)` enters with highlighter as the active tool from frame 0, before any user interaction.

**Validation defaults & ranges**
32. Default highlighter color = yellow (`#FFFF00`).
33. Default highlighter width = 12.0 pt.
34. Highlighter palette is fixed in the example app; the public API accepts any `Color`. The decoder accepts any color too — no validation against the palette.

</requirements>

<boundaries>

**Edge cases**
- Mixed pen + highlighter strokes on the same page: render order = insertion order (existing behavior). Highlighter may visually pass over a pen stroke, dimming it slightly via alpha — acceptable, document.
- Foreign-creator highlighter strokes (e.g. loaded JSON from a different `creatorName`): rendered, but neither erasable nor exported by the current session. Identical to pen-stroke rules.
- A pen stroke imported with `opacity` accidentally < 1.0 (legacy data, not produced by this codebase): decoded as highlighter (per Requirement 15 fallback). Acceptable trade-off; this is the entire reason inference is the fallback, not the primary signal.

**Error scenarios**
- `setAnnotationHighlighterWidth(-1.0)` or `0.0`: stored as-is. The painter is responsible for clamping at render time. Match existing pen behavior — do not introduce new validation here.
- Decoder receives `pdfrx:kind: 42` (wrong type): treat as missing → opacity inference path.

**Limits**
- No upper bound on highlighter thickness in the public API. The example toolbar caps at 24 pt by exposing only that preset.

**Out of scope**
- **Runtime-mutable highlighter opacity from the toolbar / end-user UI.** The integrator can configure it via `PdfViewerParams.highlighterOpacity` (default 0.35); changing that value mid-session requires a `PdfViewer` rebuild. No setter, listenable, or per-session enterAnnotationMode override in v1.
- Per-stroke opacity slider in the UI.
- Multiply blend mode (alpha blending only — see legibility note in `<validation>` step 5; integrators can bump opacity if it falls short).
- Native PDF annotation baking (Instant JSON only, same as today).
- Real PDF `/Highlight` text-attached annotations (see `<background>` taxonomy note — those are a separate model and a future spec).
- Any change to eraser geometry or undo/redo.
- Migrating existing on-disk fixtures — they continue to decode as pen via the opacity-1.0 fast path.

</boundaries>

<implementation>

**Files to modify** (in suggested order)

1. **`packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart`**
   - Add `enum PdfInkAnnotationKind { pen, highlighter }`.
   - Add `final PdfInkAnnotationKind kind` to `PdfInkAnnotation` with `this.kind = PdfInkAnnotationKind.pen` default in the constructor.

2. **`packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart`**
   - Add `highlighter` to `PdfAnnotationTool`.
   - Add `_highlighterColor`, `_highlighterWidth` notifiers + getters/setters/listenables.
   - Extend `enterMode` signature with `highlighterColor`, `highlighterWidth`.
   - Extend `startStroke` and `_InFlightStroke` with `kind`. Propagate through `commitStroke` and `inFlightStrokesFor`.
   - Update `_splitStrokeByEraserSegment` to copy `s.kind` into each emitted sub-stroke.
   - Dispose the new notifiers in `dispose()`.
   - Update dartdoc on `_strokeColor` / `_strokeWidth` to clarify they are pen-scoped.
   - **Note**: opacity is *not* controller state — it lives on `PdfViewerParams`. The controller's `startStroke` continues to take an `opacity` parameter from the caller (the layer).

3. **`packages/pdfrx/lib/src/widgets/annotations/instant_json.dart`**
   - Encoder: when `a.kind != PdfInkAnnotationKind.pen`, add `'pdfrx:kind': 'highlighter'`.
   - Decoder: parse `pdfrx:kind` first; on miss/unknown, fall back to `opacity < 1.0 ? highlighter : pen`. Pass `kind` into the `PdfInkAnnotation` constructor.

4. **`packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart`**
   - Add a `final double highlighterOpacity` constructor parameter on `PdfAnnotationLayer` (required, no default — the caller in `pdf_viewer.dart` is responsible for sourcing it from `PdfViewerParams.highlighterOpacity`).
   - In `_onPanStart` / `_onPanUpdate` / `_onPanEnd` / `_onPanCancel`, add a `case PdfAnnotationTool.highlighter:` branch (mirrors pen but reads color/width from the controller's highlighter state and uses the constructor-injected `highlighterOpacity` for opacity, with `kind: PdfInkAnnotationKind.highlighter`).
   - In `_InkPainter._paintStroke`, branch on `stroke.kind` to set `strokeCap` and `strokeJoin`.

5. **`packages/pdfrx/lib/src/widgets/pdf_viewer.dart`** (`PdfViewerController` annotation section, ~lines 5351–5486; `PdfViewerParams` wherever it lives)
   - `PdfViewerController`:
     - Add `annotationHighlighterColor` / `setAnnotationHighlighterColor` / `annotationHighlighterColorListenable`.
     - Add `annotationHighlighterWidth` / `setAnnotationHighlighterWidth` / `annotationHighlighterWidthListenable`.
     - Add `highlighterColor` / `highlighterWidth` named params to `enterAnnotationMode`.
   - `PdfViewerParams`:
     - Add `final double highlighterOpacity = 0.35` (or `required` with a default in the constructor — match the existing params style; spot-check `pdf_viewer_params.dart` first).
   - At the call site that mounts `PdfAnnotationLayer`, forward `params.highlighterOpacity` into the layer's new constructor parameter.

6. **`packages/pdfrx/lib/pdfrx.dart`**
   - Already exports the whole `pdf_ink_annotation.dart`, so `PdfInkAnnotationKind` is exported automatically. Verify, no change needed.

7. **`packages/pdfrx/example/music_viewer/lib/main_page.dart`**
   - Add `_highlighterColorPalette` and `_highlighterThicknesses` constants alongside the existing pen ones.
   - Extend `_colorName` with the new palette colors.
   - In `_buildAnnotationToolbar`: replace the binary `isPen` switch with `final tool = ...` switch over the three tools; add the Highlighter `IconButton.filledTonal`.
   - In `_buildColorButton` and `_buildThicknessButton`: parameterize on tool (or add highlighter-specific copies — implementer's choice; keep DRY where natural). Bind to the appropriate listenable / setter / palette / thickness preset based on `tool`.
   - Optionally extend `_penThicknessPreview` to accept an `opacity` parameter so the highlighter preview tile in the popup looks translucent. (Strictly cosmetic — fine to skip in v1.)

**Patterns to reuse**
- Existing `ValueListenable` + `ValueListenableBuilder` plumbing — copy verbatim.
- `IconButton.filledTonal` selection pattern from the existing Pen/Eraser toggle.
- `CheckedPopupMenuItem` palette pattern from `_buildColorButton`.
- `_pushUndoSnapshot` invocations on `commitStroke` — already covers highlighter strokes for free.

**What to avoid**
- Do **not** add a `BlendMode.multiply` path. The user agreed alpha-blended is acceptable; multiply requires a save layer per stroke and complicates testing.
- Do **not** introduce a parallel "active values" abstraction (e.g. `activeColor` / `activeWidth` as a tool-aware front for both pen and highlighter). Keep the per-tool methods explicit. The toolbar already conditions on `tool` — that's the right place for the multiplexing.
- Do **not** break `decodeInstantJson` on JSON that lacks `pdfrx:kind`. The opacity-fallback path is mandatory for backwards compatibility.

</implementation>

<validation>

**Test split** (default mapping — deviate only with stated justification):
- **Unit (Dart) tests** — logic, state transitions, JSON round-trip. Most coverage lives here.
- **Widget tests** — toolbar UI variants, screen-level edge cases (cancel stroke, switch tools mid-session).
- **Widget journey test** in `music_viewer` — the **highlighter happy path** driven via stable tooltip selectors: enter mode → tap Highlighter → drag a stroke → exit mode → assert callback JSON decodes back to a highlighter `PdfInkAnnotation`. **No `integration_test/` infrastructure is required for this spec**; the existing `AnnotationUndoRedoButtons` widget-test pattern in `packages/pdfrx/example/music_viewer/test/` is the model. If a future spec wants device-level journey coverage, it can introduce that scaffolding then.

**TDD discipline (consult `act-flutter-tdd`)**: implement behavior-first, one slice at a time. Suggested vertical-slice order:
1. RED: a unit test asserting `PdfInkAnnotation` carries a `kind` field defaulting to `pen`. GREEN: add the field. REFACTOR.
2. RED: encoder emits `pdfrx:kind` only for highlighter. GREEN. REFACTOR.
3. RED: decoder round-trips kind from explicit field. GREEN. REFACTOR.
4. RED: decoder infers highlighter from opacity < 1.0 when field is missing. GREEN.
5. RED: controller `setHighlighterColor` / `setHighlighterWidth` updates listenables idempotently. GREEN.
6. RED: `commitStroke` from a highlighter pan produces an annotation with `kind == highlighter`, opacity 0.35, the controller's highlighter color/width. GREEN.
7. RED: `_splitStrokeByEraserSegment` preserves kind on emitted sub-strokes. GREEN.
8. RED: painter renders highlighter strokes with `StrokeCap.butt`. GREEN. (Painter test via `paints` matchers from `package:flutter_test`.)
9. RED (widget): toolbar shows highlighter palette + presets when active tool is highlighter. GREEN.
10. RED (widget journey): mount `MainPage` (or its toolbar-bearing subtree) with stub document state, drive the highlighter happy path via tooltip selectors, capture the `onAnnotationsChanged` JSON, and assert that decoding it via `decodeInstantJson` yields a `PdfInkAnnotation` with `kind == PdfInkAnnotationKind.highlighter`. GREEN.

**Required testability seams**
- Controller already accepts injected dependencies for time / RNG implicitly — no new seams needed.
- Painter tests can construct `_InkPainter` directly with a fixture `List<PdfInkAnnotation>` and verify via `paint` capture.
- Widget journey test for the music_viewer app uses the existing `'Undo'` / `'Redo'` tooltip pattern. Add stable selectors:
  - Pen button tooltip: `'Pen'` (already exists).
  - Highlighter button tooltip: `'Highlighter'` (new — required selector).
  - Eraser button tooltip: `'Eraser'` (already exists).
  - Highlighter color popup tooltip: `'Highlighter color'` — distinguishes it from the pen's `'Color'`.
  - Highlighter thickness popup tooltip: `'Highlighter thickness'`.
- Drawing flow inside the widget journey test: use `WidgetTester.dragFrom(...)` (or `TestPointer`) on the annotation layer's `GestureDetector`. Ensure the page render rect is deterministic — the music_viewer already uses fixed test fixtures, but add a stable `Key` to the `PdfViewer` if not already present.
- If extracting `MainPage` for a widget test is impractical (e.g. it requires a real `PdfDocumentRef`), follow the `AnnotationUndoRedoButtons` precedent: extract a public, parameterized component (e.g. `AnnotationToolButtons`, `AnnotationColorPopup`) that the test can mount in isolation. The journey-test scope can then be the smallest extracted seam that covers tool selection + popup binding.

**Mocking policy**: prefer fakes / real instances. Mock only true external boundaries (file I/O for `readAnnotations` / `writeAnnotations` in the example). The `PdfAnnotationController` is internal logic — test it directly.

**Manual validation steps**
1. `cd packages/pdfrx/example/music_viewer && flutter run` on macOS / iOS sim.
2. Open a PDF, tap **Annotate**.
3. Verify three toolbar buttons: Pen, Highlighter, Eraser.
4. Tap **Highlighter**: swatch becomes a yellow circle, thickness preview becomes a 12 pt translucent yellow bar.
5. Drag across some text/notation. Verify three things:
   - **Translucency**: stroke is clearly translucent yellow, not solid.
   - **Legibility (concrete criterion)**: the underlying notation/text under the stroke remains *identifiable at a glance* — i.e. you can still read the notes/lyrics/words without effort. With `srcOver` alpha at 0.35, the page will visibly darken (toward yellow); if it darkens to the point that black text becomes hard to read on white paper, that is a *real* problem with this spec's blend-mode trade-off. **Mitigation path**: an integrator can lower `PdfViewerParams.highlighterOpacity` (e.g. to 0.2–0.25) — lower opacity → less darkening, but also fainter highlight. If even 0.2 fails the legibility check, escalate as a follow-up to revisit the multiply-blend-mode decision (currently out of scope).
   - **Stroke endpoints**: ends look intentional, not abruptly cut. With `StrokeCap.butt` the stroke begins/ends exactly at the first/last sample point (no rounded lead-in). On a slow trackpad this can look jagged; if it does, note it but do not block on it for v1.
6. Tap a different highlighter color (e.g. pink) → swatch updates; next stroke is pink @ 12 pt.
7. Tap a different thickness (e.g. 24 pt) → next stroke is pink @ 24 pt; previous strokes unchanged.
8. Tap **Pen** → swatch returns to whatever pen color was last selected; thickness returns to last pen thickness.
9. Draw a pen stroke, an eraser pass over the highlighter — highlighter splits/erases identically to pen.
10. Tap **Undo** / **Redo** repeatedly — both pen and highlighter strokes participate.
11. Exit annotation mode → no errors; `onAnnotationsChanged` fires.
12. Close the document and re-open the same file — saved highlighter strokes reappear translucent and butt-capped; saved pen strokes opaque and round-capped.
13. Run `flutter test` in `packages/pdfrx` and the example — all new + existing tests pass.

**Coverage outcomes required**
- Logic: kind round-trip, controller per-tool state, eraser kind preservation, undo/redo across mixed strokes.
- UI: toolbar variants per tool, popup bindings, selection state.
- Critical journey (widget journey test): enter mode → tap Highlighter → drag → exit → captured JSON decodes to a highlighter `PdfInkAnnotation` with the configured opacity and width.

</validation>

<done_when>
1. `flutter analyze` is clean across `packages/pdfrx` and `packages/pdfrx/example/music_viewer`.
2. `flutter test` in `packages/pdfrx` passes, including new tests for: `PdfInkAnnotationKind` field & default, encoder emission rule, decoder explicit-field path, decoder opacity-inference fallback, eraser kind preservation, controller per-tool state idempotence, painter stroke-cap branching.
3. `flutter test` in `packages/pdfrx/example/music_viewer` passes, including a widget test that the toolbar exposes a `'Highlighter'`-tooltipped button and that selecting it swaps the color & thickness popups to highlighter-tooltipped variants.
4. A widget journey test in `music_viewer` (using stable tooltip selectors, no `integration_test/` infrastructure) drives the user flow — enter annotation mode, tap **Highlighter**, drag a stroke, exit mode — captures the `onAnnotationsChanged` JSON, decodes it via `decodeInstantJson`, and asserts the resulting `PdfInkAnnotation` has `kind == PdfInkAnnotationKind.highlighter`, `opacity == params.highlighterOpacity` (the value passed to the test's `PdfViewerParams`), and `lineWidth == controller.annotationHighlighterWidth` (the value selected during the test). The encoder's specific `pdfrx:kind` JSON-key emission is covered by a separate unit test in `instant_json_test.dart` (Requirement 14) — do not duplicate the wire-format assertion here.
5. Manual validation steps 1–13 in `<validation>` all pass on macOS.
6. No regressions in existing pen / eraser / undo / redo / persistence behavior — verified by the pre-existing test suite passing without modification (other than the additive `kind` defaulting).
7. `packages/pdfrx/lib/pdfrx.dart` re-exports `PdfInkAnnotationKind` (transitively, via the existing `pdf_ink_annotation.dart` export — verify with `dart pub publish --dry-run` or a simple downstream import test).
</done_when>
