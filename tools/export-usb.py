#!/usr/bin/env python3
"""Export a PAL direct-USB take to MP4 without administrator privileges."""
import argparse
import bisect
import math
import mmap
import json
from pathlib import Path
import subprocess


def frame_indices(times, start, duration, rate=50):
    """Hold the last available frame at each output tick; never shorten gaps."""
    return [max(0,bisect.bisect_right(times,start+i/rate)-1)
            for i in range(math.floor(duration*rate))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    folder = args.directory.resolve()
    audio = json.loads((folder/'audio.json').read_text())
    video = json.loads((folder/'video.json').read_text())
    if any(audio[key] for key in ('packet_errors','empty_packets','usb_error','write_error')) or video['movie_failed']:
        parser.error('Capture reported errors; inspect original logs before exporting')
    if video['standard'] != 'pal' or (video['width'],video['height']) != (704,576):
        parser.error('This exporter currently supports 704x576 PAL only')
    offset = audio['start_monotonic']-video['first_frame_monotonic']
    times = video['frame_times']
    if len(times) != video['frames'] or any(b <= a for a,b in zip(times,times[1:])):
        parser.error('Missing or invalid video timestamps')
    duration = min(audio['sample_seconds'],times[-1]-audio['start_monotonic']+.02)
    if offset < 0 or duration <= 0:
        parser.error('Video does not cover the audio start')
    if (folder/'movie.uyvy').stat().st_size != video['frames']*704*576*2:
        parser.error('Raw video size does not match captured frame count')
    # The driver emits a rolling weave at field rate (50/s). Deinterlace and
    # reduce to 25 fps for playback. Keep original raw captures for later work.
    output = folder/'playback.mp4'
    indices = frame_indices(times,audio['start_monotonic'],duration)
    command = ['ffmpeg','-hide_banner','-loglevel','warning','-n',
        '-f','rawvideo','-pixel_format','uyvy422','-video_size','704x576',
        '-framerate','50','-i','pipe:0',
        '-f','s16le','-ar','48000','-ac','2','-i',str(folder/'audio.s16le'),
        '-map','0:v:0','-map','1:a:0','-t',str(duration),
        '-vf','yadif,fps=25,setsar=12/11','-af','pan=mono|c0=c1',
        '-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p',
        '-c:a','aac','-b:a','192k','-movflags','+faststart',str(output)]
    with (folder/'movie.uyvy').open('rb') as raw, mmap.mmap(raw.fileno(),0,access=mmap.ACCESS_READ) as frames:
        process = subprocess.Popen(command,stdin=subprocess.PIPE)
        try:
            size = 704*576*2
            for index in indices:
                process.stdin.write(frames[index*size:(index+1)*size])
        finally:
            process.stdin.close()
            code = process.wait()
        if code:
            raise subprocess.CalledProcessError(code,command)
    report={'video_trim_seconds':offset,'duration_seconds':duration,
            'repeated_output_frames':sum(a==b for a,b in zip(indices,indices[1:])),
            'max_frame_interval_seconds':max(b-a for a,b in zip(times,times[1:])),
            'alignment':'Host monotonic timestamps; USB/decoder latency is not calibrated',
            'output':str(output)}
    (folder/'export.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
