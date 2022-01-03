module Sink : sig
  type 'a t

  val string : string t
  val discard : unit t
end

module Source : sig
  type t

  val empty : t
  val string : string -> t
end

module Context : sig
  type t

  val create : unit -> t
end

module Response : sig
  type 'a t

  val response : _ t -> Http.Response.t Lwt.t
  val body : 'a t -> 'a Lwt.t

  module Expert : sig
    val curl : _ t -> Curl.t
  end
end

module Request : sig
  type 'a t

  val create :
    ?timeout_ms:int ->
    ?headers:Http.Header.t ->
    Http.Method.t ->
    uri:string ->
    input:Source.t ->
    output:'a Sink.t ->
    'a t

  module Expert : sig
    val curl : _ t -> Curl.t
  end
end

val submit : Context.t -> 'a Request.t -> 'a Response.t
