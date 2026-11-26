# Leases and the daemon

The daemon owns your Mac's VM slots and hands out clones of stopped sources as leases. This page
covers running the daemon, leasing a clone, and what happens when a leased VM stops.

## Running the daemon

`macpool daemon` runs the daemon in the foreground. It's short for `macpool daemon run`. It prints
`listening` and its socket path. Control-C stops the daemon and leaves leased VMs running.

`macpool daemon install` registers the daemon as a launchd job in your login session and starts
it. launchd starts it again at login and whenever it exits. If you run `install` again, it replaces
the job. `macpool daemon uninstall` stops the job and removes it. Neither stops leased VMs, and the
next daemon picks them up.

| Option | Default | What it does |
| --- | --- | --- |
| `--slots N` | 2 | How many VMs run at once, 1 or 2. `run` and `install` take it. |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | Where the daemon keeps its state, clones, sockets, and logs. |
| `--listen ADDRESS[:PORT]` | off | Listens for paired Macs. See [Listening for other Macs](#listening-for-other-macs). |
| `--host-name NAME` | this Mac's name | The name that a Mac sees for this host when it pairs. Needs `--listen`. |
| `--offer NAME=BUNDLE` | none | A stopped source that paired Macs may lease by its name. Repeat it for more sources. Needs `--listen`. |
| `--allow-from CIDR` | every address | A range of addresses that may connect, such as `100.64.0.0/10`. Repeat it for more ranges. Needs `--listen`. |
| `--log-level LEVEL` | `warning` | Diagnostics on standard error. Only `run` takes it. |

`install` writes these options into the job, so the next start of the daemon uses them too. To
change them, run `install` again with the new options.

Every pool command except `daemon uninstall` takes `--data-dir`. A daemon's data directory must be
on the same APFS volume as its sources. With `--pool`, the directory holds only this Mac's key and
paired hosts, and it need not be on the same volume as any source. The daemon refuses a directory
that belongs to another user or that other users can write to.

## Listening for other Macs

With `--listen`, the daemon also accepts paired Macs over TLS on one numeric address of this Mac,
such as `192.0.2.20` or `[2001:db8::20]:7480`. The default port is 7373. A host name, `0.0.0.0`,
and `::` don't work, because the daemon would then listen on every interface. Other Macs connect
only to this address, so pick one that they reach, such as a LAN or Tailscale address. A loopback
address such as `127.0.0.1` serves no other Mac. A Tailscale address stays the same when the Mac
changes networks, so it suits a Mac that moves.

```sh
$macpool daemon install --listen 192.0.2.20 --offer base="$PWD/.cache/vms/base"
$macpool list
```

`list` then prints `listening for paired Macs on 192.0.2.20:7373`. If the address isn't on an
interface yet or another process holds the port, `list` prints why the daemon isn't listening. The
daemon keeps serving this Mac and tries again every 10 seconds.

With `--allow-from`, the listener closes a connection from any other address before the TLS
handshake. A range takes a numeric address and a prefix length, and the bits after the prefix must
be zero. One address without a prefix length allows that address alone. Tailscale gives your
devices addresses in `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.

```sh
$macpool daemon install --listen 192.0.2.20 --offer base="$PWD/.cache/vms/base" \
  --allow-from 192.0.2.0/24
```

A paired Mac leases only the sources that `--offer` names, by their names. It can't share a
directory of this Mac with its guest.

## Leasing a clone

`macpool lease --from SOURCE` asks the daemon for a clone of a stopped source. While every slot is
busy, it prints `queued position=N` and waits. Once the clone is ready, it prints `lease_id=`,
`bundle=`, `address=`, `expires_at=`, and `ready`.

| Option | Default | What it does |
| --- | --- | --- |
| `--from SOURCE` | required | The stopped source bundle to clone. |
| `--ttl SECONDS` | 3600 | The time to live, counted from the first `ready`. |
| `--priority N` | 0 | Higher priorities get a slot first. Equal priorities wait in arrival order. |
| `--restart POLICY` | `on-failure` | When the daemon boots the VM again. See below. |
| `--share DIR` | none | Shares a host directory, as with `run`. |
| `--share-read-only` | off | Lets the guest only read the shared directory. |
| `--boot-timeout SECONDS` | 900 | The longest wait for each boot, including SSH and the credential replacement. |
| `--detach` | off | Exits at `ready` and leaves the lease with the daemon. |
| `--data-dir DIR` | see above | The daemon to ask, and the directory with this Mac's key and paired hosts. |
| `--pool HOST` | the daemon on this Mac | A paired host to lease from. See [Leasing from another Mac](#leasing-from-another-mac). |

The daemon refuses a source that's running, has never booted, lies on another volume, or didn't
finish replacing its credentials. It also refuses a `--share` directory that doesn't exist, that
is, contains, or lies inside its data directory, or that contains the source or an offered source.
Without `--share-read-only`, it also refuses one that contains the `macpool` executable. The guest
could otherwise reach the images, other leases' clones, or code that runs on the host. Share a
narrower directory instead.

Without `--detach`, the lease lasts as long as `lease` runs, and Control-C releases it. A command
after `--` runs with `MACPOOL_LEASE_ID`, `MACPOOL_BUNDLE`, and `MACPOOL_ADDRESS` in its
environment. The lease ends when the command exits, and `lease` exits with the command's status.

```sh
$macpool lease --from .cache/vms/base -- sh -c "$macpool ssh \$MACPOOL_LEASE_ID -- sw_vers"
```

With `--detach`, the lease lasts until you release it or it expires. Every lease expires after its
time to live.

```sh
$macpool lease --from .cache/vms/base --ttl 7200 --detach
$macpool list
$macpool renew LEASE
$macpool release LEASE
```

| Command | What it does |
| --- | --- |
| `macpool list` | Prints the slots, leases, queue, and images. `--json` prints one JSON object. |
| `macpool renew LEASE` | Moves the expiry to the time to live from now and prints `expires_at=`. |
| `macpool release LEASE` | Ends the lease right away. |

When a lease ends, the daemon stops the VM by force and deletes the clone.

## Leasing from another Mac

The host is the Mac that runs the VMs, and the client is the Mac that leases them. Pair them once.
On the host, start the daemon with `--listen` and `--offer`, as in
[Listening for other Macs](#listening-for-other-macs), and print a code.

```sh
$macpool host invite
```

On the client, pair within 10 minutes. Copy the code to the client's clipboard over a channel that
you trust, because anyone with the code can pair while it works.

```sh
pbpaste | $macpool pool add
```

The host prints `paired` with the client's short key, and the client prints the same key as
`this_mac=`. If the keys differ, another Mac used the code. Revoke the key from the host's `paired`
line with `macpool host revoke`.

If `pool add` fails after the host printed `paired`, this Mac may have paired anyway. A revoked Mac
can't pair again until `host unblock`, so don't revoke yet. Run `host invite` and `pool add` again. The host prints
`already paired` for a Mac that paired before. The new `this_mac=` line then shows whether the
first `paired` line named this Mac.
[Commands](commands.md#host-invite) describes the pairing commands.

`lease`, `list`, `renew`, and `release` take `--pool HOST` to ask a paired host instead of the
daemon on this Mac. `HOST` is a name or short key from `macpool pool list`, as with `connect`.

With `--pool`, `--from` takes the name of a source that the host offers instead of a path, and
`--share` isn't allowed. The host shows this Mac only its own leases and no paths on its disk.
`bundle=` and `address=` stay empty, and so do `MACPOOL_BUNDLE` and `MACPOOL_ADDRESS`. Reach the
guest with `macpool ssh --pool`.

```sh
$macpool lease --pool lab --from base --detach
$macpool ssh --pool lab LEASE -- sw_vers
$macpool release --pool lab LEASE
```

A shell in the guest runs on the host's NAT network. The [ssh section](commands.md#ssh) of the
command reference lists what the guest can reach there.

If the connection to the host breaks while `lease` holds a lease, `lease` connects again and
attaches to the lease. The host keeps the lease for 60 seconds after it notices the break, and it
doesn't count the time it sleeps. `lease` tries until the lease expires, with pauses of up to 15
seconds, so a host that sleeps doesn't end the lease. If `macpool renew` moves the expiry from
another shell or Mac, the host tells `lease`, and `lease` tries until the new expiry. Before the
first `ready`, `lease` tries for 60 seconds.

`lease` stops at once if the host presents another key or greets with another protocol version.
It also stops if the host answers but refuses this Mac for 120 seconds, because an awake host has
ended the lease by then.

If the host doesn't confirm the release when the command after `--` ends, `lease` prints a warning
and still exits with the command's status. At Control-C, it fails instead. The host ends the lease
60 seconds after it notices the closed connection.

## Restarts

`--restart` decides when the daemon boots a leased VM again.

| Policy | The daemon boots the clone again when |
| --- | --- |
| `on-failure` | the VM stops unexpectedly. |
| `always` | the VM stops unexpectedly or the guest shuts itself down. |
| `never` | never. The lease ends at the first stop. |

A lease gets at most three such boots, after 5, 10, and 20 seconds. The next stop ends it. `lease`
prints `restarting reason=` and later `ready` again.

If the clone's credential replacement stopped halfway, the daemon boots a fresh clone instead, and
the old clone's data is lost.

## Supervisors

Each leased VM runs in its own `macpool supervise` process. The daemon starts it, and you never run
it yourself. Because the VM lives in that process, it keeps running while the daemon stops or
restarts. A new daemon reconnects to its supervisors.

[Troubleshooting](troubleshooting.md) covers logs and what the daemon does when a supervisor or the
state file fails.
