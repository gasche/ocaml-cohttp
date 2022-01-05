open Async_kernel
module Time = Core.Time
module Fd = Async_unix.Fd
module Clock = Async_unix.Clock

let ( let+ ) x f = Deferred.map x ~f

module Sink = struct
  type _ t = String : string t | Discard : unit t

  let string = String
  let discard = Discard
end

module Source = struct
  type t = Empty | String of string

  let empty = Empty
  let string s = String s

  let to_curl_callback t =
    match t with
    | Empty -> fun _ -> ""
    | String s ->
        let len = String.length s in
        let pos = ref 0 in
        fun max_asked ->
          if !pos >= len then ""
          else
            let chunk_len = min (len - !pos) max_asked in
            let res = String.sub s !pos chunk_len in
            pos := !pos + chunk_len;
            res
end

module Context = struct
  type fd_events = {
    fd : Fd.t;
    mutable read : unit Ivar.t option;
    mutable write : unit Ivar.t option;
  }

  type t = {
    mt : Curl.Multi.mt;
    wakeners : (Curl.t, Curl.curlCode Ivar.t) Hashtbl.t;
    all_events : (Unix.file_descr, fd_events) Hashtbl.t;
    mutable timeout : (unit, unit) Clock.Event.t option;
  }

  let create () =
    (* Most of this is taken from https://github.com/ygrek/ocurl/blob/master/curl_lwt.ml *)
    let t =
      {
        mt = Curl.Multi.create ();
        wakeners = Hashtbl.create 32;
        all_events = Hashtbl.create 32;
        timeout = None;
      }
    in
    let rec finished s =
      match Curl.Multi.remove_finished t.mt with
      | None -> ()
      | Some (h, code) ->
          (match Hashtbl.find_opt t.wakeners h with
          | None -> Printf.eprintf "curl_async(%s): orphan handle" s
          | Some w ->
              Hashtbl.remove t.wakeners h;
              Ivar.fill w code);
          finished s
    in
    let on_readable fd =
      let (_ : int) = Curl.Multi.action t.mt (Fd.file_descr_exn fd) EV_IN in
      finished "on_readable"
    in
    let on_writable fd =
      let (_ : int) = Curl.Multi.action t.mt (Fd.file_descr_exn fd) EV_OUT in
      finished "on_writable"
    in
    let on_timer () =
      Curl.Multi.action_timeout t.mt;
      finished "on_timer"
    in
    Curl.Multi.set_timer_function t.mt (fun timeout ->
        (match t.timeout with
        | None -> ()
        | Some event -> Clock.Event.abort_if_possible event ());
        let duration = Time.Span.of_ms (float_of_int timeout) in
        t.timeout <- Some (Clock.Event.run_after duration on_timer ()));
    let socket_function fd (what : Curl.Multi.poll) =
      let create_event fd what =
        let interrupt = Ivar.create () in
        let f () =
          match what with `Read -> on_readable fd | `Write -> on_writable fd
        in
        let event =
          Fd.interruptible_every_ready_to fd what
            ~interrupt:(Ivar.read interrupt)
            (fun () -> f ())
            ()
          |> Deferred.map ~f:(function
               | `Bad_fd | `Closed -> assert false
               | `Unsupported -> assert false
               | `Interrupted -> ())
          |> Deferred.ignore_m
        in
        don't_wait_for event;
        interrupt
      in
      let needs_read = what = POLL_IN || what = POLL_INOUT in
      let needs_write = what = POLL_OUT || what = POLL_INOUT in
      let+ current =
        match Hashtbl.find_opt t.all_events fd with
        | Some fd -> Deferred.return fd
        | None ->
            Deferred.return
              {
                fd =
                  Fd.create
                    (Fd.Kind.Socket `Active)
                    fd (Base.Info.createf "curl");
                read = None;
                write = None;
              }
      in
      let update fd set_event set needs what =
        match (set, needs) with
        | None, false -> ()
        | Some _, true -> ()
        | None, true -> set_event (Some (create_event fd what))
        | Some ivar, false ->
            Ivar.fill ivar ();
            set_event None
      in
      update current.fd
        (fun ivar -> current.read <- ivar)
        current.read needs_read `Read;
      update current.fd
        (fun ivar -> current.write <- ivar)
        current.write needs_write `Write;
      Hashtbl.replace t.all_events fd current
    in
    Curl.Multi.set_socket_function t.mt (fun fd what ->
        don't_wait_for (socket_function fd what));
    t

  let register t curl wk =
    Hashtbl.add t.wakeners curl wk;
    Curl.Multi.add t.mt curl

  let unregister t curl =
    Curl.Multi.remove t.mt curl;
    Hashtbl.remove t.wakeners curl
end

module Method = Http.Method
module Header = Http.Header

module Response = struct
  type 'a t = {
    context : Context.t;
    curl : Curl.t;
    response : Http.Response.t Deferred.t;
    body : 'a Deferred.t;
  }

  let response t = t.response
  let body t = t.body
  let cancel t = Context.unregister t.context t.curl

  module Expert = struct
    let curl t = t.curl
  end
end

module Request = struct
  type 'a t = {
    curl : Curl.t;
    body : 'a Sink.t;
    body_ready : Curl.curlCode Ivar.t;
    response_ready : Http.Response.t Deferred.t;
    response_body : Buffer.t option ref;
  }

  module Expert = struct
    let curl t = t.curl
  end

  let create (type a) ?timeout_ms ?headers method_ ~uri ~(input : Source.t)
      ~(output : a Sink.t) : a t =
    let response_header_acc = ref [] in
    let response_body = ref None in
    let response_ready = Ivar.create () in
    let body_ready = Ivar.create () in
    let h =
      let h = Curl.init () in
      Curl.setopt h (CURLOPT_URL uri);
      Curl.setopt h (CURLOPT_CUSTOMREQUEST (Method.to_string method_));
      let () =
        match headers with
        | None -> ()
        | Some headers ->
            let buf = Buffer.create 64 in
            let headers =
              Header.fold
                (fun key value acc ->
                  Buffer.clear buf;
                  Buffer.add_string buf key;
                  Buffer.add_string buf ": ";
                  Buffer.add_string buf value;
                  Buffer.contents buf :: acc)
                headers []
              |> List.rev
            in
            Curl.setopt h (CURLOPT_HTTPHEADER headers)
      in
      Curl.setopt h
        (CURLOPT_HEADERFUNCTION
           (let status_code_ready = ref false in
            let response_http_version = ref None in
            fun header ->
              (match !status_code_ready with
              | false ->
                  (match String.split_on_char ' ' header with
                  | v :: _ ->
                      response_http_version := Some (Http.Version.of_string v)
                  | _ -> (* TODO *) invalid_arg "invalid request");
                  status_code_ready := true
              | true -> (
                  match header with
                  | "\r\n" ->
                      let response =
                        let headers = Header.of_list_rev !response_header_acc in
                        response_header_acc := [];
                        let status =
                          match Curl.getinfo h CURLINFO_HTTP_CODE with
                          | CURLINFO_Long l -> Http.Status.of_int l
                          | _ -> assert false
                        in
                        let version =
                          match !response_http_version with
                          | None -> assert false
                          | Some v -> v
                        in
                        Http.Response.make ~version ~status ~headers ()
                      in
                      Ivar.fill response_ready response
                  | _ ->
                      let k, v =
                        match Stringext.cut header ~on:":" with
                        | None -> invalid_arg "proper abort needed"
                        | Some (k, v) -> (String.trim k, String.trim v)
                      in
                      response_header_acc := (k, v) :: !response_header_acc));
              String.length header));
      Curl.setopt h (CURLOPT_READFUNCTION (Source.to_curl_callback input));
      Curl.setopt h
        (CURLOPT_WRITEFUNCTION
           (match output with
           | Discard -> fun s -> String.length s
           | String ->
               let buf = Buffer.create 128 in
               response_body := Some buf;
               fun s ->
                 Buffer.add_string buf s;
                 String.length s));
      (match timeout_ms with
      | None -> ()
      | Some tms -> Curl.setopt h (CURLOPT_TIMEOUTMS tms));
      h
    in
    {
      curl = h;
      response_ready = Ivar.read response_ready;
      body_ready;
      body = output;
      response_body;
    }
end

let submit (type a) context (request : a Request.t) : a Response.t =
  Context.register context request.curl request.body_ready;
  let body : a Deferred.t =
    let+ (_ : Curl.curlCode) = Ivar.read request.body_ready in
    (match request.body with
     | Discard ->
         assert (!(request.response_body) = None);
         ()
     | String ->
         let res =
           Buffer.contents
             (match !(request.response_body) with
             | None -> assert false
             | Some s -> s)
         in
         request.response_body := None;
         res
      : a)
  in
  {
    Response.body;
    context;
    response = request.response_ready;
    curl = request.curl;
  }
