# ``MacpoolPool``

Lease disposable macOS VMs from a daemon that owns a host's VM slots.

## Overview

A ``PoolDaemon`` runs one per user and data directory. It owns a fixed number of slots, at most
the two VMs that macOS allows per host. Clients ask it for a lease on a stopped source bundle. The
daemon clones the source into its data directory, boots the clone, and answers once the guest is
ready on SSH. Requests that find no free slot wait in a queue ordered by priority and then by
arrival.

The daemon and its clients exchange one JSON message per line over a Unix socket in the data
directory. ``PoolRequest`` and ``PoolReply`` define the messages, and ``PoolClient`` opens the
connection. The socket's directory admits only the owning user.

Network truncates a socket path with characters outside ASCII, and a socket address holds at most
103 bytes of path. The pool reaches such a socket through a symbolic link to its directory in the
user's temporary directory, so the socket file keeps its full name in the data directory. A client
also tries the truncated name that earlier builds listened on, which keeps their supervisors
reachable after an upgrade.

### Lease owners

Each lease has a ``LeaseOwner``. A client on the socket acts for the user who runs the daemon and
may see and change every lease. A paired client from another Mac is named by the
``KeyFingerprint`` of its key. It sees and changes only its own leases, and the daemon answers its
requests about any other lease as if that lease did not exist.

A paired client names its source by one of the names that the host offers, and the daemon clones
the bundle behind that name. It cannot share a host directory with its guest.

### Supervisors

Each leased VM runs in its own supervisor process, which ``SupervisorLauncher`` starts in a
session of its own. A Virtualization VM ends with the process that created it, so the supervisor
keeps the VM alive while the daemon restarts. The supervisor reports a ``SupervisorStatus`` on its
own socket through a ``SupervisorServer`` and accepts a ``SupervisorCommand`` that stops the VM.
When its VM ends, it writes the ``MachineOutcome`` to an exit record before it exits.

A supervisor holds its lease's ``SupervisorLock`` from its start until its exit. The daemon treats
a supervisor as gone only once that lock is free. It waits for the lock before it boots the lease
again or deletes the clone, so an earlier supervisor's socket and exit record never mix with a
later one's.

A supervisor whose connection ends while it holds the lock gets reconnected. One that does not
answer, ignores a stop, or reports another protocol version gets a stop command, then `SIGTERM`,
and then `SIGKILL` as a ``SupervisorSignal``. A lease that was ending then deletes its clone, and
for any other lease the run counts as a failure under the restart policy.

A signal goes only to a process whose arguments, as the kernel holds them, run `supervise` for the
lease in the data directory. When the lock records a start time, the process must also have
started at that microsecond, so a reused process identifier never matches. When a check fails,
the daemon withholds the signal and logs the ``SupervisorMismatch``.

### Supervisor lock record

The supervisor writes a ``SupervisorLockRecord`` into its lock file right after it takes the lock
and before it opens its socket. The record is UTF-8 text in two lines, each ending in a line feed.
The first line is the process identifier in decimal. The second is the process's start time in
decimal microseconds since 1970, as `proc_pidinfo` reports it.

A record with only the first line comes from a build before the start time. The daemon reads its
start time as absent and identifies that supervisor by its arguments alone, so leases survive an
upgrade. A second line that is not a whole number or lacks its line feed is malformed, and the
daemon sends that supervisor no signal.

A build before the start time cannot read the two-line record. It falls back to the process
identifier that the pool state stores for the lease. A later format keeps the two lines and adds
any new line after them, which this build ignores.

### Lease lifetime

A lease's time to live starts when its VM is first ready, and a renewal sets the expiry to the time
to live after the renewal. A lease ends on release, on expiry, when its attached client
disconnects, or when its VM stops and the ``RestartPolicy`` does not boot it again. A detached
lease outlives its client once it is ready. The daemon then stops the VM, deletes the clone, and
grants the slot to the next request.

A VM that stops unexpectedly boots again from the same clone when its policy allows. The waits
between restarts double up to a limit, and ``PoolPolicy`` sets the number of restarts.

### Recovery

The daemon stores its leases in a JSON file in the data directory after every change and holds an
exclusive lock on the directory while it runs. A new daemon reads the file, reconnects to the
supervisors that still run, and treats a supervisor that ended meanwhile as a stopped VM. A
malformed file moves aside, and the daemon starts without leases. It then stops the supervisors
and deletes the clones that belong to no lease. A file in a format that this build does not read
keeps the daemon from starting, so the build that wrote it can still resume the leases. Clients
of attached leases get a grace period to reattach. ``LaunchAgent`` describes the launchd job that
starts the daemon at login and again after it exits.

The file is in format version 2, which stores each lease's owner. A version 1 file from an earlier
build loads with the local user as the owner of every lease. The daemon's next write stores the
file in version 2, which an earlier build then refuses.

## Topics

### Daemon

- ``PoolDaemon``
- ``PoolPolicy``
- ``PoolDirectory``
- ``LaunchAgent``

### Clients

- ``PoolClient``
- ``PoolRequest``
- ``PoolReply``
- ``LeaseTerms``
- ``LeaseID``
- ``LeaseOwner``
- ``KeyFingerprint``
- ``RestartPolicy``
- ``LeasePhase``
- ``LeaseSummary``
- ``QueuedSummary``
- ``PoolSummary``

### Supervisors

- ``SupervisorLauncher``
- ``SupervisorLaunch``
- ``SupervisorSignal``
- ``SupervisorMismatch``
- ``SupervisorLock``
- ``SupervisorLockRecord``
- ``RecordedStartTime``
- ``ProcessSupervisorLauncher``
- ``SupervisorServer``
- ``SupervisorStatus``
- ``SupervisorPhase``
- ``SupervisorCommand``
- ``MachineOutcome``

### Connections

- ``MessageChannel``
- ``SocketListener``

### Errors

- ``PoolError``
