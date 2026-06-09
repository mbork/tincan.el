# Decisions

This file records non-obvious design decisions made while implementing tincan,
together with the reasoning behind them, so that any decision can be revisited
or reverted in isolation.  Each entry notes the commit theme it belongs to.

## Python transcript script

### D1 - Language and dependencies
Python 3, standard library only, no third-party dependencies.
Rationale: KISS MVP; the script only reads JSONL files and writes text.

### D2 - Script filename: `tincan-tail.py`
Rationale: its job is to print/tail a session transcript; the name follows the
project's lowercase-with-dashes file-naming convention.

### D3 - Session resolution
The positional argument may be: a path to a `.jsonl` file, a full session id,
or a unique session-id prefix.  Non-path arguments are resolved by globbing
`~/.claude/projects/*/*.jsonl` across *all* projects.
Rationale: session ids are UUIDs and globally unique, so this avoids having to
reconstruct Claude Code's fragile encoding of the working directory into the
project directory name.  An exact stem match wins; an ambiguous prefix is an
error.

### D4 - Config directory discovery
Honor `CLAUDE_CONFIG_DIR` if set, otherwise use `~/.claude`.
Rationale: matches Claude Code's own behavior and keeps the script robust.

### D5 - Which records are rendered
Only `user` and `assistant` records are rendered.  Bookkeeping records
(`mode`, `permission-mode`, `system`, `attachment`, `file-history-snapshot`,
`ai-title`, `last-prompt`, ...) are skipped in the MVP.
Rationale: they are not part of the human-readable conversation.

### D6 - Section markers: `@@@ ROLE`
Each rendered block is introduced by a line of the form `@@@ USER`,
`@@@ ASSISTANT`, `@@@ THINKING`, `@@@ TOOL_USE <name>`, `@@@ TOOL_RESULT`.
Rationale: `@@@` at the beginning of a line is rare in prose, code, and tool
output, so the Emacs side can font-lock reliably.  The markers live in
constants and are trivially changeable.

### D7 - Block body rendering
Tool-use inputs are rendered as pretty-printed JSON (`indent=2`).  Tool results
are rendered verbatim, with no truncation in the MVP.
Rationale: generic and lossless; the Emacs side can prettify later if wanted.

### D8 - Skip blank blocks
A block whose body is empty/whitespace produces no output (no bare header).
Rationale: thinking text is often not persisted to the transcript (only a
signature is kept), which would otherwise yield empty `@@@ THINKING` headers.

### D9 - Output discipline
The only thing written to stdout is transcript text, flushed after every write.
All diagnostics go to stderr.  `BrokenPipeError` (downstream reader closed) and
`KeyboardInterrupt` exit quietly.
Rationale: a downstream `tail -f`/`auto-revert-tail-mode` must see a clean,
append-only stream.

### D10 - Follow mode
`--follow`/`-f` drains the file, then polls every 0.25 s using a plain read
offset.  Only newline-terminated lines are processed, so a half-written record
is never parsed; `handle_line` additionally swallows JSON errors.
We assume session files are append-only (Claude Code never truncates or
rewrites them), so there is no rotation/truncation handling.
Rationale: KISS resilience without inotify or extra dependencies; the newline
rule is what actually guarantees we never parse incomplete JSON.  Speculative
truncation handling was removed because it cannot occur in practice and a
half-correct version (it missed in-place larger rewrites) is worse than none.

### D11 - `--show-sessions`
Lists only the *current* project's sessions, i.e. those whose `cwd` field
equals the process working directory (matching `claude --resume`).  Output is
tab-separated `id<TAB>timestamp<TAB>title`, one per line, newest first.
The title is the `aiTitle` if present, else the first user prompt (collapsed to
one line and truncated), else the session id.  Timestamps are the first
record's timestamp, shown in local time as ISO-8601 with offset.
Rationale: the id is needed so the caller (Emacs) can pick a session; tabs make
parsing trivial; restricting to the current project is the relevant set for
driving Claude Code from a project buffer.  Each file is fully scanned because
`aiTitle` can appear late; acceptable for the expected handful of sessions.

## Emacs view mode

### D12 - Single `tincan.el` with the standard package skeleton
All Emacs code lives in one `tincan.el` (header, Commentary, Code, footer).
Outli sections use `;; *` / `;; **` within the Code section; the conventional
`;;; Commentary:` / `;;; Code:` lines do not clash with that pattern.
Rationale: KISS for a small package; the view mode, future input mode, and
orchestration command are all small and naturally cohabit one file.

### D13 - `tincan-view-mode` derives from `special-mode`
Rationale: it is a read-only viewer, and `special-mode` provides read-only
buffers plus convenient keys (q, g, SPC, n/p).  It stays compatible with
`auto-revert-tail-mode`, which binds `inhibit-read-only` when appending, so the
buffer can still follow the growing transcript.  The mode handles display only;
launching the tail and turning on auto-revert is the orchestration's job.

### D14 - Font-lock only the `@@@ ROLE` marker lines
Five customizable faces (`tincan-user`, `tincan-assistant`, `tincan-thinking`,
`tincan-tool-use`, `tincan-tool-result`) inherit from theme font-lock faces and
are applied to the whole marker line; `font-lock-defaults` is keywords-only (no
syntactic fontification).  Block bodies are not fontified in the MVP.
Rationale: matches the "very simple" brief, looks reasonable in any theme, and
keeps the marker contract with tincan-tail.py explicit in one `defvar`.

### D16 - Markdown rendering via a runtime dispatcher
Transcript bodies are Markdown (Claude's output), so `tincan-render-buffer`
activates a Markdown major mode when available and layers the `@@@ ROLE` markers
on top with `font-lock-add-keywords`; the marker keywords carry the OVERRIDE
flag so they always win over Markdown's own fontification.  `tincan-view-mode`
(from D13) becomes the plain fallback used when no Markdown mode is available.
Mode choice is controlled by `tincan-markdown-mode` (t = auto-detect
`gfm-mode`/`markdown-mode`; nil = disabled; a function symbol = that mode, e.g.
`gfm-view-mode`).  The buffer is forced read-only in every case.
Rationale: a runtime dispatcher (rather than `define-derived-mode` with a
Markdown parent) is needed because `define-derived-mode` fixes its parent at
macro-expansion time, which byte-compilation would freeze to whatever was
available when compiled - the wrong choice if Markdown is installed later.
Auto-detection prefers the editing modes (markup visible, fontified) over the
view modes so exact code/markup stays readable in a transcript; users who want
the rendered look can set `tincan-markdown-mode` to `gfm-view-mode`.

### D17 - Native code-block fontification on by default
When a Markdown mode is used, `tincan-render-buffer` sets
`markdown-fontify-code-blocks-natively' buffer-locally so fenced code blocks are
highlighted with each language's own major mode.  This is gated by the
`tincan-fontify-code-blocks-natively' defcustom (default t).
Rationale: agentic-coding transcripts are code-heavy, so per-language
highlighting is worth a lot; the opt-out exists because native fontification
loads language major modes, which can add overhead on a large, continuously
tailed buffer.

## Revisited decisions

### D15 - Polling, not inotify, for follow mode (revisits D10)
Follow mode keeps the 0.25 s polling loop instead of switching to inotify.
inotify would only replace the wait step (the offset tracking, the
newline-complete-line rule, and the JSON resilience are all independent of how
we wait), so it changes little of substance, while it costs:
- A dependency: Python's stdlib has no inotify module, so it means a new
  dependency (`inotify_simple`/`pyinotify`/`watchdog`) or ~30-40 lines of
  `ctypes` against libc.
- Portability: inotify is Linux-only, so it would not replace polling but add a
  Linux-only fast path that still needs the polling loop as a fallback.
- Extra edge cases: a setup race (must drain to EOF after arming the watch,
  with a timeout as a safety net) and, for full robustness, watching the
  directory rather than the file inode.
The benefit is marginal: at most ~250 ms less latency and a few trivial reads
per second saved on an idle, human-facing viewer.
If latency ever feels laggy, the cheap first move is lowering
`POLL_INTERVAL_SECONDS` (e.g. to 0.1) - portable, one line, no deps.
Reserve inotify for the case where profiling shows polling is a real problem,
which for a transcript viewer it should not be.

### D18 - Fence TOOL_USE and TOOL_RESULT bodies (extends D7)
TOOL_USE bodies are wrapped in a ```json fenced code block and TOOL_RESULT
bodies in a plain (language-less) fence, so a Markdown view renders them as
code (and, with D17, highlights the JSON natively).  `format_block` grew a
`lang` argument: `None` renders the body as-is (USER/ASSISTANT/THINKING stay
prose Markdown), any string fences it.  The fence length is one backtick longer
than the longest backtick run inside the body (minimum three), per the
CommonMark rule, so embedded backticks/fences cannot close the block early.
Tool-result errors are flagged on the marker line (`@@@ TOOL_RESULT (error)`)
rather than inside the fenced body, keeping the body verbatim.
Rationale: tool I/O is data/code, not prose, so it should be monospaced and not
interpreted as Markdown; only these two block kinds are fenced because the
others are genuinely prose.

### D19 - Render turn_duration as `@@@ DONE`, for transcript-based completion
A `system` record with `subtype: turn_duration` is rendered as a standalone
`@@@ DONE (Ns)` marker (seconds rounded from `durationMs`); the Emacs side adds
a matching `tincan-done` face.  This is also the planned signal for detecting
that the agent has finished a turn, in place of Claude Code Stop hooks.
The transcript carries `turn_duration` exactly once at the true end of each
turn, immediately after the final `assistant` message - strictly better than
`stop_reason: end_turn`, which can occur twice within one turn.  Detecting
completion from the transcript reuses the single channel the follower already
streams, so no `settings.json` hook setup is needed.
Known limitations (to be covered later): abnormal endings (interrupt, crash,
API error) emit no `turn_duration`, so a manual escape hatch
(`tincan-unblock-agent-manually`) will be provided; and a mid-turn pause for a
permission prompt looks like "working" (no `turn_duration` yet), which is the
one case a `Notification` hook would handle better - it can be added narrowly
if it proves annoying.
The literal TUI string ("Cooked for Ns", with a randomized verb) is not stored
in the transcript and is deliberately not reproduced; only the duration is.

### D20 - Optional Notification hook via a status file (addresses D19's gap)
The "Claude is waiting for your input" state (tool-permission prompt or idle)
is the one case the transcript cannot express (D19), so it is covered by an
*optional* Claude Code `Notification` hook.  The hook is
`tincan-tail.py --notification-hook`: it reads the event JSON on stdin and
writes the message to a small per-session file at
`<config-dir>/tincan/<session-id>.notify`.  A file, deliberately, not
`emacsclient`, so the producer stays a plain stdin-to-file script with no Emacs
coupling.
Installation lives in the Python script too: `--install-hook`,
`--uninstall-hook`, `--check-hook` (the last exits 0/1), with an optional
`--settings-file` (default `<config-dir>/settings.json`).  They load the JSON,
back it up to `.bak`, merge in (or remove) our hook, prune empty containers, and
write it back with `json.dumps(indent=2)`.  Emacs only provides thin wrappers
(`tincan-install-hook`, `tincan-uninstall-hook`, `tincan-hook-installed-p`) that
`call-process` the script and surface its output/exit code.
Rationale - why Python owns the editing, not Emacs: the hook command string and
all paths already live in Python, and the script can self-reference its own
absolute path (`os.path.realpath(__file__)`), so what gets installed provably
matches what `--check-hook`/`--uninstall-hook` look for - no cross-language
duplication that could drift.  It also keeps one JSON implementation instead of
two (the elisp `alist`/vector round-trip is fiddly) and makes the hook
installable without Emacs.  The only cost is Emacs shelling out and reading an
exit code, which is trivial.
Caveats: it does NOT do tool selection - it only signals "Claude wants you",
which you still handle in the terminal.  The installed command is
`python3 <script>` (portable, no executable-bit dependency).  After install,
Claude Code must be restarted or `/hooks` run so it reviews and loads the change
(its hook-safety mechanism); the round-trip also reformats the settings file,
hence the backup.
