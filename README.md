# auto-github-runners

Run multiple self-hosted GitHub Actions runners natively on one Linux machine. Each runner gets its own directory and its own systemd **user** service, and they all share one config file. No root or sudo is needed.

```
runners/
├── .cache/            # downloaded runner tarball, shared by all runners
├── runner-1/          # github-runner@1.service
├── runner-2/          # github-runner@2.service
└── ...
```

## How it works

- `runners.sh` installs a systemd user template unit, `~/.config/systemd/user/github-runner@.service`, and starts one instance per runner under your own user manager (`systemctl --user`).
- Each instance runs `start.sh`, which:
  1. installs the latest runner release into `runners/runner-N/` if the version there is missing or outdated, verifying the SHA256 checksum,
  2. gets a fresh registration token from the GitHub API using `ACCESS_TOKEN`,
  3. registers as `<NAME>-<hostname>-<N>`, replacing any stale registration,
  4. runs the runner, and on stop deregisters it if `REMOVE_RUNNER_ON_EXIT=true`.
- systemd restarts a runner if it crashes. With `EPHEMERAL=true`, each runner re-registers clean after every job.

## Requirements

- Linux with systemd, on x64, arm64 or arm
- A normal user account. No sudo or `wheel` membership required.
- Lingering enabled for that user, so runners keep running after logout and start on boot (see [step 4](#4-start-runners))
- `bash`, `curl`, `jq`, `tar`, `flock`, `sha256sum`
- Libraries for the runner's .NET runtime. These are system packages; if they're missing, ask an admin to install them:

| Distro        | Command                                                                  |
| ------------- | ------------------------------------------------------------------------ |
| Arch          | `sudo pacman -S --needed jq icu krb5 openssl zlib`                       |
| Debian/Ubuntu | `sudo apt install jq libicu-dev libkrb5-3 libssl3 zlib1g`                |
| Fedora        | `sudo dnf install jq libicu krb5-libs openssl-libs zlib`                 |

## Setup

### 1. Clone

Log in **directly** as the user the runners should run as (SSH or console). `su` / `sudo -u` sessions have no systemd user bus, and `runners.sh` will refuse to run.

```bash
git clone https://github.com/nafkhanzam/auto-github-runners.git ~/auto-github-runners
cd ~/auto-github-runners
```

Jobs run with the full permissions of this user. If an admin can create a dedicated account for the runners, use that to keep jobs away from your own files and SSH keys.

If workflows need Docker, an admin must add the user to the `docker` group (this effectively gives jobs root on the machine), or use [rootless Docker](https://docs.docker.com/engine/security/rootless/).

### 2. Create a GitHub token

Create a Personal Access Token at <https://github.com/settings/tokens> with one of these permission sets:

| Target                    | Classic PAT scope | Fine-grained PAT permission             |
| ------------------------- | ----------------- | --------------------------------------- |
| Repository (`owner/repo`) | `repo`            | Repository → Administration: read/write |
| Organization (`org`)      | `admin:org`       | Organization → Self-hosted runners: read/write |

The token is used only to mint short-lived registration and removal tokens.

### 3. Configure

```bash
cp .env.example .env
chmod 600 .env        # holds your token
$EDITOR .env
```

At minimum, set:

```dotenv
REPO=my-org/my-repo        # or just `my-org` for org-level runners
ACCESS_TOKEN=ghp_xxx
NAME=my-runner
```

See [`.env.example`](.env.example) for all options: `LABELS`, `RUNNER_GROUP`, `EPHEMERAL`, `RUNNER_BASE_DIR`, and others.

> Leave `WORK_DIR` relative, or unset. An absolute path would be shared by every runner, and their jobs would collide.

### 4. Start runners

```bash
./runners.sh scale 4
```

This writes `~/.config/systemd/user/github-runner@.service` and enables and starts `github-runner@1` through `github-runner@4` with `systemctl --user`.

It also tries `loginctl enable-linger $USER`. Without lingering, systemd kills your user services when your last session ends and won't start them at boot. Most distros let a user enable it for themselves from a local session, but over SSH polkit may require an admin. If you see a lingering warning, ask an admin to run once:

```bash
loginctl enable-linger <your-user>
```

Check with `loginctl show-user $USER -p Linger`.

### 5. Verify

```bash
./runners.sh status
./runners.sh logs 1
```

The runners should show as **Idle** under *Settings → Actions → Runners* on GitHub.

### 6. Use in a workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
```

## Day-to-day

| Task                               | Command                  |
| ---------------------------------- | ------------------------ |
| Change the number of runners       | `./runners.sh scale <N>` |
| Show service status                | `./runners.sh status`    |
| Follow logs (all, or runner N)     | `./runners.sh logs [N]`  |
| Apply `.env` changes               | `./runners.sh restart`   |
| Remove everything and deregister   | `./runners.sh down`      |

Scaling down stops the extra runners, deregisters them from GitHub and deletes their directories. A runner that's busy is given up to 10 minutes to stop.

### Runner version

Runners always use the latest release of [actions/runner](https://github.com/actions/runner/releases):

- On every start, `start.sh` checks the latest release. If the installed version is older, it reinstalls from the shared cache, keeping `_work`. The new release is downloaded once for all runners, and older cached tarballs are deleted.
- Runners that are already running update themselves in place when GitHub announces a new release.
- If GitHub can't be reached at start, the installed version is used.

To force every runner onto the newest version right away, run `./runners.sh restart`.

## Troubleshooting

| Symptom                                   | Fix                                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------------------- |
| `ACCESS_TOKEN env var required`           | Set `ACCESS_TOKEN` in `.env`.                                                         |
| `curl: (22) ... 403/404` on token request | The PAT lacks the required scope, or `REPO` is wrong (org vs `owner/repo`).           |
| `Couldn't find a valid ICU package`       | Install the ICU library for your distro (see [Requirements](#requirements)).         |
| Runner stuck **Offline** on GitHub        | Run `./runners.sh logs N`. Usually a network or token issue.                          |
| `permission denied ... docker.sock`       | Ask an admin to add the user to the `docker` group, or use rootless Docker; then `./runners.sh restart`. |
| `cannot reach the systemd user manager`   | Log in directly as the runner user (SSH/console), not via `su` / `sudo -u`.           |
| Runners stop when you log out             | Lingering is off. Ask an admin to run `loginctl enable-linger <user>`.               |
| `./runners.sh logs` shows nothing         | Per-user journals need persistent journald storage (`/var/log/journal`). Ask an admin, or use `./runners.sh status`. |
| `missing dependency: X`                   | Install `X` (see [Requirements](#requirements)).                                      |

## Security notes

- **Never attach self-hosted runners to public repositories.** Fork PRs can run arbitrary code on your machine.
- All runners run as the same user, so they can read each other's directories and workspaces. Use `EPHEMERAL=true` to start every job from a clean registration.
- Keep `.env` at `chmod 600`. It contains a token that can manage runners for your repo or org.
