{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Ouroboros.Consensus.Cardano.Orphans () where

import           Cardano.Binary
import           Cardano.Chain.Common
import           Cardano.Chain.Genesis
import           Cardano.Chain.UTxO
import           Cardano.Crypto.Hashing
import           Cardano.Crypto.ProtocolMagic
import           Codec.Serialise (Serialise)
import           Ouroboros.Consensus.Util (SerialiseViaCanonicalJSON (..))
import           Shelley.Spec.Ledger.BaseTypes

{-------------------------------------------------------------------------------
  Orphan Instances

  The following instances are for types in the `cardano-ledger-specs` repo At
  the time of writing, none of those packages depend on the serialise package,
  and hence do not provide Serialise instances. This justifies using orphan
  instances here.
-------------------------------------------------------------------------------}

{-------------------------------------------------------------------------------
  From Package: shelley-spec-ledger
-------------------------------------------------------------------------------}

deriving anyclass instance Serialise ActiveSlotCoeff

deriving anyclass instance Serialise Network

deriving anyclass instance Serialise UnitInterval

{-------------------------------------------------------------------------------
  From Package: cardano-ledger-byron
-------------------------------------------------------------------------------}

deriving anyclass instance Serialise Config

deriving via (SerialiseViaCanonicalJSON GenesisData) instance Serialise GenesisData

deriving newtype instance Serialise GenesisHash

deriving anyclass instance Serialise CompactAddress

deriving anyclass instance Serialise UTxOConfiguration

{-------------------------------------------------------------------------------
  From Package: cardano-crypto-wrapper
-------------------------------------------------------------------------------}

deriving anyclass instance Serialise (Hash Raw) -- Raw is from repo `cardano-base` and  package `cardano-binary`

deriving anyclass instance Serialise RequiresNetworkMagic
