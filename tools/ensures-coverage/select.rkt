#lang racket/base
;; Selectors: which checked functions to report (design.md, 结论20).
;;
;; A selector is an S-expression, read with Racket's `read`
;; (see `read-selector` for how command-line text is taken):
;;
;;   "RX"                 the same as (module "RX")
;;   (module "RX")        `owning_module` matches RX
;;   (path "RX")          the VIR path (without `_VERUS_VERIFIED_`) matches RX
;;   (name "RX")          the name used in the report matches RX,
;;                        e.g. "^TlbFlusher<'a>::"
;;   (file "RX")          the source file, relative to the source root with
;;                        forward slashes, matches RX
;;   (lines "FILE" A B)   the function's source lines overlap lines A..B of FILE
;;   pub  exec  proof     visibility and mode
;;   all
;;   (and S ...)  (or S ...)  (not S)
;;
;; A function's source lines are those of the whole item as the source
;; parser sees it: attributes (including `#[verus_spec]`), signature,
;; specification and body.
(require racket/match racket/string racket/port
         "results.rkt")
(provide read-selector selector->string compile-selector)

;; read-selector : string -> selector
;; "@FILE" reads the selectors in FILE, one or more, combined with `or`; text
;; starting with `(` or `"`, and the words pub, exec, proof and all, are read
;; as one selector; any other text is a module regex.
(define (read-selector s)
  (define forms
    (cond
      [(string-prefix? s "@")
       (call-with-input-file (substring s 1) (lambda (in) (for/list ([x (in-port read in)]) x)))]
      [(or (regexp-match? #rx"^[(\"]" s) (member s '("pub" "exec" "proof" "all")))
       (list (with-input-from-string s read))]
      [else (list s)]))
  (define sel (match forms [(list x) x] [xs (cons 'or xs)]))
  (validate sel)
  sel)

(define (selector->string sel) (format "~s" sel))

(define (validate sel)
  (define (bad) (raise-user-error 'selector "not a selector: ~s" sel))
  (match sel
    [(? string?) (void)]
    [(list (or 'module 'path 'name 'file) (? string?)) (void)]
    [(list 'lines (? string?) (? exact-positive-integer?) (? exact-positive-integer?)) (void)]
    [(or 'pub 'exec 'proof 'all) (void)]
    [(list (or 'and 'or) xs ...) (for-each validate xs)]
    [(list 'not x) (validate x)]
    [_ (bad)]))

;; compile-selector : selector -> (fn -> boolean)
(define (compile-selector sel)
  (define (rx s) (pregexp s))
  (let loop ([sel sel])
    (match sel
      [(? string? s) (loop (list 'module s))]
      [(list 'module s) (let ([x (rx s)]) (lambda (r) (regexp-match? x (fn-module r))))]
      [(list 'path s) (let ([x (rx s)]) (lambda (r) (regexp-match? x (fn-path r))))]
      [(list 'name s) (let ([x (rx s)]) (lambda (r) (regexp-match? x (fn-name r))))]
      [(list 'file s)
       (let ([x (rx s)])
         (lambda (r) (and (fn-file r) (regexp-match? x (fn-file r)) #t)))]
      [(list 'lines f a b)
       (lambda (r)
         (and (equal? (fn-file r) f) (fn-start r) (<= (fn-start r) b) (>= (fn-end r) a)))]
      ['pub fn-public?]
      ['exec (lambda (r) (eq? (fn-mode r) 'exec))]
      ['proof (lambda (r) (eq? (fn-mode r) 'proof))]
      ['all (lambda (r) #t)]
      [(list 'and xs ...) (let ([ps (map loop xs)]) (lambda (r) (andmap (lambda (p) (p r)) ps)))]
      [(list 'or xs ...) (let ([ps (map loop xs)]) (lambda (r) (ormap (lambda (p) (p r)) ps)))]
      [(list 'not x) (let ([p (loop x)]) (lambda (r) (not (p r))))])))
