# PDF Annotation Drawing — Plan

## Overview

Add freehand annotation APIs to `pdfrx` (`PdfViewerController` methods + `PdfViewerParams.onAnnotationsChanged`) and wire `music_viewer` to draw → persist Instant JSON in temp files.

**Spec**: `ai_specs/pdf-annotation-drawing.md` (read for full requirements).

## Context

- **Structure**: flat `lib/src/widgets/` with `internals/` precedent. New code in `lib/src/widgets/annotations/`.
- **State management**: `PdfViewerController` (extends `ValueListenable<Matrix4>`) delegates to `_PdfViewerState`. New `_PdfAnnotationController` (`ChangeNotifier`, library-private) owned by `_PdfViewerState`; public methods on `PdfViewerController` delegate to it.
- **Reference implementations**:
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:4848+` — controller delegation pattern (`goToPage` etc.)
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:2237-2249` — `pageOverlaysBuilder` call site (mounting point for annotation layer)
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:296-368` — `didUpdateWidget → _widgetUpdated → _onDocumentChanged` chain (clear-on-doc-change)
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:508-509` — direct `widget.params.panEnabled/scaleEnabled` read
  - `packages/pdfrx/test/pdf_viewer_test.dart` — `MockClient` + `hello.pdf` widget-test pattern
  - `packages/pdfrx/example/music_viewer/lib/main_page.dart:186-200` — current `viewerOverlayBuilder` usage
- **Assumptions/Gaps**:
  - Page rotation = 0° (deferred per spec §17). If `hello.pdf` rotation breaks tests, file follow-up.
  - Pan-gesture-simulation widget tests deferred (spec "Known testing gaps"). Drawing input verified by manual smoke test.
  - `crypto` already in pdfrx pubspec; `flutter pub add crypto` from music_viewer should resolve cleanly via workspace.

## Plan

### Phase 1: Render imported annotations (end-to-end widget slice)

- **Goal**: Imported Instant JSON renders as ink strokes on the right pages. No drawing input yet.

- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart` — `PdfInkAnnotation` value class (`pageIndex`, `pointsInPdfSpace: List<Offset>` — top-left origin, `lineWidth`, `strokeColor`, `opacity`, `createdAt`, `updatedAt`).
- [x] `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — pure functions: `encodeInstantJson`, `decodeInstantJson({required pageCount, required defaultColor, required defaultLineWidth})`, `colorFromHex`, `colorToHex`, bbox helper.
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — library-private `_PdfAnnotationController` extends `ChangeNotifier`. Phase-1 surface: `strokes` getter, `setAll(List)`, `clear()`, `importJson(String, {required pageCount, ...})`. Mode/in-flight stuff deferred to Phase 2.
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — widget: `CustomPaint` with painter that scales PDF-point coords to widget pixels, `canvas.clipRect(Offset.zero & size)` first. Subscribes to controller via `AnimatedBuilder`. **No** `GestureDetector` yet.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — instantiated `PdfAnnotationController` (renamed from spec's `_PdfAnnotationController` so tests can import it directly via `package:pdfrx/src/...`; not exported from `pdfrx.dart`). Disposed in `dispose`. Added `applyAnnotationsFromJson`, `exportAnnotationsAsJson`, `clearAnnotations` on `PdfViewerController`. Per-page `PdfAnnotationLayer` mounted in `_buildPageWidgets` after the user's `pageOverlaysBuilder` widgets.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` (Phase-1 portion) — added `annotationStrokeColor` (default `Color(0xFFFF3B30)`) and `annotationStrokeWidth` (default `2.0`) so `applyAnnotationsFromJson` has stroke-style fallbacks. `onAnnotationsChanged` typedef + field deferred to Phase 2.
- [x] `packages/pdfrx/lib/pdfrx.dart` — re-export `pdf_ink_annotation.dart` + `instant_json.dart`.
- [x] TDD: `decodeInstantJson` happy path — wrapped JSON with one ink stroke decodes to one `PdfInkAnnotation` with correct page/points/color/lineWidth.
- [x] TDD: `decodeInstantJson` tolerates bare-array form `[{...}]`.
- [x] TDD: `decodeInstantJson` skips entries with unknown `type`, `v != 1`, out-of-range `pageIndex`, `< 2 points`.
- [x] TDD: `decodeInstantJson` of empty/whitespace string → empty list.
- [x] TDD: `decodeInstantJson` of malformed JSON → throws `FormatException`.
- [x] TDD: `encodeInstantJson` produces required fields (`v: 1`, `type: "pspdfkit/ink"`, `pageIndex`, `bbox`, `lines.points`, `lines.intensities`, `lineWidth`, `strokeColor`, `opacity`, `isDrawnNaturally: false`, ISO timestamps); root has `format: "https://pspdfkit.com/instant-json/v1"`, no `pdfId`.
- [x] TDD: encode → decode round-trip preserves stroke data (points within `1e-6` epsilon; color exact; lineWidth exact).
- [x] TDD: `_PdfAnnotationController.setAll` replaces strokes and bumps `notifyListeners` (counter listener).
- [x] TDD: `_PdfAnnotationController.clear` empties strokes and bumps `notifyListeners`.
- [~] Widget test (extend `pdf_viewer_test.dart`): mount viewer with `hello.pdf`, capture controller via `onViewerReady`, call `applyAnnotationsFromJson` with a hand-crafted single-stroke JSON for page 0, assert `find.byType(PdfAnnotationLayer)` finds the right number (≥ pages rendered). **DEFERRED**: the existing `PdfViewer.uri` widget test in `pdf_viewer_test.dart` fails because `TestWidgetsFlutterBinding` mocks all HTTP and `pdfium_dart` cannot download its native binary at test time (pre-existing blocker, unrelated to Phase 1 work). Coverage moves to manual smoke test in Phase 3 + unit-tested controller wiring.
- [x] Verify: `cd packages/pdfrx && flutter analyze && flutter test` — all new Phase-1 unit tests pass (8 tests). Pre-existing widget test failure is environmental.

### Phase 2: Drawing mode (input + persistence callback) ✓

- **Goal**: User can `enterAnnotationMode`, draw strokes via per-page `GestureDetector`, `exitAnnotationMode` fires `onAnnotationsChanged(json)` once with valid Instant JSON.

- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — extended with `annotationModeListenable` (ValueNotifier<bool>), `enterMode()`, `exitMode({onAnnotationsChanged})`, `addStroke`, in-flight buffer (`startStroke`/`appendPoint`/`commitStroke`/`cancelStroke`), `inFlightChangedListenable` (separate live-paint tick so committed-strokes painter doesn't repaint per move).
- [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — wraps `ValueListenableBuilder<bool>(annotationModeListenable, ...)`; when on, mounts `GestureDetector(behavior: opaque, onPanStart/Update/End/Cancel)`; converts `details.localPosition` → PDF points (top-left). Layer takes `newStrokeColor`/`newStrokeWidth` from params for new strokes.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` —
  - Public methods on `PdfViewerController`: `enterAnnotationMode`, `exitAnnotationMode`, `annotationModeListenable` getter.
  - Private getters `_effectivePanEnabled` / `_effectiveScaleEnabled` on `_PdfViewerState`; wired into the `InteractiveViewer` build.
  - `initState` attaches `_onAnnotationModeChanged` listener that calls `setState(() {})` on mode flips; `dispose` removes it.
  - `_goToPage`, `_goToArea`, `_goToRectInsidePage`, `_goToDest`, `_goTo`, `_goToManipulated` short-circuit when `annotationModeListenable.value == true`.
  - `_onDocumentChanged` calls `_annotationController.clear()` before the user `onDocumentChanged` fires.
- [x] `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — added `onAnnotationsChanged`, `PdfAnnotationsChangedCallback` typedef. `annotationStrokeColor` and `annotationStrokeWidth` already added in Phase 1.
- [x] `packages/pdfrx/lib/pdfrx.dart` — `PdfAnnotationsChangedCallback` exported transitively through `pdf_viewer_params.dart`.
- [x] TDD: controller `enterMode` flips listenable to `true`; second call is no-op (counter listener fires once).
- [x] TDD: controller `exitMode` flips listenable to `false` and awaits `onAnnotationsChanged` future before returning.
- [x] TDD: controller `exitMode` with `onAnnotationsChanged == null` completes without throwing.
- [x] TDD: controller stroke lifecycle — `startStroke` + `appendPoint` + `commitStroke` → `strokes.length == 1`, in-flight cleared, main `notifyListeners` bumped exactly twice (start, commit). `appendPoint` notifies via the separate `inFlightChangedListenable` tick to avoid rebuilding the committed-strokes painter on every move.
- [x] TDD: controller `cancelStroke` discards in-flight without committing.
- [x] TDD: controller `addStroke` appends and bumps notifications.
- [x] TDD: controller `exportJson()` output equals `encodeInstantJson(controller.strokes)`.
- [~] Widget test (extend `pdf_viewer_test.dart`): **DEFERRED** for the same environmental reason as Phase 1 (the existing `PdfViewer.uri` widget test already fails because pdfium binaries can't be downloaded in the test sandbox; adding more widget tests on the same harness would also fail). Coverage moves to manual smoke test in Phase 3 + the unit-tested controller wiring.
- [x] Verify: `cd packages/pdfrx && flutter analyze && flutter test test/instant_json_test.dart test/pdf_annotation_controller_test.dart` — analyze clean (only pre-existing warnings), all 16 unit tests pass.

### Phase 3: Music viewer integration

- **Goal**: User can tap edit FAB, draw, tap close → JSON written to temp file; reopening the document or restarting the app restores strokes; switching documents wipes UI and loads the next document's strokes (or none).

- [x] `packages/pdfrx/example/music_viewer/pubspec.yaml` — `flutter pub add crypto` from the music_viewer dir.
- [x] `packages/pdfrx/example/music_viewer/lib/annotation_storage.dart` — top-level async fns with optional `Directory? overrideTempDir`: `annotationsFileFor`, `readAnnotations` (returns `null` on missing), `writeAnnotations` (plain `writeAsString`). SHA-1 of absolute path → hex filename under `<tempDir>/pdfrx_annotations/`. Catch + log I/O errors.
- [x] `packages/pdfrx/example/music_viewer/lib/main_page.dart` —
  - New "edit" FAB (`Icons.edit`) wired to `controller.enterAnnotationMode()`. Stack vertically with existing toggle FAB at `Positioned(bottom: 32, left: 32, ...)` using a `Column(mainAxisSize: min, ...)`.
  - Wrap toggle FAB, edit FAB, and `Scaffold.floatingActionButton` (skip-next) each in `ValueListenableBuilder<bool>(controller.annotationModeListenable, ...)` returning `SizedBox.shrink()` while mode is on.
  - In `viewerOverlayBuilder`, wrap each entry (tap-zone Row + page indicator) in its own `ValueListenableBuilder<bool>` returning `SizedBox.shrink()` while mode is on.
  - Add `Positioned(bottom: 0, left: 0, right: 0, ...)` containing `Material` toolbar (~56px, `SafeArea(top: false)`) with one close `IconButton(Icons.close)` calling `controller.exitAnnotationMode()`. Wrap in `ValueListenableBuilder<bool>` so it shows only while mode is on.
  - In `PdfViewerParams`: `onAnnotationsChanged: (json) async => writeAnnotations(widget.pdfFilePaths[_fileIndex!], json)`.
  - In `onViewerReady` (after existing focus/event lines): `try { final json = await readAnnotations(widget.pdfFilePaths[_fileIndex!]); if (json != null) controller.applyAnnotationsFromJson(json); } catch (e) { debugPrint('annotation load failed: $e'); }`.
- [x] TDD (in `packages/pdfrx/example/music_viewer/test/annotation_storage_test.dart`): `writeAnnotations` then `readAnnotations` round-trips JSON when `overrideTempDir` is a fresh `systemTemp.createTempSync('annot_')`.
- [x] TDD: `readAnnotations` returns `null` for an absolute path that has never been written.
- [x] TDD: `writeAnnotations` overwrites prior content; `readAnnotations` returns the new content.
- [x] TDD: SHA-1-keyed filename — two writes with the same absolute path produce the same file; different paths produce different files (assert via two writes + listing the override temp dir).
- [ ] Manual smoke test (per spec §Manual smoke test) — **REQUIRES USER ACTION**:
  - `cd packages/pdfrx/example/music_viewer && flutter run`
  - Open doc A in 2-page mode, tap edit, draw two strokes including one crossing the page boundary; confirm crossing stroke is clipped at the right edge of the left page.
  - Tap close; confirm toggle/skip/edit FABs, page indicator, and tap zones return.
  - Tap skip-next to doc B; confirm doc A's strokes disappear.
  - Cycle back to doc A; confirm strokes reappear.
  - Kill + relaunch; confirm doc A still has its strokes.
  - Toggle to 1-page mode; confirm strokes still render in correct positions.
- [x] Verify: `cd packages/pdfrx/example/music_viewer && flutter analyze && flutter test` — analyze clean, all 4 storage tests pass.

## Risks / Out of scope

- **Risks**:
  - **Drawing input not covered by automated tests** — gesture simulation in widget tests is deferred. Manual smoke test is the only safety net for the per-page `GestureDetector` → controller wiring; regression risk if the layer changes.
  - **`InteractiveViewer` rebuild on every mode flip** — `setState(() {})` on `_PdfViewerState` rebuilds the page tree. Acceptable per spec (no worse than `_toggleMode` in music_viewer) but watch for jank on weaker devices.
  - **Page rotation = 0° assumption** — if any document in the test corpus has a rotated page, coords will be wrong. File follow-up if observed; not solved here.
- **Out of scope** (per spec):
  - Undo/redo, eraser, stroke deletion (`clearAnnotations()` exists but no UI).
  - Pressure/velocity (`intensities` filled with `1.0`).
  - Multi-touch drawing (single active pointer per page).
  - Color/thickness pickers (toolbar shows close button only).
  - Document-fingerprint identity beyond `sourceName` / file path.
  - `pdfrx_engine/` changes.
  - Goldens for stroke-clipping verification.
