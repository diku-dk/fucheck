module Types = {
  import "lib/github.com/diku-dk/cpprandom/random"
  module dist = uniform_int_distribution i32 minstd_rand

  type size = i32
  type rng = minstd_rand.rng
  type testdata 't = #testdata t
  type result = #success | #failure i32
  type^ gen 'a = #gen (size -> rng -> testdata a)

}