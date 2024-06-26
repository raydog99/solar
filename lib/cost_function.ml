open Torch

module UOT_RCL = struct
  module CostFunction = struct
    let cosine_similarity z1 z2 =
      Tensor.(dot z1 z2 / (norm z1 * norm z2))

    let calculate_consistency f_v f_t x_v x_t x_v_star x_t_star =
      let d_v = cosine_similarity (f_v x_v) (f_v x_v_star) in
      let d_t = cosine_similarity (f_t x_t) (f_t x_t_star) in
      Tensor.(d_v / d_t)

    let calculate_cost f_v f_t x_v x_t neighbors_v neighbors_t y_neighbors =
      let c_v = calculate_consistency f_v f_t x_v x_t (fst neighbors_v.(0)) (fst neighbors_t.(0)) in
      let c_t = calculate_consistency f_t f_v x_t x_v (fst neighbors_t.(0)) (fst neighbors_v.(0)) in
      let sum_v = Tensor.sum (Tensor.stack (Array.to_list (Array.map (fun (x, y) -> Tensor.(c_v * cosine_similarity (f_v x_v) (f_v x) * of_float y)) neighbors_v))) in
      let sum_t = Tensor.sum (Tensor.stack (Array.to_list (Array.map (fun (x, y) -> Tensor.(c_t * cosine_similarity (f_t x_t) (f_t x) * of_float y)) neighbors_t))) in
      Tensor.(neg (log ((sum_v + sum_t) / (of_float 2.0))))

    let update_targets y mu z_v z_t momentum =
      let j = Tensor.argmax (Tensor.add (Tensor.matmul mu (Tensor.transpose z_v (-1) (-2))) (Tensor.matmul mu (Tensor.transpose z_t (-1) (-2)))) [1] in
      Tensor.(y * momentum + one_hot_scalar j (shape y).(0) * (Scalar.f 1. - momentum))
  end

  module PartialOT = struct
    let solve cost_matrix alpha_s beta_s =
      let n, k = Tensor.shape cost_matrix in
      let u = Tensor.ones [n] in
      let v = Tensor.ones [k] in
      let rec iterate u v i =
        if i = 0 then (u, v)
        else
          let u' = Tensor.(alpha_s / (matmul (exp (neg cost_matrix)) v)) in
          let v' = Tensor.(beta_s / (matmul (transpose (exp (neg cost_matrix)) (-1) (-2)) u')) in
          iterate u' v' (i - 1)
      in
      let u, v = iterate u v 100 in
      Tensor.(exp (neg cost_matrix) * u.unsqueeze 1 * v.unsqueeze 0)

    let correct_labels cost_matrix s r =
      let n, k = Tensor.shape cost_matrix in
      let alpha_s = Tensor.cat [Tensor.full [n] (1. /. (float_of_int n)); Tensor.tensor [s]] 0 in
      let beta_s = Tensor.cat [r; Tensor.tensor [s]] 0 in
      let extended_cost = Tensor.cat [
        Tensor.cat [cost_matrix; Tensor.zeros [n; 1]] 1;
        Tensor.cat [Tensor.zeros [1; k]; Tensor.zeros [1; 1]] 1
      ] 0 in
      let transport_plan = solve extended_cost alpha_s beta_s in
      Tensor.narrow transport_plan 0 0 n |> Tensor.narrow 1 0 k
  end

  let train f_v f_t mu x_v x_t y neighbors_v neighbors_t s r momentum =
    let cost = CostFunction.calculate_cost f_v f_t x_v x_t neighbors_v neighbors_t in
    let corrected_labels = PartialOT.correct_labels cost s r in
    let updated_y = CostFunction.update_targets y mu (f_v x_v) (f_t x_t) momentum in
    let loss = Tensor.(mean (neg (corrected_labels * log (f_v x_v + f_t x_t)))) in
    loss, updated_y
end