"""Convert an AUD-delimited Annex B test stream to OpenDisplay access units."""
import re
import struct

def access_units(data):
    starts = list(re.finditer(b'\x00\x00(?:\x00)?\x01', data))
    current = []
    for i, match in enumerate(starts):
        end = starts[i+1].start() if i+1 < len(starts) else len(data)
        nal = data[match.end():end]
        if not nal:
            continue
        if nal[0] & 31 == 9 and current:
            yield b''.join(current)
            current = []
        current.append(b'\x00\x00\x00\x01' + nal)
    if current:
        yield b''.join(current)

def framed(data):
    return struct.pack('>I', len(data)) + data
