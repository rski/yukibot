{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

-- |Blacklist plugins on a per-channel basis
module Network.IRC.Bot.Blacklist
  ( -- *State
    BlacklistState
  , BlacklistStateSnapshot
  , defaultBlacklistState
  -- *Commands
  , blacklistCmd
  , whitelistCmd
  -- *Integration
  , blacklist
  , whitelist
  , ifNotBlacklisted
  , wraps
  , wrapsCmd
  ) where

import Control.Concurrent.STM (atomically, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text, isPrefixOf)
import Network.IRC.Client.Types ( ConnectionConfig(_server)
                                , Event(..)
                                , StatefulIRC, IRCState, Source(..)
                                , UnicodeEvent
                                , connectionConfig
                                , getConnectionConfig)

import Network.IRC.Bot.Blacklist.State
import Network.IRC.Bot.Commands
import Network.IRC.Bot.Types
import Network.IRC.Bot.Utils

import qualified Data.Map as M

-- *Commands

-- |Usage: "<command> <plugin>" in channel, or "<command> <channel>
-- <plugin>" in query
blacklistCmd :: BlacklistState -> CommandDef s
blacklistCmd bs = CommandDef
  { _verb   = ["blacklist"]
  , _help   = "Prevent a named entity from running."
  , _action = doCmd (blacklist bs)
  }

-- |Same usage as 'blacklistCmd'.
whitelistCmd :: BlacklistState -> CommandDef s
whitelistCmd bs = CommandDef
  { _verb   = ["whitelist"]
  , _help   = "Remove a named entity from the blacklist."
  , _action = doCmd (whitelist bs)
  }

doCmd :: (ByteString -> Text -> Text -> StatefulIRC s ()) -> [Text] -> IRCState s -> UnicodeEvent -> StatefulBot s (StatefulIRC s ())
doCmd f (x:xs) _ ev = return $ do
  network <- _server <$> connectionConfig

  case _source ev of
    Channel c _ -> mapM_ (f network c) $ x:xs
    _ | "#" `isPrefixOf` x -> mapM_ (f network x) xs
      | otherwise -> reply ev "Which channel?"

doCmd _ [] _ ev = return . reply ev $ "Name at least one plugin."

-- *Integration

-- |Blacklist a plugin in a channel
blacklist :: MonadIO m => BlacklistState -> ByteString -> Text -> Text -> m ()
blacklist bs network channel plugin = liftIO . atomically $ do
  let tvarB = _blacklist bs
  bl <- readTVar tvarB
  writeTVar tvarB $ alterBL bl network channel (plugin:)

-- |Whitelist a plugin in a channel
whitelist :: MonadIO m => BlacklistState -> ByteString -> Text -> Text -> m ()
whitelist bs network channel plugin = liftIO . atomically $ do
  let tvarB = _blacklist bs
  bl <- readTVar tvarB
  writeTVar tvarB $ alterBL bl network channel (filter (/=plugin))

-- |Event handler channel filter using a blacklist
ifNotBlacklisted :: MonadIO m => BlacklistState -> Text -> ByteString -> Text -> m Bool
ifNotBlacklisted bs plugin network channel = liftIO . atomically $ do
  let tvarB = _blacklist bs
  bl <- readTVar tvarB
  return . not $ plugin `elem` chan bl

  where
    chan bl = [] `fromMaybe` M.lookup channel (netw bl)
    netw bl = M.empty `fromMaybe` M.lookup network bl

-- |Produce a new event handler which respects the blacklist
wraps :: BlacklistState -> Text -> EventHandler s -> EventHandler s
wraps bs plugin evh = evh { _appliesTo = ifNotBlacklisted bs plugin }

-- |Produce a new command which respects the blacklist
wrapsCmd :: BlacklistState -> Text -> CommandDef s -> CommandDef s
wrapsCmd bs name cdef = cdef { _action = wrapped $ _action cdef } where
  wrapped f args ircstate ev = do
    let network = _server $ getConnectionConfig ircstate

    case _source ev of
      Channel c _ -> do
        ifbl <- ifNotBlacklisted bs name network c
        if ifbl
        then f args ircstate ev
        else return $ return ()

      _ -> f args ircstate ev

alterBL :: Map ByteString (Map Text [Text]) -> ByteString -> Text -> ([Text] -> [Text]) -> Map ByteString (Map Text [Text])
alterBL bl network channel f = M.alter netf network bl where
  netf = Just . M.alter f' channel . fromMaybe M.empty
  f' xs =
    case f $ fromMaybe [] xs of
      [] -> Nothing
      ys -> Just ys
