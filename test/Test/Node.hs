{-# LANGUAGE RecordWildCards #-}
module Test.Node where

import Control.Monad.ST.Lazy (runST)
import Data.Functor (void)
import Data.Maybe (isNothing, listToMaybe)
import Data.Semigroup ((<>))
import           Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as Map

import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

import Block
import qualified Chain
import           Chain (Chain (..))
import Node
import MonadClass
import qualified Sim

import Test.Chain (TestBlockChain (..), TestChainFork (..))

tests :: TestTree
tests =
  testGroup "Node"
  [ testGroup "fixed graph topology"
    [ testProperty "core -> relay" prop_coreToRelay
    , testProperty "core -> relay -> relay" prop_coreToRelay2
    , testProperty "core <-> relay <-> core" prop_coreToCoreViaRelay
    ]
  ]


-- note: it will reverse the order of probes!
partitionProbe :: [(NodeId, a)] -> Map NodeId [a]
partitionProbe
  = Map.fromListWith (++) . map (\(nid, a) -> (nid, [a]))

coreToRelaySim :: ( MonadSTM m stm
                  , MonadTimer m
                  , MonadSay m
                  , MonadProbe m
                  )
               => Bool              -- ^ two way subscription
               -> Chain Block
               -> Duration (Time m) -- ^ slot duration
               -> Duration (Time m) -- ^ core transport delay
               -> Duration (Time m) -- ^ relay transport delay
               -> Probe m (NodeId, Chain Block)
               -> m ()
coreToRelaySim duplex chain slotDuration coreTrDelay relayTrDelay probe = do
  (coreChans, relayChans) <- if duplex
    then createTwoWaySubscriptionChannels relayTrDelay coreTrDelay
    else createOneWaySubscriptionChannels coreTrDelay relayTrDelay

  fork $ do
    cps <- coreNode (CoreId 0) slotDuration chain coreChans
    fork $ observeChainProducerState (CoreId 0) probe cps
  fork $ void $ do
    cps <- relayNode (RelayId 0) relayChans
    fork $ observeChainProducerState (RelayId 0) probe cps

runCoreToRelaySim :: Chain Block
                  -> Sim.VTimeDuration
                  -> Sim.VTimeDuration
                  -> Sim.VTimeDuration
                  -> [(Sim.VTime, (NodeId, Chain Block))]
runCoreToRelaySim chain slotDuration coreTransportDelay relayTransportDelay =
  runST $ do
    probe <- newProbe
    runM $ coreToRelaySim False chain slotDuration coreTransportDelay relayTransportDelay probe
    readProbe probe

data TestNodeSim = TestNodeSim
  { testChain               :: Chain Block
  , testSlotDuration        :: Sim.VTimeDuration
  , testCoreTransportDelay  :: Sim.VTimeDuration
  , testRealyTransportDelay :: Sim.VTimeDuration
  }
  deriving (Show, Eq)

instance Arbitrary TestNodeSim where
  arbitrary = do
    TestBlockChain testChain <- arbitrary
    -- at least twice as much as testCoreDelay
    Positive slotDuration <- arbitrary
    Positive testCoreTransportDelay <- arbitrary
    Positive testRelayTransportDelay <- arbitrary
    return $ TestNodeSim testChain (Sim.VTimeDuration slotDuration) (Sim.VTimeDuration testCoreTransportDelay) (Sim.VTimeDuration testRelayTransportDelay)

  -- TODO: shrink

-- this test relies on the property that when there is a single core node the
-- it will never have to use @'fixupBlock'@ function.
prop_coreToRelay :: TestNodeSim -> Property
prop_coreToRelay (TestNodeSim chain slotDuration coreTrDelay relayTrDelay) =
  let probes  = map snd $ runCoreToRelaySim chain slotDuration coreTrDelay relayTrDelay
      dict    :: Map NodeId [Chain Block]
      dict    = partitionProbe probes
      mchain1 :: Maybe (Chain Block)
      mchain1 = RelayId 0 `Map.lookup` dict >>= listToMaybe
  in counterexample (show mchain1) $
    if Chain.null chain
        -- when a chain is null, the relay observer will never be triggered,
        -- since its chain never is never updated
      then property $ isNothing mchain1
      else mchain1 === Just chain

-- Node graph: c → r → r
coreToRelaySim2 :: ( MonadSTM m stm
                   , MonadTimer m
                   , MonadSay m
                   , MonadProbe m
                   )
                => Chain Block
                -> Duration (Time m)
                -- ^ slot length
                -> Duration (Time m)
                -- ^ core transport delay
                -> Duration (Time m)
                -- ^ relay transport delay
                -> Probe m (NodeId, Chain Block)
                -> m ()
coreToRelaySim2 chain slotDuration coreTrDelay relayTrDelay probe = do
  (cr1, r1c) <- createOneWaySubscriptionChannels coreTrDelay relayTrDelay
  (r1r2, r2r1) <- createOneWaySubscriptionChannels relayTrDelay relayTrDelay

  fork $ void $ do
    cps <- coreNode (CoreId 0) slotDuration chain cr1
    fork $ observeChainProducerState (CoreId 0) probe cps
  fork $ void $ do
    cps <- relayNode (RelayId 1) (r1c <> r1r2)
    fork $ observeChainProducerState (RelayId 1) probe cps
  fork $ void $ do
    cps <- relayNode (RelayId 2) r2r1
    fork $ observeChainProducerState (RelayId 2) probe cps

runCoreToRelaySim2 :: Chain Block
                   -> Sim.VTimeDuration
                   -> Sim.VTimeDuration
                   -> Sim.VTimeDuration
                  -> [(Sim.VTime, (NodeId, Chain Block))]
runCoreToRelaySim2 chain slotDuration coreTransportDelay relayTransportDelay = runST $ do
  probe <- newProbe
  runM $ coreToRelaySim2 chain slotDuration coreTransportDelay relayTransportDelay probe
  readProbe probe

prop_coreToRelay2 :: TestNodeSim -> Property
prop_coreToRelay2 (TestNodeSim chain slotDuration coreTrDelay relayTrDelay) =
  let dict    = partitionProbe probes
      probes  = map snd $ runCoreToRelaySim2 chain slotDuration coreTrDelay relayTrDelay
      mchain1 = RelayId 1 `Map.lookup` dict >>= listToMaybe
      mchain2 = RelayId 2 `Map.lookup` dict >>= listToMaybe
  in counterexample (show mchain1) $
    if Chain.null chain
        -- when a chain is null, the relay observer will never be triggered,
        -- since its chain never is never updated
      then isNothing mchain1 .&&. isNothing mchain2
      else
            mchain1 === Just chain
        .&&.
            mchain1 === Just chain

-- Node graph: c ↔ r ↔ c
coreToCoreViaRelaySim :: ( MonadSTM m stm
                         , MonadTimer m
                         , MonadSay m
                         , MonadProbe m
                         )
                      => Chain Block
                      -> Chain Block
                      -> Duration (Time m)
                      -> Duration (Time m)
                      -> Duration (Time m)
                      -> Probe m (NodeId, Chain Block)
                      -> m ()
coreToCoreViaRelaySim chain1 chain2 slotDuration coreTrDelay relayTrDelay probe = do
  (c1r1, r1c1) <- createTwoWaySubscriptionChannels coreTrDelay relayTrDelay
  (r1c2, c2r1) <- createTwoWaySubscriptionChannels relayTrDelay coreTrDelay

  fork $ void $ do
    cps <- coreNode (CoreId 1) slotDuration chain1 c1r1
    fork $ observeChainProducerState (CoreId 1) probe cps
  fork $ void $ do
    cps <- relayNode (RelayId 1) (r1c1 <> r1c2)
    fork $ observeChainProducerState (RelayId 1) probe cps
  fork $ void $ do
    cps <- coreNode (CoreId 2) slotDuration chain2 c2r1
    fork $ observeChainProducerState (CoreId 2) probe cps

runCoreToCoreViaRelaySim
  :: Chain Block
  -> Chain Block
  -> Sim.VTimeDuration
  -> Sim.VTimeDuration
  -> Sim.VTimeDuration
  -> [(Sim.VTime, (NodeId, Chain Block))]
runCoreToCoreViaRelaySim chain1 chain2 slotDuration coreTrDelay relayTrDelay = runST $ do
  probe <- newProbe
  runM $ coreToCoreViaRelaySim chain1 chain2 slotDuration coreTrDelay relayTrDelay probe
  readProbe probe

prop_coreToCoreViaRelay :: TestChainFork -> Property
prop_coreToCoreViaRelay (TestChainFork _ chain1 chain2) =
  let probes = map snd $ runCoreToCoreViaRelaySim chain1 chain2 (Sim.VTimeDuration 3) (Sim.VTimeDuration 1) (Sim.VTimeDuration 1)
  in
        let dict    = partitionProbe probes
            chainC1 = CoreId 1  `Map.lookup` dict >>= listToMaybe
            chainR1 = RelayId 1 `Map.lookup` dict >>= listToMaybe
            chainC2 = CoreId 2 `Map.lookup` dict >>= listToMaybe
        in
            isValid chainC1 chainR1 .&&. isValid chainC1 chainC2
  where
    isValid :: Maybe (Chain Block) -> Maybe (Chain Block) -> Property
    isValid Nothing   Nothing   = property True
    isValid (Just _)  Nothing   = property False
    isValid Nothing   (Just _)  = property False
    isValid (Just c1) (Just c2) = compareChains c1 c2

    compareChains :: Chain Block -> Chain Block -> Property
    compareChains c1 c2 =
        counterexample (c1_ ++ "\n\n" ++ c2_) (longerChain c1 c2 === c1)
      .&&.
        counterexample (c1_ ++ "\n\n" ++ c2_) (longerChain c2 c1 === c2)
      where
        nl  = "\n    "
        c1_ = Chain.prettyPrintChain nl show c1
        c2_ = Chain.prettyPrintChain nl show c2

    longerChain :: Chain Block -> Chain Block -> Chain Block
    longerChain c1 c2 =
      let l1 = Chain.length c1
          l2 = Chain.length c2
          c | l1 <  l2  = c2
            | otherwise = c1
      in c
