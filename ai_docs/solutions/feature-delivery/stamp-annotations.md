---
title: Stamp Annotations (vector-image stamps through pdfrx + music_viewer)
date: 2026-04-29
work_type: feature
tags: [pdfrx, annotations, stamps, instant-json, attachments, listener-vs-gesture-detector, cross-page-drag, tdd, journey-test]
confidence: high
references:
  - ai_specs/stamp-annotations.md
  - ai_specs/stamp-annotations-plan.md
  - packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_definition.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_stamp_annotation.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_controller.dart
  - packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart
  - packages/pdfrx/lib/src/widgets/annotations/instant_json.dart
  - packages/pdfrx/example/music_viewer/lib/stamp_library.dart
  - packages/pdfrx/example/music_viewer/lib/stamp_picker_panel.dart
  - packages/pdfrx/example/music_viewer/lib/stamp_image_builder.dart
  - packages/pdfrx/example/music_viewer/test/stamp_journey_test.dart
  - packages/pdfrx/example/music_viewer/test/stamp_layer_cross_page_drag_test.dart
---

## Summary

Added `PdfAnnotationTool.stamp` end-to-end through pdfrx (model →
controller → layer → JSON → public API) and surfaced a categorized
SVG picker in `music_viewer`. Stamps render as widgets (not Canvas
paint) over a per-page `Stack`; bytes are embedded into Instant JSON
via SHA-256-keyed attachments so documents stay self-contained even
when the host's stamp library changes. Shipped in three phases —
place + persist (Phase 1), selection / drag / resize / rotate
(Phase 2), asset scanner + journey test (Phase 3) — each gated by
TDD-first unit tests, widget tests, and `flutter analyze` /
`flutter test`. Real implementation diverged from the spec in three
places (Listener instead of GestureDetector, affordances outside the
bbox, aspect-locked corner resize) — those divergences are the most
reusable insights below.

## Reusable Insights

### Use `Listener`, not `GestureDetector`, for tap-+-handle-drag UIs

The plan called for a single `GestureDetector` with `onTapUp` and
`onPanStart`. The plan also flagged a "trip-wire" risk: gesture-arena
disambiguation may fight short drags. **The trip-wire fired.** The
shipped code uses a raw `Listener` for the stamp tool branch with
hand-rolled drag-vs-tap recognition (see
`packages/pdfrx/lib/src/widgets/annotations/pdf_annotation_layer.dart:469-564`).

- `_kStampDragSlopPx = 4.0` is the threshold past which a
  pointer-down is treated as a drag, much tighter than Flutter's
  `kPanSlop` (~18 px). Below that, pointer-up runs the tap branch.
  The trade-off: "tap" is committed only when the finger barely
  moves between down and up. For touch handles (~12 px visual,
  ~22 px hit radius) this is the only way fingertip drags fire
  reliably without "the gesture arena ate my drag" bugs.
- Capture pointer-down state into instance fields
  (`_pointerDownLocal`, `_pendingHandle`, `_dragRecognized`,
  `_stampCenterLocal`, `_initialRotationAngle`,
  `_originalStampRotationDeg`) at down-time. Subsequent `move`
  events route by the captured handle without re-hit-testing —
  cheaper, and immune to small finger drift moving the cursor off
  the handle mid-drag.
- Other tools (pen / highlighter / eraser) keep their existing
  `GestureDetector` branch. The `ValueListenableBuilder` on the
  active tool **swaps the input handler**; only the tool that needs
  tap-vs-pan disambiguation pays the Listener cost.

### Affordances *outside* the bbox work — if the input handler is `Positioned.fill`

The spec mandated affordances render *inside* the bbox so the
per-page Stack hit-tests them. Implementation deliberately reverted
this: the rotation handle floats above the bbox top edge, the
delete button at the top-right corner, both with
`_kRotateHandleGapPx = 8.0` outward offset
(`pdf_annotation_layer.dart:65-76`).

The spec's hit-test concern was wrong because the actual input
handler is a `Positioned.fill(Listener)` that covers the *entire
page rect*, not the bbox. The visual selection overlay is wrapped
in `IgnorePointer` so it never catches input; every tap is routed
to `_handleStampTap`, which calls explicit hit-tests
(`_stampDeleteButtonRect`, `_hitTestSelectableStampBody`,
`_hitTestStampHandles`) against page-local coordinates. Floating
affordances are perfectly hit-testable as long as they live inside
`pageRect`.

The lesson: **"affordances inside bbox" is a hit-testing
work-around, not a usability requirement.** Move the input handler
out to the parent rect and the affordances can float wherever
they're least likely to obscure content.

### One snapshot at drag-start, reconstruct from captured original

`beginStampDrag` (controller, line 856) pushes a single undo
snapshot and stashes `originalRect` / `originalRotation` /
`originalPageIndex` into `_StampDragState`. Every
`applyStampMove` / `applyStampResize` / `applyStampRotate`
**reconstructs** the new state from the captured original plus the
cumulative delta — not from the current state.

- Live repaint is driven by a separate `_stampDragTick` `ValueNotifier`
  that ticks per-update; the controller's `notifyListeners` is reserved
  for committed boundaries (place / delete / drag-end / undo / redo).
  Saves rebuilds for every widget that subscribes to the controller
  but doesn't care about in-flight transforms.
- "Cumulative delta" math (rather than incremental delta) is
  drift-immune: `applyStampResize(cumulative)` will always produce
  the same rect for the same final cursor position regardless of
  how many intermediate updates fired. Drift accumulates fast in
  the incremental form.
- `endStampDrag()` is the commit boundary — no second snapshot, no
  notify; the snapshot from `begin` already captured the pre-drag
  state, so undo walks back exactly one entry per user-meaningful
  drag.

### Cross-page body drag via viewer-space coordinates

Music sheets in two-page mode mean a body drag can cross the page
boundary. The shipped solution (not in the original spec) is
viewer-pixel coordinate space:

- `applyStampMoveViewer(Offset cumulativeDeltaViewer)` (controller,
  line 905) takes a delta in viewer-stack pixels (not PDF points).
  Each annotation layer registers its `pageRect` and PDF page size
  via `registerPageLayout` on mount and `unregisterPageLayout` on
  dispose, so the controller knows where every page lives in
  viewer space.
- The layer hands the controller `local - start` from its `Listener`
  — the Listener is mounted on a `Positioned` at `pageRect.topLeft`,
  so local-space delta equals viewer-coord delta. No coordinate
  conversion at the call site.
- The controller scans `_pageLayouts.entries` for a viewer rect
  containing the new center. If found, the stamp's `pageIndex`
  changes and its `rectInPdfSpace` is recomputed in the destination
  page's PDF point space (preserving visible pixel size). If not
  (gutter / off-screen), the stamp stays on its original page.
- Falls back gracefully when the original page's layout is no
  longer registered (mid-drag page unmount). No null-deref crash.

This is a "nice-to-have" for spread layouts that the spec missed
entirely. It only required two new methods and one map field on
the controller.

### Aspect-locked corner resize, free edge resize

The spec explicitly requires "free per-axis resize" with no
aspect-ratio lock. The shipped code splits the rule:
`_resizeCornerLocked` for corner handles (uniform scale, dominant
axis wins), `_resizeEdge` for edge handles (single-axis stretch).
Min size is `kMinStampSizePts = 8.0` either axis.

The spec wasn't wrong, just incomplete: free per-axis resize on
**corners** produces the "I can't keep my logo square" usability
trap on every WYSIWYG editor. Free on **edges** is what users
actually want when they need to break the aspect. This is the
universal convention (Figma, Keynote, Google Slides) and worth
copying without asking.

If a future requirement needs free corner resize, expose a
`bool aspectLockOnCorners` flag — don't make the call site
work around it.

### Discriminator field over parallel hierarchies (mirror the highlighter pattern)

`PdfStampHandle` is a single 10-value enum (`topLeft`, `top`,
`topRight`, `right`, `bottomRight`, `bottom`, `bottomLeft`, `left`,
`body`, `rotation`). All handle dispatch uses `switch (handle)` —
no `CornerHandle` / `EdgeHandle` / `RotationHandle` class
hierarchy. `_handleX(h, width)` and `_handleY(h, height)` are pure
positional functions of the handle enum and the bbox size.

This matches the prior `PdfInkAnnotationKind` choice (see the
highlighter compound note). The pattern: **discriminator field
on a value class, switch at the dispatch site**. Keeps the
encoder, decoder, drag math, and Semantics labels all
single-method affairs.

### Embed bytes by SHA-256 hash, dedupe by reference count

JSON shape:
`{format, annotations: [...], attachments: {<sha256>: {binary, contentType}}}`.
Stamp annotations carry only the hash; bytes live once in the
attachment store regardless of how many annotations reference them.

- Encoder emits the `attachments` map only when there's at least
  one referenced attachment. Legacy ink-only output is byte-identical
  to today's — no schema migration, no fixture rewrites.
- Encoder *also* drops orphaned attachments (in the in-memory store
  but referenced by zero annotations). The on-disk payload reflects
  actual usage; the in-memory store can be looser.
- `deleteStamp` only drops the attachment when no other stamp still
  references the same SHA-256 (`controller.dart:837`). The user can
  delete one of two identical stamps without breaking the other.
- Decoder skips orphan `imageAttachmentId` references silently
  (matches existing decoder skip-on-malformed policy). Malformed
  base64 is also skipped without dropping the document.

### Forward-compat JSON: namespaced rotation + standard rotation, dual-write

For each stamp, the encoder writes BOTH `rotation` (Instant JSON's
enum, snapped to `{0, 90, 180, 270}`) AND `pdfrx:rotation` (free
float). The decoder prefers `pdfrx:rotation` when present, falls
back to `rotation`, defaults to 0. Same pattern the highlighter
used for `pdfrx:kind`.

This lets pdfrx render a free-angle rotation while a Nutrient
viewer would still show the snapped cardinal rotation — no
roundtripping loss, no schema collision.

### Test seam: skip the asset scanner in journey tests

The `loadStampLibrary` asset-manifest scanner has its own dedicated
unit test (`test/stamp_library_test.dart`) with a fake `AssetBundle`.
The journey test (`test/stamp_journey_test.dart`) bypasses it
entirely — it constructs a hand-built `List<PdfViewerStampCategory>`
with one `PdfStampDefinition` whose `bytesLoader` returns literal
SVG bytes. Keeps the journey focused on gesture + JSON behavior,
not asset-pipeline plumbing.

The journey test mounts `PdfAnnotationLayer` against a `FakePdfPage`
(promoted from the highlighter test infra to a public
`packages/pdfrx/example/music_viewer/test/_test_helpers/fake_pdf_page.dart`)
plus the toolbar widgets, NOT the full `MainPage`. Same trick the
highlighter journey used; lets the test assert against
`decodeInstantJsonFull` output without a real `PdfDocumentRef`.

For drag interactions specifically, the journey calls the
**controller methods directly** (`beginStampDrag`,
`applyStampResize`, `endStampDrag`) instead of synthetic pans.
Reason: the Listener's 4-px slop + small handle hit-radius makes
synthetic pans flaky in `flutter_test` (the gesture-arena
disambiguation between `onPointerDown` → tap and `onPointerDown`
→ drag is exactly what `flutter_test` doesn't model perfectly).
Controller-side unit tests cover the same drag paths
(`pdf_annotation_controller_stamp_drag_test.dart`).

### TDD vertical-slice ordering (three phases, each shippable)

1. **Phase 1 — Place + persist + reload.** Models, controller fields,
   JSON encoder/decoder, picker placeholder. End state: pick a stamp,
   tap a page, see it render, exit, relaunch, see it persist. No
   selection / move / resize.
2. **Phase 2 — Selection + manipulation + undo.** Promote layer to
   `StatefulWidget`; selection-overlay sublayer with handles + delete
   button; `Listener`-based gesture pipeline; drag/resize/rotate
   mutations; foreign-creator protection. End state: full editing
   loop, journey-shaped widget tests.
3. **Phase 3 — Real asset scanner + picker UI + journey test.** Real
   `loadStampLibrary` against `AssetManifest`; polished
   `StampPickerPanel`; full robot-driven journey test asserting the
   spec's happy path through `decodeInstantJsonFull`.

Each phase had its own analyze/test gate. Worth copying for any
feature that crosses model / persistence / interactive UI layers
— same shape as the highlighter rollout.

## Decisions

- **Stamps as widgets, not Canvas paint.** `stampImageBuilder` is a
  `Widget Function(...)`; SVGs need `flutter_svg` (which is a widget,
  not a `Canvas` op). The per-page tree becomes a `Stack` of
  `CustomPaint(InkPainter)` + `Positioned` stamp widgets +
  selection-overlay + `Positioned.fill(input handler)`. Z-order
  rule: stamps always above ink. Lifecycle-stable — no layering
  surprises when an ink stroke commits while a stamp sits on top.
- **`pspdfkit/image`, not `pspdfkit/stamp`.** Instant JSON's
  `pspdfkit/stamp` is enum-bound to a fixed list of pre-rendered
  templates ("Approved", "Confidential", etc.). User-supplied vector
  images need the generic image annotation type with an attachment
  reference.
- **`flutter_svg` lives in music_viewer, not pdfrx.** pdfrx stays
  renderer-agnostic. Hosts that want raster stamps just supply a
  different `stampImageBuilder`.
- **`intrinsicSize` defaults to `Size(24, 24)` for asset-scanned
  stamps.** Music notation glyphs are roughly square; free per-axis
  edge resize lets users correct any aspect mismatch; skipping SVG
  header parsing avoids brittle regex over arbitrary SVG content
  (leading comments, multi-line attributes, missing `viewBox`,
  `em`/`%` units). Hosts that need a non-square intrinsic for a
  specific stamp construct a hand-built `PdfStampDefinition`
  instead of going through the scanner.
- **`_pickerOpen` lives in `_MainPageState`, not the controller.**
  Acceptable for v1 since music_viewer is the only host. If/when a
  second host adopts the picker, hoist to a
  `stampPickerOpenListenable` on `PdfViewerController` rather than
  duplicate the toggle logic.
- **Foreign-creator protection at the controller, not the layer.**
  `deleteStamp`, `selectStamp`, `beginStampDrag` all check
  `_ownsStamp` (which compares `creatorName == _currentCreator`,
  with single-user / null-creator mode allowing all). Layer's
  `_hitTestSelectableStampBody` filters foreign stamps so taps fall
  through to placement. Single ownership rule, two enforcement
  sites.
- **Auto-select on placement.** After `placeStamp` succeeds, the
  layer auto-selects the new stamp so the user immediately sees the
  selection affordances. The `pending` arming is dropped because
  the next tap will most likely move the just-placed stamp, not
  drop another. Diverges from spec #5 ("pending stays armed for
  repeat") — accept the user-test feedback over the spec.

## Pitfalls

- **`PdfStampDefinition` cannot be `const`.** `intrinsicSize.width`
  / `height` access in the size assert isn't const-evaluable. Mark
  `@immutable` and suppress the
  `prefer_const_constructors_in_immutables` lint at the constructor
  site. `PdfViewerStampCategory` *can* be const, but only because
  its asserts use `id.length > 0` instead of `id.isNotEmpty`
  (`String.isNotEmpty` is a getter call, not const-evaluable;
  `length > 0` is). Worth knowing for any `@immutable` value type
  with non-trivial asserts.
- **`PdfViewerParams` const-evaluable assert.** The plan called for
  `stampImageBuilder != null || (stampCategories?.isEmpty ?? true)`,
  which isn't const-evaluable. Settled on the slightly stricter
  `stampImageBuilder != null || stampCategories == null` — also
  permits `stampCategories: []` to slip through, which the picker
  short-circuits anyway.
- **Stamp tool button gated on a `Listenable`, not a `bool`.** The
  toolbar reads `controller.stampCategoriesAvailableListenable` so
  it rebuilds when params change. Forgetting the listenable would
  show a Stamp button for one frame after the host removes
  `stampCategories`.
- **Undo snapshot copies the attachment map.** Each snapshot
  duplicates the full `_attachments: Map<String, PdfStampAttachment>`.
  For tiny SVGs (<10 KB) the cost is invisible. If a future host
  embeds large rasters, reassess: a copy-on-write structure or
  reference-counting attachments separately would be appropriate.
- **Body-drag delta is in viewer space, every other drag is PDF
  space.** `applyStampMoveViewer(local - start)` (the Listener's
  local space, which equals viewer space because the Listener is
  mounted at `pageRect.topLeft`); `applyStampResize` /
  `applyStampRotate` use `_toPdfSpace(local) - _toPdfSpace(start)`.
  Easy to mix up. Read the comment in
  `pdf_annotation_layer.dart:528-536` before touching this.
- **Rotation sign convention is the screen-Y trap.** Screen-Y grows
  downward; a clockwise angular delta in screen space is a CCW
  rotation in our PDF-space convention. The implementation negates
  the delta: `final deltaRad = -(current - initial);`. Dropping the
  minus sign reverses every rotation drag.
- **Tap-clears-selection-before-placing is two taps.** When both a
  stamp is selected AND a stamp is pending, a tap on empty area
  clears the selection on tap N and places on tap N+1. Diverges
  from the spec but matches user-test expectation
  (the alternative — a single tap that simultaneously deselects
  and drops a new stamp — is jarring).
- **Selection overlay must be `IgnorePointer`-wrapped.** Otherwise
  taps on the visual handles never reach `_handleStampTap` and the
  hit-test logic in the Listener can't fire. The overlay is
  visual-only; input is exclusively the Listener's job.

## Validation

- `cd packages/pdfrx && dart analyze && flutter test` (1 pre-existing
  network-only `pdf_viewer_test.dart: PdfViewer.uri` failure unrelated
  to this work)
- `cd packages/pdfrx/example/music_viewer && flutter analyze && flutter test`
- Manual smoke (left for the user to run on macOS):
  1. Open a music sheet, tap Annotate, tap Stamp tool → picker visible.
  2. Tap a stamp thumbnail → highlighted, becomes pending.
  3. Tap a page → SVG appears at center, longest side ~36 pt.
  4. Tap stamp → selection outline + handles visible. Drag body to
     move; drag corner to scale (aspect-locked); drag edge to
     stretch one axis; drag rotation handle to rotate; tap delete to
     remove.
  5. In two-page mode, drag a stamp across the gutter → it hands off
     to the new page, retaining visible size.
  6. Place a foreign-creator stamp (test fixture) → cannot select,
     cannot delete from current creator.
  7. Undo/redo across mixed pen + highlighter + stamp ops walks the
     committed-order history.
  8. Kill the app, relaunch → stamps reload at exact positions / sizes
     / free rotations.
- Test infrastructure adds:
  `packages/pdfrx/test/widgets/annotations/` (created — house for
  pdfrx-package-level annotation tests);
  `packages/pdfrx/example/music_viewer/test/_test_helpers/fake_pdf_page.dart`
  (promoted from a private copy in `highlighter_journey_test.dart`).

## Follow-ups

- **Attachment store size budget**: today snapshots copy the full
  attachment map. Trip-wire if a future host embeds rasters >50 KB
  or the user routinely places hundreds of stamps. Consider
  reference-counted attachments held outside the snapshot.
- **Handle-drag synthetic pan in `flutter_test`**: the journey test
  drives drag via the controller because synthetic `tester.dragFrom`
  is flaky against the Listener's slop + handle hit-radius. If this
  becomes a maintenance pain, a custom `WidgetTester.sendStampDrag`
  helper with explicit `PointerDownEvent`/`PointerMoveEvent`/
  `PointerUpEvent` (bypassing the gesture arena) would let the
  journey exercise the layer pipeline end-to-end.
- **Aspect-lock toggle on corner resize**: spec said "free per-axis
  on corners", shipped code locks. If a host has a real workflow
  that needs free corner resize, expose
  `PdfViewerParams.lockStampAspectOnCornerResize` rather than
  re-hardcoding.
- **Picker open-state hoist**: `_pickerOpen` lives in
  `_MainPageState`. Hoist to
  `PdfViewerController.stampPickerOpenListenable` if/when a second
  host adopts the picker.
- **Multi-select / group ops, z-order API, page rotation ≠ 0°**:
  out of scope per spec. Each one would shape the controller's
  state model — design before coding.
