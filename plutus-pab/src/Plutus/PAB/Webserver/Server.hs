{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Plutus.PAB.Webserver.Server
    ( startServer
    , startServerDebug
    ) where

import           Control.Concurrent              (forkIO)
import           Control.Concurrent.Availability (Availability, available, newToken)
import qualified Control.Concurrent.STM          as STM
import           Control.Monad                   (void)
import           Control.Monad.Except            (ExceptT (ExceptT))
import           Control.Monad.IO.Class          (liftIO)
import           Data.Aeson                      (FromJSON, ToJSON)
import           Data.Bifunctor                  (first)
import qualified Data.ByteString.Lazy.Char8      as LBS
import           Data.Function                   ((&))
import           Data.Proxy                      (Proxy (Proxy))
import qualified Network.Wai.Handler.Warp        as Warp
import           Servant                         (Application, Handler (Handler), Raw, ServerT, err500, errBody,
                                                  hoistServer, serve, serveDirectoryFileServer, (:<|>) ((:<|>)))
import           Servant.Client                  (BaseUrl (baseUrlPort), ClientEnv)


import qualified Cardano.Wallet.API              as Wallet
import           Control.Monad.Freer.Extras.Log  (logInfo)
import           Plutus.PAB.Core                 (PABAction, PABRunner (..))
import qualified Plutus.PAB.Core                 as Core
import qualified Plutus.PAB.Effects.Contract     as Contract
import qualified Plutus.PAB.Monitoring.PABLogMsg as LM
import           Plutus.PAB.Types                (PABError, WebserverConfig (..), baseUrl)
import           Plutus.PAB.Webserver.API        (API, NewAPI, WSAPI)
import           Plutus.PAB.Webserver.Handler    (handlerNew, handlerOld, walletProxy)
import qualified Plutus.PAB.Webserver.WebSocket  as WS
import qualified Servant

asHandler :: forall t env a. PABRunner t env -> PABAction t env a -> Handler a
asHandler PABRunner{runPABAction} = Servant.Handler . ExceptT . fmap (first mapError) . runPABAction where
    mapError :: PABError -> Servant.ServerError
    mapError e = Servant.err500 { Servant.errBody = LBS.pack $ show e }

type CombinedAPI t =
      API (Contract.ContractDef t)
      :<|> WSAPI
      :<|> NewAPI (Contract.ContractDef t)

type WalletProxy = "wallet" Servant.:> Wallet.API

app ::
    forall t env.
    ( FromJSON (Contract.ContractDef t)
    , ToJSON (Contract.ContractDef t)
    , Contract.PABContract t
    , Servant.MimeUnrender Servant.JSON (Contract.ContractDef t)
    ) =>
    Maybe FilePath
    -> Maybe ClientEnv -- ^ wallet client (if wallet proxy is enabled)
    -> PABRunner t env
    -> Application
app fp walletClient pabRunner = do
    let apiServer :: ServerT (CombinedAPI t) Handler
        apiServer =
            Servant.hoistServer
                (Proxy @(CombinedAPI t))
                (asHandler pabRunner)
                (handlerOld :<|> WS.combinedWebsocket :<|> handlerNew)

    case fp of
        Nothing ->
            case walletClient of
                Nothing -> do
                    let rest = Proxy @(CombinedAPI t)
                    Servant.serve rest apiServer
                Just wc -> do
                    let rest = Proxy @(CombinedAPI t :<|> WalletProxy)
                        wpServer =
                            Servant.hoistServer
                                (Proxy @WalletProxy)
                                (asHandler pabRunner)
                                (walletProxy wc)
                    Servant.serve rest (apiServer :<|> wpServer)
        Just filePath -> do
            case walletClient of
                Nothing -> do
                    let fileServer :: ServerT Raw Handler
                        fileServer = serveDirectoryFileServer filePath
                        rest = Proxy @(CombinedAPI t :<|> Raw)
                    Servant.serve rest (apiServer :<|> fileServer)
                Just wc -> do
                    let fileServer :: ServerT Raw Handler
                        fileServer = serveDirectoryFileServer filePath
                        wpServer =
                            Servant.hoistServer
                                (Proxy @WalletProxy)
                                (asHandler pabRunner)
                                (walletProxy wc)
                        rest = Proxy @(CombinedAPI t :<|> WalletProxy :<|> Raw)
                    Servant.serve rest (apiServer :<|> wpServer :<|> fileServer)


-- | Start the server using the config. Returns an action that shuts it down
--   again.
startServer ::
    forall t env.
    ( FromJSON (Contract.ContractDef t)
    , ToJSON (Contract.ContractDef t)
    , Contract.PABContract t
    , Servant.MimeUnrender Servant.JSON (Contract.ContractDef t)
    )
    => WebserverConfig -- ^ Optional file path for static assets
    -> Maybe ClientEnv
    -> Availability
    -> PABAction t env (PABAction t env ())
startServer WebserverConfig{baseUrl, staticDir} walletClient availability =
    startServer' (baseUrlPort baseUrl) walletClient (Just staticDir) availability

-- | Start the server. Returns an action that shuts it down
--   again.
startServer' ::
    forall t env.
    ( FromJSON (Contract.ContractDef t)
    , ToJSON (Contract.ContractDef t)
    , Contract.PABContract t
    , Servant.MimeUnrender Servant.JSON (Contract.ContractDef t)
    )
    => Int -- ^ Port
    -> Maybe ClientEnv -- ^ Optional client env. for connecting to wallet server
    -> Maybe FilePath -- ^ Optional file path for static assets
    -> Availability
    -> PABAction t env (PABAction t env ())
startServer' port walletClient fp availability = do
    simRunner <- Core.pabRunner
    shutdownVar <- liftIO $ STM.atomically $ STM.newEmptyTMVar @()

    let shutdownHandler :: IO () -> IO ()
        shutdownHandler doShutdown = void $ forkIO $ do
            STM.atomically $ STM.takeTMVar shutdownVar
            putStrLn "webserver: shutting down"
            doShutdown
        warpSettings :: Warp.Settings
        warpSettings = Warp.defaultSettings
            & Warp.setPort port
            & Warp.setInstallShutdownHandler shutdownHandler
            & Warp.setBeforeMainLoop (available availability)
    logInfo @(LM.PABMultiAgentMsg t) (LM.StartingPABBackendServer port)
    _ <- liftIO $ forkIO $ Warp.runSettings warpSettings $ app fp walletClient simRunner
    pure (liftIO $ STM.atomically $ STM.putTMVar shutdownVar ())

-- | Start the server using default configuration for debugging.
startServerDebug ::
    ( FromJSON (Contract.ContractDef t)
    , ToJSON (Contract.ContractDef t)
    , Contract.PABContract t
    , Servant.MimeUnrender Servant.JSON (Contract.ContractDef t)
    )
    => PABAction t env (PABAction t env ())
startServerDebug = do
    tk <- newToken
    startServer' 8080 Nothing Nothing tk
