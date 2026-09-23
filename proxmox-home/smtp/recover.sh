#!/usr/bin/env bash
# Stage 0 workflow; private deployment logic remains in Stage 1.
set -Eeuo pipefail

readonly SMTP_REPO='rootdet/smtp-data'
readonly SMTP_ROOT='/data'
readonly SSH_DIR='/root/.ssh'
readonly BOOTSTRAP="$SMTP_ROOT/deployment/bootstrap.sh"
readonly VALIDATE="$SMTP_ROOT/deployment/validate.sh"
readonly RECOVERY_KNOWN_HOSTS="$SSH_DIR/known_hosts.infrastructure-recovery"
readonly GITHUB_KNOWN_HOSTS_ENTRY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n%s\n' "$1" "$2"; }

smtp_repository_origin_ok() {
  case $1 in
    'git@github-smtp-data:rootdet/smtp-data' \
    | 'git@github-smtp-data:rootdet/smtp-data.git' \
    | 'git@github.com:rootdet/smtp-data' \
    | 'git@github.com:rootdet/smtp-data.git' \
    | 'https://github.com/rootdet/smtp-data' \
    | 'https://github.com/rootdet/smtp-data.git' \
    | 'ssh://git@github.com/rootdet/smtp-data' \
    | 'ssh://git@github.com/rootdet/smtp-data.git')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_smtp_lxc() {
  local hostname_short hostname_fqdn os_id os_version
  [[ $EUID -eq 0 ]] || fail 'Run this recovery as root.'
  command -v systemctl >/dev/null 2>&1 || fail 'This recovery requires systemd. Prepare the clean SMTP LXC correctly, then rerun.'
  [[ -d /run/systemd/system ]] || fail 'systemd is not running. Prepare the clean SMTP LXC correctly, then rerun.'
  [[ -r /etc/os-release ]] || fail 'Cannot identify the operating system. Prepare a clean Debian 13 Trixie SMTP LXC, then rerun.'
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id=${ID:-}
  os_version=${VERSION_ID:-}
  [[ $os_id == debian && $os_version == 13 ]] || fail "Expected Debian 13 Trixie; found ${PRETTY_NAME:-unknown}. Prepare the clean SMTP LXC correctly, then rerun."
  hostname_short=$(hostname)
  hostname_fqdn=$(hostname -f 2>/dev/null) || fail 'Could not determine the FQDN. Prepare hostname and resolver settings before running recovery.'
  [[ $hostname_short == smtp ]] || fail "Expected short hostname smtp; found $hostname_short. Do not change it here—prepare the clean SMTP LXC correctly, then rerun."
  [[ $hostname_fqdn == smtp.internal.easynoc.net ]] || fail "Expected FQDN smtp.internal.easynoc.net; found $hostname_fqdn. Do not change it here—prepare the clean SMTP LXC correctly, then rerun."
}

require_smtp_lxc

step 'Step 1: verify prerequisites' 'Checking the prepared SMTP LXC and Stage 0 tools.'
missing_tools=()
for tool in git ssh ssh-keygen; do command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool"); done
if ((${#missing_tools[@]})); then
  command -v apt-get >/dev/null 2>&1 || fail "Missing ${missing_tools[*]}; install Git and the OpenSSH client, then rerun."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git openssh-client ca-certificates
fi

step 'Step 2: prepare repository access' 'Preparing secure GitHub access for the private SMTP recovery repository.'
[[ ! -e $SSH_DIR || -d $SSH_DIR ]] || fail "$SSH_DIR is not a directory. Nothing was changed."
mkdir -p "$SSH_DIR"; chown root:root "$SSH_DIR"; chmod 700 "$SSH_DIR"

ensure_github_known_host() {
  local line_count
  [[ ! -e $RECOVERY_KNOWN_HOSTS || -f $RECOVERY_KNOWN_HOSTS ]] || fail "$RECOVERY_KNOWN_HOSTS is not a regular file; refusing to modify it."
  [[ ! -L $RECOVERY_KNOWN_HOSTS ]] || fail "$RECOVERY_KNOWN_HOSTS is a symlink; refusing to modify it."
  if [[ -e $RECOVERY_KNOWN_HOSTS ]]; then
    line_count=$(wc -l < "$RECOVERY_KNOWN_HOSTS")
    [[ $line_count -eq 1 ]] || fail "$RECOVERY_KNOWN_HOSTS must contain exactly the pinned GitHub host-key entry. Resolve it manually before rerunning."
    grep -Fqx "$GITHUB_KNOWN_HOSTS_ENTRY" "$RECOVERY_KNOWN_HOSTS" || fail "$RECOVERY_KNOWN_HOSTS does not contain exactly the expected published GitHub key. Resolve it manually before rerunning."
  else
    (umask 077 && printf '%s\n' "$GITHUB_KNOWN_HOSTS_ENTRY" > "$RECOVERY_KNOWN_HOSTS") || fail "Could not create $RECOVERY_KNOWN_HOSTS."
  fi
  chown root:root "$RECOVERY_KNOWN_HOSTS"
  chmod 600 "$RECOVERY_KNOWN_HOSTS"
  [[ $(stat -c '%U:%G %a' "$RECOVERY_KNOWN_HOSTS") == 'root:root 600' ]] || fail "Could not establish safe ownership and permissions for $RECOVERY_KNOWN_HOSTS."
}

ensure_key() {
  local private=$1 comment=$2 public="${1}.pub" derived
  if [[ -e $private || -L $private ]]; then
    [[ -f $private && ! -L $private ]] || fail "$private is not a regular private-key file; it will not be overwritten."
    chmod 600 "$private"
    if [[ ! -e $public ]]; then
      derived=$(mktemp "$SSH_DIR/.derived-public.XXXXXX"); chmod 600 "$derived"
      ssh-keygen -y -f "$private" > "$derived" || { rm -f -- "$derived"; fail "Could not derive the public key for $private."; }
      mv -- "$derived" "$public"; chmod 644 "$public"
    else
      [[ -f $public && ! -L $public ]] || fail "$public is unexpected; resolve it manually."
    fi
    return
  fi
  [[ ! -e $public && ! -L $public ]] || fail "$public exists without its private key; it will not be overwritten."
  printf 'Generating an ED25519 deploy key.\n'
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$private"
  chmod 600 "$private"; chmod 644 "$public"
}

ensure_alias() {
  local alias_name=$1 identity=$2 config="$SSH_DIR/config" resolved
  [[ ! -e $config || -f $config ]] || fail "$config is not a regular file; refusing to replace it."
  [[ ! -L $config ]] || fail "$config is a symlink; refusing to modify it."
  touch "$config"; chown root:root "$config"; chmod 600 "$config"
  if awk -v wanted="$alias_name" 'tolower($1)=="host" { for(i=2;i<=NF;i++) if($i==wanted) found=1 } END { exit(found ? 0 : 1) }' "$config"; then
    resolved=$(ssh -G -F "$config" "$alias_name" 2>/dev/null) || fail "Could not safely parse existing SSH alias $alias_name."
    grep -Fqx 'hostname github.com' <<<"$resolved" || fail "SSH alias $alias_name does not target github.com."
    grep -Fqx "identityfile $identity" <<<"$resolved" || fail "SSH alias $alias_name does not use $identity."
    grep -Fqx 'identitiesonly yes' <<<"$resolved" || fail "SSH alias $alias_name does not set IdentitiesOnly yes."
    grep -Fqx "userknownhostsfile $RECOVERY_KNOWN_HOSTS" <<<"$resolved" || fail "SSH alias $alias_name does not use the dedicated recovery known_hosts file."
    grep -Fqx 'stricthostkeychecking true' <<<"$resolved" || fail "SSH alias $alias_name does not enforce StrictHostKeyChecking yes."
    return
  fi
  cat >> "$config" <<EOF

# Managed by infrastructure-recovery; unrelated entries are preserved.
Host $alias_name
  HostName github.com
  IdentityFile $identity
  IdentitiesOnly yes
  UserKnownHostsFile $RECOVERY_KNOWN_HOSTS
  StrictHostKeyChecking yes
EOF
}

verify_repository_access() {
  local alias_name=$1 repository=$2 public_key=$3
  if GIT_TERMINAL_PROMPT=0 git ls-remote "git@$alias_name:$repository.git" HEAD >/dev/null 2>&1; then
    printf 'Authorization for %s is already valid; reusing it without displaying a key.\n' "$repository"
    return
  fi
  step "Authorize $repository" "Add the following public key as a read-only deploy key at https://github.com/$repository . The private key is never displayed."
  printf '\nPublic key for %s:\n' "$repository"
  cat "$public_key"
  printf '\nPress ENTER after the deploy key has been added to GitHub... '
  IFS= read -r _ || true
  GIT_TERMINAL_PROMPT=0 git ls-remote "git@$alias_name:$repository.git" HEAD >/dev/null || fail "Access to $repository failed. Confirm the deploy key and rerun."
}

ensure_github_known_host
ensure_key "$SSH_DIR/github-smtp-data" 'smtp-data deploy key'
ensure_alias github-smtp-data "$SSH_DIR/github-smtp-data"
verify_repository_access github-smtp-data "$SMTP_REPO" "$SSH_DIR/github-smtp-data.pub"

step 'Step 3: prepare private recovery source' 'Preparing the expected private SMTP recovery checkout at /data.'
if [[ -e $SMTP_ROOT || -L $SMTP_ROOT ]]; then
  if [[ -d $SMTP_ROOT && ! -L $SMTP_ROOT ]] && git -C "$SMTP_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    remote=$(git -C "$SMTP_ROOT" remote get-url origin 2>/dev/null || true)
    smtp_repository_origin_ok "$remote" || fail "$SMTP_ROOT is a Git checkout with unexpected origin ($remote); nothing was changed."
    printf 'Reusing the correct checkout; local changes are preserved.\n'
  else
    backup="/data.stage0-backup-$(date +%Y%m%d-%H%M%S)"
    printf '%s exists but is not a verified expected checkout. It will not be treated as recoverable content automatically.\n' "$SMTP_ROOT"
    printf 'To preserve it and clone the private repository, type MOVE %s: ' "$backup"
    IFS= read -r confirmation || true
    [[ $confirmation == "MOVE $backup" ]] || fail 'Refusing to move unknown /data contents. Resolve the directory manually, then rerun.'
    [[ ! -e $backup && ! -L $backup ]] || fail "Backup destination $backup already exists."
    mv -- "$SMTP_ROOT" "$backup"
    git clone "git@github-smtp-data:$SMTP_REPO.git" "$SMTP_ROOT"
  fi
else
  git clone "git@github-smtp-data:$SMTP_REPO.git" "$SMTP_ROOT"
fi

[[ $(git -C "$SMTP_ROOT" rev-parse --show-toplevel 2>/dev/null) == "$SMTP_ROOT" ]] || fail "$SMTP_ROOT is not the expected Git working tree."
remote=$(git -C "$SMTP_ROOT" remote get-url origin 2>/dev/null || true)
smtp_repository_origin_ok "$remote" || fail 'Resulting SMTP checkout has an unexpected origin.'
[[ -x $BOOTSTRAP ]] || fail "Private Stage 1 bootstrap was not found or is not executable at $BOOTSTRAP."
[[ -x $VALIDATE ]] || fail "Private Stage 1 validation was not found or is not executable at $VALIDATE."

step 'Step 4: restore private recovery material' 'Restore the complete required private recovery material from secure external backup. Detailed requirements remain in private Stage 1 documentation.'
printf 'Press ENTER after the required private recovery material has been restored... '
IFS= read -r _ || true

step 'Step 5: invoke private Stage 1 bootstrap' 'Starting private SMTP Stage 1 deployment.'
if "$BOOTSTRAP"; then
  printf '\nStage 1 bootstrap completed successfully.\n'
else
  status=$?
  printf '\nStage 1 bootstrap failed with exit status %d; recovery is not complete.\n' "$status" >&2
  exit "$status"
fi

step 'Step 6: invoke private Stage 1 validation' 'Running private SMTP Stage 1 validation.'
if "$VALIDATE"; then
  printf '\nSMTP recovery completed successfully.\n'
else
  status=$?
  printf '\nStage 1 validation failed with exit status %d; recovery is not complete.\n' "$status" >&2
  exit "$status"
fi
