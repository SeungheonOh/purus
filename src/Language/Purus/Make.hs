module Language.Purus.Make where

import Prelude

import Control.Exception (throwIO)

import Data.Text (Text)
import Data.Text qualified as T

import Data.Map qualified as M
import Data.Set qualified as S

import Data.Function (on)

import Data.List (sortBy, stripPrefix, groupBy, foldl', delete)
import Data.Foldable (foldrM)

import System.FilePath
    ( makeRelative, (</>), takeDirectory, takeExtensions )

import Language.PureScript.CoreFn.Ann ( Ann )
import Language.PureScript.CoreFn.Module ( Module(..) )
import Language.PureScript.CoreFn.Expr ( Bind, PurusType )
import Language.PureScript.Names
    ( runIdent, Ident(Ident), runModuleName, ModuleName(..) )

import Language.Purus.Pipeline.CompileToPIR.Eval 
import Language.Purus.Pipeline.DesugarCore ( desugarCoreModule )
import Language.Purus.Pipeline.Lift ( lift )
import Language.Purus.Pipeline.Inline ( inline )
import Language.Purus.Pipeline.Instantiate ( instantiateTypes, applyPolyRowArgs )
import Language.Purus.Pipeline.DesugarObjects
    ( desugarObjects, desugarObjectsInDatatypes )
import Language.Purus.Pipeline.GenerateDatatypes
    ( generateDatatypes )
import Language.Purus.Pipeline.EliminateCases ( eliminateCases )
import Language.Purus.Pipeline.CompileToPIR ( compileToPIR )
import Language.Purus.Pipeline.Monad
    ( globalScope,
      runCounter,
      runDesugarCore,
      runInline,
      runPlutusContext,
      CounterT(runCounterT),
      DesugarCore )
import Language.Purus.Prim.Data (primDataPS)
import Language.Purus.Pretty.Common (docString, prettyStr)
import Language.Purus.Types ( PIRTerm, initDatatypeDict )
import Language.Purus.IR.Utils ( foldBinds, IR_Decl )
import Language.Purus.Utils
    ( decodeModuleIO, findDeclBodyWithIndex )

import Control.Monad.State ( evalStateT )
import Control.Monad.Except ( MonadError(throwError) )

import Control.Lens.Combinators(folded)
import Control.Lens.Operators ( (^?))
import Control.Lens ( At(at) )

import Algebra.Graph.AdjacencyMap ( stars )
import Algebra.Graph.AdjacencyMap.Algorithm (topSort)

import System.FilePath.Glob qualified as Glob

import Debug.Trace (traceM)

import PlutusIR.Core.Instance.Pretty.Readable ( prettyPirReadable )

{-
decodeModuleIR :: FilePath -> IO (Module IR_Decl SourceType SourceType Ann, (Int, M.Map Ident Int))
decodeModuleIR path = do
  myMod <- decodeModuleIO path
  case desugarCoreModule myMod of
    Left err -> throwIO $ userError err
    Right myModIR -> pure myModIR

testDesugarObjects :: FilePath -> Text -> IO (Exp WithoutObjects Ty (Vars Ty))
testDesugarObjects path decl = do
  (myMod, ds) <- decodeModuleIR path
  Just myDecl <- pure . fmap snd $ findDeclBody decl myMod
  case runMonomorphize myMod [] (toExp myDecl) of
    Left (MonoError msg) -> throwIO $ userError $ "Couldn't monomorphize " <> T.unpack decl <> "\nReason:\n" <> msg
    Right body -> case evalStateT (tryConvertExpr body) ds of
      Left convertErr -> throwIO $ userError convertErr
      Right e -> do
        putStrLn (ppExp e)
        pure e

prepPIR ::
  FilePath ->
  Text ->
  IO (Exp WithoutObjects Ty (Vars Ty), Datatypes Kind Ty)
prepPIR path decl = do
  (myMod@Module {..}, ds) <- decodeModuleIR path

  desugaredExpr <- case snd <$> findDeclBody decl myMod of
    Nothing -> throwIO $ userError "findDeclBody"
    Just expr -> pure expr
  case runMonomorphize myMod [] (toExp desugaredExpr) of
    Left (MonoError msg) ->
      throwIO $
        userError $
          "Couldn't monomorphize "
            <> T.unpack (runModuleName moduleName <> ".main")
            <> "\nReason:\n"
            <> msg
    Right body -> do
      putStrLn (ppExp body)
      case evalStateT (tryConvertExpr body) ds of
        Left convertErr -> throwIO $ userError convertErr
        Right e -> do
          moduleDataTypes' <-
            either (throwIO . userError) pure $
              bitraverseDatatypes
                tryConvertKind
                tryConvertType
                moduleDataTypes
          putStrLn $ "tryConvertExpr result:\n" <> ppExp e <> "\n" <> replicate 20 '-'
          pure (e, moduleDataTypes')
-}


{- Arguments are:
     - A CoreFn `Prim` module containing the *primitive-but-not-builtin-functions*
       (e.g. serialization and deserialization functions). This always gets processed first

     - The parsed set of CoreFn modules needed for compilation, *sorted in dependency order)
       (e.g. so that the module containing the `main` function comes *last* and all depdencies
        are prior to the modules that they depend upon)

     - The name of the module containing the main function

     - The name of the main function
-}

note :: MonadError String m => String -> Maybe a -> m a
note msg = \case
  Nothing -> throwError msg
  Just x  -> pure x

compile :: Module (Bind Ann) PurusType PurusType Ann
        -> [Module (Bind Ann) PurusType PurusType Ann]
        -> ModuleName
        -> Ident
        -> Either String PIRTerm
compile primModule orderedModules mainModuleName mainFunctionName
  = evalStateT (runCounterT go) 0
 where
   desugarCoreModules :: Module (Bind Ann) PurusType PurusType Ann
                      -> [Module (Bind Ann) PurusType PurusType Ann]
                      -> DesugarCore (Module IR_Decl PurusType PurusType Ann)
   desugarCoreModules prim rest = do
     desugaredPrim <- desugarCoreModule primDataPS  mempty prim
     loop desugaredPrim rest
    where
      loop here [] = pure here
      loop here (r:rs) = do
        let hereDatatypes = moduleDataTypes here
            hereDecls     = moduleDecls here
        r' <- desugarCoreModule hereDatatypes hereDecls r
        loop r' rs
   go :: CounterT (Either String) PIRTerm
   go = do
     (summedModule,dsCxt) <- runDesugarCore $ desugarCoreModules primModule orderedModules
     let traceBracket msg = traceM ("\n" <> msg <> "\n")
         decls = moduleDecls summedModule
         declIdentsSet = foldBinds (\acc nm _ -> S.insert nm acc) S.empty decls
         couldn'tFindMain n = "Error: Could not find a main function with the name (" <> show n <> ") '"
                            <> T.unpack (runIdent mainFunctionName)
                            <> "' in module "  
                            <> T.unpack (runModuleName mainModuleName)
                            <>  "\nin declarations:\n" <> prettyStr (S.toList declIdentsSet)
     mainFunctionIx <- note (couldn'tFindMain 1) $ dsCxt ^? globalScope . at mainModuleName . folded . at mainFunctionName . folded
     traceM $ "Found main function Index: " <> show mainFunctionIx
     mainFunctionBody <- note (couldn'tFindMain 2) $ findDeclBodyWithIndex mainFunctionName mainFunctionIx decls
     traceM "Found main function body"
     inlined <- runInline summedModule $ lift (mainFunctionName,mainFunctionIx) mainFunctionBody >>= inline
     traceBracket $ "Done inlining. Result: \n" <> prettyStr inlined
     let !instantiated = applyPolyRowArgs $ instantiateTypes inlined
     traceBracket $ "Done instantiating types. Result:\n" <> prettyStr instantiated
     withoutObjects <- instantiateTypes <$> runCounter (desugarObjects instantiated)
     traceM $ "Desugared objects. Result:\n" <> prettyStr withoutObjects
     datatypes      <- runCounter $ desugarObjectsInDatatypes (moduleDataTypes summedModule)
     traceM "Desugared datatypes"
     runPlutusContext initDatatypeDict $ do
       generateDatatypes datatypes withoutObjects
       traceM "Generated PIR datatypes"
       withoutCases <- eliminateCases datatypes withoutObjects
       traceM "Eliminated case expressions. Compiling to PIR..."
       pirTerm <- compileToPIR datatypes withoutCases
       traceM . docString $ prettyPirReadable pirTerm
       pure pirTerm



modulesInDependencyOrder :: [[FilePath]] -> IO [Module (Bind Ann) PurusType PurusType Ann]
modulesInDependencyOrder (concat -> paths) = do
  modules <- traverse decodeModuleIO paths
  let modMap = foldl' (\acc m@Module{..} -> M.insert moduleName m acc) M.empty modules
      depGraph = stars . M.toList $ M.mapWithKey (\n m -> delete n . fmap snd $  moduleImports m) modMap
  case reverse <$> topSort depGraph of
    Left cyc -> throwIO . userError $ "Error: Cycles detected in module graph: " <> show cyc
    Right ordered -> do
      -- we ignore Builtin and Prim deps (b/c we add those later ourselves)
      let canResolve :: ModuleName -> Bool
          canResolve (ModuleName mn) = mn /= "Prim" && mn /= "Builtin"
      foldrM (\mn acc -> if not (canResolve mn) then pure acc else case modMap ^? at mn . folded of
                               Nothing -> throwIO . userError $ "Error: Module '" <> T.unpack (runModuleName mn) <> "' is required for compilation but could not be found"
                               Just mdl -> pure $ mdl:acc) [] ordered

getFilesToCompile :: FilePath -> IO [[FilePath]]
getFilesToCompile targdir = do
  getFiles targdir <$> testGlob targdir
  where
  -- A glob for all purs and js files within a test directory
  testGlob :: FilePath -> IO [FilePath]
  testGlob = Glob.globDir1 (Glob.compile "**/*.cfn")
  -- Groups the test files so that a top-level file can have dependencies in a
  -- subdirectory of the same name. The inner tuple contains a list of the
  -- .purs files and the .js files for the test case.
  getFiles :: FilePath -> [FilePath] -> [[FilePath]]
  getFiles baseDir
    = map (filter ((== ".cfn") . takeExtensions) . map (baseDir </>))
    . groupBy ((==) `on` extractPrefix)
    . sortBy (compare `on` extractPrefix)
    . map (makeRelative baseDir)
  -- Extracts the filename part of a .purs file, or if the file is in a
  -- subdirectory, the first part of that directory path.
  extractPrefix :: FilePath -> FilePath
  extractPrefix fp =
    let dir = takeDirectory fp
        ext = reverse ".cfn"
    in if dir == "."
       then maybe fp reverse $ stripPrefix ext $ reverse fp
       else dir

make :: FilePath -- Path to the directory containing the modules to be compiled
     -> Text     -- Name of the Main module (we'll default to Main in production but its nice to configure for testing)
     -> Text     -- Name of the `main` function we're compiling
     -> Maybe (Module (Bind Ann) PurusType PurusType Ann) -- Optional prim module to compile first. Should be required but we don't *have* it yet so atm can't be
     -> IO PIRTerm
make path mainModule mainFunction primModule =  do
  ordered <- getFilesToCompile path >>= modulesInDependencyOrder
  case (primModule,ordered) of
    (Just prim,toCompile) ->
      either (throwIO . userError) pure $ compile prim toCompile (ModuleName mainModule) (Ident mainFunction)
      -- if we don't have a prim module we treat the first module in compilation order as prim
      -- (need to do this for development/testing)
    (Nothing,m:ms) -> either (throwIO . userError) pure $ compile m ms (ModuleName mainModule) (Ident mainFunction)
    _ -> throwIO . userError $ "Error: No modules found for compilation"


-- for exploration/repl testing, this hardcodes `tests/purus/passing/Lib` as the target directory and
-- we only select the name of the main function
makeForTest :: Text -> IO PIRTerm
makeForTest main = make "tests/purus/passing/Misc" "Lib" main Nothing 

evalForTest :: Text -> IO ()
evalForTest main = makeForTest main >>= evaluateTerm >>= print 
