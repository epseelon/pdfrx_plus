# Stamp annotations for pdfrx + music_viewer

<goal>
Add a "stamp" annotation tool to the pdfrx PDF viewer and surface it in the `music_viewer` example so that users can place, move, resize, rotate, and delete vector images on top of PDF pages while in annotation mode.

A stamp library — categorized lists of pre-baked SVG images — is supplied by the host app via `PdfViewerParams`. The library is a *picker shortcut only*: when a stamp is placed, its raw bytes are embedded into the saved Instant JSON document as a SHA-256-keyed attachment. This makes documents self-contained — adding/removing/renaming items in the host's stamp library never breaks past documents.

For `music_viewer`, the host populates the library by scanning `assets/music_stamps/<category>/*.svg` at startup, exposing the categorized inventory of music notation symbols (notes, dynamics, ornaments, keys, silences, repetition marks, time signatures) for in-PDF placement on top of music scores.
</goal>

<background>
Tech stack:
- Flutter monorepo. The pdfrx package (`packages/pdfrx`) hosts the viewer + annotation engine; the example app `packages/pdfrx/example/music_viewer` is the primary consumer.
- Existing annotation engine (ink-only) lives under `packages/pdfrx/lib/src/widgets/annotations/`:
  - @packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart — controller, tool enum, stroke list, in-flight stroke buffer, undo/redo
  - @packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart — per-page CustomPainter + GestureDetector
  - @packages/pdfrx/lib/src/widgets/annotations/pdf_ink_annotation.dart — `PdfInkAnnotation` model
  - @packages/pdfrx/lib/src/widgets/annotations/instant_json.dart — encode/decode for `pspdfkit/ink` entries
- Existing tools: `PdfAnnotationTool { pen, highlighter, eraser }`. We will add `stamp`.
- music_viewer's main page: @packages/pdfrx/example/music_viewer/lib/main_page.dart already wires up the annotation toolbar via `AnnotationToolButtons`, `AnnotationStylePopups`, `AnnotationUndoRedoButtons`, plus a `DraggablePanel` (@packages/pdfrx/example/music_viewer/lib/draggable_panel.dart) for the toolbar itself.
- Persistence layer: @packages/pdfrx/example/music_viewer/lib/annotation_storage.dart writes Instant JSON to `<tempDir>/pdfrx_annotations/<sha1>.json` keyed by absolute PDF path.
- Stamp asset library (already shipped under `packages/pdfrx/example/music_viewer/assets/music_stamps/`):
  - `dynamics/` (13 SVGs, prefixed `01_`–`13_` for sort order)
  - `keys/` (3 SVGs)
  - `notes/` (5 SVGs)
  - `ornaments/` (5 SVGs)
  - `repetition/` (1 SVG, growing)
  - `silence/` (8 SVGs, prefixed `01_`–`08_`)
  - `time_signatures/` (9 SVGs, prefixed `01_`–`09_`)

Reference for the JSON wire format:
- @instant-json.json — local copy of the Instant JSON OpenAPI schema. Relevant pieces: `Annotation` discriminated union, `ImageAnnotation` (`pspdfkit/image` type) with `imageAttachmentId` + `contentType`, `Attachments` map (key = SHA-256 hash, value contains base64 `binary`), `AnnotationRotation` enum (0/90/180/270 only).
- https://www.nutrient.io/api/reference/document-engine/instant-json/#description/stamp-annotation — stamp annotation reference. We use `pspdfkit/image` (not `pspdfkit/stamp`) because Instant JSON's stamp type is fixed to a small enum of pre-rendered stamp templates ("Approved", "Confidential", etc.) and is unsuitable for user-supplied vector images.
- https://www.nutrient.io/guides/document-engine/json/schema/file-attachments/ — attachments mechanism that backs `imageAttachmentId`.

Design constraints:
- pdfrx must remain SVG-renderer-agnostic (no flutter_svg dependency added to pdfrx itself). The image renderer is supplied by the host via a `PdfViewerParams.stampImageBuilder` callback that receives raw bytes + content type.
- Page rotation is assumed `0°` (matches existing ink-layer assumption — see `pdf_annotation_layer.dart` doc comment).
- Existing JSON files (ink-only) must continue to round-trip unchanged. The new `pspdfkit/image` entries and the `attachments` map are additive.
- music_viewer is the only consumer for now; design the API conservatively but don't add escape hatches no one needs.
</background>

<user_flows>
**Primary (place a stamp):**
1. User taps the floating "Annotate" FAB → `PdfViewerController.enterAnnotationMode()` → toolbar appears.
2. Toolbar renders `Stamp` tool button (tooltip `"Stamp"`) iff `PdfViewerParams.stampCategories` is non-null and non-empty.
3. User taps `Stamp` → controller's tool listenable switches to `PdfAnnotationTool.stamp` → `AnnotationStylePopups` switches to a stamp-specific row (only the picker-toggle button) → a separate `DraggablePanel` housing the stamp picker becomes visible.
4. Picker shows categories sorted by `id` (asc); each category shows its `title` as a header; stamps within sorted by `id` (asc). Each stamp is rendered as a thumbnail via `stampImageBuilder` plus its `name` as a tooltip.
5. User taps a stamp thumbnail → that stamp becomes the *pending* stamp (highlighted in picker). No PDF mutation yet.
6. User taps anywhere on a PDF page → a `PdfStampAnnotation` is created at the tapped point in PDF-space, sized so its *longest* side is 36 PDF points and its aspect ratio matches the stamp's declared `intrinsicSize`. The stamp's bytes are added to the controller's attachment store keyed by SHA-256.
7. Pending stamp stays armed for repeat placement until the user picks a different stamp, switches tool, or exits annotation mode.

**Primary (manipulate a placed stamp):**
1. While `PdfAnnotationTool.stamp` is active, user taps the body of an existing stamp **owned by the current creator** → that stamp becomes *selected* (single-selection — selecting a new stamp deselects any prior). Picker remains open and disarms the pending stamp (so the next page tap doesn't drop a new one).
2. Selected stamp renders an overlay with: 4 corner resize handles + 4 edge resize handles (placed at the bbox corners and edge midpoints, *inside* the bbox), 1 rotation handle (a small filled circle inset just below the top edge, centered horizontally), 1 delete `IconButton` (anchored at the inner top-right of the bbox). All affordances stay inside the bbox so the per-page Stack reliably hit-tests them.
3. Drag stamp body → translate (PDF-space). The annotation's `rect` updates live; commit on drag end (one undo entry per drag).
4. Drag any resize handle → free per-axis resize. Aspect ratio is *not* locked. Minimum size 8 PDF pts on either axis.
5. Drag rotation handle → free rotation (any angle, degrees CCW). No snap.
6. Tap the delete `IconButton` → stamp removed.
7. Tap empty page area → deselect.
8. Pan/drag on empty page area (or on a non-selected / foreign-creator stamp) → consumed but no-op (no pen draw, no marquee, no deselect; selection is preserved).

**Alternative flows:**
- `stampCategories: null` or empty → `Stamp` tool button is *not* rendered; picker panel never appears; existing pen/highlighter/eraser flows are unchanged.
- Stamp tool active but no pending stamp picked → tap on a page is a no-op (no placement, no deselection of an already-selected stamp).
- User switches to pen/highlighter/eraser mid-flow → stamp picker panel hides; stamp selection is cleared; pending stamp clears; placed stamps remain visible but non-interactable.
- User exits annotation mode while a stamp is selected → selection cleared; pending stamp cleared; `onAnnotationsChanged` fires with the full Instant JSON (ink + image annotations + attachments).
- Two-page horizontal facing layout → stamps anchor to whichever page received the tap. The existing per-page annotation layer pattern handles this naturally.
- Document switch → controller stamp + attachment + selection + pending state are all cleared, then re-loaded from the new document's JSON via `applyAnnotationsFromJson`.
- Foreign-creator stamps in the document → render normally but are *non-selectable* (taps fall through to the place/deselect branch). They cannot be moved, resized, rotated, or deleted by a different creator. Same ownership model as the ink eraser.

**Error / edge flows:**
- JSON import contains an `imageAttachmentId` not present in the document's `attachments` map → the entire annotation entry is silently skipped (matches existing `decodeInstantJson` skip-on-malformed policy).
- JSON import contains an attachment whose declared `contentType` is unsupported by the host's `stampImageBuilder` → the attachment is still loaded and the annotation kept; the builder is responsible for graceful fallback rendering (e.g. a placeholder). pdfrx does not pre-validate content types.
- JSON import without `attachments` map (legacy ink-only file) → ink annotations decode as before; stamp count is zero.
- `bytesLoader` for a `PdfStampDefinition` throws → placement is aborted and an error is surfaced via `debugPrint`. No partial state.
- User taps a stamp body that overlaps another stamp → the topmost selectable stamp (last placed, last rendered) wins selection; foreign-creator stamps are skipped during overlap resolution.
- Resize handle dragged below the 8 pt minimum → size clamps; drag continues without forcing the stamp to flip or invert.
</user_flows>

<requirements>

**Functional — public API (pdfrx):**
1. Add `PdfStampDefinition` value type (immutable) — host-supplied library entry, distinct from the placed `PdfStampAnnotation` — with fields:
   - `String id` — picker-only identifier, used for sorting + as a stable widget key in the picker.
   - `String name` — human-readable label (tooltip in picker).
   - `String contentType` — MIME type embedded into Instant JSON (e.g. `image/svg+xml`).
   - `FutureOr<Uint8List> Function() bytesLoader` — invoked at placement time and (for music_viewer's eager loader) at app start to populate caches. Must return the *exact bytes* that will be embedded.
   - `Size intrinsicSize` — declared aspect-preserving size of the underlying image (in arbitrary units; only the ratio matters). Used to compute placement-time `rect`.
2. Add `PdfViewerStampCategory` value type (immutable) with fields: `String id`, `String title`, `List<PdfStampDefinition> stamps`.
3. Add `PdfViewerParams.stampCategories` field: `List<PdfViewerStampCategory>?` (null and empty are equivalent — both disable the feature).
4. Add `PdfViewerParams.stampImageBuilder` field: `Widget Function(BuildContext context, Uint8List bytes, String contentType, Size displaySize)?`. Required when `stampCategories` is non-empty (assert at viewer construction). Builder must respect `displaySize` exactly (no intrinsic sizing).
5. Add `PdfAnnotationTool.stamp` enum value (in `pdf_annotation_controller.dart`).
6. Add `PdfStampAnnotation` model (immutable) with fields:
   - `int pageIndex` — 0-based.
   - `Rect rectInPdfSpace` — top-left + width/height in PDF points.
   - `double rotationDeg` — free angle, CCW (matches Instant JSON's CCW convention).
   - `String attachmentSha256` — hex hash of the embedded bytes (lowercase, no separator).
   - `String contentType`.
   - `DateTime createdAt`, `DateTime updatedAt`.
   - `String? creatorName`.
   - `String id` — Instant-JSON-style identifier (ULID or UUIDv4) generated at create time. Stable across move/resize/rotate, used for hit-testing and selection.
7. Extend `PdfViewerController` with:
   - `ValueListenable<List<PdfStampAnnotation>> stampsListenable` (or expose via existing controller-as-Listenable + a getter, matching ink's pattern).
   - `ValueListenable<String?> selectedStampIdListenable`.
   - `ValueListenable<PdfStampDefinition?> pendingStampListenable` — current stamp armed for placement.
   - Methods: `setPendingStamp(PdfStampDefinition? stamp)`, `clearStampSelection()`, `deleteStamp(String id)`. (Direct mutation methods like move/resize/rotate are internal-only; the layer drives them.) `deleteStamp` is a no-op for stamps whose `creatorName` differs from the controller's current creator (single-user / null-creator mode allows deletion of any stamp).
8. Extend `applyAnnotationsFromJson` / `exportAnnotationsAsJson` / `clearAnnotations` to cover stamp annotations + attachments. `clearAnnotations` clears stamps, attachment store, and selection.

**Functional — JSON wire format:**
9. JSON shape: `{ "format": "...", "annotations": [...], "attachments": { ... } }`. The `attachments` field is omitted when empty (so legacy ink-only output is byte-identical to today).
10. Stamp annotation entry uses Instant JSON's `pspdfkit/image` with `v: 1`, `pageIndex`, `bbox: [x, y, w, h]`, `contentType`, `imageAttachmentId: <sha256>`, `createdAt`, `updatedAt`, optional `creatorName`, `id`. Rotation: write *both* fields — `rotation` (Instant JSON enum, snapped to nearest of {0, 90, 180, 270}) *and* `pdfrx:rotation` (free float). On import, `pdfrx:rotation` wins when present; otherwise fall back to `rotation`; otherwise default to `0`. (Rationale for `v: 1`: matches the existing `pspdfkit/ink` entries we already emit; pdfrx is the only consumer; Instant JSON tolerates per-entry version mixing. Deliberate, not legacy.)
11. Attachments map: keys are lowercase hex SHA-256 of the binary bytes. Values are objects with `binary: <base64>` and `contentType: <mime>`. Match Instant JSON's documented shape exactly.
12. SHA-256 dedupe: placing two stamps with identical bytes produces one attachment entry referenced by both annotations. Removing one stamp does *not* drop the attachment if any other stamp still references it.
13. Bidirectional round-trip: any document we export must decode back to the same in-memory state (modulo timestamp formatting normalization). Test must pin this.
14. Forward-compat: unknown annotation `type` values and unknown top-level fields in entries are ignored without dropping the document. (Matches existing decoder behavior.)

**Functional — picker UI (music_viewer):**
15. The annotation toolbar's `AnnotationStylePopups` row, when `tool == PdfAnnotationTool.stamp`, renders a single icon button (tooltip `"Stamp library"`, icon `Icons.image_outlined`) that toggles the stamp picker panel's visibility.
16. The stamp picker is a separate `DraggablePanel` mounted alongside (not inside) the toolbar's draggable panel — independent position state. Its visibility is gated by `(annotationMode && tool == stamp && pickerOpen)`. Default state on first open: visible.
17. Picker layout: scrollable column, one section per category. Category header = `title` (text style: titleSmall, padding). Within a section: a `Wrap` of stamp thumbnails, each ~48×48 logical px, rendered via `stampImageBuilder(context, bytes, contentType, Size(48, 48))`, wrapped in a Material InkWell with a Tooltip whose message is the stamp's `name`. The currently pending stamp shows a 2 px highlight border (`Theme.colorScheme.primary`).
18. Tapping a thumbnail calls `controller.setPendingStamp(stamp)`. If that stamp was already pending, leave it pending (no toggle-off — the user disarms by switching tools or exiting mode).
19. Categories sort by `id` ascending; stamps within a category sort by `id` ascending. Sort happens at render time (don't mutate the input list).

**Functional — placement & manipulation (pdfrx layer):**
20. Stamp rendering and gestures live in the same per-page `PdfAnnotationLayer` as ink (extend it). **Stamps render as widgets, not as Canvas paint operations** — `stampImageBuilder` returns a `Widget`, which cannot be drawn into a `CustomPainter.paint(Canvas)` call. The per-page widget tree becomes a `Stack` ordered (back-to-front): (a) `CustomPaint(InkPainter)` for all ink, both committed and in-flight, plus the eraser cursor; (b) one `Stack` of stamp widgets, one entry per `PdfStampAnnotation` whose `pageIndex` matches this page (each entry is a `Positioned` with `Transform.rotate` wrapping a `SizedBox` whose child is `stampImageBuilder(context, bytes, contentType, displaySize)`); (c) a selection-overlay layer (only when this page contains the selected stamp) drawing handles + delete IconButton; (d) the existing `Positioned.fill` `GestureDetector` on top to capture pointer events. **Z-order rule: stamps always render above all ink (committed + in-flight)** — lifecycle-stable, no layering surprises when an ink stroke commits while a stamp is on top of it.
21. While `tool == stamp`, the per-page `GestureDetector` accepts both taps and pans:
    - On `onTapUp`:
      - If a stamp's body bbox contains the tap **and** the stamp is selectable for the current creator (its `creatorName == controller.currentCreator`, OR the controller is in single-user / null-creator mode) → select it (set `selectedStampIdListenable`), clear pending.
      - Else if a stamp is pending → place a new stamp at that PDF-space point with the default sizing rule (longest side = 36 PDF pts, aspect from `intrinsicSize`).
      - Else → clear selection.
    - On `onPanStart`:
      - If the drag begins on a *selected* stamp's body → translate the stamp during the pan; one undo snapshot pushed at pan-start.
      - Else if the drag begins on a resize or rotate handle of the *selected* stamp → run that handle's transform; one undo snapshot pushed at pan-start.
      - Else (pan on empty page area, or on a non-selected / foreign-creator stamp) → consume the gesture but do nothing (no pen draw, no marquee, no deselect — selection is preserved). On `onPanEnd` for this case, no commit / no undo entry.
    - Foreign-creator stamps (whose `creatorName != controller.currentCreator` in non-null-creator mode) are *non-selectable* — taps on their body fall through to the place/deselect branch as if the stamp weren't there. They render normally but cannot be selected, moved, resized, rotated, or deleted via the layer.
22. Default sizing on placement: `longest = 36.0`, then `(w, h) = intrinsicSize.aspectFit(longest)`. The placement point becomes the *center* of the new bbox. Clamp the bbox so it stays within the page rect (shift, don't shrink).
23. Move: drag on body of selected stamp → translate by drag delta in PDF space; one undo entry per drag.
24. Resize: drag a handle → recompute the bbox per-axis. Corner handles move both axes; edge handles move only one. Min size 8 pt either axis. One undo entry per drag.
25. Rotate: drag the rotation handle → angle = atan2(handle - centroid). Updates `rotationDeg`. One undo entry per drag.
26. Delete: tap the delete `IconButton` → remove the annotation. One undo entry. (Attachment map remains until no annotation references it.)
27. **Selection visuals — all affordances render *inside* the bbox** so they remain within the per-page Stack's hit-test region (the Stack is sized to `pageRect`, and Flutter does not reliably hit-test children that overflow Stack bounds). Specifically: a 1.5 px outline of `Theme.colorScheme.primary` traced just inside the bbox edges; 8 small filled square handles (~10 logical px, rendered as fixed *screen* size regardless of zoom) placed *at* the four corners and four edge midpoints of the bbox (not outside); the rotation handle is a small filled circle inset ~6 logical px below the top edge, centered horizontally; the delete IconButton uses `Icons.close` with a circular Material elevation 2 background, ~24 logical px, anchored at the inner top-right corner of the bbox (clipped/tucked just inside, not floating outside). For very small stamps where the affordances would crowd, the spec accepts overlap — usability tuning is a follow-up.
28. While `tool != stamp`: stamps render but ignore all pointer events (pen/highlighter/eraser see through them). Selection is cleared whenever `tool` changes. Pending stamp clears on: tool change, mode exit, document switch, and explicit `setPendingStamp(null)`. Picking the same stamp twice in a row leaves it pending (no toggle-off).

**Functional — music_viewer integration:**
29. New file `packages/pdfrx/example/music_viewer/lib/stamp_library.dart`: at app start, load `AssetManifest.loadFromAssetBundle(rootBundle)` and enumerate keys matching `assets/music_stamps/<category>/<file>.svg`. Group by `<category>` (subfolder name = category id, also as title via a small id→title map for prettier display, e.g. `notes` → "Notes", `time_signatures` → "Time signatures"; default is `id` capitalized + underscores → spaces). For each file: stamp `id` = filename without extension (e.g. `01_pianississimo`), `name` = same with prefix sort numbers stripped + spaces (e.g. "Pianississimo"). Bytes loader = `rootBundle.load(assetKey).then((bd) => bd.buffer.asUint8List())`. **`intrinsicSize` defaults to `Size(24, 24)` for every stamp** — music notation glyphs are roughly square, free per-axis resize lets users correct any aspect mismatch, and skipping SVG header parsing avoids brittle regex over arbitrary SVG content (leading comments, multi-line attributes, missing `viewBox`, units like `em`/`%`). Hosts that need a non-square intrinsic for a specific stamp can override per-stamp by passing a hand-built `PdfStampDefinition` instead of going through the asset scanner.
30. Eager loading: in `_MainPageState.initState`, call the loader and store result in `List<PdfViewerStampCategory>? _stampCategories` (null until loaded; first frame can render with `null` then update via `setState`). Pass through `PdfViewerParams.stampCategories`.
31. Add `flutter_svg` to `packages/pdfrx/example/music_viewer/pubspec.yaml`. Implement `stampImageBuilder` as: `if (contentType == 'image/svg+xml') return SvgPicture.memory(bytes, width: displaySize.width, height: displaySize.height, fit: BoxFit.contain); else return SizedBox.fromSize(size: displaySize, child: const Icon(Icons.broken_image_outlined));`.
32. Add a stamp tool button to `AnnotationToolButtons` (tooltip `"Stamp"`, icon `Icons.bookmark_outlined` selected, `Icons.bookmark_border` unselected). Conditional on `controller.stampCategoriesAvailable` (a new bool listenable on the controller, set when params are wired).
33. Stamp picker panel (`StampPickerPanel`, in a new file `lib/stamp_picker_panel.dart`) rendered as a sibling `DraggablePanel` inside `_MainPageState.build`'s top-level Stack. Visibility gated by `controller.annotationModeListenable.value && controller.annotationToolListenable.value == PdfAnnotationTool.stamp && _pickerOpen`. `_pickerOpen` defaults to `true` and toggles via the toolbar icon.

**Error handling:**
34. SVG bytesLoader throws → caught at placement; `debugPrint` the error; no annotation created. Caller sees no exception.
35. AssetManifest scan returns no SVGs (e.g. assets removed) → `_stampCategories = []` → stamp tool button absent → existing flows untouched.
36. Decoder receives an `imageAttachmentId` referencing a missing attachment → annotation entry skipped silently.
37. Decoder receives malformed base64 in `attachments[hash].binary` → that attachment + every annotation referencing it are skipped silently.

**Edge cases:**
38. Stamp placed at the page edge → bbox shifted (not shrunk) so it stays in-page.
39. Stamp resized so a handle would land outside the page → no clamp at resize time (PDF space allows negative / overflow coordinates; matches ink behavior).
40. Stamp rotated > 360° / < 0° → angle is normalized at JSON write time (mod 360, in `[0, 360)`).
41. Concurrent attachment hashes match (different bytes, same hash) — practically impossible for SHA-256, do not handle specially.
42. Two stamps overlap exactly → tap selects the topmost (latest in the stamps list).
43. Undo a delete → restored stamp is re-selected.
44. `clearAnnotations()` while a stamp is pending → pending stamp survives (it's a UI selection, not a document mutation).

**Validation / input constraints:**
45. `PdfStampDefinition.contentType` is non-empty.
46. `PdfStampDefinition.intrinsicSize.width > 0 && height > 0` — assert at construction.
47. `PdfViewerStampCategory.id` is non-empty; same for stamp `id`. (Assertions, since these come from the host's hand-written or generated library and bugs there should be loud.)
48. Duplicate stamp `id`s within a category, or duplicate category `id`s in the list, are not detected — they'd produce duplicate widget keys and Flutter will surface a meaningful error. Don't pre-validate.
</requirements>

<boundaries>

**Edge cases:**
- Page rotation other than 0° → unsupported (matches existing ink). Document this in the new code's doc comments.
- Scrolling / zoom mid-drag of a stamp handle → existing viewer pan/scale is suppressed during annotation mode; behavior matches ink-drag.
- Stamp placed off the visible page region (impossible — placement requires a tap on a page rect) → not reachable.
- Picker panel rendered with zero categories → `stampCategories` empty list short-circuits at `PdfViewerParams` validation (tool button absent).

**Error scenarios:**
- `bytesLoader` async throws → caught, logged, placement aborted; user sees nothing happen. (Acceptable: `bytesLoader` errors mean a broken asset and the user will notice the missing thumbnail.)
- Persistence write fails (existing `writeAnnotations` already logs and swallows) → next save retries; no spec-level retry logic added here.
- Document switch mid-placement-pending → pending stamp clears via existing controller mode toggle.
- Picker panel widget tree contains an SVG that fails to decode in `flutter_svg` → builder returns its own fallback (broken-image icon). pdfrx is unaware.

**Limits:**
- Reasonable max stamps per page: not enforced. The per-page widget Stack scales linearly with stamp count; acceptable for the music-notation use case.
- Reasonable max attachment size: not enforced. Music-notation SVGs are <10 KB each. If a future host embeds large rasters, base64 inflation is ~33%; document size is the concern but not a hard limit.
- Selection cardinality: single-select only. Multi-select is out of scope.
- Layered stamps: no explicit z-ordering API. Newest-on-top is implicit via list order.
</boundaries>

<implementation>

**Files to create (pdfrx package):**
- `packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_annotation.dart` — `PdfStampAnnotation` model.
- `packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_definition.dart` — public `PdfStampDefinition` + `PdfViewerStampCategory`. Exported via `pdfrx.dart`.

**Files to modify (pdfrx package):**
- `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart` — add `stamp` enum value; `_stamps`, `_attachments`, `_selectedStampId`, `_pendingStamp` fields + listenables; setters and mutation methods; generalize undo snapshot to capture `(strokes, stamps, attachments)`.
- `packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart` — add a *widget-tree* stamp layer above the existing `CustomPaint(InkPainter)` (Stack of `Positioned` + `Transform.rotate` + `SizedBox` + `stampImageBuilder` per stamp); add a selection overlay sublayer (handles + delete IconButton, all positioned inside the bbox); add tap + tool-aware pan handling to the existing `Positioned.fill` `GestureDetector`; coordinate conversion identical to ink (`_toPdfSpace`).
- `packages/pdfrx/lib/src/widgets/annotations/instant_json.dart` — extend encoder to emit image annotations + `attachments` map; extend decoder to consume them; preserve unknown fields conservatively for forward-compat.
- `packages/pdfrx/lib/src/widgets/pdf_viewer.dart` — add `stampCategories` and `stampImageBuilder` to `PdfViewerParams`; expose stamp listenables and methods on `PdfViewerController`; thread params through to `PdfAnnotationLayer`.
- `packages/pdfrx/lib/pdfrx.dart` — export new public types.

**Files to create (pdfrx test infrastructure):**
- `packages/pdfrx/test/widgets/annotations/_test_helpers.dart` — shared `FakePdfPage` (a minimal `PdfPage` test double exposing `pageNumber`, `width`, `height`) and any other fixtures used by both ink and stamp tests. Promoted from the private copy currently inside `packages/pdfrx/example/music_viewer/test/highlighter_journey_test.dart`. The directory `packages/pdfrx/test/widgets/annotations/` does not exist yet; create it.

**Files to create (music_viewer):**
- `packages/pdfrx/example/music_viewer/lib/stamp_library.dart` — async `loadStampLibrary({AssetBundle bundle = rootBundle})`. Returns `Future<List<PdfViewerStampCategory>>`. Exposes a small `_categoryTitles` map for friendly category labels and a regex (`^\d+_`) to strip sort prefixes from display names. *No SVG header parsing* — `intrinsicSize` defaults to `Size(24, 24)` per requirement #29.
- `packages/pdfrx/example/music_viewer/lib/stamp_picker_panel.dart` — `StampPickerPanel` widget (stateful or stateless wrapper, scrollable category list).

**Files to modify (music_viewer):**
- `packages/pdfrx/example/music_viewer/lib/main_page.dart` — eager-load library in `initState`; wire `stampCategories` + `stampImageBuilder` into `PdfViewerParams`; add `Stamp` tool button to `AnnotationToolButtons` (conditional); add stamp toggle to `AnnotationStylePopups` for `PdfAnnotationTool.stamp`; mount `StampPickerPanel` as a sibling `DraggablePanel`.
- `packages/pdfrx/example/music_viewer/pubspec.yaml` — add `flutter_svg: ^2.0.10` (or current).

**Patterns to follow:**
- Mirror ink's listenable pattern: every mutable controller state is a `ValueNotifier` exposed as `ValueListenable`; setters are idempotent (no-op when value unchanged).
- Stable test selectors: tooltips for buttons (`'Stamp'`, `'Stamp library'`); `Key('stampThumb:$categoryId/$stampId')` for picker thumbnails; `Key('stamp:${annotation.id}')` for placed-stamp wrappers.
- One undo snapshot per user-meaningful operation (place, drag-move, drag-resize, drag-rotate, delete) — NOT per pointer-update. Push at drag-start, swallow updates, leave the snapshot stable through the drag.
- Selection state cleared on: tool change, mode exit, delete-of-selected-stamp, document switch.
- Picker open/close state (`_pickerOpen`) is example-app-scoped — it lives in `_MainPageState`, not in the pdfrx controller. Acceptable for v1 since music_viewer is the only host. If/when a second host adopts the picker, hoist this to a `stampPickerOpenListenable` on `PdfViewerController`.

**Anti-patterns to avoid:**
- Don't store the in-memory `Uint8List` on `PdfStampAnnotation`. Storage is via `attachmentSha256` → controller's attachment store. The model holds only the hash.
- Don't introduce a flutter_svg dependency in pdfrx. The host's `stampImageBuilder` is the only renderer.
- Don't duplicate the per-page hit-testing into a separate stamp-only layer — extend `PdfAnnotationLayer`. The page index, page rect, and coordinate conversion already live there.
- Don't try to render stamps inside `CustomPainter.paint(Canvas)`. The image renderer is a `Widget Function(...)`. Stamps must be widgets in the per-page Stack — see requirement #20.
- Don't position selection handles, the rotation handle, or the delete IconButton *outside* the bbox. The per-page Stack is sized to `pageRect`; affordances outside it may not hit-test reliably. See requirement #27.
- Don't use `pspdfkit/stamp` (Instant JSON's stamp type) for these annotations — it's enum-bound to a fixed list of pre-rendered stamps.
- Don't lock aspect ratio on resize. The user explicitly chose free per-axis resize; locking it would force a Shift-modifier UI we don't want to build.
- Don't try to reuse `PdfInkAnnotation`'s `pdfrx:kind` extension field for stamps. Stamps are a different annotation type, not a kind of ink.
</implementation>

<validation>

**TDD discipline (per `act-flutter-tdd`):**
- All new behavior in pdfrx (controller mutation methods, JSON encoder/decoder, attachment-store dedup, undo/redo for stamps) is implemented test-first via vertical slices: RED (one failing behavior test) → GREEN (minimal code) → REFACTOR.
- Behavior order: happy path first (place a stamp, encode, decode, verify); then edge cases (dedupe, missing attachment, malformed base64, rotation normalization); then error handling (bytesLoader throw).
- Testability seams:
  - `PdfAnnotationController` is constructable in isolation (already true today).
  - `loadStampLibrary` accepts an `AssetBundle bundle` parameter (default `rootBundle`) so tests pass a fake bundle with controlled assets.
  - SHA-256 hashing uses the existing `crypto` package — no DI needed; deterministic.
  - DateTime: introduce `DateTime Function() clock` parameter on the controller's stamp-create methods, defaulted to `() => DateTime.now().toUtc()`. Tests pass a fixed clock.
  - ULID/UUID generation: same pattern — accept a `String Function() idGenerator` parameter on stamp-create methods, defaulted to a real generator.
- Mocking policy: prefer fakes (in-memory `AssetBundle`, deterministic clock/id, captured callbacks). Mock only true external boundaries; the asset bundle scan and SHA-256 hashing are not mocked.

**Robot-driven journey tests (per `act-flutter-robot-testing`):**
A single critical journey test exercises the full happy path end-to-end, in `packages/pdfrx/example/music_viewer/test/stamp_journey_test.dart`. It mounts `AnnotationToolButtons` + `AnnotationStylePopups` + `StampPickerPanel` + a real `PdfAnnotationLayer` against a `FakePdfPage` (imported from the new shared `packages/pdfrx/test/widgets/annotations/_test_helpers.dart`).

**Test seam — bypass the asset-manifest loader.** The journey test does *not* call `loadStampLibrary` or wire a fake `AssetBundle`. Instead, it constructs a hand-built `List<PdfViewerStampCategory>` directly with one or two `PdfStampDefinition` entries whose `bytesLoader` returns a fixed `Uint8List` (e.g. literal SVG bytes for a tiny test stamp). This keeps the journey test focused on the gesture + JSON behavior, not the asset scanner. The `loadStampLibrary` function gets its own dedicated unit test (see below).

Robot helpers wrap the toolbar tap, picker thumbnail tap, page tap, body drag, handle drag, and delete tap behind named methods (`enterAnnotationMode()`, `selectStampTool()`, `pickStamp(id)`, `tapPage(Offset)`, `selectStamp(id)`, `dragHandle(Handle, Offset)`, `tapDelete()`, `exitAnnotationMode()`).

The journey:
1. Enter annotation mode.
2. Tap Stamp tool → assert picker panel visible, stamp button shows selected variant.
3. Tap a stamp thumbnail (`Key('stampThumb:test/stamp_a')`, where the test fixture defines a single `test` category with stamp `stamp_a`) → assert pending stamp set.
4. Tap a page → assert `PdfStampAnnotation` placed with expected centre + size.
5. Tap the placed stamp → assert selection.
6. Drag a corner handle → assert resized (+expected delta).
7. Drag rotation handle → assert `rotationDeg` close to expected angle.
8. Tap delete → assert annotation list empty.
9. Place again, exit mode, capture JSON via `onAnnotationsChanged`.
10. Decode that JSON via `decodeInstantJson` → assert one image annotation + one attachment with the expected sha256.

**Widget tests (screen edges & error paths):**
- `packages/pdfrx/example/music_viewer/test/main_page_annotation_toolbar_test.dart` (extend): Stamp tool button absent when `stampCategories` is null/empty; present when non-empty; tooltip equals `'Stamp'`.
- `packages/pdfrx/example/music_viewer/test/stamp_picker_panel_test.dart` (new): renders categories sorted by id; renders stamps within a category sorted by id; tapping a thumbnail invokes the supplied `onPick` callback with the right stamp; the highlighted-pending visual is applied to the pending stamp only.
- `packages/pdfrx/example/music_viewer/test/stamp_foreign_creator_test.dart` (new): given a `PdfAnnotationController` populated with one stamp owned by `'alice'` and one owned by `'bob'`, with `currentCreator == 'alice'` — tapping bob's bbox does *not* select it; tapping alice's bbox selects it; `deleteStamp(bobId)` is a no-op; `deleteStamp(aliceId)` removes it.

**Asset-loader unit tests (separate from the journey):**
- `packages/pdfrx/example/music_viewer/test/stamp_library_test.dart` (new): `loadStampLibrary` against a fake `AssetBundle` containing controlled paths produces categories sorted by directory id; stamps sorted by filename; `intrinsicSize` defaults to `Size(24, 24)` for every stamp (per requirement #29); friendly category title map applied where present, otherwise capitalized fallback used; the leading-digit-prefix sort marker is stripped from display `name` but preserved in `id`.

**Unit tests (logic):**
- `packages/pdfrx/test/widgets/annotations/instant_json_stamp_test.dart` (new): encode-then-decode round trip preserves rect, rotation (free angle), contentType, attachment hash, creator name; `attachments` field omitted on empty input; legacy ink-only JSON still decodes; missing `imageAttachmentId` reference skipped; malformed base64 skipped; SHA-256 dedupe verified by encoding two annotations with the same bytes.
- `packages/pdfrx/test/widgets/annotations/pdf_annotation_controller_stamp_test.dart` (new): `setPendingStamp`, `clearStampSelection`, `deleteStamp`, place-via-internal-method, move/resize/rotate via internal methods, undo/redo across stamp operations, undo across mixed ink+stamp ops, `clearAnnotations` clears stamps + attachments + selection.

**Manual verification (run the app):**
- Run `flutter run -d <device>` in `packages/pdfrx/example/music_viewer`. Open a PDF, enter annotation mode, exercise: place several stamps, drag/resize/rotate/delete, undo/redo across mixed ink+stamp ops, exit mode, kill the app, relaunch, confirm stamps reload from disk in correct positions/sizes/rotations. Test in two-page mode (place stamps on both pages of a spread).

**Quality gates:**
- `dart analyze` clean across the workspace.
- All new tests pass.
- No regression in existing ink test suites (`highlighter_journey_test.dart`, `main_page_annotation_toolbar_test.dart`, controller tests, instant_json tests).
</validation>

<done_when>
1. A user with a non-empty `stampCategories` configured can place, move, resize, rotate, and delete a vector image on a PDF page in `music_viewer`, with all operations participating in undo/redo.
2. The saved Instant JSON document round-trips correctly: same stamps reload at same positions/sizes/rotations after killing and relaunching the app, including across changes to the stamp library (e.g. removing a stamp from `assets/music_stamps/` does not break documents that already reference it).
3. Documents are self-contained: extracting the JSON file alone is sufficient to render the stamps, given a host that supplies a `stampImageBuilder` for the embedded `contentType`s.
4. Existing ink-only JSON files continue to decode correctly, and the toolbar's pen/highlighter/eraser flows are unchanged.
5. With `stampCategories: null` or empty, no stamp UI is rendered, and the codepath reduces to today's behavior.
6. All new behavior is covered by the validation suite (TDD-first unit + widget tests, plus the journey test). `dart analyze` clean. CI passes.
</done_when>
