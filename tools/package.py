#!/usr/bin/env python3
import pathlib
import tarfile
import zipfile
root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'build/Payload/OpenDisplay4.app'
with zipfile.ZipFile(root / 'build/OpenDisplay4.ipa', 'w', zipfile.ZIP_DEFLATED) as out:
    for file in sorted(app.rglob('*')):
        if file.is_file():
            out.write(file, file.relative_to(root / 'build'))
with tarfile.open(root / 'build/OpenDisplay4-device.tar.gz', 'w:gz') as out:
    out.add(app, arcname='OpenDisplay4.app')
