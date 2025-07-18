(in-package #:org.shirakumo.cocoas)

(defvar *init* NIL)

(define-condition foundation-error (error)
  ((name :initarg :name :initform NIL :reader name)
   (reason :initarg :reason :initform NIL :reader reason))
  (:report (lambda (c s) (format s "Foundation error ~s~@[~%  ~a~]"
                                 (name c) (reason c)))))

(defun foundation-error (exception &optional (type 'foundation-error))
  (etypecase exception
    (cffi:foreign-pointer
     (error type
            :name (objc:call exception "name" nsstring)
            :reason (objc:call exception "reason" nsstring)))
    (string
     (error type :name exception))))

(cffi:defcallback %foundation-error :void ((exception :pointer))
  (foundation-error exception))

(defun init (&rest libs)
  (unless *init*
    (let ((libs (or libs '(:foundation :cocoa :appkit))))
      (unless (cffi:foreign-library-loaded-p 'objc:foundation)
        (cffi:load-foreign-library 'objc:foundation)
        (objc:set-uncaught-exception-handler (cffi:callback %foundation-error)))
      (when (member :cocoa libs)
        (unless (cffi:foreign-library-loaded-p 'objc:cocoa)
          (cffi:load-foreign-library 'objc:cocoa)))
      (when (member :appkit libs)
        (unless (cffi:foreign-library-loaded-p 'objc:appkit)
          (cffi:load-foreign-library 'objc:appkit)))
      (setf *init* T)
      (register-classes))))

(defun shutdown ()
  (when *init*
    (setf *init* NIL)))

(defun to-method-name (name)
  (etypecase name
    (string
     name)
    (symbol
     (with-output-to-string (out)
       (loop with upcase = NIL
             for char across (string name)
             do (case char
                  (#\/ (write-char #\: out))
                  (#\- (setf upcase T))
                  (T (if upcase
                         (write-char (char-upcase char) out)
                         (write-char (char-downcase char) out))
                   (setf upcase NIL))))))))

(defun to-set-method-name (name)
  (to-method-name (make-symbol (concatenate 'string "set-" (string name)))))

(defmacro define-objcfun (class mname rettype &body args)
  (destructuring-bind (name &optional (method (to-method-name (if (listp mname) (first mname) mname)))) 
      (if (listp mname) mname
          (list (intern (format NIL "~a-~a"
                                (string-upcase class)
                                (symbol-name mname)))))
    (etypecase class
      (symbol (setf class (cffi:translate-camelcase-name class :upper-initial-p T)))
      (string))
    `(defun ,name ,(loop for (name) in args collect name)
       (objc:call ,class ,method
                  ,@(loop for (name type) in args
                          collect type
                          collect name)
                  ,(or rettype 'objc:id)))))

(defmacro define-objcmethod (name rettype &body args)
  (destructuring-bind
      (name &optional method) (if (listp name) name (list name))
    (if (listp name)
        (if (eq (car name) 'setf)
            (progn
              (unless method (setf method (to-set-method-name (cadr name))))
              (if (cdr args) (error "Only one argument allowed ~a" args))
              (let ((self (gensym "SELF")))
                `(defun ,name (,(caar args) ,self)
                   (objc:call ,self ,method ,(cadar args) ,(caar args)
                              ,(or rettype 'objc:id)))))
            (error "Invalid call ~a" name))
        (progn
          (unless method (setf method (to-method-name name)))
          (let ((self (gensym "SELF")))
            `(defun ,name (,self ,@(loop for (name) in args collect name))
               (objc:call ,self ,method
                          ,@(loop for (name type) in args
                                  collect type
                                  collect name)
                          ,(or rettype 'objc:id))))))))

(defmacro with-objects (bindings &body body)
  (if bindings
      (destructuring-bind (var init &optional fail) (pop bindings)
        `(let ((,var ,init))
           (if (cffi:null-pointer-p ,var)
               ,(or fail `(error "The ObjC call to ~a failed." ',(car init)))
               (unwind-protect
                    (with-objects ,bindings ,@body)
                 (objc:autorelease ,var))))) ; changed from objc:free
      `(progn ,@body)))

(defmacro with-foundation-objects (bindings &body body)
  (if bindings
      (destructuring-bind (var init &optional fail) (pop bindings)
        `(let ((,var ,init))
           (if (cffi:null-pointer-p ,var)
               ,(or fail `(error "The OS call to ~a failed." ',(car init)))
               (unwind-protect
                    (with-foundation-objects ,bindings ,@body)
                 (objc:release ,var)))))
      `(progn ,@body)))

(defun process-event (&key (app objc:app) timeout)
  (with-objects ((date (etypecase timeout
                         (null (objc:call "NSDate" "distantPast"))
                         ((eql T) (objc:call "NSDate" "distantFuture"))
                         (real (objc:call "NSDate" "dateWithTimeIntervalSinceNow:"
                                          :double (double timeout 0d0)))))) ; FIXME no fn double ?
    (let ((event (objc:call app "nextEventMatchingMask:untilDate:inMode:dequeue:"
                            objc:event-mask :any
                            :pointer date
                            :pointer objc:default-run-loop-mode
                            :bool T)))
      (unless (cffi:null-pointer-p event)
        (objc:call app "sendEvent:" :pointer event)))))

(defmacro with-main-loop (&body init)
  `(trivial-main-thread:with-body-in-main-thread ()
     (float-features:with-float-traps-masked T
       ,@init)))
