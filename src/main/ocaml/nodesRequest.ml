open Core.Std
open Types


type t = {
  key : PublicKey.t;
  ping_id : int64;
}


let make ~dht ~node request =
  Crypto.pack_dht_packet ~dht ~node ~kind:0x02 ~f:(
    fun packet ->
      PublicKey.pack packet request.key;
      Iobuf.Fill.int64_t_be packet request.ping_id;
  )
