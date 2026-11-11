# Xcode images

An image is a stopped VM that the daemon clones for leases, with software already installed.
`macpool image xcode` builds one with Xcode and an iOS simulator runtime. A lease of the image
runs `xcodebuild` and boots a simulator without installing anything. The build boots one simulator
once and shuts it down, so the simulator in a lease starts from a stopped state.

## What you need

- A source that has booted once and has a disk of at least 128 GB. The base from
  [Getting started](getting-started.md) qualifies. On a 64 GB disk, `simctl` refuses to add the
  runtime for lack of space.
- An Xcode archive (`.xip`) that you downloaded from Apple.
- An iOS simulator runtime disk image (`.dmg`). You can download it from Apple's developer
  downloads page. On a Mac with the same Xcode, `xcodebuild -downloadPlatform iOS -exportPath DIR`
  saves it to `DIR`.

The build never signs in to an Apple account and downloads nothing.

## Building the image

```sh
$macpool image xcode --from .cache/vms/base --name xcode \
  --xcode Xcode.xip --runtime iOS_Runtime.dmg --accept-xcode-license
```

The build accepts the Xcode and Apple SDKs license agreement in the guest. Read the agreement
first. Without `--accept-xcode-license`, the command stops before it touches any file.

| Option | Default | What it does |
| --- | --- | --- |
| `--from SOURCE` | required | The stopped source to build on. The command doesn't change it. |
| `--name NAME` | required | The image's name, with 1 to 64 ASCII letters, digits, `.`, `-`, and `_` that start with a letter or digit. |
| `--xcode FILE` | required | The Xcode archive. |
| `--runtime FILE` | required | The iOS simulator runtime disk image. |
| `--accept-xcode-license` | off | Accepts the Xcode license in the guest. The command needs it. |
| `--device NAME` | the first iPhone | The simulator that the build boots once. |
| `--keep-failed` | off | Keeps a failed image for inspection instead of deleting it. |
| `--boot-timeout SECONDS` | 900 | The longest wait for the guest's SSH and the credential replacement. |
| `--data-dir DIR` | `~/Library/Application Support/macpool` | The data directory that receives the image. |

The command prints `step:` lines as it goes. It ends with `measure image_seconds=` and `image=`
with the image's path.

## What the build does

1. Clones the source to `images/.NAME.building` in the data directory.
2. Boots the clone with the archive and the runtime in a read-only shared directory.
3. Expands the archive and moves Xcode to `/Applications/Xcode_BUILD.app`, where `BUILD` is the
   Xcode build, such as `27A266a`. It selects that Xcode with `xcode-select`.
4. Accepts the license and installs the first launch packages.
5. Adds the runtime and boots one simulator until it's ready, then shuts it down.
6. Checks the Xcode build, the license, the first launch packages, and at least 40 GB of free
   space in the guest.
7. Shuts the guest down and writes `image.json` with `ready` set to true and the builds of macOS,
   Xcode, and the runtime.
8. Moves the clone to `images/NAME`.

If a step or a check fails, or you press Control-C, or the command gets `SIGTERM` or `SIGHUP`, it
stops the VM and deletes the clone. With `--keep-failed`, it keeps the clone as `images/NAME` with `ready`
set to false. Delete a failed image yourself before you build another one with the same name.
If you start the command with `nohup`, closing the terminal doesn't stop the build.

If the command ends without its cleanup, for example after `kill -9` or a power loss, it can leave
`images/.NAME.building`, `images/.NAME.inputs`, or both behind. The next build of `NAME` stops and
names both paths. When no other `image xcode` is building `NAME`, delete the ones that exist.

The daemon refuses to lease an image that isn't ready or a bundle in `images` without
`image.json`. It checks when a request arrives and again each time it clones the image for a lease.

## Leasing the image

`macpool list` shows each image with its readiness and builds. Paired Macs don't see images.
Lease an image by its path.

```sh
$macpool lease --from "$HOME/Library/Application Support/macpool/images/xcode" -- \
  sh -c 'Scripts/ssh.sh "$MACPOOL_BUNDLE" xcodebuild -version'
```

A lease of the image reached `ready` in 19 seconds, and its simulator booted in 9 seconds. The
image takes about 42 GB on your Mac. Each lease is a clone and takes space only for what the guest
writes.

## Build times

One build of Xcode 27.0 with the iOS 27.0 runtime took 273 seconds on a Mac with Apple silicon.

| Step | Seconds |
| --- | --- |
| Boot, SSH, and credential replacement | 22 |
| Expanding the archive | 133 |
| Installing the first launch packages | 11 |
| Adding the runtime | 47 |
| Booting the simulator once | 46 |
| Moving Xcode, the license, and the checks | 3 |
| Shutting down the guest | 8 |

## Limitations

- The build takes only a `.xip` archive, not an installed `Xcode.app`.
- It installs one iOS runtime. Other platforms need another tool.
- The image keeps the source's macOS. A newer macOS needs a new source.
- The source must have no iOS simulator runtime and no Xcode with the archive's build. Otherwise
  the build fails after it expands the archive.
- When the archive or the runtime is on another volume, the build copies it to the data directory.
  The copy takes its full size there until the build ends.
