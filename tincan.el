;;; tincan.el --- Drive Claude Code from Emacs via tmux -*- lexical-binding: t; -*-

;; Author: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Maintainer: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes
;; URL: https://github.com/mbork/tincan.el

;;; Commentary:

;; tincan is a hackish take on agentic coding in Emacs: it drives Claude Code
;; via tmux.  This file handles the display side of a Claude Code transcript
;; produced by tincan-tail.py.
;;
;; Call `tincan-render-buffer' to set up the current buffer for viewing: it
;; renders the conversation with a Markdown mode when one is available (see
;; `tincan-markdown-mode'), otherwise it falls back to `tincan-view-mode'.
;; Either way the "@@@ ROLE" section markers are font-locked and the buffer is
;; made read-only.
;;
;; The transcript is plain text meant to be followed with
;; `auto-revert-tail-mode', so this file only handles display.

;;; Code:

;; * Customization group
(defgroup tincan nil
  "Drive Claude Code from Emacs via tmux."
  :group 'tools
  :prefix "tincan-")

;; * The tincan-tail.py script
(defconst tincan--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing tincan.el, used to locate tincan-tail.py.")

(defcustom tincan-script
  (expand-file-name "tincan-tail.py" tincan--directory)
  "Path to tincan-tail.py, the helper that prints, follows and manages sessions."
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
;; The markers below must stay in sync with tincan-tail.py's ROLE_* constants.
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

(defun tincan--markdown-mode-symbol ()
  "Return the Markdown major-mode symbol to use, or nil.
Honors `tincan-markdown-mode' and only returns a mode that is `fboundp'."
  (cond ((null tincan-markdown-mode)
         nil)
        ((eq tincan-markdown-mode t)
         (cond ((fboundp 'gfm-mode) 'gfm-mode)
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
      (tincan-view-mode))))

;; * Notification hook
;; Optional integration: a Claude Code "Notification" hook runs tincan-tail.py,
;; which writes a small per-session file when Claude is waiting for input (e.g.
;; a tool-permission prompt).  All settings.json editing is done by the Python
;; script, so the installed command and its paths have a single source of truth;
;; the commands below are thin wrappers around it.  Installing is opt-in and only
;; signals "Claude wants you" - it does not handle tool selection.

(defcustom tincan-hook-settings-file nil
  "Settings file the Notification hook is installed into.
When nil, tincan-tail.py uses its own default,
\".claude/settings.local.json\" relative to the working directory."
  :type '(choice (const :tag "Script default" nil) file)
  :group 'tincan)

(defun tincan--run-hook-script (subcommand)
  "Run tincan-tail.py with SUBCOMMAND, echo its output, return its exit code."
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
  "Install tincan's Notification hook (via tincan-tail.py).
Installing is optional; tincan works without it.  The script backs up the
settings file first.  Afterwards, restart Claude Code or run /hooks so the
change is reviewed and loaded."
  (interactive)
  (tincan--run-hook-script "--install-hook"))

;;;###autoload
(defun tincan-uninstall-hook ()
  "Remove tincan's Notification hook (via tincan-tail.py)."
  (interactive)
  (tincan--run-hook-script "--uninstall-hook"))

;;;###autoload
(defun tincan-hook-installed-p ()
  "Return non-nil if tincan's Notification hook is installed.
Interactively, report the result in the echo area."
  (interactive)
  (= 0 (tincan--run-hook-script "--check-hook")))

;; * Footer
(provide 'tincan)
;;; tincan.el ends here
