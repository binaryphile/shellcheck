{-# LANGUAGE TemplateHaskell #-}
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
    getDocCommentsBefore,
    -- * Re-exports for plugin convenience
    -- | These are re-exported so plugin modules don't need to import
    -- Control.Monad and Control.Monad.RWS directly.
    ask,
    when,
    -- * Test runner (auto-discovered prop_ tests)
    runTests
    ) where

import ShellCheck.AST
import ShellCheck.ASTLib hiding (runTests)
import ShellCheck.AnalyzerLib hiding (runTests)
import ShellCheck.Interface

import Control.Monad (when)
import Control.Monad.RWS (ask)
import Data.Foldable (toList)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import Data.Maybe (listToMaybe, mapMaybe)

import Test.QuickCheck.All (quickCheckAll)

-- | Plugin API version. Bump when the API changes in incompatible ways.
-- Plugins can assert against this at compile time if needed:
--   _ = pluginApiVersion :: Int  -- fails if type changes
pluginApiVersion :: Int
pluginApiVersion = 2

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

-- | Doc-comments immediately preceding the given token in its parent's body
-- list, in source order (top to bottom).
--
-- "Immediately preceding" means strict line-adjacency: the comment's end
-- line must equal the target's start line minus 1, and each comment's start
-- line must equal the next comment's expected line. Any non-T_Comment
-- sibling or a blank-line gap terminates the block.
--
-- Returns [] if the token has no parent, isn't in a body list, or has no
-- line-adjacent preceding comments. Matches the bash convention where a
-- docstring is the contiguous # comment block sitting directly above the
-- declaration, with no blank line between.
getDocCommentsBefore :: Parameters -> Token -> [String]
getDocCommentsBefore params t =
    -- T_Function (and similar) isn't a direct child of T_Script's body
    -- — bash statements are wrapped in T_Pipeline → T_Redirecting. Walk
    -- up the parent chain until we find a token whose parent is a body-
    -- list container AND that contains the token in a body list.
    case findBodyMember t of
        Nothing -> []
        Just (member, siblings) ->
            let memberId = getId member
                memberLine = case Map.lookup memberId (tokenPositions params) of
                    Just (s, _) -> posLine s
                    Nothing     -> 0
                preceding = reverse $ takeWhile ((/= memberId) . getId) siblings
            in reverse $ collectBlock preceding (memberLine - 1)
  where
    findBodyMember :: Token -> Maybe (Token, [Token])
    findBodyMember tok =
        case Map.lookup (getId tok) (parentMap params) of
            Nothing -> Nothing
            Just parent ->
                case listToMaybe [ list | list <- docBodyLists parent
                                        , any ((== getId tok) . getId) list ] of
                    Just siblings -> Just (tok, siblings)
                    Nothing       -> findBodyMember parent

    collectBlock [] _ = []
    collectBlock (sib:rest) expectedLine =
        case sib of
            T_Comment cid str ->
                case Map.lookup cid (tokenPositions params) of
                    Just (start, end)
                      | posLine end == expectedLine ->
                            str : collectBlock rest (posLine start - 1)
                    _ -> []
            _ -> []

-- | Body lists where doc-comments may live as siblings. Mirrors the
-- splice scope in Parser.attachComments (kept in sync there).
-- Command-substitution constructors (T_DollarExpansion, T_Backticked,
-- T_ProcSub, T_DollarBraceCommandExpansion) are intentionally omitted
-- to preserve the bash inline-comment idiom.
docBodyLists :: Token -> [[Token]]
docBodyLists (T_Script _ _ body)                       = [body]
docBodyLists (T_BraceGroup _ body)                     = [body]
docBodyLists (T_Subshell _ body)                       = [body]
docBodyLists (T_IfExpression _ pairs els)              =
    els : concatMap (\(c, b) -> [c, b]) pairs
docBodyLists (T_WhileExpression _ c b)                 = [c, b]
docBodyLists (T_UntilExpression _ c b)                 = [c, b]
docBodyLists (T_ForIn _ _ _ b)                         = [b]
docBodyLists (T_ForArithmetic _ _ _ _ b)               = [b]
docBodyLists (T_SelectIn _ _ _ b)                      = [b]
docBodyLists _                                         = []

-- | getDocCommentsBefore scaffolding tests. The full T_Comment splice
-- needed to make these return non-empty results is staged for follow-up
-- (see Parser.hs TODO). This test verifies the accessor returns [] when
-- no T_Comment nodes are in the tree, which is the current state.
prop_docCommentsBefore_noneWhenNoComments =
    docCommentsForFirstFunction "foo() { :; }\n" == []

-- Test helper: parse src, find first T_Function, return getDocCommentsBefore.
docCommentsForFirstFunction :: String -> [String]
docCommentsForFirstFunction src =
    case prRoot pr of
        Nothing   -> []
        Just root ->
            let spec   = defaultSpec pr
                params = makeParameters spec
            in case findFirstFunction root of
                Nothing -> []
                Just f  -> getDocCommentsBefore params f
  where
    pr = pScript src

findFirstFunction :: Token -> Maybe Token
findFirstFunction t = case t of
    T_Function {}      -> Just t
    OuterToken _ inner ->
        case mapMaybe findFirstFunction (toList inner) of
            (x:_) -> Just x
            []    -> Nothing

return []
runTests = $quickCheckAll
