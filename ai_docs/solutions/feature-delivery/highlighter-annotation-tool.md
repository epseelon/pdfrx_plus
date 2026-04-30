---
title: Highlighter Annotation Tool (vertical slice through pdfrx + music_viewer)
date: 2026-04-29
work_type: feature
tags: [pdfrx, annotations, highlighter, tdd, vertical-slice, journey-test, instant-json]
confidence: high
references:
  - ai_specs/highlighter-annotation-tool.md
  - ai_specs/highlighter-annotation-tool-plan.md
  - packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart
  - packages/pdfrx/lib/src/widgets/annotations/instant_json.dart
  - packages/pdfrx/example/music_viewer/lib/main_page.dart
  - packages/pdfrx/example/music_viewer/test/highlighter_journey_test.dart
  - packages/pdfrx/example/music_viewer/test/highlighter_toolbar_test.dart
---

## Summary

Added `PdfAnnotationTool.highlighter` end-to-end through pdfrx (model →
controller → layer → JSON → public API) and surfaced it in the
`music_viewer` toolbar with a journey test. Shipped in four
phases — model + render, JSON round-trip, public API, UI + journey —
each with unit/widget tests and `flutter analyze`/`flutter test` gates.
Built on the per-tool state pattern already established for pen + eraser.

## Reusable Insights

### Discriminator field on the value class, not parallel hierarchies

- One `PdfInkAnnotation` class with a `final PdfInkAnnotationKind kind`
  enum field is dramatically simpler than a `PenInkAnnotation` /
  `HighlighterInkAnnotation` split. The eraser, undo/redo, JSON
  encode/decode, and ownership filter all stay tool-agnostic — they
  thread `kind` through unchanged.
- Default the new field to the legacy value (`PdfInkAnnotationKind.pen`)
  in the constructor so existing callers compile unchanged. This
  single line is what made the change additive instead of breaking.

### Per-tool state lives on the controller; the toolbar multiplexes

- The controller holds **independent** `ValueNotifier`s for each tool's
  remembered settings: `_strokeColor`/`_strokeWidth` (pen),
  `_highlighterColor`/`_highlighterWidth`, `_eraserRadius`. Switching
  the active tool **does not clobber** the other tool's settings.
- Resist the urge to add a "tool-aware front" abstraction
  (`activeColor` / `activeWidth`). The toolbar already has a `switch`
  on `tool` — that's the right place for the multiplexing. A
  controller-side abstraction would push the conditional down into
  every setter and double the test surface.
- `enterMode` accepts override params for **every** tool's state
  regardless of which tool is active. `null` preserves the prior
  value. This lets integrators "preset" the highlighter on the same
  call that activates the pen, without forcing a tool switch.

### Forward-compat JSON: namespaced field with graceful fallback

- New JSON fields use a namespaced key (`pdfrx:kind`) to avoid
  colliding with future Instant JSON additions.
- The encoder **omits** `pdfrx:kind` for the default value (pen) so
  files written by this codebase remain byte-compatible with what
  predecessors wrote.
- The decoder reads the explicit field first, then falls back to a
  property-based heuristic (`opacity < 1.0 ? highlighter : pen`).
  Wrong-type or unknown values silently fall through to inference —
  **never drop the entry**. This pattern lets new kinds be added
  without re-migrating fixtures.

### Render seam: per-stroke cap/join, alpha-only blending

- `_InkPainter._paintStroke` was already a single chokepoint. Add a
  `switch (stroke.kind)` there to pick `StrokeCap.butt` /
  `StrokeJoin.miter` for highlighter, `StrokeCap.round` /
  `StrokeJoin.round` for pen.
- Translucency comes from `withValues(alpha: stroke.opacity)` — no
  `BlendMode.multiply`, no save layer. Keeps testing trivial and
  performance flat. Document the legibility trade-off (alpha at 0.35
  darkens the page); leave the multiply-blend escape hatch as a
  follow-up rather than wiring it preemptively.

### Constructor-injection > InheritedWidget for single-value plumbing

- `PdfViewerParams.highlighterOpacity` reaches the layer via a single
  required constructor parameter on `PdfAnnotationLayer`. The layer is
  rebuilt on params changes anyway (the param is on the
  `PdfViewerParams.==` / `hashCode` overrides), so InheritedWidget
  would only add ceremony.
- **Trap to remember**: when adding a field to a params class with
  manual `==`/`hashCode` overrides, **update both at once**. Forgetting
  one is a silent rebuild-skip bug — Flutter assumes the params are
  unchanged and never propagates the new value.

### Integrator vs user-tunable knobs

- `highlighterOpacity` is treated as an **integrator-level styling
  decision**, not a user-tunable per-session knob. No setter, no
  listenable, no `enterMode` parameter — runtime mutation requires a
  `PdfViewer` rebuild with new params. This kept the v1 surface tiny
  and avoided an opacity slider in the toolbar.
- The principle: every additional listenable adds widget rebuilds and
  test surface. If it's "set once at integration time," keep it on
  params. If it's "user changes per session," put it on the
  controller.

### Journey-test pattern: extract widgets, use a fake `PdfPage`

- Rather than mounting the full `MainPage` (which needs a real
  `PdfDocumentRef`), the journey test in
  `packages/pdfrx/example/music_viewer/test/highlighter_journey_test.dart`
  mounts the smallest toolbar-bearing subtree:
  - The extracted public `AnnotationToolButtons` widget (mirrors the
    earlier `AnnotationUndoRedoButtons` precedent).
  - A `PdfAnnotationLayer` with a `_FakePdfPage` stub whose
    `noSuchMethod` throws — the layer only reads `pageNumber`, `width`,
    `height`, so faking those three is enough.
- Drive the pan with `tester.dragFrom(layerCenter, Offset(60, 0))`.
  Find the toolbar buttons by stable **tooltip** selectors
  (`'Pen'`, `'Highlighter'`, `'Eraser'`,
  `'Highlighter color'`, `'Highlighter thickness'`).
- Assertion shape: capture the `onAnnotationsChanged` JSON, run it
  through `decodeInstantJson`, then assert on the resulting
  `PdfInkAnnotation` (kind, opacity, lineWidth). **Do not duplicate
  the wire-format assertion** — that belongs in `instant_json_test.dart`.
- This gets you a real journey assertion (tap → draw → exit → decode)
  without `integration_test/` infrastructure or a real PDF document.

### TDD vertical-slice ordering

The phase plan ordered slices to keep each phase shippable on its own:

1. **Model + render**: kind enum, `_InFlightStroke.kind`, painter
   branch. End state: programmatic highlighter pan paints translucent
   butt-capped strokes (no JSON, no UI).
2. **JSON**: encoder emission rule + decoder field-then-inference
   fallback. End state: highlighter strokes survive
   `encode → decode → encode`; legacy fixtures still pass.
3. **Public API**: `PdfViewerController` highlighter color/width
   getters/setters/listenables; `enterAnnotationMode` overrides.
   End state: integrators can drive the highlighter without
   reaching into the controller.
4. **Toolbar + journey test**: extract `AnnotationToolButtons`, wire
   palette + thicknesses, journey test through the public API.
   End state: user-facing critical path is testable + green.

Each phase had its own `flutter analyze && flutter test` gate. Worth
copying for any feature with model/render/persistence/UI layers.

## Decisions

- **Alpha-only blending over `BlendMode.multiply`.** Multiply requires a
  per-stroke save layer and complicates the painter test. Document the
  legibility trade-off and let integrators bump opacity if it falls
  short. Keep multiply as a follow-up trigger if real-world feedback
  demands it.
- **`pdfrx:kind` as namespaced field, not a top-level `kind`.** The
  Instant JSON schema is owned by Nutrient; namespacing extension
  fields keeps us out of their way.
- **Journey test mounts toolbar + layer, not `MainPage`.** Real
  `PdfDocumentRef`s are impractical in unit/widget tests. Extracting
  widgets is cheap and the assertion fidelity (decode-and-check) is
  identical.
- **Highlighter palette is fixed in the example app, not in the
  library.** The public controller accepts any `Color`. The
  music_viewer hardcodes the five-color palette as `static const`.

## Pitfalls

- **`PdfViewerParams.==` / `hashCode` divergence**. Forgetting to add
  the new field to either is a silent rebuild-skip. Update both
  simultaneously.
- **Stroke endpoint legibility with `StrokeCap.butt`**. On a slow
  trackpad, butt caps can look jagged at stroke start/end. Acceptable
  for v1; if smoothing becomes important, revisit per-segment caps or
  add a fade-in mask.
- **Cross-page `dartdoc` drift**. Adding pen-scoped state retroactively
  required updating the dartdoc on `_strokeColor`/`_strokeWidth` to
  clarify they apply *only* to pen. Easy to forget when the type
  signature didn't change.
- **Forgetting `kind` in eraser splitting**. `_splitStrokeByEraserSegment`
  reconstructs strokes from kept runs and **must** copy `s.kind` into
  every emitted sub-stroke. Spec requirement #3; covered by
  `controller.dart:_splitStrokeByEraserSegment`.

## Validation

- `cd packages/pdfrx && flutter analyze && flutter test`
- `cd packages/pdfrx/example/music_viewer && flutter analyze && flutter test`
- Manual smoke test (left for the user to run on macOS):
  1. Open a PDF, tap Annotate, verify three toolbar buttons.
  2. Highlighter draws translucent yellow at 12 pt with butt caps.
  3. Underlying notation/text remains readable through a 0.35-alpha
     stroke.
  4. Color/thickness selections update next stroke; previous strokes
     unchanged.
  5. Pen ↔ Highlighter swap preserves each tool's last color/thickness.
  6. Eraser splits highlighter strokes identically to pen strokes.
  7. Undo/redo participates with mixed strokes.
  8. Reopening the file restores highlighter strokes translucent +
     butt-capped, pen strokes opaque + round-capped.

## Follow-ups

- `BlendMode.multiply` for highlighter (if real-world legibility
  feedback escalates the alpha-blend trade-off).
- Per-stroke opacity slider in the toolbar (currently out of scope —
  opacity is integrator-only).
- Real PDF `/Highlight` text-attached annotations — a separate model
  (rectangle quads anchored to selected text) and a future spec.
- Additional freehand kinds (marker, brush) extend
  `PdfInkAnnotationKind` cleanly; anything text-attached belongs in a
  separate type.
