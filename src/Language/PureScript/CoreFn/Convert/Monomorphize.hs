{-# OPTIONS_GHC -Wno-orphans #-} -- has to be here (more or less)
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use if" #-}
module Language.PureScript.CoreFn.Convert.Monomorphize where



import Prelude hiding (error)
import Data.Bifunctor
import Data.Maybe

import Language.PureScript.CoreFn.Expr
    ( _Var,
      eType,
      exprType,
      Bind(..),
      CaseAlternative(CaseAlternative),
      Expr(..),
      PurusType )
import Language.PureScript.CoreFn.Module ( Module(..) )
import Language.PureScript.Names (Ident(..), Qualified (..), QualifiedBy (..), pattern ByNullSourcePos, ModuleName)
import Language.PureScript.Types
    ( rowToList, RowListItem(..), SourceType, Type(ForAll) )
import Language.PureScript.CoreFn.Pretty.Common ( analyzeApp )
import Language.PureScript.CoreFn.Desugar.Utils ( showIdent' )
import Language.PureScript.Environment (pattern (:->), pattern ArrayT, pattern RecordT, function)
import Language.PureScript.CoreFn.Pretty
    ( prettyTypeStr, renderExprStr )
import Language.PureScript.CoreFn.Ann (Ann)
import Language.PureScript.CoreFn.FromJSON ()
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.List (find, foldl')
-- import Debug.Trace ( trace, traceM )
import Language.PureScript.AST.Literals (Literal(..))
import Data.Map (Map)
import Data.Map qualified as M
import Language.PureScript.Label (Label(runLabel))
import Language.PureScript.PSString (PSString, prettyPrintString)
import Language.PureScript.AST.SourcePos
    ( SourceAnn, pattern NullSourceSpan )
import Data.Bitraversable (Bitraversable(bitraverse))
import Control.Lens.IndexedPlated ( itransform, itransformM )
import Control.Lens
    ( Identity(runIdentity),
      (<&>),
      (&),
      (^?),
      preview,
      (^.),
      (.~),
      Ixed(ix) )
import Control.Monad.RWS.Class ( MonadReader(ask), gets, modify' )
import Control.Monad.RWS
    ( RWST(..) )
import Control.Monad.Except (throwError)
import Language.PureScript.CoreFn.Convert.Plated ( Context, prettyContext )
import Control.Exception
import Data.Text (Text)

monoTest :: FilePath -> Text -> IO (Expr Ann)
monoTest path decl = do
  myMod <- decodeModuleIO path
  case monomorphizeExpr myMod decl of
    Left (MonoError _ msg) -> throwIO $ userError msg
    Right e -> do
      putStrLn (renderExprStr e)
      pure e

trace :: String  -> p2 -> p2
trace _ x = x

traceM :: forall m. Monad m => String -> m ()
traceM _ = pure ()

-- hopefully a better API than the existing traversal machinery (which is kinda weak!)
-- Adapted from https://twanvl.nl/blog/haskell/traversing-syntax-trees

-- TODO: better error messages
data MonoError
 = MonoError Context String deriving (Show)

note :: Context  -> String -> Maybe b -> Monomorphizer b
note d err = \case
  Nothing -> throwError $ MonoError d err
  Just x -> pure x

-- ok we need monads
data MonoState = MonoState {
  {- Original Identifier -> Type -> (Fresh Ident, Expr)
  -}
  visited :: Map Ident (Map SourceType (Ident,Expr Ann)),
  unique :: Int
}
-- TODO: Logging, make a more useful state than S.Set Ident
type Monomorphizer a = RWST (ModuleName,[Bind Ann]) () MonoState (Either MonoError)  a
type Monomorphizer' a = RWST (ModuleName,[Bind Ann]) () MonoState Identity (Maybe a)

hoist1 ::  MonoState -> Monomorphizer a -> RWST (ModuleName,[Bind Ann]) () MonoState Identity (Maybe a)
hoist1 st act = RWST $ \r s -> f (runRWST act r s)
  where
    f :: Either MonoError (a, MonoState, ()) -> Identity (Maybe a, MonoState, ())
    f = \case
      Left (MonoError d msg) -> do
        traceM $ "MonoError:  " <> msg <> ":\n" <> "Context: " <> prettyContext d
        pure (Nothing,st,())
      Right (x,st',_) -> pure (Just x, st', ())

monomorphizeExpr :: Module Ann -> Text  -> Either MonoError (Expr Ann)
monomorphizeExpr m@Module{..} t = case findDeclBody t m of
  Nothing -> Left $ MonoError M.empty $ "Couldn't find decl: " <> T.unpack t
  Just e -> runRWST (itransformM monomorphizeA M.empty e) (moduleName,moduleDecls) (MonoState M.empty 0) & \case
    Left err -> Left err
    Right (a,_,_) -> Right a

monomorphizeMain :: Module Ann -> Maybe (Expr Ann)
monomorphizeMain Module{..} =  runMono g
  where
    emptySt = MonoState M.empty 0

    g =  monomorphizeB M.empty mainE

    monomorphizeB :: Context -> Expr Ann -> Monomorphizer' (Expr Ann)
    monomorphizeB d e = hoist1 emptySt (monomorphizeA d e)

    (mainE,otherDecls) = partitionDecls moduleDecls

    runMono :: RWST (ModuleName,[Bind Ann]) () MonoState Identity a  ->  a
    runMono act  = case runIdentity (runRWST act (moduleName,otherDecls) (MonoState M.empty 0)) of
                     (a,_,_) -> a

monomorphizeMain' :: Module Ann -> Either MonoError (Expr Ann)
monomorphizeMain' Module{..} =  g
  where
    g = runMono $ itransformM monomorphizeA M.empty mainE

    (mainE,otherDecls) = partitionDecls moduleDecls

    runMono :: RWST (ModuleName,[Bind Ann]) () MonoState (Either MonoError) a  ->  Either MonoError a
    runMono act  = case runRWST act (moduleName,otherDecls) (MonoState M.empty 0) of
                     Left err -> Left err
                     Right (a,_,_) -> Right a

decodeModuleIO :: FilePath -> IO (Module Ann)
decodeModuleIO path = Aeson.eitherDecodeFileStrict' path >>= \case
  Left err -> throwIO $ userError err
  Right modx -> pure modx

runMonoTest :: FilePath -> IO ()
runMonoTest path = do
  emod <- Aeson.eitherDecodeFileStrict' path
  case emod of
    Left err -> putStrLn $ "Couldn't deserialize module:\n  " <>  err
    Right modx -> case  monomorphizeMain modx of
      Nothing -> putStrLn "fail :-("
      Just res -> putStrLn $ renderExprStr res <> "\n"

runMonoTest' :: FilePath -> IO ()
runMonoTest' path = do
  emod <- Aeson.eitherDecodeFileStrict' path
  case emod of
    Left err -> putStrLn $ "Couldn't deserialize module:\n  " <>  err
    Right modx -> do
       case monomorphizeMain' modx of
         Left (MonoError d err) -> putStrLn $ "Failure at depth " <> show d <>  ":\n  " <> err
         Right e -> do
           putStrLn "Success! Result:\n  "
           putStr (renderExprStr e <> "\n")

getModName :: Monomorphizer ModuleName
getModName = ask <&> fst

getModBinds :: Monomorphizer [Bind Ann]
getModBinds = ask <&> snd

freshen :: Ident -> Monomorphizer Ident
freshen ident = do
  u <- gets unique
  modify' $ \(MonoState v _) -> MonoState v (u + 1)
  let uTxt = T.pack (show u)
  case ident of
    Ident t -> pure $ Ident $ t <> "_$$" <> uTxt
    GenIdent (Just t) i -> pure $ GenIdent (Just $ t <> "_$$" <> uTxt) i -- we only care about a unique ord property for the maps
    GenIdent Nothing i  -> pure $ GenIdent (Just $ "var_$$" <> uTxt) i
    -- other two shouldn't exist at this stage
    other -> pure other


checkVisited :: Ident -> SourceType -> Monomorphizer (Maybe (Ident,Expr Ann))
checkVisited ident st = gets (preview (ix ident . ix st) . visited)

markVisited :: Ident  -> SourceType -> Expr Ann -> Monomorphizer Ident
markVisited ident st e = do
  v <- gets visited
  newIdent <- freshen ident
  let v' = v & ix ident . ix st .~ (newIdent,e)
  modify' $ \(MonoState _ u) -> MonoState v' u
  pure newIdent

-- returns (main,rest)
-- NOTE: Assumes main isn't part of a recursive binding group (it really shouldn't be?)
partitionDecls :: [Bind Ann] -> (Expr Ann, [Bind Ann])
partitionDecls bs = first fromJust $ foldr go (Nothing,[]) bs
  where
    go :: Bind Ann -> (Maybe (Expr Ann), [Bind Ann]) -> (Maybe (Expr Ann), [Bind Ann])
    go b acc = case b of
      nonrec@(NonRec _ ident expr) -> case ident of
        Ident "main" -> first (const $ Just expr) acc
        _ -> second (nonrec:) acc
      other -> second (other:) acc

stripQuantifiers :: SourceType -> SourceType
stripQuantifiers = \case
  ForAll _ _ _  _ inner _ -> stripQuantifiers inner
  other -> other

getResult :: SourceType -> SourceType
getResult (_ :-> b) = getResult b
getResult other = other

nullAnn :: Ann
nullAnn = (NullSourceSpan,[],Nothing)

findDeclBody :: Text -> Module Ann -> Maybe (Expr Ann)
findDeclBody nm Module{..} = case findInlineDeclGroup (Ident nm) moduleDecls of
  Nothing -> Nothing
  Just decl -> case decl of
    NonRec _ _ e -> Just e
    Rec xs -> snd <$> find (\x -> snd (fst x) == Ident nm) xs

findInlineDeclGroup :: Ident -> [Bind a] -> Maybe (Bind a)
findInlineDeclGroup _ [] = Nothing
findInlineDeclGroup ident (NonRec ann ident' expr:rest)
  | ident == ident' = Just $ NonRec ann ident' expr
  | otherwise = findInlineDeclGroup ident rest
findInlineDeclGroup ident (Rec xs:rest) = case  find (\x -> snd (fst x) == ident) xs of
  Nothing -> findInlineDeclGroup ident rest
         -- idk if we need to specialize the whole group?
  Just _ -> Just (Rec xs)

monomorphizeA :: Context -> Expr Ann -> Monomorphizer (Expr Ann)
monomorphizeA d = \case
  app@(App ann ty _ arg) -> trace ("monomorphizeA " <> prettyTypeStr ty) $ do
    (f,args) <-  note d ("Not an App: " <> renderExprStr app) $ analyzeApp app
    let types = (^. eType) <$> args
     -- maybe trace or check that the types match?
     -- need to re-quantify? not sure. CHECK!
    handleFunction d f (types <> [ty]) >>= \case
      Left (binds,fun) -> do
        pure $ gLet  binds (App ann (getResult $ exprType fun) fun arg)
      Right fun -> pure $ App ann (getResult $ exprType fun) fun arg
  other -> pure other

gLet :: [Bind Ann] -> Expr Ann -> Expr Ann
gLet binds e = Let nullAnn (e ^. eType) binds e

nameShadows :: Context -> Ident -> Bool
nameShadows cxt iden = isJust $ M.lookup iden cxt

handleFunction :: Context
               -> Expr Ann
               -> [PurusType]
               -> Monomorphizer (Either ([Bind Ann], Expr Ann) (Expr Ann))
handleFunction  _ e [] = pure (pure e)
handleFunction  d expr@(Abs ann (ForAll{}) ident body'') (t:ts) = trace ("handleFunction abs:\n  " <> renderExprStr expr <> "\n  " <> prettyTypeStr t) $  do
  case nameShadows d ident of
    False -> do
        let body' = updateVarTy d ident t body''
            cxt   = M.insert ident t d
        handleFunction cxt body' ts >>= \case
          Left (binds,body) -> do
            let bodyT = body ^. eType
                e' = Abs ann (function t bodyT) ident body
            pure $ Left (binds,e')
          Right body -> do
            let bodyT = body ^. eType
            pure $ Right (Abs ann (function t bodyT) ident body)
    True -> do
      freshIdent <- freshen ident
      let body' = renameBoundVar ident freshIdent d $ updateVarTy d ident t body''
          cxt   = M.insert freshIdent t d
      handleFunction cxt body' ts >>= \case
          Left (binds,body) -> do
            let bodyT = body ^. eType
                e' = Abs ann (function t bodyT) freshIdent body
            pure $ Left (binds,e')
          Right body -> do
            let bodyT = body ^. eType
            pure $ Right (Abs ann (function t bodyT) freshIdent body)
handleFunction  d (Var _ _ qn) [t] = inlineAs d t qn
handleFunction d (Var _ _ qn) ts = inlineAs d (foldr1 function ts) qn -- idk about this one?
handleFunction  d e _ = throwError $ MonoError d
                        $ "Error in handleFunction:\n  "
                        <> renderExprStr e
                        <> "\n  is not an abstraction or variable"

-- I *think* all CTors should be translated to functions at this point?
-- TODO: We can make sure the variables are well-scoped too
updateVarTy :: Context -> Ident -> PurusType -> Expr Ann -> Expr Ann
updateVarTy d ident ty = itransform goVar d
  where
    goVar :: Context -> Expr Ann -> Expr Ann
    goVar _d expr = case expr ^? _Var of
      Just (ann,_,Qualified q@(BySourcePos _) varId) | varId == ident -> Var ann ty (Qualified q ident)
      _ -> expr

updateFreeVar :: M.Map Ident (Ident,SourceType) -> Context -> Expr Ann -> Expr Ann
updateFreeVar dict _ expr = case expr ^? _Var of
     Just (_,_,Qualified (ByModuleName _) varId) -> case M.lookup varId dict of
       Nothing -> expr
       Just (newId,newType) -> Var nullAnn newType (Qualified ByNullSourcePos newId)
     _ -> expr

updateFreeVars :: Map Ident (Ident, SourceType) -> Context -> Expr Ann -> Expr Ann
updateFreeVars dict = itransform (updateFreeVar dict)

-- doesn't change types!
renameBoundVar :: Ident -> Ident -> Context -> Expr Ann -> Expr Ann
renameBoundVar old new _ e = case e ^? _Var of
  Just (ann,ty,Qualified (BySourcePos sp) varId) | varId == old -> Var ann ty (Qualified (BySourcePos sp) new)
  _ -> e

renameBoundVars :: Ident -> Ident -> Context -> Expr Ann -> Expr Ann
renameBoundVars old new  = itransform (renameBoundVar old new)

inlineAs :: Context -> PurusType -> Qualified Ident -> Monomorphizer (Either ([Bind Ann], Expr Ann) (Expr Ann))
inlineAs d _ (Qualified (BySourcePos _) ident) = throwError $ MonoError d  $ "can't inline bound variable " <> showIdent' ident
inlineAs  d ty (Qualified (ByModuleName mn') ident) = trace ("inlineAs: " <> showIdent' ident <> " :: " <>  prettyTypeStr ty) $ ask >>= \(mn,modDict) ->
  if mn == mn'
    then do
      let msg = "Couldn't find a declaration with identifier " <> showIdent' ident <> " to inline as " <> prettyTypeStr ty
      note d msg  (findInlineDeclGroup ident modDict) >>= \case
        NonRec _ _ e -> do
          e' <- monomorphizeWithType ty d e
          pure . Right $ e'
        Rec xs -> do
          traceM $ "RECURSIVE GROUP:\n" <> concatMap (\((_,xId),t) -> showIdent' xId <> " :: " <> renderExprStr t <> "\n") xs
          let msg' = "Target expression with identifier " <> showIdent' ident <> " not found in mutually recursive group"
          (targIdent,targExpr) <- note d msg' $ find (\x -> fst x == ident) (first snd <$> xs) -- has to be there
          fresh <- freshen targIdent
          let initialRecDict = M.singleton targIdent (fresh,ty,targExpr)
          dict <- collectRecBinds initialRecDict ty d targExpr
          let renameMap = (\(i,t,_) -> (i,t)) <$> dict
              bindingMap = M.elems dict
              cxt = foldl' (\acc (idx,tyx)-> M.insert idx tyx acc) d $ (\(a,b,_) -> (a,b)) <$> M.elems dict
          binds <- traverse (\(newId,newTy,oldE) -> makeBind renameMap cxt newId newTy oldE) bindingMap
          case M.lookup targIdent renameMap of
            Just (newId,newTy) -> pure $ Left (binds,Var nullAnn newTy (Qualified ByNullSourcePos newId))
            Nothing -> throwError
                       $ MonoError d
                       $ "Couldn't inline " <> showIdent' ident <> " - identifier didn't appear in collected bindings:\n  "  <> show renameMap

          -- pure $ Left (monoBinds,exp)
    else throwError $ MonoError d "Imports aren't supported!"
 where
   makeBind :: Map Ident (Ident,SourceType) -> Context -> Ident -> SourceType -> Expr Ann -> Monomorphizer (Bind Ann)
   makeBind renameDict depth newIdent t e = trace ("makeBind: " <> showIdent' newIdent) $ do
     e' <- updateFreeVars renameDict depth  <$> monomorphizeWithType t depth e
     pure $ NonRec nullAnn  newIdent e'

   -- Find a declaration body in the *module* scope
   findDeclarationBody :: Ident -> Monomorphizer (Maybe (Expr Ann))
   findDeclarationBody nm = go <$> getModBinds
    where
      go :: [Bind Ann] -> Maybe (Expr Ann)
      go [] = Nothing
      go (b:bs) = case b of
        NonRec _  nm' e -> if nm' == nm then Just e else go bs
        Rec xs -> case find (\x -> snd (fst x) == nm) xs of
          Nothing -> go bs
          Just ((_,_),e) -> Just e

   {- RECURSIVE BINDINGS

      First, we need to walk the target expression and collect a list of all of the used
      bindings and the type that they must be when monomorphized, and the new identifier for their
      monomorphized/instantiated version. (We *don't* change anything here)
   -}
   collectMany :: Map Ident (Ident, SourceType, Expr Ann) -> PurusType -> Context -> [Expr Ann] -> Monomorphizer (Map Ident (Ident, SourceType, Expr Ann))
   collectMany acc _ _ [] = trace "collectMany" $ pure acc
   collectMany acc t dx (x:xs) = do
     xBinds <- collectRecBinds acc t dx x
     let acc' = acc <> xBinds
     collectMany acc' t d xs

   collectRecFieldBinds :: Map Ident (Ident, SourceType, Expr Ann)
                        -> M.Map PSString (RowListItem SourceAnn)
                        -> [(PSString, Expr Ann)]
                        -> Monomorphizer (Map Ident (Ident, SourceType, Expr Ann))
   collectRecFieldBinds visited _ [] =  pure visited
   collectRecFieldBinds visited cxt ((lbl,e):rest) = trace "collectRecFieldBinds" $ do
     RowListItem{..} <- note d ("No type for field with label " <> T.unpack (prettyPrintString lbl) <> " when collecting record binds")
                          $ M.lookup lbl cxt
     this <- collectRecBinds visited rowListType d e
     collectRecFieldBinds (visited <> this) cxt rest

   collectFun :: Map Ident (Ident, SourceType, Expr Ann)
              -> Context
              -> Expr Ann
              -> [SourceType]
              -> Monomorphizer (Map Ident (Ident, SourceType, Expr Ann))
   collectFun visited _ e [t] = trace ("collectFun FIN:\n  " <> renderExprStr e <> " :: " <> prettyTypeStr t)  $ do
     rest <- collectRecBinds visited t d e
     pure $ visited <> rest
   collectFun visited dx e@(Abs _ (ForAll{}) idx body'') (t:ts) = trace ("collectFun:\n  " <> renderExprStr e <> "\n  " <> prettyTypeStr t <> "\n" <> show ts)  $ do
      let body' = updateVarTy d idx t body''
          cxt   = M.insert idx t dx
      collectFun visited cxt body' ts

   collectFun visited dx (Var _ _ (Qualified (ByModuleName _) nm)) (t:ts)= trace ("collectFun VAR: " <> showIdent' nm) $ do
     case M.lookup nm visited of
       Nothing -> do
         let t' = foldr1 function (t:ts)
             msg =  "Couldn't find a declaration with identifier " <> showIdent' nm <> " to inline as " <> prettyTypeStr t
         declBody <- note dx msg =<< findDeclarationBody nm
         freshNm <- freshen nm
         let visited' = M.insert nm (freshNm,t',declBody) visited
         collectRecBinds visited' t' d declBody
       Just _ -> pure visited

   collectFun _ dx e _ = throwError $ MonoError dx $ "Unexpected expression in collectFun:\n  " <> renderExprStr e


   collectRecBinds :: Map Ident (Ident,SourceType,Expr Ann) -> PurusType -> Context -> Expr Ann -> Monomorphizer (Map Ident (Ident,SourceType,Expr Ann))
   collectRecBinds visited t dx e = trace ("collectRecBinds:\n  " <> renderExprStr e <> "\n  " <> prettyTypeStr t) $ case e of
     Literal _ _ (ArrayLiteral arr) -> trace "crbARRAYLIT" $ case t of
       ArrayT inner -> do
         innerBinds <- collectMany visited inner dx  arr
         pure $ visited <> innerBinds
       _ -> throwError $ MonoError dx ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not an Array type")
     Literal _ _ (ObjectLiteral fs) -> trace "crbOBJLIT" $ case t of
         RecordT fields -> do
           let fieldMap = mkFieldMap fields
           innerBinds <- collectRecFieldBinds visited fieldMap fs
           pure $ visited <> innerBinds
         _ -> throwError $ MonoError dx ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not a Record type")
     Literal{}  -> trace "crbLIT" $ pure visited
     Constructor{} -> trace "crbCTOR" $ pure visited
     ObjectUpdate _ _ _ _ updateFields -> trace "crbOBJUPDATE" $ case t of
        RecordT fields -> do
          let fieldMap = mkFieldMap fields
          -- idk. do we need to do something to the original expression or is this always sufficient?
          innerBinds <- collectRecFieldBinds visited fieldMap updateFields
          pure $ visited <> innerBinds
        _ -> throwError $ MonoError dx ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not a Record type")
     Accessor{} -> trace "crbACCSR" $ pure visited -- idk. given (x.a :: t) we can't say what x is
     absE@(Abs{}) -> trace ("crbABS TOARGS: " <> prettyTypeStr t) $ collectFun visited dx absE (toArgs t)
     app@(App _ _ _ e2) -> trace "crbAPP" $ do
       (f,args) <-  note dx ("Not an App: " <> renderExprStr app) $ analyzeApp app
       let types = (exprType <$> args) <> [t]
       funBinds' <- collectFun visited dx f types  -- collectRecBinds visited funTy d e1
       let funBinds = visited <> funBinds'
       argBinds <- collectRecBinds funBinds (head types) dx  e2
       pure $ funBinds <> argBinds
     Var _ _ (Qualified (ByModuleName _) nm) -> trace ("crbVAR: " <> showIdent' nm)  $ case M.lookup nm visited of
       Nothing -> findDeclarationBody nm >>= \case
         Nothing -> throwError $ MonoError dx  $ "No declaration correponding to name " <> showIdent' nm <> " found in the module"
         Just ex -> do
           freshNm <- freshen nm
           let this = (freshNm,t,ex)
           pure $ M.insert nm this visited
       Just _ -> pure visited  -- might not be right, might need to check that the types are equal? ugh keeping track of scope is a nightmare
     Var _ _ (Qualified _ nm) -> trace ("crbVAR_: " <> showIdent' nm) $ pure visited
     Case _ _ _  alts -> trace "crbCASE" $ do
       let flatAlts = concatMap extractAndFlattenAlts alts
       aInner <- collectMany visited t dx flatAlts
       pure $ visited <> aInner
     Let _ _ _ ex ->
       -- not sure abt this
       collectRecBinds visited t dx ex



extractAndFlattenAlts :: CaseAlternative Ann -> [Expr Ann]
extractAndFlattenAlts (CaseAlternative _ res) = case res of
  Left xs -> concatMap (\(x,y) -> [x,y]) xs
  Right x -> [x]


-- I think this one actually requires case analysis? dunno how to do it w/ the lenses in less space (w/o having prisms for types which seems dumb?)
-- This *forces* the expression to have the provided type (and returns nothing if it cannot safely do that)
monomorphizeWithType :: PurusType -> Context -> Expr Ann -> Monomorphizer (Expr Ann)
monomorphizeWithType  t d expr
  | expr ^. eType == t = pure expr
  | otherwise = trace ("monomorphizeWithType:\n  " <> renderExprStr expr <> "\n  " <> prettyTypeStr t) $ case expr of
      Literal ann _ (ArrayLiteral arr) -> case t of
        ArrayT inner -> Literal ann t . ArrayLiteral <$> traverse (monomorphizeWithType inner d)  arr
        _ -> throwError $ MonoError d ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not a Record type")
      Literal ann _ (ObjectLiteral fs) -> case t of
        RecordT fields -> do
          let fieldMap = mkFieldMap fields
          Literal ann t . ObjectLiteral <$> monomorphizeFieldsWithTypes fieldMap  fs
        _ -> throwError $ MonoError d ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not a Record type")
      Literal ann _ lit -> pure $ Literal ann t lit
      Constructor ann _ tName cName fs -> pure $ Constructor ann t tName cName fs
      ObjectUpdate a _ orig copyFields updateFields -> case t of
        RecordT fields -> do
          let fieldMap = mkFieldMap fields
          -- idk. do we need to do something to the original expression or is this always sufficient?
          updateFields' <- monomorphizeFieldsWithTypes fieldMap updateFields
          pure $ ObjectUpdate a t orig copyFields updateFields'
        _ -> throwError $ MonoError d ("Failed to collect recursive binds: " <> prettyTypeStr t <> " is not a Record type")
      Accessor ann _ str e ->  pure $ Accessor ann t str e-- idk?
      fun@(Abs _ _ ident body) -> trace ("MTABs:\n  " <> renderExprStr fun <> " :: " <> prettyTypeStr t) $ do
        case t of
          (a :-> b) -> case nameShadows d ident of
            False -> do
              let cxt = M.insert ident a d
              body' <- monomorphizeWithType b cxt $ updateVarTy cxt ident a body
              pure $ Abs nullAnn t ident  body'
            True -> do
              freshIdent <- freshen ident
              let body' = renameBoundVar ident freshIdent d $ updateVarTy d ident a body
                  cxt   = M.insert freshIdent a d
              body'' <- monomorphizeWithType b cxt body'
              pure $ Abs nullAnn t freshIdent body''

          _ -> throwError $ MonoError d "Abs isn't a function"

      app@(App a _ _ e2) -> trace ("MTAPP:\n  " <> renderExprStr app) $  do
        (f,args) <- note d ("Not an app: " <> renderExprStr app) $ analyzeApp app
        let types = (exprType <$> args) <> [t]
        traceM $ renderExprStr f
        e1' <- either (uncurry gLet) id <$> handleFunction d f types
        pure $ App a t e1' e2
      Var a _ nm -> pure $ Var a t nm -- idk
      Case a _ scrut alts ->
        let f = monomorphizeWithType  t d
            goAlt :: CaseAlternative Ann -> Monomorphizer (CaseAlternative Ann)
            goAlt (CaseAlternative binders results) =
              CaseAlternative binders <$> bitraverse (traverse (bitraverse f f)) f results
        in Case a t scrut <$> traverse goAlt alts
      Let a _ binds e -> Let a t binds <$> monomorphizeWithType t d e
  where
    monomorphizeFieldsWithTypes :: M.Map PSString (RowListItem SourceAnn) -> [(PSString, Expr Ann)] -> Monomorphizer [(PSString, Expr Ann)]
    monomorphizeFieldsWithTypes _ [] = pure []
    monomorphizeFieldsWithTypes cxt ((lbl,e):rest) = do
      RowListItem{..} <- note d ("No type for field with label " <> T.unpack (prettyPrintString lbl) <> " when monomorphizing record")
                         $ M.lookup lbl cxt
      rest' <- monomorphizeFieldsWithTypes cxt rest
      e' <- monomorphizeWithType  rowListType d e
      pure $ (lbl,e') : rest'

mkFieldMap :: SourceType -> M.Map PSString (RowListItem SourceAnn)
mkFieldMap fs = M.fromList $ (\x -> (runLabel (rowListLabel x),x)) <$> (fst . rowToList $ fs)

toArgs :: SourceType -> [SourceType]
toArgs = \case
  (a :-> b) -> a : toArgs b
  other -> [other]
