{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE PolyKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Cardano.Analysis.API.Ground
  ( module Cardano.Analysis.API.Ground
  , module Data.DataDomain
  , module Data.Time.Clock
  , BlockNo (..), EpochNo (..), SlotNo (..)
  )
where

import           Cardano.Prelude hiding (head, toText)
import           Cardano.Slotting.Slot (EpochNo (..), SlotNo (..))
import           Cardano.Util
import           Ouroboros.Network.Block (BlockNo (..))

import           Prelude as P (show)

import           Data.Aeson
import           Data.Aeson.Encode.Pretty
import           Data.Aeson.Types (toJSONKeyText)
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.CDF
import           Data.Data (Data)
import           Data.DataDomain
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import           Data.Text.Short (ShortText, fromText, toText)
import qualified Data.Text.Short as SText
import           Data.Time.Clock (NominalDiffTime, UTCTime)
import           Options.Applicative as Opt
import qualified System.FilePath as F

import qualified Unsafe.Coerce as Unsafe


newtype FieldName = FieldName { unFieldName :: Text }
  deriving (Eq, Generic, Ord)
  deriving newtype (FromJSON, IsString, ToJSON)
  deriving anyclass NFData

instance Show FieldName where
  show = ("FieldName " ++) . P.show . unFieldName

newtype TId = TId { unTId :: ShortText }
  deriving (Eq, Generic, Ord)
  deriving newtype (FromJSON, ToJSON)
  deriving anyclass NFData

instance Show TId where
  show = ("TId " ++) . P.show . unTId

newtype Hash = Hash { unHash :: ShortText }
  deriving (Eq, Generic, Ord, Data)
  deriving newtype (FromJSON, ToJSON)
  deriving anyclass NFData

shortHash :: Hash -> T.Text
shortHash = toText . SText.take 6 . unHash

instance Show Hash where show = T.unpack . toText . unHash

instance ToJSONKey Host where
  toJSONKey = toJSONKeyText (toText . unHost)
instance FromJSONKey Host where
  fromJSONKey = FromJSONKeyText (Host . fromText)
instance ToJSONKey Hash where
  toJSONKey = toJSONKeyText (toText . unHash)
instance FromJSONKey Hash where
  fromJSONKey = FromJSONKeyText (Hash . fromText)

newtype Count (a :: k) = Count { unCount :: Int }
  deriving (Eq, Generic, Ord, Show)
  deriving newtype (Divisible, FromJSON, Num, Real, ToJSON)
  deriving anyclass NFData

countMap :: Map.Map a b -> Count a
countMap = Count . Map.size

countList :: (a -> Bool) -> [a] -> Count a
countList f = Count . fromIntegral . count f

countLists :: (a -> Bool) -> [[a]] -> Count a
countLists f = Count . fromIntegral . sum . fmap (count f)

countListAll :: [a] -> Count a
countListAll = Count . fromIntegral . length

countListsAll :: [[a]] -> Count a
countListsAll = Count . fromIntegral . sum . fmap length

unsafeCoerceCount :: Count a -> Count b
unsafeCoerceCount = Unsafe.unsafeCoerce

newtype Host = Host { unHost :: ShortText }
  deriving (Eq, Generic, Ord)
  deriving newtype (IsString, FromJSON, ToJSON)
  deriving anyclass NFData

instance Show Host where
  show = ("Host " ++) . P.show . unHost

newtype EpochSlot = EpochSlot { unEpochSlot :: Word64 }
  deriving stock (Eq, Generic, Ord, Show)
  deriving newtype (FromJSON, NFData, ToJSON, Num)

newtype EpochSafeInt = EpochSafeInt { unEpochSafeInt :: Word64 }
  deriving stock (Eq, Generic, Ord, Show)
  deriving newtype (FromJSON, NFData, ToJSON, Num)

data HostDeduction
  = HostFromLogfilename
  deriving stock (Eq, Ord, Show)

---
--- Files
---
newtype InputDir
  = InputDir { unInputDir :: FilePath }
  deriving (Show, Eq)
  deriving newtype (NFData)

newtype JsonLogfile
  = JsonLogfile { unJsonLogfile :: FilePath }
  deriving (Show, Eq)
  deriving newtype (FromJSON, ToJSON, NFData)

newtype JsonInputFile (a :: Type)
  = JsonInputFile { unJsonInputFile :: FilePath }
  deriving (Show, Eq)
  deriving newtype (FromJSON, ToJSON)

newtype JsonOutputFile (a :: Type)
  = JsonOutputFile { unJsonOutputFile :: FilePath }
  deriving (Show, Eq)

newtype GnuplotOutputFile
  = GnuplotOutputFile { unGnuplotOutputFile :: FilePath }
  deriving (Show, Eq)

newtype OrgOutputFile
  = OrgOutputFile { unOrgOutputFile :: FilePath }
  deriving (Show, Eq)

newtype TextInputFile
  = TextInputFile { unTextInputFile :: FilePath }
  deriving (Show, Eq)

newtype TextOutputFile
  = TextOutputFile { unTextOutputFile :: FilePath }
  deriving (Show, Eq)

newtype CsvOutputFile
  = CsvOutputFile { unCsvOutputFile :: FilePath }
  deriving (Show, Eq)

newtype SqliteOutputFile
  = SqliteOutputFile { unSqliteOutputFile :: FilePath }
  deriving (Show, Eq)

newtype OutputFile
  = OutputFile { unOutputFile :: FilePath }
  deriving (Show, Eq)

data LogObjectSource =
    LogObjectSourceJSON   JsonLogfile
  | LogObjectSourceSQLite FilePath
  | LogObjectSourceOther  FilePath
  deriving (Show, Eq, Generic, NFData)

logObjectSourceFile :: LogObjectSource -> FilePath
logObjectSourceFile = \case
  LogObjectSourceJSON j   -> unJsonLogfile j
  LogObjectSourceSQLite f -> f
  LogObjectSourceOther f  -> f

toLogObjectSource :: FilePath -> LogObjectSource
toLogObjectSource fp
  | ext == ".sqlite" || ext == ".sqlite3" = LogObjectSourceSQLite fp
  | ext == ".json"                        = LogObjectSourceJSON (JsonLogfile fp)
  | otherwise                             = LogObjectSourceOther fp
  where
    ext = map toLower $ F.takeExtension fp

instance FromJSON LogObjectSource where
  parseJSON = withText "LogObjectSource" (pure . toLogObjectSource . T.unpack)

instance ToJSON LogObjectSource where
  toJSON = toJSON . logObjectSourceFile

---
--- Orphans
---
deriving newtype instance Real      BlockNo
deriving newtype instance Divisible BlockNo
deriving         instance Data      BlockNo

deriving newtype instance Real      SlotNo
deriving newtype instance Divisible SlotNo
deriving         instance Data      SlotNo

---
--- Readers
---
readJsonData :: FromJSON a => JsonInputFile a -> (Text -> b) -> ExceptT b IO a
readJsonData f err =
  unJsonInputFile f
  & LBS.readFile
  & fmap eitherDecode
  & newExceptT
  & firstExceptT (err . T.pack)

readJsonDataIO :: FromJSON a => JsonInputFile a -> IO (Either String a)
readJsonDataIO f =
  unJsonInputFile f
  & LBS.readFile
  & fmap eitherDecode

---
--- Parsers
---
optInputDir :: String -> String -> Parser InputDir
optInputDir optname desc =
  fmap InputDir $
    Opt.option Opt.str
      $ long optname
      <> metavar "DIR"
      <> help desc

optJsonLogfile :: String -> String -> Parser JsonLogfile
optJsonLogfile optname desc =
  fmap JsonLogfile $
    Opt.option Opt.str
      $ long optname
      <> metavar "JSONLOGFILE"
      <> help desc

optLogObjectSource :: String -> String -> Parser LogObjectSource
optLogObjectSource optname desc =
  fmap toLogObjectSource $
    Opt.option Opt.str
      $ long optname
      <> metavar "JSONLOGFILE|SQLITE3LOGFILE"
      <> help desc

argJsonLogfile :: Parser JsonLogfile
argJsonLogfile =
  JsonLogfile <$>
    Opt.argument Opt.str (Opt.metavar "LOGFILE")

optJsonInputFile :: String -> String -> Parser (JsonInputFile a)
optJsonInputFile optname desc =
  fmap JsonInputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "JSON-FILE"
      <> help desc

optJsonOutputFile :: String -> String -> Parser (JsonOutputFile a)
optJsonOutputFile optname desc =
  fmap JsonOutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "JSON-OUTFILE"
      <> help desc

optGnuplotOutputFile :: String -> String -> Parser GnuplotOutputFile
optGnuplotOutputFile optname desc =
  fmap GnuplotOutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "CDF-OUTFILE"
      <> help desc

optTextInputFile :: String -> String -> Parser TextInputFile
optTextInputFile optname desc =
  fmap TextInputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "TEXT-INFILE"
      <> help desc

optTextOutputFile :: String -> String -> Parser TextOutputFile
optTextOutputFile optname desc =
  fmap TextOutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "TEXT-OUTFILE"
      <> help desc

optCsvOutputFile :: String -> String -> Parser CsvOutputFile
optCsvOutputFile optname desc =
  fmap CsvOutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "CSV-OUTFILE"
      <> help desc

optSqliteOutputFile :: String -> String -> Parser SqliteOutputFile
optSqliteOutputFile optname desc =
  fmap SqliteOutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "SQLITE-OUTFILE"
      <> help desc

optOutputFile :: String -> String -> Parser OutputFile
optOutputFile optname desc =
  fmap OutputFile $
    Opt.option Opt.str
      $ long optname
      <> metavar "OUTFILE"
      <> help desc

pSlotNo :: String -> String -> Parser SlotNo
pSlotNo name desc =
  SlotNo <$>
    Opt.option Opt.auto
     (  Opt.long name
     <> Opt.metavar "SLOT"
     <> Opt.help desc
     )

optWord :: String -> String -> Word64 -> Parser Word64
optWord optname desc def =
  Opt.option auto
    $ long optname
    <> metavar "INT"
    <> help desc
    <> value def

optString :: String -> String -> Parser String
optString optname desc =
  Opt.option Opt.str $
    long optname <> metavar "STRING" <> Opt.help desc

-- /path/to/logs-HOSTNAME.some.ext -> HOSTNAME
hostFromLogfilename :: JsonLogfile -> Host
hostFromLogfilename (JsonLogfile f) =
  Host $ fromText . stripPrefixHard "logs-" . T.pack . F.dropExtensions . F.takeFileName $ f
 where
   stripPrefixHard :: Text -> Text -> Text
   stripPrefixHard p s = fromMaybe s $ T.stripPrefix p s

hostDeduction :: HostDeduction -> (JsonLogfile -> Host)
hostDeduction = \case
  HostFromLogfilename -> hostFromLogfilename

dumpObject :: ToJSON a => String -> a -> JsonOutputFile a -> ExceptT Text IO ()
dumpObject ident x (JsonOutputFile f) = liftIO $ do
  progress ident (Q f)
  withFile f WriteMode $ \hnd -> LBS.hPutStrLn hnd $ encode x

dumpObjects :: ToJSON a => String -> [a] -> JsonOutputFile [a] -> ExceptT Text IO ()
dumpObjects ident xs (JsonOutputFile f) = liftIO $ do
  progress ident (Q f)
  withFile f WriteMode $ \hnd -> do
    forM_ xs $ LBS.hPutStrLn hnd . encode

dumpAssociatedObjects :: ToJSON a => String -> [(LogObjectSource, a)] -> ExceptT Text IO ()
dumpAssociatedObjects = dumpAssociatedObjectsWith encode

dumpAssociatedObjectsPretty :: ToJSON a => String -> [(LogObjectSource, a)] -> ExceptT Text IO ()
dumpAssociatedObjectsPretty = dumpAssociatedObjectsWith (encodePretty' defConfig {confCompare = compare, confTrailingNewline = True})

dumpAssociatedObjectsWith :: (a -> LBS.ByteString) -> String -> [(LogObjectSource, a)] -> ExceptT Text IO ()
dumpAssociatedObjectsWith encoder ident xs = liftIO $
  flip mapConcurrently_ xs $
    \(logObjectSourceFile -> f, x) ->
      withFile (replaceExtension f $ ident <> ".json") WriteMode $ \hnd ->
        LBS.hPutStrLn hnd $ encoder x

readAssociatedObjects :: forall a.
  FromJSON a => String -> [JsonLogfile] -> ExceptT Text IO [(LogObjectSource, a)]
readAssociatedObjects ident fs = firstExceptT T.pack . newExceptT . fmap (mapM sequence) $
  flip mapConcurrently fs $
    \jf@(JsonLogfile f) -> do
        x <- eitherDecode @a <$> LBS.readFile (replaceExtension f $ ident <> ".json")
        progress ident (Q f)
        pure (LogObjectSourceJSON jf, x)

dumpAssociatedObjectStreams :: ToJSON a => String -> [(LogObjectSource, [a])] -> ExceptT Text IO ()
dumpAssociatedObjectStreams ident xss = liftIO $
  flip mapConcurrently_ xss $
    \(logObjectSourceFile -> f, xs) -> do
      withFile (replaceExtension f $ ident <> ".json") WriteMode $ \hnd -> do
        forM_ xs $ LBS.hPutStrLn hnd . encode

dumpText :: String -> [Text] -> TextOutputFile -> ExceptT Text IO ()
dumpText ident xs (TextOutputFile f) = liftIO $ do
  progress ident (Q f)
  withFile f WriteMode $ \hnd -> do
    forM_ xs $ hPutStrLn hnd

dumpAssociatedTextStreams :: String -> [(LogObjectSource, [Text])] -> ExceptT Text IO ()
dumpAssociatedTextStreams ident xss = liftIO $
  flip mapConcurrently_ xss $
    \(logObjectSourceFile -> f, xs) -> do
      withFile (replaceExtension f $ ident <> ".txt") WriteMode $ \hnd -> do
        forM_ xs $ hPutStrLn hnd
