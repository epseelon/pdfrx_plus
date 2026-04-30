<goal>
Add freehand drawing on PDFs to the `music_viewer` example app at
`packages/pdfrx/example/music_viewer/lib/main_page.dart`, persisted as Instant JSON
in temp files (one per document). The drawing primitives — entering/exiting an
annotation mode, importing/exporting annotations as JSON, rendering ink strokes
per page — must be exposed as first-class APIs on `pdfrx`'s `PdfViewer` /
`PdfViewerController`, so other apps in the workspace can adopt the same feature
with minimal wiring. Annotations are stored separately from the PDF; the PDF file
itself is never modified.

This is the first iteration. Color and stroke width are hardcoded; later
iterations will add UI to pick them.
</goal>

<background>
Monorepo layout:
- `packages/pdfrx_engine/` — pure Dart engine (no Flutter). No engine changes
  needed: annotations are a widget-layer concern.
- `packages/pdfrx/` — Flutter widgets (`PdfViewer`, `PdfViewerController`,
  `PdfViewerParams`). All new APIs land here.
- `packages/pdfrx/example/music_viewer/` — the example app being extended.

Files to examine before implementing:
- @packages/pdfrx/example/music_viewer/lib/main_page.dart — current viewer wiring
  (FABs, indicator, viewerOverlayBuilder tap zones, mode toggle).
- @packages/pdfrx/lib/src/widgets/pdf_viewer.dart — `PdfViewerController`
  (~line 4848); coord transforms `globalToLocal`, `localToDocument`,
  `documentToLocal`, `doc2local` (~lines 5249-5268); `isReady`, `pageNumber`,
  `pageCount`, `pages`, `document`.
- @packages/pdfrx/lib/src/widgets/pdf_viewer_params.dart — `panEnabled` (~38),
  `scaleEnabled` (~39), `pageOverlaysBuilder` (~542, typedef ~1562),
  `pagePaintCallbacks` (~577), lifecycle callbacks (`onViewerReady` ~353,
  `onDocumentChanged` ~343, `onPageChanged` ~397).
- @packages/pdfrx_engine/lib/src/pdf_document.dart — `PdfDocument.sourceName`
  (the only stable identifier).
- @packages/pdfrx/example/music_viewer/pubspec.yaml — already has
  `path_provider`; `crypto` needs adding.

Reference: Instant JSON / `pspdfkit/ink` annotation schema. See
https://www.nutrient.io/guides/document-engine/json/schema/annotations/
and https://www.nutrient.io/guides/web/json/. Coordinate space is PDF points
with origin at the **top-left** of the page, x-axis right, y-axis down.
</background>

<user_flows>
**Primary flow — create annotations and persist them**
1. User taps the new "annotation" FAB (`Icons.edit`) in `main_page.dart`.
2. `controller.enterAnnotationMode()` is called. The viewer internally disables
   pan and zoom and starts capturing pointer input on the visible pages.
3. The example app, via a `ValueListenable<bool>` exposed by the controller,
   hides: the page-mode toggle FAB, the `skip_next` document-switch FAB, the
   page indicator overlay, and the left/right viewer-overlay tap zones.
4. A bottom toolbar slides up with one button: a close (`Icons.close`) icon.
5. User draws one or more strokes on the visible page(s). Each stroke is
   captured starting from pointer-down on a page and rendered live.
6. User taps the close button. The example app calls
   `controller.exitAnnotationMode()`. Internally the viewer:
   - re-enables pan and zoom,
   - fires `PdfViewerParams.onAnnotationsChanged(jsonString)` with a freshly
     serialized Instant JSON document.
7. The example app's `onAnnotationsChanged` handler writes the JSON to
   `<tempDir>/pdfrx_annotations/<sha1(absolutePdfPath)>.json` (creates parent
   dir on first write; overwrites otherwise).
8. The viewer UI restores: toolbars and indicator reappear, the bottom
   annotation toolbar slides away.

**Document switch flow — load existing annotations**
1. User taps `skip_next` (or the prev/next half-screen tap zones reach a
   document boundary). A new document loads via the existing `_switchDocument`
   path.
2. `onViewerReady` fires for the new document.
3. The example app computes the JSON file path
   (`<sha1(currentAbsolutePath)>.json`). If the file exists, it reads the JSON
   and calls `controller.applyAnnotationsFromJson(json)`.
4. The annotation layer renders the strokes on top of the relevant pages even
   when annotation mode is **off**.

**App restart flow**
- Same as document switch: the first `onViewerReady` triggers the same
  load lookup. Annotations from the prior session reappear without further
  user action.

**Empty-session flow**
- User enters annotation mode, draws nothing, taps close.
- Callback still fires with `{"format": "...", "annotations": []}`. The
  example app overwrites (or creates) the JSON file. (Acceptable; deletes can
  be added later if desired.)

**Cross-page stroke flow (two-page mode)**
- User starts a stroke on the left page and drags onto the right page.
- The stroke is anchored to the page where pointer-down landed (the left
  page). Subsequent points keep accumulating in that page's coordinate space
  even when the pointer is over the right page (so x grows past the page
  width).
- During paint, the stroke is **clipped** to its anchor page's rect, so the
  visible part stops at the right edge of the left page.

**Mode-conflict flow**
- While in annotation mode, the half-screen prev/next tap zones in the example
  app are hidden, so taps on the page don't navigate.
- Programmatic page changes via `controller.goToPage(...)` are also suppressed
  while annotation mode is on (no-op or throw — see Requirements). This
  protects against the example app's tap zones being accidentally left wired.
</user_flows>

<requirements>
**Functional — pdfrx widget layer**

1. Add to `PdfViewerController` (the public API surface; no second
   public controller class). Implementation delegates to a private
   `_PdfAnnotationController` (a `ChangeNotifier`) owned by
   `_PdfViewerState`:
   - `Future<void> enterAnnotationMode()` — flips internal mode flag,
     suppresses pan/scale, and starts routing pointer events on pages to
     the annotation layer. Idempotent. Returns once the rebuild is queued
     (no need to await for correctness).
   - `Future<void> exitAnnotationMode()` — restores pan/scale and awaits
     `PdfViewerParams.onAnnotationsChanged(json)` once with the current
     set serialized as Instant JSON. Idempotent. The viewer remains in an
     "exiting" state until the callback's future completes; this is
     internal coherence only (no UI difference).
   - `ValueListenable<bool> get annotationModeListenable` — for reactive
     UI in callers. Use `.value` to query the current state. (No separate
     `bool` getter — the listenable is the single source of truth.)
   - `void applyAnnotationsFromJson(String json)` — parses the Instant
     JSON document, replaces the in-memory annotation set with strokes
     from `pspdfkit/ink` entries, ignores all other annotation types and
     ignores annotations whose `pageIndex` is out of range. Triggers a
     repaint.
   - `String exportAnnotationsAsJson()` — returns Instant JSON document
     with `format: "https://pspdfkit.com/instant-json/v1"`, no `pdfId`,
     and an `annotations` array containing one `pspdfkit/ink` entry per
     stroke.
   - `void clearAnnotations()` — removes all strokes; triggers repaint.
     Does NOT fire `onAnnotationsChanged`.

   **Document identity is the caller's responsibility.** These APIs are
   document-blind: `applyAnnotationsFromJson` operates on the currently
   loaded document; `exportAnnotationsAsJson` returns the strokes for
   whatever is currently loaded. The caller decides which JSON belongs
   to which document, using whatever key makes sense for their source
   (`PdfDocument.sourceName`, file path, hash, manual key). The
   dartdoc on these methods must mention this contract explicitly.

2. Add to `PdfViewerParams`:
   - `final PdfAnnotationsChangedCallback? onAnnotationsChanged;` — fired
     only on `exitAnnotationMode()` (not on every stroke). Signature:
     `typedef PdfAnnotationsChangedCallback = Future<void> Function(String json);`
     The async signature lets the viewer await the caller's persistence
     work before it considers itself fully out of mode (avoids lost
     writes if the app is backgrounded immediately after close).
   - `final Color annotationStrokeColor;` — defaults to `Color(0xFFFF3B30)`
     (iOS system red — chosen for legibility on white pages such as
     music scores).
   - `final double annotationStrokeWidth;` — defaults to `2.0` (PDF
     points).

3. Render strokes on every visible page (annotation mode on or off) so
   imported strokes are always visible. Mounting mechanism:
   - **Modify `_buildPageWidgets` in `pdf_viewer.dart` at the existing
     `pageOverlaysBuilder` call site (~line 2237-2249).** After the user's
     `pageOverlaysBuilder` result is wrapped in `Positioned` + inner
     `Stack`, append a *second* `Positioned` for our annotation layer
     (same `rectExternal` / `Key('#__pageAnnotationLayer__:${page.pageNumber}')`).
     This guarantees the annotation layer is always present even when
     callers also set `pageOverlaysBuilder` — no public API collision.
   - The annotation layer is a `Stack` of:
     1. A `CustomPaint` that draws all strokes for the page in PDF point
        space scaled to the page's current widget rect. The painter calls
        `canvas.clipRect(Offset.zero & size)` first so strokes that
        extend beyond page bounds are visually clipped.
     2. **Only when** `annotationModeListenable.value == true`: a
        `GestureDetector` (`HitTestBehavior.opaque`) on top of the
        `CustomPaint` that captures `onPanStart` / `onPanUpdate` /
        `onPanEnd` / `onPanCancel`. Mounted via a `ValueListenableBuilder`
        on `annotationModeListenable` so the detector appears/disappears
        without rebuilding the surrounding viewer.
     3. The annotation layer subscribes to the private
        `_PdfAnnotationController` (a `ChangeNotifier`) for repaint
        triggers. The viewer's existing `_invalidate()` /
        `_updateStream` pipeline is **not** involved in annotation
        repaints.
   - When mode is off, the gesture detector is absent so taps flow
     normally to the viewer's link handling and to any overlays added by
     callers.

4. Stroke capture rules:
   - The per-page `GestureDetector` is sized exactly to the page rect
     (mounted inside the per-page `Positioned` from §3). `details.localPosition`
     is therefore already page-local — no further offset subtraction.
   - Pointer-down on page P starts a stroke anchored to P. The local
     position is converted to PDF points (top-left origin, Instant JSON
     convention) by:
     `pdfX = local.dx * page.width / pageRect.width;`
     `pdfY = local.dy * page.height / pageRect.height;`
     Both axes share the same scale (pages render isotropically); no
     coordinate flip is needed because we never traverse Pdfium's
     bottom-left native space — we go directly from page-local widget
     pixels to top-left PDF points.
   - Pointer-up commits the stroke (adds it to the page's stroke list,
     bumps the controller's `notifyListeners()`, and clears the
     in-flight buffer).
   - Pointer-cancel discards the in-flight stroke.
   - Drag updates beyond the page rect keep accumulating points in the
     start page's coord space (so x or y may exceed `page.width` /
     `page.height`); the painter's `clipRect` ensures they don't render
     past the page boundary.
   - A stroke whose start lands in the gutter (no page hit) cannot occur
     because the gesture detector is per-page; pointer-down outside
     every page falls through to the viewer's underlying gesture
     handling, which is inert (pan/scale disabled in mode).

5. While annotation mode is on, suppress programmatic navigation:
   `controller.goToPage`, `goToArea`, `goToRectInsidePage`, `goToDest`,
   `goTo`, `goToManipulated` must short-circuit (return immediately, no
   throw). Document this contract in their dartdoc.

**Functional — example app (`music_viewer`)**

6. Add an "edit" FAB (`Icons.edit`) to the bottom-left stack alongside the
   existing mode toggle. Tapping it calls `controller.enterAnnotationMode()`.
   While annotation mode is on, this FAB is hidden too.

7. Hide on annotation mode (driven by `controller.annotationModeListenable`):
   - the page-mode toggle FAB (Positioned in the body Stack),
   - the `skip_next` document-switch FAB (`Scaffold.floatingActionButton`),
   - the new "edit" FAB itself (it lives in the body Stack alongside the
     toggle),
   - **the entire `viewerOverlayBuilder` return value** — wrap its
     contents in a `ValueListenableBuilder<bool>` on
     `controller.annotationModeListenable`, returning `[]` while mode is
     on. This single switch hides both the left/right tap zones and the
     top page indicator (they're all in `viewerOverlayBuilder` today).
     The viewer's own per-page annotation layer is mounted internally
     (per §3) and is unaffected.

8. Show a bottom toolbar while annotation mode is on, with a single
   close `IconButton` (`Icons.close`) that calls
   `controller.exitAnnotationMode()`. The toolbar is a `Material`
   widget at the bottom of the body Stack, full-width, ~56px tall,
   wrapped in `SafeArea(top: false)` so the iPhone home indicator
   doesn't overlap.

9. Wire `PdfViewerParams.onAnnotationsChanged: (json) => ...` to write to
   `<tempDir>/pdfrx_annotations/<sha1Hex(absoluteFilePath)>.json` using
   `path_provider`'s `getTemporaryDirectory` and `package:crypto` SHA-1.
   Always write (even for empty `annotations`); never delete the file.

10. In `onViewerReady` (per document load), compute the same SHA-1-keyed
    path, read the file if it exists, and call
    `controller.applyAnnotationsFromJson(json)`. Wrap in try/catch — log and
    continue on parse error so a corrupt file never blocks document load.

11. Add `crypto` to `packages/pdfrx/example/music_viewer/pubspec.yaml`
    via `flutter pub add crypto` (no hardcoded version pin — let pub
    resolve to whatever the workspace allows).

**Instant JSON serialization**

12. Exported document shape:
    ```json
    {
      "format": "https://pspdfkit.com/instant-json/v1",
      "annotations": [ ...ink entries... ]
    }
    ```
    Omit `pdfId` and `skippedPdfObjectIds` (per Nutrient's storage guidance).

13. Each `pspdfkit/ink` entry must include:
    - `v: 1`
    - `type: "pspdfkit/ink"`
    - `pageIndex: <0-based int>`
    - `bbox: [left, top, width, height]` — computed from the stroke's points
      in PDF point space (top-left origin).
    - `opacity: 1.0`
    - `createdAt`, `updatedAt` — ISO 8601 UTC timestamps captured at
      stroke-finalize time.
    - `lines.points: [[[x, y], ...]]` — one segment per stroke (a stroke is
      one segment; this implementation does not split a single stroke into
      multiple segments).
    - `lines.intensities: [[1.0, 1.0, ...]]` — array of `1.0` matching point
      count (Instant JSON requires this field even when not pressure-aware).
    - `lineWidth: <PDF points, double>` — from
      `params.annotationStrokeWidth`.
    - `isDrawnNaturally: false`.
    - `strokeColor: "#RRGGBB"` — derived from
      `params.annotationStrokeColor`.

14. Imported document parsing:
    - Accept a JSON string. Tolerate either the wrapped form
      (`{"annotations": [...]}`) or a bare array of annotations.
    - Iterate `annotations`. Keep entries where `type == "pspdfkit/ink"`,
      `v == 1`, and `pageIndex` is within `[0, pageCount)`. Ignore everything
      else, including unknown types and out-of-range pageIndex (do not
      throw).
    - Stroke style fields (`lineWidth`, `strokeColor`, `opacity`) are read
      per-stroke from the JSON and used at render time. The
      `params.annotationStrokeColor`/`Width` defaults are only applied to
      **new** strokes drawn in the current session, not to imported ones.

**Coordinate math**

15. Page-local widget pixels → PDF points (top-left origin, Instant JSON
    convention). Input is `details.localPosition` from the per-page
    `GestureDetector` (already page-local; no further offset needed):
    `pdfX = local.dx * page.width / pageRect.width;`
    `pdfY = local.dy * page.height / pageRect.height;`
    Both axes share the scale (pages render isotropically). We bypass
    Pdfium's bottom-left native space entirely, so no Y flip is needed.

16. Stroke painting (PDF points → widget pixels): inverse of (15).
    Inside the per-page `CustomPainter`, the canvas already has its
    origin at the page rect's top-left; call
    `canvas.clipRect(Offset.zero & size)` first, then for each point
    compute `widgetX = pdfX * size.width / page.width` (and similarly
    for y) before stroking.

17. Assume page rotation is 0° for this iteration. Document the assumption
    in code comments; if the test corpus contains a rotated page, file a
    follow-up rather than handling rotation now.

**Edge cases** (also covered in `<boundaries>`)

18. Pointer-down in the gutter between pages → stroke is discarded.

19. Pointer drags off a page mid-stroke → points keep accumulating in the
    start page's coord space; rendering is clipped to the page rect.

20. Document switch while in annotation mode → forbidden by the example
    app's UI (the navigation buttons/zones are hidden). The viewer itself
    does not need to handle this case.

21. Mode toggle (1↔2 page) while in annotation mode → forbidden by example
    UI (toggle FAB hidden). Viewer does not need to handle.

22. Apply-from-JSON on an empty/whitespace string → treat as
    `{"annotations": []}` (clear current set). Apply on malformed JSON →
    throw `FormatException` (caller's `try/catch` handles it).

23. Switching documents with no saved annotations → `applyAnnotationsFromJson`
    is not called; the in-memory set must be cleared automatically when the
    underlying document changes (i.e. when `onDocumentChanged` fires).

**Validation (input bounds)**

24. `pageIndex` outside `[0, pageCount)` → annotation skipped at import.
25. `points` segment with fewer than 2 entries → annotation skipped (cannot
    paint a stroke).
26. `lineWidth <= 0` or missing → use `params.annotationStrokeWidth` as
    fallback.
27. `strokeColor` not parseable as `#RRGGBB` → use
    `params.annotationStrokeColor` as fallback.
</requirements>

<boundaries>
Edge cases (verbatim contract):
- Stroke starts in inter-page gutter → discarded (no entry created).
- Stroke crosses page boundary → anchored to start page; visually clipped to
  start-page rect; coords stored in start-page PDF point space (may exceed
  page bounds).
- Imported annotation with unknown `type` → ignored silently.
- Imported annotation with out-of-range `pageIndex` → ignored silently.
- Imported annotation missing required fields (`points`, `pageIndex`) →
  ignored silently.
- Empty document JSON (`{"annotations": []}` or empty file) → in-memory
  state cleared.
- Malformed JSON string passed to `applyAnnotationsFromJson` → throws
  `FormatException`; example app must catch and log.

Error scenarios:
- `path_provider` failure (rare) → caller's try/catch logs and continues;
  annotations remain in memory but not persisted that turn.
- File I/O failure on write → caller logs and continues; in-memory state is
  authoritative for the rest of the session.
- File I/O failure on read → caller logs and continues with empty
  annotations for the document.

Limits (acceptable for this iteration):
- No undo/redo. Pointer-up commits.
- No stroke deletion / eraser. (`clearAnnotations()` clears all but is not
  wired to UI yet.)
- No pressure or velocity. `intensities` is filled with 1.0.
- No multi-touch drawing. Only the first active pointer per page is
  honored; additional simultaneous pointers are ignored until the active
  one ends.
- Page rotation is assumed 0°.
</boundaries>

<implementation>
**New files in `packages/pdfrx/lib/src/widgets/annotations/`:**

- `pdf_ink_annotation.dart` — value class holding stroke data:
  ```dart
  class PdfInkAnnotation {
    final int pageIndex;
    final List<Offset> pointsInPdfSpace; // PDF points, top-left origin
    final double lineWidth;              // PDF points
    final Color strokeColor;
    final double opacity;
    final DateTime createdAt;
    final DateTime updatedAt;
  }
  ```

- `instant_json.dart` — pure functions:
  - `String encodeInstantJson(List<PdfInkAnnotation> annotations)`
  - `List<PdfInkAnnotation> decodeInstantJson(String json, {required int pageCount, required Color defaultColor, required double defaultLineWidth})`
  - Internal helpers: `Color colorFromHex(String)`, `String colorToHex(Color)`,
    bbox computation.
  - Pure Dart, no Flutter widget imports beyond `dart:ui`/`Color` from
    `flutter/material.dart`.

- `pdf_annotation_layer.dart` — internal widget mounted by the viewer for
  each page via the existing per-page overlay mechanism. Owns the per-page
  `CustomPainter` (stateless w.r.t. the painter; receives a snapshot of
  strokes and the page rect) and the conditional `GestureDetector`.

- `pdf_annotation_controller.dart` — **library-private**
  (`_PdfAnnotationController` underscore-prefixed) `ChangeNotifier` that
  owns the strokes list, the mode flag (a `ValueNotifier<bool>`
  exposed externally as `annotationModeListenable`), and the in-flight
  stroke buffer. Exposes (to `_PdfViewerState` / `PdfViewerController`
  only):
  - `Future<void> enterMode()` / `Future<void> exitMode()`.
  - `addStroke(PdfInkAnnotation)`.
  - `clear()` — internal; does NOT fire `onAnnotationsChanged`.
  - `setAll(List<PdfInkAnnotation>)`.
  - `String exportJson()`, `void importJson(String, {required int pageCount})`.
  - `notifyListeners()` is called after every mutation so the
    `PdfAnnotationLayer` repaints.
  - **No public class is exported from `pdfrx.dart`.** All access is
    through `PdfViewerController`'s public methods.

**Edits to existing files in `packages/pdfrx/lib/src/widgets/`:**

- `pdf_viewer.dart`:
  - Instantiate `_PdfAnnotationController` inside `_PdfViewerState`, one
    per `PdfViewer` lifecycle. Dispose it in `dispose()`.
  - Add public methods on `PdfViewerController` that delegate to the
    annotation controller: `enterAnnotationMode`, `exitAnnotationMode`,
    `annotationModeListenable`, `applyAnnotationsFromJson`,
    `exportAnnotationsAsJson`, `clearAnnotations`.
  - In `_goToPage` and the other `goTo*` internals (`goToArea`,
    `goToRectInsidePage`, `goToDest`, `goTo`, `goToManipulated`),
    short-circuit (early return, no throw) when
    `annotationModeListenable.value == true`.
  - **Reactive pan/scale**: the existing build at `pdf_viewer.dart:508-509`
    reads `widget.params.panEnabled` / `widget.params.scaleEnabled`
    directly. Replace those two lines with calls to private getters
    (e.g. `_effectivePanEnabled`, `_effectiveScaleEnabled`) on
    `_PdfViewerState` that return `false` when the annotation
    controller's mode flag is on, otherwise the params value. When the
    mode flag flips, the annotation controller fires
    `notifyListeners()`; `_PdfViewerState` listens to it and calls
    `setState(() {})`, causing the `InteractiveViewer` to rebuild with
    the new effective values. This rebuild is no worse than the
    existing `_toggleMode` rebuild in the example.
  - **Document change hook**: extend `_onDocumentChanged` (in the
    existing `didUpdateWidget` → `_widgetUpdated` → `_onDocumentChanged`
    chain at `pdf_viewer.dart:296-368`) to call
    `_annotationController.clear()` *before* invoking the user's
    `params.onDocumentChanged`. This guarantees the example's
    subsequent `onViewerReady` → `applyAnnotationsFromJson` repopulates
    a clean slate.
  - **Mounting the per-page annotation layer**: modify
    `_buildPageWidgets` at `pdf_viewer.dart:2237-2249` (after the
    `pageOverlaysBuilder` block) to also append a `Positioned` widget
    keyed `'#__pageAnnotationLayer__:${page.pageNumber}'` containing
    `PdfAnnotationLayer(controller: _annotationController, page: page,
    pageRect: rectExternal)`. This guarantees the layer mounts
    regardless of whether callers set `pageOverlaysBuilder`. The
    annotation layer is appended **after** the user's overlay so it
    sits visually on top.

- `pdf_viewer_params.dart`:
  - Add fields: `onAnnotationsChanged`, `annotationStrokeColor`,
    `annotationStrokeWidth` with defaults specified above.
  - Add typedef `PdfAnnotationsChangedCallback`.

- `packages/pdfrx/lib/pdfrx.dart`:
  - Re-export the public types: `PdfInkAnnotation`,
    `PdfAnnotationsChangedCallback`. (No need to re-export internal
    controller/layer.)

**Edits to `packages/pdfrx/example/music_viewer/`:**

- `pubspec.yaml`: add `crypto` via `flutter pub add crypto` (no
  hardcoded version pin). `path_provider` is already present.

- `lib/annotation_storage.dart` (new): top-level async functions. All
  three accept an optional `Directory? overrideTempDir` named param
  (defaults to `null`, which calls `getTemporaryDirectory()`) to
  enable testing with `Directory.systemTemp.createTempSync(...)`:
  - `Future<File> annotationsFileFor(String absolutePdfPath, {Directory? overrideTempDir})`
    — returns the path to
    `<tempDir>/pdfrx_annotations/<sha1Hex(absolutePdfPath)>.json`,
    creating the parent directory as needed.
  - `Future<String?> readAnnotations(String absolutePdfPath, {Directory? overrideTempDir})`
    — returns the file contents or `null` if the file doesn't exist;
    catches and logs I/O errors.
  - `Future<void> writeAnnotations(String absolutePdfPath, String json, {Directory? overrideTempDir})`
    — plain `file.writeAsString(json)`; catches and logs. (No
    `.tmp`+rename ceremony — the music_viewer is single-process and
    the user already accepted "save only on close.")

- `lib/main_page.dart`:
  - Add a new "edit" FAB (`Icons.edit`, bottom-left, stacked above or
    beside the existing toggle FAB) wired to
    `controller.enterAnnotationMode()`.
  - Gate UI visibility on `controller.annotationModeListenable`:
    - Wrap the toggle FAB, the `skip_next` FAB
      (`Scaffold.floatingActionButton`), and the new edit FAB itself in
      `ValueListenableBuilder<bool>` blocks that render `null` /
      `SizedBox.shrink()` while mode is on.
    - Wrap the **entire** `viewerOverlayBuilder` body in a
      `ValueListenableBuilder<bool>`; return `[]` while mode is on (per
      requirement §7). This single switch hides the page indicator AND
      the left/right tap zones.
  - Add a `Positioned` at `bottom: 0, left: 0, right: 0` of the body
    Stack containing a `Material` toolbar (~56px tall, wrapped in
    `SafeArea(top: false)`) with a single close `IconButton`
    (`Icons.close`) calling `controller.exitAnnotationMode()`. The
    `Positioned` itself is wrapped in
    `ValueListenableBuilder<bool>` so it renders only while mode is
    on.
  - In `PdfViewerParams`, set
    `onAnnotationsChanged: (json) async => writeAnnotations(currentPath, json)`.
    (The viewer awaits this future before fully exiting mode, so the
    write is guaranteed to flush even if the user immediately
    backgrounds the app.)
  - In `onViewerReady`, after the existing focus/event-listen lines, look up
    the saved JSON via `readAnnotations(currentPath)` and call
    `controller.applyAnnotationsFromJson(json)` if non-null. Wrap in
    try/catch.

**Patterns / what to avoid:**
- Do **not** leak Flutter `Color` / `Offset` types into `pdfrx_engine`. JSON
  encoding/decoding lives in `pdfrx` widgets layer.
- Do **not** save annotations on every stroke — only on `exitAnnotationMode`.
  This matches the user spec and avoids I/O thrash.
- Do **not** add a separate "annotation viewer mode" vs "edit mode" — there
  are exactly two states: mode on (drawing enabled) or mode off (rendering
  only).
- Do **not** add or remove the annotation layer dynamically per page — keep
  it always mounted; toggle the gesture detector only.
- All public APIs (methods, fields, typedefs, classes) **must** carry
  `///` dartdoc comments per `doc/agents/CODE-STYLE.md` ("Even important
  private APIs should have dartdoc comments"). For `applyAnnotationsFromJson`
  and `exportAnnotationsAsJson`, the dartdoc must explicitly state that
  document identity is the caller's responsibility (see §1).
</implementation>

<validation>
**Baseline coverage (must pass before "done"):**

The existing pdfrx test suite is minimal — `packages/pdfrx/test/pdf_viewer_test.dart`
contains a single `testWidgets` that mounts `PdfViewer.uri` with `hello.pdf`
via a mocked HTTP client. The validation below adds tests at the level the
project actually supports today; richer pan-gesture-simulation tests are
explicitly deferred (see "Known testing gaps" below).

- Pure-Dart unit tests for `instant_json.dart` (no Flutter binding needed):
  - Encode → decode round-trip preserves stroke count, page indices,
    points (within float epsilon), color, line width.
  - Decode skips unknown `type`, out-of-range `pageIndex`, `v != 1`, and
    too-short point segments (< 2 points).
  - Decode tolerates wrapped (`{annotations:[...]}`) and bare-array
    forms.
  - Decode of empty / whitespace string returns empty list.
  - Decode of malformed JSON throws `FormatException`.
  - `bbox` computation matches min/max of points in both axes for a
    multi-point stroke.

- Pure-Dart unit tests for `_PdfAnnotationController` (constructable with
  no Flutter widgets in scope):
  - `enterMode` / `exitMode` flip `annotationModeListenable` and are
    idempotent.
  - `clear()` empties strokes and bumps `notifyListeners` (use a
    counter listener).
  - `setAll([...])` replaces strokes and bumps notifications.
  - `addStroke(...)` appends and bumps notifications.
  - `exportJson()` returns identical output to
    `encodeInstantJson(controller.strokes)`.

- Unit test for `annotation_storage.dart` using
  `Directory.systemTemp.createTempSync(...)` as the override directory
  (no mocks):
  - `writeAnnotations` then `readAnnotations` round-trips the JSON.
  - `readAnnotations` for a non-existent path returns `null`.

- One widget test in `packages/pdfrx/test/pdf_viewer_test.dart` extending
  the existing pattern:
  - Mount `PdfViewer.uri('https://example.com/hello.pdf')` (hits the
    mocked HTTP client → `hello.pdf`), grab the controller via a
    `GlobalKey` or `onViewerReady`.
  - Call `controller.enterAnnotationMode()`; assert
    `controller.annotationModeListenable.value == true`.
  - Call `controller.applyAnnotationsFromJson('{"annotations":[]}')`
    succeeds without throwing.
  - Call `controller.exitAnnotationMode()`; assert
    `annotationModeListenable.value == false` and that the
    `onAnnotationsChanged` callback fired exactly once with a JSON
    string parseable by `decodeInstantJson`.
  - Call `controller.goToPage(pageNumber: 2)` while in mode → page
    number does NOT change (assert `controller.pageNumber` unchanged).

**Known testing gaps (explicit, deferred):**
- Simulating per-page pan gestures on rendered pages and asserting that
  strokes are appended in the correct PDF point coords. This requires
  building widget-test infrastructure that doesn't exist today
  (deterministic page layout in `pumpAndSettle`, gesture targeting on
  per-page overlays). Cover by manual smoke test (below) for now;
  file a follow-up if regressions appear.
- Asserting `InteractiveViewer.panEnabled` reactively flips. The
  internal `InteractiveViewer` is a private wrapper; finding it
  reliably in widget tests is brittle. The `_effectivePanEnabled`
  getter is unit-testable in isolation; cover at that level instead.
- Visual clipping of out-of-page strokes. Verify by code inspection of
  the `clipRect` call in the painter; defer goldens.

**TDD expectations:**
- Use the `flutter-tdd` skill during implementation. For each behavior
  above, write the test FIRST (RED), then the minimum code to pass
  (GREEN), then refactor. Order:
  1. JSON encode/decode round-trip + skip rules.
  2. `_PdfAnnotationController` mode flag & strokes list.
  3. `PdfAnnotationLayer` widget gesture wiring (subject to the
     deferred-tests caveat above — primarily covered by inspection +
     manual smoke test).
  4. `PdfViewerController` integration: enter/exit mode side-effects,
     navigation suppression, `onAnnotationsChanged` firing.
  5. Example app `annotation_storage.dart` round-trip with a real temp
     directory (no mocks; Dart's `IOOverrides` not needed — write to a
     dedicated subdir and clean up after).

**Testability seams:**
- `_PdfAnnotationController` is constructor-injectable into
  `PdfAnnotationLayer` — tests pass a fake instead of the real one.
- `instant_json.dart` is pure functions; no DI needed.
- For viewer-level tests, expose the annotation controller via a
  `@visibleForTesting` getter on `PdfViewerController` so tests can
  introspect strokes without decoding JSON. (`@visibleForTesting`
  ships with `package:flutter/foundation.dart`, which is already a
  transitive dep of pdfrx — no new package to add.)
- `annotation_storage.dart` accepts a `Directory? overrideTempDir`
  named parameter defaulting to `null` (which calls
  `getTemporaryDirectory()`); tests pass
  `Directory.systemTemp.createTempSync('annot_test_')`.

**Mocking policy:**
- Prefer fakes over mocks. Use real types where possible (real
  `_PdfAnnotationController` + spy listener; real temp directory).
- Mock only true external boundaries: don't need to mock `PdfDocument`
  beyond what is already done in existing pdfrx widget tests; reuse the
  same `MockClient` + `hello.pdf` pattern.

**Robot tests:**
- Skip robot-driven journey tests for this iteration. The critical UI
  journey (enter mode → draw → exit → reload) is covered by the widget
  test for controller integration above. Revisit if a follow-up
  iteration adds toolbar interactions worth exercising end-to-end.

**Manual smoke test (run before declaring done):**
- `cd packages/pdfrx/example/music_viewer && flutter run`
- Open document A, tap the edit FAB, draw two strokes spanning both pages
  in 2-page mode. Confirm the cross-page stroke is clipped at the page
  edge and not painted on the next page.
- Tap close. Confirm the toggle FAB, navigation FAB, indicator, and tap
  zones reappear.
- Tap `skip_next` to switch to document B. Confirm the strokes from A
  disappear (they belong to A only).
- Tap `skip_next` repeatedly until back to A. Confirm A's strokes
  reappear.
- Kill and relaunch the app; confirm A still has its strokes.
- Toggle 1-page mode and confirm the strokes still render in the right
  positions.
</validation>

<done_when>
- All listed unit and widget tests pass: `flutter test` clean in
  `packages/pdfrx` and `packages/pdfrx/example/music_viewer`.
- `dart analyze` is clean across both packages.
- The manual smoke test in `<validation>` passes end-to-end.
- New public APIs on `PdfViewerController` and `PdfViewerParams` carry
  `///` dartdoc per `doc/agents/CODE-STYLE.md`. The dartdoc on
  `applyAnnotationsFromJson` and `exportAnnotationsAsJson` explicitly
  states that document identity is the caller's responsibility.
- The example app's `main_page.dart` shows the bottom toolbar with the
  close button only while in annotation mode, with all other UI hidden as
  specified.
- Re-opening a previously annotated document restores its strokes
  automatically with no user action beyond opening it.
- Switching to a different document hides the previous document's
  strokes and shows the new document's strokes (or none).
- No changes to `packages/pdfrx_engine/` are required to ship the
  feature.
</done_when>
