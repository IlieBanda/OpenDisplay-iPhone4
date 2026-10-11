#!/usr/bin/env python3
"""Send a real Main@3.1 H.264 test pattern to the iOS 6 receiver."""
import argparse
import json
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
from h264 import access_units, framed

def read_exact(sock, size):
    out = bytearray()
    while len(out) < size:
        data = sock.recv(size-len(out))
        if not data:
            raise EOFError('receiver disconnected')
        out.extend(data)
    return bytes(out)

def read_control(sock):
    size = struct.unpack('>I', read_exact(sock,4))[0]
    if not 0 < size < 2**20:
        raise ValueError('invalid control frame size')
    return json.loads(read_exact(sock,size))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--port', type=int, default=9000)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--width', type=int, default=960)
    parser.add_argument('--height', type=int, default=640)
    parser.add_argument('--profile', choices=('main','high'), default='main')
    parser.add_argument('--fps', type=int, choices=(30,60), default=30)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120 or not 16 <= args.width <= 960 or not 16 <= args.height <= 960 or min(args.width,args.height) > 640:
        parser.error('seconds must be 1..120; raster must fit 960x640 or 640x960')
    with tempfile.TemporaryDirectory(prefix='od4-test-') as temp:
        raw = pathlib.Path(temp)/'pattern.h264'
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',
            '-f','lavfi','-i',f'testsrc2=size={args.width}x{args.height}:rate={args.fps}',
            '-t',str(args.seconds),'-c:v','libx264','-profile:v',args.profile,'-level:v','3.2' if args.profile == 'high' or args.fps == 60 else '3.1',
            '-pix_fmt','yuv420p','-preset','ultrafast','-tune','zerolatency','-b:v','2M',
            '-x264-params',f'cabac=1:8x8dct={int(args.profile == "high")}:bframes=0:keyint={args.fps}:min-keyint={args.fps}:scenecut=0:aud=1:repeat-headers=1',
            '-f','h264',str(raw)],check=True)
        units = list(access_units(raw.read_bytes()))
    # usbmux's proxy can accept locally before the phone listener is ready.
    deadline = time.monotonic()+8
    while True:
        sock = None
        try:
            sock = socket.create_connection((args.host,args.port),timeout=2)
            sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            hello = read_control(sock)
            break
        except (OSError,EOFError):
            if sock: sock.close()
            if time.monotonic() >= deadline: raise
            time.sleep(0.3)
    with sock:
        if hello.get('type') != 'hello': raise ValueError('hello must be first')
        print('HELLO',json.dumps(hello,ensure_ascii=False),flush=True)
        sock.settimeout(6)
        lock = threading.Lock()
        def control(message):
            with lock: sock.sendall(framed(json.dumps(message,separators=(',',':')).encode()))
        stopped = threading.Event()
        def replies():
            try:
                while not stopped.is_set():
                    message = read_control(sock)
                    kind = message.get('type')
                    if kind == 'ping': control({'type':'pong','t':message.get('t'),'mt':time.time()*1000})
                    elif kind in ('stats','kf','touch','scroll'): print('RX',json.dumps(message),flush=True)
            except (OSError,EOFError,ValueError):
                stopped.set()
        thread = threading.Thread(target=replies,daemon=True); thread.start()
        control({'type':'welcome','pv':3,'min':1})
        control({'type':'streamConfig','codec':'h264','width':args.width,'height':args.height,'framesPerSecond':args.fps})
        start = time.monotonic()
        for i, unit in enumerate(units):
            if stopped.is_set(): raise RuntimeError('receiver disconnected during test')
            remaining = start+i/args.fps-time.monotonic()
            if remaining > 0: time.sleep(remaining)
            if i % 60 == 0: control({'type':'ping'})
            metadata = json.dumps({'cap':time.time()*1000,'snd':time.time()*1000},separators=(',',':')).encode()
            with lock: sock.sendall(framed(metadata+unit))
        time.sleep(1)
        print(f'SENT {len(units)} access units ({args.width}x{args.height}, {args.fps} FPS)',flush=True)
        stopped.set(); sock.shutdown(socket.SHUT_RDWR); thread.join(timeout=2)

if __name__ == '__main__': main()
