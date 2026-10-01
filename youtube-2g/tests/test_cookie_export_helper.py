"""Credential-boundary checks for the extension-free Mac helper."""
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).parents[1] / 'export-youtube-cookies.command'


class CookieExportTests(unittest.TestCase):
    def run_filter(self, rows):
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'cookies.txt'
            source.write_text('# Netscape HTTP Cookie File\n' + '\n'.join(rows) + '\n')
            # These are synthetic credentials. The actual helper redirects its
            # filter to a private file and never prints cookie values.
            return subprocess.run(
                ['bash', '-c', 'source "$1"; filter_youtube_cookies "$2"',
                 'cookie-filter-test', str(HELPER), str(source)],
                text=True, capture_output=True)

    def test_only_youtube_domains_are_preserved(self):
        rows = [
            '.youtube.com\tTRUE\t/\tTRUE\t2000000000\tSAPISID\tfake=a=b',
            '#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tfake-session',
            'www.youtube.com\tFALSE\t/\tTRUE\t0\tPREF\tfake-pref',
            '.google.com\tTRUE\t/\tTRUE\t2000000000\tSID\tother-account',
            '.youtube.com.evil.example\tTRUE\t/\tTRUE\t0\tSID\tevil',
            '.notyoutube.com\tTRUE\t/\tTRUE\t0\tSID\tunrelated',
        ]
        result = self.run_filter(rows)
        self.assertEqual(result.returncode, 0)
        self.assertIn('fake=a=b', result.stdout)
        self.assertIn('#HttpOnly_.youtube.com', result.stdout)
        self.assertIn('www.youtube.com', result.stdout)
        self.assertNotIn('other-account', result.stdout)
        self.assertNotIn('evil', result.stdout)
        self.assertNotIn('unrelated', result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 4)

    def test_guest_only_session_is_rejected(self):
        result = self.run_filter([
            '.youtube.com\tTRUE\t/\tTRUE\t0\tVISITOR_INFO1_LIVE\tguest',
        ])
        self.assertEqual(result.returncode, 3)

    def test_empty_auth_cookie_is_rejected(self):
        result = self.run_filter([
            '.youtube.com\tTRUE\t/\tTRUE\t2000000000\tSAPISID\t',
        ])
        self.assertEqual(result.returncode, 3)

    @unittest.skipUnless(os.environ.get('TEST_YTDLP_PATH'), 'optional upstream CLI integration')
    def test_upstream_cli_exports_without_a_video_url(self):
        with tempfile.TemporaryDirectory() as work:
            profile = Path(work) / 'chrome'
            profile.mkdir()
            with sqlite3.connect(profile / 'Cookies') as db:
                db.execute('CREATE TABLE meta (key TEXT, value TEXT)')
                db.execute("INSERT INTO meta VALUES ('version', '24')")
                db.execute('CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, '
                           'encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER)')
                db.executemany('INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)', [
                    ('.youtube.com', 'SAPISID', 'synthetic-youtube', b'', '/', 0, 1),
                    ('.google.com', 'SID', 'synthetic-google', b'', '/', 0, 1),
                ])
            export = Path(work) / 'all.txt'
            run = subprocess.run([
                'python3', os.environ['TEST_YTDLP_PATH'], '--ignore-config',
                '--no-warnings', '--no-progress', '--proxy', 'http://127.0.0.1:1',
                '--cookies-from-browser', 'chrome:' + str(profile),
                '--cookies', str(export), '--list-impersonate-targets',
            ], text=True, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue(export.exists())
            result = self.run_filter(export.read_text().splitlines())
            self.assertEqual(result.returncode, 0)
            self.assertIn('synthetic-youtube', result.stdout)
            self.assertNotIn('synthetic-google', result.stdout)


if __name__ == '__main__':
    unittest.main()
