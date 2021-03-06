{-# OPTIONS -Wall #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}







-- | This module defines how elaboration of programs is performed, as well as
-- how typechecking of programs is performed. Because Plutus has an
-- interleaved elaboration process, where term declaration and typechecking
-- refer to one another, we can't separate the type checking component out
-- into a separate module.

module Elaboration.Elaboration where

import Utils.ABT
import Utils.Elaborator
import Utils.Names
import Utils.Pretty
import Utils.ProofDeveloper hiding (Decomposer,ElabError)
--import Utils.Unifier
import Utils.Vars
import Plutus.Term
import PlutusTypes.ConSig
import PlutusTypes.Type
import Plutus.Program
import qualified PlutusCore.Term as Core
--import qualified PlutusCore.Program as Core
import Elaboration.Contexts
import Elaboration.Elaborator
import Elaboration.ElabState
import Elaboration.Judgments
--import Elaboration.Unification ()

import Control.Monad.Except
import Control.Monad.State
import Data.Functor.Identity
import Data.List
import Data.Maybe (isJust)













  













instance Decomposable ElabState ElabError Judgment where
  decompose (ElabProgram dctx prog) = elabProgram dctx prog
  decompose (ElabTermDecl dctx tmdecl) = elabTermDecl dctx tmdecl
  decompose (ElabAlt dctx n consig) = elabAlt dctx n consig
  decompose (ElabTypeDecl dctx tydecl) = elabTypeDecl dctx tydecl
  -- decompose (TyVarExists hctx x) = tyVarExists hctx x
  -- decompose (TyConExists dctx n) = tyconExists dctx n
  -- decompose (TypeInContext hctx x) = typeInContext hctx x
  decompose (IsType dctx hctx a) = isType dctx hctx a
  decompose (IsPolymorphicType dctx hctx a) = isPolymorphicType dctx hctx a
  decompose (Synth dctx hctx m) = synthify dctx hctx m
  decompose (SynthClause dctx hctx as cl) = synthifyClause dctx hctx as cl
  decompose (Check dctx hctx a m) = checkify dctx hctx a m
  decompose (CheckPattern dctx a p) = checkifyPattern dctx a p
  decompose (CheckConSig dctx consig) = checkifyConSig dctx consig
  decompose (Unify a b) = unify a b
  decompose (UnifyAll as) = unifyAll as
  decompose (Subtype a b) = subtype a b










-------------------------------------------------
-------------------------------------------------
----------------                 ----------------
----------------   ELABORATION   ----------------
----------------                 ----------------
-------------------------------------------------
-------------------------------------------------


{-


-- | We can add a new defined value declaration given a name, core term,
-- and type.

addDeclaration
  :: Sourced String -> Core.Term -> PolymorphicType -> Elaborator ()
addDeclaration n def ty = addElab definitions [(n,(def,ty))]


-- | We can add a new type constructor by giving a name and a type constructor
-- signature.

addTypeConstructor :: String -> TyConSig -> Elaborator ()
addTypeConstructor n sig = addElab (signature.typeConstructors) [(n,sig)]


-- | We can add a new data constructor by given a type constructor name, a
-- name for the data constructor, and a list of arg types from which to build
-- a constructor signature.

addConstructor :: String -> ConSig -> Elaborator ()
addConstructor n consig = addElab (signature.dataConstructors) [(n,consig)]


-}


-- | Elaborating a term declaration takes one of two forms, depending on what
-- kind of declaration is being elaborated. A definition of the form
-- @f : A { M }@ is elaborated directly, while a definition of the form
-- @f : A { f x y z = M }@ is first transformed into the former
-- type of declaration, and then elaborated.
--
-- This corresponds to the elaboration judgment
-- @Σ;Δ ⊢ term n type A def M ⊣ Δ'@ which is defined as
--
-- @
--      Σ ⊢ A type   Σ ; Δ ; n : A ⊢ A ∋ M ▹ M'
--    -------------------------------------------
--    Σ ; Δ ⊢ term n type A def M ⊣ Δ, n : A ↦ M'
-- @

elabTermDecl :: DeclContext
             -> TermDeclaration
             -> Decomposer DeclContext
elabTermDecl dctx (TermDeclaration n ty@(PolymorphicType sc) m) =
  do when (isJust (lookup n (definitions dctx)))
       $ failure (ElabError ("Term already defined: " ++ showSourced n))
     goal (IsPolymorphicType dctx (HypContext [] []) ty)
     let (xs,_,a) = openScope [] sc
         def = freeToDefined (In . Decname . User) m
         definitions' =
           (n,(error "This should never be used in elaboration.",ty))
             : definitions dctx
         dctxTemp = dctx { definitions = definitions' }
         hctx = HypContext
                { tyVarContext =
                    tyVarContextFromFreeVars xs ++ tyVarContext hctx
                , context = []
                }
     (def',dctx') <- goal (Check dctxTemp hctx a def)
     let newDefs = 
           (n,(def',ty))
             : filter (\(n',_) -> n' /= n)
                      (definitions dctx')
     return (dctx' { definitions = newDefs })
elabTermDecl dctx (WhereDeclaration n ty preclauses) =
  case preclauses of
    [] ->
      failure
        (ElabError "Cannot create an empty let-where definition.")
    [(ps,xs,b)] | all isVarPat ps
      -> elabTermDecl
           dctx
           (TermDeclaration
              n
              ty
              (helperFold lamH xs b))
    (ps0,_,_):_
      -> let clauses = [ clauseH xs ps b
                       | (ps,xs,b) <- preclauses
                       ]
             xs0 = [ "x" ++ show i | i <- [0..length ps0-1] ]
         in elabTermDecl
              dctx
              (TermDeclaration
                 n
                 ty
                 (helperFold
                    lamH
                    xs0
                    (caseH (map (Var . Free . FreeVar) xs0) clauses)))
  where
    isVarPat :: Pattern -> Bool
    isVarPat (Var _) = True
    isVarPat _ = False





-- | Elaboration of a constructor in this variant is a relatively simple
-- process. This corresponds to the elaboration judgment
-- @Σ ⊢ c A* alt n α* ⊣ Σ'@ which is defined as
--
-- @
--                    Σ ; α* type ⊢ Ai type
--    -------------------------------------------------------
--    Σ ⊢ c A0 ... Ak alt n α* ⊣ Σ, c : [α*](A0,...,Ak)(n α*)
-- @
--
-- Because constructor signatures are a bundle in this implementation, we
-- define this in terms of the judgment @Γ ⊢ [α*](A0,...,An)B consig@ which
-- is implemented in the @checkifyConsig@ function.

elabAlt :: DeclContext
        -> String
        -> ConSig
        -> Decomposer DeclContext
elabAlt dctx n consig =
  do when (isJust (lookup n (dataConstructors (signature dctx))))
       $ failure (ElabError ("Constructor already declared: " ++ n))
     goal (CheckConSig dctx consig)
     let cons' = (n,consig) : dataConstructors (signature dctx)
         sig' = (signature dctx) { dataConstructors = cons' }
         dctx' = dctx { signature = sig' }
     return dctx'





-- | Elaboration of a type constructor is similar to elaborating a data
-- constructor, except it includes elaborations for the constructors as well.
--
-- @
--    Σ, n : *^k ⊢ C0 alt n α* ⊣ Σ'0
--    Σ'0 ⊢ C1 alt n α* ⊣ Σ'1
--    ...
--    Σ'j-1 ⊢ Cj alt n α* ⊣ Σ'j
--    --------------------------------------
--    Σ ⊢ type n α* alts C0 | ... | Cj ⊣ Σ'j
-- @
--
-- where here @Σ # c@ means that @c@ is not a type constructor in @Σ@.

elabTypeDecl :: DeclContext
             -> TypeDeclaration
             -> Decomposer DeclContext
elabTypeDecl dctx (TypeDeclaration tycon params alts) =
  do when (isJust (lookup tycon (typeConstructors (signature dctx))))
       $ failure (ElabError ("Type constructor already declared: " ++ tycon))
     let tycons' =
           (tycon, TyConSig (length params))
             : typeConstructors (signature dctx)
         sig' = (signature dctx) { typeConstructors = tycons' }
         dctx' = dctx { signature = sig' }
     chainM dctx' alts $ \dctx'' (n,consig) ->
       goal (ElabAlt dctx'' n consig)





-- | Elaborating a whole program involves chaining together the elaborations of
-- each kind of declaration. We can define it inductively as follows:
--
-- @
--    -----------------
--    Σ ; Δ ⊢ ε ⊣ Σ ; Δ
--
--    Σ ⊢ type n α* alts C0 | ... Ck ⊣ Σ'   Σ' ; Δ ⊢ P ⊣ Σ'' ; Δ''
--    ------------------------------------------------------------
--        Σ ; Δ ⊢ data n α* = { C0 | ... | Ck} ; P ⊣ Σ'' ; Δ''
--
--    Σ ; Δ ⊢ term n type A def M ⊣ Δ'   Σ ; Δ' ⊢ P ⊣ Σ'' ; Δ''
--    ---------------------------------------------------------
--               Σ ; Δ ⊢ x : A { M } ; P ⊣ Σ'' ; Δ''
-- @

elabProgram :: DeclContext -> Program -> Decomposer DeclContext
elabProgram dctx0 (Program stmts0) =
  elabStatements dctx0 stmts0
  where
    elabStatements :: DeclContext -> [Statement] -> Decomposer DeclContext
    elabStatements dctx [] =
      return dctx
    elabStatements dctx (stmt:stmts) =
      do dctx' <- elabStatement dctx stmt
         elabStatements dctx' stmts
    
    elabStatement :: DeclContext -> Statement -> Decomposer DeclContext
    elabStatement dctx (TyDecl tyd) = goal (ElabTypeDecl dctx tyd)
    elabStatement dctx (TmDecl tmd) = goal (ElabTermDecl dctx tmd)










---------------------------------------------------
---------------------------------------------------
----------------                   ----------------
----------------   TYPE CHECKING   ----------------
----------------                   ----------------
---------------------------------------------------
---------------------------------------------------





-- | We can check that a type constructor exists by looking in the signature.
-- This corresponds to the judgment @Σ ∋ n : *^k@

tyconExists :: DeclContext -> String -> Decomposer TyConSig
tyconExists dctx n =
  case lookup n (typeConstructors (signature dctx)) of
    Nothing -> failure (ElabError ("Unknown type constructor: " ++ n))
    Just sig -> return sig



-- | We can get the consig of a constructor by looking in the signature.
-- This corresponds to the judgment @Σ ∋ n : S@

typeInSignature :: DeclContext -> String -> Decomposer ConSig
typeInSignature dctx n =
  case lookup n (dataConstructors (signature dctx)) of
    Nothing -> failure (ElabError ("Unknown constructor: " ++ n))
    Just t  -> return t



-- | We can get the signature of a built-in by looking in the signature.
-- This corresponds to the judgment @Σ ∋ !n : S@

builtinInSignature :: String -> Decomposer ConSig
builtinInSignature n =
  do case lookup n builtinSigs of
       Nothing -> failure (ElabError ("Unknown builtin: " ++ n))
       Just t  -> return t
  where
    builtinSigs :: [(String,ConSig)]
    builtinSigs =
      [ ("addInt", conSigH [] [intH,intH] intH)
      , ("subtractInt", conSigH [] [intH,intH] intH)
      , ("multiplyInt", conSigH [] [intH,intH] intH)
      , ("divideInt", conSigH [] [intH,intH] intH)
      , ("remainderInt", conSigH [] [intH,intH] intH)
      , ("lessThanInt", conSigH [] [intH,intH] (tyConH "Bool" []))
      , ("equalsInt", conSigH [] [intH,intH] (tyConH "Bool" []))
      , ("intToFloat", conSigH [] [intH] floatH)
      , ("intToByteString", conSigH [] [intH] byteStringH)
      , ("addFloat", conSigH [] [floatH,floatH] floatH)
      , ("subtractFloat", conSigH [] [floatH,floatH] floatH)
      , ("multiplyFloat", conSigH [] [floatH,floatH] floatH)
      , ("divideFloat", conSigH [] [floatH,floatH] floatH)
      , ("lessThanFloat", conSigH [] [floatH,floatH] (tyConH "Bool" []))
      , ("equalsFloat", conSigH [] [floatH,floatH] (tyConH "Bool" []))
      , ("ceiling", conSigH [] [floatH] intH)
      , ("floor", conSigH [] [floatH] intH)
      , ("round", conSigH [] [floatH] intH)
      , ("concatenate", conSigH [] [byteStringH,byteStringH] byteStringH)
      , ("drop", conSigH [] [intH,byteStringH] byteStringH)
      , ("take", conSigH [] [intH,byteStringH] byteStringH)
      , ("sha2_256", conSigH [] [byteStringH] byteStringH)
      , ("sha3_256", conSigH [] [byteStringH] byteStringH)
      , ("equalsByteString",
          conSigH [] [byteStringH,byteStringH] (tyConH "Bool" []))
      , ("verifySignature",
          conSigH [] [byteStringH,byteStringH,byteStringH] (tyConH "Bool" []))
      , ("transactionInfo", conSigH [] [] (compH byteStringH))
      ]



-- | We can get the type of a declared name by looking in the definitions.
-- This corresponds to the judgment @Δ ∋ n : A@

typeInDefinitions :: DeclContext
                  -> Sourced String
                  -> Decomposer PolymorphicType
typeInDefinitions dctx n =
  case lookup n (definitions dctx) of
    Nothing ->
      failure
        (ElabError
          ("Unknown constant/defined term: " ++ showSourced n))
    Just (_,t) ->
      return t



-- | We can get the type of a generated variable by looking in the context.
-- This corresponds to the judgment @Γ ∋ x : A@

typeInContext :: HypContext -> FreeVar -> Maybe Type
typeInContext hctx x =
  lookup x (context hctx)



-- | We can check if a type variable is in scope. This corresponds to the
-- judgment @Γ ∋ α type@

tyVarExists :: HypContext -> FreeVar -> Bool
tyVarExists hctx x =
  isJust (lookup x (tyVarContext hctx))





-- | Type well-formedness corresponds to the judgment @A type@. This throws a
-- Haskell error if it encounters a variable because there should be no
-- vars in this type checker. That would only be possible for types coming
-- from outside the parser. Same for metavariables.
--
-- The judgment @Σ;Γ ⊢ A type@ is defined inductively as follows:
--
-- @
--   Γ ∋ α type
--   ----------
--   Γ ⊢ α type
--  
--   A type   B type
--   ---------------
--     A → B type
--
--   Σ ∋ n : *^k   Σ ⊢ Ai type
--   -------------------------
--     Σ ⊢ n A0 ... Ak type
--
--   Γ, α type ⊢ A type
--   ------------------
--     Γ ⊢ ∀α. A type
-- @

isType :: DeclContext -> HypContext -> Type -> Decomposer ()
isType _ hctx (Var (Free x@(FreeVar n))) =
  if tyVarExists hctx x
  then return ()
  else failure (ElabError ("Unbound type variable: " ++ n))
isType _ _ (Var (Bound _ _)) =
  error "Bound type variables should not be the subject of type checking."
isType _ _ (Var (Meta _)) =
  error "Metavariables should not be the subject of type checking."
isType dctx hctx (In (TyCon c as)) =
  do TyConSig ar <- tyconExists dctx c
     let las = length as
     unless (ar == las)
       $ failure
           (ElabError $
             c ++ " expects " ++ show ar ++ " "
               ++ (if ar == 1 then "arg" else "args")
               ++ " but was given " ++ show las)
     forM_ as $ \a ->
       goal (IsType dctx hctx (instantiate0 a))
isType dctx hctx (In (Fun a b)) =
  do goal (IsType dctx hctx (instantiate0 a))
     goal (IsType dctx hctx (instantiate0 b))
isType dctx hctx (In (Comp a)) =
  goal (IsType dctx hctx (instantiate0 a))
isType _ _ (In PlutusInt) =
  return ()
isType _ _ (In PlutusFloat) =
  return ()
isType _ _ (In PlutusByteString) =
  return ()




isPolymorphicType :: DeclContext
                  -> HypContext
                  -> PolymorphicType
                  -> Decomposer ()
isPolymorphicType dctx hctx (PolymorphicType sc) =
  do let (xs,_,a) = openScope (tyVarContext hctx) sc
         hctx' = hctx { tyVarContext =
                          tyVarContextFromFreeVars xs ++ tyVarContext hctx
                      }
     goal (IsType dctx hctx' a)





-- | We can instantiate the argument and return types for a constructor
-- signature with variables.

instantiateParams :: [Scope TypeF] -> Scope TypeF -> Decomposer ([Type],Type)
instantiateParams argscs retsc =
  do metas <- replicateM (length (names retsc)) newMeta
     let ms = map (Var . Meta) metas
     return ( map (\sc -> instantiate sc ms) argscs
            , instantiate retsc ms
            )





-- | We can instantiate a universally quantified type with metavariables
-- eliminating all the initial quantifiers. For example, the type
-- @∀α,β. (α → β) → α@ would become @(?0 → ?1) → ?0@, while the type
-- @∀α. (∀β. α → β) → α@ would become @(∀β. ?0 → β) → ?0@ and the type
-- @A → ∀β. A → β@ would be unchanged.

instantiateQuantifiers :: Type -> Decomposer Type
-- instantiateQuantifiers (In (Forall sc)) =
--   do meta <- nextElab nextMeta
--      let m = Var (Meta meta)
--      instantiateQuantifiers (instantiate sc [m])
instantiateQuantifiers t = return t





-- | Let lifting is performed by abstracting over the free variables of a
-- @let@'s value, lifting the now closed term to a top level declaration, and
-- replacing the whole value with an application applied to the free
-- variables. For example, instead of having
--
-- @
--    let f : A -> B { \x -> y } in M
-- @
--
-- where @y@ is free in the definition of @f@, we instead would get something
-- like this:
--
-- @
--    let f : A -> B { f_helper y } in M
-- @
--
-- together with a top-level declaration
--
-- @
--    f_helper : B -> A -> B { \y x -> y }
-- @
--
-- The result of let lifting is that all local @let@s in Core are simple
-- non-recursive codes for substitutions, and all recursive definitions are
-- top-level declarations of functions.
--
-- Let lifting implements the judgment @Δ ⊢ n : A { M } lifts M' ⊣ Δ'@
-- which is defined as
--
-- @
--    Δ ⊢ helper : Γ* → A { λΓ*.M } ⊣ Δ'    Δ' ; Γ* ⊢ A ∋ helper Γ* ▹ M'
--    ------------------------------------------------------------------
--                     Δ ⊢ n : A { M } lifts M' ⊣ Δ''
-- @
--
-- where @helper@ is some globally unique name generated for the lifting
-- process, @Γ* → A@ is the iterated function type which has the @Γ*@s as the
-- arguments before @A@, @λΓ*.M@ is the function with iterated abstractions
-- over the variables of @Γ*@, and @helper Γ*@ is iterated application. For
-- the above example, @Γ* = y : B@.

letLift :: DeclContext
        -> HypContext
        -> String
        -> Term
        -> Type
        -> Decomposer (Core.Term, DeclContext)
letLift dctx hctx liftName m a =
  do let fvs = freeVars m
     i <- newGeneratedNameIndex
     currentName <- nameBeingDeclared
     let helperName :: Sourced String
         helperName =
             Generated (currentName ++ "_" ++ liftName ++ "_" ++ show i)
         fvsWithTypes :: [(FreeVar,Type)]
         fvsWithTypes = [ (fv,t)
                        | fv <- fvs
                        , fv /= FreeVar liftName
                        , let Just t = lookup fv (context hctx)
                        ]
         helperType :: PolymorphicType
         helperType = polymorphicTypeH []
                      $ helperFold
                          (\(_,b) c -> funH b c)
                          fvsWithTypes
                          a
         newM :: Term
         newM = helperFold
                  (\(x,_) f -> appH f (Var (Free x)))
                  fvsWithTypes
                  (decnameH helperName)
         helperDef :: Term
         helperDef = helperFold
                       (\(FreeVar x,_) b -> lamH x b)
                       fvsWithTypes
                       (runIdentity (swapName m))
         swapName :: Term -> Identity Term
         swapName (Var v) = Identity (Var v)
         swapName (In (Decname x))
           | x == User liftName =
               Identity newM
           | otherwise =
               Identity (In (Decname x))
         swapName (In x) = In <$> traverse (underF swapName) x
     dctx' <- goal
                (ElabTermDecl
                  dctx
                  (TermDeclaration helperName helperType helperDef))
     goal (Check dctx' hctx a newM)
     {-
     elabTermDecl
       (TermDeclaration helperName helperType helperDef)
     checkify newM a
     -}




-- | Type synthesis corresponds to the judgment @Γ ⊢ M ▹ M' ∈ A@. This throws
-- a Haskell error when trying to synthesize the type of a bound variable,
-- because all bound variables should be replaced by free variables during
-- this part of type checking.
--
-- The judgment @Γ ⊢ M ▹ M' ∈ A@ is defined inductively as follows:
--
-- @
--      Γ ∋ x : A
--    ------------- variable
--    Γ ⊢ x ▹ x ∈ A
--
--          Δ ∋ n : A
--    ---------------------- definition
--    Δ ⊢ n ▹ decname[n] ∈ A
--
--    A type   A ∋ M ▹ M'
--    ------------------- annotation
--      M : A ▹ M' ∈ A
--
--    M ▹ M' ∈ A → B   A ∋ N ▹ N'
--    --------------------------- application
--        M N ▹ app(M';N') ∈ B
--
--    Mi ▹ M'i ∈ Ai   Pj → Nj ▹ N'j from A0,...,Am to B
--    -------------------------------------------------- case
--    case M0 | ... | Mm of { P0 → N0; ...; Pn → Nn }
--    ▹ case(M'0,...,M'm; cl(P0,N'0),...,cl(Pn;N'n)) ∈ B
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'
--    ---------------------------------------------- builtin
--    Σ ⊢ !n M0 ... Mk ▹ builtin[n](M'0,...,M'k) ∈ B
-- @
--
-- Not everything is officially synthesizable but is supported here to be as
-- user friendly as possible. Successful synthesis relies on the unification
-- mechanism to fully instantiate types. The pseudo-rules that ares used are
--
-- @
--    Δ ⊢ x : A { M } lifts M' ⊣ Δ'    Δ' ; Γ, x : A ⊢ N ▹ N' ∈ B ⊣ Δ''
--    ----------------------------------------------------------------- let
--          Δ ; Γ ⊢ let x : A { M } in N ▹ let(M';x.N') ∈ B ⊣ Δ''
--
--       Γ, x : A ⊢ M ▹ M' ∈ B
--    ---------------------------- function
--    Γ ⊢ λx → M ▹ λ(x.M') ∈ A → B
--
--    Σ ∋ n : [α*](A0,...,An)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'i
--    ------------------------------------------ constructed data
--    Σ ⊢ B' ∋ n M0 ... Mn ▹ con[n](M'0,...,M'n)
--
--              Γ ⊢ M ▹ M' ∈ A
--    ------------------------------------ success
--    Γ ⊢ success M ▹ success(M') ∈ Comp A
--
--    ------------------------------ failure
--    Γ ⊢ failure ▹ failure ∈ Comp A
--
--    Γ ⊢ M ▹ M' ∈ Comp A   Γ, x : A ⊢ N ▹ N' ∈ Comp B
--    ------------------------------------------------ bind
--     Γ ⊢ do { x <- M ; N } ▹ bind(M';x.N') ∈ Comp B
-- @

synthify :: DeclContext
         -> HypContext
         -> Term
         -> Decomposer (Core.Term, Type, DeclContext)
synthify _ _ (Var (Bound _ _)) =
  error "A bound variable should never be the subject of type synthesis."
synthify dctx hctx (Var (Free x@(FreeVar n))) =
  case typeInContext hctx x of
    Nothing ->
      failure (ElabError ("Unbound variable: " ++ n))
    Just t ->
      return (Var (Free x), t, dctx)
synthify _ _ (Var (Meta _)) =
  error "Metavariables should not be the subject of type synthesis."
synthify dctx _ (In (Decname x)) =
  do PolymorphicType sc <- typeInDefinitions dctx x
     metas <- replicateM (length (names sc)) newMeta
     let as = map (Var . Meta) metas
     return (Core.decnameH x as, instantiate sc as, dctx)
synthify dctx hctx (In (Ann m t)) =
  do goal (IsType dctx hctx t)
     (m',dctx') <- goal (Check dctx hctx t (instantiate0 m))
     return (m', t, dctx')
synthify dctx hctx (In (Let a m sc)) =
  do (m', dctx') <- letLift dctx hctx (head (names sc)) (instantiate0 m) a
     let ([x],[v],n) = openScope (context hctx) sc
         ctx' = (x,a) : context hctx
         hctx' = hctx { context = ctx' }
     (n', b, dctx'') <- goal (Synth dctx' hctx' n)
     return ( Core.letH m' v n'
            , b
            , dctx''
            )
synthify dctx hctx (In (Lam sc)) =
  do meta <- newMeta
     let arg = (Var (Meta meta))
         ([x],[n],m) = openScope (context hctx) sc
         ctx' = (x,arg) : context hctx
     (m', ret, dctx') <- goal (Synth dctx (hctx { context = ctx' }) m)
     return (Core.lamH arg n m', funH arg ret, dctx')
synthify dctx hctx (In (App f a)) =
  do (f', t, dctx') <- goal (Synth dctx hctx (instantiate0 f))
     t' <- instantiateQuantifiers t
     case t' of
       In (Fun arg ret) -> do
         (a', dctx'') <-
           goal (Check dctx' hctx (instantiate0 arg) (instantiate0 a))
         return ( Core.appH f' a'
                , instantiate0 ret
                , dctx''
                )
       _ -> failure
              (ElabError
                $ "Expected a function type when checking"
                    ++ " the expression: " ++ pretty (instantiate0 f)
                    ++ "\nbut instead found: " ++ pretty t')
synthify dctx hctx (In (Con c ms)) =
  do ConSig argscs retsc <- typeInSignature dctx c
     (args',ret') <- instantiateParams argscs retsc
     let lms = length ms
         largs' = length args'
     unless (lms == largs')
       $ failure
           (ElabError
             (c ++ " expects " ++ show largs' ++ " "
                ++ (if largs' == 1 then "arg" else "args")
                ++ " but was given " ++ show lms))
     (ms', dctx') <- checkifyMulti dctx hctx args' (map instantiate0 ms)
     return ( Core.conH c ms'
            , ret'
            , dctx'
            )
synthify dctx hctx (In (Case ms cs)) =
  do (ms', as, dctx') <- synthifyCaseArgs dctx hctx (map instantiate0 ms)
     (cs', bs, dctx'') <- synthifyClauses dctx' hctx as cs
     b <- goal (UnifyAll bs)
     return ( Core.caseH ms' cs'
            , b
            , dctx''
            )
synthify dctx hctx (In (Success m)) =
  do (m',a, dctx') <- goal (Synth dctx hctx (instantiate0 m))
     return (Core.successH m', compH a, dctx')
synthify dctx _ (In Failure) =
  do meta <- newMeta
     return ( Core.failureH (Var (Meta meta))
            , compH (Var (Meta meta))
            , dctx
            )
synthify dctx hctx (In (Bind m sc)) =
  do (m', ca, dctx') <- goal (Synth dctx hctx (instantiate0 m))
     case ca of
       In (Comp a) -> do
         do let ([x],[v],n) = openScope (context hctx) sc
                ctx' = (x,instantiate0 a) : context hctx
                hctx' = hctx { context = ctx' }
            (n', cb, dctx'') <- goal (Synth dctx' hctx' n)
            case cb of
              In (Comp b) ->
                return ( Core.bindH m' v n'
                       , In (Comp b)
                       , dctx''
                       )
              _ ->
                failure
                  (ElabError
                    ("Expected a computation type but found "
                      ++ pretty cb ++ "\nWhen checking term " ++ pretty n))
       _ -> failure
              (ElabError
                ("Expected a computation type but found " ++ pretty ca
                  ++ "\nWhen checking term " ++ pretty (instantiate0 m)))
synthify dctx _ (In (PrimData (PrimInt x))) =
  return (Core.primIntH x, intH, dctx)
synthify dctx _ (In (PrimData (PrimFloat x))) =
  return (Core.primFloatH x, floatH, dctx)
synthify dctx _ (In (PrimData (PrimByteString x))) =
  return (Core.primByteStringH x, byteStringH, dctx)
synthify dctx hctx (In (Builtin n ms)) =
  do ConSig argscs retsc <- builtinInSignature n
     (args',ret') <- instantiateParams argscs retsc
     let lms = length ms
         largs' = length args'
     unless (lms == largs')
       $ failure
           (ElabError
             (n ++ " expects " ++ show largs' ++ " "
                ++ (if largs' == 1 then "arg" else "args")
                ++ " but was given " ++ show lms))
     (ms', dctx') <- checkifyMulti dctx hctx args' (map instantiate0 ms)
     return ( Core.builtinH n ms'
            , ret'
            , dctx'
            )






synthifyCaseArgs :: DeclContext
                 -> HypContext
                 -> [Term]
                 -> Decomposer ([Core.Term], [Type], DeclContext)
synthifyCaseArgs dctx _ [] =
  return ([], [], dctx)
synthifyCaseArgs dctx hctx (m:ms) =
  do (m', a, dctx') <- goal (Synth dctx hctx m)
     (ms', as, dctx'') <- synthifyCaseArgs dctx' hctx ms
     return (m':ms', a:as, dctx'')





-- | Type synthesis for clauses corresponds to the judgment
-- @Σ;Δ;Γ ⊢ P* → M ▹ M' from A* to B@.
--
-- The judgment @Σ;Δ;Γ ⊢ P* → M ▹ P'* → M' from A* to B@ is defined as follows:
--
-- @
--    Σ ⊢ Ai pattern Pi ▹ P'i ⊣ Γ'i
--    Σ ; Δ ; Γ, Γ'0, ..., Γ'k ⊢ B ∋ M ▹ M'
--    ------------------------------------------ clause
--    Σ ; Δ ; Γ ⊢ P0 | ... | Pk → M ▹
--      P'0 | ... | P'k → M' from A0,...,Ak to B
-- @

synthifyClause :: DeclContext
               -> HypContext
               -> [Type]
               -> Clause
               -> Decomposer (Core.Clause, Type, DeclContext)
synthifyClause dctx hctx patTys (Clause pscs sc) =
  case names sc \\ nub (names sc) of
    x:xs ->
      failure
        (ElabError
          ("Repeated names " ++ unwords (x:xs)
             ++ "\nIn clause pattern "
             ++ intercalate " | " (map (pretty . body) pscs)))
    [] ->
      do let lps = length pscs
         unless (length patTys == lps)
           $ failure
               (ElabError
                 ("Mismatching number of patterns. Expected "
                    ++ show (length patTys)
                    ++ " but found " ++ show lps))
         pscsOutTyss' <-
           forM (zip patTys pscs) $ \(patTy,psc) -> do
             let (_,ns,p) = openScope (context hctx) psc
             (p',outTys) <- goal (CheckPattern dctx patTy p)
             return (scope ns p', outTys)
         let (pscs',outTyss) = unzip pscsOutTyss'
             outTys = concat outTyss
             (xs,ns,m) = openScope (context hctx) sc
             ctx' = zip xs outTys ++ context hctx
             hctx' = hctx { context = ctx' }
         (m', ret, dctx') <- goal (Synth dctx hctx' m)
         return ( Core.Clause pscs' (scope ns m')
                , ret
                , dctx'
                )





-- | The monadic generalization of 'synthClause', ensuring that there's at
-- least one clause to check, and that all clauses have the same result type.

synthifyClauses :: DeclContext
                -> HypContext
                -> [Type]
                -> [Clause]
                -> Decomposer ([Core.Clause], [Type], DeclContext)
synthifyClauses _ _ _ [] =
  failure
    (ElabError "Empty clauses.")
synthifyClauses dctx hctx patTys [cl] =
  do (cl',a,dctx') <- synthifyClause dctx hctx patTys cl
     return ([cl'],[a],dctx')
synthifyClauses dctx hctx patTys (cl:cls) =
  do (cl',a,dctx') <- synthifyClause dctx hctx patTys cl
     (cls',as,dctx'') <- synthifyClauses dctx' hctx patTys cls
     return (cl':cls', a:as, dctx'')
{-
  do (cs',ts) <- unzip <$> mapM (synthifyClause patTys) cs
     case ts of
       [] -> throwError "Empty clauses."
       t:ts' -> do
         let unifier :: Type -> Elaborator ()
             unifier t' = do
               subs <- getElab substitution
               unify substitution context (substMetas subs t) (substMetas subs t')
         catchError (mapM_ unifier ts') $ \e ->
           throwError $ "Clauses do not all return the same type:\n"
                     ++ unlines (map pretty ts) ++ "\n"
                     ++ "Unification failed with error: " ++ e
         subs <- getElab substitution
         return ( map (Core.substTypeMetasClause subs) cs'
                , substMetas subs t
                )


-}


-- | Type checking corresponds to the judgment @Γ ⊢ A ∋ M ▹ M'@.
--
-- The judgment @Γ ⊢ A ∋ M ▹ M'@ is defined inductively as follows:
--
-- @
--    Δ ⊢ x : A { M } lifts M' ⊣ Δ'    Δ' ; Γ, x : A ⊢ B ∋ N ▹ N' ⊣ Δ''
--    ----------------------------------------------------------------- let
--          Δ ; Γ ⊢ B ∋ let x : A { M } in N ▹ let(M';x.N') ⊣ Δ''
--
--       Γ, x : A ⊢ B ∋ M ▹ M'
--    --------------------------- lambda
--    Γ ⊢ A → B ∋ λx → M ▹ λ(x.M')
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'i
--    ------------------------------------------ constructed data
--    Σ ⊢ B' ∋ n M0 ... Mn ▹ con[n](M'0,...,M'k)
--
--               A ∋ M ▹ M'
--    -------------------------------- success
--    Comp A ∋ success M ▹ success(M')
--
--    -------------------------- failure
--    Comp A ∋ failure ▹ failure
--
--    Γ ⊢ M ▹ M' ∈ Comp A   Γ, x : A ⊢ Comp B ∋ N ▹ N'
--    ------------------------------------------------ bind
--     Γ ⊢ Comp B ∋ do { x  ← M ; N } ▹ bind(M';x.N')
--
--    Γ, α type ⊢ A ∋ M ▹ M'
--    ---------------------- forall
--      Γ ⊢ ∀α.A ∋ M ▹ M'
--
--    M ▹ M' ∈ A   A ⊑ B
--    ------------------ direction change
--        B ∋ M ▹ M'
-- @

checkify :: DeclContext
         -> HypContext
         -> Type
         -> Term
         -> Decomposer (Core.Term, DeclContext)
checkify dctx hctx a (In (Let b m sc)) =
  do (m', dctx') <- letLift dctx hctx (head (names sc)) (instantiate0 m) a
     let ([x],[v],n) = openScope (context hctx) sc
         ctx' = (x,a) : context hctx
         hctx' = hctx { context = ctx' }
     (n', dctx'') <- goal (Check dctx' hctx' b n)
     return ( Core.letH m' v n'
            , dctx''
            )
checkify dctx hctx (In (Fun arg ret)) (In (Lam sc)) =
  do let ([x],[v],m) = openScope (context hctx) sc
         ctx' = (x,instantiate0 arg) : context hctx
         hctx' = hctx { context = ctx' }
     (m', dctx') <- goal (Check dctx hctx' (instantiate0 ret) m)
     return ( Core.lamH (instantiate0 arg) v m'
            , dctx'
            )
checkify _ _ a (In (Lam sc)) =
  failure
    (ElabError
      ("Cannot check term: " ++ pretty (In (Lam sc)) ++ "\n"
         ++ "Against non-function type: " ++ pretty a))
checkify dctx hctx a (In (Con c ms)) =
  do ConSig argscs retsc <- typeInSignature dctx c
     (args',ret') <- instantiateParams argscs retsc
     let lms = length ms
         largs' = length args'
     unless (lms == largs')
       $ failure
           (ElabError
             (c ++ " expects " ++ show largs' ++ " "
                ++ (if largs' == 1 then "arg" else "args")
                ++ " but was given " ++ show lms))
     goal (Unify a ret')
     (ms',dctx') <- checkifyMulti dctx hctx args' (map instantiate0 ms)
     return ( Core.conH c ms'
            , dctx'
            )
checkify dctx hctx (In (Comp a)) (In (Success m)) =
  do (m',dctx') <- goal (Check dctx hctx (instantiate0 a) (instantiate0 m))
     return ( Core.successH m'
            , dctx'
            )
checkify _ _ a (In (Success m)) =
  failure
    (ElabError
      ("Cannot check term: " ++ pretty (In (Success m)) ++ "\n"
         ++ "Against non-computation type: " ++ pretty a))
checkify dctx _ (In (Comp a)) (In Failure) =
  return ( Core.failureH (In (Comp a))
         , dctx
         )
checkify _ _ a (In Failure) =
  failure
    (ElabError
      ("Cannot check term: " ++ pretty (In Failure) ++ "\n"
         ++ "Against non-computation type: " ++ pretty a))
checkify dctx hctx (In (Comp b)) (In (Bind m sc)) =
  do (m', ca, dctx') <- goal (Synth dctx hctx (instantiate0 m))
     case ca of
       In (Comp a) -> do
         do let ([x],[v],n) = openScope (context hctx) sc
                ctx' = (x,instantiate0 a) : context hctx
                hctx' = hctx { context = ctx' }
            (n', dctx'') <- goal (Check dctx' hctx' (In (Comp b)) n)
            return ( Core.bindH m' v n'
                   , dctx''
                   )
       _ ->
         failure
           (ElabError
             ("Expected a computation type but found " ++ pretty ca
                ++ "\nWhen checking term " ++ pretty (instantiate0 m)))
checkify _ _ a (In (Bind m sc)) =
  failure
    (ElabError
      ("Cannot check term: " ++ pretty (In (Bind m sc)) ++ "\n"
         ++ "Against non-computation type: " ++ pretty a))
checkify dctx _ (In PlutusInt) (In (PrimData (PrimInt x))) =
  return ( Core.primIntH x
         , dctx
         )
checkify dctx _ (In PlutusFloat) (In (PrimData (PrimFloat x))) =
  return ( Core.primFloatH x
         , dctx
         )
checkify dctx _ (In PlutusByteString) (In (PrimData (PrimByteString x))) =
  return ( Core.primByteStringH x
         , dctx
         )
checkify dctx hctx a m =
  do (m', a', dctx') <- goal (Synth dctx hctx m)
     subtype a' a
     return (m', dctx')





-- | Checkifying a sequence of terms involves chaining substitutions
-- appropriately. This doesn't correspond to a particular judgment so much
-- as a by product of the need to explicitly propagate the effects of
-- unification.

checkifyMulti :: DeclContext
              -> HypContext
              -> [Type]
              -> [Term]
              -> Decomposer ([Core.Term], DeclContext)
checkifyMulti dctx _ [] [] = return ([],dctx)
checkifyMulti dctx hctx (t:ts) (m:ms) =
  do (m', dctx') <- goal (Check dctx hctx t m)
     (ms', dctx'') <- checkifyMulti dctx' hctx ts ms
     return (m':ms', dctx'')
checkifyMulti _ _ _ _ =
  failure (ElabError "Mismatched constructor signature lengths.")






-- | This function checks if the first type is a subtype of the second. This
-- corresponds to the judgment @S ⊑ T@ which is defined inductively as:
--
-- @
--     A ⊑ B
--    --------
--    A ⊑ ∀α.B
--
--    [T/α]A ⊑ B
--    ----------
--     ∀α.A ⊑ B
--
--    A' ⊑ A   B ⊑ B'
--    ---------------
--    A → B ⊑ A' → B'
--
--    -----
--    A ⊑ A
-- @

subtype :: Type -> Type -> Decomposer ()
subtype a b = unify a b
{-
-- subtype a (In (Forall sc')) =
--   do (_,_,b) <- open tyVarContext sc'
--      subtype a b
-- subtype (In (Forall sc)) b =
--   do meta <- nextElab nextMeta
--      subtype (instantiate sc [Var (Meta meta)]) b
-- subtype (In (Fun arg ret)) (In (Fun arg' ret')) =
--   do subtype (instantiate0 arg') (instantiate0 arg)
--      subtype (instantiate0 ret) (instantiate0 ret')
subtype a b =
  unify substitution context a b


-}


-- | Type checking for patterns corresponds to the judgment
-- @Σ ⊢ A pattern P ▹ P' ⊣ Γ'@, where @Γ'@ is an output context.
--
-- The judgment @Σ ⊢ A pattern P ▹ P' ⊣ Γ'@ is defined inductively as follows:
--
-- @
--    ---------------------------
--    Σ ⊢ A pattern x ▹ x ⊣ x : A
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ Ai pattern Pi ▹ P'i ⊣ Γ'i
--    -----------------------------------
--    Σ ⊢ B' pattern n P0 ... Pk ▹
--      con[n](P'0,...,P'k) ⊣ Γ'0,...,Γ'k
--
--    primitive V has type A
--    -----------------------
--    Σ ⊢ A pattern V ▹ V ⊣ ε
-- @

checkifyPattern :: DeclContext
                -> Type
                -> Pattern
                -> Decomposer (Core.Pattern, [Type])
checkifyPattern _ _ (Var (Bound _ _)) =
  error "A bound variable should not be the subject of pattern type checking."
checkifyPattern _ _ (Var (Meta _)) =
  error "Metavariables should not be the subject of type checking."
checkifyPattern _ t (Var (Free n)) =
  return (Var (Free n), [t])
checkifyPattern dctx t (In (ConPat c ps)) =
  do ConSig argscs retsc <- typeInSignature dctx c
     (args',ret') <- instantiateParams argscs retsc
     let lps = length ps
         largs' = length args'
     unless (lps == largs')
       $ failure
           (ElabError
             (c ++ " expects " ++ show largs' ++ " "
                ++ (if largs' == 1 then "arg" else "args")
                ++ " but was given " ++ show lps))
     goal (Unify t ret') --unify substitution context t ret'
     psVarTyss' --(ps',varTyss)
       <- zipWithM
            (checkifyPattern dctx)
            args'
            (map instantiate0 ps)
     let (ps',varTyss) = unzip psVarTyss'
         varTys = concat varTyss
     return (Core.conPatH c ps', varTys)
checkifyPattern _ (In PlutusInt) (In (PrimPat (PrimInt x)))  =
  return (Core.primIntPatH x, [])
checkifyPattern _ a m@(In (PrimPat (PrimInt _))) =
  failure
    (ElabError
      ("Cannot check int pattern: " ++ pretty m ++ "\n"
         ++ "Against non-integer type: " ++ pretty a))
checkifyPattern _ (In PlutusFloat) (In (PrimPat (PrimFloat x))) =
  return (Core.primFloatPatH x, [])
checkifyPattern _ a m@(In (PrimPat (PrimFloat _))) =
  failure
    (ElabError
      ("Cannot check float pattern: " ++ pretty m ++ "\n"
         ++ "Against non-float type: " ++ pretty a))
checkifyPattern _ (In PlutusByteString) (In (PrimPat (PrimByteString x))) =
  return (Core.primByteStringPatH x, [])
checkifyPattern _ a m@(In (PrimPat (PrimByteString _))) =
  failure
    (ElabError
      ("Cannot check byteString pattern: " ++ pretty m ++ "\n"
          ++ "Against non-byteString type: " ++ pretty a))




-- | Type checking of constructor signatures corresponds to the judgment
-- @Γ ⊢ [α*](A0,...,Ak)B consig@ which is defined as
--
-- @
--    Γ, α* type ⊢ Ai type   Γ, α* type ⊢ B type
--    ------------------------------------------
--           Γ ⊢ [α*](A0,...,An)B consig
-- @
--
-- Because of the ABT representation, however, the scope is pushed down inside
-- the 'ConSig' constructor, onto its arguments.
--
-- This synthesis rule is not part of the spec proper, but rather is a
-- convenience method for the elaboration process because constructor
-- signatures are already a bunch of information in the implementation.

checkifyConSig :: DeclContext
               -> ConSig
               -> Decomposer ()
checkifyConSig dctx (ConSig argscs retsc) =
  do forM_ argscs $ \argsc -> do
       let (xs,_,a) = openScope [] argsc
           tyVarCtx = [ (x,()) | x <- xs ]
       goal (IsType dctx (HypContext tyVarCtx []) a)
     let (xs,_,b) = openScope [] retsc
         tyVarCtx = [ (x,()) | x <- xs ]
     goal (IsType dctx (HypContext tyVarCtx []) b)





unify :: Type -> Type -> Decomposer ()
unify (Var (Meta x)) b =
  assignMeta x b
unify a (Var (Meta y)) =
  assignMeta y a
unify a@(Var x) b@(Var y) =
  if x == y
  then return ()
  else failure
         (ElabError
           ("Mismatching variables: " ++ pretty a ++ " and " ++ pretty b))
unify (In (TyCon tycon1 as1)) (In (TyCon tycon2 as2)) =
  do unless (tycon1 == tycon2)
       $ failure
           (ElabError
             ("Mismatching type constructors "
                ++ tycon1 ++ " and " ++ tycon2))
     unless (length as1 == length as2)
       $ failure
           (ElabError
             ("Mismatching type constructor arg lengths between "
                ++ pretty (In (TyCon tycon1 as1)) ++ " and "
                ++ pretty (In (TyCon tycon2 as2))))
     zipWithM_
       (\a1 a2 -> goal (Unify a1 a2))
       (map instantiate0 as1)
       (map instantiate0 as2)
unify (In (Fun a1 b1)) (In (Fun a2 b2)) =
  do goal (Unify (instantiate0 a1) (instantiate0 a2))
     goal (Unify (instantiate0 b1) (instantiate0 b2))
unify (In (Comp a1)) (In (Comp a2)) =
  goal (Unify (instantiate0 a1) (instantiate0 a2))
unify (In PlutusInt) (In PlutusInt) =
  return ()
unify (In PlutusFloat) (In PlutusFloat) =
  return ()
unify (In PlutusByteString) (In PlutusByteString) =
  return ()
unify l r =
  failure
    (ElabError
      ("Cannot unify " ++ pretty l ++ " with " ++ pretty r))





unifyAll :: [Type] -> Decomposer Type
unifyAll [] =
  failure (ElabError "No types to unify.")
unifyAll [a] =
  return a
unifyAll (a:as) =
  do a' <- unifyAll as
     goal (Unify a a')
     return a






-- | All metavariables have been solved when the next metavar to produces is
-- the number of substitutions we've found.

metasSolved :: Decomposer ()
metasSolved =
  do s <- get
     unless (nextMeta s == MetaVar (length (substitution s)))
       $ failure (ElabError "Not all metavariables have been solved.")



{-

-- | Checking is just checkifying with a requirement that all metas have been
-- solved.

check :: Term -> Type -> TypeChecker Core.Term
check m t = do m' <- checkify m t
               metasSolved
               subs <- getElab substitution
               return $ Core.substTypeMetas subs m'





-- | Synthesis is just synthifying with a requirement that all metas have been
-- solved. The returned type is instantiated with the solutions.

synth :: Term -> TypeChecker (Core.Term,Type)
synth m = do (m',t) <- synthify m
             metasSolved
             subs <- getElab substitution
             return ( Core.substTypeMetas subs m'
                    , substMetas subs t
                    )

--}