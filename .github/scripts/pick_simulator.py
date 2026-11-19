"""Print the UDID of the pinned simulator for a role, and nothing else.

Usage: xcrun simctl list devices available -j | python3 pick_simulator.py [--role default|pro]

The runtime and the simulator of each role are pinned in .github/toolchain.json: "default"
(CI and the nightly run) and "pro" (the UI flow and its App Store screenshots). The small iPhone
of the accessibility tests is created from its pinned device type by `ui_tests.py pick --device
se`. There is no fallback to "the newest runtime" or "a similar iPhone": when the pinned one is
missing (a new runner image), this fails with what the image offers instead, and the pins are
updated on purpose. "--pro" is kept as a short form of "--role pro".
"""
from __future__ import annotations

import json
import os
import sys

TOOLCHAIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "toolchain.json")


def pins(path: str = TOOLCHAIN) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pick(devices: dict, role: str, toolchain: dict) -> tuple[str, str]:
    """(udid, description) of the one available simulator of `role` on the pinned runtime.
    Raises SystemExit with the reason when there is none or more than one."""
    if role not in toolchain["simulators"]:
        raise SystemExit(f"unknown simulator role {role!r} (toolchain.json has {sorted(toolchain['simulators'])})")
    runtime = toolchain["runtime"]["identifier"]
    pin = toolchain["simulators"][role]
    on_runtime = [d for d in devices.get(runtime, []) if d.get("isAvailable", True)]
    found = [d for d in on_runtime if d.get("name") == pin["name"]
             and (not pin.get("type") or d.get("deviceTypeIdentifier") == pin["type"])]
    if len(found) == 1:
        d = found[0]
        return d["udid"], f"{d['name']} ({d.get('deviceTypeIdentifier', '?')}) on {runtime}"
    if not found:
        offered = sorted({d.get("name", "?") for d in on_runtime})
        raise SystemExit(f"pinned simulator {pin['name']!r} not found on {runtime} "
                         f"(it has: {', '.join(offered) or 'nothing; is the runtime installed?'}); "
                         "update .github/toolchain.json on purpose")
    raise SystemExit(f"{len(found)} simulators named {pin['name']!r} on {runtime}: "
                     + ", ".join(d["udid"] for d in found))


def main(argv: list[str]) -> int:
    role = "pro" if "--pro" in argv else "default"
    if "--role" in argv:
        role = argv[argv.index("--role") + 1]
    udid, description = pick(json.load(sys.stdin)["devices"], role, pins())
    print(description, file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
