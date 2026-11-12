"""Verify embedded checksums and, optionally, previously downloaded official ZIPs."""
import hashlib
import json
import pathlib
import re
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'snell.sh').read_text(encoding='utf-8')
embedded = dict(re.findall(r'^\s*([456]\.\d+\.\d+/[a-z0-9]+)\) echo ([a-f0-9]{64}) ;;', source, re.M))
manifest = json.loads((root / 'checksums.json').read_text(encoding='utf-8-sig'))
assert len(embedded) == len(manifest) == 11
machines = {'amd64': (2, 62), 'i386': (1, 3), 'aarch64': (2, 183), 'armv7l': (1, 40)}
for item in manifest:
    version, arch = item['version'], item['arch']
    assert embedded[f'{version}/{arch}'] == item['sha256']
    filename = f'snell-server-v{version}-linux-{arch}.zip'
    assert item['url'] == f'https://dl.nssurge.com/snell/{filename}'
    if len(sys.argv) > 1:
        data = (pathlib.Path(sys.argv[1]) / filename).read_bytes()
        assert len(data) == item['bytes']
        assert hashlib.sha256(data).hexdigest() == item['sha256']
        with zipfile.ZipFile(pathlib.Path(sys.argv[1]) / filename) as archive:
            assert archive.namelist().count('snell-server') == 1
            binary = archive.read('snell-server')
        assert binary[:4] == b'\x7fELF'
        assert (binary[4], int.from_bytes(binary[18:20], 'little')) == machines[arch]
print('PASS: 11 embedded hashes match the catalogue' + ('; official ZIPs and ELF architectures verified' if len(sys.argv) > 1 else ''))
