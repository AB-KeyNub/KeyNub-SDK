{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | The native library: found, loaded once per process, and its functions
-- resolved by name into an 'Api' table. Applications use "KeyNub.LicDongle";
-- this module is exposed for the two path functions and the error type.
module KeyNub.LicDongle.Library
  ( Api(..)
  , api
  , setLibraryPath
  , libraryPath
  , loadedLibraryPath
  , LibraryError(..)
  ) where

import Control.Concurrent.MVar
import Control.Exception (Exception, SomeException, throwIO, try)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (FunPtr, Ptr, castFunPtr)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.IO.Unsafe (unsafePerformIO)
import qualified System.Info

#if defined(mingw32_HOST_OS)
import Foreign.Ptr (castPtrToFunPtr)
import System.Win32.DLL (getProcAddress, loadLibrary)
import System.Win32.Types (HMODULE)
#else
import System.Posix.DynamicLinker (DL, RTLDFlags(..), dlopen, dlsym)
#endif

-- | Loading problems: no library found, or a library without the expected
-- functions.
newtype LibraryError = LibraryError String
  deriving (Eq, Show)

instance Exception LibraryError

-- Every shape of function the flat API has.
type F_ppp     = Ptr CInt -> Ptr CInt -> Ptr CInt -> IO CInt
type F_p       = Ptr CInt -> IO CInt
type F_isi     = CInt -> CString -> CInt -> IO CInt
type F_s       = CString -> IO CInt
type F_i       = CInt -> IO CInt
type F_ibi     = CInt -> Ptr Word8 -> CInt -> IO CInt
type F_info    = CInt -> Ptr CInt -> Ptr CInt -> Ptr CInt -> Ptr CInt -> Ptr CInt
                 -> Ptr CInt -> Ptr CInt -> Ptr CInt -> IO CInt
type F_genuine = CInt -> Ptr CInt -> CString -> CInt -> CString -> CInt -> IO CInt
type F_ip      = CInt -> Ptr CInt -> IO CInt
type F_iip     = CInt -> CInt -> Ptr CInt -> IO CInt
type F_name    = CInt -> CInt -> CString -> CInt -> Ptr CInt -> IO CInt
type F_isp     = CInt -> CString -> Ptr CInt -> IO CInt
type F_read    = CInt -> CString -> Ptr Word8 -> CInt -> Ptr CInt -> IO CInt
type F_write   = CInt -> CString -> Ptr Word8 -> CInt -> IO CInt
type F_is      = CInt -> CString -> IO CInt
type F_enc     = CInt -> CInt -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> Ptr CInt -> IO CInt
type F_dec     = CInt -> Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> Ptr CInt -> IO CInt

foreign import ccall "dynamic" mk_ppp     :: FunPtr F_ppp -> F_ppp
foreign import ccall "dynamic" mk_p       :: FunPtr F_p -> F_p
foreign import ccall "dynamic" mk_isi     :: FunPtr F_isi -> F_isi
foreign import ccall "dynamic" mk_s       :: FunPtr F_s -> F_s
foreign import ccall "dynamic" mk_i       :: FunPtr F_i -> F_i
foreign import ccall "dynamic" mk_ibi     :: FunPtr F_ibi -> F_ibi
foreign import ccall "dynamic" mk_info    :: FunPtr F_info -> F_info
foreign import ccall "dynamic" mk_genuine :: FunPtr F_genuine -> F_genuine
foreign import ccall "dynamic" mk_ip      :: FunPtr F_ip -> F_ip
foreign import ccall "dynamic" mk_iip     :: FunPtr F_iip -> F_iip
foreign import ccall "dynamic" mk_name    :: FunPtr F_name -> F_name
foreign import ccall "dynamic" mk_isp     :: FunPtr F_isp -> F_isp
foreign import ccall "dynamic" mk_read    :: FunPtr F_read -> F_read
foreign import ccall "dynamic" mk_write   :: FunPtr F_write -> F_write
foreign import ccall "dynamic" mk_is      :: FunPtr F_is -> F_is
foreign import ccall "dynamic" mk_enc     :: FunPtr F_enc -> F_enc
foreign import ccall "dynamic" mk_dec     :: FunPtr F_dec -> F_dec

-- | The flat API's functions, resolved from the loaded library.
data Api = Api
  { fVersion         :: F_ppp
  , fDeviceCount     :: F_p
  , fDeviceSerial    :: F_isi
  , fDevicePath      :: F_isi
  , fOpen            :: F_s
  , fOpenPath        :: F_s
  , fClose           :: F_i
  , fSetTrustRoot    :: F_ibi
  , fGetSerial       :: F_isi
  , fGetInfo         :: F_info
  , fVerifyGenuine   :: F_genuine
  , fSessionOpen     :: F_i
  , fSessionClose    :: F_i
  , fWriteAuth       :: F_ibi
  , fWriteAuthRotate :: F_ibi
  , fRecordCount     :: F_ip
  , fRecordName      :: F_name
  , fRecordSize      :: F_isp
  , fRecordRead      :: F_read
  , fRecordWrite     :: F_write
  , fRecordErase     :: F_is
  , fRecordEraseAll  :: F_i
  , fCounterRead     :: F_iip
  , fCounterIncrement :: F_iip
  , fAppEncrypt      :: F_enc
  , fAppDecrypt      :: F_dec
  , fStrerror        :: F_isi
  , fLastError       :: F_isi
  }

data State = State
  { chosen :: Maybe FilePath          -- named with setLibraryPath, not yet loaded
  , loaded :: Maybe (FilePath, Api)
  }

{-# NOINLINE stateVar #-}
stateVar :: MVar State
stateVar = unsafePerformIO (newMVar (State Nothing Nothing))

-- | Names the native library to load. Call it before the first call; once a
-- library is loaded, naming a different one throws 'LibraryError'.
setLibraryPath :: FilePath -> IO ()
setLibraryPath p = modifyMVar_ stateVar $ \st -> case loaded st of
  Just (lp, _) | lp /= p ->
    throwIO (LibraryError ("the KeyNub library is already loaded from " ++ lp
                           ++ "; a process loads it once"))
  _ -> pure st { chosen = Just p }

-- | The library in use, or the one the next call would load.
libraryPath :: IO FilePath
libraryPath = do
  st <- readMVar stateVar
  case loaded st of
    Just (lp, _) -> pure lp
    Nothing -> resolve (chosen st)

-- | The library in use, once one is loaded.
loadedLibraryPath :: IO (Maybe FilePath)
loadedLibraryPath = fmap fst . loaded <$> readMVar stateVar

-- | The function table, loading the library on the first call.
api :: IO Api
api = modifyMVar stateVar $ \st -> case loaded st of
  Just (_, a) -> pure (st, a)
  Nothing -> do
    p <- resolve (chosen st)
    a <- load p
    pure (st { loaded = Just (p, a) }, a)

-- The path given to setLibraryPath, then KEYNUB_LICDONGLE_FLAT_LIBRARY, then
-- natives/<platform>/ from the working directory upwards (a clone of the SDK
-- repository), then the bare name for the system loader to find.
resolve :: Maybe FilePath -> IO FilePath
resolve (Just p) = pure p
resolve Nothing = do
  env <- lookupEnv "KEYNUB_LICDONGLE_FLAT_LIBRARY"
  case env of
    Just p | not (null p) -> pure p
    _ -> do
      found <- searchNatives
      pure (maybe basename id found)

basename :: FilePath
basename = case System.Info.os of
  "mingw32" -> "keynub_licdongle_flat.dll"
  "darwin"  -> "libkeynub_licdongle_flat.dylib"
  _         -> "libkeynub_licdongle_flat.so"

-- The natives/<platform> folder name of the SDK repository for this process.
platformFolder :: Maybe String
platformFolder = case (System.Info.os, System.Info.arch) of
  ("mingw32", "x86_64")  -> Just "win-x64"
  ("mingw32", "i386")    -> Just "win-x86"
  ("mingw32", "aarch64") -> Just "win-arm64"
  ("linux", "x86_64")    -> Just "linux-x64"
  ("linux", "aarch64")   -> Just "linux-arm64"
  ("darwin", "x86_64")   -> Just "osx-x64"
  ("darwin", "aarch64")  -> Just "osx-arm64"
  _                      -> Nothing

searchNatives :: IO (Maybe FilePath)
searchNatives = case platformFolder of
  Nothing -> pure Nothing
  Just rid -> getCurrentDirectory >>= go rid
  where
    go rid dir = do
      let candidate = dir </> "natives" </> rid </> basename
      present <- doesFileExist candidate
      if present
        then pure (Just candidate)
        else let parent = takeDirectory dir
             in if parent == dir then pure Nothing else go rid parent

load :: FilePath -> IO Api
load path = do
  sym <- opener path
  let get :: String -> IO (FunPtr a)
      get name = castFunPtr <$> sym name
  Api <$> (mk_ppp     <$> get "licdf_version")
      <*> (mk_p       <$> get "licdf_device_count")
      <*> (mk_isi     <$> get "licdf_device_serial")
      <*> (mk_isi     <$> get "licdf_device_path")
      <*> (mk_s       <$> get "licdf_open")
      <*> (mk_s       <$> get "licdf_open_path")
      <*> (mk_i       <$> get "licdf_close")
      <*> (mk_ibi     <$> get "licdf_set_trust_root")
      <*> (mk_isi     <$> get "licdf_get_serial")
      <*> (mk_info    <$> get "licdf_get_info")
      <*> (mk_genuine <$> get "licdf_verify_genuine")
      <*> (mk_i       <$> get "licdf_session_open")
      <*> (mk_i       <$> get "licdf_session_close")
      <*> (mk_ibi     <$> get "licdf_write_auth")
      <*> (mk_ibi     <$> get "licdf_write_auth_rotate")
      <*> (mk_ip      <$> get "licdf_record_count")
      <*> (mk_name    <$> get "licdf_record_name")
      <*> (mk_isp     <$> get "licdf_record_size")
      <*> (mk_read    <$> get "licdf_record_read")
      <*> (mk_write   <$> get "licdf_record_write")
      <*> (mk_is      <$> get "licdf_record_erase")
      <*> (mk_i       <$> get "licdf_record_erase_all")
      <*> (mk_iip     <$> get "licdf_counter_read")
      <*> (mk_iip     <$> get "licdf_counter_increment")
      <*> (mk_enc     <$> get "licdf_app_encrypt")
      <*> (mk_dec     <$> get "licdf_app_decrypt")
      <*> (mk_isi     <$> get "licdf_strerror")
      <*> (mk_isi     <$> get "licdf_last_error")

-- Opens the library and gives a symbol lookup over it.
opener :: FilePath -> IO (String -> IO (FunPtr ()))
#if defined(mingw32_HOST_OS)
opener path = do
  r <- try (loadLibrary path) :: IO (Either SomeException HMODULE)
  handle <- either (cannotLoad path) pure r
  pure $ \name -> do
    r2 <- try (getProcAddress handle name) :: IO (Either SomeException (Ptr ()))
    either (missing path name) (pure . castPtrToFunPtr) r2
#else
opener path = do
  r <- try (dlopen path [RTLD_NOW]) :: IO (Either SomeException DL)
  dl <- either (cannotLoad path) pure r
  pure $ \name -> do
    r2 <- try (dlsym dl name) :: IO (Either SomeException (FunPtr ()))
    either (missing path name) pure r2
#endif

cannotLoad :: FilePath -> SomeException -> IO a
cannotLoad path e = throwIO (LibraryError ("cannot load the KeyNub library " ++ path ++ ": " ++ show e))

missing :: FilePath -> String -> SomeException -> IO a
missing path name _ = throwIO (LibraryError (path ++ " does not export " ++ name))
