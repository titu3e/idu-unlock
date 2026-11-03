#!/usr/bin/env bash
#
# flash.sh — one entry point for JIDU root access, backup, and OpenWrt.
#
#   ./flash.sh                 verify the router -> unlock root SSH -> back it up
#   ./flash.sh check           can this unit be unlocked? (read-only, safe to run in bulk)
#   ./flash.sh unlock          root SSH only (persistent, survives reboots)
#   ./flash.sh backup          unlock if needed, then save the stock device data
#   ./flash.sh backup --skip-unlock  use existing root SSH; do not run unlock
#   ./flash.sh download        detect the model, download + verify its OpenWrt images
#   ./flash.sh flash           backup first, then download + install OpenWrt
#   ./flash.sh flash --skip-unlock  use existing root SSH; skip unlock
#   ./flash.sh detect          identify the model, change nothing
#
# Options:
#   --router URL    router base URL (default https://192.168.31.1)
#   --password P    router admin password (prompted if omitted)
#   --key PATH      Optional SSH key. A new unlock clears the root password
#                   whether or not a key is supplied, and installs persistent
#                   SSH. Existing root SSH is left as found.
#   --address IP    local address the router should call back on (VPN/WSL)
#   --force         send the payloads even when check says NO (advanced)
#   --skip-unlock   backup/flash using existing root SSH; do not run unlock
#   -v, --verbose   show the per-command detail behind each method
#
# The router must be SET UP, not factory-fresh: a reset IDU keeps its API locked
# until the setup wizard is completed in the web UI. Reset it, finish the wizard
# (which sets the admin password), then run this and supply that password.
#
# On Linux and macOS, unlock/backup/flash may listen on port 80, which is
# privileged. If binding fails, run the affected command with sudo. On Linux you can instead
# allow unprivileged low ports for this boot:
#   sudo sysctl net.ipv4.ip_unprivileged_port_start=80
# On Windows, use .\flash.ps1 for unlock and backup: WSL2's default NAT cannot
# receive the router's callback. For OpenWrt downloads and flashing, use
# .\firmware\fwflash.ps1; see the README for model-specific commands.
#
# Only run against equipment you own or are explicitly authorised to test.
# Provided as is, without warranty, without liability — see the README.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="${ROUTER:-https://192.168.31.1}"
PASSWORD="${PASSWORD:-}"
KEY="${KEY:-}"
ADDRESS="${ADDRESS:-}"
FORCE=0
SKIP_UNLOCK=0
VERBOSE=0
NOBANNER=0
CMD=""

# Progress prefixes: [*] working, [+] success, [-] failed.
say()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    unlock|backup|download|flash|detect|check) CMD="$1"; shift ;;
    --router)   ROUTER="$2";   shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --key)      KEY="$2";      shift 2 ;;
    --address)  ADDRESS="$2";  shift 2 ;;
    --force)    FORCE=1;       shift ;;
    --skip-unlock) SKIP_UNLOCK=1; shift ;;
    -v|--verbose) VERBOSE=1;   shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         bad "unknown option: $1"; usage; exit 2 ;;
    *)          bad "unexpected argument: $1"; usage; exit 2 ;;
  esac
done
[ -n "$CMD" ] || CMD="auto"
if [ "$SKIP_UNLOCK" -eq 1 ] && [ "$CMD" != "backup" ] && [ "$CMD" != "flash" ]; then
  bad "--skip-unlock is only valid with backup or flash"
  exit 2
fi

DETECTED_MODEL=""
DETECTED_FAMILY=""

# ---- an interpreter that has `requests` ---------------------------------- #
#
# urllib3 v2 requires OpenSSL 1.1.1+ and complains on anything else — which
# includes every Python Apple ships, linked against LibreSSL. This tool only
# ever talks to the router with verification off, so the still-maintained
# urllib3 1.x costs nothing and keeps the output clean.
tls_ok() {
  "$1" -c 'import ssl, sys
sys.exit(0 if ssl.OPENSSL_VERSION.startswith("OpenSSL ")
         and ssl.OPENSSL_VERSION_INFO >= (1, 1, 1) else 1)' >/dev/null 2>&1
}

deps_ok() {
  "$1" -c 'import ssl, sys
try:
    import requests, urllib3
except ImportError:
    sys.exit(1)
tls = (ssl.OPENSSL_VERSION.startswith("OpenSSL ")
       and ssl.OPENSSL_VERSION_INFO >= (1, 1, 1))
sys.exit(0 if tls or urllib3.__version__.startswith("1.") else 1)' >/dev/null 2>&1
}

PIN=""
tls_ok python3 || PIN="urllib3<2"

PY=""
if deps_ok python3; then
  PY="python3"
elif [ -x "$HERE/.venv/bin/python" ] && deps_ok "$HERE/.venv/bin/python"; then
  PY="$HERE/.venv/bin/python"
else
  say "installing dependencies into $HERE/.venv ..."
  python3 -m venv "$HERE/.venv" || { bad "could not create a venv"; exit 1; }
  "$HERE/.venv/bin/pip" -q install --upgrade pip requests $PIN || { bad "pip failed"; exit 1; }
  PY="$HERE/.venv/bin/python"
fi

# ---- ssh key ------------------------------------------------------------- #
# Optional, and never generated: a new unlock clears root's password with or without a key.

# ---- password ------------------------------------------------------------ #
if [ -z "$PASSWORD" ]; then
  printf 'Router admin password: '
  read -rs PASSWORD
  echo
fi
[ -n "$PASSWORD" ] || { bad "no password given"; exit 2; }

# -u keeps Python's output unbuffered: piped through the driver it would
# otherwise sit in a block buffer and make a slow login look like a hang.
idu() {
  local _args=( --router "$ROUTER" --password "$PASSWORD" )
  [ -n "$KEY" ] && _args+=( --key "$KEY" )
  [ -n "$ADDRESS" ] && _args+=( --address "$ADDRESS" )
  [ "$VERBOSE" -eq 1 ] && _args+=( --verbose )
  [ "$NOBANNER" -eq 1 ] && _args+=( --no-banner )
  # --force belongs to the unlock subcommand, so it goes after the command name.
  # backup's inner `idu unlock` still gets it.
  if [ "$FORCE" -eq 1 ] && [ "${1:-}" = "unlock" ]; then
    "$PY" -u "$HERE/idu.py" "${_args[@]}" "$@" --force
  else
    "$PY" -u "$HERE/idu.py" "${_args[@]}" "$@"
  fi
}

describe() {
  say "Connecting to ${ROUTER#*//}"
  local out
  if ! out="$(idu detect)"; then
    bad "could not take over the router. Usual causes:"
    bad "  * it is unreachable, or an admin session is already open;"
    bad "  * it is factory-reset - finish the setup wizard in the web UI first;"
    bad "  * the password is wrong (the router locks out after ~5 tries)."
    exit 1
  fi
  DETECTED_MODEL="$(printf '%s\n' "$out" | sed -n 's/^MODEL=//p' | tail -n 1)"
  DETECTED_FAMILY="$(printf '%s\n' "$out" | sed -n 's/^FAMILY=//p' | tail -n 1)"
  # MODEL=/FAMILY= are how this driver reads the family; the user gets the two
  # human-readable lines instead.
  printf '%s\n' "$out" | grep -v -e '^MODEL=' -e '^FAMILY='
  NOBANNER=1        # shown once, above - don't repeat it on every later call
}

# ---- SSH authentication preparation -------------------------------------- #
#
# Normal runs retain the dedicated-key setup. With --skip-unlock, an existing
# password-protected root SSH account can be converted to the passwordless
# mode expected by the backup and stock firmware flasher.
prepare_root_ssh_key() {
  local host key_home known_hosts pub probe candidate attempt remote_cmd output status
  local manage_key_owner=0 key_group
  host="$("$PY" -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or sys.argv[1])' "$ROUTER")" || return 1

  key_home="$HOME"
  if [ -n "${SUDO_USER:-}" ]; then
    key_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -n "$key_home" ] || key_home="$HOME"
  fi
  known_hosts="$key_home/.ssh/known_hosts"

  if [ -z "$KEY" ]; then
    KEY="$key_home/.ssh/idu-$host"
    manage_key_owner=1
  fi

  mkdir -p "$(dirname "$KEY")" || { bad "cannot create SSH key directory"; return 1; }
  chmod 700 "$(dirname "$KEY")"
  if [ ! -f "$KEY" ]; then
    command -v ssh-keygen >/dev/null 2>&1 || { bad "ssh-keygen is required"; return 1; }
    say "Generating a dedicated SSH key: $KEY"
    ssh-keygen -q -t ed25519 -N "" -C "idu-$host" -f "$KEY" || return 1
  fi
  [ -f "$KEY.pub" ] || { bad "public key is missing: $KEY.pub"; return 1; }
  if [ "$manage_key_owner" -eq 1 ] && [ -n "${SUDO_USER:-}" ]; then
    key_group="$(id -gn "$SUDO_USER")" || return 1
    chown "$SUDO_USER:$key_group" "$(dirname "$KEY")" "$KEY" "$KEY.pub" || {
      bad "could not give the dedicated SSH key to $SUDO_USER"
      return 1
    }
  fi
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"

  if ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o UserKnownHostsFile="$known_hosts" \
      -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$host" true \
      >/dev/null 2>&1; then
    say "Dedicated SSH key already works."
    return 0
  fi

  # If root SSH is not running yet, let the unlock installer add this key.
  probe="$(ssh -o BatchMode=yes -o UserKnownHostsFile="$known_hosts" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "root@$host" true 2>&1 || true)"
  case "$probe" in
    *"Connection refused"*|*"Connection timed out"*|*"No route to host"*|*"Operation timed out"*)
      say "Root SSH is not available yet; the unlock step will install the public key."
      return 0
      ;;
    *"Permission denied"*|*"Authentication failed"*) ;;
    *)
      if [ -n "$KEY" ] && [ "$SKIP_UNLOCK" -eq 0 ]; then
        say "SSH is not ready; the unlock step will install the public key."
        return 0
      fi
      bad "cannot verify root SSH or install the key: $probe"
      return 1
      ;;
  esac

  command -v expect >/dev/null 2>&1 || {
    bad "installing the SSH key requires expect: sudo apt install expect"
    return 1
  }
  pub="$(cat "$KEY.pub")"
  remote_cmd="$("$PY" -c 'import shlex,sys; k=sys.argv[1]; print("umask 077; mkdir -p /root/.ssh /etc/dropbear; chown root:root /etc/dropbear && chmod go-w /etc/dropbear; touch /root/.ssh/authorized_keys /etc/dropbear/authorized_keys; grep -qxF " + shlex.quote(k) + " /root/.ssh/authorized_keys || printf %s\\\\n " + shlex.quote(k) + " >> /root/.ssh/authorized_keys; grep -qxF " + shlex.quote(k) + " /etc/dropbear/authorized_keys || printf %s\\\\n " + shlex.quote(k) + " >> /etc/dropbear/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys")' "$pub")" || return 1

  for attempt in 1 2 3; do
    printf 'Root SSH password for root@%s (used only to install your key): ' "$host"
    IFS= read -r -s candidate </dev/tty || return 1
    printf '\n'
    if IDU_SSH_PASSWORD="$candidate" IDU_HOST="$host" IDU_KNOWN_HOSTS="$known_hosts" IDU_REMOTE_CMD="$remote_cmd" expect -c '
      set timeout 20
      spawn ssh -T -o "UserKnownHostsFile=$env(IDU_KNOWN_HOSTS)" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$env(IDU_HOST)" $env(IDU_REMOTE_CMD)
      expect {
        -re "(?i)password:" { send -- "$env(IDU_SSH_PASSWORD)\r"; exp_continue }
        -re "(?i)\\(yes/no\\)" { send -- "yes\r"; exp_continue }
        timeout { exit 124 }
        eof
      }
      catch wait result
      exit [lindex $result 3]
    '; then
      unset candidate
      if ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o UserKnownHostsFile="$known_hosts" \
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$host" true \
          >/dev/null 2>&1; then
        say "SSH key installed and verified; future backup/flash runs won't need the root password."
        return 0
      fi
    fi
    unset candidate
    bad "Could not install or verify the SSH key."
  done
  return 1
}


prepare_skip_unlock_passwordless() {
  local host key_home known_hosts probe candidate attempt remote_cmd cleanup_cmd answer
  host="$("$PY" -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or sys.argv[1])' "$ROUTER")" || return 1
  key_home="$HOME"
  if [ -n "${SUDO_USER:-}" ]; then
    key_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -n "$key_home" ] || key_home="$HOME"
  fi
  known_hosts="$key_home/.ssh/known_hosts"
  mkdir -p "$(dirname "$known_hosts")" || { bad "cannot create SSH known_hosts directory"; return 1; }

  # An explicitly supplied key is preferred and never triggers password removal.
  if [ -n "$KEY" ]; then
    if ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=8 "root@$host" true >/dev/null 2>&1; then
      say "Existing root SSH key verified; leaving the root password unchanged."
      return 0
    fi
    bad "the supplied --key did not authenticate; refusing to change the root password."
    return 1
  fi

  probe="$(ssh -o BatchMode=yes -o UserKnownHostsFile="$known_hosts" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
    "root@$host" true 2>&1 || true)"
  if [ -z "$probe" ]; then
    export IDU_SSH_PASSWORD=""
    export IDU_SSH_PASSWORD_SET=1
    say "Root SSH already accepts an empty password."
    return 0
  fi
  case "$probe" in
    *"Permission denied"*|*"Authentication failed"*) ;;
    *)
      bad "root SSH is not reachable or host verification failed: $probe"
      return 1
      ;;
  esac

  command -v expect >/dev/null 2>&1 || {
    bad "password setup requires expect: sudo apt install expect"
    return 1
  }
  printf '\n[!] This deletes the router's root SSH password. Passwordless root SSH may\n'
  printf '    allow anyone on a reachable network to log in as root.\n'
  printf '    A temporary rollback is armed before the change and cancelled only\n'
  printf '    after a separate empty-password SSH login succeeds.\n'
  printf 'Type REMOVE to continue: '
  IFS= read -r answer </dev/tty || return 1
  [ "$answer" = "REMOVE" ] || { say "Cancelled; router unchanged."; return 1; }

  remote_cmd='umask 077; p=/tmp/.idu-shadow-rollback.path; [ ! -e "$p" ] || { echo "rollback already pending" >&2; exit 70; }; b=$(mktemp /tmp/.idu-shadow.XXXXXX) || exit 1; cp /etc/shadow "$b" || { rm -f "$b"; exit 1; }; printf "%s\n" "$b" > "$p"; ( sleep 120; if [ -s "$p" ]; then b=$(cat "$p"); cp "$b" /etc/shadow; rm -f "$b" "$p"; fi ) >/dev/null 2>&1 &; passwd -d root || { b=$(cat "$p"); cp "$b" /etc/shadow; rm -f "$b" "$p"; exit 1; }; echo IDU_ROOT_PASSWORD_CLEARED'
  for attempt in 1 2; do
    printf 'Current root SSH password for root@%s: ' "$host"
    IFS= read -r -s candidate </dev/tty || return 1
    printf '\n'
    if IDU_SSH_PASSWORD="$candidate" IDU_HOST="$host" IDU_KNOWN_HOSTS="$known_hosts" IDU_REMOTE_CMD="$remote_cmd" expect -c '
      set timeout 25
      spawn ssh -T -o "UserKnownHostsFile=$env(IDU_KNOWN_HOSTS)" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$env(IDU_HOST)" $env(IDU_REMOTE_CMD)
      expect {
        -re "(?i)password:" { send -- "$env(IDU_SSH_PASSWORD)\r"; exp_continue }
        -re "(?i)\\(yes/no\\)" { send -- "yes\r"; exp_continue }
        timeout { exit 124 }
        eof
      }
      catch wait result
      exit [lindex $result 3]
    '; then
      unset candidate
      cleanup_cmd='b=$(cat /tmp/.idu-shadow-rollback.path 2>/dev/null) || exit 1; rm -f "$b" /tmp/.idu-shadow-rollback.path; echo IDU_EMPTY_PASSWORD_VERIFIED'
      if IDU_SSH_PASSWORD="" IDU_HOST="$host" IDU_KNOWN_HOSTS="$known_hosts" IDU_REMOTE_CMD="$cleanup_cmd" expect -c '
        set timeout 20
        spawn ssh -T -o "UserKnownHostsFile=$env(IDU_KNOWN_HOSTS)" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$env(IDU_HOST)" $env(IDU_REMOTE_CMD)
        expect {
          -re "(?i)password:" { send -- "\r"; exp_continue }
          -re "(?i)\\(yes/no\\)" { send -- "yes\r"; exp_continue }
          timeout { exit 124 }
          eof
        }
        catch wait result
        exit [lindex $result 3]
      '; then
        export IDU_SSH_PASSWORD=""
        export IDU_SSH_PASSWORD_SET=1
        say "Root password removed; passwordless SSH verified. Continuing."
        return 0
      fi
      bad "empty-password SSH verification failed. Waiting for the 120-second rollback to restore the previous password."
      sleep 125
      return 1
    fi
    unset candidate
    bad "root SSH password authentication failed."
  done
  return 1
}

prepare_skip_unlock_password_auth() {
  local host key_home known_hosts probe candidate attempt
  host="$("$PY" -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or sys.argv[1])' "$ROUTER")" || return 1
  key_home="$HOME"
  if [ -n "${SUDO_USER:-}" ]; then
    key_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -n "$key_home" ] || key_home="$HOME"
  fi
  known_hosts="$key_home/.ssh/known_hosts"
  mkdir -p "$(dirname "$known_hosts")" || { bad "cannot create SSH known_hosts directory"; return 1; }

  if [ -n "$KEY" ]; then
    if ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=8 "root@$host" true >/dev/null 2>&1; then
      say "Existing root SSH key verified."
      return 0
    fi
    bad "the supplied --key did not authenticate."
    return 1
  fi

  probe="$(ssh -o BatchMode=yes -o UserKnownHostsFile="$known_hosts" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
    "root@$host" true 2>&1 || true)"
  if [ -z "$probe" ]; then
    export IDU_SSH_PASSWORD=""
    export IDU_SSH_PASSWORD_SET=1
    say "Root SSH already accepts an empty password."
    return 0
  fi
  case "$probe" in
    *"Permission denied"*|*"Authentication failed"*) ;;
    *)
      bad "root SSH is not reachable or host verification failed: $probe"
      return 1
      ;;
  esac

  command -v expect >/dev/null 2>&1 || {
    bad "password-authenticated SSH requires expect: sudo apt install expect"
    return 1
  }
  for attempt in 1 2; do
    printf 'Root SSH password for root@%s: ' "$host"
    IFS= read -r -s candidate </dev/tty || return 1
    printf '\n'
    if IDU_SSH_PASSWORD="$candidate" IDU_HOST="$host" IDU_KNOWN_HOSTS="$known_hosts" expect -c '
      set timeout 20
      spawn ssh -T -o "UserKnownHostsFile=$env(IDU_KNOWN_HOSTS)" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$env(IDU_HOST)" true
      expect {
        -re "(?i)password:" { send -- "$env(IDU_SSH_PASSWORD)\r"; exp_continue }
        -re "(?i)\\(yes/no\\)" { send -- "yes\r"; exp_continue }
        timeout { exit 124 }
        eof
      }
      catch wait result
      exit [lindex $result 3]
    '; then
      export IDU_SSH_PASSWORD="$candidate"
      export IDU_SSH_PASSWORD_SET=1
      unset candidate
      say "Root SSH authentication verified; password kept in memory for this run only."
      return 0
    fi
    unset candidate
    bad "root SSH authentication failed."
  done
  return 1
}

prepare_root_ssh_auth() {
  if [ "$SKIP_UNLOCK" -eq 1 ]; then
    prepare_skip_unlock_password_auth
  else
    prepare_root_ssh_key
  fi
}


ensure_root_ssh() {
  if [ "$SKIP_UNLOCK" -eq 1 ]; then
    say "Skipping unlock; using the router's existing root SSH access."
  else
    idu unlock || return 1
  fi
}

firmware_model() {
  case "$DETECTED_MODEL" in
    JIDU6101) echo "6101" ;;
    JIDU6J01|JIDU6201|JIDU6401|JIDU6601|JIDU6701) echo "6j01" ;;
    JIDU6J11|JIDU6111|JIDU6411|JIDU6611|JIDU6811|JIDU6911) echo "6j11" ;;
    *)
      bad "no OpenWrt image set is registered for model: ${DETECTED_MODEL:-unknown}"
      return 1
      ;;
  esac
}

run_firmware() {
  local action="$1" model host
  local flasher="$HERE/firmware/fwflash.sh"

  [ -x "$flasher" ] || {
    bad "missing firmware flasher: $flasher"
    return 1
  }

  model="$(firmware_model)" || return 1
  host="$("$PY" -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or sys.argv[1])' "$ROUTER")" \
    || { bad "could not parse router URL: $ROUTER"; return 1; }

  local args=( "$model" --router "$host" )
  [ "$VERBOSE" -eq 1 ] && args+=( --verbose )
  [ "$action" = "download" ] && args+=( --download-only )

  PASSWORD="$PASSWORD" KEY="$KEY" ADDRESS="$ADDRESS" \
    "$flasher" "${args[@]}"
}

case "$CMD" in
  detect)
    idu detect || exit 1
    ;;

  check)
    idu check
    exit $?
    ;;

  unlock)
    describe
    idu unlock || exit 1
    ;;

  backup)
    describe
    prepare_root_ssh_auth || exit 1
    ensure_root_ssh || exit 1
    idu backup --outdir "$PWD" || exit 1
    ;;

  download)
    describe
    run_firmware download || exit 1
    ;;

  flash)
    [ -x "$HERE/firmware/fwflash.sh" ] || {
      bad "missing firmware flasher: $HERE/firmware/fwflash.sh"
      exit 1
    }
    describe
    firmware_model >/dev/null || exit 1
    prepare_root_ssh_auth || exit 1
    if [ "$SKIP_UNLOCK" -eq 1 ]; then
      say "Skipping unlock; using existing root SSH access."
    else
      say "Unlock enables persistent root SSH. If flashing fails, stock may remain unlocked."
    fi
    say "Backing up stock firmware before flashing..."
    ensure_root_ssh || exit 1
    idu backup --outdir "$PWD" || exit 1
    run_firmware flash || exit 1
    ;;

  auto)
    describe
    idu unlock || exit 1
    idu backup --outdir "$PWD" || exit 1
    ;;
esac
