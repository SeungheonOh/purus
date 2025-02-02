module Command.Compile  where

import Prelude

import Control.Applicative (Alternative(..))
import Control.Monad (when)
import Data.Aeson qualified as A
import Data.Bool (bool)
import Data.ByteString.Lazy.UTF8 qualified as LBU8
import Data.List (intercalate, (\\))
import Data.Map qualified as M
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Traversable (for)
import Language.PureScript qualified as P
import Language.PureScript.CST qualified as CST
import Language.PureScript.Errors.JSON (JSONResult(..), toJSONErrors)
import Language.PureScript.Make (buildMakeActions, inferForeignModules, runMake)
import Options.Applicative qualified as Opts
import System.Console.ANSI qualified as ANSI
import System.Exit (exitSuccess, exitFailure)
import System.Directory (getCurrentDirectory)
import System.FilePath.Glob (glob)
import System.IO (hPutStr, hPutStrLn, stderr, stdout)
import System.IO.UTF8 (readUTF8FilesT)

data PSCMakeOptions = PSCMakeOptions
  { pscmInput        :: [FilePath]
  , pscmExclude      :: [FilePath]
  , pscmOutputDir    :: FilePath
  , pscmOpts         :: P.Options
  , pscmUsePrefix    :: Bool
  , pscmJSONErrors   :: Bool
  } deriving Show

-- | Arguments: verbose, use JSON, warnings, errors
printWarningsAndErrors :: Bool -> Bool -> [(FilePath, T.Text)] -> P.MultipleErrors -> Either P.MultipleErrors a -> IO ()
printWarningsAndErrors verbose False files warnings errors = do
  pwd <- getCurrentDirectory
  cc <- bool Nothing (Just P.defaultCodeColor) <$> ANSI.hSupportsANSI stdout
  let ppeOpts = P.defaultPPEOptions { P.ppeCodeColor = cc, P.ppeFull = verbose, P.ppeRelativeDirectory = pwd, P.ppeFileContents = files }
  when (P.nonEmpty warnings) $
    putStrLn (P.prettyPrintMultipleWarnings ppeOpts warnings)
  case errors of
    Left errs -> do
      putStrLn (P.prettyPrintMultipleErrors ppeOpts errs)
      exitFailure
    Right _ -> return ()
printWarningsAndErrors verbose True files warnings errors = do
  putStrLn . LBU8.toString . A.encode $
    JSONResult (toJSONErrors verbose P.Warning files warnings)
               (either (toJSONErrors verbose P.Error files) (const []) errors)
  either (const exitFailure) (const (return ())) errors

compile :: PSCMakeOptions -> IO ()
compile PSCMakeOptions{..} = do
  included <- globWarningOnMisses warnFileTypeNotFound pscmInput
  excluded <- globWarningOnMisses warnFileTypeNotFound pscmExclude
  let input = included \\ excluded
  when (null input) $ do
    hPutStr stderr $ unlines [ "purs compile: No input files."
                             , "Usage: For basic information, try the `--help' option."
                             ]
    exitFailure
  moduleFiles <- readUTF8FilesT input
  (makeErrors, makeWarnings) <- runMake pscmOpts $ do
    ms <- CST.parseModulesFromFiles id moduleFiles
    let filePathMap = M.fromList $ map (\(fp, pm) -> (P.getModuleName $ CST.resPartial pm, Right fp)) ms
    foreigns <- inferForeignModules filePathMap
    let makeActions = buildMakeActions pscmOutputDir filePathMap foreigns pscmUsePrefix
    P.make makeActions (map snd ms)
  printWarningsAndErrors (P.optionsVerboseErrors pscmOpts) pscmJSONErrors moduleFiles makeWarnings makeErrors
  exitSuccess

compileForTests :: PSCMakeOptions -> IO ()
compileForTests PSCMakeOptions{..} = do
  included <- globWarningOnMisses warnFileTypeNotFound pscmInput
  excluded <- globWarningOnMisses warnFileTypeNotFound pscmExclude
  let input = included \\ excluded
  if (null input) then  do
    hPutStr stderr $ unlines [ "purs compile: No input files."
                             , "Usage: For basic information, try the `--help' option."
                             ]
  else do
    moduleFiles <- readUTF8FilesT input
    (makeErrors, makeWarnings) <- runMake pscmOpts $ do
      ms <- CST.parseModulesFromFiles id moduleFiles
      let filePathMap = M.fromList $ map (\(fp, pm) -> (P.getModuleName $ CST.resPartial pm, Right fp)) ms
      foreigns <- inferForeignModules filePathMap
      let makeActions = buildMakeActions pscmOutputDir filePathMap foreigns pscmUsePrefix
      P.make makeActions (map snd ms)
    printWarningsAndErrors (P.optionsVerboseErrors pscmOpts) pscmJSONErrors moduleFiles makeWarnings makeErrors

warnFileTypeNotFound :: String -> IO ()
warnFileTypeNotFound = hPutStrLn stderr . ("purs compile: No files found using pattern: " ++)

globWarningOnMisses :: (String -> IO ()) -> [FilePath] -> IO [FilePath]
globWarningOnMisses warn = concatMapM globWithWarning
  where
  globWithWarning pattern' = do
    paths <- glob pattern'
    when (null paths) $ warn pattern'
    return paths
  concatMapM f = fmap concat . mapM f

inputFile :: Opts.Parser FilePath
inputFile = Opts.strArgument $
     Opts.metavar "FILE"
  <> Opts.help "The input .purs file(s)."

excludedFiles :: Opts.Parser FilePath
excludedFiles = Opts.strOption $
     Opts.short 'x'
  <> Opts.long "exclude-files"
  <> Opts.help "Glob of .purs files to exclude from the supplied files."

outputDirectory :: Opts.Parser FilePath
outputDirectory = Opts.strOption $
     Opts.short 'o'
  <> Opts.long "output"
  <> Opts.value "output"
  <> Opts.showDefault
  <> Opts.help "The output directory"

comments :: Opts.Parser Bool
comments = Opts.switch $
     Opts.short 'c'
  <> Opts.long "comments"
  <> Opts.help "Include comments in the generated code"

verboseErrors :: Opts.Parser Bool
verboseErrors = Opts.switch $
     Opts.short 'v'
  <> Opts.long "verbose-errors"
  <> Opts.help "Display verbose error messages"

noPrefix :: Opts.Parser Bool
noPrefix = Opts.switch $
     Opts.short 'p'
  <> Opts.long "no-prefix"
  <> Opts.help "Do not include comment header"

jsonErrors :: Opts.Parser Bool
jsonErrors = Opts.switch $
     Opts.long "json-errors"
  <> Opts.help "Print errors to stderr as JSON"

codegenTargets :: Opts.Parser [P.CodegenTarget]
codegenTargets = Opts.option targetParser $
     Opts.short 'g'
  <> Opts.long "codegen"
  <> Opts.value [P.CoreFn]
  <> Opts.help
      ( "Specifies comma-separated codegen targets to include. "
      <> targetsMessage
      <> " The default target is 'coreFn', but if this option is used only the targets specified will be used."
      )

targetsMessage :: String
targetsMessage = "Accepted codegen targets are '" <> intercalate "', '" (M.keys P.codegenTargets) <> "'."

targetParser :: Opts.ReadM [P.CodegenTarget]
targetParser =
  Opts.str >>= \s ->
    for (T.split (== ',') s)
      $ maybe (Opts.readerError targetsMessage) pure
      . flip M.lookup P.codegenTargets
      . T.unpack
      . T.strip

options :: Opts.Parser P.Options
options =
  P.Options
    <$> verboseErrors
    <*> (not <$> comments)
    <*> (handleTargets <$> codegenTargets)
  where
    -- Ensure that the JS target is included if sourcemaps are
    handleTargets :: [P.CodegenTarget] -> S.Set P.CodegenTarget
    handleTargets ts = S.fromList ts

pscMakeOptions :: Opts.Parser PSCMakeOptions
pscMakeOptions = PSCMakeOptions <$> many inputFile
                                <*> many excludedFiles
                                <*> outputDirectory
                                <*> options
                                <*> (not <$> noPrefix)
                                <*> jsonErrors

command :: Opts.Parser (IO ())
command = compile <$> (Opts.helper <*> pscMakeOptions)
