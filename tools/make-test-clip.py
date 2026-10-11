#!/usr/bin/env python3
import pathlib
import subprocess
from h264 import access_units, framed

root = pathlib.Path(__file__).resolve().parent.parent
root.joinpath('build').mkdir(exist_ok=True)
raw = root / 'build/selftest.h264'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=480x320:rate=30', '-t', '3',
    '-c:v', 'libx264', '-profile:v', 'main', '-level:v', '3.1', '-pix_fmt', 'yuv420p',
    '-preset', 'ultrafast', '-tune', 'zerolatency', '-crf', '24',
    '-x264-params', 'cabac=1:bframes=0:keyint=30:min-keyint=30:scenecut=0:aud=1:repeat-headers=1',
    '-f', 'h264', str(raw)], check=True)
units = list(access_units(raw.read_bytes()))
root.joinpath('resources/selftest.odframes').write_bytes(b''.join(map(framed, units)))
print(f'Bundled {len(units)} Main@3.1 access units (480x320)')
