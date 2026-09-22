# Infrastructure Recovery

Public Stage 0 disaster-recovery tooling for rebuilding infrastructure from clean systems and private configuration repositories.

This public repository contains the Stage 0 tooling required to begin recovery from a clean system and obtain access to private recovery sources.

Sensitive configuration, credentials, private recovery procedures, and environment-specific deployment logic remain in secure backups and private Stage 1 repositories. Do not add them to this repository.

> Review and test recovery changes before relying on them during an incident.

## Launch

```bash
curl -fsSLO https://raw.githubusercontent.com/rootdet/infrastructure-recovery/main/recovery.sh
chmod 700 recovery.sh
sudo ./recovery.sh
```

The launcher can run as a standalone file or from a complete checkout. It retrieves and validates the public Stage 0 module tree when necessary, then presents menus for the available recovery environments and targets.

## Recovery model

Recovery is split into two stages:

1. **Public Stage 0** performs the generic bootstrap and access steps needed to begin recovery.
2. **Private Stage 1** provides sensitive configuration, detailed recovery procedures, and environment-specific deployment logic.

Stage 0 is intentionally self-contained and performs the required recovery orchestration. It does not publish sensitive storage layout, secret filenames, credential locations, key-management details, or private Stage 1 implementation.

Sensitive configuration must be restored from secure backup. Detailed recovery instructions remain in the applicable private Stage 1 repositories.

## Development and validation

For development or acceptance testing, `INFRASTRUCTURE_RECOVERY_REF` may be set to `main` or an exact 40-character commit SHA. Invalid values are rejected.

Run:

```bash
bash -n recovery.sh proxmox-home/homepage/recover.sh
shellcheck recovery.sh proxmox-home/homepage/recover.sh
git diff --check
```

Runtime validation requires an authorized recovery environment and private recovery materials. Never copy secrets or private configuration into this repository for testing.
