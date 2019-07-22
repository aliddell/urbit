{-# OPTIONS_GHC -Wwarn #-}

module Noun.Conversions
  ( Nullable(..), Jammed(..), AtomCell(..)
  , Word128, Word256, Word512
  , Bytes(..), Octs(..)
  , Cord(..), Knot(..), Term(..), Tape(..), Tour(..)
  , Tank(..), Tang, Plum(..)
  , Mug(..), Path(..), Ship(..)
  , Lenient(..)
  ) where

import ClassyPrelude hiding (hash)

import Control.Lens hiding (Index)
import Data.Void
import Data.Word
import Noun.Atom
import Noun.Convert
import Noun.Core
import Noun.TH
import Text.Regex.TDFA
import Text.Regex.TDFA.Text ()

import Data.LargeWord   (LargeKey, Word128, Word256)
import GHC.Exts         (chr#, isTrue#, leWord#, word2Int#)
import GHC.Natural      (Natural)
import GHC.Types        (Char(C#))
import GHC.Word         (Word32(W32#))
import Noun.Cue         (cue)
import Noun.Jam         (jam)
import RIO              (decodeUtf8Lenient)
import System.IO.Unsafe (unsafePerformIO)

import qualified Data.Char                as C
import qualified Data.Text.Encoding       as T
import qualified Data.Text.Encoding.Error as T


-- Noun ------------------------------------------------------------------------

instance ToNoun Noun where
  toNoun = id

instance FromNoun Noun where
  parseNoun = pure


--- Atom -----------------------------------------------------------------------

instance ToNoun Atom where
  toNoun = Atom

instance FromNoun Atom where
  parseNoun = named "Atom" . \case
    Atom a   -> pure a
    Cell _ _ -> fail "Expecting an atom, but got a cell"


-- Void ------------------------------------------------------------------------

instance ToNoun Void where
  toNoun = absurd

instance FromNoun Void where
  parseNoun _ = named "Void" $ fail "Can't produce void"


-- Cord ------------------------------------------------------------------------

newtype Cord = Cord { unCord :: Text }
  deriving newtype (Eq, Ord, Show, IsString, NFData)

instance ToNoun Cord where
  toNoun = textToUtf8Atom . unCord

instance FromNoun Cord where
  parseNoun = named "Cord" . fmap Cord . parseNounUtf8Atom


-- Char ------------------------------------------------------------------------

instance ToNoun Char where
  toNoun = Atom . fromIntegral . C.ord

{-
    Hack: pulled this logic from Data.Char impl.
-}
instance FromNoun Char where
  parseNoun n = named "Char" $ do
    W32# w :: Word32 <- parseNoun n
    if isTrue# (w `leWord#` 0x10FFFF##)
      then pure (C# (chr# (word2Int# w)))
      else fail "Word is not a valid character."


-- Tour ------------------------------------------------------------------------

newtype Tour = Tour [Char]
  deriving newtype (Eq, Ord, Show, ToNoun, FromNoun)


-- Double Jammed ---------------------------------------------------------------

newtype Jammed a = Jammed a
  deriving (Eq, Ord, Show)

instance ToNoun a => ToNoun (Jammed a) where
  toNoun (Jammed a) = Atom $ jam $ toNoun a

instance FromNoun a => FromNoun (Jammed a) where
  parseNoun n = named "Jammed" $ do
    a <- parseNoun n
    cue a & \case
      Left err  -> fail (show err)
      Right res -> do
        Jammed <$> parseNoun res


-- Atom or Cell ----------------------------------------------------------------

type Word512 = LargeKey Word256 Word256

data AtomCell a c
    = ACAtom a
    | ACCell c
  deriving (Eq, Ord, Show)

instance (ToNoun a, ToNoun c) => ToNoun (AtomCell a c) where
  toNoun (ACAtom a) = toNoun a
  toNoun (ACCell c) = toNoun c

instance (FromNoun a, FromNoun c) => FromNoun (AtomCell a c) where
  parseNoun n = named "(,)" $ case n of
                                Atom _   -> ACAtom <$> parseNoun n
                                Cell _ _ -> ACCell <$> parseNoun n


-- Lenient ---------------------------------------------------------------------

data Lenient a
    = FailParse Noun
    | GoodParse a
  deriving (Eq, Ord, Show)

instance FromNoun a => FromNoun (Lenient a) where
  parseNoun n =
      (GoodParse <$> parseNoun n) <|> fallback
    where
      fallback =
        fromNounErr n & \case
          Right x  -> pure (GoodParse x)
          Left err -> do
            traceM ("LENIENT.FromNoun: " <> show err)
            pure (FailParse n)

instance ToNoun a => ToNoun (Lenient a) where
  toNoun (FailParse n) = trace ("LENIENT.ToNoun: " <> show n)
                           n
  toNoun (GoodParse x) = toNoun x


-- Nullable --------------------------------------------------------------------

{-|
    `Nullable a <-> ?@(~ a)`

    This is distinct from `unit`, since there is no tag on the non-atom
    case, therefore `a` must always be cell type.
-}
data Nullable a = None | Some a
  deriving (Eq, Ord, Show)

instance ToNoun a => ToNoun (Nullable a) where
  toNoun = toNoun . \case None   -> ACAtom ()
                          Some x -> ACCell x

instance FromNoun a => FromNoun (Nullable a) where
  parseNoun n = named "Nullable" $ do
    parseNoun n >>= \case
      (ACAtom ()) -> pure None
      (ACCell x)  -> pure (Some x)


-- List ------------------------------------------------------------------------

instance ToNoun a => ToNoun [a] where
  toNoun xs = nounFromList (toNoun <$> xs)
    where
      nounFromList :: [Noun] -> Noun
      nounFromList []     = Atom 0
      nounFromList (x:xs) = Cell x (nounFromList xs)

instance FromNoun a => FromNoun [a] where
  parseNoun = named "[]" . \case
      Atom 0   -> pure []
      Atom _   -> fail "list terminated with non-null atom"
      Cell l r -> (:) <$> parseNoun l <*> parseNoun r


-- Tape ------------------------------------------------------------------------

{-
    A `tape` is a list of utf8 bytes.
-}
newtype Tape = Tape { unTape :: Text }
  deriving newtype (Eq, Ord, Show, Semigroup, Monoid, IsString)

instance ToNoun Tape where
  toNoun = toNoun . (unpack :: ByteString -> [Word8]) . encodeUtf8 . unTape

instance FromNoun Tape where
  parseNoun n = named "Tape" $ do
    as :: [Word8] <- parseNoun n
    T.decodeUtf8' (pack as) & \case
        Left err -> fail (show err)
        Right tx -> pure (Tape tx)



-- Pretty Printing -------------------------------------------------------------

type Tang = [Tank]

data Tank
    = Leaf Tape
    | Plum Plum
    | Palm (Tape, Tape, Tape, Tape) [Tank]
    | Rose (Tape, Tape, Tape) [Tank]
  deriving (Eq, Ord, Show)

data WideFmt = WideFmt { delimit :: Cord, enclose :: Maybe (Cord, Cord) }
  deriving (Eq, Ord, Show)

data TallFmt = TallFmt { intro :: Cord, indef :: Maybe (Cord, Cord) }
  deriving (Eq, Ord, Show)

data PlumFmt = PlumFmt (Maybe WideFmt) (Maybe TallFmt)
  deriving (Eq, Ord, Show)

type Plum = AtomCell Cord PlumTree

data PlumTree
    = Para Cord [Cord]
    | Tree PlumFmt [Plum]
    | Sbrk Plum
  deriving (Eq, Ord, Show)

deriveNoun ''WideFmt
deriveNoun ''TallFmt
deriveNoun ''PlumFmt
deriveNoun ''Tank
deriveNoun ''PlumTree


-- Bytes -----------------------------------------------------------------------

newtype Bytes = MkBytes { unBytes :: ByteString }
  deriving newtype (Eq, Ord, Show)

instance ToNoun Bytes where
    toNoun = Atom . view (from atomBytes) . unBytes

instance FromNoun Bytes where
    parseNoun = named "Bytes" . fmap (MkBytes . view atomBytes) . parseNoun


-- Octs ------------------------------------------------------------------------

newtype Octs = Octs { unOcts :: ByteString }
  deriving newtype (Eq, Ord, Show)

instance ToNoun Octs where
  toNoun (Octs bs) =
      toNoun (int2Word (length bs), bs ^. from atomBytes)
    where
      int2Word :: Int -> Word
      int2Word = fromIntegral

instance FromNoun Octs where
    parseNoun x = named "Octs" $ do
        (word2Int -> len, atom) <- parseNoun x
        let bs = atom ^. atomBytes
        pure $ Octs $ case compare (length bs) len of
          EQ -> bs
          LT -> bs <> replicate (len - length bs) 0
          GT -> take len bs
      where
        word2Int :: Word -> Int
        word2Int = fromIntegral


-- Knot ------------------------------------------------------------------------

{-
    Knot (@ta) is an array of Word8 encoding an ASCII string.
-}
newtype Knot = MkKnot { unKnot :: Text }
  deriving newtype (Eq, Ord, Show, Semigroup, Monoid, IsString)

instance ToNoun Knot where
  toNoun = textToUtf8Atom . unKnot

instance FromNoun Knot where
  parseNoun n = named "Knot" $ do
    txt <- parseNounUtf8Atom n
    if all C.isAscii txt
      then pure (MkKnot txt)
      else fail ("Non-ASCII chars in knot: " <> unpack txt)


-- Term ------------------------------------------------------------------------

{-
    A Term (@tas) is a Knot satisfying the regular expression:

        ([a-z][a-z0-9]*(-[a-z0-9]+)*)?
-}
newtype Term = MkTerm { unTerm :: Text }
  deriving newtype (Eq, Ord, Show, Semigroup, Monoid, IsString)

instance ToNoun Term where -- XX TODO
  toNoun = textToUtf8Atom . unTerm

knotRegex :: Text
knotRegex = "([a-z][a-z0-9]*(-[a-z0-9]+)*)?"

instance FromNoun Term where -- XX TODO
  parseNoun n = named "Term" $ do
    MkKnot t <- parseNoun n
    if t =~ knotRegex
      then pure (MkTerm t)
      else fail ("Term not valid symbol: " <> unpack t)


-- Ship ------------------------------------------------------------------------

newtype Ship = Ship Word128 -- @p
  deriving newtype (Eq, Ord, Show, Num, ToNoun, FromNoun)


-- Path ------------------------------------------------------------------------

newtype Path = Path [Knot]
  deriving newtype (Eq, Ord, Semigroup, Monoid)

instance Show Path where
  show (Path ks) = show $ intercalate "/" ("" : ks)


-- Mug -------------------------------------------------------------------------

newtype Mug = Mug Word32
  deriving newtype (Eq, Ord, Show, Num, ToNoun, FromNoun)


-- Bool ------------------------------------------------------------------------

instance ToNoun Bool where
  toNoun True  = Atom 0
  toNoun False = Atom 1

instance FromNoun Bool where
  parseNoun = named "Bool" . parse
    where
      parse n =
        parseNoun n >>= \case
          (0::Atom) -> pure True
          1         -> pure False
          _         -> fail "Atom is not a valid loobean"


-- Integer ---------------------------------------------------------------------

instance ToNoun Integer where
    toNoun = toNoun . (fromIntegral :: Integer -> Natural)

instance FromNoun Integer where
    parseNoun = named "Integer" . fmap natInt . parseNoun
      where
        natInt :: Natural -> Integer
        natInt = fromIntegral


-- Words -----------------------------------------------------------------------

atomToWord :: forall a. (Bounded a, Integral a) => Atom -> Parser a
atomToWord atom = do
  if atom > fromIntegral (maxBound :: a)
  then fail "Atom doesn't fit in fixed-size word"
  else pure (fromIntegral atom)

wordToNoun :: Integral a => a -> Noun
wordToNoun = Atom . fromIntegral

nounToWord :: forall a. (Bounded a, Integral a) => Noun -> Parser a
nounToWord = parseNoun >=> atomToWord

instance ToNoun Word    where toNoun = wordToNoun
instance ToNoun Word8   where toNoun = wordToNoun
instance ToNoun Word16  where toNoun = wordToNoun
instance ToNoun Word32  where toNoun = wordToNoun
instance ToNoun Word64  where toNoun = wordToNoun
instance ToNoun Word128 where toNoun = wordToNoun
instance ToNoun Word256 where toNoun = wordToNoun
instance ToNoun Word512 where toNoun = wordToNoun

instance FromNoun Word    where parseNoun = named "Word"    . nounToWord
instance FromNoun Word8   where parseNoun = named "Word8"   . nounToWord
instance FromNoun Word16  where parseNoun = named "Word16"  . nounToWord
instance FromNoun Word32  where parseNoun = named "Word32"  . nounToWord
instance FromNoun Word64  where parseNoun = named "Word64"  . nounToWord
instance FromNoun Word128 where parseNoun = named "Word128" . nounToWord
instance FromNoun Word256 where parseNoun = named "Word256" . nounToWord
instance FromNoun Word512 where parseNoun = named "Word512" . nounToWord


-- Maybe is `unit` -------------------------------------------------------------

-- TODO Consider enforcing that `a` must be a cell.
instance ToNoun a => ToNoun (Maybe a) where
  toNoun Nothing  = Atom 0
  toNoun (Just x) = Cell (Atom 0) (toNoun x)

instance FromNoun a => FromNoun (Maybe a) where
  parseNoun = named "Maybe" . \case
      Atom          0   -> pure Nothing
      Atom          n   -> unexpected ("atom " <> show n)
      Cell (Atom 0) t   -> Just <$> parseNoun t
      Cell n        _   -> unexpected ("cell with head-atom " <> show n)
    where
      unexpected s = fail ("Expected unit value, but got " <> s)


-- Either is `each` ------------------------------------------------------------

instance (ToNoun a, ToNoun b) => ToNoun (Either a b) where
  toNoun (Left x)  = Cell (Atom 0) (toNoun x)
  toNoun (Right x) = Cell (Atom 1) (toNoun x)

instance (FromNoun a, FromNoun b) => FromNoun (Either a b) where
  parseNoun n = named "Either" $ do
      (Atom tag, v) <- parseNoun n
      case tag of
        0 -> named "%|" (Left <$> parseNoun v)
        1 -> named "%&" (Right <$> parseNoun v)
        n -> fail ("Each has invalid head-atom: " <> show n)


-- Tuple Conversions -----------------------------------------------------------

instance ToNoun () where
  toNoun () = Atom 0

instance FromNoun () where
  parseNoun = named "()" . \case
    Atom 0 -> pure ()
    x      -> fail ("expecting `~`, but got " <> show x)

instance (ToNoun a, ToNoun b) => ToNoun (a, b) where
  toNoun (x, y) = Cell (toNoun x) (toNoun y)


shortRec :: Word -> Parser a
shortRec 0 = fail "expected a record, but got an atom"
shortRec 1 = fail ("record too short, only one cell")
shortRec n = fail ("record too short, only " <> show n <> " cells")

instance (FromNoun a, FromNoun b) => FromNoun (a, b) where
  parseNoun n = named ("(,)") $ do
    case n of
      A _   -> shortRec 0
      C x y -> do
        (,) <$> named "1" (parseNoun x)
            <*> named "2" (parseNoun y)

instance (ToNoun a, ToNoun b, ToNoun c) => ToNoun (a, b, c) where
  toNoun (x, y, z) = toNoun (x, (y, z))

instance (FromNoun a, FromNoun b, FromNoun c) => FromNoun (a, b, c) where
  parseNoun n = named "(,,)" $ do
    case n of
      A _         -> shortRec 0
      C x (A _)   -> shortRec 1
      C x (C y z) ->
        (,,) <$> named "1" (parseNoun x)
             <*> named "2" (parseNoun y)
             <*> named "3" (parseNoun z)

instance (ToNoun a, ToNoun b, ToNoun c, ToNoun d) => ToNoun (a, b, c, d) where
  toNoun (p, q, r, s) = toNoun (p, (q, r, s))

instance (FromNoun a, FromNoun b, FromNoun c, FromNoun d)
      => FromNoun (a, b, c, d)
      where
  parseNoun n = named "(,,,)" $ do
    case n of
      A _               -> shortRec 0
      C _ (A _)         -> shortRec 1
      C _ (C _ (A _))   -> shortRec 2
      C p (C q (C r s)) ->
        (,,,) <$> named "1" (parseNoun p)
              <*> named "2" (parseNoun q)
              <*> named "3" (parseNoun r)
              <*> named "4" (parseNoun s)

instance (ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e)
      => ToNoun (a, b, c, d, e) where
  toNoun (p, q, r, s, t) = toNoun (p, (q, r, s, t))

instance (FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e)
      => FromNoun (a, b, c, d, e)
      where
  parseNoun n = named "(,,,,)" $ do
    case n of
      A _                     -> shortRec 0
      C _ (A _)               -> shortRec 1
      C _ (C _ (A _))         -> shortRec 2
      C _ (C _ (C _ (A _)))   -> shortRec 3
      C p (C q (C r (C s t))) ->
        (,,,,) <$> named "1" (parseNoun p)
               <*> named "2" (parseNoun q)
               <*> named "3" (parseNoun r)
               <*> named "4" (parseNoun s)
               <*> named "5" (parseNoun t)

instance (ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e, ToNoun f)
      => ToNoun (a, b, c, d, e, f) where
  toNoun (p, q, r, s, t, u) = toNoun (p, (q, r, s, t, u))

instance ( FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e
         , FromNoun f
         )
      => FromNoun (a, b, c, d, e, f)
      where
  parseNoun n = named "(,,,,,)" $ do
    (p, tail)       <- parseNoun n
    (q, r, s, t, u) <- parseNoun tail
    pure (p, q, r, s, t, u)

instance (ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e, ToNoun f, ToNoun g)
      => ToNoun (a, b, c, d, e, f, g) where
  toNoun (p, q, r, s, t, u, v) = toNoun (p, (q, r, s, t, u, v))

instance ( FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e
         , FromNoun f, FromNoun g
         )
      => FromNoun (a, b, c, d, e, f, g)
      where
  parseNoun n = named "(,,,,,,)" $ do
    (p, tail)          <- parseNoun n
    (q, r, s, t, u, v) <- parseNoun tail
    pure (p, q, r, s, t, u, v)

instance ( ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e, ToNoun f, ToNoun g
         , ToNoun h
         )
      => ToNoun (a, b, c, d, e, f, g, h) where
  toNoun (p, q, r, s, t, u, v, w) = toNoun (p, (q, r, s, t, u, v, w))

instance ( FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e
         , FromNoun f, FromNoun g, FromNoun h
         )
      => FromNoun (a, b, c, d, e, f, g, h)
      where
  parseNoun n = named "(,,,,,,,)" $ do
    (p, tail)             <- parseNoun n
    (q, r, s, t, u, v, w) <- parseNoun tail
    pure (p, q, r, s, t, u, v, w)

instance ( ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e, ToNoun f, ToNoun g
         , ToNoun h, ToNoun i
         )
      => ToNoun (a, b, c, d, e, f, g, h, i) where
  toNoun (p, q, r, s, t, u, v, w, x) = toNoun (p, (q, r, s, t, u, v, w, x))

instance ( FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e
         , FromNoun f, FromNoun g, FromNoun h, FromNoun i
         )
      => FromNoun (a, b, c, d, e, f, g, h, i)
      where
  parseNoun n = named "(,,,,,,,,)" $ do
    (p, tail)                <- parseNoun n
    (q, r, s, t, u, v, w, x) <- parseNoun tail
    pure (p, q, r, s, t, u, v, w, x)

instance ( ToNoun a, ToNoun b, ToNoun c, ToNoun d, ToNoun e, ToNoun f, ToNoun g
         , ToNoun h, ToNoun i, ToNoun j
         )
      => ToNoun (a, b, c, d, e, f, g, h, i, j) where
  toNoun (p, q, r, s, t, u, v, w, x, y) =
    toNoun (p, (q, r, s, t, u, v, w, x, y))

instance ( FromNoun a, FromNoun b, FromNoun c, FromNoun d, FromNoun e
         , FromNoun f, FromNoun g, FromNoun h, FromNoun i, FromNoun j
         )
      => FromNoun (a, b, c, d, e, f, g, h, i, j)
      where
  parseNoun n = named "(,,,,,,,,,)" $ do
    (p, tail)                   <- parseNoun n
    (q, r, s, t, u, v, w, x, y) <- parseNoun tail
    pure (p, q, r, s, t, u, v, w, x, y)


-- Derived Instances -----------------------------------------------------------

deriveNoun ''Path
