-- |
-- Module      :  Cryptol.Backend.SeqMap
-- Copyright   :  (c) 2013-2021 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE Safe #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module Cryptol.Backend.SeqMap
  ( -- * Sequence Maps
    SeqMap
  , indexSeqMap
  , lookupSeqMap
  , finiteSeqMap
  , infiniteSeqMap
  , enumerateSeqMap
  , streamSeqMap
  , reverseSeqMap
  , updateSeqMap
  , dropSeqMap
  , concatSeqMap
  , splitSeqMap
  , memoMap
  , delaySeqMap
  , zipSeqMap
  , mapSeqMap
  , mergeSeqMap
  , barrelShifter
  , shiftSeqByInteger

  , IndexSegment(..)
  ) where

import qualified Control.Exception as X
import Control.Monad
import Control.Monad.IO.Class
import Data.Bits
import Data.List
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Cryptol.Backend
import Cryptol.Backend.Monad (Unsupported(..))

import Cryptol.TypeCheck.Solver.InfNat(Nat'(..))

-- | A sequence map represents a mapping from nonnegative integer indices
--   to values.  These are used to represent both finite and infinite sequences.
data SeqMap sym a
  = IndexSeqMap  !(Integer -> SEval sym a)
  | UpdateSeqMap !(Map Integer (SEval sym a))
                 !(Integer -> SEval sym a)


indexSeqMap :: (Integer -> SEval sym a) -> SeqMap sym a
indexSeqMap = IndexSeqMap

lookupSeqMap :: SeqMap sym a -> Integer -> SEval sym a
lookupSeqMap (IndexSeqMap f) i = f i
lookupSeqMap (UpdateSeqMap m f) i =
  case Map.lookup i m of
    Just x  -> x
    Nothing -> f i

instance Backend sym => Functor (SeqMap sym) where
  fmap f xs = IndexSeqMap (\i -> f <$> lookupSeqMap xs i)

-- | Generate a finite sequence map from a list of values
finiteSeqMap :: Backend sym => sym -> [SEval sym a] -> SeqMap sym a
finiteSeqMap sym xs =
   UpdateSeqMap
      (Map.fromList (zip [0..] xs))
      (\i -> invalidIndex sym i)

-- | Generate an infinite sequence map from a stream of values
infiniteSeqMap :: Backend sym => sym -> [SEval sym a] -> SEval sym (SeqMap sym a)
infiniteSeqMap sym xs =
   -- TODO: use an int-trie?
   memoMap sym (IndexSeqMap $ \i -> genericIndex xs i)

-- | Create a finite list of length @n@ of the values from @[0..n-1]@ in
--   the given the sequence emap.
enumerateSeqMap :: (Integral n) => n -> SeqMap sym a -> [SEval sym a]
enumerateSeqMap n m = [ lookupSeqMap m  i | i <- [0 .. (toInteger n)-1] ]

-- | Create an infinite stream of all the values in a sequence map
streamSeqMap :: SeqMap sym a -> [SEval sym a]
streamSeqMap m = [ lookupSeqMap m i | i <- [0..] ]

-- | Reverse the order of a finite sequence map
reverseSeqMap :: Integer     -- ^ Size of the sequence map
              -> SeqMap sym a
              -> SeqMap sym a
reverseSeqMap n vals = IndexSeqMap $ \i -> lookupSeqMap vals (n - 1 - i)

updateSeqMap :: SeqMap sym a -> Integer -> SEval sym a -> SeqMap sym a
updateSeqMap (UpdateSeqMap m sm) i x = UpdateSeqMap (Map.insert i x m) sm
updateSeqMap (IndexSeqMap f) i x = UpdateSeqMap (Map.singleton i x) f

-- | Concatenate the first @n@ values of the first sequence map onto the
--   beginning of the second sequence map.
concatSeqMap :: Integer -> SeqMap sym a -> SeqMap sym a -> SeqMap sym a
concatSeqMap n x y =
    IndexSeqMap $ \i ->
       if i < n
         then lookupSeqMap x i
         else lookupSeqMap y (i-n)

-- | Given a number @n@ and a sequence map, return two new sequence maps:
--   the first containing the values from @[0..n-1]@ and the next containing
--   the values from @n@ onward.
splitSeqMap :: Integer -> SeqMap sym a -> (SeqMap sym a, SeqMap sym a)
splitSeqMap n xs = (hd,tl)
  where
  hd = xs
  tl = IndexSeqMap $ \i -> lookupSeqMap xs (i+n)

-- | Drop the first @n@ elements of the given 'SeqMap'.
dropSeqMap :: Integer -> SeqMap sym a -> SeqMap sym a
dropSeqMap 0 xs = xs
dropSeqMap n xs = IndexSeqMap $ \i -> lookupSeqMap xs (i+n)

delaySeqMap :: Backend sym => sym -> SEval sym (SeqMap sym a) -> SEval sym (SeqMap sym a)
delaySeqMap sym xs =
  do xs' <- sDelay sym xs
     pure $ IndexSeqMap $ \i -> do m <- xs'; lookupSeqMap m i

-- | Given a sequence map, return a new sequence map that is memoized using
--   a finite map memo table.
memoMap :: Backend sym => sym -> SeqMap sym a -> SEval sym (SeqMap sym a)
memoMap sym x = do
  stk <- sGetCallStack sym
  cache <- liftIO $ newIORef $ Map.empty
  return $ IndexSeqMap (memo cache stk)

  where
  memo cache stk i = do
    mz <- liftIO (Map.lookup i <$> readIORef cache)
    case mz of
      Just z  -> return z
      Nothing -> sWithCallStack sym stk (doEval cache i)

  doEval cache i = do
    v <- lookupSeqMap x i
    liftIO $ atomicModifyIORef' cache (\m -> (Map.insert i v m, ()))
    return v

-- | Apply the given evaluation function pointwise to the two given
--   sequence maps.
zipSeqMap ::
  Backend sym =>
  sym ->
  (a -> a -> SEval sym a) ->
  SeqMap sym a ->
  SeqMap sym a ->
  SEval sym (SeqMap sym a)
zipSeqMap sym f x y =
  memoMap sym (IndexSeqMap $ \i -> join (f <$> lookupSeqMap x i <*> lookupSeqMap y i))

-- | Apply the given function to each value in the given sequence map
mapSeqMap ::
  Backend sym =>
  sym ->
  (a -> SEval sym a) ->
  SeqMap sym a -> SEval sym (SeqMap sym a)
mapSeqMap sym f x =
  memoMap sym (IndexSeqMap $ \i -> f =<< lookupSeqMap x i)


{-# INLINE mergeSeqMap #-}
mergeSeqMap :: Backend sym =>
  sym ->
  (SBit sym -> a -> a -> SEval sym a) ->
  SBit sym ->
  SeqMap sym a ->
  SeqMap sym a ->
  SeqMap sym a
mergeSeqMap sym f c x y =
  IndexSeqMap $ \i -> mergeEval sym f c (lookupSeqMap x i) (lookupSeqMap y i)


{-# INLINE shiftSeqByInteger #-}
shiftSeqByInteger :: Backend sym =>
  sym ->
  (SBit sym -> a -> a -> SEval sym a) ->
  (Integer -> Integer -> Maybe Integer)
     {- ^ reindexing operation -} ->
  SEval sym a ->
  Nat' ->
  SeqMap sym a ->
  SInteger sym ->
  SEval sym (SeqMap sym a)
shiftSeqByInteger sym merge reindex zro m xs idx
  | Just j <- integerAsLit sym idx = shiftOp xs j
  | otherwise =
      do (n, idx_bits) <- enumerateIntBits sym m idx
         barrelShifter sym merge shiftOp xs n (map BitIndexSegment idx_bits)
 where
   shiftOp vs shft =
     pure $ indexSeqMap $ \i ->
       case reindex i shft of
         Nothing -> zro
         Just i' -> lookupSeqMap vs i'


data IndexSegment sym
  = BitIndexSegment (SBit sym)
  | WordIndexSegment (SWord sym)

barrelShifter :: Backend sym =>
  sym ->
  (SBit sym -> a -> a -> SEval sym a) ->
  (SeqMap sym a -> Integer -> SEval sym (SeqMap sym a))
     {- ^ concrete shifting operation -} ->
  SeqMap sym a {- ^ initial value -} ->
  Integer {- Number of bits in shift amount -} ->
  [IndexSegment sym]  {- ^ segments of the shift amount, in big-endian order -} ->
  SEval sym (SeqMap sym a)
barrelShifter sym mux shift_op x0 n0 bs0
  | n0 >= toInteger (maxBound :: Int) =
      liftIO (X.throw (UnsupportedSymbolicOp ("Barrel shifter with too many bits in shift amount: " ++ show n0)))
  | otherwise = go x0 (fromInteger n0) bs0

  where
  go x !_n [] = return x

  go x !n (WordIndexSegment w:bs) =
    let n' = n - fromInteger (wordLen sym w) in
    case wordAsLit sym w of
      Just (_,0) -> go x n' bs
      Just (_,j) ->
        do x_shft <- shift_op x (j * bit n')
           go x_shft n' bs
      Nothing ->
        do wbs <- unpackWord sym w
           go x n (map BitIndexSegment wbs ++ bs)

  go x !n (BitIndexSegment b:bs) =
    let n' = n - 1 in
    case bitAsLit sym b of
      Just False -> go x n' bs
      Just True ->
        do x_shft <- shift_op x (bit n')
           go x_shft n' bs
      Nothing ->
        do x_shft <- shift_op x (bit n')
           x' <- memoMap sym (mergeSeqMap sym mux b x_shft x)
           go x' n' bs
