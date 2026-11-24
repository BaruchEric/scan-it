#!/bin/sh
# Forced SSH command for eric@scan-it (CT 150 on pve). The scan-it filing tree
# (its local "My Drive": scans/ plus the folders entities.json copies into)
# arrives in mirror/ by rsync, and "push" copies mirror/ into Google Drive.
# Drive credentials stay on the NAS. Nothing here deletes, in mirror/ or in
# Drive, except in scans/_queue: the previews of batches scanned but not filed
# yet. "queue-prune" drops the previews scan-it no longer queues, and push
# mirrors that one folder into Drive, whose deletes go to Drive's trash.
#
# Source: ~/dev/office/scan-it/nas/receiver.sh on the Mac. Installed at
# /share/CACHEDEV1_DATA/Backups/scan-it/receiver.sh, the previous one beside
# it as receiver.sh.prev.
set -eu
umask 022
ROOT=/share/CACHEDEV1_DATA/Backups/scan-it
MIRROR=$ROOT/mirror
QUEUE=$MIRROR/scans/_queue
D=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker
RCLONE=rclone/rclone@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5
# baruchriollc's My Drive, which holds scans/. Full drive scope (scans/ was made
# by the Drive app); the token is the memory gateway's grant, see rclone.conf.
DRIVE=gdrive-scans:
# The first push would overwrite Drive's dashboards with a catalog that lacks
# everything filed before the move, so push waits until the import is done.
IMPORTED=$ROOT/imported
rc() {  # rc ro|rw <rclone args>: mirror/ mounted read-only or writable
  mode=$1; shift
  "$D" run --rm --dns 1.1.1.1 -v /share/Arik/.config/rclone:/config/rclone -v "$MIRROR":/mirror:"$mode" \
    "$RCLONE" --config /config/rclone/rclone.conf "$@"
}
# Never eval SSH_ORIGINAL_COMMAND: validate each word.
set -f
# shellcheck disable=SC2086 # split into words on purpose
set -- ${SSH_ORIGINAL_COMMAND:-}
case "${1:-}" in
  rsync)
    # Upload only: rsync --server <bundled short flags> . <path>. The client's
    # path is ignored; everything lands in mirror/.
    [ "${2:-}" = --server ] || exit 64
    shift 2
    flags=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        .) shift; break ;;
        --sender|--delete*|--remove*|--server) exit 64 ;;
        *) printf '%s\n' "$1" | grep -Eq '^-[A-Za-z.]+$' || exit 64; flags="$flags $1" ;;
      esac
      shift
    done
    [ "$#" -eq 1 ] || exit 64
    mkdir -p "$MIRROR"
    cd "$MIRROR"
    # shellcheck disable=SC2086
    exec rsync --server $flags . ./
    ;;
  push)
    [ "$#" -eq 1 ] || exit 64
    [ -e "$IMPORTED" ] || { echo "scan-it receiver: push waits for the one-time import (touch $IMPORTED)" >&2; exit 65; }
    mkdir -p "$QUEUE"
    rc ro copy /mirror "$DRIVE" --exclude '.*' --exclude '.*/**' --exclude '/scans/_queue/**' --log-level NOTICE
    rc ro sync /mirror/scans/_queue "${DRIVE}scans/_queue" --exclude '.*' --log-level NOTICE
    echo "pushed $(date -Iseconds)"
    ;;
  queue-prune)
    # stdin: the preview names scan-it still queues, one per line. Every
    # other batch-*.pdf in mirror/scans/_queue goes. Only names of that exact
    # shape are read or removed, so nothing outside the queue can be touched.
    [ "$#" -eq 1 ] || exit 64
    mkdir -p "$QUEUE"
    keep=$(mktemp)
    if ! head -n 5000 | while IFS= read -r n; do
         printf '%s\n' "$n" | grep -Eqx 'batch-[0-9]{8}-[0-9]{6}[.]pdf' || exit 64
         printf '%s\n' "$n"
       done > "$keep"; then
      rm -f "$keep"
      echo "scan-it receiver: queue-prune takes batch-YYYYMMDD-HHMMSS.pdf names only" >&2
      exit 64
    fi
    removed=0
    set +f  # globbing is off for the command words above; this loop needs it
    for f in "$QUEUE"/batch-*.pdf; do
      [ -f "$f" ] || continue
      n=$(basename "$f")
      printf '%s\n' "$n" | grep -Eqx 'batch-[0-9]{8}-[0-9]{6}[.]pdf' || continue
      grep -qxF "$n" "$keep" && continue
      rm -f "$f"
      removed=$((removed + 1))
    done
    rm -f "$keep"
    echo "queue-prune: removed $removed"
    ;;
  status)
    [ "$#" -eq 1 ] || exit 64
    printf 'mirror %s\n' "$(du -sh "$MIRROR" 2>/dev/null | cut -f1 || echo none)"
    printf 'imported %s\n' "$([ -e "$IMPORTED" ] && echo yes || echo no)"
    printf 'remote %s\n' "$(rc ro listremotes 2>/dev/null | grep -qx "$DRIVE" && echo "$DRIVE configured" || echo "$DRIVE missing")"
    ;;
  import)
    # One time, before the first push: Drive's scans/ (all filed before the
    # move) into mirror/, then to the caller as a tar on stdout.
    [ "$#" -eq 1 ] || exit 64
    [ ! -e "$IMPORTED" ] || { echo "scan-it receiver: already imported" >&2; exit 65; }
    mkdir -p "$MIRROR/scans"
    rc rw copy "${DRIVE}scans" /mirror/scans --log-level ERROR >&2
    tar -C "$MIRROR" -cf - scans
    ;;
  imported)
    # The caller unpacked the import: from now on push may run.
    [ "$#" -eq 1 ] || exit 64
    date -Iseconds > "$IMPORTED"
    echo "scan-it receiver: import marked done"
    ;;
  *) echo "scan-it receiver: rsync (upload) | queue-prune | push | status | import | imported" >&2; exit 64 ;;
esac
