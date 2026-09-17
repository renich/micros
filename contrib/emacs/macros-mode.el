;;; macros-mode.el --- Major mode for Macros (MicrOS) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 MicrOS AI Agent Protocol
;; Maintainer: MicrOS AI Agent Protocol
;; Keywords: languages

;;; Commentary:
;; Major mode for editing Macros language files (*.mx, *.macross)

;;; Code:

(defvar macros-mode-hook nil)

(defconst macros-font-lock-keywords-1
  (list
   '("\\<\\(fn\\|if\\|else\\|while\\|return\\)\\>" . font-lock-keyword-face)
   '("\\<\\(true\\|false\\|nil\\)\\>" . font-lock-constant-face)
   '("\\<\\(print\\|println\\|len\\|push\\|substr\\|load\\|import\\)\\>" . font-lock-builtin-face)
   )
  "Minimal highlighting expressions for Macros mode.")

(defvar macros-font-lock-keywords macros-font-lock-keywords-1
  "Default highlighting expressions for Macros mode.")

(defvar macros-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; strings
    (modify-syntax-entry ?\" "\"" st)
    ;; comments
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?\n "> b" st)
    st)
  "Syntax table for `macros-mode'.")

;;;###autoload
(define-derived-mode macros-mode prog-mode "Macros"
  "Major mode for editing Macros language files."
  :syntax-table macros-mode-syntax-table
  (setq font-lock-defaults '(macros-font-lock-keywords))
  (setq-local comment-start "// ")
  (setq-local comment-end ""))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.mx\\'" . macros-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.macross\\'" . macros-mode))

(provide 'macros-mode)
;;; macros-mode.el ends here
