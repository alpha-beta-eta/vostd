#lang racket/base
;; usage: racket contrib/pr-functions.rkt <head.results> <worktree> <base> <out.results> [<base.results>]
;;
;; Writes the results of only the functions a PR's changes involve, each
;; `fn` form followed by a comment naming why it is there; `racket main.rkt
;; report <out.results> <out.md> all` expands it.  The choice of functions is
;; the reviewer's, made outside the tool (design.md, 结论19); this is a
;; mechanical choice, also meant for CI:
;;   changed   the function's whole item (attributes, spec, signature, body)
;;             in HEAD overlaps a hunk of `git diff BASE...HEAD`
;;   decl      a trait method implementation whose declaration is changed:
;;             its postcondition comes from the declaration (结论13), so a
;;             change there changes its results although its own lines may
;;             be untouched
;;   new       only with <base.results>: the function is in the head results
;;             but not in the base results, compared by module and report
;;             name; e.g. existing code the PR moved into `verus! {}`
;; <head.results> must come from the checkout of HEAD in <worktree>; in CI
;; that is the PR's merge commit and BASE the target branch's commit.
;;
;; A function without source lines (named from VIR, design.md 注意9) is
;; matched by its VIR line alone.  On stdout: the counts, and how many
;; functions were matched so.
(require racket/list racket/string racket/system racket/port racket/match
         "../results.rkt")

(define-values (head-path worktree base out base-path)
  (match (vector->list (current-command-line-arguments))
    [(list h w b o) (values h w b o #f)]
    [(list h w b o bp) (values h w b o bp)]
    [_ (eprintf "usage: racket contrib/pr-functions.rkt <head.results> <worktree> <base> <out.results> [<base.results>]\n")
       (exit 2)]))

;; file -> list of (first . last), the new-side lines of each hunk; a pure
;; deletion after line n is (n+1 . n), overlapping items that contain both
(define changes
  (let ([diff (parameterize ([current-directory worktree])
                (with-output-to-string
                  (lambda () (system* (find-executable-path "git") "diff" "-U0" "--no-color"
                                      (string-append base "...HEAD") "--" "*.rs"))))]
        [h (make-hash)])
    (for/fold ([file #f]) ([line (string-split diff "\n")])
      (cond
        [(regexp-match #rx"^[+][+][+] b/(.*)$" line) => cadr]
        [(string-prefix? line "+++ ") #f]
        [(and file (regexp-match #px"^@@ [^+]*[+]([0-9]+)(?:,([0-9]+))? @@" line))
         => (lambda (m)
              (define start (string->number (cadr m)))
              (define n (if (caddr m) (string->number (caddr m)) 1))
              (hash-update! h file (lambda (l) (cons (if (= n 0) (cons (add1 start) start)
                                                         (cons start (+ start n -1)))
                                                     l))
                            '())
              file)]
        [else file]))
    h))

(define-values (vir head) (read-results head-path))

;; A function without source lines (named from VIR, 注意9) is matched by the
;; line VIR gives it instead, e.g. the `#[derive(Clone)]` of a derived impl.
(define (changed? r)
  (define-values (a b)
    (if (fn-start r) (values (fn-start r) (fn-end r)) (values (fn-line r) (fn-line r))))
  (and (fn-file r) a
       (for/or ([c (hash-ref changes (fn-file r) '())])
         (and (<= a (cdr c)) (>= b (car c))))))

(define changed-paths (for/hash ([r head] #:when (changed? r)) (values (fn-path r) #t)))
(define (decl? r) (and (fn-trait r) (hash-ref changed-paths (fn-trait r) #f)))

(define (key r) (cons (fn-module r) (fn-name r)))
(define old
  (and base-path
       (let-values ([(_ base-fns) (read-results base-path)])
         (for/hash ([r base-fns]) (values (key r) #t)))))
(define (new? r) (and old (not (hash-ref old (key r) #f))))

(define (reasons r)
  (filter values (list (and (changed? r) "changed") (and (decl? r) "decl") (and (new? r) "new"))))

(define picked (for/list ([r head] #:when (pair? (reasons r))) (cons r (reasons r))))

(with-output-to-file out #:exists 'replace
  (lambda ()
    (printf ";; ensures-coverage results, design.md 结论22: only the functions involved in\n")
    (printf ";; the changes since ~a (pr-functions.rkt); the comment after each is why\n" base)
    (write `(vir ,@vir)) (newline)
    (for ([p picked])
      (write (car p))
      (printf " ; ~a\n" (string-join (cdr p) "+")))))

(define (only tag) (count (lambda (p) (equal? (cdr p) (list tag))) picked))
(printf "~a functions: ~a changed, ~a only by decl, ~a only new~a\n"
        (length picked) (count (lambda (p) (member "changed" (cdr p))) picked)
        (only "decl") (only "new") (if old "" " (no base results given)"))
(define by-vir-line (filter (lambda (p) (and (member "changed" (cdr p)) (not (fn-start (car p))))) picked))
(unless (null? by-vir-line)
  (printf "~a of them changed by their VIR line only, having no source lines (注意9)\n"
          (length by-vir-line)))
