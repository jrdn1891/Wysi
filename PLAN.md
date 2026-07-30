# WYSI — Implementation & UX Plan

## What it is

Agents produce HTML — slide decks, landing pages, dashboards — and humans need to touch them up before sharing: fix copy, swap an image, delete slide 7, reorder the rest. Today that means a code editor or another agent round-trip. WYSI is a native macOS app that opens these files in a WYSIWYG editor: click text to type, drop an image to replace it, manage slides in a filmstrip. Files stay plain `.html` on disk the whole time.

## Locked decisions

- **Shell:** Swift/SwiftUI + AppKit where needed; the document renders in a `WKWebView`; the editing engine is JavaScript inside it.
- **File model:** managed library — WYSI owns a folder of plain `.html` files — plus WYSI registers as an HTML editor so double-clicking any HTML file opens it.
- **v1 scope:** inline text editing, image replace, slide filmstrip (reorder/delete), slide insert/duplicate, element move within page flow. Color/property inspector is roadmap.
- **Images:** inlined as data URIs (downscale ≤1600px, WebP q0.85, JPEG fallback); documents stay self-contained.

## Inherited from quickhost.my

The hard problems are already solved in `/Users/gabriel/Documents/GitHub/quickhost.my` and port with little change:

| Mechanism | Source | Destiny in WYSI |
|---|---|---|
| Canonical DOM + paused live DOM, aligned by child-index paths | `public/editor.js:15-113` | Port as-is; the load-bearing invariant |
| Script pausing via `type="text/qh-paused"` | `editor.js:29-33` | Port; rename prefix `qh-` → `wy-` |
| Op vocabulary `setHTML / setAttr / remove / move`, save = `'<!doctype html>' + outerHTML` | `editor.js:65-84` | Port; add `insert` (slide duplicate) |
| `pathOf` / `nodeFromPath` child-index addressing | `doc-agent.js:27-46` | Port as-is |
| contenteditable `plaintext-only`, plain paste, Esc-cancels / Enter-commits, `editTarget` block→inline→text cascade | `doc-agent.js:424-425, 625-726` | Port as-is |
| Image replace: `<picture>` flattening, `srcset` removal, bitmap→canvas→WebP→data URI | `doc-agent.js:837-888` | Port as-is |
| Slide detection: dominant same-tag child group ≥3, scroll-shaped vs stacked, `linearize()` | `doc-agent.js:464-535` | Ported; extended — stacked decks may hide slides via `opacity`/`visibility` (not just `display:none`), and linearize unpins `position:fixed` wrapper ancestors so the page scrolls |
| Filmstrip: live full-width iframes CSS-scaled down, `dataset.doc` memoization | `editor.js:190-269` | Port as-is |
| Pointer-based drag reorder (4px threshold, midpoint targeting, edge auto-scroll, click suppression) | `editor.js:161-245` | Port; also reuse for element move |
| Palette sampling from the document for adaptive chrome | `comments.js:167-274` | Port for editor HUD colors |
| Test harnesses: path-alignment signature diff, malformed-HTML corpus, synthesized-event agent tests | `spike/` | Port first — regression net for everything above |

Known accepted limitation, inherited knowingly: content built by scripts at runtime is not editable — the canonical doc is the source file, never the runtime DOM.

## Architecture

```
┌─ Swift ──────────────────────────────────────────────┐
│ Library window        Editor window (per document)   │
│ (SwiftUI grid)        ┌ toolbar: title · Edit/Preview│
│                       │          · Play · Share      │
│ WysiDocument (NSDocument): read/write, dirty, undo   │
│ FileWatcher (DispatchSource): external-change reload │
│ Thumbnailer (offscreen WKWebView.takeSnapshot cache) │
│ WKURLSchemeHandler `wysi://` serving editor assets   │
└──────────────┬───────────────────────────────────────┘
               │ WKScriptMessageHandler ⇅ evaluateJavaScript
┌─ WKWebView ──┴───────────────────────────────────────┐
│ editor.html — the "session": canonical DOMParser doc,│
│ op replay, filmstrip UI                              │
│   └ <iframe sandbox="allow-scripts" srcdoc=…>        │
│     document + injected wy-agent.js                  │
│     (contenteditable, image replace, slide detection,│
│      element move) — postMessage ops up              │
└──────────────────────────────────────────────────────┘
```

The quickhost parent-page/iframe split is kept intact inside the `WKWebView`: `editor.html` plays the role quickhost's viewer page plays, the sandboxed `srcdoc` iframe hosts the user document with the agent injected. This keeps the entire proven editor core browser-testable without the app around it.

Swift sees only strings and events, never ops:

| Direction | Message | Meaning |
|---|---|---|
| Swift → JS | `load {html, mode}` | seed the session with file contents |
| Swift → JS | `undo` / `redo` / `flush` | menu commands |
| JS → Swift | `changed {html}` | committed gesture; Swift pushes prior string onto `NSUndoManager`, marks document dirty |
| JS → Swift | `state {deck, slideCount, canUndo, canRedo}` | drives toolbar/menu enablement |
| JS → Swift | `pickImage` → reply `imagePicked {dataUri}` | native open panel (in-page `<input type=file>` also works; native panel keeps UX consistent) |

Undo lives in `NSUndoManager` as full-document string snapshots (quickhost's model, bounded), so Cmd-Z, the Edit menu, and dirty state all behave natively. Undo re-seeds the session; scroll loss is accepted in v1 exactly as quickhost accepts it.

### Document lifecycle

- `WysiDocument` (NSDocument, UTType `public.html`, role Editor): free autosave-in-place, window restoration, titlebar rename, Duplicate, Revert, `NSFileVersion` history later.
- Saves are atomic writes of the canonical string. Nothing else — no diffing, no versioning of our own.
- **External-change watching is a first-class feature**, because the other editor of these files is an agent. `NSFilePresenter` on the open document: clean document → silent revert-from-disk (scroll resets — the same accepted loss as undo); dirty document → sheet "Changed on disk — Reload From Disk / Keep My Edits". This makes WYSI a live preview for Claude Code sessions writing the same file.

### Serving the document

`editor.html`, `wy-agent.js`, and editor CSS ship as bundle resources served through a `wysi://` custom scheme (clean absolute URLs inside the opaque-origin iframe). Documents referencing local relative assets get a `<base>` pointing at a second scheme rooted at the file's directory; with self-contained files as the norm this is robustness, not a main path.

## The library

- One folder, default `~/Documents/WYSI`, user-relocatable (security-scoped bookmark). Files in it are plain `.html`, fully visible and usable in Finder — "managed" means WYSI watches and displays the folder, not that files are hidden in an opaque bundle.
- Library window: sidebar (All Files / Favorites) beside a thumbnail grid or sortable list view (toggle persists). The search field matches titles, filenames, and document text — content is extracted with script/style/tag stripping, cached by mtime, and matches show a context snippet on the card or row. Sort by modified/title/filename. Cards show a live thumbnail, `<title>` (falls back to filename), modified date, and a star badge; favorites are stored as a Finder tag ("Favorite") on the file itself, so they survive moves and show in Finder.
- Thumbnails: live scaled-down `WKWebView`s (magnification ~0.25), one per visible card, lazily mounted by the grid — quickhost's workspace-card pattern. No snapshot cache to invalidate; FSEvents on the folder reloads cards live as agents write files.
- Card actions: open, inline rename, Duplicate, Move to Trash, Reveal in Finder, drag-out (real file drag), Share (`NSSharingServicePicker`).
- Import: drag files into the window or Dock icon, or File → Import — copies into the library.
- **External files** (double-click elsewhere on disk, since WYSI is an HTML editor): open and edit **in place** — never silently copy, the user expects their file updated. The editor toolbar offers one-click "Add to Library" (copies, then continues on the library copy). *This is my call — veto if you want open-always-imports.*
- Settings: library location; "Make WYSI the default app for HTML files" via `NSWorkspace.setDefaultApplication` (macOS 12+, system-mediated).

## The editor window

**Modes.** Opens in **Preview**: the live document, scripts running — dashboards render their charts, stacked decks animate. **Edit** (toolbar toggle, Cmd-E) re-renders the paused snapshot with the agent injected; **Done/Esc** returns to Preview. **Play** presents the live document full-screen. Preview/Play include a **laser pointer**: click-drag (or press-and-hold) draws a glowing trail for circling things — held strokes persist, released strokes fade over a second — and a laser gesture swallows its click so decks that advance on click don't jump; a quick tap still advances.

**Editing interactions** (all inside the iframe, all emitting ops):

- *Text*: hover shows the dashed ring; click places the caret and edits in place. Plain text only, Enter commits, Esc restores.
- *Images*: hover pill "replace" opens the picker; dropping an image file from Finder onto any `<img>` replaces it. Placeholder images (`<img data-wy-placeholder>`) get a persistent dashed outline — we publish this convention for generating agents, as quickhost does in `llms.txt`.
- *Element move* (new): repeated units — an element whose parent contains ≥2 same-tag siblings: cards, list items, sections — show a drag handle (✥) at their top-right on hover; pointer-drag from the handle reorders among siblings with an accent drop-line at the insertion edge. Same-parent only in v1; cross-parent drops produce layout chaos for no real use case.
- *Element resize* (new): the hovered box shows an accent grip on each edge that can actually move, and the pointer-drag resolves per axis — a grid item shifts the seam it shares with its neighbour (rewriting the parent's track list as `fr`, so the container keeps its size and the layout stays proportional), a flex item on the main axis is pinned with `flex: 0 0 Npx`, everything else takes a `width`/`height`. Drag deltas are divided by the element's local scale, so resizing works on transform-scaled slide canvases. No grip appears on an edge that coincides with the grid's outer boundary — moving it would leave dead space, not resize anything.
- *Filmstrip* (appears in Edit mode when a deck is detected): drag to reorder, hover `×` / `⧉` to delete or duplicate, a `+` at the strip end duplicates the current slide as the fast "one more slide" path. Click scrolls to the slide; current slide tracks scroll.

**Slide duplicate** (new op): `duplicate {path}` — the live DOM and the canonical document each clone their own node at the path and insert it after itself. No HTML payload round-trip, so the copy is byte-identical by construction.

**Keyboard**: Cmd-S save now, Cmd-Z/Shift-Cmd-Z undo/redo (also as toolbar buttons), Cmd-E edit/preview, Cmd-F find in document (titlebar bar; Cmd-G / Shift-Cmd-G next/previous, wraps, works in both modes via a `window.find` message agent since `WKWebView.find` cannot see into the sandboxed iframe), Esc cancel or exit edit, Enter commit text. In Edit mode arrows/PageUp/PageDown/Space page through the document — slide-by-slide when a deck is detected.

## Milestones — each with its verification check

**M1 — Editor core in the app shell.**
Xcode project; `wysi://` scheme; port `editor.js` session + `wy-agent.js` text editing; `WysiDocument` open/save/undo; the Swift⇅JS bridge.
*Verify:* port `spike/index.html` signature-diffing harness and `spike/stress.html` corpus; open a malformed agent-generated deck, edit five text nodes, undo twice, save; signature diff between canonical and live DOM stays empty, and the saved file diffs from the original only in the edited text.

**M2 — Slides.**
Detection + linearize, filmstrip with reorder/delete, insert/duplicate op, Play mode, Preview/Edit toggle.
*Verify:* against three real decks (one scroll, one stacked/script-driven, one non-deck page): filmstrip appears only for the decks; reorder+delete+duplicate then save; reopen — order correct, deleted slide gone, duplicate present, scripts still run in Preview.

**M3 — Images + element move.**
Image pipeline port, native picker bridge, drag-drop replace; repeated-unit move.
*Verify:* replace a `<picture>`-wrapped image and a `srcset` image by drag-drop; saved file is self-contained (zero network fetches when opened offline) and under size ceilings. Drag a card among three siblings; saved HTML shows the elements reordered, nothing else changed.

**M4 — Library + file citizenship.**
Library window, thumbnail cache, import/rename/duplicate/trash/reveal/share, external-change watching, external-file open + Add to Library, default-handler setting, palette-adaptive editor chrome, notarized DMG.
*Verify:* run a Claude Code session that rewrites a deck in the library while WYSI shows it — card thumbnail and open editor both refresh; dirty-document conflict shows the banner. Double-click an HTML file on the Desktop — edits land in that file. Fresh-machine install from the DMG passes Gatekeeper.

## Testing

The JS editor core stays dependency-free vanilla ES modules, runnable in a plain browser — all four quickhost spike harnesses port and run headless (Playwright) in CI without the app. XCTest covers the Swift layer: atomic save, watcher debounce, undo registration, thumbnail cache invalidation. Every editor bug gets a failing corpus page first.

## Risks

- **WKWebView + sandboxed `srcdoc` + custom scheme interplay** — the one genuinely unproven combination. Spiked inside M1 week one; fallback is dropping the iframe and injecting the agent into the document's own `WKWebView` via `WKContentWorld` (filmstrip moves to snapshot-based thumbnails).
- **Parser divergence** on malformed HTML between `DOMParser` and the live engine — same engine (WebKit) on both sides in WYSI, which is actually a stronger position than quickhost's; the signature harness guards it.
- **Script-generated content isn't editable** — accepted and documented; the placeholder/`llms.txt` convention pushes generating agents toward static markup.

## Property editing

Two layers, both riding the existing op machinery — a `<style>` element's `innerHTML` is its CSS text, so patching a declaration is a `setHTML` op (with one extension: ops carry `root: 'head'` since style blocks live outside `<body>`).

- **Document theme (phase A)**: the agent enumerates custom properties and body-level declarations from inline stylesheets, classifies them (color / gradient / font / simple size), and reports them to Swift. A native Theme popover shows real controls — `NSColorWell` with eyedropper, font-stack picker, size steppers. Dragging previews via an injected override style (instant, touches nothing); committing textually patches the declaration in place, anchored on `name: old-value`, replacing all occurrences (handles `@media` re-declarations) and leaving every other byte of the file alone. Cross-origin sheets are skipped; documents without variables (Tailwind CDN) get an honest empty state.
- **Element format bar (phase B, shipped)**: a bar attached to the editing ring — bold/italic toggles, font-size ±10%, text/background color via native color inputs (live preview, one op per pick), alignment cycle — all written to the element's `style` attribute (`setAttr` op), with a computed-style check that re-applies with `!important` when the document's own CSS wins. The bar survives color-panel focus loss and dismisses on click-away/Escape.
- **Phase C**: gradient stop editing (per-stop color wells), curated web-font additions.

Not attempted, permanently: arbitrary selector/cascade editing — that is DevTools, not WYSI. Document-wide *size* editing only exists where size variables exist; agent decks mostly use `clamp()` inside rules, which stays read-only.

## Roadmap after v1

1. **Element format bar + gradient stops** — phases B and C above.
2. **Publish integration** — one-click publish to quickhost.my (its `handlePublish` API, edit tokens, invites, and comments already exist; WYSI keeps the token and pushes updates on save). This is a sharing channel, not the collaboration answer: multi-editor collaboration stays an open design question — candidates include CRDT-style sync on the file, a dedicated service, or OS-level file sharing — and gets decided on its own merits when we get there.
3. Finer undo (inverse ops; keep caret and scroll), `NSFileVersion` history UI, text-style toolbar (bold/links), paste-to-replace-image, Quick Look extension, Spotlight importer for `<title>`.
