(*
open Core_kernel
let ( ! ) = `no_refs
open Hlist

module type F2 = Free_monad.Functor.S2

type m = A | B | C

let split_depth = 1
let split_width = 1 lsl split_depth

(* b from the paper *)
let zk_margin = 1

let gen_name =
  let r = ref (-1) in
  fun () -> incr r ; sprintf "a%d" r.contents

let reducei xs ( + ) f =
  match xs with
  | [] ->
      assert false
  | x :: xs ->
      List.foldi ~init:(f 0 x) ~f:(fun i acc x -> acc + f i x) xs

let reduce xs add f = reducei xs add (fun _ -> f)

let sum xs f = reduce xs Arithmetic_expression.( + ) f

let product xs f = reduce xs Arithmetic_expression.( * ) f

let sumi xs = reducei xs Arithmetic_expression.( + )

(* For simplicity we just handle 1 public input for now. *)
let interpolate
    (* The first element of the domain is 1 *)
    (_domain : 'field Sequence.t) (values : 'field list) =
  match values with
  | [v] ->
      fun x ->
        let open Arithmetic_expression in
        !v * (x - int 1)
  | _ ->
      assert false

let u_ (type f) domain (alpha : f) =
  let open Arithmetic_expression in
  let open Arithmetic_circuit.E in
  let v_H = Domain.vanishing domain in
  let%map v_H_alpha = v_H !alpha in
  fun x ->
    let%map v_H_x = v_H x in
    (!v_H_x - !v_H_alpha) / (x - !alpha)

module AHIOP = struct
  module Arithmetic_computation = struct
    module F = struct
      type ('k, 'f) t =
        | Eval of 'f Arithmetic_expression.t * ('f -> 'k)
        | Assert_equal of
            'f Arithmetic_expression.t * 'f Arithmetic_expression.t * 'k

      let map t ~f =
        let cont k x = f (k x) in
        match t with
        | Eval (x, k) ->
            Eval (x, cont k)
        | Assert_equal (x, y, k) ->
            Assert_equal (x, y, f k)

      let to_statement ~assert_equal ~constant ~int ~negate ~op ~pow =
        let expr = Arithmetic_expression.to_expr ~constant ~int ~op ~negate ~pow in
        function
        | Eval (e, k) ->
            let name = gen_name () in
            (Statement.Assign (name, expr e), k (Expr.Var name))
        | Assert_equal (x, y, k) ->
            (assert_equal (expr x) (expr y), k)

      let to_program ~assert_equal ~constant ~int ~negate  ~op ~pow t =
        let s, k = to_statement ~assert_equal ~constant ~int ~negate ~op ~pow t in
        ([s], k)
    end

    include Free_monad.Make2 (F)

    let to_program ~assert_equal ~constant ~int ~negate ~op ~pow =
      let rec go : type a. (a, 'f) t -> Program.t -> Program.t * a =
       fun t acc ->
        match t with
        | Pure x ->
            (List.rev acc, x)
        | Free f ->
            let s, k = F.to_statement f ~assert_equal ~constant ~int ~negate ~op ~pow in
            go k (s :: acc)
      in
      fun t -> go t []

    let eval x = Free (Eval (x, return))

    let ( = ) x y = Free (Assert_equal (x, y, return ()))

    let rec circuit : type a f. (a, f) Arithmetic_circuit.t -> (a, f) t =
     fun t ->
      match t with
      | Pure x ->
          Pure x
      | Free (Eval (c, k)) ->
          Free (Eval (c, fun y -> circuit (k y)))
  end

  module Batch_AHP_arithmetic = struct
    module F = struct
      type ('k, _) t =
        | Arithmetic :
            ('k, 'field) Arithmetic_computation.F.t
            -> ('k, < field: 'field ; .. >) t
        | Query :
            (('poly, 'n) Vector.t * 'field * (('field, 'n) Vector.t -> 'k))
            -> ('k, < poly: 'poly ; field: 'field ; .. >) t

      let map : type a b s. (a, s) t -> f:(a -> b) -> (b, s) t =
       fun t ~f ->
        match t with
        | Arithmetic a ->
            Arithmetic (Arithmetic_computation.F.map a ~f)
        | Query (ps, x, k) ->
            Query (ps, x, fun res -> f (k res))
    end

    include Free_monad.Make2 (F)

    let query ps x = Free (Query (ps, x, return))

    let eval x = Free (Arithmetic (Eval (x, return)))

    let ( = ) x y = Free (Arithmetic (Assert_equal (x, y, return ())))

    let rec circuit : type a f.
        (a, f) Arithmetic_circuit.t -> (a, < field: f ; .. >) t =
     fun t ->
      match t with
      | Pure x ->
          Pure x
      | Free (Eval (c, k)) ->
          Free (Arithmetic (Eval (c, fun y -> circuit (k y))))
  end

  module AHP = struct
    module Interaction = struct
      type (_, _) t =
        | Query :
            (('poly, 'n) Vector.t * 'field * (('field, 'n) Vector.t -> 'k))
            -> ('k, < poly: 'poly ; field: 'field ; .. >) t

      let map : type a b s. (a, s) t -> f:(a -> b) -> (b, s) t =
       fun t ~f ->
        match t with Query (ps, x, k) -> Query (ps, x, fun res -> f (k res))
    end

    include Free_monad.Make2 (Interaction)

    let query ps x = Free (Query (ps, x, return))

    let query ps x =
      query ps x >>| Vector.map ~f:Arithmetic_expression.constant
  end

  module PCS_IP = struct
    module Interaction = struct
      module Message = struct
        type (_, _) t =
          | Evals :
              ('poly, 'n) Vector.t * 'field
              -> ( ('field, 'n) Vector.t
                 , < poly: 'poly ; field: 'field ; .. > )
                 t
          | Proof :
              'poly * 'field * 'field
              -> ('pi, < poly: 'poly ; field: 'field ; proof: 'pi ; .. >) t
      end

      type (_, _) t = Receive : ('a, 'e) Message.t * ('a -> 'k) -> ('k, 'e) t

      let map : type a b s. (a, s) t -> f:(a -> b) -> (b, s) t =
       fun t ~f ->
        let cont k x = f (k x) in
        match t with Receive (m, k) -> Receive (m, cont k)
    end

    module Computation = struct
      type ('k, _) t =
        | Arithmetic :
            ('k, 'field) Arithmetic_computation.F.t
            -> ('k, < field: 'field ; .. >) t
        | Scale_poly :
            'field * 'poly * ('poly -> 'k)
            -> ('k, < poly: 'poly ; field: 'field ; .. >) t
        | Add_poly :
            'poly * 'poly * ('poly -> 'k)
            -> ('k, < poly: 'poly ; .. >) t
        | Check_proof :
            'poly * 'field * 'field * 'pi * 'k
            -> ('k, < poly: 'poly ; field: 'field ; proof: 'pi ; .. >) t

      let map : type a b s. (a, s) t -> f:(a -> b) -> (b, s) t =
       fun t ~f ->
        let cont k x = f (k x) in
        match t with
        | Arithmetic a ->
            Arithmetic (Arithmetic_computation.F.map a ~f)
        | Check_proof (poly, x, y, pi, k) ->
            Check_proof (poly, x, y, pi, f k)
        | Scale_poly (x, p, k) ->
            Scale_poly (x, p, cont k)
        | Add_poly (p, q, k) ->
            Add_poly (p, q, cont k)
    end

    module Randomness = struct
      type (_, _) t =
        | () : ('field, < field: 'field; .. >) t
    end

    include Ip.T (Randomness)(Interaction) (Computation)

    let eval ps x = interact (Receive (Evals (ps, x), return))

    let scale_poly x p = compute (Scale_poly (x, p, return))

    let add_poly x y = compute (Add_poly (x, y, return))

    let field_op o x y =
      compute
        (Arithmetic
           (Arithmetic_computation.F.Eval
              (Arithmetic_expression.(op o !x !y), return)))

    let add_field x y = field_op `Add x y

    let scale_field x y = field_op `Mul x y

    let get_and_check_proof poly ~input:x ~output:y =
      let%bind pi = interact (Receive (Proof (poly, x, y), return)) in
      compute (Check_proof (poly, x, y, pi, return ()))

    let scaling ~scale ~add xi =
      let open Let_syntax in
      let rec go acc = function
        | [] ->
            return acc
        | p :: ps ->
            let%bind acc = scale xi acc >>= add p in
            go acc ps
      in
      function [] -> assert false | p :: ps -> go p ps

    (* TODO: Cata *)
    let rec ahp_compiler : type a.
           (a, < field: 'field ; poly: 'poly >) AHP.t
        -> (a, < field: 'field ; poly: 'poly ; proof: 'pi >) t =
     fun v ->
      match v with
      | Pure x ->
          Pure x
      | Free v -> (
        match v with
        | Query (ps, x, k) ->
            let open Let_syntax in
            let%bind vs = eval ps x in
            let%bind xi = sample () in
            let%bind p =
              scaling ~scale:scale_poly ~add:add_poly xi (Vector.to_list ps)
            and v =
              scaling ~scale:scale_field ~add:add_field xi (Vector.to_list vs)
            in
            let%bind () = get_and_check_proof p ~input:x ~output:v in
            ahp_compiler (k vs) )
  end

  module Verifier = struct
    module Pairing = struct
      module F = struct
        type ('k, _) t =
          | Arithmetic :
              ('k, 'f) Arithmetic_computation.F.t
              -> ('k, < field: 'f ; .. >) t
          | Scale :
              'f * 'g1 * ('g1 -> 'k)
              -> ('k, < field: 'f ; g1: 'g1 ; .. >) t
          | Add : 'g1 * 'g1 * ('g1 -> 'k) -> ('k, < g1: 'g1 ; .. >) t
          | Assert_equal :
              [`pair_H of 'g1] * [`pair_betaH of 'g1] * 'k
              -> ('k, < g1: 'g1 ; .. >) t

        let map : type a b s. (a, s) t -> f:(a -> b) -> (b, s) t =
         fun t ~f ->
          let cont k x = f (k x) in
          match t with
          | Arithmetic k ->
              Arithmetic (Arithmetic_computation.F.map k ~f)
          | Scale (x, g, k) ->
              Scale (x, g, cont k)
          | Add (x, y, k) ->
              Add (x, y, cont k)
          | Assert_equal (p1, p2, k) ->
              Assert_equal (p1, p2, f k)
      end

      include Free_monad.Make2 (F)
    end

    let batch_pairing : type a field g1.
           (a, < field: field ; g1: g1 >) Pairing.t
        -> field
        -> (a, < field: field ; g1: g1 >) Pairing.t =
     fun t ->
      let module E = struct
        type t = < field: field ; g1: g1 >
      end in
      let open Pairing.Let_syntax in
      let rec go (xi : field) (acc : (g1 * g1) option) (t : (a, E.t) Pairing.t)
          =
        match t with
        | Pure v ->
            Option.value_map acc ~default:(return v) ~f:(fun (x1, x2) ->
                let%map () =
                  Free (Assert_equal (`pair_H x1, `pair_betaH x2, return ()))
                in
                v )
        | Free t -> (
          match t with
          | Assert_equal (`pair_H p1, `pair_betaH p2, k) ->
              let%bind acc =
                Option.value_map acc
                  ~default:(return (p1, p2))
                  ~f:(fun (x1, x2) ->
                    let cons p x =
                      let%bind xi_x = Free (Scale (xi, x, return)) in
                      Free (Add (xi_x, p, return))
                    in
                    let%map x1' = cons p1 x1 and x2' = cons p2 x2 in
                    (x1', x2') )
              in
              go xi (Some acc) k
          | _ ->
              Free (Pairing.F.map t ~f:(go xi acc)) )
      in
      fun xi -> go xi None t

    (* Pairing -> Random(Pairing) *)
  end

  let abc a b c = function A -> a | B -> b | C -> c

  module Index = struct
    type 'poly t = {row: m -> 'poly; col: m -> 'poly; value: m -> 'poly}
  end

  module Fractal = struct
    module Fof = struct
      let add (p1, q1) (p2, q2) =
        let open Arithmetic_expression in
        let denom = (q1 * q2)
        and num = (p1*q2 + p2*q1) in
        (num, denom)
    end

    module Prover_message = struct
      type ('field, 'poly) basic =
        [`Field of 'field | `X | `Poly of 'poly | `M_hat of m * 'field]

      type ('a, 'env) t =
        | F_w :
            { input : 'field list
            ; h: Domain.t 
            }
            -> ('poly, < poly: 'poly; field: 'field; .. >) t
        | Mz_random_extension :
            { m: m
            ; h : Domain.t }
            -> ('poly, < poly: 'poly ; .. >) t
        | Random_summing_to_zero :
            { h : Domain.t
            ; degree : int }
            -> ('poly, < poly: 'poly ; .. >) t
        | Linear_combination :
            ('field * [`u of m * 'field]) list 
            -> ('poly, < poly: 'poly ; field: 'field; .. >) t
        | Eval : 'poly * 'field
            -> ('field, < poly: 'poly ; field: 'field; .. >) t
        | Sigma_residue
          : { f : [ `Field of 'field
                  | `Poly_times_x of 'poly
                  | `Poly of 'poly 
                  | `Vanishing_poly of Domain.t 
                  | `Circuit of ('field -> 
                                 ('field, 'field) Arithmetic_circuit.t)
                  ] Arithmetic_expression.t as 'expr
            ; q : 'expr
            ; domain : Domain.t }
        (* Given f, q, sigma, and domain H,
           compute g such that exists h such that

           Sigma_H(g, sigma) q + h v_H = f.

           g can be computed as

           (* r + h v_H = f *)
           let (h, r) = div_mod(f, v_H) in 
           ((r / q) - sigma / |H|) / X
        *)
            -> ('poly, < poly: 'poly ; field: 'field; .. >) t

      let degree_bound : type e a. b:int -> Domain.t -> (a, e) t -> int option =
        fun ~b h t ->
        match t with
        | F_w
            { input
            ; h } -> Some (Domain.size h - List.length input + b - 1)
        | Mz_random_extension 
            { m=_
            ; h }
            -> Some (Domain.size h + b - 1)
        | Random_summing_to_zero 
            { h=_
            ; degree  } -> Some (degree)
        | Linear_combination _terms ->
          Some (Domain.size h - 1)
        | Sigma_residue { f=_; q=_; domain } ->
          Some (Domain.size domain - 2)
        | Eval _ -> None
    end

    module Messaging_IP
        (Randomness : T2)
        (Computation : F2)
        (Message : T2)
      : sig
      include Ip.S
      with module Interaction := Messaging.F(Message)
        and module Computation := Computation
        and module Randomness := Randomness

      val send : ('q, 'e) Type.t -> 'q -> ('r, 'e) Message.t -> ('r, 'e) t

      val receive  : ('r, 'e) Message.t -> ('r, 'e) t

      val challenge
        : ('f, < field:'f; ..> as 'e) Randomness.t
        -> ('r, 'e) Message.t
        -> ('f * 'r, 'e) t

      val interact
        : send:('f, 'n) Vector.t
        -> receive:('r, < field:'f; ..> as 'e) Message.t
        -> ('r, 'e) t
    end = struct
      include Ip.T (Randomness)(Messaging.F(Message)) (Computation)

      let send t_q q t_r = interact (Send_and_receive (t_q, q, t_r, return))

      let challenge t m =
        let open Let_syntax in
        let%bind c = sample t in
        let%map x = send Field c m in
        (c, x)

      let receive t =
        let%map x = send (Hlist []) [] t in
        x

      let interact ~send:q ~receive =
        let n = Vector.length q in
        send (Type.Vector (Field, n)) q receive
    end

    module Evaluation_domain : sig
      type t 

      val pow : t -> t

    end = struct
      type t =
        { log_split_width_size : int }

      let pow { log_split_width_size } =
        { log_split_width_size = log_split_width_size + 1 }
    end

    module Randomness = struct
      type (_, _) t =
        | () : ('field, < field: 'field; .. >) t
        (* The domain L^i *)
        | Evaluation_domain
          : Evaluation_domain.t -> ('loc, < loc: 'loc; ..>) t
    end

    module Computation = Arithmetic_circuit.E.F

    module Basic_IP = struct
      module F = Ip.F(Randomness)(Messaging.F(Prover_message)) (Computation)
      include Messaging_IP(Randomness)(Computation)(Prover_message)
    end

    module Junk = struct
      module Randomness = struct
        type (_, _) t =
          | Field

            : ('field, < field : 'field; ..>) t
      end

      module Computation = struct
        type (_, _) t =
          | Check_equal
            : 'field Arithmetic_expression.t * 'field Arithmetic_expression.t
              * 'k
              -> ('k, < field: 'field; ..>) t

        let map : type a b e. (a, e) t -> f:(a -> b) -> (b, e) t =
          fun t ~f ->
            match t with
            | Check_equal (x, y, k) -> Check_equal (x, y, f k)
      end

      module Interaction = struct
        module Prover_message = struct
          type (_, _) t =
            | Square_root : 'field Arithmetic_expression.t -> ('field, < field: 'field; ..>) t
        end
        include Messaging.F(Prover_message)
      end

      include Ip.T(Randomness)(Interaction)(Computation)

      let protocol x =
        let open Arithmetic_expression in
        let%bind a = sample Field in
        let%bind r =
          interact
            (Send_and_receive
               (Field
               , a
               , Square_root (!a * !x)
                , return))
        in
        compute (
          Check_equal
            (!r * !r, !a * !x, return ()))

    end

    type ('field, 'poly) virtual_oracle =
      [ `Field of 'field 
      | `Poly_times_x of 'poly
      | `Poly of 'poly 
      | `Vanishing_poly of Domain.t 
      | `Circuit of ('field -> 
                      ('field, 'field) Arithmetic_circuit.t)
      ] Arithmetic_expression.t

    module Oracle = struct
      type ('field, 'poly) t =
        | Poly of 'poly
        | Virtual of ('field, 'poly) virtual_oracle
    end

    module FRI = struct
      module Computation = struct
        type ('a, 'e) t =
          | Arithmetic of ('a, 'e) Arithmetic_circuit.E.F.t
          | Assert_equal :
              'field Arithmetic_expression.t * 'field Arithmetic_expression.t
              * 'k -> ('k, < field: 'field; .. >) t
          | Adapt_location
            : Evaluation_domain.t * 'loc * ('loc -> 'k) -> ('k, < loc: 'loc; ..>) t
          | Location_to_field
            : 'loc * ('field -> 'k) -> ('k, < loc: 'loc; field: 'field; ..>) t

        let map : type a b e. (a, e) t -> f:(a -> b) -> (b, e) t =
          fun t ~f ->
          let cont k = fun x -> f(k x) in
          match t with
          | Arithmetic a -> Arithmetic (Arithmetic_circuit.E.F.map a ~f)
          | Assert_equal (x, y,k) -> Assert_equal (x, y, f k)
          | Adapt_location (dom, l, k) ->
            Adapt_location (dom, l, cont k)
          | Location_to_field (l, k) ->
            Location_to_field (l, cont k)
      end

      (* Split into 2^split_depth "coset polynomials" *)
      let k = split_width

      module Prover_message = struct
        type (_, _) t =
          | Coset_evals
            : 'poly * 'loc
          (* Let S be the two-adic subgroup of F^*, 

             S = < omega_0 >
             |S| = N = 2^n

             Let L = g S for some g notin S of large order.

             Let L_n = L.
             Let L_{i - split_depth} = L_i ^ (2^split_depth) = L_i ^ split_width

             So |L_i| = 2^i and L_i = g^{2^{n-i}} < omega_0^{2^{n - i}} >
          *)

          (* Given a polynomial f and x in a given domain, get
              f( omega^i x ) for 0 <= i < k

             We represent each oracle for domain L_t as a Merkle tree
             with the the i^{th} leaf containing the coset

             x_i * < omega_0^{N / split_width} >

             which is what this message should be.
          *)
              -> ('field list, < field: 'field; poly: 'poly; loc: 'loc; ..>) t
          | Sub_poly_constant
            :  'poly * 'field
              -> ('field, < field: 'field; poly: 'poly; ..>) t
          | Sub_poly_commitment
            : ('field, 'poly) Oracle.t * 'field * Evaluation_domain.t
          (* Given a polynomial f and field elt a, commit on domain d to the polynomial

             \sum_{i=0}^k a^i f_i

             where the f_i are such that

             f = \sum_{i=0}^k x^i f_i(x^k)
          *)
              -> ('poly, < field: 'field; poly: 'poly; ..>) t
      end 

      module IP = Messaging_IP(Randomness)(Computation)(Prover_message)

      open IP

      let eval t =
        compute (Arithmetic (Eval (t, return)))

      module Virtual_oracle = struct
        type ('field, 'poly) t = ('field, 'poly) virtual_oracle

        (* TODO: Not sure if the caching layer should go here. *)
        let rec coset_evals (type loc field poly)
            (evals : (poly, field list) Hashtbl.t)
            (c : (field, poly) t)
            (loc : loc)
            (z_loc : field)
          : 
            (field list, < poly: poly; field: field; loc: loc; .. >) IP.t
          =
          (* Traversable would be nice... *)
          let rec eval_expr i
            : [ `Field of field 
              | `Poly of poly 
              | `Poly_times_x of poly 
              | `Vanishing_poly of Domain.t 
              | `Circuit of (field -> (field, field) Arithmetic_circuit.t)
              ] Arithmetic_expression.t
              -> (field Arithmetic_expression.t,  < field: field; poly:poly; ..> as 'env) IP.t =
            let open Arithmetic_expression in
            function
            | Op (op, x, y) ->
              let%bind x = eval_expr i x in
              let%map y = eval_expr i y in
              Op (op, x, y)
            | Int n -> return (Int n)
            | Pow (x,n) ->
              let%map x = eval_expr i x in
              Pow(x,n)
            | Negate x -> let%map x = eval_expr i x in Negate x
            | Constant (`Field f) -> return (Constant f)
            | Constant (`Circuit c) ->
              let%map x = circuit_eval (c z_loc) in
              Constant x
            | Constant (`Vanishing_poly (dom)) -> 
              (* The vanishing poly takes on the same values everywhere in the coset. *)
              return (Pow (Constant z_loc, Domain.size dom))
            | Constant (`Poly_times_x p) ->
              let%bind pz = eval_expr i (Constant (`Poly p)) in
              eval (!z_loc * pz) >>| constant
            | Constant (`Poly p) ->
              match Hashtbl.find evals p with
              | Some xs -> return (Constant (List.nth_exn xs i))
              | None ->
                let%map xs = receive (Coset_evals (p, loc)) in
                Hashtbl.set evals ~key:p ~data:xs;
                Constant (List.nth_exn xs i)
          in
          List.init split_width ~f:(fun i -> eval_expr i c >>= eval)
          |> all
        and
          circuit_eval : type a field poly loc. (a, field) Arithmetic_circuit.t -> (a, < field: field; poly:poly; loc:loc; ..>) IP.t
          =
          fun c ->
          match c with
          | Pure x ->
            return x
          | Free (Eval (x, k)) ->
            let%bind y = eval x in
            circuit_eval (k y)

        let of_oracle = function
          | Oracle.Virtual c -> c
          | Poly p ->
            Arithmetic_expression.(! (`Poly p))
      end

      let pow (type field) (x : field) k =
        let test_bit i = (k lsr i) land 1 = 1 in
        let top_bit =
          let open Sequence in
          init Int.num_bits ~f:(fun i -> Int.num_bits - 1 - i)
          |> filter ~f:test_bit
          |> hd_exn
        in
        let open Arithmetic_expression in
        let rec go (acc : field) i =
          if i < 0
          then return (!acc)
          else 
            let%bind acc =
              if test_bit i then eval (!x * !acc)
              else return acc
            in
            let%bind acc = eval (!acc * !acc) in
            go acc Int.(i - 1)
        in
        if k = 0
        then return (Int 1)
        else go x Int.(top_bit - 1)

      (* Compute x^0, x^1, ... x^{k - 1 } *)
      let pows (type field) (x : field) k =
        let (!) = Arithmetic_expression.(!) in
        (* Can't be bothered with edge cases. *)
        assert (k >= 2);
        let rec go acc x_to_i_minus_1 i =
          if i = k
          then return (Array.of_list_rev acc)
          else
            let%bind x_to_i = eval Arithmetic_expression.(!x * !x_to_i_minus_1) in
            go (!x_to_i :: acc) x_to_i (i + 1)
        in
        go [ !x; Int 1 ] x 2

      (* TODO: omega^(row*col) should be precomputed *)
      let phi_inverse omega_pows z = 
        let open Arithmetic_expression in
        let k = Array.length omega_pows in
        let%map z_pows = pows z k in
        List.init k ~f:(fun row ->
          List.init k ~f:(fun col ->
          int 1 / ( omega_pows.(Int.((row*col) mod k)) * z_pows.(row)) ))

      (*
        f_omega_zs = [ f (omega^i z), i in [0, K - 1] ]

         u_i = f(omega^i z)
         U = < u_i >

         v_i = f_i(z^K)
         V = < v_i >

         phi : U -> V
         f(omega^i z) = \sum_j omega^{i*j} z^j f_j(z^K)
         u_i = \sum_j omega^{i*j} z^j v_j

         phi is injective. 

         We want to find phi^{-1}(v_j) for each j.

         As a matrix phi looks like

         columns(
          { omega^{0*0} z^0, omega^{0*1} z^1, ... },
          { omega^{1*0} z^0, omega^{1*1} z^1, ... },
          { omega^{2*0} z^0, omega^{2*1} z^1, ... },
          ... )

         I found the expression in the below claim by computing the
         inverse of this matrix for small K and extrapolating.

         Claim:
         v_t = \sum_i 1/(K w^{t*i} z^t) u_i

         = \sum_i 1/(K w^{t*i} z^t) \sum_j w^{i*j} z^j v_j
         = \sum_i \sum_j 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         = \sum_j \sum_i 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         =  \sum_i 1/(K w^{t*i} z^t) w^{t*i} z^t v_t
          + \sum_{j != t} \sum_i 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         =  (\sum_i 1/(K w^{t*i} z^t) w^{t*i} z^t) v_t
          + \sum_{j != t} \sum_i 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         =  (\sum_i 1/(K w^{t*i}) w^{t*i}) v_t
          + \sum_{j != t} \sum_i 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         =  v_t
          + \sum_{j != t} \sum_i 1/(K w^{t*i} z^t) w^{i*j} z^j v_j
         =  v_t
          + 1/(K z^t) \sum_{j != t} z^j (\sum_i w^{i*(j - t)}) v_j
         = v_t
      *)
      (* TODO: Optimization: Division by k can be done once *)
      let fi_zks ~omega_pows ~z f_omegai_zs =
        let open Arithmetic_expression in
        let k = Array.length omega_pows in
        let%bind z_inv = eval (Int 1 / ! z ) in
        let%map z_inv_pows = pows z_inv k in
        Array.init k ~f:(fun t ->
          sumi f_omegai_zs (fun i u_i ->
            omega_pows.(Int.((k - (t*i)) mod k)) * z_inv_pows.(t) * !u_i / int k
              ))

      let adapt_location dom l = compute (Adapt_location (dom, l, return))
      let location_to_field l = compute (Location_to_field ( l, return))
      let assert_equal x y = compute (Assert_equal (x, y, return ()))

(* TODO: It's possible I need to use independent alphas here rather
   than alpha, alpha^2, ... *)
      let check_evaluation ~omega_pows ~alpha ~z f1_zk f_omega_zs =
        let%bind fi_zks = (fi_zks ~omega_pows ~z f_omega_zs) in
        let rec go acc i =
          if i < 0
          then acc
          else
            let open Arithmetic_expression in
            (* Multiply by alpha, then add next term *)
            go (!alpha * acc + fi_zks.(i)) Int.(i - 1)
        in
        let k = Array.length fi_zks in
        let expected_f1_zk = go fi_zks.(k-1) (k-2)  in
        assert_equal expected_f1_zk (Arithmetic_expression.constant f1_zk)

(* TODO: I wonder if the rust compiler will insert "drops"
   at the appropriate locations so that we deallocate as we compute.

   May have to insert explicit scoping into the monad. 
*)
      (* I really need looping in the target language, otherwise the generated code is going to be huge. *)
      let fri ~create_cache ~omega_pows f0 dom0 logk_d0 =
        let query_phase commitments =
          let%bind loc = sample (Evaluation_domain dom0) in
          let cache = create_cache () in
          let%bind evals =
            List.map commitments ~f:(fun (f, dom, alpha) ->
              let%bind loc = adapt_location dom loc in
              let%bind z = location_to_field loc in
              let%map evals = 
                Virtual_oracle.(
                  coset_evals cache
                    (of_oracle f)
                    loc z)
              in
              (evals, z, alpha)
              )
            |> all
            >>| Array.of_list
          in
          List.init (Array.length evals - 1) ~f:(fun i ->
            let f_loc, z, alpha = evals.(i) in
            let f1_loc, _, _ = evals.(i+1) in
            check_evaluation ~omega_pows ~alpha ~z
              (List.hd_exn f1_loc) f_loc )
          |> all
        in
        let rec commitments acc f dom logk_d =
          (*
            Test that f has degree less than k^log_d.
          *)
          if logk_d = 1
          then
            (* f is degree < k, so f's subpolynomial will be a constant *)
            (* TODO: This is missing the last check. I.e., f is never checked for low degreeness *)
            (*
            let%bind alpha = sample () in
            let%bind f1 =
              receive (Sub_poly_constant (f, alpha))
            in
            let%bind loc = sample (Evaluation_domain dom0) in *)
            return (List.rev acc)
          else
            let%bind alpha = sample () in
            let dom2 = Evaluation_domain.pow dom in
            let%bind f1 =
              receive (Sub_poly_commitment (f, alpha, dom2))
            in
            commitments ((f, dom, alpha) :: acc) (Poly f1) dom2 (logk_d - 1)
        in
        commitments [] (Virtual f0) dom0 logk_d0 >>= query_phase
    end

    open Basic_IP

    let rec with_implicit_degree_constraints 
      : type a field poly.
        b:int
        -> Domain.t
        -> (poly * int) list
        -> (a, < poly:poly; field:field >) t
        -> (a * (poly * int) list, < poly:poly; field:field >) t
      =
      fun ~b h acc t ->
      match t with
      | Pure x -> Pure (x, acc)
      | Free (Interact (Send_and_receive (t_q, q, t_r, k))) ->
        Free (Interact (Send_and_receive (t_q, q, t_r, fun r ->
          let acc =
            let c : (poly * int) option =
              match t_r with
              | F_w
                  { input
                  ; h } -> Some (r, Domain.size h - List.length input + b - 1)
              | Mz_random_extension 
                  { m=_
                  ; h }
                  -> Some (r, Domain.size h + b - 1)
              | Random_summing_to_zero 
                  { h=_
                  ; degree  } -> Some (r, degree)
              | Linear_combination _terms ->
                Some (r, Domain.size h - 1)
              | Sigma_residue { f=_; q=_; domain } ->
                Some (r, Domain.size domain - 2)
              | Eval _ -> None
            in
            Option.value_map ~f:List.cons ~default:Fn.id c acc
          in
          with_implicit_degree_constraints ~b h acc (k r))))
      | Free f -> Free (F.map f ~f:(with_implicit_degree_constraints ~b h acc))

    let with_implicit_degree_constraints ~b h t =
      with_implicit_degree_constraints ~b h [] t

    let sample_eta () =
      let%map a = sample ()
      and b = sample ()
      and c = sample () in
      abc a b c 

    (* Sigma_S(g, sigma) = X g(X) + sigma / |S| *)

(* g_1 such that exists h 

   X g_1(X) + h v_H = f.

   let (q, r) such that
     { f = v_H q + r}
    =
    div_mod (f, v_H)
   in
*)

    let abc f =
      let%map a = f A
      and b = f B
      and c = f C in
      abc a b c

    (* TODO: Assuming input has size 1 *)
    let v_I x = Arithmetic_circuit.eval Arithmetic_expression.(!x - Int 1)

    let ceil_div x k =
      (x + (k - 1)) / k

    let log_split_width x =
      ceil_div (Int.ceil_log2 x) split_depth

    let combine : type field poly.
        ((field, poly) Oracle.t * int) list
      -> ((field, poly) Oracle.t * int, < field: field; poly: poly; .. >) t
      =
      fun fds ->
        let d = List.max_elt (List.map ~f:snd fds) ~compare:Int.compare |> Option.value_exn in
        let log_split_width = log_split_width d in
        let d0 = Int.pow split_width log_split_width in
        let%map terms =
          List.map fds ~f:(fun (fi,di) ->
            let%map alpha = sample () in
            let open Arithmetic_expression in
            ! (`Field alpha)
            * !(`Circuit (fun x -> Arithmetic_circuit.eval (Pow (!x, Int.(d0 - di)))) )
            * FRI.Virtual_oracle.of_oracle fi )
          |> all
        in
        ( Oracle.Virtual (List.reduce_exn terms ~f:Arithmetic_expression.(+)), log_split_width )

    let protocol (type poly field) { Index.row; col; value } b domain_H domain_K (input : field list) =
      (* TODO: Make parallelism explicit so the prover can utilize that. *)
      let%bind f_w = receive (F_w { input; h=domain_H })
      and f_ = abc (fun m ->receive (Mz_random_extension { m; h=domain_H }) )
      and (r : poly) = receive (Random_summing_to_zero { h=domain_H; degree=2 * Domain.size domain_H + b - 2 })
      in
      let open Arithmetic_expression in
      let%bind alpha = sample () in
      let%bind v_H_alpha = lift_compute (Domain.vanishing domain_H (!alpha)) in
      let%bind eta = abc (fun _ -> sample ()) in
      let%bind t =
        interact ~send:[ alpha; eta A; eta B; eta C ]
          ~receive:(
            Linear_combination (List.map [A;B;C]  ~f:(fun m ->
                (eta m, `u (m, alpha)))))
      in
      let open Arithmetic_expression in
      let f_1 =
        let f_z = 
          let f_x = let f = interpolate Sequence.empty input in
            fun x -> Arithmetic_circuit.( eval (f (!x))
              )
          in
          !(`Poly f_w) * !(`Circuit v_I) + !(`Circuit f_x)
        in
        let u_x_alpha (x : field) = 
          Arithmetic_circuit.(
            let%bind v_H_x = Domain.vanishing0 domain_H (!x) in
            eval (
              (! v_H_x - ! v_H_alpha)
              / (!x - !(alpha))))
        in
        !(`Poly r) - !(`Poly t) * f_z + sum [A;B;C] (fun m ->
          !(`Field (eta m)) * !(`Circuit u_x_alpha ) * !(`Poly(f_ m) ))
      in
      let%bind (g_1 : poly) =
        receive
          (Sigma_residue { f=f_1
                         ; q=Int 1; domain=domain_H })
      in
      let%bind beta = sample () in
      let%bind p, q =
        let%map v_H_alpha_v_H_beta =
          let v_H x = Domain.vanishing domain_H x in
          lift_compute Arithmetic_circuit.E.(
              let%bind (a : field) = v_H (!alpha)
              and (b : field) = v_H (!beta)
              in
              eval (!a * !b)
            )
        in
        let top, bot =
          reduce [A;B;C] Fof.add (fun m ->
              let (/) = Tuple2.create in
              (! (`Field (eta m)) * value m) / 
              ((! (`Field alpha) - row m) * (! (`Field beta) - col m)) )
        in
        (Negate (! (`Field v_H_alpha_v_H_beta)) * top, bot)
      in
      let%bind gamma =
        interact
          ~send:[beta]
          ~receive:(Eval (t, beta))
      and g_2 =
        receive
          (Sigma_residue { f=p; q; domain= domain_K })
      in
      let v_H = `Vanishing_poly domain_H in
      let s =
        let f_ m = !(`Poly (f_ m)) in
        ( f_ A * f_ B - f_ C ) / !(v_H)
      in
      let h =
        let sigma_H_g_1 = !(`Poly_times_x g_1) in
        ( f_1 - sigma_H_g_1 ) / !(v_H )
      in
      let e = 
        let sigma_K_g_2_gamma =
          !(`Poly_times_x g_2) +
            ((! (`Field gamma)) / Int (Domain.size domain_K))
        in
        ( sigma_K_g_2_gamma * q - p ) / !(`Vanishing_poly domain_K
)
      in
      (* TODO: Random linear combination and "levelling off" *)
      (* Not sure about the use of fri_rounds. Wrote this after not touching the code for a long time. *)
      combine
        [ (Virtual s, Int.(Domain.size domain_H + 2 * b - 2))
        ; (Virtual h, Int.(Domain.size domain_H + b - 2))
        ; (Virtual e, 
          let k = Domain.size domain_K in
          Int.(max (5*k - 5 - k) (6*k - 6 - 1)
              ) )
        ]

    let _ = protocol

  end

  module Marlin_prover_message = struct
    type ('field, 'poly) basic =
      [`Field of 'field | `X | `Poly of 'poly | `M_hat of m * 'field]

    (* All degrees are actuall a strict upper bound on the degree *)
    type (_, _) t =
      | Sum :
          Domain.t
          * ((('field, 'poly) basic as 'lit), 'lit) Arithmetic_circuit.t
          -> ('field, < field: 'field ; poly: 'poly ; .. >) t
      | PCS : ('a, 'e) PCS_IP.Interaction.Message.t -> ('a, 'e) t
      | Random_mask : int -> ('poly, < poly: 'poly ; .. >) t
      | W_hat :
          { degree: int
          ; domain: Domain.t
          ; input_size: int }
          -> ('poly, < poly: 'poly ; .. >) t
      | Mz_hat :
          { m: m
          ; b: int
          ; domain: Domain.t }
          -> ('poly, < poly: 'poly ; .. >) t
      | GH :
          Domain.t * ('field, 'poly) basic
          -> ('poly * 'poly, < field: 'field ; poly: 'poly ; .. >) t

    let type_ : type a e. (a, e) t -> (a, e) Type.t = function
      | Sum _ ->
          Field
      | Random_mask n ->
          Polynomial n
      | GH (domain, _expr) ->
          let degree_g = Domain.size domain - 1 in
          let degree_h = failwith "TODO" in
          Pair (Polynomial degree_g, Polynomial degree_h)
      | W_hat {degree; _} ->
          Polynomial degree
      | Mz_hat {domain; _} ->
          Polynomial (Domain.size domain + zk_margin)
      | PCS (Evals (v, _)) ->
          Vector (Field, Vector.length v)
      | PCS (Proof _) ->
          Proof

    let zk_only = function Random_mask _ -> true | _ -> false

    let domain_sum dom e = Sum (dom, e)

    let random_mask d = Random_mask d

    let w_hat degree domain input_size = W_hat {degree; domain; input_size}

    let mz_hat domain m = Mz_hat {domain; m; b= zk_margin}
  end

  module Basic_IP = struct
    module Interaction = Messaging.F(Marlin_prover_message)
    module Computation = Trivial_computation
    include Ip.T (Interaction) (Computation)

    let send t_q q t_r = interact (Send_and_receive (t_q, q, t_r, return))

    let challenge m =
      let open Let_syntax in
      let%bind c = sample in
      let%map x = send Field c m in
      (c, x)

    module Of_PCS = struct end
  end

  module SNARK (Computation : F2) = struct
    module Proof_component = Marlin_prover_message

    module Hash_input = struct
      type 'e t =
        | Field : 'field -> < field: 'field ; .. > t
        | Polynomial : 'poly -> < poly: 'poly ; .. > t
        | PCS_proof : 'proof -> < proof: 'proof ; .. > t
    end

    module F = struct
      type ('k, 'e) t =
        | Proof_component :
            ('r, 'e) Proof_component.t * ('r -> 'k)
            -> ('k, 'e) t
        | Compute : ('a, 'e) Computation.t -> ('a, 'e) t
        | Absorb : 'e Hash_input.t * 'k -> ('k, 'e) t
        | Squeeze : ('field -> 'k) -> ('k, < field: 'field ; .. >) t

      let map : type a b e. (a, e) t -> f:(a -> b) -> (b, e) t =
       fun t ~f ->
        let cont k x = f (k x) in
        match t with
        | Compute c ->
            Compute (Computation.map c ~f)
        | Squeeze k ->
            Squeeze (cont k)
        | Absorb (h, k) ->
            Absorb (h, f k)
        | Proof_component (c, k) ->
            Proof_component (c, cont k)
    end

    include Free_monad.Make2 (F)

    let absorb x = Free (Absorb (x, return ()))

    let rec absorb_value : type x e. (x, e) Type.t -> x -> (unit, e) t =
     fun t x ->
      match t with
      | Field ->
          absorb (Field x)
      | Pair (t1, t2) ->
          let x1, x2 = x in
          let%map () = absorb_value t1 x1 and () = absorb_value t2 x2 in
          ()
      | Polynomial _ ->
          absorb (Polynomial x)
      | Hlist ts0 ->
          let rec go : type ts.
              (ts, e) Type.Hlist.t -> ts HlistId.t -> (unit, e) t =
           fun ts xs ->
            match (ts, xs) with
            | [], [] ->
                return ()
            | t :: ts, x :: xs ->
                let%bind () = absorb_value t x in
                go ts xs
          in
          go ts0 x
      | Proof ->
          absorb (PCS_proof x)
      | Vector (t, _n) ->
          let rec go : type n a.
              (a, e) Type.t -> (a, n) Vector.t -> (unit, e) t =
           fun ty xs ->
            match xs with
            | [] ->
                return ()
            | x :: xs ->
                let%bind () = absorb_value ty x in
                go ty xs
          in
          go t x

    type field = Expr.t

    module Poly = struct
      type basic = Expr.t

      type 'poly expr =
        [`Scale of field * 'poly | `Add of 'poly * 'poly | `Constant of basic]

      type t =
        { expr: t expr
        ; commitment: Expr.t Lazy.t
        ; evaluations: Expr.t Expr.Table.t }

      let commitment t = Lazy.force t.commitment

      let add ~append_lines ~add_commitment t1 t2 =
        { expr= `Add (t1, t2)
        ; commitment=
            lazy
              (let c1 = Lazy.force t1.commitment in
               let c2 = Lazy.force t2.commitment in
               let name = gen_name () in
               append_lines [Statement.Assign (name, add_commitment c1 c2)] ;
               Var name)
        ; evaluations= Expr.Table.create () }

      let scale ~append_lines ~scale_commitment x t =
        { expr= `Scale (x, t)
        ; commitment=
            lazy
              (let name = gen_name () in
               append_lines
                 [ Statement.Assign
                     (name, scale_commitment x (Lazy.force t.commitment)) ] ;
               Var name)
        ; evaluations= Expr.Table.create () }

      (* This isn't necessarily the most efficient way to evaluate things, 
   but probably it is negligible compared to the cost of e.g., doing
   mulit-exps. *)
      let eval ~eval_poly ~add_field ~mul_field =
        let rec eval t x =
          Hashtbl.find_or_add t.evaluations x ~default:(fun () ->
              match t.expr with
              | `Constant p ->
                  eval_poly p x
              | `Add (t1, t2) ->
                  add_field (eval t1 x) (eval t2 x)
              | `Scale (s, t) ->
                  mul_field s (eval t x) )
        in
        eval
    end

    type env = < field: field ; poly: Poly.t ; proof: Expr.t >

    module Compiler (F : sig
      type (_, _) t
    end) =
    struct
      type t =
        { f:
            'a.    append_lines:(Program.t -> unit) -> ('a, env) F.t
            -> Program.t * 'a }
    end

    type compute = Compiler(Computation).t

    module Proof = struct
      type t =
        { field_elements: Expr.t list
        ; polynomials: Expr.t list
        ; pcs_proofs: Expr.t list }
      [@@deriving fields]

      let to_expr {field_elements; polynomials; pcs_proofs} =
        Expr.Struct
          [ ("field_elements", Array field_elements)
          ; ("polynomials", Array polynomials)
          ; ("pcs_proofs", Array pcs_proofs) ]

      let empty = {field_elements= []; polynomials= []; pcs_proofs= []}

      let rev_append t1 t2 =
        let a f = List.rev_append (Field.get f t1) (Field.get f t2) in
        Fields.map ~field_elements:a ~polynomials:a ~pcs_proofs:a

      let rev (t : t) =
        let r f = List.rev (Field.get f t) in
        Fields.map ~field_elements:r ~polynomials:r ~pcs_proofs:r

      let rec cons : type a. (a, env) Type.t * a -> t -> t =
       fun (ty, x) t ->
        let field = Fields.field_elements in
        let poly = Fields.polynomials in
        let proof = Fields.pcs_proofs in
        let fcons f x = Field.map f t ~f:(List.cons x) in
        match ty with
        | Vector (ty, _) ->
            List.fold (Vector.to_list x)
              ~f:(fun acc x -> cons (ty, x) acc)
              ~init:t
        | Field ->
            fcons field x
        | Polynomial _ ->
            fcons poly (Poly.commitment x)
        | Proof ->
            fcons proof x
        | Pair (ty1, ty2) ->
            let x1, x2 = x in
            cons (ty1, x1) t |> cons (ty2, x2)
        | Hlist ts ->
            let rec go : type xs.
                (xs, env) Type.Hlist.t -> xs HlistId.t -> t -> t =
             fun tys xs t ->
              match (tys, xs) with
              | [], [] ->
                  t
              | ty :: tys, x :: xs ->
                  go tys xs (cons (ty, x) t)
            in
            go ts x t

      let cons (c, x) t = cons (Proof_component.type_ c, x) t
    end

    let prover ~(compute : compute) ~(prove : Compiler(Proof_component).t)
        ~absorb ~squeeze ~initialize =
      let acc = ref [] in
      let append_lines lines = acc := List.rev_append lines !acc in
      let rec go proof t =
        match t with
        | Pure _ ->
            proof
        | Free (Compute c) ->
            let lines, k = compute.f c ~append_lines in
            append_lines lines ; go proof k
        | Free (Absorb (x, k)) ->
            append_lines (absorb x) ;
            go proof k
        | Free (Proof_component (c, k)) ->
            let lines, pi = prove.f c ~append_lines in
            append_lines lines ;
            go (Proof.cons (c, pi) proof) (k pi)
        | Free (Squeeze k) ->
            let lines, challenge = squeeze () in
            append_lines lines ;
            go proof (k challenge)
      in
      fun t ->
        acc := [initialize] ;
        let proof = go Proof.empty t in
        let proof = Proof.rev proof in
        List.rev (Statement.Return (Proof.to_expr proof) :: !acc)

    type 'e pending_absorptions = (unit, 'e) t list

    let rec fiat_shamir : type a e.
           (unit, e) t list
        -> (a, e) Ip.T(Basic_IP.Interaction)(Computation).t
        -> (e pending_absorptions * a, e) t =
     fun pending_absorptions t ->
      match t with
      | Pure x ->
          Pure (pending_absorptions, x)
      | Free (Compute c) ->
          Free
            (Compute (Computation.map c ~f:(fiat_shamir pending_absorptions)))
      | Free (Sample k) ->
          let%bind () = all_unit (List.rev pending_absorptions) in
          Free (Squeeze (fun x -> fiat_shamir [] (k x)))
      | Free (Interact (Send_and_receive (t_q, q, m, k))) ->
          let pending_absorptions =
            absorb_value t_q q :: pending_absorptions
          in
          Free
            (Proof_component
               ( m
               , fun r ->
                   fiat_shamir
                     ( absorb_value (Marlin_prover_message.type_ m) r
                     :: pending_absorptions )
                     (k r) ))
  end

  open Basic_IP

  let h = 5

  let d = 5

  let k = 5

  (*
Minimal zero knowledge query bound. The query algorithm of the AHP verifier V queries each prover
polynomial at exactly one location, regardless of the randomness used to generate the queries. In particular,
ŵ(X), ẑ A (X), ẑ B (X), ẑ C (X) are queried at exactly one location. So it suffices to set the parameter b := 1.
    *)
  (*
Eliminating σ 1 . We can sample the random polynomial s(X) conditioned on it summing to zero on H.
The prover can thus omit σ 1 , because it will always be zero, without affecting zero knowledge. *)
  (*. In particular, only the polynomials ŵ, ẑ A , ẑ B , ẑ C , s, h 1 , and g 1 need hiding
commitments. *)
  (* TODO: enforce the degree bounds on the g_i *)
  (*. When compiling our AHP, we need this feature only when committing to g 1 , g 2 , g 3 (the exact
degree bound matters for soundness) but for all other polynomials it suffices to rely on the maximum degree
bound and so for them we omit the shifted polynomials altogether. This increases the soundness error by a
negligible amount (which is fine), and lets us reduce argument size by 9 group elements. *)

  let w = 100

  let challenge t =
    let%bind x = sample in
    let%map r = send Field x t in
    (x, r)

  let vanishing_poly (_domain : 'field Sequence.t) (prefix_length : int) =
    assert (prefix_length = 1) ;
    fun x ->
      let open Arithmetic_expression in
      x - int 1

  (* Section 5.3.2 *)
  let z_hat domain input w_hat =
    let open Arithmetic_expression in
    let input_length = List.length input in
    let x_hat = interpolate domain input in
    fun t -> (w_hat * vanishing_poly domain input_length t) + x_hat t

  let all_but x0 = List.filter ~f:(fun x -> x <> x0)

  let domain_H = failwith "TODO"

  let domain_K = failwith "TODO"

  let receive t =
    let%map x = send (Hlist []) [] t in
    x

  let r (type f) domain (alpha : f) =
    let open Arithmetic_expression in
    let open Arithmetic_circuit in
    let open Let_syntax in
    let v_H = Domain.vanishing domain in
    let%map v_H_alpha = v_H !alpha in
    fun y ->
      let%map v_H_y = v_H y in
      (!v_H_alpha - !v_H_y) / (!alpha - y)

  let vanishing_polynomial d x =
    let open Arithmetic_expression in
    Arithmetic_computation.(circuit (Domain.vanishing d x) >>| constant)

  let query' HlistId.[h_3; g_3 ; row; col; value] beta_3 =
    let open AHP in
    let%map [ h_3_beta_3
            ; g_3_beta_3
            ; row_A_beta_3
            ; row_B_beta_3
            ; row_C_beta_3
            ; col_A_beta_3
            ; col_B_beta_3
            ; col_C_beta_3
            ; value_A_beta_3
            ; value_B_beta_3
            ; value_C_beta_3 ] =
      query
        [ h_3
        ; g_3
        ; row A
        ; row B
        ; row C
        ; col A
        ; col B
        ; col C
        ; value A
        ; value B
        ; value C ]
        beta_3
    in
    HlistId.[ h_3_beta_3
    ; g_3_beta_3
          ; abc row_A_beta_3 row_B_beta_3 row_C_beta_3
          ; abc col_A_beta_3 col_B_beta_3 col_C_beta_3
          ; abc value_A_beta_3 value_B_beta_3 value_C_beta_3
    ]


  let interact ~send:q ~receive =
    let n = Vector.length q in
    send (Type.Vector (Field, n)) q receive

  let ( ->! ) send receive = interact ~send ~receive

  let ( !<- ) = receive

  let assert_all = Arithmetic_computation.all_unit

  open Marlin_prover_message
  open Arithmetic_expression

  let todo = failwith "TODO"

  let protocol {Index.row; col; value} input =
    let input_size = List.length input in
    let v_K = vanishing_polynomial domain_K in
    let v_H = vanishing_polynomial domain_H in
    (* s can be ignored if we don't need zero knowledge *)
    let%bind s        = receive (random_mask Int.((2 * h) + zk_margin - 1)) in
    let%bind sigma_1  = receive (domain_sum domain_H (Arithmetic_circuit.eval !(`Poly s)))
    and w_hat         = receive (w_hat Int.(w + zk_margin) domain_H input_size)
    and z_A           = receive (mz_hat domain_H A)
    and z_B           = receive (mz_hat domain_H B) in
    let%bind alpha    = sample
    and eta_A         = sample
    and eta_B         = sample
    and eta_C         = sample in
    let eta           = abc eta_A eta_B eta_C in
    let%bind g_1, h_1 = interact ~send:[alpha; eta_A; eta_B; eta_C] ~receive:(GH (domain_H, todo)) in
    let%bind beta_1   = sample in
    let%bind sigma_2  =
      receive
        (let summand =
           let open Arithmetic_circuit in
           let%bind r_alpha = r domain_H (`Field alpha) in
           let%bind r_alpha_x = r_alpha !`X in
           eval
             ( r_alpha_x
             * sum [A; B; C] (fun m ->
                   !(`Field (eta m)) * !(`M_hat (m, beta_1)) ) )
         in
         domain_sum domain_H summand)
    in
    let%bind g_2, h_2 = interact ~send:[beta_1] ~receive:(GH (domain_H, todo)) in
    let%bind beta_2   = sample in
    let%bind sigma_3  = interact ~send:[beta_2] ~receive:(domain_sum domain_K todo) in
    let%bind g_3, h_3 = receive (GH (domain_K, todo)) in
    let%map beta_3    = sample in
    let open AHP in
    let%map [ h_3_beta_3; g_3_beta_3; row; col; value ] =
      query' [ h_3; g_3; row; col; value ] beta_3
    and [h_2_beta_2; g_2_beta_2] =
      query [h_2; g_2] beta_2
    and [ h_1_beta_1; g_1_beta_1; z_B_beta_1; z_A_beta_1; w_hat_beta1; s_beta_1 ] =
      query [h_1; g_1; z_B; z_A; w_hat; s] beta_1
    in
    let open Arithmetic_computation in
    let%bind r_alpha =
      let%map f = circuit (r domain_H alpha) in
      fun y -> circuit (f y)
    in
    let eta x = !(eta x) in
    let beta_1, beta_2, beta_3 = !beta_1, !beta_2, !beta_3 in
    let sigma_1, sigma_2, sigma_3 = !sigma_1, !sigma_2, !sigma_3 in
    let%bind a_beta_3, b_beta_3 =
      let%map a =
        let%map v_H_beta_2 = v_H beta_2 and v_H_beta_1 = v_H beta_1 in
        sum [A; B; C] (fun m ->
            eta m * v_H_beta_2 * v_H_beta_1 * value m
            * product
                (all_but m [A; B; C])
                (fun n -> (beta_2 - row n) * (beta_1 * col n)) )
      in
      let b =
        product [A; B; C] (fun m -> (beta_2 - row m) * (beta_1 - col m))
      in
      (a, b)
    in
    let%bind v_K_beta_3 = v_K beta_3
    and v_H_beta_1 = v_H beta_1
    and v_H_beta_2 = v_H beta_2
    and r_alpha_beta_1 = r_alpha beta_1
    and r_alpha_beta_2 = r_alpha beta_2 in
    let z_hat_beta_1 =
      z_hat Sequence.empty (* TODO *) input w_hat_beta1 beta_1
    in
    let z_C_beta_1 = z_A_beta_1 * z_B_beta_1 in
    assert_all
      [ h_3_beta_3 * v_K_beta_3
        = a_beta_3
          - (b_beta_3 * ((beta_3 * g_3_beta_3) + (sigma_3 / int k)))
      ; r_alpha_beta_2 * sigma_3
        = (h_2_beta_2 * v_H_beta_2) + (beta_2 * g_2_beta_2)
          + (sigma_2 / int h)
      ; s_beta_1
        + r_alpha_beta_1
          * ( (eta A * z_A_beta_1)
            + (eta B * z_B_beta_1)
            + (eta C * z_C_beta_1) )
        - (sigma_2 * z_hat_beta_1)
        = (h_1_beta_1 * v_H_beta_1) + (beta_1 * g_1_beta_1)
          + (sigma_1 / int h) ]

  module type IP_intf = sig
    type field
    type poly
    type e = < field: field; poly: poly >
    val receive : ('a, e) Marlin_prover_message.t -> 'a
    val sample : unit -> field
    val send : (field, 'n) Vector.t -> unit
  end

  type ('f, 'p) ip = (module IP_intf with type field = 'f and type poly = 'p)

  let protocol (type f p) ((module IP) : (f, p) ip) {Index.row; col; value} input =
    let open IP in
    let input_size = List.length input in
    let v_K = vanishing_polynomial domain_K in
    let v_H = vanishing_polynomial domain_H in
    (* s can be ignored if we don't need zero knowledge *)
    let s       = receive (random_mask Int.((2 * h) + zk_margin - 1)) in
    let sigma_1 = receive (domain_sum domain_H (Arithmetic_circuit.eval !(`Poly s))) in
    let w_hat   = receive (w_hat Int.(w + zk_margin) domain_H input_size) in
    let z_A     = receive (mz_hat domain_H A) in
    let z_B     = receive (mz_hat domain_H B) in
    let alpha   = sample () in
    let eta_A   = sample () in
    let eta_B   = sample () in
    let eta_C   = sample () in
    let eta     = abc eta_A eta_B eta_C in
    send [alpha; eta_A; eta_B; eta_C] ;
    let g_1, h_1 = receive (GH (domain_H, todo)) in
    let beta_1   = sample () in
    let sigma_2  =
      receive
        (let summand =
           let open Arithmetic_circuit in
           let%bind r_alpha = r domain_H (`Field alpha) in
           let%bind r_alpha_x = r_alpha !`X in
           eval
             ( r_alpha_x
             * sum [A; B; C] (fun m ->
                   !(`Field (eta m)) * !(`M_hat (m, beta_1)) ) )
         in
         domain_sum domain_H summand)
    in
    send [beta_1];
    let g_2, h_2 = receive (GH (domain_H, todo)) in
    let beta_2   = sample () in
    send [ beta_2 ];
    let sigma_3  = receive (domain_sum domain_K todo) in
    let g_3, h_3 = receive (GH (domain_K, todo)) in
    let beta_3   = sample () in
    let open AHP in
    let%map [ h_3_beta_3; g_3_beta_3; row; col; value ] =
      query' [ h_3; g_3; row; col; value ] beta_3
    and [h_2_beta_2; g_2_beta_2] =
      query [h_2; g_2] beta_2
    and [ h_1_beta_1; g_1_beta_1; z_B_beta_1; z_A_beta_1; w_hat_beta1; s_beta_1 ] =
      query [h_1; g_1; z_B; z_A; w_hat; s] beta_1
    in
    let open Arithmetic_computation in
    let%bind r_alpha =
      let%map f = circuit (r domain_H alpha) in
      fun y -> circuit (f y)
    in
    let eta x = !(eta x) in
    let beta_1, beta_2, beta_3 = !beta_1, !beta_2, !beta_3 in
    let sigma_1, sigma_2, sigma_3 = !sigma_1, !sigma_2, !sigma_3 in
    let%bind a_beta_3, b_beta_3 =
      let%map a =
        let%map v_H_beta_2 = v_H beta_2 and v_H_beta_1 = v_H beta_1 in
        sum [A; B; C] (fun m ->
            eta m * v_H_beta_2 * v_H_beta_1 * value m
            * product
                (all_but m [A; B; C])
                (fun n -> (beta_2 - row n) * (beta_1 * col n)) )
      in
      let b =
        product [A; B; C] (fun m -> (beta_2 - row m) * (beta_1 - col m))
      in
      (a, b)
    in
    let%bind v_K_beta_3 = v_K beta_3
    and v_H_beta_1 = v_H beta_1
    and v_H_beta_2 = v_H beta_2
    and r_alpha_beta_1 = r_alpha beta_1
    and r_alpha_beta_2 = r_alpha beta_2 in
    let z_hat_beta_1 =
      z_hat Sequence.empty (* TODO *) input w_hat_beta1 beta_1
    in
    let z_C_beta_1 = z_A_beta_1 * z_B_beta_1 in
    assert_all
      [ h_3_beta_3 * v_K_beta_3
        = a_beta_3
          - (b_beta_3 * ((beta_3 * g_3_beta_3) + (sigma_3 / int k)))
      ; r_alpha_beta_2 * sigma_3
        = (h_2_beta_2 * v_H_beta_2) + (beta_2 * g_2_beta_2)
          + (sigma_2 / int h)
      ; s_beta_1
        + r_alpha_beta_1
          * ( (eta A * z_A_beta_1)
            + (eta B * z_B_beta_1)
            + (eta C * z_C_beta_1) )
        - (sigma_2 * z_hat_beta_1)
        = (h_1_beta_1 * v_H_beta_1) + (beta_1 * g_1_beta_1)
          + (sigma_1 / int h) ] 
  (*
    *)

  let ahp_to_pcs_ip = Basic_IP.map ~f:PCS_IP.ahp_compiler

  module S = SNARK (PCS_IP.Computation)

  let p = protocol (failwith "TODO") []

  let p = ahp_to_pcs_ip p

  (* Everything after this essentially only concerns the verifier *)
  let p_for_prover =
    let open Basic_IP in
    let module IP1 = Ip.T (Basic_IP.Interaction) (PCS_IP.Computation) in
    let module Expand_outer_computation =
      Ip.Computation.Bind (Interaction) (Computation) (PCS_IP.Computation)
        (struct
          let f (Computation.Nop k) = IP1.Pure k
        end)
    in
    let module Expand_inner_interaction =
      Ip.Interaction.Map (PCS_IP.Computation) (PCS_IP.Interaction)
        (Basic_IP.Interaction)
        (struct
          let f (PCS_IP.Interaction.Receive (pcs, k)) =
            Basic_IP.Interaction.Send_and_receive (Hlist [], [], PCS pcs, k)
        end)
    in
    IP1.bind (Expand_outer_computation.f p) ~f:Expand_inner_interaction.f

  let p = S.fiat_shamir [] p_for_prover

  let _ = p

  let _ = p

  let ocaml_prover =
    let assert_equal x y = failwith "" in
    let op o = failwith "" in
    let int _ = failwith "" in
    let constant _ = failwith "" in
    let scale_commitment _ _ = failwith "" in
    let add_commitment _ _ = failwith "" in
    let add_field _ _ = failwith "" in
    let mul_field _ _ = failwith "" in
    let open_commitment _ _ _ = failwith "" in
    let compute : S.compute =
      { f=
          (fun ~append_lines c ->
            match c with
            | Arithmetic c ->
                Arithmetic_computation.F.to_program c ~assert_equal ~constant
                  ~int ~op
            | Scale_poly (x, p, k) ->
                let xp = S.Poly.scale ~append_lines ~scale_commitment x p in
                ([], k xp)
            | Add_poly (p1, p2, k) ->
                let p = S.Poly.add ~append_lines ~add_commitment p1 p2 in
                ([], k p)
            | Check_proof (_p, _x, _y, _pi, k) ->
                ([], k) ) }
    in
    let prove : S.Compiler(S.Proof_component).t =
      let f : type a.
             append_lines:(Program.t -> unit)
          -> (a, S.env) S.Proof_component.t
          -> Program.t * a =
       fun ~append_lines c ->
        match c with
        | PCS (Proof (p, x, y)) ->
            open_commitment p x y
        | PCS (Evals (ps, pt)) ->
            let eval_poly (p : S.Poly.basic) x =
              let r = gen_name () in
              append_lines
                [Statement.Assign 
                   (r, Method_call
                      (p, "evaluate", [x]))] ;
              Expr.Var r
            in
            ( []
            , Vector.map ps ~f:(fun p ->
                  S.Poly.eval ~eval_poly ~add_field ~mul_field p pt ) )
      in
      {f}
    in
    S.prover ~compute ~prove

  (*   let p = S.fiat_shamir [(* Input goes here *)] p *)
end

type domain = I | L | H | K

module Oracle = struct
  type t = F_input | F_A
end*)