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

  let spawn = Idle_domains.spawn () in
  Idle_domains.start spawn ~scheduler;

  while Idle_domains.is_in_progress spawn do
    Domain.cpu_relax ()
  done;

  while Atomic.get scheduler_started = 0 do
    Domain.cpu_relax ()
  done;

  assert (Atomic.get scheduler_started = 1)
