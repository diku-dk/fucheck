import "/home/sigurd/studie/bachelor/fucheck/src/futs/fucheck"
open Fucheck

-- ==
-- input @ scan_100.in
-- input @ scan_1000.in
-- input @ scan_10000.in
-- input @ scan_100000.in
-- input @ scan_1000000.in
-- input @ scan_10000000.in

let segscan [n] 't (op: t -> t -> t) (ne: t) (arr: [n](t, bool)) : [n]t =
    let tuples = scan (\ (v1:t, f1:bool) (v2:t, f2:bool) ->
                   ((if f2 then v2 else op v1 v2), (f1 || f2))
                 ) (ne, false) arr
    let (res, _) = unzip tuples
    in res

let main [n] (arr: [n]i32) (arrB: [n]bool) : [n]i32 =
  segscan (+) 0 (zip arr arrB)

let fst (a,_) = a
let snd (_,b) = b


let crude_segscan [n] (op: i32 -> i32 -> i32) (ne: i32) (arr: [n](i32,bool)) : [n]i32 =
  let (right,almostdone) =
    loop (right, newarr) = (length arr,[])
    for i in reverse <| iota <| length arr do
      if snd arr[i] then
        (i, (scan op ne <| drop i <| take right <| fst <| unzip arr) ++ newarr)
      else (right, newarr)
  let result =
    if right == 0 then almostdone else (scan op ne <| take right <| fst <| unzip arr) ++ almostdone
  in result :> [n]i32

-- fucheck segscan
let gen_segscan (size : i32) (seed : i32) : testdata ([](i32,bool)) =
  let rngs = split_rng 2 <| rng_from_seed seed
  let sizes = getsizes size rngs[0] 1
  let arrgen = arbitraryarr (arbitrarytuple arbitraryi32 arbitrarybool) sizes[0]
  in arrgen size rngs[1]

let prop_segscan [n] (input : testdata ([n](i32,bool))) : bool =
  match input
  case #testdata arr ->
    crude_segscan (+) 0 arr == segscan (+) 0 arr

let show_segscan [n] (input : testdata ([n](i32,bool))) : []u8 =
  show_array (showtuple showdecimali32 showbool) input
