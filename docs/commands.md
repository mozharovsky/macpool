# Commands

This page lists the commands that prepare, boot, and clone VMs, the commands that pair Macs, and
the scripts that reach a guest. The daemon's commands are in
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
| `--share DIR` | none | Shares a host directory. The guest mounts it at `/Volumes/My Shared Files`. It can't be, contain, or lie inside the default data directory, or contain the bundle. Without `--share-read-only` it can't contain the `macpool` executable. |
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
$macpool run --bundle .cache/vms/job1 --share "$PWD/Sources" --hold 600
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

Each row shows when the client paired, whether this Mac blocks it, its priority ceiling, its short
key, such as `mzxw-6ytb-oi2d-k3lq`, and its name. Names aren't unique, so compare the short key in
the `KEY` column. A name can contain text that looks like a short key.

The other Mac chose its name. The table shows each character that pairing refuses in a name as an
escape such as `\u{202E}`, and a backslash as two. These are control and format characters, line
and paragraph separators, private-use and unassigned characters, and invisible characters such as
variation selectors. The table also puts the name between the invisible isolates U+2068 and U+2069.
Right-to-left letters then don't reorder the columns.

`--json` keeps the exact names and the full keys. It writes the same characters as JSON escapes
such as `\u202E`. A JSON parser reads them back as the original text.

## host invite

`macpool host invite` prints a code that lets one Mac pair with this Mac, and then waits until a Mac
pairs. The daemon on this Mac must listen for paired Macs. See
[Listening for other Macs](leases.md#listening-for-other-macs).

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory of the daemon. |
| `--address ADDRESS` | the address that the daemon listens on | The address in the code, such as a DNS name of this Mac. It must lead to the address that the daemon listens on. |
| `--priority-ceiling N` | `0` | The highest priority that the Mac may ask for when it leases. |

The command prints the code and its end, and then waits.

```text
code=macpool1:192.0.2.20:7373:...
expires_at=2027-01-15T08:10:00Z
```

Run [`pool add`](#pool-add) with the code on the other Mac. The code works once and for 10
minutes. It stops working when the command exits, and a newer invitation replaces it. The code holds the
first half of the host key's fingerprint and a secret. Send it over a channel that you trust,
because anyone with the code can pair while it works.

When a Mac pairs, the command prints its short key and name, such as
`paired mzxw-6ytb-oi2d-k3lq runner`, and exits. Compare the short key with the `this_mac` key that
`pool add` prints on the other Mac. If a Mac that paired before uses the code, the line starts with `already paired`, and the host
keeps the Mac's name and priority ceiling. If a Mac sends a wrong code, the command warns and keeps
the invitation open.

## host revoke

`macpool host revoke KEY` blocks a paired Mac and closes its connections. `KEY` is the short key or
the full key from `host list`.

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory of the daemon. |
| `--end-leases` | off | Also ends the Mac's detached leases. |

The Mac's queued requests and its leases with a connection end at once. Its detached leases run
until they expire unless you pass `--end-leases`. The command prints the Mac and the number of
connections and leases that ended.

```text
revoked mzxw-6ytb-oi2d-k3lq runner connections=1 leases=0
```

The Mac stays in `host list` with `BLOCKED` set to `yes`, and it can't pair again.

## pool list

`macpool pool list` prints the hosts that this Mac paired with. It reads `trust/hosts.json` in the
data directory and needs no running daemon. Without paired hosts it prints `no paired hosts`. It
takes the same `--data-dir` and `--json` options as `host list`.

Each row shows when this Mac paired, the host's address and port from the pairing code, the host's
short key, and its name. The host chose its name and its address. The table escapes and isolates
both like a client's name in `host list`.

## pool add

`macpool pool add CODE` pairs this Mac with the host that printed the code with `host invite`.
Without `CODE`, the command reads the code from standard input, so the code stays out of the process
list.

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory of this Mac's key and paired hosts. |
| `--name NAME` | this Mac's name | The name that the host shows for this Mac. |

```sh
pbpaste | macpool pool add
```

The command checks the host's key against the code before it sends the secret. It then adds the
host to `trust/hosts.json` and prints the host and this Mac's short key.

```text
paired 7xkq-4mzp-c2rd-6tvw lab
this_mac=mzxw-6ytb-oi2d-k3lq
```

`host invite` on the host prints the same `this_mac` key after `paired`. If the two keys differ,
another Mac used the code. Revoke that Mac on the host with `host revoke`.

## pool remove

`macpool pool remove HOST` asks the host to forget this Mac and then removes the host from this
Mac's list. `HOST` is a name or short key from `pool list`.

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory of this Mac's key and paired hosts. |
| `--end-leases` | off | Ends this Mac's leases on the host. |
| `--local` | off | Removes the host from this Mac's list without asking the host. |

The host refuses while this Mac holds leases there, unless you pass `--end-leases`. The command
prints the host and the number of leases that ended, such as
`removed 7xkq-4mzp-c2rd-6tvw lab leases=0`. If the host can't be reached or refuses, the host stays
in the list.

`--local` suits a host that is gone or that revoked this Mac. The host then keeps this Mac in its
`host list`. Run `host revoke` there to block this Mac. The record stays, with `BLOCKED` set to
`yes`.

## connect

`macpool connect LEASE` relays its standard input and output to the SSH server of a ready lease's
guest. It suits the `ProxyCommand` option of `ssh`. The connection holds no lease, so the lease
runs on after the connection ends.

| Option | Default | What it does |
| --- | --- | --- |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory of this Mac's daemon, key, and paired hosts. |
| `--pool HOST` | the daemon on this Mac | A paired host's name or short key from `pool list`. The lease must belong to this Mac. |

```sh
ssh -o ProxyCommand="macpool connect 0a1b2c3d" -o HostKeyAlias=macpool-0a1b2c3d admin@macpool-0a1b2c3d
```

`ssh` never connects to the host name in the command, so any name works there. Give each lease an
alias of its own, because every clone has its own host key. `macpool ssh` logs in with the key that
the lease pins and needs none of these options.

The command exits with status 0 when the stream ends normally. A short key in `--pool` names its
host even when other hosts have that text as their name. If no short key matches and two paired
hosts have the name, the command fails and asks for the short key.

The daemon ends the stream when the lease stops being ready, when the host revokes this Mac or no
longer accepts it, and when the daemon stops. Over the local socket such an end looks normal to
`connect`, which then exits with status 0. `ssh` still reports the cut connection. With `--pool`,
the end of standard input ends the whole stream, because TLS can't end one direction alone. One Mac
may hold 8 streams on a host at once.

## ssh

`macpool ssh LEASE` logs in to a ready lease's guest with `ssh` and opens a shell. A command after
`--` runs in the guest instead, and `macpool ssh` exits with its status. It takes the same
`--data-dir` and `--pool` options as `connect`.

```sh
macpool ssh --pool lab 0a1b2c3d -- sw_vers
```

The command first asks the daemon for the guest's account and host key. The daemon reads them from
the lease's bundle and doesn't connect to the guest. The command then runs `/usr/bin/ssh` through
`macpool connect`. `ssh` accepts only the guest's pinned host key, logs in with the account's
password, and ignores your SSH configuration and agent. The password reaches `ssh` through a named
pipe in a private temporary directory, so it never appears in a file, a process argument, or the
environment. The pipe hands out the password at most twice, once for each way `ssh` asks for it.

`ssh` joins the words after `--` with spaces, and the guest's shell splits them again. Quote them as
you would for `ssh`. The status is 255 when `ssh` itself fails.

All guests on a host share the host's NAT network. A shell in a guest, or a port that `ssh -L` or
`ssh -D` forwards, therefore reaches the other guests on the host, the host's own services on that
network, and the host's local network. Pair only Macs that you would let onto the host's network.

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
