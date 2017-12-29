module Test.Instrument (instrumentSuite) where

import Prelude (Unit, discard)
import Control.Monad.Free (Free)
import Test.Unit.Assert (equal) as Assert
import Test.Unit (TestF, test, suite)
import Data.Maybe (Maybe(..))
import Data.Midi.Instrument

instrumentSuite :: forall t. Free (TestF t) Unit
instrumentSuite = do
  suite "instrument" do
    test "Marimba" do
      Assert.equal "marimba" (gleitzmanName Marimba)
    test "AcousticGrandPiano" do
      Assert.equal "acoustic_grand_piano" (gleitzmanName AcousticGrandPiano)
    test "Lead2Sawtooth" do
      Assert.equal "lead_2_sawtooth" (gleitzmanName Lead2Sawtooth)
    test "SynthBass1" do
      Assert.equal "synth_bass_1" (gleitzmanName SynthBass1)
    test "acoustic_grand_piano" do
      Assert.equal (Just AcousticGrandPiano) (read "acoustic_grand_piano")
    test "unknown" do
      Assert.equal Nothing (read "unknown")
