;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-COLD")

;;; The list below contains the name of every symbol whose function might be
;;; called from a non-compiled format string. This is important only for SBCL
;;; as host lisp built prior to git revision 6d743d78d9ba840b.
;;; For such hosts, after giving all host packages a new name, we must ASAP
;;; reestablish the function bindings of these "missing" symbols.
;;;
;;; * PRINT-SYMBOL-WITH-PREFIX was added in rev ff218a24fbd70b2e (2007-04-29)
;;;   and later exported from SB-EXT with no explanation.
;;;   It was occasionally invoked via SB-IMPL: which it no longer is.
;;;
;;; * SB-IMPL:PRINT-TYPE and SB-IMPL:PRINT-TYPE-SPECIFIER were first added
;;;   in rev c1b03a36ec4439c8 (2016-01-09). Newer code always uses them
;;;   from SB-IMPL but older code used them from SB-EXT as well.
;;;
;;; The other 3 functions mentioned below have been stable
;;; in that they are always used from SB-IMPL.
;;;
;;; This list must contain names of functions used by *ANY* past revision
;;; even if such function does not appear in current code.  The list does
;;; not need additions to it for future changes though. i.e. this is final.
;;;
(defparameter *host-format-function-names*
  '("PRINT-SYMBOL-WITH-PREFIX"
    "PRINT-TYPE"
    "PRINT-TYPE-SPECIFIER"
    "FORMAT-MILLISECONDS"
    "FORMAT-MICROSECONDS"
    "PRINT-DEPRECATION-REPLACEMENTS"))
(defparameter *host-format-functions* nil)

;;; Rename all host packages, but unhide the host's format functions
;;; for hosts that do not support renaming of internal packages.
;;; Consider all situations in which functions are called via ~// directives:
;;; - The host calls ~/PRINT-TYPE/ for itself (i.e in its compiler) while
;;;   running make-host-1 because "our" code (being compiled) is wrong.
;;;   Barring a host bug (such as was fixed in rev e6fd2a9635e4),
;;;   the format string referencing this function would spell the name
;;;   using a "dash" package. We restore the format functions into the
;;;   expected package below.
;;; - The cross-compiler wants to call a ~// function while executing,
;;;   maybe even from a macro. The format control string should spell the
;;;   function as a "bang" package. If it didn't, the string is wrong.
;;; - The target wants to call a ~// function.
;;;   That's conceptually the easiest to deal with - we've already ensured
;;;   that cross-compiled format strings dump their symbols correctly.
;;;
#+sbcl
(defun hide-host-packages ()
  ;; Rename
  (sb-ext:without-package-locks
   (dolist (pkg (list-all-packages))
     (let ((name (package-name pkg)))
       (unless (member name '("KEYWORD" "COMMON-LISP"  "COMMON-LISP-USER"
                              "SB-COLD" "SB!XC")
                       :test #'string=)
         ;; This also removes nicknames SEQUENCE and SB-C-CALL.
         (rename-package pkg (concatenate 'string "HOST-" name)))))))

#+sbcl
(defun unhide-host-format-funs ()
  ;; Restore operation
  (unless (find-symbol "FMT-CONTROL" "HOST-SB-FORMAT")
    (format t "~&; Restoring format control functions~%")
    ;; Copy the definitions from SB-EXT and SB-IMPL as needed.
    (dolist (symbol-name *host-format-function-names*)
      (dolist (package-name '("SB-EXT" "SB-IMPL"))
        (multiple-value-bind (host-symbol access)
            (find-symbol symbol-name (concatenate 'string "HOST-" package-name))
          (when (and access (fboundp host-symbol))
            (let ((original-fun (fdefinition host-symbol)))
              (push (list* host-symbol original-fun package-name)
                    *host-format-functions*)
              (setf (fdefinition (intern symbol-name package-name))
                    original-fun)))))))

  nil)

#-sbcl
(progn (defun hide-host-packages ())
       (defun unhide-host-format-funs ()))

(compile 'hide-host-packages)
(compile 'unhide-host-format-funs)

;;; Macro invoked from 'src/code/early-extensions' to avoid clobbering
;;; host functions that are potentially called from format strings.
(export 'preserving-host-function)
(defmacro preserving-host-function (defun)
  (let ((name (second defun)))
    `(progn
       ;; Assume that this function got a definition from set-up-cold-packages
       ;; and prevent a possible redefinition warning.
       (fmakunbound ',name)
       ,defun
       (restore-host-function ',(string name)))))

(defun restore-host-function (name)
  #+sbcl
  (let ((host-fun (second (assoc name *host-format-functions* :test #'string=))))
    (when host-fun
      (if (string= name "PRINT-TYPE")
          (let* ((our-fun (fdefinition (intern name "SB-IMPL")))
                 (combined
                  (lambda (stream object &rest rest)
                    (let ((ours (typep object (find-symbol "CTYPE" "SB-KERNEL"))))
                      (apply (if ours our-fun host-fun) stream object rest)))))
            (dolist (entry *host-format-functions*)
              (when (string= (car entry) 'print-type)
                (let ((symbol (intern name (cddr entry))))
                  ;; The parallelized build performs this twice: once from
                  ;;interpreted load, again from compilation.
                  ;; So don't wrap more than once.
                  (unless (sb-kernel:closurep (fdefinition symbol))
                    (setf (fdefinition symbol) combined))))))
          (dolist (entry *host-format-functions*)
            (when (string= (car entry) name)
              (setf (fdefinition (intern name (cddr entry))) host-fun)))))))

;;; an entry in the table which describes the non-standard part (i.e. not
;;; CL/CL-USER/KEYWORD) of the package structure of the SBCL system
;;;
;;; We make no attempt to be fully general; our table doesn't need to be
;;; able to express features which we don't happen to use.
(export '(genesis
          package-data
          make-package-data
          package-data-name
          package-data-export
          package-data-reexport
          package-data-import-from
          package-data-use))
(defstruct package-data
  ;; a string designator for the package name
  (name (error "missing PACKAGE-DATA-NAME datum"))
  ;; a doc string
  (doc (error "missing PACKAGE-DOC datum"))
  ;; a tree containing names for exported symbols which'll be set up at package
  ;; creation time, and NILs, which are ignored. (This is a tree in order to
  ;; allow constructs like '("ENOSPC" #!+LINUX ("EDQUOT" "EISNAM" "ENAVAIL"
  ;; "EREMOTEIO")) to be used in initialization. NIL entries in the tree are
  ;; ignored for the same reason of notational convenience.)
  export
  ;; a list of string designators for exported symbols which don't necessarily
  ;; originate in this package (so their EXPORT operations should be handled
  ;; after USE operations have been done, so that duplicates aren't created)
  reexport
  ;; a list of sublists describing imports. Each sublist has the format as an
  ;; IMPORT-FROM list in DEFPACKAGE: the first element is the name of the
  ;; package to import from, and the remaining elements are the names of
  ;; symbols to import.
  import-from
  ;; a tree of string designators for package names of other packages
  ;; which this package uses
  use)

;; The running-in-the-host-Lisp Python cross-compiler defines its
;; own versions of a number of functions which should not overwrite
;; host-Lisp functions. Instead we put them in a special package.
;;
;; The common theme of the functions, macros, constants, and so
;; forth in this package is that they run in the host and affect the
;; compilation of the target.
;;
;; FIXME: this package should have only one name, not two,
;; and its one name should be SBCL, but changing it to that
;; would entail touching about 900 lines.
(let ((package-name "SB!XC"))
  (dolist (name '(;; the constants (except for T and NIL which have
                  ;; a specially hacked correspondence between
                  ;; cross-compilation host Lisp and target Lisp)
                  "ARRAY-DIMENSION-LIMIT"
                  "ARRAY-RANK-LIMIT"
                  "ARRAY-TOTAL-SIZE-LIMIT"
                  "BOOLE-1"
                  "BOOLE-2"
                  "BOOLE-AND"
                  "BOOLE-ANDC1"
                  "BOOLE-ANDC2"
                  "BOOLE-C1"
                  "BOOLE-C2"
                  "BOOLE-CLR"
                  "BOOLE-EQV"
                  "BOOLE-IOR"
                  "BOOLE-NAND"
                  "BOOLE-NOR"
                  "BOOLE-ORC1"
                  "BOOLE-ORC2"
                  "BOOLE-SET"
                  "BOOLE-XOR"
                  "CALL-ARGUMENTS-LIMIT"
                  "CHAR-CODE-LIMIT"
                  "DOUBLE-FLOAT-EPSILON"
                  "DOUBLE-FLOAT-NEGATIVE-EPSILON"
                  "INTERNAL-TIME-UNITS-PER-SECOND"
                  "LAMBDA-LIST-KEYWORDS"
                  "LAMBDA-PARAMETERS-LIMIT"
                  "LEAST-NEGATIVE-DOUBLE-FLOAT"
                  "LEAST-NEGATIVE-LONG-FLOAT"
                  "LEAST-NEGATIVE-NORMALIZED-DOUBLE-FLOAT"
                  "LEAST-NEGATIVE-NORMALIZED-LONG-FLOAT"
                  "LEAST-NEGATIVE-NORMALIZED-SHORT-FLOAT"
                  "LEAST-NEGATIVE-NORMALIZED-SINGLE-FLOAT"
                  "LEAST-NEGATIVE-SHORT-FLOAT"
                  "LEAST-NEGATIVE-SINGLE-FLOAT"
                  "LEAST-POSITIVE-DOUBLE-FLOAT"
                  "LEAST-POSITIVE-LONG-FLOAT"
                  "LEAST-POSITIVE-NORMALIZED-DOUBLE-FLOAT"
                  "LEAST-POSITIVE-NORMALIZED-LONG-FLOAT"
                  "LEAST-POSITIVE-NORMALIZED-SHORT-FLOAT"
                  "LEAST-POSITIVE-NORMALIZED-SINGLE-FLOAT"
                  "LEAST-POSITIVE-SHORT-FLOAT"
                  "LEAST-POSITIVE-SINGLE-FLOAT"
                  "LONG-FLOAT-EPSILON"
                  "LONG-FLOAT-NEGATIVE-EPSILON"
                  "MOST-NEGATIVE-DOUBLE-FLOAT"
                  "MOST-NEGATIVE-FIXNUM"
                  "MOST-NEGATIVE-LONG-FLOAT"
                  "MOST-NEGATIVE-SHORT-FLOAT"
                  "MOST-NEGATIVE-SINGLE-FLOAT"
                  "MOST-POSITIVE-DOUBLE-FLOAT"
                  "MOST-POSITIVE-FIXNUM"
                  "MOST-POSITIVE-LONG-FLOAT"
                  "MOST-POSITIVE-SHORT-FLOAT"
                  "MOST-POSITIVE-SINGLE-FLOAT"
                  "MULTIPLE-VALUES-LIMIT"
                  "PI"
                  "SHORT-FLOAT-EPSILON"
                  "SHORT-FLOAT-NEGATIVE-EPSILON"
                  "SINGLE-FLOAT-EPSILON"
                  "SINGLE-FLOAT-NEGATIVE-EPSILON"

                  ;; everything else which needs a separate
                  ;; existence in xc and target
                  "BYTE" "BYTE-POSITION" "BYTE-SIZE"
                  "CHAR-CODE"
                  "CODE-CHAR"
                  "COMPILE-FILE"
                  "COMPILE-FILE-PATHNAME"
                  "*COMPILE-FILE-PATHNAME*"
                  "*COMPILE-FILE-TRUENAME*"
                  "*COMPILE-PRINT*"
                  "*COMPILE-VERBOSE*"
                  "COMPILER-MACRO-FUNCTION"
                  "CONSTANTP"
                  "DEFCONSTANT"
                  "DEFINE-MODIFY-MACRO"
                  "DEFINE-SETF-EXPANDER"
                  "DEFMACRO" "DEFSETF" "DEFSTRUCT" "DEFTYPE"
                  "DEPOSIT-FIELD" "DPB"
                  "GENSYM" "*GENSYM-COUNTER*"
                  "GET-SETF-EXPANSION"
                  "LDB" "LDB-TEST"
                  "LISP-IMPLEMENTATION-TYPE" "LISP-IMPLEMENTATION-VERSION"
                  "MACRO-FUNCTION"
                  "MACROEXPAND" "MACROEXPAND-1" "*MACROEXPAND-HOOK*"
                  "MAKE-LOAD-FORM"
                  "MAKE-LOAD-FORM-SAVING-SLOTS"
                  "MASK-FIELD"
                  "PROCLAIM"
                  "SPECIAL-OPERATOR-P"
                  "SUBTYPEP"
                  "TYPE-OF" "TYPEP"
                  "UPGRADED-ARRAY-ELEMENT-TYPE"
                  "UPGRADED-COMPLEX-PART-TYPE"
                  "WITH-COMPILATION-UNIT"))
      (export (intern name package-name) package-name)))

;; Symbols that we want never to accidentally see the host's definition of.
(defparameter *shadowing-imports*
  (mapcar (lambda (name) (find-symbol name "SB!XC"))
          '("BYTE" "BYTE-POSITION" "BYTE-SIZE"
            "DPB" "LDB" "LDB-TEST"
            "DEPOSIT-FIELD" "MASK-FIELD")))

(let ((package-data-list (read-from-file "package-data-list.lisp-expr")))
  (labels ((flatten (tree)
             (mapcan (lambda (x) (if (listp x) (flatten x) (list x)))
                     tree)))

    (hide-host-packages)

    ;; Build all packages that we need, and initialize them as far as we
    ;; can without referring to any other packages.
    (dolist (package-data package-data-list)
      (let* ((name (package-data-name package-data))
             (package (make-package
                       name
                       :nicknames (list (concatenate 'string "SB!" (subseq name 3)))
                       :use nil)))
        (shadowing-import *shadowing-imports* package)
        ;; Walk the tree of exported names, exporting each name.
        (dolist (string (flatten (package-data-export package-data)))
          (export (intern string package) package))))

    ;; Now that all packages exist, we can set up package-package
    ;; references.
    (dolist (package-data package-data-list)
      (use-package (package-data-use package-data)
                   (package-data-name package-data))
      (dolist (sublist (package-data-import-from package-data))
        (let ((from-package (first sublist)))
          (import (mapcar (lambda (name) (intern name from-package))
                          (rest sublist))
                  (package-data-name package-data)))))

    (unhide-host-format-funs)

    ;; Now that all package-package references exist, we can handle
    ;; REEXPORT operations. (We have to wait until now because they
    ;; interact with USE operations.)  This code handles dependencies
    ;; properly, but is somewhat ugly.
    (let (done)
      (labels
          ((reexport (package-data)
             (let ((package (find-package (package-data-name package-data))))
               (cond
                 ((member package done))
                 ((null (package-data-reexport package-data))
                  (push package done))
                 (t
                  (mapcar #'reexport
                          (remove-if-not
                           (lambda (x)
                             (member x (package-data-use package-data)
                                     :test #'string=))
                           package-data-list
                           :key #'package-data-name))
                  (dolist (symbol-name
                           (flatten (package-data-reexport package-data)))
                    (multiple-value-bind (symbol status)
                        (find-symbol symbol-name package)
                      (unless status
                        (error "No symbol named ~S is accessible in ~S."
                               symbol-name package))
                      (when (eq (symbol-package symbol) package)
                        (error
                         "~S is not inherited/imported, but native to ~S."
                         symbol-name package))
                      (export symbol package)))
                  (push package done))))))
        (dolist (x package-data-list)
          (reexport x))
        (assert (= (length done) (length package-data-list)))))))

(defun make-assembler-package (pkg-name)
  (when (find-package pkg-name)
    (delete-package pkg-name))
  (let ((pkg (make-package pkg-name
                           :nicknames
                           (list (concatenate 'string "SB!" (subseq pkg-name 3)))
                           :use '("CL" "SB-INT" "SB-EXT" "SB-KERNEL" "SB-VM"
                                  "SB-SYS" ; for SAP accessors
                                  ;; Dependence of the assembler on the compiler
                                  ;; feels a bit backwards, but assembly needs
                                  ;; TN-SC, TN-OFFSET, etc. because the compiler
                                  ;; doesn't speak the assembler's language.
                                  ;; Rather vice-versa.
                                  "SB-C"))))
    (shadowing-import *shadowing-imports* pkg)
    ;; Both SB-ASSEM and SB-DISASSEM export these two symbols.
    ;; Neither is shadowing-imported. If you need one, package-qualify it.
    (shadow '("SEGMENT" "MAKE-SEGMENT") pkg)
    (use-package '("SB-ASSEM" "SB-DISASSEM") pkg)
    pkg))

;; Each backend should have a different package for its instruction set
;; so that they can co-exist.
(make-assembler-package (backend-asm-package-name))

(defun package-list-for-genesis ()
  (append (read-from-file "package-data-list.lisp-expr")
          (let ((asm-package (backend-asm-package-name)))
            (list (make-package-data
                   :name asm-package
                   :use (mapcar 'package-name
                                (package-use-list asm-package))
                   :doc nil)))))
