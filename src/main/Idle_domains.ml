[@@@alert "-unstable"]

let null () = Obj.magic ()

type managed_id = Domain.id

let main_id = Domain.self ()

type scheduler = managed_id -> unit

let max_domains = Domain.recommended_domain_count ()

let mutex = Mutex.create ()
and condition = Condition.create ()

let any_waiters = Multicore_magic.copy_as_padded (ref false)
and num_waiters = Multicore_magic.copy_as_padded (ref 0)

let wait () =
  let n = !num_waiters + 1 in
  num_waiters := n;
  if n = 1 then any_waiters := true;
  Condition.wait condition mutex;
  let n = !num_waiters - 1 in
  num_waiters := n;
  if n = 0 then any_waiters := false

let schedulers =
  Multicore_magic.copy_as_padded
    (Atomic.make (Multicore_magic.make_padded_array 0 (null ())))

let domains =
  Multicore_magic.copy_as_padded
    (ref (Multicore_magic.make_padded_array max_domains (null ())))

let next_sibling =
  Multicore_magic.copy_as_padded
    (ref (Multicore_magic.make_padded_array max_domains main_id))

let terminated = Multicore_magic.copy_as_padded (ref false)

let set ar i x =
  let n = Multicore_magic.length_of_padded_array !ar in
  if n <= i then begin
    let a =
      Multicore_magic.make_padded_array (Int.max (n * 2) (i + 1)) (null ())
    in
    for i = 0 to n - 1 do
      Array.unsafe_set a i (Array.unsafe_get !ar i)
    done;
    ar := a
  end;
  Array.unsafe_set !ar i x

let rec run_managed mid =
  if not !terminated then begin
    let ss = Multicore_magic.fenceless_get schedulers in
    let n = Multicore_magic.length_of_padded_array ss in
    try_managed mid ss ~n 0
  end

and try_managed mid ss ~n i =
  if i < n then begin
    let scheduler = Array.unsafe_get ss i in
    scheduler mid;
    run_managed mid
  end
  else begin
    Mutex.lock mutex;
    if not !terminated then wait ();
    Mutex.unlock mutex;
    run_managed mid
  end

let next (id : managed_id) = Array.unsafe_get !next_sibling (id :> int)
  [@@inline]

let rec all ids id =
  if id == main_id then main_id :: ids else all (id :: ids) (next id)

let all () = all [] (next main_id)

let rec register ~scheduler =
  let expected = Multicore_magic.fenceless_get schedulers in
  let n = Multicore_magic.length_of_padded_array expected in
  let desired = Multicore_magic.make_padded_array (n + 1) (null ()) in
  for i = 0 to n - 1 do
    Array.unsafe_set desired i (Array.unsafe_get expected i)
  done;
  Array.unsafe_set desired n scheduler;
  if not (Atomic.compare_and_set schedulers expected desired) then
    register ~scheduler

let rec unregister ~scheduler =
  let expected = Multicore_magic.fenceless_get schedulers in
  let n = Multicore_magic.length_of_padded_array expected in
  let desired = Multicore_magic.make_padded_array (n - 1) (null ()) in
  let rec loop ie id =
    if ie < n then
      let s = Array.unsafe_get expected ie in
      if s != scheduler then begin
        Array.unsafe_set desired id s;
        loop (ie + 1) (id + 1)
      end
      else loop (ie + 1) id
  in
  loop 0 0;
  if not (Atomic.compare_and_set schedulers expected desired) then
    unregister ~scheduler

let signal spawner = if !any_waiters then Condition.signal condition [@@inline]

let wakeup (_id : managed_id) =
  Mutex.lock mutex;
  Condition.broadcast condition;
  Mutex.unlock mutex

let rec run_idle ~until ready mid =
  if not (until ready) then begin
    let ss = Multicore_magic.fenceless_get schedulers in
    let n = Multicore_magic.length_of_padded_array ss in
    try_idle ~until ready mid ss ~n 0
  end

and try_idle ~until ready mid ss ~n i =
  if i < n then begin
    let scheduler = Array.unsafe_get ss i in
    scheduler mid;
    run_idle ~until ready mid
  end
  else begin
    Mutex.lock mutex;
    if not (until ready) then wait ();
    Mutex.unlock mutex;
    run_idle ~until ready mid
  end

let is_managed (id : Domain.id) =
  id == main_id
  ||
  let ds = !domains in
  (id :> int) < Array.length ds && Array.unsafe_get ds (id :> int) != null ()

let self () : managed_id =
  let id = Domain.self () in
  assert (is_managed id);
  id
  [@@inline]

let idle ~until ready =
  let mid = Domain.self () in
  assert (is_managed mid);
  run_idle ~until ready mid

exception Terminate

let terminate _ = raise Terminate [@@inline never]
let check_terminate () = if !terminated then terminate () [@@inline]

exception Managed_domains_raised of exn list

let printer_Managed_domains_raised = function
  | Managed_domains_raised exns ->
    let msg =
      "Managed_domains_raised ["
      ^ (String.concat "; " @@ List.rev_map Printexc.to_string exns)
      ^ "]"
    in
    Some msg
  | _ -> None

let terminate_at_exit () =
  terminated := true;

  Mutex.lock mutex;
  Condition.broadcast condition;
  Mutex.unlock mutex;

  let rec join_all exns id =
    if id == main_id then exns
    else
      let d = Array.unsafe_get !domains (id :> int) in
      match Domain.join d with
      | () | (exception Terminate) -> join_all exns (next id)
      | exception exn -> join_all (exn :: exns) (next id)
  in
  let exns = join_all [] (next main_id) in

  if exns != [] then raise @@ Managed_domains_raised exns

let num_managed_domains = ref 0

let prepare ~num_domains =
  if !num_managed_domains = 0 then begin
    let num_domains = Int.max 1 (Int.min num_domains max_domains) in
    Mutex.lock mutex;
    if !num_managed_domains = 0 then begin
      Printexc.register_printer printer_Managed_domains_raised;
      incr num_managed_domains;
      at_exit terminate_at_exit;
      for _ = 2 to num_domains do
        let domain =
          Domain.spawn @@ fun () ->
          let mid = Domain.self () in
          Mutex.lock mutex;
          incr num_managed_domains;
          if !num_managed_domains = num_domains then
            Condition.broadcast condition;
          while !num_managed_domains <> num_domains do
            Condition.wait condition mutex
          done;
          Mutex.unlock mutex;
          run_managed mid
        in
        let id = Domain.get_id domain in
        let next_id = Array.unsafe_get !next_sibling (main_id :> int) in
        set next_sibling (id :> int) next_id;
        set next_sibling (main_id :> int) id;
        set domains (id :> int) domain
      done;
      while !num_managed_domains <> num_domains do
        Condition.wait condition mutex
      done
    end;
    Mutex.unlock mutex
  end

let prepare_opt ~num_domains =
  prepare ~num_domains:(Option.value ~default:max_domains num_domains)

let prepare_recommended () = prepare_opt ~num_domains:None
