[@@@alert "-unstable"]

(* The implementation makes a number of important choices for performance.

   First of all, the implementation makes use of `Multicore_magic` to pad data
   structures and to perform fenceless get operations on atomics.  Both padding
   and the use of fenceless get provide clear measurable performance
   improvements.

   Idle domains are pushed onto a Treiber stack.  Instead of using pointers, the
   stack uses indices that refer to preallocated `managed_domain` records.  This
   way operations on the stack require neither write barriers nor allocations.
   The indices are tagged to avoid ABA problems.

   You might be worried that a single shared Treiber stack does not scale.  The
   reason why that is not a major problem is that we need to allow any domain to
   quickly poll whether there are any idle domains.  The top of the Treiber
   stack tells whether there are idle domains and it can be read quickly using a
   fenceless get.

   Each managed domain has its own mutex and condition variable.  This should
   ensure that a wakeup operation does not block the other n-2 domains. *)

let null () = Obj.magic ()

type managed_id = Domain.id

let main_id = Domain.self ()

type scheduler = managed_id -> unit

type managed_domain = {
  mutex : Mutex.t;
  condition : Condition.t;
  id : managed_id;
  mutable next_idx : int;
}

type spawn = scheduler Atomic.t

let spawns = Multicore_magic.copy_as_padded (Atomic.make [])

let rec add spawn =
  let top = Multicore_magic.fenceless_get spawns in
  if not @@ Atomic.compare_and_set spawns top (spawn :: top) then add spawn

let is_empty () = Multicore_magic.fenceless_get spawns == [] [@@inline]

let rec try_remove () =
  match Multicore_magic.fenceless_get spawns with
  | [] -> null ()
  | spawn :: rest as top ->
    if not @@ Atomic.compare_and_set spawns top rest then try_remove ()
    else
      let scheduler = Atomic.exchange spawn (null ()) in
      if scheduler == null () then try_remove () else scheduler

let max_domains = Domain.recommended_domain_count ()

let managed_domains =
  Multicore_magic.copy_as_padded
    (ref (Multicore_magic.make_padded_array max_domains (null ())))

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

let idx_bits = 16
let tag_1 = 1 lsl idx_bits
let tag_mask = -tag_1
let idx_mask = tag_1 - 1
let none_idx = -1 land idx_mask
let target_of tagged_idx = tagged_idx land idx_mask [@@inline]

let make_tagged_idx ~expected ~target =
  (expected land tag_mask) + (target lor tag_1)
  [@@inline]

let top_idle = Multicore_magic.copy_as_padded (Atomic.make none_idx)

let alarm md =
  Mutex.lock md.mutex;
  Condition.signal md.condition;
  Mutex.unlock md.mutex
  [@@inline]

let alarm top idx =
  let md = Array.unsafe_get !managed_domains idx in
  if
    Atomic.compare_and_set top_idle top
      (make_tagged_idx ~expected:top ~target:md.next_idx)
  then alarm md

let alarm () =
  let top = Multicore_magic.fenceless_get top_idle in
  let idx = target_of top in
  if idx != none_idx then alarm top idx

let rec run_managed md =
  let scheduler = try_remove () in
  if null () != scheduler then got_managed md scheduler
  else
    let top = Multicore_magic.fenceless_get top_idle in
    md.next_idx <- target_of top;
    if
      not
        (Atomic.compare_and_set top_idle top
           (make_tagged_idx ~expected:top ~target:(md.id :> int)))
    then run_managed md
    else begin
      Mutex.lock md.mutex;
      wait_managed md
    end

and wait_managed md =
  let scheduler = try_remove () in
  if scheduler == null () && not !terminated then begin
    Condition.wait md.condition md.mutex;
    wait_managed md
  end
  else begin
    Mutex.unlock md.mutex;
    got_managed md scheduler
  end

and got_managed md scheduler =
  if not (is_empty ()) then alarm ();
  if scheduler != null () then scheduler md.id;
  if not !terminated then run_managed md

let managed_domain id =
  Multicore_magic.copy_as_padded
    {
      mutex = Mutex.create ();
      condition = Condition.create ();
      id;
      next_idx = none_idx;
    }

let next (id : managed_id) = Array.unsafe_get !next_sibling (id :> int)
  [@@inline]

let rec all ids id =
  if id == main_id then main_id :: ids else all (id :: ids) (next id)

let all () = all [] (next main_id)

let is_in_progress spawn = Multicore_magic.fenceless_get spawn != null ()
  [@@inline]

let spawn () = Multicore_magic.copy_as_padded @@ Atomic.make @@ null ()

let start spawn ~scheduler =
  let was = Atomic.exchange spawn scheduler in
  if was == null () then begin
    add spawn;
    alarm ()
  end
  [@@inline]

let cancel spawn =
  let was = Multicore_magic.fenceless_get spawn in
  if was != null () then Atomic.compare_and_set spawn was (null ()) |> ignore

let wakeup (id : managed_id) =
  let md = Array.unsafe_get !managed_domains (id :> int) in
  Mutex.lock md.mutex;
  Condition.signal md.condition;
  Mutex.unlock md.mutex

let rec run_idle ~until ready md =
  let scheduler = try_remove () in
  if null () != scheduler then got_idle ~until ready md scheduler
  else if not (until ready) then begin
    let top = Multicore_magic.fenceless_get top_idle in
    md.next_idx <- target_of top;
    if
      not
        (Atomic.compare_and_set top_idle top
           (make_tagged_idx ~expected:top ~target:(md.id :> int)))
    then run_idle ~until ready md
    else begin
      Mutex.lock md.mutex;
      wait_idle ~until ready md
    end
  end

and wait_idle ~until ready md =
  let scheduler = try_remove () in
  if scheduler == null () && not (until ready) then begin
    Condition.wait md.condition md.mutex;
    wait_idle ~until ready md
  end
  else begin
    Mutex.unlock md.mutex;
    got_idle ~until ready md scheduler
  end

and got_idle ~until ready md scheduler =
  if not (is_empty ()) then alarm ();
  if scheduler != null () then scheduler md.id;
  run_idle ~until ready md

let is_managed (id : Domain.id) =
  let mds = !managed_domains in
  (id :> int) < Multicore_magic.length_of_padded_array mds
  && Array.unsafe_get mds (id :> int) != null ()

let self () : managed_id =
  let id = Domain.self () in
  assert (is_managed id);
  id
  [@@inline]

let idle ~until ready =
  let id = Domain.self () in
  assert (is_managed id);
  let md = Array.unsafe_get !managed_domains (id :> int) in
  run_idle ~until ready md

exception Terminate

let terminate _ = raise Terminate [@@inline never]
let check_terminate () = if !terminated then terminate () [@@inline]

exception Managed_domains_raised of exn list

let () =
  Printexc.register_printer @@ function
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

  let rec terminate_all id =
    if id != main_id then begin
      wakeup id;
      terminate_all (next id)
    end
  in
  terminate_all (next main_id);

  let rec join_all exns id =
    if id == main_id then exns
    else
      let d = Array.unsafe_get !domains (id :> int) in
      match Domain.join d with
      | () -> join_all exns (next id)
      | exception Terminate -> join_all exns (next id)
      | exception exn -> join_all (exn :: exns) (next id)
  in
  let exns = join_all [] (next main_id) in

  if exns != [] then raise @@ Managed_domains_raised exns

let num_managed_domains = Atomic.make 0

let prepare ~num_domains =
  let num_domains = Int.max 1 (Int.min num_domains max_domains) in
  if Atomic.compare_and_set num_managed_domains 0 1 then begin
    at_exit terminate_at_exit;
    set managed_domains (main_id :> int) (managed_domain main_id);
    let mutex = Mutex.create () and condition = Condition.create () in
    Mutex.lock mutex;
    for _ = 2 to num_domains do
      let domain =
        Domain.spawn @@ fun () ->
        let id = Domain.self () in
        let md = managed_domain id in
        Mutex.lock mutex;
        set managed_domains (id :> int) md;
        Atomic.incr num_managed_domains;
        if Atomic.get num_managed_domains = num_domains then
          Condition.broadcast condition;
        while Atomic.get num_managed_domains <> num_domains do
          Condition.wait condition mutex
        done;
        Mutex.unlock mutex;
        run_managed md
      in
      let id = Domain.get_id domain in
      assert ((id :> int) < idx_mask);
      let next_id = Array.unsafe_get !next_sibling (main_id :> int) in
      set next_sibling (id :> int) next_id;
      set next_sibling (main_id :> int) id;
      set domains (id :> int) domain
    done;
    while Atomic.get num_managed_domains <> num_domains do
      Condition.wait condition mutex
    done;
    Mutex.unlock mutex
  end

let prepare_opt ~num_domains =
  prepare ~num_domains:(Option.value ~default:max_domains num_domains)

let prepare_recommended () = prepare_opt ~num_domains:None
