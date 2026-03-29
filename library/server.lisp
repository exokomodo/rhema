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

(defun handle-client (socket)
  "Read lines from client, eval each, write delimited result back."
  (let ((stream (socket-make-stream socket
                                    :input t
                                    :output t
                                    :buffering :line
                                    :element-type 'character)))
    (handler-case
      (loop
        (let ((line (read-line stream nil nil)))
          (unless line (return))
          (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
            (unless (string= trimmed "")
              (let ((result (safe-eval trimmed)))
                (format stream "~%===RHEMA-BEGIN===~%~A~%===RHEMA-END===~%"
                        result)
                (force-output stream))))))
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
