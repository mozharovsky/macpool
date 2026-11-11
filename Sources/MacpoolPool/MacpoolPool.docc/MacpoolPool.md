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

A channel runs the same way over any stream connection, such as TCP. A request can also switch its
connection to raw bytes. ``MessageChannel/takeStream()`` then hands the connection over as a
``ByteStream``, which first returns the bytes that arrived after the last line.

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
the bundle behind that name. It cannot share a host directory with its guest or raise its
priority above the default of 0. Requests of equal priority wait in the order they arrive. The
local user gets ahead of a paired client's waiting request by asking for a higher priority.

### Mac identity

Each Mac has one P-256 key, which serves it as a host and as a client of other Macs. The key lives
in PKCS#8 PEM in `trust/identity.pem` of the data directory, and only its owner may read the file
or enter the directory. The pool refuses a key file that other users can reach and never replaces
an unusable one, because paired Macs know the Mac by its key.

The pool creates the key when it first needs it, unless `trust` holds a list of paired Macs. The
host lists its clients in `clients.json`, and a client lists its hosts in `hosts.json`. If the key
is missing while either list exists, the pool refuses to start the listener for paired Macs. The
error names the lists. Put the key file back, or delete the lists and pair the Macs again.

The pool reads and writes a list of at most 256 KiB. The host reads its list during every
handshake, so the limit bounds the work of one connection. A pairing that would make the list
larger fails.

People compare a key by its ``KeyFingerprint/shortKey``, the first 80 bits of the digest in
base32. Logs name a paired client by the same text.

Permission bits alone do not keep other users out. The pool also refuses the key and the `trust`
directory on a volume that ignores ownership or is not local, and when either has an access control
list. The data directory may have an access control list that denies access or allows reading, such
as the `group:everyone deny delete` that macOS puts on `~/Library`. The pool refuses one that lets
other users add, delete, or rename its entries, because they could then move `trust` away. The
`trust` directory is excluded from backups, which Time Machine honors.

The pool builds a self-signed certificate that carries the key in TLS each time it loads the key.
The SHA-256 digest of the key's SubjectPublicKeyInfo names the Mac, so its peers check the key and
not the certificate's names or dates.

### Connections between Macs

With ``PoolDaemon/Configuration/peers`` set, the daemon also listens on TCP for paired Macs. It
binds to the one numeric address in ``PeerSettings/address``. For a host name, Network would bind
to every interface, so the listener refuses names. Both sides present their key in a TLS 1.3
handshake with the application protocol `macpool/1`. Each side checks only the key in the first
certificate that the other side sends, and the system's trust evaluation never runs. Session
resumption and session tickets are off, so every connection runs a full handshake.

The host reads `trust/clients.json` during every handshake and admits the keys of clients that are
not blocked. While an invitation is open, it also admits keys that the list does not name, so that
a new client can pair. A key that leaves the list opens no new connection, and connections that are
already open stay open. If the list cannot be read when the listener starts, the listener does not
start. If it cannot be read later, the host admits nobody until it can. A TLS 1.3 client finishes
its handshake before the host checks the client's key. The host therefore first sends a `hello`
line. The line names the host's role and the protocol version that ALPN chose. The client sends
requests only after that line. Both sides then exchange the same lines as on the Unix socket.

The daemon loads the key when it starts listening. A key or a list that cannot be loaded, or a
port that another process holds, leaves the local socket serving. The daemon logs the failure and
tries again after ``PeerSettings/retryInterval``.

Anyone who reaches the port can start a handshake, because a client proves its key only at the
end. At most 16 handshakes run at once, and the host closes a connection beyond that before its
handshake begins. A handshake that does not finish within 5 seconds ends. A paired Mac may hold
at most 4 connections. A fifth connection receives a failure reply instead of the greeting and
closes. These limits are fixed.

A channel queues at most 4 MiB for a peer that does not read and closes the connection beyond
that. After the daemon handles a request, it reads the next one only once the messages that it
sent to the client so far left.
Network does not pass the end of one direction through TLS, so
``ByteStream/finishSending(within:)`` closes a TLS connection once its bytes left. If the timeout
ends first, it closes the connection anyway. The bytes that were still waiting are lost, and the
peer still sees a normal end of the stream.

### Pairing

A client Mac pairs with a host once, with a ``PairingCode``. The local user asks the daemon for a
code with ``PoolRequest/invite(address:)``. The code carries the host's address and port, the
first 128 bits of the digest of the host's key, and a secret of 128 bits. Pass it to the person
who pairs the client, because anyone with the code can pair in that client's place.

``PoolClient/pair(using:name:directory:timeout:)`` checks the host's key against the code before
it sends the secret. The host then adds the client to `clients.json`, and the client adds the
host to `hosts.json`. Both sides can show the client's ``KeyFingerprint/shortKey``. If the two
texts differ, someone else used the code.

A Mac that the host does not know may send one ``PoolRequest/pair(secret:name:)`` request within
5 seconds, and at most 4 such Macs connect at once. The invitation ends when a client pairs, after
10 minutes, after 5 wrong secrets, when a newer invitation replaces it, or when the inviting
connection closes. The daemon keeps only the SHA-256 digest of the secret, and only in memory. A
restart of the daemon therefore ends the invitation. A blocked client cannot pair again.

Each Mac gives the other its name, and both names follow the same rule. A name has 1 to 64 Unicode
scalars and not only whitespace. It has no control, format, private-use, or unassigned scalars and
no line or paragraph separators. Format scalars include the controls that reverse the direction of
text, so a name cannot hide part of itself when the pool shows it.

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
build loads with the local user as the owner of every lease. The first start of this build
rewrites the file in version 2 before any lease changes. An earlier build then refuses the file.

## Topics

### Daemon

- ``PoolDaemon``
- ``PoolPolicy``
- ``PoolDirectory``
- ``PeerSettings``
- ``LaunchAgent``

### Clients

- ``PoolClient``
- ``PoolRequest``
- ``PoolReply``
- ``LeaseTerms``
- ``LeaseID``
- ``LeaseOwner``
- ``KeyFingerprint``
- ``PairingCode``
- ``PairedMac``
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
- ``ByteStream``
- ``SocketListener``

### Errors

- ``PoolError``
