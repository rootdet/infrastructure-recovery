#!/usr/bin/env bash
# Public Stage 0 dispatcher.
set -Eeuo pipefail

readonly SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
readonly SCRIPT_DIR=${SCRIPT_PATH%/*}
readonly REPOSITORY_NAME='infrastructure-recovery'
readonly DEFAULT_REF='main'
readonly INFRASTRUCTURE_RECOVERY_REF=${INFRASTRUCTURE_RECOVERY_REF:-$DEFAULT_REF}

validate_ref() {
  local ref=$1
  if [[ $ref == "$DEFAULT_REF" ]]; then
    return 0
  fi
  [[ $ref =~ ^[0-9a-fA-F]{40}$ ]] || {
    printf 'Invalid INFRASTRUCTURE_RECOVERY_REF=%q. Expected a 40-character hexadecimal Git commit SHA, or leave it unset to use the default %s.\n' "$ref" "$DEFAULT_REF" >&2
    exit 1
  }
}

validate_ref "$INFRASTRUCTURE_RECOVERY_REF"

# Metadata is deliberately parsed, never sourced. Results are METADATA_NAME and
# METADATA_ORDER, and only the supported fields are accepted.
parse_metadata() {
  local file=$1 line key value
  METADATA_NAME=''
  METADATA_ORDER=''
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || ${line:0:1} == '#' ]] && continue
    [[ $line == *=* ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    case $key in
      name)
        [[ -z $METADATA_NAME && -n $value ]] || return 1
        METADATA_NAME=$value
        ;;
      order)
        [[ -z $METADATA_ORDER && $value =~ ^[0-9]+$ ]] || return 1
        METADATA_ORDER=$value
        ;;
      *) ;; # Unknown fields are harmless and ignored.
    esac
  done < "$file"
  [[ -n $METADATA_NAME && -n $METADATA_ORDER ]]
}

# A valid environment directory is any immediate child directory containing a
# valid recovery.conf. A valid target directory is any immediate grandchild
# directory containing both a valid recovery.conf and a recover.sh. Neither
# check knows about any specific environment or target name; the dispatcher
# stays generic and new modules never require dispatcher changes.
has_valid_environment() {
  local directory=$1
  [[ -d $directory ]] || return 1
  parse_metadata "$directory/recovery.conf"
}

has_valid_target() {
  local directory=$1
  [[ -d $directory && -f $directory/recover.sh ]] || return 1
  parse_metadata "$directory/recovery.conf"
}

# A valid module tree is the root dispatcher plus at least one discoverable
# environment that itself contains at least one discoverable target. This
# intentionally does not reference any specific environment or target name.
has_module_tree() {
  local root=$1 environment target
  [[ -f $root/recovery.sh ]] || return 1
  while IFS= read -r -d '' environment; do
    if has_valid_environment "$environment"; then
      while IFS= read -r -d '' target; do
        if has_valid_target "$target"; then
          return 0
        fi
      done < <(find "$environment" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  return 1
}

bootstrap_standalone() {
  local cache_root archive extract_dir checkout ref
  ref=$INFRASTRUCTURE_RECOVERY_REF
  cache_root=${XDG_CACHE_HOME:-${TMPDIR:-/tmp}}
  checkout="$cache_root/$REPOSITORY_NAME"
  if has_module_tree "$checkout"; then
    exec env INFRASTRUCTURE_RECOVERY_BOOTSTRAPPED=1 bash "$checkout/recovery.sh" "$@"
  fi

  command -v curl >/dev/null 2>&1 || {
    printf 'Standalone launcher needs curl to download the public recovery repository. Install curl or run the launcher from a complete checkout.\n' >&2
    exit 1
  }
  command -v tar >/dev/null 2>&1 || {
    printf 'Standalone launcher needs tar to unpack the public recovery repository. Install tar or run the launcher from a complete checkout.\n' >&2
    exit 1
  }
  archive=$(mktemp "${TMPDIR:-/tmp}/infrastructure-recovery.XXXXXX.tar.gz")
  extract_dir=$(mktemp -d "${TMPDIR:-/tmp}/infrastructure-recovery.XXXXXX")
  trap 'rm -f -- "$archive"; rm -rf -- "$extract_dir"' EXIT
  printf 'This is a standalone launcher. Downloading the public recovery module tree at ref %s...\n' "$ref"
  curl --fail --silent --show-error --location --retry 2 \
    "https://github.com/rootdet/infrastructure-recovery/archive/$ref.tar.gz" \
    --output "$archive" || {
      printf 'Could not download the public recovery repository at ref %s. Check network access or use a complete checkout.\n' "$ref" >&2
      exit 1
    }
  tar -xzf "$archive" -C "$extract_dir"
  checkout=''
  while IFS= read -r -d '' directory; do
    if has_module_tree "$directory"; then
      checkout=$directory
      break
    fi
  done < <(find "$extract_dir" -mindepth 1 -maxdepth 3 -type d -print0)
  [[ -n $checkout && -d $checkout ]] || {
    printf 'Downloaded archive did not contain the expected %s tree for ref %s.\n' "$REPOSITORY_NAME" "$ref" >&2
    exit 1
  }
  has_module_tree "$checkout" || {
    printf 'Downloaded recovery tree failed module validation; refusing to relaunch it.\n' >&2
    exit 1
  }
  exec env INFRASTRUCTURE_RECOVERY_BOOTSTRAPPED=1 bash "$checkout/recovery.sh" "$@"
}

if [[ ${INFRASTRUCTURE_RECOVERY_BOOTSTRAPPED:-0} != 1 ]] && ! has_module_tree "$SCRIPT_DIR"; then
  bootstrap_standalone "$@"
fi

# Records are order<TAB>name<TAB>path. The path is never taken from metadata.
discover_environments() {
  DISCOVERY_LINES=()
  local directory
  while IFS= read -r -d '' directory; do
    if has_valid_environment "$directory"; then
      DISCOVERY_LINES+=("$METADATA_ORDER"$'\t'"$METADATA_NAME"$'\t'"$directory")
    fi
  done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
}

discover_targets() {
  DISCOVERY_LINES=()
  local environment=$1 directory
  while IFS= read -r -d '' directory; do
    if has_valid_target "$directory"; then
      DISCOVERY_LINES+=("$METADATA_ORDER"$'\t'"$METADATA_NAME"$'\t'"$directory")
    fi
  done < <(find "$environment" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
}

menu() {
  local title=$1 zero_label=$2
  shift 2
  local -a records=("$@")
  local index selection
  printf '\n%s\n' "$title"
  printf '%*s\n\n' "${#title}" '' | tr ' ' '='
  for index in "${!records[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${records[index]#*$'\t'}" | sed 's/\t.*$//'
  done
  printf '  0) %s\n\nSelection: ' "$zero_label"
  IFS= read -r selection || return 2
  [[ $selection =~ ^[0-9]+$ ]] || return 1
  if ((selection == 0)); then return 0; fi
  ((selection >= 1 && selection <= ${#records[@]})) || return 1
  MENU_SELECTED=${records[selection-1]}
  return 10
}

while :; do
  discover_environments
  ((${#DISCOVERY_LINES[@]} > 0)) || { printf 'No valid recovery environments were found in %s.\n' "$SCRIPT_DIR" >&2; exit 1; }
  mapfile -t sorted < <(printf '%s\n' "${DISCOVERY_LINES[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3)
  if menu 'Infrastructure Recovery' 'Exit' "${sorted[@]}"; then exit 0; else menu_status=$?; fi
  if ((menu_status != 10)); then printf 'Invalid selection. Please enter one of the displayed numbers.\n' >&2; continue; fi
  environment_record=$MENU_SELECTED
  environment=${environment_record##*$'\t'}
  environment_name=${environment_record#*$'\t'}; environment_name=${environment_name%%$'\t'*}

  while :; do
    discover_targets "$environment"
    ((${#DISCOVERY_LINES[@]} > 0)) || { printf 'No valid recovery targets were found for %s.\n' "$environment_name" >&2; break; }
    mapfile -t sorted < <(printf '%s\n' "${DISCOVERY_LINES[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3)
    if menu "$environment_name Recovery" 'Back' "${sorted[@]}"; then break; else menu_status=$?; fi
    if ((menu_status != 10)); then printf 'Invalid selection. Please enter one of the displayed numbers.\n' >&2; continue; fi
    target_record=$MENU_SELECTED
    target=${target_record##*$'\t'}
    target_name=${target_record#*$'\t'}; target_name=${target_name%%$'\t'*}
    printf '\nLaunching %s...\n' "$target_name"
    if bash "$target/recover.sh"; then
      :
    else
      target_status=$?
      printf 'Recovery target %s failed with exit status %d. Returning to the menu.\n' "$target_name" "$target_status" >&2
    fi
  done
done
