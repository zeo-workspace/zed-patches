# metadata.xml notes for the next Zeo release

`app-editors/zeo/metadata.xml` edits the release story owes, one per USE flag the
candidate ebuild (`zeo-next.ebuild`) adds. The overlay's `metadata.xml` is written
only by the release story, so each flag's description waits here until then.

## devtools-panel (patch 0063, story 055)

Add under `<use>`, after `browser-extension`:

```xml
<flag name="devtools-panel">Apply a source patch that gives the zeo-devtools panel page devtools threads of its own project, adds the `devtools: start`, `devtools: stop` and `devtools: open in browser` actions, and a badge and "Devtools threads only" filter in the thread list (needs browser-extension)</flag>
```
