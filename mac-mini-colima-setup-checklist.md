# Mac Mini Colima Setup Checklist

This checklist is the operator-friendly companion to [mac-mini-colima-bootstrap.sh](/Users/alecmccauley/Documents/Coworkers/mac-mini-colima-bootstrap.sh).

It is intentionally narrower than [Setting Up Openclaw Agents on Mac Mini.md](/Users/alecmccauley/Documents/Coworkers/Setting%20Up%20Openclaw%20Agents%20on%20Mac%20Mini.md): the goal here is to turn a fresh Apple Silicon Mac mini into a hardened, ARM-native Colima host with one persistent work container running. It does not configure OpenClaw itself, Google Chat, or any tenant-specific secrets. The bootstrap script also does not automate Cloudflare Tunnel setup, but this checklist includes optional manual sections for Cloudflare-backed SSH and browser-rendered VNC access.

## Container Stack Used In This Guide

- `Colima` is the actual container runtime and Linux VM.
- `Docker CLI` is only the command-line client that talks to Colima.
- `Docker Desktop` is not used anywhere in this setup.
- `Rosetta` is intentionally not installed in this guide.
- The persistent work container uses `alpine/openclaw:latest`, but only as a running ARM-native container you can shell into and start working from.
- Despite the repository name, Docker Hub currently notes that this image is built on Debian rather than Alpine.
- This guide does not configure the OpenClaw application inside that image.

## Important Reboot Requirement

- True unattended recovery after a reboot on macOS requires a logged-in user session.
- For this guide, that means:
  - use a dedicated local admin/service user
  - enable automatic login for that user
  - let the script install a user LaunchAgent that starts Colima and the work container at login
- If automatic login is not enabled, the container will not reliably come back until someone logs in again.
- If FileVault is enabled, automatic login is generally unavailable. If unattended restart matters more than at-rest encryption on this device, leave FileVault off for this Mac mini.

## 1. Before First Boot

- [ ] `Manual` Put the Mac mini on stable power. Prefer Ethernet and a UPS.
- [ ] `Manual` Decide on the hostname you want to use.
- [ ] `Manual` Decide on the local service/admin username you want this machine to use long-term.
- [ ] `Manual` If this will run headless, have a temporary monitor/keyboard available for setup. An HDMI dummy plug is optional but useful later for remote GUI troubleshooting.
- [ ] `Manual` During Setup Assistant:
  - skip Apple ID sign-in
  - skip iCloud
  - skip Siri
  - skip analytics sharing
  - skip App Store sign-in
- [ ] `Manual` Create a local admin account only. Do not tie the server to a personal Apple identity.
- [ ] `Manual` After first login, enable automatic login for that dedicated local user.
- [ ] `Manual` If unattended reboot recovery is required, do not enable FileVault on this Mac mini.

## 2. First Login

- [ ] `Manual` Log in as the dedicated local admin/service user.
- [ ] `Manual` Put the repo or the script somewhere accessible on the Mac mini.
- [ ] `Manual` Make the script executable:

```bash
chmod +x mac-mini-colima-bootstrap.sh
```

- [ ] `Manual` Run the script with your hostname. Example:

```bash
./mac-mini-colima-bootstrap.sh \
  --hostname macmini-agents \
  --workspace-root "$HOME/workspace" \
  --container-name workbox \
  --image alpine/openclaw:latest
```

- [ ] `Optional` Run the script in dry-run mode first if you want to inspect every action:

```bash
./mac-mini-colima-bootstrap.sh \
  --dry-run \
  --hostname macmini-agents
```

## 3. What The Script Automates

- [ ] `Automated` Verifies that the host is macOS on Apple Silicon.
- [ ] `Automated` Verifies that you are not running as `root`.
- [ ] `Automated` Verifies `sudo` access.
- [ ] `Automated` Warns if automatic login does not appear to be enabled for the current user.
- [ ] `Automated` Warns if FileVault appears to be enabled.
- [ ] `Automated` Installs Xcode Command Line Tools if needed.
- [ ] `Automated` Installs Homebrew if needed.
- [ ] `Automated` Installs:
  - `colima`
  - `docker`
  - `docker-compose`
  - `jq`
  - `git`
- [ ] `Automated` Applies server-first host tuning from the source doc:
  - restart after power failure
  - no sleep
  - network-over-sleep persistence
  - reduced UI animation overhead
  - Spotlight indexing disabled
  - firewall enabled
  - stealth mode enabled
- [ ] `Automated` Optionally runs `softwareupdate -ia` unless you pass `--skip-macos-update`.
- [ ] `Automated` Starts Colima with Apple-native settings:
  - `vz` virtualization
  - `virtiofs` mounts
  - no Rosetta
- [ ] `Automated` Verifies the Docker CLI can talk to Colima.
- [ ] `Automated` Creates a host workspace directory.
- [ ] `Automated` Pulls `alpine/openclaw:latest` for `linux/arm64`.
- [ ] `Automated` Creates a persistent container named `workbox` by default.
- [ ] `Automated` Sets the container restart policy to `unless-stopped`.
- [ ] `Automated` Installs a wrapper script in `~/bin/`.
- [ ] `Automated` Installs a user LaunchAgent in `~/Library/LaunchAgents/`.
- [ ] `Automated` Loads the LaunchAgent for the current user session.

## 4. Manual Follow-Up After The Script

- [ ] `Manual` Confirm automatic login is enabled for the dedicated local service user.
- [ ] `Manual` Confirm the current user is the one you want launchd to use for Colima recovery.
- [ ] `Manual` Confirm the host tuning landed:

```bash
pmset -g
sudo systemsetup -getrestartpowerfailure
sudo mdutil -s /
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode
```

- [ ] `Manual` Confirm Colima is running:

```bash
colima status
docker info
```

- [ ] `Manual` Confirm the persistent container is running:

```bash
docker ps
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' workbox
```

## 5. Validate The Workspace Mount

- [ ] `Manual` Confirm the host workspace exists:

```bash
ls -la "$HOME/workspace"
```

- [ ] `Manual` Confirm it is mounted into the container:

```bash
docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' workbox
```

- [ ] `Manual` Shell into the container:

```bash
docker exec -it workbox bash
```

- [ ] `Manual` If `bash` is not present, use:

```bash
docker exec -it workbox sh
```

- [ ] `Manual` Inside the container, confirm the working directory:

```sh
pwd
ls -la /workspace
```

## 6. Reboot Recovery Test

- [ ] `Manual` Reboot the Mac mini:

```bash
sudo reboot
```

- [ ] `Manual` Confirm the Mac mini automatically logs in as the dedicated local service user.
- [ ] `Manual` Confirm Colima came back without manual intervention:

```bash
colima status
docker info
```

- [ ] `Manual` Confirm the container is running after reboot:

```bash
docker ps
```

- [ ] `Manual` Confirm you can still shell into it:

```bash
docker exec -it workbox bash
```

## 7. Optional: Secure SSH Access Through Cloudflare Tunnel

- [ ] `Manual` Confirm macOS Remote Login is enabled on the Mac mini:

```bash
sudo systemsetup -setremotelogin on
sudo systemsetup -getremotelogin
```

- [ ] `Manual` Confirm the SSH service is reachable locally on the Mac mini:

```bash
ssh localhost
```

- [ ] `Manual` Install `cloudflared` on the Mac mini:

```bash
brew install cloudflared
cloudflared --version
```

- [ ] `Manual` In the Cloudflare dashboard, create a Cloudflare Tunnel for this Mac mini.
- [ ] `Manual` In that tunnel, publish an SSH route for a hostname you control, pointing to `localhost:22`.
- [ ] `Manual` Add a Cloudflare Access self-hosted application for that SSH hostname and restrict it to the identities allowed to reach this Mac mini.
- [ ] `Manual` Install `cloudflared` on each client machine that will SSH into the Mac mini.
- [ ] `Manual` On each client machine, add an SSH config entry for the tunnel hostname. Example:

```sshconfig
Host ssh.example.com
  User <mac-mini-username>
  ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

- [ ] `Manual` If the `cloudflared` path is different on the client, check it with:

```bash
brew --prefix cloudflared
```

- [ ] `Manual` Test the SSH path from the client machine:

```bash
ssh <mac-mini-username>@ssh.example.com
```

- [ ] `Manual` Confirm `cloudflared` opens the browser for Cloudflare Access authentication and the SSH session lands on the Mac mini.

## 8. Optional: Browser-Rendered VNC Through Cloudflare Tunnel

- [ ] `Manual` Enable Screen Sharing, Remote Management, or another VNC-compatible server on the Mac mini.
- [ ] `Manual` If your VNC server requires its own password, configure that password before exposing it through Cloudflare Access.
- [ ] `Manual` Confirm the VNC service is listening locally on the Mac mini. Example for the default VNC port:

```bash
sudo lsof -nP -iTCP:5900 -sTCP:LISTEN
nc -vz localhost 5900
```

- [ ] `Manual` If the VNC server listens on a non-default port, note that port before creating the Cloudflare route.
- [ ] `Manual` In the Cloudflare dashboard, edit the Mac mini tunnel and add a published application route for a hostname such as `vnc.example.com`.
- [ ] `Manual` For the VNC route service, select `TCP` and point it to `localhost:5900` or your VNC server's local listening port.
- [ ] `Manual` Create a Cloudflare Access self-hosted application for that VNC hostname.
- [ ] `Manual` In the Access application, set Browser rendering to `VNC`.
- [ ] `Manual` Restrict the VNC application to approved identities with `Allow` or `Block` policies only.
- [ ] `Manual` Confirm the VNC Access application does not use `Bypass` or `Service Auth`, because Cloudflare does not support those policy types for browser-rendered applications.
- [ ] `Manual` From a client browser, open `https://vnc.example.com`, authenticate with Cloudflare Access, and enter the VNC password when prompted.
- [ ] `Manual` Confirm the Mac mini desktop renders successfully in the browser.

## 9. Daily Workflow

- [ ] `Manual` Check container status:

```bash
docker ps
```

- [ ] `Manual` Open a shell:

```bash
docker exec -it workbox bash
```

- [ ] `Manual` Work from the bind-mounted directory:
  - host: `$HOME/workspace`
  - container: `/workspace`

- [ ] `Manual` Stop the container only if you really want it down:

```bash
docker stop workbox
```

- [ ] `Manual` Bring it back manually if needed:

```bash
docker start workbox
```

## 10. Source-Doc Recommendations Carried Forward

These recommendations from the source document are intentionally reflected in this host-only guide:

- [ ] `Included` local-only server posture with no Apple ID or iCloud
- [ ] `Included` restart-after-power-failure behavior
- [ ] `Included` no-sleep tuning for headless/server use
- [ ] `Included` reduced UI overhead
- [ ] `Included` Spotlight disablement for lower I/O contention
- [ ] `Included` Apple Silicon-native runtime path
- [ ] `Included` `virtiofs` for fast host/container file access
- [ ] `Included` closed-host posture with macOS firewall and stealth mode
- [ ] `Included` optional manual SSH access through Cloudflare Tunnel with client-side `cloudflared`
- [ ] `Included` optional browser-rendered VNC access through Cloudflare Tunnel and Cloudflare Access

These recommendations are intentionally left out of the bootstrap script because this setup still stops short of full application and tenant provisioning:

- [ ] `Excluded` multi-tenant OpenClaw deployment
- [ ] `Excluded` Google Chat integration
- [ ] `Excluded` OpenClaw app configuration
- [ ] `Excluded` gws skills and tool-policy configuration
- [ ] `Excluded` tenant secrets, service accounts, and API key injection

## 11. When This Host Is Ready

You are ready to start work when all of the following are true:

- [ ] the Mac mini boots after power loss
- [ ] the dedicated service user auto-logs in
- [ ] `colima status` reports running after reboot
- [ ] `docker ps` shows `workbox`
- [ ] `docker exec -it workbox bash` works
- [ ] files created in `$HOME/workspace` are visible in `/workspace`
- [ ] if you are using Cloudflare Tunnel for SSH, `ssh <username>@ssh.example.com` works after Cloudflare Access authentication
- [ ] if you are using browser-rendered VNC through Cloudflare, `https://vnc.example.com` shows the Mac mini desktop after Cloudflare Access authentication
