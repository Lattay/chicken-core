;;;; egg-info processing and compilation
;
; Copyright (c) 2017-2018, The CHICKEN Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer.
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution.
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(define default-extension-options '())
(define default-program-options '())
(define default-static-program-link-options '())
(define default-dynamic-program-link-options '())
(define default-static-extension-link-options '())
(define default-dynamic-extension-link-options '())
(define default-program-linkage '(dynamic))
(define default-static-compilation-options '("-O2" "-d1"))
(define default-dynamic-compilation-options '("-O2" "-d1"))
(define default-import-library-compilation-options '("-O2" "-d0"))

(define default-extension-linkage
  (if staticbuild '(static) '(static dynamic)))

(define +unix-executable-extension+ "")
(define +windows-executable-extension+ ".exe")
(define +unix-object-extension+ ".o")
(define +windows-object-extension+ ".obj")
(define +link-file-extension+ ".link")

(define keep-generated-files #f)


;;; some utilities

(define override-prefix
  (let ((prefix (get-environment-variable "CHICKEN_INSTALL_PREFIX")))
    (lambda (dir default)
      (if prefix
          (string-append prefix dir)
          default))))

(define (object-extension platform)
  (case platform
    ((unix) +unix-object-extension+)
    ((windows) +windows-object-extension+)))

(define (executable-extension platform)
  (case platform
     ((unix) +unix-executable-extension+)
     ((windows) +windows-executable-extension+)))

(define (copy-directory-command platform)
  (case platform
    ((unix) "cp -r")
    ((windows) "xcopy /y /i")))

(define (mkdir-command platform)
  (case platform
    ((unix) "mkdir -p")
    ((windows) "mkdir")))

(define (install-executable-command platform)
  (case platform
    ((unix) "install -m755")
    ((windows) "copy /y")))

(define (install-file-command platform)
  (case platform
    ((unix) "install -m644")
    ((windows) "copy /y")))

(define (remove-file-command platform)
  (case platform
    ((unix) "rm -f")
    ((windows) "del /f /q")))

(define (cd-command platform) "cd")

(define (uses-compiled-import-library? mode)
  (not (and (eq? mode 'host) staticbuild)))


;;; topological sort with cycle check

(define (sort-dependencies dag eq)
  (condition-case (topological-sort dag eq)
    ((exn runtime cycle)
     (error "cyclic dependencies" dag))))


;;; collect import libraries for all modules

(define (import-libraries mods dest rtarget mode)
  (define (implib name)
    (conc dest "/" name ".import."
          (if (uses-compiled-import-library? mode)
              "so"
              "scm")))
  (if mods
      (map implib mods)
      (list (implib rtarget))))


;;; compile an egg-information tree into abstract build/install operations

(define (compile-egg-info eggfile info platform mode)
  (let ((exts '())
        (prgs '())
        (data '())
        (genfiles '())
        (cinc '())
        (scminc '())
        (target #f)
        (src #f)
        (files '())
        (ifiles '())
        (cbuild #f)
        (oname #f)
        (link '())
        (dest #f)
        (sdeps '())
        (cdeps '())
        (lopts '())
        (opts '())
        (mods #f)
        (tfile #f)
        (ptfile #f)
        (ifile #f)
        (eggfile (locate-egg-file eggfile))
        (objext (object-extension platform))
        (exeext (executable-extension platform)))
    (define (check-target t lst)
      (when (member t lst)
        (error "target multiply defined" t))
      t)
    (define (addfiles . filess)
      (set! ifiles (concatenate (cons ifiles filess)))
      files)
    (define (compile-component info)
      (case (car info)
        ((extension)
          (fluid-let ((target (check-target (cadr info) exts))
                      (cdeps '())
                      (sdeps '())
                      (src #f)
                      (cbuild #f)
                      (link default-extension-linkage)
                      (tfile #f)
                      (ptfile #f)
                      (ifile #f)
                      (lopts '())
                      (oname #f)
                      (mods #f)
                      (opts '()))
            (for-each compile-extension/program (cddr info))
            (let ((dest (destination-repository mode #t))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (when (eq? #t tfile) (set! tfile rtarget))
              (when (eq? #t ifile) (set! ifile rtarget))
              (addfiles 
                (if (memq 'static link) 
                    (list (conc dest "/" rtarget objext)
                          (conc dest "/" rtarget +link-file-extension+))
                    '())
                (if (memq 'dynamic link) (list (conc dest "/" rtarget ".so")) '())
                (if tfile 
                    (list (conc dest "/" tfile ".types"))
                    '())
                (if ifile 
                    (list (conc dest "/" ifile ".inline"))
                    '())
                (import-libraries mods dest rtarget mode))
              (set! exts
                (cons (list target dependencies: cdeps source: src options: opts
                            link-options: lopts linkage: link custom: cbuild
                            mode: mode types-file: tfile inline-file: ifile
                            predefined-types: ptfile eggfile: eggfile
                            modules: (or mods (list rtarget))
                            source-dependencies: sdeps
                            output-file: rtarget)
                    exts)))))
        ((data)
          (fluid-let ((target (check-target (cadr info) data))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest 
                             (if (eq? mode 'target)
                                 default-sharedir    ; XXX wrong!
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! data
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    data))))                      
        ((generated-source-file)
          (fluid-let ((target (check-target (cadr info) data))
                      (src #f)
                      (cbuild #f)
                      (sdeps '())
                      (cdeps '()))
            (for-each compile-extension/program (cddr info))
            (unless cbuild
              (error "generated source files need a custom build step" target))
            (set! genfiles
              (cons (list target dependencies: cdeps source: src 
                          custom: cbuild source-dependencies: sdeps)
                    genfiles))))
        ((c-include)
          (fluid-let ((target (check-target (cadr info) cinc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest 
                             (if (eq? mode 'target) 
                                 default-incdir   ; XXX wrong!
                                 (override-prefix "/include" host-incdir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! cinc
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    cinc))))            
        ((scheme-include)
          (fluid-let ((target (check-target (cadr info) scminc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (let* ((dest (or dest
                             (if (eq? mode 'target) 
                                 default-sharedir   ; XXX wrong!
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! scminc 
              (cons (list target dependencies: '() files: files 
                          destination: dest mode: mode) 
                    scminc))))     
        ((program)
          (fluid-let ((target (check-target (cadr info) prgs))
                      (cdeps '())
                      (sdeps '())
                      (cbuild #f)
                      (src #f)
                      (link default-program-linkage)
                      (lopts '())
                      (oname #f)
                      (opts '()))
            (for-each compile-extension/program (cddr info))
            (let ((dest (if (eq? mode 'target) 
                            default-bindir   ; XXX wrong!
                            (override-prefix "/bin" host-bindir)))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (addfiles (list (conc dest "/" rtarget exeext)))
	      (set! prgs
		(cons (list target dependencies: cdeps 
                            source: src options: opts
			    link-options: lopts linkage: link 
                            custom: cbuild
			    mode: mode output-file: rtarget 
                            source-dependencies: sdeps
                            eggfile: eggfile)
		      prgs)))))
        (else (compile-common info compile-component))))
    (define (compile-extension/program info)
      (case (car info)
        ((linkage) 
         (set! link (cdr info)))
        ((types-file)
         (set! tfile
           (cond ((null? (cdr info)) #t)
                 ((not (pair? (cadr info)))
                  (arg info 1 name?))
                 (else
                   (set! ptfile #t)
                   (set! tfile
                     (or (null? (cdadr info))
                         (arg (cadr info) 1 name?)))))))
        ((inline-file)
         (set! ifile (or (null? (cdr info)) (arg info 1 name?))))
        ((custom-build)
         (set! cbuild (->string (arg info 1 name?))))
        ((csc-options) 
         (set! opts (append opts (cdr info))))
        ((link-options)
         (set! lopts (append lopts (cdr info))))
        ((source)
         (set! src (->string (arg info 1 name?))))
        ((install-name)
         (set! oname (->string (arg info 1 name?))))
        ((modules)
         (set! mods (map ->string (cdr info))))
        ((component-dependencies)
         (set! cdeps (append cdeps (map ->dep (cdr info)))))
        ((source-dependencies)
         (set! sdeps (append sdeps (map ->dep (cdr info)))))
        (else (compile-common info compile-extension/program))))
    (define (compile-common info walk)
      (case (car info)
        ((target)
         (when (eq? mode 'target)
           (for-each walk (cdr info))))
        ((host)
         (when (eq? mode 'host)
           (for-each walk (cdr info))))))
    (define (compile-data/include info)
      (case (car info)
        ((destination)
         (set! dest (->string (arg info 1 name?))))
        ((files) 
         (set! files (append files (map ->string (cdr info)))))
        (else (compile-common info compile-data/include))))
    (define (->dep x)
      (if (name? x) x (error "invalid dependency" x)))
    (define (compile info)
      (case (car info)
        ((components) (for-each compile-component (cdr info)))
        (else (compile-common info compile))))
    (define (arg info n #!optional (pred (constantly #t)))
      (when (< (length info) n)
        (error "missing argument" info n))
      (let ((x (list-ref info n)))
        (unless (pred x)
          (error "argument has invalid type" x))
        x))
    (define (name? x) (or (string? x) (symbol? x)))
    (define dep=? equal?)
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))
    (define (filter-deps name deps)
      (filter (lambda (dep)
                (and (symbol? dep)
                     (or (assq dep exts)
                         (assq dep data)
                         (assq dep cinc)
                         (assq dep scminc)
                         (assq dep genfiles)
                         (error "unknown component dependency" dep name))))
              deps))
    ;; collect information
    (for-each compile info)
    ;; sort topologically, by dependencies
    (let* ((all (append prgs exts genfiles))
           (order (reverse (sort-dependencies      
                            (map (lambda (dep)
                                   (cons (car dep) 
                                         (filter-deps (car dep)
                                                      (get-keyword dependencies: (cdr dep)))))
                              all)
                            dep=?))))
      ;; generate + return build/install commands
      (values
        ;; build commands
        (append-map 
          (lambda (id)
            (cond ((assq id exts) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data)))
                           (mods (get-keyword modules: (cdr data))))
                       (append (if (memq 'dynamic link) 
                                   (list (apply compile-dynamic-extension data))
                                   '())
                               (if (memq 'static link) 
                                   ;; if compiling both static + dynamic, override
                                   ;; types-file: + inline-file: properties to
                                   ;; avoid generating things twice:
                                   (list (apply compile-static-extension
                                                (if (memq 'dynamic link)
                                                    (cons (car data)
                                                          (append '(types-file: #f
                                                                    inline-file: #f)
                                                                  (cdr data)))
                                                    data)))
                                   '())
                               (if (uses-compiled-import-library? mode)
                                   (map (lambda (mod)
                                          (apply compile-import-library
                                             mod (cdr data))) ; override name
                                     mods)
                                   '())))))
                  ((assq id prgs) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data))))
                       (append (if (memq 'dynamic link) 
                                   (list (apply compile-dynamic-program data))
                                   '())
                               (if (memq 'static link) 
                                   (list (apply compile-static-program data))
                                   '())))))
                  (else
                    (let ((data (assq id genfiles)))
                      (list (apply compile-generated-file data))))))
          order)
        ;; installation commands
        (append
          (append-map
            (lambda (ext)          
              (let ((link (get-keyword linkage: (cdr ext)))
                    (mods (get-keyword modules: (cdr ext))))
                (append
                  (if (memq 'static link)
                      (list (apply install-static-extension ext))
                      '())
                  (if (memq 'dynamic link)
                      (list (apply install-dynamic-extension ext))
                      '())
                  (if (and (memq 'dynamic link)
                           (uses-compiled-import-library? (get-keyword mode: ext)))
                      (map (lambda (mod)
                             (apply install-import-library
                                    mod (cdr ext))) ; override name
                        mods)
                      (map (lambda (mod)
                             (apply install-import-library-source
                                    mod (cdr ext))) ; s.a.
                        mods))
                  (if (get-keyword types-file: (cdr ext))
                      (list (apply install-types-file ext))
                      '())
                  (if (get-keyword inline-file: (cdr ext))
                      (list (apply install-inline-file ext))
                      '()))))
             exts)
          (map (lambda (prg) (apply install-program prg)) prgs)
          (map (lambda (data) (apply install-data data)) data)
          (map (lambda (cinc) (apply install-c-include cinc)) cinc)
          (map (lambda (scminc) (apply install-data scminc)) scminc))
        ;; augmented egg-info
        (cons `(installed-files ,@ifiles) info)))))


;;; shell code generation - build operations

(define ((compile-static-extension name #!key mode 
                                   source-dependencies
                                   source (options '())
                                   predefined-types eggfile
                                   custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (or (and custom (prefix srcdir custom))
                  default-csc))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (opts (append (if (null? options)
                           default-static-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file"
                                 (quotearg (prefix srcdir (conc types-file ".types"))))
                           '())
                       (if inline-file
                           (list "-emit-inline-file"
                                 (quotearg (prefix srcdir (conc inline-file ".inline"))))
                           '())))
         (out (quotearg (target-file (conc sname
                                           ".static"
                                           (object-extension platform))
                                     mode)))
         (src (quotearg (or ssname (conc sname ".scm")))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " " out " " cmd 
           (if keep-generated-files " -k" "")
           " -setup-mode -static -I " srcdir 
           " -emit-link-file "
           (quotearg (conc sname +link-file-extension+))
           (if (eq? mode 'host) " -host" "")
           " -D compiling-extension -c -unit " name
           " -D compiling-static-extension"
           " -C -I" srcdir (arglist opts) 
           " " src " -o " out " : "
           src " " (quotearg eggfile) " "
           (if custom (quotearg cmd) "") " "
           (filelist srcdir source-dependencies))))

(define ((compile-dynamic-extension name #!key mode mode
                                    source (options '()) (link-options '()) 
                                    predefined-types eggfile
                                    source-dependencies
                                    custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (or (and custom (prefix srcdir custom))
                  default-csc))
         (sname (prefix srcdir name))
         (opts (append (if (null? options)
                           default-dynamic-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file"
                                 (quotearg (prefix srcdir (conc types-file ".types"))))
                           '())
                       (if inline-file
                           (list "-emit-inline-file"
                                 (quotearg (prefix srcdir (conc inline-file ".inline"))))
                           '())))
         (ssname (and source (prefix srcdir source)))
         (out (quotearg (target-file (conc sname ".so") mode)))
         (src (quotearg (or ssname (conc sname ".scm")))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " " out " " cmd 
           (if keep-generated-files " -k" "")
           (if (eq? mode 'host) " -host" "")
           " -D compiling-extension -J -s"
           " -setup-mode -I " srcdir " -C -I" srcdir (arglist opts)
           (arglist link-options) " " src " -o " out " : "
           src " " (quotearg eggfile) " "
           (if custom (quotearg cmd) "") " "
           (filelist srcdir source-dependencies))))

(define ((compile-import-library name #!key mode
                                 source-dependencies
                                 (options '()) (link-options '())
                                 custom)
         srcdir platform)
  (let* ((cmd (or (and custom (prefix srcdir custom))
                  default-csc))
         (sname (prefix srcdir name))
         (opts (if (null? options) 
                   default-import-library-compilation-options
                   options))
         (out (quotearg (target-file (conc sname ".import.so") mode)))
         (src (quotearg (conc sname ".import.scm"))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " " out " " cmd 
           (if keep-generated-files " -k" "")
           " -setup-mode -s"
           (if (eq? mode 'host) " -host" "")
           " -I " srcdir " -C -I" srcdir (arglist opts)
           (arglist link-options) " " src " -o " out " : "
           src (filelist srcdir source-dependencies))))

(define ((compile-dynamic-program name #!key source mode
                                  (options '()) (link-options '())
                                  source-dependencies
                                  custom eggfile)
         srcdir platform)
  (let* ((cmd (or (and custom (prefix srcdir custom))
                  default-csc))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (opts (if (null? options) 
                   default-dynamic-compilation-options
                   options))
         (out (quotearg (target-file (conc sname
                                           (executable-extension platform)) 
                                     mode)))
         (src (quotearg (or ssname (conc sname ".scm")))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " " out " " cmd 
           (if keep-generated-files " -k" "")
           " -setup-mode"
           (if (eq? mode 'host) " -host" "")
           " -I " srcdir " -C -I" srcdir (arglist opts)
           (arglist link-options) " " src " -o " out " : "
           src " " (quotearg eggfile) " "
           (if custom (quotearg cmd) "") " "
           (filelist srcdir source-dependencies))))

(define ((compile-static-program name #!key source
                                 (options '()) (link-options '())
                                 source-dependencies
                                 custom mode eggfile)
         srcdir platform)
  (let* ((cmd (or (and custom (prefix srcdir custom))
                  default-csc))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (opts (if (null? options) 
                   default-static-compilation-options
                   options))
         (out (quotearg (target-file (conc sname
                                           (executable-extension platform)) 
                                     mode)))
         (src (quotearg (or ssname (conc sname ".scm")))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform) " " out " " cmd 
           (if keep-generated-files " -k" "")
           (if (eq? mode 'host) " -host" "")
           " -static -setup-mode -I " srcdir " -C -I" 
           srcdir (arglist opts)
           (arglist link-options) " " src " -o " out " : "
           src " " (quotearg eggfile) " "
           (if custom (quotearg cmd) "") " "
           (filelist srcdir source-dependencies))))

(define ((compile-generated-file name #!key source custom
                                 source-dependencies) 
         srcdir platform)
  (let* ((cmd (prefix srcdir custom))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (out (quotearg (or ssname sname))))
    (when custom
      (prepare-custom-command cmd platform))
    (print "\n" (slashify default-builder platform)
           " " out " " cmd " : " cmd " "
           (filelist srcdir source-dependencies))))


;; installation operations

(define ((install-static-extension name #!key mode output-file)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (ext (object-extension platform))
         (sname (prefix srcdir name))
         (out (quotearg (target-file (conc sname ".static" ext)
                                     mode)))
         (outlnk (quotearg (conc sname +link-file-extension+)))
         (dest (destination-repository mode))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
           (quotearg (slashify (conc dest "/" 
                                     output-file
                                     ext) 
                               platform)))
    (print cmd " " outlnk " " ddir
           (quotearg (slashify (conc dest "/" 
                                     output-file
                                     +link-file-extension+)
                               platform)))))

(define ((install-dynamic-extension name #!key mode (ext ".so")
                                    output-file)
         srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (dcmd (remove-file-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (quotearg (target-file (conc sname ext) mode)))
         (dest (destination-repository mode))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform))
         (destf (quotearg (slashify (conc dest "/" output-file ext)
                                    platform))))
    (print "\n" mkdir " " ddir dfile)
    (when (eq? platform 'unix)
      (print dcmd " " ddir destf))
    (print cmd " " out " " ddir destf)))

(define ((install-import-library name #!key mode)
         srcdir platform)
  ((install-dynamic-extension name mode: mode ext: ".import.so"
                              output-file: name)
   srcdir platform))

(define ((install-import-library-source name #!key mode)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (quotearg (target-file (conc sname ".import.scm") mode)))
         (dest (destination-repository mode))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (quotearg (slashify (conc dest "/" name ".import.scm")
                              platform)))))

(define ((install-types-file name #!key mode types-file)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (quotearg (prefix srcdir (conc types-file ".types"))))
         (dest (destination-repository mode))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (quotearg (slashify (conc dest "/" types-file ".types") 
                              platform)))))

(define ((install-inline-file name #!key mode inline-file) 
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (quotearg (prefix srcdir (conc inline-file ".inline"))))
         (dest (destination-repository mode))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (quotearg (slashify (conc dest "/" inline-file ".inline")
                              platform)))))

(define ((install-program name #!key mode output-file) srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (dcmd (remove-file-command platform))
         (mkdir (mkdir-command platform))
         (ext (executable-extension platform))
         (sname (prefix srcdir name))
         (out (quotearg (target-file (conc sname ext) mode)))
         (dest (if (eq? mode 'target)
                   default-bindir
                   (override-prefix "/bin" host-bindir)))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform))
         (destf (quotearg (slashify (conc dest "/" output-file ext) 
                                    platform))))
    (print "\n" mkdir " " ddir dfile)
    (when (eq? platform 'unix)
      (print dcmd " " ddir destf))
    (print cmd " " out " " ddir destf)))

(define ((install-data name #!key files destination mode) 
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (dest (or destination (if (eq? mode 'target)
                                   default-sharedir 
                                   (override-prefix "/share" host-sharedir))))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd (arglist (map (cut prefix srcdir <>) files)) " " ddir 
           dfile)))

(define ((install-c-include name #!key deps files destination mode) 
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (dest (or destination (if (eq? mode 'target) 
                                   default-incdir 
                                   (override-prefix "/include" host-incdir))))
         (dfile (quotearg (slashify dest platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (print "\n" mkdir " " ddir dfile)
    (print cmd (arglist (map (cut prefix srcdir <>) files)) " " ddir dfile)))


;;; Generate shell or batch commands from abstract build/install operations

(define (generate-shell-commands platform cmds dest srcdir prefix suffix keep)
  (fluid-let ((keep-generated-files keep))
    (with-output-to-file dest
      (lambda ()
        (prefix platform)
        (print (cd-command platform) 
               " " (quotearg (slashify srcdir platform)))
        (for-each
          (lambda (cmd) (cmd srcdir platform))
          cmds)
        (suffix platform)))))
                        

;;; affixes for build- and install-scripts

(define ((build-prefix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
#!/bin/sh~%
set -e
PATH="~a":$PATH
export CHICKEN_CC="~a"
export CHICKEN_CXX="~a"
export CHICKEN_CSC="~a"
export CHICKEN_CSI="~a"

EOF
             default-bindir default-cc default-cxx default-csc
             default-csi))
    ((windows)
     (printf #<<EOF
@echo off~%
set PATH=~a;%PATH%
set CHICKEN_CC=~a
set CHICKEN_CXX=~a
set CHICKEN_CSC=~a
set CHICKEN_CSI=~a

EOF
             default-bindir default-cc default-cxx default-csc
             default-csi))))

(define ((build-suffix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
EOF
             ))
    ((windows)
     (printf #<<EOF
EOF
             ))))

(define ((install-prefix mode name info) platform)
  (case platform
    ((unix)
     (printf #<<EOF
#!/bin/sh~%
set -e

EOF
             ))
    ((windows)
     (printf #<<EOF
@echo off~%
EOF
             ))))

(define ((install-suffix mode name info) platform)
  (let* ((infostr (with-output-to-string (cut pp info)))
         (dcmd (remove-file-command platform))
         (mkdir (mkdir-command platform))
         (dir (destination-repository mode))
         (qdir (quotearg (slashify dir platform)))
         (dest (quotearg (slashify (make-pathname dir name +egg-info-extension+)
                                   platform)))
         (ddir (shell-variable "DESTDIR" platform)))
    (case platform
      ((unix)
       (printf #<<EOF

~a ~a~a
~a ~a~a
cat >~a~a <<ENDINFO
~aENDINFO~%
EOF
               mkdir ddir qdir
               dcmd ddir dest
               ddir dest infostr))
      ((windows)
       (printf #<<EOF

~a ~a~a
echo ~a >~a~a~%
EOF
               mkdir ddir qdir
               (string-intersperse (string-split infostr "\n") "^\n\n")
               ddir dest)))))


;;; some utilities for mangling + quoting

(define (prefix dir name)
  (make-pathname dir (->string name)))

(define (quotearg str)
  (let ((lst (string->list str)))
    (if (any char-whitespace? lst)
        (string-append "\"" str "\"")
        str)))

(define (slashify str platform)
  (if (eq? platform 'windows)
      (list->string 
        (map (lambda (c) (if (char=? #\/ c) #\\ c)) (string->list str)))
      str))

(define (quote-all str platform)
  (if (and (eq? platform 'windows) 
           (positive? (string-length str))
           (char=? #\" (string-ref str 0)))
      (string-append "\"" str "\"")
      str))

(define (target-file fname mode)
  (if (eq? mode 'target) (string-append fname ".target") fname))

(define (arglist lst)
  (apply conc (map (lambda (x) (conc " " (quotearg x))) lst)))

(define (filelist dir lst)
  (arglist (map (cut prefix dir <>) lst)))

(define (shell-variable var platform)
  (case platform
    ((unix) (string-append "${" var "}"))
    ((windows) (string-append "%" var "%"))))
  
(define (prepare-custom-command cmd platform)
  (unless (eq? 'windows platform)
    (print "chmod +x " (quotearg cmd))))
