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
| `--log-level LEVEL` | `warning` | Diagnostics on standard error. Only `run` takes it. |

Every pool command except `daemon uninstall` takes `--data-dir`. The directory must be on the same
APFS volume as your sources. The daemon refuses a directory that belongs to another user or that
other users can write to.

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
| `--data-dir DIR` | see above | The daemon to ask. |

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
$macpool lease --from .cache/vms/base -- sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE" sw_vers'
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
| `macpool list` | Prints the slots, leases, and queue. `--json` prints one JSON object. |
| `macpool renew LEASE` | Moves the expiry to the time to live from now and prints `expires_at=`. |
| `macpool release LEASE` | Ends the lease right away. |

When a lease ends, the daemon stops the VM by force and deletes the clone.

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
