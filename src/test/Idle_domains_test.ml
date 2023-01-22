[@@@alert "-unstable"]

let () =
  Idle_domains.prepare ~num_domains:2;

  assert (List.length (Idle_domains.all ()) = 2);
  assert (List.hd (Idle_domains.all ()) == Idle_domains.self ());

  assert (
    Idle_domains.next (Idle_domains.next (Idle_domains.self ()))
    = Idle_domains.self ());
  assert (Idle_domains.next (Idle_domains.self ()) <> Idle_domains.self ());

  let scheduler_started = Atomic.make 0 in

  let scheduler _ =
    Atomic.incr scheduler_started;
    while true do
      Idle_domains.check_terminate ();
      Domain.cpu_relax ()
    done
  in

  Idle_domains.register ~scheduler;

  while Atomic.get scheduler_started = 0 do
    Idle_domains.signal ()
  done;

  Idle_domains.unregister ~scheduler;

  let self = Idle_domains.self () in
  Idle_domains.wakeup ~self;
  Idle_domains.idle ~self
