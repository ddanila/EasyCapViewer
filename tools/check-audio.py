#!/usr/bin/env python3
"""Find suspicious PCM interruptions; requires FFmpeg for input decoding.
Flags are evidence for listening review, not proof of capture failure.
"""
import argparse
import array
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import wave


def rms(samples):
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0


def analyze(samples, rate):
    events = []
    n = len(samples)
    if not n:
        raise ValueError('No audio samples')
    context = max(1, round(rate * .05))
    min_run = max(2, round(rate * .002))
    start = 0
    flat_seconds = 0
    for end in range(1, n + 1):
        if end < n and samples[end] == samples[start]:
            continue
        if end - start >= min_run:
            duration = (end - start) / rate
            flat_seconds += duration
            before = rms(samples[max(0, start-context):start])
            after = rms(samples[end:min(n, end+context)])
            # Exact PCM silence can be intentional. Require activity on both
            # sides before calling it a suspected interruption.
            surrounded = before > 33 and after > 33  # approximately -60 dBFS
            events.append(dict(kind='digital_silence' if samples[start] == 0 else 'held_sample',
                               start_seconds=round(start/rate, 6),
                               duration_seconds=round(duration, 6),
                               value=samples[start], suspected_interruption=surrounded))
        start = end
    diffs = [abs(samples[i] - samples[i-1]) for i in range(1, n)]
    last_click = -rate
    for i, jump in enumerate(diffs, 1):
        if jump < 655 or i - last_click < rate * .005:
            continue
        # Compare against local high-percentile slopes, excluding the spike.
        nearby = diffs[max(0, i-context):max(0, i-3)] + diffs[i+2:min(len(diffs), i+context)]
        if not nearby:
            continue
        nearby.sort()
        baseline = max(16, nearby[int(.95 * (len(nearby)-1))])
        if jump >= 8 * baseline:
            events.append(dict(kind='abrupt_jump', start_seconds=round(i/rate, 6),
                               duration_seconds=round(1/rate, 6),
                               jump_dbfs=round(20*math.log10(jump/32768), 2),
                               local_slope_ratio=round(jump/baseline, 2),
                               suspected_interruption=True))
            last_click = i
    events.sort(key=lambda x: x['start_seconds'])
    suspected = sum(e['suspected_interruption'] for e in events)
    return dict(duration_seconds=n/rate, sample_rate=rate,
                zero_samples=sum(x == 0 for x in samples),
                signal_present=rms(samples) > 33,
                suspected_events=suspected,
                flat_runs=sum(e['kind'] != 'abrupt_jump' for e in events),
                flat_seconds=flat_seconds, flat_fraction=flat_seconds/(n/rate),
                rms_dbfs=20*math.log10(max(rms(samples), 1e-12)/32768),
                events=events,
                interpretation='Heuristic flags, not a verdict: intentional silence or transients can trigger events; non-flat losses can escape detection.')


def inspect(path, channel=None):
    with tempfile.TemporaryDirectory(prefix='ecv-audio-check-') as tmp:
        decoded = Path(tmp) / 'decoded.wav'
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                        '-i', str(path), '-map', '0:a:0', '-c:a', 'pcm_s16le', str(decoded)], check=True)
        with wave.open(str(decoded)) as wav:
            rate, channels = wav.getframerate(), wav.getnchannels()
            data = array.array('h', wav.readframes(wav.getnframes()))
        if sys.byteorder != 'little':
            data.byteswap()
        if channel is None:
            channel = max(range(channels), key=lambda c: rms(data[c::channels])) + 1
        if not 1 <= channel <= channels:
            raise ValueError(f'Channel must be between 1 and {channels}')
        report = analyze(data[channel-1::channels], rate)
        report.update(file=str(path.resolve()), channel=channel, source_channels=channels)
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--channel', type=int, help='1-based channel; default is highest RMS')
    parser.add_argument('--report', type=Path, help='Also save JSON here')
    parser.add_argument('--capture-seconds', type=float, help='First record to a NEW input .caf using ecv-audio')
    parser.add_argument('--device', default='USB Audio Interface')
    args = parser.parse_args()
    capture = None
    if args.report and args.report.resolve() == args.input.resolve():
        parser.error('Report path must differ from the audio input')
    try:
        if args.capture_seconds is not None:
            exe = Path(__file__).resolve().parent.parent / 'build/headless/ecv-audio'
            result = subprocess.run([str(exe), args.device, str(args.capture_seconds), str(args.input)], capture_output=True, text=True)
            if result.stderr:
                print(result.stderr, file=sys.stderr, end='')
            if not result.stdout.strip():
                raise ValueError(f'Capture failed with exit code {result.returncode}')
            capture = json.loads(result.stdout)
            if capture.get('error') or not capture.get('sample_frames'):
                raise ValueError(f'Capture failed: {capture}')
        report = inspect(args.input, args.channel)
        if capture is not None:
            report['capture'] = capture
        encoded = json.dumps(report, indent=2, allow_nan=False) + '\n'
        if args.report:
            args.report.write_text(encoded)
        print(encoded, end='')
        return 1 if report['suspected_events'] or (capture and capture['timestamp_gaps']) else 0
    except (OSError, ValueError, subprocess.CalledProcessError, wave.Error) as error:
        print(f'Audio check failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
