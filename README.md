# Royal GTPS Setup

A native macOS installer for macOS 13 Ventura or later. Both the app and its administrator helper are universal binaries for Apple silicon and Intel. The ZIP uses ad hoc signing and is unnotarized. Players need neither developer tools nor a developer account.

## Build

Use a Mac with Apple's free Xcode or Command Line Tools and a macOS SDK that supports the macOS 13 deployment target.

```sh
./test.sh
./build.sh
```

This creates `dist/Royal GTPS Setup.zip` with Install disabled. The archive contains the app and a short first-launch guide. If Gatekeeper blocks first launch, players who trust the source of their ZIP can open System Settings → Privacy & Security → Security → Open Anyway, then confirm. Managed Macs may restrict this option. [Apple's first-launch guide](https://support.apple.com/en-us/102445)

## Enable installation

Obtain the SHA-256 fingerprint of the DER-encoded certificate from the certificate owner through an independent trusted channel. Then download the certificate from the [Royal GTPS certificate link](https://gtps.link/downloads/gtps-hosts-ca.crt?v=7318563622b6). The link currently redirects to a MediaFire download page. Save the actual DER or PEM certificate file and build with:

```sh
./build.sh --fingerprint '<independently confirmed SHA-256>' --certificate '/path/to/gtps-hosts-ca.crt'
```

If the link serves the certificate directly, omitting `--certificate` makes the build fetch it over HTTPS. The build and privileged installer both require the pinned SHA-256 digest and the display name `GTPS Hosts Private CA 49415744`. Fingerprints with or without colons are accepted. Distribute the newly built ZIP after the isolated test below.

## Recovery behavior

The app requests approval for SSL server trust from the logged-in window, where macOS can present its own authorization dialog. It uses a separate administrator helper for System keychain items and hosts file writes. The helper verifies trust before changing hosts entries and stores its recovery journal under `/var/db/com.royalgtps.setup`. The journal records original hosts contents and whether the certificate or its SSL trust was already present. Existing matching SSL trust is left in place. If the same certificate has other explicit administrator trust settings, installation stops for manual review.

Undo restores the original hosts file byte for byte when its contents still match the installed version. If there have been later unrelated edits, it restores the old target mappings while retaining those edits. Restored aliases may appear on separate lines. If a target mapping or the app's SSL trust has since been changed, the corresponding step reports a conflict and retains recovery data. Other recoverable steps are still attempted. Use **Return to Original Growtopia** after an interrupted install before retrying.

## Verification

`./test.sh` exercises the hosts transformation and rollback with fixtures, including old IPv4 and IPv6 mappings, shared aliases, later edits, conflicting target changes, mixed whitespace, and a missing final newline. It uses no system files.

For an end-to-end test, use an isolated macOS VM or a dedicated test Mac. Start from a snapshot, record the hosts and trust state, and test the enabled ZIP through Finder. Check that Growtopia blocks setup while running, that a successful install sets administrator SSL trust for the pinned certificate and resolves both hosts to `15.235.167.45`, and that a repeat install retains the original recovery state. Add an unrelated hosts entry, relaunch, and select **Return to Original Growtopia**. Compare the resulting mappings and certificate trust to the initial state, and check that the unrelated entry remains. Test a failed hosts write in a separate snapshot to verify that certificate changes roll back.
