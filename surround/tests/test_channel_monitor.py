"""Live regression: the diagnostic must observe all six Windows input channels.

Reuses the existing isolated speaker fixture. Windows output is muted for this
test, and its original volume/mute is restored even if an assertion fails.
"""
from pathlib import Path
import subprocess
import time
from bridge_test_settings import selected_devices

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "source/engine/build/Release"
settings = selected_devices()
endpoint = settings["in_id"]

def control(*arguments):
    return subprocess.run([str(BIN / "bridge_control.exe"), *arguments], check=True, capture_output=True, text=True).stdout

original = dict(line.split("=", 1) for line in control("--volume", endpoint).splitlines() if "=" in line)
monitor = player = None
try:
    control("--set-volume", endpoint, original["scalar"], "1")
    monitor = subprocess.Popen([str(BIN / "engine.exe"), "--in-id", endpoint, "--loopback", "--mon", "--duration", "21"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(0.3)
    player = subprocess.Popen([str(BIN / "bridge_control.exe"), "--play-wav", endpoint, str(ROOT / "tests/output/sequential_5p1.wav")], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    output, _ = monitor.communicate(timeout=28)
    assert monitor.returncode == 0, output
    assert player.wait(timeout=5) == 0, player.stderr.read().decode()
    (ROOT / "tests/output/channel-monitor.log").write_text(output)
    fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    for index, label in enumerate(("FL", "FR", "FC", "LFE", "BL", "BR")):
        assert fields[f"channel_{index}_label"] == label, output
        assert float(fields[f"channel_{index}_peak"]) > 0.01, f"Missing {label} activity: {output}"
        assert float(fields[f"channel_{index}_rms"]) > 0, output
    print("PASS: monitor independently detected FL/FR/FC/LFE/BL/BR source activity; Windows mute prevented speaker output.")
finally:
    for process in (monitor, player):
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    control("--set-volume", endpoint, original["scalar"], original["mute"])
