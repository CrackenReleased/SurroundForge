"""Verify six independent tones survive WAV -> AC3 -> IEC61937 -> decoded PCM.

Run: python tests/test_channel_roundtrip.py
Keeps only output/sequential_5p1.wav for the physical speaker test.
No audio endpoint is opened and no additional Python packages are required.
"""
import argparse
from array import array
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).resolve().parent / "output"
FREQUENCIES = (200, 300, 400, 60, 600, 700)
CHANNELS = ("FL", "FR", "FC", "LFE", "BL", "BR")
RATE = 48000


def run(*command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        raise AssertionError(f"Command failed: {command}\n{result.stderr.decode(errors='replace')}")
    return result.stdout


def probe(path, *options):
    return json.loads(run("ffprobe", "-v", "error", *options, "-show_streams", "-of", "json", str(path)))["streams"][0]


def pcm(path, *options):
    data = array("h", run("ffmpeg", "-v", "error", *options, "-i", str(path),
                          "-c:a", "pcm_s16le", "-f", "s16le", "-"))
    if sys.byteorder != "little":
        data.byteswap()
    return data


def window(data, start, duration=.5):
    first = round(start * RATE) * 6
    end = first + round(duration * RATE) * 6
    assert end <= len(data), "Audio ended before all six channel slots"
    return [data[first + channel:end:6] for channel in range(6)]


def rms(samples):
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def tone_amplitude(samples, frequency):
    angle = 2 * math.pi * frequency / RATE
    real = sum(sample * math.cos(angle * i) for i, sample in enumerate(samples))
    imag = sum(sample * math.sin(angle * i) for i, sample in enumerate(samples))
    return 2 * math.hypot(real, imag) / len(samples)


def assert_slots(data, label):
    assert len(data) // 6 >= RATE * 18.7, f"{label}: need all six slots and their trailing gaps"
    assert max(rms(channel) for channel in window(data, .1)) < 2, f"{label}: missing start silence"
    for i, (name, frequency) in enumerate(zip(CHANNELS, FREQUENCIES)):
        channels = window(data, 1.5 + 3 * i)
        levels = [rms(channel) for channel in channels]
        assert levels[i] > 500, f"{label}: {name} missing: {levels}"
        assert max(level for j, level in enumerate(levels) if j != i) < levels[i] / 50, \
            f"{label}: {name} leaked or was mapped to the wrong channel: {levels}"
        amplitude = tone_amplitude(channels[i], frequency)
        assert amplitude > levels[i] * 1.25, f"{label}: {name} frequency {frequency} Hz lost"
        assert max(abs(sample) for sample in channels[i]) < 2000, f"{label}: tone too loud"
        assert max(rms(channel) for channel in window(data, 3.3 + 3 * i, .3)) < 2, \
            f"{label}: missing gap after {name}"


def assert_bursts(data):
    assert data and len(data) % 6144 == 0, "AC3 IEC61937 bursts must occupy 6144 bytes each"
    for offset in range(0, len(data), 6144):
        burst = data[offset:offset + 6144]
        pa, pb, pc, pd = struct.unpack_from("<4H", burst)
        assert (pa, pb) == (0xF872, 0x4E1F), "Wrong IEC61937 sync words"
        assert pc & 0x1F == 1, "Burst type must be AC3"
        assert pd == 1792 * 8, "448 kbit/s, 48 kHz AC3 frame must be 1792 bytes"
        assert burst[8:10] == b"\x77\x0b", "Missing byte-swapped AC3 sync word"
        assert not any(burst[8 + pd // 8:]), "IEC61937 padding must be zero"


def main():
    import os
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, default=ROOT / "source/scripts/make-test-wav.ps1")
    parser.add_argument("--encoder", type=Path, default=ROOT / "source/engine/build/Release/encode_wav.exe")
    args = parser.parse_args()

    ffmpeg_bin = ROOT / "source/third_party/ffmpeg/bin"
    if ffmpeg_bin.is_dir() and str(ffmpeg_bin) not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{ffmpeg_bin};{os.environ.get('PATH', '')}"

    missing = [tool for tool in ("pwsh", "ffmpeg", "ffprobe") if not shutil.which(tool)]
    if missing:
        print(f"SKIP: Required tools unavailable ({', '.join(missing)}); skipping roundtrip probe.")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    simultaneous = OUT / "simultaneous_regression.wav"
    sequence = OUT / "sequential_5p1.wav"
    ac3 = OUT / "channel_roundtrip.ac3"
    spdif = OUT / "channel_roundtrip.spdif"
    native_spdif = OUT / "native_channel_roundtrip.spdif"
    try:
        run("pwsh", "-NoProfile", "-File", str(args.script), "-Out", str(sequence), "-Sequential")
        info = probe(sequence)
        assert (info["channels"], int(info["sample_rate"]), info["channel_layout"], info["codec_name"]) == \
            (6, RATE, "5.1", "pcm_s16le"), info
        assert_slots(pcm(sequence), "Original WAV")
        assert args.encoder.is_file(), f"Build the native encoder first: {args.encoder}"
        run(str(args.encoder), str(sequence), str(native_spdif), "448000")
        assert_bursts(native_spdif.read_bytes())
        assert_slots(pcm(native_spdif, "-f", "spdif"), "Native encoder optical stream")
        run("ffmpeg", "-v", "error", "-y", "-i", str(sequence), "-c:a", "ac3", "-b:a", "448k", str(ac3))
        run("ffmpeg", "-v", "error", "-y", "-i", str(ac3), "-c:a", "copy", "-f", "spdif", str(spdif))
        assert_bursts(spdif.read_bytes())
        encoded = probe(spdif, "-f", "spdif")
        assert (encoded["codec_name"], encoded["channels"], int(encoded["sample_rate"])) == \
            ("ac3", 6, RATE), encoded
        # AC3 identifies the surround pair as SL/SR; six-channel sample order is unchanged.
        assert encoded["channel_layout"] in ("5.1", "5.1(side)"), encoded
        assert_slots(pcm(spdif, "-f", "spdif"), "Decoded optical stream")
        run("pwsh", "-NoProfile", "-File", str(args.script), "-Out", str(simultaneous), "-Duration", "1")
        for channel, frequency in zip(window(pcm(simultaneous), .2), FREQUENCIES):
            assert tone_amplitude(channel, frequency) > 500, "Original simultaneous mode changed"
        print("PASS: WAV 5.1 channel slots, 60 Hz LFE, all six frequencies, native encoder and FFmpeg AC3 roundtrips, IEC61937 sync/type/6144-byte bursts, 48 kHz, and original simultaneous mode")
        print(f"Physical test WAV: {sequence}")
    finally:
        # Only remove the exact intermediate files this test owns, within its output directory.
        for path in (simultaneous, ac3, spdif, native_spdif):
            assert path.resolve().parent == OUT.resolve()
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
