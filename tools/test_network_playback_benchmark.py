"""Protocol checks for the isolated loopback playback experiment."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import http.client
from pathlib import Path
import tempfile
import unittest

from network_playback_benchmark import Loopback, fixture_origin, running


class LoopbackTest(unittest.TestCase):
    def setUp(self):
        data = bytes(range(256)) * 48
        self.data = data
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        source = directory / 'media.bin'
        source.write_bytes(data)
        self.origin = self.enterContext(running(fixture_origin({'/media.bin': source})))
        self.proxy = self.enterContext(running(Loopback(
            f'http://127.0.0.1:{self.origin.server_port}/media.bin', len(data), 4096)))

    def read(self, header=None, method='GET', path=None, **extras):
        headers = {'Range': header} if header else {}
        with closing(http.client.HTTPConnection('127.0.0.1', self.proxy.server_port,
                                                timeout=3)) as connection:
            connection.request(method, path or self.proxy.path, headers={**headers, **extras})
            response = connection.getresponse()
            return response.status, dict(response.headers), response.read()

    def test_metadata_and_bounds(self):
        status, headers, data = self.read(method='HEAD')
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Length'], str(len(self.data)))
        self.assertEqual(data, b'')
        self.assertEqual(self.origin.records, [])
        status, headers, data = self.read('bytes=-17')
        self.assertEqual(status, 206)
        self.assertEqual(data, self.data[-17:])
        self.assertEqual(headers['Content-Range'], 'bytes 12271-12287/12288')
        status, headers, _ = self.read('bytes=12288-')
        self.assertEqual(status, 416)
        self.assertEqual(headers['Content-Range'], 'bytes */12288')

    def test_if_range_mismatch_returns_full_representation(self):
        status, _, data = self.read('bytes=10-20', **{'If-Range': '"old"'})
        self.assertEqual(status, 200)
        self.assertEqual(data, self.data)

    def test_token_required(self):
        self.assertEqual(self.read(path='/media.bin')[0], 404)
        self.assertEqual(self.origin.records, [])

    def test_hits_do_not_repeat_remote_range(self):
        self.assertEqual(self.read('bytes=7-29')[2], self.data[7:30])
        self.assertEqual(self.read('bytes=21-45')[2], self.data[21:46])
        self.assertEqual(len(self.origin.records), 1)
        self.assertEqual(self.proxy.cache_hits, 1)

    def test_simultaneous_ranges_share_one_origin_block(self):
        self.origin.latency_ms = 50
        ranges = ('bytes=0-63', 'bytes=16-127')
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.read, ranges))
        self.assertEqual([r[2] for r in results],
                         [self.data[:64], self.data[16:128]])
        self.assertEqual(len(self.origin.records), 1)

    def test_rejects_bad_source_response(self):
        for fault in ('no-range', 'invalid-range', 'unavailable'):
            with self.subTest(fault=fault), self.assertRaises(http.client.IncompleteRead):
                self.origin.fault = fault
                self.read('bytes=10-20')
        self.assertEqual(len(self.proxy.cache), 0)

    def test_rejects_changed_version_for_new_block(self):
        self.read('bytes=0-20')
        self.origin.etag = '"changed"'
        with self.assertRaises(http.client.IncompleteRead):
            self.read('bytes=4000-5000')
        self.assertEqual(list(self.proxy.cache), [0])

    def test_rejects_missing_validator_and_changed_length(self):
        self.origin.etag = None
        with self.assertRaises(http.client.IncompleteRead):
            self.read('bytes=10-20')
        self.origin.etag = '"fixture"'
        self.origin.files['/media.bin'].write_bytes(self.data + b'x')
        with self.assertRaises(http.client.IncompleteRead):
            self.read('bytes=10-20')
        self.assertEqual(len(self.proxy.cache), 0)

    def test_retries_one_transient_disconnect_for_block(self):
        self.origin.fault = 'drop-once'
        self.assertEqual(self.read('bytes=10-20')[2], self.data[10:21])


if __name__ == '__main__':
    unittest.main()
