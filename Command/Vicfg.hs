{- git-annex command
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Vicfg where

import qualified Data.Map as M
import qualified Data.Set as S
import System.Environment (getEnv)
import Data.Tuple (swap)
import Data.Char (isSpace)

import Common.Annex
import Command
import Annex.Perms
import Types.TrustLevel
import Types.Group
import Logs.Trust
import Logs.Group
import Logs.PreferredContent
import Remote

def :: [Command]
def = [command "vicfg" paramNothing seek
	"edit git-annex's configuration"]

seek :: [CommandSeek]
seek = [withNothing start]

start :: CommandStart
start = do
	f <- fromRepo gitAnnexTmpCfgFile
	createAnnexDirectory $ parentDir f
	cfg <- getCfg
	liftIO $ writeFile f $ genCfg cfg
	vicfg cfg f
	stop

vicfg :: Cfg -> FilePath -> Annex ()
vicfg curcfg f = do
	vi <- liftIO $ catchDefaultIO "vi" $ getEnv "EDITOR"
	-- Allow EDITOR to be processed by the shell, so it can contain options.
	unlessM (liftIO $ boolSystem "sh" [Param "-c", Param $ unwords [vi, f]]) $
		error $ vi ++ " exited nonzero; aborting"
	r <- parseCfg curcfg <$> liftIO (readFileStrict f)
	liftIO $ nukeFile f
	case r of
		Left s -> do
			liftIO $ writeFile f s
			vicfg curcfg f
		Right newcfg -> setCfg curcfg newcfg

data Cfg = Cfg
	{ cfgTrustMap :: TrustMap
	, cfgGroupMap :: M.Map UUID (S.Set Group)
	, cfgPreferredContentMap :: M.Map UUID String
	, cfgDescriptions :: M.Map UUID String
	}

getCfg :: Annex Cfg
getCfg = Cfg
	<$> trustMapRaw -- without local trust overrides
	<*> (groupsByUUID <$> groupMap)
	<*> preferredContentMapRaw
	<*> uuidDescriptions

setCfg :: Cfg -> Cfg -> Annex ()
setCfg curcfg newcfg = do
	let (trustchanges, groupchanges, preferredcontentchanges) = diffCfg curcfg newcfg
	mapM_ (uncurry trustSet) $ M.toList trustchanges
	mapM_ (uncurry groupSet) $ M.toList groupchanges
	mapM_ (uncurry preferredContentSet) $ M.toList preferredcontentchanges

diffCfg :: Cfg -> Cfg -> (TrustMap, M.Map UUID (S.Set Group), M.Map UUID String)
diffCfg curcfg newcfg = (diff cfgTrustMap, diff cfgGroupMap, diff cfgPreferredContentMap)
	where
		diff f = M.differenceWith (\x y -> if x == y then Nothing else Just x)
			(f newcfg) (f curcfg)

genCfg :: Cfg -> String
genCfg cfg = unlines $ concat
	[ intro
	, trustintro, trust, defaulttrust
	, groupsintro, groups, defaultgroups
	, preferredcontentintro, preferredcontent, defaultpreferredcontent
	]
	where
		intro =
			[ com "git-annex configuration"
			, com ""
			, com "Changes saved to this file will be recorded in the git-annex branch."
			, com ""
			, com "Lines in this file have the format:"
			, com "  setting repo = value"
			]

		trustintro =
			[ ""
			, com "Repository trust configuration"
			, com "(Valid trust levels: " ++
			  unwords (map showTrustLevel [Trusted .. DeadTrusted]) ++
			  ")"
			]
		trust = map (\(t, u) -> line "trust" u $ showTrustLevel t) $
			sort $ map swap $ M.toList $ cfgTrustMap cfg

		defaulttrust = map (\u -> pcom $ line "trust" u $ showTrustLevel SemiTrusted) $
			missing cfgTrustMap
		groupsintro = 
			[ ""
			, com "Repository groups"
			, com "(Separate group names with spaces)"
			]
		groups = sort $ map (\(s, u) -> line "group" u $ unwords $ S.toList s) $
			map swap $ M.toList $ cfgGroupMap cfg
		defaultgroups = map (\u -> pcom $ line "group" u "") $
			missing cfgGroupMap

		preferredcontentintro = 
			[ ""
			, com "Repository preferred contents"
			]
		preferredcontent = sort $ map (\(s, u) -> line "preferred-content" u s) $
			map swap $ M.toList $ cfgPreferredContentMap cfg
		defaultpreferredcontent = map (\u -> pcom $ line "preferred-content" u "") $
			missing cfgPreferredContentMap

		line setting u value = unwords
			[ setting
			, showu u
			, "=" 
			, value
			]
		pcom s = "#" ++ s
		showu u = fromMaybe (fromUUID u) $
			M.lookup u (cfgDescriptions cfg)
		missing field = S.toList $ M.keysSet (cfgDescriptions cfg) `S.difference` M.keysSet (field cfg)

{- If there's a parse error, returns a new version of the file,
 - with the problem lines noted. -}
parseCfg :: Cfg -> String -> Either String Cfg
parseCfg curcfg = go [] curcfg . lines
	where
		go c cfg []
			| null (catMaybes $ map fst c) = Right cfg
			| otherwise = Left $ unlines $
				badheader ++ concatMap showerr (reverse c)
		go c cfg (l:ls) = case parse (dropWhile isSpace l) cfg of
			Left msg -> go ((Just msg, l):c) cfg ls
			Right cfg' -> go ((Nothing, l):c) cfg' ls

		parse l cfg
			| null l = Right cfg
			| "#" `isPrefixOf` l = Right cfg
			| null setting || null repo' = Left "missing repository name"
			| otherwise = case M.lookup repo' name2uuid of
				Nothing -> badval "repository" repo'
				Just u -> handle cfg u setting value'
			where
				(setting, rest) = separate isSpace l
				(repo, value) = separate (== '=') rest
				value' = trimspace value
				repo' = reverse $ trimspace $
					reverse $ trimspace repo
				trimspace = dropWhile isSpace

		handle cfg u setting value
			| setting == "trust" = case readTrustLevel value of
				Nothing -> badval "trust value" value
				Just t ->
					let m = M.insert u t (cfgTrustMap cfg)
					in Right $ cfg { cfgTrustMap = m }
			| setting == "group" =
				let m = M.insert u (S.fromList $ words value) (cfgGroupMap cfg)
				in Right $ cfg { cfgGroupMap = m }
			| setting == "preferred-content" = 
				case checkPreferredContentExpression value of
					Just e -> Left e
					Nothing ->
						let m = M.insert u value (cfgPreferredContentMap cfg)
						in Right $ cfg { cfgPreferredContentMap = m }
			| otherwise = badval "setting" setting

		name2uuid = M.fromList $ map swap $
			M.toList $ cfgDescriptions curcfg

		showerr (Just msg, l) = [parseerr ++ msg, l]
		showerr (Nothing, l)
			-- filter out the header and parse error lines
			-- from any previous parse failure
			| any (`isPrefixOf` l) (parseerr:badheader) = []
			| otherwise = [l]

		badval desc val = Left $ "unknown " ++ desc ++ " \"" ++ val ++ "\""
		badheader = 
			[ com "There was a problem parsing your input."
			, com "Search for \"Parse error\" to find the bad lines."
			, com "Either fix the bad lines, or delete them (to discard your changes)."
			]
		parseerr = com "Parse error in next line: "

com :: String -> String
com s = "# " ++ s