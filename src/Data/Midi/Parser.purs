module Data.Midi.Parser
        ( normalise
        , parse
        , parseMidiEvent
        ) where

import Prelude (Unit, unit, ($), (<$>), (<$), (<*>), (*>), (+), (-), (>),
                (==), (>=), (<=), (&&), (>>=), (>>>), (<<<), map, pure, show, void)
import Control.Alt ((<|>))
import Data.List (List(..), (:))
import Data.Foldable (fold)
import Data.Unfoldable (replicateA)
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import Data.Maybe (Maybe(..))
import Data.Char (fromCharCode, toCharCode)
import Data.String (singleton, fromCharArray, toCharArray)
import Data.Int (pow)
import Data.Int.Bits (and, shl)
import Text.Parsing.StringParser (Parser, runParser, try, fail)
import Text.Parsing.StringParser.String (anyChar, satisfy, string, char, noneOf)
import Text.Parsing.StringParser.Combinators (choice, many, (<?>))

import Data.Midi

{- debugging utilities

import Debug.Trace (trace)

traceParse :: forall a. String -> a -> a
traceParse s p =
  trace s (\_ -> p)

traceEvent :: Event -> Event
traceEvent p =
  trace (show p) (\_ -> p)

-}

-- low level parsers

-- | Apply a parser and skip its result.
skip :: forall a. Parser a -> Parser Unit
skip = void

-- | Parse `n` occurences of `p`. -
count :: forall a. Int -> Parser a -> Parser (List a)
count = replicateA

{- parse a binary 8 bit integer -}
int8 :: Parser Int
int8 =
  toCharCode <$> anyChar

{- parse a signed binary 8 bit integer -}
signedInt8 :: Parser Int
signedInt8 =
  (\i ->
    if (topBitSet i) then
      i - 256
    else
      i
  )
    <$> int8

{- parse a specific binary 8 bit integer -}
bchar :: Int -> Parser Int
bchar val =
  toCharCode <$> char (fromCharCode (val))

{- parse an 8 bit integer lying within a range -}
brange :: Int -> Int -> Parser Int
brange l r =
  let
    f a =
      toCharCode a >= l && toCharCode a <= r
  in
    toCharCode <$> satisfy f

{- parse a choice between a pair of 8 bit integers -}
bchoice :: Int -> Int -> Parser Int
bchoice x y =
  bchar x <|> bchar y

notTrackEnd :: Parser Int
notTrackEnd =
  let
    c =
      fromCharCode 0x2F
  in
    toCharCode <$> noneOf [ c ]

-- fixed length integers
int16 :: Parser Int
int16 =
  let
    toInt16 a b =
      a `shl` 8 + b
  in
    toInt16 <$> int8 <*> int8


int24 :: Parser Int
int24 =
  let
    toInt24 a b c =
      a `shl` 16 + b `shl` 8 + c
  in
    toInt24 <$> int8 <*> int8 <*> int8

int32 :: Parser Int
int32 =
  let
    toInt32 a b c d =
      a `shl` 24 + b `shl` 16 + c `shl` 8 + d
  in
    toInt32 <$> int8 <*> int8 <*> int8 <*> int8

-- variable length integers
-- (need to somehow check this for lengths above 16 bits)
varInt :: Parser Int
varInt =
  int8
    >>= (\n ->
          if (topBitSet n) then
            ((+) ((clearTopBit >>> shiftLeftSeven) n)) <$> varInt
          else
            pure n
        )

{- just for debug purposes - consume the rest of the input -}
rest :: Parser (List Char)
rest =
  many anyChar

-- top level parsers

midi :: Parser Recording
midi =
  midiHeader >>= midiTracks

{- this version of the top level parser just parses many tracks
      without checking whether the track count agrees with the header
   midi0 : Parser s MidiRecording
   midi0 = (,) <$> midiHeader <*> midiTracks0

   midiTracks0 : Parser s (List Track)
   midiTracks0 = many1 midiTrack <?> "midi tracks"
-}
{- simple parser for headers which assumes chunk size is 6
   midiHeader : Parser Header
   midiHeader = string "MThd"
                  *> int32
                  *> ( Header <$>  int16 <*> int16 <*> int16 )
                  <?> "header"
-}
{- parser for headers which quietly eats any extra bytes if we have a non-standard chunk size -}


midiHeader :: Parser Header
midiHeader =
  string "MThd"
    *> let
         h =
            headerChunk <$> int32 <*> int16 <*> int16 <*> int16
       in
         consumeOverspill h 6
            <?> "header"


midiTracks :: Header -> Parser Recording
midiTracks (Header h) =
  buildRecording (Header h) <$> count h.trackCount midiTrack <?> "midi tracks"

{- we don't place TrackEnd events into the parse tree - there is no need.
   The end of the track is implied by the end of the event list
-}
midiTrack :: Parser Track
midiTrack =
  Track <$>
     -- (string "MTrk" *> int32 *> many1Till midiMessage trackEndMessage <?> "midi track")
     (string "MTrk" *> int32 *> midiMessages Nothing <?> "midi track")

midiMessages :: Maybe Event -> Parser (List Message)
midiMessages parent =
    midiMessage parent
        >>= moreMessageOrEnd

moreMessageOrEnd :: Message -> Parser (List Message)
moreMessageOrEnd lastMessage =
  let
    (Message ticks lastEvent) = lastMessage
  in
    ((:) lastMessage)
      <$> choice
            [ endOfTrack   -- must come first otherwise we need to use try
            , midiMessages (Just lastEvent)
            ]

{- we don't place TrackEnd events into the parse tree - there is no need.
   The end of the track is implied by the end of the event list
-}


endOfTrack :: Parser (List Message)
endOfTrack =
    Nil <$ trackEndMessage

-- Note - it is important that runningStatus is placed last because of its catch-all definition
midiMessage :: Maybe Event -> Parser Message
midiMessage parent =
  Message
    <$> varInt
    <*> midiEvent parent
    <?> "midi message"

-- | we need to pass the parent event to running status events in order to
-- | make sense of them.
midiEvent :: Maybe Event -> Parser Event
midiEvent parent =
  -- traceEvent <$>
    choice
      [ metaEvent
      , sysEx
      , noteOn
      , noteOff
      , noteAfterTouch
      , controlChange
      , programChange
      , channelAfterTouch
      , pitchBend
      , runningStatus parent
      ]
        <?> "midi event"

-- metadata parsers
metaEvent :: Parser Event
metaEvent =
   bchar 0xFF
    *> choice
      [ sequenceNumber
      , text
      , copyright
      , trackName
      , instrumentName
      , lyrics
      , marker
      , cuePoint
      , channelPrefix
      , tempoChange
      , smpteOffset
      , timeSignature
      , keySignature
      , sequencerSpecific
      , unspecified
      ]
        <?> "meta event"

sequenceNumber :: Parser Event
sequenceNumber =
  SequenceNumber <$> (bchar 0x00 *> bchar 0x02 *> int16 <?> "sequence number")

{- parse a simple string-valued meta event -}
parseMetaString :: Int -> Parser String
parseMetaString target =
  catChars
    <$>
      (bchar target *> varInt >>= (\l -> count l anyChar))

text :: Parser Event
text =
  Text <$> parseMetaString 0x01 <?> "text"

copyright :: Parser Event
copyright =
  Copyright <$> parseMetaString 0x02 <?> "copyright"

trackName :: Parser Event
trackName =
  TrackName <$> parseMetaString 0x03 <?> "track name"

instrumentName :: Parser Event
instrumentName =
  InstrumentName <$> parseMetaString 0x04 <?> "instrument name"

lyrics :: Parser Event
lyrics =
  Lyrics <$> parseMetaString 0x05 <?> "lyrics"

marker :: Parser Event
marker =
  Marker <$> parseMetaString 0x06 <?> "marker"

cuePoint :: Parser Event
cuePoint =
  CuePoint <$> parseMetaString 0x07 <?> "cue point"

channelPrefix :: Parser Event
channelPrefix =
  ChannelPrefix <$> (bchar 0x20 *> bchar 0x01 *> int8 <?> "channel prefix")

tempoChange :: Parser Event
tempoChange =
  Tempo <$> (bchar 0x51 *> bchar 0x03 *> int24) <?> "tempo change"

smpteOffset :: Parser Event
smpteOffset =
  bchar 0x54 *> bchar 0x03 *> (SMPTEOffset <$> int8 <*> int8 <*> int8 <*> int8 <*> int8 <?> "SMTPE offset")

timeSignature :: Parser Event
timeSignature =
  bchar 0x58 *> bchar 0x04 *> (buildTimeSig <$> int8 <*> int8 <*> int8 <*> int8) <?> "time signature"

keySignature :: Parser Event
keySignature =
  bchar 0x59 *> bchar 0x02 *> (KeySignature <$> signedInt8 <*> int8)

sequencerSpecific :: Parser Event
sequencerSpecific =
  SequencerSpecific <$> parseMetaString 0x7F <?> "sequencer specific"

sysEx :: Parser Event
sysEx =
  -- SysEx <$> (String.fromList <$> (bchoice 0xF0 0xF7 *> varInt `andThen` (\l -> count l anyChar))) <?> "system exclusive"
  SysEx <$> (catChars <$> (bchoice 0xF0 0xF7 *> varInt >>= (\l -> count l anyChar))) <?> "system exclusive"

{- parse an unspecified meta event
   The possible range for the type is 00-7F. Not all values in this range are defined, but programs must be able
   to cope with (ie ignore) unexpected values by examining the length and skipping over the data portion.
   We cope by accepting any value here except TrackEnd which is the terminating condition for the list of MidiEvents
   and so must not be recognized here
-}
unspecified :: Parser Event
unspecified =
  Unspecified <$> notTrackEnd <*> (int8 >>= (\l -> count l int8))

trackEndMessage :: Parser Unit
trackEndMessage =
    try
      (varInt *> bchar 0xFF *> bchar 0x2F *> bchar 0x00 *> pure unit <?> "track end")

-- channel parsers

noteOn :: Parser Event
noteOn =
  buildNote <$> brange 0x90 0x9F <*> int8 <*> int8 <?> "note on"

noteOff :: Parser Event
noteOff =
  buildNoteOff <$> brange 0x80 0x8F <*> int8 <*> int8 <?> "note off"

noteAfterTouch :: Parser Event
noteAfterTouch =
  buildNoteAfterTouch <$> brange 0xA0 0xAF <*> int8 <*> int8 <?> "note after touch"

controlChange :: Parser Event
controlChange =
  buildControlChange <$> brange 0xB0 0xBF <*> int8 <*> int8 <?> "control change"

programChange :: Parser Event
programChange =
  buildProgramChange <$> brange 0xC0 0xCF <*> int8 <?> "program change"

channelAfterTouch :: Parser Event
channelAfterTouch =
  buildChannelAfterTouch <$> brange 0xD0 0xDF <*> int8 <?> "channel after touch"

pitchBend :: Parser Event
pitchBend =
  buildPitchBend <$> brange 0xE0 0xEF <*> int8 <*> int8 <?> "pitch bend"

-- | running status is somewhat anomalous.  It inherits the 'type' of the last event parsed,
-- | (here called the parent) which must be a channel event.
-- | We now macro-expand the running status message to be the type (and use the channel status)
-- | of the parent.  If the parent is missing or is not a channel event, we fail the parse
runningStatus :: Maybe Event -> Parser Event
runningStatus parent =
    -- RunningStatus <$> brange 0x00 0x7F <*> int8 <?> "running status"
    case parent of
        Just (NoteOn status _ _) ->
            (NoteOn status) <$> int8 <*> int8 <?> "note on running status"

        Just (NoteOff status _ _) ->
            (NoteOff status) <$> int8 <*> int8 <?> "note off running status"

        Just (NoteAfterTouch status _ _) ->
            (NoteAfterTouch status) <$> int8 <*> int8 <?> "note aftertouch running status"

        Just (ControlChange status _ _) ->
            (ControlChange status) <$> int8 <*> int8 <?> "control change running status"

        Just (ProgramChange status _) ->
            (ProgramChange status) <$> int8 <?> "program change running status"

        Just (ChannelAfterTouch status _) ->
            (ChannelAfterTouch status) <$> int8 <?> "channel aftertouch running status"

        Just (PitchBend status _) ->
            (PitchBend status) <$> int8 <?> "pitch bend running status"

        Just _ ->
            fail "inappropriate parent for running status"

        _ ->
            fail "no parent for running status"

{-
runningStatus :: Parser Event
runningStatus =
  RunningStatus <$> brange 0x00 0x7F <*> int8 <?> "running status"
-}

-- runningStatus = log "running status" <$> ( RunningStatus <$> brange 0x00 0x7F  <*> int8 <?> "running status")
-- result builder
{- build a Header and make the chunk length available so that any overspill bytes can
   later be quietly ignored
-}
headerChunk :: Int -> Int -> Int -> Int -> Tuple Int Header
headerChunk l a b c =
  let
    header =
        { formatType : a
        , trackCount : b
        , ticksPerBeat : c
        }
  in
    Tuple l (Header header)

buildRecording :: Header -> List Track -> Recording
buildRecording h ts =
  Recording { header: h, tracks : ts }

{- build NoteOn (unless the velocity is zero in which case NoteOff) -}
buildNote :: Int -> Int -> Int -> Event
buildNote cmd note velocity =
  let
    channel =
      and cmd 0x0F

    isOff =
      (velocity == 0)
  in
    case isOff of
      true ->
        NoteOff channel note velocity

      _ ->
        NoteOn channel note velocity

{- abstract builders that construct MidiEvents that all have the same shape -}
channelBuilder3 :: (Int -> Int -> Int -> Event) -> Int -> Int -> Int -> Event
channelBuilder3 construct cmd x y =
  let
    channel =
      and cmd 0x0F
  in
    construct channel x y

channelBuilder2 :: (Int -> Int -> Event) -> Int -> Int -> Event
channelBuilder2 construct cmd x =
  let
    channel =
      and cmd 0x0F
  in
    construct channel x

{- build NoteOff -}
buildNoteOff :: Int -> Int -> Int -> Event
buildNoteOff cmd note velocity =
  channelBuilder3 NoteOff cmd note velocity

{- build Note AfterTouch AKA Polyphonic Key Pressure -}
buildNoteAfterTouch :: Int -> Int -> Int -> Event
buildNoteAfterTouch cmd note pressure =
  channelBuilder3 NoteAfterTouch cmd note pressure

{- build Control Change -}
buildControlChange :: Int -> Int -> Int -> Event
buildControlChange cmd num value =
  channelBuilder3 ControlChange cmd num value

{- build Program Change -}
buildProgramChange :: Int -> Int -> Event
buildProgramChange cmd num =
  channelBuilder2 ProgramChange cmd num

{- build Channel AfterTouch AKA Channel Key Pressure -}
buildChannelAfterTouch :: Int -> Int -> Event
buildChannelAfterTouch cmd num =
  channelBuilder2 ChannelAfterTouch cmd num

{- build Pitch Bend -}
buildPitchBend :: Int -> Int -> Int -> Event
buildPitchBend cmd lsb msb =
  channelBuilder2 PitchBend cmd $ lsb + shiftLeftSeven msb

{- build a Time Signature -}
buildTimeSig :: Int -> Int -> Int -> Int -> Event
buildTimeSig nn dd cc bb =
  let
    denom =
      2 `pow` dd
  in
    TimeSignature nn denom cc bb

-- utility functions
{- consume the overspill from a non-standard size chunk
   actual is the parsed actual chunk size followed by the chunk contents (which are returned)
   expected is the expected size of the chunk
   consume the rest if the difference suggests an overspill of unwanted chunk material
-}
consumeOverspill :: forall a. Parser (Tuple Int a ) -> Int -> Parser a
consumeOverspill actual expected =
  actual
    >>= (\(Tuple cnt oversp ) ->
          map (\_ -> oversp) $
                skip $
                    count (cnt - expected) int8
        )

topBitSet :: Int -> Boolean
topBitSet n =
  and n 0x80 > 0

clearTopBit :: Int -> Int
clearTopBit n =
  and n 0x7F

shiftLeftSeven :: Int -> Int
shiftLeftSeven n =
    n `shl` 7

makeTuple :: forall a b. a -> b -> Tuple a b
makeTuple a b =
  Tuple a b

-- utils
catChars :: List Char -> String
catChars = fold <<< map singleton

-- exported functions

-- | Parse a MIDI event
parseMidiEvent :: String -> Either String Event
parseMidiEvent s =
  case runParser (midiEvent Nothing) s of
    Right n ->
      Right n

    Left e ->
      Left $ show e

-- | entry point - Parse a normalised MIDI file image
parse :: String -> Either String Recording
parse s =
  case runParser midi s of
    Right n ->
      Right n

    Left e ->
      Left $ show e

-- | normalise the input before we parse by masking off all but the least significant 8 bits
normalise :: String -> String
normalise =
  let
    f = toCharCode >>> ((and) 0xFF) >>> fromCharCode
  in
    toCharArray >>> map f >>> fromCharArray
