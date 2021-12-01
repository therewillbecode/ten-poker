{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Poker.FSMSpec where

import Control.Lens
import Control.Monad
import Control.Monad.State
import Data.Either ()
import qualified Data.List as List
import Data.Maybe (Maybe (..))
import Data.Proxy ()
import Data.Text (Text)
import Data.List
import Data.Maybe
import Data.Functor.Identity
import qualified Data.Text as T
import qualified Data.Text as Text
import Data.Traversable (mapAccumR)
import Data.Tuple (fst, swap)
import qualified Data.Vector as V
import System.Random (getStdGen)
import Debug.Trace ()
import GHC.Enum (Enum (fromEnum))
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import Hedgehog (Property, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import Poker.Poker
import qualified Hedgehog.Range as Range
import Test.Hspec (describe, it)
import Test.Hspec.Hedgehog
import qualified Hedgehog.Range as Range
import Poker.Game.Game
import Poker.Game.Utils (shuffledDeck)
import Poker.Game.Utils
  ( getActivePlayers,
    getPlayersSatIn,
    initialDeck,
  )
import Poker.Types
import Data.IORef
import Prelude
import Hedgehog



initialModel :: GameModel v
initialModel = GModel GNotStarted [] (Dealer 0) (MaxPlayerCount 6) (MaxBuyInChips 3000) (MinBuyInChips 1500)

newtype NextPosToPost = NextPosToPost Int deriving (Eq, Ord, Show)

data GAwaitingBlind = GAwaitingBlind NextPosToPost GBlind
  deriving (Eq, Ord, Show)

data GBlindsStatus =  
    GBlindPosting GAwaitingBlind
  | GBlindPostingFinished
  deriving (Eq, Ord, Show)

data GHandStatus = 
     GStreetFinished
   | GPlayerNeedsToAct Int
   | GEveryoneFolded
   | GEveryoneAllIn
    deriving (Eq, Ord, Show)

data GStatus = GNotStarted | GBlinds GBlindsStatus | GHandInProgress GHandStatus
  deriving (Eq, Ord, Show)

data GBlind = BB | SB
  deriving (Eq, Ord, Show)

data PBlindStatus = PHasPostedBlind GBlind | PHasNotPostedBlind deriving (Eq, Ord, Show)

data GPlayer = PInBlind PBlindStatus | PInHand PInHandStatus | PSatOut 
  deriving (Eq, Ord, Show)

data PInHandStatus = PFolded | PNotFolded
  deriving (Eq, Ord, Show)

newtype MinBuyInChips = MinBuyInChips Int deriving (Eq, Ord, Show)

newtype MaxBuyInChips = MaxBuyInChips Int deriving (Eq, Ord, Show)

newtype MaxPlayerCount = MaxPlayerCount Int deriving (Eq, Ord, Show)

newtype Dealer = Dealer Int deriving (Eq, Ord, Show)

newtype PlayerPos = PlayerPos Int deriving (Eq, Ord, Show)

------------------
-- Player actions
------------------

data GNewPlayer =
    GNewPlayer Text Int
  deriving (Eq, Show)

newtype PSitDown (v :: * -> *) =
    PSitDown GNewPlayer
  deriving (Eq, Show)

instance HTraversable PSitDown where
  htraverse _ (PSitDown (GNewPlayer n c)) = pure (PSitDown (GNewPlayer n c))

data GProgressGame (v :: * -> *) =
    GProgressGame
  deriving (Eq, Show)

data PPostBlind (v :: * -> *) =
    PPostBlind PlayerPos GBlind
  deriving (Eq, Show)

data PBet (v :: * -> *) =
    PBet PlayerPos Int
  deriving (Eq, Show)

data PCall (v :: * -> *) =
    PCall PlayerPos Int
  deriving (Eq, Show)

data PCheck (v :: * -> *) =
    PCheck PlayerPos Int
  deriving (Eq, Show)

data PFold (v :: * -> *) =
    PFold PlayerPos Int
  deriving (Eq, Show)

---------------------------

data GameModel (v :: * -> *) =
    GModel GStatus [GPlayer] Dealer MaxPlayerCount MaxBuyInChips MinBuyInChips
  deriving (Eq, Ord, Show)




genNewPlayer :: Int -> Int -> Int -> Gen GNewPlayer
genNewPlayer pos minChips maxChips = do 
    cs <- Gen.int $ Range.constant minChips maxChips
    return $ GNewPlayer (T.pack $ show pos) cs


newGameIO :: IO (IORef Game)
newGameIO = do
    randGen <- getStdGen
    newIORef $ initialGameState $ shuffledDeck randGen

{-
data GBlindsStatus =  
    GBlindPosting
  | GBlindPostingFinished
  deriving (Eq, Ord, Show)

data GHandStatus = 
     GStreetFinished
   | GPlayerNeedsToAct Int
   | GEveryoneFolded
   | GEveryoneAllIn
    deriving (Eq, Ord, Show)

data GStatus = GNotStarted | GBlinds GBlindsStatus | GHandInProgress GHandStatus
  deriving (Eq, Ord, Show)

data GBlind = SB | BB deriving (Eq, Ord, Show)

data PInBlindStatus = PHasPosted GBlind | PHasNotPostedBlind deriving (Eq, Ord, Show)

data GPlayer = PInBlind PInBlindStatus | PInHand PInHandStatus | PSatOut 
  deriving (Eq, Ord, Show)

data PInHandStatus = PFolded | PNotFolded
  deriving (Eq, Ord, Show)
-}


reqBlinds :: Dealer -> [GPlayer] -> Maybe [(PlayerPos, GBlind)]
reqBlinds (Dealer dlr) ps 
  | length actives < 2 = Just []
  | length actives == 2 = 
             case dealerPlusNActives dlr actives 1 of 
               Just (_, bbPos) -> Just [(PlayerPos dlr, SB), (bbPos, BB)]
               Nothing         -> Nothing
  
  | otherwise = case [dealerPlusNActives dlr actives 0, 
                      dealerPlusNActives dlr actives 1] of
                  [Just (_, sbPos), Just (_, bbPos)] -> Just [(sbPos, SB), (bbPos, BB)]
                  _                        -> Nothing
   where actives = filter ((/= PSatOut) . fst) $ zip ps $ PlayerPos <$> [0..]

dropSatOutPs :: [GPlayer] -> [GPlayer]
dropSatOutPs = filter (/= PSatOut)
--getBBNotHeadsUp dealerPos actives = nextElemfromNth (const True) (cycle actives) dealerPos

dealerPlusNActives dealerPos actives n = nextElemfromNth (const True) (cycle actives) (dealerPos + n)

nextElemfromNth :: (a -> Bool) -> [a] -> Int -> Maybe a
nextElemfromNth f ps n = find f $ drop n $ cycle ps 

--getPlayerNameAtPos :: [Player] -> Int -> Maybe Text
--getPlayerNameAtPos ps n = !!
--  | n < 0 || n > length ps = Nothing
--fromMaybe $ ps ^? ix pos


-- TODO Should also add actions / commands that should fail i.e cannot bet when all in etc
-- you just flip the either for this - see example in yow lambda talk.

s_post_blind :: (MonadTest m, MonadIO m) => IORef Game -> Command Gen m GameModel
s_post_blind ref =
  let 
    gen state =
        case state of
          -- Another player already posted a blind to start the blind action
          -- Pick the next required blind
          (GModel (GBlinds (GBlindPosting (GAwaitingBlind (NextPosToPost pos) blind))) ps _  _ _ _) ->
             Just $ pure $ PPostBlind (PlayerPos pos) blind

          -- Pick any possible blind
          (GModel (GNotStarted) ps dlr  _ _ _) ->
            let
               blindGen :: Gen (PlayerPos, GBlind)
               blindGen =  Gen.element $ fromJust $ reqBlinds dlr ps
            in pure $ fmap (uncurry PPostBlind) blindGen
  
          _ -> Nothing
    execute :: (MonadTest m, MonadIO m) => PPostBlind v -> m Game
    execute (PPostBlind (PlayerPos pos) blind) = do
       prevGame <- liftIO $ readIORef ref
       let pName = ((prevGame ^. players) !! pos ) ^. playerName
       newGame <- evalEither 
                     $ runPlayerAction prevGame 
                     $ PlayerAction { name = pName, action = PostBlind $ blind' blind  }
       liftIO $ atomicWriteIORef ref newGame
       return newGame
      where
        blind' BB = Big
        blind' SB = Small
   
  in
    Command gen execute [
            -- Precondition: the 
        Require $ 
          \(GModel gStatus ps maxPs _ _ _)  (PPostBlind pos blind) -> 
            canPostBlindAtStage ps gStatus

    --    -- Update: add blinds status in model
    --  , Update $ \(GModel gStatus ps maxPs dlr maxChips minChips) (PSitDown _) (game :: Var Game v) ->
    --      let newPlayer = PInBlind PHasNotPostedBlind
    --      in (GModel gStatus (ps <> pure newPlayer ) maxPs dlr maxChips minChips)
--
    --    -- Postcondition: player added to table
    --  , Ensure $ \(GModel gStatus prevPlayers _ _ _ _) (GModel _ nextPlayers _ _ _ _) (PSitDown _) _ -> do
    --      length nextPlayers === (length prevPlayers) + 1
    --      gStatus === GNotStarted
      ]
  where
    canPostBlindAtStage :: [GPlayer] -> GStatus -> Bool
    canPostBlindAtStage _ (GBlinds (GBlindPosting _)) = True
    canPostBlindAtStage ps GNotStarted =  length (dropSatOutPs ps) > 1 
    canPostBlindAtStage _ _ = False

   

s_sit_down_new_player :: (MonadTest m, MonadIO m) => IORef Game -> Command (GenT Identity) m GameModel
s_sit_down_new_player ref =
  let
    -- This generator only produces an action to sit down when the game hand has not started yet.
    gen state =
      case state of
        (GModel (GNotStarted) ps _ (MaxPlayerCount maxPlayers) (MaxBuyInChips maxChips) (MinBuyInChips minChips)) ->
            if length ps < maxPlayers
                then Just $ fmap PSitDown $ genNewPlayer (length ps) minChips maxChips
                else Nothing
        _ -> Nothing
 
    execute :: (MonadTest m, MonadIO m) => PSitDown v -> m Game
    execute (PSitDown (GNewPlayer name chips))  = do
       prevGame <- liftIO $ readIORef ref
       newGame <- evalEither $ runPlayerAction prevGame playerAction
       liftIO $ atomicWriteIORef ref newGame
       return newGame
      where playerAction = PlayerAction { name = name, action = SitDown $ initPlayer name chips}

  in
    Command gen execute [
        -- Precondition: the 
        Require $ 
          \(GModel gStatus ps maxPs _ (MaxBuyInChips maxChips)
           (MinBuyInChips minChips))
           (PSitDown (GNewPlayer name chips)) -> 
               gStatus == GNotStarted
                && chips >= minChips && chips <= maxChips

        -- Update: add player to table in model
      , Update $ \(GModel gStatus ps maxPs dlr maxChips minChips) (PSitDown _) (game :: Var Game v) ->
          let newPlayer = PInBlind PHasNotPostedBlind
          in (GModel gStatus (ps <> pure newPlayer ) maxPs dlr maxChips minChips)

        -- Postcondition: player added to table
      , Ensure $ \(GModel gStatus prevPlayers _ _ _ _) (GModel _ nextPlayers _ _ _ _) (PSitDown _) _ -> do
          length nextPlayers === (length prevPlayers) + 1
          gStatus === GNotStarted
      ]


spec = 
    describe "fsm" $ do

      it "Status" $
        hedgehog $ do
                ref <- liftIO newGameIO
                actions <- forAll $
                   Gen.sequential (Range.linear 1 6) initialModel [
                       s_sit_down_new_player ref
                   
                     ]
                executeSequential initialModel actions
