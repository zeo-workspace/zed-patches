# Changelog

All notable changes to the `zed-patches` repository are documented in this file:
the downstream patch **series** (which patches exist, which were added, retired,
split or renumbered, and which packaged version the series targets) and the
**tooling** under `scripts/` and `release/`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This repository has no version of its own and does not follow Semantic Versioning:
a section is keyed by the packaged version (`PVR`) the repository held at the time —
Zeo's, such as `0.2.1_p20261008`, since 2026-10-01, and `app-editors/zed`'s before.
Where the repository carries a `v<PVR>` tag, the heading says *tagged*; the others
say *untagged*. A tag marks the commit that holds `patches/<PF>/`; the first six
were created after the fact, on 2026-10-03, when `zeo-bin` moved to GitHub releases.

How it is kept: open entries under `[Unreleased]` as changes land, and rename the
section to the `PVR` when the package is cut. A tooling change goes in the section
of the series the repository held when it landed; the two that were prerequisites
of the next cut (the retarget to `app-editors/zeo`, and story 026's changelog gate)
are filed with that cut. **A patch's reasoning lives in its format-patch header**,
above the `---`, which `refresh.sh` carries forward byte for byte — not here. **What
a user sees lives in [`zeo/CHANGELOG.md`](../zeo/CHANGELOG.md)**; an entry here only
names the patch, its `USE` condition and the Zeo version that records it. This file
is for the maintainer: what changed in the series and in the tools, and what to do
differently because of it.

Before 2026-10-01 the series targeted `app-editors/zed-<PV>` snapshots, one
directory per `PF`, often several a day. Those sections are grouped by Zed minor
version, as a range of `PF`s dated by the last commit in the range; refresh-only
bumps inside a range are summarised rather than listed one by one.

## [Unreleased]

## [0.4.0_p20261009] — 2026-10-10 (untagged)

Same Zed snapshot as 0.3.0 (`089abd691`); a new feature, so Zeo moves to 0.4.0.
`patches/zeo-0.3.0_p20261009/` stays as 0.3.0 shipped it.

### Added

- `0052` (`USE=devtools-bridge`, default on, its own group after `claude-code-ide`
  and before `test`): the devtools bridge — crate `devtools_bridge` (unix socket,
  NDJSON protocol, listener, setting, wiring), `MentionUri::DomElement`, and
  `agent_ui::devtools_delivery`. It needs `claude-agent-acp-plus` (0040's router,
  0045's new thread), which the ebuild's `REQUIRED_USE` ties to it, and not
  `claude-code-ide`. `0050`/`0051` apply on top of it unchanged, with or without
  it. Story 033; the browser end is the `zeo-devtools` repository. Zeo 0.4.0
  records it.

## [0.3.0_p20261009] — 2026-10-09 (untagged)

Same Zed snapshot as 0.2.3 (`089abd691`); a new feature, so Zeo moves to 0.3.0.
`patches/zeo-0.2.3_p20261009/` stays as 0.2.3 shipped it.

### Added

- `0048` (ungrouped, unconditional): thread organization gets a store of its own,
  `ThreadOrganizationDb` -- a sqlez domain beside upstream's, with an append-only
  migration list, so an upstream step can never collide with it. No UI; it is what
  `0049` and the later organization stories read and write. Written on
  `zeo-0.2.1_p20261008` for story 031, forward-ported here (story 032).
- `0049` (ungrouped, unconditional, right after `0048`): the threads sidebar's
  Pinned section, `crates/sidebar/src/pinned_section.rs` and 36 tests in
  `sidebar_pinned_tests.rs`, plus `shift-p` in the three default keymaps. Zeo
  0.3.0 records it.
- `scripts/proofs/032-pinned-section/run.sh`: the section's live proof, driven
  off-desktop on `xvfb-proof.sh`.

### Changed

- `0025`: `prevent_root_execution` names Zeo ("Running Zeo as root or via sudo is
  unsupported"); `ZED_ALLOW_ROOT` keeps its name. The header gains the reasoning,
  the rest of it byte-identical.
- `0029`: its first `sidebar.rs` hunk follows the status check into
  `apply_live_row_state`, where `0049` moved it -- re-indented, the same change.
- `0010`, `0027`, `0028`, `0030`, `0035`, `0036`, `0037`, `0039`, `0040`, `0043`,
  `0044`, `0045` move in context only: generated on top of `0049`.

## [0.2.3_p20261009] — 2026-10-09 (untagged)

### Changed

- `0043`: a swallowed Enter is explained in the composer while the question is
  pending; the blocking rule is unchanged. User-visible, so Zeo moves to 0.2.3.
- `0025`: "zed is already running" reads the channel's display name, and
  onboarding's "unlock all Zed's features" says Zeo.

### Added

- The medium- and low-priority tests of the 2026-10-09 audit, in the patch each
  guards: `0002` (folderless withdrawal, frame loop, JSON-RPC validation, the
  terminal environment as one helper), `0008`, `0010`, `0011`, `0013`, `0015`,
  `0018` (the drop handler itself), `0022`, `0023`, `0025`, `0026`, `0029`, `0030`
  (the sidebar status as a truth table), `0031`, `0036` (restore through
  session/resume), `0037`/`0024`, `0038` (type and id capped), `0040`, `0042`
  (the delete race, in memory and on disk), `0043` (every default keymap), `0047`.
  Each was run with the line it guards reverted; two that still passed were
  strengthened until they failed.
- `scripts/test.sh <PF> [--from-tree] [--doc] [--ignored] [--e2e]`: the suite
  the release ships, versioned -- the series applied (or the prepared tree as it
  stands), the ebuild's offline rewrite, nextest run with rustup's toolchain for
  wasm32-wasip2, doctests, the ignored tests minus e2e, and the e2e suites with a
  key from the session keyring.
- `check-rebrand.sh` also tracks lowercase "zed" in prose (`rebrand/zed-prose.txt`):
  "zed is already running" was the miss that showed the gap.

### Changed (tooling)

- `0039`: the duplicate dock-fallback test is removed (it lives in `0039` because
  that patch is the last to touch the file).
- `0016`, `0017`, `0027`, `0032`, `0034`, `0035`, `0041`, `0044`, `0045` move in
  context only.

## [0.2.2_p20261009] — 2026-10-09 (untagged)

### Fixed

- `0042`: one task-history row this build cannot read (a status a newer Zeo
  wrote) no longer makes the whole history Unavailable — which also dropped
  every write for the session. The row is skipped with a warning naming it.
  User-visible, so Zeo moves to 0.2.2.
- `0001`: the two upstream tests adapted in `-r1` proved nothing — a debug
  build counts as staff, so the flag was on without the patch. They keep
  upstream's "off" override again and assert ON, which only `0001` makes true.

### Added

- `0050` (USE=test): three upstream git tests, `#[ignore]`d and rotted, revived —
  `test_git_status_postprocessing`, `test_ignored_dirs_events`,
  `test_odd_events_for_ignored_dirs`. 20/20 under `--stress-count 20`.
- `0051` (USE=test): the e2e suites made runnable on Linux, and run against
  Claude Agent (Plus) as well as the native agent — 16/16 with a real key.
  The ebuild applies `0050`/`0051` only under USE=test and requires the
  default adapter flags with it, since both are generated on top of them.
- Tests pinning what a bump could break silently, each verified to fail with
  its guard reverted: `0002` lock-file permissions and wrong-token handshake;
  `0021` Zeo's channel identity (`poll_for_updates() == false`) and Wasm API
  range; `0017` the status-less compaction frame; `0027` the card predicate;
  `0034` task-aware thread retention; `0037` batch entry sync; `0043` a URL
  elicitation blocking Enter (pinned on purpose) and `0005`'s Shift-Enter.
- `scripts/check-rebrand.sh`, run by `bump.sh` after verify: a new literal naming
  Zed's identity fails, a new `"…Zed…"` string is reported for triage, against
  the baselines in `rebrand/`.

### Changed

- `0010`, `0029`, `0031`, `0035`, `0036`, `0038`, `0040`, `0041`, `0044`,
  `0045` move in context only.

## [0.2.1_p20261009-r1] — 2026-10-09 (untagged)

### Fixed

- `0033`: `AgentRegistryStore::init_global` never ran its own first registry
  fetch, because the store's list always holds Zeo's two built-ins and the guard
  was `is_empty()`. Now it fetches when the list holds nothing else. Invisible in
  a running Zeo (default.json's registry agents trigger `refresh_if_stale`
  anyway); caught by the three `registry_refresh_*` integration tests.
- Seven upstream tests the series had left failing now describe the patched
  behaviour, in the patch that changes it: `0001` (acp-beta cannot be switched
  off: `test_compact_prompt_routes_to_manual_compaction`,
  `connection_routes_terminal_auth_without_acp_beta`), `0033` (the three
  `registry_refresh_*`, `test_remote_external_agent_server`) and `0035`
  (`test_action_namespaces`). `cargo test` over the 30 crates the series
  touches: 3899 passed, 17 ignored (all upstream `#[ignore]`), 2 failed — the
  flaky `test_multi_workspace_session_restore`, which passes alone, and
  `test_extension_store_with_test_extension`, which fails without the series
  too.

### Changed

- `0010`, `0034`, `0036`, `0040` and `0046` move in context only.

## [0.2.1_p20261009] — 2026-10-09 (untagged)

### Changed

- Refreshed onto Zed `089abd691` (20 commits past `20aff3132`).
  `agent-client-protocol` goes 3.1.0 -> 3.2.0; the schema stays at 1.10.2, and
  `0017`'s header now names 3.2.0.
- Upstream `1c9dd3e70` moved every session and tool call ID in shared agent state
  -- `AgentConnection`, `AcpThread`, the thread metadata store -- from schema v1 to
  v2. The series follows it: every `SessionId` and `ToolCallId` the patches keep in
  that state is now `acp_v2`, in `0024`, `0034`-`0042`, `0044` and `0045`. That
  includes `AgentConnection::stop_task`/`background_task` and
  `AgentTask::tool_call_id`. Only values put on the wire -- a
  `SetSessionModeRequest`, a test agent's `NewSessionResponse` or
  `SessionNotification`, `0029`'s sidebar test updates -- stay v1, converted
  explicitly as upstream does. Both versions serialize to the same JSON string, so
  the `acp_thread_config` records `0036` already wrote still read back.

### Fixed

- `0028` applies again: upstream's sidebar background became
  `color.background.blend(color.panel_background)`; only that context line moved.
- `0034` and `0036` apply again: upstream retyped `AcpConnection`'s session maps
  and `register_session`, and made `new_session` wait for registration before
  answering. `0036` now starts the config recorder inside that registration.

## [0.2.1_p20261008] — 2026-10-08 (tagged)

### Added

- `0047` (the About window names Zeo's version), **ungrouped**, placed after `0032`
  with the rebrand patches; see Zeo 0.2.1. The series is now 44 patches.
- `release-portable.sh` reads `ZP_PORTABLE_JOBS=<n>`, which gives the build
  container `--cpus n` and `CARGO_BUILD_JOBS=n`. Unset, the build still takes every
  host core; `taskset` on the docker client cannot do this, because its affinity
  does not reach the container.

### Changed

- The series directory was moved from `zeo-0.2.0_p20261008` with `git mv`, the
  step `zeo/docs/RELEASING.md` prescribes for cutting a version.

## [0.2.0_p20261008] — 2026-10-08 (untagged)

The directory was renamed to `zeo-0.2.1_p20261008` the same day.

### Changed

- Refreshed onto Zed `20aff3132`: all 43 patches applied without a conflict, 23 of
  them moved by offset or context only.

### Fixed

- `0017` compiles again: upstream's new compaction module made
  `ContextCompaction`'s summary a `MessageContent` and added `meta`, so both
  constructors the patch adds now build `MessageContent::default()` and
  `meta: None`. Its header now names `agent-client-protocol` 3.1.0 with schema
  1.10.2.

## [0.2.0_p20261007] — 2026-10-07 (untagged)

### Changed

- The series directory was moved from `zeo-0.1.1_p20261007-r1`; Zeo's version
  moved to 0.2.0.
- `0025` takes the application menu and the About window's title from
  `display_name()`, and treats `"Zed"` as the menu's old name so existing keymaps
  keep working; `0002` writes the release channel's display name as the lock
  file's `ideName` (`serverInfo.name` stays `"zed"`). See Zeo 0.2.0.

### Fixed

- `xvfb-proof.sh` gives its private session bus a configuration with no
  `<servicedir>`. With the stock one, Zeo's first keyring call started a `kwalletd`
  whose password dialog took every typed step of a proof.

## [0.1.1_p20261007-r1] — 2026-10-07 (untagged)

The directory was renamed to `zeo-0.2.0_p20261007` the same day.

### Changed

- Refreshed onto Zed `cb73ee1d4`. `0026`, `0027`, `0034` and `0045` conflicted on
  context only. Six patches stopped compiling in code they add, against upstream's
  ACP v1 → v2 migration, and were ported: `0027` (`acp_v2::ElicitationMode`), the
  test connections of `0034`, `0035`, `0037` and `0038` (v2 `AuthMethod`), and
  `0030`'s sidebar test.
- `0026` does **not** adopt upstream's new rule that an accepted form-elicitation
  answer is a user-authored scroll target: that is a behaviour change, left for a
  decision rather than slipped into a rebase.
- Known test failures on the applied tree are listed in commit `2d57151`; none is
  new (two `*_without_acp_beta` tests and `test_action_namespaces` are series
  expectations, three `agent_registry_store` tests fail only with `0033`).

### Fixed

- `xvfb-proof.sh`, story 021's audit advisories: an unknown key now fails the step
  instead of passing because `xdotool` exits 0; each part of a combination and any
  non-ASCII character is sent as a keysym; a Zeo that dies mid-run fails the next
  step instead of yielding empty captures; Zeo runs under `dbus-run-session` with a
  private runtime directory, so it can no longer reach `zeo-systray`'s socket; and
  process cleanup signals only the members of its own run.

## [0.1.1_p20261007] — 2026-10-07 (untagged)

The overlay's autoupdate moved the ebuild from `0.1.1_p20261006` to this version
with no series recorded here; the `-r1` refresh above replaced it the same day.

## [0.1.1_p20261006] — 2026-10-06 (untagged)

### Added

All six landed in this directory after the refresh, while `0.1.1_p20261006` and then
`0.1.1_p20261007` were packaged; Zeo's changelog records them under 0.2.0, the
version cut on 2026-10-07.

- `0041`, the tasks card's progress and "Open at Task", under
  `claude-agent-acp-plus` by dependency (story 023); see Zeo 0.2.0.
- `0042`, deleting archived records from the Agent Tasks panel, under
  `claude-agent-acp-plus` by dependency (story 025); see Zeo 0.2.0.
- `0043`, Enter does nothing in the composer while the agent's question is open,
  under `claude-agent-acp-plus` by choice (story 017). It has **no entry** in
  `zeo/CHANGELOG.md`.
- `0044`, the composer's sent-message history, under `claude-agent-acp-plus` by
  choice (story 018); see Zeo 0.2.0.
- `0045`, a slash command in a code block opens a new thread, under
  `claude-agent-acp-plus` by choice (story 020); see Zeo 0.2.0.
- `0046`, the default agents prefer the system adapter, **ungrouped** after
  `0033`, whose code it changes (story 019); see Zeo 0.2.0.

### Changed

- Refreshed onto Zed `ba8159b4d`. `0036` was rebased onto upstream's sequential
  defaults loop, which it now keeps as written, changing only where each value
  comes from. `0029`'s and `0034`'s blocks applied with fuzz 2 into the wrong arm
  and were moved back into the `SessionInfoUpdate` arm. `0034`, `0035` and `0037`
  build the v2 `PromptCapabilities` in their test helpers.

### Removed

- `0009` (adopt the agent's config-option response when applying defaults) is
  retired: upstream `78a0da201` (#65233) ships the same fix, with tests. The number
  stays retired and the series says why.

### Fixed

- `0041` puts the card's progress on a line of its own (story 023).
- `0044` ends history browsing when an earlier message is resubmitted, and then
  when any operator message enters the thread (story 018).
- `0045` logs the session of the clicked message instead of the panel's root
  thread, which was wrong for a subagent's message (story 020).

## [0.1.1_p20261005-r1] — 2026-10-05 (untagged)

### Changed

- Refreshed onto Zed `a1b71072e`: `0002`, `0020`, `0035`, `0036` and `0039` moved
  in context only; the other 33 are byte-identical.

## [0.1.1_p20261005] — 2026-10-05 (untagged)

The first package under Zeo's own version (story 026). The series directory was
moved from `zeo-0.1.0_p20261005`.

### Added

- `scripts/check-changelog.sh`: a packaged `zeo-X.Y.Z_p…` needs a line starting
  `## [X.Y.Z] — ` in `zeo/CHANGELOG.md` (or `ZP_CHANGELOG`). `check-sync.sh` runs
  it, so `bump.sh` and the workspace's `status.sh` report a missing section as
  drift (story 026).
- `scripts/changelog-notes.sh <PF>` prints that section's body, which becomes the
  GitHub release body. `release-portable.sh`, `release-zeo-bin.sh` and
  `make-bin-release.sh` refuse, before building, a version without a section
  (story 026).
- `0040`, one router that opens a session in its project's window, under
  `claude-agent-acp-plus` by dependency, after `0035` and `0039` (story 024); see
  Zeo 0.2.0.

### Changed

- **What a maintainer does differently:** a version is cut by writing its section
  in `zeo/CHANGELOG.md` first, then `git mv patches/zeo-<old PF> patches/zeo-<new PF>`
  and `check-sync.sh`; the rules are in `zeo/docs/RELEASING.md`.

### Fixed

- A release script that cannot read the changelog now exits 2 naming that cause,
  instead of reporting a missing section; `selftest.sh` runs every filter it is
  given (story 027).
- The release scripts print their whole header as help, so the help can no longer
  fall behind it (story 028).

## [0.1.0_p20261005] — 2026-10-05 (untagged)

The directory was renamed to `zeo-0.1.1_p20261005` the same day.

### Changed

- Refreshed onto Zed `cac9d17a`. `0008` (upstream renamed `acp_v1` to `acp_v2`) and
  `0002` (`cli` gained `default-features = false`) stopped applying on context;
  both were fixed in a temporary source series and refreshed from it.

### Fixed

- The test code of `0008`, `0034`, `0035`, `0037` and `0038` was ported to ACP
  schema v2; production code was unaffected.

## [0.1.0_p20261004-r2] — 2026-10-05 (untagged)

### Added

- `scripts/xvfb-proof.sh` runs a step script against an isolated Zeo on a private
  `Xvfb` display, so a GUI proof needs neither the operator's desktop nor a consent
  dialog. It validates the whole script before starting, accepts `live-proof.py`'s
  step format, keeps only captures that decode at a sane size, and stops Zeo and
  `Xvfb` on every exit. `scripts/examples/xvfb-proof-smoke.json` is its smoke test
  and the README documents it (story 021).

### Changed

- `0039` refreshed for story 022's second round: a rename editor that vanishes
  cancels, and the panel docks at the bottom by default; see Zeo 0.1.1.

## [0.1.0_p20261004-r1] — 2026-10-05 (untagged)

### Added

- `0039`, one-line task labels and Rename, under `claude-agent-acp-plus` after
  `0035` (story 022); see Zeo 0.1.1.

## [0.1.0_p20261004] — 2026-10-05 (untagged)

### Changed

- Refreshed onto Zed `279fe070` with `bump.sh`: 9 patches changed in context only,
  27 identical.

## [0.1.0_p20261003-r7] — 2026-10-04 (untagged)

### Added

- `0035`, the Agent Tasks panel, under `claude-agent-acp-plus` by dependency, after
  `0038` (story 014); see Zeo 0.1.1.

## [0.1.0_p20261003-r6] — 2026-10-04 (untagged)

### Changed

- Packaging only: the ebuild requires `>=dev-util/claude-agent-acp-plus-0.24.0`,
  the first adapter release that sends the snapshot `0037` reads. The series is
  `-r5`'s, byte-identical.

## [0.1.0_p20261003-r5] — 2026-10-04 (untagged)

### Added

- `0037` (the tasks card) and `0038` (the card's notification to `zeo-systray`),
  under `claude-agent-acp-plus` after `0034` (story 013); see Zeo 0.1.1. They were
  written as `0033` and `0034` and renumbered because both numbers were taken by
  the time they were registered.

### Fixed

- `cargo fmt --check` failed on seven hunks from our own patches: `0008`, `0014`,
  `0026` and `0027`, plus the tests of `0037` and `0038`. Each body was regenerated
  formatted, header byte for byte, and copied into `-r2` … `-r5`, which share the
  overlay's `files/`. Formatting-only, so no revision bump.
- Story 013's second round added tests to `0037` and `0038`; test code only, so
  `-r5` kept its revision.

## [0.1.0_p20261003-r4] — 2026-10-04 (untagged)

### Added

- `0034`, the agent's task feed, under `claude-agent-acp-plus` by dependency
  (story 012); see Zeo 0.1.1.

### Fixed

- `0029`'s test helper (rustfmt) and `0034`'s test comparison (clippy
  `cmp_owned`); test code only. `0029` was refreshed in `-r2` and `-r3` too, since
  they share `files/`.

## [0.1.0_p20261003-r3] — 2026-10-04 (untagged)

### Added

- `0036`, a reopened thread keeps its configuration, under `claude-agent-acp-plus`
  by choice (story 015); see Zeo 0.1.1.

## [0.1.0_p20261003-r2] — 2026-10-03 (tagged)

### Added

- `0033`, the Claude adapters as default agents, **ungrouped**; see Zeo 0.1.1.
- `scripts/release-portable.sh` and `release/portable/`: the series built inside a
  Debian 12 container (glibc 2.36, `x86-64-v3`, every input pinned by digest or
  sha256) and packaged as the `zeo-bin` tarball, a plain tarball, `.deb`, `.rpm`
  (nfpm), AppImage and Flatpak. It never uploads. Running it end to end found and
  fixed: clang instead of GCC 12 for the WebRTC headers, `t64` library names first
  in the `.deb` dependencies, `libX11-xcb` named explicitly, `libxcb-xkb` bundled in
  the AppImage.
- sccache (pinned by sha256) and a cargo home shared by every version under
  `ZP_PORTABLE_DIR`: 16m42s cold, 5m44s warm on `-r2`.
- `acp-probe.mjs` pins the `_claude/tasks` shape and probes it against the real
  CLI (story 012).

### Changed

- **From this version on, `zeo-bin` is the portable build.** The Gentoo-host route
  (`release-zeo-bin.sh`) remains, but links the host's `std`.

### Fixed

- Every `zeo-bin` up to `0.1.0_p20261003-r1` could die with *illegal instruction*
  on an `x86-64-v3` CPU without AVX-512: the host's Rust `std` is built for
  `znver5`, so `-r1` carried 85 AVX-512 functions. The check meant to refuse it
  never worked — `objdump | grep -q` under `pipefail` exited 141 from `SIGPIPE`.
  Both scanners now read the whole disassembly and flag only compiler-generated
  Rust/C++ symbols.

## [0.1.0_p20261003-r1] — 2026-10-03 (tagged)

### Added

- `0032`, the Flatpak escape recognises Zeo, **ungrouped** with the rebrand; see
  Zeo 0.1.1.

## [0.1.0_p20261003] — 2026-10-03 (tagged)

### Changed

- Refreshed onto Zed `a84689073d29`. `refresh.sh` stopped at `0006`, so the rest
  was carried by cherry-picking the `-r2` series, applied to its own baseline, onto
  the new one. Five patches needed a decision, each keeping upstream's change:
  `0006` wraps upstream's `ChoiceCard`, `0007` keeps both sides' tests, `0009`
  converts with `config_options::from_v1`, `0010` keeps upstream's stale-option
  guard (and one upstream test's expectation was changed to match Shift
  semantics), `0030` seeds pending questions in a loop of its own. Every header
  above `---` is byte-identical to `-r2`.
- One `agent_servers` test fails by design from here on: `0001` forces the ACP beta
  flag that `connection_routes_terminal_auth_without_acp_beta` asserts is off.

## [0.1.0_p20261002] — 2026-10-02 (untagged)

The overlay's autoupdate moved the ebuild to this version with no series recorded
here; `0.1.0_p20261003` was refreshed from the `-r2` series past it.

## [0.1.0_p20261001-r2] — 2026-10-01 (tagged)

### Changed

- `0022` accepts `zeo://` in every link, not only channel links; see Zeo 0.1.1.
- **`zeo-bin` is published as an asset of the `zeo-workspace/zeo` GitHub release
  tagged `v<PVR>`**, no longer to the overlay's R2 bucket. `make-bin-release.sh`
  checks that release for a name collision and prints the tag and `gh release`
  steps. The three tarballs already on R2 were attached, byte-identical, to
  `v0.1.0_p20261001`, `-r1` and `-r2`, and both repositories gained the matching
  tags (2026-10-03).

### Security

- `SECURITY.md`: where to report, and what this repository controls — the
  patches, the prebuilt release, no secrets in the scripts.

## [0.1.0_p20261001-r1] — 2026-10-01 (tagged)

### Changed

- `0002` publishes the IDE lock file only while the workspace has folders, and
  `0021` points the release notes at `zeo-workspace/zeo`; see Zeo 0.1.1.

## [0.1.0_p20261001] — 2026-10-01 (tagged)

The series moves from `app-editors/zed` to `app-editors/zeo`. New directories are
named after the Zeo `PF`; the `zed-*` directories are history.

### Added

- The rebrand patches `0019`–`0023` and `0025` enter `series` for the first time,
  **ungrouped and ahead of every `USE` group**, so their diff never depends on the
  flags; every feature patch was regenerated on top of them. See Zeo 0.1.0. Until
  now they had sat beside the zed series unrefreshed — still their 2026-09-12 bytes
  — and `0021` lost one hunk here because upstream removed
  `announcement_for_version`. The series is now 29 patches.
- `release/configroot/`, a versioned `/etc/portage` targeting `x86-64-v3`, because
  the host's `make.conf` appends `target-cpu=znver5` to any `RUSTFLAGS`.
  `release-zeo-bin.sh` compiles and installs under it without root;
  `make-bin-release.sh` refuses a non-`v3` or AVX-512 binary, writes a deterministic
  tarball with `PROVENANCE.txt`, and only prints the upload.

### Changed

- The tooling targets `app-editors/zeo` (`ZP_CATEGORY_PATH`), and the distfile name
  is read from the ebuild's `SRC_URI` rename (`zed-${EGIT_COMMIT}.tar.gz`) instead
  of being assumed to be `${PF}.tar.gz`. Landed just before the first Zeo directory,
  as its prerequisite.
- `make-bin-release.sh` keeps the revision in the tarball name
  (`zeo-bin-<PVR>-amd64.tar.xz`) and refuses a name the server already holds with
  different bytes, because the `zeo-bin` Manifest pins them.

## [zed-1.24.0_pre20261001-r1] — 2026-10-01 (untagged)

### Changed

- Refreshed from `zed-1.23.0_pre20260930` onto `71456c40`, without a conflict. The
  two autoupdate bumps in between (`1.24.0_pre20260930`, `_pre20261001`) never got
  a series of their own. The last series under `app-editors/zed`.

## [zed-1.23.0_pre20260924 … zed-1.23.0_pre20260930] — 2026-09-30 (untagged)

Ten directories, 2026-09-25 to 2026-09-30, growing from 19 patches to 23.

### Added

- `0028`, a folder dropped on the threads sidebar opens as a project, by choice.
- `0029`, a status for a thread with background work, by dependency (it reads
  `_claude/backgroundTasks`).
- `0030`, a status for a thread waiting for an answer, by choice.
- `0031`, session time and tool usage in the turn stats, by choice; first in the
  ebuild at `_pre20260927`.
- All four ride `claude-agent-acp-plus` and predate Zeo's changelog; they ship in
  Zeo 0.1.0.
- `scripts/acp-probe.mjs`, the ACP stdio probe, versioned after six rounds of
  rewriting it into `/tmp`: `init` and `plan`, later `fallback --notices`, `load`
  and `ask` modes. It drives an adapter with no editor, which is what separates an
  adapter fault from a client fault.
- Repository advisories in the advisory step (`report_repo_advisories`,
  `repo-advisories.mjs`): npm audit, osv-scanner and Dependabot all read the global
  database, which carries a repository advisory only after review, so they were
  blind to the same advisories at the same time.
- `check-sync.sh` gains a fourth relation: no patch may add a `*.orig` or `*.rej`
  file. Such litter applies cleanly, so `verify.sh` cannot see it.

### Changed

- `0026` grew from two controls to five (copy, previous, next, top, bottom), and
  the turn stats moved to the left from under its overlay. `0027` queues several
  question sets in one pinned card.
- `0002` advertises `close_tab`, which it dispatched but never declared, with a
  test holding the advertised list against the dispatched one.
- `0024` opens a session in its own project's window, with its own agent, instead
  of the focused window and the native agent.
- `_pre20260928`: upstream began importing ACP as `v1 as acp_v1` / `v2 as acp_v2`,
  and `refresh.sh` stopped at `0008`. **The series was carried by cherry-picking
  the previous version's built and tested commits onto the new baseline**, with one
  mechanical `acp::` → `acp_v1::` rule applied to every snapshot. This is the route
  to reach for when a refresh conflicts across many patches at once.
- `0009` and `0011` (`_pre20260924`), `0010` (`_pre20260925-r1`), `0011` and `0031`
  (`_pre20260930`) were rebased onto moved context; none changed what it does.
- `zed-1.23.0_pre20260925` was committed after the fact as the series the overlay
  had shipped.

### Fixed

- `0014`'s test fixtures still built `UserMessage` the pre-#64667 way. The breakage
  had been there since `a84858acb953`, hidden because nothing compiled the series
  with `--all-targets`; a redundant `to_string` there also failed clippy.
- A vulnerable range given as a bare version beside a named fix is read as
  open-ended up to the fix; before, two advisories on `@agentclientprotocol/sdk`
  went unreported.

## [zed-1.22.0_pre20260917-r1 … zed-1.22.0_pre20260923-r1] — 2026-09-23 (untagged)

Six directories, 2026-09-17 to 2026-09-23. `_pre20260919` never got one.

### Added

- `0027`, the pinned elicitation card, under `claude-agent-acp-plus` by choice. It
  was already in the overlay and the ebuild when it was first committed here.
- `status.sh`'s new *installed* column (what Portage has actually merged) gained
  fixtures in `selftest.sh`, and `lib.sh` the `ZP_VDB` override that feeds them.

### Changed

- Conflicts in `0006` (`_pre20260918-r1`), `0027` (`_pre20260922-r1`) and `0011`
  (`_pre20260923-r1`) were resolved **through a temporary source series**: fix the
  one patch, then re-refresh the whole series from that copy, so neighbours that
  only drifted are regenerated too. That became the standard route for a conflict.
- `check-protocol.sh` probes the first lock file that both answers and names itself
  Zed, and exits 0 ("not askable") when none answers, instead of reporting DRIFT
  against a stale lock. Exit 1 keeps its meaning, because `status.sh` calls it
  behind `|| true`.

### Fixed

- `0017`'s header claimed the linked ACP crate had no compaction notification; it
  has one. The correction is recorded in the header, and the comment in `series`,
  which repeated the claim, was corrected too. The diff below `---` is unchanged.

### Security

- `check-protocol.sh` took the port from a lock file's name and spliced it into a
  shell string, so a file named `$(command).lock` would have been executed. The name
  must now be digits within 1–65535, and the port is passed as an argument.

## [zed-1.21.0_pre20260909 … zed-1.21.0_pre20260915-r1] — 2026-09-21 (untagged)

Seven directories, committed 2026-09-11 to 2026-09-21; `_pre20260910`, `_pre20260911`
and `_pre20260914` (without revision) never got one. The series grew from 16 patches
to 18.

### Added

- `0024`, a deep link reopens an existing thread, **ungrouped**, numbered `0024`
  because `0019`–`0023` were reserved for the rebrand.
- `0026`, the floating thread controls, under `claude-agent-acp-plus` by choice;
  first in the ebuild at `_pre20260915`.
- The rebrand patches for the coming `app-editors/zeo`: `0019`–`0022` (2026-09-12),
  then `0023` (launcher) and `0025` (strings) after the first Zeo build. They lived
  in these directories **outside `series`**, selected only by the `zeo` ebuild's own
  `PATCHES+=()`, so `check-sync.sh` could not see them and every bump copied them
  forward unrefreshed. That lasted until `0.1.0_p20261001`.
- An advisory note naming workspace crates whose name and version collide with a
  published crate, which osv-scanner matches by construction (`telemetry 0.1.0` was
  being reported at CVSS 9.8).

### Changed

- The first `0021` carried the Zeo icons as git binary hunks. GNU `patch`, which
  both `refresh.sh` and `eapply` use, cannot apply those at all, so it was dropped
  and the channel patch renumbered `0022` → `0021`; the art is copied from the
  ebuild's `FILESDIR` instead. A later `0022` added the `zeo://` scheme.
- `0025` was written as `0024`, collided with a registered `0024`, and moved. **A
  number belongs to whoever registers it in `series` and the ebuild**, not to a file
  on disk.
- `_pre20260911-r2` was retargeted in place when the packaged commit moved without
  a new `PF`. `refresh.sh` refuses to overwrite an existing directory, so the old one
  is moved aside and used as `--from`.
- `kwin-window.sh` matches windows on "ze", so `dev.zeo.Zeo` windows are no longer
  silently missing from `list`.

### Fixed

- `0002`'s `Cargo.lock` hunk pinned `futures 0.3.32` in a block it *adds*, after
  upstream moved to 0.3.34; `cargo --locked` would have refused it. **`refresh.sh`
  rewrites context lines, never added ones**, so this class of drift needs a
  compiler, not a refresh.
- `0017` compiles again after upstream split `ContextCompaction`'s summary.
- `0024` as published in `_pre20260912-r1` was 13,069 lines, because a conflicted
  run had swept `.orig` and `.rej` files into it; the next refresh cut it back to 308.

## [zed-1.20.0_pre20260904 … zed-1.20.0_pre20260909-r1] — 2026-09-09 (untagged)

Seven directories, 2026-09-04 to 2026-09-09. The series grew from 10 patches to 16.

### Added

- `0013`–`0017`, five agent-panel patches under `claude-agent-acp-plus`: `0013`
  (per-model quota row) and `0017` (native compaction entry) by dependency, `0014`
  (copy own message), `0015` (archive scoped to its project) and `0016` (markdown
  preview of the draft) by choice. Each carries its reasoning in its header and its
  own tests.
- `0018`, a dropped folder opens as its own project — **the first ungrouped patch**,
  placed before the first `# @feature:` line and applied unconditionally.
- `live-proof.py` and `kwin-window.sh`, moved out of a gitignored `.epic/` story
  directory where they had been the only copy (story 009), with two guards learned
  from `zeo`'s `shot.sh`: refuse a locked session, and delete any capture that does
  not decode at a sane size.

### Changed

- `0009` was rebased as code (`_pre20260904-r1`) after upstream replaced
  `AcpSession`'s reference count; same shape, 10 hunks.
- `0016` gained a scrollbar and a toggle button; the command palette alone was not
  a way in that anyone found.

### Fixed

- The advisory step was scanning lockfiles under `claude-agent-fork/`, renamed to
  `claude-agent-plus/`, and reported both as *skipped* — so the shipped adapter went
  unscanned on every bump since the rename while the report looked clean.
- `selftest.sh` had lost its executable bit.

### Security

- `.gitleaks.toml` allowlists, **by value**, RFC 6455's sample WebSocket nonce that
  `0002` and `check-protocol.sh` use, so `gitleaks` reports zero findings and a real
  one would be read.

## [zed-1.19.0_pre20260826 … zed-1.19.0_pre20260902] — 2026-09-02 (untagged)

Eight directories, 2026-08-26 to 2026-09-02. The series grew from 8 patches to 10.

### Added

- `0011`, an Account section with the quota windows the adapter forwards, under
  `claude-agent-acp-plus` by dependency — the first patch written as a commit and
  exported with `git format-patch`, so it carries its own header.
- `0012`, a Worktrees entry in the agent panel's menu, under `claude-agent-acp-plus`
  by choice. From here on every patch's `series` comment says whether it rides its
  flag by dependency or by choice.
- `scripts/bump.sh`: refresh, verify, sync, check, each gating the next, stopping at
  the ebuild — which patches apply under which flag is the one decision no script
  makes.
- An advisory step (`report_advisories`, osv-scanner) run by `bump.sh` before its
  first step, reporting clean, findings, scan failed or skipped, and never changing
  an exit code (story 001).
- `scripts/check-protocol.sh`, which reads the Claude Code CLI binary for the
  protocol clauses `0002` depends on and probes a running editor's handshake:
  `verify.sh` proves `0002` applies, not that the CLI still speaks to it. Its
  transport clause was then re-anchored on shape rather than on minified names.

### Changed

- **`verify.sh` applies the series cumulatively**, each patch onto the one before
  it, in a throwaway worktree cut from the prepared tree's baseline, the way
  `eapply` does. Before, it dry-ran each patch against pristine source, and the
  stacked pair `0007`/`0010` passed only on fuzz. The prepared tree is never written.
- `bump.sh` blames the ebuild only when `series` and `PATCHES+=()` disagree; an
  overlay drift during a dry run says to re-run with `--apply`.
- The `series` header no longer names an ebuild version, which went stale within
  days; it names how `resolve_version()` finds the overlay's single ebuild.
- `0002`, until then a bare diff, gained a format-patch header with its provenance,
  just before the prepared tree that held its originating commits was deleted.

### Fixed

- `0002`'s fix for upstream's removal of `DiffBaseKind` had been made in the
  overlay's `files/` only, where the next sync would have erased it. It was carried
  back here and compiled (`_pre20260901-r1`).

## [zed-1.18.0_pre20260822 … zed-1.18.0_pre20260825-r1] — 2026-08-26 (untagged)

The repository's first four directories, 2026-08-23 to 2026-08-26 (story 001).

### Added

- The seven `app-editors/zed` patches, imported byte-identical: `0001`, `0005`–`0009`
  under `claude-agent-acp-plus` and `0002` under `claude-code-ide`. `0003`/`0004`
  stay retired, with the reason in `series`.
- The `series` format: apply order, `# @feature: <use-flag>` groups mirroring the
  ebuild's `src_prepare()`, free `#` comments.
- The tooling: `lib.sh` (resolve the ebuild, `EGIT_COMMIT`, distfile and work tree;
  parse `series`), `prepare-tree.sh`, `verify.sh`, `sync-overlay.sh` (writes only
  names `series` carries, reports orphans), `refresh.sh` (keeps each patch's header
  above `---`, regenerates the diff below it), `check-sync.sh` (`series` ↔ ebuild,
  patches ↔ overlay, patches ↔ source), `patch-branches.sh` and the fixture-only
  `selftest.sh`. Exit codes are uniform: 0 ok, 1 a patch does not apply, 2
  environment.
- `.zp-overlay`, which names the overlay checkout to write, ahead of `portageq`'s
  synced copy; a file naming nothing is an error, never a silent fallback.
- `LICENSE` (MIT), covering the tooling and `series` files but not the patch bodies,
  which remain under Zed's GPL-3.0.
- `0010`, Shift to set a menu choice as the default, under `claude-agent-acp-plus` by
  choice. `zed-1.18.0_pre20260825-r1` was recorded after the fact with `0010` in the
  form that shipped, which does not compile under `cargo check --tests`; the fixed
  form starts in the 1.19 directories.

### Fixed

- `verify.sh` restores the prepared tree's baseline before checking, because
  `refresh.sh` leaves a commit per patch there and the check was otherwise run
  against its own output. A tree with uncommitted edits exits 2 instead of being
  discarded.
