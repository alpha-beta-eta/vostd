#lang racket/base
;; Command line (README.md):
;;   racket main.rkt check <vir>[,<vir>...] <out.results> <src-root> [<item-index>]
;;       check every function and write the results (design.md, 结论22);
;;       each <vir> is a crate.vir or a cache made by `cache`, one per crate;
;;       <src-root> is the checkout the VIR was exported from
;;   racket main.rkt report <in.results> <out.md> <selector>
;;       expand the results into the report (结论23) on the functions
;;       <selector> picks (select.rkt, 结论20)
;;   racket main.rkt cache <crate.vir> <out.fasl>
;;       read a crate.vir once and cache it, so that `check` starts faster
;;
;; All wording of the report is in the "text" section below and nowhere
;; else; the rest of this file only arranges it.
(require racket/list racket/string racket/match racket/cmdline racket/set racket/runtime-path
         "check.rkt" "items.rkt" "results.rkt" "select.rkt" "vir.rkt")

;; ================================================================ text

(define (code s) (format "`~a`" s))

(define kind-names
  '((return-unmentioned . "返回值未被提及")
    (mut-param-unmentioned . "`&mut`参数调用后的状态未被提及")))

(define (kind-name k) (cdr (assq k kind-names)))

(define group-names
  '((#t . "有postcondition的函数")
    (#f . "没有postcondition的函数")))

(define (group-name g) (cdr (assoc g group-names)))

(define (mode-name m) (symbol->string m))

(define private-name "非pub")

(define selected-heading "选中的函数")

;; explain-finding : finding -> string
(define (explain-finding fi)
  (define x (finding-output fi))
  (define t (typ->text (finding-typ fi)))
  (define ghost (if (finding-ghost? fi) "幽灵" ""))
  (string-append
   (match (finding-role fi)
     ['return
      (format "返回~a值~a的类型为~a. postcondition中没有出现返回值的名字, 也没有`returns`子句."
              ghost (if x (code x) "") (code t))]
     ['return-component
      (format "`#[verus_spec]`返回元组的第~a个分量 (~a返回值~a, 类型为~a) 没有被postcondition提及."
              (finding-index fi) (if (= (finding-index fi) 0) "exec" "幽灵")
              (if x (code x) "") (code t))]
     ['mut-param
      (format "~a参数~a的类型为~a. postcondition中的`final(...)`都不包含`~a`, 调用者只能假设它可能被任意修改."
              ghost (code x) (code t) x)])
   (if (finding-type-inv fi)
       (format " 只有类型不变量: 调用者只知道它满足类型不变量~a, 不知道它与参数或调用前状态的关系."
               (code (short-path (finding-type-inv fi))))
       "")
   (if (finding-default-only? fi)
       " 只在`default_ensures`中提及: 只有沿用默认函数体的实现保证这一点, 经由trait泛型调用时得不到."
       "")))

;; explain-function : fn -> string
;; The line under a function's heading.
(define (explain-function r)
  (define decl (fn-trait r))
  (string-join
   (filter values
           (list (code (location r))
                 (mode-name (fn-mode r))
                 (and (not (fn-public? r)) private-name)
                 (and (fn-external-body? r) "`external_body`: 函数体未经验证, 规格是被信任的")
                 (and decl (fn-trait-found? r)
                      (format "postcondition来自trait声明~a~a"
                              (code decl)
                              (if (fn-own-post? r) "和实现自身附加的子句" "")))
                 (and decl (not (fn-trait-found? r))
                      (format "未找到trait声明~a, 只按实现自身的子句检查" (code decl)))
                 (and (fn-inferred? r) "名称由VIR推断")))
   " · "))

(define merged-heading "~a (~a个实现, 规格都来自该声明, 结果相同)")
(define merged-example "以第一个实现为例:")

;; ================================================================ report

;; "ostd/src/mm/io.rs:1576", the signature's line
(define (location r) (if (fn-file r) (format "~a:~a" (fn-file r) (fn-line r)) ""))

;; by file, then by line as a number (not as text: 93 before 663)
(define (location<? a b)
  (define fa (or (fn-file a) "")) (define fb (or (fn-file b) ""))
  (or (string<? fa fb)
      (and (string=? fa fb) (< (or (fn-line a) 0) (or (fn-line b) 0)))))

(define (by-location rs) (sort rs location<?))

(define (findings rs) (append-map fn-findings rs))

;; 结论23: how a trait method implementation appears in the report.
;;   'with-decl  no clauses of its own, the declaration is in the report: omitted
;;   'merged     no clauses of its own, the declaration is not in the report:
;;               merged with the other implementations of the same method
;;   'own        listed on its own
;; reported? : declaration path -> boolean
(define (placement r reported?)
  (cond [(or (not (fn-trait r)) (fn-own-post? r)) 'own]
        [(reported? (fn-trait r)) 'with-decl]
        [else 'merged]))

(define (print-findings r)
  (for ([fi (fn-findings r)])
    (printf "- **~a**~a: ~a\n" (kind-name (finding-kind fi))
            (if (finding-output fi) (format " (~a)" (code (finding-output fi))) "")
            (explain-finding fi))))

;; report : (listof fn) selector-text total out-path -> void
;;   total  number of functions checked, before the selector
(define (report rs scope total out-path)
  (define in-report (for/set ([r rs]) (fn-path r)))
  (define (place r) (placement r (lambda (d) (set-member? in-report d))))
  (define (in-group g) (filter (lambda (r) (eq? (fn-has-post? r) g)) rs))
  (define (tally rs)
    (printf "| 问题 | 无任何约束 | 只有类型不变量 |\n|---|---|---|\n")
    (for ([k finding-kinds])
      (define fs (filter (lambda (fi) (eq? (finding-kind fi) k)) (findings rs)))
      (printf "| ~a | ~a | ~a |\n" (kind-name k)
              (count (lambda (fi) (not (finding-type-inv fi))) fs)
              (count finding-type-inv fs))))
  (define (print-group rs)
    (define own (filter (lambda (r) (and (eq? (place r) 'own) (pair? (fn-findings r)))) rs))
    (define merged
      (filter (lambda (g) (pair? (fn-findings (car g))))
              (group-by fn-trait
                        (by-location (filter (lambda (r) (eq? (place r) 'merged)) rs)))))
    ;; one entry per function, or per merged trait method, by source position
    (define entries
      (sort (append (map list own) merged) location<? #:key car))
    (when (null? entries) (printf "无报告.\n\n"))
    (for ([e entries])
      (match e
        [(list r)
         (printf "### ~a\n\n~a\n\n" (code (fn-name r)) (explain-function r))
         (print-findings r)]
        [(cons r _)
         (printf "### ~a\n\n" (format merged-heading (code (fn-trait r)) (length e)))
         (for ([x e])
           (printf "- ~a: ~a\n" (code (fn-name x)) (code (location x))))
         (printf "\n~a\n\n" merged-example)
         (print-findings r)])
      (newline)))
  (with-output-to-file out-path #:exists 'replace
    (lambda ()
      (printf "# postcondition未提及的输出\n\n")
      (printf "检查范围: 已检查的~a个exec函数和proof函数中, 选择器~a选中的~a个 (exec ~a个, proof ~a个; pub ~a个, ~a ~a个). 设计见`design.md`.\n\n"
              total (code scope) (length rs)
              (count (lambda (r) (eq? (fn-mode r) 'exec)) rs)
              (count (lambda (r) (eq? (fn-mode r) 'proof)) rs)
              (count fn-public? rs)
              private-name (count (lambda (r) (not (fn-public? r))) rs))
      (printf "## 汇总\n\n| 组 | 函数 | 输出 | 报告 |\n|---|---|---|---|\n")
      (for ([g '(#t #f)])
        (define gs (in-group g))
        (printf "| ~a | ~a | ~a | ~a |\n" (group-name g) (length gs)
                (apply + (map fn-outputs gs)) (length (findings gs))))
      (for ([g '(#t #f)])
        (printf "\n**~a**\n\n" (group-name g))
        (tally (in-group g)))
      (define impls (filter fn-trait rs))
      (define merged (filter (lambda (r) (eq? (place r) 'merged)) impls))
      (printf "\ntrait方法的实现共~a个: 自身附加了postcondition子句的~a个, 逐个列出; 其余的结果与声明相同, 其中声明也在本报告中的~a个随声明报告, 不再列出, 声明不在本报告中的~a个按trait方法合并 (其中有报告的~a个列在正文中).\n\n"
              (length impls)
              (count (lambda (r) (eq? (place r) 'own)) impls)
              (count (lambda (r) (eq? (place r) 'with-decl)) impls)
              (length merged)
              (count (lambda (r) (pair? (fn-findings r))) merged))
      (for ([g '(#t #f)])
        (printf "## ~a\n\n" (group-name g))
        (print-group (in-group g)))
      (printf "## ~a\n\n| 函数 | 位置 | 报告 |\n|---|---|---|\n" selected-heading)
      (for ([r (by-location rs)])
        (printf "| ~a | ~a | ~a |\n" (code (fn-name r))
                (string-join (filter values (list (code (location r))
                                                  (mode-name (fn-mode r))
                                                  (and (not (fn-public? r)) private-name)))
                             " · ")
                (length (fn-findings r))))))
  (printf "report written to ~a\n" out-path))

;; ================================================================ command line

;; Where `cargo build --release` in item-index/ puts the parser by default.
(define-runtime-path release-dir "item-index/target/release")
(define default-item-index
  (build-path release-dir (if (eq? (system-type) 'windows) "item-index.exe" "item-index")))

;; <in> may name several VIR dumps separated by commas, one per crate.  The
;; parser supplies each function's name and lines (结论21).
(define (check in out src-root exe)
  (define vir (string-split in ","))
  (define dumps (map load-vir vir))
  (for* ([(p items) (in-parallel vir dumps)] [w (vir-format-warnings items)])
    (eprintf "warning: ~a: ~a\n" p w))
  (define rs (run-check dumps))
  (define (loc r) (and (fn-file r) (cons (fn-file r) (fn-line r))))
  (define idx (load-item-index exe src-root (filter values (map loc rs))))
  (define checked
    (for/list ([r rs])
      (define-values (name lines) (if (loc r) (parser-source idx (loc r) (fn-path r)) (values #f #f)))
      (fn-with-source r name lines)))
  (write-results out vir checked)
  (printf "~a functions checked, results written to ~a\n" (length rs) out)
  ;; expected for derive- and macro-generated functions (注意9); if it is
  ;; most of them, the source root or the parser does not match the VIR
  (define unnamed (count fn-inferred? checked))
  (when (> unnamed 0)
    (printf "~a of them not found by the source parser; they keep the names inferred from VIR (design.md, 注意9)\n" unnamed)))

;; A selector read from a file is shown as `@FILE`, not expanded.
(define (report-on in out selector)
  (define sel (read-selector selector))
  (define-values (_ all) (read-results in))
  (report (filter (compile-selector sel) all)
          (if (string-prefix? selector "@") selector (selector->string sel))
          (length all) out))

(define (cache vir out)
  (printf "~a top-level items cached to ~a\n" (cache-vir vir out) out))

(define usage "usage: racket main.rkt check <vir>[,<vir>...] <out.results> <src-root> [<item-index>]
       racket main.rkt report <in.results> <out.md> <selector>
       racket main.rkt cache <crate.vir> <out.fasl>
")

(module+ main
  (command-line
   #:args args
   (match args
     [(list "check" in out src-root) (check in out src-root default-item-index)]
     [(list "check" in out src-root exe) (check in out src-root exe)]
     [(list "report" in out selector) (report-on in out selector)]
     [(list "cache" vir out) (cache vir out)]
     [_ (eprintf usage) (exit 2)])))
