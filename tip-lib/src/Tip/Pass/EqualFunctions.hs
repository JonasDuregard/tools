{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}
module Tip.Pass.EqualFunctions(collapseEqual, removeAliases) where

import Tip.Core
import Tip.Fresh

import Data.Traversable
import Control.Applicative
import Data.Either
import Data.List (delete, inits)

import Data.Map (Map)
import qualified Data.Map as M

import Control.Monad.State

import Data.Generics.Geniplate

renameVars :: forall f a . (Ord a,Traversable f) => (a -> Bool) -> f a -> f (Either a Int)
renameVars is_var t = runFresh (evalStateT (traverse rename t) M.empty)
  where
    rename :: a -> StateT (Map a Int) Fresh (Either a Int)
    rename x | is_var x = do my <- gets (M.lookup x)
                             case my of
                               Just y  -> do return (Right y)
                               Nothing -> do y <- lift fresh
                                             modify (M.insert x y)
                                             return (Right y)
    rename x = return (Left x)

renameFn :: Ord a => Function a -> Function (Either a Int)
renameFn fn = renameVars (`notElem` gbls) fn
  where
    gbls = delete (func_name fn) (globals fn)

rename :: Eq a => [(a,a)] -> a -> a
rename d x = case lookup x d of
    Just y  -> y
    Nothing -> x

-- | If we have
--
-- > f x = E[x]
-- > g y = E[y]
--
-- then we remove @g@ and replace it with @f@ everywhere
collapseEqual :: forall a . Ord a => Theory a -> Theory a
collapseEqual thy@(Theory{ thy_funcs = fns0 })
    = fmap (rename renamings) thy{ thy_funcs = survivors }
  where
    rfs :: [(Function a,Function (Either a Int))]
    rfs = [ (f,renameFn f) | f <- fns0 ]

    renamings :: [(a,a)]
    survivors :: [Function a]
    (renamings,survivors) = partitionEithers
        [ case [ (func_name f,func_name g) | (g,rg) <- prev , rf == rg ] of
            []   -> Right f -- f is better
            fg:_ -> Left fg -- g is better
        | ((f,rf),prev) <- withPrevious rfs
        ]

-- | Pair up a list with its previous elements
--
-- > withPrevious "abc" = [('a',""),('b',"a"),('c',"ab")]
withPrevious :: [a] -> [(a,[a])]
withPrevious xs = zip xs (inits xs)

renameGlobals :: Eq a => [(a,[Type a] -> Head a)] -> Theory a -> Theory a
renameGlobals rns = transformBi $ \ h0 ->
  case h0 of
    Gbl (Global g _ ts) | Just hd <- lookup g rns -> hd ts
    _ -> h0

-- | If we have
--
-- > g [a] x y = f [T1 a,T2 a] x y
--
-- then we remove @g [t]@ and replace it with @f [T1 t,T2 t]@ everywhere
removeAliases :: Ord a => Theory a -> Theory a
removeAliases thy@(Theory{thy_funcs=fns0})
    | null renamings = thy
    | otherwise = removeAliases $ renameGlobals renamings thy{ thy_funcs = survivors }
  where
    renamings = take 1
      [ (g,k)
      | Function g g_tvs vars _ (hd :@: args) <- fns0
      , map Lcl vars == args
      , let k = case hd of
                  Builtin{} -> \ _ -> hd
                  Gbl (Global f pty f_args) ->
                    \ g_app -> Gbl (Global f pty (map (applyType g_tvs g_app) f_args))
      ]

    remove = map fst renamings

    survivors = filter ((`notElem` remove) . func_name) fns0

