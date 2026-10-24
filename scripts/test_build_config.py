import argparse
import json
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
from build_config import (ROOT, MACOS_MINIMUM, resolve_config, select_signing_identity,
                          ensure_destination_stopped, verify_macos_minimum)

TEAM = "ABCDEFGHIJ"
OTHER = "ZYXWVUTSRQ"

class BuildConfigurationTests(unittest.TestCase):
    def test_missing_team_explains_all_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "CODEX_DROP_APPLE_TEAM_ID.*--apple-team-id.*codex-drop.local.json"):
                resolve_config(root=Path(directory), environ={})

    def test_precedence_cli_environment_local_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "codex-drop.local.json").write_text(json.dumps({"apple_team_id": TEAM, "ios_bundle_id": "local.example.app"}))
            env = {"CODEX_DROP_APPLE_TEAM_ID": OTHER, "CODEX_DROP_IOS_BUNDLE_ID": "env.example.app"}
            config = resolve_config(argparse.Namespace(apple_team_id=TEAM), root=root, environ=env)
            self.assertEqual(config.apple_team_id, TEAM)
            self.assertEqual(config.ios_bundle_id, "env.example.app")
            self.assertEqual(config.mac_bundle_id, "guide.guidelabs.codexdrop.mac")
            self.assertEqual(resolve_config(root=root, environ={}).ios_bundle_id, "local.example.app")

    def test_explicit_config_and_invalid_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "custom.json"
            path.write_text(json.dumps({"apple_team_id": TEAM}))
            self.assertEqual(resolve_config({"config": path}, environ={}).apple_team_id, TEAM)
            for value in ("[]", '{"shell": "echo unsafe"}', '{"apple_team_id": "bad"}', '{"apple_team_id": "ABCDEFGHIJ", "ios_bundle_id": null}'):
                path.write_text(value)
                with self.assertRaises(ValueError):
                    resolve_config({"config": path}, environ={})
            path.unlink()
            with self.assertRaisesRegex(ValueError, "does not exist"):
                resolve_config({"config": path}, environ={})

    def test_coupled_ids_and_entitlements_preserve_xcode_prefix(self):
        config = resolve_config({"apple_team_id": TEAM, "ios_bundle_id": "example.custom.drop"}, environ={})
        self.assertEqual(config.ios_share_bundle_id, "example.custom.drop.Share")
        project = (ROOT / "iphone/project.yml").read_text()
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: $(CODEX_DROP_IOS_BUNDLE_ID)\n", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: $(CODEX_DROP_IOS_BUNDLE_ID).Share\n", project)
        for target in ("App", "Share"):
            info = plistlib.loads((ROOT / f"iphone/{target}/Info.plist").read_bytes())
            entitlements = plistlib.loads((ROOT / f"iphone/{target}/CodexShot.entitlements").read_bytes())
            self.assertIn("$(AppIdentifierPrefix)$(CODEX_DROP_KEYCHAIN_GROUP_SUFFIX)", info.values())
            self.assertEqual(entitlements["keychain-access-groups"], ["$(AppIdentifierPrefix)$(CODEX_DROP_KEYCHAIN_GROUP_SUFFIX)"])

    def test_signing_requires_unique_valid_identity_for_explicit_team(self):
        first = ("A" * 40, "Apple Development: One", TEAM)
        second = ("B" * 40, "Apple Development: Two", TEAM)
        unrelated = ("C" * 40, "Apple Development: Other", OTHER)
        self.assertEqual(select_signing_identity([first, unrelated], TEAM), first[0])
        self.assertEqual(select_signing_identity([first, second], TEAM, second[0].lower()), second[0])
        self.assertEqual(select_signing_identity([first, second], TEAM, second[1]), second[0])
        with self.assertRaisesRegex(RuntimeError, "Multiple"):
            select_signing_identity([first, second], TEAM)
        for candidates, requested in (([unrelated], None), ([first], unrelated[0]), ([("D" * 40, "Developer ID Application: One", TEAM)], None)):
            with self.assertRaisesRegex(RuntimeError, "No valid existing"):
                select_signing_identity(candidates, TEAM, requested)

    def test_running_destination_and_nested_helpers_cannot_be_replaced(self):
        destination = Path("/tmp/Codex Drop.app")
        for suffix in ("Contents/MacOS/CodexDrop", "Contents/Resources/MacAttachmentReceiver", "Contents/Resources/ReceiverPairing"):
            with self.assertRaisesRegex(RuntimeError, "PID 42"):
                ensure_destination_stopped(destination, f" 42 {destination}/{suffix}\n")
        ensure_destination_stopped(destination, "42 /tmp/Codex Drop.app.other/Contents/MacOS/CodexDrop\n43 /tmp/other")
        with tempfile.TemporaryDirectory() as directory:
            alias = Path(directory) / "alias.app"
            alias.symlink_to(destination)
            with self.assertRaises(RuntimeError):
                ensure_destination_stopped(alias, f"42 {destination}/Contents/MacOS/CodexDrop")

    def test_orphan_python_running_bundled_receiver_blocks_replacement(self):
        destination = Path("/tmp/Codex Drop.app")
        for script in ("lan_receiver.py", "mac_receiver.py"):
            path = destination / "Contents/Resources/receiver" / script
            # ps joins argv without quoting paths that contain spaces. Keep the
            # complete command intact rather than guessing argv with shlex.
            for command in (f"/usr/local/bin/python3 {path} --token PRIVATE_VALUE",
                            f'/usr/local/bin/python3 "{path}" --data-dir /tmp/private state'):
                with self.assertRaisesRegex(RuntimeError, "PID 81") as caught:
                    ensure_destination_stopped(destination, f" 81 /usr/local/bin/python3 {command}\n")
                self.assertNotIn("PRIVATE_VALUE", str(caught.exception))
                self.assertNotIn("--data-dir", str(caught.exception))

    def test_unrelated_similar_destination_or_script_does_not_block(self):
        destination = Path("/tmp/Codex Drop.app")
        commands = [
            "/usr/local/bin/python3 /tmp/Codex Drop.app.other/Contents/Resources/receiver/lan_receiver.py",
            "/usr/local/bin/python3 /tmp/Codex Drop.app Copy/Contents/Resources/receiver/mac_receiver.py",
            "/usr/local/bin/python3 /unrelated/tmp/Codex Drop.app/Contents/Resources/receiver/lan_receiver.py",
            "/usr/local/bin/python3 /tmp/Codex Drop.app/Contents/Resources/receiver/lan_receiver.py.backup",
        ]
        for command in commands:
            ensure_destination_stopped(destination, "81 " + command)

    def test_builder_checks_destination_before_signing_or_compiling(self):
        spec = importlib.util.spec_from_file_location("mac_builder", ROOT / "scripts/build-mac-app.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "Codex Drop.app"
            listing = subprocess.CompletedProcess([], 0, f"42 /usr/local/bin/python3 /usr/local/bin/python3 {destination}/Contents/Resources/receiver/lan_receiver.py --data-dir /tmp/private\n", "")
            with patch.object(sys, "argv", ["build-mac-app.py", "--apple-team-id", TEAM, "--output", str(destination)]), \
                 patch.object(builder, "run", return_value=listing) as run, \
                 patch.object(builder, "signing_identity", side_effect=AssertionError("must not access signing")):
                with self.assertRaisesRegex(RuntimeError, "PID 42"):
                    builder.main()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0], "/bin/ps")
                self.assertIn("command=", run.call_args.args[0][-1])

    def test_all_macho_architectures_must_match_advertised_minimum(self):
        good = "cmd LC_BUILD_VERSION\n platform 1\n minos 26.0\n sdk 26.1\n"
        verify_macos_minimum(good)
        verify_macos_minimum(good + "cmd LC_VERSION_MIN_MACOSX\n version 26.0.0\n")
        for commands in ("", good.replace("26.0", "14.0"), good + good.replace("26.0", "27.0")):
            with self.assertRaisesRegex(RuntimeError, "do not agree"):
                verify_macos_minimum(commands)
        info = plistlib.loads((ROOT / "macos/Info.plist").read_bytes())
        self.assertEqual(info["LSMinimumSystemVersion"], MACOS_MINIMUM)

if __name__ == "__main__":
    unittest.main()
