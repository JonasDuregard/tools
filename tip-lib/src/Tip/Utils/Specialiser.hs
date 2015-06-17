{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ConstraintKinds #-}
module Tip.Utils.Specialiser
    (specialise, Rule(..), Expr(..),
     Void, absurd,
     Closed, subtermRules, subterms, Subst, Inst) where

import Tip.Fresh
import Tip.Utils
import Tip.Pretty

import Control.Termination
import Data.Functor.Contravariant

import Control.Monad
import Data.Maybe
-- import Data.List
import Data.Foldable (Foldable)
import Data.Traversable (Traversable)

import Data.Set (Set)
import qualified Data.Set as S

import Data.Generics.Genifunctors

import Text.PrettyPrint

import Debug.Trace

-- traceShow x y = y

data Expr c a = Var a | Con c [Expr c a]
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

data Rule c a = Rule
  { rule_pre  :: Expr c a
  -- ^ The trigger.
  , rule_post :: Expr c a
  -- ^ The action. The variables here must be a subset of those in pre.
  }
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

return []

data ExprF c a r = VAR a | CON c [r]
  deriving Functor

data ListF a r = NIL | CONS a r
  deriving Functor

type EXPR c a = Fix (ExprF c a)

type LIST a = Fix (ListF a)

newtype Fin a = Fin a
  deriving (Eq)

instance Eq a => Finite (Fin a)

morallyFiniteT :: Eq a => TTest a
morallyFiniteT = contramap Fin finiteT

fromList :: [a] -> LIST a
fromList []     = Roll NIL
fromList (x:xs) = Roll (CONS x (fromList xs))

fromExpr :: Expr c a -> EXPR c a
fromExpr (Var x)    = Roll (VAR x)
fromExpr (Con x xs) = Roll (CON x (map fromExpr xs))

-- toList :: Fix (ListF a) -> [a]

listT :: forall a . TTest a -> TTest [a]
listT t = contramap fromList (fixT kids id f)
  where
  kids NIL = []
  kids (CONS _ xs) = [xs]

  f :: forall rec . TTest rec -> TTest (ListF a rec)
  f test = contramap (\ u        -> case u of NIL       -> Left ()
                                              CONS x xs -> Right (x,xs))
                     (eitherT unitT (pairT t test))

exprT :: forall c a . (Eq c, Eq a) => TTest (Expr c a)
exprT = contramap fromExpr (fixT kids id f)
  where
  kids VAR{}      = []
  kids (CON _ xs) = xs

  f :: forall rec . TTest rec -> TTest (ExprF c a rec)
  f test = contramap (\ u ->        case u of VAR x    -> Left x
                                              CON c xs -> Right (c,xs))
                     (eitherT morallyFiniteT (pairT morallyFiniteT (listT test)))

bimapRule :: (c -> c') -> (a -> a') -> Rule c a -> Rule c' a'
bimapRule = $(genFmap ''Rule)

mapRuleCtx :: (c -> c') -> Rule c a -> Rule c' a
mapRuleCtx c = bimapRule c id

instance (Pretty c,Pretty a) => Pretty (Expr c a) where
  pp (Var x)    = pp x
  pp (Con k es) = parens (pp k <+> fsep (map pp es))

instance (Pretty c,Pretty a) => Pretty (Rule c a) where
  pp (Rule p q) = pp p <+> "=>" $\ pp q

subtermRules :: Rule c a -> [Rule c a]
subtermRules (Rule p q) = map (Rule p) (subterms q)

subterms :: Expr c a -> [Expr c a]
subterms e = e : case e of Var a    -> []
                           Con _ es -> concatMap subterms es

ruleVars :: Ord a => Rule c a -> [a]
ruleVars (Rule p q) = usort $ concatMap go [p,q]
  where
  go (Var x) = [x]
  go (Con c es) = concatMap go es

type Closed c = Expr c Void

data Sk c = Old c | Sk Int
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

instance Pretty c => Pretty (Sk c) where
  pp (Old c) = pp c
  pp (Sk i)  = int i

instance Ord c => Name (Sk c) where
  fresh = Sk <$> fresh

instance PrettyVar (Sk c) where
  varStr _ = show ""

unSkolem :: Closed (Sk c) -> Expr c Int
unSkolem (Con (Old k) es) = Con k (map unSkolem es)
unSkolem (Con (Sk i) [])  = Var i

varOf :: Eq a => a -> Expr c a -> Bool
x `varOf` Var y    = x == y
x `varOf` Con _ es = any (x `varOf`) es

type Ctx a = (Ord a,Pretty a)

specialise :: forall d c a . (Ctx d,Ctx c,Ctx a) =>
    [(d,[Rule c a])] -> [Closed c] -> ([(d,Subst a Void c)],[d])
specialise decl_rules seeds = (which (usort (go seeds)), scary)
  where
  free0,free,scary :: [d]
  (usort -> free0,usort -> scary) = separate [ (d,r) | (d,rs) <- decl_rules, r <- rs ]
  free = free0 \\ scary

  named_rules :: [(d,Rule c a)]
  named_rules = [ (d,r) | (d,rules) <- decl_rules, d `elem` free, r <- rules ]

  go :: [Closed c] -> [Closed c]
  go insts
    | null (new_insts \\ insts) = []
    | otherwise                 = new_insts `union` go (new_insts `union` insts)
    where
    new_insts = usort $ map (snd . snd) new
    new = step named_rules insts

  which :: [Closed c] -> [(d,Subst a Void c)]
  which cls = usort [ (d,i) | (d,(i,_)) <- step named_rules cls ]

-- Return the safe rules, and the scary rules
separate :: (Ctx a,Ctx c) => [(name,Rule c a)] -> ([name],[name])
separate = go []
  where
  go rs ((n,r):xs)
    | terminating (r:rs) = let (a,b) = go (r:rs) xs in (n:a,b  )
    | otherwise          = let (a,b) = go rs     xs in (  a,n:b)
  go _ _ = ([],[])

cyclic :: (Ctx a,Ctx c) => Expr c a -> Expr c a -> Bool
cyclic e1 e2 | res       = traceShow ("cyclic" $\ sep [pp e1, pp e2]) res
             | otherwise = res
               where res = cyclic' e1 e2
cyclic' e1 e2 | Just m0 <- match e1 e2
              = or [ x `varOf` e | (x,e) <- m0, e /= Var x ]
cyclic' _  _  = False

terminating :: forall a c . (Ctx a,Ctx c) => [Rule c a] -> Bool
terminating (map (mapRuleCtx Old) -> rs) = go S.empty (initHistory (listT exprT)) (map return (inst rs))
  where
  trejs = trace
  -- go :: Set (Closed (Sk c)) -> History (Closed (Sk c)) -> Closed (Sk c) -> Bool
  go visited trace [] = trejs "Good!" True
  go visited trace (new:news)
    | traceShow ("go" $\ sep ["visited:" $\ pp (S.toList visited)
                             , "new:" $\ pp new]) False = undefined
    | head new `S.member` visited = trejs "Drop 1" (go visited trace news)
    | otherwise =
        case test trace new of
          Stop -> trejs "Stop!" False
          Continue trace' -> go (S.insert (head new) visited)
                                trace'
                                (news `union` [ n:new | n <- unnamedStep rs [head new] ])

--  go old new = traceShow ("go" $\ sep ["old:" $\ pp old, "new:" $\ pp new]) (go' old new)
--  go' old new | or [ cyclic (unSkolem o) (unSkolem new) | o <- old ] = False
--  go' old new = let both = old `union` [new] in all (go both) (unnamedStep rs [new] \\ both)

union :: Ord a => [a] -> [a] -> [a]
union (S.fromList -> s1) (S.fromList -> s2) = S.toList (s1 `S.union` s2)

(\\) :: Ord a => [a] -> [a] -> [a]
(\\) (S.fromList -> s1) (S.fromList -> s2) = S.toList (s1 S.\\ s2)

inst :: (Ctx a,Ctx c) => [Rule (Sk c) a] -> [Closed (Sk c)]
inst rules = runFresh $
  do i <- fresh
     return (map (instPre i) rules)

instPre :: (Ctx a,Ctx c) => Sk c -> Rule (Sk c) a -> Closed (Sk c)
instPre c r =
  let su = [ (v,Con c []) | v <- ruleVars r ]
  in  close su (rule_pre r)

close :: Eq a => [(a,Closed c)] -> Expr c a -> Closed c
close su (Var v)    = fromMaybe (error "close") (lookup v su)
close su (Con c es) = Con c (map (close su) es)

unnamedStep :: (Ctx c,Ctx a) => [Rule c a] -> [Closed c] -> [Closed c]
unnamedStep rs = usort . map (snd . snd) . step (map ((,) ()) rs)

step :: (Ctx name,Ctx c,Ctx a) => [(name,Rule c a)] -> [Closed c] -> [(name,Inst a c)]
step rs = usort . concatMap (activateAll rs)

activateAll :: (Ctx c,Ctx a) => [(name,Rule c a)] -> Closed c -> [(name,Inst a c)]
activateAll rs c = [ (name,c') | (name,rul) <- rs, Just c' <- [activateOne rul c] ]

type Inst a c = (Subst a Void c,Closed c)

activateOne :: (Ctx c,Ctx a) => Rule c a -> Closed c -> Maybe (Inst a c)
activateOne r@(Rule p q) e
  = fmap (\ su -> (su, close su q)) (match p e)

type Subst a b c = [(a,Expr c b)]

merge :: (Ctx a,Ctx b,Ctx c) => Subst a b c -> Subst a b c -> Maybe (Subst a b c)
merge xs ys =
  do guard (and [ maybe True (e ==) (lookup v ys) | (v,e) <- xs ])
     Just (unionOn fst xs ys)

merges :: (Ctx a,Ctx b,Ctx c) => [Subst a b c] -> Maybe (Subst a b c)
merges = foldM merge []

match :: (Ctx a,Ctx b,Ctx c) => Expr c a -> Expr c b -> Maybe (Subst a b c)
match (Var x) e = Just [(x,e)]
match (Con c xs) (Con d ys)
  | c == d
  , length xs == length ys
  = merges =<< zipWithM match xs ys
match _ _ = Nothing

test_rules = [("list",testList),("mdef",test1),("f_ok",test2),("f_bad",test3),("fg",test4)]

test_seeds = [Con "map" [Con "A" [],Con "B" []]
             ,Con "f" [Con "X" []]
             ]

testList =
  [ Rule (Con "cons" [Var "a"]) (Con "nil" [Var "a"])
  , Rule (Con "nil" [Var "a"])  (Con "cons" [Var "a"])
  ]

test1 =
  [ Rule (Con "map" [Var "a",Var "b"]) (Con "cons" [Var "a"])
  , Rule (Con "map" [Var "a",Var "b"]) (Con "cons" [Var "b"])
  , Rule (Con "map" [Var "a",Var "b"]) (Con "nil" [Var "a"])
  , Rule (Con "map" [Var "a",Var "b"]) (Con "nil" [Var "b"])
  , Rule (Con "map" [Var "a",Var "b"]) (Con "map" [Var "a",Var "b"])
  ]

test2 =
  [ Rule (Con "f" [Var "a"]) (Con "f" [Var "a"])
  ]

test3 =
  [ Rule (Con "f" [Var "a"]) (Con "f" [Con "f'" [Var "a"]])
  ]

test4 =
  [ Rule (Con "f" [Var "a"]) (Con "g" [Con "g'" [Var "a"]])
  , Rule (Con "g" [Var "b"]) (Con "f" [Var "b"])
  ]

data Void = Void !Void
  deriving (Eq,Ord,Show)

absurd :: Void -> a
absurd (Void v) = absurd v

instance Pretty Void where
  pp = absurd

