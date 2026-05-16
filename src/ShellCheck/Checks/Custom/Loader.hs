{-# LANGUAGE CPP #-}
{-
    Dynamic plugin loader for the ShellCheck custom check system.
    See docs/design.md ("Dynamic Plugin Loading") for architecture details.

    On platforms with dlopen (Linux, macOS), scans a plugin directory at
    startup, loads shared libraries, verifies API version, and returns
    merged [CustomCheck] lists. On Windows, returns [] (no plugin support).

    Resource lifecycle (unix platforms):
    - dlopen fails: exception caught, dl not opened
    - version/symbol check fails: dl stays open (GHC may have run init
      code during dlopen -- closing would invalidate RTS references)
    - load succeeds: dl stays open (closures reference code in .so),
      StablePtr freed after deRefStablePtr (data on GC heap)
-}
module ShellCheck.Checks.Custom.Loader (loadPlugins) where

import ShellCheck.Checks.Custom.Base (CustomCheck)

#ifdef HAVE_DYNAMIC_LOADING

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.List (isSuffixOf)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (FunPtr, castFunPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.DynamicLinker (RTLDFlags(..), dlopen, dlsym)

import ShellCheck.Checks.Custom.Base (pluginApiVersion)

foreign import ccall "dynamic"
    mkApiVersion :: FunPtr (IO CInt) -> IO CInt
foreign import ccall "dynamic"
    mkPluginInit :: FunPtr (IO (StablePtr [CustomCheck])) -> IO (StablePtr [CustomCheck])

-- | Load all plugins from the given directory.
-- Returns [] silently if the directory doesn't exist.
-- Bad plugins produce warnings on stderr but never cause failure.
loadPlugins :: FilePath -> IO [CustomCheck]
loadPlugins dir = do
    exists <- doesDirectoryExist dir
    if not exists then return [] else do
        files <- filter (".so" `isSuffixOf`) <$> listDirectory dir
        concat <$> mapM (loadPlugin dir) files

loadPlugin :: FilePath -> FilePath -> IO [CustomCheck]
loadPlugin dir file = do
    let path = dir </> file
    result <- try $ loadPlugin' path
    case result :: Either IOException [CustomCheck] of
        Right checks -> do
            hPutStrLn stderr $ "Loaded plugin: " ++ file
                ++ " (" ++ show (length checks) ++ " check(s))"
            return checks
        Left ex -> do
            hPutStrLn stderr $ "Warning: failed to load plugin "
                ++ file ++ ": " ++ show ex
            return []

loadPlugin' :: FilePath -> IO [CustomCheck]
loadPlugin' path = do
    dl <- dlopen path [RTLD_NOW, RTLD_GLOBAL]

    -- dlsym throws on missing symbol, caught by outer try in loadPlugin
    versionFP <- dlsym dl "plugin_api_version"
    version <- mkApiVersion (castFunPtr versionFP)
    when (fromIntegral version /= pluginApiVersion) $
        fail $ "API version mismatch: host=" ++ show pluginApiVersion
               ++ " plugin=" ++ show version

    -- Load checks
    initFP <- dlsym dl "plugin_init"
    checksPtr <- mkPluginInit (castFunPtr initFP)
    checks <- deRefStablePtr checksPtr
    freeStablePtr checksPtr  -- host owns the data now, free the stable pointer
    -- Do NOT dlclose -- Haskell closures in checks reference code in the .so

    return checks

#else

-- | Stub: dynamic plugin loading not available on this platform.
loadPlugins :: FilePath -> IO [CustomCheck]
loadPlugins _ = return []

#endif
