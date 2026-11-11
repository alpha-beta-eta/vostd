#lang racket/base
;; The results format (design.md, 结论22): compact S-expressions holding
;; only facts, one `fn` form per checked function.  check.rkt builds them,
;; main.rkt expands them into reports.  Nothing here depends on VIR.
;;
;;   (fn PATH MODE (name NAME [inferred]) (at FILE LINE) [(lines START END)]
;;       [(module MODULE)] [private] [external-body] [(trait DECL [missing])]
;;       [(post SOURCE ...)] [(outs N)] FINDING ...)
;;
;;   FINDING = (ret NAME TYPE FLAG ...) | (ret-part I NAME TYPE FLAG ...)
;;           | (mut NAME TYPE FLAG ...)
;;   FLAG    = ghost | (inv PATH) | default-only
(require racket/list racket/match racket/string)
(provide make-fn fn-with-source make-finding write-results read-results
         fn-path fn-mode fn-name fn-inferred? fn-file fn-line fn-start fn-end fn-module
         fn-public? fn-external-body? fn-trait fn-trait-found? fn-has-post? fn-own-post?
         fn-outputs fn-findings
         finding-kinds finding-kind finding-role finding-index finding-output finding-typ
         finding-ghost? finding-type-inv finding-default-only?
         typ->text short-path)

;; ================================================================ building

;; make-fn : ... -> fn form, in the canonical order, defaults omitted.
;;   post     list of 'own / 'decl
;;   findings list of FINDING forms (make-finding)
(define (make-fn path mode
                 #:name name #:inferred? [inferred? #f]
                 #:file [file #f] #:line [line #f] #:lines [lines #f]
                 #:module module
                 #:public? [public? #t] #:external-body? [external-body? #f]
                 #:trait [decl #f] #:trait-found? [found? #t]
                 #:post [post '()] #:outputs [outs 0] #:findings [findings '()])
  `(fn ,path ,mode
       (name ,name ,@(if inferred? '(inferred) '()))
       ,@(if file `((at ,file ,line)) '())
       ,@(if lines `((lines ,(car lines) ,(cdr lines))) '())
       ,@(if (equal? module (path-module path)) '() `((module ,module)))
       ,@(if public? '() '(private))
       ,@(if external-body? '(external-body) '())
       ,@(if decl `((trait ,decl ,@(if found? '() '(missing)))) '())
       ,@(if (null? post) '() `((post ,@post)))
       ,@(if (zero? outs) '() `((outs ,outs)))
       ,@findings))

;; fn-with-source : fn name-or-#f lines-or-#f -> fn
;; The name and lines from the source parser; without a name, the one in r
;; (inferred from VIR) is kept.
(define (fn-with-source r name lines)
  (make-fn (fn-path r) (fn-mode r)
           #:name (or name (fn-name r)) #:inferred? (not name)
           #:file (fn-file r) #:line (fn-line r) #:lines lines
           #:module (fn-module r)
           #:public? (fn-public? r) #:external-body? (fn-external-body? r)
           #:trait (fn-trait r) #:trait-found? (fn-trait-found? r)
           #:post (fn-post r) #:outputs (fn-outputs r) #:findings (fn-findings r)))

;; make-finding : role name index typ ghost? type-inv default-only? -> FINDING
;;   role  'return | 'return-component | 'mut-param
(define (make-finding role name index typ ghost? type-inv default-only?)
  (define flags
    (append (if ghost? '(ghost) '())
            (if type-inv `((inv ,type-inv)) '())
            (if default-only? '(default-only) '())))
  (match role
    ['return `(ret ,name ,typ ,@flags)]
    ['return-component `(ret-part ,index ,name ,typ ,@flags)]
    ['mut-param `(mut ,name ,typ ,@flags)]))

;; The last segment of a path: "a::b::Frame" -> "Frame".
(define (short-path p)
  (last (string-split (if (symbol? p) (symbol->string p) p) "::")))

;; "a::b::impl&%0::f" -> "a::b"; "a::b::f" -> "a::b"
(define (path-module path)
  (define segs (drop-right (string-split path "::") 1))
  (string-join (if (and (pair? segs) (string-prefix? (last segs) "impl&%")) (drop-right segs 1) segs)
               "::"))

;; ================================================================ files

;; write-results : out-path (listof vir-path) (listof fn) -> void
;; The `(vir ...)` form only records which VIR the results came from.
(define (write-results out vir fns)
  (with-output-to-file out #:exists 'replace
    (lambda ()
      (printf ";; ensures-coverage results, design.md 结论22\n")
      (write `(vir ,@vir)) (newline)
      (for ([r fns]) (write r) (newline)))))

;; read-results : path -> (values (listof fasl-path) (listof fn))
(define (read-results p)
  (define forms (call-with-input-file p (lambda (in) (for/list ([x (in-port read in)]) x))))
  (values (append* (for/list ([f forms] #:when (eq? (car f) 'vir)) (cdr f)))
          (filter (lambda (f) (eq? (car f) 'fn)) forms)))

;; ================================================================ fn

(define (fn-path r) (cadr r))
(define (fn-mode r) (caddr r))
(define (fields r) (cdddr r))
(define (tagged r tag)
  (for/first ([x (fields r)] #:when (and (pair? x) (eq? (car x) tag))) (cdr x)))
(define (flag? r s) (and (memq s (fields r)) #t))

(define (fn-name r) (car (tagged r 'name)))
(define (fn-inferred? r) (and (memq 'inferred (tagged r 'name)) #t))
(define (fn-file r) (let ([a (tagged r 'at)]) (and a (car a))))
(define (fn-line r) (let ([a (tagged r 'at)]) (and a (cadr a))))
(define (fn-start r) (let ([l (tagged r 'lines)]) (and l (car l))))
(define (fn-end r) (let ([l (tagged r 'lines)]) (and l (cadr l))))
(define (fn-module r) (let ([m (tagged r 'module)]) (if m (car m) (path-module (fn-path r)))))
(define (fn-public? r) (not (flag? r 'private)))
(define (fn-external-body? r) (flag? r 'external-body))
(define (fn-trait r) (let ([t (tagged r 'trait)]) (and t (car t))))
(define (fn-trait-found? r) (let ([t (tagged r 'trait)]) (not (and t (memq 'missing t)))))
(define (fn-post r) (or (tagged r 'post) '()))
(define (fn-has-post? r) (pair? (fn-post r)))
(define (fn-own-post? r) (and (memq 'own (fn-post r)) #t))
(define (fn-outputs r) (let ([n (tagged r 'outs)]) (if n (car n) 0)))
(define (fn-findings r)
  (filter (lambda (x) (and (pair? x) (memq (car x) '(ret ret-part mut)))) (fields r)))

;; ================================================================ findings

(define finding-kinds '(return-unmentioned mut-param-unmentioned))

(define (finding-role fi)
  (match (car fi) ['ret 'return] ['ret-part 'return-component] ['mut 'mut-param]))
(define (finding-kind fi)
  (if (eq? (car fi) 'mut) 'mut-param-unmentioned 'return-unmentioned))
;; (index name typ flag ...) for every role
(define (finding-parts fi) (if (eq? (car fi) 'ret-part) (cdr fi) (cons #f (cdr fi))))
(define (finding-index fi) (car (finding-parts fi)))
(define (finding-output fi) (cadr (finding-parts fi)))
(define (finding-typ fi) (caddr (finding-parts fi)))
(define (finding-flags fi) (cdddr (finding-parts fi)))
(define (finding-ghost? fi) (and (memq 'ghost (finding-flags fi)) #t))
(define (finding-type-inv fi)
  (for/first ([x (finding-flags fi)] #:when (and (pair? x) (eq? (car x) 'inv))) (cadr x)))
(define (finding-default-only? fi) (and (memq 'default-only (finding-flags fi)) #t))

;; ================================================================ types

;; typ->text : compact type -> Rust-like string
(define (typ->text t)
  (define (args ts) (if (null? ts) "" (format "<~a>" (string-join (map typ->text ts) ", "))))
  (match t
    [(? symbol?) (symbol->string t)]
    [(list '& x) (string-append "&" (typ->text x))]
    [(list '&mut x) (string-append "&mut " (typ->text x))]
    [(list 'tuple ts ...) (format "(~a)" (string-join (map typ->text ts) ", "))]
    [(list 'slice x) (format "[~a]" (typ->text x))]
    [(list 'as self trait name) (format "<~a as ~a>::~a" (typ->text self) (typ->text trait) name)]
    [(list name ts ...) (string-append (symbol->string name) (args ts))]))
