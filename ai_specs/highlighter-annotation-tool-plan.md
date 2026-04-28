# Plan: Highlighter annotation tool

## Overview

Add `PdfAnnotationTool.highlighter` (translucent, butt-capped, thicker) end-to-end through pdfrx and surface it in the `music_viewer` toolbar. Vertical slice: model → controller → layer/render → JSON → public API → UI + journey test.

**Spec**: `ai_specs/highlighter-annotation-tool.md` (read this for full requirements)

## Context

- **Structure**: monorepo. Library code in `packages/pdfrx/lib/src/widgets/annotations/`. Public surface in `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` + `pdf_viewer_params.dart`. Example app in `packages/pdfrx/example/music_viewer/`.
- **State management**: `ChangeNotifier` + per-field `ValueNotifier` on `PdfAnnotationController`; UI binds via `ValueListenableBuilder`.
- **Reference implementations**:
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — pen + eraser per-tool state pattern (mirror for highlighter).
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — pan dispatch + `_InkPainter._paintStroke`.
  - `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — `_encodeInkEntry` / `_decodeInkEntry`.
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:5346–5486` — annotation surface on `PdfViewerController`.
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:2271–2284` — `PdfAnnotationLayer(...)` construction site.
  - `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — `class PdfViewerParams` (line 14, 1833 LOC); `final double maxScale` + `==`/`hashCode` overrides at L710/L772 (no `copyWith`).
  - `packages/pdfrx/example/music_viewer/lib/main_page.dart` — toolbar in `_buildAnnotationToolbar` (L138); `AnnotationUndoRedoButtons` (L22) is the public-extracted-component precedent for journey tests.
  - `packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart` — toolbar widget-test pattern.
- **Assumptions/Gaps**: none. Spec is fully prescriptive. Dartdoc dedupe: when adding fields to `PdfViewerParams`, update both `==` (L710) and `hashCode` (L772).

## Plan

### Phase 1: Data model, controller per-tool state, render layer

- **Goal**: programmatically-drawn highlighter stroke renders translucent + butt-capped end-to-end (no JSON, no UI yet).
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart` — add `enum PdfInkAnnotationKind { pen, highlighter }`; add `final PdfInkAnnotationKind kind` to `PdfInkAnnotation` with constructor default `PdfInkAnnotationKind.pen`; dartdoc the taxonomy note (freehand only, not `/Highlight`).
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — add `highlighter` to `PdfAnnotationTool`; add `_highlighterColor` (default `Color(0xFFFFFF00)`), `_highlighterWidth` (default `12.0`) notifiers + `highlighterColor` / `highlighterWidth` getters + `*Listenable` + `setHighlighterColor` / `setHighlighterWidth` (idempotent); dispose both in `dispose()`; update dartdoc on `_strokeColor`/`_strokeWidth` to clarify "pen-scoped".
- [x] `pdf_annotation_controller.dart` — extend `enterMode` with `Color? highlighterColor`, `double? highlighterWidth` (null = preserve); applies regardless of active tool; dartdoc the behavior.
- [x] `pdf_annotation_controller.dart` — add `kind` to `_InFlightStroke`; `startStroke({..., required PdfInkAnnotationKind kind})`; `commitStroke` and `inFlightStrokesFor` propagate `kind` onto produced `PdfInkAnnotation`.
- [x] `pdf_annotation_controller.dart` — `_splitStrokeByEraserSegment` copies `s.kind` into every emitted sub-stroke.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — add `final double highlighterOpacity` (default `0.35`, clamp on read in layer); update `operator ==` (L710) and `hashCode` (L772) to include the new field; dartdoc that v1 has no runtime mutation path (rebuild required).
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — add `final double highlighterOpacity` ctor param (required); add `case PdfAnnotationTool.highlighter:` in `_onPanStart` / `_onPanUpdate` / `_onPanEnd` / `_onPanCancel` (mirror pen branch but use `controller.highlighterWidth`, `controller.highlighterColor`, `widget.highlighterOpacity.clamp(0.0, 1.0)`, `kind: PdfInkAnnotationKind.highlighter`).
- [x] `pdf_annotation_layer.dart` — pen branch passes `kind: PdfInkAnnotationKind.pen` explicitly to `startStroke`.
- [x] `pdf_annotation_layer.dart` — `_InkPainter._paintStroke` selects `StrokeCap.round`/`StrokeJoin.round` for `pen`, `StrokeCap.butt`/`StrokeJoin.miter` for `highlighter`; alpha-only blending unchanged.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:2278` — forward `params.highlighterOpacity` into the new `PdfAnnotationLayer` ctor param.
- [x] TDD: `PdfInkAnnotation` carries `kind`; default is `PdfInkAnnotationKind.pen`.
- [x] TDD: `controller.setHighlighterColor` / `setHighlighterWidth` are idempotent (no-fire on equal value).
- [x] TDD: `enterMode(highlighterColor:, highlighterWidth:)` updates highlighter state regardless of active tool; null preserves prior values.
- [x] TDD: a highlighter pan (programmatic via controller) commits a stroke with `kind == highlighter`, the controller's highlighter color/width, and opacity from params.
- [x] TDD: `_splitStrokeByEraserSegment` preserves `kind` across emitted sub-strokes (mixed pen + highlighter input).
- [x] TDD: `_InkPainter._paintStroke` uses `StrokeCap.butt` / `StrokeJoin.miter` for highlighter strokes (verify via `paints` matchers or paint-capture fixture).
- [x] Verify: `cd packages/pdfrx && flutter analyze && flutter test`

### Phase 2: JSON round-trip

- **Goal**: highlighter strokes survive `encode → decode`; legacy data still decodes correctly.
- [ ] `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — `_encodeInkEntry`: emit `'pdfrx:kind': 'highlighter'` only when `a.kind != PdfInkAnnotationKind.pen` (omit for pen → backwards-compatible).
- [ ] `instant_json.dart` — `_decodeInkEntry`: parse `pdfrx:kind` first (string `"pen"` / `"highlighter"`); on missing, malformed, or unknown value fall back to `opacity < 1.0 ? highlighter : pen`; pass `kind` into the `PdfInkAnnotation` constructor.
- [ ] TDD: encoder omits `pdfrx:kind` for pen entries; emits `'highlighter'` for highlighter entries.
- [ ] TDD: decoder round-trips kind from explicit `pdfrx:kind` field.
- [ ] TDD: decoder infers `highlighter` from `opacity < 1.0` when `pdfrx:kind` is missing.
- [ ] TDD: decoder tolerates `pdfrx:kind` with wrong type (e.g. `42`) and unknown string (e.g. `"marker"`) — falls back to opacity inference, never drops the entry.
- [ ] TDD: legacy fixture (no `pdfrx:kind`, `opacity == 1.0`) still decodes as `pen` — existing fixture-based tests must not regress.
- [ ] TDD: round-trip property — `decodeInstantJson(encodeInstantJson(strokes), …)` preserves `kind` on every entry (mixed list).
- [ ] Verify: `cd packages/pdfrx && flutter analyze && flutter test`

### Phase 3: Public API on `PdfViewerController`

- **Goal**: integrators can drive the highlighter via `PdfViewerController` only.
- [ ] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:~5400` — add `annotationHighlighterColor` getter, `setAnnotationHighlighterColor(Color)`, `annotationHighlighterColorListenable`; mirror style of `annotationStrokeColor*`.
- [ ] `pdf_viewer.dart` — add `annotationHighlighterWidth` getter, `setAnnotationHighlighterWidth(double)`, `annotationHighlighterWidthListenable`.
- [ ] `pdf_viewer.dart:5379` — extend `enterAnnotationMode` with `Color? highlighterColor`, `double? highlighterWidth`; forward to `_annotationController.enterMode`; dartdoc the per-tool override behavior.
- [ ] `packages/pdfrx/lib/pdfrx.dart` — verify `PdfInkAnnotationKind` is re-exported via the existing whole-file export of `pdf_ink_annotation.dart` (no change expected; assert with import-only smoke test or `dart pub publish --dry-run`).
- [ ] TDD: `PdfViewerController` highlighter color/width getters reflect setter values; listenables fire only on change.
- [ ] TDD: `enterAnnotationMode(highlighterColor: X, highlighterWidth: Y)` writes through to controller listenables even when active tool is pen.
- [ ] Verify: `cd packages/pdfrx && flutter analyze && flutter test`

### Phase 4: `music_viewer` toolbar + journey test

- **Goal**: user-facing critical path. Tap Highlighter → draw → exit → JSON decodes to a highlighter `PdfInkAnnotation`.
- [ ] `packages/pdfrx/example/music_viewer/lib/main_page.dart` — add `static const _highlighterColorPalette = [Color(0xFFFFFF00), Color(0xFF00FF00), Color(0xFFFF69B4), Color(0xFFFFA500), Color(0xFF00BFFF)]` and `static const _highlighterThicknesses = [8.0, 12.0, 16.0, 24.0]`.
- [ ] `main_page.dart` — extend `_colorName` with `Yellow / Green / Pink / Orange / Blue` (single function; no parallel lookup).
- [ ] `main_page.dart:_buildAnnotationToolbar` — replace `final isPen = ...` with `switch` over the three tools; insert `IconButton.filledTonal` between Pen and Eraser with `tooltip: 'Highlighter'`, `selectedIcon: Icon(Icons.highlight)`, `icon: Icon(Icons.highlight_outlined)`, `isSelected: tool == PdfAnnotationTool.highlighter`, `onPressed: () => controller.setAnnotationTool(PdfAnnotationTool.highlighter)`.
- [ ] `main_page.dart:_buildColorButton` — parameterize on `tool`; for `highlighter` bind to `controller.annotationHighlighterColorListenable` + `setAnnotationHighlighterColor`; tooltip `'Highlighter color'`; palette `_highlighterColorPalette`.
- [ ] `main_page.dart:_buildThicknessButton` — parameterize on `tool`; for `highlighter` bind to `controller.annotationHighlighterWidthListenable` + `setAnnotationHighlighterWidth`; tooltip `'Highlighter thickness'`; presets `_highlighterThicknesses`.
- [ ] `main_page.dart:_penThicknessPreview` — accept optional `double opacity = 1.0` so the highlighter preview renders translucent at ~0.35.
- [ ] `main_page.dart` — extract `AnnotationToolButtons` (or reuse existing pattern) as a public top-level widget mirroring `AnnotationUndoRedoButtons` so journey tests can mount the toolbar in isolation. Stable selector tooltips: `Pen`, `Highlighter`, `Eraser`, `Highlighter color`, `Highlighter thickness`.
- [ ] TDD (widget): toolbar shows three tool buttons; tapping `Highlighter` selects it (`annotationToolListenable` flips); color popup tooltip becomes `Highlighter color`; thickness popup tooltip becomes `Highlighter thickness`; selecting a swatch updates `annotationHighlighterColorListenable`.
- [ ] TDD (widget): when `tool == eraser`, only the eraser-radius popup shows.
- [ ] TDD (widget journey): mount the smallest toolbar-bearing subtree with a stub controller; enter mode → tap `Highlighter` → drive a programmatic pan via `WidgetTester.dragFrom` (or `TestPointer`) on the page-layer `GestureDetector` → exit mode → capture `onAnnotationsChanged` JSON → `decodeInstantJson` it → assert resulting `PdfInkAnnotation` has `kind == PdfInkAnnotationKind.highlighter`, `opacity == params.highlighterOpacity`, `lineWidth == controller.annotationHighlighterWidth`. Encoder wire-format assertion stays in `instant_json_test.dart` — do not duplicate here.
- [ ] Robot/journey selectors: `Pen`, `Highlighter`, `Eraser`, `Highlighter color`, `Highlighter thickness`. Deterministic seam: stable `Key` on the `PdfViewer` (or its toolbar) if not already present; fixed test `PdfViewerParams(highlighterOpacity: 0.35)`.
- [ ] Verify: `cd packages/pdfrx/example/music_viewer && flutter analyze && flutter test` and `cd packages/pdfrx && flutter analyze && flutter test`.
- [ ] Manual: spec `<validation>` steps 1–13 on macOS — translucency, legibility, butt caps, palette swap, undo/redo, persistence reload.

## Risks / Out of scope

- **Risks**:
  - Legibility under `srcOver` alpha: at `0.35` the page may darken under dense strokes. Mitigation = integrator lowers `PdfViewerParams.highlighterOpacity`. Multiply blend mode is out of scope.
  - `PdfViewerParams.==` / `hashCode` divergence: forgetting to add `highlighterOpacity` to either is a silent rebuild-skip bug. Update both at once.
  - Journey-test flakiness from non-deterministic `PdfDocumentRef`: extract toolbar to a parameterized widget (per `AnnotationUndoRedoButtons` precedent) rather than mounting a full `MainPage`.
- **Out of scope** (per spec):
  - Runtime-mutable highlighter opacity, per-stroke opacity slider, multiply blend mode, native PDF annotation baking, PDF `/Highlight` (text-attached) type, eraser/undo/redo changes, fixture migration.
