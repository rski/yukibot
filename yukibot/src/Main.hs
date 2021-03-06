{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import Control.Concurrent.STM (atomically, readTVar)
import Control.Monad.Trans.Reader (runReaderT)
import Network.IRC.Bot
import Network.IRC.Bot.Commands (CommandDef(..), registerCommand)
import Network.IRC.Bot.State (rollback)
import Network.IRC.Bot.Types
import Network.IRC.Client
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Posix.Signals (Handler(..), installHandler, sigINT, sigTERM)

import Yukibot.State
import Yukibot.Utils

import qualified Network.IRC.Bot.Blacklist   as BL
import qualified Network.IRC.Bot.Commands    as C
import qualified Network.IRC.Bot.Help        as H
import qualified Network.IRC.Bot.Permissions as P
import qualified Yukibot.Plugins.Brainfuck   as BF
import qualified Yukibot.Plugins.Cellular    as CA
import qualified Yukibot.Plugins.Channels    as CH
import qualified Yukibot.Plugins.Dedebtifier as D
import qualified Yukibot.Plugins.Initialise  as I
import qualified Yukibot.Plugins.LinkInfo    as L
import qualified Yukibot.Plugins.Memory      as M
import qualified Yukibot.Plugins.Mueval      as Mu
import qualified Yukibot.Plugins.Seen        as S
import qualified Yukibot.Plugins.Trigger     as T

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
       else Just <$> rollback defaultBotState

  case ys of
    Just ys' -> runWithState configFile ys'
    Nothing  -> putStrLn "Failed to parse configuration file." >> exitFailure

-- |Run the bot with a given state.
runWithState :: FilePath -> YukibotState -> IO ()
runWithState fp ys = do
  state <- newBotState' $ _original ys

  let ps  = _permissionState ys
  let cs  = _commandState    ys
  let bs  = _blacklistState  ys
  let ls  = _linkinfoState   ys
  let wfs = M.simpleFactStore (defaultMongo' (_config state) "watching") "watching"
  let ds  = defaultMongo' (_config state) "debts"

  -- Register signal handlers
  installHandler sigINT  (Catch $ handler state) Nothing
  installHandler sigTERM (Catch $ handler state) Nothing

  -- Register commands
  registerCommand cs $ H.helpCmd cs

  registerCommand cs $ P.wrapsCmd ps (P.Admin 0)   CH.joinCmd
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0)   CH.partCmd
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0) $ CH.setChanPrefix   cs
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0) $ CH.unsetChanPrefix cs
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0) $ BL.blacklistCmd    bs
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0) $ BL.whitelistCmd    bs
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0)   T.addTriggerCmd
  registerCommand cs $ P.wrapsCmd ps (P.Admin 0)   T.rmTriggerCmd
  registerCommand cs   T.listTriggerCmd

  registerCommand cs $ BL.wrapsCmd bs "watching" $ (M.simpleGetCommand wfs) { _verb = ["watching"] }
  registerCommand cs $ BL.wrapsCmd bs "watching" $ (M.simpleSetCommand wfs) { _verb = ["set", "watching"] }
  registerCommand cs $ BL.wrapsCmd bs "seen"        S.command
  registerCommand cs $ BL.wrapsCmd bs "cellular"    CA.command
  registerCommand cs $ BL.wrapsCmd bs "brainfuck"   BF.command
  registerCommand cs $ BL.wrapsCmd bs "brainfuck"   BF.command8bit
  registerCommand cs $ BL.wrapsCmd bs "debts"    $  D.oweCmd  ds
  registerCommand cs $ BL.wrapsCmd bs "debts"    $  D.owedCmd ds
  registerCommand cs $ BL.wrapsCmd bs "debts"    $  D.payCmd  ds
  registerCommand cs $ BL.wrapsCmd bs "debts"    $  D.listCmd ds
  registerCommand cs $ BL.wrapsCmd bs "eval"        Mu.evalCommand
  registerCommand cs $ BL.wrapsCmd bs "type"        Mu.typeCommand
  registerCommand cs $ BL.wrapsCmd bs "kind"        Mu.kindCommand

  -- Register event handlers
  addGlobalEventHandler' state $ C.eventRunner cs

  addGlobalEventHandler' state $ BL.wraps bs "seen"          S.eventHandler
  addGlobalEventHandler' state $ BL.wraps bs "linkinfo"    $ L.eventHandler ls
  addGlobalEventHandler' state $ BL.wraps bs "triggers"      T.eventHandler
  addGlobalEventHandler' state $ BL.wraps bs "inline-eval"   Mu.evalEvent
  addGlobalEventHandler' state $ BL.wraps bs "inline-eval"   Mu.typeEvent
  addGlobalEventHandler' state $ BL.wraps bs "inline-eval"   Mu.kindEvent

  addGlobalEventHandler' state $ P.wrapsEv ps (P.Trusted 0) CH.inviteEv

  -- Connect to networks
  I.initialiseWithState state

  -- Block until all networks have been disconnected from
  blockWithState state

  -- Save the state
  save fp ys

-- |Handle a signal by disconnecting from every IRC network.
handler :: BotState () -> IO ()
handler botstate = (atomically . readTVar . _connections $ botstate) >>= mapM_ (runReaderT dc . snd) where
  dc = do
    send . Quit $ Just "Process interrupted."
    disconnect
