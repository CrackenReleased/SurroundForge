"""Live regression: Windows mute must silence the production six-channel capture.

Uses a quiet existing speaker fixture and restores the original volume/mute.
Run with the bridge running; --mon never opens the optical output.
"""
from pathlib import Path
import subprocess
import time
from bridge_test_settings import selected_devices

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "source/engine/build/Release"
ID = selected_devices()["in_id"]

def call(*args):
    result = subprocess.run([str(BIN / "bridge_control.exe"), *args], capture_output=True, text=True, check=True)
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

def monitor():
    result = subprocess.run([str(BIN / "engine.exe"), "--in-id", ID, "--loopback",
                             "--require-surround", "--mon"], capture_output=True, text=True, check=True)
    return float(next(line[5:] for line in result.stdout.splitlines() if line.startswith("peak=")))

original = call("--volume", ID)
player = None
try:
    call("--set-volume", ID, "0.1", "0")
    player = subprocess.Popen([str(BIN / "bridge_control.exe"), "--play-wav", ID,
                               str(ROOT / "tests/output/sequential_5p1.wav")],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(1.2)
    audible = monitor()
    assert audible > 0, "Test source did not reach the bridge capture"
    call("--set-volume", ID, "0.1", "1")
    muted = monitor()
    assert muted == 0, f"Windows mute leaked PCM into AC3: peak={muted} (unmuted={audible})"
    print(f"PASS: six-channel Windows mute; unmuted peak={audible}, muted peak={muted}")
finally:
    if player:
        player.terminate()
        player.wait(timeout=5)
    call("--set-volume", ID, original["scalar"], original["mute"])
