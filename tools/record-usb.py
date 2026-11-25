#!/usr/bin/env python3
"""Privileged bounded STK1160 audio test with optional simultaneous video.
Use sudo; native USB ownership is returned to macOS after each take.
Analysis/export should run afterward without sudo.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='New capture directory')
    parser.add_argument('--seconds', type=int, default=30, choices=range(1,601), metavar='1..600')
    parser.add_argument('--video', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('macOS requires administrator authorization: run with sudo')
    args.directory.mkdir(parents=True, exist_ok=False)
    folder = args.directory.resolve()
    required_bytes = ((args.seconds+10)*704*576*2*50 if args.video else 0)+args.seconds*192000+1024**3
    if shutil.disk_usage(folder).free < required_bytes:
        parser.error(f'Insufficient space: need {required_bytes/1024**3:.1f} GiB including reserve')
    video = audio = None
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        with (folder/'audio.json').open('w') as out, (folder/'audio.log').open('w') as err, (folder/'video.json').open('w') as vout, (folder/'video.log').open('w') as verr:
            command = [str(ROOT/'build/headless/ecv-usbaudio'), str(args.seconds), str(folder/'audio.s16le')]
            if args.video:
                command += ['--start-delay','10']
            audio = subprocess.Popen(command, stdout=out, stderr=err)
            deadline = time.monotonic()+args.seconds+55
            while audio.poll() is None:
                if time.monotonic()>deadline:
                    raise TimeoutError('Capture exceeded deadline')
                log = (folder/'audio.log').read_text()
                if args.video and video is None and 'Ready for video initialization' in log:
                    video = subprocess.Popen([str(ROOT/'build/headless/ecv-capture'),'--shared-device','--seconds',str(args.seconds+10),'--output',str(folder/'video.uyvy'),'--raw-video',str(folder/'movie.uyvy')],stdout=vout,stderr=verr)
                if video is not None and 'Audio capture complete' in log and video.poll() is None:
                    # Let the bounded video run finish before USB ownership returns.
                    video.wait(timeout=15)
                if video is not None and video.poll() not in (None,0):
                    raise RuntimeError('Video capture failed; inspect video.log')
                time.sleep(.05)
            if audio.returncode:
                raise RuntimeError('USB capture failed; inspect audio.json and audio.log')
        report=json.loads((folder/'audio.json').read_text())
        print(json.dumps(report,indent=2))
        return 0
    finally:
        for child in [video,audio]:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    # Always continue to the USB owner so it can restore drivers.
                    print(f'Child {child.pid} has not finished cleanup', file=sys.stderr)
                    if child is video:
                        child.kill()
                        child.wait()
        if 'SUDO_UID' in os.environ and 'SUDO_GID' in os.environ:
            uid,gid=int(os.environ['SUDO_UID']),int(os.environ['SUDO_GID'])
            for path in folder.iterdir():
                os.chown(path,uid,gid)
            os.chown(folder,uid,gid)


if __name__ == '__main__':
    raise SystemExit(main())
