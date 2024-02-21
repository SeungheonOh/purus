-- |
-- Read the core functional representation from JSON format
--

module Language.PureScript.CoreFn.FromJSON
  ( moduleFromJSON
  , parseVersion'
  ) where

import Prelude

import Control.Applicative ((<|>))

import Data.Aeson (FromJSON(..), Object, Value(..), withObject, withText, (.:))
import Data.Aeson.Types (Parser, listParser)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Version (Version, parseVersion)

import Language.PureScript.AST.SourcePos (SourceSpan(..))
import Language.PureScript.AST.Literals (Literal(..))
import Language.PureScript.CoreFn.Ann (Ann)
import Language.PureScript.CoreFn (Bind(..), Binder(..), CaseAlternative(..), ConstructorType(..), Expr(..), Guard, Meta(..), Module(..))
import Language.PureScript.Names (Ident(..), ModuleName(..), ProperName(..), Qualified(..), QualifiedBy(..), unusedIdent)
import Language.PureScript.PSString (PSString)

import Language.PureScript.Types ()

import Text.ParserCombinators.ReadP (readP_to_S)

-- dunno how to work around the orphan
instance FromJSON (Module Ann) where
  parseJSON = fmap snd .  moduleFromJSON

parseVersion' :: String -> Maybe Version
parseVersion' str =
  case filter (null . snd) $ readP_to_S parseVersion str of
    [(vers, "")] -> Just vers
    _            -> Nothing

constructorTypeFromJSON :: Value -> Parser ConstructorType
constructorTypeFromJSON v = do
  t <- parseJSON v
  case t of
    "ProductType" -> return ProductType
    "SumType"     -> return SumType
    _             -> fail ("not recognized ConstructorType: " ++ T.unpack t)

metaFromJSON :: Value -> Parser (Maybe Meta)
metaFromJSON Null = return Nothing
metaFromJSON v = withObject "Meta" metaFromObj v
  where
    metaFromObj o = do
      type_ <- o .: "metaType"
      case type_ of
        "IsConstructor" -> isConstructorFromJSON o
        "IsNewtype"     -> return $ Just IsNewtype
        "IsTypeClassConstructor"
                        -> return $ Just IsTypeClassConstructor
        "IsForeign"     -> return $ Just IsForeign
        "IsWhere"       -> return $ Just IsWhere
        "IsSyntheticApp"
                        -> return $ Just IsSyntheticApp
        _               -> fail ("not recognized Meta: " ++ T.unpack type_)

    isConstructorFromJSON o = do
      ct <- o .: "constructorType" >>= constructorTypeFromJSON
      is <- o .: "identifiers" >>= listParser identFromJSON
      return $ Just (IsConstructor ct is)

annFromJSON :: FilePath -> Value -> Parser Ann
annFromJSON modulePath = withObject "Ann" annFromObj
  where
  annFromObj o = do
    ss <- o .: "sourceSpan" >>= sourceSpanFromJSON modulePath
    mm <- o .: "meta" >>= metaFromJSON
    return (ss, [], mm)

sourceSpanFromJSON :: FilePath -> Value -> Parser SourceSpan
sourceSpanFromJSON modulePath = withObject "SourceSpan" $ \o ->
  SourceSpan modulePath <$>
    o .: "start" <*>
    o .: "end"

literalFromJSON :: (Value -> Parser a) -> Value -> Parser (Literal a)
literalFromJSON t = withObject "Literal" literalFromObj
  where
  literalFromObj o = do
    type_ <- o .: "literalType" :: Parser Text
    case type_ of
      "IntLiteral"      -> NumericLiteral . Left <$> o .: "value"
      "NumberLiteral"   -> NumericLiteral . Right <$> o .: "value"
      "StringLiteral"   -> StringLiteral <$> o .: "value"
      "CharLiteral"     -> CharLiteral <$> o .: "value"
      "BooleanLiteral"  -> BooleanLiteral <$> o .: "value"
      "ArrayLiteral"    -> parseArrayLiteral o
      "ObjectLiteral"   -> parseObjectLiteral o
      _                 -> fail ("error parsing Literal: " ++ show o)

  parseArrayLiteral o = do
    val <- o .: "value"
    as <- mapM t (V.toList val)
    return $ ArrayLiteral as

  parseObjectLiteral o = do
    val <- o .: "value"
    ObjectLiteral <$> recordFromJSON t val

identFromJSON :: Value -> Parser Ident
identFromJSON = withText "Ident" $ \case
  ident | ident == unusedIdent -> pure UnusedIdent 
        | otherwise -> pure $ Ident ident 

properNameFromJSON :: Value -> Parser (ProperName a)
properNameFromJSON = fmap ProperName . parseJSON

qualifiedFromJSON :: (Text -> a) -> Value -> Parser (Qualified a)
qualifiedFromJSON f = withObject "Qualified" qualifiedFromObj
  where
  qualifiedFromObj o =
    qualifiedByModuleFromObj o <|> qualifiedBySourcePosFromObj o
  qualifiedByModuleFromObj o = do
    mn <- o .: "moduleName" >>= moduleNameFromJSON
    i  <- o .: "identifier" >>= withText "Ident" (return . f)
    pure $ Qualified (ByModuleName mn) i
  qualifiedBySourcePosFromObj o = do
    ss <- o .: "sourcePos"
    i  <- o .: "identifier" >>= withText "Ident" (return . f)
    pure $ Qualified (BySourcePos ss) i

moduleNameFromJSON :: Value -> Parser ModuleName
moduleNameFromJSON v = ModuleName . T.intercalate "." <$> listParser parseJSON v

moduleFromJSON :: Value -> Parser (Version, Module Ann)
moduleFromJSON = withObject "Module" moduleFromObj
  where
  moduleFromObj o = do
    version <- o .: "builtWith" >>= versionFromJSON
    moduleName <- o .: "moduleName" >>= moduleNameFromJSON
    modulePath <- o .: "modulePath"
    moduleSourceSpan <- o .: "sourceSpan" >>= sourceSpanFromJSON modulePath
    moduleImports <- o .: "imports" >>= listParser (importFromJSON modulePath)
    moduleExports <- o .: "exports" >>= listParser identFromJSON
    moduleReExports <- o .: "reExports" >>= reExportsFromJSON
    moduleDecls <- o .: "decls" >>= listParser (bindFromJSON modulePath)
    moduleForeign <- o .: "foreign" >>= listParser identFromJSON
    moduleComments <- o .: "comments" >>= listParser parseJSON
    return (version, Module {..})

  versionFromJSON :: String -> Parser Version
  versionFromJSON v =
    case parseVersion' v of
      Just r -> return r
      Nothing -> fail "failed parsing purs version"

  importFromJSON :: FilePath -> Value -> Parser (Ann, ModuleName)
  importFromJSON modulePath = withObject "Import"
    (\o -> do
      ann <- o .: "annotation" >>= annFromJSON modulePath
      mn  <- o .: "moduleName" >>= moduleNameFromJSON
      return (ann, mn))

  reExportsFromJSON :: Value -> Parser (M.Map ModuleName [Ident])
  reExportsFromJSON = fmap (M.map (map Ident)) . parseJSON

bindFromJSON :: FilePath -> Value -> Parser (Bind Ann)
bindFromJSON modulePath = withObject "Bind" bindFromObj
  where
  bindFromObj :: Object -> Parser (Bind Ann)
  bindFromObj o = do
    type_ <- o .: "bindType" :: Parser Text
    case type_ of
      "NonRec"  -> (uncurry . uncurry) NonRec <$> bindFromObj' o
      "Rec"     -> Rec <$> (o .: "binds" >>= listParser (withObject "Bind" bindFromObj'))
      _         -> fail ("not recognized bind type \"" ++ T.unpack type_ ++ "\"")
        
  bindFromObj' :: Object -> Parser ((Ann, Ident), Expr Ann)
  bindFromObj' o = do
    a <- o .: "annotation" >>= annFromJSON modulePath
    i <- o .: "identifier" >>= identFromJSON
    e <- o .: "expression" >>= exprFromJSON modulePath
    return ((a, i), e)

recordFromJSON :: (Value -> Parser a) -> Value -> Parser [(PSString, a)]
recordFromJSON p = listParser parsePair
  where
  parsePair v = do
    (l, v') <- parseJSON v :: Parser (PSString, Value)
    a <- p v'
    return (l, a)

exprFromJSON :: FilePath -> Value -> Parser (Expr Ann)
exprFromJSON modulePath = withObject "Expr" exprFromObj
  where
  exprFromObj o = do
    kind_ <- o .: "kind"
    case kind_ of
      "Var"           -> varFromObj o
      "Literal"       -> literalExprFromObj o
      "Constructor"   -> constructorFromObj o
      "Accessor"      -> accessorFromObj o
      "ObjectUpdate"  -> objectUpdateFromObj o
      "Abs"           -> absFromObj o
      "App"           -> appFromObj o
      "Case"          -> caseFromObj o
      "Let"           -> letFromObj o
      _               -> fail ("not recognized expression kind: \"" ++ T.unpack kind_ ++ "\"")

  tyFromObj o = o .: "type" >>= parseJSON

  varFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty <- tyFromObj o
    qi <- o .: "value" >>= qualifiedFromJSON Ident
    return $ Var ann ty qi

  literalExprFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty <- tyFromObj o
    lit <- o .: "value" >>= literalFromJSON (exprFromJSON modulePath)
    return $ Literal ann ty lit

  constructorFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    tyn <- o .: "typeName" >>= properNameFromJSON
    ty  <- tyFromObj o
    con <- o .: "constructorName" >>= properNameFromJSON
    is  <- o .: "fieldNames" >>= listParser identFromJSON
    return $ Constructor ann ty tyn con is

  accessorFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty <- tyFromObj o
    f   <- o .: "fieldName"
    e <- o .: "expression" >>= exprFromJSON modulePath
    return $ Accessor ann ty f e

  objectUpdateFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty <- tyFromObj o
    e   <- o .: "expression" >>= exprFromJSON modulePath
    copy <- o .: "copy" >>= parseJSON
    us  <- o .: "updates" >>= recordFromJSON (exprFromJSON modulePath)
    return $ ObjectUpdate ann ty e copy us

  absFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty  <- tyFromObj o
    idn <- o .: "argument" >>= identFromJSON
    e   <- o .: "body" >>= exprFromJSON modulePath
    return $ Abs ann ty idn e

  appFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty  <- tyFromObj o
    e   <- o .: "abstraction" >>= exprFromJSON modulePath
    e'  <- o .: "argument" >>= exprFromJSON modulePath
    return $ App ann ty e e'

  caseFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty  <- tyFromObj o
    cs  <- o .: "caseExpressions" >>= listParser (exprFromJSON modulePath)
    cas <- o .: "caseAlternatives" >>= listParser (caseAlternativeFromJSON modulePath)
    return $ Case ann ty cs cas

  letFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    ty  <- tyFromObj o
    bs  <- o .: "binds" >>= listParser (bindFromJSON modulePath)
    e   <- o .: "expression" >>= exprFromJSON modulePath
    return $ Let ann ty bs e

caseAlternativeFromJSON :: FilePath -> Value -> Parser (CaseAlternative Ann)
caseAlternativeFromJSON modulePath = withObject "CaseAlternative" caseAlternativeFromObj
  where
    caseAlternativeFromObj o = do
      bs <- o .: "binders" >>= listParser (binderFromJSON modulePath)
      isGuarded <- o .: "isGuarded"
      if isGuarded
        then do
          es <- o .: "expressions" >>= listParser parseResultWithGuard
          return $ CaseAlternative bs (Left es)
        else do
          e <- o .: "expression" >>= exprFromJSON modulePath
          return $ CaseAlternative bs (Right e)

    parseResultWithGuard :: Value -> Parser (Guard Ann, Expr Ann)
    parseResultWithGuard = withObject "parseCaseWithGuards" $
      \o -> do
        g <- o .: "guard" >>= exprFromJSON modulePath
        e <- o .: "expression" >>= exprFromJSON modulePath
        return (g, e)

binderFromJSON :: FilePath -> Value -> Parser (Binder Ann)
binderFromJSON modulePath = withObject "Binder" binderFromObj
  where
  binderFromObj o = do
    type_ <- o .: "binderType"
    case type_ of
      "NullBinder"        -> nullBinderFromObj o
      "VarBinder"         -> varBinderFromObj o
      "LiteralBinder"     -> literalBinderFromObj o
      "ConstructorBinder" -> constructorBinderFromObj o
      "NamedBinder"       -> namedBinderFromObj o
      _                   -> fail ("not recognized binder: \"" ++ T.unpack type_ ++ "\"")


  nullBinderFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    return $ NullBinder ann

  varBinderFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    idn <- o .: "identifier" >>= identFromJSON
    return $ VarBinder ann idn

  literalBinderFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    lit <- o .: "literal" >>= literalFromJSON (binderFromJSON modulePath)
    return $ LiteralBinder ann lit

  constructorBinderFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    tyn <- o .: "typeName" >>= qualifiedFromJSON ProperName
    con <- o .: "constructorName" >>= qualifiedFromJSON ProperName
    bs  <- o .: "binders" >>= listParser (binderFromJSON modulePath)
    return $ ConstructorBinder ann tyn con bs

  namedBinderFromObj o = do
    ann <- o .: "annotation" >>= annFromJSON modulePath
    n   <- o .: "identifier" >>= identFromJSON
    b   <- o .: "binder" >>= binderFromJSON modulePath
    return $ NamedBinder ann n b
