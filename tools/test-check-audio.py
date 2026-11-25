"""Synthetic checks distinguish clean tone/silence from injected defects."""
import importlib.util
import math
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('checker', Path(__file__).with_name('check-audio.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
RATE = 48000

class AudioCheckTests(unittest.TestCase):
    def tone(self):
        return [round(5000 * math.sin(2*math.pi*440*i/RATE)) for i in range(RATE)]

    def test_clean_tone(self):
        self.assertEqual(checker.analyze(self.tone(), RATE)['suspected_events'], 0)

    def test_intentional_silence(self):
        report = checker.analyze([0]*RATE, RATE)
        self.assertEqual(report['suspected_events'], 0)
        self.assertEqual(report['flat_seconds'], 1)

    def test_missing_audio(self):
        samples = self.tone()
        samples[12000:20160] = [0]*8160
        events = checker.analyze(samples, RATE)['events']
        event = next(e for e in events if e['kind'] == 'digital_silence')
        self.assertTrue(event['suspected_interruption'])
        self.assertAlmostEqual(event['start_seconds'], .25, places=4)
        self.assertAlmostEqual(event['duration_seconds'], .17, places=4)

    def test_held_audio(self):
        samples = self.tone()
        samples[12000:16800] = [1234]*4800
        self.assertTrue(any(e['kind'] == 'held_sample' and e['suspected_interruption']
                            for e in checker.analyze(samples, RATE)['events']))

    def test_click(self):
        samples = self.tone()
        samples[24000] = 30000
        self.assertTrue(any(e['kind'] == 'abrupt_jump' for e in checker.analyze(samples, RATE)['events']))

if __name__ == '__main__':
    unittest.main()
