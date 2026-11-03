import unittest

from featurize import next_speaking_mode


class SpeakingModeTests(unittest.TestCase):
    def test_agent_audio_enters_speaking_and_restarts_quiet_hysteresis(self):
        self.assertEqual(next_speaking_mode(True, False, 0), (True, 0))
        self.assertEqual(next_speaking_mode(True, True, 4), (True, 0))

    def test_speaking_latches_for_six_quiet_hops_then_releases(self):
        speaking, quiet = True, 0
        for expected in range(1, 7):
            speaking, quiet = next_speaking_mode(False, speaking, quiet)
            self.assertEqual((speaking, quiet), (True, expected))
        self.assertEqual(next_speaking_mode(False, speaking, quiet), (False, 0))

    def test_silence_while_listening_does_not_start_speaking(self):
        self.assertEqual(next_speaking_mode(False, False, 0), (False, 0))


if __name__ == "__main__":
    unittest.main()
