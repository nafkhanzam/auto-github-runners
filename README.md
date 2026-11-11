# auto-github-runners

Run multiple self-hosted GitHub Actions runners natively on one Linux machine. Each runner gets its own directory and its own systemd service, and they all share one config file.

```
runners/
├── .cache/            # downloaded runner tarball, shared by all runners
├── runner-1/          # github-runner@1.service
├── runner-2/          # github-runner@2.service
└── ...
```

## How it works

- `runners.sh` installs a systemd template unit, `github-runner@.service`, and starts one instance per runner.
- Each instance runs `start.sh`, which:
  1. installs the latest runner release into `runners/runner-N/` if the version there is missing or outdated, verifying the SHA256 checksum,
  2. gets a fresh registration token from the GitHub API using `ACCESS_TOKEN`,
  3. registers as `<NAME>-<hostname>-<N>`, replacing any stale registration,
  4. runs the runner, and on stop deregisters it if `REMOVE_RUNNER_ON_EXIT=true`.
- systemd restarts a runner if it crashes. With `EPHEMERAL=true`, each runner re-registers clean after every job.

## Requirements

- Linux with systemd, on x64, arm64 or arm
- `sudo` access, used only for `systemctl` and writing the unit file
- `bash`, `curl`, `jq`, `tar`, `flock`, `sha256sum`
- Libraries for the runner's .NET runtime:

| Distro        | Command                                                                  |
| ------------- | ------------------------------------------------------------------------ |
| Arch          | `sudo pacman -S --needed jq icu krb5 openssl zlib`                       |
| Debian/Ubuntu | `sudo apt install jq libicu-dev libkrb5-3 libssl3 zlib1g`                |
| Fedora        | `sudo dnf install jq libicu krb5-libs openssl-libs zlib`                 |

On Debian, Ubuntu and Fedora you can also run `runners/runner-1/bin/installdependencies.sh` with sudo after the first runner has been downloaded.

## Setup

### 1. (Recommended) Create a dedicated user

Jobs run with the full permissions of the user that runs the runners. A dedicated user keeps them away from your own files and SSH keys.

```bash
sudo useradd -m -s /bin/bash gh-runner
sudo -iu gh-runner
git clone <this-repo> ~/auto-github-runners
cd ~/auto-github-runners
```

If workflows need Docker, add the user to the `docker` group. Be aware that this effectively gives jobs root on the machine:

```bash
sudo usermod -aG docker gh-runner
```

The runner user needs sudo for `runners.sh`. Alternatively, run the `systemctl` steps from an admin account.

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

This writes `/etc/systemd/system/github-runner@.service` and enables and starts `github-runner@1` through `github-runner@4`. They also start automatically on boot.

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
| `permission denied ... docker.sock`       | Add the runner user to the `docker` group, then `./runners.sh restart`.               |
| `missing dependency: X`                   | Install `X` (see [Requirements](#requirements)).                                      |

## Security notes

- **Never attach self-hosted runners to public repositories.** Fork PRs can run arbitrary code on your machine.
- All runners run as the same user, so they can read each other's directories and workspaces. Use `EPHEMERAL=true` to start every job from a clean registration.
- Keep `.env` at `chmod 600`. It contains a token that can manage runners for your repo or org.
