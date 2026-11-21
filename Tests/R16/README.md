# Independent execution in selected directories (R16)

Run the probe as the login user on macOS 13 or later with the Xcode command line tools. Each run creates two private directory trees and an outside control. It compiles a fresh Mach-O and records whether each copy reaches its entry point.

```sh
/usr/bin/python3 -IB Tests/R16/run.py baseline
/usr/bin/python3 -IB Tests/R16/run.py package --output-dir /private/tmp
```

The second command prints the path to a diagnostic app bundle. For the live comparison, the bundle needs an Apple-authorized Endpoint Security profile for the Airlock standalone App ID, matching entitlements in its signature, and local Full Disk Access. Install the signed diagnostic build in an administrator-controlled directory. Set `AIRLOCK_TEAM_ID` to the expected team from your signing configuration. [Apple signing guide](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)

```sh
/usr/bin/python3 -IB Tests/R16/run.py compare --app "/Library/Application Support/Deus Airlock R16/ExecProbe.app" --report /private/tmp/r16-result.json
```

When the runner prints the private run directory, launch that bundle's `Contents/MacOS/ExecProbe` as root with the printed directory as its only argument. The runner checks the peer, requires two matching kernel denials and a successful outside control, then waits for the client to disconnect and exit. It retries the original files and tests a newly compiled image. A baseline report covers execution before registration only. Network isolation through the first packet requires separate packet measurements.
