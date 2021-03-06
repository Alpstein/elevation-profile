;;;
;;; google elevation web-service client
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
(define-module google-elevation-client
  (use rfc.json)
  (use rfc.uri)
  (use rfc.http)
  (use util.list)
  (use gauche.sequence)
  (use gauche.time)
  (export google-polyline->3d
          google-sample-polyline->3d))

(select-module google-elevation-client)

(define (encode-polyline pl)
  (string-join (map (lambda(p)
		      (string-join (map x->string
					(permute p '(1 0)))
                                   ","))
		    pl)
               "|"))

(define (json->list json)
  (map (lambda(p)
         (append
          (list (assoc-ref (assoc-ref p "location") "lng")
                (assoc-ref (assoc-ref p "location") "lat")
                (assoc-ref p "elevation"))
          (if (assoc-ref p "distance")
            (list (assoc-ref p "distance"))
	    ;; todo: should we calculate the distance on client side?
            '())))
       (assoc-ref (parse-json-string json) "results")))

;; todo: temporarily ignore or block sigpipe?!
(define (elevation-profile-http-request server request-uri method params reader)
  (let1 tc (make <real-time-counter>)
    (receive (status headers body)
        (with-time-counter tc (case method
                                [(post)
                                 (http-post server
                                            request-uri
                                            params)]
                                [(get)
                                 (http-get server
                                           (http-compose-query request-uri params))]
                                [else
                                 (error "todo")]))
      (case (x->number status)
        [(200)
         (reader body)]
        [else
         (error status headers body (time-counter-value tc))]))))

;; note: google does not support post
(define (google-http-request params)
  (elevation-profile-http-request "maps.googleapis.com"
                                  "/maps/api/elevation/json"
                                  'get
                                  (append params '((sensor "false")))
                                  json->list))

(define (google-polyline->3d pl)
  (google-http-request `((locations ,(encode-polyline pl)))))

(define (google-sample-polyline->3d pl samples)
  (google-http-request `((path ,(encode-polyline pl))
			 (samples ,samples))))
