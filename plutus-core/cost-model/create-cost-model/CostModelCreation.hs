{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CostModelCreation where

import           PlutusCore.Evaluation.Machine.ExBudgeting
import           PlutusCore.Evaluation.Machine.ExMemory

import           Barbies
import           Control.Applicative
import           Control.Exception                         (TypeError (..))
import           Control.Monad.Catch
import qualified Data.ByteString.Hash                      as PlutusHash
import qualified Data.ByteString.Lazy                      as BSL
import           Data.Coerce
import           Data.Csv
import           Data.Default
import           Data.Either.Extra
import           Data.Functor.Compose
import           Data.Text                                 as T
import qualified Data.Text.Encoding                        as T
import           Data.Vector
import           GHC.Generics

import           Foreign.R
import           H.Prelude                                 (MonadR, Region, r)
import           Language.R

{- See Note [Creation of the Cost Model]
-}

-- TODO some generics magic
-- Mentioned in CostModel.md. Change here, change there.
-- The names of the models in R
costModelNames :: CostModelBase (Const Text)
costModelNames = CostModel
  { paramAddInteger           = "addIntegerModel"
  , paramSubtractInteger      = "subtractIntegerModel"
  , paramMultiplyInteger      = "multiplyIntegerModel"
  , paramDivideInteger        = "divideIntegerModel"
  , paramQuotientInteger      = "quotientIntegerModel"
  , paramRemainderInteger     = "remainderIntegerModel"
  , paramModInteger           = "modIntegerModel"
  , paramLessThanInteger      = "lessThanIntegerModel"
  , paramLessThanEqInteger    = "lessThanEqIntegerModel"
  , paramGreaterThanInteger   = "greaterThanIntegerModel"
  , paramGreaterThanEqInteger = "greaterThanEqIntegerModel"
  , paramEqInteger            = "eqIntegerModel"
  , paramConcatenate          = "concatenateModel"
  , paramTakeByteString       = "takeByteStringModel"
  , paramDropByteString       = "dropByteStringModel"
  , paramSHA2                 = "sHA2Model"
  , paramSHA3                 = "sHA3Model"
  , paramVerifySignature      = "verifySignatureModel"
  , paramEqByteString         = "eqByteStringModel"
  , paramLtByteString         = "ltByteStringModel"
  , paramGtByteString         = "gtByteStringModel"
  , paramIfThenElse           = "ifThenElseModel"
  }

-- Loads the models from R
costModelsR :: MonadR m => m (CostModelBase (Const (SomeSEXP (Region m))))
costModelsR = do
  list <- [r|
    source("cost-model/data/models.R")
    modelFun("cost-model/data/benching.csv")
  |]
  -- TODO use btraverse instead
  bsequence $ bmap (\name -> let n = getConst name in Compose $ fmap Const $ [r| list_hs[[n_hs]] |]) costModelNames

-- Creates the cost model from the csv benchmarking files
createCostModel :: IO CostModel
createCostModel =
  withEmbeddedR defaultConfig $ runRegion $ do
    models <- costModelsR
    -- TODO: refactor with barbies
    let getParams x y = x (getConst $ y models)
    paramAddInteger           <- getParams addInteger           paramAddInteger
    paramSubtractInteger      <- getParams subtractInteger      paramSubtractInteger
    paramMultiplyInteger      <- getParams multiplyInteger      paramMultiplyInteger
    paramDivideInteger        <- getParams divideInteger        paramDivideInteger
    paramQuotientInteger      <- getParams quotientInteger      paramQuotientInteger
    paramRemainderInteger     <- getParams remainderInteger     paramRemainderInteger
    paramModInteger           <- getParams modInteger           paramModInteger
    paramLessThanInteger      <- getParams lessThanInteger      paramLessThanInteger
    paramGreaterThanInteger   <- getParams greaterThanInteger   paramGreaterThanInteger
    paramLessThanEqInteger    <- getParams lessThanEqInteger    paramLessThanEqInteger
    paramGreaterThanEqInteger <- getParams greaterThanEqInteger paramGreaterThanEqInteger
    paramEqInteger            <- getParams eqInteger            paramEqInteger
    paramConcatenate          <- getParams concatenate          paramConcatenate
    paramTakeByteString       <- getParams takeByteString       paramTakeByteString
    paramDropByteString       <- getParams dropByteString       paramDropByteString
    paramSHA2                 <- getParams sHA2                 paramSHA2
    paramSHA3                 <- getParams sHA3                 paramSHA3
    paramVerifySignature      <- getParams verifySignature      paramVerifySignature
    paramEqByteString         <- getParams eqByteString         paramEqByteString
    paramLtByteString         <- getParams ltByteString         paramLtByteString
    paramGtByteString         <- getParams gtByteString         paramGtByteString
    paramIfThenElse           <- getParams ifThenElse           paramIfThenElse

    pure $ CostModel {..}

-- The output of `tidy(model)` on the R side.
data LinearModelRaw = LinearModelRaw
  { linearModelIndex        :: Integer
  , linearModelRawTerm      :: String
  , linearModelRawEstimate  :: Double
  , linearModelRawStdError  :: Double
  , linearModelRawStatistic :: Double
  , linearModelRawPValue    :: Double
  } deriving (Show, Eq, Generic)

-- Reading via CSV because the R side did weird things in JSON
instance FromNamedRecord LinearModelRaw where
  parseNamedRecord v =
      LinearModelRaw
        <$> v .: ""
        <*> v .: "term"
        <*> v .: "estimate"
        <*> v .: "std.error"
        <*> v .: "statistic"
        <*> v .: "p.value"

instance FromRecord LinearModelRaw

findInRaw :: String -> Vector LinearModelRaw -> Either String LinearModelRaw
findInRaw s v = maybeToEither ("Couldn't find the term " <> s) $
  Data.Vector.find (\e -> linearModelRawTerm e == s) v

unsafeReadModelFromR :: MonadR m => String -> (SomeSEXP (Region m)) -> m (Double, Double)
unsafeReadModelFromR formula rmodel = do
  j <- [r| write.csv(tidy(rmodel_hs), file=textConnection("out", "w", local=TRUE))
          paste(out, collapse="\n") |]
  let m = do
        model <- Data.Csv.decode HasHeader $ BSL.fromStrict $ T.encodeUtf8 $ (fromSomeSEXP j :: Text)
        intercept <- linearModelRawEstimate <$> findInRaw "(Intercept)" model
        slope <- linearModelRawEstimate <$> findInRaw formula model
        pure $ (intercept, slope)
  case m of
    Left err -> throwM (TypeError err)
    Right x  -> pure x

unsafeReadModelFromR2 :: MonadR m => String -> String -> (SomeSEXP (Region m)) -> m (Double, Double, Double)
unsafeReadModelFromR2 formula1 formula2 rmodel = do
  j <- [r| write.csv(tidy(rmodel_hs), file=textConnection("out", "w", local=TRUE))
          paste(out, collapse="\n") |]
  let m = do
        model <- Data.Csv.decode HasHeader $ BSL.fromStrict $ T.encodeUtf8 $ (fromSomeSEXP j :: Text)
        intercept <- linearModelRawEstimate <$> findInRaw "(Intercept)" model
        slope1 <- linearModelRawEstimate <$> findInRaw formula1 model
        slope2 <- linearModelRawEstimate <$> findInRaw formula2 model
        pure $ (intercept, slope1, slope2)
  case m of
    Left err -> throwM (TypeError err)
    Right x  -> pure x

readModelAddedSizes :: MonadR m => (SomeSEXP (Region m)) -> m ModelAddedSizes
readModelAddedSizes model = (pure . uncurry ModelAddedSizes) =<< unsafeReadModelFromR "I(x_mem + y_mem)" model

readModelMinSize :: MonadR m => (SomeSEXP (Region m)) -> m ModelMinSize
readModelMinSize model = (pure . uncurry ModelMinSize) =<< unsafeReadModelFromR "I(pmin(x_mem, y_mem))" model

uncurry3 :: (a -> b -> c -> d) -> ((a, b, c) -> d)
uncurry3 f ~(a,b,c) = f a b c

readModelMultiSizes :: MonadR m => (SomeSEXP (Region m)) -> m ModelMultiSizes
readModelMultiSizes model = (pure . uncurry ModelMultiSizes) =<< unsafeReadModelFromR "I(x_mem * y_mem)" model

readModelSplitConst :: MonadR m => (SomeSEXP (Region m)) -> m ModelSplitConst
readModelSplitConst model = (pure . uncurry ModelSplitConst) =<< unsafeReadModelFromR "ifelse(x_mem > y_mem, I(x_mem * y_mem), 0)" model

readModelConstantCost :: MonadR m => (SomeSEXP (Region m)) -> m Integer
readModelConstantCost model = (\(i, _i) -> pure $ ceiling i) =<< unsafeReadModelFromR "(Intercept)" model

readModelLinear :: MonadR m => (SomeSEXP (Region m)) -> m ModelLinearSize
readModelLinear model = (\(intercept, slope) -> pure $ ModelLinearSize intercept slope ModelOrientationX) =<< unsafeReadModelFromR "x_mem" model

boolMemModel :: ModelTwoArguments
boolMemModel = ModelTwoArgumentsConstantCost 1

addInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
addInteger cpuModelR = do
  cpuModel <- readModelAddedSizes cpuModelR
  -- The worst case is adding e.g. `maxBound :: Int` + `maxBound :: Int`, which increases the memory usage by one.
  -- (max x y) + 1
  let memModel = ModelTwoArgumentsMaxSize $ ModelMaxSize 1 1
  pure $ CostingFun (ModelTwoArgumentsAddedSizes cpuModel) memModel

subtractInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
subtractInteger cpuModelR = do
  cpuModel <- readModelAddedSizes cpuModelR
  -- The worst case is subtracting e.g. `minBound :: Int` - `maxBound :: Int`, which increases the memory usage by one.
  -- (max x y) + 1
  let memModel = ModelTwoArgumentsMaxSize $ ModelMaxSize 1 1
  pure $ CostingFun (ModelTwoArgumentsAddedSizes cpuModel) memModel

multiplyInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
multiplyInteger cpuModelR = do
  cpuModel <- readModelMultiSizes cpuModelR
  -- GMP requires multiplication (mpn_mul) to have x + y space.
  -- x + y
  let memModel = ModelTwoArgumentsAddedSizes $ ModelAddedSizes 0 1
  pure $ CostingFun (ModelTwoArgumentsMultiSizes cpuModel) memModel

divideInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
divideInteger cpuModelR = do
  cpuModel <- readModelSplitConst cpuModelR
  -- GMP requires division (mpn_divrem) to have x - y space.
  -- x - y
  let memModel = ModelTwoArgumentsSubtractedSizes $ ModelSubtractedSizes 0 1 1
  pure $ CostingFun (ModelTwoArgumentsSplitConstMulti cpuModel) memModel
modInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
modInteger = divideInteger

quotientInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
quotientInteger cpuModelR = do
  cpuModel <- readModelSplitConst cpuModelR
  -- Maximum size is the divisor size.
  -- y
  let memModel = ModelTwoArgumentsLinearSize $ ModelLinearSize 0 1 ModelOrientationY
  pure $ CostingFun (ModelTwoArgumentsSplitConstMulti cpuModel) memModel
remainderInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
remainderInteger = quotientInteger

lessThanInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
lessThanInteger cpuModelR = do
  cpuModel <- readModelMinSize cpuModelR
  pure $ CostingFun (ModelTwoArgumentsMinSize cpuModel) boolMemModel
greaterThanInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
greaterThanInteger = lessThanInteger

lessThanEqInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
lessThanEqInteger cpuModelR = do
  cpuModel <- readModelMinSize cpuModelR
  pure $ CostingFun (ModelTwoArgumentsMinSize cpuModel) boolMemModel
greaterThanEqInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
greaterThanEqInteger = lessThanEqInteger

eqInteger :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
eqInteger cpuModelR = do
  cpuModel <- readModelMinSize cpuModelR
  pure $ CostingFun (ModelTwoArgumentsMinSize cpuModel) boolMemModel

eqByteString :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
eqByteString cpuModelR = do
  cpuModel <- readModelMinSize cpuModelR
  pure $ CostingFun (ModelTwoArgumentsMinSize cpuModel) boolMemModel

ltByteString :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
ltByteString cpuModelR = do
  cpuModel <- readModelMinSize cpuModelR
  pure $ CostingFun (ModelTwoArgumentsMinSize cpuModel) boolMemModel

gtByteString :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
gtByteString = ltByteString

concatenate :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
concatenate cpuModelR = do
  cpuModel <- readModelAddedSizes cpuModelR
  -- The buffer gets reallocated
  let memModel = ModelTwoArgumentsAddedSizes $ ModelAddedSizes 0 1
  pure $ CostingFun (ModelTwoArgumentsAddedSizes cpuModel) memModel

takeByteString :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
takeByteString cpuModelR = do
  cpuModel <- readModelConstantCost cpuModelR
  -- The buffer gets reused.
  let memModel = ModelTwoArgumentsConstantCost 2
  pure $ CostingFun (ModelTwoArgumentsConstantCost cpuModel) memModel
dropByteString :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelTwoArguments)
dropByteString cpuModelR = do
  cpuModel <- readModelConstantCost cpuModelR
  -- The buffer gets reused.
  let memModel = ModelTwoArgumentsConstantCost 2
  pure $ CostingFun (ModelTwoArgumentsConstantCost cpuModel) memModel

sHA2 :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelOneArgument)
sHA2 cpuModelR = do
  cpuModel <- readModelLinear cpuModelR
  let memModel = ModelOneArgumentConstantCost (coerce $ memoryUsage $ PlutusHash.sha2 "")
  pure $ CostingFun (ModelOneArgumentLinearCost cpuModel) memModel
sHA3 :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelOneArgument)
sHA3 cpuModelR = do
  cpuModel <- readModelLinear cpuModelR
  let memModel = ModelOneArgumentConstantCost (coerce $ memoryUsage $ PlutusHash.sha3 "")
  pure $ CostingFun (ModelOneArgumentLinearCost cpuModel) memModel
verifySignature :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelThreeArguments)
verifySignature cpuModelR = do
  cpuModel <- readModelConstantCost cpuModelR
  pure $ CostingFun (ModelThreeArgumentsConstantCost cpuModel) (ModelThreeArgumentsConstantCost 1)
ifThenElse :: MonadR m => (SomeSEXP (Region m)) -> m (CostingFun ModelThreeArguments)
ifThenElse _ = pure def
