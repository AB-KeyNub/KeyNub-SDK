-- KeyNub SDK - Haskell sample: take ownership of a new dongle.
--
-- A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
-- so that from the next session onward only your key can write records, erase
-- them or increment counters. Run it once per dongle, when it arrives.
--
-- Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
--
--   openssl ecparam -name prime256v1 -genkey -noout |
--     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
--
--   cabal run rotate_write_key -- ../../keys/keynub-shipping-writeauth.key.der my-key.der
--
-- Targets real hardware: with no dongle attached it prints guidance and exits 0.
--
-- The replacement key is worth what your licence-signing key is worth. It
-- cannot be recovered from the dongle, and a unit rotated to a key you have
-- lost has to come back to be re-provisioned.
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import qualified Data.ByteString as BS
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith, ExitCode(..))

import KeyNub.LicDongle

main :: IO ()
main = do
  args <- getArgs
  case args of
    [current, replacement] -> do
      r <- try (run current replacement)
      case r of
        Left (e :: SomeException) -> putStrLn ("KeyNub error: " ++ displayException e) >> exitFailure
        Right () -> pure ()
    _ -> putStrLn "usage: rotate_write_key <current-key.der> <new-key.der>" >> exitWith (ExitFailure 2)

run :: FilePath -> FilePath -> IO ()
run currentPath replacementPath = do
  current <- BS.readFile currentPath
  replacement <- BS.readFile replacementPath
  ds <- devices
  if null ds
    then putStrLn "Connect a KeyNub dongle and re-run."
    else withDongle open $ \d -> do
      s <- serial d
      putStrLn ("Dongle " ++ s)
      before <- info d
      when (writeAuthRotated before) $
        putStrLn "This dongle's write key has already been rotated away from the factory one."
      withSession d $ do
        authorizeWrite d current          -- the key the dongle accepts today
        rotateWriteKey d replacement      -- from the next session: only the new one
      after <- info d
      putStrLn ("Write key rotated: " ++ if writeAuthRotated after then "yes" else "no")
