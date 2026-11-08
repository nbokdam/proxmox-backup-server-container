# proxmox-backup-server container

Unofficial container image of [Proxmox Backup Server](https://pbs.proxmox.com/) (PBS), built from
Proxmox's `pbs-no-subscription` apt repository on Debian trixie. Proxmox does not publish a container image.

Image: `ghcr.io/nbokdam/proxmox-backup-server` (tags: `latest`, and the PBS version, e.g. `4.2.9-1`; amd64 only).

Renovate keeps the Debian base image digest and the PBS version (`ARG PBS_VERSION` in the `Dockerfile`, looked up in
the Proxmox apt repo) current. A weekly build also picks up Debian security fixes. Because the version tag is rebuilt, prefer pinning by digest.

## Volumes

| Path | Content |
|---|---|
| `/etc/proxmox-backup` | configuration, users, certificates, keys (**back this up**) |
| `/var/lib/proxmox-backup` | task state and statistics |
| `/var/log/proxmox-backup` | task logs |
| your datastore path | backup data |

`/run` must be writable (e.g. a tmpfs/emptyDir). PBS listens on port `8007` (HTTPS).

## Environment

| Variable | Purpose |
|---|---|
| `PBS_ADMIN_PASSWORD` | Password of `admin@pbs` (created with the Admin role on `/`, password reset on each start). |
| `PBS_DATASTORE_NAME`, `PBS_DATASTORE_PATH` | Create this datastore on first start. The path must be an empty or new directory (not a filesystem root with `lost+found`). |
| `PBS_TLS_CERT`, `PBS_TLS_KEY` | PEM files (e.g. a mounted cert-manager Secret) to serve instead of the self-signed certificate. When the certificate file changes the container exits so the orchestrator restarts it. |

## Try it

```sh
docker run -d --name pbs -p 8007:8007 --tmpfs /run \
  -e PBS_ADMIN_PASSWORD=change-me -e PBS_DATASTORE_NAME=main -e PBS_DATASTORE_PATH=/datastore/main \
  -v pbs-etc:/etc/proxmox-backup -v pbs-lib:/var/lib/proxmox-backup -v pbs-log:/var/log/proxmox-backup \
  -v pbs-data:/datastore ghcr.io/nbokdam/proxmox-backup-server
# https://localhost:8007  login admin@pbs
```

PBS is AGPL-3.0 software by Proxmox Server Solutions GmbH; this repository only packages it.
