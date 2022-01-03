(* {[
   Copyright (c) 2003, Lars Nilsson, <lars@quantumchamaeleon.com>
   Copyright (c) 2009, ygrek, <ygrek@autistici.org>

   Permission is hereby granted, free of charge, to any person obtaining
   a copy of this software and associated documentation files (the
   "Software"), to deal in the Software without restriction, including
   without limitation the rights to use, copy, modify, merge, publish,
   distribute, sublicense, and/or sell copies of the Software, and to
   permit persons to whom the Software is furnished to do so, subject to
   the following conditions:

   The above copyright notice and this permission notice shall be
   included in all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
   OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
   ]} *)

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
  type t = {
    mt : Curl.Multi.mt;
    wakeners : (Curl.t, Curl.curlCode Lwt.u) Hashtbl.t;
    all_events : (Unix.file_descr, Lwt_engine.event list) Hashtbl.t;
    mutable timer_event : Lwt_engine.event;
  }

  let create () =
    (* Most of this is taken from https://github.com/ygrek/ocurl/blob/master/curl_lwt.ml *)
    let t =
      {
        mt = Curl.Multi.create ();
        wakeners = Hashtbl.create 32;
        all_events = Hashtbl.create 32;
        timer_event = Lwt_engine.fake_event;
      }
    in
    let rec finished s =
      match Curl.Multi.remove_finished t.mt with
      | None -> ()
      | Some (h, code) ->
          (match Hashtbl.find_opt t.wakeners h with
          | None -> Printf.eprintf "curl_lwt(%s): orphan handle" s
          | Some w ->
              Hashtbl.remove t.wakeners h;
              Lwt.wakeup w code);
          finished s
    in
    let on_readable fd _ =
      let (_ : int) = Curl.Multi.action t.mt fd EV_IN in
      finished "on_readable"
    in
    let on_writable fd _ =
      let (_ : int) = Curl.Multi.action t.mt fd EV_OUT in
      finished "on_writable"
    in
    let on_timer _ =
      Lwt_engine.stop_event t.timer_event;
      Curl.Multi.action_timeout t.mt;
      finished "on_timer"
    in
    Curl.Multi.set_timer_function t.mt (fun timeout ->
        Lwt_engine.stop_event t.timer_event;
        t.timer_event <-
          Lwt_engine.on_timer (float_of_int timeout /. 1000.) false on_timer);
    Curl.Multi.set_socket_function t.mt (fun fd what ->
        (match Hashtbl.find_opt t.all_events fd with
        | None -> ()
        | Some events ->
            List.iter Lwt_engine.stop_event events;
            Hashtbl.remove t.all_events fd);
        let events =
          match what with
          | POLL_REMOVE | POLL_NONE -> []
          | POLL_IN -> [ Lwt_engine.on_readable fd (on_readable fd) ]
          | POLL_OUT -> [ Lwt_engine.on_writable fd (on_writable fd) ]
          | POLL_INOUT ->
              [
                Lwt_engine.on_readable fd (on_readable fd);
                Lwt_engine.on_writable fd (on_writable fd);
              ]
        in
        match events with [] -> () | _ -> Hashtbl.add t.all_events fd events);
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
    curl : Curl.t;
    response : Http.Response.t Lwt.t;
    body : 'a Lwt.t;
  }

  let response t = t.response
  let body t = t.body

  module Expert = struct
    let curl t = t.curl
  end
end

module Request = struct
  type 'a t = {
    curl : Curl.t;
    body : 'a Sink.t;
    wk_body : Curl.curlCode Lwt.u;
    wt_body : Curl.curlCode Lwt.t;
    wt_response : Http.Response.t Lwt.t;
    response_body : Buffer.t option ref;
  }

  module Expert = struct
    let curl t = t.curl
  end

  let create (type a) ?timeout_ms ?headers method_ ~uri ~(input : Source.t)
      ~(output : a Sink.t) : a t =
    let response_header_acc = ref [] in
    let response_body = ref None in
    let wt_response, wk_response = Lwt.wait () in
    let wt_body, wk_body = Lwt.wait () in
    let wt_response = Lwt.protected wt_response in
    let wt_body = Lwt.protected wt_body in
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
                      Lwt.wakeup wk_response response
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
    { curl = h; wt_response; wk_body; body = output; wt_body; response_body }
end

let submit (type a) context (request : a Request.t) : a Response.t =
  let cancel = lazy (Context.unregister context request.curl) in
  Lwt.on_cancel request.wt_response (fun () -> Lazy.force cancel);
  Lwt.on_cancel request.wt_body (fun () -> Lazy.force cancel);
  Context.register context request.curl request.wk_body;
  let body : a Lwt.t =
    let open Lwt.Syntax in
    let+ (_ : Curl.curlCode) = request.wt_body in
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
  { Response.body; response = request.wt_response; curl = request.curl }
