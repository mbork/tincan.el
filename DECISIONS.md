# Decisions

This file records non-obvious design decisions made while implementing tincan,
together with the reasoning behind them, so that any decision can be revisited
or reverted in isolation.  Each entry notes the commit theme it belongs to.

## Python transcript script

### D1 - Language and dependencies
Python 3, standard library only, no third-party dependencies.
Rationale: KISS MVP; the script only reads JSONL files and writes text.

### D2 - Script filename: `tincan.py`
Originally `tincan-tail.py`, renamed to `tincan.py` once it outgrew tailing:
it now also lists sessions, runs the Notification hook, and installs/removes/
checks it.  `tincan.py` is the single Python entry point, sitting alongside
`tincan.el`.  Note the installed hook command embeds this file's absolute path
(from `realpath(__file__)`), so a rename requires re-pointing any installed
hook (re-run `--install-hook`, or edit the settings file).

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

### D11 - `--show-sessions` (deepest-ancestor by default; `--all` for everything)
By default lists the sessions of the *closest* launch directory at or above the
working directory: among sessions whose `cwd' is an ancestor-or-equal of the cwd
(component-aware via `os.path.commonpath', so `M-x tincan' works from any
subproject directory), the ones with the deepest such `cwd'.  `--all' instead
lists every project's sessions.  Output is tab-separated
`id<TAB>timestamp<TAB>title<TAB>cwd', one per line, newest first.
The title is `customTitle' (a `/rename'), else `aiTitle', else the first user
prompt (collapsed/truncated), else the id (see D27).  Timestamps are the first
record's, in local time as ISO-8601 with offset.
Rationale: exact-cwd matching broke when run below the project root; ancestor
matching is symlink-safe for free because both `os.getcwd()' and the recorded
`cwd' are physical paths.  The `cwd' column lets the Emacs all-projects picker
narrow by directory.  Each file is fully scanned because `aiTitle'/`customTitle'
can appear late; acceptable for the expected handful of sessions.

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
keeps the marker contract with tincan.py explicit in one `defvar`.

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
`tincan.py --notification-hook`: it reads the event JSON on stdin and
writes the message to a small per-session file at
`<config-dir>/tincan/<session-id>.notify`.  A file, deliberately, not
`emacsclient`, so the producer stays a plain stdin-to-file script with no Emacs
coupling.
Installation lives in the Python script too: `--install-hook`,
`--uninstall-hook`, `--check-hook` (the last exits 0/1), with an optional
`--settings-file`.  The default target is `.claude/settings.local.json`
resolved against the working directory - Claude Code's personal, gitignored
project settings - so the hook fires only for the project you drive with tincan
and is never committed; install from where you start Claude Code, or pass
`--settings-file`.  They load the JSON,
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

### D21 - Read-only orchestration via a process filter
`M-x tincan' picks a session (from `tincan.py --show-sessions', parsed from
its tab-separated output via `completing-read') and watches it live: it runs
`tincan.py <id> --follow' as an async `make-process' whose filter feeds the
output into a rendered, read-only buffer.
Chosen over streaming to a temp file + `auto-revert-tail-mode' because the
filter is event-driven (no temp file, no second polling layer on top of the
follower's own poll) and the same function that inserts text is the natural
place to react to in-stream markers like `@@@ DONE'.  The cost is handling
chunked output ourselves: process output arrives in arbitrary chunks, and a line
(or even a searched string) can be split across calls.  The filter therefore
uses the marker idiom (see [[process-filter-idiom]]): insert each chunk at the
`process-mark', and act only on newline-terminated lines - the same discipline
tincan.py uses on the file side, mirrored with a marker instead of a byte
offset.
Session selection runs in `default-directory' (that is the cwd
`--show-sessions' filters by), so invoke `tincan' from the project root; the
follower itself resolves the session by id regardless of cwd.  The buffer reuses
a live watcher, follows the tail only in windows already at the end, and kills
the follower from `kill-buffer-hook'.
The agent state is shown in the mode line: `working'/`idle' is derived from the
stream (a `@@@ DONE' line means idle), and `needs-input' is driven by a
`file-notify' watch on the `.notify' *directory* (the file may not exist yet, so
we watch the directory and match the basename), cleared back to `working'/`idle'
when transcript activity resumes.  The watch is best-effort: if the optional hook
(D20) is not installed or watching is unsupported, only working/idle show.

### D22 - Foldable `@@@` sections, folded by default except USER/ASSISTANT
The viewer folds with `outline-minor-mode'.  `outline-regexp' matches both `@@@ '
section markers and Markdown `#' headings, and `tincan--outline-level' makes the
`@@@' sections level 1 with Markdown headings nested below - so TAB folds either
a section or a heading within it.  Markdown headings deliberately go through
`outline-cycle' (not Markdown's `markdown-cycle'): `markdown-cycle' navigates via
`outline-regexp'/`outline-level', which we have repurposed, so it would jump to
the wrong place and error (`markdown-end-of-subtree' on a nil position).  The
trade-off is that a `#'-prefixed line inside a code block also looks like a
heading, which is harmless (it just becomes foldable).
`outline-minor-mode-cycle' (Emacs 28.1+) binds TAB on a heading to
`outline-cycle' and S-TAB to `outline-cycle-buffer'.  This wins over the major
mode's TAB on headings because outline installs the binding on the heading via
an overlay keymap (higher precedence than the major-mode map); off a heading TAB
falls through to the mode (e.g. `markdown-cycle').  It works in GUI too:
`markdown-mode' binds TAB as `[9]' (not `<tab>'), so a GUI `<tab>' with no
binding is translated to `[9]' and lands on `outline-cycle' on a heading.
Every section whose role is not in
`tincan-unfolded-sections' (default `("USER" "ASSISTANT")') starts folded,
keeping thinking/tool calls/tool results/DONE out of the way.
Folding is overlay-based, so it works in the read-only buffer with no
`inhibit-read-only'.  `tincan--autofold' only folds sections it has not passed
(tracked by `tincan--fold-marker', the same idiom as the scan marker) and never
folds the still-arriving last section, so streaming folds new sections exactly
once and never re-folds one the user manually opened.
TAB cycles only on the section's heading line, not anywhere within the section -
that is `outline-minor-mode-cycle''s behavior (see D23 for the Emacs floor it
relies on).

### D23 - Emacs 30.1 floor
`Package-Requires' is `((emacs "30.1"))'.  The folding (D22) relies on
`outline-minor-mode-cycle' (Emacs 28.1+); nothing else in the file needs to run
on older Emacs.
Rationale: a personal tool run on current Emacs - no reason to carry a lower
floor, and the folding is simpler for leaning on the built-in cycle keys.

### D27 - Session title: prefer the renamed title; use it in the buffer name
`read_session_meta' prefers `customTitle' (written by `/rename') over `aiTitle'
(auto-generated), then the first user prompt, then the session id.  Each kind is
optional and every combination occurs in practice (some sessions have neither
title; one can have a custom title but no AI title), so it is a graceful
fallback chain.  The Emacs viewer names its buffer `*tincan: <title>*' with the
title abbreviated to `tincan-buffer-title-width' columns (default 16; short id
when there is no title).
Because the title can change mid-session (a later `/rename'), buffer reuse is
keyed on the session id held buffer-locally, not on the buffer name - so
re-watching a renamed session reuses its buffer instead of spawning a duplicate
(`generate-new-buffer' names only genuinely new ones).

### D28 - `M-x tincan' session picking: deepest-ancestor, `C-u' for all
`M-x tincan' lists this project's sessions (D11's deepest-ancestor match), so it
works from any subdirectory.  With a prefix argument (`C-u') it offers *every*
project's session instead - the escape hatch for "I am not in the project" or
"I want another project's session".
For the all-projects picker the candidate string is \"TITLE  DIR\" (abbreviated
directory), because completion backends match input against the candidate
*string*: putting both title and directory there lets you narrow by either in
vanilla `completing-read', Vertico, Ivy or Helm alike (annotations are display
only and are not matched).  How flexibly a mid-string field narrows depends on
`completion-styles' (Ivy/Helm and orderless do it out of the box; vanilla wants
`flex'/`substring'), which is the user's config, not tincan's concern.
Chosen over detecting a project "root" (vc/project.el/dominating file) because
those are heuristics that can disagree with the directory Claude actually
launched in, whereas the ancestor match reads the real recorded `cwd'.

These decisions record the chosen shape of sending textual replies back to
Claude Code (the input mode).  D24-D30 are the early design; D31-D38 are the
final, implemented design, which revises several of them now that the `claude'
CLI's `--session-id'/`--resume' flags let tincan own the session id.

### D24 - No tmux: run Claude in an Emacs terminal buffer
Claude is launched directly in an Emacs terminal-emulator buffer (see D26), not
inside tmux.  Replies are sent to that buffer's process, which is the send
target, so there is no session naming or pane discovery.
Rationale: simplicity over persistence, per the project's guiding principle.
The cost, accepted deliberately: no persistence/detach (killing the buffer or
Emacs ends the Claude session and loses an in-flight run) and no external-
terminal escape hatch for the TUI.  A kill confirmation is the only safeguard.

### D25 - Split "start Claude" from "attach a view" (REVISED by D31/D32)
Original rationale: a freshly started Claude session's transcript id is not known
until Claude writes the file, so auto-attaching at start is racy; making attach a
manual pick sidesteps the race and doubles as the escape hatch.
This is superseded: because tincan now owns the id (`--session-id' for new,
`--resume' for resume; D31) and the follower waits for the not-yet-written file
(`--wait'; D32), `tincan-start' auto-attaches in both directions with no race.
Manual `tincan-attach' survives only as an escape hatch / recovery, and it too is
deterministic - run from a terminal buffer, it (re)builds the view for *that
terminal's* stored id, so there is no session picking and no possible mislink.

### D26 - vterm when available, term as fallback
The terminal buffer uses `vterm' if it is available, else the built-in `term'.
Rationale: vterm renders Claude's full-screen TUI well; it is an optional,
feature-detected dependency (like markdown-mode), not a hard requirement, so the
no-new-dependencies rule holds.  `term' is the always-present fallback, with the
caveat that it renders a complex TUI less well and - with tmux dropped (D24) -
has no external-attach escape hatch.

### D29 - Input-mode design choices (early draft; see D31-D38 for the final form)
Most of these were superseded once tincan took ownership of the session id:
- Start vs attach (now D25/D31): `tincan-start' auto-attaches; manual attach is
  only an escape hatch.
- Reply safety (now D35): show the terminal on send *without stealing focus*,
  with a one-shot next-command dismissal, instead of "raise then bury".
- Keybindings (now D37): no global prefix; per-buffer maps with `C-c SPC' reply.
- Backend (still): the `vterm' path is implemented; `term' (D26) is deferred.
- No single "current session" (kept, now D33): no global `tincan--current-view';
  `tincan-reply' resolves its target from the current buffer.  Final mechanism in
  D33 - two origins (view, terminal), not three, since compose has its own send.

### D30 - Distinguishing the transcript view from the terminal
The view (rendered, read-only) and the vterm terminal show the same conversation
and are easy to confuse, especially in scrollback where the `@@@' markers scroll
out of sight.  Each buffer therefore carries an always-visible header line
identifying it (view: read-only transcript; terminal: type here).  A header line
is the strongest cue because it does not scroll (unlike the markers) and is more
prominent than the mode line; it is reinforced by distinct buffer-name prefixes
and the view's read-only-ness.  An optional `buffer-face-mode' background tint
(off by default) is scaffolded as an extra ambient cue - off because tints fight
themes and vterm's own colors.  Exact header-line contents are settled within the
implementing commit.

### D31 - tincan owns the session id (`--session-id` / `--resume`)
For a new session `tincan-start' generates a fresh UUID and launches
`claude --session-id <uuid>'; to resume, `C-u tincan-start' picks an existing
session and launches `claude --resume <id>'.  Either way tincan knows the id
before Claude finishes writing anything, which (a) removes the terminal<->session
pairing ambiguity entirely (the terminal buffer stores its own id), (b) lets the
view follow by id immediately, and (c) makes resume a single step.  The JSONL
filename equals the session id (verified against a real transcript), so
`--session-id <uuid>' yields `<uuid>.jsonl', which the follower finds by id.
The UUID comes from `tincan.py --new-session-id' (Python's `uuid4'), keeping id
generation in the component that already owns session/file concerns and avoiding
a dependency on a system `uuidgen'.
Rationale: without this, a vterm is an opaque pty - tincan cannot tell which
session a running `claude' uses (the id only surfaces as the file name), so any
attach would pair view and terminal by unverified user assertion, risking
"read one conversation, type into another".  Owning the id makes the pairing
correct by construction.

### D32 - Follower waits for a not-yet-written transcript (`--wait`)
A brand-new session has no `.jsonl' until Claude processes its first turn, so
following by id must tolerate an absent file.  `tincan.py --follow --wait' polls
for the file to appear (the same 0.25 s interval as follow mode) instead of
erroring, then follows normally.  `--wait' is opt-in: the standalone CLI still
errors fast on a typo'd id, while the Emacs follower always passes `--wait'
because it always has a genuine id.  This relocates the new-session race into one
polling loop in the follower rather than deferring attach (revises D25).

### D33 - Session-group linking via buffer-locals; reply resolves from buffer
There is deliberately no global "current session" - concurrent sessions are
supported - so each buffer in a group carries buffer-locals instead of a global
pointer.  The view holds `tincan--session-id', the follower `tincan--process',
`tincan--state', and `tincan--terminal' (its terminal buffer).  The terminal
holds `tincan--terminal-p', `tincan--session-id', and `tincan--view' (its view
buffer).  The compose buffer captures `tincan--terminal' and `tincan--view' when
spawned.  `tincan-reply' resolves its target from the current buffer: from the
view -> (view, view's terminal); from the terminal -> (terminal's view,
terminal).  Compose has its own send command, so the resolver handles two
origins, not three (this finalizes D29's und. mechanism).

### D34 - Reply gate and compose buffer
`tincan-reply' (run from the view or the terminal) gates on the view's state:
`needs-input' -> do not compose; surface the terminal so you answer the prompt
there (a pasted reply would be wrong during a permission prompt).  `working' ->
confirm "send anyway?" (Claude queues mid-turn input, so this is a soft guard).
`idle'/unknown -> open a compose buffer.  The compose buffer uses a Markdown
major mode when available (markdown-ts-mode/gfm-mode/markdown-mode, else
text-mode; the same runtime-dispatch reasoning as D16) plus a
`tincan-compose-minor-mode' binding `C-c C-c' (send) and `C-c C-k' (cancel).
Send pastes the text into the terminal with `vterm-send-string' (bracketed paste)
then `vterm-send-return', and clears/buries the compose buffer.

### D35 - After sending, show the terminal without stealing focus
On send the terminal is shown for a misfire check, but focus stays on the view
(where Claude's reply streams, and where the sent USER message will also appear).
`tincan-show-terminal-on-send' selects how: `display' (default - show in a
window, do not select), `select' (raise and select), or `none'.  With `display',
and gated by `tincan-dismiss-terminal-on-next-command' (default t), a one-shot
`pre-command-hook' makes your next command in the view delete that popped
terminal window (the command still runs) - a momentary peek that clears the
instant you move on, with no timer.  `tincan-delete-terminal-window' (`C-c 0')
dismisses the terminal window on demand at any other time.
Rationale: a timed auto-bury steals focus unpredictably and bakes in a magic
number; decoupling "visible" from "selected" achieves "glance, then keep reading"
without either problem.

### D36 - Distinct names and header lines for the three buffers (extends D30)
The buffers are named distinctly: view `*tincan view: TITLE*', terminal
`*tincan terminal: DIR*' (no title exists at start, so the abbreviated directory
is the stable identity), compose `*tincan compose: TITLE*'.  Each carries an
identifying header line (view: read-only transcript; terminal: type here;
compose: send/cancel keys).  Agent state (`[working]'/`[idle]'/`[needs input]')
is shown in both the view's header line and its mode line via one shared
formatter so the two cannot drift.  The new-session terminal's header line also
carries a transient hint (give the session a title; the already-open view follows
in the background; kill + restart as an escape hatch) until the first turn lands.

### D37 - Keybindings: no global binding, per-buffer maps
Entry commands (`tincan-view', `tincan-start', `tincan-attach') are M-x only;
tincan binds no global keys (bind them yourself if wanted).  In-session keys live
in buffer-local maps.  View and terminal share `C-c SPC' (reply), `C-c o' (go to
the sibling buffer), and `C-c k' (close the session).  The view adds `C-c 0'
(dismiss the terminal window) and `q' (bury).  The terminal is a
`tincan-terminal-mode' minor mode layered over vterm (its lighter doubles as an
identity cue); it adds `C-c C-c' -> send a real interrupt to Claude, restored
because binding `C-c ...' keys makes `C-c' an Emacs prefix in the buffer.  The
compose buffer uses `C-c C-c' (send) and `C-c C-k' (cancel).
Rationale: `C-c <letter>'/`C-c SPC' are the user keyspace, so they never clash
with markdown-mode; `C-c C-c'/`C-c C-k' is the familiar org-capture/magit idiom.

### D38 - markdown-ts-mode preferred when available (extends D16)
Auto-detection prefers `markdown-ts-mode' (Emacs 31, and only when the
tree-sitter `markdown' grammar is actually ready - `fboundp' alone is not enough)
over `gfm-mode' over plain `markdown-mode'.  `gfm-mode' beats `markdown-mode'
because Claude emits GitHub Flavored Markdown (fenced code with info strings,
tables, strikethrough, task lists, and intraword underscores left literal so
snake_case is not italicized).  The same detection feeds the view and the compose
buffer; the view falls back to `tincan-view-mode', compose to `text-mode'.  A
*view* mode (markup-hiding) is deliberately never the default, even on 31: a
code-heavy transcript wants the literal characters (D16).

### D39 - Render content-bearing tool uses as code, not JSON (extends D7/D18)
A `Write' tool_use is rendered as the file *content* in a fenced code block, with
the language inferred from the file extension and the file path appended to the
`@@@ TOOL_USE' marker line; an unknown extension yields a language-less fence.
This is driven by a `CONTENT_TOOLS' map (tool name -> path field, content field)
plus an `EXT_TO_LANG' map, so adding other single-content tools is a one-line
change.  All other tools keep the pretty-printed JSON rendering of D7/D18.
Rationale: a `Write''s input is dominated by the file body, which as JSON is
escaped, single-line-per-field and unreadable, and cannot be fontified by
language.  As a fenced code block it reads naturally and gets native per-language
fontification (D17) on the Emacs side, while the path on the marker line keeps
the font-lock/outline/state regexes intact (they match the marker prefix and
ignore trailing text).  The fence length still follows the CommonMark rule (D18),
so file content containing backticks widens the fence.
Not handled: `Edit'/`MultiEdit' carry two payloads (old/new string), so they do
not fit the single-content map and still render as JSON; a two-block renderer
could be added later.
