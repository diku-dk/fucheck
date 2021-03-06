import "types"

import "lib/github.com/diku-dk/cpprandom/random"
module r = minstd_rand
module dist = uniform_int_distribution i64 r

module Rng = {
  open Types

 type rng = r.rng

  let snd (_,b) = b

  let rng_from_seed seed = r.rng_from_seed [seed]
  let split_rng n rng = r.split_rng n rng

  let rand_i64 ((low,high) : (i64,i64)) (rng : rng) : i64 =
    snd <| dist.rand (low, high) rng

  let rand_i32 ((low,high) : (i32,i32)) (rng : rng) : i32 =
    i32.i64 <| snd <| dist.rand (i64.i32 low, i64.i32 high) rng

  let rand_i16 ((low,high) : (i16,i16)) (rng : rng) : i16 =
    i16.i64 <| snd <| dist.rand (i64.i16 low, i64.i16 high) rng

  let rand_i8 ((low,high) : (i8,i8)) (rng : rng) : i8 =
    i8.i64 <| snd <| dist.rand (i64.i8 low, i64.i8 high) rng

  let rand_u64 ((low,high) : (u64,u64)) (rng : rng) : u64 =
  let negate_high_bit bs = 0x8000000000000000 ^ bs
  in negate_high_bit
     <| u64.i64
     <| snd
     <| dist.rand ( i64.u64 (negate_high_bit low)
                  , i64.u64 (negate_high_bit high)
                  ) rng

  let rand_u32 ((low,high) : (u32,u32)) (rng : rng) : u32 =
    u32.i64 <| snd <| dist.rand (i64.u32 low, i64.u32 high) rng

  let rand_u16 ((low,high) : (u16,u16)) (rng : rng) : u16 =
    u16.i64 <| snd <| dist.rand (i64.u16 low, i64.u16 high) rng

  let rand_u8 ((low,high) : (u8,u8)) (rng : rng) : u8 =
    u8.i64 <| snd <| dist.rand (i64.u8 low, i64.u8 high) rng

  let rand_bool ((low,high) : (bool,bool)) (rng : rng) : bool =
    bool.i64 <| snd <| dist.rand (i64.bool low, i64.bool high) rng

  let getsizes (maxsize : size) (rng : rng) (num : i32) : [num]i32 =
    let rngs     = r.split_rng num rng
    let sizes    = map (\rng -> rand_i32 (0,maxsize) rng) rngs
    in sizes

}
