# shellcheck shell=bash
# Service descriptor: redis — Redis key-value store (databases topic).
#   wsl → systemd unit `redis-server` (apt pkg name; topics/databases/wsl/redis.sh).
#   mac → brew formula `redis` (topics/databases/mac/redis.sh).
# Opt-out at boot on WSL by default (T-006).
svcdef_redis_meta()   { echo "Redis|redis-server|databases"; }
svcdef_redis_wsl()    { echo "systemd|system|redis-server"; }
svcdef_redis_mac()    { echo "brew||redis"; }
svcdef_redis_optout() { echo "wsl"; }
