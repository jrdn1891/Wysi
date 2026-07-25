<img src="App/AppIcon.png" width="128" alt="WYSI icon">

# WYSI

**What You See Is** — a native macOS app for editing AI-generated HTML files as if they were regular documents.

Agents produce HTML — slide decks, landing pages, dashboards. WYSI is where humans polish it before sharing:

- **Click any text to rewrite it.** Plain-text editing with Escape to cancel, Enter to commit.
- **Drop in a replacement image.** From Finder or a picker; images inline as data URIs so files stay self-contained.
- **Manage slides in a filmstrip.** Reorder by drag, delete, duplicate — works for scroll decks, stacked decks, and opacity/visibility overlay decks.
- **Re-theme the whole document.** A native panel edits the `:root` CSS variables and body colors/fonts agent HTML already defines, patching declarations in place.
- **Format any element.** Bold/italic, size, colors, alignment via a bar on the editing ring.
- **A library of your files.** Live first-screen thumbnails, favorites (stored as Finder tags), full-text search, list and grid views. Files stay plain `.html` on disk — agents can keep rewriting them and WYSI reloads live.

Undo, find (⌘F), and save are native. The saved file differs from the original only where you edited.

## Download

Grab `WYSI.dmg` from the [latest release](https://github.com/jrdn1891/Wysi/releases/latest), drag WYSI to Applications.

The app is not yet notarized: on first launch, **right-click the app → Open → Open**, or clear the quarantine flag with `xattr -d com.apple.quarantine /Applications/Wysi.app`.

## Build from source

Requires Xcode command line tools.

```
make run     # build the app bundle and launch it
make test    # Swift test suite
make spike   # headless browser harnesses for the editor core (needs Chrome)
make dmg     # release build + WYSI.dmg
```

## For generating agents

WYSI edits static markup best. To make documents WYSI-friendly:

- Define the palette as custom properties on `:root` — the theme panel picks them up.
- Mark image slots with `<img data-wy-placeholder alt="…">` — they get a visible outline in edit mode.
- Content built by scripts at runtime is viewable but not editable.

## Architecture

One `WKWebView` hosts a parent page holding the canonical document (`DOMParser`); the rendered document lives in a sandboxed iframe with scripts paused during editing, emitting path-addressed ops that replay onto the canonical DOM. Saving serializes the canonical document — no diffing, no reformatting. See [PLAN.md](PLAN.md) for the full design, provenance (much of the editor core is ported from quickhost.my), and roadmap.
