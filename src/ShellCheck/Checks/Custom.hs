{-
    Compositor for the ShellCheck custom check plugin system.
    Loads external checks dynamically from shared libraries at startup.
    See docs/plugins.md for architecture details.
-}
module ShellCheck.Checks.Custom (checker, optionalChecks) where

import ShellCheck.AnalyzerLib
import ShellCheck.Checks.Custom.Base
import ShellCheck.Interface

-- | Compose all active checks (loaded plugins) into a single Checker.
checker :: [CustomCheck] -> AnalysisSpec -> Parameters -> Checker
checker loadedPlugins spec _params = Checker {
    perScript = const $ return (),
    perToken  = \t -> mapM_ (\c -> ccChecker c t) activeChecks
  }
  where
    keys = asOptionalChecks spec
    isEnabled c = cdName (ccDescription c) `elem` keys || "all" `elem` keys
    activeChecks = filter (\c -> ccAlwaysOn c || isEnabled c) loadedPlugins

-- | Descriptions of optional checks for the --enable= system.
optionalChecks :: [CustomCheck] -> [CheckDescription]
optionalChecks loadedPlugins =
    map ccDescription $ filter (not . ccAlwaysOn) loadedPlugins
