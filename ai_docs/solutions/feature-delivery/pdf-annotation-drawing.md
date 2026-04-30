---
title: Freehand PDF Annotation Drawing on pdfrx
date: 2026-04-29
work_type: feature
tags: [pdfrx, annotations, custompaint, gesture-detector, instant-json, controller-pattern]
confidence: high
references:
  - ai_specs/pdf-annotation-drawing.md
  - ai_specs/pdf-annotation-drawing-plan.md
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart
  - packages/pdfrx/lib/src/widgets/annotations/instant_json.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart
  - packages/pdfrx/example/music_viewer/lib/annotation_storage.dart
---

## Summary

Added a freehand annotation system to the `pdfrx` widget layer (no engine
changes), wired through `PdfViewerController` and persisted as Instant JSON
by the `music_viewer` example. The first iteration shipped as three phases
(render imported strokes → draw mode + persistence callback → music_viewer
integration) and was later extended in-place with highlighter, eraser,
undo/redo, and creator-scoped collaboration without breaking the original
controller surface.

## Reusable Insights

### Architectural seams

- **Keep Flutter types out of `pdfrx_engine/`.** Annotations are a
  widget-layer concern. The engine never imports `Color`/`Offset`/`Canvas`,
  so anything that needs them (Instant JSON codec, painter) lives in
  `packages/pdfrx/lib/src/widgets/annotations/`.
- **Document identity is the caller's responsibility.**
  `applyAnnotationsFromJson` and `exportAnnotationsAsJson` operate on the
  *currently loaded* document and do not look at `sourceName`, file path,
  or PDF fingerprint. Callers key persistence themselves
  (`<sha1(absolutePath)>.json` in `music_viewer`). Documenting this
  contract explicitly in dartdoc kept the controller small and
  reusable across apps with different identity schemes.
- **Append, don't replace, at the existing `pageOverlaysBuilder` site.**
  The annotation layer is mounted as a *second* `Positioned` after the
  user's overlay block in `_buildPageWidgets`. This guarantees the
  layer is always present even when callers also set
  `pageOverlaysBuilder`, with no public API collision.

### Repaint hygiene with multiple listenables

- A single `ChangeNotifier` is too coarse for live drawing. The
  `PdfAnnotationController` exposes **separate listenables for separate
  repaint cadences**:
  - `notifyListeners()` (main) — fires on commit, undo/redo, import,
    clear. The committed-strokes `CustomPainter` rebuilds on this only.
  - `inFlightChangedListenable` (a `ValueNotifier<int>` tick) — fires on
    every `appendPoint`. Only the live-draw painter listens, so the
    committed-strokes painter never repaints during a drag.
  - `eraserCursorChangedListenable` — same trick for eraser cursor preview.
  - `annotationModeListenable`, `currentToolListenable`,
    `strokeColorListenable`, `strokeWidthListenable`,
    `highlighterColorListenable`, `highlighterWidthListenable`,
    `eraserRadiusListenable`, `canUndoListenable`, `canRedoListenable`
    — for reactive UI without polling.
- The pattern ("one notifier per cost class") generalizes to any
  Flutter widget with both a low-frequency state machine and a
  high-frequency drag.

### "Always render, conditionally capture"

- The annotation layer is **always mounted**, but the `GestureDetector`
  is only mounted when `annotationModeListenable.value == true`,
  via a `ValueListenableBuilder<bool>` inside the layer. When mode is
  off, taps fall through to link handling and any caller-supplied
  overlays. When mode is on, `HitTestBehavior.opaque` swallows them.
- The detector is sized exactly to the per-page rect (it's mounted
  inside the per-page `Positioned`), so `details.localPosition` is
  already page-local — no offset arithmetic needed.

### Coordinate space discipline

- Stay in **top-left PDF-point space** (Instant JSON convention)
  throughout. The pipeline never traverses Pdfium's bottom-left native
  space at the widget layer, so no Y-flip is needed.
- Conversion is one-line each way:
  - Capture: `pdfX = local.dx * page.width / pageRect.width;`
  - Paint: `widgetX = pdfX * size.width / page.width;`
- Cross-page strokes are anchored to the start page, accumulate points
  beyond page bounds, and are visually clipped at paint time via
  `canvas.clipRect(Offset.zero & size)` as the painter's first call.

### Reactive pan/scale via private getters

- The viewer used to read `widget.params.panEnabled` /
  `widget.params.scaleEnabled` directly when building the
  `InteractiveViewer`. We replaced both reads with private getters
  (`_effectivePanEnabled`, `_effectiveScaleEnabled`) on
  `_PdfViewerState` that return `false` when annotation mode is on.
- A listener on `annotationModeListenable` calls `setState(() {})`
  on flip, causing the InteractiveViewer to rebuild with the new
  effective values. This rebuild is no worse than the existing
  `_togglePageMode` rebuild in the example, and it avoids leaking
  mode awareness into the params object.

### Document-change clear hook ordering matters

- `_onDocumentChanged` calls `_annotationController.clear()` **before**
  invoking the user's `params.onDocumentChanged`. The example's
  subsequent `onViewerReady` then calls `applyAnnotationsFromJson` on
  a guaranteed-clean slate. Inverting the order would race against
  caller-side imports.

### Async `onAnnotationsChanged` lets persistence finish

- `PdfAnnotationsChangedCallback` is `Future<void> Function(String)`.
  `exitMode` `await`s it before considering itself fully out of
  mode. This avoids lost writes when the app is backgrounded
  immediately after the close button — the file flush is part of the
  exit transition, not a fire-and-forget.

### Persistence as the caller's concern

- `<tempDir>/pdfrx_annotations/<sha1Hex(absolutePdfPath)>.json` —
  `path_provider`'s `getTemporaryDirectory` + `package:crypto` SHA-1.
- `annotation_storage.dart` exposes `annotationsFileFor`,
  `readAnnotations` (returns `null` on missing file or I/O error),
  `writeAnnotations` (always overwrites; never deletes),
  `deleteAnnotations`. All three accept `Directory? overrideTempDir`,
  defaulting to `null`. **This testability seam is what made
  unit-testing persistence trivial** — tests pass a
  `Directory.systemTemp.createTempSync(...)` instead of mocking
  `path_provider`.
- I/O errors are caught + logged inside the storage functions; the
  caller never sees them. In-memory state is authoritative for the
  rest of the session.

### Forward-compat for Instant JSON extensions

- The Instant JSON document is exported with no `pdfId` and no
  `skippedPdfObjectIds` (per Nutrient's storage guidance). New
  pdfrx-specific fields are namespaced (e.g. `pdfrx:kind` for
  pen-vs-highlighter, `creatorName` adopted via a non-namespaced
  field already in the schema).
- The decoder applies a **graceful-fallback rule** for new fields:
  if `pdfrx:kind` is missing/malformed, fall back to opacity-based
  inference (`opacity < 1.0 → highlighter`). This keeps legacy
  documents (no `pdfrx:kind`, opacity 1.0) round-tripping correctly
  while letting future kinds extend without dropping entries.

### Creator-scoped export for multi-user collaboration

- `enterMode(creatorName: ...)` tags new strokes with that creator;
  `exitMode` filters the JSON passed to `onAnnotationsChanged` to
  *only* strokes matching that creator. Foreign-creator strokes
  rendered for context never leak into the local user's persisted
  file.
- Single-user callers pass `creatorName: null` and get the full
  export. The eraser is also creator-scoped — foreign strokes
  survive untouched.

### Eraser as a stroke-splitter, not a deleter

- The eraser doesn't remove a whole stroke when touched. It tests each
  *segment* of a pen-stroke against the eraser segment (segment
  intersection + closest-point-to-segment within radius). Surviving
  runs are emitted as new sub-strokes (each ≥ 2 points). A single
  eraser pass can therefore split one stroke into many, or trim one
  end without affecting the other. Tail runs of < 2 points are
  dropped (cannot be painted).
- The geometry helpers (`_segmentsIntersect`,
  `_distancePointToSegment`) live next to the controller and are
  reusable for any "hit a polyline" test in the codebase.

## Decisions

- **Library-private `_PdfAnnotationController` ⇒ public
  `PdfAnnotationController`**. The spec called for an underscore-prefixed
  class accessed only via `PdfViewerController` methods, but Phase 1
  testing needed direct construction in unit tests. The class was
  renamed (no underscore) but is **not exported from `pdfrx.dart`** —
  tests reach in via `package:pdfrx/src/...`. Public callers still go
  through `PdfViewerController`. This kept the API surface small while
  unblocking unit tests.
- **Pen and highlighter share the controller; tools have separate
  color/width state.** Switching tools doesn't clobber the other tool's
  remembered settings — both `strokeColor`/`strokeWidth` (pen) and
  `highlighterColor`/`highlighterWidth` exist as independent
  listenables. Highlighter opacity comes from
  `PdfViewerParams.highlighterOpacity` at draw time.
- **`pdfrx:kind` for pen-vs-highlighter, not standardized opacity
  inference alone.** Opacity inference works for round-tripping legacy
  pen strokes but isn't future-proof; namespaced `pdfrx:kind` is the
  source of truth, with opacity inference as a tolerant fallback.

## Pitfalls

- **Test-binding cannot download pdfium.** `TestWidgetsFlutterBinding`
  mocks all HTTP and `pdfium_dart` cannot fetch its native binary, so
  any widget test that mounts `PdfViewer.uri` fails environmentally
  (independent of the changes here). Coverage shifted to:
  - pure-Dart unit tests for codec, controller, layer painter, ink
    value class, annotation storage,
  - widget tests that don't actually render PDFs (toolbar, journey),
  - manual smoke test for the per-page `GestureDetector` → controller
    wire (the one path with no automated coverage).
  Document this as a known testing gap rather than disabling tests
  silently.
- **Page rotation is hardcoded 0°.** All coord math assumes
  `pageRect.width / page.width` is the isotropic scale on both axes.
  Any rotated page will paint strokes in the wrong place. File a
  follow-up if observed; do not retrofit rotation handling
  speculatively.
- **`InteractiveViewer` rebuilds on every mode flip** because of the
  `setState(() {})` in `_PdfViewerState`'s mode listener. Acceptable
  per spec, but watch for jank on weaker devices.
- **Deferred widget-test infrastructure**: pan-gesture simulation on
  rendered pages, `InteractiveViewer.panEnabled` reactivity assertions,
  and stroke-clipping goldens are all explicitly out of scope for the
  initial iteration. Re-evaluate when the test harness can render PDFs.

## Validation

- Pure-Dart unit tests in `packages/pdfrx/test/`:
  - `instant_json_test.dart` — encode/decode round-trip, skip rules,
    bare-array tolerance, malformed JSON `FormatException`,
    empty-string handling, bbox computation, kind round-trip.
  - `pdf_annotation_controller_test.dart` — mode flip idempotency,
    `setAll` / `clear` / `addStroke` notifications,
    `startStroke`/`appendPoint`/`commitStroke`/`cancelStroke`
    lifecycle, separate inFlight tick, undo/redo, eraser
    splitting, creator-scoped export.
  - `pdf_annotation_layer_painter_test.dart` — painter coords + clip.
  - `pdf_ink_annotation_test.dart`,
    `pdf_viewer_controller_annotation_test.dart`,
    `pdfrx_public_exports_test.dart`.
- `packages/pdfrx/example/music_viewer/test/`:
  - `annotation_storage_test.dart` — round-trip,
    missing-file-returns-null, overwrite, SHA-1 keying (same path →
    same file; different paths → different files), all using
    `Directory.systemTemp.createTempSync`.
  - `main_page_annotation_toolbar_test.dart`,
    `highlighter_journey_test.dart`,
    `highlighter_toolbar_test.dart`.
- Run from each package: `flutter analyze && flutter test`. Both should
  be clean (only pre-existing warnings).
- Manual smoke test (per spec §Validation):
  1. `cd packages/pdfrx/example/music_viewer && flutter run`
  2. Open document A, tap edit FAB, draw cross-page strokes →
     confirm clipping at page boundary.
  3. Tap close → confirm toggle/skip/edit FABs and tap zones return.
  4. Skip to document B → A's strokes disappear.
  5. Cycle back → A's strokes reappear.
  6. Kill + relaunch → A's strokes still there.
  7. Toggle 1↔2 page mode → strokes track the new layout.

## Follow-ups

- Page-rotation support (deferred — file a ticket if any test corpus
  document is rotated).
- Pan-gesture-simulation widget tests for the per-page detector
  (deferred — needs harness work).
- Goldens for stroke clipping (deferred — verify by code inspection
  for now).
- Color/thickness pickers (out of scope for the initial iteration;
  later phases added a draggable toolbar in `music_viewer`).
- Eraser/undo/redo/highlighter were follow-up phases on this same
  branch — see commits `0442c27`, `fba09aa`, `1a103bb`, `1aae5f1`,
  `07295ed`, `77aab2f`.
