(* Distributed under the terms of the MIT license.   *)

From Coq Require Import Bool String List Program BinPos Compare_dec Omega.
From Template Require Import Template utils monad_utils Ast univ Induction LiftSubst UnivSubst Typing Checker Retyping MetaTheory WcbvEval.
From Template Require AstUtils.
Require Import String.
Local Open Scope string_scope.
Set Asymmetric Patterns.
Import MonadNotation.

Definition is_prop_sort s :=
  match Universe.level s with
  | Some l => Level.is_prop l
  | None => false
  end.

Section Erase.
  Context `{F : Fuel}.
  Context (Σ : global_context).

  Definition dummy := tVar "dummy".
  Definition assertfalse := tVar "assertfalse".
  Definition is_dummy c := match c with
                           | tVar s => eq_string "dummy" s
                           | _ => false
                           end.

  Definition on_snd_map {A B C} (f : B -> C) (p : A * B) :=
    (fst p, f (snd p)).

  Section EraseMfix.
    Context (erase : forall (Γ : context) (t : term), typing_result term).

    Definition erase_mfix Γ (defs : mfixpoint term) :=
      let Γ' := (fix_decls defs ++ Γ)%list in
      monad_map (fun d => dtype' <- erase Γ d.(dtype);;
                          dbody' <- erase Γ' d.(dbody);;
                          ret ({| dname := d.(dname); rarg := d.(rarg);
                                  dtype := dtype'; dbody := dbody' |})) defs.
  End EraseMfix.

  Fixpoint erase (Γ : context) (t : term) : typing_result term :=
    s <- sort_of Σ Γ t;;
    if is_prop_sort s then ret dummy
    else match t with
    | tRel _ | tVar _ | tMeta _ | tEvar _ _ | tSort _ | tConst _ _ | tInd _ _ | tConstruct _ _ _ => ret t
    | tCast t k ty => erase Γ t
                      (* ty' <- erase Γ ty ;; *)
                      (* ret (tCast t' k ty') *)
    | tProd na b t => b' <- erase Γ b;;
                      t' <- erase (vass na b :: Γ) t;;
                      ret (tProd na b' t')
    | tLambda na b t =>
      b' <- erase Γ b;;
      t' <- erase (vass na b :: Γ) t;;
      ret (tLambda na b' t')
    | tLetIn na b t0 t1 =>
      b' <- erase Γ b;;
      t0' <- erase Γ t0;;
      t1' <- erase (vdef na b t0 :: Γ) t1;;
      ret (tLetIn na b' t0' t1')
    | tApp f l =>
      f' <- erase Γ f;;
      l' <- monad_map (erase Γ) l;;
      ret (tApp f' l') (* if is_dummy f' then ret dummy else *)
    | tCase ip p c brs =>
      c' <- erase Γ c;;
      if is_dummy c' then
        match brs with
        | (_, x) :: _ => erase Γ x (* Singleton elimination *)
        | nil => ret (tCase ip p c' brs) (* Falsity elimination *)
        end
      else
        brs' <- monad_map (T:=typing_result) (fun x => x' <- erase Γ (snd x);; ret (fst x, x')) brs;;
        ret (tCase ip p c' brs')
    | tProj p c =>
      c' <- erase Γ c;;
      ret (tProj p c')
    | tFix mfix n =>
      mfix' <- erase_mfix erase Γ mfix;;
      ret (tFix mfix' n)
    | tCoFix mfix n =>
      mfix' <- erase_mfix erase Γ mfix;;
      ret (tCoFix mfix' n)
     end.

End Erase.

(** * Erasure correctness
    
    The statement below expresses that any well-typed term's
    extraction has the same operational semantics as its source, under
    a few conditions:

    - The terms has to be locally closed, otherwise evaluation could get 
      stuck on free variables. Typing under an empty context ensures that.
    - The global environment is axiom-free, for the same reason.
    - The object is of inductive type, or more generally a function resulting 
      ultimately in an inductive value when applied.

   We use an observational equality relation to relate the two values, 
   which is indifferent to the erased parts.
 *)

Fixpoint inductive_arity (t : term) :=
  match t with
  | tApp f _ | f =>
    match f with
    | tInd ind u => Some ind
    | _ => None
    end
  end.

(* Inductive inductive_arity : term -> Prop := *)
(* | inductive_arity_concl ind u args : inductive_arity (mkApps (tInd ind u) args) *)
(* | inductive_arity_arrow na b t : inductive_arity t -> inductive_arity (tProd na b t). *)

Definition option_is_none {A} (o : option A) :=
  match o with
  | Some _ => false
  | None => true
  end.

Definition is_axiom_decl g :=
  match g with
  | ConstantDecl kn cb => option_is_none cb.(cst_body)
  | InductiveDecl kn ind => false
  end.

Definition axiom_free Σ :=
  List.forallb (fun g => negb (is_axiom_decl g)) Σ.

Definition computational_ind Σ ind :=
  let 'mkInd mind n := ind in
  let mib := lookup_env Σ mind in
  match mib with
  | Some (InductiveDecl kn decl) =>
    match List.nth_error decl.(ind_bodies) n with
    | Some body =>
      match destArity [] body.(ind_type) with
      | Some arity => negb (is_prop_sort (snd arity))
      | None => false
      end
    | None => false
    end
  | _ => false
  end.

Require Import Bool.
Coercion is_true : bool >-> Sortclass.

Definition computational_type Σ T :=
  exists ind, inductive_arity T = Some ind /\ computational_ind Σ ind.

(** The precondition on the extraction theorem. *)

Record extraction_pre (Σ : global_context) t T :=
  { extr_typed : Σ ;;; [] |- t : T;
    extr_env_axiom_free : axiom_free (fst Σ);
    extr_computational_type : computational_type Σ T }.

(** The observational equivalence relation between source and erased values. *)

Definition destApp t :=
  match t with
  | tApp f args => (f, args)
  | f => (f, [])
  end.

Inductive Question : Set  := 
| Cnstr : Ast.inductive -> nat -> Question 
| Abs : Question.

Definition observe (q : Question) (v : term) : bool :=
  match q with
  | Cnstr i k =>
    match v with
    | tConstruct i' k' u =>
      eq_ind i i' && eq_nat k k'
    | _ => false
    end
  | Abs =>
    match v with
    | tLambda _ _ _ => true
    | tFix _ _ => true
    | _ => false
    end
  end.
             

(*
Fixpoint obs_eq (Σ : global_context) (v v' : term) (T : term) (s : universe) : Prop :=
  if is_prop_sort s then is_dummy v'
  else
    match T with
    | tInd ind u =>
      (* Canonical inductive value *)
      let '(hd, args) := destApp v in
      let '(hd', args') := destApp v' in
      eq_term Σ hd hd' /\ obs_eq 
      
 | obs_eq_prf v T s : Σ ;;; [] |- v : T ->
  Σ ;;; [] |- T : tSort s ->
  is_prop_sort s ->
  obs_eq Σ v dummy

| obs_eq_cstr ind k u args args' T : Σ ;;; [] |- mkApps (tConstruct ind k u) args : T ->
  computational_type Σ T ->
  Forall2 (obs_eq Σ) args args' ->
  obs_eq Σ (mkApps (tConstruct ind k u) args) (mkApps (tConstruct ind k u) args')

| obs_eq_arrow na f f' T T' :
    Σ ;;; [] |- f : tProd na T T' ->
    (forall arg arg', obs_eq Σ arg arg' -> 
    
    obs_eq Σ f f'.                                     
*)                      

Record extraction_post (Σ : global_context) (t' v : term) :=
  { extr_value : term;
    extr_eval : eval Σ [] t' extr_value;
    (* extr_equiv : obs_eq Σ v extr_value *) }.
    


(** The extraction correctness theorem we conjecture. *)

Definition erasure_correctness :=
  forall Σ t T, extraction_pre Σ t T ->
    forall (f : Fuel) (t' : term),
      erase Σ [] t = Checked t' ->
      forall v, eval Σ [] t v ->
      exists v', eval Σ [] t' v'.
      
Conjecture erasure_correct : erasure_correctness.

Quote Recursively Definition zero_syntax := 0.

Definition erase_rec (t : global_declarations * term) : typing_result term :=
  let '(Σ, t) := t in
  erase (reconstruct_global_context Σ) [] t.

(* A few tests *)

Quote Recursively Definition true_syntax := I.
Eval vm_compute in erase_rec true_syntax.

Quote Recursively Definition exist_syntax := (exist _ 0 I : { x : nat | True }).
Eval vm_compute in erase_rec exist_syntax.

Quote Recursively Definition exist'_syntax := ((exist _ (S 0) (le_n (S 0))) : { x : nat | 0 < x }).
Eval vm_compute in erase_rec exist'_syntax.

Quote Recursively Definition fun_syntax := (fun (x : nat) (bla : x < 0) => x).
Eval vm_compute in erase_rec fun_syntax. (* Not erasing bindings *)

Quote Recursively Definition fun'_syntax := (fun (x : nat) (bla : x < 0) => bla).
Eval vm_compute in erase_rec fun'_syntax. 
