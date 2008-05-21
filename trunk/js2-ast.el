;;; js2-ast.el --- JavaScript syntax tree node definitions

;; Author:  Steve Yegge (steve.yegge@gmail.com)
;; Keywords:  javascript languages

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public
;; License along with this program; if not, write to the Free
;; Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
;; MA 02111-1307 USA

;;; Code:

(eval-and-compile
  (require 'cl))

(require 'js2-vars)

;; flags for ast node property 'member-type (used for e4x operators)
(defvar js2-property-flag    #x1 "property access: element is valid name")
(defvar js2-attribute-flag   #x2 "x.@y or x..@y")
(defvar js2-descendants-flag #x4 "x..y or x..@i")

(defsubst js2-relpos (pos anchor)
  "Convert POS to be relative to ANCHOR.
If POS is nil, returns nil."
  (and pos (- pos anchor)))

(defsubst js2-make-pad (indent)
  (if (zerop indent)
      ""
    (make-string (* indent js2-basic-offset) ? )))

(defsubst js2-visit-ast (node callback)
  "Visit every node in ast NODE with visitor CALLBACK.

CALLBACK is a function that takes two arguments:  (NODE END-P).  It is
called twice:  once to visit the node, and again after all the node's
children have been processed.  The END-P argument is nil on the first
call and non-nil on the second call.  The return value of the callback
affects the traversal:  if non-nil, the children of NODE are processed.
If the callback returns nil, or if the node has no children, then the
callback is called immediately with a non-nil END-P argument.

The node traversal is approximately lexical-order, although there
are currently no guarantees around this."
  (let ((vfunc (get (aref node 0) 'js2-visitor)))
    ;; visit the node
    (when  (funcall callback node nil)
      ;; visit the kids
      (cond
       ((eq vfunc 'js2-visit-none)
        nil)                            ; don't even bother calling it
       ;; Each AST node type has to define a `js2-visitor' function
       ;; that takes a node and a callback, and calls `js2-visit-ast'
       ;; on each child of the node.
       (vfunc
        (funcall vfunc node callback))
       (t
        (error "%s does not define a visitor-traversal function"
               (aref node 0)))))
    ;; call the end-visit
    (funcall callback node t)))

(defstruct (js2-node
            (:constructor nil))  ; abstract
  "Base AST node type."
  (type -1)  ; token type
  (pos -1)   ; start position of this AST node in parsed input
  (len 1)    ; num characters spanned by the node
  props      ; optional node property list (an alist)
  parent)    ; link to parent node; null for root

(defsubst js2-node-get-prop (node prop)
  (assoc prop (js2-node-props node)))

(defsubst js2-node-set-prop (node prop value)
  (setf (js2-node-props node)
        (cons (list prop value) (js2-node-props node))))

(defsubst js2-fixup-starts (n nodes)
  "Adjust the start positions of NODES to be relative to N.
Any node in the list may be nil, for convenience."
  (dolist (node nodes)
    (when node
      (setf (js2-node-pos node) (- (js2-node-pos node)
                                   (js2-node-pos n))))))

(defsubst js2-node-add-children (parent &rest nodes)
  "Set parent node of NODES to PARENT.
Does nothing if we're not recording parent links.
If any given node in NODES is nil, doesn't record that link."
  (js2-fixup-starts parent nodes)
  (dolist (node nodes)
    (and node
         (setf (js2-node-parent node) parent))))

;; Non-recursive since it's called a frightening number of times.
(defsubst js2-node-abs-pos (n)
  (let ((pos (js2-node-pos n)))
    (while (setq n (js2-node-parent n))
      (setq pos (+ pos (js2-node-pos n))))
    pos))

(defsubst js2-node-abs-end (n)
  "Return absolute buffer position of end of N."
  (+ (js2-node-abs-pos n) (js2-node-len n)))

(defstruct (js2-stmt-node
            (:include js2-node)
            (:constructor nil))  ; abstract
  "Abstract supertype of (most) statement nodes.")

(defstruct (js2-expr-node
            (:include js2-node)
            (:constructor nil))  ; abstract
  "Abstract supertype of (most) expression nodes.")

(defstruct (js2-error-node
            (:include js2-node)
            (:constructor nil) ; silence emacs21 byte-compiler
            (:constructor make-js2-error-node (&key (type js2-ERROR)
                                                    (pos js2-token-beg)
                                                    len)))
  "AST node representing a parse error.")

(put 'cl-struct-js2-error-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-error-node 'js2-printer 'js2-print-none)

;; It's important to make sure block nodes have a lisp list for the
;; child nodes, to limit printing recursion depth in an AST that
;; otherwise consists of defstruct vectors.  Emacs will crash printing
;; a sufficiently large vector tree.

(defstruct (js2-block-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-block-node (&key (type js2-BLOCK)
                                                    (pos js2-token-beg)
                                                    len
                                                    props
                                                    kids)))
  "A block of statements."
  scope  ; a `js2-scope'
  kids)  ; a lisp list of the child statement nodes

(put 'cl-struct-js2-block-node 'js2-visitor 'js2-visit-block)
(put 'cl-struct-js2-block-node 'js2-printer 'js2-print-block)

(defsubst js2-visit-block (ast callback)
  "Visit the `js2-block-node' children of AST."
  (dolist (kid (js2-block-node-kids ast))
    (js2-visit-ast kid callback)))

(defun js2-print-block (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad "{\n")
    (dolist (kid (js2-block-node-kids n))
      (js2-print-ast kid (1+ i)))
    (insert pad "}")))

(defstruct (js2-script-node
            (:include js2-block-node)
            (:constructor nil)
            (:constructor make-js2-script-node (&key (type js2-SCRIPT)
                                                     (pos js2-token-beg)
                                                     len
                                                     var-decls
                                                     fun-decls)))
  functions   ; lisp list of nested functions
  regexps     ; lisp list of (string . flags)
  symbols     ; alist (every symbol gets unique index)
  (param-count 0)
  var-names   ; vector of string names
  consts      ; bool-vector matching var-decls
  (temp-number 0))  ; for generating temp variables

(put 'cl-struct-js2-script-node 'js2-visitor 'js2-visit-block)
(put 'cl-struct-js2-script-node 'js2-printer 'js2-print-script)

(defun js2-print-script (node indent)
  (dolist (kid (js2-block-node-kids node))
    (js2-print-ast kid indent)))

(defstruct (js2-ast-root
            (:include js2-script-node)
            (:constructor nil)
            (:constructor make-js2-ast-root (&key (type js2-SCRIPT)
                                                  (pos js2-token-beg)
                                                  len
                                                  buffer)))
  "The root node of a js2 AST."
  buffer         ; the source buffer from which the code was parsed
  comments       ; a lisp list of comments, ordered by start position
  errors         ; a lisp list of errors found during parsing
  warnings       ; a lisp list of warnings found during parsing
  node-count)    ; number of nodes in the tree, including the root

(put 'cl-struct-js2-ast-root 'js2-visitor 'js2-visit-ast-root)
(put 'cl-struct-js2-ast-root 'js2-printer 'js2-print-script)

(defun js2-visit-ast-root (ast callback)
  (dolist (kid (js2-ast-root-kids ast))
    (js2-visit-ast kid callback))
  (dolist (comment (js2-ast-root-comments ast))
    (js2-visit-ast comment callback)))

(defstruct (js2-comment-node
            (:include js2-node)
            (:constructor nil)
            (:constructor make-js2-comment-node (&key (type js2-COMMENT)
                                                      (pos js2-token-beg)
                                                      len
                                                      (format js2-ts-comment-type))))
  format)  ; 'line, 'block, 'jsdoc or 'html

(put 'cl-struct-js2-comment-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-comment-node 'js2-printer 'js2-print-comment)

(defun js2-print-comment (n i)
  ;; We really ought to link end-of-line comments to their nodes.
  ;; Or maybe we could add a new comment type, 'endline.
  (insert (js2-make-pad i)
          (js2-node-string n)))

(defstruct (js2-expr-stmt-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-expr-stmt-node (&key (type js2-EXPR_RESULT)
                                                        (pos js2-ts-cursor)
                                                        len
                                                        expr)))
  "An expression statement."
  expr)

(put 'cl-struct-js2-expr-stmt-node 'js2-visitor 'js2-visit-expr-stmt-node)
(put 'cl-struct-js2-expr-stmt-node 'js2-printer 'js2-print-expr-stmt-node)

(defun js2-visit-expr-stmt-node (n v)
  (js2-visit-ast (js2-expr-stmt-node-expr n) v))

(defun js2-print-expr-stmt-node (n indent)
  (js2-print-ast (js2-expr-stmt-node-expr n) indent)
  (insert ";\n"))

(defstruct (js2-loop-node
            (:include js2-stmt-node)
            (:constructor nil))
  "Abstract supertype of loop nodes."
  label     ; optional `js2-labeled-stmt-node'
  body      ; a `js2-block-node'
  scope     ; a `js2-scope'
  lp        ; position of left-paren, nil if omitted
  rp)       ; position of right-paren, nil if omitted

(defstruct (js2-do-node
            (:include js2-loop-node)
            (:constructor nil)
            (:constructor make-js2-do-node (&key (type js2-DO)
                                                 (pos js2-token-beg)
                                                 len
                                                 label
                                                 body
                                                 condition
                                                 while-pos
                                                 lp
                                                 rp)))
  "AST node for do-loop."
  condition  ; while (expression)
  while-pos) ; buffer position of 'while' keyword

(put 'cl-struct-js2-do-node 'js2-visitor 'js2-visit-do-node)
(put 'cl-struct-js2-do-node 'js2-printer 'js2-print-do-node)

(defun js2-visit-do-node (n v)
  (js2-visit-ast (js2-do-node-body n) v)
  (js2-visit-ast (js2-do-node-condition n) v))

(defun js2-print-do-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad "do {\n")
    (dolist (kid (js2-block-node-kids (js2-do-node-body n)))
      (js2-print-ast kid (1+ i)))
    (insert pad "} while (")
    (js2-print-ast (js2-do-node-condition n) 0)
    (insert ");\n")))

(defstruct (js2-while-node
            (:include js2-loop-node)
            (:constructor nil)
            (:constructor make-js2-while-node (&key (type js2-WHILE)
                                                    (pos js2-token-beg)
                                                    len
                                                    label
                                                    body
                                                    condition
                                                    lp
                                                    rp)))
  "AST node for while-loop."
  condition)    ; while-condition

(put 'cl-struct-js2-while-node 'js2-visitor 'js2-visit-while-node)
(put 'cl-struct-js2-while-node 'js2-printer 'js2-print-while-node)

(defun js2-visit-while-node (n v)
  (js2-visit-ast (js2-while-node-condition n) v)
  (js2-visit-ast (js2-while-node-body n) v))

(defun js2-print-while-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad "while (")
    (js2-print-ast (js2-while-node-condition n) 0)
    (insert ") {\n")
    (js2-print-body (js2-while-node-body n) (1+ i))
    (insert pad "}\n")))

(defstruct (js2-for-node
            (:include js2-loop-node)
            (:constructor nil)
            (:constructor make-js2-for-node (&key (type js2-FOR)
                                                  (pos js2-ts-cursor)
                                                  len
                                                  label
                                                  body
                                                  init
                                                  condition
                                                  update
                                                  lp
                                                  rp)))
  "AST node for a C-style for-loop."
  init       ; initialization expression
  condition  ; loop condition
  update)    ; update clause

(put 'cl-struct-js2-for-node 'js2-visitor 'js2-visit-for-node)
(put 'cl-struct-js2-for-node 'js2-printer 'js2-print-for-node)

(defun js2-visit-for-node (n v)
  (js2-visit-ast (js2-for-node-init n) v)
  (js2-visit-ast (js2-for-node-condition n) v)
  (js2-visit-ast (js2-for-node-update n) v)
  (js2-visit-ast (js2-for-node-body n) v))

(defun js2-print-for-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad "for (")
    (js2-print-ast (js2-for-node-init n) 0)
    (insert "; ")
    (js2-print-ast (js2-for-node-condition n) 0)
    (insert "; ")
    (js2-print-ast (js2-for-node-update n) 0)
    (insert ") {\n")
    (js2-print-body (js2-for-node-body n) (1+ i))
    (insert pad "}\n")))

(defstruct (js2-for-in-node
            (:include js2-loop-node)
            (:constructor nil)
            (:constructor make-js2-for-in-node (&key (type js2-FOR)
                                                     (pos js2-ts-cursor)
                                                     len
                                                     label
                                                     body
                                                     iterator
                                                     object
                                                     in-pos
                                                     each-pos
                                                     foreach-p
                                                     lp
                                                     rp)))
  "AST node for a for..in loop."
  iterator  ; [var] foo in ...
  object    ; object over which we're iterating
  in-pos    ; buffer position of 'in' keyword
  each-pos  ; buffer position of 'each' keyword, if foreach-p
  foreach-p) ; t if it's a for-each loop

(put 'cl-struct-js2-for-in-node 'js2-visitor 'js2-visit-for-in-node)
(put 'cl-struct-js2-for-in-node 'js2-printer 'js2-print-for-in-node)

(defun js2-visit-for-in-node (n v)
  (js2-visit-ast (js2-for-in-node-iterator n) v)
  (js2-visit-ast (js2-for-in-node-object n) v)
  (js2-visit-ast (js2-for-in-node-body n) v))

(defun js2-print-for-in-node (n i)
  (let ((pad (js2-make-pad i))
        (foreach (js2-for-in-node-foreach-p n)))
    (insert pad "for ")
    (if foreach
        (insert "each "))
    (insert "(")
    (js2-print-ast (js2-for-in-node-iterator n) 0)
    (insert " in ")
    (js2-print-ast (js2-for-in-node-object n) 0)
    (insert ") {\n")
    (js2-print-body (js2-for-in-node-body n) (1+ i))
    (insert pad "}\n")))

(defstruct (js2-return-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-return-node (&key (type js2-RETURN)
                                                     (pos js2-ts-cursor)
                                                     len
                                                     retval)))
  "AST node for a return statement."
  retval)  ; expression to return, or 'undefined

(put 'cl-struct-js2-return-node 'js2-visitor 'js2-visit-return-node)
(put 'cl-struct-js2-return-node 'js2-printer 'js2-print-return-node)

(defun js2-visit-return-node (n v)
  (if (js2-return-node-retval n)
      (js2-visit-ast (js2-return-node-retval n) v)))

(defun js2-print-return-node (n i)
  (insert (js2-make-pad i) "return")
  (when (js2-return-node-retval n)
    (insert " ")
    (js2-print-ast (js2-return-node-retval n) 0))
  (insert ";\n"))

(defstruct (js2-if-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-if-node (&key (type js2-IF)
                                                 (pos js2-ts-cursor)
                                                 len
                                                 condition
                                                 then-part
                                                 else-pos
                                                 else-part
                                                 lp
                                                 rp)))
  "AST node for an if-statement."
  condition   ; expression
  then-part   ; statement or block
  else-pos    ; optional buffer position of 'else' keyword
  else-part   ; optional statement or block
  lp          ; position of left-paren, nil if omitted
  rp)         ; position of right-paren, nil if omitted

(put 'cl-struct-js2-if-node 'js2-visitor 'js2-visit-if-node)
(put 'cl-struct-js2-if-node 'js2-printer 'js2-print-if-node)

(defun js2-visit-if-node (n v)
  (js2-visit-ast (js2-if-node-condition n) v)
  (js2-visit-ast (js2-if-node-then-part n) v)
  (if (js2-if-node-else-part n)
      (js2-visit-ast (js2-if-node-else-part n) v)))

(defun js2-print-if-node (n i)
  (let ((pad (js2-make-pad i))
        (then-part (js2-if-node-then-part n))
        (else-part (js2-if-node-else-part n)))
    (insert pad "if (")
    (js2-print-ast (js2-if-node-condition n) 0)
    (insert ") {\n")
    (js2-print-body then-part (1+ i))
    (insert pad "}")
    (cond
     ((not else-part)
      (insert "\n"))
     ((js2-if-node-p else-part)
      (insert " else ")
      (js2-print-body else-part i))
     (t
      (insert " else {\n")
      (js2-print-body else-part (1+ i))
      (insert pad "}\n")))))

(defstruct (js2-try-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-try-node (&key (type js2-TRY)
                                                  (pos js2-ts-cursor)
                                                  len
                                                  try-block
                                                  catch-clauses
                                                  finally-block)))
  "AST node for a try-statement."
  try-block
  catch-clauses  ; a lisp list of js2-catch-node
  finally-block) ; a `js2-finally-node'

(put 'cl-struct-js2-try-node 'js2-visitor 'js2-visit-try-node)
(put 'cl-struct-js2-try-node 'js2-printer 'js2-print-try-node)

(defun js2-visit-try-node (n v)
  (js2-visit-ast (js2-try-node-try-block n) v)
  (dolist (clause (js2-try-node-catch-clauses n))
    (js2-visit-ast clause v))
  (if (js2-try-node-finally-block n)
      (js2-visit-ast (js2-try-node-finally-block n) v)))

(defun js2-print-try-node (n i)
  (let ((pad (js2-make-pad i))
        (catches (js2-try-node-catch-clauses n))
        (finally (js2-try-node-finally-block n)))
    (insert pad "try {\n")
    (js2-print-body (js2-try-node-try-block n) (1+ i))
    (insert pad "}")
    (when catches
      (dolist (catch catches)
        (js2-print-ast catch i)))
    (if finally
        (js2-print-ast finally i)
      (insert "\n"))))

(defstruct (js2-catch-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-catch-node (&key (type js2-CATCH)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    var-name
                                                    guard-kwd
                                                    guard-expr
                                                    block
                                                    lp
                                                    rp)))
  "AST node for a catch clause."
  var-name    ; a `js2-name-node'
  guard-kwd   ; relative buffer position of "if" in "catch (x if ...)"
  guard-expr  ; catch condition, a `js2-expr-node'
  block       ; statements, a `js2-block-node'
  lp          ; buffer position of left-paren, nil if omitted
  rp)         ; buffer position of right-paren, nil if omitted

(put 'cl-struct-js2-catch-node 'js2-visitor 'js2-visit-catch-node)
(put 'cl-struct-js2-catch-node 'js2-printer 'js2-print-catch-node)

(defun js2-visit-catch-node (n v)
  (js2-visit-ast (js2-catch-node-var-name n) v)
  (when (js2-catch-node-guard-kwd n)
    (js2-visit-ast (js2-catch-node-guard-expr n) v))
  (js2-visit-ast (js2-catch-node-block n) v))

(defun js2-print-catch-node (n i)
  (let ((pad (js2-make-pad i))
        (guard-kwd (js2-catch-node-guard-kwd n))
        (guard-expr (js2-catch-node-guard-expr n)))
    (insert " catch (")
    (js2-print-ast (js2-catch-node-var-name n) 0)
    (when guard-kwd
      (insert " if ")
      (js2-print-ast guard-expr 0))
    (insert ") {\n")
    (js2-print-body (js2-catch-node-block n) (1+ i))
    (insert pad "}")))

(defstruct (js2-finally-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-finally-node (&key (type js2-FINALLY)
                                                      (pos js2-ts-cursor)
                                                      len
                                                      block)))
  "AST node for a finally clause."
  block)

(put 'cl-struct-js2-finally-node 'js2-visitor 'js2-visit-finally-node)
(put 'cl-struct-js2-finally-node 'js2-printer 'js2-print-finally-node)

(defun js2-visit-finally-node (n v)
  (js2-visit-ast (js2-finally-node-block n) v))

(defun js2-print-finally-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert " finally {\n")
    (js2-print-body (js2-finally-node-block n) (1+ i))
    (insert pad "}\n")))

(defstruct (js2-switch-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-switch-node (&key (type js2-SWITCH)
                                                     (pos js2-ts-cursor)
                                                     len
                                                     discriminant
                                                     cases
                                                     lp
                                                     rp)))
  "AST node for a switch statement."
  discriminant
  cases  ; a lisp list of `js2-case-node'
  lp     ; position of open-paren for discriminant, nil if omitted
  rp)    ; position of close-paren for discriminant, nil if omitted

(put 'cl-struct-js2-switch-node 'js2-visitor 'js2-visit-switch-node)
(put 'cl-struct-js2-switch-node 'js2-printer 'js2-print-switch-node)

(defun js2-visit-switch-node (n v)
  (js2-visit-ast (js2-switch-node-discriminant n) v)
  (dolist (c (js2-switch-node-cases n))
    (js2-visit-ast c v)))

(defun js2-print-switch-node (n i)
  (let ((pad (js2-make-pad i))
        (cases (js2-switch-node-cases n)))
    (insert pad "switch (")
    (js2-print-ast (js2-switch-node-discriminant n) 0)
    (insert ") {\n")
    (dolist (case cases)
      (js2-print-ast case i))
    (insert pad "}\n")))

(defstruct (js2-case-node
            (:include js2-block-node)
            (:constructor nil)
            (:constructor make-js2-case-node (&key (type js2-CASE)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   kids
                                                   expr)))
  "AST node for a case clause of a switch statement."
  expr)   ; the case expression (nil for default)

(put 'cl-struct-js2-case-node 'js2-visitor 'js2-visit-case-node)
(put 'cl-struct-js2-case-node 'js2-printer 'js2-print-case-node)

(defun js2-visit-case-node (n v)
  (if (js2-case-node-expr n)  ; nil for default: case
      (js2-visit-ast (js2-case-node-expr n) v))
  (js2-visit-block n v))

(defun js2-print-case-node (n i)
  (let ((pad (js2-make-pad i))
        (expr (js2-case-node-expr n)))
    (insert pad)
    (if (null expr)
        (insert "default:\n")
      (insert "case ")
      (js2-print-ast expr 0)
      (insert ":\n"))
    (dolist (kid (js2-case-node-kids n))
      (js2-print-ast kid (1+ i)))))

(defstruct (js2-throw-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-throw-node (&key (type js2-THROW)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    expr)))
  "AST node for a throw statement."
  expr)   ; the expression to throw

(put 'cl-struct-js2-throw-node 'js2-visitor 'js2-visit-throw-node)
(put 'cl-struct-js2-throw-node 'js2-printer 'js2-print-throw-node)

(defun js2-visit-throw-node (n v)
  (js2-visit-ast (js2-throw-node-expr n) v))

(defun js2-print-throw-node (n i)
  (insert (js2-make-pad i) "throw ")
  (js2-print-ast (js2-throw-node-expr n) 0)
  (insert ";\n"))

(defstruct (js2-with-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-with-node (&key (type js2-WITH)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   object
                                                   body
                                                   lp
                                                   rp)))
  "AST node for a with-statement."
  object
  body
  lp    ; buffer position of left-paren around object, nil if omitted
  rp)   ; buffer position of right-paren around object, nil if omitted

(put 'cl-struct-js2-with-node 'js2-visitor 'js2-visit-with-node)
(put 'cl-struct-js2-with-node 'js2-printer 'js2-print-with-node)

(defun js2-visit-with-node (n v)
  (js2-visit-ast (js2-with-node-object n) v)
  (js2-visit-ast (js2-with-node-body n) v))

(defun js2-print-with-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad "with (")
    (js2-print-ast (js2-with-node-object n) 0)
    (insert ") {\n")
    (js2-print-body (js2-with-node-body n) (1+ i))
    (insert pad "}\n")))

(defstruct (js2-label-node
            (:include js2-node)
            (:constructor nil)
            (:constructor make-js2-label-node (&key (type js2-LABEL)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    label)))
  "AST node for a statement label or case label."
  label)  ; a string

(put 'cl-struct-js2-label-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-label-node 'js2-printer 'js2-print-label)

(defun js2-print-label (n i)
  (insert (js2-make-pad i)
          (js2-label-node-label n)
          ":\n"))

(defstruct (js2-labeled-stmt-node
            (:include js2-stmt-node)
            (:constructor nil)
            ;; type needs to be in `js2-side-effecting-tokens' to avoid spurious
            ;; no-side-effects warnings
            (:constructor make-js2-labeled-stmt-node (&key (type js2-EXPR_RESULT)
                                                           (pos js2-ts-cursor)
                                                           len
                                                           labels
                                                           stmt)))
  "AST node for a statement with one or more labels.
Multiple labels for a statement are collapsed into the labels field."
  labels  ; lisp list of `js2-label-node'
  stmt)   ; the statement these labels are for

(put 'cl-struct-js2-labeled-stmt-node 'js2-visitor 'js2-visit-labeled-stmt)
(put 'cl-struct-js2-labeled-stmt-node 'js2-printer 'js2-print-labeled-stmt)

(defun js2-visit-labeled-stmt (n v)
  (dolist (label (js2-labeled-stmt-node-labels n))
    (js2-visit-ast label v))
  (js2-visit-ast (js2-labeled-stmt-node-stmt n) v))

(defun js2-print-labeled-stmt (n i)
  (dolist (label (js2-labeled-stmt-node-labels n))
    (js2-print-ast label i))
  (js2-print-ast (js2-labeled-stmt-node-stmt n) (1+ i)))

(defun js2-labeled-stmt-node-contains (node label)
  "Return t if NODE contains LABEL in its label set.
NODE is a `js2-labels-node'.  LABEL is an identifier."
  (loop for nl in (js2-labeled-stmt-node-labels node)
        if (string= label (js2-label-node-label nl))
          return t
        finally return nil))

(defsubst js2-labeled-stmt-node-add-label (node label)
  "Add a `js2-label-node' to the label set for this statement."
  (setf (js2-labeled-stmt-node-labels node)
        (nconc (js2-labeled-stmt-node-labels node) (list label))))

(defstruct (js2-jump-node
            (:include js2-stmt-node)
            (:constructor nil))
  "Abstract supertype of break and continue nodes."
  label   ; `js2-name-node' for location of label identifier, if present
  target) ; target js2-labels-node or loop/switch statement

(defun js2-visit-jump-node (n v)
  ;; we don't visit the target, since it's a back-link
  (if (js2-jump-node-label n)
      (js2-visit-ast (js2-jump-node-label n) v)))

(defstruct (js2-break-node
            (:include js2-jump-node)
            (:constructor nil)
            (:constructor make-js2-break-node (&key (type js2-BREAK)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    label
                                                    target)))
  "AST node for a break statement.
The label field is a `js2-name-node', possibly nil, for the named label
if provided.  E.g. in 'break foo', it represents 'foo'.  The target field
is the target of the break - a label node or enclosing loop/switch statement.")

(put 'cl-struct-js2-break-node 'js2-visitor 'js2-visit-jump-node)
(put 'cl-struct-js2-break-node 'js2-printer 'js2-print-break-node)

(defun js2-print-break-node (n i)
  (insert (js2-make-pad i) "break")
  (when (js2-break-node-label n)
    (insert " ")
    (js2-print-ast (js2-break-node-label n) 0))
  (insert ";\n"))

(defstruct (js2-continue-node
            (:include js2-jump-node)
            (:constructor nil)
            (:constructor make-js2-continue-node (&key (type js2-CONTINUE)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       label
                                                       target)))
  "AST node for a continue statement.
The label field is the user-supplied enclosing label name, a `js2-name-node'.
It is nil if continue specifies no label.  The target field is the jump target:
a `js2-label-node' or the innermost enclosing loop.")

(put 'cl-struct-js2-continue-node 'js2-visitor 'js2-visit-jump-node)
(put 'cl-struct-js2-continue-node 'js2-printer 'js2-print-continue-node)

(defun js2-print-continue-node (n i)
  (insert (js2-make-pad i) "continue")
  (when (js2-continue-node-label n)
    (insert " ")
    (js2-print-ast (js2-continue-node-label n) 0))
  (insert ";\n"))

(defstruct (js2-function-node
            (:include js2-script-node)
            (:constructor nil)
            (:constructor make-js2-function-node (&key (type js2-FUNCTION)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       (ftype 'FUNCTION)
                                                       (form 'STATEMENT_FORM)
                                                       (name "")
                                                       params
                                                       body
                                                       lp
                                                       rp)))
  "AST node for a function declaration.
The `params' field is a lisp list of nodes.  Each node is either a simple
`js2-name-node', or if it's a destructuring-assignment parameter, a
`js2-array-node' or `js2-object-node'."
  ftype            ; FUNCTION, GETTER or SETTER
  form             ; DECLARED_FORM, STATEMENT_FORM or EXPRESSED_FORM
  name             ; function name (a `js2-name-node', or nil if anonymous)
  params           ; a lisp list of `js2-function-arg-node'
  body             ; a `js2-block-node'
  lp               ; position of arg-list open-paren, or nil if omitted
  rp               ; position of arg-list close-paren, or nil if omitted
  needs-activation ; t if we need an activation object for this frame
  is-generator)    ; t if this function contains a yield

(put 'cl-struct-js2-function-node 'js2-visitor 'js2-visit-function-node)
(put 'cl-struct-js2-function-node 'js2-printer 'js2-print-function-node)

(defun js2-visit-function-node (n v)
  (if (js2-function-node-name n)
      (js2-visit-ast (js2-function-node-name n) v))
  (dolist (p (js2-function-node-params n))
    (js2-visit-ast p v))
  (js2-visit-ast (js2-function-node-body n) v))

(defun js2-print-function-node (n i)
  (let ((pad (js2-make-pad i))
        (getter (js2-node-get-prop n 'GETTER_SETTER))
        (name (js2-function-node-name n))
        (params (js2-function-node-params n))
        (body (js2-function-node-body n))
        (expr (eq (js2-function-node-form n) 'FUNCTION_EXPRESSION)))
    (unless getter
      (insert pad "function"))
    (when name
        (insert " ")
        (js2-print-ast name 0))
    (insert "(")
    (loop with len = (length params)
          for param in params
          for count from 1
          do
          (js2-print-ast param 0)
          (if (< count len)
              (insert ", ")))
    (insert ") {")
    (unless expr
      (insert "\n"))
    ;; TODO:  fix this to be smarter about indenting, etc.
    (js2-print-body body (1+ i))
    (insert pad "}")
    (unless expr
      (insert "\n"))))

(defsubst js2-function-name (node)
  "Return function name for NODE, a `js2-function-node', or nil if anonymous."
  (and (js2-function-node-name node)
       (js2-name-node-name (js2-function-node-name node))))

(defstruct (js2-function-arg-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-function-arg-node (&key (type js2-NAME)
                                                           (pos js2-token-beg)
                                                           len
                                                           value)))
  "AST node for a function formal parameter.
The value field is either an array/object literal or a name node."
  value)

(put 'cl-struct-js2-function-arg-node 'js2-visitor 'js2-visit-function-arg-node)
(put 'cl-struct-js2-function-arg-node 'js2-printer 'js2-print-function-arg-node)

(defun js2-visit-function-arg-node (n v)
  (js2-visit-ast (js2-function-arg-node-value n) v))

(defun js2-print-function-arg-node (n i)
  (js2-print-ast (js2-function-arg-node-value n) i))

;; Having this be an expression node makes it more flexible.
;; There are IDE contexts, such as indentation in a for-loop initializer,
;; that work better if you assume it's an expression.  Whenever we have
;; a standalone var/const declaration, we just wrap with an expr stmt.
;; Eclipse apparently screwed this up and now has two versions, expr and stmt.
(defstruct (js2-var-decl-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-var-decl-node (&key (type js2-VAR)
                                                       (pos js2-token-beg)
                                                       len
                                                       kids
                                                       decl-type)))
  "AST node for a variable declaration list (VAR, CONST or LET).
The node bounds differ depending on the declaration type.  For VAR or
CONST declarations, the bounds include the var/const keyword.  For LET
declarations, the node begins at the position of the first child."
  kids        ; a lisp list of `js2-var-init-node' structs.
  decl-type)  ; js2-VAR, js2-CONST or js2-LET

(put 'cl-struct-js2-var-decl-node 'js2-visitor 'js2-visit-var-decl)
(put 'cl-struct-js2-var-decl-node 'js2-printer 'js2-print-var-decl)

(defun js2-visit-var-decl (n v)
  (dolist (kid (js2-var-decl-node-kids n))
    (js2-visit-ast kid v)))

(defun js2-print-var-decl (n i)
  (let ((pad (js2-make-pad i))
        (tt (js2-var-decl-node-decl-type n)))
    (insert pad)
    (insert (cond
             ((= tt js2-VAR) "var ")
             ((= tt js2-LET) "")  ; handled by parent let-{expr/stmt}
             ((= tt js2-CONST) "const ")
             (t
              (error "malformed var-decl node"))))
    (loop with kids = (js2-var-decl-node-kids n)
          with len = (length kids)
          for kid in kids
          for count from 1
          do
          (js2-print-ast kid 0)
          (if (< count len)
              (insert ", ")))))

(defstruct (js2-var-init-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-var-init-node (&key (type js2-VAR)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       name
                                                       initializer)))
  "AST node for a variable declaration.
The type field will be js2-CONST for a const decl."
  name          ; foo (a `js2-name-node')
  initializer)  ; = bar * baz  (a `js2-expr-node')

(put 'cl-struct-js2-var-init-node 'js2-visitor 'js2-visit-var-init-node)
(put 'cl-struct-js2-var-init-node 'js2-printer 'js2-print-var-init-node)

(defun js2-visit-var-init-node (n v)
  (js2-visit-ast (js2-var-init-node-name n) v)
  (if (js2-var-init-node-initializer n)
      (js2-visit-ast (js2-var-init-node-initializer n) v)))

(defun js2-print-var-init-node (n i)
  (let ((pad (js2-make-pad i))
        (name (js2-var-init-node-name n))
        (init (js2-var-init-node-initializer n)))
    (insert pad)
    (js2-print-ast name 0)
    (when init
      (insert " = ")
      (js2-print-ast init 0))))

(defstruct (js2-destructuring-init-node
            (:include js2-var-init-node)
            (:constructor nil)
            (:constructor make-js2-destructuring-init-node (&key (type js2-VAR)
                                                                 (pos js2-ts-cursor)
                                                                 len
                                                                 lhs
                                                                 initializer)))
  "AST node for a destructuring-assignment expression.
It will likely have a `js2-var-decl-node' as its direct parent.
The lhs field is an array literal or object literal node, and the initializer
is the expression that will be destructured."
  lhs)  ; a `js2-expr-node' (array literal or obj literal)

(put 'cl-struct-js2-destructuring-init-node 'js2-visitor 'js2-visit-destructuring-init)
(put 'cl-struct-js2-destructuring-init-node 'js2-printer 'js2-print-destructuring-init)

(defun js2-visit-destructuring-init (n v)
  (js2-visit-ast (js2-destructuring-init-node-lhs n) v)
  (if (js2-destructuring-init-node-initializer n) ; not present in for..in loops
      (js2-visit-ast (js2-destructuring-init-node-initializer n) v)))

(defun js2-print-destructuring-init (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-destructuring-init-node-lhs n) 0)
  (when (js2-destructuring-init-node-initializer n)
    (insert " = ")
    (js2-print-ast (js2-destructuring-init-node-initializer n) 0)))

(defstruct (js2-cond-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-cond-node (&key (type js2-HOOK)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   test-expr
                                                   true-expr
                                                   false-expr
                                                   q-pos
                                                   c-pos)))
  "AST node for the ternary operator"
  test-expr
  true-expr
  false-expr
  q-pos   ; buffer position of ?
  c-pos)  ; buffer position of :

(put 'cl-struct-js2-cond-node 'js2-visitor 'js2-visit-cond-node)
(put 'cl-struct-js2-cond-node 'js2-printer 'js2-print-cond-node)

(defun js2-visit-cond-node (n v)
  (js2-visit-ast (js2-cond-node-test-expr n) v)
  (js2-visit-ast (js2-cond-node-true-expr n) v)
  (js2-visit-ast (js2-cond-node-false-expr n) v))

(defun js2-print-cond-node (n i)
  (let ((pad (js2-make-pad i)))
    (insert pad)
    (js2-print-ast (js2-cond-node-test-expr n) 0)
    (insert " ? ")
    (js2-print-ast (js2-cond-node-true-expr n) 0)
    (insert " : ")
    (js2-print-ast (js2-cond-node-false-expr n) 0)))

(defstruct (js2-infix-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-infix-node (&key type
                                                    (pos js2-ts-cursor)
                                                    len
                                                    op-pos
                                                    left
                                                    right)))
  "Abstract base type for infix expressions.
Includes assignment ops like `|=', and the comma operator.
The type field inherited from `js2-node' holds the operator."
  op-pos ; buffer position where operator begins
  left      ; a `js2-expr-node'
  right)    ; a `js2-expr-node' or `js2-function-node'

(put 'cl-struct-js2-infix-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-infix-node 'js2-printer 'js2-print-infix-node)

(defun js2-visit-infix-node (n v)
  (js2-visit-ast (js2-infix-node-left n) v)
  (js2-visit-ast (js2-infix-node-right n) v))

(defconst js2-operator-tokens
  (let ((table (make-hash-table :test 'eq))
        (tokens
         (list (cons js2-IN "in")
               (cons js2-TYPEOF "typeof")
               (cons js2-INSTANCEOF "instanceof")
               (cons js2-DELPROP "delete")
               (cons js2-COMMA ",")
               (cons js2-COLON ":")
               (cons js2-OR "||")
               (cons js2-AND "&&")
               (cons js2-INC "++")
               (cons js2-DEC "--")
               (cons js2-BITOR "|")
               (cons js2-BITXOR "^")
               (cons js2-BITAND "&")
               (cons js2-EQ "==")
               (cons js2-NE "!=")
               (cons js2-LT "<")
               (cons js2-LE "<=")
               (cons js2-GT ">")
               (cons js2-GE ">=")
               (cons js2-LSH "<<")
               (cons js2-RSH ">>")
               (cons js2-URSH ">>>")
               (cons js2-ADD "+")       ; infix plus
               (cons js2-SUB "-")       ; infix minus
               (cons js2-MUL "*")
               (cons js2-DIV "/")
               (cons js2-MOD "%")
               (cons js2-NOT "!")
               (cons js2-BITNOT "~")
               (cons js2-POS "+")       ; unary plus
               (cons js2-NEG "-")       ; unary minus
               (cons js2-SHEQ "===")    ; shallow equality
               (cons js2-SHNE "!==")    ; shallow inequality
               (cons js2-ASSIGN "=")
               (cons js2-ASSIGN_BITOR "|=")
               (cons js2-ASSIGN_BITXOR "^=")
               (cons js2-ASSIGN_BITAND "&=")
               (cons js2-ASSIGN_LSH "<<=")
               (cons js2-ASSIGN_RSH ">>=")
               (cons js2-ASSIGN_URSH ">>>=")
               (cons js2-ASSIGN_ADD "+=")
               (cons js2-ASSIGN_SUB "-=")
               (cons js2-ASSIGN_MUL "*=")
               (cons js2-ASSIGN_DIV "/=")
               (cons js2-ASSIGN_MOD "%="))))
    (loop for (k . v) in tokens do
          (puthash k v table))
    table))

(defun js2-print-infix-node (n i)
  (let* ((tt (js2-node-type n))
         (op (gethash tt js2-operator-tokens)))
    (unless op
      (error "unrecognized infix operator %s" (js2-node-type n)))
    (insert (js2-make-pad i))
    (js2-print-ast (js2-infix-node-left n) 0)
    (unless (= tt js2-COMMA)
      (insert " "))
    (insert op)
    (insert " ")
    (js2-print-ast (js2-infix-node-right n) 0)))

(defstruct (js2-in-node
            (:include js2-infix-node)
            (:constructor nil)
            (:constructor make-js2-in-node (&key (type js2-IN)
                                                 (pos js2-ts-cursor)
                                                 len
                                                 op-pos
                                                 left
                                                 right)))
  "AST node for an in-expression such as `foo in bar'")

(put 'cl-struct-js2-in-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-in-node 'js2-printer 'js2-print-infix-node)

(defstruct (js2-assign-node
            (:include js2-infix-node)
            (:constructor nil)
            (:constructor make-js2-assign-node (&key type
                                                     (pos js2-ts-cursor)
                                                     len
                                                     op-pos
                                                     left
                                                     right)))
  "Represents any assignment.
The type field holds the actual assignment operator.")

(put 'cl-struct-js2-assign-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-assign-node 'js2-printer 'js2-print-infix-node)

(defstruct (js2-unary-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-unary-node (&key type ; required
                                                    (pos js2-ts-cursor)
                                                    len
                                                    operand)))
  "AST node type for unary operator nodes.
The type field can be NOT, BITNOT, POS, NEG, INC, DEC,
TYPEOF, or DELPROP.  For INC or DEC, a 'postfix node
property is added if the operator follows the operand."
  operand)  ; a `js2-expr-node'

(put 'cl-struct-js2-unary-node 'js2-visitor 'js2-visit-unary-node)
(put 'cl-struct-js2-unary-node 'js2-printer 'js2-print-unary-node)

(defun js2-visit-unary-node (n v)
  (js2-visit-ast (js2-unary-node-operand n) v))

(defun js2-print-unary-node (n i)
  (let* ((tt (js2-node-type n))
         (op (gethash tt js2-operator-tokens))
         (postfix (js2-node-get-prop n 'postfix)))
    (unless op
      (error "unrecognized unary operator %s" tt))
    (insert (js2-make-pad i))
    (unless postfix
      (insert op))
    (if (or (= tt js2-TYPEOF)
            (= tt js2-DELPROP))
        (insert " "))
    (js2-print-ast (js2-unary-node-operand n) 0)
    (when postfix
      (insert op))))

(defstruct (js2-let-expr-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-let-expr-node (&key (type js2-LETEXPR)
                                                       (pos js2-token-beg)
                                                       len
                                                       vars
                                                       expr
                                                       lp
                                                       rp)))
  "AST node for a let expression such as let (i=6) i+2."
  vars
  expr   ; a `js2-expr-node'
  scope  ; a `js2-scope'
  lp
  rp)

(put 'cl-struct-js2-let-expr-node 'js2-visitor 'js2-visit-let-expr-node)
(put 'cl-struct-js2-let-expr-node 'js2-printer 'js2-print-let-expr-node)

(defun js2-visit-let-expr-node (n v)
  (js2-visit-ast (js2-let-expr-node-vars n) v)
  (if (js2-let-expr-node-expr n)
      (js2-visit-ast (js2-let-expr-node-expr n) v)))

(defun js2-print-let-expr-node (n i)
  (let ((expr (js2-let-expr-node-expr n)))
  (insert (js2-make-pad i) "let ")
  (if expr
      (insert "("))
  (js2-print-ast (js2-let-expr-node-vars n) 0)
  (when expr
    (insert ") ")
    (js2-print-ast expr 0))))

(defstruct (js2-let-stmt-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-let-stmt-node (&key (type js2-LET)
                                                       (pos js2-token-beg)
                                                       len
                                                       vars
                                                       body
                                                       lp
                                                       rp)))
  "AST node for a let statement such as let (i=6) {x += i}."
  vars
  body   ; a statement node
  scope  ; a `js2-scope'
  lp     ; position of left-paren, nil if omitted
  rp)    ; position of right-paren, nil if omitted

(put 'cl-struct-js2-let-stmt-node 'js2-visitor 'js2-visit-let-stmt-node)
(put 'cl-struct-js2-let-stmt-node 'js2-printer 'js2-print-let-stmt-node)

(defun js2-visit-let-stmt-node (n v)
  (let ((body (js2-let-stmt-node-body n)))
    (js2-visit-ast (js2-let-stmt-node-vars n) v)
    (when body
      (js2-visit-ast body v))))

(defun js2-print-let-stmt-node (n i)
  (let ((pad (js2-make-pad i))
        (body (js2-let-stmt-node-body n)))
    (insert pad "let ")
    (if body
        (insert "("))
    (js2-print-ast (js2-let-stmt-node-vars n) 0)
    (if (not body)
        (insert ";\n")
      (insert ") {\n")
      (js2-print-body (js2-let-stmt-node-body n) (1+ i))
      (insert pad "}\n"))))

;; `defstruct' doesn't provide multiple inheritance for fields, alas.
(defsubst js2-let-node-p (node)
  "Interface predicate for let-stmt and let-expr nodes."
  (or (js2-let-expr-node-p node)
      (js2-let-stmt-node-p node)))

(defsubst js2-let-node-lp (node)
  (if (js2-let-expr-node-p node)
      (js2-let-expr-node-lp node)
    (js2-let-stmt-node-lp node)))

(defsubst js2-let-node-rp (node)
  (if (js2-let-expr-node-p node)
      (js2-let-expr-node-rp node)
    (js2-let-stmt-node-rp node)))

(defstruct (js2-debugger-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-debugger-node (&key (type js2-DEBUGGER)
                                                       (pos js2-token-beg)
                                                       (len (- js2-ts-cursor pos)))))
  "AST node for debugger statement.")

(put 'cl-struct-js2-debugger-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-debugger-node 'js2-printer 'js2-print-debugger)

(defun js2-print-debugger (n i)
  (insert (js2-make-pad i) "debugger;\n"))

(defstruct (js2-new-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-new-node (&key (type js2-NEW)
                                                  (pos js2-token-beg)
                                                  len
                                                  target
                                                  args
                                                  initializer
                                                  lp
                                                  rp)))
  "AST node for new-expression such as new Foo()."
  target  ; an identifier or reference
  args    ; a lisp list of argument nodes
  lp      ; position of left-paren, nil if omitted
  rp      ; position of right-paren, nil if omitted
  initializer) ; experimental Rhino syntax:  optional `js2-object-node'

(put 'cl-struct-js2-new-node 'js2-visitor 'js2-visit-new-node)
(put 'cl-struct-js2-new-node 'js2-printer 'js2-print-new-node)

(defun js2-visit-new-node (n v)
  (js2-visit-ast (js2-new-node-target n) v)
  (dolist (arg (js2-new-node-args n))
    (js2-visit-ast arg v))
  (when (js2-new-node-initializer n)
    (js2-visit-ast (js2-new-node-initializer n) v)))

(defun js2-print-new-node (n i)
  (insert (js2-make-pad i) "new ")
  (js2-print-ast (js2-new-node-target n))
  (insert "(")
  (js2-print-list (js2-new-node-args n))
  (insert ")")
  (when (js2-new-node-initializer n)
    (insert " ")
    (js2-print-ast (js2-new-node-initializer n))))

(defstruct (js2-name-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-name-node (&key (type js2-NAME)
                                                   (pos js2-token-beg)
                                                   (len (- js2-ts-cursor
                                                           js2-token-beg))
                                                   (name js2-ts-string))))
  "AST node for a JavaScript identifier"
  name)  ; a string

(put 'cl-struct-js2-name-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-name-node 'js2-printer 'js2-print-name)

(defun js2-print-name (n i)
  (insert (js2-make-pad i)
          (js2-name-node-name n)))

(defstruct (js2-number-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-number-node (&key (type js2-NUMBER)
                                                     (pos js2-token-beg)
                                                     (len (- js2-ts-cursor
                                                             js2-token-beg))
                                                     (value js2-ts-string)
                                                     (num-value js2-ts-number))))
  "AST node for a number literal."
  value      ; the original string, e.g. "6.02e23"
  num-value) ; the parsed number value

(put 'cl-struct-js2-number-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-number-node 'js2-printer 'js2-print-number-node)

(defun js2-print-number-node (n i)
  (insert (js2-make-pad i)
          (number-to-string (js2-number-node-value n))))

(defstruct (js2-regexp-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-regexp-node (&key (type js2-REGEXP)
                                                     (pos js2-token-beg)
                                                     (len (- js2-ts-cursor
                                                             js2-token-beg))
                                                     value
                                                     flags)))
  "AST node for a regular expression literal."
  value  ; the regexp string, without // delimiters
  flags) ; a string of flags, e.g. `mi'.

(put 'cl-struct-js2-regexp-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-regexp-node 'js2-printer 'js2-print-regexp)

(defun js2-print-regexp (n i)
  (insert (js2-make-pad i)
          "/"
          (js2-regexp-node-value n)
          "/")
  (if (js2-regexp-node-flags n)
      (insert (js2-regexp-node-flags n))))

(defstruct (js2-string-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-string-node (&key (type js2-STRING)
                                                     (pos js2-token-beg)
                                                     (len (- js2-ts-cursor
                                                             js2-token-beg))
                                                     (value js2-ts-string))))
  "String literal.
Escape characters are not evaluated; e.g. \n is 2 chars in value field.
You can tell the quote type by looking at the first character."
  value) ; the characters of the string, including the quotes

(put 'cl-struct-js2-string-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-string-node 'js2-printer 'js2-print-string)

(defun js2-print-string (n i)
  (insert (js2-make-pad i)
          (js2-node-string n)))

(defstruct (js2-array-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-array-node (&key (type js2-ARRAYLIT)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    elems)))
  "AST node for an array literal."
  elems)  ; list of expressions.  [foo,,bar] yields a nil middle element.

(put 'cl-struct-js2-array-node 'js2-visitor 'js2-visit-array-node)
(put 'cl-struct-js2-array-node 'js2-printer 'js2-print-array-node)

(defun js2-visit-array-node (n v)
  (dolist (e (js2-array-node-elems n))
    (when e  ; can be nil, e.g. [a, ,b]
      (js2-visit-ast e v))))

(defun js2-print-array-node (n i)
  (insert (js2-make-pad i) "[")
  (js2-print-list (js2-array-node-elems n))
  (insert "]"))

(defstruct (js2-object-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-object-node (&key (type js2-OBJECTLIT)
                                                     (pos js2-ts-cursor)
                                                     len
                                                     elems)))
  "AST node for an object literal expression."
  elems)  ; a lisp list of `js2-object-prop-node'

(put 'cl-struct-js2-object-node 'js2-visitor 'js2-visit-object-node)
(put 'cl-struct-js2-object-node 'js2-printer 'js2-print-object-node)

(defun js2-visit-object-node (n v)
  (dolist (e (js2-object-node-elems n))
    (js2-visit-ast e v)))

(defun js2-print-object-node (n i)
  (insert (js2-make-pad i) "{")
  (js2-print-list (js2-object-node-elems n))
  (insert "}"))

(defstruct (js2-object-prop-node
            (:include js2-infix-node)
            (:constructor nil)
            (:constructor make-js2-object-prop-node (&key (type js2-COLON)
                                                          (pos js2-ts-cursor)
                                                          len
                                                          left
                                                          right
                                                          op-pos)))
  "AST node for an object literal prop:value entry.
The `left' field is the property:  a name node, string node or number node.
The `right' field is a `js2-expr-node' representing the initializer value.")

(put 'cl-struct-js2-object-prop-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-object-prop-node 'js2-printer 'js2-print-object-prop-node)

(defun js2-print-object-prop-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-object-prop-node-left n) 0)
  (insert ":")
  (js2-print-ast (js2-object-prop-node-right n) 0))

(defstruct (js2-getter-setter-node
            (:include js2-infix-node)
            (:constructor nil)
            (:constructor make-js2-getter-setter-node (&key type ; GET or SET
                                                            (pos js2-ts-cursor)
                                                            len
                                                            left
                                                            right
                                                            kwd)))
  "AST node for a getter/setter property in an object literal.
The `left' field is the `js2-name-node' naming the getter/setter prop.
The `right' field is always an anonymous `js2-function-node' with a node
property `GETTER_SETTER' set to js2-GET or js2-SET. "
  kwd)  ; a `js2-string-node' representing the keyword

(put 'cl-struct-js2-getter-setter-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-getter-setter-node 'js2-printer 'js2-print-getter-setter)

(defun js2-print-getter-setter (n i)
  (let ((pad (js2-make-pad i))
        (kwd (js2-getter-setter-node-kwd n))
        (left (js2-getter-setter-node-left n))
        (right (js2-getter-setter-node-right n)))
    (insert pad (js2-string-node-value kwd) " ")
    (js2-print-ast left 0)
    (js2-print-ast right 0)))

(defstruct (js2-prop-get-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-prop-get-node (&key (type js2-GETPROP)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       target
                                                       prop)))
  "AST node for a dotted property reference, e.g. foo.bar or foo().bar"
  target  ; foo (can be any expression)
  prop)   ; bar (a `js2-name-node')

(put 'cl-struct-js2-prop-get-node 'js2-visitor 'js2-visit-prop-get-node)
(put 'cl-struct-js2-prop-get-node 'js2-printer 'js2-print-prop-get-node)

(defun js2-visit-prop-get-node (n v)
  (js2-visit-ast (js2-prop-get-node-target n) v)
  (js2-visit-ast (js2-prop-get-node-prop n) v))

(defun js2-print-prop-get-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-prop-get-node-target n) 0)
  (insert ".")
  (js2-print-ast (js2-prop-get-node-prop n) 0))

(defstruct (js2-elem-get-node
            (:include js2-prop-get-node)
            (:constructor nil)
            (:constructor make-js2-elem-get-node (&key (type js2-GETELEM)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       target
                                                       prop
                                                       lb
                                                       rb)))
  "AST node for an array index expression such as foo[bar]."
  lb      ; position of left-bracket, nil if omitted
  rb)     ; position of right-bracket, nil if omitted

(put 'cl-struct-js2-elem-get-node 'js2-visitor 'js2-visit-elem-get-node)
(put 'cl-struct-js2-elem-get-node 'js2-printer 'js2-print-elem-get-node)

(defun js2-visit-elem-get-node (n v)
  (js2-visit-ast (js2-elem-get-node-target n) v)
  (js2-visit-ast (js2-elem-get-node-prop n) v))

(defun js2-print-elem-get-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-elem-get-node-target n) 0)
  (insert "[")
  (js2-print-ast (js2-elem-get-node-prop n) 0)
  (insert "]"))

(defstruct (js2-call-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-call-node (&key (type js2-CALL)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   expr
                                                   args
                                                   lp
                                                   rp)))
  "AST node for a JavaScript function call."
  expr  ; a `js2-expr-node' evaluating to the function to call
  args  ; a lisp list of argument AST nodes
  lp    ; position of open-paren, or nil if missing
  rp)   ; position of close-paren, or nil if missing

(put 'cl-struct-js2-call-node 'js2-visitor 'js2-visit-call-node)
(put 'cl-struct-js2-call-node 'js2-printer 'js2-print-call-node)

(defun js2-visit-call-node (n v)
  (js2-visit-ast (js2-call-node-expr n) v)
  (dolist (arg (js2-call-node-args n))
    (js2-visit-ast arg v)))

(defun js2-print-call-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-call-node-expr n) 0)
  (insert "(")
  (js2-print-list (js2-call-node-args n))
  (insert ")"))

(defstruct (js2-literal-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-literal-node (&key type  ; required
                                                      (pos js2-token-beg)
                                                      (len (- js2-ts-cursor
                                                              js2-token-beg)))))
  "AST node representing a literal value such as `null'.
Used for `null', `this', `true' and `false'.
The node type is set to js2-NULL, js2-THIS, etc.")

(put 'cl-struct-js2-literal-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-literal-node 'js2-printer 'js2-print-literal-node)

(defsubst js2-this-node-p (node)
  "Return t if this node is a `js2-literal-node' of type js2-THIS."
  (eq (js2-node-type node) js2-THIS))

(defun js2-print-literal-node (n i)
  (insert (js2-make-pad i))
  (insert
   (let ((type (js2-node-type n)))
     (cond
      ((= type js2-NULL) "null")
      ((= type js2-VOID) "void")
      ((= type js2-THIS) "this")
      ((= type js2-TRUE) "true")
      ((= type js2-FALSE) "false")
      (t
       (error "Unknown literal value %s" type))))))

;; This can be an expr or statment, unfortunately.
(defstruct (js2-yield-node
            (:include js2-node)
            (:constructor nil)
            (:constructor make-js2-yield-node (&key (type js2-YIELD)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    value)))
  "AST node for yield statement."
  value) ; value to be yielded

(put 'cl-struct-js2-yield-node 'js2-visitor 'js2-visit-yield-node)
(put 'cl-struct-js2-yield-node 'js2-printer 'js2-print-yield-node)

(defun js2-visit-yield-node (n v)
  (js2-visit-ast (js2-yield-node-value n) v))

(defun js2-print-yield-node (n i)
  (insert (js2-make-pad i))
  (insert "yield")
  (when (js2-yield-node-value n)
    (insert " ")
    (js2-print-ast (js2-yield-node-value n) 0)))

(defstruct (js2-paren-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-paren-node (&key (type js2-LP)
                                                    (pos js2-ts-cursor)
                                                    len
                                                    expr)))
  "AST node for a parenthesized expression.
In particular, used when the parens are syntactically optional,
as opposed to required parens such as those enclosing an if-conditional."
  expr)   ; `js2-expr-node'

(put 'cl-struct-js2-paren-node 'js2-visitor 'js2-visit-paren-node)
(put 'cl-struct-js2-paren-node 'js2-printer 'js2-print-paren-node)

(defun js2-visit-paren-node (n v)
  (js2-visit-ast (js2-paren-node-expr n) v))

(defun js2-print-paren-node (n i)
  (insert (js2-make-pad i))
  (insert "(")
  (js2-print-ast (js2-paren-node-expr n) 0)
  (insert ")"))

(defstruct (js2-array-comp-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-array-comp-node (&key (type js2-ARRAYCOMP)
                                                         (pos js2-ts-cursor)
                                                         len
                                                         result
                                                         loops
                                                         filter
                                                         if-pos
                                                         lp
                                                         rp)))
  "AST node for an Array comprehension such as [[x,y] for (x in foo) for (y in bar)]."
  result  ; result expression (just after left-bracket)
  loops   ; a lisp list of `js2-array-comp-loop-node'
  filter  ; guard/filter expression
  if-pos  ; buffer pos of 'if' keyword, if present, else nil
  lp      ; buffer position of if-guard left-paren, or nil if not present
  rp)     ; buffer position of if-guard right-paren, or nil if not present

(put 'cl-struct-js2-array-comp-node 'js2-visitor 'js2-visit-array-comp-node)
(put 'cl-struct-js2-array-comp-node 'js2-printer 'js2-print-array-comp-node)

(defun js2-visit-array-comp-node (n v)
  (js2-visit-ast (js2-array-comp-node-result n) v)
  (dolist (l (js2-array-comp-node-loops n))
    (js2-visit-ast l v))
  (if (js2-array-comp-node-filter n)
      (js2-visit-ast (js2-array-comp-node-filter n) v)))

(defun js2-print-array-comp-node (n i)
  (let ((pad (js2-make-pad i))
        (result (js2-array-comp-node-result n))
        (loops (js2-array-comp-node-loops n))
        (filter (js2-array-comp-node-filter n)))
    (insert pad "[")
    (js2-print-ast result 0)
    (dolist (l loops)
      (insert " ")
      (js2-print-ast l 0))
    (when filter
      (insert " if (")
      (js2-print-ast filter 0))
    (insert ")]")))

(defstruct (js2-array-comp-loop-node
            (:include js2-for-in-node)
            (:constructor nil)
            (:constructor make-js2-array-comp-loop-node (&key (type js2-FOR)
                                                              (pos js2-ts-cursor)
                                                              len
                                                              iterator
                                                              object
                                                              in-pos
                                                              foreach-p
                                                              each-pos
                                                              lp
                                                              rp)))
  "AST subtree for each 'for (foo in bar)' loop in an array comprehension.")

(put 'cl-struct-js2-array-comp-loop-node 'js2-visitor 'js2-visit-array-comp-loop)
(put 'cl-struct-js2-array-comp-loop-node 'js2-printer 'js2-print-array-comp-loop)

(defun js2-visit-array-comp-loop (n v)
  (js2-visit-ast (js2-array-comp-loop-node-iterator n) v)
  (js2-visit-ast (js2-array-comp-loop-node-object n) v))

(defun js2-print-array-comp-loop (n i)
  (insert "for (")
  (js2-print-ast (js2-array-comp-loop-node-iterator n) 0)
  (insert " in ")
  (js2-print-ast (js2-array-comp-loop-node-object n) 0)
  (insert ")"))

(defstruct (js2-empty-stmt-node
            (:include js2-stmt-node)
            (:constructor nil)
            (:constructor make-js2-empty-stmt-node (&key (type js2-EMPTY)
                                                         (pos js2-token-beg)
                                                         len)))
  "AST node for an empty statement.")

(put 'cl-struct-js2-empty-stmt-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-empty-stmt-node 'js2-printer 'js2-print-none)

(defstruct (js2-empty-expr-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-empty-expr-node (&key (type js2-EMPTY)
                                                         (pos js2-token-beg)
                                                         len)))
  "AST node for an empty expression.")

(put 'cl-struct-js2-empty-expr-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-empty-expr-node 'js2-printer 'js2-print-none)

(defstruct (js2-xml-node
            (:include js2-block-node)
            (:constructor nil)
            (:constructor make-js2-xml-node (&key (type js2-XML)
                                                  (pos js2-token-beg)
                                                  len
                                                  kids)))
  "AST node for initial parse of E4X literals.
The kids field is a list of XML fragments:  strings and js exprs.
Rhino just creates a concatenation of them (binary plus) and passes
the concatenation to the constructor of a new XML object.")

(put 'cl-struct-js2-xml-node 'js2-visitor 'js2-visit-block)
(put 'cl-struct-js2-xml-node 'js2-printer 'js2-print-xml-node)

(defun js2-print-xml-node (n i)
  (dolist (kid (js2-xml-node-kids n))
    (js2-print-ast kid i)))

(defstruct (js2-xml-start-tag-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-start-tag-node (&key (type js2-XML)
                                                            (pos js2-ts-cursor)
                                                            len
                                                            name
                                                            attrs
                                                            kids
                                                            empty-p)))
  "AST node for an XML start-tag.
The `kids' field is a lisp list of child content nodes."
  name      ; a `js2-xml-name-node'
  attrs     ; a lisp list of `js2-xml-attr-node'
  empty-p)  ; t if this is an empty element such as <foo bar="baz"/>

(put 'cl-struct-js2-xml-start-tag-node 'js2-visitor 'js2-visit-xml-start-tag)
(put 'cl-struct-js2-xml-start-tag-node 'js2-printer 'js2-print-xml-start-tag)

(defun js2-visit-xml-start-tag (n v)
  (js2-visit-ast (js2-xml-start-tag-node-name n) v)
  (dolist (attr (js2-xml-start-tag-node-attrs n))
    (js2-visit-ast attr v))
  (js2-visit-block n v))

(defun js2-print-xml-start-tag (n i)
  (insert (js2-make-pad i) "<")
  (js2-print-ast (js2-xml-start-tag-node-name n) 0)
  (when (js2-xml-start-tag-node-attrs n)
    (insert " ")
    (js2-print-list (js2-xml-start-tag-node-attrs n) " "))
  (insert ">"))

;; I -think- I'm going to make the parent node the corresponding start-tag,
;; and add the end-tag to the kids list of the parent as well.
(defstruct (js2-xml-end-tag-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-end-tag-node (&key (type js2-XML)
                                                          (pos js2-ts-cursor)
                                                          len
                                                          name)))
  "AST node for an XML end-tag."
  name)  ; a `js2-xml-name-node'

(put 'cl-struct-js2-xml-end-tag-node 'js2-visitor 'js2-visit-xml-end-tag)
(put 'cl-struct-js2-xml-end-tag-node 'js2-printer 'js2-print-xml-end-tag)

(defun js2-visit-xml-end-tag (n v)
  (js2-visit-ast (js2-xml-end-tag-node-name n) v))

(defun js2-print-xml-end-tag (n i)
  (insert (js2-make-pad i))
  (insert "</")
  (js2-print-ast (js2-xml-end-tag-node-name n) 0)
  (insert ">"))

(defstruct (js2-xml-name-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-name-node (&key (type js2-XML)
                                                       (pos js2-ts-cursor)
                                                       len
                                                       namespace
                                                       kids)))
  "AST node for an E4X XML name.
Any XML name can be qualified with a namespace, hence the namespace field.
Further, any E4X name can be comprised of arbitrary JavaScript {} expressions.
The kids field is a list of `js2-name-node' and `js2-xml-js-expr-node'.
For a simple name, the kids list has exactly one node, a `js2-name-node'."
  namespace)  ; a `js2-string-node'

(put 'cl-struct-js2-xml-name-node 'js2-visitor 'js2-visit-xml-name-node)
(put 'cl-struct-js2-xml-name-node 'js2-printer 'js2-print-xml-name-node)

(defun js2-visit-xml-name-node (n v)
  (js2-visit-ast (js2-xml-name-node-namespace n) v))

(defun js2-print-xml-name-node (n i)
  (insert (js2-make-pad i))
  (when (js2-xml-name-node-namespace n)
    (js2-print-ast (js2-xml-name-node-namespace n) 0)
    (insert "::"))
  (dolist (kid (js2-xml-name-node-kids n))
    (js2-print-ast kid 0)))

(defstruct (js2-xml-pi-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-pi-node (&key (type js2-XML)
                                                     (pos js2-ts-cursor)
                                                     len
                                                     name
                                                     attrs)))
  "AST node for an E4X XML processing instruction."
  name   ; a `js2-xml-name-node'
  attrs) ; a list of `js2-xml-attr-node'

(put 'cl-struct-js2-xml-pi-node 'js2-visitor 'js2-visit-xml-pi-node)
(put 'cl-struct-js2-xml-pi-node 'js2-printer 'js2-print-xml-pi-node)

(defun js2-visit-xml-pi-node (n v)
  (js2-visit-ast (js2-xml-pi-node-name n) v)
  (dolist (attr (js2-xml-pi-node-attrs n))
    (js2-visit-ast attr v)))

(defun js2-print-xml-pi-node (n i)
  (insert (js2-make-pad i) "<?")
  (js2-print-ast (js2-xml-pi-node-name n))
  (when (js2-xml-pi-node-attrs n)
    (insert " ")
    (js2-print-list (js2-xml-pi-node-attrs n)))
  (insert "?>"))

(defstruct (js2-xml-cdata-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-cdata-node (&key (type js2-XML)
                                                        (pos js2-ts-cursor)
                                                        len
                                                        content)))
  "AST node for a CDATA escape section."
  content)  ; a `js2-string-node' with node-property 'quote-type 'cdata

(put 'cl-struct-js2-xml-cdata-node 'js2-visitor 'js2-visit-xml-cdata-node)
(put 'cl-struct-js2-xml-cdata-node 'js2-printer 'js2-print-xml-cdata-node)

(defun js2-visit-xml-cdata-node (n v)
  (js2-visit-ast (js2-xml-cdata-node-content n) v))

(defun js2-print-xml-cdata-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-xml-cdata-node-content n)))

(defstruct (js2-xml-js-expr-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-js-expr-node (&key (type js2-XML)
                                                          (pos js2-ts-cursor)
                                                          len
                                                          expr)))
  "AST node for an embedded JavaScript {expression} in an E4X literal.
The start and end fields correspond to the curly-braces."
  expr)  ; a `js2-expr-node' of some sort

(put 'cl-struct-js2-xml-js-expr-node 'js2-visitor 'js2-visit-xml-js-expr)
(put 'cl-struct-js2-xml-js-expr-node 'js2-printer 'js2-print-xml-js-expr)

(defun js2-visit-xml-js-expr (n v)
  (js2-visit-ast (js2-xml-js-expr-node-expr n) v))

(defun js2-print-xml-js-expr (n i)
  (insert (js2-make-pad i))
  (insert "{")
  (js2-print-ast (js2-xml-js-expr-node-expr n) 0)
  (insert "}"))

(defstruct (js2-xml-attr-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-attr-node (&key (type js2-XML)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   name
                                                   value
                                                   eq-pos
                                                   quote-type)))
  "AST node representing a foo='bar' XML attribute value."
  name   ; a `js2-xml-name-node'
  value  ; a `js2-xml-name-node'
  eq-pos ; buffer position of "=" sign
  quote-type) ; 'single or 'double

(put 'cl-struct-js2-xml-attr-node 'js2-visitor 'js2-visit-xml-attr-node)
(put 'cl-struct-js2-xml-attr-node 'js2-printer 'js2-print-xml-attr-node)

(defun js2-visit-xml-attr-node (n v)
  (js2-visit-ast (js2-xml-attr-node-name n) v)
  (js2-visit-ast (js2-xml-attr-node-value n) v))

(defun js2-print-xml-attr-node (n i)
  (let ((quote (if (eq (js2-xml-attr-node-quote-type n) 'single)
                   "'"
                 "\"")))
    (insert (js2-make-pad i))
    (js2-print-ast (js2-xml-attr-node-name n) 0)
    (insert "=" quote)
    (js2-print-ast (js2-xml-attr-node-value n) 0)
    (insert quote)))

(defstruct (js2-xml-text-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-text-node (&key (type js2-XML)
                                                   (pos js2-ts-cursor)
                                                   len
                                                   content)))
  "AST node for an E4X XML text node."
  content)  ; a lisp list of `js2-string-node' and `js2-xml-js-expr-node'

(put 'cl-struct-js2-xml-text-node 'js2-visitor 'js2-visit-xml-text-node)
(put 'cl-struct-js2-xml-text-node 'js2-printer 'js2-print-xml-text-node)

(defun js2-visit-xml-text-node (n v)
  (js2-visit-ast (js2-xml-text-node-content n) v))

(defun js2-print-xml-text-node (n i)
  (insert (js2-make-pad i))
  (dolist (kid (js2-xml-text-node-content n))
    (js2-print-ast kid)))

;; Should this be a `js2-comment-node' instead?
(defstruct (js2-xml-comment-node
            (:include js2-xml-node)
            (:constructor nil)
            (:constructor make-js2-xml-comment-node (&key (type js2-XML)
                                                          (pos js2-ts-cursor)
                                                          len)))
  "AST node for E4X XML comment.")

(put 'cl-struct-js2-xml-comment-node 'js2-visitor 'js2-visit-none)
(put 'cl-struct-js2-xml-comment-node 'js2-printer 'js2-print-xml-comment)

(defun js2-print-xml-comment (n i)
  (insert (js2-make-pad i)
          (js2-node-string n)))

(defstruct (js2-xml-dot-query-node
            (:include js2-infix-node)
            (:constructor nil)
            (:constructor make-js2-xml-dot-query-node (&key (type js2-DOTQUERY)
                                                            (pos js2-ts-cursor)
                                                            op-pos
                                                            len
                                                            left
                                                            right)))
  "AST node for an E4X foo.(bar) filter expression.")

(put 'cl-struct-js2-xml-dot-query-node 'js2-visitor 'js2-visit-infix-node)
(put 'cl-struct-js2-xml-dot-query-node 'js2-printer 'js2-print-xml-dot-query)

(defun js2-print-xml-dot-query (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-xml-dot-query-node-left n) 0)
  (insert ".(")
  (js2-print-ast (js2-xml-dot-query-node-right n) 0)
  (insert ")"))

(defstruct (js2-xml-ref-node
            (:include js2-expr-node)
            (:constructor nil)
            (:constructor make-js2-xml-ref-node (&key (type js2-REF_NAME)
                                                      (pos js2-ts-cursor)
                                                      op-pos
                                                      len
                                                      target
                                                      namespace
                                                      propname
                                                      ref-expr
                                                      flags)))
  "AST node for a simple E4X XML attribute or member expression.
This can take a variety of forms:
  name, ns::name, *::name, ns::*, *::*
  @attr, @*, @ns::attr, @ns::*, @*::attr, @*::*
  @[expr], @ns::[expr], @*::[expr]
Not all the fields will be set for any given format.
This node type will be the child of a '.' or '..' operator.
The target field is the expression preceding the operator.
The flags field specifies whether it's an attribute access, and
also whether it was a .. (descendants) operator."
  target    ; `js2-expr-node'
  namespace ; a `js2-string-node' representing a prop name or "*"
  propname  ; a `js2-string-node' representing a prop name or "*"
  ref-expr  ; if [expr], a `js2-expr-node' for the expression
  flags     ; member type flags (mostly for runtime execution)
  op-pos)   ; position of the start of the operator

(put 'cl-struct-js2-xml-ref-node 'js2-visitor 'js2-visit-xml-ref-node)
(put 'cl-struct-js2-xml-ref-node 'js2-printer 'js2-print-xml-ref-node)

(defun js2-visit-xml-ref-node (n v)
  (if (js2-xml-ref-node-target n)
      (js2-visit-ast (js2-xml-ref-node-target n) v))
  (if (js2-xml-ref-node-namespace n)
      (js2-visit-ast (js2-xml-ref-node-namespace n) v))
  (if (js2-xml-ref-node-propname n)
      (js2-visit-ast (js2-xml-ref-node-propname n) v))
  (if (js2-xml-ref-node-ref-expr n)
      (js2-visit-ast (js2-xml-ref-node-ref-expr n) v)))

(defun js2-print-xml-ref-node (n i)
  (insert (js2-make-pad i))
  (js2-print-ast (js2-xml-ref-node-target n) 0)
  (insert (if (flag-set-p (js2-xml-ref-node-flags n)
                          js2-descendants-flag)
              ".."
            ","))
  (when (js2-xml-ref-node-namespace n)
    (js2-print-ast (js2-xml-ref-node-namespace n) 0)
    (insert "::"))
  (if (js2-xml-ref-node-propname n)
      (js2-print-ast (js2-xml-ref-node-propname n) 0)
    (insert "[")
    (js2-print-ast (js2-xml-ref-node-ref-expr n) 0)
    (insert "]")))

(defsubst js2-node-line (n)
  "Fetch the source line number at the start of node N.
This is O(n) in the length of the source buffer; use prudently."
  (1+ (count-lines (point-min) (js2-node-abs-pos n))))

(defsubst js2-block-node-kid (n i)
  "Return child I of node N, or nil if there aren't that many."
  (nth i (js2-block-node-kids n)))

(defsubst js2-block-node-first (n)
  "Return first child of block node N, or nil if there is none."
  (first (js2-block-node-kids n)))

(defun js2-node-root (n)
  "Return the root of the AST containing N.
If N has no parent pointer, returns N."
  (let ((parent (js2-node-parent n)))
    (if parent
        (js2-node-root parent)
      n)))

(defun js2-node-parent-stmt (node)
  "Return the node's first ancestor that is a statement.
Returns nil if NODE is a `js2-ast-root'."
  (let ((parent (js2-node-parent node)))
    (if (or (null parent)
            (js2-stmt-node-p parent)
            (and (js2-function-node-p parent)
                 (neq (js2-function-node-form parent) 'FUNCTION_EXPRESSION)))
        parent
      (js2-node-parent-stmt parent))))

(defun js2-node-position-in-parent (node &optional parent)
  "Return the position of NODE in parent's block-kids list.
PARENT can be supplied if known.  Positioned returned is zero-indexed.
Returns 0 if NODE is not a child of a block statement, or if NODE
is not a statement node."
  (let ((p (or parent (js2-node-parent node)))
        (i 0))
    (if (not (js2-block-node-p p))
        i
      (or (js2-position node (js2-block-node-kids p))
          0))))

(defsubst js2-node-short-name (n)
  "Return the short name of node N as a string, e.g. `js2-if-node'."
  (substring (symbol-name (aref n 0))
             (length "cl-struct-")))

(defsubst js2-node-child-list (node)
  "Return the child list for NODE, a lisp list of nodes.
Works for block nodes, array nodes, obj literals, funarg lists,
var decls and try nodes (for catch clauses).  Note that you should call
`js2-block-node-kids' on the function body for the body statements.
Returns nil for zero-length child lists or unsupported nodes."
  (cond
   ((js2-function-node-p node)
    (js2-function-node-params node))
   ((js2-block-node-p node)
    (js2-block-node-kids node))
   ((js2-try-node-p node)
    (js2-try-node-catch-clauses node))
   ((js2-array-node-p node)
    (js2-array-node-elems node))
   ((js2-object-node-p node)
    (js2-object-node-elems node))
   ((js2-call-node-p node)
    (js2-call-node-args node))
   ((js2-new-node-p node)
    (js2-new-node-args node))
   ((js2-var-decl-node-p node)
    (js2-var-decl-node-kids node))
   (t
    nil)))

(defsubst js2-node-set-child-list (node kids)
  "Set the child list for NODE to KIDS."
   (cond
    ((js2-function-node-p node)
     (setf (js2-function-node-params node) kids))
    ((js2-block-node-p node)
     (setf (js2-block-node-kids node) kids))
    ((js2-try-node-p node)
     (setf (js2-try-node-catch-clauses node) kids))
    ((js2-array-node-p node)
     (setf (js2-array-node-elems node) kids))
    ((js2-object-node-p node)
     (setf (js2-object-node-elems node) kids))
    ((js2-call-node-p node)
     (setf (js2-call-node-args node) kids))
    ((js2-new-node-p node)
     (setf (js2-new-node-args node) kids))
    ((js2-var-decl-node-p node)
     (setf (js2-var-decl-node-kids node) kids))
    (t
     (error "Unsupported node type: %s" (js2-node-short-name node))))
   kids)

;; All because Common Lisp doesn't support multiple inheritance for defstructs.
(defconst js2-paren-expr-nodes
  '(cl-struct-js2-array-comp-loop-node
    cl-struct-js2-array-comp-node
    cl-struct-js2-call-node
    cl-struct-js2-catch-node
    cl-struct-js2-do-node
    cl-struct-js2-elem-get-node
    cl-struct-js2-for-in-node
    cl-struct-js2-for-node
    cl-struct-js2-function-node
    cl-struct-js2-if-node
    cl-struct-js2-let-expr-node
    cl-struct-js2-let-stmt-node
    cl-struct-js2-new-node
    cl-struct-js2-paren-node
    cl-struct-js2-switch-node
    cl-struct-js2-while-node
    cl-struct-js2-with-node)
  "Node types that can have a parenthesized child expression.
In particular, nodes that respond to `js2-node-lp' and `js2-node-rp'.")

(defsubst js2-paren-expr-node-p (node)
  "Return t for nodes that typically have a parenthesized child expression.
Useful for computing the indentation anchors for arg-lists and conditions.
Note that it may return a false positive, for instance when NODE is
a `js2-new-node' and there are no arguments or parentheses."
  (memq (aref node 0) js2-paren-expr-nodes))

;; Fake polymorphism... yech.
(defsubst js2-node-lp (node)
  "Return relative left-paren position for NODE, if applicable.
For `js2-elem-get-node' structs, returns left-bracket position.
Note that the position may be nil in the case of a parse error."
  (cond
   ((js2-elem-get-node-p node)
    (js2-elem-get-node-lb node))
   ((js2-loop-node-p node)
    (js2-loop-node-lp node))
   ((js2-function-node-p node)
    (js2-function-node-lp node))
   ((js2-if-node-p node)
    (js2-if-node-lp node))
   ((js2-new-node-p node)
    (js2-new-node-lp node))
   ((js2-call-node-p node)
    (js2-call-node-lp node))
   ((js2-paren-node-p node)
    (js2-node-pos node))
   ((js2-switch-node-p node)
    (js2-switch-node-lp node))
   ((js2-catch-node-p node)
    (js2-catch-node-lp node))
   ((js2-let-expr-node-p node)
    (js2-let-expr-node-lp node))
   ((js2-let-stmt-node-p node)
    (js2-let-stmt-node-lp node))
   ((js2-array-comp-node-p node)
    (js2-array-comp-node-lp node))
   ((js2-with-node-p node)
    (js2-with-node-lp node))
   (t
    (error "Unsupported node type: %s" (js2-node-short-name node)))))

;; Fake polymorphism... blech.
(defsubst js2-node-rp (node)
  "Return relative right-paren position for NODE, if applicable.
For `js2-elem-get-node' structs, returns right-bracket position.
Note that the position may be nil in the case of a parse error."
  (cond
   ((js2-elem-get-node-p node)
    (js2-elem-get-node-lb node))
   ((js2-loop-node-p node)
    (js2-loop-node-rp node))
   ((js2-function-node-p node)
    (js2-function-node-rp node))
   ((js2-if-node-p node)
    (js2-if-node-rp node))
   ((js2-new-node-p node)
    (js2-new-node-rp node))
   ((js2-call-node-p node)
    (js2-call-node-rp node))
   ((js2-paren-node-p node)
    (+ (js2-node-pos node) (js2-node-len node)))
   ((js2-switch-node-p node)
    (js2-switch-node-rp node))
   ((js2-catch-node-p node)
    (js2-catch-node-rp node))
   ((js2-let-expr-node-p node)
    (js2-let-expr-node-rp node))
   ((js2-let-stmt-node-p node)
    (js2-let-stmt-node-rp node))
   ((js2-array-comp-node-p node)
    (js2-array-comp-node-rp node))
   ((js2-with-node-p node)
    (js2-with-node-rp node))
   (t
    (error "Unsupported node type: %s" (js2-node-short-name node)))))

(defsubst js2-node-first-child (node)
  "Returns the first element of `js2-node-child-list' for NODE."
  (car (js2-node-child-list node)))

(defsubst js2-node-last-child (node)
  "Returns the last element of `js2-node-last-child' for NODE."
  (car (last (js2-node-child-list node))))

(defun js2-node-prev-sibling (node)
  "Return the previous statement in parent.
Works for parents supported by `js2-node-child-list'.
Returns nil if NODE is not in the parent, or PARENT is
not a supported node, or if NODE is the first child."
  (let* ((p (js2-node-parent node))
         (kids (js2-node-child-list p))
         (sib (car kids)))
    (while (and kids
                (neq node (cadr kids)))
      (setq kids (cdr kids)
            sib (car kids)))
    sib))

(defun js2-node-next-sibling (node)
  "Return the next statement in parent block.
Returns nil if NODE is not in the block, or PARENT is not
a block node, or if NODE is the last statement."
  (let* ((p (js2-node-parent node))
         (kids (js2-node-child-list p)))
    (while (and kids
                (neq node (car kids)))
      (setq kids (cdr kids)))
    (cadr kids)))

(defun js2-node-find-child-before (pos parent &optional after)
  "Find the last child that starts before POS in parent.
If AFTER is non-nil, returns first child starting after POS.
POS is an absolute buffer position.  PARENT is any node
supported by `js2-node-child-list'.
Returns nil if no applicable child is found."
  (let ((kids (if (js2-function-node-p parent)
                  (js2-block-node-kids (js2-function-node-body parent))
                (js2-node-child-list parent)))
        (beg (if (js2-function-node-p parent)
                 (js2-node-abs-pos (js2-function-node-body parent))
               (js2-node-abs-pos parent)))
        kid
        result
        fn
        (continue t))
    (setq fn (if after '> '<))
    (while (and kids continue)
      (setq kid (car kids))
      (if (funcall fn (+ beg (js2-node-pos kid)) pos)
          (setq result kid
                continue (if after nil t))
        (setq continue (if after t nil)))
      (setq kids (cdr kids)))
    result))

(defun js2-node-find-child-after (pos parent)
  "Find first child that starts after POS in parent.
POS is an absolute buffer position.  PARENT is any node
supported by `js2-node-child-list'.
Returns nil if no applicable child is found."
  (js2-node-find-child-before pos parent 'after))

(defun js2-node-replace-child (pos parent new-node)
  "Replace node at index POS in PARENT with NEW-NODE.
Only works for parents supported by `js2-node-child-list'."
  (let ((kids (js2-node-child-list parent))
        (i 0))
    (while (< i pos)
      (setq kids (cdr kids)
            i (1+ i)))
    (setcar kids new-node)
    (js2-node-add-children parent new-node)))

(defun js2-node-buffer (n)
  "Return the buffer associated with AST N.
Returns nil if the buffer is not set as a property on the root
node, or if parent links were not recorded during parsing."
  (let ((root (js2-node-root n)))
    (and root
         (js2-ast-root-p root)
         (js2-ast-root-buffer root))))

(defsubst js2-block-node-push (n kid)
  "Push js2-node KID onto the end of js2-block-node N's child list.
KID is always added to the -end- of the kids list.
Function also calls `js2-node-add-children' to add the parent link."
  (let ((kids (js2-node-child-list n)))
    (if kids
        (setcdr kids (nconc (cdr kids) (list kid)))
      (js2-node-set-child-list n (list kid)))
    (js2-node-add-children n kid)))

(defun js2-node-string (node)
  (let ((buf (js2-node-buffer node))
        pos)
    (unless buf
      (error "No buffer available for node %s" node))
    (save-excursion
      (set-buffer buf)
      (buffer-substring-no-properties (setq pos (js2-node-abs-pos node))
                                      (+ pos (js2-node-len node))))))

;; Container for storing the node we're looking for in a traversal.
(defvar js2-discovered-node nil)
(make-variable-buffer-local 'js2-discovered-node)

;; Keep track of absolute node position during traversals.
(defvar js2-visitor-offset nil)
(make-variable-buffer-local 'js2-visitor-offset)

(defvar js2-node-search-point nil)
(make-variable-buffer-local 'js2-node-search-point)

(when js2-mode-dev-mode-p
  (defun js2-find-node-at-point ()
    (interactive)
    (let ((node (js2-node-at-point)))
      (message "%s" (or node "No node found at point"))))
  (defun js2-node-name-at-point ()
    (interactive)
    (let ((node (js2-node-at-point)))
      (message "%s" (if node
                        (js2-node-short-name node)
                      "No node found at point.")))))

(defun js2-node-at-point (&optional pos skip-comments)
  "Return AST node at POS, a buffer position, defaulting to current point.
The `js2-mode-ast' variable must be set to the current parse tree.
Signals an error if the AST (`js2-mode-ast') is nil.
Always returns a node - if it can't find one, it returns the root.
If SKIP-COMMENTS is non-nil, comment nodes are ignored."
  (let ((ast js2-mode-ast)
        result)
    (unless ast
      (error "No JavaScript AST available"))
    ;; Look through comments first, since they may be inside nodes that
    ;; would otherwise report a match.
    (setq pos (or pos (point))
          result (if (> pos (js2-node-abs-end ast))
                     ast
                   (if (not skip-comments)
                       (js2-comment-at-point pos))))
    (unless result
      (setq js2-discovered-node nil
            js2-visitor-offset 0
            js2-node-search-point pos)
      (unwind-protect
          (catch 'js2-visit-done
            (js2-visit-ast ast #'js2-node-at-point-visitor))
        (setq js2-visitor-offset nil
              js2-node-search-point nil))
      (setq result js2-discovered-node))
    ;; may have found a comment beyond end of last child node,
    ;; since visiting the ast-root looks at the comment-list last.
    (if (and skip-comments
             (js2-comment-node-p result))
        (setq result nil))
    (or result js2-mode-ast)))

(defun js2-node-at-point-visitor (node end-p)
  (let ((rel-pos (js2-node-pos node))
        abs-pos
        abs-end
        (point js2-node-search-point))
    (cond
     (end-p
      ;; this evaluates to a non-nil return value, even if it's zero
      (decf js2-visitor-offset rel-pos))
     ;; we already looked for comments before visiting, and don't want them now
     ((js2-comment-node-p node)
      nil)
     (t
      (setq abs-pos (incf js2-visitor-offset rel-pos)
            ;; we only want to use the node if the point is before
            ;; the last character position in the node, so we decrement
            ;; the absolute end by 1.
            abs-end (+ abs-pos (js2-node-len node) -1))
      (cond
       ;; If this node starts after search-point, stop the search.
       ((> abs-pos point)
        (throw 'js2-visit-done nil))
       ;; If this node ends before the search-point, don't check kids.
       ((> point abs-end)
        nil)
       (t
        ;; Otherwise point is within this node, possibly in a child.
        (setq js2-discovered-node node)
        t))))))  ; keep processing kids to look for more specific match

(defsubst js2-block-comment-p (node)
  "Return non-nil if NODE is a comment node of format `jsdoc' or `block'."
  (and (js2-comment-node-p node)
       (memq (js2-comment-node-format node) '(jsdoc block))))

;; TODO:  put the comments in a vector and binary-search them instead
(defun js2-comment-at-point (&optional pos)
  "Look through scanned comment nodes for one containing POS.
POS is a buffer position that defaults to current point.
Function returns nil if POS was not in any comment node."
  (let ((ast js2-mode-ast)
        (x (or pos (point)))
        beg
        end)
    (unless ast
      (error "No JavaScript AST available"))
    (catch 'done
      ;; Comments are stored in lexical order.
      (dolist (comment (js2-ast-root-comments ast) nil)
        (setq beg (js2-node-abs-pos comment)
              end (+ beg (js2-node-len comment)))
        (if (and (>= x beg)
                 (<= x end))
            (throw 'done comment))))))

(defun js2-mode-find-parent-fn (node)
  "Find function enclosing NODE.
Returns nil if NODE is not inside a function."
  (setq node (js2-node-parent node))
  (while (and node (not (js2-function-node-p node)))
    (setq node (js2-node-parent node)))
  (and (js2-function-node-p node) node))

(defun js2-mode-find-enclosing-fn (node)
  "Find function or root enclosing NODE."
  (if (js2-ast-root-p node)
      node
    (setq node (js2-node-parent node))
    (while (not (or (js2-ast-root-p node)
                    (js2-function-node-p node)))
      (setq node (js2-node-parent node)))
    node))

(defun js2-mode-find-enclosing-node (beg end)
  "Find script or function fully enclosing BEG and END."
  (let ((node (js2-node-at-point beg))
        pos
        (continue t))
    (while continue
      (if (or (js2-ast-root-p node)
              (and (js2-function-node-p node)
                   (<= (setq pos (js2-node-abs-pos node)) beg)
                   (>= (+ pos (js2-node-len node)) end)))
          (setq continue nil)
        (setq node (js2-node-parent node))))
    node))

(defun js2-node-parent-script-or-fn (node)
  "Find script or function immediately enclosing NODE.
If NODE is the ast-root, returns nil."
  (if (js2-ast-root-p node)
      nil
    (setq node (js2-node-parent node))
    (while (and node (not (or (js2-function-node-p node)
                              (js2-script-node-p node))))
      (setq node (js2-node-parent node)))
    node))

(defsubst js2-mode-find-first-stmt (node)
  "Search upward starting from NODE looking for a statement.
For purposes of this function, a `js2-function-node' counts."
  (while (not (or (js2-stmt-node-p node)
                  (js2-function-node-p node)))
    (setq node (js2-node-parent node)))
  node)

(defsubst js2-nested-function-p (node)
  "Return t if NODE is a nested function, or is inside a nested function."
  (js2-function-node-p (if (js2-function-node-p node)
                           (js2-node-parent-script-or-fn node)
                         (js2-node-parent-script-or-fn
                          (js2-node-parent-script-or-fn node)))))

(defsubst js2-mode-shift-kids (kids start offset)
  (dolist (kid kids)
    (if (> (js2-node-pos kid) start)
        (incf (js2-node-pos kid) offset))))

(defsubst js2-mode-shift-children (parent start offset)
  "Update start-positions of all children of PARENT beyond START."
  (let ((root (js2-node-root parent)))
    (js2-mode-shift-kids (js2-node-child-list parent) start offset)
    (js2-mode-shift-kids (js2-ast-root-comments root) start offset)))

(defsubst js2-node-is-descendant (node ancestor)
  "Return t if NODE is a descendant of ANCESTOR."
  (while (and node
              (neq node ancestor))
    (setq node (js2-node-parent node)))
  node)

;;; visitor infrastructure

(defun js2-visit-none (node callback)
  "Visitor for AST node that have no node children."
  nil)

(defun js2-print-none (node indent)
  "Visitor for AST node with no printed representation.")

(defun js2-print-body (node indent)
  "Print a statement, or a block without braces."
  (if (js2-block-node-p node)
      (dolist (kid (js2-block-node-kids node))
        (js2-print-ast kid indent))
    (js2-print-ast node indent)))

(defun js2-print-list (args &optional delimiter)
  (loop with len = (length args)
        for arg in args
        for count from 1
        do
        (js2-print-ast arg 0)
        (if (< count len)
            (insert (or delimiter ", ")))))

(defun js2-print-tree (ast)
  "Prints an AST to the current buffer.
Makes `js2-ast-parent-nodes' available to the printer functions."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 1500)))
    (js2-print-ast ast)))

(defun js2-print-ast (node &optional indent)
  "Helper function for printing AST nodes.
Requires `js2-ast-parent-nodes' to be non-nil.
You should use `js2-print-tree' instead of this function."
  (let ((printer (get (aref node 0) 'js2-printer))
        (i (or indent 0))
        (pos (js2-node-abs-pos node)))
    ;; TODO:  wedge comments in here somewhere
    (if printer
        (funcall printer node i))))

;; Symbol-table support.  Unfortunately defstruct doesn't support
;; multiple inheritance, so we use delegation:  any node type that
;; introduces a new scope (a script, function or let-node) has
;; an associated scope field containing a `js2-scope', which
;; we must fetch when doing scope operations.  This scope node has
;; two "parent" pointers:  its parent scope node, and its associated
;; AST node.  This lets us climb up the scope chain and then figure
;; out which AST node we're at.

(defstruct (js2-symbol
            (:constructor nil)
            (:constructor make-js2-symbol (decl-type name &optional ast-node)))
  "A symbol table entry."
  ;; One of js2-FUNCTION, js2-LP (for parameters), js2-VAR,
  ;; js2-LET, or js2-CONST
  decl-type
  name  ; string
  ast-node) ; a `js2-node'

(defstruct (js2-scope
            (:constructor nil)
            (:constructor make-js2-scope (&key type
                                               (ast-node nil))))
  ;; The symbol-table is a LinkedHashMap<String,Symbol> in Rhino.
  ;; I don't have one of those handy, so I'll use an alist for now.
  ;; It's as fast as an emacs hashtable for up to about 50 elements,
  ;; and is much lighter-weight to construct (both CPU and mem).
  ;; The keys are interned strings (symbols) for faster lookup.
  ;; Should switch to hybrid alist/hashtable eventually.
  type      ; the AST token type, e.g. js2-FUNCTION
  symbols   ; an alist of (symbol . js2-symbol)
  parent    ; a `js2-scope'
  ast-node)     ; ast node: a `js2-node'

(defun js2-node-scope (node)
  "Return the `js2-scope' for NODE.
Signals an error if NODE is not a scope node."
  (let ((tt (js2-node-type node)))
    (cond
     ;; fake polymorphism
     ((= tt js2-FUNCTION)
      (js2-function-node-scope node))
     ((= tt js2-SCRIPT)
      (js2-script-node-scope node))
     ((= tt js2-BLOCK)
      (js2-block-node-scope node))
     ((js2-loop-node-p node)
      (js2-loop-node-scope node))
     ((= tt js2-LETEXPR)
      (js2-let-expr-node-scope node))
     ((= tt js2-LET)
      (js2-let-stmt-node-scope node))
     (t
      (error "%s is not a scope node" (js2-node-short-name node))))))

(defun js2-node-set-scope (node scope)
  "Set the `js2-scope' for NODE, and return SCOPE.
Signals an error if NODE is not a scope node."
  (let ((tt (js2-node-type node)))
    (cond
     ;; fake polymorphism
     ((= tt js2-FUNCTION)
      (setf (js2-function-node-scope node) scope))
     ((= tt js2-SCRIPT)
      (setf (js2-script-node-scope node) scope))
     ((= tt js2-BLOCK)
      (setf (js2-block-node-scope node) scope))
     ((js2-loop-node-p node)
      (setf (js2-loop-node-scope node) scope))
     ((= tt js2-LETEXPR)
      (setf (js2-let-expr-node-scope node) scope))
     ((= tt js2-LET)
      (setf (js2-let-stmt-node-scope node) scope))
     (t
      (error "%s is not a scope node" (js2-node-short-name node))))
    scope))

(defconst js2-scope-node-types
  (list js2-FUNCTION js2-SCRIPT js2-BLOCK js2-LETEXPR js2-LET
        js2-FOR js2-WHILE js2-DO))

(defsubst js2-scope-node-p (node)
  "Return t if NODE is a node associated with a `js2-scope'."
  (memq (js2-node-type node) js2-scope-node-types))

(defun js2-node-get-enclosing-scope (node)
  "Return the innermost `js2-scope' node surrounding NODE.
Returns nil if there is no enclosing scope node."
  (let ((parent (js2-node-parent node)))
    ;; loop until we have a scope-node parent with a non-nil scope
    (while (and parent
                (or (not (js2-scope-node-p parent))
                    (null (js2-node-scope parent))))
      (setq parent (js2-node-parent parent)))
    parent))

(defun js2-get-defining-scope (scope name)
  "Search up scope chain from SCOPE looking for NAME, a string or symbol.
Returns `js2-scope' in which NAME is defined, or nil if not found."
  (let ((sym (if (symbolp name)
                 name
               (intern name)))
        table
        result
        (continue t))
    (while (and scope continue)
      (if (and (setq table (js2-scope-symbols scope))
               (assq sym table))
          (setq continue nil
                result scope)
        (setq scope (js2-scope-parent scope))))
    result))

(defsubst js2-scope-get-symbol (scope name)
  "Return symbol table entry for NAME in SCOPE.
NAME can be a string or symbol.   Returns a `js2-symbol' or nil if not found."
  (and (js2-scope-symbols scope)
       (cdr (assq (if (symbolp name)
                      name
                    (intern name))
                  (js2-scope-symbols scope)))))

(defsubst js2-scope-put-symbol (scope name symbol)
  "Enter SYMBOL into symbol-table for SCOPE under NAME.
NAME can be a lisp symbol or string.  SYMBOL is a `js2-symbol'."
  (let* ((table (js2-scope-symbols scope))
         (sym (if (symbolp name) name (intern name)))
         (entry (assq sym table)))
    (if entry
        (setcdr entry symbol)
      (push (cons sym symbol)
            (js2-scope-symbols scope)))))

(defconst js2-side-effecting-tokens
  (let ((tokens (make-bool-vector js2-num-tokens nil)))
    (dolist (tt (list js2-ASSIGN
                      js2-ASSIGN_ADD
                      js2-ASSIGN_BITAND
                      js2-ASSIGN_BITOR
                      js2-ASSIGN_BITXOR
                      js2-ASSIGN_DIV
                      js2-ASSIGN_LSH
                      js2-ASSIGN_MOD
                      js2-ASSIGN_MUL
                      js2-ASSIGN_RSH
                      js2-ASSIGN_SUB
                      js2-ASSIGN_URSH
                      js2-BLOCK
                      js2-BREAK
                      js2-CALL
                      js2-CATCH
                      js2-CATCH_SCOPE
                      js2-CONST
                      js2-CONTINUE
                      js2-DEBUGGER
                      js2-DEC
                      js2-DELPROP
                      js2-DEL_REF
                      js2-DO
                      js2-ELSE
                      js2-EMPTY
                      js2-ENTERWITH
                      js2-EXPORT
                      js2-EXPR_RESULT
                      js2-FINALLY
                      js2-FOR
                      js2-FUNCTION
                      js2-GOTO
                      js2-IF
                      js2-IFEQ
                      js2-IFNE
                      js2-IMPORT
                      js2-INC
                      js2-JSR
                      js2-LABEL
                      js2-LEAVEWITH
                      js2-LET
                      js2-LETEXPR
                      js2-LOCAL_BLOCK
                      js2-LOOP
                      js2-NEW
                      js2-REF_CALL
                      js2-RETHROW
                      js2-RETURN
                      js2-RETURN_RESULT
                      js2-SEMI
                      js2-SETELEM
                      js2-SETELEM_OP
                      js2-SETNAME
                      js2-SETPROP
                      js2-SETPROP_OP
                      js2-SETVAR
                      js2-SET_REF
                      js2-SET_REF_OP
                      js2-SWITCH
                      js2-TARGET
                      js2-THROW
                      js2-TRY
                      js2-VAR
                      js2-WHILE
                      js2-WITH
                      js2-WITHEXPR
                      js2-YIELD))
      (aset tokens tt t))
    (if js2-instanceof-has-side-effects
        (aset tokens js2-INSTANCEOF t))
    tokens))

(defun js2-node-has-side-effects (node)
  "Return t if NODE has side effects."
  (let ((tt (js2-node-type node))
        expr)
    (cond
     ;; This doubtless needs some work, since EXPR_VOID is used
     ;; in several ways in Rhino, and I may not have caught them all.
     ;; I'll wait for people to notice incorrect warnings.
     ((and (= tt js2-EXPR_VOID)
           (js2-expr-stmt-node-p node))  ; but not if EXPR_RESULT
      (if (setq expr (js2-expr-stmt-node-expr node))
          (js2-node-has-side-effects expr)
        t))
     ((= tt js2-COMMA)
      (if (setq expr (js2-infix-node-right node))
          (js2-node-has-side-effects expr)
        t))
     ((= tt js2-HOOK)
      (and (js2-node-has-side-effects (js2-cond-node-true-expr node))
           (js2-node-has-side-effects (js2-cond-node-false-expr node))))
     ((= tt js2-ERROR) ; avoid cascaded error messages
      nil)
     (t
      (aref js2-side-effecting-tokens tt)))))

(defun js2-expr-at-point (node-or-position)
  "Returns the outermost parent expression containing NODE-OR-POSITION.
NODE-OR-POSITION is a `js2-node' or subtype, or a buffer position."
  (let ((n (if (numberp node-or-position)
               (js2-node-at-point node-or-position)
             node-or-position)))
    (while (js2-expr-node-p (js2-node-parent n))
      (setq n (js2-node-parent n)))
    n))

(defun js2-member-expr-leftmost-name (node)
  "For an expr such as foo.bar.baz, return leftmost node foo.
NODE is any `js2-node' object.  If it represents a member expression,
which is any sequence of property gets, element-gets, function calls,
or xml descendants/filter operators, then we look at the lexically
leftmost (first) node in the chain.  If it is a name-node we return it.
Note that NODE can be a raw name-node and it will be returned as well.
If NODE is not a name-node or member expression, or if it is a member
expression whose leftmost target is not a name node, returns nil."
  (let ((continue t)
        result)
    (while (and continue (not result))
      (cond
       ((js2-name-node-p node)
        (setq result node))
       ((js2-prop-get-node-p node)
        (setq node (js2-prop-get-node-target node)))
       ;; TODO:  handle call-nodes, xml-nodes, others?
       (t
        (setq continue nil))))
    result))
      
(defalias #'js2-ancestor-expr #'js2-expr-at-point)

(provide 'js2-ast)

;;; js2-ast.el ends here