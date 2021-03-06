#lang racket/base

;; This module provides a cross-platform, polling based file watch.

(require
 racket/contract
 racket/list
 racket/set
 )

(provide
 (contract-out
  [robust-poll-milliseconds (parameter/c exact-positive-integer?)]
  [robust-watch  (->* () (path-on-disk? #:batch? boolean?) thread?)]))


;; ------------------------------------------------------------------
;; Implementation

(require
 racket/hash
 "./filesystem.rkt"
 "./threads.rkt")

(define-values (report-activity report-status) (report-iface 'robust))

(define robust-poll-milliseconds (make-parameter 250))

(define (get-file-attributes path)
  (with-handlers ([exn:fail? (λ _ #f)])
    (cons (file-or-directory-modify-seconds path)
          (file-or-directory-permissions path 'bits))))

(define (get-listing-numbers listing)
  (foldl
   (lambda (p res)
     (define attrs (get-file-attributes p))
     (append res (list
                  (if (not attrs)
                      -1
                      (+ (car attrs) (cdr attrs))))))
   '()
   listing))

(define (get-robust-state path)
  (define listing (if (file-exists? path)
                      (list path)
                      (recursive-file-list path)))
  (make-immutable-hash (map cons
                            listing
                            (get-listing-numbers listing))))

(define (mark-changes prev next)
  (hash-union prev next
              #:combine/key (lambda (k a b)
                              (if (= a b) 'same 'change))))

(define (mark-status prev next)
  (make-immutable-hash
   (map
    (lambda (pair)
      (if (symbol? (cdr pair))
          pair
          (cons (car pair)
                (if (path-on-disk? (car pair)) 'add 'remove))))
    (hash->list (mark-changes prev next)))))

(define (robust-watch [path (current-directory)] #:batch? [batch? #f])
  (define complete (path->complete-path (simplify-path path #t)))
  (thread (lambda ()
            (define initial (get-robust-state complete))
            (let loop ([state initial])
              (cond [(path-on-disk? complete)
                     (let* ([next (get-robust-state complete)]
                            [status-marked-hash (mark-status state next)]
                            )
                       (cond [(equal? #f batch?) ; no need to pull in racket/bool for one test
                              ; we should NOT batch notifications
                              (hash-for-each
                               status-marked-hash
                               (lambda (affected op)
                                 (unless (equal? op 'same)
                                   (report-activity op affected))))
                              ]
                             [else ; we SHOULD batch notifications

                              (let* ([report (filter-not (lambda (arg) (equal? 'same (cdr arg)))
                                                         (hash->list status-marked-hash))])
                                (when (not (null? report))
                                  (define messages
                                    (for/list ([item report])
                                      ;item looks like, e.g.:   (cons <path:/foo/bar> 'add)
                                      (list 'robust (cdr item) (car item))))
                                  (report-change-literal messages)))
                              ]
                             )
                       (sync/enable-break (alarm-evt (+ (current-inexact-milliseconds)
                                                        (robust-poll-milliseconds))))
                       (loop next))]
                    [else
                     (report-activity 'remove complete)])))))


(module+ test
  (require
   rackunit
   racket/async-channel
   racket/file
   (submod "./filesystem.rkt" test-lib)
   (submod "./threads.rkt" test-lib))

  (define (allow-poll) (sleep (/ (robust-poll-milliseconds) 1000)))
  (test-case
      "Robust watch over directory, unbatched"
    (parameterize ([current-directory (create-temp-directory)]
                   [robust-poll-milliseconds 50]
                   [file-activity-channel (make-async-channel)])
      (create-file "a")
      (create-file "b")
      (create-file "c")
      (define th (robust-watch))
      (allow-poll)
      (delete-file "c") (create-file "c")
      (delete-file "b")
      (allow-poll)
      (delete-directory/files (current-directory))
      (thread-wait th)

      ; TODO: Paratition these messages into "may appear" and "must appear"
      (define expected-messages
        `((robust change ,(build-path (current-directory) "c"))   ; must
          (robust remove ,(build-path (current-directory) "b"))   ; may
          (robust remove ,(build-path (current-directory)))))     ; must

      (let loop ()
        (define msg (file-watcher-channel-try-get))
        (when msg
          (check-true (and (member msg expected-messages) #t))
          (loop)))))


  (test-case
      "Robust watch over directory, batched"
    (parameterize ([current-directory (create-temp-directory)]
                   [robust-poll-milliseconds 50]
                   [file-activity-channel (make-async-channel)])
      (define dir2  (create-temp-directory))
      (parameterize ([current-directory dir2])
        (make-directory* (build-path "foo" "bar" "baz"))
        (current-directory (build-path "foo" "bar" "baz"))
        (create-file "a.txt")
        )

      (define th (robust-watch #:batch? #t))

      (allow-poll)

      (rename-file-or-directory (build-path dir2 "foo")
                                (build-path (current-directory) "foo"))
      (delete-directory/files dir2)

      (allow-poll)
      (allow-poll)

      (define messages (file-watcher-channel-try-get))

      (allow-poll)

      (define dir (current-directory))
      (check-equal? (sort messages path<? #:key last)
                    `((robust add ,(build-path dir "foo"))
                      (robust add ,(build-path dir "foo/bar"))
                      (robust add ,(build-path dir "foo/bar/baz"))
                      (robust add ,(build-path dir "foo/bar/baz/a.txt"))))
      (delete-directory/files (current-directory))
      (thread-wait th)))

  (test-case
      "Robust watch over file"
    (parameterize ([current-directory (create-temp-directory)]
                   [robust-poll-milliseconds 50]
                   [file-activity-channel (make-async-channel)])
      (create-file (build-path "a"))
      (define th (robust-watch "a"))
      (allow-poll)
      (delete-file "a")
      (allow-poll)
      (thread-wait th)
      (delete-directory/files (current-directory))
      (check-equal?
       (sync (file-activity-channel))
       `(robust remove ,(build-path (current-directory) "a"))))))
