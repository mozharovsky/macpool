# Commands

This page lists the commands that prepare, boot, and clone VMs, the commands that list paired
Macs, and the scripts that reach a guest. The daemon's commands are in
[Leases and the daemon](leases.md), and `image xcode` is in [Xcode images](xcode-image.md).

`macpool --help` lists the commands, and `macpool help COMMAND` shows a command's options.
`macpool --version` prints the version. The examples keep images and bundles in the ignored
`.cache` directory.

## Bundles

A bundle is a directory that holds one VM. These are the files you'll meet.

| File | What it holds |
| --- | --- |
| `disk.img` | The guest's disk, a sparse file. |
| `settings.json` | CPUs, memory, MAC address, `has_booted`, and `credential_rotation`. |
| `guest-account.json` | The guest account's name and password, readable only by you. |
| `known_hosts` | The guest's pinned Ed25519 host key. |
| `lock` | The lock that a running command holds. |
| `stop-request` | Created by you to end a `run` early. |
| `image.json` | Whether an image passed its checks, and its builds. See [Xcode images](xcode-image.md). |

## fetch

`macpool fetch` finds the newest restore image that your Mac supports and prints its URL, build,
and version.

| Option | Default | What it does |
| --- | --- | --- |
| `--download` | off | Also downloads the image. |
| `--cache DIR` | `.cache/ipsw` | The directory that receives the image. |

The image lands in `DIR/BUILD.ipsw`. If the download breaks off, running the command again continues
it. `fetch` refuses to download over an image that's already there.

## create

`macpool create --ipsw FILE --bundle DIR` creates a bundle and installs macOS into it. The bundle
directory must not exist yet. If the install fails or you press Control-C, `create` deletes the
bundle.

| Option | Default | What it does |
| --- | --- | --- |
| `--ipsw FILE` | required | The restore image to install. |
| `--bundle DIR` | required | The new bundle. |
| `--cpus N` | 8 | Virtual CPUs. |
| `--memory-gb N` | 16 | Guest memory in gigabytes. |
| `--disk-gb N` | 128 | Disk size in gigabytes. The disk is sparse and can't grow later. |
| `--log-level LEVEL` | `warning` | Diagnostics on standard error. `info` shows each step. |

## run

`macpool run --bundle DIR` boots a bundle headless with NAT networking. It prints `ready` once the
guest has an address, and with `--wait-ssh` once SSH answers too.

| Option | Default | What it does |
| --- | --- | --- |
| `--bundle DIR` | required | The bundle to boot. |
| `--provision` | off | Creates the guest account on the first boot. |
| `--wait-ssh` | off | Waits for SSH before `ready`. |
| `--timeout SECONDS` | 900 | The longest wait for the address and SSH. On a clone's first run it also limits the credential replacement. |
| `--hold SECONDS` | 0 | How long the VM keeps running after `ready`. With 0, `run` starts to stop it right away. |
| `--share DIR` | none | Shares a host directory. The guest mounts it at `/Volumes/My Shared Files`. |
| `--share-read-only` | off | Lets the guest only read the shared directory. Needs `--share`. |
| `--log-level LEVEL` | `warning` | Diagnostics on standard error. |

The first `run` of a new bundle needs `--provision`. It creates the account in
`guest-account.json` with a random password. The guest applies the account only on its first boot
after the install. That's why `run` refuses a first boot without `--provision` and refuses
`--provision` on a bundle that has booted. It records the first boot as `has_booted`.

If you create the bundle's `stop-request` file, the hold ends early. If the file appears before
`ready`, `run` stops the VM and fails.

macOS answers the virtual power button with a dialog. When the hold ends or you ask for a stop,
`run` waits 90 seconds and then forces the stop. For a clean stop, use `Scripts/shutdown.sh`.
`run` reports a clean stop as `measure stop=guest` and a forced one as `measure stop=forced`.

## ip

`macpool ip --bundle DIR` prints the guest's address from the Mac's DHCP leases. It prints one only
while a command holds the bundle and the DHCP lease is current.

## clone

`macpool clone --from SOURCE --to DIR` copies a stopped bundle with APFS and gives the copy a new
machine identifier and MAC address. The target directory must not exist yet.

`clone` refuses a source that a command holds. It never copies a disk that a running guest writes
to. It also refuses a source whose credential replacement didn't finish.

A clone's first `run` always waits for SSH, because it replaces the inherited credentials over SSH.
Use the clone only after that `run` prints `ready`. See [Clone credentials](clone-credentials.md).

Here's a clone by hand. `run` keeps its terminal busy until the VM stops. Run the other commands
in a second terminal.

```sh
$macpool clone --from .cache/vms/base --to .cache/vms/job1
$macpool run --bundle .cache/vms/job1 --share "$PWD" --hold 600
Scripts/ssh.sh .cache/vms/job1 'ls "/Volumes/My Shared Files"'
Scripts/shutdown.sh .cache/vms/job1
```

`Scripts/shutdown.sh` returns before the guest stops. Wait until `run` exits, and then delete the
clone with `rm -rf .cache/vms/job1`.

## host list

`macpool host list` prints the Macs that paired with this Mac as clients. It reads
`trust/clients.json` in the data directory and needs no running daemon. Without paired clients it
prints `no paired clients`.

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory that holds the list. |
| `--json` | off | Prints the records as one JSON array. |

Each row shows when the client paired, whether this Mac blocks it, its priority ceiling, and its
name with its short key, such as `runner (mzxw-6ytb-oi2d-k3lq)`. Names aren't unique, so compare
the short key.

The other Mac chose its name. The table shows each control, format, line separator, and paragraph
separator character as an escape such as `\u{202E}`, and a backslash as two. It also puts the name
between the invisible isolates U+2068 and U+2069. Right-to-left letters then don't reorder the
columns. Scripts should read `--json`. It keeps the exact names and the full keys.

## pool list

`macpool pool list` prints the hosts that this Mac paired with. It reads `trust/hosts.json` in the
data directory and needs no running daemon. Without paired hosts it prints `no paired hosts`. It
takes the same `--data-dir` and `--json` options as `host list`.

Each row shows when this Mac paired, the host's address and port from the pairing code, and the
host's name with its short key. The host chose its name and its address. The table escapes and
isolates both like a client's name in `host list`.

## Scripts

`Scripts/ssh.sh BUNDLE [COMMAND]` runs a command in the guest over SSH, or opens a shell without
one. It logs in with the account in the bundle and ignores your own SSH configuration and agent.
Its first connection pins the guest's Ed25519 host key in the bundle's `known_hosts`. Later
connections refuse any other key.

`Scripts/shutdown.sh BUNDLE` shuts the guest down from inside. It gives `sudo` the account's
password on standard input, because the SSH session has no terminal.

If you write Swift, `GuestSession` in the `MacpoolVM` library runs commands in a guest. It logs in
as the bundle's account and accepts only the pinned host key. A clone pins its key on its first
run. A bundle from `create` has no pinned key until `Scripts/ssh.sh` connects once. A root command
goes through `sudo` with the password on standard input. If `sudo` runs without asking for a
password, the session stops the command before it starts.

## Output

Every command prints `measure key=value` lines with its timings and sizes on standard output. You
can collect them with `grep`. Addresses and progress lines go to standard output too. Diagnostics
go to standard error.
