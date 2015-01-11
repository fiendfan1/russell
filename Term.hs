{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
module Term where

import Control.Monad
import Control.Monad.State
import Control.Applicative
import Data.Monoid
import Data.String (IsString(..))

import Text.PrettyPrint.HughesPJClass hiding ((<>))
--import Text.PrettyPrint

import qualified Data.Map as M

data Term n =
    Par !NameType n (Term n)
--  | Var !Int
  | App (Term n) (Term n)
  | Bind n (Binder (Term n)) (Term n)
  | Constant !Constant
  | Type !Int
--  | Erased
  deriving (Show, Functor)

instance Pretty n => Pretty (Term n) where
    pPrint (Par _ n _ty) = pPrint n -- <> " : " <> pPrint ty
    pPrint (App f x) = "(" <> pPrint f <> " " <> pPrint x <> ")"
    pPrint (Bind n (Lam ty) b) =
        "(" <>
        "\\(" <> pPrint n <> " : " <> pPrint ty <> ") => " <>
        pPrint b
        <> ")"
    pPrint (Bind n (Hole ty) b) =
        "(" <>
        "\\(__" <> pPrint n <> "__ : " <> pPrint ty <> ") =>" <>
        pPrint b
        <> ")"
    pPrint (Bind n (Pi ty) b) =
--        "(" <>
        "(" <> pPrint n <> " : " <> pPrint ty <> ") -> " <>
        pPrint b
--        <> ")"
    pPrint (Bind n (Let ty val) b) =
        "let " <> pPrint n <> " = " <>
        pPrint val <> " : " <> pPrint ty <>
        "in " <> pPrint b
    pPrint (Constant c) = pPrint c
    pPrint (Type i) = "Type " <> fromString (show i)

instance Eq n => Eq (Term n) where
    x == y = evalState (termEq (normalize x) (normalize y)) []

termEq :: Eq n => Term n -> Term n -> State [(n, n)] Bool
termEq (App f x) (App g y) = (&&) <$> termEq f g <*> termEq x y
termEq (Par _ nA tyA) (Par _ nB tyB) = do
    ctx <- get
    tyEq <- termEq tyA tyB
    return $ tyEq && case lookup nA ctx of
        Nothing -> nA == nB
        Just nC -> nC == nB
termEq (Bind nA (Lam tyA) a) (Bind nB (Lam tyB) b) = do
    modify ((nA, nB):)
    tyEq <- termEq tyA tyB
    bEq  <- termEq a b
    return $ tyEq && bEq
termEq (Bind nA (Pi tyA) a) (Bind nB (Pi tyB) b) = do
    modify ((nA, nB):)
    tyEq <- termEq tyA tyB
    bEq  <- termEq a b
    return $ tyEq && bEq
termEq (Bind nA (Hole tyA) a) (Bind nB (Hole tyB) b) = do
    modify ((nA, nB):)
    tyEq <- termEq tyA tyB
    bEq  <- termEq a b
    return $ tyEq && bEq
termEq (Bind nA (Let tyA valA) a) (Bind nB (Let tyB valB) b) = do
    modify ((nA, nB):)
    tyEq <- termEq tyA tyB
    bEq  <- termEq a b
    vEq  <- termEq valA valB
    return $ tyEq && vEq && bEq
termEq (Constant a) (Constant b) =
    return $ a == b
-- XXX: Pretend 'forall i j, Type i == Type j'
-- TODO: FIX
termEq Type{} Type{} = return True
termEq Type{} (Constant ConstTy{}) = return True  -- XXX: ??
termEq (Constant ConstTy{}) Type{} = return True  -- XXX: ??
termEq _ _ = return False

data Binder b =
    Lam b
  | Pi  b
  | Hole b
  | Let b b
    -- ^ Let type value
  deriving (Show, Eq, Functor)

binderTy :: Binder b -> b
binderTy (Lam  ty)  = ty
binderTy (Pi   ty)  = ty
binderTy (Hole ty)  = ty
binderTy (Let ty _) = ty

data Constant =
    ConstInt !Int
  | ConstFlt !Float
  | ConstStr !String
  | ConstTy  !ConstTy
  deriving (Show, Eq)

instance Pretty Constant where
    pPrint (ConstInt i) = fromString (show i)
    pPrint (ConstFlt f) = fromString (show f)
    pPrint (ConstStr s) = fromString (show s)
    pPrint (ConstTy ty) = pPrint ty

data ConstTy = IntTy | FltTy | StrTy
  deriving (Show, Eq)

instance Pretty ConstTy where
    pPrint IntTy = "Int"
    pPrint FltTy = "Float"
    pPrint StrTy = "String"

data Name =
    SName !String
  | IName !Int !String
  deriving (Show, Eq, Ord)

instance Pretty Name where
    pPrint (SName name) = fromString name
    pPrint (IName i name) = fromString (name ++ show i)

instance IsString Name where
    fromString = SName

data NameType =
    Bound
  | Ref
  | DataCon !Int
  | TypeCon !Int
  deriving (Show, Eq)

instance Pretty NameType where
    pPrint Bound       = "Bound"
    pPrint Ref         = "Ref"
    pPrint (DataCon i) = "DataCon " <> pPrint i
    pPrint (TypeCon i) = "TypeCon " <> pPrint i

-----------------
-- Environment --
-----------------

type Env = [(Name, Binder (Term Name))]

type Subst = M.Map Name (Term Name)


type Ctx = M.Map Name

data Context t = MkContext {
    definitions :: Ctx (Def t)
    } deriving (Show, Eq, Functor)

instance Monoid (Context t) where
    mempty = MkContext M.empty
    mappend (MkContext a) (MkContext b) =
        MkContext $ a `mappend` b

instance Pretty t => Pretty (Context t) where
    pPrint (MkContext defMap) = foldr mappend mempty $
        flip map (M.toList defMap) $ \(n, x) ->
            pPrint n <> " = " <> pPrint x <> "\n"

data Def t =
    Function t t
    -- ^ Function type term
  | TyDecl NameType t
    -- ^ TyDecl nametype type
  deriving (Show, Eq, Functor)

instance Pretty t => Pretty (Def t) where
    pPrint (Function ty term) =
        pPrint term <> "\n    : " <> pPrint ty
    pPrint (TyDecl nt ty) = pPrint nt <> " " <> pPrint ty

-------------------
-- Type checking --
-------------------

data TypeCheck a =
    PassCheck a
  | TypeError (Err Name)
  deriving (Show, Eq, Functor)

instance Applicative TypeCheck where
    pure = PassCheck
    PassCheck f <*> PassCheck x =
        PassCheck $ f x
    TypeError erra <*> TypeError errb =
        TypeError (ThenE erra errb)
    TypeError err <*> _ = TypeError err
    _ <*> TypeError err = TypeError err

instance Monad TypeCheck where
    return  = pure
    PassCheck x >>= f = f x
    TypeError e >>= _ = TypeError e

data Err n =
    Msg String
  | MsgT String (Term n)
  | UnboundVar n
  | CantUnify (Term n) (Term n)
  | TypeMismatch (Term n) (Term n)
  | NotAFunction (Term n)
--  | InfiniteType n (Term n)
  | ThenE (Err n) (Err n)
  deriving (Show, Eq)

typeOf ::
    Env ->
    Context (Term Name) ->
    Term Name ->
    TypeCheck (Term Name)
typeOf _ _ (Type i)       = return $ Type (i+1)
typeOf _ _ (Constant c)   = return $ constType c
typeOf env ctx (Par _ n _ty) = lookupName env ctx n
    --binderTy <$> lookupName env ctx n -- XXX: return ty
typeOf env ctx (Bind n (Lam tyN) b) = do
    tyB <- typeOf ((n, Lam tyN) : env) ctx b
    let p = Bind n (Pi tyN) tyB
    -- Make sure it's type-safe.
    void $ typeOf env ctx p
    return p
typeOf env ctx (Bind n (Pi tyN) b) = do
    tyTyN <- fmap whnf (typeOf env ctx tyN)
    tyTyN' <- case tyTyN of
        Type{}             -> return tyTyN
        -- XXX Should I add this?:
        --Constant ConstTy{} -> return tyTyN
        _                  -> TypeError $ MsgT "Invalid input type" tyN

    tyB <- fmap whnf (typeOf ((n, Pi tyN) : env) ctx b)
    tyB' <- case tyB of
        Type{}             -> return tyTyN
        -- XXX Should I add this?:
        --Constant ConstTy{} -> return tyTyN
        _                  -> TypeError $ MsgT "Invalid output type" b
    return $ maxType tyTyN' tyB'
typeOf env ctx (Bind n (Hole tyN) b) = do
    -- XXX: Is this correct?
    -- (Just pretending the Hole isn't there?)
    -- or should I treat a Hole like a Lam?

    -- Make sure tyN is type-safe.
    void $ typeOf env ctx tyN
    typeOf ((n, Hole tyN) : env) ctx b
typeOf env ctx (Bind n (Let tyN valN) b) =
    -- XXX: IS THIS CORRECT??
    --
    -- Either this:
    -- typeWith ((n, tyN) : ctx) b
    --
    -- Or this:
    typeOf env ctx $ App (Bind n (Lam tyN) b) valN
typeOf env ctx (App f a) = do
    tyF <- fmap whnf (typeOf env ctx f)
    (n, tyN, b) <- case tyF of
        Bind n (Pi tyN) b -> return (n, tyN, b)
        _                 -> TypeError (NotAFunction f)
    tyA <- typeOf env ctx a

    converts env tyN tyA
    return $ subst n a b
{-
    if tyA == tyN
        then return $ subst n a b
        else
            let tyN' = normalize tyN
                tyA' = normalize tyA
            in TypeError (TypeMismatch f a) --(TypeMismatch tyN' tyA')
-}

converts :: [(Name, Binder (Term Name))] ->
              Term Name -> Term Name ->
              TypeCheck ()
converts env x y =
    when' (not <$> convEq env x y) $
        when' (not <$> convEq env (normalize x) (normalize y)) $
            TypeError (TypeMismatch (normalize x) (normalize y))
  where
    when' b a = b >>= flip when a

convEq :: [(Name, Binder (Term Name))] ->
            Term Name -> Term Name ->
            TypeCheck Bool
convEq env = ceq []
  where
    -- XXX: This just says that holes can convert
    --      with anything. TODO: FIX?
    ceq _ (Par _ nx _) _
        | isHole nx = return True
    ceq _ _ (Par _ ny _)
        | isHole ny = return True
    ceq ns (Par _ nx _) (Par _ ny _)
        | nx == ny ||
          (nx,ny) `elem` ns || (ny,nx) `elem` ns = return True
        | otherwise = return False -- TODO: sameDefs ns x y
{-
    ceq ns (Par _ nx _) (Par _ ny _)
        | isHole nx || isHole ny ||
          nx == ny ||
          (nx,ny) `elem` ns || (ny,nx) `elem` ns = return True
        | otherwise = return False -- TODO: sameDefs ns x y
-}
    ceq ns (App f x) (App g y) = liftA2 (&&) (ceq ns f g) (ceq ns x y)
    ceq ns (Bind nx bx sx) (Bind ny by sy) =
        liftA2 (&&) (ceqB bx by) (ceq ((nx,ny):ns) sx sy)
      where
        ceqB (Let t v) (Let t' v') =
            liftA2 (&&) (ceq ns t t') (ceq ns v v')
        ceqB b b' = ceq ns (binderTy b) (binderTy b')
    ceq _  (Constant x) (Constant y) = return $ x == y
    ceq _   Type{} Type{} = return True
    ceq _ _ _ = return False

    isHole x = x `elem` map fst (filter isHoleB env)
      where
        isHoleB (_,Hole{}) = True
        isHoleB _          = False

constType :: Constant -> Term n
constType ConstInt{} = Constant (ConstTy IntTy)
constType ConstFlt{} = Constant (ConstTy FltTy)
constType ConstStr{} = Constant (ConstTy StrTy)
constType ConstTy{}  = Type 0

maxType :: Term n -> Term n -> Term n
maxType (Type i) (Type j)
    | i >= j    = Type i
    | otherwise = Type j
maxType a@Type{} _ = a
maxType _ b@Type{} = b
maxType a _        = a

isUniverse :: Term Name -> Bool
isUniverse Type{} = True
--isUniverse (Constant ConstTy{}) = True
isUniverse _ = False

-------------------------
-- Operations on Terms --
-------------------------

normalize :: Eq n => Term n -> Term n
normalize (Bind n (Lam ty) b) =
    case normalize b of
        -- Eta reduce
        App f (Par _ n' _)
            | n == n' && not (n `freeIn` f) -> f
        e -> Bind n (Lam (normalize ty)) e
normalize (Bind n (Pi ty) b) =
    Bind n (Pi (normalize ty)) (normalize b)
normalize (Bind n (Hole ty) b) =
    -- XXX: This throws away holes if they
    --      aren't used. May be dangerous.
    let b' = normalize b
    in if n `freeIn` b'
        then Bind n (Hole (normalize ty)) b'
        else b'
    -- XXX: Should I eta-reduce holes??
    --Bind n (Hole (normalize ty)) (normalize b)
normalize (Bind n (Let _ val) b) =
    -- XXX: Correct?
    subst n (normalize val) b
normalize (App f a) =
    case normalize f of
        -- Beta reduce
        Bind n Lam{} b -> normalize (subst n a b)
        f'             -> App f' (normalize a)
normalize p@Par{}      = p
normalize c@Constant{} = c
normalize t@Type{}     = t

-- | Returns whether a variable is free in an expression.
freeIn :: Eq n => n -> Term n -> Bool
freeIn n = go
  where
    go (Bind n' (Lam  ty) b) = n /= n' && (go ty || go b)
    go (Bind n' (Pi   ty) b) = n /= n' && (go ty || go b)
    go (Bind n' (Hole ty) b) = n /= n' && (go ty || go b)
    go (Bind n' (Let ty val)
                b)           = n /= n' && (go ty || go val || go b)
    go (Par _ n' _)          = n /= n'
    go (App f a)             = go f || go a
    go Constant{}            = False
    go Type{}                = False

applySubst :: Subst -> Term Name -> Term Name
applySubst = flip (foldr (uncurry subst)) . M.toList

substEnv :: Eq n => [(n, Binder (Term n))] -> Term n -> Term n
substEnv env x = foldr (uncurry substB) x env
  where
    substB n (Lam ty) x' = subst n ty x'
    substB n (Pi  ty) x' = subst n ty x'
    substB n (Let ty _) x' = subst n ty x'
    substB n (Hole ty) x' = subst n ty x'

subst :: Eq n => n -> Term n -> Term n -> Term n
subst ni ei = go
  where
    go   (Bind n (Lam ty) b)  = helper Lam  n ty b
    go   (Bind n (Pi  ty) b)  = helper Pi   n ty b
    go   (Bind n (Hole ty) b) = helper Hole n ty b
    go   (Bind n (Let ty val) b)
        -- XXX: Correct?
        | n == ni   = Bind n (Let ty val) b
        | otherwise =
            Bind n (Let (go ty) (go val))
                   (go (subst n (Par Bound n ty) b))
    go   (App f a)            = App (go f) (go a)
    go e@(Par _ n _)
        | n == ni             = ei
        | otherwise           = e
    go c@Constant{}           = c
    go t@Type{}               = t

    -- XXX: Correct?
    helper c n ty b
        | n == ni   = Bind n (c ty) b
        | otherwise =
            Bind n (c (go ty)) (go (subst n (Par Bound n ty) b))

-- | Reduce an expression to weak-head normal form.
whnf :: Eq n => Term n -> Term n
whnf (App f a) =
    case whnf f of
        -- Beta reduce
        Bind n Lam{} b -> whnf (subst n a b)
        e -> e
whnf e = e

-- | Check if a term has any holes in it.
pureTerm :: Term Name -> Bool
pureTerm (App f a) = pureTerm f && pureTerm a
pureTerm (Bind _ b a) = pureBinder b && pureTerm a
  where
    pureBinder Hole{} = False
    pureBinder _ = True
pureTerm _ = True

-----------
-- Other --
-----------

lookupName :: [(Name, Binder a)] -> Context a -> Name -> TypeCheck a
lookupName env (MkContext ctx) n =
    case lookup n env of
        Just a -> return (binderTy a)
        Nothing -> case M.lookup n ctx of
            Just (Function ty _) -> return ty
            Just (TyDecl _ ty)   -> return ty
            Nothing -> TypeError $ UnboundVar n