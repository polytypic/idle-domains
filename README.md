# Co-operative allocation of domains for OCaml

This is a framework for co-operative allocation of domains for multicore OCaml.

The overall goal is to make it possible for asynchronous and parallel
programming libraries to co-exist and co-operate profitably with minimal loss of
performance so that applications do not have to unnecessarily choose between
competing library ecosystems.

The basic problem with domains in OCaml is that they are very expensive. They
are relatively expensive to create and, more importantly, performance drops when
there are more domains than available hardware threads
[even when domains are merely idle](https://github.com/ocaml-multicore/domainslib/issues/77#issuecomment-1290398870).
Even if the cost of idle domains might be reduced via future runtime
optimizations, having
[at most one domain per available hardware thread](https://github.com/ocaml-multicore/domainslib/issues/92#issuecomment-1291671479)
can provide performance benefits.

This basically means that libraries that want to co-exist and co-operate should
never create domains on their own.

On the other hand, what (low-level) asynchronous and parallel programming
libraries want to do is to schedule operations on one or more domains. A
scheduler typically runs a loop on one or more domains that takes operations
from some sort of dispenser (queue, stack, work-stealing deque, ...). The exact
details of how a scheduler is implemented tend to be very important.

The approach of `idle-domains` is to manage a number of domains and keep track
of when a domain is idle. Co-operative libraries can then attempt to allocate
idle domains for running their schedulers.

**_`idle-domains` is not intended to be a general purpose scheduler_** and does
not make use of any unbounded dispensers for handling requests. `idle-domains`
merely manages the allocation of a finite number of domains. The goal is to
provide a layer on top of which effective and efficient schedulers can be
written.

See
[the reference manual](https://polytypic.github.io/idle-domains/idle-domains/Idle_domains/index.html)
or the [Idle_domains.mli](src/main/Idle_domains.mli) signature for the API.
