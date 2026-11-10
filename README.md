# BackupScripts

Two Bash scripts to back up and restore **rootless Podman** services, on the machine
you run them from or on a server over SSH.

- `VolumeBackup.sh` saves the config and the data of each service.
- `VolumeRestore.sh` puts a backup back, on the same server or on a new one.

A "service" is any of these:

| Type | What it is |
|---|---|
| compose | a project started with `podman-compose` |
| Quadlet | a container managed by a systemd user unit (`.container` file) |
| standalone | a single container created with `podman run` |

Each script is a single file with no configuration: copy it to a USB drive and run it.
Both are interactive and ask for everything they need.

## Requirements

On the machine where the containers live:

- Bash 4.4 or newer and rootless Podman (used with Podman 4.9 and 5.x)
- `tar`, `zstd`, `sha256sum`, `flock`, `findmnt`, `numfmt` (coreutils and util-linux)
- `podman-compose` for compose services, `systemctl --user` for Quadlets

On the machine you run the scripts from, when working over SSH:

- Bash, `ssh`, `sha256sum`
- `rsync` on both sides is recommended; without it the scripts fall back to `scp`
  (slower and cannot resume)

## Backing up

```bash
./VolumeBackup.sh
```

It asks:

1. Whether the containers are on another server. If so, `user@server` and the SSH port.
2. Which services to back up. It lists them by number; `all` picks every one.
3. Which services to restart at the end, if any.
4. The folder to store the backup in.

Then it shows what it found for each service and waits for a confirmation.

What gets saved for each service:

- **Config**: the compose folder, or the folder of the Quadlet unit.
- **Named volumes**.
- **Bind mounts**, except system paths (`/etc`, `/usr`, `/dev`, `/proc`, `/sys`, `/run`)
  and anything already inside the config folder.
- The `podman inspect` output of its containers and the images they used.

How it works:

- Services are stopped **one at a time**, only while their own data is copied, and
  started again right after. Before stopping anything it checks that the copy fits.
- After starting a service it checks every container that was running before. If one
  did not come back, it says so in red and lists it again at the end.
- Over SSH, each service is downloaded in the background while the next one is copied,
  and verified with SHA-256 on arrival.
- Files are read with `podman unshare`, so files owned by the container users
  (databases, for example) are copied with their original owners.

At the end it offers to delete old backups: each service keeps its newest backups
(3 by default). Nothing is deleted unless you type `delete`.

### Options

Set them as environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `ZSTD_LEVEL` | `1` | Compression level, 1 (fastest) to 19 |
| `COMPRESSION` | `while_copying` | `while_copying` compresses during the copy. `afterwards` copies first and compresses once the service is running again: less downtime on a slow CPU, more temporary disk space |
| `KEEP_LAST` | `3` | Backups kept for each service when it offers to delete old ones |

```bash
ZSTD_LEVEL=6 KEEP_LAST=5 ./VolumeBackup.sh
```

### What a backup looks like

```text
backup_2026-01-31_0300/
├── backup.log                 full log, with manual restore commands at the end
└── myservice/
    ├── MANIFEST.tsv           every archive, where it came from and its size
    ├── SERVICE.tsv            service type, systemd unit, compose files
    ├── CONTAINERS.json        `podman inspect` of its containers
    ├── IMAGES.tsv             container name, image name and image ID
    ├── SHA256SUMS             checksums of everything above
    ├── config/                compose folder or Quadlet units (.tar.zst)
    └── volumes/               named volumes and bind mounts (.tar.zst)
```

## Restoring

```bash
./VolumeRestore.sh
```

It asks where to restore (this machine or a server over SSH), where the backup is,
which services and which parts of each one. You can point it at a single service
folder, at one `backup_...` folder or at the folder that holds several backups.

Before touching anything it verifies the checksums and shows, for each service, what
will be replaced and what will be created. It only goes on if you type `restore`.

Safety net:

- **Nothing is deleted.** What was there before is renamed to
  `<path>.before_restore_<date>`. If the parent folder belongs to root and cannot be
  written, its content is moved to `~/.before_restore/<date><path>` instead. At the end
  the script prints the commands to remove those copies once you have checked that
  everything works.
- If a restore fails halfway, the service is put back the way it was and started again.
- If the restored service does not start, the script offers to put back what was there
  before.
- If containers with the same names exist but belong to something else (another compose
  project, another unit, or created by hand), it shows where they come from and asks
  before setting them aside.
- If a folder can only be created or taken over with `sudo`, it skips that service and
  prints the exact `sudo` commands to prepare it.
- A backup made by another user can be restored: paths under `/home/<old user>` can be
  moved to the home of the user who restores.

On a new server, a compose service is created from its restored config. A standalone
container is not recreated: its data is restored and `CONTAINERS.json` holds what is
needed to create it again by hand.

To see what a restore would do without changing anything:

```bash
DRY_RUN=yes ./VolumeRestore.sh
```

## Tests

```bash
bash tests/tests.sh              # all of them
bash tests/tests.sh over_ssh     # only the named tests
```

The end-to-end tests need Podman and `podman-compose`. They create and remove a
throwaway compose service called `rtest` (container `rtest_app`, volume `rtest_data`).

## Limitations

- Rootless Podman only. Docker and rootful Podman are not supported.
- The scripts are interactive; they are not meant to run from cron.
- Images are not saved, only their names and IDs. A restore on a new server pulls or
  builds them again.
- The service is stopped while its data is copied.

## License

[MIT](LICENSE)
