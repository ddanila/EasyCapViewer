#!/usr/bin/env python3
"""Bounded, sequential capture comparisons; retains originals and all reports."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('check_audio',ROOT/'tools/check-audio.py')
checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path,help='New directory for this run')
    parser.add_argument('--seconds',type=float,default=15)
    parser.add_argument('--backend',choices=['both','avfoundation','coreaudio'],default='both')
    parser.add_argument('--video',action='store_true')
    args=parser.parse_args()
    if not 0 < args.seconds <= 600:parser.error('Use 0 < seconds <= 600')
    args.directory.mkdir(parents=True,exist_ok=False)
    summary=[]
    backends=['avfoundation','coreaudio'] if args.backend=='both' else [args.backend]
    for backend in backends:
        folder=args.directory/backend;folder.mkdir()
        video=None
        with (folder/'video.stderr.log').open('w') as err, (folder/'video.json').open('w') as out:
            try:
                if args.video:
                    video=subprocess.Popen([str(ROOT/'build/headless/ecv-capture'),'--seconds',str(args.seconds+5),'--output',str(folder/'video.uyvy')],stdout=out,stderr=err)
                    time.sleep(2)
                    if video.poll() is not None:raise RuntimeError('Video initialization failed; inspect video logs')
                exe='ecv-audio' if backend=='avfoundation' else 'ecv-coreaudio'
                result=subprocess.run([str(ROOT/'build/headless'/exe),'USB Audio Interface',str(args.seconds),str(folder/'audio.caf'),'--diagnostics',str(folder/'buffers.jsonl')],capture_output=True,text=True,timeout=args.seconds+20)
                (folder/'capture.stdout.json').write_text(result.stdout)
                (folder/'capture.stderr.log').write_text(result.stderr)
                capture=json.loads(result.stdout)
                channels=[]
                # Both channels matter: highest-RMS selection can hide failure.
                for channel in [1,2]:
                    report=checker.inspect(folder/'audio.caf',channel)
                    (folder/f'channel-{channel}.json').write_text(json.dumps(report,indent=2))
                    channels.append({k:report[k] for k in ['channel','duration_seconds','flat_seconds','suspected_events','rms_dbfs','zero_samples','signal_present']})
                rows=[json.loads(line) for line in (folder/'buffers.jsonl').read_text().splitlines()]
                input_zeros=[sum(row.get('channels',[{},{}])[c].get('zero_samples',0) for row in rows) for c in [0,1]]
                status='failed' if result.returncode or channels[1]['suspected_events'] else ('no_signal' if not channels[1]['signal_present'] else 'candidate_pass')
                summary.append(dict(backend=backend,returncode=result.returncode,capture=capture,channels=channels,input_zero_samples=input_zeros,validation_status=status))
            finally:
                if video is not None:
                    try:video.wait(timeout=8)
                    except subprocess.TimeoutExpired:video.terminate();video.wait(timeout=8)
    (args.directory/'summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2))
    return 1 if any(r['validation_status'] != 'candidate_pass' for r in summary) else 0


if __name__=='__main__':
    raise SystemExit(main())
