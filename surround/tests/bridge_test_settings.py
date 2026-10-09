"""Read destination-PC device selection for live integration tests."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def selected_devices():
    path = ROOT / "bridge.conf"
    if not path.exists():
        raise RuntimeError("Run SurroundForge Setup before live device tests; this PC has no bridge.conf.")
    values = dict(line.split("=", 1) for line in path.read_text(encoding="utf-8-sig").splitlines()
                  if "=" in line and not line.lstrip().startswith(("#", ";")))
    if not values.get("in_id") or not values.get("out_id"):
        raise RuntimeError("Configure both virtual input and optical output in SurroundForge Setup.")
    return {key: value.strip() for key, value in values.items()}
