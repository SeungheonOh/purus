{-# LANGUAGE DoAndIfThenElse #-}

module TestCoreFn (spec) where

import Prelude

import Data.Aeson (Result(..), Value)
import Data.Aeson.Types (parse)
import Data.Map as M
import Data.Version (Version(..))

import Language.PureScript.AST.Literals (Literal(..))
import Language.PureScript.AST.SourcePos (SourcePos(..), SourceSpan(..))
import Language.PureScript.Comments (Comment(..))
import Language.PureScript.CoreFn (Ann, Bind(..), Binder(..), CaseAlternative(..), ConstructorType(..), Expr(..), Meta(..), Module(..), ssAnn)
import Language.PureScript.CoreFn.FromJSON (moduleFromJSON)
import Language.PureScript.CoreFn.ToJSON (moduleToJSON)
import Language.PureScript.Names (pattern ByNullSourcePos, Ident(..), ModuleName(..), ProperName(..), Qualified(..), QualifiedBy(..))
import Language.PureScript.PSString (mkString)
import Language.PureScript.Environment

import Test.Hspec (Spec, context, shouldBe, shouldSatisfy, specify)
import Language.PureScript.CoreFn.Desugar.Utils (purusTy)

parseModule :: Value -> Result (Version, Module Ann)
parseModule = parse moduleFromJSON

-- convert a module to its json CoreFn representation and back
parseMod :: Module Ann -> Result (Module Ann)
parseMod m =
  let v = Version [0] []
  in snd <$> parseModule (moduleToJSON v m)

isSuccess :: Result a -> Bool
isSuccess (Success _) = True
isSuccess _           = False

-- TODO: Fix
spec :: Spec
spec = pure () {-
  context "CoreFnFromJson" $ do
  let mn = ModuleName "Example.Main"
      mp = "src/Example/Main.purs"
      ss = SourceSpan mp (SourcePos 0 0) (SourcePos 0 0)
      ann = ssAnn ss

  specify "should parse version" $ do
    let v = Version [0, 13, 6] []
        m = Module ss [] mn mp [] [] M.empty [] []
        r = fst <$> parseModule (moduleToJSON v m)
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success v' -> v' `shouldBe` v

  specify "should parse an empty module" $ do
    let r = parseMod $ Module ss [] mn mp [] [] M.empty [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleName m `shouldBe` mn

  specify "should parse source span" $ do
    let r = parseMod $ Module ss [] mn mp [] [] M.empty [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleSourceSpan m `shouldBe` ss

  specify "should parse module path" $ do
    let r = parseMod $ Module ss [] mn mp [] [] M.empty [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> modulePath m `shouldBe` mp

  specify "should parse imports" $ do
    let r = parseMod $ Module ss [] mn mp [(ann, mn)] [] M.empty [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleImports m `shouldBe` [(ann, mn)]

  specify "should parse exports" $ do
    let r = parseMod $ Module ss [] mn mp [] [Ident "exp"] M.empty [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleExports m `shouldBe` [Ident "exp"]

  specify "should parse re-exports" $ do
    let r = parseMod $ Module ss [] mn mp [] [] (M.singleton (ModuleName "Example.A") [Ident "exp"]) [] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleReExports m `shouldBe` M.singleton (ModuleName "Example.A") [Ident "exp"]


  specify "should parse foreign" $ do
    let r = parseMod $ Module ss [] mn mp [] [] M.empty [Ident "exp"] []
    r `shouldSatisfy` isSuccess
    case r of
      Error _   -> return ()
      Success m -> moduleForeign m `shouldBe` [Ident "exp"]

  context "Expr" $ do
    specify "should parse literals" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "x1") $ Literal ann (purusTy tyInt) (NumericLiteral (Left 1))
                , NonRec ann (Ident "x2") $ Literal ann (purusTy tyNumber) (NumericLiteral (Right 1.0))
                , NonRec ann (Ident "x3") $ Literal ann (purusTy tyString) (StringLiteral (mkString "abc"))
                , NonRec ann (Ident "x4") $ Literal ann (purusTy tyChar) (CharLiteral 'c')
                , NonRec ann (Ident "x5") $ Literal ann (purusTy tyBoolean) (BooleanLiteral True)
                , NonRec ann (Ident "x6") $ Literal ann (arrayT tyChar) (ArrayLiteral [Literal ann (purusTy tyChar) (CharLiteral 'a')])
                -- TODO: Need helpers to make the type
                -- , NonRec ann (Ident "x7") $ Literal ann (ObjectLiteral [(mkString "a", Literal ann (CharLiteral 'a'))])
                ]
      parseMod m `shouldSatisfy` isSuccess
{- don't have the tools to write type sigs, TODO come back an fix
    specify "should parse Constructor" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "constructor") $ Constructor ann (ProperName "Either") (ProperName "Left") [Ident "value0"] ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse Accessor" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "x") $
                    Accessor ann (mkString "field") (Literal ann $ ObjectLiteral [(mkString "field", Literal ann (NumericLiteral (Left 1)))]) ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse ObjectUpdate" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "objectUpdate") $
                    ObjectUpdate ann
                      (Literal ann $ ObjectLiteral [(mkString "field", Literal ann (StringLiteral (mkString "abc")))])
                      (Just [mkString "unchangedField"])
                      [(mkString "field", Literal ann (StringLiteral (mkString "xyz")))]
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse Abs" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "abs")
                    $ Abs ann (Ident "x") (Var ann (Qualified (ByModuleName mn) (Ident "x")))
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse App" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "app")
                    $ App ann
                        (Abs ann (Ident "x") (Var ann (Qualified ByNullSourcePos (Ident "x"))))
                        (Literal ann (CharLiteral 'c'))
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse UnusedIdent in Abs" $ do
      let i = NonRec ann (Ident "f") (Abs ann UnusedIdent (Var ann (Qualified ByNullSourcePos (Ident "x"))))
      let r = parseMod $ Module ss [] mn mp [] [] M.empty [] [i]
      r `shouldSatisfy` isSuccess
      case r of
        Error _ -> pure ()
        Success Module{..} ->
          moduleDecls `shouldBe` [i]

    specify "should parse Case" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Case ann [Var ann (Qualified ByNullSourcePos (Ident "x"))]
                      [ CaseAlternative
                        [ NullBinder ann ]
                        (Right (Literal ann (CharLiteral 'a')))
                      ]
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse Case with guards" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Case ann [Var ann (Qualified ByNullSourcePos (Ident "x"))]
                      [ CaseAlternative
                        [ NullBinder ann ]
                        (Left [(Literal ann (BooleanLiteral True), Literal ann (CharLiteral 'a'))])
                      ]
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse Let" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Let ann
                      [ Rec [((ann, Ident "a"), Var ann (Qualified ByNullSourcePos (Ident "x")))] ]
                      (Literal ann (BooleanLiteral True))
                ]
      parseMod m `shouldSatisfy` isSuccess

  context "Meta" $ do
    specify "should parse IsConstructor" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec (ss, [], Just (IsConstructor ProductType [Ident "x"])) (Ident "x") $
                  Literal (ss, [], Just (IsConstructor SumType [])) (CharLiteral 'a')
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse IsNewtype" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec (ss, [], Just IsNewtype) (Ident "x") $
                  Literal ann (CharLiteral 'a')
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse IsTypeClassConstructor" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec (ss, [], Just IsTypeClassConstructor) (Ident "x") $
                  Literal ann (CharLiteral 'a')
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse IsForeign" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec (ss, [], Just IsForeign) (Ident "x") $
                  Literal ann (CharLiteral 'a')
                ]
      parseMod m `shouldSatisfy` isSuccess

  context "Binders" $ do
    specify "should parse LiteralBinder" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Case ann [Var ann (Qualified ByNullSourcePos (Ident "x"))]
                      [ CaseAlternative
                        [ LiteralBinder ann (BooleanLiteral True) ]
                        (Right (Literal ann (CharLiteral 'a')))
                      ]
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse VarBinder" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Case ann [Var ann (Qualified ByNullSourcePos (Ident "x"))]
                      [ CaseAlternative
                        [ ConstructorBinder
                            ann
                            (Qualified (ByModuleName (ModuleName "Data.Either")) (ProperName "Either"))
                            (Qualified ByNullSourcePos (ProperName "Left"))
                            [VarBinder ann (Ident "z")]
                        ]
                        (Right (Literal ann (CharLiteral 'a')))
                      ]
                ]
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse NamedBinder" $ do
      let m = Module ss [] mn mp [] [] M.empty []
                [ NonRec ann (Ident "case") $
                    Case ann [Var ann (Qualified ByNullSourcePos (Ident "x"))]
                      [ CaseAlternative
                        [ NamedBinder ann (Ident "w") (NamedBinder ann (Ident "w'") (VarBinder ann (Ident "w''"))) ]
                        (Right (Literal ann (CharLiteral 'a')))
                      ]
                ]
      parseMod m `shouldSatisfy` isSuccess
  -}
  context "Comments" $ do
    specify "should parse LineComment" $ do
      let m = Module ss [ LineComment "line" ] mn mp [] [] M.empty [] []
      parseMod m `shouldSatisfy` isSuccess

    specify "should parse BlockComment" $ do
      let m = Module ss [ BlockComment "block" ] mn mp [] [] M.empty [] []
      parseMod m `shouldSatisfy` isSuccess
-}
