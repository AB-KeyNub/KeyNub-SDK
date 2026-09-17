-- KeyNub SDK - Haskell sample: verify a dongle and read what it holds.
--
--   cabal run verify_and_read          (from samples/haskell)
--
-- Targets real hardware: with no dongle attached it prints guidance and exits 0.
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import System.Exit (exitFailure)
import Text.Printf (printf)

import KeyNub.LicDongle

main :: IO ()
main = do
  r <- try run
  case r of
    Left (e :: SomeException) -> putStrLn ("KeyNub error: " ++ displayException e) >> exitFailure
    Right () -> pure ()

run :: IO ()
run = do
  (a, b, c) <- libraryVersion
  printf "KeyNub library v%d.%d.%d\n" a b c
  ds <- devices
  if null ds
    then putStrLn "Connect a KeyNub dongle and re-run."
    else withDongle open $ \d -> do
      report d
      withSession d $ do
        readRecords d
        protectSomething d

report :: Dongle -> IO ()
report d = do
  i <- info d
  let (pa, pb) = protocolVersion i
      (fa, fb, fc) = firmwareVersion i
  printf "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n" pa pb fa fb fc (dataFree i) (dataCapacity i)
  -- The only trace a firmware hang leaves behind. Worth reporting to support.
  when (watchdogReboot i) $ putStrLn "WARNING: this dongle's previous boot ended in a watchdog reset."
  g <- verifyGenuine d
  printf "Genuine: yes (serial %s, provisioned %s)\n" (genuineSerial g) (provisionedDate g)

readRecords :: Dongle -> IO ()
readRecords d = do
  recs <- records d
  printf "%d record(s) on the dongle:\n" (length recs)
  forM_ recs $ \r -> printf "  %-16s %d bytes\n" (recordName r) (recordSize r)
  -- A missing record is a normal state, not an error.
  when ("license" `elem` map recordName recs) $ do
    dat <- readRecord d "license"
    printf "Read %d bytes from the license record.\n" (BS.length dat)

-- The part that actually protects something. At licence-issue time you would
-- call appEncrypt once, with a developer dongle, and ship only the sealed
-- data; the program then cannot proceed without a dongle, because it holds no
-- other copy. DeveloperScope lets any dongle you have issued decrypt it, so
-- one file serves every customer; DeviceScope locks it to one dongle.
protectSomething :: Dongle -> IO ()
protectSomething d = do
  let needed = BC.pack "the data this program cannot run without"
  sealed <- appEncrypt d DeveloperScope needed
  recovered <- appDecrypt d sealed
  printf "App-crypto round trip: %d bytes -> %d sealed -> %s\n" (BS.length needed) (BS.length sealed)
    (if recovered == needed then "recovered intact" else "MISMATCH" :: String)
