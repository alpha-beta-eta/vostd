#lang racket/base
;; Function names for reports, and the source lines of each function for
;; selectors, from the source parser item-index (built on the Verus fork of
;; syn).  See design.md, 结论21.
;;
;; A VIR function is matched to the parsed function in the same file with
;; the same name whose line range contains the first line of the VIR span.
(require racket/list racket/string racket/match racket/system racket/port)
(provide load-item-index parser-source)

;; load-item-index : exe root (listof (cons file line)) -> index
;; Only the files that the given locations point into are parsed.  Files
;; that cannot be found under root, and the parser's own complaints, are
;; reported on stderr: otherwise their functions would silently keep the
;; names inferred from VIR (结论24).
(define (load-item-index exe root locs)
  (unless (file-exists? exe)
    (raise-user-error 'check "item-index not found: ~a (build it first, see README)" exe))
  (define-values (relative absolute) (partition relative-path? (remove-duplicates (map car locs))))
  (define-values (files missing)
    (partition (lambda (f) (file-exists? (build-path root f))) relative))
  (warn-files absolute "are named by absolute paths in the VIR (export the VIR from within the source root, so that the paths are relative to it)")
  (warn-files missing (format "are not found under ~a (is it the source root the VIR was exported from?)" root))
  (define out
    (apply string-append (for/list ([b (batches files)]) (run-item-index exe root b))))
  (define idx (make-hash))
  (for ([it (with-input-from-string out (lambda () (for/list ([x (in-port read)]) x)))])
    (hash-update! idx (cons (get it 'file) (get it 'name)) (lambda (l) (cons it l)) '()))
  idx)

(define (warn-files files why)
  (unless (null? files)
    (eprintf "warning: ~a source file(s) ~a; their functions keep the names inferred from VIR and have no source lines, e.g. ~a\n"
             (length files) why (car files))))

;; Batches of files whose command line stays well below the 32767
;; characters that Windows allows.
(define (batches files [limit 16000])
  (let loop ([fs files] [cur '()] [len 0] [acc '()])
    (define (flush) (if (null? cur) acc (cons (reverse cur) acc)))
    (cond [(null? fs) (reverse (flush))]
          [(and (pair? cur) (> (+ len (string-length (car fs)) 3) limit))
           (loop fs '() 0 (flush))]
          [else (loop (cdr fs) (cons (car fs) cur) (+ len (string-length (car fs)) 3) acc)])))

;; The parser's stderr (files it cannot read or parse) is passed on as warnings.
(define (run-item-index exe root files)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-directory root] [current-output-port out] [current-error-port err])
      (apply system* exe files)))
  (for ([l (in-lines (open-input-string (get-output-string err)))])
    (eprintf "warning: item-index: ~a\n" l))
  (unless ok? (raise-user-error 'check "item-index failed: ~a" exe))
  (get-output-string out))

(define (get it k) (cadr (assq k (cdr it))))

;; parser-source : index (cons file line) full-name -> (values name lines)
;;   full-name  the VIR path without the `_VERUS_VERIFIED_` prefix; its last
;;              segment is the source name
;;   name       the name for reports, or #f when the parser has no such function
;;   lines      (cons start end) of the whole item: attributes, signature,
;;              specification, body; or #f
(define (parser-source idx loc full-name)
  (match (regexp-match #rx"^(.*)::([^:]+)$" full-name)
    [(list _ prefix fname)
     (define it
       (for/first ([it (hash-ref idx (cons (car loc) fname) '())]
                   #:when (<= (get it 'start) (cdr loc) (get it 'end)))
         it))
     (if it
         (values (let ([name (get it 'name)])
                   (cond
                     [(and (get it 'self) (get it 'trait)) (format "<~a as ~a>::~a" (get it 'self) (get it 'trait) name)]
                     [(get it 'self) (format "~a::~a" (get it 'self) name)]
                     [(get it 'in-trait) (format "~a::~a" (get it 'in-trait) name)]
                     [else (format "~a::~a" prefix name)]))
                 (cons (get it 'start) (get it 'end)))
         (values #f #f))]
    [_ (values #f #f)]))
