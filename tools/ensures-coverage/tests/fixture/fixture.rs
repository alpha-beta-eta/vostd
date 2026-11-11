//! Fixture for the ensures-coverage tests (tests/run.sh).
//!
//! One function per rule of design.md; the comment above each says what
//! the check must find.  tests/expected.results is the exact result.  When
//! adding a case, keep it small and say which 结论 it covers.
//!
//! Functions are spread over nested modules so that module paths are
//! exercised too (结论20; the VIR path format changed in Verus 0.2026.11.08).
#![allow(unused)]
use vstd::prelude::*;

verus! {

/// Return values (结论6, 8).
pub mod rets {
    use vstd::prelude::*;

    /// named, mentioned: nothing
    pub fn named_mentioned(x: u64) -> (r: u64)
        ensures r == x,
    { x }

    /// named, not mentioned although there is a postcondition: (ret "r" u64)
    pub fn named_unmentioned(x: u64) -> (r: u64)
        ensures x == x,
    { x }

    /// unnamed, no postcondition: (ret #f u64), and no (post ...)
    pub fn unnamed(x: u64) -> u64 { x }

    /// unnamed, but `returns` mentions it: nothing
    pub fn unnamed_returns(x: u64) -> u64
        returns x,
    { x }

    /// only `requires`: no postcondition (结论12), (ret #f u64).  Without
    /// `ensures` Verus does not keep the name `r` in VIR.
    pub fn requires_only(x: u64) -> (r: u64)
        requires x > 0,
    { x }

    /// unit return: no output at all
    pub fn unit_return(x: u64)
        ensures true,
    { }

    /// a quantified variable with the same name is not the return value
    /// (结论11): (ret "r" u64)
    pub fn shadowed(x: u64) -> (r: u64)
        ensures forall|r: u64| #[trigger] spec_fn(r) == r,
    { x }

    /// non-pub (结论1): private, (ret "r" u64)
    fn private_unmentioned(x: u64) -> (r: u64)
        ensures true,
    { x }

    /// spec functions are not checked (结论1): absent from the results
    pub open spec fn spec_fn(x: u64) -> u64 { x }

    /// proof function with a ghost return (结论1, 6): proof, (ret "r" int ghost)
    pub proof fn proof_unmentioned(x: int) -> (r: int)
        ensures x == x,
    { x }

    /// tracked return mentioned: nothing
    pub proof fn tracked_mentioned(tracked x: u64) -> (tracked r: u64)
        ensures r == x,
    { x }

    /// external_body (结论5): external-body, (ret "r" u64)
    #[verifier::external_body]
    pub fn external_unmentioned(x: u64) -> (r: u64)
        ensures true,
    { x }
}

/// `&mut` parameters (结论7, 9, 10).
pub mod muts {
    use vstd::prelude::*;

    pub struct Pair { pub a: u64, pub b: u64 }

    /// final(x) mentioned: nothing
    pub fn final_mentioned(x: &mut u64)
        ensures *final(x) == *old(x),
    { }

    /// only old(x): (mut "x" (&mut u64))
    pub fn old_only(x: &mut u64)
        ensures *old(x) == *old(x),
    { }

    /// a field inside final(...) counts: nothing
    pub fn final_field(p: &mut Pair)
        ensures final(p).a == old(p).a,
    { }

    /// two parameters, one mentioned: (mut "y" (&mut u64))
    pub fn one_of_two(x: &mut u64, y: &mut u64)
        ensures *final(x) == *old(x),
    { }

    /// no postcondition: (mut "x" (&mut u64)), no (post ...)
    pub fn no_post(x: &mut u64) { }

    /// a return value that mentions nothing about x (结论10): both reported
    pub fn ret_and_mut(x: &mut u64) -> (r: u64)
        ensures *old(x) == *old(x),
    { 0 }

    /// tracked &mut parameter of a proof function: (mut "x" (&mut int) ghost)
    pub proof fn tracked_mut(tracked x: &mut int)
        ensures *old(x) == *old(x),
    { }

    /// exec function with `Tracked(x): Tracked<&mut ..>`, the wrapper is
    /// peeled (结论7): (mut "t" (&mut int) ghost)
    pub fn tracked_param(Tracked(t): Tracked<&mut int>)
        ensures *old(t) == *old(t),
    { }

    /// nested &mut is not an output (结论7): (outs 0)
    pub fn nested(x: Option<&mut u64>)
        ensures true,
    { }
}

/// Type invariants (结论16, 17).
pub mod invs {
    use vstd::prelude::*;

    pub struct Bounded { v: u64 }

    impl Bounded {
        #[verifier::type_invariant]
        spec fn inv(self) -> bool { self.v < 100 }

        pub closed spec fn val(self) -> u64 { self.v }

        /// (ret #f Bounded (inv "...::inv")), no (post ...)
        pub fn make() -> Bounded { Bounded { v: 0 } }

        /// mentioned: nothing
        pub fn make_named() -> (r: Bounded)
            ensures r.val() == 0,
        { Bounded { v: 0 } }

        /// &mut self with an invariant, not mentioned:
        /// (mut "self" (&mut Bounded) (inv "...::inv"))
        pub fn touch(&mut self)
            ensures true,
        { }
    }

    /// only the outermost type is looked at (注意6): Option<Bounded> has no
    /// invariant, (ret #f (Option Bounded))
    pub fn maybe() -> Option<Bounded> { None }
}

/// Traits (结论3, 4, 12, 13, 14, 15).
pub mod traits {
    use vstd::prelude::*;

    pub trait Tr {
        /// declaration: mentioned, nothing
        fn decl_mentioned(&self) -> (r: u64)
            ensures r > 0;

        /// declaration with `returns`: nothing; inherited by implementations
        fn decl_returns(&self) -> u64
            returns 7u64;

        /// declaration not mentioning r: (ret "r" u64)
        fn decl_unmentioned(&self) -> (r: u64)
            ensures true;

        /// mentioned only in default_ensures (结论15):
        /// (ret "r" bool default-only), and no (post ...) of its own
        fn with_default(&self) -> (r: bool)
            default_ensures r == false,
        { false }

        /// &mut self, declaration says nothing about it: (mut "self" ...)
        fn bump(&mut self)
            ensures true;
    }

    pub struct A { pub n: u64 }
    pub struct B { pub n: u64 }

    /// overrides every method
    impl Tr for A {
        /// inherits the declaration's ensures (结论13): nothing, (post decl)
        fn decl_mentioned(&self) -> (r: u64) { 1 }

        /// inherits `returns`: nothing
        fn decl_returns(&self) -> u64 { 7 }

        /// own clause mentions the return: nothing, (post own decl)
        fn decl_unmentioned(&self) -> (r: u64)
            ensures r == 0,
        { 0 }

        /// overriding drops default_ensures (结论13): (ret "r" bool), no post
        fn with_default(&self) -> (r: bool) { false }

        /// own clause with final(self): nothing
        fn bump(&mut self)
            ensures final(self).n == old(self).n,
        { }
    }

    /// keeps the default `with_default`: its inherited copy is not checked
    /// (结论3)
    impl Tr for B {
        fn decl_mentioned(&self) -> (r: u64) { 1 }
        fn decl_returns(&self) -> u64 { 7 }
        /// no clause of its own: same finding as the declaration, (post
        /// decl) (ret #f u64), the name being dropped as in
        /// rets::requires_only
        fn decl_unmentioned(&self) -> (r: u64) { 0 }
        fn bump(&mut self) { }
    }
}

} // verus!

/// `#[verus_spec]` return tuples (结论2, 6, 8).  Only the
/// `_VERUS_VERIFIED_` twin is checked.
pub mod spec_tuple {
    use vstd::prelude::*;

    /// both components mentioned: nothing
    #[verus_spec(r =>
        with -> g: Ghost<u64>
        ensures r == x, g@ == x,
    )]
    pub fn both(x: u64) -> u64 {
        proof_with!{|= Ghost(x)}
        x
    }

    /// ghost component not mentioned: (ret-part 1 "g" (Ghost u64) ghost)
    #[verus_spec(r =>
        with -> g: Ghost<u64>
        ensures r == x,
    )]
    pub fn ghost_unmentioned(x: u64) -> u64 {
        proof_with!{|= Ghost(x)}
        x
    }

    /// exec component not mentioned: (ret-part 0 "r" u64)
    #[verus_spec(r =>
        with -> g: Ghost<u64>
        ensures g@ == x,
    )]
    pub fn exec_unmentioned(x: u64) -> u64 {
        proof_with!{|= Ghost(x)}
        x
    }

    /// plain `#[verus_spec]` with a named return, not mentioned:
    /// (ret "r" u64)
    #[verus_spec(r =>
        ensures x == x,
    )]
    pub fn plain(x: u64) -> u64 { x }

    /// `returns` in verus_spec: nothing
    #[verus_spec(returns x)]
    pub fn plain_returns(x: u64) -> u64 { x }
}
