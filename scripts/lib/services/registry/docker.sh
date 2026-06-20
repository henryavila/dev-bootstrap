# shellcheck shell=bash
# Service descriptor: docker — Docker Engine daemon (containers topic).
#   wsl → systemd unit `docker` (topics/containers/post-setup-wsl.sh).
#   mac → Docker Desktop is a GUI app, not a brew service / launchd daemon the
#         mesh manages, so docker has NO mac mapping (omitted ⇒ not listed on
#         mac); `mesh services --all` still surfaces whatever is discoverable.
# linux reuses the wsl systemd mapping. Opt-out at boot on WSL by default (T-006):
# kept installed but not autostarted unless the host's services.default opts in.
svcdef_docker_meta()   { echo "Docker|dockerd,docker-ce|containers"; }
svcdef_docker_wsl()    { echo "systemd|system|docker"; }
svcdef_docker_optout() { echo "wsl"; }
