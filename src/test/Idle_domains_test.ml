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

  let spawner = Idle_domains.spawner () in
  Idle_domains.register spawner ~scheduler;

  while Atomic.get scheduler_started = 0 do
    Idle_domains.signal spawner
  done;

  assert (Atomic.get scheduler_started = 1)
