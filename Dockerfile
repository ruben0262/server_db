# server_db's image: MongoDB, one exact version (the one Atlas and the laptops run), with this
# server's settings built in (mongod.conf). Built on the server by `bin/sdb up`; nothing is pulled at
# start but this one base image, and only when the version line below changes.
FROM mongo:8.0.34

COPY mongod.conf /etc/mongod.conf

# Linux 6.19 through 7.0.13 crash MongoDB 8.0's memory allocator (TCMalloc) when it uses the kernel's
# rseq for its per-CPU caches, so mongod refuses to start on them (SERVER-121912, MongoDB's production
# notes). An LXC runs on the Proxmox host's kernel, and the host's is one of those. The base image hands
# rseq to TCMalloc (glibc.pthread.rseq=0); this hands it back to glibc, and TCMalloc keeps per-thread
# caches instead, as MongoDB 7.0 and earlier always did. Measured 2026-11-05 on kernel 7.0.0 with
# mongod 8.0.34: refused with 0, starts with 1, and 200,000 inserts from 8 threads, an aggregation and a
# full scan ran with no crash, usingPerCPUCaches false. Remove it once the host runs 7.0.14 or later.
ENV GLIBC_TUNABLES=glibc.pthread.rseq=1

# A ping needs no login, so the check never holds a password. `bin/sdb up` waits for "healthy".
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=5 \
  CMD mongosh --quiet --eval "quit(db.adminCommand('ping').ok ? 0 : 1)"

# The image's own entrypoint creates the administrator on the first start (MONGO_INITDB_ROOT_*), then
# runs this. The cache size is added by compose.yml, from SDB_CACHE_GB: it depends on the LXC, not the image.
CMD ["mongod", "--config", "/etc/mongod.conf"]
