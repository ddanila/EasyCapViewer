#!/usr/bin/env python3
"""Build the experimental raw USB audio reader using installed libusb."""
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parent.parent
prefix=Path(subprocess.check_output(['brew','--prefix','libusb'],text=True).strip())
out=root/'build/headless/ecv-usbaudio'
out.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','clang','-std=c11','-O2','-Wall','-Wextra',
               '-I'+str(prefix/'include/libusb-1.0'),str(root/'tools/ecv-usbaudio.c'),
               '-L'+str(prefix/'lib'),'-lusb-1.0','-o',str(out)],check=True)
print(out)
