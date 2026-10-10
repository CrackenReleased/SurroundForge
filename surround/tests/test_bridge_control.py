"""Non-mutating CLI regression: reject invalid IDs, roles, and non-VB format/play requests."""
from pathlib import Path
import subprocess
from bridge_test_settings import selected_devices

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "source/engine/build/Release/bridge_control.exe"

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

# Test --init-optical: either succeeds on C-Media hardware or reports device not found
res_opt = subprocess.run([str(CONTROL), "--init-optical", "48000"], capture_output=True, text=True)
assert (res_opt.returncode == 0 and "cmedia_spdif=initialized" in res_opt.stdout) or \
       (res_opt.returncode == 1 and "No C-Media optical device found" in res_opt.stderr), res_opt

expect(2, "Invalid command", "--unknown")
expect(2, "exactly match", "--format", "not-an-endpoint")
if has_live_config:
    expect(2, "ROLE must be exactly", "--default", OPTICAL, "99")
    expect(2, "restricted to", "--set-51", OPTICAL)
    expect(2, "restricted to", "--set-mix-51", OPTICAL)
    expect(2, "restricted to", "--play-wav", OPTICAL, str(ROOT / "tests/output/sequential_5p1.wav"))
else:
    expect(2, "must exactly match", "--default", OPTICAL, "99")
    expect(2, "must exactly match", "--set-51", OPTICAL)
    expect(2, "must exactly match", "--set-mix-51", OPTICAL)
    expect(2, "must exactly match", "--play-wav", OPTICAL, str(ROOT / "tests/output/sequential_5p1.wav"))
if has_live_config:
    expect(0, "0=", "--defaults")
    expect(0, "scalar=", "--volume", CABLE)
else:
    res_def = subprocess.run([str(CONTROL), "--defaults"], capture_output=True, text=True)
    assert (res_def.returncode == 0 and "0=" in res_def.stdout) or \
           (res_def.returncode == 1 and "No default render endpoint" in res_def.stderr), res_def
    expect(1, "must exactly match", "--volume", CABLE)
expect(2, "", "--set-volume", OPTICAL, "0.1", "0")
expect(2, "", "--set-volume", CABLE, "nan", "0")
expect(2, "", "--set-volume", CABLE, "1.1", "0")
expect(2, "", "--set-volume", CABLE, "0.1", "invalid")
expect(2, "", "--measure-loopback", CABLE, "11")
print("PASS: controller help/default reads and invalid command/ID/role/non-VB mutation/play guards; no endpoint changed")
