import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('words', ROOT / 'lib/word-count.py')
words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(words)
spec = importlib.util.spec_from_file_location('isolation', ROOT / 'lib/verify-runtime-isolation.py')
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)


class WordTests(unittest.TestCase):
    def test_cached_personal_count_cannot_skip_real_dictation(self):
        (ROOT / 'profiles').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='test-words-', dir=ROOT / 'profiles') as directory:
            profile = Path(directory)
            (profile / 'config.json').write_text(json.dumps({'prefs': {'cache': {'statistics': {'totalWords': 999999}}}}))
            self.assertEqual(words.get_total_words(directory), 0)
            with sqlite3.connect(profile / 'flow.sqlite') as db:
                db.execute('CREATE TABLE History (numWords INTEGER, needsUploading INTEGER)')
                db.executemany('INSERT INTO History VALUES (?, ?)', [(45, 1), (55, 0), (None, 1)])
            self.assertEqual(words.get_total_words(directory), 100)
            self.assertEqual(words.get_total_words(directory, pending=True), 45)

    def test_profiles_distinguish_full_addresses_and_normalize_case(self):
        self.assertNotEqual(isolation.profile_key('alice@domain-a.com'), isolation.profile_key('alice@domain-b.com'))
        self.assertEqual(isolation.profile_key('Alice@Domain-A.com'), isolation.profile_key('alice@domain-a.com'))
        with self.assertRaises(ValueError):
            isolation.profile_key('not an email')

    def test_personal_profile_is_rejected_before_database_access(self):
        with self.assertRaises(ValueError):
            words.get_total_words(str(Path.home() / 'Library/Application Support/Wispr Flow'))


if __name__ == '__main__':
    unittest.main()
