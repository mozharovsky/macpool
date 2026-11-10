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
lease in the data directory. When the check fails, the daemon withholds the signal and logs the
``SupervisorMismatch``.

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
and deletes the clones that belong to no lease. A file in another build's format keeps the daemon
from starting, so that build can still resume the leases. Clients
of attached leases get a grace period to reattach. ``LaunchAgent`` describes the launchd job that
starts the daemon at login and again after it exits.

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
