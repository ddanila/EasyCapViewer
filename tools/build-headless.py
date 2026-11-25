#!/usr/bin/env python3
"""Build the STK1160 diagnostic CLI with Apple's Command Line Tools (no Xcode)."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
src = root / 'EasyCapViewer'
out = root / 'build/headless'
out.mkdir(parents=True, exist_ok=True)
files = [src / p for p in [
    'Models/Capture/ECVCaptureDevice.m', 'Models/Capture/ECVUSBTransferList.m',
    'Models/Capture/ECVVideoSource.m', 'Models/Capture/ECVVideoFormat.m',
    'Models/Capture/ECVDeinterlacingMode.m',
    'Models/Video/ECVVideoStorage.m', 'Models/Video/ECVIndependentVideoStorage.m',
    'Models/Video/ECVVideoFrame.m', 'Models/Video/ECVPixelBuffer.m',
    'Models/Math/ECVRational.m', 'Utilities/ECVDebug.m',
    'Utilities/ECVFoundationAdditions.m',
    'Drivers/STK1160/ECVSTK1160Device.m', 'Drivers/STK1160/stk11xx-dev-0408.m',
    'Drivers/Chipsets/SAA711XChip.m', 'Drivers/Chipsets/VT1612AChip.m',
]]
cmd = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2', '-g',
       '-Wno-deprecated-declarations', '-DECV_LOG_TO_CONSOLE',
       '-include', str(src / 'App/EasyCapViewer-Prefix.pch')]
for directory in sorted({p.parent for p in src.rglob('*.h')}):
    cmd += ['-I', str(directory)]
cmd += [str(root / 'tools/ecv-capture.m')] + [str(p) for p in files]
for framework in ['Cocoa', 'IOKit', 'CoreVideo', 'CoreMedia', 'AVFoundation', 'Accelerate']:
    cmd += ['-framework', framework]
cmd += ['-o', str(out / 'ecv-capture')]
subprocess.run(cmd, check=True)
print(out / 'ecv-capture')

# Native audio recorder avoids FFmpeg's single unread AVFoundation buffer.
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2',
                '-Wno-deprecated-declarations', str(root / 'tools/ecv-audio.m'),
                '-framework', 'Foundation', '-framework', 'AVFoundation',
                '-framework', 'CoreMedia', '-o', str(out / 'ecv-audio')], check=True)
print(out / 'ecv-audio')

subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2',
                '-Wno-deprecated-declarations', str(root / 'tools/ecv-coreaudio.m'),
                '-framework', 'Foundation', '-framework', 'AVFoundation',
                '-framework', 'CoreAudio', '-o', str(out / 'ecv-coreaudio')], check=True)
print(out / 'ecv-coreaudio')
