{- git-annex remotes
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remote (
	Remote,
	uuid,
	name,
	storeKey,
	retrieveKeyFile,
	removeKey,
	hasKey,
	hasKeyCheap,

	byName,
	nameToUUID,
	keyPossibilities,
	remotesWithUUID,
	remotesWithoutUUID,

	configGet,
	configSet,
	keyValToMap
) where

import Control.Monad.State (liftIO)
import Control.Monad (when, liftM)
import Data.List
import Data.String.Utils
import qualified Data.Map as M
import Data.Maybe

import RemoteClass
import qualified Remote.Git
import qualified Remote.S3
import Types
import UUID
import qualified Annex
import Trust
import LocationLog
import Locations
import Messages

remoteTypes :: [RemoteType Annex]
remoteTypes =
	[ Remote.Git.remote
	, Remote.S3.remote
	]

{- Runs the generators of each type of Remote -}
runGenerators :: Annex [Remote Annex]
runGenerators = do
	(actions, expensive) <- collect ([], []) $ map generator remoteTypes
	when (not $ null expensive) $
		showNote $ "getting UUID for " ++ join ", " expensive
	sequence actions
	where
		collect v [] = return v
		collect (actions, expensive) (x:xs) = do
			(a, e) <- x
			collect (a++actions, e++expensive) xs

{- Builds a list of all available Remotes.
 - Since doing so can be expensive, the list is cached in the Annex. -}
genList :: Annex [Remote Annex]
genList = do
	rs <- Annex.getState Annex.remotes
	if null rs
		then do
			rs' <- runGenerators
			Annex.changeState $ \s -> s { Annex.remotes = rs' }
			return rs'
		else return rs

{- Looks up a remote by name. (Or by UUID.) -}
byName :: String -> Annex (Remote Annex)
byName "" = error "no remote specified"
byName n = do
	allremotes <- genList
	let match = filter matching allremotes
	when (null match) $ error $
		"there is no git remote named \"" ++ n ++ "\""
	return $ head match
	where
		matching r = n == name r || n == uuid r

{- Looks up a remote by name (or by UUID), and returns its UUID. -}
nameToUUID :: String -> Annex UUID
nameToUUID "." = do -- special case for current repo
	g <- Annex.gitRepo
	getUUID g
nameToUUID n = liftM uuid (byName n)

{- Cost ordered lists of remotes that the LocationLog indicate may have a key.
 -
 - Also returns a list of UUIDs that are trusted to have the key
 - (some may not have configured remotes).
 -}
keyPossibilities :: Key -> Annex ([Remote Annex], [UUID])
keyPossibilities key = do
	g <- Annex.gitRepo
	u <- getUUID g
	trusted <- trustGet Trusted

	-- get uuids of all remotes that are recorded to have the key
	uuids <- liftIO $ keyLocations g key
	let validuuids = filter (/= u) uuids

	-- note that validuuids is assumed to not have dups
	let validtrusteduuids = intersect validuuids trusted

	-- remotes that match uuids that have the key
	allremotes <- genList
	let validremotes = remotesWithUUID allremotes validuuids

	return (sort validremotes, validtrusteduuids)

{- Filters a list of remotes to ones that have the listed uuids. -}
remotesWithUUID :: [Remote Annex] -> [UUID] -> [Remote Annex]
remotesWithUUID rs us = filter (\r -> uuid r `elem` us) rs

{- Filters a list of remotes to ones that do not have the listed uuids. -}
remotesWithoutUUID :: [Remote Annex] -> [UUID] -> [Remote Annex]
remotesWithoutUUID rs us = filter (\r -> uuid r `notElem` us) rs

{- Filename of remote.log. -}
remoteLog :: Annex FilePath
remoteLog = do
	g <- Annex.gitRepo
	return $ gitStateDir g ++ "remote.log"

{- Reads the uuid and config of the specified remote from the remoteLog. -}
configGet :: String -> Annex (Maybe (UUID, M.Map String String))
configGet n = do
	rs <- readRemoteLog
	let matches = filter (matchName n) rs
	case matches of
		[] -> return Nothing
		((u, _, c):_) -> return $ Just (u, c)

{- Changes or adds a remote's config in the remoteLog. -}
configSet :: String -> UUID -> M.Map String String -> Annex ()
configSet n u c = do
	rs <- readRemoteLog
	let others = filter (not . matchName n) rs
	writeRemoteLog $ (u, n, c):others

matchName :: String -> (UUID, String, M.Map String String) -> Bool
matchName n (_, n', _) = n == n'

readRemoteLog :: Annex [(UUID, String, M.Map String String)]
readRemoteLog = do
	l <- remoteLog
	s <- liftIO $ catch (readFile l) ignoreerror
	return $ remoteLogParse s
	where
		ignoreerror _ = return []

writeRemoteLog :: [(UUID, String, M.Map String String)] -> Annex ()
writeRemoteLog rs = do
	l <- remoteLog
	liftIO $ writeFile l $ unlines $ map toline rs
	where
		toline (u, n, c) = u ++ " " ++ n ++ (unwords $ mapToKeyVal c)

remoteLogParse :: String -> [(UUID, String, M.Map String String)]
remoteLogParse s = catMaybes $ map parseline $ filter (not . null) $ lines s
	where
		parseline l
			| length w > 2 = Just (u, n, c)
			| otherwise = Nothing
			where
				w = words l
				u = w !! 0
				n = w !! 1
				c = keyValToMap $ drop 2 w

{- Given Strings like "key=value", generates a Map. -}
keyValToMap :: [String] -> M.Map String String
keyValToMap ws = M.fromList $ map (/=/) ws
	where
		(/=/) s = (k, v)
			where
				k = takeWhile (/= '=') s
				v = drop (1 + length k) s

mapToKeyVal :: M.Map String String -> [String]
mapToKeyVal m = map toword $ M.toList m
	where
		toword (k, v) = k ++ "=" ++ v
