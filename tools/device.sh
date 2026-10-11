#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps
port="${OD_SSH_PORT:-2224}"
options=(-p "$port" -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$PWD/.deps/known_hosts"
  -o ControlMaster=auto -o ControlPersist=600 -o "ControlPath=$PWD/.deps/device-ssh")
remote() { ssh "${options[@]}" root@127.0.0.1 "$@"; }
case "${1:-}" in
  install)
    [[ -f build/OpenDisplay4-device.tar.gz ]] || { echo 'Run tools/build.sh first.' >&2; exit 1; }
    remote 'killall OpenDisplay4 2>/dev/null || true'
    scp -O -P "$port" -o "ControlPath=$PWD/.deps/device-ssh" build/OpenDisplay4-device.tar.gz root@127.0.0.1:/var/mobile/Media/
    remote 'tar -xzf /var/mobile/Media/OpenDisplay4-device.tar.gz -C /Applications && chown -R root:wheel /Applications/OpenDisplay4.app && chmod 755 /Applications/OpenDisplay4.app/OpenDisplay4 && su mobile -c uicache'
    ;;
  start) remote "su mobile -c 'uiopen opendisplay4://${1}'" ;;
  logs) remote 'cat /var/mobile/Documents/OpenDisplay-iPhone4.log' ;;
  *) echo 'Usage: tools/device.sh install|start|logs'; echo 'First run iproxy 2224:22 in another terminal.'; exit 1 ;;
esac
