#!/usr/bin/env bash
# Public Stage 0 workflow; private deployment logic remains in Stage 1.
set -Eeuo pipefail

readonly CONFIG_REPO='rootdet/homepage-dashboard'
readonly INTEGRATIONS_REPO='rootdet/homepage-integrations'
readonly HOMEPAGE_ROOT='/opt/homepage'
readonly CONFIG_DIR="$HOMEPAGE_ROOT/config"
readonly SECRETS_DIR='/opt/secrets'
readonly SSH_DIR='/root/.ssh'
readonly BOOTSTRAP="$CONFIG_DIR/deployment/bootstrap.sh"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n%s\n' "$1" "$2"; }

[[ $EUID -eq 0 ]] || fail 'Run this recovery as root.'
[[ -d $HOMEPAGE_ROOT ]] || fail "Expected Homepage installation $HOMEPAGE_ROOT was not found. Create the LXC with the Community Scripts Homepage helper first."

step 'Step 1: verify prerequisites' 'Checking the Homepage installation and Stage 0 tools.'
missing_tools=()
for tool in git ssh ssh-keygen; do command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool"); done
if ((${#missing_tools[@]})); then
  command -v apt-get >/dev/null 2>&1 || fail "Missing ${missing_tools[*]}; install Git and the OpenSSH client, then rerun."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git openssh-client ca-certificates
fi

step 'Step 2: prepare SSH storage' "Ensuring $SSH_DIR exists with root-only directory permissions."
[[ ! -e $SSH_DIR || -d $SSH_DIR ]] || fail "$SSH_DIR is not a directory. Nothing was changed."
mkdir -p "$SSH_DIR"; chown root:root "$SSH_DIR"; chmod 700 "$SSH_DIR"

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
  printf 'Generating ED25519 deploy key %s.\n' "$private"
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$private"
  chmod 600 "$private"; chmod 644 "$public"
}

ensure_key "$SSH_DIR/github-homepage-config" 'homepage-dashboard deploy key'
ensure_key "$SSH_DIR/github-homepage-integrations" 'homepage-integrations deploy key'

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
    return
  fi
  cat >> "$config" <<EOF

# Managed by infrastructure-recovery; unrelated entries are preserved.
Host $alias_name
  HostName github.com
  IdentityFile $identity
  IdentitiesOnly yes
EOF
}

ensure_alias github-homepage-config "$SSH_DIR/github-homepage-config"
ensure_alias github-homepage-integrations "$SSH_DIR/github-homepage-integrations"

verify_repository_access() {
  local alias_name=$1 repository=$2 public_key=$3
  if GIT_TERMINAL_PROMPT=0 git ls-remote "git@$alias_name:$repository.git" HEAD >/dev/null 2>&1; then
    printf 'Authorization for %s is already valid; reusing it without displaying a key.\n' "$repository"
    return
  fi
  step "Authorize $repository" "Add the following public key as a deploy key at https://github.com/$repository . The private key is never displayed."
  printf '\nPublic key for %s:\n' "$repository"
  cat "$public_key"
  printf '\nPress ENTER after the deploy key has been added to GitHub... '
  IFS= read -r _ || true
  GIT_TERMINAL_PROMPT=0 git ls-remote "git@$alias_name:$repository.git" HEAD >/dev/null || fail "Access to $repository failed. Confirm the deploy key and rerun."
}

verify_repository_access github-homepage-config "$CONFIG_REPO" "$SSH_DIR/github-homepage-config.pub"
verify_repository_access github-homepage-integrations "$INTEGRATIONS_REPO" "$SSH_DIR/github-homepage-integrations.pub"

step 'Step 4: prepare private Homepage configuration' "Only the expected private repository may become $CONFIG_DIR."
if [[ -e $CONFIG_DIR || -L $CONFIG_DIR ]]; then
  if [[ -d $CONFIG_DIR && ! -L $CONFIG_DIR ]] && git -C "$CONFIG_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    remote=$(git -C "$CONFIG_DIR" remote get-url origin 2>/dev/null || true)
    [[ $remote == "git@github-homepage-config:$CONFIG_REPO.git" ]] || fail "$CONFIG_DIR is a Git checkout with unexpected origin ($remote); nothing was changed."
    printf 'Reusing the correct checkout; local changes are preserved.\n'
  else
    backup="$HOMEPAGE_ROOT/config.stage0-backup-$(date +%Y%m%d-%H%M%S)"
    printf '%s exists but is not a verified expected checkout. It will not be treated as stock configuration automatically.\n' "$CONFIG_DIR"
    printf 'To preserve it and clone the private repository, type MOVE %s: ' "$backup"
    IFS= read -r confirmation || true
    [[ $confirmation == "MOVE $backup" ]] || fail 'Refusing to move unknown config contents. Resolve the directory manually, then rerun.'
    [[ ! -e $backup && ! -L $backup ]] || fail "Backup destination $backup already exists."
    mv -- "$CONFIG_DIR" "$backup"
    git clone "git@github-homepage-config:$CONFIG_REPO.git" "$CONFIG_DIR"
  fi
else
  git clone "git@github-homepage-config:$CONFIG_REPO.git" "$CONFIG_DIR"
fi
remote=$(git -C "$CONFIG_DIR" remote get-url origin 2>/dev/null || true)
[[ $remote == "git@github-homepage-config:$CONFIG_REPO.git" ]] || fail 'Resulting config checkout has an unexpected origin.'
[[ -f $CONFIG_DIR/deployment/bootstrap.sh ]] || fail "Private Stage 1 bootstrap was not found at $BOOTSTRAP."

step 'Step 5: restore private secrets' 'Restore these files from secure external backup. They must never come from this public repository.'
printf 'Required files: /opt/secrets/homepage.env and /opt/secrets/python_http.env\n'
printf 'Press ENTER after both files have been restored... '
IFS= read -r _ || true
[[ -d $SECRETS_DIR && ! -L $SECRETS_DIR ]] || fail "$SECRETS_DIR is missing or unsafe."
for secret in "$SECRETS_DIR/homepage.env" "$SECRETS_DIR/python_http.env"; do [[ -f $secret && ! -L $secret ]] || fail "Required secret file $secret is missing or unsafe; contents were not displayed."; done
chown root:root "$SECRETS_DIR" "$SECRETS_DIR/homepage.env" "$SECRETS_DIR/python_http.env"
chmod 700 "$SECRETS_DIR"; chmod 600 "$SECRETS_DIR/homepage.env" "$SECRETS_DIR/python_http.env"
[[ $(stat -c '%U:%G %a' "$SECRETS_DIR") == 'root:root 700' ]] || fail 'Could not verify /opt/secrets permissions.'
[[ $(stat -c '%U:%G %a' "$SECRETS_DIR/homepage.env") == 'root:root 600' ]] || fail 'Could not verify homepage.env permissions.'
[[ $(stat -c '%U:%G %a' "$SECRETS_DIR/python_http.env") == 'root:root 600' ]] || fail 'Could not verify python_http.env permissions.'

step 'Step 6: invoke private Stage 1' "Running $BOOTSTRAP; Stage 1 owns the remaining deployment and validation logic."
[[ -x $BOOTSTRAP ]] || fail "$BOOTSTRAP is not executable."
if "$BOOTSTRAP"; then
  printf '\nStage 1 completed successfully.\n'
else
  status=$?
  printf '\nStage 1 failed with exit status %d; recovery is not complete.\n' "$status" >&2
  exit "$status"
fi
