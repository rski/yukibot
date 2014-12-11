{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TupleSections         #-}

module Yukibot.State where

import Control.Applicative      ((<$>), (<*>), pure)
import Control.Monad            (join)
import Control.Monad.IO.Class   (MonadIO, liftIO)
import Data.Aeson               (FromJSON(..), ToJSON(..), Value(..), (.=), (.:?), (.!=), object, decode')
import Data.Aeson.Types         (emptyObject)
import Data.Aeson.Encode.Pretty (Config(..), encodePretty')
import Data.ByteString.Lazy     (ByteString)
import Data.Default.Class       (Default(..))
import Network.IRC.Asakura.State
import System.Directory         (doesFileExist)

import qualified Data.ByteString.Lazy            as B
import qualified Data.HashMap.Strict             as HM
import qualified Network.IRC.Asakura.Commands    as C
import qualified Network.IRC.Asakura.Permissions as P
import qualified Network.IRC.Asakura.Blacklist   as BL
import qualified Yukibot.Plugins.Initialise      as I
import qualified Yukibot.Plugins.LinkInfo        as L

-- *Live State

-- |The live state of the bot.
data YukibotState = YS
  { _commandState    :: C.CommandState
  , _permissionState :: P.PermissionState
  , _linkinfoState   :: L.LinkInfoCfg
  , _blacklistState  :: BL.BlacklistState
  , _initialState    :: I.InitialCfg
  , _original        :: Value
  }

-- *Snapshotting

-- |A snapshot of the bot.
data YukibotStateSnapshot = YSS
  { _commandSnapshot    :: C.CommandStateSnapshot
  , _permissionSnapshot :: P.PermissionStateSnapshot
  , _linkinfoSnapshot   :: L.LinkInfoCfg
  , _blacklistSnapshot  :: BL.BlacklistStateSnapshot
  , _initialSnapshot    :: I.InitialCfg
  , _originalSnapshot   :: Value
  }

instance Default YukibotStateSnapshot where
  def = YSS def def def def def emptyObject

instance Snapshot YukibotState YukibotStateSnapshot where
  snapshotSTM ys = do
    css <- snapshotSTM . _commandState    $ ys
    pss <- snapshotSTM . _permissionState $ ys
    bss <- snapshotSTM . _blacklistState  $ ys

    return YSS
      { _commandSnapshot    = css
      , _permissionSnapshot = pss
      , _linkinfoSnapshot   = _linkinfoState ys
      , _blacklistSnapshot  = bss
      , _initialSnapshot    = _initialState ys
      , _originalSnapshot   = _original ys
      }

instance Rollback YukibotStateSnapshot YukibotState where
  rollbackSTM yss = do
    cs <- rollbackSTM . _commandSnapshot    $ yss
    ps <- rollbackSTM . _permissionSnapshot $ yss
    bs <- rollbackSTM . _blacklistSnapshot  $ yss

    return YS
      { _commandState    = cs
      , _permissionState = ps
      , _linkinfoState   = _linkinfoSnapshot yss
      , _blacklistState  = bs
      , _initialState    = _initialSnapshot yss
      , _original        = _originalSnapshot yss
      }

instance ToJSON YukibotStateSnapshot where
  toJSON yss = object $
    [ "prefixes"    .= _commandSnapshot    yss
    , "permissions" .= _permissionSnapshot yss
    , "linkinfo"    .= _linkinfoSnapshot   yss
    , "blacklist"   .= _blacklistSnapshot  yss
    ]
    ++
    opairs (_originalSnapshot yss)

    where
      opairs (Object o) = reverse $ HM.foldlWithKey' (\ps k v -> (k,v):ps) [] o
      opairs _ = []

instance FromJSON YukibotStateSnapshot where
  parseJSON o@(Object v) = YSS
    <$> v .:? "prefixes"    .!= def
    <*> v .:? "permissions" .!= def
    <*> v .:? "linkinfo"    .!= def
    <*> v .:? "blacklist"   .!= def
    <*> v .:? "initial"     .!= def
    <*> pure o

  parseJSON _ = fail "Expected object"

-- *Initialisation

-- |Attempt to load a state from a lazy ByteString.
stateFromByteString :: (Functor m, MonadIO m) => ByteString -> m (Maybe YukibotState)
stateFromByteString bs =
  case decode' bs :: Maybe YukibotStateSnapshot of
    Just yss' -> Just <$> rollback yss'
    _ -> return Nothing

-- |Attempt to load a state from a file.
stateFromFile :: MonadIO m => FilePath -> m (Maybe YukibotState)
stateFromFile fp = liftIO $ do
  exists <- doesFileExist fp
  if exists
  then join $ stateFromByteString <$> B.readFile fp
  else return Nothing

-- *Saving

-- |Snapshot the state and save it to disk.
save :: (Functor m, MonadIO m) => FilePath -> YukibotState -> m ()
save fp ys = join $ saveSnapshot fp <$> snapshot ys

-- |Save a snapshot of the state to disk.
saveSnapshot :: MonadIO m => FilePath -> YukibotStateSnapshot -> m ()
saveSnapshot fp yss = liftIO $ B.writeFile fp bs
  where
    bs = encodePretty' (Config 4 compare) yss
