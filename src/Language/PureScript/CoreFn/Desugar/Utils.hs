{- HLINT ignore "Use void" -}
{- HLINT ignore "Use <$" -}
{- HLINT ignore "Use <&>" -}
module Language.PureScript.CoreFn.Desugar.Utils where

import Prelude
import Prelude qualified as P
import Protolude (MonadError (..), traverse_)

import Data.Function (on)
import Data.Tuple (swap)
import Data.Map qualified as M

import Language.PureScript.AST qualified as A
import Language.PureScript.AST.Literals (Literal(..))
import Language.PureScript.AST.SourcePos (pattern NullSourceSpan, SourceSpan(..))
import Language.PureScript.AST.Traversals (everythingOnValues, overTypes)
import Language.PureScript.CoreFn.Ann (Ann)
import Language.PureScript.CoreFn.Binders (Binder(..))
import Language.PureScript.CoreFn.Expr (Expr(..), PurusType)
import Language.PureScript.CoreFn.Meta (ConstructorType(..), Meta(..))
import Language.PureScript.Crash (internalError)
import Language.PureScript.Environment (
  pattern RecordT,
  DataDeclType(..),
  Environment(..),
  NameKind(..),
  lookupConstructor,
  lookupValue,
  NameVisibility (..),
  dictTypeName,
  TypeClassData (typeClassArguments),
  function,
  pattern (:->), pattern (:$), isDictTypeName)
import Language.PureScript.Names (Ident(..), ModuleName, ProperName(..), ProperNameType(..), Qualified(..), QualifiedBy(..), disqualify, getQual, runIdent, coerceProperName)
import Language.PureScript.Types (SourceType, Type(..), Constraint (..), srcTypeConstructor, srcTypeApp, rowToSortedList, RowListItem(..), replaceTypeVars, everywhereOnTypes)
import Language.PureScript.AST.Binders qualified as A
import Language.PureScript.AST.Declarations qualified as A
import Control.Monad.Supply.Class (MonadSupply)
import Control.Monad.State.Strict (MonadState, gets, modify')
import Control.Monad.Writer.Class ( MonadWriter )
import Language.PureScript.TypeChecker.Types
    ( kindType,
      TypedValue'(TypedValue'),
      infer )
import Language.PureScript.Errors
    ( MultipleErrors )
import Debug.Trace (traceM, trace)
import Language.PureScript.CoreFn.Pretty ( ppType )
import Data.Text qualified as T
import Text.Pretty.Simple (pShow)
import Data.Text.Lazy qualified as LT
import Language.PureScript.TypeChecker.Monad
    ( bindLocalVariables,
      getEnv,
      withScopedTypeVars,
      CheckState(checkCurrentModule, checkEnv), debugNames )
import Language.PureScript.Pretty.Values (renderValue)
import Language.PureScript.PSString (PSString)
import Language.PureScript.Label (Label(..))
import Data.Bifunctor (Bifunctor(..))


{- UTILITIES -}

-- | Type synonym for a monad that has all of the required typechecker functionality
type M m = (MonadSupply m, MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)

ctorArgs :: SourceType -> [SourceType]
ctorArgs (TypeApp _ t1 t2) = ctorArgs t1 <> [t2]
ctorArgs _  = []

ctorFun :: SourceType -> Maybe SourceType
ctorFun (TypeApp _ t1 _) = go t1
  where
    go (TypeApp _ tx _) = case ctorFun tx of
      Nothing -> Just tx
      Just tx' -> Just tx'
    go other = Just other
ctorFun _ = Nothing

analyzeCtor :: SourceType -> Maybe (SourceType,[SourceType])
analyzeCtor t = (,ctorArgs t) <$> ctorFun t


instantiate :: SourceType -> [SourceType] -> SourceType
instantiate ty [] = ty
instantiate (ForAll _ _ var _ inner _) (t:ts) = replaceTypeVars var t $ instantiate inner ts
instantiate other _ = other

-- | Traverse a literal. Note that literals are usually have a type like `Literal (Expr a)`. That is: The `a` isn't typically an annotation, it's an expression type
traverseLit :: forall m a b. Monad m => (a -> m b) -> Literal a -> m (Literal b)
traverseLit f = \case
  NumericLiteral x -> pure $ NumericLiteral x
  StringLiteral x -> pure $ StringLiteral x
  CharLiteral x -> pure $ CharLiteral x
  BooleanLiteral x -> pure $ BooleanLiteral x
  ArrayLiteral xs  -> ArrayLiteral <$> traverse f xs
  ObjectLiteral xs -> ObjectLiteral <$> traverse (\(str,x) -> f x >>= \b -> pure (str,b)) xs

-- | When we call `exprToCoreFn` we sometimes know the type, and sometimes have to infer it. This just simplifies the process of getting the type we want (cuts down on duplicated code)
inferType :: M m => Maybe SourceType -> A.Expr -> m SourceType
inferType (Just t) _ = pure t
inferType Nothing e = traceM ("**********HAD TO INFER TYPE FOR: (" <> renderValue 100 e <> ")") >>
  infer e >>= \case
    TypedValue' _ _ t -> do
      traceM ("TYPE: " <> ppType 100 t)
      pure t

-- Wrapper around instantiatePolyType to provide a better interface
withInstantiatedFunType :: M m => ModuleName -> SourceType -> (SourceType -> SourceType -> m (Expr Ann)) -> m (Expr Ann)
withInstantiatedFunType mn ty act = case instantiatePolyType mn ty of
  (a :-> b, replaceForalls, bindAct) -> bindAct $ replaceForalls <$> act a b
  (other,_,_) -> let !showty = LT.unpack (pShow other)
                 in error $ "Internal error. Expected a function type, but got: " <> showty
{- This function more-or-less contains our strategy for handling polytypes (quantified or constrained types). It returns a tuple T such that:
     - T[0] is the inner type, where all of the quantifiers and constraints have been removed. We just instantiate the quantified type variables to themselves (I guess?) - the previous
       typchecker passes should ensure that quantifiers are all well scoped and that all essential renaming has been performed. Typically, the inner type should be a function.
       Constraints are eliminated by replacing the constraint argument w/ the appropriate dictionary type.

     - T[1] is a function to transform the eventual expression such that it is properly typed. Basically: It puts the quantifiers back, (hopefully) in the right order and with
       the correct visibility, skolem scope, etc.

     - T[2] is a monadic action which binds local variables or type variables so that we can use type inference machinery on the expression corresponding to this type.
       NOTE: The only local vars this will bind are "dict" identifiers introduced to type desguared typeclass constraints.
             That is: If you're using this on a function type, you'll still have to bind the antecedent type to the
                      identifier bound in the VarBinder.
-}
-- TODO: Explicitly return two sourcetypes for arg/return types
instantiatePolyType :: M m => ModuleName -> SourceType-> (SourceType, Expr b -> Expr b, m a -> m a)
instantiatePolyType mn = \case
  ForAll ann vis var mbk t mSkol -> case instantiatePolyType mn t of
    (inner,g,act) ->
      let f = \case
                Abs ann' ty' ident' expr' ->
                  Abs ann' (ForAll ann vis var (purusTy <$> mbk) (purusTy ty') mSkol) ident' expr'
                other -> other
          -- FIXME: kindType?
          act' ma = withScopedTypeVars mn [(var,kindType)] $ act ma -- NOTE: Might need to pattern match on mbk and use the real kind (though in practice this should always be of kind Type, I think?)
      in (inner, f . g, act')
  -- this branch should be deprecated
  {-
   ConstrainedType _  Constraint{..} t -> case instantiatePolyType mn t of
    (inner,g,act) ->
      let dictTyName :: Qualified (ProperName 'TypeName) = dictTypeName . coerceProperName <$> constraintClass
          dictTyCon = srcTypeConstructor dictTyName
          dictTy = foldl srcTypeApp dictTyCon constraintArgs
          act' ma = bindLocalVariables [(NullSourceSpan,Ident "dict",dictTy,Defined)] $ act ma
      in (function dictTy inner,g,act')
   -}
  fun@(a :-> r) ->  case analyzeCtor a of
      Just (TypeConstructor ann ctor@(Qualified qb nm), args) ->
        if isDictTypeName nm
          then
            let act' ma = bindLocalVariables [(NullSourceSpan,Ident "dict",a,Defined)] $ ma
            in (fun,id,act')
          else (fun,id,id)
      other -> (fun,id,id)
  other -> (other,id,id)

-- In a context where we expect a Record type (object literals, etc), unwrap the record and get at the underlying rowlist
unwrapRecord :: Type a -> Either (Type a) [(PSString,Type a)]
unwrapRecord = \case
  RecordT lts -> Right $ go <$> fst (rowToSortedList lts)
  other -> Left other
 where
  go :: RowListItem a -> (PSString, Type a)
  go RowListItem{..} = (runLabel rowListLabel, rowListType)


traceNameTypes :: M m => m ()
traceNameTypes  = do
  nametypes <- getEnv >>= pure . debugNames
  traverse_ traceM nametypes

{- Since we operate on an AST where constraints have been desugared to dictionaries at the *expr* level,
   using a typechecker context which contains ConstrainedTypes, looking up the type for a class method
   will always give us a "wrong" type. Let's try fixing them in the context!

-}
desugarConstraintType' :: SourceType -> SourceType
desugarConstraintType' = \case
  ForAll a vis var mbk t mSkol ->
    let t' = desugarConstraintType' t
    in ForAll a vis var mbk t' mSkol
  ConstrainedType _ Constraint{..} t ->
    let inner = desugarConstraintType' t
        dictTyName :: Qualified (ProperName 'TypeName) = dictTypeName . coerceProperName <$> constraintClass
        dictTyCon = srcTypeConstructor dictTyName
        dictTy = foldl srcTypeApp dictTyCon constraintArgs
    in function dictTy inner
  other -> other

desugarConstraintTypes :: M m =>  m ()
desugarConstraintTypes  = do
  env <- getEnv
  let f = everywhereOnTypes desugarConstraintType'

      oldNameTypes = names env
      desugaredNameTypes = (\(st,nk,nv) -> (f st,nk,nv)) <$> oldNameTypes

      oldTypes = types env
      desugaredTypes = first f <$> oldTypes

      oldCtors = dataConstructors env
      desugaredCtors = (\(a,b,c,d) -> (a,b,f c,d)) <$> oldCtors

      oldSynonyms = typeSynonyms env
      desugaredSynonyms = second f <$> oldSynonyms

      newEnv = env { names = desugaredNameTypes
                   , types = desugaredTypes
                   , dataConstructors = desugaredCtors
                   , typeSynonyms = desugaredSynonyms }

  modify' $ \checkstate -> checkstate {checkEnv = newEnv}

desugarConstraintsInDecl :: A.Declaration -> A.Declaration
desugarConstraintsInDecl = \case
  A.BindingGroupDeclaration decls ->
    A.BindingGroupDeclaration
      $ (\(annIdent,nk,expr) -> (annIdent,nk,overTypes desugarConstraintType' expr)) <$> decls
  A.ValueDecl ann name nk bs [A.MkUnguarded e] ->
     A.ValueDecl ann name nk bs [A.MkUnguarded $ overTypes desugarConstraintType' e]
  A.DataDeclaration ann declTy tName args ctorDecs ->
    let fixCtor (A.DataConstructorDeclaration a nm fields) = A.DataConstructorDeclaration a nm (second (everywhereOnTypes desugarConstraintType') <$> fields)
    in A.DataDeclaration ann declTy tName args (fixCtor <$> ctorDecs)
  other -> other


-- Gives much more readable output (with colors for brackets/parens!) than plain old `show`
pTrace :: (Monad m, Show a) => a -> m ()
pTrace = traceM . LT.unpack . pShow

-- | Given a string and a monadic action, produce a trace with the given message before & after the action (with pretty lines to make it more readable)
wrapTrace :: Monad m => String -> m a -> m a
wrapTrace msg act = do
  traceM startMsg
  res <- act
  traceM endMsg
  pure res
 where
   padding = replicate 10 '='
   pad str = padding <> str <> padding
   startMsg = pad $ "BEGIN " <> msg
   endMsg = pad $ "END " <> msg

-- | Generates a pretty (ish) representation of the type environment/context. For debugging.
printEnv :: M m => m String
printEnv = do
   env <- gets checkEnv
   let ns = map (\(i,(st,_,_)) -> (i,st)) . M.toList $ names env
   pure $ concatMap (\(i,st) -> "ENV:= " <> T.unpack (runIdent . disqualify $  i) <> " :: " <> ppType 10 st <> "\n") ns

(</>) :: String -> String -> String
x </> y = x <> "\n" <> y

-- We need a string for traces and readability is super important here
showIdent' :: Ident -> String
showIdent' = T.unpack . runIdent

-- | Turns a `Type a` into a `Type ()`. We shouldn't need source position information for types.
-- NOTE: Deprecated (probably)
purusTy :: SourceType -> PurusType
purusTy = id -- fmap (const ())

-- | Given a class name, return the TypeClassData associated with the name.
getTypeClassData :: M m => Qualified (ProperName 'ClassName) -> m TypeClassData
getTypeClassData nm = do
  env <- getEnv
  case M.lookup nm (typeClasses env) of
    Nothing -> error $ "No type class data for " </> show nm </> "  found in" </> show (typeClasses env)
    Just cls -> pure cls

-- | Given a class name, return the parameters to the class and their *kinds*. (Maybe SourceType is a kind. Type classes cannot be parameterized by anything other than type variables)
getTypeClassArgs :: M m => Qualified (ProperName 'ClassName) -> m [(T.Text,Maybe SourceType)]
getTypeClassArgs nm = getTypeClassData nm >>= (pure . typeClassArguments)


-- | Retrieves the current module name from the context. This should never fail (as we set the module name when we start converting a module)
getModuleName :: M m => m ModuleName
getModuleName = gets checkCurrentModule >>= \case
  Just mn -> pure mn
  Nothing -> error "No module name found in checkState"

-- Creates a map from a module name to the re-export references defined in
-- that module.
reExportsToCoreFn :: (ModuleName, A.DeclarationRef) -> M.Map ModuleName [Ident]
reExportsToCoreFn (mn', ref') = M.singleton mn' (exportToCoreFn ref')

toReExportRef :: A.DeclarationRef -> Maybe (ModuleName, A.DeclarationRef)
toReExportRef (A.ReExportRef _ src ref) =
      fmap
        (, ref)
        (A.exportSourceImportedFrom src)
toReExportRef _ = Nothing

-- Remove duplicate imports
dedupeImports :: [(Ann, ModuleName)] -> [(Ann, ModuleName)]
dedupeImports = fmap swap . M.toList . M.fromListWith const . fmap swap

-- | Create an Ann (with no comments or metadata) from a SourceSpan
ssA :: SourceSpan -> Ann
ssA ss = (ss, [], Nothing)

-- Gets metadata for let bindings.
getLetMeta :: A.WhereProvenance -> Maybe Meta
getLetMeta A.FromWhere = Just IsWhere
getLetMeta A.FromLet = Nothing

-- Gets metadata for values.
getValueMeta :: Environment -> Qualified Ident -> Maybe Meta
getValueMeta env name =
  case lookupValue env name of
    Just (_, External, _) -> Just IsForeign
    _ -> Nothing

-- Gets metadata for data constructors.
getConstructorMeta :: Environment -> Qualified (ProperName 'ConstructorName) -> Meta
getConstructorMeta env ctor =
  case lookupConstructor env ctor of
    (Newtype, _, _, _) -> IsNewtype
    dc@(Data, _, _, fields) ->
      let constructorType = if numConstructors (ctor, dc) == 1 then ProductType else SumType
      in IsConstructor constructorType fields
  where

  numConstructors
    :: (Qualified (ProperName 'ConstructorName), (DataDeclType, ProperName 'TypeName, SourceType, [Ident]))
    -> Int
  numConstructors ty = length $ filter (((==) `on` typeConstructor) ty) $ M.toList $ dataConstructors env

  typeConstructor
    :: (Qualified (ProperName 'ConstructorName), (DataDeclType, ProperName 'TypeName, SourceType, [Ident]))
    -> (ModuleName, ProperName 'TypeName)
  typeConstructor (Qualified (ByModuleName mn') _, (_, tyCtor, _, _)) = (mn', tyCtor)
  typeConstructor _ = internalError "Invalid argument to typeConstructor"

-- | Find module names from qualified references to values. This is used to
-- ensure instances are imported from any module that is referenced by the
-- current module, not just from those that are imported explicitly (#667).
findQualModules :: [A.Declaration] -> [ModuleName]
findQualModules decls =
 let (f, _, _, _, _) = everythingOnValues (++) fqDecls fqValues fqBinders (const []) (const [])
 in f `concatMap` decls

fqDecls :: A.Declaration -> [ModuleName]
fqDecls (A.TypeInstanceDeclaration _ _ _ _ _ _ q _ _) = getQual' q
fqDecls (A.ValueFixityDeclaration _ _ q _) = getQual' q
fqDecls (A.TypeFixityDeclaration _ _ q _) = getQual' q
fqDecls _ = []

fqValues :: A.Expr -> [ModuleName]
fqValues (A.Var _ q) = getQual' q
fqValues (A.Constructor _ q) = getQual' q
fqValues _ = []

fqBinders :: A.Binder -> [ModuleName]
fqBinders (A.ConstructorBinder _ q _) = getQual' q
fqBinders _ = []

getQual' :: Qualified a -> [ModuleName]
getQual' = maybe [] return . getQual

-- | Converts a ProperName to an Ident.
properToIdent :: ProperName a -> Ident
properToIdent = Ident . runProperName

-- "Pure" desugaring utils

-- Desugars case binders from AST to CoreFn representation. Doesn't need to be monadic / essentially the same as the old version.
binderToCoreFn ::  Environment -> ModuleName -> SourceSpan -> A.Binder -> Binder Ann
binderToCoreFn  env mn _ss (A.LiteralBinder ss lit) =
  let lit' = binderToCoreFn env mn ss <$> lit
  in  LiteralBinder (ss, [], Nothing) lit'
binderToCoreFn _ _ ss A.NullBinder =
  NullBinder (ss, [], Nothing)
binderToCoreFn _ _ _ss vb@(A.VarBinder ss name) = trace ("binderToCoreFn: " <> show vb ) $
  VarBinder (ss, [], Nothing) name
binderToCoreFn env mn _ss (A.ConstructorBinder ss dctor@(Qualified mn' _) bs) =
  let (_, tctor, _, _) = lookupConstructor env dctor
      args = binderToCoreFn env mn _ss <$> bs
  in  ConstructorBinder (ss, [], Just $ getConstructorMeta env dctor) (Qualified mn' tctor) dctor args
binderToCoreFn env mn _ss (A.NamedBinder ss name b) =
  let arg = binderToCoreFn env mn _ss b
  in  NamedBinder (ss, [], Nothing) name arg
binderToCoreFn env mn _ss (A.PositionedBinder ss _ b) =
  binderToCoreFn env mn ss  b
binderToCoreFn env mn ss  (A.TypedBinder _ b) =
  binderToCoreFn env mn ss  b
binderToCoreFn _ _ _  A.OpBinder{} =
  internalError "OpBinder should have been desugared before binderToCoreFn"
binderToCoreFn _ _ _  A.BinaryNoParensBinder{} =
  internalError "BinaryNoParensBinder should have been desugared before binderToCoreFn"
binderToCoreFn _ _ _  A.ParensInBinder{} =
  internalError "ParensInBinder should have been desugared before binderToCoreFn"



-- | Desugars import declarations from AST to CoreFn representation.
importToCoreFn :: A.Declaration -> Maybe (Ann, ModuleName)
-- TODO: We probably *DO* want types here
importToCoreFn (A.ImportDeclaration (ss, com) name _ _) = Just ((ss, com, Nothing), name)
importToCoreFn _ = Nothing

-- | Desugars foreign declarations from AST to CoreFn representation.
externToCoreFn :: A.Declaration -> Maybe Ident
externToCoreFn (A.ExternDeclaration _ name _) = Just name
externToCoreFn _ = Nothing

-- | Desugars export declarations references from AST to CoreFn representation.
-- CoreFn modules only export values, so all data constructors, instances and
-- values are flattened into one list.
exportToCoreFn :: A.DeclarationRef -> [Ident]
exportToCoreFn (A.TypeRef _ _ (Just dctors)) = fmap properToIdent dctors
exportToCoreFn (A.TypeRef _ _ Nothing) = []
exportToCoreFn (A.TypeOpRef _ _) = []
exportToCoreFn (A.ValueRef _ name) = [name]
exportToCoreFn (A.ValueOpRef _ _) = []
exportToCoreFn (A.TypeClassRef _ _) = []
exportToCoreFn (A.TypeInstanceRef _ name _) = [name]
exportToCoreFn (A.ModuleRef _ _) = []
exportToCoreFn (A.ReExportRef _ _ _) = []
