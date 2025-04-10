{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Node.Handlers.Shutdown
  ( ShutdownOn (..)
  , parseShutdownOn

  -- * Generalised shutdown handling
  , ShutdownConfig (..)
  , withShutdownHandling

  , ShutdownTrace (..)

  -- * Watch ChainDB for passing a configured slot sync limit threshold,
  --   translating it to a graceful shutdown.
  , maybeSpawnOnSlotSyncedShutdownHandler
  )
where


import           Cardano.Slotting.Slot (WithOrigin (..))
import           Ouroboros.Consensus.Block (Header)
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import           Ouroboros.Consensus.Util.STM (Watcher (..), forkLinkedWatcher)
import           Ouroboros.Network.Block (BlockNo (..), HasHeader, SlotNo (..), pointSlot)

import           Control.Concurrent.Async (race_)
import           Control.DeepSeq (NFData)
import           Control.Exception (try)
import           Control.Exception.Base (throwIO)
import           Control.Monad (void, when)
import           Control.ResourceRegistry (ResourceRegistry)
import           "contra-tracer" Control.Tracer
import           Data.Aeson (FromJSON, ToJSON)
import           Data.Foldable (asum)
import           Data.Text (Text, pack)
import           GHC.Generics (Generic)
import qualified GHC.IO.Handle.FD as IO (fdToHandle)
import qualified Options.Applicative as Opt
import           System.Exit (ExitCode (..))
import qualified System.IO as IO
import qualified System.IO.Error as IO
import           System.Posix.Types (Fd (Fd))
import qualified Text.Read as Read


import           Generic.Data.Orphans ()

data ShutdownOn
  = ASlot  !SlotNo
  | ABlock !BlockNo
  | NoShutdown
  deriving (Generic, Eq, Show)

deriving instance FromJSON ShutdownOn
deriving instance ToJSON ShutdownOn
deriving instance NFData ShutdownOn


parseShutdownOn :: Opt.Parser ShutdownOn
parseShutdownOn = asum
  [ Opt.option (ASlot . SlotNo <$> bounded "SLOT") $ mconcat
    [ Opt.long "shutdown-on-slot-synced"
    , Opt.metavar "SLOT"
    , Opt.help "Shut down the process after ChainDB is synced up to the specified slot"
    , Opt.hidden
    ]
  , Opt.option (ABlock . BlockNo <$> bounded "BLOCK") $ mconcat
    [ Opt.long "shutdown-on-block-synced"
    , Opt.metavar "BLOCK"
    , Opt.help "Shut down the process after ChainDB is synced up to the specified block"
    , Opt.hidden
    ]
  , pure NoShutdown
  ]
  where
    bounded :: forall a. (Bounded a, Integral a, Show a) => String -> Opt.ReadM a
    bounded t = Opt.eitherReader $ \s -> do
      i <- Read.readEither @Integer s
      when (i < fromIntegral (minBound @a)) $ Left $ t <> " must not be less than " <> show (minBound @a)
      when (i > fromIntegral (maxBound @a)) $ Left $ t <> " must not greater than " <> show (maxBound @a)
      pure (fromIntegral i)

data ShutdownTrace
  = ShutdownRequested
  -- ^ Received shutdown request
  | AbnormalShutdown
  -- ^ Non-isEOFError shutdown request
  | ShutdownUnexpectedInput Text
  -- ^ Received shutdown request but found unexpected input in --shutdown-ipc FD:
  | RequestingShutdown Text
  -- ^ Ringing the node shutdown doorbell for reason
  | ShutdownArmedAt ShutdownOn
  -- ^ Will terminate upon reaching a ChainDB sync limit
  deriving (Generic, FromJSON, ToJSON)

deriving instance NFData ShutdownTrace

data AndWithOrigin
  = AndWithOriginBlock (BlockNo, WithOrigin BlockNo)
  | AndWithOriginSlot (SlotNo, WithOrigin SlotNo)
  | WithoutOrigin

deriving instance Eq AndWithOrigin

data ShutdownConfig
  = ShutdownConfig
    { scIPC         :: !(Maybe Fd)
    , scOnSyncLimit :: !(Maybe ShutdownOn)
    }
    deriving (Eq, Show)

-- | We provide an optional cross-platform method to politely request shut down.
-- The parent process passes us the file descriptor number of the read end of a pipe,
-- via the CLI with @--shutdown-ipc FD@
withShutdownHandling
  :: ShutdownConfig
  -> Tracer IO ShutdownTrace
  -> IO ()
  -- ^ Action to potentially shutdown via file descriptor
  -> IO ()
withShutdownHandling ShutdownConfig{scIPC = Nothing} _ action = action
withShutdownHandling ShutdownConfig{scIPC = Just fd} tr action = do
  race_ (waitForEOF fd) action
 where
   waitForEOF :: Fd -> IO ()
   waitForEOF (Fd fileDesc) = do
     hnd <- IO.fdToHandle fileDesc
     r <- try $ IO.hGetChar hnd
     case r of
       Left e
         | IO.isEOFError e ->
             traceWith tr ShutdownRequested
         | otherwise -> do
             traceWith tr AbnormalShutdown
             throwIO e
       Right inp  ->
         traceWith tr (ShutdownUnexpectedInput . pack $ show inp)

-- | Spawn a thread that would cause node to shutdown upon ChainDB reaching the
-- configuration-defined slot.
maybeSpawnOnSlotSyncedShutdownHandler
  :: HasHeader (Header blk)
  => ShutdownConfig
  -> Tracer IO ShutdownTrace
  -> ResourceRegistry IO
  -> ChainDB.ChainDB IO blk
  -> IO ()
maybeSpawnOnSlotSyncedShutdownHandler sc tr registry chaindb =
  case scOnSyncLimit sc of
    Nothing -> pure ()
    Just lim -> do
      traceWith tr (ShutdownArmedAt lim)
      spawnLimitTerminator lim
 where
  spawnLimitTerminator :: ShutdownOn -> IO ()
  spawnLimitTerminator limit =
    void $ forkLinkedWatcher registry "slotLimitTerminator" Watcher {
        wFingerprint = id
      , wInitial     = Nothing
      , wReader      =
          case limit of
            ASlot   x -> AndWithOriginSlot . (x,) . pointSlot <$> ChainDB.getTipPoint chaindb
            ABlock  x -> AndWithOriginBlock . (x,) <$> ChainDB.getTipBlockNo chaindb
            NoShutdown -> return WithoutOrigin
      , wNotify      = \case
          (AndWithOriginSlot (lim, At cur)) ->
              when (cur >= lim) $ do
                traceWith tr (RequestingShutdown $ "spawnLimitTerminator: reached target slot "
                              <> (pack . show) cur)
                throwIO ExitSuccess
          (AndWithOriginBlock (lim, At cur)) ->
              when (cur >= lim) $ do
                traceWith tr (RequestingShutdown $ "spawnLimitTerminator: reached target block "
                              <> (pack . show) cur)
                throwIO ExitSuccess
          WithoutOrigin -> pure ()
          _ -> pure ()
      }
