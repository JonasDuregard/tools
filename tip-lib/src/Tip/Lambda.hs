{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
module Tip.Lambda (lambdaLift, axiomatizeLambdas) where

import Tip
import Tip.Fresh

import Data.Either
import Data.Generics.Geniplate
import Control.Applicative
import Control.Monad
import Control.Monad.Writer

-- | Defunctionalization.
--
-- Transforms
--
--    f x = ... \ y -> e [ x ] ...
--
-- into
--
--    f x = ... g x ...
--    g x = \ y -> e [ x ]
--
-- where g is a fresh function.
--
-- After this pass, lambdas only exist at the top level of functions

type DefunM a = WriterT [Function a] Fresh

lambdaLiftTop :: Name a => Expr a -> DefunM a (Expr a)
lambdaLiftTop e0 =
  case e0 of
    Lam lam_args lam_body ->
      do g_name <- lift fresh
         let g_args = free e0
         let g_tvs  = freeTyVars e0
         let g_type = map lcl_type lam_args :=>: exprType lam_body
         let g = Function g_name g_tvs g_args g_type (Lam lam_args lam_body)
         tell [g]
         return (applyFunction g (map TyVar g_tvs) (map Lcl g_args))
    _ -> return e0

lambdaLiftAnywhere :: (Name a,TransformBiM (DefunM a) (Expr a) (t a)) =>
                      t a -> Fresh (t a,[Function a])
lambdaLiftAnywhere = runWriterT . transformExprInM lambdaLiftTop

lambdaLift :: Name a => Theory a -> Fresh (Theory a)
lambdaLift thy0 =
  do (Theory{..},new_func_decls) <- lambdaLiftAnywhere thy0
     return Theory{thy_func_decls = new_func_decls ++ thy_func_decls,..}

-- | Axiomatize lambdas
--
-- turns
--
--   f x = \ y -> E[x,y]
--
-- into
--
--   declare-fun f ...
--
--   assert (forall x y . @ (f x) y = E[x,y]
axLamFunc :: Function a -> Maybe (AbsFunc a,Formula a)
axLamFunc Function{..} =
  case func_body of
    Lam lam_args e ->
      let abs = AbsFunc func_name (PolyType func_tvs (map lcl_type func_args) func_res)
          fm  = Formula Assert func_tvs
                  (mkQuant
                    Forall
                    (func_args ++ lam_args)
                    (apply
                      (applyAbsFunc abs (map TyVar func_tvs) (map Lcl func_args))
                      (map Lcl lam_args)
                     === e))
      in  Just (abs,fm)
    _ -> Nothing

axiomatizeLambdas :: Theory a -> Theory a
axiomatizeLambdas Theory{..} =
  Theory{
    thy_abs_func_decls = new_abs ++ thy_abs_func_decls,
    thy_func_decls = survivors,
    thy_form_decls = new_form ++ thy_form_decls,
    ..
  }
  where
    (survivors,new) =
      partitionEithers
        [ maybe (Left fn) Right (axLamFunc fn)
        | fn <- thy_func_decls
        ]

    (new_abs,new_form) = unzip new

