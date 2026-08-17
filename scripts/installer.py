#!/usr/bin/env python3
"""Build and manage the Sub2API Menu Bar LaunchAgent."""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional


LABEL = "io.github.huangsw666.sub2api-menubar"
APP_NAME = "Sub2API Menu Bar.app"
VERSION = "0.1.2"


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


def write_info_plist(bundle: Path) -> None:
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
                "CFBundleVersion": "3",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            },
            handle,
            sort_keys=True,
        )


def compile_executable(source: Path, executable: Path, target: Optional[str] = None) -> None:
    command = [
        "/usr/bin/xcrun",
        "--sdk",
        "macosx",
        "swiftc",
        "-swift-version",
        "5",
    ]
    if target:
        command.extend(["-target", target])
    command.extend(
        [
            "-O",
            str(source),
            "-framework",
            "AppKit",
            "-framework",
            "WebKit",
            "-framework",
            "Security",
            "-o",
            str(executable),
        ]
    )
    subprocess.run(command, check=True)
    executable.chmod(0o700)


def migrate_legacy_config(config: Path) -> bool:
    legacy_path = Path.home() / "Library" / "Application Support" / "MacAIMonitor" / "config.json"
    if config.exists() or not legacy_path.exists():
        return False

    legacy = json.loads(legacy_path.read_text())
    sub2api = legacy.get("sub2api", {})
    old_upstream = legacy.get("callai", {})
    account_name = legacy.get("account_name")
    upstreams = []
    if old_upstream.get("base_url") and account_name:
        upstreams.append(
            {
                "name": old_upstream.get("name", account_name),
                "account_names": [account_name],
                "base_url": old_upstream["base_url"],
                "login_path": old_upstream.get("login_path", "/login"),
                "key_name": account_name,
                "channel_group": legacy.get("channel_group"),
            }
        )

    migrated = {
        "sub2api_base_url": sub2api.get("base_url", "https://sub2api.example.com"),
        "sub2api_login_path": sub2api.get("login_path", "/login"),
        "tracked_user_id": legacy.get("user_id"),
        "tracked_api_key_id": legacy.get("api_key_id"),
        "tracked_group": legacy.get("account_group"),
        "upstreams": upstreams,
        "usage_interval_seconds": legacy.get("usage_interval_seconds", 10),
        "channel_interval_seconds": legacy.get("channel_interval_seconds", 30),
        "balance_interval_seconds": legacy.get("balance_interval_seconds", 60),
        "http_timeout_seconds": legacy.get("http_timeout_seconds", 8),
    }
    config.parent.mkdir(parents=True, exist_ok=True)
    temporary = config.with_suffix(".json.new")
    temporary.write_text(json.dumps(migrated, ensure_ascii=False, indent=2) + "\n")
    temporary.chmod(0o600)
    os.replace(temporary, config)
    print(f"Migrated legacy configuration: {config}")
    return True


def install(project_dir: Path, prebuilt_app: Optional[Path], migrate_legacy: bool) -> None:
    support_dir, bundle, executable, config, launch_agent = paths()
    executable.parent.mkdir(parents=True, exist_ok=True)
    launch_agent.parent.mkdir(parents=True, exist_ok=True)

    if migrate_legacy:
        migrate_legacy_config(config)
    example = project_dir / "config.example.json"
    if not config.exists():
        shutil.copyfile(example, config)
        config.chmod(0o600)
        print(f"Created configuration: {config}")
        print("Edit sub2api_base_url before logging in.")

    if prebuilt_app:
        if not (prebuilt_app / "Contents" / "MacOS" / "Sub2APIMenuBar").is_file():
            raise RuntimeError(f"Invalid prebuilt app: {prebuilt_app}")
        shutil.copytree(prebuilt_app, bundle, dirs_exist_ok=True)
        subprocess.run(
            ["/usr/bin/xattr", "-dr", "com.apple.quarantine", str(bundle)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        executable.chmod(0o700)
    else:
        compile_executable(project_dir / "Sources" / "Sub2APIMenuBar.swift", executable)
        write_info_plist(bundle)

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


def package(project_dir: Path, output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"sub2api-menubar-v{VERSION}-macos-universal.zip"
    if archive.exists():
        archive.unlink()

    with tempfile.TemporaryDirectory(prefix="sub2api-menubar-") as temporary:
        root = Path(temporary) / f"Sub2API Menu Bar v{VERSION}"
        bundle = root / APP_NAME
        executable = bundle / "Contents" / "MacOS" / "Sub2APIMenuBar"
        executable.parent.mkdir(parents=True)

        arm_binary = Path(temporary) / "Sub2APIMenuBar-arm64"
        intel_binary = Path(temporary) / "Sub2APIMenuBar-x86_64"
        source = project_dir / "Sources" / "Sub2APIMenuBar.swift"
        compile_executable(source, arm_binary, "arm64-apple-macos13")
        compile_executable(source, intel_binary, "x86_64-apple-macos13")
        subprocess.run(
            ["/usr/bin/lipo", "-create", str(arm_binary), str(intel_binary), "-output", str(executable)],
            check=True,
        )
        executable.chmod(0o700)
        write_info_plist(bundle)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)

        shutil.copy2(project_dir / "config.example.json", root / "config.example.json")
        shutil.copy2(project_dir / "scripts" / "installer.py", root / "installer.py")
        shutil.copy2(project_dir / "distribution" / "install.command", root / "install.command")
        shutil.copy2(project_dir / "distribution" / "uninstall.command", root / "uninstall.command")
        shutil.copy2(project_dir / "distribution" / "README.txt", root / "README.txt")
        for script in [root / "installer.py", root / "install.command", root / "uninstall.command"]:
            script.chmod(0o755)

        subprocess.run(
            ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(root), str(archive)],
            check=True,
        )
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    checksum.write_text(f"{digest}  {archive.name}\n")
    print(archive)
    print(checksum)
    return archive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall", "status", "package"))
    parser.add_argument("--project-dir", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--prebuilt-app")
    parser.add_argument("--migrate-legacy", action="store_true")
    parser.add_argument("--output-dir", default="dist")
    args = parser.parse_args()
    project_dir = Path(args.project_dir).resolve()
    if args.action == "install":
        prebuilt_app = Path(args.prebuilt_app).resolve() if args.prebuilt_app else None
        install(project_dir, prebuilt_app, args.migrate_legacy)
        return 0
    if args.action == "uninstall":
        uninstall()
        return 0
    if args.action == "status":
        return status()
    package(project_dir, Path(args.output_dir).resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
