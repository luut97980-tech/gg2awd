#!/usr/bin/env python3
"""Release consistency check for the VTMenu iOS source drop.

Verifies the pieces that drift silently between releases: the manifest revision
written by build_dylib.sh, the artifact the workflow uploads, and the guard
constants the IPA patcher will accept. Does not touch the game, the dylib or
any Apple toolchain, so it runs on Windows too.
"""
import json
import pathlib
import re
import sys

REMOTE_ACTIONS = {"actions/checkout": "v5", "actions/upload-artifact": "v5"}


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check_revision(root):
    analysis = load_json(root / "analysis" / "ios_build.json")
    if analysis.get("menu_revision") != 5:
        raise SystemExit("analysis/ios_build.json: menu_revision must be 5")
    if analysis.get("features") != ["esp", "spam_jump"]:
        raise SystemExit("analysis/ios_build.json: features must be esp + spam_jump")

    build = (root / "build_dylib.sh").read_text(encoding="utf-8")
    if "meta['menu_revision']=5" not in build:
        raise SystemExit("build_dylib.sh: menu_revision=5 marker missing")
    if "meta['features']=['esp','spam_jump']" not in build:
        raise SystemExit("build_dylib.sh: features marker missing")

    patcher = (root / "tao_ipa_menu.py").read_text(encoding="utf-8")
    if "meta.get('menu_revision')==5" not in patcher:
        raise SystemExit("tao_ipa_menu.py: revision gate missing")


def check_workflow(root):
    workflow = (root / ".github" / "workflows" / "build-ios.yml").read_text(encoding="utf-8")
    for action, version in REMOTE_ACTIONS.items():
        if f"{action}@{version}" not in workflow:
            raise SystemExit(f"workflow: {action} must be pinned to {version} (Node 24)")
    for match in re.finditer(r"uses:\s*(\S+)", workflow):
        ref = match.group(1)
        if "@v4" in ref or "@v3" in ref:
            raise SystemExit(f"workflow: {ref} still targets a deprecated Node runtime")
    if "build_dylib.sh" not in workflow or "VTMenu-iOS-ESP-Spam-R5" not in workflow:
        raise SystemExit("workflow: build or artifact step missing")


def check_guard_constants(root):
    guard = (root / "src" / "ios_build_guard.hpp").read_text(encoding="utf-8")
    entries = re.findall(r"\{\s*0x[0-9a-fA-F]+,\s*\{", guard)
    if len(entries) != 7:
        raise SystemExit(f"ios_build_guard.hpp: expected 7 method guards, found {len(entries)}")
    if "1c1d8aea78c838f89a09d62cc639465d" not in guard:
        raise SystemExit("ios_build_guard.hpp: framework UUID changed")

    metadata = (root / "src" / "app_metadata.hpp").read_text(encoding="utf-8")
    for bundle in ("com.vng.playtogether", "ptg.vng"):
        if bundle not in metadata:
            raise SystemExit(f"app_metadata.hpp: accepted bundle missing: {bundle}")

    patcher = (root / "tao_ipa_menu.py").read_text(encoding="utf-8")
    metadata_sha = "ddefd97ac49d5431d25757e409e4c03973c79f553c025b931da00949867cc5fb"
    if metadata_sha not in patcher:
        raise SystemExit("tao_ipa_menu.py: metadata hash changed")


def check_login_hardening(root):
    plugin = (root / "src" / "Plugin.mm").read_text(encoding="utf-8")
    for marker in ('VTDefaultAttachDelay', 'attach_delay_s', 'attach_mode', '"safe"', 'VTAttachModeSubview'):
        if marker not in plugin:
            raise SystemExit(f"Plugin.mm: login hardening marker missing: {marker}")
    if 'windowLevel=UIWindowLevelAlert+100' not in plugin:
        raise SystemExit("Plugin.mm: overlay window path removed by accident")
    if '[game addSubview:VTController.view]' not in plugin:
        raise SystemExit("Plugin.mm: subview attach path missing")


def check_login_probe(root):
    probe = (root / "src" / "login_probe.mm").read_text(encoding="utf-8")
    for marker in ("NSURLProtocol", "installLoginProbe", "login.log", "noprobe"):
        if marker not in probe:
            raise SystemExit(f"login_probe.mm: probe marker missing: {marker}")
    plugin = (root / "src" / "Plugin.mm").read_text(encoding="utf-8")
    if "vt::installLoginProbe()" not in plugin:
        raise SystemExit("Plugin.mm: login probe is not installed")
    cmake = (root / "CMakeLists.txt").read_text(encoding="utf-8")
    for source in ("src/debug_log.mm", "src/login_probe.mm"):
        if source not in cmake:
            raise SystemExit(f"CMakeLists.txt: {source} missing from the VTMenu target")


def check_injection_modes(root):
    patcher = (root / "tao_ipa_menu.py").read_text(encoding="utf-8")
    for marker in ("FRAMEWORK_INSTALL_NAME", "'unityframework'", "0x100000c"):
        if marker not in patcher:
            raise SystemExit(f"tao_ipa_menu.py: injection mode marker missing: {marker}")
    if "add_library(source.read(framework),install_name,6)" not in patcher:
        raise SystemExit("tao_ipa_menu.py: framework injection path missing")


def check_log_viewer(root):
    menu = (root / "src" / "mobile_menu.cpp").read_text(encoding="utf-8")
    for marker in ("logView", "login.log", "Sao chép log", "Quay lại"):
        if marker not in menu:
            raise SystemExit(f"mobile_menu.cpp: on-device log viewer marker missing: {marker}")
    plugin = (root / "src" / "Plugin.mm").read_text(encoding="utf-8")
    for marker in ("refreshLog", "copyLog", "UIPasteboard"):
        if marker not in plugin:
            raise SystemExit(f"Plugin.mm: log reader marker missing: {marker}")


def check_json(root):
    for name in ("VALIDATION.json", "DEPENDENCIES.json", "analysis/ios_build.json"):
        load_json(root / name)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    check_revision(root)
    check_workflow(root)
    check_guard_constants(root)
    check_login_hardening(root)
    check_login_probe(root)
    check_injection_modes(root)
    check_log_viewer(root)
    check_json(root)
    print("release check OK: revision 5, 7 guards, 2 bundles, actions v5, login probe, dual injection, log viewer, JSON valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
