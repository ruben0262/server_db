# server_db's image: MongoDB, one exact version (the one Atlas and the laptops run), with this
# server's settings built in (mongod.conf). Built on the server by `bin/sdb up`; nothing is pulled at
# start but this one base image, and only when the version line below changes.
FROM mongo:8.0.34

COPY mongod.conf /etc/mongod.conf

# A ping needs no login, so the check never holds a password. `bin/sdb up` waits for "healthy".
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=5 \
  CMD mongosh --quiet --eval "quit(db.adminCommand('ping').ok ? 0 : 1)"

# The image's own entrypoint creates the administrator on the first start (MONGO_INITDB_ROOT_*), then
# runs this. The cache size is added by compose.yml, from SDB_CACHE_GB: it depends on the VM, not the image.
CMD ["mongod", "--config", "/etc/mongod.conf"]
