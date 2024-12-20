{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-missed-specialisations #-} -- suppressing fromFloatDigits warning

module Database.Oracle.Simple.JSON (AesonField (..), JsonDecodeError (..), DPIJsonNode(..), getJson, DPIJson(..), dpiJson_getValue, parseJson) where

import Control.Exception (Exception (displayException), SomeException, catch, evaluate, throwIO)
import Control.Monad (void, (<=<))
import qualified Data.Aeson as Aeson
import Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as LBS
import Data.Coerce (coerce)
import Data.Scientific (fromFloatDigits)
import Data.String (fromString)
import Data.Text.Encoding (decodeUtf8)
import qualified Data.Vector as Vector
import Foreign (Ptr, Storable, alloca, peekArray)
import Foreign.C (CDouble (CDouble), CInt (CInt), CString, CUInt (CUInt), peekCStringLen)
import Foreign.Storable.Generic (GStorable, Storable(..))
import Foreign.Ptr (castPtr, plusPtr)
import GHC.Generics (Generic)

import Database.Oracle.Simple.FromField (FieldParser (FieldParser), FromField (fromDPINativeType, fromField), ReadDPIBuffer)
import Database.Oracle.Simple.Internal
  ( DPIBytes (DPIBytes, dpiBytesLength, dpiBytesPtr),
    DPIData,
    DPINativeType
      ( DPI_NATIVE_TYPE_BOOLEAN,
        DPI_NATIVE_TYPE_BYTES,
        DPI_NATIVE_TYPE_DOUBLE,
        DPI_NATIVE_TYPE_JSON,
        DPI_NATIVE_TYPE_JSON_ARRAY,
        DPI_NATIVE_TYPE_JSON_OBJECT,
        DPI_NATIVE_TYPE_NULL
      ),
    DPIOracleType (DPI_ORACLE_TYPE_NUMBER),
    ReadBuffer,
    WriteBuffer (AsBytes),
    mkDPIBytesUTF8,
  )
import Database.Oracle.Simple.ToField (ToField (toDPINativeType, toField))

{- | Use this newtype with the DerivingVia extension to
derive ToField/FromField instances for types that you want
to serialize via their Aeson instance.
-}
newtype AesonField a = AesonField {unAesonField :: a}
  deriving newtype (Aeson.ToJSON, Aeson.FromJSON)

instance (Aeson.ToJSON a) => ToField (AesonField a) where
  toDPINativeType _ = DPI_NATIVE_TYPE_BYTES

  -- Oracle allows JSON data to be inserted using the character API.
  toField =
    fmap AsBytes
      . mkDPIBytesUTF8
      . C8.unpack
      . LBS.toStrict
      . Aeson.encode
      . unAesonField

-- | For use with columns that have @JSON@ data type (since Oracle 21c)
instance (Aeson.FromJSON a) => FromField (AesonField a) where
  fromDPINativeType _ = DPI_NATIVE_TYPE_JSON

  -- ODPI does not support casting from DPI_ORACLE_TYPE_JSON to DPI_NATIVE_TYPE_BYTES.
  -- This means we need to build an aeson Value from the top-level DPIJsonNode.
  fromField = coerce (FieldParser (getJson @a))

-- | Reads a JSON object from a DPI buffer.
-- This function is parameterized over any type that has an 'Aeson.FromJSON' instance.
getJson :: (Aeson.FromJSON a) => ReadDPIBuffer a
getJson = parseJson <=< peek <=< dpiJson_getValue <=< dpiData_getJson

-- | Parses a 'DPIJsonNode' into a Haskell value.
-- This function requires a type with an 'Aeson.FromJSON' instance to convert the JSON node.
parseJson :: Aeson.FromJSON b => DPIJsonNode -> IO b
parseJson topNode = do
  aesonValue <- buildValue topNode
  case Aeson.fromJSON aesonValue of
    Aeson.Error msg -> throwIO $ ParseError msg
    Aeson.Success a -> pure a

-- Build Aeson values for various cases:
-- Object
buildValue :: DPIJsonNode -> IO Aeson.Value
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_JSON_OBJECT nodeValue) = do
  DPIJsonObject {..} <- peek =<< dpiDataBuffer_getAsJsonObject nodeValue
  fieldNamePtrs <- peekArray (fromIntegral djoNumFields) djoFieldNames
  fieldNameLengths <- fmap fromIntegral <$> peekArray (fromIntegral djoNumFields) djoFieldNameLengths
  ks <- mapM (fmap fromString . peekCStringLen) (zip fieldNamePtrs fieldNameLengths)
  values <- mapM buildValue =<< peekArray (fromIntegral djoNumFields) djoFields
  pure $ Aeson.Object $ KeyMap.fromList (zip ks values)
-- Array
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_JSON_ARRAY nodeValue) = do
  DPIJsonArray {..} <- peek =<< dpiDataBuffer_getAsJsonArray nodeValue
  values <- mapM buildValue =<< peekArray (fromIntegral djaNumElements) djaElements
  pure $ Aeson.Array $ Vector.fromList values
-- Number returned as DPIBytes
buildValue (DPIJsonNode DPI_ORACLE_TYPE_NUMBER DPI_NATIVE_TYPE_BYTES nodeValue) = do
  DPIBytes {..} <- peek =<< dpiDataBuffer_getAsBytes nodeValue
  bytes <- BS.packCStringLen (dpiBytesPtr, fromIntegral dpiBytesLength)
  let numStr = C8.unpack bytes
  number <- evaluate (read numStr) `catch` (\(_ :: SomeException) -> throwIO $ InvalidNumber numStr)
  pure $ Aeson.Number number
-- String
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_BYTES nodeValue) = do
  DPIBytes {..} <- peek =<< dpiDataBuffer_getAsBytes nodeValue
  bytes <- BS.packCStringLen (dpiBytesPtr, fromIntegral dpiBytesLength)
  pure $ Aeson.String (decodeUtf8 bytes)
-- Number encoded as Double (will not fire as dpiJsonOptions_numberAsString is set)
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_DOUBLE nodeValue) = do
  doubleVal <- dpiDataBuffer_getAsDouble nodeValue
  pure $ Aeson.Number $ fromFloatDigits doubleVal
-- Boolean literals (true, false)
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_BOOLEAN nodeValue) = do
  intVal <- dpiDataBuffer_getAsBoolean nodeValue
  pure $ Aeson.Bool (intVal == 1)
-- Null literal (null)
buildValue (DPIJsonNode _ DPI_NATIVE_TYPE_NULL _) = pure Aeson.Null
-- All other DPI native types
buildValue (DPIJsonNode _ nativeType _) = throwIO $ UnsupportedDPINativeType nativeType

-- | Represents a JSON object in the Oracle database.
-- The 'DPIJson' type wraps a pointer to a DPI JSON structure.
newtype DPIJson = DPIJson (Ptr DPIJson)
  deriving (Show, Eq)
  deriving newtype (Storable)

-- | Represents a JSON node in Oracle, including type numbers and value buffer.
-- The 'DPIJsonNode' type is used for handling JSON data within Oracle operations.
data DPIJsonNode = DPIJsonNode
  { djnOracleTypeNumber :: DPIOracleType  -- ^ Oracle's type number for the JSON node.
  , djnNativeTypeNumber :: DPINativeType  -- ^ Native type number for the JSON node.
  , djnValue :: Ptr ReadBuffer            -- ^ Pointer to the buffer storing the node's value.
  }
  deriving (Eq, Show)

instance Storable DPIJsonNode where
    sizeOf _ = sizeOf (undefined :: DPIOracleType)
                + sizeOf (undefined :: DPINativeType)
                    + sizeOf (undefined :: Ptr ReadBuffer)
    alignment _ = alignment (undefined :: DPIOracleType)

    peek ptr = do
      let base = castPtr ptr
      DPIJsonNode
        <$> peek (base `plusPtr` 0) -- DPIOracleType
        <*> peek (base `plusPtr` sizeOf (undefined :: DPIOracleType)) -- DPINativeType
        <*> peek (base `plusPtr` sizeOf (undefined :: DPIOracleType)
                                   `plusPtr` sizeOf (undefined :: DPINativeType)) -- Ptr ReadBuffer
    poke ptr DPIJsonNode{..} = do
      let base = castPtr ptr
      poke (base `plusPtr` 0) djnOracleTypeNumber
      poke (base `plusPtr` sizeOf (undefined :: DPIOracleType)) djnNativeTypeNumber
      poke (base `plusPtr` sizeOf (undefined :: DPIOracleType)
                    `plusPtr` sizeOf (undefined :: Ptr ReadBuffer)) djnValue

data DPIJsonArray = DPIJsonArray
  { djaNumElements :: CUInt
  , djaElements :: Ptr DPIJsonNode
  , djaElementValues :: Ptr ReadBuffer
  }
  deriving (Generic)
  deriving anyclass (GStorable)

data DPIJsonObject = DPIJsonObject
  { djoNumFields :: CUInt
  , djoFieldNames :: Ptr CString
  , djoFieldNameLengths :: Ptr CUInt
  , djoFields :: Ptr DPIJsonNode
  , fieldValues :: Ptr ReadBuffer
  }
  deriving (Generic)
  deriving anyclass (GStorable)

foreign import ccall "dpiData_getJson"
  dpiData_getJson :: Ptr (DPIData ReadBuffer) -> IO DPIJson

foreign import ccall "dpiJson_getValue"
  dpiJson_getValue' :: DPIJson -> CUInt -> Ptr (Ptr DPIJsonNode) -> IO CInt

-- | Retrieves the value of a JSON object as a pointer to a 'DPIJsonNode'.
-- This function performs an IO action to extract the JSON node from a 'DPIJson'.
dpiJson_getValue :: DPIJson -> IO (Ptr DPIJsonNode)
dpiJson_getValue dpiJson = alloca $ \ptr -> do
  let dpiJsonOptions_numberAsString = 0x01 -- return data from numeric fields as DPIBytes
  void $ dpiJson_getValue' dpiJson dpiJsonOptions_numberAsString ptr
  peek ptr

foreign import ccall "dpiDataBuffer_getAsJsonObject"
  dpiDataBuffer_getAsJsonObject :: Ptr ReadBuffer -> IO (Ptr DPIJsonObject)

foreign import ccall "dpiDataBuffer_getAsJsonArray"
  dpiDataBuffer_getAsJsonArray :: Ptr ReadBuffer -> IO (Ptr DPIJsonArray)

foreign import ccall "dpiDataBuffer_getAsBytes"
  dpiDataBuffer_getAsBytes :: Ptr ReadBuffer -> IO (Ptr DPIBytes)

foreign import ccall "dpiDataBuffer_getAsBoolean"
  dpiDataBuffer_getAsBoolean :: Ptr ReadBuffer -> IO CInt

foreign import ccall "dpiDataBuffer_getAsDouble"
  dpiDataBuffer_getAsDouble :: Ptr ReadBuffer -> IO CDouble

-- | Represents errors that may occur during JSON decoding.
-- 'JsonDecodeError' includes specific errors for invalid numbers,
-- parsing errors, and unsupported native types.
data JsonDecodeError = InvalidNumber String | ParseError String | UnsupportedDPINativeType DPINativeType
  deriving (Show)

instance Exception JsonDecodeError where
  displayException (ParseError msg) = "Failed to parse JSON: " <> msg
  displayException (InvalidNumber numStr) =
    "While parsing JSON node, encountered invalid numeric value '" <> numStr <> "'"
  displayException (UnsupportedDPINativeType nativeType) =
    "While parsing JSON node, encountered unsupported DPI native type " <> show nativeType
