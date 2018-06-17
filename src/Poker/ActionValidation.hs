{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Poker.ActionValidation where

import Control.Lens hiding (Fold)

------------------------------------------------------------------------------
import Control.Monad.State.Lazy
import Data.List
import qualified Data.List.Safe as Safe
import Data.Maybe
import Data.Monoid
import Data.Text (Text)

import qualified Data.Text as T
import Debug.Trace

------------------------------------------------------------------------------
import Poker.Hands
import Poker.Types
import Poker.Utils

-- a Nothing signifies the absence of an error in which case the action is valid
validateAction :: Game -> PlayerName -> PlayerAction -> Maybe GameErr
validateAction game@Game {..} playerName action@(PostBlind blind) =
  case checkPlayerSatAtTable game playerName of
    err@(Just _) -> err
    Nothing
     -- case isPlayerActingOutOfTurn game playerName of
      --  err@(Just _) -> err
       -- Nothing ->
     ->
      case validateBlindAction game playerName blind of
        err@(Just _) -> err
        Nothing -> Nothing
validateAction game@Game {..} playerName action@(Check) = do
  err <- canCheck playerName game
  return $ InvalidMove playerName err
validateAction game@Game {..} playerName action@(Fold) = do
  err <- canFold playerName game
  return $ InvalidMove playerName err
validateAction game@Game {..} playerName action@(Bet amount) = do
  err <- canBet playerName amount game
  return $ InvalidMove playerName err
validateAction game@Game {..} playerName action@(Raise amount) = do
  err <- canRaise playerName amount game
  return $ InvalidMove playerName err

-- | The first player to post their blinds in the predeal stage  can do it from any position
-- Therefore the acting in turn rule wont apply for that first move.
isPlayerActingOutOfTurn :: Game -> PlayerName -> Maybe GameErr
isPlayerActingOutOfTurn game@Game {..} playerName =
  if _street == PreDeal && not haveBetsBeenMade -- first predeal blind bet exempt
    then Nothing
    else do
      let playerPosition = playerName `elemIndex` gamePlayerNames
      case playerPosition of
        Nothing -> Just $ NotAtTable playerName
        Just pos ->
          if _currentPosToAct == pos
            then Nothing
            else Just $
                 InvalidMove playerName $
                 OutOfTurn $
                 CurrentPlayerToActErr $ gamePlayerNames !! _currentPosToAct
  where
    haveBetsBeenMade = (sum $ (\Player {..} -> _bet) <$> _players) == 0
    gamePlayerNames = (\Player {..} -> _playerName) <$> _players

checkPlayerSatAtTable :: Game -> PlayerName -> Maybe GameErr
checkPlayerSatAtTable game@Game {..} playerName
  | not atTable = Just $ NotAtTable playerName
  | otherwise = Nothing
  where
    playerNames = getGamePlayerNames game
    atTable = playerName `elem` playerNames

validateBlindAction :: Game -> PlayerName -> Blind -> Maybe GameErr
validateBlindAction game@Game {..} playerName blind
  | _street /= PreDeal =
    Just $ InvalidMove playerName $ CannotPostBlindOutsidePreDeal
  | otherwise =
    case getGamePlayer game playerName of
      Nothing -> Just $ PlayerNotAtTable playerName
      Just p@Player {..} ->
        case blindRequired of
          Just Small ->
            if blind == Small
              then if _committed >= _smallBlind
                     then Just $
                          InvalidMove playerName $ BlindAlreadyPosted Small
                     else Nothing
              else Just $ InvalidMove playerName $ BlindRequired Small
          Just Big ->
            if blind == Big
              then if _committed >= bigBlindValue
                     then Just $ InvalidMove playerName $ BlindAlreadyPosted Big
                     else Nothing
              else Just $ InvalidMove playerName $ BlindRequired Big
          Nothing -> Just $ InvalidMove playerName $ NoBlindRequired
        where blindRequired = blindRequiredByPlayer game playerName
              bigBlindValue = _smallBlind * 2

-- if a player does not post their blind at the appropriate time then their state will be changed to 
--None signifying that they have a seat but are now sat out
-- blind is required either if player is sitting in bigBlind or smallBlind position relative to dealer
-- or if their current playerState is set to Out 
-- If no blind is required for the player to remain In for the next hand then we will return Nothing
blindRequiredByPlayer :: Game -> Text -> Maybe Blind
blindRequiredByPlayer game playerName = do
  let player = fromJust $ getGamePlayer game playerName
  let playerNames = getPlayerNames (_players game)
  let playerPosition = fromJust $ getPlayerPosition playerNames playerName
  let smallBlindPos = getSmallBlindPosition playerNames (_dealer game)
  let bigBlindPos = smallBlindPos `modInc` (length playerNames - 1)
  if playerPosition == smallBlindPos
    then Just Small
    else if playerPosition == bigBlindPos
           then Just Big
           else Nothing

getSmallBlindPosition :: [Text] -> Int -> Int
getSmallBlindPosition playersSatIn dealerPos =
  if length playersSatIn == 2
    then dealerPos
    else modInc dealerPos (length playersSatIn)

canBet :: PlayerName -> Int -> Game -> Maybe InvalidMoveErr
canBet pName amount game@Game {..} =
  if amount < _bigBlind
    then Just BetLessThanBigBlind
    else if maxBet > 0
           then Just CannotBetShouldRaiseInstead
           else if amount > chipCount
                  then Just NotEnoughChipsForAction
                  else if (_street == Showdown) || (_street == PreDeal)
                         then Just InvalidActionForStreet
                         else Nothing
  where
    maxBet = getMaxBet _players
    chipCount = _chips $ fromJust (getGamePlayer game pName)

-- Keep in mind that a player can always raise all in,
-- even if their total chip count is less than what 
-- a min-bet or min-raise would be. 
canRaise :: PlayerName -> Int -> Game -> Maybe InvalidMoveErr
canRaise pName amount game@Game {..} =
  if (_street == Showdown) || (_street == PreDeal)
    then Just InvalidActionForStreet
    else if maxBet == 0
           then Just CannotRaiseShouldBetInstead
           else if (amount < minRaise) && (amount /= chipCount)
                  then Just $ RaiseAmountBelowMinRaise minRaise
                  else if amount > chipCount
                         then Just NotEnoughChipsForAction
                         else Nothing
  where
    maxBet = getMaxBet _players
    minRaise = 2 * maxBet
    chipCount = _chips $ fromJust (getGamePlayer game pName)

canCheck :: PlayerName -> Game -> Maybe InvalidMoveErr
canCheck pName game@Game {..} =
  if (_street == Showdown) || (_street == PreDeal)
    then Just InvalidActionForStreet
    else if maxBet /= 0
           then Just CannotCheckMustCallOrFold
           else Nothing
  where
    maxBet = maximum $ flip (^.) bet <$> (getActivePlayers _players)

canFold :: PlayerName -> Game -> Maybe InvalidMoveErr
canFold pName game@Game {..} =
  if (_street == Showdown) || (_street == PreDeal)
    then Just InvalidActionForStreet
    else Nothing

canCall :: PlayerName -> Game -> Maybe InvalidMoveErr
canCall pName game@Game {..} =
  if (_street == Showdown) || (_street == PreDeal)
    then Just InvalidActionForStreet
    else if maxBet == 0
           then Just CannotCallZeroAmountCheckOrBetInstead
           else Nothing
  where
    maxBet = getMaxBet _players
    minRaise = 2 * maxBet
    p = fromJust (getGamePlayer game pName)
    chipCount = _chips p
    amountNeededToCall = maxBet - (_bet p)