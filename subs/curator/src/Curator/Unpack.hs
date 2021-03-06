{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Unpack packages and write out a stack.yaml
module Curator.Unpack
  ( unpackSnapshot
  ) where

import RIO
import RIO.Process (HasProcessContext)
import Pantry
import Curator.Types
import Path
import Path.IO
import qualified RIO.Text as T
import Data.Yaml
import qualified RIO.Map as Map
import qualified RIO.Set as Set

unpackSnapshot
  :: (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
  => Constraints
  -> Snapshot
  -> Path Abs Dir
  -> RIO env ()
unpackSnapshot cons snap root = do
  unpacked <- parseRelDir "unpacked"
  (suffixes, flags, (skipTest, expectTestFailure), (skipBench, expectBenchmarkFailure),
   (skipHaddock, expectHaddockFailure)) <- fmap fold $ for (snapshotPackages snap) $ \sp -> do
    let pl = spLocation sp
    TreeKey (BlobKey sha _size) <- getPackageLocationTreeKey pl
    let (PackageIdentifier name version) =
          case pl of
            PLIHackage ident _ _ -> ident
            PLIArchive _ pm -> pmIdent pm
            PLIRepo _ pm -> pmIdent pm
    let (flags, skipBuild, test, bench, haddock) =
          case Map.lookup name $ consPackages cons of
            Nothing ->
              (mempty, False, CAExpectSuccess, CAExpectSuccess, CAExpectSuccess)
            Just pc ->
              (pcFlags pc, pcSkipBuild pc, pcTests pc, pcBenchmarks pc, pcHaddock pc)
    unless (flags == spFlags sp) $ error $ unlines
      [ "mismatched flags for " ++ show pl
      , " snapshot: " ++ show (spFlags sp)
      , " constraints: " ++ show flags
      ]
    if skipBuild
      then pure mempty
      else do
        let suffixBuilder =
              fromString (packageNameString name) <>
              "-" <>
              fromString (versionString version) <>
              "-" <>
              display sha
        suffixTmp <- parseRelDir $ T.unpack $ utf8BuilderToText $ suffixBuilder <> ".tmp"
        let destTmp = root </> unpacked </> suffixTmp
        suffix <- parseRelDir $ T.unpack $ utf8BuilderToText suffixBuilder
        let dest = root </> unpacked </> suffix
        exists <- doesDirExist dest
        unless exists $ do
          ignoringAbsence $ removeDirRecur destTmp
          ensureDir destTmp
          logInfo $ "Unpacking " <> display pl
          unpackPackageLocation destTmp pl
          renameDir destTmp dest
        pure
          ( Set.singleton suffix
          , if Map.null flags then Map.empty else Map.singleton name flags
          , case test of
              CAExpectSuccess -> mempty
              CAExpectFailure -> (mempty, Set.singleton name)
              CASkip ->  (Set.singleton name, mempty)
          , case bench of
              CAExpectSuccess -> mempty
              CAExpectFailure -> (mempty, Set.singleton name)
              CASkip -> (Set.singleton name, mempty)
          , case haddock of
              CAExpectSuccess -> mempty
              CAExpectFailure -> (mempty, Set.singleton name)
              CASkip -> (Set.singleton name, mempty)
          )
  stackYaml <- parseRelFile "stack.yaml"
  let stackYamlFP = toFilePath $ root </> stackYaml
  liftIO $ encodeFile stackYamlFP $ object
    [ "resolver" .= ("ghc-" ++ versionString (consGhcVersion cons))
    , "packages" .= Set.map (\suffix -> toFilePath (unpacked </> suffix)) suffixes
    , "flags" .= fmap toCabalStringMap (toCabalStringMap flags)
    , "curator" .= object
        [ "skip-test" .= Set.map CabalString skipTest
        , "expect-test-failure" .= Set.map CabalString expectTestFailure
        , "skip-bench" .= Set.map CabalString skipBench
        , "expect-benchmark-failure" .= Set.map CabalString expectBenchmarkFailure
        , "skip-haddock" .= Set.map CabalString skipHaddock
        , "expect-haddock-failure" .= Set.map CabalString expectHaddockFailure
        ]
    ]
