{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
module Tip.Pass.Monomorphise where

import Tip.Utils.Specialiser
import Tip.Utils
import Tip.Fresh
import Tip.Core hiding (Expr)
import qualified Tip.Core as Tip

import Data.Foldable as F

import Tip.Pretty
import Text.PrettyPrint
import Tip.Pretty.SMT

import Control.Monad
import Control.Monad.Writer

import Data.Generics.Geniplate

import Data.List (union)

import Debug.Trace

trListTYPE :: (Type a -> Type a) -> [((a,[Type a]),a)] -> [((a,[Type a]),a)]
trListTYPE = undefined
return []
trList :: (Type a -> Type a) -> [((a,[Type a]),a)] -> [((a,[Type a]),a)]
trList = $(genTransformBi 'trListTYPE)

newtype PPVar a = PPVar { unPPVar :: a }
  deriving (Eq,Ord,PrettyVar)

instance Name a => Name (PPVar a) where
  fresh = fmap PPVar fresh
  refresh = fmap PPVar . refresh . unPPVar
  freshNamed = fmap PPVar . freshNamed
  refreshNamed s n = fmap PPVar (refreshNamed s (unPPVar n))

instance PrettyVar a => Pretty (PPVar a) where
  pp (PPVar x) = ppVar x

instance PrettyVar a => Show (PPVar a) where
  show (PPVar x) = varStr x

monomorphise :: forall a . Name a => Theory a -> Fresh (Theory a)
monomorphise = fmap (fmap unPPVar) . monomorphise' . fmap PPVar

monomorphise' :: forall a . (Name a,Pretty a) => Theory a -> Fresh (Theory a)
monomorphise' thy = do
    let ds = theoryDecls thy
        seeds = theorySeeds thy
        insts :: [(Decl a,Subst a Void (Con a))]
        loops :: [Decl a]
        rules = [ (d,declToRule d) | d <- ds ]
        (insts,loops) = specialise rules seeds
    traceM (show ("rules:" $\ pp rules))
    traceM (show ("loops:" $\ pp loops))
    traceM (show ("insts:" $\ pp insts))
    if null loops
      then do
        (insts',renames) <- runWriterT (mapM (uncurry renameDecl) insts)
        return $ renameWith (renameRenames renames) (declsToTheory (insts' ++ loops))
      else return thy

theorySeeds :: Ord a => Theory a -> [Closed (Con a)]
theorySeeds Theory{..} = usort (concat [ map close (exprRecords b) | Formula Prove [] b <- thy_asserts ])

exprPredRecords :: forall a . Ord a => Tip.Expr a -> [Expr (Con a) a]
exprPredRecords e =
    [ Con (Pred gbl_name) (map trType gbl_args)
    | Global{..} <- universeBi e
    ]

exprRecords :: forall a . Ord a => Tip.Expr a -> [Expr (Con a) a]
exprRecords e =
    exprPredRecords e ++
    [ Con (TCon tc) (map trType args)
    | Lcl (Local{..}) :: Tip.Expr a <- universeBi e
    , TyCon tc args :: Type a <- universeBi lcl_type
    ]

renameRenames :: Ord a => [((a,[Type a]),a)] -> [((a,[Type a]),a)]
renameRenames su =
    let su' = trList (tyRename su) su
        su2 = usort (su ++ su')
    in  if su == su2 then su else renameRenames su2

tyRename :: Ord a => [((a,[Type a]),a)] -> Type a -> Type a
tyRename su (TyCon tc ts) | Just tc' <- lookup (tc,ts) su = TyCon tc' []
tyRename _  t0 = t0

renameWith :: Ord a => [((a,[Type a]),a)] -> Theory a -> Theory a
renameWith su = transformBi (tyRename su) . transformBi gbl
  where
    gbl (Global f (PolyType tvs args res) ts)
        | Just f' <- lookup (f,ts) su
        = let at = applyType tvs ts
          in  Global f' (PolyType [] (map at args) (at res)) []
    gbl g0 = g0

renameDecl :: forall a . Name a => Decl a -> Subst a Void (Con a) -> WriterT [((a,[Type a]),a)] Fresh (Decl a)
renameDecl d su = case d of
    SortDecl (Sort s tvs)  -> do
        s' <- rename tvs s
        return (SortDecl (Sort s' []))
    SigDecl (Signature f pt@(PolyType tvs _ _)) -> do
        f' <- rename tvs f
        let (args',res) = applyPolyType pt (ty_args tvs)
        return (SigDecl (Signature f' (PolyType [] args' res)))
    AssertDecl (Formula r tvs b) ->
        return (ty_inst tvs (AssertDecl (Formula r [] b)))

    DataDecl (Datatype tc tvs cons) -> do
        tc' <- rename tvs tc
        cons' <- sequence
            [ do k' <- rename tvs k
                 d' <- rename tvs d
                 args' <- sequence [ do p' <- rename tvs p; return (p',t) | (p,t) <- args ]
                 return (Constructor k' d' args')
            | Constructor k d args <- cons
            ]
        return (ty_inst tvs (DataDecl (Datatype tc' [] cons')))

    FuncDecl fn@(Function f tvs args res body) -> do
        f' <- rename tvs f
        let fn' = Function f' [] args res body
        return (ty_inst tvs (FuncDecl fn'))
  where
  ty_args tvs = [ toType (fmap absurd e) | tv <- tvs, let Just e = lookup tv su ]

  ty_inst :: [a] -> Decl a -> Decl a
  ty_inst tvs d = applyTypeInDecl tvs (ty_args tvs) d

  rename :: [a] -> a -> WriterT [((a,[Type a]),a)] Fresh a
  -- rename [] f = return f
  rename tvs f = do
    f' <- lift (refresh f)
    tell [((f,ty_args tvs),f')]
    return f'

data Con a = Pred a | TCon a | TyArr | TyBun BuiltinType | Dummy
  deriving (Eq,Ord,Show)

instance Pretty a => Pretty (Con a) where
  pp (Pred x)   = "Pred" <+> parens (pp x)
  pp (TCon x)   = "TCon" <+> parens (pp x)
  pp TyArr      = "=>"
  pp (TyBun bu) = ppBuiltinType bu
  pp Dummy      = "dummy"

trType :: Type a -> Expr (Con a) a
trType (TyCon tc ts)     = Con (TCon tc) (map trType ts)
trType (ts :=>: tr)      = Con TyArr (map trType ts ++ [trType tr])
trType (TyVar x)         = Var x
trType (BuiltinType bun) = Con (TyBun bun) []

toType :: Expr (Con a) a -> Type a
toType (Con (TCon tc) ts)   = TyCon tc (map toType ts)
toType (Con TyArr ts)       = map toType (init ts) :=>: toType (last ts)
toType (Var x)              = TyVar x
toType (Con (TyBun bun) []) = BuiltinType bun

close :: Expr (Con a) a -> Closed (Con a)
close = fmap (error "contains variables")

sigRule :: a -> [a] -> Type a -> Rule (Con a) a
sigRule f tvs t = Rule (Con (Pred f) (map Var tvs)) (trType t)

declToRule :: Ord a => Decl a -> [Rule (Con a) a]
declToRule d = usort $ case d of
    SortDecl (Sort d tvs)         -> [Rule (Con (TCon d) (map Var tvs)) (Con Dummy [])]
    SigDecl (Signature f (PolyType tvs args res)) ->
        [ sigRule f tvs t | t <- args ++ [res] ]
    AssertDecl (Formula r tvs b)    ->
        quadratic
            [ pre
            | pre <- exprRecords b
            , and [ t `elem` F.toList pre | t <- tvs ]
            ]
    DataDecl (Datatype tc tvs cons) ->
        let tcon x = Con (TCon x) (map Var tvs)
            pred x = Con (Pred x) (map Var tvs)
        in (coactive $
              [ tcon tc ] ++
              [ pred f
              | Constructor k d args <- cons
              , f <- [k,d] ++ map fst args
              ]) ++
           [sigRule p tvs t | Constructor _ _ args <- cons, (p,t) <- args ]

    FuncDecl (Function f tvs args res body) ->
        {- concatMap subtermRules $ -}
        [ sigRule f tvs t | t <- map lcl_type args ++ [res] ] ++
        map (Rule (Con (Pred f) (map Var tvs))) (exprPredRecords body)

coactive :: [Expr (Con a) a] -> [Rule (Con a) a]
coactive []     = []
coactive [e]    = [Rule e (Con Dummy [])]
coactive (e:es) = map (Rule e) es ++ map (`Rule` e) es

quadratic :: [Expr (Con a) a] -> [Rule (Con a) a]
quadratic es = [ Rule p q
               | n <- [0..length es-1]
               , let (l,p:r) = splitAt n es
               , q <- l ++ r
               ]
