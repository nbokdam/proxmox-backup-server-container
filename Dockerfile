FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# renovate: datasource=deb depName=proxmox-backup-server registryUrl=http://download.proxmox.com/debian/pbs?suite=trixie&components=pbs-no-subscription&binaryArch=amd64
ARG PBS_VERSION=4.2.9-1

ARG DEBIAN_FRONTEND=noninteractive

# Proxmox's archive keyring is fetched over HTTPS from Proxmox itself; the apt repo is then verified against it.
ADD --chmod=644 --checksum=sha256:136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45 https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg /usr/share/keyrings/proxmox-archive-keyring.gpg

RUN echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pbs trixie pbs-no-subscription" \
      > /etc/apt/sources.list.d/pbs.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "proxmox-backup-server=${PBS_VERSION}" \
      ca-certificates tini procps busybox \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY rootfs/entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 8007
VOLUME ["/etc/proxmox-backup", "/var/lib/proxmox-backup", "/var/log/proxmox-backup"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
