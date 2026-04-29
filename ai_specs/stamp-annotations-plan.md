# Stamp annotations — implementation plan

## Overview

Add `PdfAnnotationTool.stamp` to pdfrx + wire stamp library/picker into music_viewer. Stamps as widgets in per-page Stack; bytes embedded in Instant JSON via SHA-256 attachments. Three phases: thin end-to-end place+persist (Phase 1), selection/manipulation (Phase 2), asset loader + journey test (Phase 3).

**Spec**: `ai_specs/stamp-annotations.md` (read for full requirements)

## Context

- **Structure**: monorepo workspace; only `packages/pdfrx` + `packages/pdfrx/example/music_viewer` touched. Annotation engine: `packages/pdfrx/lib/src/widgets/annotations/`.
- **State management**: `ChangeNotifier` controller + per-axis `ValueNotifier`s; idempotent setters (`if (_x.value == value) return; _x.value = value;`).
- **Reference implementations**:
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — pattern for state, listenables, undo snapshots, in-flight tick (`_inFlightTick:33`).
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — per-page `Stack { CustomPaint + Positioned.fill(GestureDetector) }`; `_toPdfSpace:166`.
  - `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — encode/decode shape, `colorFromHex`/`colorToHex` reusable.
  - `packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart` — model conventions (immutable `const`, `///` doc comments).
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:2272-2286` — layer mount site (per-page `Positioned`, NOT inside InteractiveViewer's transformed subtree → handles must stay inside bbox).
  - `packages/pdfrx/lib/src/widgets/pdf_viewer.dart:5387-5520` — controller forwarder pattern.
  - `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart:14-89` — `@immutable const` params with assert-in-body.
  - `packages/pdfrx/example/music_viewer/test/highlighter_journey_test.dart:102-115` — `_FakePdfPage` to promote.
- **Conventions**: relative imports inside `lib/`; single quotes; 120-char lines; `snake_case.dart`; `ValueListenable<T>` getters over `ValueNotifier<T>` fields; `///` doc comments on every public symbol.
- **Deps**: `crypto: ^3.0.6` + `dart:convert.base64Encode/Decode` already available in pdfrx; `flutter_svg` to add to music_viewer only.
- **Assumptions**:
  - Use `String Function() idGenerator` seam for ULIDs (caller-injected). Pick `^4.0.0 collection` already in deps; ULIDs hand-rolled (24-char random hex acceptable — IDs are local).
  - SHA-256 collision detection out of scope (#41 in spec).
  - `_pickerOpen` lives in `_MainPageState`, not the controller (per spec).
  - Drag in stamp tool but no pending stamp + no selection = consumed no-op (per spec #21).

## Plan

### Phase 1 — Vertical slice: place a stamp, persist, reload

- **Goal**: end-to-end: pick a stamp → tap to place → see it render → exit mode → JSON written w/ embedded attachment → relaunch → stamp reloads. No selection/move/resize yet.
- **Tasks (pdfrx)**:
  - [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_definition.dart` — new file. `PdfStampDefinition` (immutable `const`, fields `id/name/contentType/bytesLoader/intrinsicSize`, asserts on non-empty + positive size). `PdfViewerStampCategory` (immutable `const`, fields `id/title/stamps`, assert non-empty id). `///` doc comments. (Note: `PdfStampDefinition` ended up non-`const` because `Size.width`/`height` access in the size assert isn't const-evaluable; `@immutable` lint suppressed at the constructor.)
  - [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_annotation.dart` — new file. `PdfStampAnnotation` (immutable `const`, fields `id/pageIndex/rectInPdfSpace/rotationDeg/attachmentSha256/contentType/createdAt/updatedAt/creatorName`).
  - [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — add `PdfAnnotationTool.stamp`. Add fields: `_stamps: List<PdfStampAnnotation>`, `_attachments: Map<String, PdfStampAttachment>`, `_pendingStamp: ValueNotifier<PdfStampDefinition?>`, `_selectedStampId: ValueNotifier<String?>`, `_stampDragTick: ValueNotifier<int>`. Expose listenables (`stamps` getter via the existing controller-as-Listenable; `pendingStampListenable`, `selectedStampIdListenable`, `stampDragChangedListenable`). Methods: `setPendingStamp`, `clearStampSelection`, `selectStamp`, `placeStamp(...)`, `deleteStamp(String id)` (no-op for foreign creator). Generalized undo snapshot to `_AnnotationSnapshot { strokes, stamps, attachments }`. `clear()` clears stamps + attachments + selection + history. `dispose()` releases the new ValueNotifiers. `_kDefaultStampLongestSidePts = 36.0` constant. `placeStamp` wraps synchronous failures in `try { ... } catch (e, st) { debugPrint(...); }` and aborts cleanly.
  - [x] `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — extended `encodeInstantJson` (optional `stamps:`/`attachments:` parameters); emits `pspdfkit/image` entries with `v: 1`, `bbox`, `contentType`, `imageAttachmentId`, `rotation` (snapped) + `pdfrx:rotation` (free float), `id`, optional `creatorName`. Top-level `attachments` map omitted when empty. Added `decodeInstantJsonFull` returning `DecodedInstantJson { strokes, stamps, attachments }`; skips orphaned `imageAttachmentId`s, malformed base64, unknown `type`s. Legacy `decodeInstantJson` delegates and returns ink only.
  - [x] `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — extended the per-page Stack with a stamp sublayer (one `Positioned` per stamp, `Transform.rotate` + `SizedBox` + `stampImageBuilder`). Added `onTapUp` to the gesture detector that places the pending stamp when `tool == stamp`. Selection/manipulation deferred to Phase 2 (no-op tap on existing stamp; pan in stamp tool is a consumed no-op).
  - [x] `packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart` — added `stampCategories: List<PdfViewerStampCategory>?` and `stampImageBuilder: PdfStampImageBuilder?` fields. Const-compatible assert: `stampImageBuilder != null || stampCategories == null` (slightly stricter than the planned `?.isEmpty`-based form, which isn't const-evaluable).
  - [x] `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — thread `stampImageBuilder` into `PdfAnnotationLayer` at the per-page mount site. Added forwarders on `PdfViewerController`: `pendingStampListenable`, `selectedStampIdListenable`, `setPendingStamp`, `clearStampSelection`, `deleteStamp`. `applyAnnotationsFromJson` / `clearAnnotations` already pass through stamps+attachments via the generalized snapshot/import path.
  - [x] `packages/pdfrx/lib/pdfrx.dart` — exported `pdf_stamp_definition.dart` and `pdf_stamp_annotation.dart`.
- **Tasks (pdfrx test infra)**:
  - [x] `packages/pdfrx/example/music_viewer/test/_test_helpers/fake_pdf_page.dart` — promoted to public `FakePdfPage`; `highlighter_journey_test.dart` migrated to import the shared helper.
- **Tasks (music_viewer)**:
  - [x] `packages/pdfrx/example/music_viewer/pubspec.yaml` — added `flutter_svg: ^2.0.10` and explicit `assets/music_stamps/<category>/` entries.
  - [x] `packages/pdfrx/example/music_viewer/lib/stamp_image_builder.dart` — new file rendering SVGs via `SvgPicture.memory` and falling back to `Icon(Icons.broken_image_outlined)` for other content types, wrapped in `SizedBox.fromSize` to enforce `displaySize`.
  - [x] `packages/pdfrx/example/music_viewer/lib/main_page.dart` — eager-loads a hand-built `_stampCategories` (one `notes` category with sharp/flat/natural) into `PdfViewerParams`. Stamp tool button added to `AnnotationToolButtons` (gated on non-empty categories). `AnnotationStylePopups` stamp branch returns the picker-toggle button. Stamp picker mounted as a sibling `DraggablePanel` (placeholder grid; full `StampPickerPanel` lands in Phase 3).
- **TDD**:
  - [x] TDD: `PdfStampAnnotation`/`PdfStampDefinition` constructors validate inputs (positive size, non-empty contentType/id).
  - [x] TDD: `placeStamp(...)` adds a stamp + dedupes attachment bytes by sha256.
  - [x] TDD: `placeStamp` clamps bbox so it stays inside the page rect (shift, not shrink).
  - [x] TDD: `placeStamp` writes `id` from `idGenerator` and `createdAt`/`updatedAt` from `clock`.
  - [x] TDD: `clear()` empties stamps + attachments + selection + pending.
  - [x] TDD: `placeStamp` failure paths — synchronous error does not leak partial state; `debugPrint` invoked with stack trace.
  - [x] TDD: `encodeInstantJson` round-trip — 1 ink stroke + 1 stamp → decode equal; legacy ink-only JSON still decodes.
  - [x] TDD: `decodeInstantJsonFull` skips orphan `imageAttachmentId` and malformed base64.
  - [x] TDD: SHA-256 dedupe — two stamps with identical bytes produce one attachment entry.
  - [x] TDD: `attachments` field omitted from JSON when no stamps present.
- **Tests (place these in `packages/pdfrx/test/widgets/annotations/`** — directory creation included):
  - [x] `instant_json_stamp_test.dart` — JSON round-trip, dedupe, missing/malformed handling, legacy compatibility.
  - [x] `pdf_annotation_controller_stamp_test.dart` — `placeStamp`, `setPendingStamp`, `deleteStamp`, `clear`, dedupe + retain-on-other-reference, undo across mixed ink+stamp.
- **Verify**: in `packages/pdfrx`: `dart analyze` && `flutter test`. In repo root: `flutter pub get` (workspace) first if pubspec changed. Manual smoke: `flutter run` in music_viewer → enter annotation mode → tap Stamp tool → tap a stamp → tap a page → see SVG render → exit mode → kill app → relaunch → stamp persists.

### Phase 2 — Selection, manipulation, undo/redo

- **Goal**: tap-to-select, drag to move, drag handles to resize, drag rotation handle to rotate, tap delete IconButton to remove. Foreign-creator stamps non-selectable. Undo/redo across mixed ink+stamp ops.
- **Tasks (pdfrx)**:
  - [x] `pdf_annotation_controller.dart` — added public `PdfStampHandle` enum (corners/edges/body/rotation), private `_StampDragState`, and the `beginStampDrag`/`applyStampMove`/`applyStampResize`/`applyStampRotate`/`endStampDrag` API. Snapshot is pushed once at `beginStampDrag`; subsequent updates reconstruct from the captured original rect/rotation; `_stampDragTick` ticks every update for live repaint; `endStampDrag` is the commit boundary. (Plan called these "internal" — surfaced as public methods because the layer lives in a sibling file and shares no library-private scope.) Min-size constant exposed publicly as `kMinStampSizePts = 8.0` so widget tests can assert against it.
  - [x] `pdf_annotation_controller.dart` — `setPendingStamp` clears selection (Phase 1); `setTool` clears both selection and pending stamp (Phase 1).
  - [x] `pdf_annotation_layer.dart` — promoted to `StatefulWidget` to track per-drag state. Selection-overlay sublayer renders only when the selected stamp's `pageIndex` matches: 1.5 px outline, 8 filled square handles at corners + edge midpoints (~10 logical px, screen-fixed via Positioned offsets), small filled circle rotation handle inset ~6 px below the top edge, and a delete `Material+Icon(Icons.close)` button at the inner top-right (~24 logical px). All affordances stay inside the bbox and are wrapped in `Semantics` (`Resize <position>`, `Rotate stamp`, `Delete stamp`) for screen-reader support. Sizing constants live as file-level `_k...Px` constants on the layer file.
  - [x] `pdf_annotation_layer.dart` — extended GestureDetector dispatch:
    - `onTapUp(stamp tool)`: hit-tests selectable stamps in reverse-Z order, falls through foreign-creator stamps to the place/deselect branch; tap on the selected stamp's delete affordance routes to `deleteStamp`.
    - `onPanStart(stamp tool)`: hit-tests selected-stamp handles first (corner/edge/rotation/body), else consumes the gesture as a no-op.
    - `onPanUpdate`: routes to `applyStampMove` / `applyStampResize` / `applyStampRotate` based on the captured active handle.
    - `onPanEnd`/`onPanCancel`: `endStampDrag()`.
  - [x] `pdf_annotation_layer.dart` — handle hit-test radius is `_kHandleHitRadiusPx = 14.0` logical px (fingertip-friendly). Coordinates convert to PDF-space via `_toPdfSpace` for cumulative move/resize deltas; rotation uses absolute angle math centered on the bbox.
- **TDD**:
  - [x] TDD: tap on selectable stamp → `selectedStampIdListenable.value == that stamp's id`; tap on empty area clears selection; tap on foreign-creator stamp does not select.
  - [x] TDD: tap on foreign-creator stamp → selection unchanged.
  - [x] TDD: drag body → rect shifts by cumulative delta; one undo entry; `undo()` restores.
  - [x] TDD: drag corner handle → bbox grows/shrinks per axis; min 8 pt clamped; one undo entry.
  - [x] TDD: drag rotation handle → `rotationDeg` updates absolutely; one undo entry per drag.
  - [x] TDD: `deleteStamp(ownId)` removes; `deleteStamp(foreignId)` is no-op; attachments dropped only when reference count hits zero.
  - [x] TDD: rotation normalization — `encodeInstantJson` writes snapped `rotation` + free `pdfrx:rotation`; decode prefers `pdfrx:rotation`. (Covered by Phase 1 instant_json_stamp_test cases.)
  - [x] TDD: undo across mixed ink+stamp ops walks back/forward in committed order. (Covered in pdf_annotation_controller_stamp_test.)
- **Widget tests (music_viewer)**:
  - [x] `packages/pdfrx/example/music_viewer/test/stamp_foreign_creator_test.dart` — alice + bob stamps, alice cannot delete or select bob's; her own delete succeeds.
  - [x] `packages/pdfrx/example/music_viewer/test/stamp_layer_selection_test.dart` (new) — exercises the layer's gesture pipeline: tap on selectable stamp selects, tap empty clears, foreign-creator tap does not select.
- **Verify**: `flutter analyze` clean of new issues; `flutter test` green except the pre-existing pdfium-download-required `pdf_viewer_test.dart: PdfViewer.uri` (network sandbox limitation). Manual smoke deferred to Phase 3 once the picker panel lands.

### Phase 3 — Asset library scanner, picker panel, journey test

- **Goal**: real `loadStampLibrary` scanning `AssetManifest`, polished `StampPickerPanel` widget, full robot-driven journey test asserting the spec's happy path end-to-end.
- **Tasks (music_viewer)**:
  - [ ] `packages/pdfrx/example/music_viewer/lib/stamp_library.dart` — `Future<List<PdfViewerStampCategory>> loadStampLibrary({AssetBundle bundle = rootBundle})`. Scan `AssetManifest.loadFromAssetBundle(bundle).listAssets()` for keys matching `^assets/music_stamps/([^/]+)/([^/]+)\.svg$`. Group by `<category>`. Friendly title map for known categories (`notes` → "Notes", `time_signatures` → "Time signatures", etc.) with capitalized fallback (`underscores → spaces`). Stamp `id` = filename without extension; `name` = id with `^\d+_` prefix stripped + spaces. **`intrinsicSize` = `Size(24, 24)`** for every stamp (no SVG header parsing). `bytesLoader = () => bundle.load(assetKey).then((bd) => bd.buffer.asUint8List())`. Categories sorted by `id` asc; stamps within sorted by `id` asc (sort at render time per spec #19; the loader returns arbitrary order or sorted — caller-friendly is sorted).
  - [ ] `packages/pdfrx/example/music_viewer/lib/stamp_picker_panel.dart` — `StampPickerPanel` `StatelessWidget` taking `controller: PdfViewerController`, `categories: List<PdfViewerStampCategory>`, `stampImageBuilder`. Scrollable column; one section per category (header = `title`, titleSmall + padding); `Wrap` of thumbnails wrapped in `Semantics(label: stamp.name, button: true)` for screen readers, then `InkWell + Tooltip(name) + SizedBox(48,48) + stampImageBuilder(..., Size(48,48))`; 2 px primary border on the pending-matched thumbnail; `Key('stampThumb:$catId/$stampId')` per thumbnail. Tap → `controller.setPendingStamp(stamp)`.
  - [ ] `packages/pdfrx/example/music_viewer/lib/main_page.dart` — replace Phase-1 hand-built fixture w/ `loadStampLibrary` in `initState`. Add `_pickerOpen: bool` state field (defaults `true`). Mount `StampPickerPanel` as a sibling `DraggablePanel` inside the build's top-level Stack (visibility: `annotationMode && tool == stamp && _pickerOpen`). `AnnotationStylePopups` stamp branch returns an `IconButton(tooltip: 'Stamp library', icon: Icons.image_outlined)` toggling `_pickerOpen`. Clean up Phase-1 inline picker.
- **TDD**:
  - [ ] TDD: `loadStampLibrary` against a fake `AssetBundle` w/ 3 controlled paths (`assets/music_stamps/notes/sharp.svg`, `assets/music_stamps/notes/flat.svg`, `assets/music_stamps/dynamics/01_pianississimo.svg`) → returns 2 categories sorted by id (`dynamics`, `notes`); each category has stamps sorted by id; default `intrinsicSize == Size(24, 24)`.
  - [ ] TDD: friendly category title map — `notes` → "Notes"; `time_signatures` → "Time signatures"; `unknown_cat` → "Unknown cat" (capitalized fallback).
  - [ ] TDD: `^\d+_` prefix stripped from `name` but preserved in `id` — `01_pianississimo` → name "Pianississimo", id "01_pianississimo".
- **Widget tests (music_viewer)**:
  - [ ] `packages/pdfrx/example/music_viewer/test/stamp_library_test.dart` — covers TDD items above.
  - [ ] `packages/pdfrx/example/music_viewer/test/stamp_picker_panel_test.dart` — renders categories sorted; stamps within sorted; tap thumbnail → `controller.setPendingStamp` called; pending highlight visual applied.
  - [ ] Extend `packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart` — Stamp tool button absent when `stampCategories` is null/empty; present + tooltip equals `'Stamp'` when non-empty.
- **Robot journey test**:
  - [ ] `packages/pdfrx/example/music_viewer/test/stamp_journey_test.dart` — robot helpers: `enterAnnotationMode()`, `selectStampTool()`, `pickStamp(id)`, `tapPage(Offset)`, `selectStamp(id)`, `dragHandle(Handle, Offset)`, `dragRotation(double angle)`, `tapDelete()`, `exitAnnotationMode()`. Mount `AnnotationToolButtons` + `AnnotationStylePopups` + `StampPickerPanel` + real `PdfAnnotationLayer` against `FakePdfPage`. **Bypass the asset loader**: hand-build `[PdfViewerStampCategory(id:'test', title:'Test', stamps:[PdfStampDefinition(id:'stamp_a', ..., bytesLoader: () => testSvgBytes)])]`. Walk the spec's 10-step journey (#step 1-10 in <validation>) including final `decodeInstantJson` assertion on emitted JSON.
  - [ ] Inject deterministic clock + idGenerator via the seams added in Phase 1 so timestamps + ulids are predictable.
- **Verify**: `dart analyze` && `flutter test` (both packages). Manual smoke: full library loads from assets; picker shows all 7 categories sorted; tap-place-select-resize-rotate-delete-undo across mixed ink+stamp; two-page mode places stamps on the correct page.

## Risks / Out of scope

- **Risks**:
  - Single GestureDetector handling tap + pan + handle hit-tests: gesture-arena disambiguation may fight short drags. Fallback if needed: split into a `Listener`-based custom recognizer. Phase 2 trip-wire.
  - Selection overlay clipped: `pdf_viewer.dart:2272` shows the layer is in a `Positioned` sibling to bitmap, NOT inside InteractiveViewer. Spec already mandates inside-bbox affordances; if tests reveal the Stack still clips, hoist via `viewerOverlayBuilder`.
  - Undo snapshot memory: each snapshot now copies stamps + attachments map. With many large rasters this could grow. Music-notation SVGs are tiny (<10 KB); reassess if a future host embeds rasters.
- **Out of scope**:
  - Aspect-ratio lock during resize (free per-axis only).
  - Multi-select / group operations.
  - Z-ordering API (newest-on-top via list order is implicit).
  - Page rotation other than 0° (matches existing ink limitation).
  - SHA-256 collision handling.
  - Picker open-state hoisted to controller (example-app-scoped per spec).
  - Rasters / non-SVG content types in the music_viewer's `stampImageBuilder` (broken-image fallback only).
