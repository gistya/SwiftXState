# Setting up a Linux VM on macOS to Run SwiftXState

**The easiest and most recommended way is using Multipass** (from Canonical). It's lightweight, CLI-first, and perfect for quick Ubuntu VMs — especially for Swift/Vapor testing.

### 1. Install Multipass (if not already installed)

On **macOS** (you seem to be on macOS based on your Swift dev setup):

```bash
brew install --cask multipass
```

Or download the `.pkg` from [multipass.run](https://multipass.run/).

On **Linux**:
```bash
sudo snap install multipass
```

### 2. Create the VM in your desired location

Multipass stores VMs in a default location (usually under `/var` or `~/Library`), but you can **mount** your host directory into the VM for easy access, or redirect storage (more advanced).

For simplicity, create the VM with plenty of disk space:

```bash
mkdir -p ~/dev/vm/ubuntu/test

# Launch a Ubuntu VM (latest LTS recommended) with good resources for Swift + Vapor
multipass launch 24.04 \
  --name swift-test \
  --cpus 4 \
  --memory 8G \
  --disk 40G
```

- **40G disk** should be more than enough (Ubuntu ~5-8GB + Swift toolchain ~2-3GB + Vapor deps/builds).
- You can increase later if needed: `multipass set local.swift-test.disk=60G` (after stopping the VM).

### 3. Access and set it up

```bash
# Shell into the VM
multipass shell swift-test

# Inside the VM:
sudo apt update && sudo apt upgrade -y

# Install dependencies for Swift
sudo apt install -y curl git build-essential libssl-dev pkg-config lsb-release

# Install latest Swift (example for Swift 6.0 or check swift.org for latest)
curl -s https://swift.org/keys/all-keys.asc | sudo apt-key add -
# Follow official instructions: https://swift.org/install/linux/

# Or use the official script / Docker inside the VM if preferred
```

**Mount your project directory** for easy editing from host:

```bash
# From host (while VM is running)
multipass mount ~/dev/vm/ubuntu/test swift-test:/home/ubuntu/test
```

Now you can `cd /home/ubuntu/test` inside the VM and work on your Swift package.

### Quick test commands inside the VM

```bash
# Install Vapor (example)
swift package init --type executable   # or use your existing package
swift build
swift run

# For full Vapor stack:
# curl -sL https://swift.org/install.sh | bash   # or swiftly:
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && \
tar zxf swiftly-$(uname -m).tar.gz && \
./swiftly init --quiet-shell-followup && \
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && \
hash -r

# set your toolchain
swiftly use 6.3.2

# then install Swiftly's recommended stuff:
sudo apt-get -y install unzip gnupg2 libcurl4-openssl-dev libpython3-dev libxml2-dev libncurses-dev libz3-dev zlib1g-dev
```

### Other Useful Multipass commands

```bash
multipass list
multipass info swift-test
multipass stop swift-test
multipass start swift-test
multipass delete swift-test && multipass purge   # clean up
```

This setup is much lighter and faster than full VirtualBox/UTM for server-style testing. Let me know if you prefer **QEMU/KVM** (more manual) or **VirtualBox** instead!

# Now that your VM is setup...

## Getting the package into the VM

Recommended: mount the host repo (already active on your swift-test instance):

`multipass mount (path_to)/swift-xstate swift-test:/home/ubuntu/swift-xstate`

That gives you live edits on the Mac reflected in the VM — no copy/rsync step. multipass info swift-test should show:

Mounts: (path_to)/swift-xstate => /home/ubuntu/swift-xstate

After a VM reboot, remount with the same command.

Alternatives if you don’t want a mount:

```
# rsync once (or whenever you want a snapshot)
multipass transfer -r (path_to_)/swift-xstate swift-test:/home/ubuntu/

# or clone inside the VM if the repo is on GitHub
multipass shell swift-test
git clone <your-repo-url> ~/swift-xstate
```

## Running tests

From the host (no interactive shell):

```
multipass exec swift-test -- bash -lc 'cd /home/ubuntu/swift-xstate && ./Scripts/linux-smoke-test.sh'
```

Or interactively:

```
multipass shell swift-test
cd /home/ubuntu/swift-xstate
./Scripts/linux-smoke-test.sh
```

## Important: .build on mounted dirs

Multipass mounts are effectively read-only for Swift’s .build directory (Operation not permitted). The smoke script now uses a build path outside the mount:

```
# default: ~/swift-build/swift-xstate inside the VM
SWIFTXSTATE_LINUX_BUILD_PATH=~/swift-build/swift-xstate ./Scripts/linux-smoke-test.sh
```
## Current Status on Linux

Current status: 

- all three core targets build on Linux (Swift 6.3.2, aarch64)
- 153/156 core tests pass
- Three stop-related tests fail because the child is still `.active` when the assertion runs, likely a timing/cancellation difference on Linux, not a mount/setup issue