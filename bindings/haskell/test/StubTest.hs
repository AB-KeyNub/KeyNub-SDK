{-# LANGUAGE ScopedTypeVariables #-}
-- Every call of the binding against a stand-in for the flat C API: the SDK's
-- flat layer compiled together with the C ABI stand-in
-- (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
-- into one shared library, with a C compiler from the path (cc, gcc, clang or
-- zig cc). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled stand-in
-- skips the build. Exit code 0 when every check passed.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import Data.List (sort)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>), takeDirectory)
import qualified System.Info
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))

import KeyNub.LicDongle

main :: IO ()
main = do
  lib <- standIn
  setLibraryPath lib
  failures <- newIORef (0 :: Int)
  let check cond what = unless cond $ do
        modifyIORef' failures (+ 1)
        putStrLn ("  FAIL  " ++ what)
      fails st what act = do
        r <- try act
        case r of
          Left (e :: LicDongleError) -> check (errorStatus e == st) (what ++ ": " ++ show (errorStatus e))
          Right _ -> check False (what ++ ": no failure")
      serialValue = "04A1B2C3D4E5F6"
      factoryKey = BS.pack [0x30, 0x10, 0x01, 0x02, 0x03]
      replacementKey = BS.pack [0x30, 0x11, 0x09, 0x08, 0x07, 0x06]

  v <- libraryVersion
  check (v == (9, 8, 7)) "the stand-in reports 9.8.7"
  t <- statusText (-2)
  check (t == "no device") "strerror text"

  ds <- devices
  check (ds == [Device serialValue "stub:0"]) "enumeration"
  fails NoDevice "open with a wrong serial" (openSerial "nope")
  fails NoDevice "open at a wrong path" (openPath "stub:9")

  d <- open
  s <- serial d
  check (s == serialValue) "serial"
  i <- info d
  check (protocolVersion i == (1, 0) && firmwareVersion i == (2, 3, 4)) "versions"
  check (secureElementReady i && provisioned i && isolated i) "flags set"
  check (not (watchdogReboot i) && not (writeAuthRotated i)) "flags clear"
  check (dataCapacity i == 1024 * 1024 && dataFree i == 1000000) "storage"
  g <- verifyGenuine d
  check (genuineSerial g == serialValue && provisionedDate g == "2026-08-15") "genuine"
  isGenuine d >>= \ok -> check ok "isGenuine"

  fails CertInvalid "a non-DER root is refused" (setTrustRoot d (BS.pack [0x02, 0x01, 0x00]))
  setTrustRoot d (BS.pack ([0x30, 0x82, 0x01, 0x00] ++ replicate 128 0xAB))
  fails CertInvalid "verification under a foreign root" (verifyGenuine d)
  isGenuine d >>= \ok -> check (not ok) "isGenuine fails closed"
  setTrustRoot d (BS.pack ([0x30, 0x82, 0x01, 0x00] ++ replicate 128 0x01))
  isGenuine d >>= \ok -> check ok "genuine again under the issuing root"

  fails SessionExpired "records need a session" (records d)
  sessionOpen d
  let payload = BC.pack "license-blob-0123456789"
  fails AuthRequired "writing needs the write role" (writeRecord d "lic" payload)
  fails NotGenuine "a wrong key does not elevate" (authorizeWrite d (BS.pack [0x30, 0x00]))
  authorizeWrite d factoryKey
  writeRecord d "lic" payload
  readRecord d "lic" >>= \r -> check (r == payload) "read back what was written"
  writeRecord d "cfg" (BC.pack "cfgdata")
  recs <- records d
  check (sort (map recordName recs) == ["cfg", "lic"]) "record names"
  check ([recordSize r | r <- recs, recordName r == "lic"] == [BS.length payload]) "record size"
  readRecord d "cfg" >>= \r -> check (BC.unpack r == "cfgdata") "a string is stored as its bytes"
  fails NotFound "reading a missing record" (readRecord d "nope")
  fails InvalidArg "an empty name never erases" (eraseRecord d "")
  records d >>= \rs -> check (length rs == 2) "nothing erased by mistake"
  eraseRecord d "cfg"
  records d >>= \rs -> check (map recordName rs == ["lic"]) "one record after the erase"
  writeRecord d "empty" BS.empty
  readRecord d "empty" >>= \r -> check (r == BS.empty) "an empty record reads back empty"

  before <- readCounter d 0
  incrementCounter d 0 >>= \n -> check (n == before + 1) "increment returns the new value"
  c0 <- readCounter d 0
  c1 <- readCounter d 1
  check (c0 == before + 1 && c1 == 0) "counters"
  fails Range "a counter the dongle lacks" (readCounter d 7)

  let secret = BS.pack [fromIntegral ((3 * k + 7) `mod` 256) | k <- [0 .. 99 :: Int]]
  forM_ [(DeviceScope, 0), (DeveloperScope, 1)] $ \(scope, byte) -> do
    blob <- appEncrypt d scope secret
    check (BS.length blob > BS.length secret) ("sealed data is longer, " ++ show scope)
    check (BS.head blob == byte) ("scope byte " ++ show scope)
    appDecrypt d blob >>= \r -> check (r == secret) ("round trip " ++ show scope)
    let tampered = BS.init blob `BS.snoc` (BS.last blob `xor` 1)
    fails TagMismatch ("tampered data " ++ show scope) (appDecrypt d tampered)
  eraseAllRecords d
  records d >>= \rs -> check (null rs) "erase all leaves nothing"

  rotateWriteKey d replacementKey
  writeRecord d "lic" (BC.pack "still-writable")
  sessionClose d
  info d >>= \i2 -> check (writeAuthRotated i2) "the rotation flag is set"
  sessionOpen d
  fails NotGenuine "the factory key no longer elevates" (authorizeWrite d factoryKey)
  authorizeWrite d replacementKey
  writeRecord d "lic" (BC.pack "new-key-writes")
  readRecord d "lic" >>= \r -> check (BC.unpack r == "new-key-writes") "the new key writes"
  sessionClose d
  close d
  r <- try (serial d)
  check (either (\(_ :: LicDongleError) -> True) (const False) r) "a closed handle refuses calls"

  n <- readIORef failures
  if n == 0
    then putStrLn "keynub-licdongle: every call passed against the ABI stand-in" >> exitSuccess
    else putStrLn (show n ++ " check(s) failed") >> exitFailure

-- The compiled stand-in: from the environment, or built from the SDK sources
-- found by walking up from the working directory.
standIn :: IO FilePath
standIn = do
  env <- lookupEnv "KEYNUB_LICDONGLE_FLAT_LIBRARY"
  case env of
    Just p | not (null p) -> pure p
    _ -> do
      root <- sdkRoot
      tmp <- getTemporaryDirectory
      let dir = tmp </> "keynub-haskell-stub"
          out = dir </> libName
      createDirectoryIfMissing True dir
      let args = ["-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED",
                  "-I" ++ (root </> "core" </> "include"), "-I" ++ (root </> "bindings" </> "flat"),
                  "-o", out,
                  root </> "bindings" </> "flat" </> "licd_flat.c",
                  root </> "bindings" </> "julia" </> "test" </> "stub" </> "licd_stub.c"]
                 ++ (if System.Info.os == "mingw32" then [] else ["-fPIC"])
      ok <- tryCompilers [("cc", []), ("gcc", []), ("clang", []), ("zig", ["cc"])] args
      unless ok $ do
        putStrLn "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc) on the path"
        exitFailure
      pure out
  where
    libName = case System.Info.os of
      "mingw32" -> "keynub_licdongle_flat.dll"
      "darwin"  -> "libkeynub_licdongle_flat.dylib"
      _         -> "libkeynub_licdongle_flat.so"
    tryCompilers [] _ = pure False
    tryCompilers ((exe, pre) : rest) args = do
      r <- try (readProcessWithExitCode exe (pre ++ args) "") :: IO (Either SomeException (ExitCode, String, String))
      case r of
        Right (ExitSuccess, _, _) -> pure True
        Right (_, _, err) -> putStrLn (exe ++ ": " ++ err) >> tryCompilers rest args
        Left _ -> tryCompilers rest args

-- The SDK root: KEYNUB_SDK_ROOT, or the first directory upwards holding
-- bindings/flat/licd_flat.c.
sdkRoot :: IO FilePath
sdkRoot = do
  env <- lookupEnv "KEYNUB_SDK_ROOT"
  case env of
    Just p | not (null p) -> pure p
    _ -> getCurrentDirectory >>= go
  where
    go dir = do
      present <- doesFileExist (dir </> "bindings" </> "flat" </> "licd_flat.c")
      if present then pure dir else do
        let parent = takeDirectory dir
        if parent == dir
          then putStrLn "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT" >> exitFailure
          else go parent
