# Contributing to macpool

Thank you for helping. This guide covers the clean-room rule, local setup, and how changes land.
[AGENTS.md](AGENTS.md) holds the full engineering standards and the list of checks.

## Clean room

macpool is original work built from Apple's public material. Contributors and coding agents design
and write it only from these sources.

- Apple's documentation for Virtualization and the other system frameworks.
- The headers and Swift interfaces in the macOS SDK.
- Apple's published sample code, within its license.
- General knowledge of macOS, networking, and Swift.

Do not read, copy, translate, or paraphrase the source code of other VM managers, VM runners, or
their libraries while you work on macpool. Do not paste their code or their issue discussions into
a prompt for a coding agent. If you studied such code in depth, tell us in the pull request so that
someone else can write the affected part.

Behavior that users of other tools expect, such as a command name or a file layout, may match when
it follows from Apple's APIs or from common practice. The implementation still comes from the
sources above.

## Setup

You need a Mac with Apple silicon, macOS 27, and Xcode 27.0. Select Xcode through
`DEVELOPER_DIR` and leave the global selection unchanged.

```sh
export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
Scripts/install-hooks.sh
xcrun swift build --build-tests
xcrun swift test
```

The hooks check formatting, lint rules, and the commit subject. Format files in place with
`xcrun swift package plugin --allow-writing-to-package-directory swiftformat --cache ignore`.

## Making a change

Keep each pull request to one concern. Run the checks from [AGENTS.md](AGENTS.md) that cover your
change. A change to VM behavior also needs the opt-in VM suite on a Mac that can start VMs, and the
description says whether it ran.

Commit subjects follow Conventional Commits in the form `type(scope): summary`. The commit-msg hook
lists the accepted types and scopes. The body explains why the change is needed.

A new dependency needs its own pull request that explains why the approved set cannot meet the
need. Its license must pass `Scripts/check-licenses.sh`.

## Reporting problems

Open an issue with the macOS versions of the host and the guest, the command, and its output. The
`measure` lines and any framework error with its domain and code help most. Remove guest passwords
and addresses that you do not want to share.

## License

By contributing, you agree that your contributions are licensed under the MIT license in
[LICENSE](LICENSE).
