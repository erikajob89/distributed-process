{-# LANGUAGE DeriveGeneric   #-}
module Control.Distributed.Process.Management.Types
  ( MxAgentId(..)
  , MxTableId(..)
  , MxAgentState(..)
  , MxAgent(..)
  , MxAction(..)
  , MxAgentStart(..)
  , Fork
  , MxSink
  , MxEvent(..)
  , Addressable(..)
  ) where

import Control.Applicative ((<$>), (<*>), Applicative)
import Control.Concurrent.STM
  ( TChan
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , Message
  , SendPort
  , DiedReason
  , NodeId
  )
import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State as ST
  ( MonadState
  , StateT
  , get
  , lift
  , runStateT
  )
import Data.Binary
import Data.Map.Strict (Map)
import Data.Typeable (Typeable)
import GHC.Generics
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  )

-- TODO: consider factoring out MxEvent's tracing specific constructors

-- | This is the /default/ management event, fired for various internal
-- events around the NT connection and Process lifecycle. All published
-- events that conform to this type, are eligible for tracing - i.e.,
-- they will be delivered to the trace controller.
--
data MxEvent =
    MxSpawned          ProcessId
    -- ^ fired whenever a local process is spawned
  | MxRegistered       ProcessId    String
    -- ^ fired whenever a process/name is registered (locally)
  | MxUnRegistered     ProcessId    String
    -- ^ fired whenever a process/name is unregistered (locally)
  | MxProcessDied      ProcessId    DiedReason
    -- ^ fired whenever a process dies
  | MxNodeDied         NodeId       DiedReason
    -- ^ fired whenever a node /dies/ (i.e., the connection is broken/disconnected)
  | MxSent             ProcessId    ProcessId Message
    -- ^ fired whenever a message is sent from a local process
  | MxReceived         ProcessId    Message
    -- ^ fired whenever a message is received by a local process
  | MxConnected        ConnectionId EndPointAddress
    -- ^ fired when a network-transport connection is first established
  | MxDisconnected     ConnectionId EndPointAddress
    -- ^ fired when a network-transport connection is broken/disconnected
  | MxUser             Message
    -- ^ a user defined trace event
  | MxLog              String
    -- ^ a /logging/ event - used for debugging purposes only
  | MxTraceTakeover    ProcessId
    -- ^ notifies a trace listener that all subsequent traces will be sent to /pid/
  | MxTraceDisable
    -- ^ notifies a trace listener that it has been disabled/removed
    deriving (Typeable, Generic, Show)

instance Binary MxEvent where

  -- put (MxSpawned pid)           = putWord8 1 >> put pid
  -- put (MxRegistered pid str)    = putWord8 2 >> put pid >> put str
  -- put (MxUnRegistered pid str)  = putWord8 3 >> put pid >> put str
  -- put (MxProcessDied pid res)   = putWord8 4 >> put pid >> put res
  -- put (MxNodeDied nid res)      = putWord8 5 >> put nid >> put res
  -- put (MxSent to fro msg)       = putWord8 6 >> put to >> put fro >> put msg
  -- put (MxReceived pid msg)      = putWord8 7 >> put pid >> put msg
  -- put (MxConnected cid epid)    = putWord8 8 >> put cid >> put epid
  -- put (MxDisconnected cid epid) = putWord8 9 >> put cid >> put epid
  -- put (MxUser msg)              = putWord8 10 >> put msg
  -- put (MxLog  msg)              = putWord8 11 >> put msg
  -- put (MxTraceTakeover pid)     = putWord8 12 >> put pid
  -- put MxTraceDisable            = putWord8 13

  -- get = do
  --   header <- getWord8
  --   case header of
  --     1  -> MxSpawned <$> get
  --     2  -> MxRegistered <$> get <*> get
  --     3  -> MxUnRegistered <$> get <*> get
  --     4  -> MxProcessDied <$> get <*> get
  --     5  -> MxNodeDied <$> get <*> get
  --     6  -> MxSent <$> get <*> get <*> get
  --     7  -> MxReceived <$> get <*> get
  --     8  -> MxConnected <$> get <*> get
  --     9  -> MxDisconnected <$> get <*> get
  --     10 -> MxUser <$> get
  --     11 -> MxLog <$> get
  --     12 -> MxTraceTakeover <$> get
  --     13 -> return MxTraceDisable
  --     _ -> error "MxEvent.get - invalid header"

class Addressable a where
  resolveToPid :: a -> Maybe ProcessId

instance Addressable MxEvent where
  resolveToPid (MxSpawned     p)     = Just p
  resolveToPid (MxProcessDied p _)   = Just p
  resolveToPid (MxSent        _ p _) = Just p
  resolveToPid (MxReceived    p _)   = Just p
  resolveToPid _                     = Nothing

-- | Gross though it is, this synonym represents a function
-- used to forking new processes, which has to be passed as a HOF
-- when calling mxAgentController, since there's no other way to
-- avoid a circular dependency with Node.hs
type Fork = (Process () -> IO ProcessId)

-- | A newtype wrapper for an agent id (which is a string).
newtype MxAgentId = MxAgentId { agentId :: String }
  deriving (Typeable, Binary, Eq, Ord)

data MxTableId =
    MxForAgent !MxAgentId
  | MxForPid   !ProcessId
  deriving (Typeable, Generic)
instance Binary MxTableId where

data MxAgentState s = MxAgentState
                      {
                        mxAgentId     :: !MxAgentId
                      , mxBus         :: !(TChan Message)
                      , mxSharedTable :: !ProcessId
                      , mxLocalState  :: !s
                      }

-- | Monad for management agents, encapsulting the
-- agent's state and private
newtype MxAgent s a =
  MxAgent
  {
    unAgent :: ST.StateT (MxAgentState s) Process a
  } deriving ( Functor
             , Monad
             , MonadIO
             , ST.MonadState (MxAgentState s)
             , Typeable
             , Applicative
             )

data MxAgentStart = MxAgentStart
                    {
                      mxAgentTableChan :: SendPort ProcessId
                    , mxAgentIdStart   :: MxAgentId
                    }
  deriving (Typeable, Generic)
instance Binary MxAgentStart where

data MxAction =
    MxAgentDeactivate !String
  | MxAgentReady

-- | Type of a management agent's event sink.
type MxSink s = Message -> MxAgent s (Maybe MxAction)

