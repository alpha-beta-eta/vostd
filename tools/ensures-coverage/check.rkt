#lang racket/base
;; ensures-coverage: does the postcondition mention every output?
;;
;; The design is design.md; "结论N" below refers to its conclusions.  This
;; module only computes results as data (results.rkt); all wording is in
;; main.rkt.
;;
;; For each checked function the outputs are its return value (each
;; component separately for a `#[verus_spec]` return tuple) and its `&mut`
;; parameters (结论6).  An output is reported when the postcondition never
;; mentions it:
;;   - a return value is mentioned when its name occurs anywhere, or there is
;;     a `returns` clause (结论8);
;;   - a `&mut` parameter x is mentioned when x occurs anywhere inside some
;;     `final(...)` (结论9).
(require racket/list racket/match racket/string racket/set
         "vir.rkt" (only-in "results.rkt" make-fn make-finding typ->text short-path))
(provide run-check vir-format-warnings)

;; ================================================================ VIR helpers

;; The raw VIR path, with namespace prefixes (vir.rkt, path->text): only for
;; looking functions up.  Results and reports use display-name.
(define (fn-path f) (symbol->string (field (field f 'name) 'path)))

(define verified-prefix "_VERUS_VERIFIED_")

(define (display-name f) (string-replace (path->text (fn-path f)) verified-prefix ""))

;; The last segment of a VIR path, without its namespace prefix: "Frame".
(define (short-name p) (short-path (path->text p)))

(define (fn-kind f)
  (match (field f 'kind) [(list 'FunctionKind k _ ...) k] [k k]))

(define (kind-field f name)
  (match (field f 'kind)
    [(list 'FunctionKind _ rest ...) (field (cons 'FunctionKind rest) name)]
    [_ #f]))

(define (attr f name) (eq? (field (field f 'attrs) name) 'true))

(define (public? f) (eq? (field (field f 'visibility) 'restricted_to) 'None))

(define (owning-module f) (path->text (field f 'owning_module)))

;; :ensure is (tuple <ensures> <default_ensures>) (结论15).
(define (ensures f)
  (match (field f 'ensure) [(list 'tuple a _) a] [_ '()]))
(define (default-ensures f)
  (match (field f 'ensure) [(list 'tuple _ b) b] [_ '()]))

(define (returns? f) (not (eq? (field f 'returns) 'None)))

(define (var-name v) (match v [(list 'VarIdent (? string? s) _ ...) s] [_ #f]))

;; The name VIR gives a return value that the spec leaves unnamed (结论8):
;; `%return` until Verus 0.2026.11.08, `return%` since (verus 942817445).
(define unnamed-return-names '("%return" "return%"))

;; '() when the field is missing, so that vir-format-warnings can report it
(define (params f) (let ([ps (field f 'params)]) (if (list? ps) (map unwrap ps) '())))

;; Peel `Decorate` wrappers; report whether a Tracked or Ghost decoration was seen.
(define (peel-typ t [ghost? #f])
  (match t
    [(list 'Typ 'Decorate (list 'TypDecoration d) _ inner)
     (peel-typ inner (or ghost? (memq d '(Tracked Ghost)) #f))]
    [_ (values t (and ghost? #t))]))

;; 结论7: the outermost type, after peeling decorations, is `&mut`.
(define (mut-ref? t)
  (let-values ([(t _) (peel-typ t)]) (match t [(list 'Typ 'MutRef _) #t] [_ #f])))

(define (unit-typ? t)
  (match t [(list 'Typ 'Datatype (list 'Dt 'Tuple 0) _ ...) #t] [_ #f]))

;; 结论17: the datatype path of the outermost type, after peeling
;; decorations and `&mut`.
(define (typ-dt-path t)
  (let-values ([(t _) (peel-typ t)])
    (match t
      [(list 'Typ 'MutRef inner) (typ-dt-path inner)]
      [(list 'Typ 'Datatype (list 'Dt 'Path p) _ ...) p]
      [_ #f])))

;; typ->sexp : VIR type -> compact type (结论22)
(define (typ->sexp t)
  (define (dt name ts) (if (null? ts) name (cons name (map typ->sexp ts))))
  (define (sym x) (string->symbol (format "~a" x)))
  (match t
    [(list 'Typ 'Bool) 'bool]
    [(list 'Typ 'Int (list 'IntRange 'USize)) 'usize]
    [(list 'Typ 'Int (list 'IntRange 'ISize)) 'isize]
    [(list 'Typ 'Int (list 'IntRange 'U n)) (sym (format "u~a" n))]
    [(list 'Typ 'Int (list 'IntRange 'I n)) (sym (format "i~a" n))]
    [(list 'Typ 'Int (list 'IntRange r)) (sym (string-downcase (format "~a" r)))]
    [(list 'Typ 'Int r) (sym r)]
    ;; VIR names the implicit Self type parameter `Self%`
    [(list 'Typ 'TypParam (? string? s)) (sym (string-replace s "Self%" "Self"))]
    [(list 'Typ 'MutRef inner) (list '&mut (typ->sexp inner))]
    [(list 'Typ 'Decorate (list 'TypDecoration 'Ref) _ inner) (list '& (typ->sexp inner))]
    [(list 'Typ 'Decorate (list 'TypDecoration d) _ inner) (list d (typ->sexp inner))]
    [(list 'Typ 'Datatype (list 'Dt 'Tuple 0) _ ...) '(tuple)]
    [(list 'Typ 'Datatype (list 'Dt 'Tuple _) ts _ ...) (cons 'tuple (map typ->sexp ts))]
    [(list 'Typ 'Datatype (list 'Dt 'Path p) ts _ ...) (dt (sym (short-name p)) ts)]
    ;; <Self as Trait<Args>>::Name ; trait_typ_args = (Self Args ...)
    [(list 'Typ 'Projection _ ...)
     (define targs (or (field (cdr t) 'trait_typ_args) '()))
     (list 'as
           (if (pair? targs) (typ->sexp (car targs)) '?)
           (dt (sym (short-name (or (field (cdr t) 'trait_path) "?"))) (if (pair? targs) (cdr targs) '()))
           (let ([n (field (cdr t) 'name)]) (if n (sym n) '?)))]
    [(list 'Typ 'Primitive (list 'Primitive 'Slice) (list t0) _ ...) (list 'slice (typ->sexp t0))]
    [(list 'Typ 'Primitive (list 'Primitive 'StrSlice) _ ...) 'str]
    [(list 'Typ 'Primitive (list 'Primitive kind) ts _ ...) (dt kind (if (list? ts) ts '()))]
    [_ '?]))

;; readable-name : function -> string
;; The name inferred from VIR, kept when the source parser does not find
;; the function (结论21): "VmReader::has_remain",
;; "<PageTableGuard as Deref>::deref", or the full path.
(define (readable-name f)
  (define path (display-name f))
  (define method (short-path path))
  (define (self-type)
    (for/or ([p (params f)] #:when (equal? (var-name (field p 'name)) "self"))
      (typ-dt-path (field p 'typ))))
  (define (ret-self-type)
    ;; constructors: the return type, or the `T` in Result<T, _> / Option<T>
    (define r (field f 'outer_ret))
    (and r
         (let loop ([t (let-values ([(t _) (peel-typ (field (unwrap r) 'typ))]) t)])
           (match t
             ;; `#[verus_spec]` packs (exec return, ghost returns) into a tuple
             [(list 'Typ 'Datatype (list 'Dt 'Tuple _) (cons a _) _ ...)
              (loop (let-values ([(a _) (peel-typ a)]) a))]
             [(list 'Typ 'Datatype (list 'Dt 'Path
                                         (? (lambda (p) (member (path->text p) '("core::result::Result" "core::option::Option")))))
                    (cons a _) _ ...)
              (typ-dt-path a)]
             [_ (typ-dt-path t)]))))
  (cond
    [(eq? (fn-kind f) 'TraitMethodImpl)
     (define self (match (kind-field f 'trait_typ_args)
                    [(cons t _) (typ->text (typ->sexp t))] [_ "?"]))
     (format "<~a as ~a>::~a" self (short-name (kind-field f 'trait_path)) method)]
    [(regexp-match? #rx"::impl&%[^:]*::" path)
     (define ty (or (self-type) (ret-self-type)))
     (if ty (format "~a::~a" (short-name ty) method) path)]
    [else path]))

;; ================================================================ selection

;; 结论3: a trait default method that an implementation does not override.
;; Verus emits a copy per implementation, with `:inherit_body_from` naming
;; the trait method.
(define (inherited-default? f)
  (match (kind-field f 'inherit_body_from)
    [(list 'Fun _ ...) #t]
    [_ #f]))

;; 结论1, 2, 3: exec and proof functions that `keep?` accepts and that are
;; not inherited default methods.  When `#[verus_spec]` produced a
;; `_VERUS_VERIFIED_` twin, keep only the twin.
(define (select-functions fns keep?)
  (define in-scope
    (filter (lambda (f)
              (and (memq (field f 'mode) '(Exec Proof))
                   (not (inherited-default? f))
                   (keep? f)))
            fns))
  (define twins
    (for/set ([f in-scope] #:when (string-contains? (fn-path f) verified-prefix))
      (display-name f)))
  (filter (lambda (f)
            (or (string-contains? (fn-path f) verified-prefix)
                (not (set-member? twins (display-name f)))))
          in-scope))

;; ================================================================ outputs

(define (ret-param f) (let ([r (field f 'outer_ret)]) (and r (unwrap r))))
(define (ret-var f) (let ([p (ret-param f)]) (and p (field p 'name))))

(define (exec-mode? p) (eq? (field p 'mode) 'Exec))

;; 结论6.  Return components: a list of (index ghost? typ) for a
;; `#[verus_spec]` return tuple, or a single (#f ghost? typ) for an ordinary
;; return; '() for unit.
(define (return-components f)
  (define p (ret-param f))
  (cond
    [(not p) '()]
    [else
     (define-values (t g) (peel-typ (field p 'typ)))
     (define ghost? (or g (not (exec-mode? p))))
     (match t
       [_ #:when (unit-typ? t) '()]
       [(list 'Typ 'Datatype (list 'Dt 'Tuple _) comps _ ...)
        #:when (equal? (var-name (field p 'name)) "_VERUS_ret_ident")
        (for/list ([c comps] [i (in-naturals)]
                   #:unless (unit-typ? (let-values ([(ct _) (peel-typ c)]) ct)))
          (let-values ([(_ cg) (peel-typ c)])
            (list i (or cg (not (exec-mode? p))) c)))]
       [_ (list (list #f ghost? (field p 'typ)))])]))

(define (mut-params f) (filter (lambda (p) (mut-ref? (field p 'typ))) (params f)))

(define (param-ghost? p)
  (define-values (_ g) (peel-typ (field p 'typ)))
  (or g (not (exec-mode? p))))

;; ================================================================ scanning

;; scan : exprs ret-var -> (values uses bindings)
;;   uses     : list of (VarIdent in-final?) for every variable read;
;;              in-final? is #t anywhere inside `final(...)` (结论9)
;;   bindings : list of (index VarIdent): the names a `#[verus_spec]`
;;              postcondition gives the return components, from a `let`
;;              whose initialiser is the return variable (结论8)
;; Variables are compared as whole VarIdents (结论11).
(define (scan exprs rv)
  (define uses '())
  (define bindings '())
  (define (tuple-bindings p)
    ;; (Pattern Constructor (Dt Tuple n) "tuple%n" ((-> i <pat>) ...))
    (match (unwrap p)
      [(list 'Pattern 'Constructor (list 'Dt 'Tuple _) _ fields)
       (for ([fld fields])
         (match fld
           [(list '-> i sub)
            (match (unwrap sub)
              [(list 'Pattern 'Var b) (set! bindings (cons (list i (field b 'name)) bindings))]
              [_ (void)])]
           [_ (void)]))]
      [_ (void)]))
  (let walk ([n exprs] [in-final? #f])
    (when (pair? n)
      (match n
        ;; A variable is read either through a place or, in specs Verus
        ;; generates (e.g. derived `Clone`), as a plain `Var` expression.
        [(list 'Place 'Local v) (set! uses (cons (list v in-final?) uses))]
        [(list '> 'Var v) (set! uses (cons (list v in-final?) uses))]
        ;; `final(e)` (and the builtin `mut_ref_future(e)`)
        [(list '> 'Unary (list 'UnaryOp 'MutRefFuture _) e _ ...) (walk e #t)]
        [(list 'Stmt 'Decl _ ...)
         (when (and rv (match (unwrap (field n 'init))
                         [(list 'Place 'Local v) (equal? v rv)]
                         [_ #f]))
           (tuple-bindings (field n 'pattern)))
         (for ([c (in-list n)]) (walk c in-final?))]
        [_ (for ([c (in-list (if (list? n) n '()))]) (walk c in-final?))])))
  (values uses bindings))

;; What a set of clauses mentions.
;;   ret?       : the return variable is read
;;   component? : index -> the binding of that component is read
;;   final?     : VarIdent -> read inside `final(...)`
(struct mentions (ret? component? final?))

(define (mentions-of uses bindings rv)
  (define (used? v) (for/or ([u uses]) (equal? (car u) v)))
  (mentions (and rv (used? rv))
            (lambda (i) (for/or ([b bindings]) (and (= (car b) i) (used? (cadr b)))))
            (lambda (x) (for/or ([u uses]) (and (equal? (car u) x) (cadr u))))))

;; The declaration's clauses, with its parameter and return names renamed,
;; by position, to the implementation's (结论13).
(define (renamed-uses decl f)
  (define rename (for/hash ([dp (params decl)] [ip (params f)])
                   (values (field dp 'name) (field ip 'name))))
  (define drv (ret-var decl))
  (define-values (us bs) (scan (ensures decl) drv))
  (values (for/list ([u us])
            (define v (car u))
            (cons (cond [(hash-ref rename v #f)]
                        [(and drv (equal? v drv)) (ret-var f)]
                        [else v])
                  (cdr u)))
          bs))

;; ================================================================ check

;; check-function : function decl-or-#f type-inv-of -> (values post outputs findings)
;;   post      where the caller's postcondition clauses come from: a list of
;;             'own and 'decl, empty when there are none (结论12)
;;   findings  FINDING forms (结论22)
;; decl: for a trait method implementation, the trait's declaration of the
;; method.  Its `ensures` and `returns` are inherited; its `default_ensures`
;; are not (结论13).
(define (check-function f decl type-inv-of)
  (define rv (ret-var f))
  ;; regular clauses: own `ensures`, plus the declaration's
  (define-values (own-uses own-bindings) (scan (ensures f) rv))
  (define-values (decl-uses decl-bindings)
    (if decl (renamed-uses decl f) (values '() '())))
  (define reg (mentions-of (append own-uses decl-uses) (append own-bindings decl-bindings) rv))
  ;; `default_ensures`: only on a declaration itself (结论15)
  (define-values (def-uses def-bindings) (scan (default-ensures f) rv))
  (define def (mentions-of def-uses def-bindings rv))
  (define has-returns? (or (returns? f) (and decl (returns? decl))))
  (define post
    (append (if (or (pair? (ensures f)) (returns? f)) '(own) '())
            (if (and decl (or (pair? (ensures decl)) (returns? decl))) '(decl) '())))
  (define (inv-of t) (let ([p (type-inv-of t)]) (and p (path->text p))))
  ;; return values (结论8); `returns` mentions only the exec return
  (define (ret-mentioned? m rc)
    (match rc
      [(list #f _ _) (mentions-ret? m)]
      [(list i _ _) ((mentions-component? m) i)]))
  (define return-findings
    (for/list ([rc (return-components f)]
               #:unless (or (ret-mentioned? reg rc)
                            (and has-returns? (memv (car rc) '(#f 0)))))
      (match-define (list i ghost? t) rc)
      (define name
        (if i
            (for/or ([b (append own-bindings decl-bindings def-bindings)])
              (and (= (car b) i) (var-name (cadr b))))
            ;; an unnamed return has no name for the report
            (and rv (let ([n (var-name rv)]) (and n (not (member n unnamed-return-names)) n)))))
      (make-finding (if i 'return-component 'return) name i (typ->sexp t) ghost?
                    (inv-of t) (ret-mentioned? def rc))))
  ;; `&mut` parameters (结论7, 9)
  (define param-findings
    (for/list ([p (mut-params f)]
               #:unless ((mentions-final? reg) (field p 'name)))
      (make-finding 'mut-param (var-name (field p 'name)) #f
                    (typ->sexp (let-values ([(t _) (peel-typ (field p 'typ))]) t))
                    (param-ghost? p) (inv-of (field p 'typ))
                    ((mentions-final? def) (field p 'name)))))
  (values post
          (+ (length (return-components f)) (length (mut-params f)))
          (append return-findings param-findings)))

;; ================================================================ VIR format

;; vir-format-warnings : items -> (listof string)
;; The check matches VIR by node and field names, which Verus does not keep
;; stable; when a name changes the check does not fail but gives wrong
;; results.  These are names it depends on that any real crate exercises, so
;; a missing one most likely means the VIR format has changed (结论24).
(define (vir-format-warnings items)
  (define fns (map car (function-spans items)))
  (define dts (for*/list ([i items] [d (in-value (unwrap i))]
                          #:when (and (pair? d) (eq? (car d) 'Datatype)))
                d))
  (define impls (filter (lambda (f) (eq? (fn-kind f) 'TraitMethodImpl)) fns))
  (define (none-has? xs get) (and (pair? xs) (not (ormap get xs))))
  (define (mut-ensured? f) (and (pair? (mut-params f)) (pair? (ensures f))))
  (define (final-in? f) (memq 'MutRefFuture (flatten (ensures f))))
  (define (missing what) (format "~a; the VIR format may have changed" what))
  (define all-params (append-map params fns))
  (cond
    [(null? fns) (list (missing "no Function nodes"))]
    [else
     (append
      (for/list ([k '(name mode kind params outer_ret ensure returns visibility owning_module attrs)]
                 #:when (none-has? fns (lambda (f) (field f k))))
        (missing (format "no Function node has a `:~a` field" k)))
      (for/list ([k '(name typ mode)]
                 #:when (none-has? all-params (lambda (p) (field p k))))
        (missing (format "no function parameter has a `:~a` field" k)))
      (for/list ([k '(method trait_path trait_typ_args)]
                 #:when (none-has? impls (lambda (f) (kind-field f k))))
        (missing (format "no TraitMethodImpl kind has `:~a` (结论13, 14)" k)))
      (if (ormap (lambda (f) (match (field f 'ensure) [(list 'tuple _ _) #t] [_ #f])) fns)
          '()
          (list (missing "no `:ensure` is (tuple <ensures> <default_ensures>) (结论15)")))
      (if (and (ormap mut-ensured? fns) (not (ormap final-in? fns)))
          (list (missing "no ensures contains `MutRefFuture` (final(...), 结论9), although some functions have `&mut` parameters and ensures"))
          '())
      (if (none-has? (filter ret-param fns)
                     (lambda (f) (member (var-name (ret-var f)) unnamed-return-names)))
          (list (missing (format "no return value is named ~a (an unnamed return, 结论8)"
                                 (string-join unnamed-return-names " or "))))
          '())
      ;; path segments still carrying a namespace mark after path->text
      (let ([odd (for*/first ([f fns]
                              [seg (string-split (owning-module f) "::")]
                              #:when (regexp-match? #rx"%" seg))
                   seg)])
        (if odd
            (list (missing (format "a module path has the unknown segment `~a` (vir.rkt, path->text)" odd)))
            '()))
      (if (none-has? impls (lambda (f) (kind-field f 'inherit_body_from)))
          (list (missing "no TraitMethodImpl kind has `:inherit_body_from` (结论3)"))
          '())
      (if (none-has? dts (lambda (d) (field d 'user_defined_invariant_fn)))
          (list (missing "no Datatype node has `:user_defined_invariant_fn` (结论17)"))
          '()))]))

;; ================================================================ driver

;; function-spans : items -> (listof (cons function span-string))
;; Top-level items are (@ "<span>" (Function ...)).
(define (function-spans items)
  (for/list ([i items] #:when (match (unwrap i) [(cons 'Function _) #t] [_ #f]))
    (cons (unwrap i) (if (and (pair? i) (eq? (car i) '@)) (cadr i) ""))))

;; run-check : (listof items) -> (listof fn)
;; Every function, from the top-level items of one or more VIR dumps, one
;; per crate.  A crate's VIR also holds the pub functions it uses from its
;; dependencies, so a function is checked only in a dump where its crate has
;; non-pub functions, and of those in the one with the most functions of its
;; crate (结论18).
(define (run-check dumps)
  (define (crate-of f) (car (string-split (owning-module f) "::")))
  ;; per dump: crate -> (cons functions non-pub-functions)
  (define counts
    (for/list ([items dumps])
      (for/fold ([h (hash)]) ([fs (function-spans items)])
        (define f (car fs))
        (hash-update h (crate-of f)
                     (lambda (c) (cons (add1 (car c)) (if (public? f) (cdr c) (add1 (cdr c)))))
                     (cons 0 0)))))
  (define (owner crate)
    (define (count-in i) (hash-ref (list-ref counts i) crate (cons 0 0)))
    (define owning (filter (lambda (i) (> (cdr (count-in i)) 0)) (range (length dumps))))
    (and (pair? owning) (argmax (lambda (i) (car (count-in i))) owning)))
  (append* (for/list ([items dumps] [i (in-naturals)])
             (check-dump items (lambda (f) (eqv? (owner (crate-of f)) i))))))

;; check-dump : items keep? -> (listof fn)
;;   keep?  function -> boolean: the function belongs to this dump
(define (check-dump items keep?)
  (define spans (make-hasheq))
  ;; datatype path -> type invariant function path (结论17)
  (define type-invs
    (for*/hash ([i items]
                [d (in-value (unwrap i))]
                #:when (and (pair? d) (eq? (car d) 'Datatype))
                [inv (in-value (field d 'user_defined_invariant_fn))]
                #:unless (eq? inv 'None))
      (values (match (field d 'name) [(list 'Dt 'Path p) p] [x x])
              (field (field inv 'fun) 'path))))
  (define (type-inv-of t)
    (define p (typ-dt-path t))
    (and p (hash-ref type-invs p #f)))
  (define fns
    (for/list ([fs (function-spans items)])
      (hash-set! spans (car fs) (cdr fs))
      (car fs)))
  (define by-path (for/hash ([f fns]) (values (fn-path f) f)))
  (define targets (select-functions fns keep?))
  ;; 结论14: the declaration, preferring its `_VERUS_VERIFIED_` twin
  (define (trait-decl f)
    (define m (symbol->string (field (kind-field f 'method) 'path)))
    (define twin (regexp-replace #rx"::([^:]+)$" m (string-append "::" verified-prefix "\\1")))
    (values (string-replace (path->text m) verified-prefix "")
            (or (hash-ref by-path twin #f) (hash-ref by-path m #f))))
  (for/list ([f targets])
    (define impl? (eq? (fn-kind f) 'TraitMethodImpl))
    (define-values (method decl) (if impl? (trait-decl f) (values #f #f)))
    (define-values (post n-outputs findings) (check-function f decl type-inv-of))
    (define at (span-file+line (hash-ref spans f "")))
    ;; the name is the one inferred from VIR until main.rkt asks the parser
    (make-fn (display-name f) (if (eq? (field f 'mode) 'Proof) 'proof 'exec)
             #:name (readable-name f) #:inferred? #t
             #:file (and at (car at)) #:line (and at (cdr at))
             #:module (owning-module f)
             #:public? (public? f) #:external-body? (attr f 'is_external_body)
             #:trait method #:trait-found? (and decl #t)
             #:post post #:outputs n-outputs #:findings findings)))
