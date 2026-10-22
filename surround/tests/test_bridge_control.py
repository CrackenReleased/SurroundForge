"""Non-mutating CLI regression: reject invalid IDs, roles, and non-VB format/play requests."""
from pathlib import Path
import argparse
import subprocess
from bridge_test_settings import selected_devices

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--control", type=Path, default=ROOT / "source/engine/build/Release/bridge_control.exe")
CONTROL = parser.parse_args().control.resolve()

try:
    DEVICES = selected_devices()
    OPTICAL = DEVICES["out_id"]
    CABLE = DEVICES["in_id"]
    has_live_config = True
except Exception:
    OPTICAL = "mock-optical-endpoint-id"
    CABLE = "mock-cable-endpoint-id"
    has_live_config = False


def expect(code, text, *args):
    result = subprocess.run([str(CONTROL), *args], capture_output=True, text=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert text in result.stdout + result.stderr, (args, result.stdout, result.stderr)


expect(0, "--play-wav ID PATH", "--help")
expect(0, "--tone-speaker ID SPEAKER LAYOUT", "--help")

# Offline tests inspect the HID command without initializing real optical hardware.
expect(0, "--init-optical", "--help")

expect(2, "Invalid command", "--unknown")
expect(2, "exactly match", "--format", "not-an-endpoint")
optical_active = False
cable_active = False
try:
    dev_res = subprocess.run([str(CONTROL), "--devices-json"], capture_output=True, text=True)
    if dev_res.returncode == 0:
        optical_active = f'"{OPTICAL}"' in dev_res.stdout
        cable_active = f'"{CABLE}"' in dev_res.stdout
except Exception:
    pass

if optical_active:
    expect(2, "ROLE must be exactly", "--default", OPTICAL, "99")
    expect(2, "restricted to", "--set-51", OPTICAL)
    expect(2, "restricted to", "--set-mix-51", OPTICAL)
    expect(2, "restricted to", "--play-wav", OPTICAL, str(ROOT / "tests/output/sequential_5p1.wav"))
    expect(2, "restricted to", "--tone-speaker", OPTICAL, "FL", "5.1")
else:
    expect(2, "must exactly match", "--default", OPTICAL, "99")
    expect(2, "must exactly match", "--set-51", OPTICAL)
    expect(2, "must exactly match", "--set-mix-51", OPTICAL)
    expect(2, "must exactly match", "--play-wav", OPTICAL, str(ROOT / "tests/output/sequential_5p1.wav"))
    expect(2, "must exactly match", "--tone-speaker", OPTICAL, "FL", "5.1")

if cable_active:
    expect(2, "", "--tone-speaker", CABLE, "INVALID_SPK", "5.1")
    expect(2, "", "--tone-speaker", CABLE, "FL", "9.1")
    expect(0, "scalar=", "--volume", CABLE)
else:
    expect(2, "must exactly match", "--volume", CABLE)

res_def = subprocess.run([str(CONTROL), "--defaults"], capture_output=True, text=True)
assert (res_def.returncode == 0 and "0=" in res_def.stdout) or \
       (res_def.returncode == 1 and "No default render endpoint" in res_def.stderr), res_def
expect(2, "", "--set-volume", OPTICAL, "0.1", "0")
expect(2, "", "--set-volume", CABLE, "nan", "0")
expect(2, "", "--set-volume", CABLE, "1.1", "0")
expect(2, "", "--set-volume", CABLE, "0.1", "invalid")
expect(2, "", "--measure-loopback", CABLE, "11")
print("PASS: controller help/default reads and invalid command/ID/role/non-VB mutation/play/tone-speaker guards; no endpoint changed")

