# Infrastructure Recovery

Public Stage 0 disaster-recovery tooling for rebuilding infrastructure from clean systems and private configuration repositories.

This repository is intentionally public and contains only generic Stage 0 orchestration. Private project repositories remain authoritative for Stage 1 recovery. This repository must never contain secrets, private keys, tokens, `.env` contents, internal configuration, or copied private-repository files.

> The only currently implemented workflow is the Homepage recovery path for the Home Proxmox environment. Review and test changes before using them during an incident.

## One-file usage

The universal entry point is `recovery.sh`. Download only that file on a recovery machine and run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/rootdet/infrastructure-recovery/main/recovery.sh
chmod 700 recovery.sh
sudo ./recovery.sh
```

Normal recovery does not set `INFRASTRUCTURE_RECOVERY_REF`. When it is unset, a standalone launcher downloads the `main` branch automatically. If the launcher is not inside a complete checkout, it downloads the public repository archive into a temporary working directory, validates the expected module tree, and relaunches that repository copy exactly once.

### Development and acceptance-testing override

`INFRASTRUCTURE_RECOVERY_REF` is an optional development/acceptance-testing override. It is intended for testing a candidate commit before that commit is merged into `main`; it is not required for production recovery.

The accepted values are:

- `main`; or
- an exact 40-character hexadecimal Git commit SHA.

Malformed explicit values are rejected with an error. The launcher does not silently fall back to `main` when an override was supplied. For example:

```bash
INFRASTRUCTURE_RECOVERY_REF=0123456789abcdef0123456789abcdef01234567 ./recovery.sh
```

The intended pre-merge acceptance-test workflow is:

```text
download recovery.sh from the candidate commit
→ set INFRASTRUCTURE_RECOVERY_REF to that same commit SHA
→ run recovery.sh
→ standalone launcher downloads that exact revision
```

The normal end-user command above remains unchanged and continues to use `main` automatically.

## Dynamic architecture

`recovery.sh` discovers immediate child directories with a valid `recovery.conf` as environments. Within the selected environment it discovers immediate child directories containing both a valid `recovery.conf` and `recover.sh` as targets. It executes only a validated module's specifically named `recover.sh`, never arbitrary shell files.

Metadata is declarative and never sourced or executed. Supported fields are `name` and a non-negative integer `order`; unknown fields are ignored and malformed metadata is skipped. Entries sort by order, then human-readable name, then path for deterministic menus.

```text
infrastructure-recovery/
├── README.md
├── recovery.sh
└── proxmox-home/
    ├── recovery.conf
    └── homepage/
        ├── recovery.conf
        └── recover.sh
```

To add an environment, add a directory with a valid metadata file. To add a target, add a child directory with both metadata and `recover.sh`. No additional modules are included today.

## Homepage Stage 0 workflow

The Homepage module requires root and an installation at `/opt/homepage`. It verifies or installs the basic Git/OpenSSH prerequisites through `apt-get` when appropriate, prepares `/root/.ssh`, and creates or safely reuses these ED25519 deploy keys without overwriting existing private keys:

- `github-homepage-config` for `rootdet/homepage-dashboard`
- `github-homepage-integrations` for `rootdet/homepage-integrations`

SSH aliases target GitHub with their corresponding identity and `IdentitiesOnly yes`. Existing unrelated SSH configuration is preserved. Unsafe or ambiguous configuration causes a safe stop.

For each private repository, Stage 0 first tests `git ls-remote` through the configured alias. If access already works, it does not display a key or pause. Otherwise it displays only the public key, asks the operator to add it manually as a deploy key, pauses, and verifies repository access. No GitHub API, PAT, token, browser automation, or automatic deploy-key registration is used.

The module reuses an existing checkout only when it is a Git checkout with exactly the expected origin. It never resets local changes. A wrong remote fails. A non-Git or otherwise unknown `/opt/homepage/config` is never silently assumed to be the stock Community Scripts skeleton: the operator must explicitly type the exact `MOVE ...` confirmation before it is moved to a timestamped backup. Nothing is deleted or overwritten.

The operator restores `/opt/secrets/homepage.env` and `/opt/secrets/python_http.env` from secure external backup. The files are checked without printing contents and enforced as root-owned `0600`, with `/opt/secrets` root-owned `0700`. Finally Stage 0 invokes `/opt/homepage/config/deployment/bootstrap.sh`; private Stage 1 remains responsible for `/opt/python_http`, dependencies, services, cron, runtime directories, and final validation. Stage 1 failure is reported and its exit status is preserved.

## Safety and reruns

The workflow is designed to stop rather than guess. Existing keys and authorized repository access are reused. Existing correct checkouts and aliases are reused, while local changes are preserved. Ambiguous state requires operator action. Secret and private-key contents are never printed or committed.

The security boundary is:

```text
generate key locally
→ display public key only when access is not already valid
→ operator adds deploy key manually
→ Stage 0 verifies private repository access
→ private Stage 1 performs deployment
```

## Validation

Shell syntax and ShellCheck should be run from a development checkout when those tools are available:

```bash
bash -n recovery.sh proxmox-home/homepage/recover.sh
shellcheck recovery.sh proxmox-home/homepage/recover.sh

git diff --check
```

Runtime testing of the Homepage module requires a root Homepage LXC and access to the private repositories, neither of which is provided by this public repository. Do not test it against fake secrets or private configuration copied into this repository.
