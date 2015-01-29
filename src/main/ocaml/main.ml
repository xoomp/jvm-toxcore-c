let fl () = flush stdout
open Core.Std
open Async.Std

open Types
open Sodium


let sonOfRa = {
  (*n_addr = "144.76.60.215";*)
  n_proto = Protocol.UDP;
  n_addr = InetAddr.IPv4 (Option.value_exn (InetAddr.ipv4_of_string
                                              "\x90\x4c\x3c\xd7"));
  n_port = Option.value_exn (Port.of_int 33445);
  n_key =
    PublicKey.of_string (
      "\x04\x11\x9E\x83\x5D\xF3\xE7\x8B" ^
      "\xAC\xF0\xF8\x42\x35\xB3\x00\x54" ^
      "\x6A\xF8\xB9\x36\xF0\x35\x18\x5E" ^
      "\x2A\x8E\x9E\x0A\x67\xC8\x92\x4F"
    )
}


type network_packet =
  | EchoRequest   of EchoRequest.t
  | EchoResponse  of EchoResponse.t
  | NodesRequest  of NodesRequest.t
  | NodesResponse of NodesResponse.t


let handle_packet ~dht ~recv_write buf from =
  let buf = Iobuf.read_only buf in
 
  match Iobuf.Peek.uint8 ~pos:0 buf with
  | 0x00 ->
      begin match EchoRequest.unpack dht buf with
        | None -> failwith "Format error in EchoRequest"
        | Some (node, decoded) ->
            Pipe.write_without_pushback recv_write
              (node, EchoRequest decoded)
      end

  | 0x01 ->
      print_endline @@ "Got EchoResponse from " ^
                       Socket.Address.Inet.to_string from;
      print_endline @@ Iobuf.to_string_hum ~bounds:`Window buf;
  | 0x02 ->
      print_endline @@ "Got NodesRequest from " ^
                       Socket.Address.Inet.to_string from;
      print_endline @@ Iobuf.to_string_hum ~bounds:`Window buf;
  | 0x04 ->
      begin match NodesResponse.unpack dht buf with
        | None -> failwith "Format error in NodesResponse"
        | Some (node, decoded) ->
            Pipe.write_without_pushback recv_write
              (node, NodesResponse decoded)
      end
 
  | code ->
      failwith @@ Printf.sprintf "Unhandled packet type: 0x%02x" code


let recv_loop ~dht_ref ~sock ~recv_write =
  Udp.recvfrom_loop (Socket.fd sock)
    (fun buf from -> handle_packet ~dht:!dht_ref ~recv_write buf from)


let send_loop ~sock ~send_read =
  let sendto =
    match Udp.sendto () with
    | Error error ->
        Error.raise error
    | Ok sendto ->
        sendto
  in

  let rec send_read_loop () =
    Pipe.read send_read >>= function
    | `Eof -> return ()
    | `Ok (node, packet) ->
        let ip = InetAddr.to_string node.n_addr in
        sendto (Socket.fd sock) packet
          (Socket.Address.Inet.create
             (Unix.Inet_addr.of_string ip)
             ~port:(Port.to_int node.n_port))
        >>= send_read_loop
  in

  send_read_loop ()


let network_loop ~dht_ref ~recv_write ~send_read =
  Udp.bind (Socket.Address.Inet.create Unix.Inet_addr.bind_any ~port:33445) >>=
  fun sock ->

  Deferred.all_ignore [
    recv_loop ~dht_ref ~sock ~recv_write;
    send_loop ~sock ~send_read;
  ]


let handle_network_event ~dht_ref ~send_write (from, packet) =
  match packet with
  | EchoRequest { EchoRequest.ping_id } ->
      print_endline @@ "Got EchoRequest from " ^
                       InetAddr.to_string from.cn_node.n_addr ^ ":" ^
                       string_of_int (Port.to_int from.cn_node.n_port);
 
      (*
      print_endline @@ "Sending EchoResponse to " ^
                       InetAddr.to_string from.cn_node.n_addr ^ ":" ^
                       string_of_int (Port.to_int from.cn_node.n_port);
      *)
      (* Form an EchoResponse. *)
      let response =
        Option.value_exn (
          EchoResponse.(
            make ~dht:!dht_ref ~node:from.cn_node { ping_id }
          )
        )
      in

      Pipe.write send_write (from.cn_node, response)

  | EchoResponse _
  | NodesRequest _ ->
      return ()
  | NodesResponse response ->
      let node_count = PublicKeyMap.length !dht_ref.dht_nodes in
      print_string @@ "[" ^ string_of_int node_count ^ "] ";
      print_endline @@ "Got NodesResponse from " ^
                       InetAddr.to_string from.cn_node.n_addr ^ ":" ^
                       string_of_int (Port.to_int from.cn_node.n_port);

      let open NodesResponse in
      assert (response.ping_id = 0x8765432101234567L);

      Deferred.all_ignore (
        List.map response.NodesResponse.nodes
          ~f:(
            fun node ->
              match node.n_addr with
              | InetAddr.IPv6 _ ->
                  (*
                  print_endline @@ "Ignoring IPv6 address " ^
                                   InetAddr.to_string node.n_addr ^ ":" ^
                                   string_of_int (Port.to_int node.n_port);
                  *)
                  return ()
              | InetAddr.IPv4 _ ->
                  (*
                  print_endline @@ "Sending NodesRequest to " ^
                                   InetAddr.to_string node.n_addr ^ ":" ^
                                   string_of_int (Port.to_int node.n_port);
                  *)
                  (* Get or create new channel key. *)
                  let dht, channel_key =
                    Dht.channel_key !dht_ref node
                  in

                  (* Update DHT reference. *)
                  dht_ref := dht;

                  (* Form a NodesRequest. *)
                  let request =
                    Option.value_exn (
                      NodesRequest.(
                        make ~dht ~node {
                          key = dht.dht_pk;
                          ping_id = 0x8765432101234567L;
                        }
                      )
                    )
                  in

                  Pipe.write send_write (node, request)
          )
      )


let event_loop ~dht_ref ~recv_read ~send_write =
  let rec recv_read_loop () =
    Pipe.read recv_read >>= function
    | `Eof ->
        return ()
    | `Ok decoded ->
        handle_network_event ~dht_ref ~send_write decoded >>= recv_read_loop
  in

  recv_read_loop ()


let main =
  let dht_ref = ref (Dht.create ()) in

  dht_ref := Dht.add_node !dht_ref sonOfRa;

  let recv_read, recv_write = Pipe.create () in
  let send_read, send_write = Pipe.create () in

  let request =
    Option.value_exn (
      NodesRequest.(
        make ~dht:!dht_ref ~node:sonOfRa {
          key = !dht_ref.dht_pk;
          ping_id = 0x8765432101234567L;
        }
      )
    )
  in

  Deferred.all_ignore [
    Pipe.write send_write (sonOfRa, request);
    event_loop   ~dht_ref ~recv_read ~send_write;
    network_loop ~dht_ref ~recv_write ~send_read;
  ]


let () =
  (main >>> fun () -> shutdown 0);
  never_returns (Scheduler.go ())
