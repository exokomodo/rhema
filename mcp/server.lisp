;;;; mcp/server.lisp — Rhema MCP server (stdio transport)
;;;; JSON-RPC 2.0 over stdin/stdout, delegates to /tmp/rhema.sock
;;;; Run: sbcl --script mcp/server.lisp
;;;; Requires Quicklisp + jonathan for JSON.

(require :sb-bsd-sockets)

;;; Load Quicklisp and jonathan (suppress stdout to keep MCP transport clean)
(let ((*standard-output* *error-output*))
  (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
  (ql:quickload :jonathan :silent t))

;;; ============================================================
;;; JSON helpers (jonathan library)
;;; ============================================================

(defun parse-json (str)
  "Parse a JSON string into a hash table using jonathan."
  (jonathan:parse str :as :hash-table))

(defun json-get (obj key)
  "Get KEY from a parsed JSON object (hash table). KEY is a string."
  (when obj (gethash key obj)))

(defun alist-to-json-value (value)
  "Recursively convert alist-based response structures for JSON serialization.
   Alists with string keys become hash tables; lists become arrays."
  (cond
    ((eq value :false) :false)
    ((eq value :null) :null)
    ((eq value t) t)
    ((null value) :null)
    ((stringp value) value)
    ((numberp value) value)
    ;; Alist (object) — detect by first element being a cons with string car
    ((and (consp value) (consp (car value)) (stringp (caar value)))
     (let ((ht (make-hash-table :test 'equal)))
       (dolist (pair value)
         (setf (gethash (car pair) ht) (alist-to-json-value (cdr pair))))
       ht))
    ;; List (array)
    ((listp value)
     (mapcar #'alist-to-json-value value))
    (t value)))

(defun serialize-json (value)
  "Serialize a Lisp value to a JSON string using jonathan."
  (jonathan:to-json (alist-to-json-value value)))

;;; ============================================================
;;; Socket client — talk to /tmp/rhema.sock
;;; ============================================================

(defvar *rhema-socket-path* "/tmp/rhema.sock")
(defvar *rhema-timeout-seconds* 30)

(defun rhema-eval (expression)
  "Send EXPRESSION to the Rhema socket server and return the delimited result.
   Returns two values: result-string and error-p."
  (handler-case
      (let ((sock (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (unwind-protect
            (progn
              (sb-bsd-sockets:socket-connect sock *rhema-socket-path*)
              (let ((stream (sb-bsd-sockets:socket-make-stream
                             sock :input t :output t
                             :buffering :line
                             :element-type 'character)))
                (unwind-protect
                    (progn
                      ;; Send expression
                      (write-string expression stream)
                      (terpri stream)
                      (force-output stream)
                      ;; Shutdown write side so server sees EOF
                      (sb-bsd-sockets:socket-shutdown sock :direction :output)
                      ;; Read response, extract between delimiters
                      (let ((lines '())
                            (capturing nil)
                            (captured '()))
                        (loop for line = (read-line stream nil nil)
                              while line do
                              (cond
                                ((string= (string-trim '(#\Space #\Return) line)
                                          "===RHEMA-BEGIN===")
                                 (setf capturing t))
                                ((string= (string-trim '(#\Space #\Return) line)
                                          "===RHEMA-END===")
                                 (setf capturing nil)
                                 ;; Join captured lines
                                 (push (format nil "~{~A~^~%~}" (nreverse captured))
                                       lines)
                                 (setf captured '()))
                                (capturing
                                 (push line captured))))
                        (if lines
                            (values (format nil "~{~A~^~%~}" (nreverse lines)) nil)
                            (values "ERROR: No delimited response from Rhema" t))))
                  (close stream))))
          (handler-case (sb-bsd-sockets:socket-close sock) (error () nil))))
    (sb-bsd-sockets:socket-error (c)
      (values (format nil "ERROR: Cannot connect to ~A — ~A" *rhema-socket-path* c) t))
    (error (c)
      (values (format nil "ERROR: ~A" c) t))))

;;; ============================================================
;;; MCP protocol handlers
;;; ============================================================

(defvar *mcp-server-name* "rhema-mcp")
(defvar *mcp-server-version* "0.1.0")

(defun make-jsonrpc-response (id result)
  "Build a JSON-RPC 2.0 success response alist."
  `(("jsonrpc" . "2.0")
    ("id" . ,id)
    ("result" . ,result)))

(defun make-jsonrpc-error (id code message)
  "Build a JSON-RPC 2.0 error response alist."
  `(("jsonrpc" . "2.0")
    ("id" . ,id)
    ("error" . (("code" . ,code)
                ("message" . ,message)))))

(defun handle-initialize (id _params)
  "Handle initialize request — return server capabilities."
  (declare (ignore _params))
  (make-jsonrpc-response id
    `(("protocolVersion" . "2024-11-05")
      ("capabilities" . (("tools" . (("listChanged" . :false)))))
      ("serverInfo" . (("name" . ,*mcp-server-name*)
                       ("version" . ,*mcp-server-version*))))))

(defun handle-tools-list (id _params)
  "Handle tools/list — return available tools."
  (declare (ignore _params))
  (make-jsonrpc-response id
    `(("tools" .
       ((("name" . "rhema_eval")
         ("description" . "Evaluate a Common Lisp expression in the persistent Rhema REPL. The expression is sent to the SBCL process via /tmp/rhema.sock and the result is returned.")
         ("inputSchema" .
          (("type" . "object")
           ("properties" .
            (("expression" .
              (("type" . "string")
               ("description" . "A Common Lisp expression to evaluate")))))
           ("required" . ("expression"))))))))))

(defun handle-tools-call (id params)
  "Handle tools/call — dispatch to the requested tool."
  (let* ((tool-name (json-get params "name"))
         (arguments (json-get params "arguments")))
    (cond
      ((string= tool-name "rhema_eval")
       (let ((expression (json-get arguments "expression")))
         (if expression
             (multiple-value-bind (result errorp) (rhema-eval expression)
               (make-jsonrpc-response id
                 `(("content" .
                    ((("type" . "text")
                      ("text" . ,result))))
                   ,@(when errorp
                       `(("isError" . t))))))
             (make-jsonrpc-error id -32602 "Missing required argument: expression"))))
      (t
       (make-jsonrpc-error id -32602 (format nil "Unknown tool: ~A" tool-name))))))

;;; ============================================================
;;; Main loop — stdio JSON-RPC transport
;;; ============================================================

(defun send-response (response)
  "Serialize and write a JSON-RPC response to stdout."
  (let ((json (serialize-json response)))
    (write-string json *standard-output*)
    (terpri *standard-output*)
    (force-output *standard-output*)))

(defun process-message (msg)
  "Dispatch a parsed JSON-RPC message. Returns response or nil for notifications."
  (let ((method (json-get msg "method"))
        (id (json-get msg "id"))
        (params (or (json-get msg "params") (make-hash-table))))
    (cond
      ;; Notifications (no id) — don't respond
      ((and (null id) (string= method "notifications/initialized"))
       nil)
      ((and (null id) method)
       ;; Unknown notification — silently ignore
       nil)
      ;; Requests
      ((string= method "initialize")
       (handle-initialize id params))
      ((string= method "tools/list")
       (handle-tools-list id params))
      ((string= method "tools/call")
       (handle-tools-call id params))
      ;; Unknown method
      (id
       (make-jsonrpc-error id -32601 (format nil "Method not found: ~A" method)))
      (t nil))))

(defun main-loop ()
  "Read JSON-RPC messages from stdin, dispatch, respond on stdout."
  ;; Redirect any stray debug output to stderr so stdout stays clean
  (let ((*error-output* *error-output*)
        (*trace-output* *error-output*)
        (*debug-io* (make-two-way-stream *standard-input* *error-output*)))
    (loop for line = (read-line *standard-input* nil nil)
          while line do
          (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
            (unless (string= trimmed "")
              (handler-case
                  (let* ((msg (parse-json trimmed))
                         (response (process-message msg)))
                    (when response
                      (send-response response)))
                (error (c)
                  ;; Parse error or internal error — send JSON-RPC error
                  (send-response
                   (make-jsonrpc-error :null -32700
                     (format nil "Parse error: ~A" c))))))))))

;; Suppress SBCL startup noise
(handler-case
    (progn
      ;; Log to stderr so MCP host can see it
      (format *error-output* "rhema-mcp: starting stdio transport~%")
      (force-output *error-output*)
      (main-loop)
      (sb-ext:exit :code 0))
  (error (c)
    (format *error-output* "rhema-mcp: fatal error: ~A~%" c)
    (force-output *error-output*)
    (sb-ext:exit :code 1)))
