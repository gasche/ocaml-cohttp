(lang dune 2.9)
(name cohttp)

(license ISC)
(maintainers "Anil Madhavapeddy <anil@recoil.org>")
(authors
  "Anil Madhavapeddy"
  "Stefano Zacchiroli"
  "David Sheets"
  "Thomas Gazagnaire"
  "David Scott"
  "Rudi Grinberg"
  "Andy Ray")
(source (github mirage/ocaml-cohttp))
(documentation "https://mirage.github.io/ocaml-cohttp/")

(generate_opam_files true)

(package
 (name cohttp)
 (synopsis "An OCaml library for HTTP clients and servers")
 (description "\
Cohttp is an OCaml library for creating HTTP daemons. It has a portable
HTTP parser, and implementations using various asynchronous programming
libraries.

See the cohttp-async, cohttp-lwt, cohttp-lwt-unix, cohttp-lwt-jsoo and
cohttp-mirage libraries for concrete implementations for particular
targets.

You can implement other targets using the parser very easily. Look at the `IO`
signature in `lib/s.mli` and implement that in the desired backend.

You can activate some runtime debugging by setting `COHTTP_DEBUG` to any
value, and all requests and responses will be written to stderr.  Further
debugging of the connection layer can be obtained by setting `CONDUIT_DEBUG`
to any value.
")
 (depends
  (ocaml (>= 4.08))
  (re (>= 1.9.0))
  (uri (>= 2.0.0))
  uri-sexp
  sexplib0
  (ppx_sexp_conv (>= v0.13.0))
  stringext
  (base64 (>= 3.1.0))
  (fmt :with-test)
  jsonm
  (alcotest :with-test)
  (crowbar :with-test)))

(package
 (name cohttp-top)
 (synopsis "CoHTTP toplevel pretty printers for HTTP types")
 (description "\
This library installs toplevel prettyprinters for CoHTTP
types such as the `Request`, `Response` and `Types` modules.
Once this library has been loaded, you can directly see the
values of those types in toplevels such as `utop` or `ocaml`.
")
 (depends
  (ocaml (>= 4.08))
  (cohttp (= :version))))

(package
 (name cohttp-lwt)
 (synopsis "CoHTTP implementation using the Lwt concurrency library")
 (description "\
This is a portable implementation of HTTP that uses the Lwt concurrency library
to multiplex IO.  It implements as much of the logic in an OS-independent way
as possible, so that more specialised modules can be tailored for different
targets.  For example, you can install `cohttp-lwt-unix` or `cohttp-lwt-jsoo`
for a Unix or JavaScript backend, or `cohttp-mirage` for the MirageOS unikernel
version of the library. All of these implementations share the same IO logic
from this module.")
 (depends
  (ocaml (>= 4.08))
  (cohttp (= :version))
  (lwt (>= 2.5.0))
  sexplib0
  (ppx_sexp_conv (>= v0.13.0))
  logs
  (uri (>= 2.0.0))))

(package
 (name cohttp-lwt-unix)
 (synopsis "CoHTTP implementation for Unix and Windows using Lwt")
 (description "\
An implementation of an HTTP client and server using the Lwt
concurrency library. See the `Cohttp_lwt_unix` module for information
on how to use this.  The package also installs `cohttp-curl-lwt`
and a `cohttp-server-lwt` binaries for quick uses of a HTTP(S)
client and server respectively.

Although the name implies that this only works under Unix, it
should also be fine under Windows too.
")
 (depends
  (ocaml (>= 4.08))
  (cohttp (= :version))
  (cohttp-lwt (= :version))
  cmdliner
  (lwt (>= 3.0.0))
  (conduit-lwt (>= 5.0.0))
  (conduit-lwt-unix (>= 5.0.0))
  (fmt (>= 0.8.2))
  base-unix
  (ppx_sexp_conv (>= v0.13.0))
  magic-mime
  logs
  (ounit :with-test)))

(package
 (name cohttp-lwt-jsoo)
 (synopsis "CoHTTP implementation for the Js_of_ocaml JavaScript compiler")
 (description "\
An implementation of an HTTP client for JavaScript, but using the
CoHTTP types.  This lets you build HTTP clients that can compile
natively (using one of the other Cohttp backends such as `cohttp-lwt-unix`)
and also to native JavaScript via js_of_ocaml.
")
 (depends
  (ocaml (>= 4.08))
  (cohttp (= :version))
  (cohttp-lwt (= :version))
  logs
  (lwt (>= 3.0.0))
  (lwt_ppx :with-test)
  (conf-npm :with-test)
  (js_of_ocaml (>= 3.3.0))
  (js_of_ocaml-ppx (>= 3.3.0))
  (js_of_ocaml-lwt (>= 3.5.0))))

(package
 (name cohttp-async)
 (synopsis "CoHTTP implementation for the Async concurrency library")
 (description "\
An implementation of an HTTP client and server using the Async
concurrency library. See the `Cohttp_async` module for information
on how to use this.  The package also installs `cohttp-curl-async`
and a `cohttp-server-async` binaries for quick uses of a HTTP(S)
client and server respectively.
")
 (depends
  (ocaml (>= 4.08))
  (cohttp (= :version))
  (async_kernel (>= v0.14.0))
  (async_unix (>= v0.14.0))
  (async (>= v0.14.0))
  (base (>= v0.11.0))
  (core :with-test)
  (core_unix (>= v0.14.0))
  (conduit-async (>= 1.2.0))
  magic-mime
  (mirage-crypto :with-test)
  logs
  (fmt (>= 0.8.2))
  sexplib0
  (ppx_sexp_conv (>= v0.13.0))
  (ounit :with-test)
  (uri (>= 2.0.0))
  uri-sexp
  ipaddr))

(package
 (name cohttp-mirage)
 (synopsis "CoHTTP implementation for the MirageOS unikernel")
 (description "\
This HTTP implementation uses the Cohttp portable implementaiton
along with the Lwt threading library in order to provide a
`Cohttp_mirage` functor that can be used in MirageOS unikernels
to build very small and efficient HTTP clients and servers
without having a hard dependency on an underlying operating
system.

Please see <https://mirage.io> for a self-hosted explanation
and instructions on how to use this library.")
 (depends
  (ocaml (>= 4.08))
  (mirage-flow (>= 2.0.0))
  (mirage-channel (>= 4.0.0))
  (conduit (>= 2.0.2))
  (conduit-mirage (>= 2.3.0))
  (mirage-kv (>= 3.0.0))
  (lwt (>= 2.4.3))
  (cohttp-lwt (= :version))
  (fmt (>= 0.8.7))
  astring
  magic-mime
  (ppx_sexp_conv (>= v0.13.0))
  (cohttp (= :version))))

(package
 (name http)
 (synopsis "Type definitions of HTTP essentials")
 (description "\
This package contains essential type definitions used in Cohttp. It is designed
to have no dependencies and make it easy for other packages to easily
interoperate with Cohttp.")
 (depends
  (ocaml (>= 4.08))))
