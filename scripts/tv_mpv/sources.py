"""Stage the TV recipe's pinned downloads before starting the cross compiler."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
import shutil
from pathlib import Path
import subprocess
from urllib.parse import urlsplit

MIRRORS = {
    'download.gnome.org': 'https://dev-www.libreoffice.org/src/',
    'downloads.sourceforge.net': 'https://dev-www.libreoffice.org/src/',
    'download.videolan.org': 'https://mirror.csclub.uwaterloo.ca/vlc/dav1d/1.5.1/',
}


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def prefetch(checkout, target, directory):
    directory.mkdir(parents=True, exist_ok=True)
    entries = {}
    for line in (checkout / 'scripts/shared/_sources.sha256').read_text().splitlines():
        fields = line.split()
        if len(fields) != 2 or len(fields[0]) != 64 or not fields[1].startswith('https://'):
            continue
        digest, url = fields
        path = urlsplit(url).path
        if ('android-ndk' in path or 'fontconfig' in path or 'rubberband' in path or
                'ffmpeg-' in path and path.endswith('.xz') or 'speex' in path or
                'torvalds/linux/' in path and target != 'tizen'):
            continue
        entries[digest] = url

    def acquire(item):
        digest, url = item
        final = directory / digest
        if final.is_file() and digest_file(final) == digest:
            return
        temp = final.with_suffix('.part')
        parsed = urlsplit(url)
        urls = [url]
        if parsed.hostname in MIRRORS:
            urls.append(MIRRORS[parsed.hostname] + Path(parsed.path).name)
        if parsed.hostname == 'raw.githubusercontent.com' and parsed.path.startswith('/torvalds/linux/'):
            urls.append('https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/' +
                        parsed.path.removeprefix('/torvalds/linux/') + '?format=TEXT')
        staged_dav1d = os.environ.get('PLEAZYNG_DAV1D_ARCHIVE')
        if staged_dav1d and parsed.path.endswith('/dav1d-1.5.1.tar.xz'):
            local = Path(staged_dav1d)
            if local.is_file() and digest_file(local) == digest:
                shutil.copyfile(local, temp)
                temp.replace(final)
                return
            urls.append('https://veronanetworks.mm.fcix.net/videolan-ftp/dav1d/1.5.1/dav1d-1.5.1.tar.xz')
        for candidate in urls:
            cmd = ['curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '180',
                   '--retry', '2', '--output', str(temp), candidate]
            if subprocess.run(cmd).returncode:
                continue
            if candidate.endswith('?format=TEXT'):
                temp.write_bytes(base64.b64decode(temp.read_bytes()))
            if digest_file(temp) == digest:
                temp.replace(final)
                return
        raise ValueError(f'Could not stage checksum-pinned source {url}')

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(acquire, entries.items()))
    helpers = checkout / 'scripts/shared/_helpers.sh'
    marker = '  local url="$1" dest="$2"; shift 2'
    code = helpers.read_text()
    if code.count(marker) != 1:
        raise ValueError('Download helper no longer matches the pinned recipe')
    helpers.write_text(code.replace(marker, marker + '''
  local staged
  staged=$(awk -v u="$url" '$2 == u {print $1}' "$SOURCES_SHA256_FILE")
  if [[ -n "$staged" && -f "$PLEAZYNG_TV_SOURCES/$staged" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$PLEAZYNG_TV_SOURCES/$staged" "$dest"
    verify_source "$url" "$dest"
    return
  fi'''))
