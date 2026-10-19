# metadata.xml notes for the next Zeo release

`app-editors/zeo/metadata.xml` edits the release story owes, one per USE flag the
candidate ebuild (`zeo-next.ebuild`) adds. The overlay's `metadata.xml` is written
only by the release story, so each flag's description waits here until then.

## devtools-panel (patch 0063, story 055)

Add under `<use>`, after `browser-extension`:

```xml
<flag name="devtools-panel">Apply a source patch that gives the zeo-devtools panel page devtools threads of its own project, adds the `devtools: start`, `devtools: stop` and `devtools: open in browser` actions, and a badge and "Devtools threads only" filter in the thread list (needs browser-extension)</flag>
```

## epic (patch 0066, story 042)

Add under `<use>`, after `devtools-panel`:

```xml
<flag name="epic">Apply a source patch that adds a read-only Epic Stories dock panel listing the project's .epic/ stories with their status and tasks.md progress, updated live (needs claude-agent-acp-plus)</flag>
```

## voice (patch 0067, story 044)

Add under `<use>`, after `tracy`:

```xml
<flag name="voice">Apply a source patch that adds voice input to the agent composer: a microphone button and ctrl-alt-v (tap to toggle, hold to talk) record speech and whisper.cpp transcribes it on this machine into the composer, unsent; pulls in <pkg>app-accessibility/whisper-models</pkg> for the default speech model, and a remote OpenAI-compatible service is opt-in, off by default (needs claude-agent-acp-plus)</flag>
```

The `BENTOO-DIVERGENCE: metadata.xml` note in `zeo-next.ebuild` counts sixteen flags
once this one, `devtools-panel` and `epic` are in.
