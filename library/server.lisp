;;;; server.lisp — Rhema Unix socket REPL server
;;;; Allows any process on this machine to connect and evaluate expressions.
;;;; Start: (rhema-server:start) — runs in a background thread
;;;; Socket: /tmp/rhema.sock

(require :sb-bsd-sockets)

(defpackage :rhema-server
  (:use :cl :sb-bsd-sockets :sb-thread)
  (:export #:start #:stop #:*socket-path*))

(in-package :rhema-server)

(defvar *socket-path* "/tmp/rhema.sock")
(defvar *server-thread* nil)
(defvar *server-socket* nil)
(defvar *eval-lock* (make-mutex :name "rhema-eval"))

(defun safe-eval (expr-string)
  "Eval a string expression, return result string. Never signals."
  (with-mutex (*eval-lock*)
    (handler-case
      (let* ((form (read-from-string expr-string))
             (result (handler-bind ((warning #'muffle-warning))
                       (eval form))))
        (format nil "~A" result))
      (end-of-file ()
        "ERROR: incomplete expression")
      (error (c)
        (format nil "ERROR: ~A" c)))))

(defun expression-complete-p (string)
  "Return T if STRING contains a complete readable s-expression.
   Uses READ-FROM-STRING to test — if it succeeds without END-OF-FILE,
   the expression is complete."
  (handler-case
      (progn (read-from-string string) t)
    (end-of-file () nil)
    (error () t)))  ; other errors (e.g. syntax) mean we should try eval to surface them

(defun handle-client (socket)
  "Read lines from client, accumulate into complete expressions, eval, and
   write delimited results back. Supports multiline s-expressions."
  (let ((stream (socket-make-stream socket
                                    :input t
                                    :output t
                                    :buffering :line
                                    :element-type 'character))
        (buffer ""))
    (handler-case
      (loop
        (let ((line (read-line stream nil nil)))
          (unless line
            ;; Connection closed — eval any remaining buffer
            (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) buffer)))
              (unless (string= trimmed "")
                (let ((result (safe-eval trimmed)))
                  (format stream "~%===RHEMA-BEGIN===~%~A~%===RHEMA-END===~%"
                          result)
                  (force-output stream))))
            (return))
          ;; Accumulate line into buffer
          (setf buffer
                (if (string= buffer "")
                    line
                    (concatenate 'string buffer (string #\Newline) line)))
          ;; Try to eval complete expressions from the buffer
          (loop
            (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) buffer)))
              (when (string= trimmed "")
                (setf buffer "")
                (return))
              (if (expression-complete-p trimmed)
                  ;; Complete expression — eval it
                  (handler-case
                      (multiple-value-bind (form pos)
                          (read-from-string trimmed)
                        (declare (ignore form))
                        (let* ((expr (subseq trimmed 0 pos))
                               (rest (string-trim '(#\Space #\Tab #\Return #\Newline)
                                                  (subseq trimmed pos)))
                               (result (safe-eval expr)))
                          (format stream "~%===RHEMA-BEGIN===~%~A~%===RHEMA-END===~%"
                                  result)
                          (force-output stream)
                          (setf buffer rest)))
                    (error (c)
                      (format stream "~%===RHEMA-BEGIN===~%ERROR: ~A~%===RHEMA-END===~%"
                              c)
                      (force-output stream)
                      (setf buffer "")
                      (return)))
                  ;; Incomplete — wait for more lines
                  (return))))))
      (error () nil))
    (handler-case (close stream) (error () nil))
    (handler-case (socket-close socket) (error () nil))))

(defun start (&optional (path *socket-path*))
  "Start the Unix socket REPL server in a background thread."
  (when (and *server-thread* (thread-alive-p *server-thread*))
    (format t "Rhema server already running on ~A~%" path)
    (return-from start nil))
  (when (probe-file path)
    (delete-file path))
  (setf *server-socket* (make-instance 'local-socket :type :stream))
  (socket-bind *server-socket* path)
  (socket-listen *server-socket* 8)
  ;; Restrict socket to owner only
  (sb-ext:run-program "/bin/chmod" (list "600" path))
  (setf *server-thread*
        (make-thread
          (lambda ()
            (loop
              (handler-case
                (let ((client (socket-accept *server-socket*)))
                  (make-thread
                    (lambda () (handle-client client))
                    :name "rhema-client"))
                (error () (return)))))
          :name "rhema-server"))
  (format t "Rhema socket server started: ~A~%" path)
  path)

(defun stop ()
  "Stop the socket server."
  (when *server-thread*
    (handler-case (terminate-thread *server-thread*) (error () nil))
    (setf *server-thread* nil))
  (when *server-socket*
    (handler-case (socket-close *server-socket*) (error () nil))
    (setf *server-socket* nil))
  (when (probe-file *socket-path*)
    (delete-file *socket-path*))
  (format t "Rhema socket server stopped.~%"))
