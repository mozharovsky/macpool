# macpool agent instructions

This file is the single source of instructions for people and coding agents who change the
repository. `CLAUDE.md` contains only `@AGENTS.md`, which Claude Code resolves as an import.

## Project map

The root Swift package has three products. The `MacpoolVM` library owns VM operations, which are
bundles, restore images, installation, provisioning, cloning, the rotation of a clone's guest
credentials, the VM actor, DHCP lease lookup, and the SSH probe. The `MacpoolPool` library owns
the pool daemon, its lease ledger and queue, the stored state, the socket protocol, and the
supervisor processes that keep leased VMs running. The `macpool` executable in
`Sources/MacpoolCLI` parses arguments, runs host tools, and prints measurements. It holds no VM or
pool logic that a library user would need.

The lease ledger in `MacpoolPool` is a value type without I/O. It returns the actions that the
daemon actor performs, so its tests cover the queue, expiries, and restarts without sockets or
processes.

`Tests/MacpoolVMTests`, `Tests/MacpoolPoolTests`, and `Tests/MacpoolCLITests` hold focused
swift-testing suites. `Scripts`
holds the build, signing, SSH, license, and hook scripts. `macpool.entitlements` carries the
virtualization entitlement that `Scripts/build.sh` signs into the binary.

## Toolchain

The repository pins Xcode 27.0 in `.xcode-version`. Select it for each command with
`DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer` and invoke Swift through
`xcrun swift`. Bare `swift` can resolve another installed toolchain. Never change the machine's
global Xcode selection.

## Checks

Run these checks before every commit that touches their scope.

```sh
Scripts/check-licenses.sh
xcrun swift package plugin --allow-writing-to-package-directory swiftformat --lint --cache ignore
xcrun swift package plugin --allow-writing-to-package-directory swiftlint --strict
xcrun swift build --build-tests
xcrun swift test
Scripts/build.sh
mkdir -p .build/docs
xcrun swift package --allow-writing-to-directory .build/docs generate-documentation \
    --target MacpoolVM --warnings-as-errors --output-path .build/docs/MacpoolVM
xcrun swift package --allow-writing-to-directory .build/docs generate-documentation \
    --target MacpoolPool --warnings-as-errors --output-path .build/docs/MacpoolPool
xcrun swift package --allow-writing-to-directory .build/docs generate-documentation \
    --target MacpoolCLI --warnings-as-errors --output-path .build/docs/MacpoolCLI
```

`Scripts/install-hooks.sh` installs a pre-commit hook for formatting and lint and a commit-msg
hook for the subject form. Run the formatter without `--lint` to rewrite files.

The GitHub workflow runs the same checks on hosted macOS runners. Those runners are VMs
themselves and cannot start VMs.

## VM checks

Changes to VM behavior also need a run on a Mac that can start VMs. Build with `Scripts/build.sh`
and set `MACPOOL_VM_TEST_BUNDLE` to a stopped, provisioned bundle before `xcrun swift test`. The
VM suite clones that bundle, boots the clone to SSH, stops it, and deletes it. A plain
`xcrun swift test` skips the suite.

macOS allows two VMs per host. Never run more than two at once, and stop every VM you start. The
framework enforces the limit, and `run` and `create` report it when a VM cannot start.

Changes to the daemon or the supervisors also need a run with real VMs. Start
`macpool daemon --data-dir DIR` in the foreground with a directory under `.cache`, lease from a
stopped bundle, and check the queue, release, expiry, and a restart of the daemon and of a
supervisor. Do not install the launchd job for such a check. An installed daemon does not count
the test daemon's VMs, and its VMs keep running when it stops. Release its leases first, or give
the test daemon `--slots` that fit beside its VMs. Release every lease and stop the daemon
afterward.

## Swift standards

Use the Swift 6 language mode with complete concurrency checking and warnings as errors.
`Package.swift` sets these for every target together with the upcoming features that keep imports
explicit and keep nonisolated async calls on the caller's actor.

Do not force unwrap, force cast, use `try!`, declare an implicitly unwrapped optional, or use
`unowned`. State an invariant with `guard` and a typed error. Use typed throws when the package
owns the error set. `MacpoolError` is the library's error set and `CommandError` is the command
line's.

Every Virtualization object that belongs to a VM lives inside the `VirtualMachine` actor, whose
executor is the VM's serial queue. Add new framework calls as actor methods so that the compiler
checks the queue. Use the framework's async methods where it declares them. A method that the
framework refines for Swift with a `Result` callback goes through a checked continuation inside
the actor.

Do not write `@unchecked Sendable` or `nonisolated(unsafe)`. SwiftLint rejects both. A framework
type that forces one needs a comment that names the type and the reason, and the lint rule needs an
explicit exception in the same change. The repository has no such exception today.

Use named structs or enums for stored records and multi-field results. Tuples stay for brief local
grouping and for signatures that a framework defines.

Write an access modifier only when it changes Swift's default. Never write `internal`.

## Documentation

Document every declaration at every access level. SwiftLint's `missing_docs` rule enforces the
presence of a comment. The review checks its meaning.

A summary states the declaration's purpose with a noun phrase for a type or property and a verb
phrase for a method. Add details that a caller needs, such as units, bounds, sentinel values,
failure conditions, and lifetime rules. Returning functions document Returns, and throwing
functions document Throws with their failure conditions. A Parameters section covers every
parameter.

Each module has a DocC catalog. DocC builds with warnings as errors.

The README covers only what macpool is, its requirements, setup, commands, and a short list of
current limitations. Each limitation takes one or two plain sentences. History and rationale
belong in the code's documentation and in pull requests.

## Dependencies

Use an existing Swift implementation from the approved set when it provides the behavior. Each
dependency has one role.

- swift-argument-parser parses the command line.
- swift-subprocess runs host tools such as `curl`, `pgrep`, `renice`, `ssh`, and `launchctl`,
  and starts the daemon's supervisor processes.
- swift-log carries the library's VM lifecycle and event diagnostics. The command line chooses
  their level and writes them to standard error.
- swift-certificates builds the self-signed X.509 certificates that carry a Mac's P-256 key in
  TLS, because the SDK parses certificates but cannot build them. Network, Security, and CryptoKit
  still run TLS, hold the keys, and sign.
- swift-asn1 serializes those certificates to DER.
- swift-crypto arrives with swift-certificates. macpool does not import it, and `Package.resolved`
  pins its version. Its BoringSSL code enters the release binary.
- swift-docc-plugin builds the documentation.
- SwiftFormat formats the code as a command plugin.
- SwiftLint lints the code as a command plugin through its plugin package.

A dependency outside this set arrives in its own pull request. The description states why the set
cannot meet the need and records the new dependency's role here.

`Scripts/check-licenses.sh` reads the license of every resolved package and binary artifact, and
the licenses that a package's NOTICE file names for the code it embeds. MIT, BSD, ISC, and Apache
2.0 pass. GPL, LGPL, AGPL, the Functional Source License, and unrecognized licenses fail.

## Clean room

Design from Apple's documentation, the SDK headers, and the Swift interfaces in the SDK. Never read
or copy the source of other VM managers. [CONTRIBUTING.md](CONTRIBUTING.md) states the rule in
full.

## Prose

Write plain prose for a busy reader. Use short declarative sentences with one idea each. Use
paragraphs by default and lists only for content that is a list. Avoid em dashes, semicolons,
filler, rhetorical questions, and exclamation marks. Documentation describes current behavior.
Inline comments explain why a choice exists.

## Commits and pull requests

Commit subjects follow `type(scope): summary` with an optional scope. Types are `feat`, `fix`,
`docs`, `refactor`, `test`, `perf`, `ci`, `build`, and `chore`. Scopes are `vm`, `pool`, `cli`,
`tools`, `docs`, and `ci`. Subjects stay under 72 characters. Bodies explain why.

Pull request descriptions follow `.github/PULL_REQUEST_TEMPLATE.md`. They state the change, the
checks that ran with their results, the checks that did not run, and the known limitations.

## Never do

- Never commit restore images, VM bundles, guest passwords, or anything under `.cache`.
- Never loosen a lint rule to make a change pass.
- Never add telemetry or analytics.
- Never start more VMs than macOS allows on one host.
