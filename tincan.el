;;; tincan.el --- Drive Claude Code from Emacs -*- lexical-binding: t; -*-

;; Author: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Maintainer: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes
;; URL: https://github.com/mbork/tincan.el

;;; Commentary:

;; tincan is a hackish take on agentic coding in Emacs.  Claude Code runs in a
;; vterm terminal buffer; tincan.py renders that session's transcript as plain,
;; font-lockable text which a read-only "view" buffer follows live.  You read in
;; the view and send replies (composed in a dedicated buffer) to the terminal.
;;
;; Entry points: `tincan-start' (run/resume Claude and attach a view),
;; `tincan-view' (watch a session read-only), `tincan-reply' (compose a reply).
;; `tincan-render-buffer' sets up a buffer for viewing: it renders the
;; conversation with a Markdown mode when one is available (see
;; `tincan-markdown-mode'), otherwise it falls back to `tincan-view-mode'.
;; Either way the "@@@ ROLE" section markers are font-locked and the buffer is
;; made read-only.  See DECISIONS.md for the design rationale.

;;; Code:

;; * Customization group
(defgroup tincan nil
  "Drive Claude Code from Emacs."
  :group 'tools
  :prefix "tincan-")

;; * The tincan.py script
(defconst tincan--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing tincan.el, used to locate tincan.py.")

(defcustom tincan-script
  (expand-file-name "tincan.py" tincan--directory)
  "Path to tincan.py, the helper that prints, follows and manages sessions."
  :type 'file
  :group 'tincan)

;; * Faces
(defface tincan-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the \"@@@ USER\" marker line."
  :group 'tincan)

(defface tincan-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the \"@@@ ASSISTANT\" marker line."
  :group 'tincan)

(defface tincan-thinking
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for the \"@@@ THINKING\" marker line."
  :group 'tincan)

(defface tincan-tool-use
  '((t :inherit font-lock-builtin-face))
  "Face for the \"@@@ TOOL_USE\" marker line."
  :group 'tincan)

(defface tincan-tool-result
  '((t :inherit font-lock-string-face))
  "Face for the \"@@@ TOOL_RESULT\" marker line."
  :group 'tincan)

(defface tincan-done
  '((t :inherit success :weight bold))
  "Face for the \"@@@ DONE\" marker line that ends a turn."
  :group 'tincan)

;; * Font lock
;; The markers below must stay in sync with tincan.py's ROLE_* constants.
(defvar tincan-font-lock-keywords
  '(("^@@@ USER.*$" 0 'tincan-user t)
    ("^@@@ ASSISTANT.*$" 0 'tincan-assistant t)
    ("^@@@ THINKING.*$" 0 'tincan-thinking t)
    ("^@@@ TOOL_USE.*$" 0 'tincan-tool-use t)
    ("^@@@ TOOL_RESULT.*$" 0 'tincan-tool-result t)
    ("^@@@ DONE.*$" 0 'tincan-done t))
  "Font-lock keywords highlighting the \"@@@ ROLE\" section markers.
Used directly by `tincan-view-mode' and added on top of Markdown
fontification by `tincan-render-buffer'.  The trailing OVERRIDE flag makes the
marker faces win even when a Markdown mode has already fontified the line.")

;; * View mode
;;;###autoload
(define-derived-mode tincan-view-mode special-mode "Tincan"
  "Plain-text fallback mode for viewing a tincan transcript.

Used by `tincan-render-buffer' when no Markdown mode is available.  The buffer
is read-only; new content is expected to arrive via `auto-revert-tail-mode'.
Section markers of the form \"@@@ ROLE\" are font-locked according to the
`tincan-user', `tincan-assistant', `tincan-thinking', `tincan-tool-use',
`tincan-tool-result' and `tincan-done' faces."
  (setq-local font-lock-defaults '(tincan-font-lock-keywords t)))

;; * Folding
;; The @@@ sections are foldable with `outline-minor-mode'.  With
;; `outline-minor-mode-cycle', TAB on a section's @@@ heading cycles its
;; visibility and S-TAB cycles the whole buffer.  Every section except those in
;; `tincan-unfolded-sections' starts folded, so thinking, tool calls/results and
;; DONE markers stay out of the way until opened.  Folding uses overlays, so it
;; works in the read-only buffer; auto-folding is marker-driven so manual
;; unfolds are preserved.
(require 'outline)

(defcustom tincan-unfolded-sections '("USER" "ASSISTANT")
  "Roles of \"@@@ ROLE\" sections shown expanded by default.
Every other section (THINKING, TOOL_USE, TOOL_RESULT, DONE, ...) starts folded."
  :type '(repeat string)
  :group 'tincan)

(defvar-local tincan--fold-marker nil
  "Marker up to which streamed @@@ sections have been auto-folded.")

(defun tincan--default-folded-p (role)
  "Non-nil if a section with ROLE should start folded."
  (not (member role tincan-unfolded-sections)))

(defun tincan--autofold ()
  "Fold complete, default-folded @@@ sections from `tincan--fold-marker'.
A section is complete once another @@@ heading follows it; the last (still
arriving) section is left open until its successor shows up.  Sections already
passed are not revisited, so manual unfolding is preserved."
  (when tincan--fold-marker
    (save-excursion
      (goto-char tincan--fold-marker)
      (catch 'incomplete
        (while (re-search-forward "^@@@ \\([A-Z_]+\\)" nil t)
          (let ((role (match-string 1))
                (heading (match-beginning 0)))
            (unless (save-excursion (re-search-forward "^@@@ " nil t))
              (set-marker tincan--fold-marker heading)
              (throw 'incomplete nil))
            (when (tincan--default-folded-p role)
              (save-excursion (goto-char heading) (outline-hide-subtree)))
            (set-marker tincan--fold-marker (line-end-position))))))))

(defun tincan--outline-level ()
  "Outline level: @@@ sections are level 1; Markdown headings nest below them."
  (if (looking-at-p "@@@ ")
      1
    (1+ (save-excursion
          (beginning-of-line)
          (skip-chars-forward "#")))))

(defun tincan--setup-folding ()
  "Enable folding in the current buffer and apply the default fold.
Both @@@ section markers and Markdown headings are outline headings, so TAB
cycles either; @@@ sections are top level and Markdown headings nest within.
Markdown headings go through `outline-cycle' here rather than `markdown-cycle',
which would misnavigate because `outline-regexp' is not Markdown's."
  (setq-local outline-regexp "\\(?:@@@\\|#+\\) ")
  (setq-local outline-level #'tincan--outline-level)
  (setq-local outline-minor-mode-highlight nil)
  (setq-local outline-minor-mode-cycle t)
  (outline-minor-mode 1)
  (setq-local tincan--fold-marker (copy-marker (point-min)))
  (tincan--autofold))

;; * Rendering
(defcustom tincan-markdown-mode t
  "How to render a tincan transcript with Markdown.
If t, auto-detect and use `gfm-mode' or `markdown-mode' when available.
If nil, never use Markdown (always fall back to `tincan-view-mode').
If a function symbol, call it as the major mode when it is `fboundp'
\(for example `markdown-view-mode' or `gfm-view-mode')."
  :type '(choice (const :tag "Auto-detect gfm-mode/markdown-mode" t)
                 (const :tag "Disabled (plain fallback)" nil)
                 (function :tag "Specific Markdown mode"))
  :group 'tincan)

(defcustom tincan-fontify-code-blocks-natively t
  "If non-nil, fontify fenced code blocks with each language's major mode.
Only has an effect when a Markdown mode is used (see `tincan-markdown-mode'):
it sets `markdown-fontify-code-blocks-natively' buffer-locally.  Turning this
off avoids loading language major modes, which can matter for a large,
continuously tailed transcript."
  :type 'boolean
  :group 'tincan)

;; Declared by markdown-mode; forward declaration keeps the byte-compiler quiet.
(defvar markdown-fontify-code-blocks-natively)

(defun tincan--markdown-ts-ready-p ()
  "Non-nil if `markdown-ts-mode' is usable (Emacs 31, with the grammar).
`fboundp' alone is not enough: the tree-sitter `markdown' grammar can be
missing, which would make the mode error out."
  (and (fboundp 'markdown-ts-mode)
       (fboundp 'treesit-ready-p)
       (treesit-ready-p 'markdown t)))

(defun tincan--markdown-mode-symbol ()
  "Return the Markdown major-mode symbol to use, or nil.
Honors `tincan-markdown-mode' and only returns a mode that is usable.  When
auto-detecting, prefer `markdown-ts-mode' (Emacs 31), then `gfm-mode' (Claude
emits GitHub Flavored Markdown), then plain `markdown-mode' (see D38)."
  (cond ((null tincan-markdown-mode)
         nil)
        ((eq tincan-markdown-mode t)
         (cond ((tincan--markdown-ts-ready-p) 'markdown-ts-mode)
               ((fboundp 'gfm-mode) 'gfm-mode)
               ((fboundp 'markdown-mode) 'markdown-mode)
               (t nil)))
        ((and (symbolp tincan-markdown-mode) (fboundp tincan-markdown-mode))
         tincan-markdown-mode)
        (t nil)))

;;;###autoload
(defun tincan-render-buffer ()
  "Set up the current buffer to display a tincan transcript.
Render the conversation with a Markdown mode when one is available (see
`tincan-markdown-mode'), otherwise fall back to `tincan-view-mode'.  In both
cases the \"@@@ ROLE\" markers are font-locked and the buffer is read-only."
  (interactive)
  (let ((markdown-mode-symbol (tincan--markdown-mode-symbol)))
    (if markdown-mode-symbol
        (progn
          (funcall markdown-mode-symbol)
          (setq-local markdown-fontify-code-blocks-natively
                      tincan-fontify-code-blocks-natively)
          (font-lock-add-keywords nil tincan-font-lock-keywords 'append)
          (setq buffer-read-only t)
          (font-lock-flush))
      (tincan-view-mode)))
  ;; Soft-wrap long prose and tool output at word boundaries.
  (visual-line-mode 1)
  (tincan--setup-folding))

;; * Notification hook
;; Optional integration: a Claude Code "Notification" hook runs tincan.py,
;; which writes a small per-session file when Claude is waiting for input (e.g.
;; a tool-permission prompt).  All settings.json editing is done by the Python
;; script, so the installed command and its paths have a single source of truth;
;; the commands below are thin wrappers around it.  Installing is opt-in and only
;; signals "Claude wants you" - it does not handle tool selection.

(defcustom tincan-hook-settings-file nil
  "Settings file the Notification hook is installed into.
When nil, tincan.py uses its own default,
\".claude/settings.local.json\" relative to the working directory."
  :type '(choice (const :tag "Script default" nil) file)
  :group 'tincan)

(defun tincan--run-hook-script (subcommand)
  "Run tincan.py with SUBCOMMAND, echo its output, return its exit code."
  (let ((args (if tincan-hook-settings-file
                  (list subcommand "--settings-file" tincan-hook-settings-file)
                (list subcommand))))
    (with-temp-buffer
      (let* ((code (apply #'call-process "python3" nil t nil
                          tincan-script args))
             (output (string-trim (buffer-string))))
        (unless (string-empty-p output)
          (message "%s" output))
        code))))

;;;###autoload
(defun tincan-install-hook ()
  "Install tincan's Notification hook (via tincan.py).
Installing is optional; tincan works without it.  The script backs up the
settings file first.  Afterwards, restart Claude Code or run /hooks so the
change is reviewed and loaded."
  (interactive)
  (tincan--run-hook-script "--install-hook"))

;;;###autoload
(defun tincan-uninstall-hook ()
  "Remove tincan's Notification hook (via tincan.py)."
  (interactive)
  (tincan--run-hook-script "--uninstall-hook"))

;;;###autoload
(defun tincan-hook-installed-p ()
  "Return non-nil if tincan's Notification hook is installed.
Interactively, report the result in the echo area."
  (interactive)
  (= 0 (tincan--run-hook-script "--check-hook")))

;; * Session orchestration
;; `tincan' picks one of this project's sessions and watches it live: it runs
;; tincan.py --follow as an async process and feeds the output into a
;; rendered, read-only buffer through a process filter.  Output may arrive in
;; arbitrary chunks (even mid-line), so the filter follows the marker idiom -
;; insert at the process mark, and process only newline-terminated lines.
(require 'filenotify)

(defvar-local tincan--process nil
  "The tincan.py --follow process feeding the current buffer.")

(defvar-local tincan--session-id nil
  "The Claude Code session id shown in the current buffer.")

;; Session-group links (D33).  No global \"current session\": each buffer points
;; at its siblings so `tincan-reply' can resolve its target from the current
;; buffer alone, and several sessions can run at once.
(defvar-local tincan--terminal nil
  "For a view (or compose) buffer, the terminal buffer of the same session.")

(defvar-local tincan--view nil
  "For a terminal (or compose) buffer, the view buffer of the same session.")

(defvar-local tincan--terminal-p nil
  "Non-nil in a tincan terminal buffer (running Claude under vterm).")

(defun tincan--short-id (session-id)
  "Return a short, buffer-name-friendly form of SESSION-ID."
  (substring session-id 0 (min 8 (length session-id))))

(defcustom tincan-buffer-title-width 16
  "Columns the session title is abbreviated to in the viewer buffer name."
  :type 'integer
  :group 'tincan)

(defun tincan--buffer-name (session-id title)
  "Return the view buffer name for SESSION-ID, using TITLE when non-empty.
TITLE is abbreviated to `tincan-buffer-title-width' columns; with no usable
TITLE the short id is used."
  (let* ((trimmed (and (stringp title) (string-trim title)))
         (label (if (and trimmed (not (string-empty-p trimmed)))
                    (truncate-string-to-width trimmed tincan-buffer-title-width)
                  (tincan--short-id session-id))))
    (format "*tincan view: %s*" label)))

;; ** Session selection
(defun tincan--list-sessions (&optional all)
  "Return an alist of (DISPLAY . PLIST) for sessions; PLIST has :id :title :cwd.
Without ALL, list the sessions of the closest launch directory at or above
`default-directory' (DISPLAY is \"TIMESTAMP  TITLE\").  With ALL, list every
project's sessions and put the directory in DISPLAY (\"TITLE  DIR\") so it
narrows by title or directory.  Runs tincan.py in `default-directory'."
  (with-temp-buffer
    (let* ((args (append '("--show-sessions") (and all '("--all"))))
           (code (apply #'call-process "python3" nil t nil tincan-script args)))
      (unless (= code 0)
        (error "tincan: --show-sessions failed: %s" (string-trim (buffer-string))))
      (let ((sessions '()))
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((line (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
                 (fields (split-string line "\t")))
            (when (>= (length fields) 3)
              (let ((id (nth 0 fields))
                    (timestamp (nth 1 fields))
                    (title (nth 2 fields))
                    (cwd (nth 3 fields)))
                (push (cons (if (and all cwd (not (string-empty-p cwd)))
                                (format "%s  %s" title (abbreviate-file-name cwd))
                              (format "%s  %s" timestamp title))
                            (list :id id :title title :cwd cwd))
                      sessions))))
          (forward-line 1))
        (nreverse sessions)))))

(defun tincan--read-session (&optional all)
  "Prompt for a session; return its PLIST (:id :title :cwd).
With ALL, choose among every project's sessions instead of this project's."
  (let ((sessions (tincan--list-sessions all)))
    (unless sessions
      (if all
          (user-error "tincan: no sessions found")
        (user-error "tincan: no sessions under %s (use C-u for all projects)"
                    default-directory)))
    (cdr (assoc (completing-read "tincan session: " sessions nil t) sessions))))

;; ** State and mode line
;; The agent's state is derived from the transcript stream: a `@@@ DONE' line
;; means the turn finished (idle); any other content means it is working.
;; `tincan--scan-marker' tracks how far we have scanned, so chunked/partial
;; lines are handled the same way the follower handles partial writes.
(defvar-local tincan--state nil
  "Current agent state for the buffer: nil, `working', `idle' or `needs-input'.")

(defvar-local tincan--scan-marker nil
  "Marker up to which output has been scanned for state markers.")

(defface tincan-state-working '((t :inherit warning))
  "Mode-line face shown while the agent is working."
  :group 'tincan)

(defface tincan-state-idle '((t :inherit success))
  "Mode-line face shown when the agent is idle (the turn finished)."
  :group 'tincan)

(defface tincan-state-needs-input '((t :inherit error :weight bold))
  "Mode-line face shown when Claude is waiting for your input."
  :group 'tincan)

(defun tincan--state-string (state)
  "Return the indicator string for STATE, shared by the mode line and header."
  (pcase state
    ('working (propertize " [working]" 'face 'tincan-state-working))
    ('idle (propertize " [idle]" 'face 'tincan-state-idle))
    ('needs-input (propertize " [needs input]" 'face 'tincan-state-needs-input))
    (_ "")))

(defun tincan--set-state (state)
  "Set the buffer's tincan STATE and reflect it in the mode line and header.
The header line uses the same `tincan--state-string' via its :eval, so
refreshing the mode line refreshes both."
  (unless (eq tincan--state state)
    (setq tincan--state state)
    (setq-local mode-line-process (tincan--state-string state))
    (force-mode-line-update)))

(defun tincan--update-state-from-line (line)
  "Update the agent state from a completed transcript LINE."
  (cond ((string-prefix-p "@@@ DONE" line)
         (tincan--set-state 'idle))
        ((not (string-empty-p line))
         (tincan--set-state 'working))))

(defun tincan--scan-for-state (limit)
  "Scan complete lines from `tincan--scan-marker' up to LIMIT, updating state.
Only newline-terminated lines are scanned; the marker is left at the start of
any incomplete trailing line so a later chunk completes it."
  (save-excursion
    (goto-char tincan--scan-marker)
    (while (and (< (point) limit)
                (save-excursion (search-forward "\n" limit t)))
      (tincan--update-state-from-line
       (buffer-substring-no-properties (point) (line-end-position)))
      (forward-line 1))
    (set-marker tincan--scan-marker (point))))

;; ** Notification watch
;; The hook writes <config-dir>/tincan/<session-id>.notify when Claude wants
;; input (D20).  We watch the directory (the file may not exist yet) and flag
;; `needs-input' on a write; resumed transcript activity clears it back to
;; `working' or `idle'.
(defvar-local tincan--notify-watch nil
  "File-notify descriptor for this buffer's .notify status file, or nil.")

(defun tincan--config-dir ()
  "Return Claude Code's config directory (honoring CLAUDE_CONFIG_DIR)."
  (expand-file-name (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))

(defun tincan--notify-file (session-id)
  "Return the notify status file the hook writes for SESSION-ID.
Mirrors tincan.py's notify_status_path."
  (expand-file-name (concat session-id ".notify")
                    (expand-file-name "tincan" (tincan--config-dir))))

(defun tincan--setup-notify-watch (session-id)
  "Watch SESSION-ID's notify file and flag `needs-input' on change.
Return the watch descriptor, or nil.  Failures are non-fatal: the indicator
just will not appear if the optional hook is absent or watching is unsupported."
  (let* ((file (tincan--notify-file session-id))
         (directory (file-name-directory file))
         (basename (file-name-nondirectory file))
         (buffer (current-buffer)))
    (condition-case nil
        (progn
          (unless (file-directory-p directory)
            (make-directory directory t))
          (file-notify-add-watch
           directory '(change)
           (lambda (event)
             (when (and (memq (nth 1 event) '(created changed renamed))
                        (equal (file-name-nondirectory (nth 2 event)) basename)
                        (buffer-live-p buffer))
               (with-current-buffer buffer
                 (tincan--set-state 'needs-input))))))
      (error nil))))

;; ** Buffer identity: header lines and faces
;; The view and the terminal show the same conversation and are easy to confuse
;; (D30/D36), so each gets an always-visible header line.  A header line beats
;; the mode line and the @@@ markers because it never scrolls away.
(defface tincan-header-view '((t :inherit mode-line-emphasis))
  "Face for the leading label of the tincan view header line."
  :group 'tincan)

(defface tincan-header-terminal '((t :inherit (warning mode-line-emphasis)))
  "Face for the leading label of the tincan terminal header line."
  :group 'tincan)

(defface tincan-header-compose '((t :inherit (success mode-line-emphasis)))
  "Face for the leading label of the tincan compose header line."
  :group 'tincan)

(defface tincan-header-dim '((t :inherit shadow))
  "Face for the descriptive part of a tincan header line."
  :group 'tincan)

(defun tincan--view-header ()
  "Header-line content for a tincan view buffer (identity plus agent state)."
  (concat (propertize " tincan view " 'face 'tincan-header-view)
          (propertize " read-only transcript" 'face 'tincan-header-dim)
          (tincan--state-string tincan--state)))

(defvar tincan-view-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c SPC") #'tincan-reply)
    (define-key map (kbd "C-c o") #'tincan-switch-terminal)
    (define-key map (kbd "C-c k") #'tincan-close)
    (define-key map (kbd "C-c 0") #'tincan-delete-terminal-window)
    (define-key map (kbd "q") #'quit-window)
    ;; Read-only buffer, so single keys are free for viewer-style navigation
    ;; (special-mode/Info conventions).  TAB/S-TAB folding is handled by
    ;; outline-minor-mode-cycle's heading overlay keymap, so it is not set here.
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "<") #'beginning-of-buffer)
    (define-key map (kbd ">") #'end-of-buffer)
    (define-key map (kbd "M-n") #'outline-next-visible-heading)
    (define-key map (kbd "M-p") #'outline-previous-visible-heading)
    ;; Reader-style actions and turn-only navigation.
    (define-key map (kbd "r") #'tincan-reply)
    (define-key map (kbd "t") #'tincan-switch-terminal)
    (define-key map (kbd "w") #'tincan-copy-section)
    (define-key map (kbd "RET") #'find-file-at-point)
    (define-key map (kbd "?") #'describe-mode)
    (define-key map (kbd "M-}") #'tincan-next-turn)
    (define-key map (kbd "M-{") #'tincan-previous-turn)
    map)
  "Keys layered onto a live tincan view buffer (see D37).
Composed over the major mode's map so reply/switch/close/dismiss work while the
Markdown view keeps its own bindings.")

(defvar tincan--turn-regexp "^@@@ \\(?:USER\\|ASSISTANT\\)\\b"
  "Marker lines that begin an actual conversation turn (USER/ASSISTANT).")

(defun tincan-next-turn (&optional n)
  "Move to the Nth next USER/ASSISTANT marker, skipping tool/thinking sections.
Interactively N is the prefix argument; a negative N moves backward."
  (interactive "p")
  (let* ((n (or n 1))
         (back (< n 0))
         (search (if back #'re-search-backward #'re-search-forward)))
    (dotimes (_ (abs n))
      (let ((origin (point)))
        (if back (beginning-of-line) (end-of-line))
        (if (funcall search tincan--turn-regexp nil t)
            (goto-char (match-beginning 0))
          (goto-char origin)
          (message "tincan: no %s turn" (if back "earlier" "later")))))))

(defun tincan-previous-turn (&optional n)
  "Move to the Nth previous USER/ASSISTANT marker (see `tincan-next-turn')."
  (interactive "p")
  (tincan-next-turn (- (or n 1))))

(defun tincan--code-block-at-point ()
  "If point is inside a fenced code block, return (BEG . END) of its content.
The content excludes the fence lines.  Parses the literal ``` / ~~~ fences in
the buffer text (markup is always visible), pairing each opening fence with a
closing one of the same character and at least its length (the CommonMark rule),
so it is major-mode-independent and tolerates code containing shorter fences."
  (let ((pos (point))
        (open-re "^[ ]\\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)")
        result)
    (save-excursion
      (goto-char (point-min))
      (catch 'done
        (while (re-search-forward open-re nil t)
          (let* ((fence (match-string 1))
                 (close-re (format "^[ ]\\{0,3\\}%c\\{%d,\\}[ \t]*$"
                                   (aref fence 0) (length fence)))
                 (content-beg (progn (forward-line 1) (point))))
            (if (re-search-forward close-re nil t)
                (let ((content-end (line-beginning-position)))
                  (when (and (>= pos content-beg) (< pos content-end))
                    (setq result (cons content-beg content-end))
                    (throw 'done nil)))
              ;; Unterminated fence: content runs to end of buffer.
              (when (>= pos content-beg)
                (setq result (cons content-beg (point-max))))
              (throw 'done nil))))))
    result))

(defun tincan-copy-section ()
  "Copy code or section text at point to the kill ring.
Inside a fenced code block, copy just the code (without the fences); otherwise
copy the body of the @@@ section at point (without the marker line)."
  (interactive)
  (let ((block (tincan--code-block-at-point))
        start end what)
    (if block
        (setq start (car block) end (cdr block) what "code block")
      (save-excursion
        (end-of-line)
        (setq start (if (re-search-backward "^@@@ " nil t)
                        (line-beginning-position 2)
                      (point-min)))
        (goto-char start)
        (setq end (if (re-search-forward "^@@@ " nil t)
                      (match-beginning 0)
                    (point-max))))
      (setq what "section"))
    (let ((body (string-trim (buffer-substring-no-properties start end))))
      (if (string-empty-p body)
          (message "tincan: empty %s" what)
        (kill-new body)
        (message "tincan: copied %s (%d chars)" what (length body))))))

;; ** Watching a session
(defun tincan--filter (proc chunk)
  "Insert CHUNK from PROC at its process mark; follow the tail and track state."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((mark (process-mark proc))
               (old (marker-position mark))
               (inhibit-read-only t))
          (save-excursion
            (goto-char mark)
            (insert chunk)
            (set-marker mark (point)))
          (tincan--scan-for-state mark)
          (tincan--autofold)
          ;; Follow the tail in any window that was already at the end.
          (dolist (window (get-buffer-window-list buffer nil t))
            (when (>= (window-point window) old)
              (set-window-point window (point-max)))))))))

(defun tincan--sentinel (proc event)
  "Report when the tincan follower PROC ends (EVENT)."
  (let ((buffer (process-buffer proc)))
    (when (and (buffer-live-p buffer) (not (process-live-p proc)))
      (with-current-buffer buffer
        (message "tincan: follower for %s exited (%s)"
                 tincan--session-id (string-trim event))))))

(defun tincan--cleanup ()
  "Tear down this buffer's follower process and notify watch.
For `kill-buffer-hook'."
  (when (process-live-p tincan--process)
    (delete-process tincan--process))
  (when tincan--notify-watch
    (file-notify-rm-watch tincan--notify-watch)
    (setq tincan--notify-watch nil)))

(defun tincan--session-buffer (session)
  "Return an existing tincan VIEW buffer bound to SESSION, or nil.
Terminal buffers also carry `tincan--session-id', so they are excluded here -
otherwise `tincan--watch' would try to render the vterm terminal as a view
\(\"You cannot change major mode in vterm buffers\")."
  (seq-find (lambda (buffer)
              (and (equal (buffer-local-value 'tincan--session-id buffer) session)
                   (not (buffer-local-value 'tincan--terminal-p buffer))))
            (buffer-list)))

(defun tincan--watch (session buffer-name)
  "Set up a buffer watching SESSION (an id or transcript path); return it.
Reuse the buffer already bound to SESSION - matched by id, not name, since the
title (hence the name) can change; BUFFER-NAME names a freshly created one."
  (let ((existing (tincan--session-buffer session)))
    (if (and existing
             (process-live-p (buffer-local-value 'tincan--process existing)))
        existing
      (let ((buffer (or existing (generate-new-buffer buffer-name))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer))
          (tincan-render-buffer)
          ;; Identify the buffer (D36) and layer the in-session keys (D37).
          (setq-local header-line-format '((:eval (tincan--view-header))))
          (use-local-map (make-composed-keymap tincan-view-command-map
                                               (current-local-map)))
          (setq-local tincan--session-id session)
          (setq-local tincan--scan-marker (copy-marker (point-min)))
          (tincan--set-state 'working)
          (add-hook 'kill-buffer-hook #'tincan--cleanup nil t)
          ;; --wait so the follower tolerates a just-started session whose
          ;; transcript file is not written until Claude's first turn (D32).
          (let ((proc (make-process
                       :name (format "tincan-%s" session)
                       :buffer buffer
                       :command (list "python3" tincan-script session
                                      "--follow" "--wait")
                       :connection-type 'pipe
                       :filter #'tincan--filter
                       :sentinel #'tincan--sentinel
                       :noquery t)))
            (setq-local tincan--process proc)
            (set-marker (process-mark proc) (point-max)))
          (setq-local tincan--notify-watch (tincan--setup-notify-watch session)))
        buffer))))

;;;###autoload
(defun tincan-view (session-id &optional title)
  "Watch a Claude Code SESSION-ID live in a read-only buffer.
TITLE, if given, is shown (abbreviated) in the buffer name.
Interactively choose among this project's sessions; with a prefix argument,
choose among all projects' sessions (narrow by title or directory).
This only observes; to reply, start or attach a terminal (see `tincan-start',
`tincan-attach')."
  (interactive
   (let ((plist (tincan--read-session current-prefix-arg)))
     (list (plist-get plist :id) (plist-get plist :title))))
  (pop-to-buffer
   (tincan--watch session-id (tincan--buffer-name session-id title))))

;; * Terminal (running Claude under vterm)
;; Claude runs in an Emacs vterm buffer (D24/D26); replies are pasted into it.
;; tincan owns the session id (D31): a new session is launched with
;; `claude --session-id <uuid>' and a resumed one with `claude --resume <id>',
;; so the id is known up front and the view can follow and link immediately.

(defcustom tincan-claude-command "claude"
  "Program (and any base arguments) used to launch Claude Code in the terminal.
tincan appends \"--session-id <uuid>\" for a new session or \"--resume <id>\"
for a resumed one."
  :type 'string
  :group 'tincan)

(defcustom tincan-show-terminal-on-send 'display
  "What to do with the terminal after sending a reply (D35).
`display' shows it in a window without selecting it (focus stays on the view);
`select' raises and selects it; `none' does nothing."
  :type '(choice (const :tag "Show without selecting" display)
                 (const :tag "Raise and select" select)
                 (const :tag "Do nothing" none))
  :group 'tincan)

(defcustom tincan-dismiss-terminal-on-next-command t
  "If non-nil, the first command after a send dismisses the popped terminal window.
Only applies when `tincan-show-terminal-on-send' is `display': the terminal is a
momentary peek that clears as soon as you act in the view (D35)."
  :type 'boolean
  :group 'tincan)

(defcustom tincan-send-return-delay 0.1
  "Seconds to pause between pasting a reply and sending Return (D34).
Claude's TUI ignores an Enter bundled with a bracketed paste (so pasted text
does not auto-submit), so the Return must arrive as a separate event.  Raise
this if multi-line replies are not submitted; 0 sends the Return immediately."
  :type 'number
  :group 'tincan)

;; Declared by vterm; forward declarations keep the byte-compiler quiet.
(defvar vterm-shell)
(declare-function vterm-mode "ext:vterm")
(declare-function vterm-send-string "ext:vterm" (string &optional paste))
(declare-function vterm-send-return "ext:vterm")
(declare-function vterm-send-C-c "ext:vterm")

(defvar-local tincan--terminal-hint nil
  "Transient hint shown in a new terminal's header line until the first key.")

(defun tincan--vterm-available-p ()
  "Non-nil if vterm is available (loading it on demand)."
  (or (featurep 'vterm) (require 'vterm nil t)))

(defun tincan--new-session-id ()
  "Return a fresh session id from tincan.py (Python's uuid4)."
  (with-temp-buffer
    (let ((code (call-process "python3" nil t nil
                              tincan-script "--new-session-id")))
      (unless (= code 0)
        (error "tincan: could not generate a session id"))
      (string-trim (buffer-string)))))

;; ** Terminal minor mode and header
(defvar tincan-terminal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c SPC") #'tincan-reply)
    (define-key map (kbd "C-c o") #'tincan-switch-view)
    (define-key map (kbd "C-c k") #'tincan-close)
    (define-key map (kbd "C-c C-c") #'tincan-terminal-interrupt)
    ;; Swallow C-z: vterm would forward it as SIGTSTP, suspending Claude with
    ;; no job-control shell to resume it (D37).
    (define-key map (kbd "C-z") #'ignore)
    map)
  "Keys for `tincan-terminal-mode' (layered over vterm; see D37).")

(define-minor-mode tincan-terminal-mode
  "Minor mode for a tincan terminal buffer (Claude under vterm).
It adds a few tincan keys; because they use the `C-c' prefix, `C-c C-c' is
rebound to send a real interrupt to Claude.  The lighter doubles as an identity
cue (D36/D37)."
  :lighter " Tincan"
  :keymap tincan-terminal-mode-map)

(defun tincan-terminal-interrupt ()
  "Send a real C-c (interrupt) to Claude in this terminal."
  (interactive)
  (vterm-send-C-c))

;; A terse placeholder hint for the user to expand; see DECISIONS.md (D36).
(defun tincan--terminal-hint-string ()
  "Return the transient new-session hint for the terminal header line."
  (propertize
   (concat " type to Claude here  -  give it a title (/rename or just ask)"
           "  -  view follows (C-c o)  -  kill + restart to redo")
   'face 'tincan-header-dim))

(defun tincan--terminal-header ()
  "Header-line content for a tincan terminal buffer."
  (concat (propertize " tincan terminal " 'face 'tincan-header-terminal)
          (or tincan--terminal-hint
              (propertize " type to Claude here" 'face 'tincan-header-dim))))

(defun tincan--arm-hint-clear ()
  "Clear `tincan--terminal-hint' on the first command in this buffer (D36)."
  (let ((buffer (current-buffer)))
    (letrec ((fn (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq tincan--terminal-hint nil)
                       (force-mode-line-update)
                       (remove-hook 'pre-command-hook fn t))))))
      (add-hook 'pre-command-hook fn nil t))))

(defvar tincan--closing nil
  "Bound non-nil while `tincan-close' tears a session down, to skip the guard.")

(defun tincan--terminal-kill-query ()
  "Confirm before killing a tincan terminal, which ends its Claude session (D24).
Skipped during an intentional `tincan-close' teardown."
  (or tincan--closing
      (yes-or-no-p "Kill this terminal and end its Claude session? ")))

(defun tincan--make-terminal (session-id command dir hint)
  "Create a tincan terminal for SESSION-ID running COMMAND in DIR; return it.
HINT, if non-nil, is shown in the header line until the first keystroke."
  (let* ((name (format "*tincan terminal: %s*"
                       (abbreviate-file-name (directory-file-name dir))))
         (vterm-shell command)
         (default-directory (file-name-as-directory dir))
         (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      ;; vterm-mode is a major mode, so set our buffer-locals after it.
      (vterm-mode)
      ;; Our kill guard is the single confirmation; suppress Emacs's separate
      ;; "buffer has a running process" prompt so killing asks exactly once.
      (let ((proc (get-buffer-process buffer)))
        (when proc (set-process-query-on-exit-flag proc nil)))
      (setq-local tincan--terminal-p t)
      (setq-local tincan--session-id session-id)
      (setq-local tincan--terminal-hint hint)
      (setq-local header-line-format '((:eval (tincan--terminal-header))))
      (tincan-terminal-mode 1)
      (when hint (tincan--arm-hint-clear))
      (add-hook 'kill-buffer-query-functions #'tincan--terminal-kill-query nil t))
    buffer))

;; ** Linking a session group
(defun tincan--link (view terminal id)
  "Cross-link VIEW and TERMINAL as one session group for ID (D33)."
  (when (buffer-live-p view)
    (with-current-buffer view (setq-local tincan--terminal terminal)))
  (when (buffer-live-p terminal)
    (with-current-buffer terminal
      (setq-local tincan--view view)
      (setq-local tincan--session-id id))))

(defun tincan--resolve-target ()
  "Return (VIEW . TERMINAL) for the current buffer's session group (D33).
Works from a view or a terminal buffer; either element may be nil."
  (cond (tincan--terminal-p
         (cons tincan--view (current-buffer)))
        (tincan--session-id            ; a view buffer
         (cons (current-buffer) tincan--terminal))
        (t (cons nil nil))))

(defun tincan--this-terminal ()
  "Return the terminal buffer of the current buffer's session group, or nil."
  (cdr (tincan--resolve-target)))

;; ** Starting and attaching
;;;###autoload
(defun tincan-start (&optional resume)
  "Start Claude in a tincan terminal and attach a view (D31).
With no prefix, start a NEW session: generate a session id, launch
\"claude --session-id <id>\" in `default-directory', show the terminal, and
open a view that follows it in the background.
With a prefix argument RESUME, pick an existing session and launch
\"claude --resume <id>\" in its directory, showing the view and leaving the
terminal buried."
  (interactive "P")
  (unless (tincan--vterm-available-p)
    (user-error "tincan: vterm is required to run the terminal (see D26)"))
  (if resume (tincan--start-resume) (tincan--start-new)))

(defun tincan--start-new ()
  "Start a new Claude session; see `tincan-start'."
  (let* ((id (tincan--new-session-id))
         (dir default-directory)
         (command (format "%s --session-id %s" tincan-claude-command id))
         (terminal (tincan--make-terminal id command dir
                                          (tincan--terminal-hint-string)))
         (view (tincan--watch id (tincan--buffer-name id nil))))
    (tincan--link view terminal id)
    (pop-to-buffer terminal)
    view))

(defun tincan--start-resume ()
  "Resume an existing Claude session; see `tincan-start'."
  (let* ((plist (tincan--read-session t))
         (id (plist-get plist :id))
         (title (plist-get plist :title))
         (cwd (plist-get plist :cwd))
         (dir (if (and cwd (not (string-empty-p cwd))) cwd default-directory))
         (command (format "%s --resume %s" tincan-claude-command id))
         (terminal (tincan--make-terminal id command dir nil))
         (view (tincan--watch id (tincan--buffer-name id title))))
    (tincan--link view terminal id)
    (pop-to-buffer view)
    view))

;;;###autoload
(defun tincan-attach ()
  "(Re)build and link a view for the terminal in the current buffer (D25/D31).
Run from a tincan terminal buffer; it follows that terminal's own session id, so
there is no session picking and no possible mislink."
  (interactive)
  (unless tincan--terminal-p
    (user-error "tincan: run tincan-attach from a tincan terminal buffer"))
  (let* ((id tincan--session-id)
         (terminal (current-buffer))
         (view (tincan--watch id (tincan--buffer-name id nil))))
    (tincan--link view terminal id)
    (pop-to-buffer view)
    view))

;; * Input (reply and compose)
;; `tincan-reply' (from the view or the terminal) gates on the agent state and,
;; when appropriate, opens a compose buffer; sending pastes into the terminal.

(defun tincan--display-terminal (terminal how)
  "Display TERMINAL.  HOW `select' also selects its window."
  (when (buffer-live-p terminal)
    (let ((window (display-buffer terminal)))
      (when (and (eq how 'select) (window-live-p window))
        (select-window window)))))

;;;###autoload
(defun tincan-reply ()
  "Compose and send a reply to this session's Claude (D34).
Run from the view or the terminal.  Gates on the agent state: when Claude is
waiting for input, surface the terminal instead of composing; when it is still
working, confirm first; otherwise open a compose buffer."
  (interactive)
  (let* ((target (tincan--resolve-target))
         (view (car target))
         (terminal (cdr target)))
    (unless (buffer-live-p terminal)
      (user-error "tincan: no terminal linked (use M-x tincan-attach)"))
    (let ((state (and (buffer-live-p view)
                      (buffer-local-value 'tincan--state view))))
      (cond
       ((eq state 'needs-input)
        (tincan--display-terminal terminal 'select)
        (message "Claude is waiting for input - answer in the terminal"))
       ((and (eq state 'working)
             (not (y-or-n-p "Claude is still working; send anyway? ")))
        (message "tincan: reply cancelled"))
       (t (tincan--open-compose view terminal))))))

;; ** Compose buffer
(defun tincan--compose-major-mode ()
  "Return the major mode for a compose buffer: Markdown when available, else text."
  (or (tincan--markdown-mode-symbol) 'text-mode))

(defun tincan--compose-buffer-name (view terminal)
  "Return a compose buffer name for the VIEW/TERMINAL session group."
  (cond ((buffer-live-p view)
         (replace-regexp-in-string
          "tincan view:" "tincan compose:" (buffer-name view) t t))
        ((buffer-live-p terminal)
         (format "*tincan compose: %s*"
                 (tincan--short-id
                  (buffer-local-value 'tincan--session-id terminal))))
        (t "*tincan compose*")))

(defun tincan--compose-header ()
  "Header-line content for a tincan compose buffer."
  (concat (propertize " tincan compose " 'face 'tincan-header-compose)
          (propertize " C-c C-c send  -  C-c C-k cancel" 'face 'tincan-header-dim)))

(defvar tincan-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'tincan-compose-send)
    (define-key map (kbd "C-c C-k") #'tincan-compose-cancel)
    map)
  "Keys for `tincan-compose-minor-mode' (D34/D37).")

(define-minor-mode tincan-compose-minor-mode
  "Minor mode for a tincan compose buffer: \\`C-c C-c' sends, \\`C-c C-k' cancels."
  :lighter " Tincan-Compose"
  :keymap tincan-compose-mode-map)

(defun tincan--compose-buffer-for (terminal)
  "Return a live compose buffer targeting TERMINAL, or nil.
Keyed on the terminal so concurrent sessions keep separate drafts."
  (seq-find (lambda (buffer)
              (and (buffer-local-value 'tincan-compose-minor-mode buffer)
                   (eq (buffer-local-value 'tincan--terminal buffer) terminal)))
            (buffer-list)))

(defun tincan--open-compose (view terminal)
  "Pop a compose buffer targeting the VIEW/TERMINAL session group.
Reuse this session's existing compose buffer (keeping any in-progress draft)
rather than spawning a duplicate."
  (let ((buffer (or (tincan--compose-buffer-for terminal)
                    (with-current-buffer
                        (generate-new-buffer
                         (tincan--compose-buffer-name view terminal))
                      (funcall (tincan--compose-major-mode))
                      (visual-line-mode 1)
                      (setq-local tincan--view view)
                      (setq-local tincan--terminal terminal)
                      (setq-local header-line-format
                                  '((:eval (tincan--compose-header))))
                      (tincan-compose-minor-mode 1)
                      (current-buffer)))))
    (pop-to-buffer buffer)
    buffer))

(defun tincan-compose-send ()
  "Send the compose buffer to Claude in the linked terminal (D34/D35)."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (terminal tincan--terminal)
        (view tincan--view)
        (compose (current-buffer)))
    (when (string-empty-p text)
      (user-error "tincan: nothing to send"))
    (unless (buffer-live-p terminal)
      (user-error "tincan: terminal is gone"))
    (unless (process-live-p (get-buffer-process terminal))
      (user-error "tincan: Claude process is not running"))
    (with-current-buffer terminal
      (vterm-send-string text t)
      ;; Send Return as a separate event: Claude ignores an Enter bundled with
      ;; the bracketed paste, so a brief pause is needed for it to submit.
      (when (> tincan-send-return-delay 0)
        (sleep-for tincan-send-return-delay))
      (vterm-send-return))
    (kill-buffer compose)
    (tincan--after-send view terminal)))

(defun tincan-compose-cancel ()
  "Discard the compose buffer without sending."
  (interactive)
  (kill-buffer (current-buffer)))

(defun tincan--after-send (view terminal)
  "Show TERMINAL per `tincan-show-terminal-on-send' and keep focus on VIEW (D35)."
  (pcase tincan-show-terminal-on-send
    ('none nil)
    ('select (tincan--display-terminal terminal 'select))
    ('display
     (tincan--display-terminal terminal 'display)
     (when (buffer-live-p view)
       (let ((window (get-buffer-window view)))
         (if window (select-window window) (pop-to-buffer view))))
     (when tincan-dismiss-terminal-on-next-command
       (tincan--arm-terminal-dismiss view terminal)))))

(defun tincan--arm-terminal-dismiss (view terminal)
  "Delete TERMINAL's window on the next command in VIEW (D35).
The command still runs; going to the terminal on purpose is exempted."
  (when (buffer-live-p view)
    (with-current-buffer view
      (letrec ((fn (lambda ()
                     (remove-hook 'pre-command-hook fn t)
                     (when (and (buffer-live-p terminal)
                                (not (eq this-command 'tincan-switch-terminal)))
                       (let ((window (get-buffer-window terminal)))
                         (when (and (window-live-p window)
                                    (not (one-window-p nil window)))
                           (delete-window window)))))))
        (add-hook 'pre-command-hook fn nil t)))))

;; * Switching and closing
(defun tincan--pop-to-sibling (buffer what)
  "Show BUFFER in another window and select it (never the current window).
WHAT names the buffer for the error when it is missing."
  (unless (buffer-live-p buffer)
    (user-error "tincan: no %s linked (use M-x tincan-attach)" what))
  (select-window (display-buffer buffer)))

(defun tincan-switch-terminal ()
  "Show this session's terminal in another window and select it."
  (interactive)
  (tincan--pop-to-sibling (cdr (tincan--resolve-target)) "terminal"))

(defun tincan-switch-view ()
  "Show this session's view in another window and select it."
  (interactive)
  (tincan--pop-to-sibling (car (tincan--resolve-target)) "view"))

(defun tincan-delete-terminal-window ()
  "Delete the window showing this session's terminal, if any (D35)."
  (interactive)
  (let* ((terminal (tincan--this-terminal))
         (window (and (buffer-live-p terminal) (get-buffer-window terminal))))
    (if (and (window-live-p window) (not (one-window-p nil window)))
        (delete-window window)
      (message "tincan: terminal window is not shown"))))

(defun tincan-close ()
  "Close this tincan session: kill its terminal, view and follower (D24)."
  (interactive)
  (let* ((target (tincan--resolve-target))
         (view (car target))
         (terminal (cdr target)))
    (when (yes-or-no-p "Close this tincan session (ends Claude in the terminal)? ")
      (let ((tincan--closing t))
        (when (buffer-live-p terminal) (kill-buffer terminal))
        (when (buffer-live-p view) (kill-buffer view))))))

;; * Footer
(provide 'tincan)
;;; tincan.el ends here
