# Clone credentials

A clone starts as an exact copy of its source, including the guest password and the SSH host keys.
This page explains how macpool replaces them, what can go wrong, and how long the clone is exposed.

## What happens on the first boot

1. The clone boots, gets an address, and answers on SSH.
2. macpool logs in with the source's account and sets a new random password and new SSH host keys.
3. The new password goes to the clone's `guest-account.json`, readable only by you. The new
   Ed25519 host key goes to its `known_hosts`.
4. `run` reports the time of this step as `measure rotate_seconds` and the new key's fingerprint as
   `measure host_key`. Then it prints `ready`.

A lease goes through the same steps before it reports `ready`. The `--timeout` of `run` and the
`--boot-timeout` of `lease` limit the whole step. A `stop-request` file ends it early.

## When it fails

`settings.json` records the step as `credential_rotation`.

| State | What it means | What you do |
| --- | --- | --- |
| `pending` | The first login failed. The guest is unchanged. | Run the clone again. The next `run` tries again. |
| `started` | The step failed after the guest started to change. | Delete the clone and clone the source again. |
| `finished` | The clone has its own credentials. | Nothing. |

If the step fails, `run` stops the VM. `run`, `clone`, and `Scripts/ssh.sh` refuse a clone in the
`started` state, and the daemon refuses it as a source. While another `run` holds the clone, they
report the step as still under way.

## The source's host key

The first login to a clone checks its inherited host key against the `known_hosts` file that the
clone copied from its source. If the source has no `known_hosts` file, the clone's first `run`
trusts the first host key that the clone presents. If the file exists without an Ed25519 key that's
still trusted, that `run` fails instead.

Connecting to the source once with `Scripts/ssh.sh` or `Scripts/shutdown.sh` writes the file.
[Getting started](getting-started.md) does this when it shuts the source down.

## The window before `ready`

Until the clone prints `ready`, it still accepts its source's password and host key. That usually
lasts 11 to 69 seconds after SSH answers, and it can last until the timeout.

Anyone with the source's password, in another guest or on the host, can log in during that window.
They could leave access behind that `ready` doesn't reveal. Use a clone only after `ready`.
