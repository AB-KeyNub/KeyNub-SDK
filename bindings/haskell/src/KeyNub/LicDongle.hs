{-# LANGUAGE ScopedTypeVariables #-}
-- | KeyNub License Dongle for Haskell.
--
-- Calls the SDK's flat companion API (@keynub_licdongle_flat@) through
-- function pointers resolved at run time, so nothing is linked at build time
-- and the package is pure Haskell. Handles are 'Dongle' values; byte data is
-- 'ByteString'; every failure is a 'LicDongleError' exception carrying the
-- library's status code, the operation and its diagnostic detail.
--
-- @
-- import KeyNub.LicDongle
--
-- main = withDongle open $ \\d -> do
--   _ <- verifyGenuine d                 -- throws unless genuine
--   secret <- withSession d $ appDecrypt d sealed   -- build the licence check on this
--   ...
-- @
module KeyNub.LicDongle
  ( -- * The native library
    libraryVersion
  , libraryPath
  , loadedLibraryPath
  , setLibraryPath
  , statusText
    -- * Failures
  , Status(..)
  , statusFromCode
  , LicDongleError(..)
  , LibraryError(..)
    -- * Dongles
  , Device(..)
  , devices
  , Dongle
  , open
  , openSerial
  , openPath
  , close
  , withDongle
  , serial
  , Info(..)
  , info
  , lastErrorDetail
    -- * Authenticity
  , GenuineResult(..)
  , verifyGenuine
  , isGenuine
  , setTrustRoot
    -- * Session
  , sessionOpen
  , sessionClose
  , withSession
  , authorizeWrite
  , rotateWriteKey
    -- * Records
  , RecordInfo(..)
  , records
  , readRecord
  , writeRecord
  , eraseRecord
  , eraseAllRecords
    -- * Counters
  , readCounter
  , incrementCounter
    -- * Application data
  , Scope(..)
  , appEncrypt
  , appDecrypt
  ) where

import Control.Exception (Exception(..), SomeException, bracket, bracket_, catch, throwIO)
import Control.Monad (forM, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (advancePtr, allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke, pokeByteOff)

import KeyNub.LicDongle.Library

-- | The library's status codes, by name.
data Status
  = InvalidArg | NoDevice | AccessDenied | IOFailure | Timeout | ProtocolError
  | NotGenuine | CertInvalid | SessionExpired | TagMismatch | Range | StorageFull
  | Busy | NotFound | AuthRequired | FirmwareIncompatible | SdkTooOld | Cancelled
  | NotImplemented | Internal
  | Unknown Int   -- ^ a code this binding does not know
  deriving (Eq, Show)

-- | The 'Status' for a raw status code.
statusFromCode :: Int -> Status
statusFromCode c = case c of
  -1 -> InvalidArg;  -2 -> NoDevice;      -3 -> AccessDenied;   -4 -> IOFailure
  -5 -> Timeout;     -6 -> ProtocolError; -7 -> NotGenuine;     -8 -> CertInvalid
  -9 -> SessionExpired; -10 -> TagMismatch; -11 -> Range;       -12 -> StorageFull
  -13 -> Busy;       -14 -> NotFound;     -15 -> AuthRequired;  -16 -> FirmwareIncompatible
  -17 -> SdkTooOld;  -18 -> Cancelled;    -19 -> NotImplemented; -20 -> Internal
  _ -> Unknown c

-- | A failed call: the status, its raw code, the C function that failed and
-- the library's diagnostic detail for it (often empty).
data LicDongleError = LicDongleError
  { errorStatus    :: Status
  , errorCode      :: Int
  , errorOperation :: String
  , errorDetail    :: String
  } deriving (Eq, Show)

instance Exception LicDongleError where
  displayException e =
    errorOperation e ++ ": " ++ show (errorStatus e) ++ " (" ++ show (errorCode e) ++ ")"
    ++ (if null (errorDetail e) then "" else ": " ++ errorDetail e)

-- | An attached dongle, as listed by 'devices'.
data Device = Device
  { deviceSerial :: String   -- ^ the serial, as hex
  , devicePath   :: String   -- ^ the device path 'openPath' takes
  } deriving (Eq, Show)

-- | An open dongle. The library holds up to 32 at a time; release them with
-- 'close' or use 'withDongle'.
newtype Dongle = Dongle CInt
  deriving (Eq, Show)

-- | Plaintext device information, read without a session.
data Info = Info
  { protocolVersion    :: (Int, Int)
  , firmwareVersion    :: (Int, Int, Int)
  , secureElementReady :: Bool
  , provisioned        :: Bool
  , watchdogReboot     :: Bool   -- ^ the previous boot ended in a watchdog reset
  , isolated           :: Bool
  , writeAuthRotated   :: Bool   -- ^ 'rotateWriteKey' has replaced the shipped write key
  , dataCapacity       :: Int    -- ^ record storage, bytes
  , dataFree           :: Int
  } deriving (Eq, Show)

-- | What a genuine dongle proves: the serial from its certificate and the day
-- it was personalised (@YYYY-MM-DD@, or empty).
data GenuineResult = GenuineResult
  { genuineSerial   :: String
  , provisionedDate :: String
  } deriving (Eq, Show)

-- | A record on the dongle.
data RecordInfo = RecordInfo
  { recordName :: String
  , recordSize :: Int
  } deriving (Eq, Show)

-- | Who can decrypt data sealed with 'appEncrypt'.
data Scope
  = DeviceScope     -- ^ only the dongle that sealed it
  | DeveloperScope  -- ^ any dongle issued to the same developer
  deriving (Eq, Show)

serialSize, dateSize, pathSize, errorSize :: Int
serialSize = 15
dateSize = 11
pathSize = 512
errorSize = 256

rangeCode :: CInt
rangeCode = -11

-- Failure handling: every flat call returns 0 or a negative status.
check :: Maybe Dongle -> String -> CInt -> IO ()
check h op rc
  | rc == 0 = pure ()
  | otherwise = do
      detail <- maybe (pure "") lastErrorDetail h
      throwIO (LicDongleError (statusFromCode (fromIntegral rc)) (fromIntegral rc) op detail)

withOutInt :: (Ptr CInt -> IO CInt) -> IO (CInt, CInt)
withOutInt f = alloca $ \p -> do
  poke p 0
  rc <- f p
  v <- peek p
  pure (rc, v)

-- A NUL-terminated string into a caller buffer of the given capacity.
readString :: Int -> (CString -> CInt -> IO CInt) -> IO (CInt, String)
readString cap f = allocaBytes cap $ \buf -> do
  pokeByteOff buf 0 (0 :: Word8)
  rc <- f buf (fromIntegral cap)
  s <- if rc == 0 then peekCString buf else pure ""
  pure (rc, s)

-- Bytes of unknown length: ask with a capacity of 0, the library answers
-- Range and the size needed, then read into a buffer of that size.
readBytes :: Maybe Dongle -> String -> (Ptr Word8 -> CInt -> Ptr CInt -> IO CInt) -> IO ByteString
readBytes h op f = do
  (rc0, need) <- withOutInt (f nullPtr 0)
  if rc0 == 0
    then pure BS.empty
    else if rc0 /= rangeCode
      then check h op rc0 >> pure BS.empty
      else allocaBytes (fromIntegral need) $ \buf -> do
        (rc, len) <- withOutInt (f buf need)
        check h op rc
        BS.packCStringLen (castPtr buf, fromIntegral len)

useBytes :: ByteString -> (Ptr Word8 -> CInt -> IO a) -> IO a
useBytes bs f = BS.useAsCStringLen bs $ \(p, n) -> f (castPtr p) (fromIntegral n)

-- | @(major, minor, patch)@ of the loaded native library; loads it if no other
-- call has.
libraryVersion :: IO (Int, Int, Int)
libraryVersion = do
  a <- api
  allocaArray 3 $ \arr -> do
    rc <- fVersion a arr (advancePtr arr 1) (advancePtr arr 2)
    check Nothing "licdf_version" rc
    [x, y, z] <- map fromIntegral <$> peekArray 3 arr
    pure (x, y, z)

-- | The library's text for a status code.
statusText :: Int -> IO String
statusText code = do
  a <- api
  snd <$> readString errorSize (fStrerror a (fromIntegral code))

-- | The library's diagnostic detail for the most recent failure on a dongle.
lastErrorDetail :: Dongle -> IO String
lastErrorDetail (Dongle h) = do
  a <- api
  snd <$> readString errorSize (fLastError a h)

-- | The attached dongles.
devices :: IO [Device]
devices = do
  a <- api
  (rc, n) <- withOutInt (fDeviceCount a)
  check Nothing "licdf_device_count" rc
  forM [0 .. n - 1] $ \i -> do
    (rc1, s) <- readString pathSize (fDeviceSerial a i)
    check Nothing "licdf_device_serial" rc1
    (rc2, p) <- readString pathSize (fDevicePath a i)
    check Nothing "licdf_device_path" rc2
    pure (Device s p)

-- | Opens the first dongle.
open :: IO Dongle
open = openSerial ""

-- | Opens the dongle with that serial (an empty serial means the first one).
openSerial :: String -> IO Dongle
openSerial s = do
  a <- api
  h <- withCString s (fOpen a)
  handleOf "licdf_open" h

-- | Opens the dongle at a device path from 'devices'.
openPath :: String -> IO Dongle
openPath p = do
  a <- api
  h <- withCString p (fOpenPath a)
  handleOf "licdf_open_path" h

handleOf :: String -> CInt -> IO Dongle
handleOf op h
  | h > 0 = pure (Dongle h)
  | otherwise = throwIO (LicDongleError (statusFromCode (fromIntegral h)) (fromIntegral h) op "")

-- | Releases a dongle; its session ends with it.
close :: Dongle -> IO ()
close (Dongle h) = do
  a <- api
  fClose a h >>= check Nothing "licdf_close"

-- | Opens a dongle, runs the action, and closes the dongle on every exit path.
withDongle :: IO Dongle -> (Dongle -> IO a) -> IO a
withDongle acquire = bracket acquire close

-- | The dongle's serial, as hex.
serial :: Dongle -> IO String
serial d@(Dongle h) = do
  a <- api
  (rc, s) <- readString serialSize (fGetSerial a h)
  check (Just d) "licdf_get_serial" rc
  pure s

-- | Plaintext device information.
info :: Dongle -> IO Info
info d@(Dongle h) = do
  a <- api
  allocaArray 8 $ \arr -> do
    let p i = advancePtr arr i
    rc <- fGetInfo a h (p 0) (p 1) (p 2) (p 3) (p 4) (p 5) (p 6) (p 7)
    check (Just d) "licdf_get_info" rc
    v <- map fromIntegral <$> peekArray 8 arr
    let flags = v !! 5 :: Int
        flag b = flags .&. b /= 0
    pure Info
      { protocolVersion = (v !! 0, v !! 1)
      , firmwareVersion = (v !! 2, v !! 3, v !! 4)
      , secureElementReady = flag 0x01
      , provisioned = flag 0x02
      , watchdogReboot = flag 0x04
      , isolated = flag 0x08
      , writeAuthRotated = flag 0x10
      , dataCapacity = v !! 6
      , dataFree = v !! 7
      }

-- | Proves that the dongle is genuine: certificate chain to the trusted root
-- and a live challenge-response. Throws unless it is.
verifyGenuine :: Dongle -> IO GenuineResult
verifyGenuine d@(Dongle h) = do
  a <- api
  alloca $ \pg -> allocaBytes serialSize $ \ps -> allocaBytes dateSize $ \pd -> do
    poke pg 0
    pokeByteOff ps 0 (0 :: Word8)
    pokeByteOff pd 0 (0 :: Word8)
    rc <- fVerifyGenuine a h pg ps (fromIntegral serialSize) pd (fromIntegral dateSize)
    check (Just d) "licdf_verify_genuine" rc
    g <- peek pg
    when (g == 0) $ throwIO (LicDongleError NotGenuine (-7) "licdf_verify_genuine" "")
    GenuineResult <$> peekCString ps <*> peekCString pd

-- | 'True' only when the dongle proves genuine. Every failure, of any kind,
-- gives 'False'.
isGenuine :: Dongle -> IO Bool
isGenuine d = (verifyGenuine d >> pure True) `catch` \(_ :: SomeException) -> pure False

-- | Replaces the CA root that 'verifyGenuine' checks against (a certificate in
-- DER form). Applications do not need this.
setTrustRoot :: Dongle -> ByteString -> IO ()
setTrustRoot d@(Dongle h) der = do
  a <- api
  useBytes der (fSetTrustRoot a h) >>= check (Just d) "licdf_set_trust_root"

-- | Opens the encrypted session that records, counters and application-data
-- encryption need.
sessionOpen :: Dongle -> IO ()
sessionOpen d@(Dongle h) = do
  a <- api
  fSessionOpen a h >>= check (Just d) "licdf_session_open"

-- | Ends the session; the write role ends with it.
sessionClose :: Dongle -> IO ()
sessionClose d@(Dongle h) = do
  a <- api
  fSessionClose a h >>= check (Just d) "licdf_session_close"

-- | Runs the action inside a session, closing it on every exit path.
withSession :: Dongle -> IO a -> IO a
withSession d = bracket_ (sessionOpen d) (sessionClose d)

-- | Elevates the session to the write role with the dongle's write key, a
-- P-256 private key in PKCS#8 DER form.
authorizeWrite :: Dongle -> ByteString -> IO ()
authorizeWrite d@(Dongle h) key = do
  a <- api
  useBytes key (fWriteAuth a h) >>= check (Just d) "licdf_write_auth"

-- | Replaces the dongle's write key with the given one (P-256, PKCS#8 DER).
-- From the next session on, only that key elevates. Needs the write role.
rotateWriteKey :: Dongle -> ByteString -> IO ()
rotateWriteKey d@(Dongle h) key = do
  a <- api
  useBytes key (fWriteAuthRotate a h) >>= check (Just d) "licdf_write_auth_rotate"

-- | The records on the dongle. Needs a session.
records :: Dongle -> IO [RecordInfo]
records d@(Dongle h) = do
  a <- api
  (rc, n) <- withOutInt (fRecordCount a h)
  check (Just d) "licdf_record_count" rc
  forM [0 .. n - 1] $ \i -> allocaBytes pathSize $ \buf -> alloca $ \psz -> do
    pokeByteOff buf 0 (0 :: Word8)
    poke psz 0
    rc1 <- fRecordName a h i buf (fromIntegral pathSize) psz
    check (Just d) "licdf_record_name" rc1
    RecordInfo <$> peekCString buf <*> (fromIntegral <$> peek psz)

-- | Reads a record. Needs a session.
readRecord :: Dongle -> String -> IO ByteString
readRecord d@(Dongle h) name = do
  a <- api
  withCString name $ \cn -> readBytes (Just d) "licdf_record_read" (fRecordRead a h cn)

-- | Replaces (or creates) a record. Needs the write role.
writeRecord :: Dongle -> String -> ByteString -> IO ()
writeRecord d@(Dongle h) name bytes = do
  a <- api
  withCString name $ \cn -> useBytes bytes (fRecordWrite a h cn) >>= check (Just d) "licdf_record_write"

-- | Erases one record. Needs the write role. An empty name is refused; use
-- 'eraseAllRecords' to erase everything.
eraseRecord :: Dongle -> String -> IO ()
eraseRecord d@(Dongle h) name = do
  a <- api
  withCString name (fRecordErase a h) >>= check (Just d) "licdf_record_erase"

-- | Erases every record. Needs the write role.
eraseAllRecords :: Dongle -> IO ()
eraseAllRecords d@(Dongle h) = do
  a <- api
  fRecordEraseAll a h >>= check (Just d) "licdf_record_erase_all"

-- | Reads a hardware monotonic counter (0 or 1). Needs a session.
readCounter :: Dongle -> Int -> IO Int
readCounter d@(Dongle h) i = do
  a <- api
  (rc, v) <- withOutInt (fCounterRead a h (fromIntegral i))
  check (Just d) "licdf_counter_read" rc
  pure (fromIntegral v)

-- | Increments a counter, irreversibly, and gives the new value. Needs the
-- write role.
incrementCounter :: Dongle -> Int -> IO Int
incrementCounter d@(Dongle h) i = do
  a <- api
  (rc, v) <- withOutInt (fCounterIncrement a h (fromIntegral i))
  check (Just d) "licdf_counter_increment" rc
  pure (fromIntegral v)

-- | Seals data so that only a dongle can open it. Needs a session. This is the
-- pair to build a licence check on: route something the program needs through
-- it, so that removing the check removes the data.
appEncrypt :: Dongle -> Scope -> ByteString -> IO ByteString
appEncrypt d@(Dongle h) scope plain = do
  a <- api
  let code = case scope of DeviceScope -> 0; DeveloperScope -> 1
  useBytes plain $ \pp n -> readBytes (Just d) "licdf_app_encrypt" (fAppEncrypt a h code pp n)

-- | Opens data sealed with 'appEncrypt'. Needs a session.
appDecrypt :: Dongle -> ByteString -> IO ByteString
appDecrypt d@(Dongle h) packed = do
  a <- api
  useBytes packed $ \pp n -> readBytes (Just d) "licdf_app_decrypt" (fAppDecrypt a h pp n)
