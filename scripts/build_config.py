"""Resolve declarative local Apple build settings; never execute configuration."""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
MACOS_MINIMUM = "26.0"
DEFAULTS = {
    "apple_team_id": None,
    "mac_signing_identity": None,
    "ios_bundle_id": "guide.guidelabs.codexdrop",
    "mac_bundle_id": "guide.guidelabs.codexdrop.mac",
    "keychain_group_suffix": "guide.guidelabs.codexdrop.shared",
}

@dataclass(frozen=True)
class BuildConfig:
    apple_team_id: str
    mac_signing_identity: str | None
    ios_bundle_id: str
    mac_bundle_id: str
    keychain_group_suffix: str

    @property
    def ios_share_bundle_id(self):
        return self.ios_bundle_id + ".Share"


def add_config_arguments(parser):
    parser.add_argument("--config", type=Path, help="Local JSON settings (default: codex-drop.local.json)")
    for key in DEFAULTS:
        parser.add_argument("--" + key.replace("_", "-"), default=None)


def resolve_config(arguments=None, *, root=ROOT, environ=None):
    environ = os.environ if environ is None else environ
    overrides = vars(arguments) if isinstance(arguments, argparse.Namespace) else (arguments or {})
    explicit = overrides.get("config")
    path = Path(explicit) if explicit else root / "codex-drop.local.json"
    local = {}
    if path.exists():
        try:
            local = json.loads(path.read_text())
        except (ValueError, OSError) as error:
            raise ValueError(f"Cannot read JSON configuration {path}: {error}") from error
        if not isinstance(local, dict) or set(local) - DEFAULTS.keys():
            raise ValueError(f"Configuration must be an object using only: {', '.join(DEFAULTS)}")
    elif explicit:
        raise ValueError(f"Configuration does not exist: {path}")
    values = {}
    for key, default in DEFAULTS.items():
        value = overrides.get(key)
        if value is None:
            value = environ.get("CODEX_DROP_" + key.upper(), local.get(key, default))
        if value is not None and (not isinstance(value, str) or not value.strip()):
            raise ValueError(f"{key} must be a nonempty string")
        values[key] = value.strip() if isinstance(value, str) else value
    if not values["apple_team_id"]:
        raise ValueError("Set CODEX_DROP_APPLE_TEAM_ID, --apple-team-id, or apple_team_id in codex-drop.local.json to your Apple Developer Team ID")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["apple_team_id"]):
        raise ValueError("apple_team_id must be a 10-character Apple Developer Team ID")
    for key in ("ios_bundle_id", "mac_bundle_id", "keychain_group_suffix"):
        if not isinstance(values[key], str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", values[key]):
            raise ValueError(f"{key} must be a dotted identifier without build-setting syntax")
    return BuildConfig(**values)


def select_signing_identity(candidates, team, requested=None):
    """Candidates are (SHA-1, display name, certificate OU) valid identities."""
    eligible = {(fingerprint.upper(), name) for fingerprint, name, ou in candidates
                if ou == team and name.startswith("Apple Development:")}
    if requested:
        eligible = {(fingerprint, name) for fingerprint, name in eligible
                    if requested.upper() == fingerprint or requested == name}
    if not eligible:
        raise RuntimeError(f"No valid existing Apple Development identity for Team {team} matches the configuration")
    if len(eligible) != 1:
        raise RuntimeError(f"Multiple valid Apple Development identities for Team {team}; set CODEX_DROP_MAC_SIGNING_IDENTITY or --mac-signing-identity to one SHA-1 fingerprint")
    return next(iter(eligible))[0]


def ensure_destination_stopped(destination, process_listing):
    """Inspect ps executable/command text without splitting unquoted space paths.

    The receiver can outlive the launcher as an external Python executable whose
    argv names a bundled script. Match those exact paths too, with argument
    boundaries, and never expose full command lines in an error.
    """
    original = Path(destination).absolute()
    resolved = original.resolve()
    suffixes = (
        "Contents/MacOS/CodexDrop",
        "Contents/Resources/MacAttachmentReceiver",
        "Contents/Resources/ReceiverPairing",
        "Contents/Resources/receiver/lan_receiver.py",
        "Contents/Resources/receiver/mac_receiver.py",
    )
    # ps prints argv joined with spaces. Identify possible absolute-path starts
    # and exact known suffix ends, then resolve each intact path. This handles
    # spaces and aliases such as /var -> /private/var without guessing argv.
    endings = [(re.compile("/" + re.escape(suffix) + r"(?=$|[\s\"'])"), resolved / suffix)
               for suffix in suffixes]
    for line in process_listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        pid, command = fields
        starts = [match.end() for match in re.finditer(r"(?:^|[\s\"'])(?=/)", command)]
        for ending, expected in endings:
            for match in ending.finditer(command):
                for start in starts:
                    if start >= match.start():
                        continue
                    try:
                        matches = Path(command[start:match.end()]).resolve() == expected
                    except (OSError, ValueError):
                        matches = False
                    if matches:
                        raise RuntimeError(f"Destination app or receiver is running (PID {pid}); quit it before replacing {resolved}")


def verify_macos_minimum(load_commands, expected=MACOS_MINIMUM):
    """Check every architecture's Mach-O deployment command, including old form."""
    versions = []
    command = None
    for line in load_commands.splitlines():
        fields = line.strip().split()
        if fields[:1] == ["cmd"] and len(fields) > 1:
            command = fields[1]
        elif len(fields) == 2 and ((command == "LC_BUILD_VERSION" and fields[0] == "minos") or
                                  (command == "LC_VERSION_MIN_MACOSX" and fields[0] == "version")):
            versions.append(fields[1])
    def normalized(value):
        pieces = value.split(".")
        return tuple(int(piece) for piece in pieces) + (0,) * (3 - len(pieces))
    if not versions or any(normalized(version) != normalized(expected) for version in versions):
        raise RuntimeError(f"Mach-O minimum macOS versions {versions} do not agree with {expected}")
