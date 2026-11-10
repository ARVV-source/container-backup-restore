#!/usr/bin/env bash
# Tests for VolumeBackup.sh and VolumeRestore.sh. Usage: bash tests/tests.sh [test ...]
# The end-to-end tests create and remove a throwaway service called "rtest".
# The tests use the global variables of the script they load
# shellcheck source-path=SCRIPTDIR/.. disable=SC2034,SC2154,SC2030,SC2031
set -uo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
RESTORE=$root/VolumeRestore.sh
BACKUP=$root/VolumeBackup.sh
TMP=$(mktemp -d)
filter=("$@")
passes=0 failures=0

# Each test runs in a subshell with set -e: the first command that fails brings it down
run_test() {
    local name=$1 fn=$2 rc
    if (( ${#filter[@]} > 0 )) && [[ " ${filter[*]} " != *" $name "* ]]; then return 0; fi
    # No "||": inside a condition bash ignores the set -e of the subshell
    # Each test gets its own temporary folder
    ( set -e; TMP=$(mktemp -d -p "$TMP"); "$fn" ) > "$TMP/$name.out" 2>&1
    rc=$?
    if (( rc == 0 )); then
        passes=$(( passes + 1 ))
        printf '  ✓ %s\n' "$name"
    else
        failures=$(( failures + 1 ))
        printf '  ✗ %s (code %d)\n' "$name" "$rc"
        tail -n 25 -- "$TMP/$name.out" | sed 's/^/      /'
    fi
}

assert_equal() {
    if [[ $1 != "$2" ]]; then
        printf 'FAILED: %s\n  expected: «%s»\n  got:      «%s»\n' "$3" "$1" "$2"
        exit 1
    fi
}

assert_fails() {
    local message=$1
    shift
    if ! type -t "$1" > /dev/null; then
        printf 'FAILED: %s ("%s" does not exist)\n' "$message" "$1"
        exit 1
    fi
    if "$@"; then
        printf 'FAILED: %s (it should have failed and it did not)\n' "$message"
        exit 1
    fi
}

load() {
    # shellcheck source=VolumeRestore.sh
    source "$RESTORE"
}

# ---------- Tests ----------

choose_numbers() {
    load
    services=(a b c)
    choose "3, 1 3"
    assert_equal "c a" "${result[*]}" "chooses by number without repeats"
    choose ALL
    assert_equal "a b c" "${result[*]}" "all = every one"
    assert_fails "number out of range" choose 9
}

# Fake backup shaped like the ones VolumeBackup.sh leaves: a compose in /opt/app,
# a volume app_db and a bind /opt/data. It is left in $1 (the service folder).
fake_backup() {
    local d=$1 src
    src=$(mktemp -d -p "$TMP")
    mkdir -p "$src/opt/app" "$src/vol" "$src/opt/data" "$d/config" "$d/volumes"
    echo 'services: {}' > "$src/opt/app/docker-compose.yml"
    echo hello > "$src/vol/a.txt"
    echo bind > "$src/opt/data/b.txt"
    tar -C "$src/opt" -cf - app | zstd -q -o "$d/config/app.tar.zst"
    tar -C "$src/vol" -cf - . | zstd -q -o "$d/volumes/app_db.tar.zst"
    tar -C "$src/opt" -cf - data | zstd -q -o "$d/volumes/bind_opt_data_12345678.tar.zst"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        file type origin restore_to bytes_original bytes_compressed \
        config/app.tar.zst config /opt/app /opt 10 5 \
        volumes/app_db.tar.zst volume app_db app_db 20 6 \
        volumes/bind_opt_data_12345678.tar.zst bind /opt/data /opt 30 7 \
        > "$d/MANIFEST.tsv"
    sign "$d"
}

sign() {
    # The brackets make nullglob drop the service info file if the backup does not have it
    (cd -- "$1" && shopt -s nullglob && sha256sum -- config/* volumes/* MANIFEST.tsv \
        SERVICE.ts[v] CONTAINERS.jso[n] IMAGES.ts[v] > SHA256SUMS)
}

# Changes row N (1 = first one after the header) of the manifest and signs it again
change_row() {
    local d=$1 n=$2 row=$3
    awk -v n=$(( n + 1 )) -v row="$row" 'NR == n { print row; next } { print }' \
        "$d/MANIFEST.tsv" > "$d/m.tmp"
    mv -- "$d/m.tmp" "$d/MANIFEST.tsv"
    sign "$d"
}

valid_manifest() {
    load
    fake_backup "$TMP/s"
    read_manifest "$TMP/s"
    assert_equal "config volume bind" "${m_type[*]}" "types"
    assert_equal "/opt/app app_db /opt/data" "${m_origin[*]}" "origins"
    assert_equal "/opt app_db /opt" "${m_restore[*]}" "restore_to"
    assert_equal "10 20 30" "${m_bytes[*]}" "bytes"
    assert_equal "volumes/app_db.tar.zst" "${m_file[1]}" "file"
}

manifest_rejects_dot_dot() {
    load
    fake_backup "$TMP/s"
    change_row "$TMP/s" 3 $'volumes/bind_opt_data_12345678.tar.zst\tbind\t/opt/../etc/x\t/opt/../etc\t30\t7'
    assert_fails "path with .." read_manifest "$TMP/s"
}

manifest_rejects_etc() {
    load
    fake_backup "$TMP/s"
    change_row "$TMP/s" 3 $'volumes/bind_opt_data_12345678.tar.zst\tbind\t/etc/data\t/etc\t30\t7'
    assert_fails "system path" read_manifest "$TMP/s"
}

manifest_rejects_odd_volume() {
    load
    fake_backup "$TMP/s"
    change_row "$TMP/s" 2 $'volumes/app_db.tar.zst\tvolume\ta;b\ta;b\t20\t6'
    assert_fails "volume name with ;" read_manifest "$TMP/s"
}

manifest_rejects_missing_file() {
    load
    fake_backup "$TMP/s"
    rm -- "$TMP/s/volumes/app_db.tar.zst"
    assert_fails "file that does not exist" read_manifest "$TMP/s"
}

sums_detect_change() {
    load
    fake_backup "$TMP/s"
    read_manifest "$TMP/s"
    verify_sums "$TMP/s"
    printf 'x' >> "$TMP/s/volumes/app_db.tar.zst"
    assert_fails "tampered file" verify_sums "$TMP/s"
}

detects_compose() {
    load
    fake_backup "$TMP/s"
    read_manifest "$TMP/s"
    detect_service "$TMP/s" app
    assert_equal compose "$s_type" "type"
    assert_equal /opt/app "$s_dir" "compose folder"
}

# Backup of a quadlet: the config is the folder with ALL the units
quadlet_backup() {
    local d=$1 content=$2 src
    src=$(mktemp -d -p "$TMP")
    mkdir -p "$src/systemd" "$d/config" "$d/volumes"
    printf '%s\n' "$content" > "$src/systemd/web.container"
    echo '[Volume]' > "$src/systemd/web.volume"
    printf '[Container]\nImage=x\n' > "$src/systemd/other.container"
    tar -C "$src" -cf - systemd | zstd -q -o "$d/config/systemd_ab12cd34.tar.zst"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        file type origin restore_to bytes_original bytes_compressed \
        config/systemd_ab12cd34.tar.zst config /home/u/.config/containers/systemd /home/u/.config/containers 10 5 \
        > "$d/MANIFEST.tsv"
    sign "$d"
}

detects_quadlet_only_its_unit() {
    load
    quadlet_backup "$TMP/q" $'[Container]\nImage=x'
    read_manifest "$TMP/q"
    detect_service "$TMP/q" systemd-web
    assert_equal quadlet "$s_type" "type"
    assert_equal web.service "$s_unit" "unit"
    assert_equal "systemd/web.container,systemd/web.volume" "$s_members" "only its files"
    assert_fails "unit that is not in the backup" detect_service "$TMP/q" nothing
}

detects_quadlet_by_container_name() {
    load
    quadlet_backup "$TMP/q" $'[Container]\nImage=x\nContainerName=my_web'
    read_manifest "$TMP/q"
    detect_service "$TMP/q" my_web
    assert_equal web.service "$s_unit" "unit by ContainerName"
}

detects_standalone() {
    load
    fake_backup "$TMP/s"
    # Without the config row (line 2 of the file, after the header)
    sed -i 2d -- "$TMP/s/MANIFEST.tsv"
    sign "$TMP/s"
    read_manifest "$TMP/s"
    detect_service "$TMP/s" app
    assert_equal standalone "$s_type" "neither compose nor quadlet"
}

load_backup_three_cases() {
    load
    fake_backup "$TMP/b/backup_2026-10-01_1000/app"
    fake_backup "$TMP/b/backup_2026-10-02_1000/app"
    fake_backup "$TMP/b/backup_2026-10-02_1000/web"

    load_backup "$TMP/b/backup_2026-10-01_1000/app"
    assert_equal "$TMP/b/backup_2026-10-01_1000|app" "$backup_dir|${services[*]}" "folder of one service"

    load_backup "$TMP/b/backup_2026-10-02_1000"
    assert_equal "$TMP/b/backup_2026-10-02_1000|app web" "$backup_dir|${services[*]}" "folder of one backup"

    load_backup "$TMP/b" <<< 1
    assert_equal "$TMP/b/backup_2026-10-02_1000" "$backup_dir" "1 is the newest"

    assert_fails "folder without backups" load_backup "$TMP/s_missing"
}

remaps_home() {
    load
    fake_backup "$TMP/s"
    change_row "$TMP/s" 3 $'volumes/bind_opt_data_12345678.tar.zst\tbind\t/home/old/data\t/home/old\t30\t7'
    read_manifest "$TMP/s"
    remap_home /home/old /home/new
    assert_equal "/opt/app app_db /home/new/data" "${m_origin[*]}" "origins"
    assert_equal "/opt app_db /home/new" "${m_restore[*]}" "restore_to"
}

# ---------- Throwaway service for the end-to-end tests ----------

# Compose "rtest": volume rtest_data on /data and a bind outside its folder on /bind.
# $1 = name of the compose file (docker-compose.yml by default)
prepare_service() {
    COMPOSE_FILE=${1:-docker-compose.yml}
    if podman container exists rtest_app; then
        echo "rtest_app already exists from another test. Remove it: podman rm -f rtest_app; podman volume rm rtest_data"
        exit 1
    fi
    COMPOSE_DIR=$TMP/rtest BIND=$TMP/rtest_bind BACKUPS=$TMP/backups
    mkdir -p "$COMPOSE_DIR" "$BIND"
    cat > "$COMPOSE_DIR/$COMPOSE_FILE" <<EOF
services:
  app:
    image: docker.io/library/nginx:alpine
    container_name: rtest_app
    environment:
      - RT=original
    # If /data/a.txt says "broken", it crashes on startup (like a damaged database)
    command: ["sh", "-c", "grep -qx broken /data/a.txt 2>/dev/null && exit 1; trap exit TERM; while :; do sleep 1; done"]
    volumes:
      - data:/data
      - $BIND:/bind
volumes:
  data:
EOF
    trap clean_service EXIT
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest -f "$COMPOSE_FILE" up -d) > /dev/null 2>&1
    podman exec rtest_app sh -c 'echo original > /data/a.txt && chown 101 /data/a.txt'
    echo original > "$BIND/b.txt"
}

clean_service() {
    podman ps -a -q --filter name=rtest_app | xargs -r podman rm -f > /dev/null 2>&1 || true
    podman ps -a -q --filter name=rtest_extra | xargs -r podman rm -f > /dev/null 2>&1 || true
    podman volume ls -q --filter name=rtest_data | xargs -r podman volume rm -f > /dev/null 2>&1 || true
    podman network rm -f rtest_default > /dev/null 2>&1 || true
    # What was set aside in ~/.before_restore for this test, and the folders left empty
    { compgen -G "$HOME/.before_restore/*$TMP" || true; } | while IFS= read -r d; do podman unshare rm -rf -- "$d"; done
    if [[ -d $HOME/.before_restore ]]; then find "$HOME/.before_restore" -depth -type d -empty -delete; fi
    podman unshare rm -rf -- "$TMP" 2> /dev/null || true
}

# Backs up rtest with VolumeBackup.sh answering its questions; leaves the folder in LAST_BACKUP
backup_service() {
    local n
    # Same order in which VolumeBackup.sh numbers the services
    n=$(podman ps -a --format '{{or (index .Labels "com.docker.compose.project") .Names}} {{.Names}}' \
        | sort | awk '!seen[$1]++ { print $1 }' | grep -nx rtest | cut -d: -f1)
    # If the service does not start again the backup exits with an error, but the backup is still there
    # RESTART=yes: also ask to restart it when done
    printf 'n\n%s\n%s\n%s\ny\n' "$n" "${RESTART:+$n}" "$BACKUPS" | "$BACKUP" > "$TMP/backup.out" 2>&1 || true
    LAST_BACKUP=$(compgen -G "$BACKUPS/backup_*" | tail -n 1)
    [[ -f $LAST_BACKUP/rtest/MANIFEST.tsv ]]
}

volume_data() { podman exec rtest_app cat /data/a.txt; }
state() { podman inspect -f '{{.State.Status}}' rtest_app; }
before_copies() {
    # Only the rtest ones: the machine may have others from real restores
    podman volume ls -q --filter name=rtest_data.before_restore
    find "$TMP" -name '*.before_restore_*'
}

contains() {
    if [[ $2 != *"$1"* ]]; then
        printf 'FAILED: the output does not say «%s»\n' "$1"
        exit 1
    fi
}

dry_run_touches_nothing() {
    local output
    prepare_service
    backup_service
    podman exec rtest_app sh -c 'echo changed > /data/a.txt'
    output=$(printf 'n\n%s\n1\n\n' "$LAST_BACKUP" | DRY_RUN=yes "$RESTORE" 2>&1)
    echo "$output"
    contains "Dry run" "$output"
    contains "rtest_data" "$output"
    assert_equal changed "$(volume_data)" "the data is not touched"
    assert_equal running "$(state)" "still running"
    assert_equal "" "$(before_copies)" "there are no .before_restore copies"
}

wrong_confirmation_cancels() {
    local output
    prepare_service
    backup_service
    podman exec rtest_app sh -c 'echo changed > /data/a.txt'
    output=$(printf 'n\n%s\n1\n\ny\n' "$LAST_BACKUP" | "$RESTORE" 2>&1)
    echo "$output"
    contains "Cancelled" "$output"
    assert_equal changed "$(volume_data)" "the data is not touched"
    assert_equal running "$(state)" "still running"
}

# Restores LAST_BACKUP without SSH; $1 = answer to "which parts?" (empty = all)
restore_rtest() {
    printf 'n\n%s\n1\n%s\nrestore\n' "$LAST_BACKUP" "${1:-}" | "$RESTORE" 2>&1
}

change_data() {
    podman exec rtest_app sh -c 'echo changed > /data/a.txt'
    echo changed > "$BIND/b.txt"
}

before_volume() { podman volume ls -q --filter name=rtest_data.before_restore; }
read_in_volume() { podman unshare cat "$(podman volume inspect "$1" -f '{{.Mountpoint}}')/$2"; }

restores_data() {
    prepare_service
    backup_service
    change_data
    restore_rtest
    assert_equal original "$(volume_data)" "volume restored"
    assert_equal original "$(cat -- "$BIND/b.txt")" "bind restored"
    assert_equal running "$(state)" "left running"
    assert_equal 101 "$(podman exec rtest_app stat -c %u /data/a.txt)" "original owner"
    assert_equal changed "$(read_in_volume "$(before_volume)" a.txt)" "copy of the previous volume"
    assert_equal changed "$(cat -- "$BIND".before_restore_*/b.txt)" "copy of the previous bind"
}

restores_without_service() {
    prepare_service
    backup_service
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest down -v) > /dev/null 2>&1
    rm -rf -- "$COMPOSE_DIR" "$BIND"
    restore_rtest
    assert_equal running "$(state)" "it was created again and started"
    assert_equal original "$(volume_data)" "volume restored"
    assert_equal original "$(cat -- "$BIND/b.txt")" "bind restored"
    assert_equal "" "$(before_copies)" "there was nothing to set aside"
}

twice_in_a_row() {
    prepare_service
    backup_service
    change_data
    restore_rtest
    sleep 1
    restore_rtest
    assert_equal original "$(volume_data)" "volume restored"
    assert_equal 2 "$(before_volume | wc -l)" "two previous copies, with different stamps"
}

only_one_part() {
    prepare_service
    backup_service
    change_data
    restore_rtest 2
    assert_equal original "$(volume_data)" "the volume was restored"
    assert_equal changed "$(cat -- "$BIND/b.txt")" "the bind was not touched"
    assert_equal running "$(state)" "left running"
}

rollback_if_file_truncated() {
    local output f
    prepare_service
    backup_service
    f=$LAST_BACKUP/rtest/volumes/rtest_data.tar.zst
    truncate -s $(( $(stat -c %s -- "$f") / 2 )) -- "$f"
    sign "$LAST_BACKUP/rtest"
    change_data
    if output=$(restore_rtest); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "everything was left the way it was" "$output"
    if [[ $output == *"delete it with"* ]]; then echo "FAILED: it offers to delete copies that no longer exist"; exit 1; fi
    assert_equal running "$(state)" "it started again"
    assert_equal changed "$(volume_data)" "the volume was left as it was"
    assert_equal changed "$(cat -- "$BIND/b.txt")" "the bind was left as it was"
    assert_equal "" "$(before_copies)" "no stray copies left"
}

revert_if_it_does_not_start() {
    local output mp
    prepare_service
    podman exec rtest_app sh -c 'echo broken > /data/a.txt'
    backup_service
    # Fix it so that the "broken" backup is the one that does not start
    mp=$(podman volume inspect rtest_data -f '{{.Mountpoint}}')
    podman unshare sh -c "echo changed > '$mp/a.txt'"
    podman start rtest_app > /dev/null
    sleep 1
    assert_equal running "$(state)" "running before restoring"
    if output=$(printf 'n\n%s\n1\n\nrestore\ny\n' "$LAST_BACKUP" | "$RESTORE" 2>&1); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "did NOT start" "$output"
    assert_equal running "$(state)" "it reverted and started"
    assert_equal changed "$(volume_data)" "the previous data"
    assert_equal "" "$(before_copies)" "no stray copies left"
}

log_in_home_if_read_only() {
    local output log
    prepare_service
    backup_service
    touch "$TMP/marker"
    chmod a-w -- "$LAST_BACKUP"
    output=$(restore_rtest)
    chmod u+w -- "$LAST_BACKUP"
    echo "$output"
    log=$(find "$HOME" -maxdepth 1 -name 'restore_*.log' -newer "$TMP/marker" | head -n 1)
    assert_equal "" "$(compgen -G "$LAST_BACKUP/restore_*.log")" "it did not write into the backup"
    [[ -n $log ]] || { echo "FAILED: there is no log in $HOME"; exit 1; }
    contains "Summary" "$(cat -- "$log")"
    rm -f -- "$log"
    assert_equal original "$(volume_data)" "it did restore"
}

# Fake ssh: runs the command right here, as the server shell would
# (sshd is not running on this machine). rsync -e ssh also goes through here.
fake_ssh() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
while (( $# > 0 )); do
    case $1 in
        -O) exit 0 ;;
        -o|-p|-l|-i) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift
exec bash -c "$*"
FAKE
    chmod +x "$TMP/bin/ssh"
    PATH=$TMP/bin:$PATH
}

over_ssh() {
    local output
    prepare_service
    backup_service
    change_data
    fake_ssh
    touch "$TMP/marker"
    output=$(printf 'y\n%s@localhost\n\n%s\n1\n\nrestore\n' "$USER" "$LAST_BACKUP" | "$RESTORE" 2>&1)
    echo "$output"
    contains "Uploaded and verified" "$output"
    assert_equal original "$(volume_data)" "volume restored"
    assert_equal original "$(cat -- "$BIND/b.txt")" "bind restored"
    assert_equal "" "$(find /tmp /var/tmp -maxdepth 1 -name '.restore_*' -newer "$TMP/marker" 2>/dev/null)" "it deleted the temporary copy"
}

# ---------- Findings from the final review ----------

# Runs $1 (bash) in a real terminal, types $2 into it and returns everything shown on screen
in_terminal() {
    python3 -I - "$1" "$2" <<'PY'
import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", sys.argv[1]])
time.sleep(1)
os.write(fd, sys.argv[2].encode())
output = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
os.waitpid(pid, 0)
sys.stdout.write(output.decode(errors="replace"))
PY
}

# C1: with stderr captured for the log, the questions still have to be visible
prompt_visible_with_log() {
    local output
    output=$(in_terminal "source $(printf '%q' "$RESTORE"); log=$TMP/l; exec 2> >(capture_stderr); ask r 'VISIBLE QUESTION: '; echo \"r=\$r\"" $'x\n')
    echo "$output"
    contains "VISIBLE QUESTION:" "$output"
    contains "r=x" "$output"
}

# C2: compose with a file name that is not one of the usual ones
detects_compose_any_name() {
    local src
    load
    fake_backup "$TMP/s"
    src=$(mktemp -d -p "$TMP")
    mkdir -p "$src/app"
    printf 'services:\n  web:\n    image: x\n' > "$src/app/stack.yaml"
    rm -- "$TMP/s/config/app.tar.zst"
    tar -C "$src" -cf - app | zstd -q -o "$TMP/s/config/app.tar.zst"
    sign "$TMP/s"
    read_manifest "$TMP/s"
    detect_service "$TMP/s" app
    assert_equal compose "$s_type" "a .yaml with services: is compose"
}

# C2: even if the type is detected wrong, if there are containers of a compose with that name it is not touched
check_blocks_unrecognized_compose() {
    prepare_service
    load
    use_ssh=no dest="this machine"
    svc_type[rtest]=standalone svc_dir[rtest]="" svc_unit[rtest]="" svc_stamp[rtest]=20990101_000000
    svc_files[rtest]=$TMP svc_parts[rtest]=all
    printf -v 'svc_items[rtest]' '%s|%s|%s|%s|%s|%s' volume volumes/x.tar.zst rtest_data rtest_data 1 ""
    assert_fails "a compose detected as standalone" check_service rtest
}

# I2: two rows with the same path can make the rollback delete the original
manifest_rejects_repeated_origin() {
    load
    fake_backup "$TMP/s"
    change_row "$TMP/s" 3 $'volumes/bind_opt_data_12345678.tar.zst\tbind\t/opt/app\t/opt\t30\t7'
    assert_fails "repeated origin" read_manifest "$TMP/s"
}

# I3: if the config of a compose that already exists is restored, it has to be applied
restores_config_on_existing_compose() {
    prepare_service
    backup_service
    sed -i 's/RT=original/RT=changed/' "$COMPOSE_DIR/docker-compose.yml"
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest down && podman-compose -p rtest up -d) > /dev/null 2>&1
    assert_equal changed "$(podman exec rtest_app printenv RT)" "setup"
    restore_rtest
    assert_equal original "$(podman exec rtest_app printenv RT)" "it runs with the restored config"
    assert_equal running "$(state)" "left running"
}

# I4: if the upload fails, do not go on (and do not stop the service)
failed_upload_is_detected() {
    load
    fake_backup "$TMP/s"
    fake_ssh
    printf '#!/bin/sh\nexit 23\n' > "$TMP/bin/rsync"
    chmod +x "$TMP/bin/rsync"
    use_ssh=yes dest=$USER@localhost ssh_opts=() method=rsync
    backup_dir=$TMP remote_tmp=$TMP/remote
    mkdir -p "$remote_tmp"
    printf -v 'svc_items[s]' '%s|%s|%s|%s|%s|%s' volume volumes/app_db.tar.zst app_db app_db 20 ""
    assert_fails "rsync failed" upload s
}

# I7: what travels to the server cannot use $'…' (dash and fish do not understand it)
items_without_dollar_quotes() {
    local args
    load
    fake_backup "$TMP/s"
    backup_dir=$TMP srv_home=$HOME
    build_service s <<< ""
    mapfile -t items <<< "${svc_items[s]}"
    printf -v args '%q ' "${items[@]}"
    [[ $args != *"\$'"* ]] || { echo "FAILED: $args"; exit 1; }
}

# I8: the .container uses other units (volume, network) and a drop-in: they go with it
detects_quadlet_with_references() {
    local src d=$TMP/q
    load
    src=$(mktemp -d -p "$TMP")
    mkdir -p "$src/systemd/web.container.d" "$d/config" "$d/volumes"
    printf '[Container]\nImage=x\nVolume=web-data.volume:/data\nNetwork=red.network\n' > "$src/systemd/web.container"
    echo '[Volume]' > "$src/systemd/web-data.volume"
    echo '[Network]' > "$src/systemd/red.network"
    echo '[Container]' > "$src/systemd/web.container.d/extra.conf"
    printf '[Container]\nImage=y\n' > "$src/systemd/other.container"
    tar -C "$src" -cf - systemd | zstd -q -o "$d/config/systemd_ab12cd34.tar.zst"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        file type origin restore_to bytes_original bytes_compressed \
        config/systemd_ab12cd34.tar.zst config /home/u/.config/containers/systemd /home/u/.config/containers 10 5 \
        > "$d/MANIFEST.tsv"
    sign "$d"
    read_manifest "$d"
    detect_service "$d" systemd-web
    assert_equal "systemd/red.network,systemd/web-data.volume,systemd/web.container,systemd/web.container.d/extra.conf" \
        "$s_members" "the unit, what it uses and its drop-in"
}

# I8: units in a subfolder of their own (~/.config/containers/systemd/app/)
detects_quadlet_in_subfolder() {
    local src d=$TMP/q
    load
    src=$(mktemp -d -p "$TMP")
    mkdir -p "$src/app" "$d/config" "$d/volumes"
    printf '[Container]\nImage=x\n' > "$src/app/web.container"
    tar -C "$src" -cf - app | zstd -q -o "$d/config/app_ab12cd34.tar.zst"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        file type origin restore_to bytes_original bytes_compressed \
        config/app_ab12cd34.tar.zst config /home/u/.config/containers/systemd/app /home/u/.config/containers/systemd 10 5 \
        > "$d/MANIFEST.tsv"
    sign "$d"
    read_manifest "$d"
    detect_service "$d" systemd-web
    assert_equal "quadlet|web.service|" "$s_type|$s_unit|$s_members" "the subfolder is all its own"
}

# I8: a file in the tar with ".." cannot end up outside the folder
detects_quadlet_rejects_odd_member() {
    local d=$TMP/q
    load
    mkdir -p "$d/config" "$d/volumes"
    python3 -I - "$d/config/s.tar" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
    for name in ("systemd/web.container", "systemd/../web.volume"):
        data = b"[Container]\nImage=x\n"
        info = tarfile.TarInfo(name)
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
PY
    zstd -q --rm -o "$d/config/systemd_ab12cd34.tar.zst" "$d/config/s.tar"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        file type origin restore_to bytes_original bytes_compressed \
        config/systemd_ab12cd34.tar.zst config /home/u/.config/containers/systemd /home/u/.config/containers 10 5 \
        > "$d/MANIFEST.tsv"
    sign "$d"
    read_manifest "$d"
    assert_fails "member with .." detect_service "$d" systemd-web
}

# I6: Ctrl+C in the middle of a restore over SSH: the server finishes on its own; here we warn and wait
ctrl_c_over_ssh_waits() {
    local output pid
    prepare_service
    backup_service
    change_data
    fake_ssh
    # With "&" bash leaves SIGINT ignored and it cannot be re-enabled; python leaves it as
    # in a terminal and opens its own process group so the Ctrl+C can be sent to it
    python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.setsid()
os.execvp("bash", ["bash", "-c", sys.argv[1]])' \
        "printf 'y\n%s@localhost\n\n%s\n1\n\nrestore\n' $(printf '%q' "$USER") $(printf '%q' "$LAST_BACKUP") | $(printf '%q' "$RESTORE")" > "$TMP/r.out" 2>&1 &
    pid=$!
    timeout 60 bash -c "until grep -q 'Uploaded and verified' $(printf '%q' "$TMP/r.out"); do sleep 0.2; done"
    sleep 1
    kill -INT -- "-$pid"
    wait "$pid" || true
    output=$(cat -- "$TMP/r.out")
    echo "$output"
    contains "still working" "$output"
    assert_equal running "$(state)" "left running"
    assert_equal original "$(volume_data)" "it finished restoring"
}

# ---------- Permissions: folders that can only be created with sudo ----------

# Builds a standalone service "rtest_permissions" (number 2 in the list) with a single bind
# at $1, runs the pre-check and shows the notice about the missing folders
check_bind_at() {
    load
    use_ssh=no dest="this machine" services=(other rtest_permissions)
    svc_type[rtest_permissions]=standalone svc_dir[rtest_permissions]="" svc_unit[rtest_permissions]=""
    svc_stamp[rtest_permissions]=20990101_000000 svc_files[rtest_permissions]=$TMP svc_parts[rtest_permissions]=all
    printf -v 'svc_items[rtest_permissions]' '%s|%s|%s|%s|%s|%s' bind volumes/x.tar.zst "$1" "$(dirname -- "$1")" 1 ""
    if check_service rtest_permissions 2>&1; then
        echo "FAILED: it should have blocked it"
        exit 1
    fi
    show_missing_permissions
}

# On a new machine /opt belongs to root: the folder of the bind cannot be created
permission_create_with_sudo() {
    local output
    output=$(check_bind_at /opt/rtest_missing)
    echo "$output"
    contains "there are folders that can only be prepared with sudo" "$output"
    contains $'rtest_permissions\n        /opt/rtest_missing' "$output"
    contains "sudo mkdir -p /opt/rtest_missing" "$output"
    contains "sudo chown $USER: /opt/rtest_missing" "$output"
    contains "choose: 2" "$output"
    [[ ! -e /opt/rtest_missing ]]
}

# It exists and has data, but the parent folder belongs to root: it has to be set aside with sudo
permission_set_aside_with_sudo() {
    local output
    output=$(check_bind_at /var/lib/dnf)
    echo "$output"
    contains "sudo mv /var/lib/dnf /var/lib/dnf.before_restore_manual" "$output"
    contains "sudo mkdir -p /var/lib/dnf" "$output"
    contains "choose: 2" "$output"
}

# An empty folder that already exists (the one created with sudo) is used as it is: it is not set aside
restores_into_empty_folder() {
    prepare_service
    backup_service
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest down -v) > /dev/null 2>&1
    rm -rf -- "$COMPOSE_DIR"
    rm -f -- "$BIND"/*
    restore_rtest
    assert_equal original "$(cat -- "$BIND/b.txt")" "it restored inside the empty folder"
    assert_equal running "$(state)" "left running"
    assert_equal "" "$(compgen -G "$BIND.before_restore_*")" "it did not set the empty folder aside"
}

# ---------- Containers with the name of the service but from somewhere else ----------

# Someone brought rtest up by hand (not with its compose) and with its same volume: the
# names are the ones in the backup, but the container is not part of the rtest project
put_foreign() {
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest down) > /dev/null 2>&1
    podman run -d --name rtest_app -v rtest_data:/data docker.io/library/nginx:alpine \
        sh -c 'trap exit TERM; while :; do sleep 1; done' > /dev/null
    podman exec rtest_app sh -c 'echo other > /data/a.txt'
}
project() { podman inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' rtest_app; }
foreign_set_aside() { podman ps -a --format '{{.Names}}' | grep -F 'rtest_app.before_restore_' || true; }

foreign_container_is_not_touched() {
    local output
    prepare_service
    backup_service
    put_foreign
    if output=$(printf 'n\n%s\n1\n\nn\n' "$LAST_BACKUP" | "$RESTORE" 2>&1); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "created by hand" "$output"
    assert_equal running "$(state)" "the other one is still running"
    assert_equal "" "$(project)" "it is still the other one"
    assert_equal other "$(volume_data)" "its data is not touched"
    assert_equal "" "$(before_copies)$(foreign_set_aside)" "nothing was set aside"
}

foreign_container_is_set_aside() {
    local output a
    prepare_service
    backup_service
    put_foreign
    if ! output=$(printf 'n\n%s\n1\n\ny\nrestore\n' "$LAST_BACKUP" | "$RESTORE" 2>&1); then
        echo "$output"
        echo "FAILED: it should have restored"
        exit 1
    fi
    echo "$output"
    assert_equal rtest "$(project)" "now it is the one from the backup"
    assert_equal running "$(state)" "running"
    assert_equal original "$(volume_data)" "data from the backup"
    a=$(foreign_set_aside)
    [[ -n $a ]] || { echo "FAILED: it did not set the other container aside"; exit 1; }
    assert_equal exited "$(podman inspect -f '{{.State.Status}}' "$a")" "the other one was left stopped"
    contains "podman rm $a" "$output"
}

foreign_container_comes_back_if_it_fails() {
    local output f
    prepare_service
    backup_service
    f=$LAST_BACKUP/rtest/volumes/rtest_data.tar.zst
    truncate -s $(( $(stat -c %s -- "$f") / 2 )) -- "$f"
    sign "$LAST_BACKUP/rtest"
    put_foreign
    if output=$(printf 'n\n%s\n1\n\ny\nrestore\n' "$LAST_BACKUP" | "$RESTORE" 2>&1); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "everything was left the way it was" "$output"
    assert_equal running "$(state)" "the other one started again"
    assert_equal "" "$(project)" "it is the other one, with its name"
    assert_equal other "$(volume_data)" "its data as it was"
    assert_equal "" "$(before_copies)$(foreign_set_aside)" "no stray copies left"
}

foreign_container_comes_back_if_it_does_not_start() {
    local output
    prepare_service
    podman exec rtest_app sh -c 'echo broken > /data/a.txt'
    backup_service
    put_foreign
    if output=$(printf 'n\n%s\n1\n\ny\nrestore\ny\n' "$LAST_BACKUP" | "$RESTORE" 2>&1); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "did NOT start" "$output"
    assert_equal running "$(state)" "the other one reverted and started"
    assert_equal "" "$(project)" "it is the other one, with its name"
    assert_equal other "$(volume_data)" "its data as it was"
    assert_equal "" "$(before_copies)$(foreign_set_aside)" "no stray copies left"
}

# ---------- Its own folder, but the parent belongs to root (like /opt) ----------

# Without sudo we cannot create something owned by root with a folder of ours inside: we
# pretend the parent belongs to root (RESTORE_TEST_NO_RENAME). The test lives in the home
# so that it ends up on the same disk as ~/.before_restore.
before_in_home() { compgen -G "$HOME/.before_restore/*$BIND" || true; }

sets_content_aside_in_home() {
    local output before
    TMP=$(mktemp -d -p "$HOME" .rtest_XXXXXXXX)
    prepare_service
    backup_service
    change_data
    output=$(RESTORE_TEST_NO_RENAME=$BIND restore_rtest)
    echo "$output"
    contains "what was there before is kept in $HOME/.before_restore/" "$output"
    assert_equal original "$(cat -- "$BIND/b.txt")" "it restored in the same folder"
    assert_equal running "$(state)" "left running"
    before=$(before_in_home)
    [[ -n $before ]] || { echo "FAILED: nothing was set aside in ~/.before_restore"; exit 1; }
    assert_equal changed "$(cat -- "$before/b.txt")" "what was there before is in the home"
    contains "podman unshare rm -rf -- $before" "$output"
    assert_equal "" "$(compgen -G "$BIND.before_restore_*" || true)" "it did not rename the folder"
}

content_in_home_comes_back_if_it_fails() {
    local output f
    TMP=$(mktemp -d -p "$HOME" .rtest_XXXXXXXX)
    prepare_service
    backup_service
    # The last part (the bind) is damaged: what was there before has already been moved when it crashes
    f=$(compgen -G "$LAST_BACKUP/rtest/volumes/bind_*.tar.zst")
    truncate -s $(( $(stat -c %s -- "$f") / 2 )) -- "$f"
    sign "$LAST_BACKUP/rtest"
    change_data
    if output=$(RESTORE_TEST_NO_RENAME=$BIND restore_rtest); then
        echo "$output"
        echo "FAILED: it should have ended with an error"
        exit 1
    fi
    echo "$output"
    contains "everything was left the way it was" "$output"
    assert_equal changed "$(cat -- "$BIND/b.txt")" "the content came back"
    assert_equal running "$(state)" "it started again"
    assert_equal "" "$(before_in_home)" "nothing was left in ~/.before_restore"
}

# ---------- VolumeBackup.sh: service info file and old backups ----------

# Every backed-up service carries its info file (type, compose file), the recipe of
# its containers and its images, all signed in SHA256SUMS
service_info_file() {
    local d
    # With "./" the compose records it as it is; the info file stores it clean
    prepare_service ./stack.yaml
    backup_service
    d=$LAST_BACKUP/rtest
    assert_equal compose "$(awk -F'\t' '$1 == "type" { print $2 }' "$d/SERVICE.tsv")" "type"
    assert_equal stack.yaml "$(awk -F'\t' '$1 == "compose_files" { print $2 }' "$d/SERVICE.tsv")" "compose file"
    assert_equal rtest_app "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[0]["Name"])' "$d/CONTAINERS.json")" "recipe"
    contains "nginx:alpine" "$(cat -- "$d/IMAGES.tsv")"
    for f in SERVICE.tsv CONTAINERS.json IMAGES.tsv; do
        contains "  $f" "$(cat -- "$d/SHA256SUMS")"
    done
}

# With the info file, the restore brings a compose up even if its file does not have a usual name
restores_compose_with_another_name() {
    prepare_service stack.yaml
    backup_service
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest -f stack.yaml down -v) > /dev/null 2>&1
    rm -rf -- "$COMPOSE_DIR" "$BIND"
    restore_rtest
    assert_equal running "$(state)" "it was brought up with stack.yaml"
    assert_equal original "$(volume_data)" "volume restored"
}

# An info file that is not in SHA256SUMS (or with an odd type) is not trusted
unsigned_service_info_is_rejected() {
    load
    fake_backup "$TMP/s"
    printf 'key\tvalue\ntype\tstandalone\n' > "$TMP/s/SERVICE.tsv"
    read_manifest "$TMP/s"
    assert_fails "unsigned service info" detect_service "$TMP/s" app
    (cd -- "$TMP/s" && sha256sum -- SERVICE.tsv >> SHA256SUMS)
    detect_service "$TMP/s" app
    assert_equal standalone "$s_type" "once signed it is used"
    printf 'key\tvalue\ntype\twhatever\n' > "$TMP/s/SERVICE.tsv"
    assert_fails "odd type" detect_service "$TMP/s" app
    for odd in ../x.yml -x.yml a/b.yml; do
        printf 'key\tvalue\ntype\tcompose\ncompose_files\t%s\n' "$odd" > "$TMP/s/SERVICE.tsv"
        assert_fails "compose file $odd" detect_service "$TMP/s" app
    done
}

# A fake backup from $1 days ago (time $2, HHMM) with the complete services $3...
backup_from_days_ago() {
    local d sv
    d=$BACKUPS/backup_$(date -d "-$1 days" +%F)_$2
    mkdir -p -- "$d"
    echo log > "$d/backup.log"
    for sv in "${@:3}"; do
        mkdir -p -- "$d/$sv"
        echo old > "$d/$sv/MANIFEST.tsv"
        echo old > "$d/$sv/SHA256SUMS"
    done
    printf '%s' "$d"
}

# Real backup of rtest answering $1 to the question about deleting old ones
backup_and_answer() {
    local n
    n=$(podman ps -a --format '{{or (index .Labels "com.docker.compose.project") .Names}} {{.Names}}' \
        | sort | awk '!seen[$1]++ { print $1 }' | grep -nx rtest | cut -d: -f1)
    printf 'n\n%s\n\n%s\ny\n%s\n' "$n" "$BACKUPS" "$1" | "$BACKUP" 2>&1
}

# Each service keeps its 3 newest copies, whatever the date
deletes_old_backups() {
    local new1 new2 new3 fourth very_old shared incomplete link odd output
    prepare_service
    mkdir -p -- "$BACKUPS"
    # Two on the same day count as two copies
    new1=$(backup_from_days_ago 1 1800 x)
    new2=$(backup_from_days_ago 1 0800 x)
    new3=$(backup_from_days_ago 2 0900 x)
    # The fourth one of x is offered even though it is only 3 days old
    fourth=$(backup_from_days_ago 3 0900 x)
    very_old=$(backup_from_days_ago 40 0900 x)
    # x already has more than enough, but it is the only copy of "single": it stays
    shared=$(backup_from_days_ago 50 0900 x single)
    # One that failed halfway (without complete services) is no good for restoring
    incomplete=$(backup_from_days_ago 14 2000)
    link=$BACKUPS/backup_$(date -d '-60 days' +%F)_0900
    ln -s -- "$new1" "$link"
    odd=$BACKUPS/backup_odd
    mkdir -p -- "$odd"
    output=$(backup_and_answer delete)
    echo "$output"
    contains "old backups" "$output"
    contains "its 3 newest backups" "$output"
    for d in "$new1" "$new2" "$new3" "$shared" "$odd" "$link"; do
        [[ -e $d || -L $d ]] || { echo "FAILED: it deleted $d, which had to stay"; exit 1; }
    done
    for d in "$fourth" "$very_old" "$incomplete"; do
        [[ ! -e $d ]] || { echo "FAILED: it did not delete $d"; exit 1; }
    done
    assert_equal 1 "$(compgen -G "$BACKUPS/backup_$(date +%F)_*" | wc -l)" "today's is still there"
}

# With 3 copies or fewer of each service nothing is asked, even if they are old
does_not_ask_with_three() {
    local output
    prepare_service
    mkdir -p -- "$BACKUPS"
    backup_from_days_ago 40 0900 x rtest > /dev/null
    backup_from_days_ago 90 0900 x rtest > /dev/null
    backup_from_days_ago 200 0900 x > /dev/null
    output=$(backup_and_answer delete)
    echo "$output"
    if [[ $output == *"old backups"* ]]; then echo "FAILED: it asked with only 3 copies"; exit 1; fi
    assert_equal 4 "$(compgen -G "$BACKUPS/backup_*" | wc -l)" "nothing was deleted"
}

# KEEP_LAST changes how many stay; an odd value stops the script
keep_count_can_be_changed() {
    local output second
    prepare_service
    mkdir -p -- "$BACKUPS"
    backup_from_days_ago 1 0900 x > /dev/null
    second=$(backup_from_days_ago 2 0900 x)
    output=$(KEEP_LAST=1 backup_and_answer delete)
    echo "$output"
    [[ ! -e $second ]] || { echo "FAILED: with KEEP_LAST=1 it did not offer the second copy"; exit 1; }
    for odd in 0 -1 abc '1;x'; do
        if output=$(KEEP_LAST=$odd "$BACKUP" < /dev/null 2>&1); then
            echo "FAILED: it accepted KEEP_LAST=$odd"; exit 1
        fi
        contains "KEEP_LAST" "$output"
    done
}

# A "y" (or Enter) is not enough: "delete" has to be typed
does_not_delete_without_confirming() {
    local old output
    prepare_service
    mkdir -p -- "$BACKUPS"
    backup_from_days_ago 1 0900 x > /dev/null
    backup_from_days_ago 2 0900 x > /dev/null
    backup_from_days_ago 3 0900 x > /dev/null
    old=$(backup_from_days_ago 40 0900 x)
    output=$(backup_and_answer y)
    echo "$output"
    contains "Nothing was deleted" "$output"
    [[ -d $old ]] || { echo "FAILED: it deleted it without confirming"; exit 1; }
}

# ---------- VolumeBackup.sh: check each container when stopping and when starting ----------

# rtest with a second container, rtest_extra
prepare_two_containers() {
    prepare_service
    sed -i '/^volumes:/i\  extra:\n    image: docker.io/library/nginx:alpine\n    container_name: rtest_extra\n    command: ["sh", "-c", "trap exit TERM; while :; do sleep 1; done"]' \
        "$COMPOSE_DIR/$COMPOSE_FILE"
    (cd -- "$COMPOSE_DIR" && podman-compose -p rtest -f "$COMPOSE_FILE" up -d) > /dev/null 2>&1
    assert_equal running "$(podman inspect -f '{{.State.Status}}' rtest_extra)" "it starts with both running"
}

# Fake podman-compose: runs $1 (bash) when the command is $2; everything else goes to the real one
fake_compose() {
    local real
    real=$(command -v podman-compose)
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/podman-compose" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" $2 "* ]]; then
    $1
    exit 0
fi
exec "$real" "\$@"
EOF
    chmod +x "$TMP/bin/podman-compose"
}

# Fake podman: rtest_extra always shows as "stopping"; everything else goes to the real one
stuck_podman() {
    local real
    real=$(command -v podman)
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "container inspect" && "\${!#}" == rtest_extra ]]; then
    echo stopping
    exit 0
fi
exec "$real" "\$@"
EOF
    chmod +x "$TMP/bin/podman"
}

# With the restore: start returns 0, one container does not start and reverting has to be offered
restore_warns_if_a_container_does_not_start() {
    local output
    prepare_two_containers
    backup_service
    change_data
    fake_compose 'podman start rtest_app > /dev/null' start
    # Answers "y" to reverting: since start still does not bring it up, it must not be reported as good either
    output=$(printf 'n\n%s\n1\n2\nrestore\ny\n' "$LAST_BACKUP" | PATH=$TMP/bin:$PATH "$RESTORE" 2>&1 || true)
    echo "$output"
    contains "did NOT start" "$output"
    contains "rtest_extra" "$output"
    contains "put back, but does NOT START" "$output"
    if [[ $output == *"restored and running"* ]]; then echo "FAILED: it said it started"; exit 1; fi
    assert_equal changed "$(volume_data)" "it put back the previous data"
}

# With a container half stopped the data is not touched
does_not_restore_if_stuck_stopping() {
    local output
    prepare_two_containers
    backup_service
    change_data
    stuck_podman
    output=$(printf 'n\n%s\n1\n2\nrestore\n' "$LAST_BACKUP" | PATH=$TMP/bin:$PATH "$RESTORE" 2>&1 || true)
    echo "$output"
    contains "It did not finish stopping" "$output"
    contains "stopping" "$output"
    assert_equal changed "$(volume_data)" "the data is not touched"
    assert_equal "" "$(before_copies)" "nothing was set aside"
}

# A real incident: start returns 0 but one container did not start
warns_if_a_container_does_not_start() {
    local output
    prepare_two_containers
    fake_compose 'podman start rtest_app > /dev/null' start
    PATH=$TMP/bin:$PATH backup_service
    output=$(cat -- "$TMP/backup.out")
    echo "$output"
    contains "did NOT come back up" "$output"
    contains "rtest_extra" "$output"
    contains "ATTENTION" "$output"
    if [[ $output == *"Started again"* ]]; then echo "FAILED: it said it started"; exit 1; fi
}

warns_if_not_up_after_restart() {
    local output
    prepare_two_containers
    fake_compose 'podman stop rtest_extra > /dev/null' restart
    RESTART=yes PATH=$TMP/bin:$PATH backup_service
    output=$(cat -- "$TMP/backup.out")
    echo "$output"
    contains "did NOT come back up" "$output"
    contains "rtest_extra" "$output"
    contains "ATTENTION" "$output"
}

# A container stuck in "stopping": nothing is copied while it is half stopped
does_not_copy_if_stuck_stopping() {
    local output
    prepare_two_containers
    stuck_podman
    PATH=$TMP/bin:$PATH backup_service || true
    output=$(cat -- "$TMP/backup.out")
    echo "$output"
    contains "It did not finish stopping" "$output"
    contains "stopping" "$output"
    if compgen -G "$BACKUPS/backup_*/rtest/MANIFEST.tsv" > /dev/null; then
        echo "FAILED: it saved a backup with a container half stopped"
        exit 1
    fi
}

clean() {
    [[ -n ${KEEP:-} ]] && { echo "Outputs in $TMP"; return; }
    rm -rf -- "$TMP"
}
trap clean EXIT

echo "Tests for VolumeBackup.sh and VolumeRestore.sh"
run_test choose_numbers choose_numbers
run_test valid_manifest valid_manifest
run_test manifest_rejects_dot_dot manifest_rejects_dot_dot
run_test manifest_rejects_etc manifest_rejects_etc
run_test manifest_rejects_odd_volume manifest_rejects_odd_volume
run_test manifest_rejects_missing_file manifest_rejects_missing_file
run_test sums_detect_change sums_detect_change
run_test detects_compose detects_compose
run_test detects_quadlet_only_its_unit detects_quadlet_only_its_unit
run_test detects_quadlet_by_container_name detects_quadlet_by_container_name
run_test detects_standalone detects_standalone
run_test load_backup_three_cases load_backup_three_cases
run_test remaps_home remaps_home
run_test dry_run_touches_nothing dry_run_touches_nothing
run_test wrong_confirmation_cancels wrong_confirmation_cancels
run_test restores_data restores_data
run_test restores_without_service restores_without_service
run_test twice_in_a_row twice_in_a_row
run_test only_one_part only_one_part
run_test rollback_if_file_truncated rollback_if_file_truncated
run_test revert_if_it_does_not_start revert_if_it_does_not_start
run_test log_in_home_if_read_only log_in_home_if_read_only
run_test over_ssh over_ssh
run_test prompt_visible_with_log prompt_visible_with_log
run_test detects_compose_any_name detects_compose_any_name
run_test check_blocks_unrecognized_compose check_blocks_unrecognized_compose
run_test manifest_rejects_repeated_origin manifest_rejects_repeated_origin
run_test restores_config_on_existing_compose restores_config_on_existing_compose
run_test failed_upload_is_detected failed_upload_is_detected
run_test items_without_dollar_quotes items_without_dollar_quotes
run_test detects_quadlet_with_references detects_quadlet_with_references
run_test detects_quadlet_in_subfolder detects_quadlet_in_subfolder
run_test detects_quadlet_rejects_odd_member detects_quadlet_rejects_odd_member
run_test ctrl_c_over_ssh_waits ctrl_c_over_ssh_waits
run_test service_info_file service_info_file
run_test unsigned_service_info_is_rejected unsigned_service_info_is_rejected
run_test restores_compose_with_another_name restores_compose_with_another_name
run_test deletes_old_backups deletes_old_backups
run_test does_not_delete_without_confirming does_not_delete_without_confirming
run_test does_not_ask_with_three does_not_ask_with_three
run_test keep_count_can_be_changed keep_count_can_be_changed
run_test permission_create_with_sudo permission_create_with_sudo
run_test permission_set_aside_with_sudo permission_set_aside_with_sudo
run_test restores_into_empty_folder restores_into_empty_folder
run_test foreign_container_is_not_touched foreign_container_is_not_touched
run_test foreign_container_is_set_aside foreign_container_is_set_aside
run_test foreign_container_comes_back_if_it_fails foreign_container_comes_back_if_it_fails
run_test foreign_container_comes_back_if_it_does_not_start foreign_container_comes_back_if_it_does_not_start
run_test sets_content_aside_in_home sets_content_aside_in_home
run_test content_in_home_comes_back_if_it_fails content_in_home_comes_back_if_it_fails
run_test warns_if_a_container_does_not_start warns_if_a_container_does_not_start
run_test warns_if_not_up_after_restart warns_if_not_up_after_restart
run_test does_not_copy_if_stuck_stopping does_not_copy_if_stuck_stopping
run_test restore_warns_if_a_container_does_not_start restore_warns_if_a_container_does_not_start
run_test does_not_restore_if_stuck_stopping does_not_restore_if_stuck_stopping

echo
printf '%d passed, %d failed\n' "$passes" "$failures"
(( failures == 0 ))
