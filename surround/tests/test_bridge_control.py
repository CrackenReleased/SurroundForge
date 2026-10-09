"""Non-mutating CLI regression: reject invalid IDs, roles, and non-VB format/play requests."""
from pathlib import Path
import subprocess
from bridge_test_settings import selected_devices

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "source/engine/build/Release/bridge_control.exe"
DEVICES = selected_devices()
OPTICAL = DEVICES["out_id"]
CABLE = DEVICES["in_id"]


def expect(code, text, *args):
    result = subprocess.run([str(CONTROL), *args], capture_output=True, text=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert text in result.stdout + result.stderr, (args, result.stdout, result.stderr)


expect(0, "--play-wav ID PATH", "--help")
expect(2, "Invalid command", "--unknown")
expect(2, "exactly match", "--format", "not-an-endpoint")
expect(2, "ROLE must be exactly", "--default", OPTICAL, "99")
expect(2, "restricted to", "--set-51", OPTICAL)
expect(2, "restricted to", "--set-mix-51", OPTICAL)
expect(2, "restricted to", "--play-wav", OPTICAL, str(ROOT / "tests/output/sequential_5p1.wav"))
expect(0, "0=", "--defaults")
expect(0, "scalar=", "--volume", CABLE)
expect(2, "", "--set-volume", OPTICAL, "0.1", "0")
expect(2, "", "--set-volume", CABLE, "nan", "0")
expect(2, "", "--set-volume", CABLE, "1.1", "0")
expect(2, "", "--set-volume", CABLE, "0.1", "invalid")
expect(2, "", "--measure-loopback", CABLE, "11")
print("PASS: controller help/default reads and invalid command/ID/role/non-VB mutation/play guards; no endpoint changed")
