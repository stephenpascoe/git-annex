{- git-annex uuids
 -
 - Each git repository used by git-annex has an annex.uuid setting that
 - uniquely identifies that repository.
 -
 - UUIDs of remotes are cached in git config, using keys named
 - remote.<name>.annex-uuid
 -
 - uuid.log stores a list of known uuids, and their descriptions.
 -
 - Copyright 2010-2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Logs.UUID (
	describeUUID,
	recordUUID,
	uuidMap
) where

import qualified Data.Map as M
import Data.Time.Clock.POSIX

import Common.Annex
import qualified Annex.Branch
import Logs.UUIDBased
import qualified Annex.UUID

{- Filename of uuid.log. -}
logfile :: FilePath
logfile = "uuid.log"

{- Records a description for a uuid in the log. -}
describeUUID :: UUID -> String -> Annex ()
describeUUID uuid desc = do
	ts <- liftIO getPOSIXTime
	Annex.Branch.change logfile $
		showLog id . changeLog ts uuid desc . fixBadUUID . parseLog Just

{- Temporarily here to fix badly formatted uuid logs generated by
 - versions 3.20111105 and 3.20111025. 
 -
 - Those logs contain entries with the UUID and description flipped.
 - Due to parsing, if the description is multiword, only the first
 - will be taken to be the UUID. So, if the UUID of an entry does
 - not look like a UUID, and the last word of the description does,
 - flip them back.
 -}
fixBadUUID :: Log String -> Log String
fixBadUUID = M.fromList . map fixup . M.toList
	where
		fixup (k, v)
			| isbad = (fixeduuid, LogEntry (Date $ newertime v) fixedvalue)
			| otherwise = (k, v)
			where
				kuuid = fromUUID k
				isbad = not (isuuid kuuid) && isuuid lastword
				ws = words $ value v
				lastword = Prelude.last ws
				fixeduuid = toUUID lastword
				fixedvalue = unwords $ kuuid: Prelude.init ws
		-- For the fixed line to take precidence, it should be
		-- slightly newer, but only slightly.
		newertime (LogEntry (Date d) _) = d + minimumPOSIXTimeSlice
		newertime (LogEntry Unknown _) = minimumPOSIXTimeSlice
		minimumPOSIXTimeSlice = 0.000001
		isuuid s = length s == 36 && length (split "-" s) == 5

{- Records the uuid in the log, if it's not already there. -}
recordUUID :: UUID -> Annex ()
recordUUID u = go . M.lookup u =<< uuidMap 
	where
		go (Just "") = set
		go Nothing = set
		go _ = noop
		set = describeUUID u ""

{- Read the uuidLog into a simple Map.
 -
 - The UUID of the current repository is included explicitly, since
 - it may not have been described and so otherwise would not appear. -}
uuidMap :: Annex (M.Map UUID String)
uuidMap = do
	m <- (simpleMap . parseLog Just) <$> Annex.Branch.get logfile
	u <- Annex.UUID.getUUID
	return $ M.insertWith' preferold u "" m
	where
		preferold = flip const
