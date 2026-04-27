# Standalone justfile - intended to be invoked via:
#   just --justfile prep.just nerdctl
#   just --justfile prep.just docker
#   just --justfile prep.just kubernetes
#   just --justfile prep.just kubernetes
#
# Upstream repos should use a thin dispatcher pattern:
#   prep *args:
#     @curl -sS https://raw.githubusercontent.com/hotosm/justfiles/main/prep.just \
#       -o {{justfile_directory()}}/tasks/prep.just;
#     @just --justfile {{justfile_directory()}}/tasks/prep.just {{args}}
#
# Note that nerdctl support is experimental. In theory it has some improvements
# over compose, such as faster rootless networking, but it does not support
# sharing a network namespace between containers (needed for local dev):
# https://github.com/containerd/nerdctl/issues/2833

_self := justfile()

# List available recipes
[private]
default:
  @just --justfile {{_self}} --list

[private]
[no-cd]
_echo-red msg:
  @printf '\033[0;31m%s\033[0m\n' '{{msg}}'

[private]
[no-cd]
_echo-yellow msg:
  @printf '\033[0;33m%s\033[0m\n' '{{msg}}'

[private]
[no-cd]
_echo-blue msg:
  @printf '\033[0;34m%s\033[0m\n' '{{msg}}'

[no-cd]
_curl:
  #!/usr/bin/env bash
  set -euo pipefail
  if command -v curl &> /dev/null; then
    exit 0
  fi
  sudo apt-get update
  sudo apt-get install --no-install-recommends -y curl ca-certificates

[no-cd]
_get_arch:
  #!/usr/bin/env sh
  set -e
  dpkg --print-architecture

# Check the current user is not root
[no-cd]
_check_not_root:
  #!/usr/bin/env bash
  set -euo pipefail

  echo "Current user:"
  echo "$(id)"
  if [ "$(id -u)" == 0 ]; then
    just --justfile {{_self}} _echo-red "Currently logged in as root. Please login as a different user."
    echo ""
    just --justfile {{_self}} _echo-yellow "Create a new user and grant sudo privileges with:"
    just --justfile {{_self}} _echo-yellow "    adduser myuser"
    just --justfile {{_self}} _echo-yellow "    usermod -aG sudo myuser     # (use 'wheel' instead of 'sudo' on RHEL/Fedora)"
    echo ""
    just --justfile {{_self}} _echo-yellow "Then log in as that user with a full PAM session (not 'su -'):"
    just --justfile {{_self}} _echo-yellow "First 'apt install systemd-container', then"
    just --justfile {{_self}} _echo-yellow "    machinectl shell myuser@"
    echo ""
    just --justfile {{_self}} _echo-yellow "⚠️ Make sure to remove the user from sudoers when you're done."
    just --justfile {{_self}} _echo-yellow "    usermod -rG sudo myuser"

    exit 1
  fi

# Low level container runtime
[no-cd]
_runc:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{justfile_directory()}}

  if command -v runc &> /dev/null; then
    just --justfile {{_self}} _echo-yellow "Binary 'runc' already installed"
    exit 0
  fi

  just --justfile {{_self}} _curl

  VERSION=1.4.2
  ARCH=$(just --justfile {{_self}} _get_arch)
  URL="https://github.com/opencontainers/runc/releases/download/v${VERSION}/runc.${ARCH}"

  just --justfile {{_self}} _echo-blue "Installing low level container runtime: runc"
  sudo curl -SL "${URL}" -o /usr/local/bin/runc
  sudo chmod +x /usr/local/bin/runc

# High level container runtime + CLI
[no-cd]
_nerdctl_containerd:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{justfile_directory()}}

  if command -v containerd &> /dev/null; then
    just --justfile {{_self}} _echo-yellow "Binary 'containerd' already installed. Exiting."
    exit 0
  fi
  if command -v nerdctl &> /dev/null; then
    just --justfile {{_self}} _echo-yellow "Binary 'nerdctl' already installed. Exiting."
    exit 0
  fi

  just --justfile {{_self}} _curl

  just --justfile {{_self}} _echo-blue "Installing high level container runtime: containerd + nerdctl CLI"
  VERSION=2.2.2
  ARCH=$(just --justfile {{_self}} _get_arch)
  URL="https://github.com/containerd/nerdctl/releases/download/v${VERSION}/nerdctl-full-${VERSION}-linux-${ARCH}.tar.gz"

  TMP_DIR=$(mktemp -d)
  curl -SL "${URL}" -o "${TMP_DIR}/nerdctl-${VERSION}-linux-${ARCH}.tar.gz"
  sudo tar Cxzvvf /usr/local "${TMP_DIR}/nerdctl-${VERSION}-linux-${ARCH}.tar.gz"

# Convert containerd to rootless mode
[no-cd]
_containerd_rootless:
  #!/usr/bin/env bash
  set -euo pipefail
  just --justfile {{_self}} _echo-blue "Converting containerd --> rootless install"

  # uidmap is needed for 'newuidmap' and 'newgidmap' binaries
  # dbus-user-session is needed for userspace systemd
  sudo apt-get install --no-install-recommends -y uidmap dbus-user-session iptables
  # Ensure iptables alternative is configured (may not be set on minimal installs)
  if ! command -v iptables &> /dev/null; then
    sudo update-alternatives --set iptables /usr/sbin/iptables-nft
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
  fi
  # Rootless containerd may not have /usr/sbin in PATH, so ensure iptables is reachable
  if [ ! -e /usr/local/bin/iptables ]; then
    sudo ln -s "$(update-alternatives --query iptables | grep Value | awk '{print $2}')" /usr/local/bin/iptables
  fi
  systemctl --user start dbus

  # AppArmor required for Ubuntu 24.04 onwards
  # https://rootlesscontaine.rs/getting-started/common/apparmor/
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "ubuntu" ] && [ "${VERSION_ID%%.*}" -ge 24 ]; then
      rootlesskit_path="$(command -v rootlesskit || true)"
      if [ -n "$rootlesskit_path" ] && [ "$rootlesskit_path" != "/usr/bin/rootlesskit" ]; then
        # Set temp
        echo 0 | sudo tee /proc/sys/kernel/apparmor_restrict_unprivileged_userns
        # Set on restart
        profile_path="/etc/apparmor.d/${rootlesskit_path#/}"
        sudo mkdir -p "$(dirname "$profile_path")"
        just --justfile {{_self}} _echo-yellow "Configuring AppArmor for rootlesskit at $rootlesskit_path"
        {
          echo 'abi <abi/4.0>,'
          echo 'include <tunables/global>'
          echo "${rootlesskit_path} flags=(unconfined) {"
          echo "  userns,"
          echo "  # Site-specific additions and overrides. See local/README for details."
          echo "  include if exists <local/${rootlesskit_path#/}>"
          echo "}"
        } | sudo tee "$profile_path" >/dev/null
        sudo systemctl restart apparmor.service
      fi
    fi
  fi

  containerd-rootless-setuptool.sh install

  # Enable containerd on startup
  sudo loginctl enable-linger "$(id -un)"

  # Ensure buildkit is installed
  containerd-rootless-setuptool.sh install-buildkit

  # Enable bypass4netnsd rootless network accelerator
  containerd-rootless-setuptool.sh install-bypass4netnsd

  # Enable lazy image pulling
  containerd-rootless-setuptool.sh install-stargz
  sudo mkdir -p "/home/$(id -un)/.config/containerd"
  config_file="/home/$(id -un)/.config/containerd/config.toml"
  if ! grep -q 'proxy_plugins."stargz"' "$config_file" 2>/dev/null; then
    {
      echo '[proxy_plugins]'
      echo '  [proxy_plugins."stargz"]'
      echo '    type = "snapshot"'
      echo "    address = \"/run/user/$(id -u)/containerd-stargz-grpc/containerd-stargz-grpc.sock\""
    } | tee -a "$config_file" > /dev/null
  fi
  # containerd restart required
  systemctl --user restart containerd.service

  # Usage of priv ports below 1024
  # https://rootlesscontaine.rs/getting-started/common/sysctl/
  echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/99-rootless.conf
  sudo sysctl --system

[no-cd]
_nerdctl_docker_alias:
  #!/usr/bin/env bash
  set -euo pipefail
  just --justfile {{_self}} _echo-blue "Adding docker --> nerdctl alias to bashrc"

  stargz_env_var='export CONTAINERD_SNAPSHOTTER="stargz"'
  docker_alias_cmd="alias docker='nerdctl'"
  dc_alias_cmd="alias dc='nerdctl compose'"

  for cmd in "$stargz_env_var" "$docker_alias_cmd" "$dc_alias_cmd"; do
    if ! grep -Fxq "$cmd" ~/.bashrc; then
      echo "$cmd" >> ~/.bashrc
    fi
  done

  echo ""
  just --justfile {{_self}} _echo-yellow "To use the 'docker' alias, login and log out."
  just --justfile {{_self}} _echo-yellow "Or run:"
  just --justfile {{_self}} _echo-yellow "    source ~/.bashrc"

# Install nerdctl container engine (NOTE: do not run as root!)
[no-cd]
nerdctl:
  #!/usr/bin/env bash
  set -euo pipefail

  just --justfile {{_self}} _check_not_root
  just --justfile {{_self}} _runc
  just --justfile {{_self}} _nerdctl_containerd
  just --justfile {{_self}} _containerd_rootless
  just --justfile {{_self}} _nerdctl_docker_alias

# Install Docker Engine + Docker Compose (NOTE: do not run as root!)
[no-cd]
docker:
  #!/usr/bin/env bash
  set -euo pipefail

  just --justfile {{_self}} _check_not_root
  just --justfile {{_self}} _curl

  if command -v docker &> /dev/null; then
    just --justfile {{_self}} _echo-yellow "Docker is already installed."
    docker --version
    exit 0
  fi

  just --justfile {{_self}} _echo-blue "Installing Docker Engine + Docker Compose via official convenience script"

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  curl -fsSL https://get.docker.com -o "$TMP_DIR/get-docker.sh"
  sudo sh "$TMP_DIR/get-docker.sh"

  # Add current user to docker group so we can run without sudo
  just --justfile {{_self}} _echo-blue "Adding current user to 'docker' group"
  sudo usermod -aG docker "$(id -un)"

  # Enable and start Docker service
  sudo systemctl enable docker
  sudo systemctl start docker

  echo ""
  just --justfile {{_self}} _echo-yellow "Docker installed successfully."
  docker --version
  echo ""
  just --justfile {{_self}} _echo-yellow "You may need to log out and back in for the docker group to take effect."
  just --justfile {{_self}} _echo-yellow "Or run:"
  just --justfile {{_self}} _echo-yellow "    newgrp docker"

# Install k3s Kubernetes distribution (NOTE: do not run as root!)
[no-cd]
kubernetes:
  #!/usr/bin/env bash
  set -euo pipefail

  just --justfile {{_self}} _check_not_root
  just --justfile {{_self}} _curl

  if command -v k3s &> /dev/null; then
    just --justfile {{_self}} _echo-yellow "k3s is already installed."
    k3s --version
    exit 0
  fi

  K3S_VERSION="v1.35.3+k3s1"
  just --justfile {{_self}} _echo-blue "Installing k3s ${K3S_VERSION}"

  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -

  # Allow current user to access kubeconfig without sudo
  just --justfile {{_self}} _echo-blue "Configuring kubeconfig access for current user"
  sudo chmod 644 /etc/rancher/k3s/k3s.yaml

  # Set up KUBECONFIG in bashrc
  kubeconfig_line='export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"'
  if ! grep -Fxq "$kubeconfig_line" ~/.bashrc; then
    echo "$kubeconfig_line" >> ~/.bashrc
  fi

  # Install kubectl alias if kubectl is not already present
  if ! command -v kubectl &> /dev/null; then
    kubectl_alias='alias kubectl="k3s kubectl"'
    if ! grep -Fxq "$kubectl_alias" ~/.bashrc; then
      echo "$kubectl_alias" >> ~/.bashrc
    fi
  fi

  echo ""
  just --justfile {{_self}} _echo-yellow "k3s installed successfully."
  k3s --version
  echo ""
  just --justfile {{_self}} _echo-yellow "To use kubectl, log out and back in, or run:"
  just --justfile {{_self}} _echo-yellow "    source ~/.bashrc"

# Install envsubst
[no-cd]
[no-exit-message]
envsubst:
  #!/usr/bin/env bash
  echo
  # Get a8m/envsubst (required for default vals syntax ${VAR:-default})
  # Use local version, as envsubst may be installed on system already
  if [ -f ./envsubst ]; then
      echo "envsubst already exists. Continuing."
  else
      echo "Downloading a8m/envsubst"
      echo
      curl -L "https://github.com/a8m/envsubst/releases/download/v1.2.0/envsubst-$(uname -s)-$(uname -m)" -o envsubst
      chmod +x envsubst
  fi
