-- |
-- Module      :  Cryptol.Eval
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}

module Cryptol.Eval (
    moduleEnv
  , runEval
  , EvalOpts(..)
  , PPOpts(..)
  , defaultPPOpts
  , Eval
  , EvalEnv
  , emptyEnv
  , evalExpr
  , evalDecls
  , evalNewtypeDecls
  , evalSel
  , evalSetSel
  , EvalError(..)
  , EvalErrorEx(..)
  , Unsupported(..)
  , WordTooWide(..)
  , forceValue
  ) where

import Cryptol.Backend
import Cryptol.Backend.Concrete( Concrete(..) )
import Cryptol.Backend.Monad
import Cryptol.Backend.SeqMap
import Cryptol.Backend.WordValue

import Cryptol.Eval.Env
import Cryptol.Eval.Prims
import Cryptol.Eval.Type
import Cryptol.Eval.Value
import Cryptol.ModuleSystem.Name
import Cryptol.Parser.Position
import Cryptol.Parser.Selector(ppSelector)
import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Solver.InfNat(Nat'(..))
import Cryptol.Utils.Ident
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.PP
import Cryptol.Utils.RecordMap

import           Control.Monad
import           Data.List
import           Data.Maybe
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Map.Strict as Map
import           Data.Semigroup

import Prelude ()
import Prelude.Compat

type EvalEnv = GenEvalEnv Concrete

type EvalPrims sym =
  ( Backend sym, ?callStacks :: Bool, ?evalPrim :: PrimIdent -> Maybe (Either Expr (Prim sym)) )

type ConcPrims =
  (?callStacks :: Bool, ?evalPrim :: PrimIdent -> Maybe (Either Expr (Prim Concrete)))

-- Expression Evaluation -------------------------------------------------------

{-# SPECIALIZE moduleEnv ::
  ConcPrims =>
  Concrete ->
  Module ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

-- | Extend the given evaluation environment with all the declarations
--   contained in the given module.
moduleEnv ::
  EvalPrims sym =>
  sym ->
  Module         {- ^ Module containing declarations to evaluate -} ->
  GenEvalEnv sym {- ^ Environment to extend -} ->
  SEval sym (GenEvalEnv sym)
moduleEnv sym m env = evalDecls sym (mDecls m) =<< evalNewtypeDecls sym (mNewtypes m) env

{-# SPECIALIZE evalExpr ::
  (?range :: Range, ConcPrims) =>
  Concrete ->
  GenEvalEnv Concrete ->
  Expr ->
  SEval Concrete (GenValue Concrete)
  #-}

-- | Evaluate a Cryptol expression to a value.  This evaluator is parameterized
--   by the `EvalPrims` class, which defines the behavior of bits and words, in
--   addition to providing implementations for all the primitives.
evalExpr ::
  (?range :: Range, EvalPrims sym) =>
  sym ->
  GenEvalEnv sym  {- ^ Evaluation environment -} ->
  Expr          {- ^ Expression to evaluate -} ->
  SEval sym (GenValue sym)
evalExpr sym env expr = case expr of

  ELocated r e ->
    let ?range = r in
    evalExpr sym env e

  -- Try to detect when the user has directly written a finite sequence of
  -- literal bit values and pack these into a word.
  EList es ty
    -- NB, even if the list cannot be packed, we must use `VWord`
    -- when the element type is `Bit`.
    | isTBit tyv -> {-# SCC "evalExpr->Elist/bit" #-}
        VWord len <$>
          (tryFromBits sym vs >>= \case
             Just w  -> pure (wordVal w)
             Nothing -> do xs <- mapM (\x -> sDelay sym (fromVBit <$> x)) vs
                           bitmapWordVal sym len $ finiteSeqMap sym xs)
    | otherwise -> {-# SCC "evalExpr->EList" #-} do
        xs <- mapM (sDelay sym) vs
        return $ VSeq len $ finiteSeqMap sym xs
   where
    tyv = evalValType (envTypes env) ty
    vs  = map eval es
    len = genericLength es

  ETuple es -> {-# SCC "evalExpr->ETuple" #-} do
     xs <- mapM (sDelay sym . eval) es
     return $ VTuple xs

  ERec fields -> {-# SCC "evalExpr->ERec" #-} do
     xs <- traverse (sDelay sym . eval) fields
     return $ VRecord xs

  ESel e sel -> {-# SCC "evalExpr->ESel" #-} do
     e' <- eval e
     evalSel sym e' sel

  ESet ty e sel v -> {-# SCC "evalExpr->ESet" #-}
    do e' <- eval e
       let tyv = evalValType (envTypes env) ty
       evalSetSel sym tyv e' sel (eval v)

  EIf c t f -> {-# SCC "evalExpr->EIf" #-} do
     b <- fromVBit <$> eval c
     iteValue sym b (eval t) (eval f)

  EComp n t h gs -> {-# SCC "evalExpr->EComp" #-} do
      let len  = evalNumType (envTypes env) n
      let elty = evalValType (envTypes env) t
      evalComp sym env len elty h gs

  EVar n -> {-# SCC "evalExpr->EVar" #-} do
    case lookupVar n env of
      Just (Left p)
        | ?callStacks -> sPushFrame sym n ?range (cacheCallStack sym =<< evalPrim sym n p)
        | otherwise   -> evalPrim sym n p
      Just (Right val)
        | ?callStacks ->
            case nameInfo n of
              Declared{} -> sPushFrame sym n ?range (cacheCallStack sym =<< val)
              Parameter  -> cacheCallStack sym =<< val
        | otherwise -> val
      Nothing  -> do
        envdoc <- ppEnv sym defaultPPOpts env
        panic "[Eval] evalExpr"
                     ["var `" ++ show (pp n) ++ "` (" ++ show (nameUnique n) ++ ") is not defined"
                     , show envdoc
                     ]

  ETAbs tv b -> {-# SCC "evalExpr->ETAbs" #-}
    case tpKind tv of
      KType -> tlam sym $ \ty -> evalExpr sym (bindType (tpVar tv) (Right ty) env) b
      KNum  -> nlam sym $ \n  -> evalExpr sym (bindType (tpVar tv) (Left n) env) b
      k     -> panic "[Eval] evalExpr" ["invalid kind on type abstraction", show k]

  ETApp e ty -> {-# SCC "evalExpr->ETApp" #-} do
    eval e >>= \case
      f@VPoly{}    -> fromVPoly sym f    $! (evalValType (envTypes env) ty)
      f@VNumPoly{} -> fromVNumPoly sym f $! (evalNumType (envTypes env) ty)
      val     -> do vdoc <- ppV val
                    panic "[Eval] evalExpr"
                      ["expected a polymorphic value"
                      , show vdoc, show (pp e), show (pp ty)
                      ]

  EApp f v -> {-# SCC "evalExpr->EApp" #-} do
    eval f >>= \case
      f'@VFun {} -> fromVFun sym f' (eval v)
      it         -> do itdoc <- ppV it
                       panic "[Eval] evalExpr" ["not a function", show itdoc ]

  EAbs n _ty b -> {-# SCC "evalExpr->EAbs" #-}
    lam sym (\v -> do env' <- bindVar sym n v env
                      evalExpr sym env' b)

  -- XXX these will likely change once there is an evidence value
  EProofAbs _ e -> eval e
  EProofApp e   -> eval e

  EWhere e ds -> {-# SCC "evalExpr->EWhere" #-} do
     env' <- evalDecls sym ds env
     evalExpr sym env' e

  where

  {-# INLINE eval #-}
  eval = evalExpr sym env
  ppV = ppValue sym defaultPPOpts


-- | Capure the current call stack from the evaluation monad and
--   annotate function values.  When arguments are later applied
--   to the function, the call stacks will be combined together.
cacheCallStack ::
  Backend sym =>
  sym ->
  GenValue sym ->
  SEval sym (GenValue sym)
cacheCallStack sym v = case v of
  VFun fnstk f ->
    do stk <- sGetCallStack sym
       pure (VFun (combineCallStacks stk fnstk) f)
  VPoly fnstk f ->
    do stk <- sGetCallStack sym
       pure (VPoly (combineCallStacks stk fnstk) f)
  VNumPoly fnstk f ->
    do stk <- sGetCallStack sym
       pure (VNumPoly (combineCallStacks stk fnstk) f)

  -- non-function types don't get annotated
  _ -> pure v

-- Newtypes --------------------------------------------------------------------

{-# SPECIALIZE evalNewtypeDecls ::
  ConcPrims =>
  Concrete ->
  Map.Map Name Newtype ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

evalNewtypeDecls ::
  EvalPrims sym =>
  sym ->
  Map.Map Name Newtype ->
  GenEvalEnv sym ->
  SEval sym (GenEvalEnv sym)
evalNewtypeDecls sym nts env = foldM (flip (evalNewtypeDecl sym)) env $ Map.elems nts

-- | Introduce the constructor function for a newtype.
evalNewtypeDecl ::
  EvalPrims sym =>
  sym ->
  Newtype ->
  GenEvalEnv sym ->
  SEval sym (GenEvalEnv sym)
evalNewtypeDecl _sym nt = pure . bindVarDirect (ntName nt) (foldr tabs con (ntParams nt))
  where
  con           = PFun PPrim

  tabs tp body =
    case tpKind tp of
      KType -> PTyPoly  (\ _ -> body)
      KNum  -> PNumPoly (\ _ -> body)
      k -> evalPanic "evalNewtypeDecl" ["illegal newtype parameter kind", show (pp k)]

{-# INLINE evalNewtypeDecl #-}


-- Declarations ----------------------------------------------------------------

{-# SPECIALIZE evalDecls ::
  ConcPrims =>
  Concrete ->
  [DeclGroup] ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

-- | Extend the given evaluation environment with the result of evaluating the
--   given collection of declaration groups.
evalDecls ::
  EvalPrims sym =>
  sym ->
  [DeclGroup]   {- ^ Declaration groups to evaluate -} ->
  GenEvalEnv sym  {- ^ Environment to extend -} ->
  SEval sym (GenEvalEnv sym)
evalDecls x dgs env = foldM (evalDeclGroup x) env dgs

{-# SPECIALIZE evalDeclGroup ::
  ConcPrims =>
  Concrete ->
  GenEvalEnv Concrete ->
  DeclGroup ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

evalDeclGroup ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym ->
  DeclGroup ->
  SEval sym (GenEvalEnv sym)
evalDeclGroup sym env dg = do
  case dg of
    Recursive ds -> do
      -- declare a "hole" for each declaration
      -- and extend the evaluation environment
      holes <- mapM (declHole sym) ds
      let holeEnv = IntMap.fromList $ [ (nameUnique nm, Right h) | (nm,_,h,_) <- holes ]
      let env' = env `mappend` emptyEnv{ envVars = holeEnv }

      -- evaluate the declaration bodies, building a new evaluation environment
      env'' <- foldM (evalDecl sym env') env ds

      -- now backfill the holes we declared earlier using the definitions
      -- calculated in the previous step
      mapM_ (fillHole sym env'') holes

      -- return the map containing the holes
      return env'

    NonRecursive d -> do
      evalDecl sym env env d



{-# SPECIALIZE fillHole ::
  Concrete ->
  GenEvalEnv Concrete ->
  (Name, Schema, SEval Concrete (GenValue Concrete), SEval Concrete (GenValue Concrete) -> SEval Concrete ()) ->
  SEval Concrete ()
  #-}

-- | This operation is used to complete the process of setting up recursive declaration
--   groups.  It 'backfills' previously-allocated thunk values with the actual evaluation
--   procedure for the body of recursive definitions.
--
--   In order to faithfully evaluate the nonstrict semantics of Cryptol, we have to take some
--   care in this process.  In particular, we need to ensure that every recursive definition
--   binding is indistinguishable from its eta-expanded form.  The straightforward solution
--   to this is to force an eta-expansion procedure on all recursive definitions.
--   However, for the so-called 'Value' types we can instead optimistically use the 'delayFill'
--   operation and only fall back on full eta expansion if the thunk is double-forced.

fillHole ::
  Backend sym =>
  sym ->
  GenEvalEnv sym ->
  (Name, Schema, SEval sym (GenValue sym), SEval sym (GenValue sym) -> SEval sym ()) ->
  SEval sym ()
fillHole _sym env (nm, _sch, _, fill) = do
  case lookupVar nm env of
    Just (Right v) -> fill v
    _ -> evalPanic "fillHole" ["Recursive definition not completed", show (ppLocName nm)]


{-# SPECIALIZE declHole ::
  Concrete ->
  Decl ->
  SEval Concrete
    (Name, Schema, SEval Concrete (GenValue Concrete), SEval Concrete (GenValue Concrete) -> SEval Concrete ())
  #-}

declHole ::
  Backend sym =>
  sym -> Decl -> SEval sym (Name, Schema, SEval sym (GenValue sym), SEval sym (GenValue sym) -> SEval sym ())
declHole sym d =
  case dDefinition d of
    DPrim   -> evalPanic "Unexpected primitive declaration in recursive group"
                         [show (ppLocName nm)]
    DExpr _ -> do
      (hole, fill) <- sDeclareHole sym msg
      return (nm, sch, hole, fill)
  where
  nm = dName d
  sch = dSignature d
  msg = unwords ["while evaluating", show (pp nm)]


-- | Evaluate a declaration, extending the evaluation environment.
--   Two input environments are given: the first is an environment
--   to use when evaluating the body of the declaration; the second
--   is the environment to extend.  There are two environments to
--   handle the subtle name-binding issues that arise from recursive
--   definitions.  The 'read only' environment is used to bring recursive
--   names into scope while we are still defining them.
evalDecl ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym  {- ^ A 'read only' environment for use in declaration bodies -} ->
  GenEvalEnv sym  {- ^ An evaluation environment to extend with the given declaration -} ->
  Decl            {- ^ The declaration to evaluate -} ->
  SEval sym (GenEvalEnv sym)
evalDecl sym renv env d =
  let ?range = nameLoc (dName d) in
  case dDefinition d of
    DPrim ->
      case ?evalPrim =<< asPrim (dName d) of
        Just (Right p) -> pure $ bindVarDirect (dName d) p env
        Just (Left ex) -> bindVar sym (dName d) (evalExpr sym renv ex) env
        Nothing        -> bindVar sym (dName d) (cryNoPrimError sym (dName d)) env

    DExpr e -> bindVar sym (dName d) (evalExpr sym renv e) env


-- Selectors -------------------------------------------------------------------

{-# SPECIALIZE evalSel ::
  Concrete ->
  GenValue Concrete ->
  Selector ->
  SEval Concrete (GenValue Concrete)
  #-}

-- | Apply the the given "selector" form to the given value.  This function pushes
--   tuple and record selections pointwise down into other value constructs
--   (e.g., streams and functions).
evalSel ::
  Backend sym =>
  sym ->
  GenValue sym ->
  Selector ->
  SEval sym (GenValue sym)
evalSel sym val sel = case sel of

  TupleSel n _  -> tupleSel n val
  RecordSel n _ -> recordSel n val
  ListSel ix _  -> listSel ix val
  where

  tupleSel n v =
    case v of
      VTuple vs       -> vs !! n
      _               -> do vdoc <- ppValue sym defaultPPOpts v
                            evalPanic "Cryptol.Eval.evalSel"
                              [ "Unexpected value in tuple selection"
                              , show vdoc ]

  recordSel n v =
    case v of
      VRecord {}      -> lookupRecord n v
      _               -> do vdoc <- ppValue sym defaultPPOpts v
                            evalPanic "Cryptol.Eval.evalSel"
                              [ "Unexpected value in record selection"
                              , show vdoc ]

  listSel n v =
    case v of
      VSeq _ vs       -> lookupSeqMap vs (toInteger n)
      VStream vs      -> lookupSeqMap vs (toInteger n)
      VWord _ wv      -> VBit <$> indexWordValue sym wv (toInteger n)
      _               -> do vdoc <- ppValue sym defaultPPOpts val
                            evalPanic "Cryptol.Eval.evalSel"
                              [ "Unexpected value in list selection"
                              , show vdoc ]
{-# SPECIALIZE evalSetSel ::
  Concrete -> TValue ->
  GenValue Concrete -> Selector -> SEval Concrete (GenValue Concrete) -> SEval Concrete (GenValue Concrete)
  #-}
evalSetSel :: forall sym.
  Backend sym =>
  sym ->
  TValue ->
  GenValue sym -> Selector -> SEval sym (GenValue sym) -> SEval sym (GenValue sym)
evalSetSel sym _tyv e sel v =
  case sel of
    TupleSel n _  -> setTuple n
    RecordSel n _ -> setRecord n
    ListSel ix _  -> setList (toInteger ix)

  where
  bad msg =
    do ed <- ppValue sym defaultPPOpts e
       evalPanic "Cryptol.Eval.evalSetSel"
          [ msg
          , "Selector: " ++ show (ppSelector sel)
          , "Value: " ++ show ed
          ]

  setTuple n =
    case e of
      VTuple xs ->
        case splitAt n xs of
          (as, _: bs) -> pure (VTuple (as ++ v : bs))
          _ -> bad "Tuple update out of bounds."
      _ -> bad "Tuple update on a non-tuple."

  setRecord n =
    case e of
      VRecord xs ->
        case adjustField n (\_ -> v) xs of
          Just xs' -> pure (VRecord xs')
          Nothing -> bad "Missing field in record update."
      _ -> bad "Record update on a non-record."

  setList n =
    case e of
      VSeq i mp  -> pure $ VSeq i  $ updateSeqMap mp n v
      VStream mp -> pure $ VStream $ updateSeqMap mp n v
      VWord i m  -> VWord i <$> updateWordValue sym m n asBit
      _ -> bad "Sequence update on a non-sequence."

  asBit = do res <- v
             case res of
               VBit b -> pure b
               _      -> bad "Expected a bit, but got something else"

-- List Comprehension Environments ---------------------------------------------

-- | Evaluation environments for list comprehensions: Each variable
-- name is bound to a list of values, one for each element in the list
-- comprehension.
data ListEnv sym = ListEnv
  { leVars   :: !(IntMap.IntMap (Integer -> SEval sym (GenValue sym)))
      -- ^ Bindings whose values vary by position
  , leStatic :: !(IntMap.IntMap (Either (Prim sym) (SEval sym (GenValue sym))))
      -- ^ Bindings whose values are constant
  , leTypes  :: !TypeEnv
  }

instance Semigroup (ListEnv sym) where
  l <> r = ListEnv
    { leVars   = IntMap.union (leVars  l)  (leVars  r)
    , leStatic = IntMap.union (leStatic l) (leStatic r)
    , leTypes  = leTypes l <> leTypes r
    }

instance Monoid (ListEnv sym) where
  mempty = ListEnv
    { leVars   = IntMap.empty
    , leStatic = IntMap.empty
    , leTypes  = mempty
    }

  mappend l r = l <> r

toListEnv :: GenEvalEnv sym -> ListEnv sym
toListEnv e =
  ListEnv
  { leVars   = mempty
  , leStatic = envVars e
  , leTypes  = envTypes e
  }
{-# INLINE toListEnv #-}

-- | Evaluate a list environment at a position.
--   This choses a particular value for the varying
--   locations.
evalListEnv :: ListEnv sym -> Integer -> GenEvalEnv sym
evalListEnv (ListEnv vm st tm) i =
    let v = fmap (Right . ($i)) vm
     in EvalEnv{ envVars = IntMap.union v st
               , envTypes = tm
               }
{-# INLINE evalListEnv #-}


bindVarList ::
  Name ->
  (Integer -> SEval sym (GenValue sym)) ->
  ListEnv sym ->
  ListEnv sym
bindVarList n vs lenv = lenv { leVars = IntMap.insert (nameUnique n) vs (leVars lenv) }
{-# INLINE bindVarList #-}

-- List Comprehensions ---------------------------------------------------------

{-# SPECIALIZE evalComp ::
  (?range :: Range, ConcPrims) =>
  Concrete ->
  GenEvalEnv Concrete ->
  Nat'           ->
  TValue         ->
  Expr           ->
  [[Match]]      ->
  SEval Concrete (GenValue Concrete)
  #-}
-- | Evaluate a comprehension.
evalComp ::
  (?range :: Range, EvalPrims sym) =>
  sym ->
  GenEvalEnv sym {- ^ Starting evaluation environment -} ->
  Nat'           {- ^ Length of the comprehension -} ->
  TValue         {- ^ Type of the comprehension elements -} ->
  Expr           {- ^ Head expression of the comprehension -} ->
  [[Match]]      {- ^ List of parallel comprehension branches -} ->
  SEval sym (GenValue sym)
evalComp sym env len elty body ms =
       do lenv <- mconcat <$> mapM (branchEnvs sym (toListEnv env)) ms
          mkSeq sym len elty =<< memoMap sym len (indexSeqMap $ \i -> do
              evalExpr sym (evalListEnv lenv i) body)

{-# SPECIALIZE branchEnvs ::
  (?range :: Range, ConcPrims) =>
  Concrete ->
  ListEnv Concrete ->
  [Match] ->
  SEval Concrete (ListEnv Concrete)
  #-}
-- | Turn a list of matches into the final environments for each iteration of
-- the branch.
branchEnvs ::
  (?range :: Range, EvalPrims sym) =>
  sym ->
  ListEnv sym ->
  [Match] ->
  SEval sym (ListEnv sym)
branchEnvs sym env matches = snd <$> foldM (evalMatch sym) (1, env) matches

{-# SPECIALIZE evalMatch ::
  (?range :: Range, ConcPrims) =>
  Concrete ->
  (Integer, ListEnv Concrete) ->
  Match ->
  SEval Concrete (Integer, ListEnv Concrete)
  #-}

-- | Turn a match into the list of environments it represents.
evalMatch ::
  (?range :: Range, EvalPrims sym) =>
  sym ->
  (Integer, ListEnv sym) ->
  Match ->
  SEval sym (Integer, ListEnv sym)
evalMatch sym (lsz, lenv) m = seq lsz $ case m of

  -- many envs
  From n l _ty expr ->
    case len of
      -- Select from a sequence of finite length.  This causes us to 'stutter'
      -- through our previous choices `nLen` times.
      Nat nLen -> do
        vss <- memoMap sym (Nat lsz) $ indexSeqMap $ \i -> evalExpr sym (evalListEnv lenv i) expr
        let stutter xs = \i -> xs (i `div` nLen)
        let lenv' = lenv { leVars = fmap stutter (leVars lenv) }
        let vs i = do let (q, r) = i `divMod` nLen
                      lookupSeqMap vss q >>= \case
                        VWord _ w   -> VBit <$> indexWordValue sym w r
                        VSeq _ xs'  -> lookupSeqMap xs' r
                        VStream xs' -> lookupSeqMap xs' r
                        _           -> evalPanic "evalMatch" ["Not a list value"]
        return (lsz * nLen, bindVarList n vs lenv')

      -- Select from a sequence of infinite length.  Note that this means we
      -- will never need to backtrack into previous branches.  Thus, we can convert
      -- `leVars` elements of the comprehension environment into `leStatic` elements
      -- by selecting out the 0th element.
      Inf -> do
        let allvars = IntMap.union (fmap (Right . ($0)) (leVars lenv)) (leStatic lenv)
        let lenv' = lenv { leVars   = IntMap.empty
                         , leStatic = allvars
                         }
        let env   = EvalEnv allvars (leTypes lenv)
        xs <- evalExpr sym env expr
        let vs i = case xs of
                     VWord _ w   -> VBit <$> indexWordValue sym w i
                     VSeq _ xs'  -> lookupSeqMap xs' i
                     VStream xs' -> lookupSeqMap xs' i
                     _           -> evalPanic "evalMatch" ["Not a list value"]
        -- Selecting from an infinite list effectively resets the length of the
        -- list environment, so return 1 as the length
        return (1, bindVarList n vs lenv')

    where
      len  = evalNumType (leTypes lenv) l

  -- XXX we don't currently evaluate these as though they could be recursive, as
  -- they are typechecked that way; the read environment to evalExpr is the same
  -- as the environment to bind a new name in.
  Let d -> return (lsz, bindVarList (dName d) (\i -> f (evalListEnv lenv i)) lenv)
    where
      f env =
          case dDefinition d of
            DPrim   -> evalPanic "evalMatch" ["Unexpected local primitive"]
            DExpr e -> evalExpr sym env e
