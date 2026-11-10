#!/usr/bin/env bash
# Restores backups made with VolumeBackup.sh, on this machine or on a server over SSH.
# It is interactive: it asks where to restore, which backup and which services.
#   DRY_RUN=yes   checks everything and says what it would do, without stopping,
#                 moving or extracting anything
#   -h, --help    show this help
# What was there before is not deleted: it is renamed to <path>.before_restore_<date> (or,
# if the parent folder belongs to root, its content is kept in ~/.before_restore/<date><path>).
set -euo pipefail
umask 077

DRY_RUN=${DRY_RUN:-no}

log="" use_ssh=no dest=""
ssh_opts=() services=() result=() backup_dir=""
m_file=() m_type=() m_origin=() m_restore=() m_bytes=()
s_type="" s_dir="" s_unit="" s_members="" s_compose_f="" s_image="" s_names=""
ctl_dir="" srv_home="" remote_output="" restorable=()
declare -gA svc_type=() svc_dir=() svc_unit=() svc_items=() svc_parts=() svc_bytes=() \
           svc_files=() svc_stamp=() svc_running=() svc_exists=() remaps=() \
           svc_compose_f=() svc_image=() svc_names=() svc_set_aside=()
declare -gA r_state=() r_before=() r_stopped=() r_time=() r_started=() perm_create=() perm_chown=() perm_set_aside=()
pending=() srv_user=""
remote_tmp="" method=local capture_pid="" finished=no t_start=0 port=22 cancelled=no
critical=() failed=()

exec 3>&1 4>&2
if [[ -t 1 ]]; then
    tty=yes
    cols=$(tput cols 2>/dev/null || echo 80)
    c_green=$'\e[32m' c_red=$'\e[31m' c_yellow=$'\e[33m' c_dim=$'\e[2m'
    c_bold=$'\e[1m' c_end=$'\e[0m' erase=$'\r\e[K'
else
    tty=no cols=80
    c_green="" c_red="" c_yellow="" c_dim="" c_bold="" c_end="" erase=""
fi

# ---------- Utilities ----------

now() {
    local us=${EPOCHREALTIME:-}
    us=${us/[.,]/}
    [[ -n $us ]] || us=$(date +%s%6N)
    printf -v "$1" '%d' $(( us / 1000 ))
}

hsize() { numfmt --to=iec -- "${1:-0}"; }

duration() {
    local ms=$1 s=$(( $1 / 1000 ))
    if (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif (( s >= 60 )); then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else printf '%d.%ds' "$s" $(( ms % 1000 / 100 ))
    fi
}

speed() {
    if (( $2 > 0 )); then printf '%s/s' "$(hsize $(( $1 * 1000 / $2 )))"; else printf -- '-'; fi
}

# ---------- Output: the terminal gets a summary, the log gets the details ----------

to_log() {
    [[ -n $log ]] || return 0
    printf '%(%T)T  %s\n' -1 "$*" >> "$log"
}

raw() {
    [[ -n $log ]] || return 0
    printf '%s\n' "$*" >> "$log"
}

message() {
    local fd=$1 color=$2 symbol=$3
    shift 3
    printf '%s%s%(%T)T%s %s%s%s %s\n' "$erase" "$c_dim" -1 "$c_end" "$color" "$symbol" "$c_end" "$*" >&"$fd"
    to_log "$symbol $*"
}

info()    { message 3 "" " " "$*"; }
success()   { message 3 "$c_green" "✓" "$*"; }
warn()   { message 4 "$c_yellow" "!" "$*"; }
error()   { message 4 "$c_red" "✗" "$*"; }
detail() { to_log "  $*"; }

title() {
    printf '%s\n%s▸ %s%s\n' "$erase" "$c_bold" "$*" "$c_end" >&3
    raw ""
    raw "──────── $* ────────"
}

clear_line() {
    if [[ $tty == yes ]]; then printf '%s' "$erase" >&3; fi
}

bar() {
    [[ $tty == yes ]] || return 0
    local current=$1 total=$2 text=$3 pct=0 filled empty line
    if (( total > 0 )); then pct=$(( current * 100 / total )); fi
    if (( pct > 100 )); then pct=100; fi
    printf -v filled '%*s' $(( pct / 5 )) ''
    printf -v empty '%*s' $(( 20 - pct / 5 )) ''
    printf -v line '         %s%s %3d%%  %s / %s  %s' \
        "${filled// /█}" "${empty// /░}" "$pct" "$(hsize "$current")" "$(hsize "$total")" "$text"
    printf '%s%s' "$erase" "${line:0:cols-1}" >&3
}

# Asks and leaves the answer in the variable $1. read -p writes to stderr, which during
# the restore goes to the log line by line: without 2>&4 it would not be seen.
ask() {
    read -rp "$2" "$1" 2>&4
}

# Anything that leaks to stderr (ssh, podman, sha256sum...) is shown and kept in the log
capture_stderr() {
    local line
    # Ctrl+C must not silence it: the log and the messages go on until the end
    trap '' INT
    while IFS= read -r line; do
        printf '%s%s\n' "$erase" "$line" >&4
        printf '%(%T)T  [stderr] %s\n' -1 "$line" >> "$log"
    done
}

# ---------- Server connection ----------

# With ssh the command is sent to the server; without ssh, bash -c parses it again just
# like ssh would, so the rest of the script does not care which mode it is in.
on_server() {
    if [[ $use_ssh == yes ]]; then
        # Built on this side on purpose: the data is already protected with %q
        # shellcheck disable=SC2029
        ssh "${ssh_opts[@]}" "$dest" "$@"
    else
        bash -c "$*"
    fi
}

# Turns "1 3 5", "1,3" or "all" into elements of "services", without repeats.
# Leaves them in "result". An empty answer means none.
choose() {
    local answer=${1,,}
    local n group
    local -a numbers
    local -A seen=()

    answer=${answer//,/ }
    result=()
    if [[ $answer == all ]]; then
        result=("${services[@]}")
        return 0
    fi
    read -ra numbers <<< "$answer"
    for n in "${numbers[@]}"; do
        if [[ ! $n =~ ^[1-9][0-9]*$ ]] || (( n > ${#services[@]} )); then
            echo "Invalid option: $n" >&2
            return 1
        fi
        group=${services[n - 1]}
        if [[ -z ${seen[$group]:-} ]]; then
            seen[$group]=1
            result+=("$group")
        fi
    done
}

# ---------- Read and validate the backup ----------

readonly HEADER=$'file\ttype\torigin\trestore_to\tbytes_original\tbytes_compressed'

# The manifest decides what gets renamed and where things are extracted: a tampered
# manifest must not be able to write to the system or escape with "..".
allowed_path() {
    local r=$1
    [[ $r == /* && $r != */ && $r != *//* && "$r/" != */../* && "$r/" != */./* ]] || return 1
    case $r in
        /home|/root|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*| \
        /boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/var/run|/var/run/*) return 1 ;;
    esac
}

# Checks one row; uses the variables of read_manifest and leaves the why in "reason"
valid_row() {
    case $type in
        config)       [[ $file =~ ^config/[A-Za-z0-9._-]+\.tar\.zst$ ]] ;;
        volume|bind) [[ $file =~ ^volumes/[A-Za-z0-9._-]+\.tar\.zst$ ]] ;;
        *) reason="unknown type '$type'"; return 1 ;;
    esac || { reason="odd file name '$file'"; return 1; }
    if [[ ! -f $d/$file ]]; then reason="the file $file is missing"; return 1; fi
    if [[ ! $bytes =~ ^[0-9]+$ ]]; then reason="odd size '$bytes'"; return 1; fi
    if [[ $type == volume ]]; then
        if [[ ! $origin =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ || $restore != "$origin" ]]; then
            reason="odd volume name '$origin'"
            return 1
        fi
    elif [[ $origin == *[\|,]* ]]; then
        reason="the path '$origin' contains | or ,"
        return 1
    elif ! allowed_path "$origin"; then
        reason="path not allowed: '$origin'"
        return 1
    elif [[ $restore != "$(dirname -- "$origin")" ]]; then
        reason="'$restore' is not the folder of '$origin'"
        return 1
    fi
}

# Fills m_file, m_type, m_origin, m_restore and m_bytes with the rows of DIR/MANIFEST.tsv
read_manifest() {
    local d=$1 header file type origin restore bytes _comp reason n=1
    local -A seen=()
    m_file=() m_type=() m_origin=() m_restore=() m_bytes=()
    if [[ ! -f $d/MANIFEST.tsv ]]; then
        error "There is no MANIFEST.tsv in $d"
        return 1
    fi
    {
        IFS= read -r header || true
        if [[ $header != "$HEADER" ]]; then
            error "$d/MANIFEST.tsv is not in the VolumeBackup.sh format"
            return 1
        fi
        while IFS=$'\t' read -r file type origin restore bytes _comp; do
            n=$(( n + 1 ))
            if ! valid_row; then
                error "$d/MANIFEST.tsv, row $n: $reason. Not restoring this service"
                return 1
            fi
            # Two parts in the same place would overwrite each other (and the rollback would delete the original)
            if [[ -n ${seen[$origin]:-} ]]; then
                error "$d/MANIFEST.tsv, row $n: $origin appears twice. Not restoring this service"
                return 1
            fi
            seen[$origin]=1
            m_file+=("$file") m_type+=("$type") m_origin+=("$origin")
            m_restore+=("$restore") m_bytes+=("$bytes")
        done
    } < "$d/MANIFEST.tsv"
    if (( ${#m_file[@]} == 0 )); then
        error "$d/MANIFEST.tsv is empty"
        return 1
    fi
}

# Every file in the manifest must be signed in SHA256SUMS and match
verify_sums() {
    local d=$1 a
    if [[ ! -f $d/SHA256SUMS ]]; then
        error "There is no SHA256SUMS in $d"
        return 1
    fi
    for a in "${m_file[@]}" MANIFEST.tsv; do
        if ! awk -v a="$a" '$2 == a { found = 1 } END { exit !found }' "$d/SHA256SUMS"; then
            error "$a is not in SHA256SUMS"
            return 1
        fi
    done
    if ! (cd -- "$d" && sha256sum -c --quiet SHA256SUMS >&2); then
        error "The files in $d do not match SHA256SUMS: the backup is damaged"
        return 1
    fi
}

# Backups carry SERVICE.tsv (the service info file): it says what type of service it is.
# Backups without it: the type is detected from the saved config.
# Leaves s_type (compose|quadlet|standalone), s_dir, s_unit, s_members, s_compose_f, s_image
# and s_names (the containers of the service, comma separated).
detect_service() {
    local d=$1 group=$2 i f member root
    local -a list
    s_type=standalone s_dir="" s_unit="" s_members="" s_compose_f="" s_image="" s_names=""
    if [[ -f $d/SERVICE.tsv ]]; then
        read_service_info "$d" "$group"
        return
    fi
    for i in "${!m_type[@]}"; do
        [[ ${m_type[i]} == config ]] || continue
        f=$d/${m_file[i]}
        mapfile -t list < <(zstd -dc -- "$f" | tar -t | LC_ALL=C sort)

        if [[ ${m_origin[i]} == */containers/systemd || ${m_origin[i]} == */containers/systemd/* ]]; then
            detect_quadlet "$f" "$group" "${m_origin[i]}"
            return
        fi

        root=${m_origin[i]##*/}
        for member in "${list[@]}"; do
            case ${member#"$root"/} in
                docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml|podman-compose.yml|podman-compose.yaml)
                    s_type=compose s_dir=${m_origin[i]}
                    return 0
                    ;;
            esac
        done
        # Any other .yml/.yaml in the folder that has "services:" is also compose
        for member in "${list[@]}"; do
            [[ $member == "$root"/*.y*ml && ${member#"$root"/} != */* ]] || continue
            if zstd -dc -- "$f" | tar -xOf - "$member" | grep -Ec '^services:' > /dev/null; then
                s_type=compose s_dir=${m_origin[i]}
                return 0
            fi
        done
    done
}

read_service_info() {
    local d=$1 group=$2 key value type="" cf="" i x
    local -a xs
    if ! awk '$2 == "SERVICE.tsv" { found = 1 } END { exit !found }' "$d/SHA256SUMS" 2>/dev/null; then
        error "$d/SERVICE.tsv is not signed in SHA256SUMS"
        return 1
    fi
    while IFS=$'\t' read -r key value; do
        case $key in
            type)             type=$value ;;
            compose_files) cf=$value ;;
        esac
    done < "$d/SERVICE.tsv"
    if [[ -f $d/IMAGES.tsv ]] && awk '$2 == "IMAGES.tsv" { found = 1 } END { exit !found }' "$d/SHA256SUMS"; then
        s_image=$(awk -F'\t' 'NR == 1 { print $2 }' "$d/IMAGES.tsv")
        s_image=${s_image//[^[:print:]]/}
        # The first column holds the names of its containers: they are used to check
        # whether other containers are using those names today
        while IFS=$'\t' read -r x _; do
            if [[ ! $x =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
                error "$d/IMAGES.tsv: odd container name '$x'"
                return 1
            fi
            s_names+=${s_names:+,}$x
        done < "$d/IMAGES.tsv"
    fi

    case $type in
        compose)
            # The compose folder is the first config the backup holds
            for i in "${!m_type[@]}"; do
                if [[ ${m_type[i]} == config ]]; then s_dir=${m_origin[i]}; break; fi
            done
            if [[ -z $s_dir ]]; then
                error "$group is compose but the backup does not include its folder"
                return 1
            fi
            IFS=, read -ra xs <<< "$cf"
            for x in "${xs[@]}"; do
                if [[ ! $x =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
                    error "$d/SERVICE.tsv: odd compose file name '$x'"
                    return 1
                fi
            done
            s_type=compose s_compose_f=$cf
            ;;
        quadlet)
            for i in "${!m_type[@]}"; do
                if [[ ${m_type[i]} == config && ( ${m_origin[i]} == */containers/systemd || ${m_origin[i]} == */containers/systemd/* ) ]]; then
                    detect_quadlet "$d/${m_file[i]}" "$group" "${m_origin[i]}"
                    return
                fi
            done
            error "$group is a Quadlet but the backup does not include its units"
            return 1
            ;;
        standalone) s_type=standalone ;;
        *)
            error "$d/SERVICE.tsv: odd service type '$type'"
            return 1
            ;;
    esac
}

# Finds the .container unit of the service. If the folder holds ALL the units, it leaves
# in s_members only what belongs to it: its files, its drop-in and the units it uses.
detect_quadlet() {
    local f=$1 group=$2 origin=$3 member m base name content line value
    local -a list
    local -A uses=()
    mapfile -t list < <(zstd -dc -- "$f" | tar -t | LC_ALL=C sort)
    for m in "${list[@]}"; do
        # These names end up in mv and tar -x: nothing outside the folder, and the comma is the separator
        if [[ $m == /* || "/$m/" == */../* || $m == *[,\|]* ]]; then
            error "The Quadlet backup contains a file with an odd name: $m"
            return 1
        fi
    done
    for member in "${list[@]}"; do
        [[ $member == *.container ]] || continue
        base=${member##*/}
        base=${base%.container}
        content=$(zstd -dc -- "$f" | tar -xOf - "$member")
        if [[ $group != "$base" && $group != "systemd-$base" &&
              $'\n'$content$'\n' != *$'\nContainerName='"$group"$'\n'* ]]; then
            continue
        fi
        s_type=quadlet s_unit=$base.service
        # In its own subfolder everything belongs to it
        [[ $origin == */containers/systemd ]] || return 0
        while IFS= read -r line; do
            [[ $line =~ ^(Volume|Network|Pod|Image|Mount)[[:space:]]*=[[:space:]]*([^:[:space:]]+) ]] || continue
            value=${BASH_REMATCH[2]}
            case $value in *.volume|*.network|*.pod|*.image|*.build|*.kube) uses[$value]=1 ;; esac
        done <<< "$content"
        for m in "${list[@]}"; do
            [[ $m != */ ]] || continue
            name=${m##*/}
            if [[ ${name%.*} == "$base" || $m == */"$base".container.d/* || -n ${uses[$name]:-} ]]; then
                s_members+=${s_members:+,}$m
            fi
        done
        return 0
    done
    error "Could not find the Quadlet unit of $group in ${f##*/}"
    return 1
}

# Fills "services" with the folders of DIR that have a MANIFEST.tsv
services_en() {
    local f name
    services=()
    for f in "$1"/*/MANIFEST.tsv; do
        [[ -f $f ]] || continue
        f=${f%/MANIFEST.tsv}
        name=${f##*/}
        if [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            services+=("$name")
        else
            warn "Skipping the folder $f: its name is odd"
        fi
    done
}

# PATH can be the folder of one service, of one backup (backup_...) or the one that
# holds several backups (then it asks which one). Leaves backup_dir and services.
load_backup() {
    local path=${1%/} d n name when answer
    local -a backups=()
    backup_dir="" services=()

    if [[ -f $path/MANIFEST.tsv ]]; then
        backup_dir=$(dirname -- "$path")
        services=("${path##*/}")
        return 0
    fi
    services_en "$path"
    if (( ${#services[@]} > 0 )); then
        backup_dir=$path
        return 0
    fi

    # The name carries the date: reversed, the newest comes first
    for d in "$path"/backup_*/; do
        d=${d%/}
        if compgen -G "$d/*/MANIFEST.tsv" > /dev/null; then backups=("$d" "${backups[@]}"); fi
    done
    if (( ${#backups[@]} == 0 )); then
        error "No backups found in $path"
        return 1
    fi

    echo >&3
    for n in "${!backups[@]}"; do
        name=${backups[n]##*/}
        when=${name#backup_}
        if [[ $when =~ ^([0-9-]{10})_([0-9]{2})([0-9]{2})$ ]]; then
            when="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        fi
        printf '  %2d) %-16s %s%s · %s%s\n' $(( n + 1 )) "$when" "$c_dim" \
            "$(du -sh -- "${backups[n]}" | cut -f1)" "$name" "$c_end" >&3
    done
    echo >&3
    ask answer "Which backup? (Enter = the newest): "
    answer=${answer:-1}
    if [[ ! $answer =~ ^[1-9][0-9]*$ ]] || (( answer > ${#backups[@]} )); then
        error "Invalid option: $answer"
        return 1
    fi
    backup_dir=${backups[answer - 1]}
    services_en "$backup_dir"
}

# Paths under /home/<another user> are moved to the home of whoever restores
remap_home() {
    local old=$1 new=$2 i
    for i in "${!m_type[@]}"; do
        [[ ${m_type[i]} != volume && ${m_origin[i]} == "$old"/* ]] || continue
        m_origin[i]=$new${m_origin[i]#"$old"}
        m_restore[i]=$new${m_restore[i]#"$old"}
    done
}

# ---------- Talking to the server ----------

# Turns the events sent by the server ("@@TYPE<tab>data...") into terminal and log output
route() {
    local line ev a b c total=0 label=""
    # On Ctrl+C keep showing what the server reports until it is done
    trap '' INT
    while IFS= read -r line; do
        if [[ $line == *'@@PROG '* ]]; then
            a=${line#*@@PROG }
            bar "${a%% *}" "$total" "$label"
            continue
        elif [[ $line != @@* ]]; then
            detail "server: $line"
            continue
        fi
        IFS=$'\t' read -r ev a b c <<< "${line#@@}"
        case $ev in
            INFO)          info "$a" ;;
            DET)           detail "  $a" ;;
            WARN)         warn "$a" ;;
            ERROR|CRITICAL) error "$a" ;;
            STOPPED)         message 3 "$c_yellow" "■" "Stopped; restoring..." ;;
            ALREADY_STOPPED) message 3 "$c_yellow" "■" "It was stopped" ;;
            EXTRACTING)
                total=$a label="$b $c"
                if [[ $tty == yes ]]; then detail "Extracting $b $c ($(hsize "$a"))"
                else info "Extracting $b $c ($(hsize "$a"))"
                fi
                ;;
            EXTRACTED)
                clear_line
                detail "  extracted in $(duration "$a") ($(speed "$total" "$a"))"
                ;;
            STARTED)       message 3 "$c_green" "▶" "Started · it was down for $(duration "$a")" ;;
            REVERTING)     warn "Putting $a back the way it was" ;;
            *)             detail "server: $line" ;;
        esac
    done
}

# Runs $REMOTE on the server for a service that is already built. Leaves what it returns in "remote_output".
remote() {
    local action=$1 group=$2 rc=0 args
    local -a items params
    mapfile -t items <<< "${svc_items[$group]}"
    params=("$action" "$group" "${svc_type[$group]}" "${svc_dir[$group]}" "${svc_unit[$group]}"
            "${svc_files[$group]}" "${svc_stamp[$group]}" "${svc_compose_f[$group]:-}"
            "${svc_names[$group]:-}" "${svc_set_aside[$group]:-no}" "${r_started[$group]:-}" "${items[@]}")
    # ssh joins everything into one string that the server parses again; %q makes
    # every value arrive whole and nothing gets executed.
    printf -v args '%q ' "${params[@]}"
    # $( ) waits for route to finish (it inherits its output), so no message
    # arrives late or gets mixed with what comes next.
    if [[ $use_ssh == yes && $action != check ]]; then
        # Once the service is stopped, cutting ssh would leave the server working blind:
        # ssh runs in its own session (Ctrl+C does not reach it); here we warn and wait.
        trap 'cancelled=yes; warn "The server is still working on $group; wait for it to finish (cutting it halfway would leave half-written data). After that I will not go on with the others."' INT
        # shellcheck disable=SC2029
        remote_output=$(setsid -w ssh "${ssh_opts[@]}" "$dest" "bash -s -- $args" <<< "$REMOTE" 2> >(route)) || rc=$?
        trap 'exit 130' INT
    else
        remote_output=$(on_server "bash -s -- $args" <<< "$REMOTE" 2> >(route)) || rc=$?
    fi
    return "$rc"
}

# ---------- Script that runs on the server ----------

# It lives inside main() so bash reads all of it before starting: if the connection
# drops halfway, no half-read script is left running with the service stopped.
# Parameters: action group type dir unit files stamp compose_f names set_aside started item...
# (compose_f: compose files, comma separated; empty = the default ones;
#  names: its containers, comma separated; set_aside: yes = set aside the ones that are
#  not its own; started: the set-aside ones that were running, to bring them back that way)
# Each item: type|file|origin|restore|bytes|members. No tabs on purpose: with a tab,
# %q uses $'…', which the server shell does not understand if it is dash or fish.
read -r -d '' REMOTE <<'EOF' || true
main() {
    set -Eeuo pipefail
    trap '' HUP PIPE
    trap 'exit 130' INT TERM
    # Without SSH, bash inherits descriptors from the main script; if a container
    # started here keeps one, the main script waits forever.
    local fd
    for fd in /proc/self/fd/*; do
        fd=${fd##*/}
        if (( fd > 2 )); then eval "exec $fd>&-" 2>/dev/null || true; fi
    done
    exec 5>&1 6>&2 1>&2

    action=$1 group=$2 type=$3 dir=$4 unit=$5 files=$6 stamp=$7 compose_f=$8
    names=$9 set_aside_foreign=${10} started=${11}
    shift 11
    items=("$@")
    lock=${XDG_RUNTIME_DIR:-/tmp}/backup-podman-$group.lock

    event()    { local IFS=$'\t'; printf '@@%s\n' "$*" >&6 || true; }
    result() { printf '%s %s\n' "$1" "$2" >&5 || true; }
    now()     { local us=${EPOCHREALTIME:-}; us=${us/[.,]/}; [[ -n $us ]] || us=$(date +%s%6N); printf -v "$1" '%d' $(( us / 1000 )); }
    trap 'event ERROR "«$BASH_COMMAND» failed (code $?)"' ERR

    running() {
        if [[ $type == compose ]]; then
            podman ps --filter "label=com.docker.compose.project=$group" --format '{{.Names}}'
        else
            podman ps --filter "name=^${group//./\\.}\$" --format '{{.Names}}'
        fi
    }

    exists() {
        if [[ $type == compose ]]; then
            [[ -n $(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}') ]]
        else
            podman container exists "$group"
        fi
    }

    # There are containers of a compose with this name but compose was not detected here:
    # we would not know how to stop it, so it is left alone (it would mean restoring under a running database)
    foreign_compose() {
        [[ $type != compose && -n $(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}') ]]
    }

    # Containers with the names of this service that do not belong to it (another compose,
    # another unit or made by hand; e.g. someone brought it up in a hurry from another folder).
    # They hold the names: what gets restored could not be started. One line for each:
    # "name where it comes from".
    foreign() {
        local n project folder unit_c
        local -a xs
        [[ -n $names ]] || return 0
        IFS=, read -ra xs <<< "$names"
        for n in "${xs[@]}"; do
            [[ -n $(podman ps -a --filter "name=^${n//./\\.}\$" --format '{{.Names}}') ]] || continue
            IFS='|' read -r project folder unit_c < <(podman inspect "$n" --format \
                '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}')
            case $type in
                compose) [[ $project != "$group" ]] || continue ;;
                quadlet) [[ $unit_c != "$unit" ]] || continue ;;
                *)       [[ $n != "$group" ]] || continue ;;
            esac
            if [[ -n $project ]]; then printf '%s project %s, folder %s\n' "$n" "$project" "${folder:-?}"
            elif [[ -n $unit_c ]]; then printf '%s service %s\n' "$n" "$unit_c"
            else printf '%s created by hand\n' "$n"
            fi
        done
    }

    # Mountpoint of a volume; empty or "/" would mean rm -rf of everything
    mount_dir() {
        local mp
        mp=$(podman volume inspect "$1" --format '{{.Mountpoint}}')
        if [[ $mp != /?* || $mp == / ]]; then
            event ERROR "The volume $1 has no valid folder ('$mp')"
            return 1
        fi
        printf '%s' "$mp"
    }

    read_item() {
        IFS='|' read -r i_type i_file i_origin i_restore i_bytes i_members <<< "$1"
    }

    # What an item replaces on disk: its folder or, for a Quadlet, only its files
    paths_item() {
        local m
        local -a ms
        paths=()
        if [[ -n $i_members ]]; then
            IFS=, read -ra ms <<< "$i_members"
            for m in "${ms[@]}"; do paths+=("$i_restore/$m"); done
        else
            paths=("$i_origin")
        fi
    }

    # First parent that exists, to measure the disk where it will land
    existing() {
        local p=$1
        while [[ ! -e $p ]]; do p=$(dirname -- "$p"); done
        printf '%s' "$p"
    }

    # As "root of the containers": this is how things are really set aside and extracted
    can_write() { podman unshare test -w "$1"; }
    is_empty() { [[ -d $1 && ! -L $1 && -z $(podman unshare ls -A -- "$1") ]]; }

    # To set a folder aside by renaming it, the parent folder must be writable
    can_rename() {
        # Only for the tests (and only without SSH): pretend the parent folder belongs to root
        [[ ",${RESTORE_TEST_NO_RENAME:-}," != *",$1,"* ]] && can_write "$(dirname -- "$1")"
    }

    # Moving between two places is only instant (and needs no extra space) if they are on the
    # same filesystem and the same mount point (a btrfs subvolume counts as a different one)
    same_disk() {
        local a b
        a=$(existing "$1") b=$(existing "$2")
        [[ $(stat -c %d -- "$a") == "$(stat -c %d -- "$b")" &&
           $(df --output=target -- "$a" | tail -n 1) == "$(df --output=target -- "$b" | tail -n 1)" ]]
    }

    # The folder is yours and has data, but its parent belongs to root (typical: /opt): it cannot
    # be renamed, so what is inside is moved to ~/.before_restore/<stamp><path>
    before_in_home() { printf '%s' "$HOME/.before_restore/$stamp$1"; }
    moves_to_home() {
        [[ -d $1 && ! -L $1 ]] && can_write "$1" && ! can_rename "$1" &&
            same_disk "$1" "$HOME/.before_restore"
    }

    # Will it be possible to set aside what is there and extract? If not, which folder has to
    # be prepared with sudo (create it, change its owner or set aside what it holds). Typical
    # on a new machine: /opt belongs to root and the user cannot create anything there.
    check_permissions() {
        local p=$i_origin
        if [[ -n $i_members ]]; then
            can_write "$(existing "$i_restore")" || result no_permission "create $i_restore"
            return 0
        fi
        if [[ -e $p || -L $p ]]; then
            if is_empty "$p"; then
                can_write "$p" || result no_permission "chown $p"
            elif moves_to_home "$p"; then
                result in_home "$(before_in_home "$p")"
                if [[ -e $(before_in_home "$p") ]]; then result clash "$(before_in_home "$p")"; fi
            elif ! can_rename "$p"; then
                result no_permission "set_aside $p"
            fi
        elif ! can_write "$(existing "$i_restore")"; then
            result no_permission "create $p"
        fi
    }

    check() {
        local p item place mp hsize free
        local -a programs=(podman tar zstd sha256sum flock)
        local -A needs=()

        result home "$HOME"
        result user "$(id -un)"
        if foreign_compose; then result foreign_compose yes; fi
        if [[ -n $(running) ]]; then result running yes; else result running no; fi
        if exists; then result exists yes; else result exists no; fi
        while IFS= read -r p; do result foreign "$p"; done < <(foreign)
        case $type in
            compose) programs+=(podman-compose) ;;
            quadlet) programs+=(systemctl) ;;
        esac
        for p in "${programs[@]}"; do
            command -v "$p" > /dev/null || result lacking "$p"
        done

        exec 9> "$lock"
        if ! flock -n 9; then result busy yes; fi
        exec 9>&-

        for item in "${items[@]}"; do
            read_item "$item"
            if [[ $i_type == volume ]]; then
                place=$(podman info --format '{{.Store.VolumePath}}')
                if podman volume exists "$i_origin"; then
                    mp=$(mount_dir "$i_origin")
                    hsize=$(podman unshare du -sb -- "$mp" | cut -f1)
                    result overwrite "volume $hsize $i_origin"
                fi
                if podman volume exists "$i_origin.before_restore_$stamp"; then
                    result clash "volume $i_origin.before_restore_$stamp"
                fi
            else
                place=$i_restore
                paths_item
                for p in "${paths[@]}"; do
                    if [[ -e $p || -L $p ]]; then
                        hsize=$(podman unshare du -sb -- "$p" | cut -f1)
                        result overwrite "$i_type $hsize $p"
                    fi
                    if [[ -e $p.before_restore_$stamp ]]; then result clash "$p.before_restore_$stamp"; fi
                done
                check_permissions
            fi
            # What was there is renamed (not deleted): the restored data takes its full size in extra space
            mp=$(df --output=target -- "$(existing "$place")" | tail -n 1)
            needs[$mp]=$(( ${needs[$mp]:-0} + i_bytes ))
        done
        for mp in "${!needs[@]}"; do
            free=$(df -B1 --output=avail -- "$mp" | tail -n 1)
            free=${free//[[:space:]]/}
            if (( needs[$mp] > free )); then
                result no_space "${needs[$mp]} $free $mp"
            fi
        done
    }

    # Whatever is started here must not inherit the lock or the ssh channels
    # (5, 6, 9): it would keep them open for as long as the container lives.
    control() {
        local x
        local -a xs cf=()
        if [[ -n $compose_f ]]; then
            IFS=, read -ra xs <<< "$compose_f"
            for x in "${xs[@]}"; do cf+=(-f "$x"); done
        fi
        case $type in
            compose) (cd -- "$dir" && podman-compose -p "$group" "${cf[@]}" "$@") ;;
            quadlet)
                if [[ $1 == start ]]; then systemctl --user daemon-reload; fi
                systemctl --user "$1" "$unit"
                ;;
            standalone)  podman "$1" "$group" ;;
            *)       echo "unknown service type '$type'"; return 1 ;;
        esac 5>&- 6>&- 9>&- 2>&1 | sed -u $'s/^/@@DET\t/' >&2
    }

    # If it already existed it is started as it was; if not (new server), compose creates it.
    # If the config of a compose was restored, the containers are recreated so that they
    # use it (volumes and binds are not touched).
    with_config=no

    # The containers that were running: those are the ones that must come back up.
    # No "local": the emergency trap runs after the function returns.
    expected=() missing="" tolerate_exit=no
    take_expected() {
        local list
        list=$(running)
        if [[ -n $list ]]; then mapfile -t expected <<< "$list"; fi
    }

    take_all() {
        expected=()
        if [[ $type != compose ]]; then
            expected=("$group")
            return 0
        fi
        local list
        list=$(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}')
        if [[ -n $list ]]; then mapfile -t expected <<< "$list"; fi
    }

    state_of() { podman container inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo absent; }

    not_started() {
        local c e
        for c in "${expected[@]}"; do
            e=$(state_of "$c")
            if [[ $e == running ]]; then continue; fi
            # Freshly created ones: we cannot tell which were one-shot jobs, so a clean exit is not a failure
            if [[ $e == exited && $tolerate_exit == yes && $(podman container inspect --format '{{.State.ExitCode}}' "$c") == 0 ]]; then
                continue
            fi
            printf '%s (%s) ' "$c" "$e"
        done
    }

    # A Quadlet removes its container when it stops: "absent" also means stopped
    not_stopped() {
        local c e
        for c in "${expected[@]}"; do
            e=$(state_of "$c")
            case $e in
                exited|stopped|created|configured|absent) ;;
                *) printf '%s (%s) ' "$c" "$e" ;;
            esac
        done
    }

    # $1 = not_started or not_stopped, $2 = seconds. Whatever did not get there is left in $missing
    wait_state() {
        local i
        for (( i = 0; i <= $2; i++ )); do
            missing=$("$1")
            if [[ -z $missing ]]; then return 0; fi
            sleep 1
        done
        return 1
    }

    # No data is touched while a container is still stopping
    stop_and_wait() {
        take_expected
        control stop
        if ! wait_state not_stopped 30; then
            event ERROR "It did not finish stopping: $missing; not touching anything. If it says stopping, start will not bring it up and it has to be recreated."
            exit 1
        fi
    }

    bring_up() {
        local recreated=no
        missing=""
        if [[ $type == compose && $with_config == yes ]] && exists; then
            podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.ID}}' \
                | xargs podman rm > /dev/null
            recreated=yes
        fi
        if [[ $type == compose ]] && ! exists; then
            recreated=yes
            control up -d
        elif [[ $type == standalone ]] && ! exists; then
            event WARN "$group does not exist on this server: its data is already in place, but the container has to be created by hand"
            return 1
        else
            control start
        fi
        # A container that crashes on startup still gets a "good" exit from start
        sleep 3
        # Recreated or on a new server: the names may differ, so the ones that exist are checked
        if [[ $recreated == yes ]] || (( ${#expected[@]} == 0 )); then
            take_all
        fi
        # Only for freshly created ones: an old one that did not start also shows "exited 0"
        tolerate_exit=$recreated
        if (( ${#expected[@]} == 0 )); then
            missing="no containers"
            return 1
        fi
        wait_state not_started 20
    }

    # What was already there is set aside under its previous name, never deleted.
    # h_* remembers every thing set aside or created (to put it back if something fails).
    h_type=() h_path=() h_before=()
    set_aside() {
        local p before mp_v mp_a
        if [[ $i_type == volume ]]; then
            if podman volume exists "$i_origin"; then
                before=$i_origin.before_restore_$stamp
                mp_v=$(mount_dir "$i_origin")
                podman volume create "$before" > /dev/null
                # Recorded BEFORE moving: if it is cut halfway, the rollback puts back
                # what did get moved (without deleting what stayed)
                h_type+=(volume_moving) h_path+=("$i_origin") h_before+=("$before")
                mp_a=$(mount_dir "$before")
                # Same disk: moving is instant even for many GB
                podman unshare bash -ec 'shopt -s dotglob nullglob
                    chown --reference="$1" -- "$2"; chmod --reference="$1" -- "$2"
                    for f in "$1"/*; do mv -- "$f" "$2"/; done' _ "$mp_v" "$mp_a"
                h_type[-1]=volume
                result before "volume $before"
            else
                podman volume create "$i_origin" > /dev/null
                h_type+=(new_volume) h_path+=("$i_origin") h_before+=("")
            fi
            return 0
        fi
        mkdir -p -- "$i_restore"
        paths_item
        for p in "${paths[@]}"; do
            # An empty folder (e.g. the one created with sudo) is used as it is
            if [[ -z $i_members ]] && is_empty "$p"; then
                h_type+=(empty_path) h_path+=("$p") h_before+=("")
                continue
            fi
            if [[ -z $i_members ]] && moves_to_home "$p"; then
                before=$(before_in_home "$p")
                podman unshare mkdir -p -- "$before"
                # Like the volumes: recorded before moving so the rollback puts back
                # what got moved
                h_type+=(content_moving) h_path+=("$p") h_before+=("$before")
                podman unshare bash -ec 'shopt -s dotglob nullglob
                    chown --reference="$1" -- "$2"; chmod --reference="$1" -- "$2"
                    for f in "$1"/*; do mv -- "$f" "$2"/; done' _ "$p" "$before"
                h_type[-1]=content
                result before "$i_type $before"
            elif [[ -e $p || -L $p ]]; then
                podman unshare mv -T -- "$p" "$p.before_restore_$stamp"
                h_type+=(path) h_path+=("$p") h_before+=("$p.before_restore_$stamp")
                result before "$i_type $p.before_restore_$stamp"
            else
                h_type+=(new_path) h_path+=("$p") h_before+=("")
            fi
        done
    }

    # Containers that do not belong to it are stopped and renamed (not removed). It goes
    # before moving data: they may be using the same volumes.
    set_aside_foreign() {
        local line n
        for line in "${foreign_list[@]}"; do
            n=${line%% *}
            # Recorded BEFORE stopping it: if something fails, the rollback puts it back and starts it
            if [[ $(podman inspect -f '{{.State.Running}}' "$n") == true ]]; then
                h_type+=(container_running)
                result foreign_running "$n"
            else
                h_type+=(container)
            fi
            h_path+=("$n") h_before+=("$n.before_restore_$stamp")
            podman stop "$n" > /dev/null
            podman rename "$n" "$n.before_restore_$stamp"
            result before "container $n.before_restore_$stamp"
            event INFO "Set $n aside (it did not belong to $group) as $n.before_restore_$stamp"
        done
    }

    extract() {
        local dest=$i_restore t0 t1 every
        local -a ms=() tar_cmd
        if [[ $i_type == volume ]]; then
            dest=$(mount_dir "$i_origin")
        fi
        if [[ -n $i_members ]]; then IFS=, read -ra ms <<< "$i_members"; fi
        every=$(( i_bytes / 10240 / 200 + 1 ))
        event EXTRACTING "$i_bytes" "$i_type" "$i_origin"
        now t0
        # podman unshare = write as "root of the containers": the owners
        # (MySQL, Postgres...) stay as they were
        tar_cmd=(podman unshare tar --numeric-owner -xpf - -C "$dest" --checkpoint="$every"
                 --checkpoint-action='echo=@@PROG %{}T' "${ms[@]}")
        zstd -dc -- "$files/$i_file" | "${tar_cmd[@]}"
        now t1
        event EXTRACTED $(( t1 - t0 ))
    }

    # Puts back, in reverse order, everything set_aside() moved or created. It only touches the
    # paths and volumes of the items (already validated on this side). Returns 1 if something could not be done.
    undo_done() {
        local i rc=0 mp_v mp_a erase
        for (( i = ${#h_type[@]} - 1; i >= 0; i-- )); do
            event REVERTING "${h_path[i]}"
            case ${h_type[i]} in
                volume|volume_moving)
                    # Halfway through setting aside, what is still in the volume is original: it is not deleted
                    erase=yes
                    if [[ ${h_type[i]} == volume_moving ]]; then erase=no; fi
                    mp_v=$(mount_dir "${h_path[i]}") &&
                    mp_a=$(mount_dir "${h_before[i]}") &&
                    podman unshare bash -ec 'shopt -s dotglob nullglob
                        if [[ $3 == yes ]]; then rm -rf -- "$1"/*; fi
                        for f in "$2"/*; do mv -n -- "$f" "$1"/; done
                        chown --reference="$2" -- "$1"; chmod --reference="$2" -- "$1"' _ "$mp_v" "$mp_a" "$erase" &&
                    podman volume rm "${h_before[i]}" > /dev/null
                    ;;
                new_volume) podman volume rm -f "${h_path[i]}" > /dev/null ;;
                path)          podman unshare rm -rf -- "${h_path[i]}" && podman unshare mv -T -- "${h_before[i]}" "${h_path[i]}" ;;
                new_path)    podman unshare rm -rf -- "${h_path[i]}" ;;
                empty_path)    podman unshare bash -ec 'shopt -s dotglob nullglob; rm -rf -- "$1"/*' _ "${h_path[i]}" ;;
                # The content comes back from ~/.before_restore and the folders left
                # empty there are removed (never going above ~/.before_restore)
                content|content_moving)
                    erase=yes
                    if [[ ${h_type[i]} == content_moving ]]; then erase=no; fi
                    podman unshare bash -ec 'shopt -s dotglob nullglob
                        if [[ $3 == yes ]]; then rm -rf -- "$1"/*; fi
                        for f in "$2"/*; do mv -n -- "$f" "$1"/; done
                        d=$2
                        while [[ $d == "$4"/* ]] && rmdir -- "$d" 2>/dev/null; do d=${d%/*}; done
                        [[ ! -e $2 ]]' _ "${h_path[i]}" "${h_before[i]}" "$erase" "$HOME/.before_restore"
                    ;;
                # They were set aside first: they come back last, with their data already back
                container|container_running)
                    if podman container exists "${h_before[i]}"; then
                        podman rename "${h_before[i]}" "${h_path[i]}"
                    fi &&
                    # Without channels 5, 6 and 9 (see control): the container would keep them open
                    if [[ ${h_type[i]} == container_running ]]; then
                        podman start "${h_path[i]}" > /dev/null 5>&- 6>&- 9>&-
                    fi
                    ;;
            esac || rc=1
        done
        return "$rc"
    }

    # Runs if restore() dies halfway (error, Ctrl+C): never leave half-written data
    undo() {
        trap - EXIT ERR
        set +e
        # What was there before is started with its same containers
        with_config=no
        event WARN "Something failed halfway; putting $group back the way it was"
        local rc=0
        undo_done || rc=1
        if [[ $was_running == yes ]] && ! bring_up; then rc=1; fi
        if (( rc != 0 )); then
            event CRITICAL "Could not leave $group the way it was${missing:+: $missing}. Check *.before_restore_$stamp by hand"
            exit 4
        fi
        event INFO "It failed, but everything was left the way it was"
        exit 2
    }

    # No "local": the emergency trap runs after the function returns
    was_running=no

    restore() {
        local item t_stopped t1
        exec 9> "$lock"
        if ! flock -n 9; then
            event ERROR "Another backup or restore is working with $group; not touching it"
            exit 1
        fi
        if foreign_compose; then
            event ERROR "$group is a compose that I did not recognize in the backup; not touching it"
            exit 1
        fi
        # Looked up again here (the earlier check is not trusted): it may have changed
        mapfile -t foreign_list < <(foreign)
        if (( ${#foreign_list[@]} > 0 )) && [[ $set_aside_foreign != yes ]]; then
            event ERROR "There are containers with the names of $group that do not belong to it; not touching anything"
            exit 1
        fi

        now t_stopped
        if [[ -n $(running) ]]; then
            was_running=yes
            trap undo EXIT
            stop_and_wait
            event STOPPED
        else
            event ALREADY_STOPPED
        fi

        trap undo EXIT
        set_aside_foreign
        for item in "${items[@]}"; do
            read_item "$item"
            if [[ $i_type == config ]]; then with_config=yes; fi
            set_aside
            extract
        done
        trap - EXIT

        if ! bring_up; then
            event CRITICAL "$group was restored but did NOT start${missing:+: $missing}. What was there before is still in *.before_restore_$stamp"
            exit 3
        fi
        now t1
        result stopped $(( t1 - t_stopped ))
        event STARTED $(( t1 - t_stopped ))
    }

    # Swaps what was restored for what was left in *.before_restore_<stamp> and starts it
    revert() {
        local item p n had_foreign=no
        local -a xs=()
        exec 9> "$lock"
        if ! flock -n 9; then
            event ERROR "Another backup or restore is working with $group; not touching it"
            exit 1
        fi
        if [[ -n $(running) ]]; then
            stop_and_wait
            # What came up halfway is not the right list: when reverting, all of them are checked
            expected=()
        fi
        # If containers that did not belong to it were set aside, they are what was there before:
        # they come back with their name (the restored ones holding it are removed) and the ones
        # that were running are started. They are recorded first so that they come back last.
        if [[ -n $names ]]; then IFS=, read -ra xs <<< "$names"; fi
        for n in "${xs[@]}"; do
            podman container exists "$n.before_restore_$stamp" || continue
            had_foreign=yes
            if [[ ",$started," == *",$n,"* ]]; then h_type+=(container_running); else h_type+=(container); fi
            h_path+=("$n") h_before+=("$n.before_restore_$stamp")
        done
        if [[ $had_foreign == yes ]]; then
            for n in "${xs[@]}"; do
                if podman container exists "$n"; then podman rm -f "$n" > /dev/null; fi
            done
        fi
        for item in "${items[@]}"; do
            read_item "$item"
            if [[ $i_type == config ]]; then with_config=yes; fi
            if [[ $i_type == volume ]]; then
                if podman volume exists "$i_origin.before_restore_$stamp"; then
                    h_type+=(volume) h_path+=("$i_origin") h_before+=("$i_origin.before_restore_$stamp")
                else
                    h_type+=(new_volume) h_path+=("$i_origin") h_before+=("")
                fi
                continue
            fi
            paths_item
            for p in "${paths[@]}"; do
                if [[ -e $p.before_restore_$stamp ]]; then
                    h_type+=(path) h_path+=("$p") h_before+=("$p.before_restore_$stamp")
                elif [[ -z $i_members && -d $(before_in_home "$p") ]]; then
                    h_type+=(content) h_path+=("$p") h_before+=("$(before_in_home "$p")")
                elif [[ -d $p ]] && ! can_write "$(dirname -- "$p")"; then
                    # It was the empty folder created with sudo: it is emptied, it cannot be removed
                    h_type+=(empty_path) h_path+=("$p") h_before+=("")
                else
                    h_type+=(new_path) h_path+=("$p") h_before+=("")
                fi
            done
        done
        if ! undo_done; then
            event CRITICAL "Could not put everything back. Check *.before_restore_$stamp by hand"
            exit 4
        fi
        if [[ $had_foreign == yes ]]; then
            sleep 3
            for n in ${started//,/ }; do
                if [[ $(podman inspect -f '{{.State.Running}}' "$n") != true ]]; then
                    event CRITICAL "Put back what was there before, but $n does not start that way either. Start it by hand"
                    exit 3
                fi
            done
            event INFO "Put back the containers that were there before restoring $group"
            return 0
        fi
        if ! bring_up; then
            event CRITICAL "Put back what was there before, but $group does not start that way either${missing:+: $missing}. Start it by hand"
            exit 3
        fi
        event INFO "Put $group back the way it was and it is running"
    }

    case $action in
        check)   check ;;
        restore) restore ;;
        revert)  revert ;;
        *) event ERROR "Unknown action: $action"; exit 1 ;;
    esac
}
main "$@"
EOF

# ---------- Prepare each service ----------

# Lists the parts of a service and leaves the chosen indexes in "parts" (Enter = all)
choose_parts() {
    local answer i
    # choose works on "services"
    local -a services=("${!m_type[@]}")
    printf '\n  %s%s%s\n' "$c_bold" "$1" "$c_end" >&3
    for i in "${!m_type[@]}"; do
        printf '    %d) %-8s %8s  %s\n' $(( i + 1 )) "${m_type[i]}" "$(hsize "${m_bytes[i]}")" "${m_origin[i]}" >&3
    done
    ask answer "  Which parts to restore? (Enter = all, e.g. 2): "
    if [[ -z $answer ]]; then
        parts=("${!m_type[@]}")
        return 0
    fi
    choose "$answer" || return 1
    parts=("${result[@]}")
    if (( ${#parts[@]} == 0 )); then parts=("${!m_type[@]}"); fi
}

# If the paths belong to another user (/home/old), asks once whether to move them to srv_home
ask_remap() {
    local i old answer
    for i in "${parts[@]}"; do
        [[ ${m_type[i]} != volume && ${m_origin[i]} =~ ^(/home/[^/]+)/ ]] || continue
        old=${BASH_REMATCH[1]}
        [[ $old != "$srv_home" && -z ${remaps[$old]:-} ]] || continue
        ask answer "  The paths belong to $old and here the user is $srv_home. Move them to $srv_home? [Y/n]: "
        case ${answer,,} in
            ""|y|yes) remaps[$old]=yes ;;
            *)        remaps[$old]=no ;;
        esac
    done
    for old in "${!remaps[@]}"; do
        if [[ ${remaps[$old]} == yes ]]; then remap_home "$old" "$srv_home"; fi
    done
    for i in "${parts[@]}"; do
        if [[ ${m_type[i]} != volume ]] && ! allowed_path "${m_origin[i]}"; then
            error "After changing the user, ${m_origin[i]} is not an allowed path"
            return 1
        fi
    done
}

# Reads, asks and leaves ready everything the server needs for one service (svc_*)
build_service() {
    local group=$1 d=$backup_dir/$1 i members item text="" total=0
    local -a parts
    read_manifest "$d" || return 1
    choose_parts "$group" || return 1
    ask_remap || return 1
    detect_service "$d" "$group" || return 1

    svc_items[$group]=""
    for i in "${parts[@]}"; do
        members=""
        if [[ $s_type == quadlet && ${m_type[i]} == config && ${m_origin[i]} == */containers/systemd ]]; then
            members=$s_members
        fi
        printf -v item '%s|%s|%s|%s|%s|%s' "${m_type[i]}" "${m_file[i]}" "${m_origin[i]}" \
            "${m_restore[i]}" "${m_bytes[i]}" "$members"
        svc_items[$group]+=${svc_items[$group]:+$'\n'}$item
        total=$(( total + m_bytes[i] ))
        text+="${text:+, }${m_type[i]} ${m_origin[i]##*/}"
    done
    if (( ${#parts[@]} == ${#m_type[@]} )); then text="all"; fi
    svc_type[$group]=$s_type svc_dir[$group]=$s_dir svc_unit[$group]=$s_unit
    svc_compose_f[$group]=$s_compose_f svc_image[$group]=$s_image
    # Backups without a recipe: a Quadlet or a standalone container is named like the service
    if [[ -z $s_names && $s_type != compose ]]; then s_names=$group; fi
    svc_names[$group]=$s_names svc_set_aside[$group]=no
    svc_parts[$group]=$text svc_bytes[$group]=$total
    svc_files[$group]=$d
    svc_stamp[$group]=$(date +%Y%m%d_%H%M%S)
}

# Asks the server what is there today and what will be overwritten. Returns 1 if it cannot be restored.
check_service() {
    local group=$1 key value t z r item block="" foreign_txt="" answer
    local -a it
    local -A overwrites=()
    if ! remote check "$group"; then
        error "Could not check $group on $dest"
        return 1
    fi

    printf '\n  %s%s%s (%s) · parts: %s\n' "$c_bold" "$group" "$c_end" "${svc_type[$group]}" "${svc_parts[$group]}" >&3
    while read -r key value; do
        case $key in
            running) svc_running[$group]=$value ;;
            exists)    svc_exists[$group]=$value ;;
            overwrite)
                read -r t z r <<< "$value"
                overwrites[$r]=1
                printf '    %s⚠ will be replaced:%s %-8s %s (%s)\n' "$c_yellow" "$c_end" "$t" "$r" "$(hsize "$z")" >&3
                ;;
            lacking)     block+="the program $value is missing; " ;;
            busy)        block+="another backup or restore is working with it; " ;;
            user) srv_user=$value ;;
            no_permission)
                read -r t r <<< "$value"
                case $t in
                    set_aside) perm_set_aside[$group]+=$r$'\n'; perm_create[$group]+=$r$'\n' ;;
                    create)   perm_create[$group]+=$r$'\n' ;;
                    chown)   perm_chown[$group]+=$r$'\n' ;;
                esac
                ;;
            foreign_compose) block+="on the server it is a compose, but I did not recognize its file in the backup (I would not know how to stop it); " ;;
            foreign)       foreign_txt+="        ${value%% *}  (${value#* })"$'\n' ;;
            in_home)
                printf '    %s  what was there before is kept in %s (the parent folder belongs to root and cannot be renamed)%s\n' \
                    "$c_dim" "$value" "$c_end" >&3
                ;;
            clash)       block+="${value#volume } already exists; " ;;
            no_space)
                read -r t z r <<< "$value"
                block+="it does not fit in $r: it needs $(hsize "$t"), there is $(hsize "$z"); "
                ;;
        esac
    done <<< "$remote_output"

    while IFS='|' read -ra it; do
        r=${it[2]}
        if [[ -n ${it[5]:-} ]]; then r="${it[3]}/${it[5]//,/ and }"; fi
        if [[ -z ${overwrites[$r]:-} ]]; then
            printf '    + will be created:  %-8s %s\n' "${it[0]}" "$r" >&3
        fi
    done <<< "${svc_items[$group]}"

    if [[ ${svc_running[$group]:-no} == yes ]]; then
        printf '    %sit is running: it is stopped while it is restored%s\n' "$c_dim" "$c_end" >&3
    fi
    if [[ ${svc_exists[$group]:-no} == no && ${svc_type[$group]} == standalone ]]; then
        warn "$group is a standalone container and no longer exists: its data is restored, but it has to be created by hand"
        if [[ -n ${svc_image[$group]:-} ]]; then
            warn "  It used the image ${svc_image[$group]}; its full recipe is in ${svc_files[$group]}/CONTAINERS.json"
        fi
    fi
    if [[ -n ${perm_create[$group]:-}${perm_chown[$group]:-} ]]; then
        pending+=("$group")
        block+="there are folders that can only be prepared with sudo (listed at the end); "
    fi
    # Its names are held by containers that do not belong to it: the decision is up to whoever
    # restores, seeing where they come from (if the wrong service was picked, this is where it shows)
    if [[ -n $foreign_txt ]]; then
        printf '    %s⚠ these containers have the names of %s, but do not belong to it:%s\n%s' \
            "$c_yellow" "$group" "$c_end" "$foreign_txt" >&3
        if [[ -z $block ]]; then
            ask answer "    Is it the same service? I will stop them and set them aside as *.before_restore_<date> [y/N]: "
            case ${answer,,} in
                y|yes) svc_set_aside[$group]=yes ;;
                *)     block+="its names are used by containers that do not belong to it (I did not touch them); " ;;
            esac
        fi
    fi
    if [[ -n $block ]]; then
        error "$group cannot be restored: ${block%; }"
        return 1
    fi
}

# ---------- Upload the backup to the server (SSH only) ----------

# Temporary folder on disk (not in RAM: /tmp is often tmpfs) to upload the files to
prepare_tmp() {
    local info key value rsync_srv=no
    info=$(on_server bash -s <<'TEMPORARY'
set -euo pipefail
for d in /var/tmp /tmp; do
    [[ $(findmnt -no FSTYPE -T "$d") != tmpfs ]] || continue
    t=$(mktemp -d "$d/.restore_XXXXXXXX")
    echo "tmp $t"
    echo "rsync $(command -v rsync > /dev/null && echo yes || echo no)"
    exit 0
done
echo "Neither /tmp nor /var/tmp is on disk (both are in RAM)" >&2
exit 1
TEMPORARY
) || return 1
    while read -r key value; do
        case $key in
            tmp)   remote_tmp=$value ;;
            rsync) rsync_srv=$value ;;
        esac
    done <<< "$info"
    # This folder is removed with rm -rf: make sure it is exactly what we expect
    if [[ ! $remote_tmp =~ ^/(var/)?tmp/\.restore_[A-Za-z0-9]{8}$ ]]; then
        remote_tmp=""
        error "Unexpected temporary folder on the server"
        return 1
    fi
    if [[ $rsync_srv == yes ]] && command -v rsync > /dev/null; then
        method=rsync
    else
        method=scp
        warn "rsync is not on both machines: using scp (slower and cannot resume)"
    fi
}

# Uploads only the files of the chosen parts (plus the manifest and the checksums)
# and verifies them again over there. Done while the service is still running.
upload() {
    local group=$1 d=$backup_dir/$1 item a size=0 free t0 t1 srv_dest
    local -a it files=(MANIFEST.tsv SHA256SUMS)
    while IFS='|' read -ra it; do files+=("${it[1]}"); done <<< "${svc_items[$group]}"
    for a in "${files[@]}"; do size=$(( size + $(stat -c %s -- "$d/$a") )); done

    srv_dest=$remote_tmp/$group
    free=$(on_server "mkdir -p -- $(printf '%q' "$srv_dest")/config $(printf '%q' "$srv_dest")/volumes && df -B1 --output=avail -- $(printf '%q' "$remote_tmp") | tail -n 1") || {
        error "$group: could not prepare the temporary folder on the server"
        return 1
    }
    free=${free//[[:space:]]/}
    if (( size > free )); then
        error "$group does not fit in ${remote_tmp%/*} on the server: it needs $(hsize "$size"), there is $(hsize "$free")"
        return 1
    fi

    message 3 "$c_dim" "↑" "Uploading $(hsize "$size") ($method)"
    now t0
    # Called inside an "if": set -e does not apply here, each step is checked by hand
    if [[ $method == rsync ]]; then
        if ! printf '%s\n' "${files[@]}" | rsync -rt --partial --files-from=- -e "ssh ${ssh_opts[*]}" -- "$d/" "$dest:$srv_dest/"; then
            error "$group: the upload failed"
            return 1
        fi
    else
        for a in "${files[@]}"; do
            if ! scp -q "${ssh_opts[@]}" -- "$d/$a" "$dest:$srv_dest/$a"; then
                error "$group: the upload of $a failed"
                return 1
            fi
        done
    fi
    # Exactly the uploaded ones are verified (if one were missing, sha256sum -c flags it)
    if ! awk 'NR == FNR { want[$0] = 1; next } want[$2]' <(printf '%s\n' "${files[@]}") "$d/SHA256SUMS" \
        | on_server "cd -- $(printf '%q' "$srv_dest") && sha256sum -c --quiet - >&2"; then
        error "$group: the files arrived damaged on the server"
        return 1
    fi
    now t1
    success "Uploaded and verified · $(hsize "$size") in $(duration $(( t1 - t0 ))) ($(speed "$size" $(( t1 - t0 ))))"
    svc_files[$group]=$srv_dest
}

delete_uploaded() {
    [[ $use_ssh == yes && -n $remote_tmp ]] || return 0
    on_server "rm -rf -- $(printf '%q' "$remote_tmp/$1")" \
        || warn "$1: could not delete its temporary copy on the server"
}

# Like a launcher asking for the missing pieces: which folders to prepare with sudo, per
# service, and which numbers to choose when running the script again
show_missing_permissions() {
    local g r n pick="" names="" me=${srv_user:-$USER} q line
    local -a create=() owner=() lines=()
    (( ${#pending[@]} > 0 )) || return 0
    for g in "${pending[@]}"; do
        lines+=("    $g")
        while IFS= read -r r; do
            [[ -n $r ]] || continue
            if [[ $'\n'${perm_set_aside[$g]:-} == *$'\n'"$r"$'\n'* ]]; then
                lines+=("        $r   (it has data and the parent folder belongs to root: it has to be set aside)")
            else
                lines+=("        $r   (it does not exist and the parent folder belongs to root: it has to be created)")
            fi
            q=$(printf '%q' "$r")
            create+=("$q") owner+=("$q")
        done <<< "${perm_create[$g]:-}"
        while IFS= read -r r; do
            [[ -n $r ]] || continue
            lines+=("        $r   (it exists but is not yours)")
            owner+=("$(printf '%q' "$r")")
        done <<< "${perm_chown[$g]:-}"
        for n in "${!services[@]}"; do
            if [[ ${services[n]} == "$g" ]]; then pick+="$(( n + 1 )) "; fi
        done
        names+="${names:+, }$g"
    done
    lines+=("" "  1. Prepare them (it asks for your password):")
    for g in "${pending[@]}"; do
        while IFS= read -r r; do
            [[ -n $r ]] || continue
            # It has data and the parent folder belongs to root: it is set aside by hand
            lines+=("        sudo mv $(printf '%q' "$r") $(printf '%q' "$r.before_restore_manual")")
        done <<< "${perm_set_aside[$g]:-}"
    done
    if (( ${#create[@]} > 0 )); then lines+=("        sudo mkdir -p ${create[*]}"); fi
    lines+=("        sudo chown $me: ${owner[*]}")
    lines+=("  2. Run the script again and choose: ${pick% }   ($names)")

    printf '\n%s⚠ These services could not be restored: there are folders that can only be prepared with sudo%s\n\n' \
        "$c_yellow" "$c_end" >&3
    printf '%s\n' "${lines[@]}" >&3
    raw ""
    raw "⚠ These services could not be restored: there are folders that can only be prepared with sudo"
    for line in "${lines[@]}"; do raw "$line"; done
}

# ---------- Restore ----------

# Server exit codes: 0 = restored and running, 1 = failed without touching anything,
# 2 = failed and was left the way it was, 3 = restored but did NOT start (what was there
# before is still set aside), 4 = failed and could not be left the way it was.
restore_service() {
    local group=$1 rc=0 key value t0 t1
    now t0
    if ! read_manifest "$backup_dir/$group" || ! verify_sums "$backup_dir/$group"; then
        r_state[$group]="damaged backup, not touched"
        failed+=("$group")
        return 0
    fi
    info "Backup verified"
    if [[ $use_ssh == yes ]] && ! upload "$group"; then
        r_state[$group]="upload failed, not touched"
        failed+=("$group")
        delete_uploaded "$group"
        return 0
    fi

    remote restore "$group" || rc=$?
    delete_uploaded "$group"
    while read -r key value; do
        case $key in
            before)   r_before[$group]+=$value$'\n' ;;
            stopped) r_stopped[$group]=$value ;;
            foreign_running) r_started[$group]+=${r_started[$group]:+,}$value ;;
        esac
    done <<< "$remote_output"
    now t1
    r_time[$group]=$(( t1 - t0 ))

    case $rc in
        0)
            r_state[$group]=OK
            success "$group restored and running"
            ;;
        2)
            r_state[$group]="failed, left the way it was"
            failed+=("$group")
            ;;
        3)
            r_state[$group]="restored, but did NOT START"
            ask_revert "$group"
            ;;
        4)
            r_state[$group]="failed and was NOT left the way it was"
            critical+=("$group")
            error "Do NOT delete the *.before_restore_${svc_stamp[$group]} of $group: they may be the only good thing left"
            ;;
        *)
            r_state[$group]="failed (code $rc)"
            failed+=("$group")
            error "$group failed (code $rc)"
            ;;
    esac
}

# What was restored does not start: offer to put back what was there before (which may also be the broken one)
ask_revert() {
    local group=$1 answer rc=0
    ask answer "Put $group back the way it was before restoring? [y/N]: "
    if [[ ${answer,,} != y && ${answer,,} != yes ]]; then
        critical+=("$group")
        raw ""
        raw "To put $group back by hand: stop it and swap each restored part for its *.before_restore_${svc_stamp[$group]}"
        return 0
    fi
    remote revert "$group" || rc=$?
    case $rc in
        0)
            r_state[$group]="did not start; put back the way it was"
            r_before[$group]=""
            failed+=("$group")
            ;;
        3)
            r_state[$group]="put back, but does NOT START"
            r_before[$group]=""
            critical+=("$group")
            ;;
        *)
            r_state[$group]="did not start and could not be put back"
            critical+=("$group")
            ;;
    esac
}

# What was set aside, with the command to delete it once everything has been checked to work
show_copies() {
    local group t r
    local -a lines=()
    for group in "${restorable[@]}"; do
        # After a rollback they no longer exist, and if the rollback failed they may be the only good thing left
        [[ ${r_state[$group]:-} == OK || ${r_state[$group]:-} == "restored, but did NOT START" ]] || continue
        while read -r t r; do
            [[ -n $r ]] || continue
            if [[ $t == volume ]]; then
                lines+=("podman volume rm $(printf '%q' "$r")")
            elif [[ $t == container ]]; then
                lines+=("podman rm $(printf '%q' "$r")")
            else
                lines+=("podman unshare rm -rf -- $(printf '%q' "$r")")
            fi
        done <<< "${r_before[$group]:-}"
    done
    (( ${#lines[@]} > 0 )) || return 0
    echo >&3
    info "What was there before was set aside. Once you have checked that everything works, delete it with:"
    printf '    %s\n' "${lines[@]}" >&3
    raw ""
    for t in "${lines[@]}"; do raw "  $t"; done
}

# ---------- Report ----------

write_header() {
    local group old
    raw "════════════════ Podman services restore ════════════════"
    raw "Started:         $(date '+%F %T')"
    raw "Local machine:   ${HOSTNAME:-?} ($(id -un))"
    if [[ $use_ssh == yes ]]; then
        raw "Server:          $dest, port $port"
    else
        raw "Server:          this machine"
    fi
    raw "Backup:          $backup_dir"
    for group in "${restorable[@]}"; do
        raw "Service:         $group (${svc_type[$group]}) · parts: ${svc_parts[$group]} · $(hsize "${svc_bytes[$group]}")"
    done
    for old in "${!remaps[@]}"; do
        raw "Path change:     $old → $srv_home (${remaps[$old]})"
    done
    if [[ $use_ssh == yes ]]; then raw "Transfer:        $method"; fi
}

show_summary() {
    local g row
    local -a rows=()
    printf -v row '%-22s %-22s %8s %9s %9s  %s' Service Parts Data Stopped Time State
    rows+=("$row")
    for g in "${restorable[@]}"; do
        printf -v row '%-22s %-22s %8s %9s %9s  %s' "$g" "${svc_parts[$g]:0:22}" \
            "$(hsize "${svc_bytes[$g]}")" \
            "$( [[ -n ${r_stopped[$g]:-} ]] && duration "${r_stopped[$g]}" || echo -)" \
            "$( [[ -n ${r_time[$g]:-} ]] && duration "${r_time[$g]}" || echo -)" \
            "${r_state[$g]:-not started}"
        rows+=("$row")
    done
    printf '\n%s%s%s\n' "$c_bold" "${rows[0]}" "$c_end" >&3
    printf '%s\n' "${rows[@]:1}" >&3
    raw ""
    raw "════════════════ Summary ════════════════"
    for row in "${rows[@]}"; do raw "$row"; done
}

# ---------- Cleanup ----------

on_exit() {
    local rc=$?
    if [[ -n $remote_tmp ]]; then
        on_server "rm -rf -- $(printf '%q' "$remote_tmp")" \
            || warn "Could not delete $remote_tmp on the server; delete it by hand"
    fi
    if [[ -n $log && $finished == no ]]; then
        raw ""
        to_log "The script ended early (code $rc)"
    fi
    if [[ -n $ctl_dir ]]; then
        ssh "${ssh_opts[@]}" -O exit "$dest" 2>/dev/null || true
        rm -rf -- "$ctl_dir"
    fi
    if [[ -n $capture_pid ]]; then
        exec 2>&4
        wait "$capture_pid" 2>/dev/null || true
    fi
}

# ---------- Main flow ----------

main_flow() {
    local answer path group confirm i n end
    local -a chosen ready=()
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then
        sed -n '2,/^set -euo pipefail$/{/^#/!d;s/^# \{0,1\}//;p}' -- "$0"
        exit 0
    fi
    if [[ $DRY_RUN != yes && $DRY_RUN != no ]]; then
        echo "DRY_RUN must be 'yes' or 'no'" >&2
        exit 1
    fi

    ask answer "Restore on another server (use SSH)? [Y/n]: "
    case ${answer,,} in
        ""|y|yes) use_ssh=yes ;;
        n|no)     use_ssh=no ;;
        *)
            echo "Answer y or n" >&2
            exit 1
            ;;
    esac

    trap on_exit EXIT
    trap 'exit 130' INT TERM

    if [[ $use_ssh == yes ]]; then
        ask dest "Enter the user and host as user@server: "
        if [[ -z $dest ]]; then
            echo "Nothing was entered" >&2
            exit 1
        # Nothing starting with "-": ssh would take it as an option (some run commands)
        elif [[ ! $dest =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; then
            echo "Wrong format (expected user@server)" >&2
            exit 1
        fi
        ask port "Press Enter for the default port [22] or type another one: "
        port=${port:-22}
        if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "The port must be a number between 1 and 65535" >&2
            exit 1
        fi
        # A single shared connection (the password is asked once)
        ctl_dir=$(mktemp -d)
        # shellcheck disable=SC2054
        ssh_opts=(-o Port="$port" -o LogLevel=ERROR
                  -o Ciphers=^aes128-gcm@openssh.com,chacha20-poly1305@openssh.com
                  -o ControlMaster=auto -o "ControlPath=$ctl_dir/%C" -o ControlPersist=10m)
        if ! ssh "${ssh_opts[@]}" "$dest" true; then
            echo "Connection failed" >&2
            exit 1
        fi
        echo "Connection OK"
    else
        dest="this machine"
        ssh_opts=()
    fi
    # The server's $HOME, not the one here
    # shellcheck disable=SC2016
    srv_home=$(on_server 'printf "%s" "$HOME"')

    ask path "Where is the backup? (e.g. /media/disk/backups): "
    if [[ -z $path ]]; then
        echo "No folder was given" >&2
        exit 1
    fi
    path=$(realpath -m -- "${path/#\~/$HOME}")
    load_backup "$path" || exit 1

    echo
    echo "Backup: $backup_dir"
    for i in "${!services[@]}"; do
        printf '  %2d) %-20s %s%s%s\n' $(( i + 1 )) "${services[i]}" "$c_dim" \
            "$(du -sh -- "$backup_dir/${services[i]}" | cut -f1)" "$c_end"
    done
    echo
    ask answer "Services to restore (e.g. 1 2 or 'all'): "
    choose "$answer" || exit 1
    chosen=("${result[@]}")
    if (( ${#chosen[@]} == 0 )); then
        echo "No service was chosen" >&2
        exit 1
    fi

    for group in "${chosen[@]}"; do
        if build_service "$group"; then
            ready+=("$group")
        else
            warn "Skipping $group"
        fi
    done

    echo
    echo "Checking on $dest..."
    restorable=()
    for group in "${ready[@]}"; do
        if check_service "$group"; then restorable+=("$group"); fi
    done
    show_missing_permissions
    echo
    if (( ${#restorable[@]} == 0 )); then
        error "No service is left that can be restored"
        exit 1
    fi

    if [[ $DRY_RUN == yes ]]; then
        info "Dry run: this is what it would do (nothing was touched)"
        for group in "${restorable[@]}"; do
            info "  $group: stop it if it is running, rename what is marked with ⚠ (also the containers that do not belong to it) to *.before_restore_${svc_stamp[$group]}, extract ${svc_parts[$group]} ($(hsize "${svc_bytes[$group]}")) and start it"
        done
        exit 0
    fi

    echo "These will be restored: ${restorable[*]}"
    echo "What is marked with ⚠ is not deleted: it is set aside (*.before_restore_<date> or ~/.before_restore)."
    ask confirm "To continue type 'restore': "
    if [[ $confirm != restore ]]; then
        echo "Cancelled."
        exit 0
    fi

    # The backup may be on a read-only USB drive: then the log goes to the home folder
    if [[ -w $backup_dir ]]; then log=$backup_dir/restore_$(date +%F_%H%M%S).log
    else log=$HOME/restore_$(date +%F_%H%M%S).log
    fi
    : > "$log"
    exec 2> >(capture_stderr)
    capture_pid=$!
    now t_start
    if [[ $use_ssh == yes ]]; then prepare_tmp || exit 1; fi
    write_header

    n=0
    for group in "${restorable[@]}"; do
        if [[ $cancelled == yes ]]; then
            r_state[$group]="cancelled, not touched"
            failed+=("$group")
            continue
        fi
        n=$(( n + 1 ))
        title "[$n/${#restorable[@]}] $group"
        restore_service "$group"
    done

    now end
    finished=yes
    show_summary
    show_copies
    show_missing_permissions
    raw ""
    info "Total time: $(duration $(( end - t_start )))"
    info "Details: $log"
    if (( ${#critical[@]} > 0 )); then
        error "ATTENTION: restored but did NOT start: ${critical[*]}"
    fi
    if (( ${#failed[@]} > 0 )); then
        error "Finished with errors in: ${failed[*]}"
    fi
    if (( ${#critical[@]} + ${#failed[@]} > 0 )); then
        exit 1
    fi
    success "All done"
}

# When sourced (tests) only the functions are loaded
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main_flow "$@"
fi
