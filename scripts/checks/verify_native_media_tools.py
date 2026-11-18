#!/usr/bin/env python3
"""Exercise buffer recording, episode slices, CUE slices and commentary in libmpv.

Uses generated local media. Pass the library from the packaged build, with its
shared-library directory on the loader path if needed. No server account needed.
"""
import argparse
import array
import ctypes as c
import http.server
import json
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time


class Mpv:
    def __init__(self, library):
        self.lib = c.CDLL(str(Path(library).resolve()))
        p, s = c.c_void_p, c.c_char_p
        for name, result, args in [
            ('create', p, []), ('initialize', c.c_int, [p]),
            ('set_option_string', c.c_int, [p, s, s]), ('set_property_string', c.c_int, [p, s, s]),
            ('get_property_string', p, [p, s]), ('free', None, [p]),
            ('command', c.c_int, [p, c.POINTER(s)]),
            ('command_async', c.c_int, [p, c.c_uint64, c.POINTER(s)]),
            ('terminate_destroy', None, [p]),
        ]:
            f = getattr(self.lib, 'mpv_' + name)
            f.restype, f.argtypes = result, args

    @staticmethod
    def check(code):
        if code < 0:
            raise AssertionError(f'mpv rejected request: {code}')

    def create(self, **options):
        h = self.lib.mpv_create()
        assert h
        for name, value in {'vo': 'null', 'ao': 'null', 'idle': 'yes', 'ytdl': 'no',
                            'audio-display': 'no', 'terminal': 'yes', 'msg-level': 'all=warn', **options}.items():
            self.check(self.lib.mpv_set_option_string(h, name.encode(), str(value).encode()))
        self.check(self.lib.mpv_initialize(h))
        return h

    def get(self, h, key):
        pointer = self.lib.mpv_get_property_string(h, key.encode())
        if not pointer:
            return ''
        try:
            return c.string_at(pointer).decode()
        finally:
            self.lib.mpv_free(pointer)

    def set(self, h, key, value):
        self.check(self.lib.mpv_set_property_string(h, key.encode(), str(value).encode()))

    def command(self, h, *args, asynchronous=False):
        values = (c.c_char_p * (len(args) + 1))(*(str(v).encode() for v in args), None)
        self.check(self.lib.mpv_command_async(h, 42, values) if asynchronous else self.lib.mpv_command(h, values))

    def close(self, h):
        self.lib.mpv_terminate_destroy(h)


def wait(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError('native playback deadline expired')


def ffmpeg(*args):
    return subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', *map(str, args)])


def samples(path):
    return array.array('f', ffmpeg('-i', path, '-ar', '48000', '-ac', '1', '-f', 'f32le', '-'))


def verify_audio(mpv, root):
    movie, voice = root / 'movie.wav', root / 'commentary,été.wav'
    ffmpeg('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono', '-t', 6, movie)
    ffmpeg('-f', 'lavfi', '-i', r'aevalsrc=if(between(t\,3\,3.05)\,0.5\,0):s=48000', '-t', 6, voice)
    for delay in (-1000, 0, 1000):
        for seek in (0, 1):
            output = root / f'mix-{delay}-{seek}.wav'
            h = mpv.create(**{'ao': 'pcm', 'ao-pcm-file': output, 'pause': 'yes', 'keep-open': 'yes'})
            try:
                mpv.command(h, 'loadfile', movie)
                wait(lambda: mpv.get(h, 'track-list/count') == '1')
                uri = voice.as_uri()
                address = f'edl://%{len(uri.encode())}%{uri},{-delay/1000}' if delay < 0 else uri
                mpv.command(h, 'audio-add', address, 'auto')
                timing = f'adelay={delay}:all=1,' if delay > 0 else ''
                graph = ('[aid1]volume=0.8[movie];[aid2]' + timing + 'volume=0.5[voice];'
                         '[movie][voice]amix=inputs=2:duration=first:normalize=0,alimiter=level=0[ao]')
                mpv.set(h, 'file-local-options/lavfi-complex', graph)
                mpv.command(h, 'seek', seek, 'absolute+exact')
                mpv.set(h, 'pause', 'no')
                wait(lambda: mpv.get(h, 'eof-reached') == 'yes')
            finally:
                mpv.close(h)
            pcm = samples(output)
            first = next((n / 48000 for n, value in enumerate(pcm) if abs(value) > .15), None)
            expected = 3 + delay / 1000 - seek
            assert first is not None and abs(first - expected) < .05, (delay, seek, first, expected)
            assert abs(max(pcm) - .25) < .005, 'independent commentary gain did not reach output'
            print(f'commentary delay={delay}ms seek={seek}s pulse={first:.4f}s', flush=True)
    # Native bounded load terminates at the authored episode boundary.
    # EDL gives an individual CUE track its own zero-based seek/repeat clock.
    for kind in ('episode', 'cue'):
        out = root / f'{kind}.wav'
        h = mpv.create(**{'ao': 'pcm', 'ao-pcm-file': out, 'keep-open': 'yes'})
        try:
            if kind == 'cue':
                uri = voice.as_uri()
                mpv.command(h, 'loadfile', f'edl://%{len(uri.encode())}%{uri},1,2')
            else:
                mpv.command(h, 'loadfile', movie, 'replace', '-1', 'start=1,end=3')
            wait(lambda: mpv.get(h, 'eof-reached') == 'yes')
        finally:
            mpv.close(h)
        duration = len(samples(out)) / 48000
        assert abs(duration - 2) < .05, (kind, duration)
        print(f'{kind}: bounded native output {duration:.4f}s', flush=True)


def verify_recording(mpv, root):
    source, output = root / 'live.ts', root / 'saved.ts'
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=15', '-f', 'lavfi', '-i', 'sine=frequency=440',
           '-t', 12, '-c:v', 'mpeg2video', '-g', 5, '-c:a', 'mp2', '-muxrate', '600k', '-f', 'mpegts', source)
    requests, data = [], source.read_bytes()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp2t')
            self.end_headers()
            try:
                for start in range(0, len(data), 188 * 40):
                    self.wfile.write(data[start:start + 188 * 40])
                    self.wfile.flush()
                    time.sleep(.1)
            except (ConnectionResetError, BrokenPipeError):
                pass

    with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler) as server:
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        h = mpv.create(**{'cache': 'yes', 'cache-secs': 30, 'demuxer-max-back-bytes': '8MiB', 'force-seekable': 'yes'})
        try:
            mpv.command(h, 'loadfile', f'http://127.0.0.1:{server.server_address[1]}/channel.ts')
            wait(lambda: float(mpv.get(h, 'time-pos') or 0) > 3)
            before = float(mpv.get(h, 'time-pos'))
            mpv.command(h, 'dump-cache', '.3', 'no', output, asynchronous=True)
            wait(output.exists)
            wait(lambda: float(mpv.get(h, 'time-pos') or 0) > before + 1.5)
            mpv.command(h, 'dump-cache', 'no', 'no', '')
        finally:
            mpv.close(h)
            server.shutdown()
    metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
        'stream=codec_type:format=duration', '-of', 'json', output]))
    assert {s['codec_type'] for s in metadata['streams']} >= {'audio', 'video'}
    assert float(metadata['format']['duration']) > 4
    assert requests == ['/channel.ts'], requests
    ffmpeg('-i', output, '-map', '0:v', '-map', '0:a', '-f', 'null', '-')
    def frame_hashes(path):
        rows = ffmpeg('-i', path, '-map', '0:v:0', '-f', 'framemd5', '-').decode().splitlines()
        return [row.rsplit(',', 1)[-1].strip() for row in rows if row and not row.startswith('#')]
    reference, saved = frame_hashes(source), frame_hashes(output)
    first = reference.index(saved[0])
    assert saved == reference[first:first + len(saved)], 'buffer/live join duplicated or lost video frames'
    assert saved.count(reference[30]) == 1, 'the pre-recording goal frame must appear exactly once'
    packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
        '-show_packets', '-show_entries', 'packet=pts_time,duration_time', '-of', 'json', output]))['packets']
    for previous, current in zip(packets, packets[1:]):
        gap = float(current['pts_time']) - float(previous['pts_time']) - float(previous['duration_time'])
        assert abs(gap) < .001, ('audio gap or duplicate packet at buffer/live join', gap)
    print('buffer: one provider connection, contiguous video, one goal, continuous audio and decoded live continuation', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pleazyng-native-media-') as directory:
        mpv, root = Mpv(args.libmpv), Path(directory)
        verify_audio(mpv, root)
        verify_recording(mpv, root)


if __name__ == '__main__':
    main()
