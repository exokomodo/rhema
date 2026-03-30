;;;; mcp/server.lisp — Rhema MCP server (stdio transport)
;;;; JSON-RPC 2.0 over stdin/stdout, delegates to /tmp/rhema.sock
;;;; Run: sbcl --script mcp/server.lisp
;;;; Zero external dependencies — SBCL built-ins only.

(require :sb-bsd-sockets)

;;; ============================================================
;;; Minimal JSON parser (handles MCP envelopes only)
;;; ============================================================

(defun skip-ws (str pos)
  "Skip whitespace in STR starting at POS."
  (loop while (and (< pos (length str))
                   (member (char str pos) '(#\Space #\Tab #\Newline #\Return)))
        do (incf pos))
  pos)

(defun parse-json-string (str pos)
  "Parse a JSON string starting at POS (after opening quote). Returns (values string new-pos)."
  (assert (char= (char str pos) #\"))
  (incf pos) ; skip opening "
  (let ((out (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (when (>= pos (length str))
        (error "Unterminated JSON string"))
      (let ((ch (char str pos)))
        (cond
          ((char= ch #\")
           (return (values (coerce out 'simple-string) (1+ pos))))
          ((char= ch #\\)
           (incf pos)
           (when (>= pos (length str))
             (error "Unterminated JSON escape"))
           (let ((esc (char str pos)))
             (vector-push-extend
              (case esc
                (#\" #\")
                (#\\ #\\)
                (#\/ #\/)
                (#\n #\Newline)
                (#\r #\Return)
                (#\t #\Tab)
                (#\b #\Backspace)
                (#\f (code-char 12))
                (#\u
                 ;; Parse 4-hex-digit unicode escape
                 (let ((hex (subseq str (1+ pos) (+ pos 5))))
                   (setf pos (+ pos 4))
                   (code-char (parse-integer hex :radix 16))))
                (t esc))
              out)
             (incf pos)))
          (t
           (vector-push-extend ch out)
           (incf pos)))))))

(defun parse-json-number (str pos)
  "Parse a JSON number. Returns (values number new-pos)."
  (let ((start pos)
        (has-dot nil))
    (when (and (< pos (length str)) (char= (char str pos) #\-))
      (incf pos))
    (loop while (and (< pos (length str))
                     (or (digit-char-p (char str pos))
                         (and (char= (char str pos) #\.) (not has-dot))))
          do (when (char= (char str pos) #\.)
               (setf has-dot t))
             (incf pos))
    ;; Handle exponent
    (when (and (< pos (length str))
               (member (char str pos) '(#\e #\E)))
      (incf pos)
      (when (and (< pos (length str))
                 (member (char str pos) '(#\+ #\-)))
        (incf pos))
      (loop while (and (< pos (length str))
                       (digit-char-p (char str pos)))
            do (incf pos)))
    (let ((num-str (subseq str start pos)))
      (if has-dot
          (values (read-from-string num-str) pos)
          (values (parse-integer num-str) pos)))))

(defun parse-json-value (str pos)
  "Parse a JSON value at POS. Returns (values value new-pos)."
  (setf pos (skip-ws str pos))
  (when (>= pos (length str))
    (error "Unexpected end of JSON"))
  (let ((ch (char str pos)))
    (cond
      ((char= ch #\")
       (parse-json-string str pos))
      ((char= ch #\{)
       (parse-json-object str pos))
      ((char= ch #\[)
       (parse-json-array str pos))
      ((char= ch #\t) ; true
       (values t (+ pos 4)))
      ((char= ch #\f) ; false
       (values nil (+ pos 5)))
      ((char= ch #\n) ; null
       (values :null (+ pos 4)))
      ((or (digit-char-p ch) (char= ch #\-))
       (parse-json-number str pos))
      (t (error "Unexpected JSON character ~A at ~D" ch pos)))))

(defun parse-json-object (str pos)
  "Parse a JSON object. Returns (values alist new-pos)."
  (assert (char= (char str pos) #\{))
  (incf pos)
  (setf pos (skip-ws str pos))
  (let ((result '()))
    (when (char= (char str pos) #\})
      (return-from parse-json-object (values result (1+ pos))))
    (loop
      (setf pos (skip-ws str pos))
      (multiple-value-bind (key new-pos) (parse-json-string str pos)
        (setf pos (skip-ws str new-pos))
        (assert (char= (char str pos) #\:))
        (incf pos)
        (multiple-value-bind (val val-pos) (parse-json-value str pos)
          (push (cons key val) result)
          (setf pos (skip-ws str val-pos))
          (cond
            ((char= (char str pos) #\})
             (return (values (nreverse result) (1+ pos))))
            ((char= (char str pos) #\,)
             (incf pos))
            (t (error "Expected , or } in object"))))))))

(defun parse-json-array (str pos)
  "Parse a JSON array. Returns (values list new-pos)."
  (assert (char= (char str pos) #\[))
  (incf pos)
  (setf pos (skip-ws str pos))
  (let ((result '()))
    (when (char= (char str pos) #\])
      (return-from parse-json-array (values result (1+ pos))))
    (loop
      (multiple-value-bind (val new-pos) (parse-json-value str pos)
        (push val result)
        (setf pos (skip-ws str new-pos))
        (cond
          ((char= (char str pos) #\])
           (return (values (nreverse result) (1+ pos))))
          ((char= (char str pos) #\,)
           (incf pos))
          (t (error "Expected , or ] in array")))))))

(defun parse-json (str)
  "Parse a JSON string into Lisp. Objects become alists, arrays become lists."
  (multiple-value-bind (val _pos) (parse-json-value str 0)
    (declare (ignore _pos))
    val))

(defun json-get (obj key)
  "Get KEY from a parsed JSON object (alist). KEY is a string."
  (cdr (assoc key obj :test #'string=)))

;;; ============================================================
;;; Minimal JSON serializer
;;; ============================================================

(defun json-escape-string (s)
  "Escape a Lisp string for JSON output."
  (with-output-to-string (out)
    (loop for ch across s do
      (case ch
        (#\" (write-string "\\\"" out))
        (#\\ (write-string "\\\\" out))
        (#\Newline (write-string "\\n" out))
        (#\Return (write-string "\\r" out))
        (#\Tab (write-string "\\t" out))
        (#\Backspace (write-string "\\b" out))
        (t
         (if (< (char-code ch) 32)
             (format out "\\u~4,'0X" (char-code ch))
             (write-char ch out)))))))

(defun serialize-json (value)
  "Serialize a Lisp value to JSON string.
   Alists with string keys -> objects, lists -> arrays,
   strings -> strings, numbers -> numbers, t -> true, nil -> false, :null -> null."
  (cond
    ((eq value :null) "null")
    ((eq value t) "true")
    ((null value) "false")
    ((stringp value)
     (format nil "\"~A\"" (json-escape-string value)))
    ((integerp value)
     (format nil "~D" value))
    ((numberp value)
     (format nil "~F" value))
    ;; Alist (object) — detect by first element being a cons with string car
    ((and (consp value) (consp (car value)) (stringp (caar value)))
     (format nil "{~{~A~^,~}}"
             (mapcar (lambda (pair)
                       (format nil "\"~A\":~A"
                               (json-escape-string (car pair))
                               (serialize-json (cdr pair))))
                     value)))
    ;; List (array)
    ((listp value)
     (format nil "[~{~A~^,~}]"
             (mapcar #'serialize-json value)))
    (t (format nil "\"~A\"" (json-escape-string (format nil "~A" value))))))

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
      ("capabilities" . (("tools" . (("listChanged" . ,nil)))))
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
        (params (or (json-get msg "params") '())))
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
