#cs
(module lazy mzscheme

  ;; ~ = lazy (or delayed)
  ;; ! = strict (or forced)
  ;; (See below for app-related names)

  ;; --------------------------------------------------------------------------
  ;; Syntax utilities

  ;; taken & modified from swindle/misc.ss
  (provide defsubst) ; useful utility
  (define-syntax (defsubst-process stx)
    (syntax-case stx ()
      [(_ name (acc ...))
       #'(define-syntax (name stx)
           (syntax-case stx () acc ...))]
      [(_ name (acc ...) id subst . more) (identifier? #'id)
       #'(defsubst-process
           name (acc ...
                 (id (identifier? #'id) #'subst)
                 ((id x (... ...)) #'(subst x (... ...))))
           . more)]
      [(_ name (acc ...) n+a subst . more)
       #'(defsubst-process name (acc ... (n+a #'subst)) . more)]))
  (define-syntax defsubst
    (syntax-rules ()
      [(_ (name . args) subst . more)
       (defsubst-process name () (name . args) subst . more)]
      [(_ name subst . more)
       (defsubst-process name () name subst . more)]))

  ;; utility for defining ~foo but make it look like #<procedure:foo>
  (define-syntax (define* stx)
    (syntax-case stx ()
      [(_ ~name val) (identifier? #'~name)
       (let* ([~str (symbol->string (syntax-e #'~name))]
              [str  (string->symbol (regexp-replace #rx"^[~*]" ~str ""))])
         (with-syntax ([name (datum->syntax-object #'~name str #'~name)])
           #'(define ~name (let ([name val]) (mark-lazy name)))))]
      [(_ (~name . xs) body ...) (identifier? #'~name)
       #'(define* ~name (lambda xs body ...))]))

  ;; --------------------------------------------------------------------------
  ;; Delay/force etc
  
  (provide ~)
  (defsubst (~ x) (delay x))

  (define (! x) (if (promise? x) (! (force x)) x))
  ;; the exposed `!' must be a special form
  (provide (rename special-form-! !))
  ;; hack to see if it solves a certificate problem:
  (provide (rename ! crazythingthatwillneverbereferredto))
  (defsubst (special-form-! x) (! x) special-form-! !)

  ;; These things are useful too, to write strict functions (with various
  ;; levels of strictness) -- need to provide them as special forms.
  (provide (rename special-form-!! !!))
  (defsubst (special-form-!! x) (!! x) special-form-!! !!)
  (provide (rename special-form-!!! !!!))
  (defsubst (special-form-!!! x) (!!! x) special-form-!!! !!!)
  (provide (rename special-form-!list !list))
  (defsubst (special-form-!list x) (!list x) special-form-!list !list)
  (provide (rename special-form-!!list !!list))
  (defsubst (special-form-!!list x) (!!list x) special-form-!!list !!list)
  (provide (rename special-form-!values !values))
  (defsubst (special-form-!values x) (!values x) special-form-!values !values)
  (provide (rename special-form-!!values !!values))
  (defsubst (special-form-!!values x) (!!values x)
            special-form-!!values !!values)

  ;; Force a nested structure -- we don't distinguish values from promises so
  ;; it's fine to destructively modify the structure.
  (define (do-!! x translate-procedures?)
    (define table (make-hash-table)) ; avoid loops due to sharing
    (split-values ; see below
     (let loop ([x x])
       (let ([x (! x)])
         (unless (hash-table-get table x (lambda () #f))
           (hash-table-put! table x #t)
           (cond [(pair? x)
                  (set-car! x (loop (car x)))
                  (set-cdr! x (loop (cdr x)))]
                 [(vector? x)
                  (let loop ([i 0])
                    (when (< i (vector-length x))
                      (vector-set! x (loop (vector-ref x i)))
                      (loop (add1 i))))]
                 [(box? x) (set-box! x (loop (unbox x)))]
                 [(struct? x)
                  (let-values ([(type skipped?) (struct-info x)])
                    (if type
                      (let*-values ([(name initk autok ref set imms spr skp?)
                                     (struct-type-info type)]
                                    [(k) (+ initk autok)])
                        (let sloop ([i 0])
                          (unless (= i k)
                            (set x i (loop (ref x i)))
                            (sloop (add1 i)))))
                      x))]))
         (if (and (procedure? x) translate-procedures?)
           (lambda args (do-!! (apply x args) #t))
           x)))))
  (define (!! x) (do-!! x #f))
  ;; Similar to the above, but wrape procedure values too
  (define (!!! x) (do-!! x #t))
  ;; Force just a top-level list structure, similar to the above.
  ;; (todo: this and the next assumes no cycles.)
  (define (!list x)
    (let loop ([x x])
      (let ([x (! x)]) (when (pair? x) (set-cdr! x (loop (cdr x)))) x)))
  ;; Force a top-level list structure and the first level of values, again,
  ;; similar to the above.
  (define (!!list x)
    (let loop ([x x])
      (let ([x (! x)])
        (when (pair? x)
          (set-car! x (! (car x)))
          (set-cdr! x (loop (cdr x)))) x)))
  ;; Force and split resulting values.
  (define (!values x)
    (split-values (! x)))
  ;; Similar, but forces the actual values too.
  (define (!!values x)
    (let ([x (! x)])
      (if (multiple-values? x)
        (apply values (map ! (multiple-values-values x)))
        x)))

  ;; --------------------------------------------------------------------------
  ;; Determine laziness

  (define-values (lazy-proc lazy-proc?)
    (let-values ([(type make pred ref set)
                  (make-struct-type
                   'lazy-proc #f 1 0 #f null (current-inspector) 0)])
      (values make pred)))
  (defsubst (lazy? x) (if (lazy-proc? x) #t (struct-constructor-procedure? x)))
  ;; a version that works on any value
  (defsubst (mark-lazy x) (if (procedure? x) (lazy-proc x) x))

  ;; a few primitive constructors
  (define ~cons   (lazy-proc cons))
  (define ~list   (lazy-proc list))
  (define ~list*  (lazy-proc list*))
  (define ~vector (lazy-proc vector))
  (define ~box    (lazy-proc box))
  ;; values is special, see below

  ;; --------------------------------------------------------------------------
  ;; Implicit begin & multiple values

  ;; This is used for implicit body begins.  It is slightly complex since it
  ;; should still be possible to use it for splicing up macro contents, so
  ;; definitions are used with a normal begin.  The actual body turns into one
  ;; promise that, when forced, forces each of its expressions and returns the
  ;; last value.  This effectively ties evaluation of all expressions in one
  ;; package, so (~begin foo bar) will always evaluate `foo' when the value of
  ;; `bar' is forced.
  (define-syntax ~begin
    (let ([ids (syntax->list
                #'(~define ~define-values define-syntax define-syntaxes
                   define-struct require provide))])
      (define (definition? stx)
        (ormap (lambda (id) (module-identifier=? id stx)) ids))
      (lambda (stx)
        (syntax-case stx ()
          ;; optimize simple cases
          [(_) #'(begin)]
          [(_ expr) #'expr]
          [(_ expr ...)
           (let loop ([exprs #'(expr ...)] [defs '()])
             (syntax-case exprs ()
               [((head . rest) expr ...)
                (definition? #'head)
                (loop #'(expr ...) (cons #'(head . rest) defs))]
               ;; only definitions
               [() #`(begin #,@(reverse! defs))]
               ;; single expr
               [(expr) #`(begin #,@(reverse! defs) expr)]
               [(expr ...)
                #`(begin #,@(reverse! defs) (~ (begin (! expr) ...)))]))]))))

  ;; redefined to use lazy-proc and ~begin
  (define-syntax (~lambda stx)
    (syntax-case stx ()
      [(_ args body0 body ...)
       (let ([n (syntax-local-name)])
         (with-syntax ([lam (syntax-property
                             (syntax/loc stx
                               (lambda args (~begin body0 body ...)))
                             'inferred-name n)])
           (syntax/loc stx (lazy-proc lam))))]))
  (defsubst
    (~define (f . xs) body0 body ...) (define f (~lambda xs body0 body ...))
    (~define v x) (define v x))
  (defsubst
    (~let [(x v) ...] body0 body ...)
      (let ([x v] ...) (~begin body0 body ...))
    (~let name [(x v) ...] body0 body ...)
      (let name [(x v) ...] (~begin body0 body ...)))
  (defsubst (~let* [(x v) ...] body0 body ...)
    (let* ([x v] ...) (~begin body0 body ...)))
  (defsubst (~letrec [(x v) ...] body0 body ...)
    (letrec ([x v] ...) (~begin body0 body ...)))

  ;; parameterize should force its arguments
  (defsubst (~parameterize ([param val] ...) body ...)
    ;; like ~begin, delaying the whole thing is necessary to tie the evaluation
    ;; to whenever the value is actually forced
    (~ (parameterize ([param (! val)] ...) (~begin body ...))))

  ;; Multiple values are problematic: MzScheme promises can use multiple
  ;; values, but to carry that out `call-with-values' should be used in all
  ;; places that deal with multiple values, which will make the whole thing
  ;; much slower -- but multiple values are rarely used (spceifically, students
  ;; never use them).  Instead, `values' is redefined to produce a special
  ;; struct, and `split-values' turns that into multiple values.
  (define-struct multiple-values (values))
  (define* (~values . xs) (make-multiple-values xs))
  (define (split-values x)
    (let ([x (! x)])
      (if (multiple-values? x) (apply values (multiple-values-values x)) x)))

  ;; Redefine multiple-value constructs so they split the results
  (defsubst (~define-values (v ...) body)
    (define-values (v ...) (split-values body)))
  (defsubst (~let-values ([(x ...) v] ...) body ...)
    (let-values ([(x ...) (split-values v)] ...) (~begin body ...)))
  (defsubst (~let*-values ([(x ...) v] ...) body ...)
    (let*-values ([(x ...) (split-values v)] ...) (~begin body ...)))
  (defsubst (~letrec-values ([(x ...) v] ...) body ...)
    (letrec-values ([(x ...) (split-values v)] ...) (~begin body ...)))

  ;; Redefine things that return multiple values.
  ;; (todo: only stuff necessary for the datatypes are done, more needed)
  (define* (~make-struct-type . args)
    (let ([args (!!list args)])
      (call-with-values (lambda () (apply make-struct-type args)) ~values)))

  ;; --------------------------------------------------------------------------
  ;; Applications

  ;; Basic names:
  ;; `app':    syntax, calls a function over given arguments
  ;; `apply':  function, last argument is a list of arguments to the function
  ;; Conventions:
  ;; `!*---':  forces args when needed (depending on the function)
  ;;           doesn't force the function (internal use only)
  ;; `!---':   forces function, and forces args when needed
  ;; `~!---':  adds a delay wrapper to the application (uses the above)
  ;;           (this is a macro in the `apply' case too)
  ;; `~!*---': like the previous, but does not force the function (internal)
  ;; Provided stuff:
  ;; `~!%app': provided as `#%app' -- similar to `~!app' but treats a few
  ;;           application kinds as special (mostly all kinds of forces)
  ;; `!apply': provided as `apply' (no need to provide `~!apply', since all
  ;;           function calls are delayed by `#%app')

  (define-syntax (jbc! stx)
      (syntax-case stx (!)
        [(_ arg) (syntax-property #`(! arg) 'stepper-skipto '(syntax-e cdr syntax-e cdr car))]))
  
  (define-syntax (!*app stx)
    (syntax-case stx (~ ! !! !list !!list !values !!values)
      [(_ f x ...)
       (let ([$$ (lambda (stx) (syntax-property stx 'stepper-skipto '(syntax-e cdr cdr both-l () (car))))]
             [$ (lambda (stx) (syntax-property stx 'stepper-skipto '(syntax-e cdr syntax-e car)))])
       (with-syntax ([(y ...) (generate-temporaries #'(x ...))])
         (with-syntax ([(!y ...) (map (lambda (stx) (syntax-property stx 'stepper-skipto '(syntax-e cdr syntax-e cdr car)))
                                      (syntax->list #`((! y) ...)))])
         ;; use syntax/loc for better errors etc
         (with-syntax ([lazy   (quasisyntax/loc stx (p y     ...))]
                       [strict (quasisyntax/loc stx (p !y ...))])
           (quasisyntax/loc stx
              (let ([p f] [y x] ...)
                #,($$ #`(if (lazy? p) lazy strict))))))))]))

  (defsubst (!app   f x ...) (!*app (jbc! f) x ...))
  (defsubst (~!*app f x ...) (~ (!*app f x ...)))
  (defsubst (~!app  f x ...) (~ (!app f x ...)))

  (provide (rename ~!%app #%app)) ; all applications are delayed
  (define-syntax (~!%app stx) ; provided as #%app
    (define (unwinder stx rec)
      (syntax-case stx (!)
        [(let-values ([(_p) (_app ! f)] [(_y) x] ...) _body)
         (with-syntax ([(f x ...) (rec #'(f x ...))])
           #'(f x ...))]))
    (define (stepper-annotate stx)
      (let* ([stx (syntax-property stx 'stepper-hint unwinder)]
             [stx (syntax-property stx 'stepper-skip-double-break #t)])
        stx))
    (syntax-case stx (~ ! !! !list !!list !values !!values)
      ;; the usual () shorthand for null
      [(_) #'null]
      ;; do not treat these as normal applications
      [(_ ~ x)        (syntax/loc stx (~ x))]
      [(_ ! x)        (syntax/loc stx (! x))]
      [(_ !! x)       (syntax/loc stx (!! x))]
      [(_ !list x)    (syntax/loc stx (!list x))]
      [(_ !!list x)   (syntax/loc stx (!!list x))]
      [(_ !values x)  (syntax/loc stx (!values x))]
      [(_ !!values x) (syntax/loc stx (!!values x))]
      [(_ f x ...)    (stepper-annotate (syntax/loc stx (~!app f x ...)))]))

  (define (!*apply f . xs)
    (let ([xs (!list (apply list* xs))])
      (apply f (if (lazy? f) xs (map ! xs)))))
  (define* (!apply f . xs)
    (let ([f (! f)] [xs (!list (apply list* xs))])
      (apply f (if (lazy? f) xs (map ! xs)))))
  (defsubst (~!*apply f . xs) (~ (!*apply f . xs)))
  (defsubst (~!apply  f . xs) (~ (!apply  f . xs)))

  (provide (rename !apply apply)) ; can only be used through #%app => delayed

  ;; used for explicitly strict/lazy calls
  (defsubst (strict-call f x ...) (~ (f (! x) ...)))
  (defsubst (lazy-call f x ...) (~ (f x ...)))

  ;; --------------------------------------------------------------------------
  ;; Special forms that are now functions

  ;; Since these things are rarely used as functions, they are defined as
  ;; macros that expand to the function form when used as an expression.

  (define* *if
    (case-lambda [(e1 e2 e3) (if (! e1) e2 e3)]
                 [(e1 e2   ) (if (! e1) e2   )]))
  (defsubst (~if e1 e2 e3) (~ (if (! e1) e2 e3))
            (~if e1 e2   ) (~ (if (! e1) e2   ))
            ~if *if)

  (define* (*and . xs)
    (let ([xs (!list xs)])
      (or (null? xs)
          (let loop ([x (car xs)] [xs (cdr xs)])
            (if (null? xs) x (and (! x) (loop (car xs) (cdr xs))))))))
  (defsubst (~and x ...) (~ (and (! x) ...)) ~and *and)

  (define* (*or . xs)
    (let ([xs (!list xs)])
      (and (pair? xs)
           (let loop ([x (car xs)] [xs (cdr xs)])
             (if (null? xs) x (or (! x) (loop (car xs) (cdr xs))))))))
  (defsubst (~or x ...) (~ (or (! x) ...)) ~or *or)

  ;; --------------------------------------------------------------------------
  ;; Special forms that are still special forms since they use ~begin

  (defsubst (~begin0 x y ...) ; not using ~begin, but equivalent
    (~ (let ([val (! x)]) (! y) ... val)))

  (defsubst (~when   e x ...) (~ (when   (! e) (~begin x ...))))
  (defsubst (~unless e x ...) (~ (unless (! e) (~begin x ...))))

  ;; --------------------------------------------------------------------------
  ;; Misc stuff

  ;; Just for fun...
  (defsubst (~set! id expr) (~ (set! id (! expr))))
  ;; The last ! above is needed -- without it:
  ;;   (let ([a 1] [b 2]) (set! a (add1 b)) (set! b (add1 a)) a)
  ;; goes into an infinite loop.  (Thanks to Jos Koot)

  (define* (~set-car! pair val) (~ (set-car! (! pair) val)))
  (define* (~set-cdr! pair val) (~ (set-cdr! (! pair) val)))
  (define* (~vector-set! vec i val) (~ (vector-set! (! vec) (! i) val)))
  (define* (~set-box! box val) (~ (set-box! (! box) val)))

  ;; not much to do with these besides inserting strict points
  (define-syntax (~cond stx)
    (syntax-case stx ()
      [(_ [test body ...] ...)
       (with-syntax ([(test ...)
                      ;; avoid forcing an `else' keyword
                      (map (lambda (stx)
                             (syntax-case stx (else)
                               [else stx] [x #'(! x)]))
                           (syntax->list #'(test ...)))])
         #'(~ (cond [test (~begin body ...)] ...)))]))
  (defsubst (~case v [keys body ...] ...)
    (~ (case (! v) [keys (~begin body ...)] ...)))

  ;; Doing this will print the whole thing, but problems with infinite things
  (define* (~error . args) (apply error (!! args)))

  ;; I/O shows the whole thing
  (define* (~printf fmt . args) (apply printf (! fmt) (!! args)))
  (define* (~fprintf p fmt . args) (apply fprintf (! p) (! fmt) (!! args)))
  (define* (~display x . port)  (apply display (!! x) (!!list port)))
  (define* (~write   x . port)  (apply write   (!! x) (!!list port)))
  (define* (~print   x . port)  (apply print   (!! x) (!!list port)))

  ;; --------------------------------------------------------------------------
  ;; Equality functions

  ;; All of these try to stop if the promises are the same.

  (define* (~eq? . args)
    (or (apply eq? (!list args)) (apply eq? (!!list args))))

  (define* (~eqv? . args)
    (or (apply eqv? (!list args)) (apply eqv? (!!list args))))

  ;; for `equal?' we must do a recursive scan
  (define* (~equal? x y . args)
    (let ([args (!list args)])
      (if (pair? args)
        (and (~equal? x y) (apply ~equal? y (cdr args)))
        (or (equal? x y)
            (let ([x (! x)] [y (! y)])
              (or (equal? x y)
                  (cond
                   [(pair? x) (and (pair? y)
                                   (~equal? (car x) (car y))
                                   (~equal? (cdr x) (cdr y)))]
                   [(vector? x) (and (vector? y)
                                     (andmap ~equal?
                                             (vector->list x)
                                             (vector->list y)))]
                   [(box? x) (and (box? y) (~equal? (unbox x) (unbox y)))]
                   [(struct? x)
                    (and (struct? y)
                         (let-values ([(xtype xskipped?) (struct-info x)]
                                      [(ytype yskipped?) (struct-info y)])
                           (and xtype ytype (not xskipped?) (not yskipped?)
                                (eq? xtype ytype)
                                (let*-values
                                    ([(name initk autok ref set imms spr skp?)
                                      (struct-type-info xtype)]
                                     [(k) (+ initk autok)])
                                  (let loop ([i 0])
                                    (or (= i k)
                                        (and (~equal? (ref x i) (ref y i))
                                             (loop (add1 i)))))))))]
                   [else #f])))))))

  ;; --------------------------------------------------------------------------
  ;; List functions

  (define* (~list?  x) (list?  (!list x))) ; must force the whole list
  (define* (~length l) (length (!list l))) ; for these

  (define* (~car    x) (car (! x))) ; these are for internal use: ~!app will do
  (define* (~cdr    x) (cdr (! x))) ; this job when using this language
  (define* (~caar   x) (car (! (car (! x)))))
  (define* (~cadr   x) (car (! (cdr (! x)))))
  (define* (~cdar   x) (cdr (! (car (! x)))))
  (define* (~cddr   x) (cdr (! (cdr (! x)))))
  (define* (~caaar  x) (car (! (~caar x))))
  (define* (~caadr  x) (car (! (~cadr x))))
  (define* (~cadar  x) (car (! (~cdar x))))
  (define* (~caddr  x) (car (! (~cddr x))))
  (define* (~cdaar  x) (cdr (! (~caar x))))
  (define* (~cdadr  x) (cdr (! (~cadr x))))
  (define* (~cddar  x) (cdr (! (~cdar x))))
  (define* (~cdddr  x) (cdr (! (~cddr x))))
  (define* (~caaaar x) (car (! (~caaar x))))
  (define* (~caaadr x) (car (! (~caadr x))))
  (define* (~caadar x) (car (! (~cadar x))))
  (define* (~caaddr x) (car (! (~caddr x))))
  (define* (~cadaar x) (car (! (~cdaar x))))
  (define* (~cadadr x) (car (! (~cdadr x))))
  (define* (~caddar x) (car (! (~cddar x))))
  (define* (~cadddr x) (car (! (~cdddr x))))
  (define* (~cdaaar x) (cdr (! (~caaar x))))
  (define* (~cdaadr x) (cdr (! (~caadr x))))
  (define* (~cdadar x) (cdr (! (~cadar x))))
  (define* (~cdaddr x) (cdr (! (~caddr x))))
  (define* (~cddaar x) (cdr (! (~cdaar x))))
  (define* (~cddadr x) (cdr (! (~cdadr x))))
  (define* (~cdddar x) (cdr (! (~cddar x))))
  (define* (~cddddr x) (cdr (! (~cdddr x))))

  (define* (~list-ref l k)
    (let ([k (! k)])
      (unless (and (integer? k) (exact? k) (<= 0 k))
        (raise-type-error 'list-ref "non-negative exact integer" 1 l k))
      (let loop ([k k] [l (! l)])
        (cond [(not (pair? l))
               (raise-type-error 'list-ref "proper list" l)]
              [(zero? k) (car l)]
              [else (loop (sub1 k) (! (cdr l)))]))))
  (define* (~list-tail l k)
    (let ([k (! k)])
      (unless (and (integer? k) (exact? k) (<= 0 k))
        (raise-type-error 'list-tail "non-negative exact integer" 1 l k))
      (let loop ([k k] [l l]) ; don't force here -- unlike list-ref
        (cond [(zero? k) l]
              [else (let ([l (! l)])
                      (unless (pair? l)
                        (raise-type-error 'list-tail "list" l))
                      (loop (sub1 k) (cdr l)))]))))

  (define* (~append . xs)
    (let ([xs (!list xs)])
      (cond [(null? xs) '()]
            [(null? (cdr xs)) (car xs)]
            [else (let ([ls (~ (apply ~append (cdr xs)))])
                    (let loop ([l (! (car xs))])
                      (if (null? l)
                        ls
                        (cons (car l) (~ (loop (! (cdr l))))))))])))

  ;; useful utility for many list functions
  (define (!cdr l) (! (cdr l)))

  (define-syntax (deflistiter stx)
    (syntax-case stx (extra: null ->)
      [(deflistiter (?~name ?proc ?args ... ?l . ?ls)
         null -> ?base
         ?loop -> ?step-single ?step-multiple)
       #'(deflistiter (?~name ?proc ?args ... ?l . ?ls)
           extra:
           null -> ?base
           ?loop -> ?step-single ?step-multiple)]
      [(deflistiter (?~name ?proc ?args ... ?l . ?ls)
         extra: [?var ?init] ...
         null -> ?base
         ?loop -> ?step-single ?step-multiple)
       (with-syntax ([?name (let* ([x (symbol->string (syntax-e #'?~name))]
                                   [x (regexp-replace #rx"^~" x "")]
                                   [x (string->symbol x)])
                              (datum->syntax-object #'?~name x #'?~name))])
         #'(define* ?~name
             (case-lambda
               [(?proc ?args ... ?l)
                (let ([?proc (! ?proc)])
                  (let ?loop ([?l (! ?l)] [?var ?init] ...)
                    (if (null? ?l)
                      ?base
                      ?step-single)))]
               [(?proc ?args ... ?l . ?ls)
                (let ([?proc (! ?proc)])
                  (let ?loop ([?ls (cons (! ?l) (!!list ?ls))] [?var ?init] ...)
                    (if (ormap null? ?ls)
                      (if (andmap null? ?ls)
                        ?base
                        (error '?name "all lists must have same size"))
                      ?step-multiple)))])))]))

  ;; These use the `*' version of app/ly, to avoid forcing the function over
  ;; and over -- `deflistiter' forces it on entry
  (deflistiter (~map proc l . ls)
    null -> '()
    loop -> (cons (~!*app proc (car l)) (~ (loop (! (cdr l)))))
            (cons (~!*apply proc (map car ls)) (~ (loop (map !cdr ls)))))
  (deflistiter (~for-each proc l . ls)
    null -> (void)
    loop -> (begin (! (!*app proc (car l))) (loop (! (cdr l))))
            (begin (! (!*apply proc (map car ls))) (loop (map !cdr ls))))
  (deflistiter (~andmap proc l . ls)
    null -> #t
    loop -> (and (! (!*app proc (car l))) (loop (! (cdr l))))
            (and (! (!*apply proc (map car ls))) (loop (map !cdr ls))))
  (deflistiter (~ormap proc l . ls)
    null -> #f
    loop -> (or (! (!*app proc (car l))) (loop (! (cdr l))))
            (or (! (!*apply proc (map car ls))) (loop (map !cdr ls))))
  (deflistiter (foldl proc init l . ls)
    extra: [acc init]
    null -> acc
    loop ->
      (~ (loop (! (cdr l)) (~!*app proc (car l) acc)))
      (~ (loop (map !cdr ls)
               (~!*apply proc (append! (map car ls) (list acc))))))
  (deflistiter (foldr proc init l . ls)
    null -> init
    loop ->
      (~!*app proc (car l) (~ (loop (! (cdr l)))))
      (~!*apply proc (append! (map car ls) (list (~ (loop (map !cdr ls)))))))

  (define (do-member name = elt list) ; no currying for procedure names
    ;; `elt', `=', and `name' are always forced values
    (let loop ([list (! list)])
      (cond [(null? list) #f]
            [(not (pair? list)) (error name "not a proper list: ~e" list)]
            [(= elt (! (car list))) list]
            [else (loop (! (cdr list)))])))
  (define* (~member elt list) (do-member 'member ~equal? (! elt) list))
  (define* (~memq   elt list) (do-member 'memq   ~eq?    (! elt) list))
  (define* (~memv   elt list) (do-member 'memv   ~eqv?   (! elt) list))

  (define (do-assoc name = key alist) ; no currying for procedure names
    ;; `key', `=', and `name' are always forced values
    (let loop ([alist (! alist)])
      (cond [(null? alist) #f]
            [(not (pair? alist)) (error name "not a proper list: ~e" alist)]
            [else (let ([cell (! (car alist))])
                    (cond [(not (pair? cell))
                           (error name "non-pair found in list: ~e" cell)]
                          [(= (! (car cell)) key) cell]
                          [else (loop (! (cdr alist)))]))])))
  (define* (~assoc key alist) (do-assoc 'assoc ~equal? (! key) alist))
  (define* (~assq  key alist) (do-assoc 'assq  ~eq?    (! key) alist))
  (define* (~assv  key alist) (do-assoc 'assv  ~eqv?   (! key) alist))

  (define* (~reverse list)
    (let ([list (!list list)])
      (reverse list)))

  ;; --------------------------------------------------------------------------
  ;; Extra functionality that is useful for lazy list stuff

  (define* (take n l)
    (let loop ([n (! n)] [l (! l)])
      (cond [(or (<= n 0) (null? l)) '()]
            [(pair? l) (cons (car l) (~ (loop (sub1 n) (! (cdr l)))))]
            [else (error 'take "not a proper list: ~e" l)])))

  ;; not like Haskell's `take' that consumes a list
  (define* (cycle . l)
    (letrec ([r (~ (~append (! l) r))])
      r))

  ;; --------------------------------------------------------------------------
  ;; (lib "list.ss") functionality

  (define* (rest x) (~cdr x))
  (define* (first   x) (~car    x))
  (define* (second  x) (~cadr   x))
  (define* (third   x) (~caddr  x))
  (define* (fourth  x) (~cadddr x))
  (define* (fifth   x) (~car    (~cddddr x)))
  (define* (sixth   x) (~cadr   (~cddddr x)))
  (define* (seventh x) (~caddr  (~cddddr x)))
  (define* (eighth  x) (~cadddr (~cddddr x)))
  (define* (cons? x) (pair? (! x)))
  (define* empty null)
  (define* (empty? x) (null? (! x)))

  (require (rename (lib "list.ss") !last-pair last-pair))
  (define* (last-pair list) (!last-pair (!list list)))

  (define (do-remove name item list =)
    (let ([= (! =)])
      (let loop ([list (! list)])
        (cond [(null? list) list]
              [(not (pair? list))
               (error name "not a proper list: ~e" list)]
              [(= item (car list)) (cdr list)]
              [else (cons (car list) (~ (loop (! (cdr list)))))]))))
  (define* remove
    (case-lambda [(item list  ) (do-remove 'remove item list ~equal?)]
                 [(item list =) (do-remove 'remove item list =)]))
  (define* (remq item list)      (do-remove 'remq   item list ~eq?))
  (define* (remv item list)      (do-remove 'remv   item list ~eqv?))

  (define (do-remove* name items list =)
    (let ([= (! =)] [items (!list items)])
      (let loop ([list (! list)])
        (cond [(null? list) list]
              [(not (pair? list))
               (error name "not a proper list: ~e" list)]
              [else (let ([xs (~ (loop (! (cdr list))))])
                      (if (memf (lambda (item) (= item (car list))) items)
                        xs
                        (cons (car list) xs)))]))))
  (define* remove*
    (case-lambda [(items list  ) (do-remove* 'remove* items list ~equal?)]
                 [(items list =) (do-remove* 'remove* items list =)]))
  (define* (remq* items list)     (do-remove* 'remq*   items list ~eq?))
  (define* (remv* items list)     (do-remove* 'remv*   items list ~eqv?))

  (define* (memf pred list)
    (let ([pred (! pred)])
      (let loop ([list (! list)])
        (cond [(null? list) #f]
              [(not (pair? list)) (error 'memf "not a proper list: ~e" list)]
              [(pred (! (car list))) list]
              [else (loop (! (cdr list)))]))))

  (define* (assf pred alist)
    (let ([pred (! pred)])
      (let loop ([alist (! alist)])
        (cond [(null? alist) #f]
              [(not (pair? alist)) (error 'assf "not a proper list: ~e" alist)]
              [else (let ([cell (! (car alist))])
                      (cond [(not (pair? cell))
                             (error 'assf "non-pair found in list: ~e" cell)]
                            [(pred (! (car cell))) cell]
                            [else (loop (! (cdr alist)))]))]))))

  (define* (filter pred list)
    (let loop ([list (! list)])
      (cond ([null? list] list)
            ([pair? list]
             (let ([x (! (car list))] [xs (~ (loop (! (cdr list))))])
               (if (! (pred x)) (cons x xs) xs)))
            (else (error 'filter "not a proper list: ~e" list)))))

  (require (rename (lib "list.ss") !quicksort quicksort)
           (rename (lib "list.ss") !mergesort mergesort))
  (define* (quicksort list less-than)
    (!quicksort (!list list) (! less-than)))
  (define* (mergesort list less-than)
    (!mergesort (!list list) (! less-than)))

  ;; --------------------------------------------------------------------------
  ;; (lib "etc.ss") functionality

  (require (rename (lib "etc.ss") boolean=? boolean=?)
           (rename (lib "etc.ss") symbol=?  symbol=?))
  (define* true  #t)
  (define* false #f)

  (define* (identity x) x)
  ;; no need for dealing with multiple values since students don't use them
  (define* (compose . fs)
    (let ([fs (!list fs)])
      (cond [(null? fs) identity]
            [(null? (cdr fs)) (car fs)]
            [else (let ([fs (reverse fs)])
                    (lambda xs
                      (let loop ([fs (cdr fs)]
                                 [x  (~!apply (car fs) xs)])
                        (if (null? fs)
                          x
                          (loop (cdr fs) (~!app (car fs) x))))))])))

  (define* (build-list n f)
    (let ([n (! n)] [f (! f)])
      (unless (and (integer? n) (exact? n) (>= n 0))
        (error 'build-list "~s must be an exact integer >= 0" n))
      (unless (procedure? f)
        (error 'build-list "~s must be a procedure" f))
      (let loop ([i 0])
        (if (>= i n)
          '()
          (cons (~ (f i)) (~ (loop (add1 i))))))))

  ;; --------------------------------------------------------------------------
  ;; Provide everything except some renamed stuff

  (define-syntax (renaming-provide stx)
    (syntax-case stx ()
      [(_ id ...)
       (with-syntax
           ([(~id ...)
             (map (lambda (id)
                    (let* ([str (symbol->string (syntax-e id))]
                           [~id (string->symbol (string-append "~" str))])
                      (datum->syntax-object id ~id id)))
                  (syntax->list #'(id ...)))])
         #'(provide (all-from-except mzscheme module #%app apply id ...)
                    (rename ~id id) ...))]))
  (renaming-provide
   lambda define let let* letrec parameterize
   values define-values let-values let*-values letrec-values make-struct-type
   cons list list* vector box
   if and or begin begin0 when unless
   set! set-car! set-cdr! vector-set! set-box!
   cond case error printf fprintf display write print
   eq? eqv? equal?
   list? length list-ref list-tail append map for-each andmap ormap
   member memq memv assoc assq assv reverse
   caar cadr cdar cddr caaar caadr cadar caddr cdaar cdadr cddar cdddr caaaar
   caaadr caadar caaddr cadaar cadadr caddar cadddr cdaaar cdaadr cdadar cdaddr
   cddaar cddadr cdddar cddddr)

  (provide
   ;; multiple values (see above)
   split-values
   ;; explicit strict/lazy calls
   strict-call lazy-call
   ;; `list' stuff
   first second third fourth fifth sixth seventh eighth rest cons? empty empty?
   foldl foldr last-pair remove remq remv remove* remq* remv* memf assf filter
   quicksort mergesort
   ;; `etc' stuff
   true false boolean=? symbol=? identity compose build-list
   ;; extra stuff for lazy Scheme
   take cycle)

  ;; --------------------------------------------------------------------------
  ;; Initialize special evaluation hooks

  ;; taking this out so that stepper test cases will work correctly:
  
  #;(let ([prim-eval (current-eval)])
      (current-eval (lambda (expr) (!! (prim-eval expr)))))

)

#|
;; Some tests
(cadr (list (/ 1 0) 1 (/ 1 0))) -> 1
(foldl + 0 '(1 2 3 4)) -> 10
(foldl (lambda (x y) y) 0 (list (/ 1 0) (/ 2 0) (/ 3 0))) -> 0
(foldl (lambda (x y) y) 0 (cons (/ 1 0) (cons (/ 2 0) '()))) -> 0
(foldr + 0 '(1 2 3 4)) -> 10
(foldr (lambda (x y) y) 0 (list (/ 1 0) (/ 2 0) (/ 3 0))) -> 0
(foldr (lambda (x y) y) 0 (cons (/ 1 0) (cons (/ 2 0) '()))) -> 0
(define ones (cons 1 ones))
(take 5 (foldr cons '() ones)) -> (1 1 1 1 1)
(define a (list (/ 1 0) 2 (/ 3 0)))
(caadr (map list a)) -> 2
(cadr (map + a a)) -> 4
(andmap even? '(1 2 3 4)) -> #f
(ormap even? '(1 2 3 4)) -> #t
(ormap even? '(1 21 3 41)) -> #f
(andmap even? (list 1 2 3 (/ 4 0))) -> #f
|#