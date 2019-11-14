module Functor = struct
  module type S = sig
    type 'a t

    val map : 'a t -> f:('a -> 'b) -> 'b t
  end

  module type S2 = sig
    type ('a, 'e) t

    val map : ('a, 'e) t -> f:('a -> 'b) -> ('b, 'e) t
  end

  module type S3 = sig
    type ('a, 'x, 'y) t

    val map : ('a, 'x, 'y) t -> f:('a -> 'b) -> ('b, 'x, 'y) t
  end
end

module Make (F : Functor.S) : sig
  type 'a t = Pure of 'a | Free of 'a t F.t

  include Monad_let.S with type 'a t := 'a t
end = struct
  module T = struct
    type 'a t = Pure of 'a | Free of 'a t F.t

    let rec map t ~f =
      match t with
      | Pure x ->
          Pure (f x)
      | Free tf ->
          Free (F.map tf ~f:(map ~f))

    let map = `Custom map

    let return x = Pure x

    let rec bind t ~f =
      match t with Pure x -> f x | Free tf -> Free (F.map tf ~f:(bind ~f))
  end

  include T
  include Monad_let.Make (T)
end

module Make2 (F : Functor.S2) : sig
  type ('a, 'x) t = Pure of 'a | Free of (('a, 'x) t, 'x) F.t

  include Monad_let.S2 with type ('a, 'x) t := ('a, 'x) t
end = struct
  module T = struct
    type ('a, 'x) t = Pure of 'a | Free of (('a, 'x) t, 'x) F.t

    let rec map t ~f =
      match t with
      | Pure x ->
          Pure (f x)
      | Free tf ->
          Free (F.map tf ~f:(map ~f))

    let map = `Custom map

    let return x = Pure x

    let rec bind t ~f =
      match t with Pure x -> f x | Free tf -> Free (F.map tf ~f:(bind ~f))
  end

  include T
  include Monad_let.Make2 (T)
end

module Make3 (F : Functor.S3) : sig
  type ('a, 'x, 'y) t = Pure of 'a | Free of (('a, 'x, 'y) t, 'x, 'y) F.t

  include Monad_let.S3 with type ('a, 'x, 'y) t := ('a, 'x, 'y) t
end = struct
  module T = struct
    type ('a, 'x, 'y) t = Pure of 'a | Free of (('a, 'x, 'y) t, 'x, 'y) F.t

    let rec map t ~f =
      match t with
      | Pure x ->
          Pure (f x)
      | Free tf ->
          Free (F.map tf ~f:(map ~f))

    let map = `Custom map

    let return x = Pure x

    let rec bind t ~f =
      match t with Pure x -> f x | Free tf -> Free (F.map tf ~f:(bind ~f))
  end

  include T
  include Monad_let.Make3 (T)
end

module Bind2 
    (F1 : Functor.S2)
    (F2 : Functor.S2)
    (Eta : sig
       val f : ('a, 'e) F1.t -> ('a, 'e) Make2(F2).t
     end)
  : sig
    val f : ('a, 'e) Make2(F1).t -> ('a, 'e) Make2(F2).t
  end 
= struct
  module M2 = Make2(F2)

  let rec f : type a e. (a, e) Make2(F1).t -> (a, e) Make2(F2).t =
    fun t ->
      match t with
      | Pure x -> Pure x
      | Free xf ->
        let ef = Eta.f xf in
        M2.bind ef ~f
end


