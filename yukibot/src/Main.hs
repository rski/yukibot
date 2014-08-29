{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Applicative    ((<$>))
import Control.Concurrent.STM (atomically, readTVar)
import Control.Monad          (void)
import Control.Monad.Trans.Reader (runReaderT)
import Data.Default.Class     (def)
import Network.IRC.Asakura
import Network.IRC.Asakura.State (rollback)
import Network.IRC.Asakura.Types
import Network.IRC.IDTE
import System.Directory       (doesFileExist)
import System.Environment     (getArgs)
import System.Exit            (exitFailure)
import System.Posix.Signals   (Handler(..), installHandler, sigINT, sigTERM)
import Yukibot.State

import qualified Network.IRC.Asakura.Commands    as C
import qualified Network.IRC.Asakura.Permissions as P
import qualified Yukibot.Plugins.Channels        as CH
import qualified Yukibot.Plugins.ImgurLinks      as I
import qualified Yukibot.Plugins.LinkInfo        as L
import qualified Yukibot.Plugins.LinkInfo.Common as LC
import qualified Yukibot.Plugins.MAL             as M
import qualified Yukibot.Plugins.Memory          as Me
import qualified Yukibot.Plugins.Trigger         as T

-- |Default configuration file name
defaultConfigFile :: FilePath
defaultConfigFile = "yukibot.json"

-- |Load the configuration file, if it exists, otherwise initialise a
-- new state. Upon successfully constructing a state, run the bot.
main :: IO ()
main = do
  configFile <- do
    args <- getArgs
    return $ case args of
      (cfg:_) -> cfg
      _       -> defaultConfigFile

  confExists <- doesFileExist configFile
  ys <- if confExists
       then stateFromFile configFile
       else Just <$> rollback (def :: YukibotStateSnapshot)

  case ys of
    Just ys' -> runWithState configFile ys'
    Nothing  -> putStrLn "Failed to parse configuration file." >> exitFailure

-- |Run the bot with a given state.
runWithState :: FilePath -> YukibotState -> IO ()
runWithState fp ys = do
  cconf <- connect "irc.freenode.net" 6667
  state <- newBotState

  -- Register signal handlers
  installHandler sigINT  (Catch $ handler state) Nothing
  installHandler sigTERM (Catch $ handler state) Nothing

  -- Start commands
  let cs = _commandState ys

  C.registerCommand cs "join" (Just $ P.Admin 0) CH.joinCmd
  C.registerCommand cs "part" (Just $ P.Admin 0) CH.partCmd
  C.registerCommand cs "mal" Nothing $ M.malCommand (_malState ys)

  let ms  = _memoryState ys
  let wfs = Me.simpleFactStore ms "watching"

  C.registerCommand cs "watching"     Nothing $ Me.simpleGetCommand wfs
  C.registerCommand cs "watching.set" Nothing $ Me.simpleSetCommand wfs

  addGlobalEventHandler' state $ C.eventRunner cs

  -- Start LinkInfo
  let lis = LC.addLinkHandler (_linkinfoState ys) I.licPredicate I.licHandler
  addGlobalEventHandler' state $ L.eventHandler lis

  -- Start triggers
  let ts = _triggerState ys
  addGlobalEventHandler' state $ T.eventHandler ts

  case cconf of
    Right cconf' -> do
      void $ run cconf' (defaultIRCConf "yukibot") state
      save fp ys

    Left err -> putStrLn err >> exitFailure

-- |Handle a signal by disconnecting from every IRC network.
handler :: BotState -> IO ()
handler botstate = (atomically . readTVar . _connections $ botstate) >>= mapM_ (runReaderT dc . snd)
    where dc = do
            send . quit $ Just "Process interrupted."
            disconnect
