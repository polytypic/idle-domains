[@@@alert "-unstable"]

(** This is a framework for co-operative allocation of domains particularly
    intended for libraries providing schedulers for parallel programming.

    The overall goal is to make it possible for asynchronous and parallel
    programming libraries to co-exist and co-operate profitably with minimal
    loss of performance so that applications do not have to unnecessarily choose
    between competing library ecosystems.

    The basic problem with domains in OCaml is that they are very expensive.
    They are relatively expensive to create and, more importantly,
    {{:https://github.com/ocaml-multicore/domainslib/issues/77#issuecomment-1290398870}
    performance drops when there are more domains than available hardware
    threads}.  Even if the cost of idle domains might be reduced via future
    runtime optimizations, having
    {{:https://github.com/ocaml-multicore/domainslib/issues/92#issuecomment-1291671479}
    at most one domain per available hardware thread} can provide performance
    benefits.

    This basically means that libraries that want to co-exist and co-operate
    should never create domains on their own.

    On the other hand, what (low-level) asynchronous and parallel programming
    libraries want to do is to schedule work (i.e. tasks, fibers, ...) on one or
    more domains.  A scheduler typically runs a loop on one or more domains that
    takes work from some sort of dispenser (queue, stack, work-stealing deque,
    ...).  The exact details of how a scheduler is implemented tend to be very
    important.

    This framework manages a number of domains and keeps track of when a domain
    is idle.  Co-operative libraries can then attempt to allocate idle domains
    for running their schedulers.

    On the other hand, this framework is not intended to be a general purpose
    scheduler and does not make use of any unbounded dispensers.  This framework
    merely manages the allocation of a finite number of domains. The goal is to
    provide a layer on top of which effective and efficient scheduler libraries
    can be written.

    The implementation of this framework is lock-free with the exception that
    each domain has a mutex and a condition variable that are used by the domain
    to wait for a signal to wake up.  This means that either domain involved in
    a specific wake-up operation may be blocked. *)

(** {1 Library level interface}

    The operations in this section are intended for writing libraries that use
    domains co-operatively. *)

type managed_id = private Domain.id
(** A {!managed_id} is an alias for [Domain.id] used to indicate the subset of
    ids referring to managed domains. *)

(** {2 Reflecting managed domains} *)

val all : unit -> managed_id list
(** Returns a list of all the managed domains.  This list also includes the main
    domain as the first element.

    The intended use case of {!all} is for libraries providing {!scheduler}s to
    perform per domain preparation once. *)

val self : unit -> managed_id
(** An alias for [Domain.self ()] that asserts that is called from a managed
    domain.  The main domain is considered to be a managed domain. *)

val next : managed_id -> managed_id
(** Returns the next sibling of the given managed domain.  The siblings form a
    cycle and the main domain is included in the cycle.

    An intended use case for {!next} is to iterate over managed domains e.g. to
    implement work-stealing. *)

(** {2 Idling} *)

val wakeup : managed_id -> unit
(** Ensures that the specified managed domain is woken up.  This is for use with
    {!idle} to ensure that the predicate given to {!idle} is checked and {!idle}
    may return. *)

val idle : until:('ready -> bool) -> 'ready -> unit
(** Runs the current domain in a managed fashion [until] the given predicate
    returns [true].  The caller must arrange for {!wakeup} to be called to
    ensure that the predicate is checked to allow {!idle} to return.

    The [until] predicate should ideally be as fast as possible, because it is
    called repeatedly and it is also called during the period when the mutex of
    the domain is locked before waiting on the condition variable of the domain
    for a signal to wake up.

    During the {!idle} call any {!scheduler}s may be spawned to run on the
    domain. *)

(** {2 Schedulers} *)

type scheduler = managed_id -> unit
(** A {!scheduler} is just a function that executes on a specific domain.

    Once a {!scheduler} is called, it owns the domain for as long as it runs.
    For co-operative use of domains, the {!scheduler} should return as soon as
    it no longer has work to do.

    All {!scheduler}s must stop before the program can exit.  If a scheduler has
    no better way to decide when to stop, it should periodically call
    {!check_terminate}.

    A {!scheduler} should never [raise] arbitrary exceptions as there is no
    effective mechanism to handle such exceptions promptly, see {!prepare}. *)

val check_terminate : unit -> unit
(** Checks whether the program is being terminated and, if so, raises the
    {!Terminate} exception.

    The implementation of {!check_terminate} has been carefully optimized to
    make sure that it can be called highly frequently.

    It is typically not necessary to call {!check_terminate} from a {!scheduler}
    that always returns as soon as it has no work to do. *)

(** {3 Spawning schedulers} *)

val try_spawn : scheduler:scheduler -> bool
(** Tries to spawn the given {!scheduler} to run on a managed domain that
    happens to be idle at the moment.  Returns [true] on success and [false] on
    failure.

    The implementation of {!try_spawn} has been carefully optimized to make sure
    that it can be called highly frequently.  No unbounded queues or other kinds
    of dispensers are maintained by this library.  If there is contention or it
    seems that there are no idle domains at the moment, {!try_spawn} will
    immediately return [false].

    The intention is not that {!try_spawn} would be called in a loop until it
    returns [true].  The intention is that libraries may call {!try_spawn} every
    time they believe there is potentially work for an additional {!scheduler}.

    For best performance the caller likely wants to make sure that no closure
    needs to be allocated for the {!scheduler}. *)

(** {1 Application level interface}

    Applications should explicitly decide how the operations in this section are
    called and libraries should never call these functions on their own. *)

val prepare : num_domains:int -> unit
(** Prepares the given number of managed domains, including the calling main
    domain, for use.  The number of managed domains is restricted to the range
    [(1, Domain.recommended_domain_count ())].

    {!prepare} is idempotent and should be called at most once during
    application start-up.

    {!prepare} registers an [at_exit] operation to terminate all the managed
    domains.  The termination process [Domain.join]s with all the managed
    domains.  Unexpected exceptions are collected into a list and a single
    {!Managed_domains_raised} exception is raised in case the list is
    non-empty. *)

val prepare_opt : num_domains:int option -> unit
(** Calls {!prepare} defaulting to [Domain.recommended_domain_count ()]. *)

val prepare_recommended : unit -> unit
(** Calls {!prepare} with [Domain.recommended_domain_count ()]. *)

(** {1 Exceptions}

    Users of this framework should never need to [raise] any of the exceptions
    in this section. *)

exception Managed_domains_raised of exn list
(** Raised during application termination in case any [Domain.join]s with the
    managed domains raise exceptions due to {!scheduler}s passed to {!try_spawn}
    having raised exceptions.

    This exception indicates that some {!scheduler} has a bug. *)

exception Terminate
(** Exception used to indicate expected termination of a domain, see
    {!check_terminate}. *)
