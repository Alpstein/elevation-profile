;;;
;;; dem (digital elevation model) via gdal (http://www.gdal.org)
;;;
;;;   Copyright (c) 2012 Jens Thiele <karme@karme.de>
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;  

;; notes/todo:
;; - quite a hack
;; - get rid of c-wrapper / speedup
;; - leaks memory => call procedures only once if possible!
;; - you can use gdal's vrt format to merge images
;;   see also: http://www.gdal.org/gdal_vrttut.html
;;   and in general (WMS,....)
;;   http://www.gdal.org/formats_list.html
;; - a more general purpose gdal wrapper would be nice
;;   (upload to gl texture ...)
;; - use GDAL_CACHEMAX?
(define-module dem-gdal
  (use srfi-1)
  (use gauche.collection) ;; use after srfi-1 to make find work as expected!
  (use gauche.sequence)
  (use srfi-13)
  (use c-wrapper)
  (use gauche.array)
  (use gauche.uvector)
  (use gauche.process)
  (use runtime-compile)
  ;;(use sxml.adaptor)
  (export dem->xy->z   
          dem->xy-project->z
          dem-stack->xy->z
          ))

(select-module dem-gdal)

(c-load '("gdal/gdal.h" "gdal/ogr_srs_api.h") :libs-cmd "gdal-config --libs")

;; todo: hmm
(CPLSetErrorHandler 0)

(define-macro (assert e)
  `(when (not ,e)
     (error "assertion failed: " ,(x->string e))))

(define (gdal-open-dataset name)
  (assert (string? name))
  (with-output-to-port (current-error-port)
    (lambda()
      (gdal-init)
      (let ((dataset (GDALOpen name GA_ReadOnly)))
        (cond [(not (null-ptr? dataset))
               (let ((driver (GDALGetDatasetDriver dataset)))
                 ;; (print #`"Driver ,(GDALGetDriverShortName driver)/,(GDALGetDriverLongName driver)")
                 ;; (print #`"Size is ,(GDALGetRasterXSize dataset)x,(GDALGetRasterYSize dataset)x,(GDALGetRasterCount dataset)")
                 (when (not (null-ptr? (GDALGetProjectionRef dataset)))
                   ;; (print #`"Projection is ',(GDALGetProjectionRef dataset)'")
                   (let ((transform (make (c-array <c-double> 6))))
                     (when (= (GDALGetGeoTransform dataset transform) CE_None)
                       ;;#?=(map (cut cast <number> <>) transform)
                       ;; (print #`"Origin = ,(ref transform 0), ,(ref transform 3)")
                       ;; (print #`"Pixel Size = ,(ref transform 1), ,(ref transform 5)")
                       ))))
               dataset]
              [else
               (error "Unsupported format")])))))

(define (osr-from-user-input s)
  (let ((hSRS (OSRNewSpatialReference NULL))) ;; todo: leak!
    (when (not (= (OSRSetFromUserInput hSRS s) OGRERR_NONE))
      (error "OSRSetFromUserInput failed"))
    hSRS))

(define (osr-from-dataset dataset)
  (let ((hSRS (OSRNewSpatialReference NULL)))
    (when (not (= (OSRImportFromWkt hSRS (ptr (GDALGetProjectionRef dataset))) OGRERR_NONE))
      (error "OSRImportFromWkt failed"))
    hSRS))

(define (c-int->bool x)
  (not (zero? (cast <number> x))))

(define (osr-is-same? from to)
  (c-int->bool (OSRIsSame from to)))

(define-condition-type <transform-error> <error>
  transform-error?
  (pos transform-error-pos))

(cond-expand
 (no-runtime-compile
  (define (osr-transform from to)
    (if (osr-is-same? from to)
      identity
      (let ((ct (OCTNewCoordinateTransformation from to))
            (xa (make (c-array <c-double> 1)))
            (ya (make (c-array <c-double> 1)))
            (za (make (c-array <c-double> 1))))
        (assert (not (null-ptr? ct)))
        (lambda(l)
          (set! (ref xa 0) (ref l 0))
          (set! (ref ya 0) (ref l 1))
          (set! (ref za 0) (ref l 2 0))
          (when (not (c-int->bool (OCTTransform ct 1 xa ya za)))
            (error <transform-error> :pos l))
          (list (ref xa 0) (ref ya 0) (ref za 0))))))

  ;; todo:
  ;; - gdal already should provide that, no?
  ;; - slow
  (define (gdal-get-geotransform⁻¹ dataset)
    (let1 A (array-inverse (array-mul (gdal-get-geotransform-matrix dataset)
                                      (array (shape 0 3 0 3)
                                             1.0 0.0 0.5
                                             0.0 1.0 0.5
                                             0.0 0.0 1.0)))
      (lambda(l)
        (let1 r (array-mul A (array (shape 0 3 0 1) (ref l 0) (ref l 1) 1))
          (list (array-ref r 0 0) (array-ref r 1 0))))))

  (define (f32vector-replace! vec from to)
    (let1 s (f32vector-length vec)
      (dotimes (i s)
        (when (= (f32vector-ref vec i) from)
          (f32vector-set! vec i to))))
    vec)

  (define (get-gdal-read-band-row! band nodata)
    (let ((xsize (GDALGetRasterBandXSize band))
          (ysize (GDALGetRasterBandYSize band)))
      (lambda(scanline row . args)
        (let-optionals* args ((start 0)
                              (end xsize))
          (assert (<= start end))
          (let1 count (- end start)
            (assert (>= (size-of scanline) count))
            (f32vector-fill! scanline +nan.0)
            (cond [(and (> count 0)
                        (>= row 0)
                        (< row ysize))
                   (let ((rstart (max 0 start))
                         (rend   (min end xsize)))
                     (let ((lfill (- rstart start))
                           ;; (rfill (- end rend))
                           (rcount (- rend rstart)))
                       (when (and (> rcount 0)
                                  (not (zero? (GDALRasterIO band GF_Read rstart row rcount 1
                                                            (c-ptr+ (cast (ptr <c-float>) scanline) lfill)
                                                            rcount 1 GDT_Float32 0 0))))
                         (error "todo"))
                       (assert (or (boolean? nodata) (number? nodata)))
                       ;; replace nodata with nan
                       (when nodata
                         (f32vector-replace! scanline nodata +nan.0))
                       ;; count nan
                       (let ((s (f32vector-length scanline))
                             (r 0))
                         (dotimes (i s)
                           (when (nan? (f32vector-ref scanline i))
                             (inc! r)))
                         r)))]
                  [else
                   (f32vector-length scanline)]))))))

  ;; taken from grass (interp.c)
  ;;     return (u * (u * (u * (c3 + -3 * c2 + 3 * c1 - c0) +
  ;;	      (-c3 + 4 * c2 - 5 * c1 + 2 * c0) + (c2 - c0)) + 2 * c1) / 2;
  (define (interp-cubic u c0 c1 c2 c3)
    (/ (+ (* u (+ (* u (+ (* u (+ c3 (* -3 c2) (* 3 c1) (- c0)))
                          (- c3)
                          (* 4 c2)
                          (* -5 c1)
                          (* 2 c0)))
                  c2
                  (- c0)))
          (* 2 c1))
       2))

  ;; todo: improve
  (define (mod4 x m minx maxx)
    (cond [(and (< x minx)
                (or (>= (- maxx minx) m)
                    (<= (+ x m) maxx)))
           (mod4 (+ x m) m minx maxx)]
          [(and (> x maxx)
                (or (>= (- maxx minx) m)
                    (>= (- x m) minx)))
           (mod4 (- x m) m minx maxx)]
          [else
           x]))

  (define wrap-long-to (cut mod4 <> 360 <> <>))

  ;; todo: improve / or maybe just clip?!
  (define (wrap-lat x y . l)
    (cond [(< y -90)
           (apply wrap-lat (append (list (+ x 180) (- -180 y))
                                   l))]
          [(> y 90)
           (apply wrap-lat (append (list (+ x 180) (- 180 y))
                                   l))]
          [else
           (append (list x y) l)]))

  (define (get-bbox-geo-wrap geobox)
    (lambda(xy)
      (let1 xy (apply wrap-lat xy)
        (list (wrap-long-to (car xy)
                            (ref* geobox 0 0)
                            (ref* geobox 1 0))
              (cadr xy)))))

  (define (geo-wrap xy)
    (let1 xy (apply wrap-lat xy)
      ;; note: (fmod (car xy) 360) can't be expressed using wrap-long-to :(
      (list (fmod (car xy) 360)
            (cadr xy))))

  (define (raster-pos->4x4-box raster-pos)
    (let1 tl (map (lambda(x) (- (floor->exact x) 1)) raster-pos)
      (list tl (map (cut + <> 4) tl))))

  )
 (else
  (compile-and-load
   `((inline-stub
      (declcode
       (.include "gauche/uvector.h")
       (.include "gdal/gdal.h")
       (.include "gdal/ogr_srs_api.h")
       "static ScmClass *osrn_transform_class = NULL;"
       "/* stolen from cwcompile output */
      static void cw_unbox(void *dest, ScmObj obj, size_t size)
      {
        static ScmObj bufferof_proc = NULL;
        ScmObj buf;
        if (!bufferof_proc) {
          bufferof_proc = SCM_SYMBOL_VALUE(\"c-wrapper.c-ffi\", \"buffer-of\");
        }
        buf = Scm_ApplyRec(bufferof_proc, SCM_LIST1(obj));
        memcpy(dest, SCM_UVECTOR_ELEMENTS(buf), size);
      }"
       )
      
      (define-cproc make-osrn-transform (fromp top)
        (let* ((from::OGRSpatialReferenceH NULL)
               (to::OGRSpatialReferenceH NULL))
          (cw_unbox (& from) fromp (sizeof OGRSpatialReferenceH))
          (cw_unbox (& to) top (sizeof OGRSpatialReferenceH))
          (when (not from)
            (Scm_Error "failed to set from"))
          (when (not to)
            (Scm_Error "failed to set to"))
          (return (Scm_MakeForeignPointer osrn_transform_class (OCTNewCoordinateTransformation from to)))))

      (define-cproc osrn-apply-transform (it x::<double> y::<double>)
        (unless (SCM_XTYPEP it osrn_transform_class) (SCM_TYPE_ERROR it "<osrn:transform>"))
        (let* ((t::OGRCoordinateTransformationH (SCM_FOREIGN_POINTER_REF OGRCoordinateTransformationH it))
               (xr::double x)
               (yr::double y)
               (zr::double 0))
          (when (not (OCTTransform t 1 (& xr) (& yr) (& zr)))
            (Scm_Error "transform failed")) ;; todo: use Scm_Raise ?
          (result (SCM_LIST3 (Scm_MakeFlonum xr)
                             (Scm_MakeFlonum yr)
                             (Scm_MakeFlonum zr)))))

      (define-cfn osrn-transform-cleanup (h) ::void :static
        (OCTDestroyCoordinateTransformation (SCM_FOREIGN_POINTER_REF OGRCoordinateTransformationH h)))
      
      (define-cfn osrn-transform-print (h p::ScmPort* c::ScmWriteContext*) ::void :static
        (Scm_Printf p "#<osrn:transform @%p->%p>" h (SCM_FOREIGN_POINTER_REF OGRCoordinateTransformationH h)))

      (define-cproc c-gdal-read-band-row!
        (bandp nodata xsize::<int> ysize::<int> scanline::<f32vector> row::<int> start::<int> end::<int>)
        (let* ((band::GDALRasterBandH NULL))
          (cw_unbox (& band) bandp (sizeof GDALRasterBandH))
          (unless (<= start end) (Scm_Error "(<= start end)")) ;; todo: c-level assert?!
          (let* ((count::int (- end start)))
            (unless (>= (SCM_UVECTOR_SIZE scanline) count) (Scm_Error "(>= (SCM_UVECTOR_SIZE scanline) count)"))
            (Scm_F32VectorFill scanline NAN 0 (SCM_UVECTOR_SIZE scanline))
            (cond [(and (> count 0)
                        (>= row 0)
                        (< row ysize))
                   (let* ((rstart::int (?: (< start 0) 0 start))
                          (rend::int   (?: (< end xsize) end xsize))
                          (lfill::int (- rstart start))
                          ;; (rfill (- end rend))
                          (rcount::int (- rend rstart)))
                     (when (and (> rcount 0)
                                (not (== (GDALRasterIO band GF_Read rstart row rcount 1
                                                       (+ (SCM_F32VECTOR_ELEMENTS scanline) lfill)
                                                       rcount 1 GDT_Float32 0 0)
                                         0)))
                       (Scm_Error "todo"))
                     (let* ((r::int 0)
                            (i::int 0))
                       ;; replace nodata with nan
                       (unless (or (SCM_BOOLP nodata) (SCM_FLONUMP nodata))
                         (Scm_Error "(or (SCM_BOOLP nodata) (SCM_FLONUMP nodata))"))
                       (when (and (not (SCM_BOOLP nodata))
                                  (SCM_FLONUMP nodata))
                         (for [(set! i 0) (< i (SCM_UVECTOR_SIZE scanline)) (pre++ i)]
                              (when (== (aref (SCM_F32VECTOR_ELEMENTS scanline) i) (SCM_FLONUM_VALUE nodata))
                                (set! (aref (SCM_F32VECTOR_ELEMENTS scanline) i) NAN))))
                       ;; count nan
                       (for [(set! i 0) (< i (SCM_UVECTOR_SIZE scanline)) (pre++ i)]
                            (when (isnan (aref (SCM_F32VECTOR_ELEMENTS scanline) i))
                              (pre++ r)))
                       (result (SCM_MAKE_INT r))))]
                  [else
                   (result (SCM_MAKE_INT (SCM_UVECTOR_SIZE scanline)))]))))

      (initcode (= osrn_transform_class (Scm_MakeForeignPointerClass
                                         (Scm_CurrentModule)
                                         "<osrn:transform>" osrn-transform-print osrn-transform-cleanup
                                         SCM_FOREIGN_POINTER_KEEP_IDENTITY)))
      ))
   '(make-osrn-transform osrn-apply-transform c-gdal-read-band-row!)
   :libs (process-output->string "gdal-config --libs"))

  (define (osr-transform from to)
    (if (osr-is-same? from to)
      identity
      (let1 fp (make-osrn-transform from to)
        (lambda(l)
          (guard (e [else
                     ;;#?=e
                     (error <transform-error> :pos l)])
                 (osrn-apply-transform fp (car l) (cadr l)))))))
  (with-module gauche.array
    (define (symbolic-array-mul a b) ; NxM * MxP => NxP
      (let ([a-start (start-vector-of a)]
            [a-end (end-vector-of a)]
            [b-start (start-vector-of b)]
            [b-end (end-vector-of b)])
        (unless (= 2 (s32vector-length a-start) (s32vector-length b-start))
          (error "array-mul matrices must be of rank 2"))
        (let* ([a-start-row (s32vector-ref a-start 0)]
               [a-end-row (s32vector-ref a-end 0)]
               [a-start-col (s32vector-ref a-start 1)]
               [a-end-col (s32vector-ref a-end 1)]
               [b-start-col (s32vector-ref b-start 1)]
               [b-end-col (s32vector-ref b-end 1)]
               [n (- a-end-row a-start-row)]
               [m (- a-end-col a-start-col)]
               [p (- b-end-col b-start-col)]
               [a-col-b-row-off (- a-start-col (s32vector-ref b-start 0))]
               [res (make-minimal-backend-array (list a b) (shape 0 n 0 p))])
          (unless (= m (- (s32vector-ref b-end 0) (s32vector-ref b-start 0)))
            (errorf "dimension mismatch: can't mul shapes ~S and ~S"
                    (array-shape a) (array-shape b)))
          (do ([i a-start-row (+ i 1)])       ; for-each row of a
              [(= i a-end-row) res]
            (do ([k b-start-col (+ k 1)])     ; for-each col of b
                [(= k b-end-col)]
              (let1 tmp (list '+)
                (do ([j a-start-col (+ j 1)]) ; for-each col of a & row of b
                    [(= j a-end-col)]
                  (append! tmp (list (list '* (array-ref a i j) (array-ref b (- j a-col-b-row-off) k)))))
                (array-set! res (- i a-start-row) (- k b-start-col) tmp)))))))
    (export symbolic-array-mul)
    )

  ;; todo:
  ;; - gdal already should provide that, no?
  (define (gdal-get-geotransform⁻¹ dataset)
    (let* ((A (array-inverse (array-mul (gdal-get-geotransform-matrix dataset)
                                        (array (shape 0 3 0 3)
                                               1.0 0.0 0.5
                                               0.0 1.0 0.5
                                               0.0 0.0 1.0))))
           (sr (symbolic-array-mul A (array (shape 0 3 0 1) 'x 'y 1)))
           (nf (let1 mod (compile-and-load
                          `((inline-stub
                             (define-cproc foo (x::<double> y::<double>)
                               (return (SCM_LIST2
                                        (Scm_MakeFlonum ,(array-ref sr 0 0))
                                        (Scm_MakeFlonum ,(array-ref sr 1 0)))))))
                          `())
                 (global-variable-ref mod 'foo))))
      ;;#?=(list (array-ref sr 0 0) (array-ref sr 1 0))
      (lambda(l)
        ;; (let1 r (array-mul A (array (shape 0 3 0 1) (ref l 0) (ref l 1) 1))
        ;;   (list (array-ref r 0 0) (array-ref r 1 0))
        (nf (ref l 0) (ref l 1))
        )))

  (define (get-gdal-read-band-row! band nodata)
    (let ((xsize (GDALGetRasterBandXSize band))
          (ysize (GDALGetRasterBandYSize band)))
      (lambda(scanline row . args)
        (let-optionals* args ((start 0)
                              (end xsize))
          (c-gdal-read-band-row! band nodata xsize ysize scanline row start end)))))

  (compile-and-load
   `((inline-stub
      (define-cproc interp-cubic (u::<double> c0::<double> c1::<double> c2::<double> c3::<double>)
        ::<number> ;; :fast-flonum :constant
        (result (Scm_MakeFlonum (/ (+ (* u (+ (* u (+ (* u (+ c3 (* -3 c2) (* 3 c1) (- c0)))
                                                      (- c3)
                                                      (* 4 c2)
                                                      (* -5 c1)
                                                      (* 2 c0)))
                                              c2
                                              (- c0)))
                                      (* 2 c1))
                                   2))))))
   '(interp-cubic))

  (compile-and-load
   `((inline-stub
      (declcode
       (.include "math.h"))
      (define-cproc bbox-geo-wrap-2 (x::<double> y::<double> minx::<double> maxx::<double>)
        (while 1
          (cond [(< y -90)
                 (+= x 180)
                 (set! y (- -180 y))]
                [(> y 90)
                 (+= x 180)
                 (set! y (- 180 y))]
                [else
                 (break)]))
        ;; todo: improve
        (while 1
          (cond [(and (< x minx)
                      (or (>= (- maxx minx) 360)
                          (<= (+ x 360) maxx)))
                 (+= x 360)]
                [(and (> x maxx)
                      (or (>= (- maxx minx) 360)
                          (>= (- x 360) minx)))
                 (-= x 360)]
                [else
                 (break)]))
        (result (SCM_LIST2 (Scm_MakeFlonum x)
                           (Scm_MakeFlonum y))))
      (define-cproc geo-wrap-2 (x::<double> y::<double>)
        (while 1
          (cond [(< y -90)
                 (+= x 180)
                 (set! y (- -180 y))]
                [(> y 90)
                 (+= x 180)
                 (set! y (- 180 y))]
                [else
                 (break)]))
        (result (SCM_LIST2 (Scm_MakeFlonum (fmod x 360))
                           (Scm_MakeFlonum y))))))
   '(bbox-geo-wrap-2 geo-wrap-2))

  (define (get-bbox-geo-wrap geobox)
    (lambda(xy)
      (bbox-geo-wrap-2 (car xy) (cadr xy) (ref* geobox 0 0) (ref* geobox 1 0))))

  (define (geo-wrap xy)
    (geo-wrap-2 (car xy) (cadr xy)))

  ;; todo: not worth it?!
  (compile-and-load
   `((inline-stub
      (declcode
       (.include "math.h"))
      (define-cproc raster-pos->4x4-box (l::<list>)
        ;; todo: crap - see also gauche number.c how to do it
        (unless (and (SCM_FLONUMP (SCM_CAR l)) (SCM_FLONUMP (SCM_CADR l)))
          (Scm_Error "only flonum supported"))
        (let* ((x::int (- (cast int (floor (SCM_FLONUM_VALUE (SCM_CAR l)))) 1))
               (y::int (- (cast int (floor (SCM_FLONUM_VALUE (SCM_CADR l)))) 1)))
          (result (SCM_LIST2
                   (SCM_LIST2 (SCM_MAKE_INT x) (SCM_MAKE_INT y))
                   (SCM_LIST2
                    (SCM_MAKE_INT (+ x 4)) (SCM_MAKE_INT (+ y 4)))))))))
   '(raster-pos->4x4-box))
  ))

(define (osr-is-geographic? osr)
  (let1 r (c-int->bool (OSRIsGeographic osr))
    (assert (eq? r (not (osr-is-projected? osr))))
    r))

;; note: same as (not osr-is-geographic?)
(define (osr-is-projected? osr)
  (c-int->bool (OSRIsProjected osr)))

;; not used and not available in older gdal versions
;; (define (osr-is-compound? osr)
;;   (c-int->bool (OSRIsCompound osr)))

(define (gdal-get-projection dataset)
  (let ((hSRS (osr-from-dataset dataset)))
    (if (osr-is-projected? hSRS)
      (osr-transform (OSRCloneGeogCS hSRS) hSRS)
      identity))) ;; (lambda(l) l))))

(define (gdal-get-projection⁻¹ dataset)
  (let ((hSRS (osr-from-dataset dataset)))
    (if (osr-is-projected? hSRS)
      (osr-transform hSRS (OSRCloneGeogCS hSRS))
      identity))) ;; (lambda(l) l))))

(define (gdal-get-geotransform-matrix dataset)
  (let ((m (make (c-array <c-double> 6))))
    (GDALGetGeoTransform dataset (ptr m))
    (apply array (cons (shape 0 3 0 3)
                       (append (map (cut ref m <>) '(1 2 0))
                               (map (cut ref m <>) '(4 5 3))
                               '(0.0 0.0 1.0))))))


;; todo:
;; - gdal already should provide that, no?
;; - slow, but typically not called very often 
(define (get-geotransform dataset)
  (let ((A (array-mul (gdal-get-geotransform-matrix dataset)
                      (array (shape 0 3 0 3)
                             1.0 0.0 0.5
                             0.0 1.0 0.5
                             0.0 0.0 1.0))))
    (lambda(l)
      (let1 r (array-mul A (array (shape 0 3 0 1) (ref l 0) (ref l 1) 1))
        (list (array-ref r 0 0) (array-ref r 1 0))))))

(define (gdal-open-band dataset band)
  (let ((hband (GDALGetRasterBand dataset band))
        ;; (block-size-x (make <c-int>))
        ;; (block-size-y (make <c-int>))
        ;; (gotMin (make <c-int>))
        ;; (gotMax (make <c-int>))
        ;; (adfMinMax (make (c-array <c-double> 2)))
        )
    ;; (GDALGetBlockSize hband (ptr block-size-x) (ptr block-size-y))
    ;; (print #`"Block=,(cast <number> block-size-x)x,(cast <number> block-size-y) Type=,(GDALGetDataTypeName (GDALGetRasterDataType hband)), ColorInterp=,(GDALGetColorInterpretationName (GDALGetRasterColorInterpretation hband))")
    ;; (set! (ref adfMinMax 0) (GDALGetRasterMinimum hband (ptr gotMin)))
    ;; (set! (ref adfMinMax 1) (GDALGetRasterMaximum hband (ptr gotMax)))
    ;; (when (not (and (c-int->bool gotMin) (c-int->bool gotMax)))
    ;;   (GDALComputeRasterMinMax hband TRUE adfMinMax))
    ;;        (print #`"Min=,(ref adfMinMax 0), Max=,(ref adfMinMax 1)")
    ;; (when (< 0 (GDALGetOverviewCount hband))
    ;;   (print "Band has ,(GDALGetOverviewCount hband) overviews."))
    ;; (when (not (null-ptr? (GDALGetRasterColorTable hband)))
    ;;   (print #`"Band has a color table with ,(GDALGetColorEntryCount (GDALGetRasterColorTable hband)) entries."))
    hband))

(define (gdal-band-nodata hband)
  (let ((gotNoData (make <c-int>)))
    (GDALGetRasterNoDataValue hband (ptr gotNoData))
    (and (c-int->bool gotNoData)
         (GDALGetRasterNoDataValue hband (ptr gotNoData)))))

(define (interp-linear u c0 c1)
  (+ (* u (- c1 c0)) c0))

(define (bi-interp u v f rows)
  (apply f
         (cons v
               (map (lambda(x)
                      (apply f
                             (cons u
                                   (f32vector->list (ref rows x)))))
                    (iota (size-of rows))))))

(define (interp-bicubic u v rows)
  (assert (= (size-of rows) 4))
  (bi-interp u v interp-cubic rows))

;; (benchmark 10000 (lambda _ (interp-bicubic 0.2 0.2 '(#f32(0 1 0 0) #f32(0 2 0 0)#f32(0 0 0 0)#f32(0 0 0 0)))))

(define (interp-bilinear u v rows)
  (assert (= (size-of rows) 2))
  (bi-interp u v interp-linear rows))

(define (raster-pos->2x2-box raster-pos)
  (assert (list? raster-pos))
  (let1 tl (map floor->exact raster-pos)
    (list tl (map (cut + <> 2) tl))))

(define (raster-pos->1x1-box raster-pos)
  (assert (list? raster-pos))
  (let1 tl (map round->exact raster-pos)
    (list tl (map (cut + <> 1) tl))))

(define (raster-pos->uv raster-pos)
  (map (lambda(x) (- x (floor x))) raster-pos))

(define gdal-init
  (let1 called #f
    (lambda()
      (cond [(not called)
             (set! called #t)
             (GDALAllRegister)
             #t]
            [else
             #f]))))

(define (gdal-raster-size dataset)
  (map x->number (list (GDALGetRasterXSize dataset) (GDALGetRasterYSize dataset))))

(define (gdal-geographic-bbox dataset)
  (let ((osr (osr-from-dataset dataset))
        (rsize (gdal-raster-size dataset)))
    (assert (osr-is-geographic? osr))
    (let* ((l1 (map (get-geotransform dataset)
                    (list '(-1/2 -1/2)
                          (map (cut - <> 1/2) rsize))))
           (l2 (append
                (receive lx (apply min&max (map car l1))
                  lx)
                (receive ly (apply min&max (map cadr l1))
                  ly))))
      (list (permute l2 '(0 2))
            (permute l2 '(1 3))))))

(define (nan-to-#f n)
  (if (nan? n)
    #f
    n))

(define (range s e) (iota (- e s) s))

;; return function to get z value at position x y
;; (using coordinate system described by projection)
;; note: empty projection => input cs is _geographic cs_ of dataset
;; todo: maybe disallow empty value? or special symbols? 'geographic 'projected ?!
(define (dem->xy-project->z projection name . args)
  (let-keywords args ((next (lambda _ +nan.0))
                      (interpolation 'bi-cubic)
                      (band 1))
    (let* ((dataset (gdal-open-dataset name))
           (band (gdal-open-band dataset band)))
      (let ((width (GDALGetRasterBandXSize band))
            (height (GDALGetRasterBandYSize band))
            (osr (osr-from-dataset dataset)))
        (let1 xy->z (lambda(fi get-box box-width box-height)
                      (let ((rasterpos (apply compose
                                              (reverse ;; just for readability
                                               (filter (lambda(f) (not (eq? f identity)))
                                                       (list
                                                        (if (not (string-null? projection))
                                                          (osr-transform (osr-from-user-input projection)
                                                                         (OSRCloneGeogCS osr))
                                                          identity)
                                                        (if (osr-is-geographic? osr)
                                                          ;; todo: at the moment we can only get the
                                                          ;; geographic bbox if the dataset osr is
                                                          ;; geographic
                                                          (get-bbox-geo-wrap (gdal-geographic-bbox dataset))
                                                          ;; note: input always geographic!
                                                          geo-wrap)
                                                        (gdal-get-projection dataset)
                                                        (gdal-get-geotransform⁻¹ dataset))))))
                            ;; todo:
                            ;; - only what I want if projection is a geographic cs?
                            ;; - slow, but typically not called very often
                            (rasterpos⁻¹ (apply compose
                                                (reverse
                                                 (filter (lambda(f) (not (eq? f identity)))
                                                         (list
                                                          (get-geotransform dataset)
                                                          (gdal-get-projection⁻¹ dataset)
                                                          (if (not (string-null? projection))
                                                            (osr-transform (OSRCloneGeogCS osr)
                                                                           (osr-from-user-input projection))
                                                            identity)
                                                          (cut subseq <> 0 2))))))
                            (read-row! (get-gdal-read-band-row! band (gdal-band-nodata band)))
                            (rows (map (lambda(y) (make-f32vector box-width)) (iota box-height))))
                        (let ((read-row (lambda(y xs xe)
                                          (let1 row (make-f32vector (- xe xs))
                                            (read-row! row y xs xe)
                                            row)))
                              (read-box! (lambda(box)
                                           (let ((start (caar box))
                                                 (end   (caadr box)))
                                             (apply +
                                                    (map-with-index (lambda(idx y)
                                                                      (read-row! (ref rows idx) y start end))
                                                                    (range (cadar box) (cadadr box))))))))
                          (lambda(x y)
                            (guard (e [(transform-error? e)
                                       ;; todo: maybe not what i want!
                                       ;; #?=(list e (transform-error-pos e) x y)
                                       (next x y)])
                                   (let* ((rp (rasterpos (list x y)))
                                          (box (get-box rp)))
                                     ;; bbox test
                                     (if (or (<= (caadr box) 0)  (>= (caar box) width)
                                             (<= (cadadr box) 0) (>= (cadar box) height))
                                       (next x y)
                                       (let* ((uv (raster-pos->uv rp))
                                              (nans (read-box! box)))
                                         (cond [(= nans (* box-width box-height))
                                                ;; (every (lambda(r)
                                                ;;          (every nan? (f32vector->list r)))
                                                ;;        rows)
                                                ;; all nan
                                                ;; #?="all nan!"
                                                (next x y)]
                                               [(> nans 0)
                                                ;; try to replace nan
                                                (call/cc
                                                 (lambda(break)
                                                   (for-each-with-index
                                                    (lambda(ry r)
                                                      (for-each-with-index
                                                       (lambda(rx v)
                                                         (when (nan? v)
                                                           (receive (cx cy)
                                                               (apply values
                                                                      (rasterpos⁻¹ (list (+ (caar box) rx)
                                                                                         (+ (cadar box) ry))))
                                                             (if-let1 nv
                                                                 (or (and (osr-is-geographic? osr)
                                                                          (let* ((xy (lambda(x y)
                                                                                       ;; todo: only allow close match / or interpolate?!
                                                                                       ;; (but then i could use the offset stack ...)
                                                                                       (let ((x (round->exact x))
                                                                                             (y (round->exact y)))
                                                                                         (ref (read-row y x (+ x 1)) 0))))
                                                                                 (p (lambda l
                                                                                      (nan-to-#f (apply xy (rasterpos l))))))
                                                                            (or (p (+ cx 360.0) cy)
                                                                                (p (- cx 360.0) cy)
                                                                                (and (or (> cy 90.0) (< cy -90.0))
                                                                                     (p cx cy)))))
                                                                     (nan-to-#f (next cx cy)))
                                                               (set! (ref r rx) nv)
                                                               (break (next x y))))))
                                                       r))
                                                    rows)
                                                   ;; (assert (not (any (cut find nan? <>) rows)))
                                                   (fi (car uv) (cadr uv) rows)))]
                                               [else
                                                (assert (zero? nans))
                                                (fi (car uv) (cadr uv) rows)])))))))))
          (case interpolation
            ((bi-cubic)  (xy->z interp-bicubic raster-pos->4x4-box 4 4))
            ((bi-linear) (xy->z interp-bilinear raster-pos->2x2-box 2 2))
            ((nearest)   (xy->z (lambda(u v rows) (ref* rows 0 0)) raster-pos->1x1-box 1 1))
            (else (error "Unknown interpolation:" interpolation))))))))

;; return function to get z value at position x y (using coordinate system of the dataset)
(define (dem->xy->z name . args)
  (apply dem->xy-project->z (append (list "" name) args)))

(define (keyword-exists? key kv-list)
  (or (get-keyword key kv-list #f)
      (not (equal? 1 (get-keyword key kv-list 1)))))

(define (dem-stack->xy->z projection dem-stack)
  (let1 l (reverse dem-stack)
    (fold (lambda(n o)
            ;; note: maybe we should use delete-keyword on n instead
            ;; of assuming let-keywords takes the last value
            ;; even better: throw an error if there is a next keyword!
            ;; there is no such thing as keyword-exists?
            (when (keyword-exists? :next (cdr n))
              (error ":next only allowed in last element"))
            (apply dem->xy-project->z (cons projection (append n (list :next o)))))
          (apply dem->xy-project->z (cons projection (car l)))
          (cdr l))))
