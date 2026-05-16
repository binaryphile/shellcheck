{-
    Plugin API for the ShellCheck custom check system.
    See docs/design.md ("Plugin System Architecture") for architecture details.

    This module provides the registration type, test helpers, and generic
    AST utilities needed by any custom check. Domain-specific helpers
    (e.g., naming convention checks) belong in separate modules.

    Scaling guard: if AST utilities grow beyond ~5 functions, extract
    into Custom/ASTUtils.hs. This module should stay focused on the
    plugin registration type and test helpers.

    Public API: the export list of this module is the plugin system's
    stability contract. Plugin modules depend on these exports. Changes
    to the export list are breaking changes for fork plugins.
-}
module ShellCheck.Checks.Custom.Base (
    -- * Plugin registration
    CustomCheck(..),
    pluginApiVersion,
    -- * Test helpers
    verify,
    verifyNot,
    verifyCode,
    -- * AST utilities
    getExpansionName,
    isInRedirectContext,
    -- * Re-exports for plugin convenience
    -- | These are re-exported so plugin modules don't need to import
    -- Control.Monad and Control.Monad.RWS directly.
    ask,
    when
    ) where

import ShellCheck.AST
import ShellCheck.ASTLib
import ShellCheck.AnalyzerLib
import ShellCheck.Interface

import Control.Monad (when)
import Control.Monad.RWS (ask)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map

-- | Plugin API version. Bump when the API changes in incompatible ways.
-- Plugins can assert against this at compile time if needed:
--   _ = pluginApiVersion :: Int  -- fails if type changes
pluginApiVersion :: Int
pluginApiVersion = 1

-- | A custom check plugin. Register in Custom.hs's allChecks list.
data CustomCheck = CustomCheck {
    ccChecker     :: Token -> Analysis,    -- ^ Runs in RWS monad; use 'ask' for Parameters
    ccAlwaysOn    :: Bool,                 -- ^ True = always active; False = needs enable=
    ccDescription :: CheckDescription      -- ^ Metadata for optional check system
}

-- | Test helper: returns True if the check produces any comments on the given script.
verify :: (Token -> Analysis) -> String -> Bool
verify f s = producesComments c s == Just True
  where c = Checker { perScript = nullCheck, perToken = f }

-- | Test helper: returns True if the check produces no comments on the given script.
verifyNot :: (Token -> Analysis) -> String -> Bool
verifyNot f s = producesComments c s == Just False
  where c = Checker { perScript = nullCheck, perToken = f }

-- | Test helper: returns True if the check produces exactly the given SC code.
-- Stronger than 'verify' — asserts which specific rule fired.
verifyCode :: (Token -> Analysis) -> Integer -> String -> Bool
verifyCode f code s = getCodes c s == Just [code]
  where c = Checker { perScript = nullCheck, perToken = f }

getCodes :: Checker -> String -> Maybe [Integer]
getCodes c s = do
    let pr = pScript s
    prRoot pr
    let spec = defaultSpec pr
        params = makeParameters spec
    return $ map (cCode . tcComment) $ filterByAnnotation spec params $ runChecker params c

-- | Extract the variable name from a T_DollarBraced token.
-- Returns Nothing for non-T_DollarBraced tokens.
-- Generic utility: any check that examines variable expansions needs this.
getExpansionName :: Token -> Maybe String
getExpansionName (T_DollarBraced _ _ list) =
    let name = getBracedReference (concat $ oversimplify list)
    in if null name then Nothing else Just name
getExpansionName _ = Nothing

-- | True if the token is inside a T_FdRedirect (redirect target).
-- isQuoteFree's context walk doesn't recognize T_FdRedirect as an ancestor,
-- so checks must test this explicitly. Redirect targets don't undergo word splitting.
-- Generic utility: any quoting-aware check needs this workaround.
isInRedirectContext :: Map.Map Id Token -> Token -> Bool
isInRedirectContext parents t =
    any isRedirect $ NE.tail $ getPath parents t
  where
    isRedirect (T_FdRedirect {}) = True
    isRedirect _ = False
