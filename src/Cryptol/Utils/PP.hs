-- |
-- Module      :  Cryptol.Utils.PP
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.Utils.PP where

import           Cryptol.Utils.Fixity
import           Cryptol.Utils.Ident
import           Control.DeepSeq
import           Control.Monad (mplus)
import           Data.Maybe (fromMaybe)
import qualified Data.Semigroup as S
import           Data.String (IsString(..))
import qualified Data.Text as T
import           GHC.Generics (Generic)
import qualified Text.PrettyPrint as PJ

import Prelude ()
import Prelude.Compat


-- | How to pretty print things when evaluating
data PPOpts = PPOpts
  { useAscii      :: Bool
  , useBase       :: Int
  , useInfLength  :: Int
  , useFPBase     :: Int
  , useFPFormat   :: PPFloatFormat
  , useFieldOrder :: FieldOrder
  }
 deriving Show

asciiMode :: PPOpts -> Integer -> Bool
asciiMode opts width = useAscii opts && (width == 7 || width == 8)

data PPFloatFormat =
    FloatFixed Int PPFloatExp -- ^ Use this many significant digis
  | FloatFrac Int             -- ^ Show this many digits after floating point
  | FloatFree PPFloatExp      -- ^ Use the correct number of digits
 deriving Show

data PPFloatExp = ForceExponent -- ^ Always show an exponent
                | AutoExponent  -- ^ Only show exponent when needed
 deriving Show

data FieldOrder = DisplayOrder | CanonicalOrder deriving (Bounded, Enum, Eq, Ord, Read, Show)


defaultPPOpts :: PPOpts
defaultPPOpts = PPOpts { useAscii = False, useBase = 10, useInfLength = 5
                       , useFPBase = 16
                       , useFPFormat = FloatFree AutoExponent
                       , useFieldOrder = DisplayOrder
                       }


-- Name Displaying -------------------------------------------------------------

{- | How to display names, inspired by the GHC `Outputable` module.
Getting a value of 'Nothing' from the NameDisp function indicates
that the display has no opinion on how this name should be displayed,
and some other display should be tried out. -}
data NameDisp = EmptyNameDisp
              | NameDisp (OrigName -> Maybe NameFormat)
                deriving (Generic, NFData)

instance Show NameDisp where
  show _ = "<NameDisp>"

instance S.Semigroup NameDisp where
  NameDisp f    <> NameDisp g    = NameDisp (\n -> f n `mplus` g n)
  EmptyNameDisp <> EmptyNameDisp = EmptyNameDisp
  EmptyNameDisp <> x             = x
  x             <> _             = x

instance Monoid NameDisp where
  mempty = EmptyNameDisp
  mappend = (S.<>)

data NameFormat = UnQualified
                | Qualified !ModName
                | NotInScope
                  deriving (Show)

-- | Never qualify names from this module.
neverQualifyMod :: ModPath -> NameDisp
neverQualifyMod mn = NameDisp $ \n ->
  if ogModule n == mn then Just UnQualified else Nothing

neverQualify :: NameDisp
neverQualify  = NameDisp $ \ _ -> Just UnQualified


-- | Compose two naming environments, preferring names from the left
-- environment.
extend :: NameDisp -> NameDisp -> NameDisp
extend  = mappend

-- | Get the format for a name. When 'Nothing' is returned, the name is not
-- currently in scope.
getNameFormat :: OrigName -> NameDisp -> NameFormat
getNameFormat m (NameDisp f)  = fromMaybe NotInScope (f m)
getNameFormat _ EmptyNameDisp = NotInScope

-- | Produce a document in the context of the current 'NameDisp'.
withNameDisp :: (NameDisp -> Doc) -> Doc
withNameDisp k = Doc (\disp -> runDoc disp (k disp))

-- | Fix the way that names are displayed inside of a doc.
fixNameDisp :: NameDisp -> Doc -> Doc
fixNameDisp disp (Doc f) = Doc (\ _ -> f disp)


-- Documents -------------------------------------------------------------------

newtype Doc = Doc (NameDisp -> PJ.Doc) deriving (Generic, NFData)

instance S.Semigroup Doc where
  (<>) = liftPJ2 (PJ.<>)

instance Monoid Doc where
  mempty = liftPJ PJ.empty
  mappend = (S.<>)

runDoc :: NameDisp -> Doc -> PJ.Doc
runDoc names (Doc f) = f names

instance Show Doc where
  show d = show (runDoc mempty d)

instance IsString Doc where
  fromString = text

render :: Doc -> String
render d = PJ.render (runDoc mempty d)

renderOneLine :: Doc -> String
renderOneLine d = PJ.renderStyle (PJ.style { PJ.mode = PJ.OneLineMode }) (runDoc mempty d)

class PP a where
  ppPrec :: Int -> a -> Doc

class PP a => PPName a where
  -- | Fixity information for infix operators
  ppNameFixity :: a -> Maybe Fixity

  -- | Print a name in prefix: @f a b@ or @(+) a b)@
  ppPrefixName :: a -> Doc

  -- | Print a name as an infix operator: @a + b@
  ppInfixName  :: a -> Doc

instance PPName ModName where
  ppNameFixity _ = Nothing
  ppPrefixName   = pp
  ppInfixName    = pp

pp :: PP a => a -> Doc
pp = ppPrec 0

pretty :: PP a => a -> String
pretty  = show . pp

optParens :: Bool -> Doc -> Doc
optParens b body | b         = parens body
                 | otherwise = body


-- | Information about an infix expression of some sort.
data Infix op thing = Infix
  { ieOp     :: op       -- ^ operator
  , ieLeft   :: thing    -- ^ left argument
  , ieRight  :: thing    -- ^ right argument
  , ieFixity :: Fixity   -- ^ operator fixity
  }

commaSep :: [Doc] -> Doc
commaSep = fsep . punctuate comma


-- | Pretty print an infix expression of some sort.
ppInfix :: (PP thing, PP op)
        => Int            -- ^ Non-infix leaves are printed with this precedence
        -> (thing -> Maybe (Infix op thing))
                          -- ^ pattern to check if sub-thing is also infix
        -> Infix op thing -- ^ Pretty print this infix expression
        -> Doc
ppInfix lp isInfix expr =
  sep [ ppSub wrapL (ieLeft expr) <+> pp (ieOp expr)
      , ppSub wrapR (ieRight expr) ]
  where
    wrapL f = compareFixity f (ieFixity expr) /= FCLeft
    wrapR f = compareFixity (ieFixity expr) f /= FCRight

    ppSub w e
      | Just e1 <- isInfix e = optParens (w (ieFixity e1)) (ppInfix lp isInfix e1)
    ppSub _ e                = ppPrec lp e



-- | Display a numeric value as an ordinal (e.g., 2nd)
ordinal :: (Integral a, Show a, Eq a) => a -> Doc
ordinal x = text (show x) <.> text (ordSuffix x)

-- | The suffix to use when displaying a number as an oridinal
ordSuffix :: (Integral a, Eq a) => a -> String
ordSuffix n0 =
  case n `mod` 10 of
    1 | notTeen -> "st"
    2 | notTeen -> "nd"
    3 | notTeen -> "rd"
    _ -> "th"

  where
  n       = abs n0
  m       = n `mod` 100
  notTeen = m < 11 || m > 19


-- Wrapped Combinators ---------------------------------------------------------

liftPJ :: PJ.Doc -> Doc
liftPJ d = Doc (const d)

liftPJ1 :: (PJ.Doc -> PJ.Doc) -> Doc -> Doc
liftPJ1 f (Doc d) = Doc (\env -> f (d env))

liftPJ2 :: (PJ.Doc -> PJ.Doc -> PJ.Doc) -> (Doc -> Doc -> Doc)
liftPJ2 f (Doc a) (Doc b) = Doc (\e -> f (a e) (b e))

liftSep :: ([PJ.Doc] -> PJ.Doc) -> ([Doc] -> Doc)
liftSep f ds = Doc (\e -> f [ d e | Doc d <- ds ])

infixl 6 <.>, <+>

(<.>) :: Doc -> Doc -> Doc
(<.>)  = liftPJ2 (PJ.<>)

(<+>) :: Doc -> Doc -> Doc
(<+>)  = liftPJ2 (PJ.<+>)

infixl 5 $$

($$) :: Doc -> Doc -> Doc
($$)  = liftPJ2 (PJ.$$)

sep :: [Doc] -> Doc
sep  = liftSep PJ.sep

fsep :: [Doc] -> Doc
fsep  = liftSep PJ.fsep

hsep :: [Doc] -> Doc
hsep  = liftSep PJ.hsep

hcat :: [Doc] -> Doc
hcat  = liftSep PJ.hcat

vcat :: [Doc] -> Doc
vcat  = liftSep PJ.vcat

hang :: Doc -> Int -> Doc -> Doc
hang (Doc p) i (Doc q) = Doc (\e -> PJ.hang (p e) i (q e))

nest :: Int -> Doc -> Doc
nest n = liftPJ1 (PJ.nest n)

parens :: Doc -> Doc
parens  = liftPJ1 PJ.parens

braces :: Doc -> Doc
braces  = liftPJ1 PJ.braces

brackets :: Doc -> Doc
brackets  = liftPJ1 PJ.brackets

quotes :: Doc -> Doc
quotes  = liftPJ1 PJ.quotes

backticks :: Doc -> Doc
backticks d = hcat [ "`", d, "`" ]

punctuate :: Doc -> [Doc] -> [Doc]
punctuate p = go
  where
  go (d:ds) | null ds   = [d]
            | otherwise = d <.> p : go ds
  go []                 = []

text :: String -> Doc
text s = liftPJ (PJ.text s)

char :: Char -> Doc
char c = liftPJ (PJ.char c)

integer :: Integer -> Doc
integer i = liftPJ (PJ.integer i)

int :: Int -> Doc
int i = liftPJ (PJ.int i)

comma :: Doc
comma  = liftPJ PJ.comma

empty :: Doc
empty  = liftPJ PJ.empty

colon :: Doc
colon  = liftPJ PJ.colon

instance PP T.Text where
  ppPrec _ str = text (T.unpack str)

instance PP Ident where
  ppPrec _ i = text (T.unpack (identText i))

instance PP ModName where
  ppPrec _   = text . T.unpack . modNameToText


instance PP Assoc where
  ppPrec _ LeftAssoc  = text "left-associative"
  ppPrec _ RightAssoc = text "right-associative"
  ppPrec _ NonAssoc   = text "non-associative"

instance PP Fixity where
  ppPrec _ (Fixity assoc level) =
    text "precedence" <+> int level <.> comma <+> pp assoc

instance PP ModPath where
  ppPrec _ p =
    case p of
      TopModule m -> pp m
      Nested q t  -> pp q <.> "::" <.> pp t

instance PP OrigName where
  ppPrec _ og =
    withNameDisp $ \disp ->
      case getNameFormat og disp of
        UnQualified -> pp (ogName og)
        Qualified m -> ppQual (TopModule m) (pp (ogName og))
        NotInScope  -> ppQual (ogModule og) (pp (ogName og))
    where
   ppQual mo x =
    case mo of
      TopModule m
        | m == exprModName -> x
        | otherwise -> pp m <.> "::" <.> x 
      Nested m y -> ppQual m (pp y <.> "::" <.> x)

instance PP Namespace where
  ppPrec _ ns =
    case ns of
      NSValue   -> "/*value*/"
      NSType    -> "/*type*/"
      NSModule  -> "/*module*/"
