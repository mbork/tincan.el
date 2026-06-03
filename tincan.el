;;; tincan.el --- Drive Claude Code from Emacs via tmux -*- lexical-binding: t; -*-

;; Author: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Maintainer: Marcin 'mbork' Borkowski <mbork@mbork.pl>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes
;; URL: https://github.com/mbork/tincan.el

;;; Commentary:

;; tincan is a hackish take on agentic coding in Emacs: it drives Claude Code
;; via tmux.  This file currently provides `tincan-view-mode', a read-only
;; major mode for displaying a Claude Code transcript produced by
;; tincan-tail.py, with font-locking of its "@@@ ROLE" section markers.
;;
;; The transcript is plain text meant to be followed with
;; `auto-revert-tail-mode', so `tincan-view-mode' only handles display.

;;; Code:

;; * Customization group
(defgroup tincan nil
  "Drive Claude Code from Emacs via tmux."
  :group 'tools
  :prefix "tincan-")

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

;; * Font lock
;; The markers below must stay in sync with tincan-tail.py's ROLE_* constants.
(defvar tincan-font-lock-keywords
  '(("^@@@ USER.*$" . 'tincan-user)
    ("^@@@ ASSISTANT.*$" . 'tincan-assistant)
    ("^@@@ THINKING.*$" . 'tincan-thinking)
    ("^@@@ TOOL_USE.*$" . 'tincan-tool-use)
    ("^@@@ TOOL_RESULT.*$" . 'tincan-tool-result))
  "Font-lock keywords for `tincan-view-mode'.")

;; * View mode
(define-derived-mode tincan-view-mode special-mode "Tincan"
  "Major mode for viewing a Claude Code transcript from tincan-tail.py.

The buffer is read-only; new content is expected to arrive via
`auto-revert-tail-mode'.  Section markers of the form \"@@@ ROLE\" are
font-locked according to the `tincan-user', `tincan-assistant',
`tincan-thinking', `tincan-tool-use' and `tincan-tool-result' faces."
  (setq-local font-lock-defaults '(tincan-font-lock-keywords t)))

;; * Footer
(provide 'tincan)
;;; tincan.el ends here
