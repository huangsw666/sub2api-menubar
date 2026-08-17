#!/usr/bin/env python3
"""Build and manage the Sub2API Menu Bar LaunchAgent."""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path


LABEL = "io.github.huangsw666.sub2api-menubar"
APP_NAME = "Sub2API Menu Bar.app"
VERSION = "0.1.0"


def paths():
    home = Path.home()
    support_dir = home / "Library" / "Application Support" / "Sub2APIMenuBar"
    bundle = support_dir / APP_NAME
    executable = bundle / "Contents" / "MacOS" / "Sub2APIMenuBar"
    config = support_dir / "config.json"
    launch_agent = home / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    return support_dir, bundle, executable, config, launch_agent


def service_name() -> str:
    return f"gui/{os.getuid()}/{LABEL}"


def bootout(service: str) -> None:
    subprocess.run(
        ["/bin/launchctl", "bootout", service],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(50):
        result = subprocess.run(
            ["/bin/launchctl", "print", service],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            return
        time.sleep(0.1)


def install(project_dir: Path) -> None:
    support_dir, bundle, executable, config, launch_agent = paths()
    executable.parent.mkdir(parents=True, exist_ok=True)
    launch_agent.parent.mkdir(parents=True, exist_ok=True)

    example = project_dir / "config.example.json"
    if not config.exists():
        shutil.copyfile(example, config)
        config.chmod(0o600)
        print(f"Created configuration: {config}")
        print("Edit sub2api_base_url before logging in.")

    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-swift-version",
            "5",
            "-O",
            str(project_dir / "Sources" / "Sub2APIMenuBar.swift"),
            "-framework",
            "AppKit",
            "-framework",
            "WebKit",
            "-framework",
            "Security",
            "-o",
            str(executable),
        ],
        check=True,
    )
    executable.chmod(0o700)

    with (bundle / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "Sub2APIMenuBar",
                "CFBundleIdentifier": LABEL,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Sub2API Menu Bar",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            },
            handle,
            sort_keys=True,
        )

    launch_agent_data = {
        "Label": LABEL,
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    temporary = launch_agent.with_suffix(".plist.new")
    with temporary.open("wb") as handle:
        plistlib.dump(launch_agent_data, handle, sort_keys=True)
    os.replace(temporary, launch_agent)
    launch_agent.chmod(0o644)

    service = service_name()
    bootout(service)
    result = subprocess.run(
        ["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(launch_agent)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    subprocess.run(["/bin/launchctl", "kickstart", service], check=True)
    print(f"Installed and started: {service}")


def uninstall() -> None:
    _, _, _, _, launch_agent = paths()
    bootout(service_name())
    if launch_agent.exists():
        launch_agent.unlink()
    print("LaunchAgent removed. Configuration, app bundle, and Keychain tokens were kept.")


def status() -> int:
    return subprocess.run(["/bin/launchctl", "print", service_name()], check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall", "status"))
    parser.add_argument("--project-dir", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args()
    if args.action == "install":
        install(Path(args.project_dir).resolve())
        return 0
    if args.action == "uninstall":
        uninstall()
        return 0
    return status()


if __name__ == "__main__":
    sys.exit(main())
