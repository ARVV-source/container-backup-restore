#!/usr/bin/env bash
# Backs up Podman services (compose, Quadlet or standalone containers): config and data.
# It is interactive: it asks where the containers are (this machine or a server over
# SSH), which services to back up and which folder to store the backup in.
#   ZSTD_LEVEL=1..19            compression level (1 = fastest)
#   COMPRESSION=while_copying   compress while copying (less disk, one pass less)
#   COMPRESSION=afterwards      copy uncompressed and compress once the service is back up
#                               (better if the server has a slow CPU)
#   KEEP_LAST=3                 backups kept for each service; at the end it asks
#                               (never deletes on its own) about the older ones
#   -h, --help                  show this help
set -euo pipefail
umask 077
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '2,/^set -euo pipefail$/{/^#/!d;s/^# \{0,1\}//;p}' -- "$0"
    exit 0
fi

readonly ZSTD_LEVEL=${ZSTD_LEVEL:-1}
readonly COMPRESSION=${COMPRESSION:-while_copying}
readonly KEEP_LAST=${KEEP_LAST:-3}
if [[ ! $KEEP_LAST =~ ^[1-9][0-9]{0,2}$ ]]; then
    echo "KEEP_LAST must be a number, 1 or higher (got '$KEEP_LAST')" >&2
    exit 1
fi

remote_tmp="" ctl_dir="" state_dir="" log="" capture_pid="" finished=no
t_start=0 t_end=0
download_pid="" download_group=""
declare -A inventory_cache=() r_state=() r_original=() r_compressed=() r_stopped=() \
           r_download=() r_start=() r_time=()
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

# ---------- Output: the terminal gets a summary, backup.log gets the details ----------

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

# Anything that leaks to stderr (ssh, podman, sha256sum...) is shown and kept in the log
capture_stderr() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' "$erase" "$line" >&4
        printf '%(%T)T  [stderr] %s\n' -1 "$line" >> "$log"
    done
}

# Turns the events sent by the server ("@@TYPE<tab>data...") into terminal and log output
route() {
    local line ev a b c d total=0 label="" count=0 vel
    while IFS= read -r line; do
        if [[ $line == *'@@PROG '* ]]; then
            a=${line#*@@PROG }
            vel=${a##*, }
            bar "${a%% *}" "$total" "$label  ${vel%)}"
            continue
        elif [[ $line != @@* ]]; then
            detail "server: $line"
            continue
        fi
        IFS=$'\t' read -r ev a b c d <<< "${line#@@}"
        case $ev in
            INFO)  info "$a" ;;
            DET)   detail "  $a" ;;
            WARN) warn "$a" ;;
            ERROR) error "$a" ;;
            CRITICAL) error "$a" ;;
            ITEM)
                count=$(( count + 1 ))
                detail "$(printf '%-7s %7s  %s  →  %s' "$b" "$(hsize "$a")" "$d" "$c")"
                ;;
            SPACE)
                info "$(hsize "$a") to copy in $count items · free on the server: $(hsize "$b")"
                detail "Needs $(hsize "$c") free in $d (compression: $COMPRESSION)"
                if (( c > b )); then
                    error "Not enough space: $(hsize "$c") needed in $d. The service was not touched"
                fi
                ;;
            STOPPED)
                message 3 "$c_yellow" "■" "Stopped; copying..."
                ;;
            ALREADY_STOPPED)
                message 3 "$c_yellow" "■" "It was already stopped: it is backed up and left stopped"
                ;;
            COPYING)
                total=$a label="$b $c"
                if [[ $tty == yes ]]; then detail "Copying $b $c ($(hsize "$a"))"
                else info "Copying $b $c ($(hsize "$a"))"
                fi
                ;;
            COPIED)
                clear_line
                detail "  copied in $(duration "$a") ($(speed "$total" "$a"))"
                ;;
            STARTED)
                message 3 "$c_green" "▶" "Started again · it was down for $(duration "$a")"
                ;;
            COMPRESSING) info "Compressing with zstd -$ZSTD_LEVEL..." ;;
            COMPRESSED)
                detail "$(printf '%-45s %7s → %7s (%d%%)' "$a" "$(hsize "$b")" "$(hsize "$c")" $(( b > 0 ? c * 100 / b : 0 )))"
                ;;
            READY)
                info "Ready on the server: $(hsize "$a") → $(hsize "$b") ($(( a > 0 ? b * 100 / a : 0 ))% of the original)"
                ;;
            *) detail "server: $line" ;;
        esac
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

fetch() {
    case $method in
        rsync) rsync -rt --partial -e "ssh ${ssh_opts[*]}" "$dest:$1" "$2" ;;
        scp)   scp -r -q "${ssh_opts[@]}" "$dest:$1" "$2" ;;
        local) mv -- "$1" "$2" ;;
    esac
}

inventory() {
    local group=$1
    local inventory b key value
    local binds=()

    if [[ ! $group =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        error "Suspicious service name: $group"
        exit 1
    fi

    if [[ -n ${inventory_cache[$group]:-} ]]; then
        inventory=${inventory_cache[$group]}
    else
        inventory=$(on_server bash -s -- "$group" <<'EOF'
set -euo pipefail
group=$1
conts=$(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}')

if [[ -n $conts ]]; then
    echo "type compose"
    mapfile -t cont_list <<< "$conts"
    podman inspect "${cont_list[0]}" --format 'dir {{index .Config.Labels "com.docker.compose.project.working_dir"}}'
    podman inspect "${cont_list[0]}" --format 'files {{index .Config.Labels "com.docker.compose.project.config_files"}}'
else
    echo "type standalone"
    cont_list=("$group")
    unit=$(podman inspect "$group" --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}')
    if [[ -n $unit ]] && systemctl --user cat "$unit" &>/dev/null; then
        echo "unit $unit"
        echo "source $(systemctl --user show -p SourcePath --value "$unit")"
    fi
fi

podman inspect "${cont_list[@]}" \
    --format '{{range .Mounts}}{{if eq .Type "volume"}}volume {{.Name}}{{else}}bind {{.Source}}{{end}}{{println}}{{end}}' \
    | sed '/^$/d' | sort -u
EOF
) || return 1
        inventory_cache[$group]=$inventory
    fi

    type="" dir="" files="" unit="" source=""
    volumes=() binds_to_copy=() skipped=()

    while read -r key value; do
        case $key in
            type)     type=$value ;;
            dir)      dir=$value ;;
            files) files=$value ;;
            unit)   unit=$value ;;
            source)   source=$value ;;
            volume)   volumes+=("$value") ;;
            bind)     binds+=("$value") ;;
        esac
    done <<< "$inventory"

    # Standalone with a real systemd unit = Quadlet: it is stopped with systemctl, not podman
    if [[ $type == standalone && -n $unit ]]; then
        type=quadlet
    fi

    for b in "${binds[@]}"; do
        if [[ -n $dir && ( $b == "$dir" || $b == "$dir"/* ) ]]; then
            skipped+=("$b (already inside the config folder)")
            continue
        fi
        case $b in
            /etc/*|/usr/*|/dev/*|/proc/*|/sys/*|/run/*|/var/run/*) skipped+=("$b (system path)") ;;
            *) binds_to_copy+=("$b") ;;
        esac
    done
}

log_inventory() {
    detail "Type: $type"
    if [[ -n $dir ]]; then detail "Compose folder: $dir"; fi
    if [[ -n $files ]]; then detail "Compose files: $files"; fi
    if [[ -n $unit ]]; then detail "systemd unit: $unit ($source)"; fi
    local o
    for o in "${skipped[@]}"; do detail "Not backed up: $o"; done
}

# Turns "1 3 5", "1,3" or "all" into service names, without repeats.
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

# Runs $REMOTE on the server for the service whose inventory is loaded.
# Leaves what it returns in "remote_output".
remote() {
    local action=$1 group=$2 rc=0 args v b
    local params=("$action" "$group" "$type" "$dir" "$files" "$unit" "$source"
                  "$remote_tmp" "$ZSTD_LEVEL" "$COMPRESSION")
    for v in "${volumes[@]}"; do params+=("v:$v"); done
    for b in "${binds_to_copy[@]}"; do params+=("b:$b"); done
    # ssh joins everything into one string that the server parses again; %q makes
    # every value arrive whole and nothing gets executed.
    printf -v args '%q ' "${params[@]}"
    # $( ) waits for route to finish (it inherits its output), so no message
    # arrives late or gets mixed with what comes next.
    remote_output=$(on_server "bash -s -- $args" <<< "$REMOTE" 2> >(route)) || rc=$?
    return "$rc"
}

# ---------- Phases of each service ----------

# Stops, copies, starts and compresses on the server. Server exit codes:
# 3 = backup is fine but it did NOT start again, 4 = it failed and did NOT start again,
# 5 = it does not fit on the server (nothing was touched).
phase_server() {
    local group=$1 rc=0 key value

    if ! inventory "$group"; then
        error "Could not check $group on the server"
        return 1
    fi
    if [[ -z $type ]]; then
        error "Could not tell what type of service $group is"
        return 1
    fi
    if [[ $type == compose && -z $dir ]]; then
        error "$group is compose but Podman does not say which folder it lives in; not touching it"
        return 1
    fi
    log_inventory
    info "$type · volumes: ${#volumes[@]} · binds: ${#binds_to_copy[@]}"

    remote backup "$group" || rc=$?
    while read -r key value; do
        case $key in
            original)   r_original[$group]=$value ;;
            compressed) r_compressed[$group]=$value ;;
            stopped)    r_stopped[$group]=$value ;;
            download)   r_download[$group]=$value ;;
        esac
    done <<< "$remote_output"
    return "$rc"
}

# Runs in the background while the server works on the next service
download() {
    local group=$1 size=$2 t0 t1 free
    now t0

    if [[ $method != local ]]; then
        free=$(df -B1 --output=avail -- "$folder" | tail -n 1)
        free=${free//[[:space:]]/}
        if (( size > free )); then
            error "$group does not fit in $folder: it needs $(hsize "$size"), there is $(hsize "$free")"
            return 1
        fi
        message 3 "$c_dim" "↓" "$group: downloading $(hsize "$size") in the background ($method)"
    fi

    if ! fetch "$remote_tmp/$group" "$folder/"; then
        error "$group: the download failed"
        return 1
    fi

    if [[ $method != local ]]; then
        now t1
        detail "$group: downloaded in $(duration $(( t1 - t0 ))) ($(speed "$size" $(( t1 - t0 ))))"
        if ! (cd -- "$folder/$group" && sha256sum -c --quiet SHA256SUMS >&2); then
            error "$group: the files arrived damaged"
            return 1
        fi
        on_server "rm -rf -- $(printf '%q' "$remote_tmp/$group")" \
            || warn "$group: could not delete its temporary copy on the server"
    fi

    now t1
    echo "$t1" > "$state_dir/$group"
    if [[ $method == local ]]; then
        success "$group saved · $(hsize "$size")"
    else
        success "$group saved and verified · $(hsize "$size") in $(duration $(( t1 - t0 ))) ($(speed "$size" $(( t1 - t0 ))))"
    fi
}

wait_download() {
    [[ -n $download_pid ]] || return 0
    local g=$download_group rc=0 current end

    if [[ $tty == yes && $method != local ]]; then
        while kill -0 "$download_pid" 2>/dev/null; do
            current=$(du -sb -- "$folder/$g" 2>/dev/null | cut -f1) || current=0
            bar "${current:-0}" "${r_download[$g]:-0}" "downloading $g"
            sleep 0.5
        done
        clear_line
    fi
    wait "$download_pid" || rc=$?
    download_pid="" download_group=""

    if [[ -s $state_dir/$g ]]; then end=$(< "$state_dir/$g"); else now end; fi
    r_time[$g]=$(( end - r_start[$g] ))
    if (( rc != 0 )); then
        r_state[$g]="download failed"
        failed+=("$g")
    elif [[ " ${critical[*]} " == *" $g "* ]]; then
        r_state[$g]="saved, but LEFT STOPPED"
    else
        r_state[$g]="OK"
    fi
}

backup() {
    local group=$1 rc=0 end
    now end
    r_start[$group]=$end

    phase_server "$group" || rc=$?
    if (( rc == 5 )) && [[ -n $download_pid ]]; then
        info "Waiting for the download of $download_group to finish to free up space, then retrying"
        wait_download
        rc=0
        phase_server "$group" || rc=$?
    fi

    case $rc in
        0|3)
            if (( rc == 3 )); then critical+=("$group"); fi
            r_state[$group]="downloading"
            wait_download
            download "$group" "${r_download[$group]:-0}" &
            download_pid=$! download_group=$group
            return 0
            ;;
        4)
            critical+=("$group")
            r_state[$group]="failed and LEFT STOPPED"
            ;;
        5)  r_state[$group]="no space on the server" ;;
        *)
            r_state[$group]="failed on the server"
            error "$group failed (code $rc); the details are in backup.log"
            ;;
    esac
    failed+=("$group")
    now end
    r_time[$group]=$(( end - r_start[$group] ))
}

# ---------- Final report ----------

write_header() {
    local local_free
    local_free=$(df -B1 --output=avail -- "$folder" | tail -n 1)
    raw "════════════════ Podman services backup ════════════════"
    raw "Started:             $(date '+%F %T')"
    raw "Local machine:       ${HOSTNAME:-?} ($(id -un))"
    if [[ $use_ssh == yes ]]; then
        raw "Server:              $dest, port $port (name: $srv_host)"
    else
        raw "Server:              this machine"
    fi
    raw "Podman / kernel:     $srv_podman / $srv_kernel"
    raw "Temporary folder:    $remote_tmp ($srv_fs, free $(hsize "$srv_free"))"
    raw "Destination:         $folder (free $(hsize "${local_free//[[:space:]]/}"))"
    if [[ $COMPRESSION == while_copying ]]; then
        raw "Compression:         zstd -$ZSTD_LEVEL, while copying (with the service stopped)"
    else
        raw "Compression:         zstd -$ZSTD_LEVEL, after starting the service again"
    fi
    raw "Transfer:            $method"
    raw "Services:            ${chosen[*]}"
    raw "Restart at the end:  ${restart_at_end[*]:-none}"
}

show_summary() {
    local g row
    local -a rows=()

    printf -v row '%-22s %8s %9s %9s %9s  %s' Service Data Backup Stopped Time State
    rows+=("$row")
    for g in "${chosen[@]}"; do
        printf -v row '%-22s %8s %9s %9s %9s  %s' "$g" \
            "$( [[ -n ${r_original[$g]:-} ]] && hsize "${r_original[$g]}" || echo -)" \
            "$( [[ -n ${r_compressed[$g]:-} ]] && hsize "${r_compressed[$g]}" || echo -)" \
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

write_restore_howto() {
    local g manifest file type_e origin restore
    raw ""
    raw "════════════════ How to restore ════════════════"
    raw "Copy the service folder to the server, cd into it and, with the service stopped,"
    raw "run the commands for each file. 'podman unshare' gives back the original owners."
    raw "(Or the easy way: VolumeRestore.sh does all of this, with a safety net.)"
    for g in "${chosen[@]}"; do
        manifest=$folder/$g/MANIFEST.tsv
        [[ -f $manifest ]] || continue
        raw ""
        raw "[$g]"
        raw "  sha256sum -c SHA256SUMS"
        while IFS=$'\t' read -r file type_e origin restore _; do
            if [[ $type_e == volume ]]; then
                raw "  podman volume create $origin   # if it no longer exists"
                raw "  zstd -dc $file | podman volume import $origin -"
            else
                raw "  zstd -dc $(printf '%q' "$file") | podman unshare tar -xf - -C $(printf '%q' "$restore")   # recreates $origin"
            fi
        done < <(tail -n +2 -- "$manifest")
    done
}

# ---------- Old backups ----------

# Decided PER SERVICE, not by date: each service keeps its KEEP_LAST newest copies
# (counting today's), however old they are. A folder is offered for deletion only if
# it is not among the kept ones of any service it holds, or if it failed halfway
# (without complete services it cannot be restored). Nothing is ever deleted without
# typing "delete".
offer_delete_old() {
    local d s t answer list
    local -a folders=() old=() servs
    local -A contains=() keep=() copies=()
    for d in "$path"/backup_*; do
        [[ -d $d && ! -L $d && ${d##*/} =~ ^backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]] || continue
        # The name carries date and time: reversed, the newest comes first
        folders=("$d" "${folders[@]}")
        list=""
        # Only a complete service counts (with manifest and checksums)
        for s in "$d"/*/; do
            s=${s%/}
            if [[ -f $s/MANIFEST.tsv && -f $s/SHA256SUMS ]]; then list+=" ${s##*/}"; fi
        done
        contains[$d]=$list
    done

    for d in "${folders[@]}"; do
        read -ra servs <<< "${contains[$d]}"
        for s in "${servs[@]}"; do
            copies[$s]=$(( ${copies[$s]:-0} + 1 ))
            if (( copies[$s] <= KEEP_LAST )); then keep[$d]=1; fi
        done
    done
    for d in "${folders[@]}"; do
        if [[ $d == "$folder" || -n ${keep[$d]:-} ]]; then continue; fi
        old+=("$d")
    done
    (( ${#old[@]} > 0 )) || return 0

    echo >&3
    info "There are ${#old[@]} old backups in $path that are no longer needed"
    info "(each service keeps its $KEEP_LAST newest backups):"
    for d in "${old[@]}"; do
        list=${contains[$d]# }
        list=${list// /, }
        printf -v t '    %6s  %s  (%s)' "$(du -sh -- "$d" | cut -f1)" "${d##*/}" "${list:-no complete services}"
        printf '%s\n' "$t" >&3
        raw "$t"
    done
    # Whatever was typed while the backup was running does not count as an answer
    if [[ -t 0 ]]; then
        while read -r -t 0 _; do read -r _ || break; done
    fi
    # 2>&4: stderr goes to the log line by line and the question would not be seen
    read -rp "To delete them type 'delete' (Enter = delete nothing): " answer 2>&4 || answer=""
    detail "Answer: '$answer'"
    if [[ $answer != delete ]]; then
        info "Nothing was deleted"
        return 0
    fi
    for d in "${old[@]}"; do
        if rm -rf -- "$d"; then
            detail "Deleted: $d"
        else
            warn "Could not delete $d"
        fi
    done
    success "Old backups deleted"
}

# ---------- Cleanup ----------

clean_remote() {
    [[ -n $remote_tmp ]] || return 0
    on_server "rm -rf -- $(printf '%q' "$remote_tmp")" \
        || warn "Could not delete $remote_tmp on the server; delete it by hand"
}

on_exit() {
    local rc=$?
    if [[ -n $download_pid ]] && kill -0 "$download_pid" 2>/dev/null; then
        pkill -TERM -P "$download_pid" 2>/dev/null || true
        kill "$download_pid" 2>/dev/null || true
        wait "$download_pid" 2>/dev/null || true
        warn "Download of $download_group interrupted; whatever is in $folder/$download_group is incomplete"
    fi
    clean_remote
    if [[ -n $ctl_dir ]]; then
        ssh "${ssh_opts[@]}" -O exit "$dest" 2>/dev/null || true
        rm -rf -- "$ctl_dir"
    fi
    if [[ -n $state_dir ]]; then rm -rf -- "$state_dir"; fi
    if [[ -n $log && $finished == no ]]; then
        raw ""
        to_log "The script ended early (code $rc)"
    fi
    if [[ -n $capture_pid ]]; then
        exec 2>&4
        wait "$capture_pid" 2>/dev/null || true
    fi
}

# ---------- Script that runs on the server ----------

# It lives inside main() so bash reads all of it before starting: if the connection
# drops halfway, no half-read script is left running with the service stopped.
# It talks to this side through events on stderr ("@@TYPE<tab>data") and returns
# results on stdout.
read -r -d '' REMOTE <<'EOF' || true
main() {
    set -Eeuo pipefail
    # If the connection drops, do not die in the middle of a copy. On Ctrl+C or TERM,
    # exit the normal way so the trap starts the service again.
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

    # No "local": the emergency trap runs AFTER main returns
    action=$1 group=$2 type=$3 dir=$4 files=$5 unit=$6 source=$7 tmp=$8
    local level=$9 mode=${10}
    shift 10
    local items=("$@")

    event()    { local IFS=$'\t'; printf '@@%s\n' "$*" >&6 || true; }
    result() { printf '%s %s\n' "$1" "$2" >&5 || true; }
    now()     { local us=${EPOCHREALTIME:-}; us=${us/[.,]/}; [[ -n $us ]] || us=$(date +%s%6N); printf -v "$1" '%d' $(( us / 1000 )); }
    trap 'event ERROR "«$BASH_COMMAND» failed (code $?)"' ERR

    compose_args=(-p "$group")
    local f file_list=()
    if [[ -n $files ]]; then
        IFS=, read -ra file_list <<< "$files"
        for f in "${file_list[@]}"; do compose_args+=(-f "$f"); done
    fi

    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/backup-podman-$group.lock"
    if ! flock -n 9; then
        event ERROR "Another backup is working with $group right now; not touching it"
        exit 1
    fi

    running() {
        if [[ $type == compose ]]; then
            podman ps --filter "label=com.docker.compose.project=$group" --format '{{.Names}}'
        else
            podman ps --filter "name=^${group//./\\.}\$" --format '{{.Names}}'
        fi
    }

    # Whatever is started here must not inherit the lock or the ssh channels
    # (5, 6, 9): it would keep them open for as long as the container lives.
    control() {
        case $type in
            compose) (cd -- "$dir" && podman-compose "${compose_args[@]}" "$1") ;;
            quadlet) systemctl --user "$1" "$unit" ;;
            standalone)  podman "$1" "$group" ;;
            *)       echo "unknown service type '$type'"; return 1 ;;
        esac 5>&- 6>&- 9>&- 2>&1 | sed -u $'s/^/@@DET\t/' >&2
    }

    # The containers that were running: those are the ones that must come back up.
    # One that was already stopped (a one-shot job) does not count. No "local", because of the trap.
    expected=() missing=""
    take_expected() {
        local list
        list=$(running)
        if [[ -n $list ]]; then mapfile -t expected <<< "$list"; fi
    }

    state_of() { podman container inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo absent; }

    not_started() {
        local c e
        for c in "${expected[@]}"; do
            e=$(state_of "$c")
            if [[ $e != running ]]; then printf '%s (%s) ' "$c" "$e"; fi
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

    # The answer from start is not trusted: the state of each container is checked.
    # The sleep is because one that crashes on startup shows up as "running" for a moment.
    all_started() {
        if (( ${#expected[@]} == 0 )); then
            missing="no containers"
            return 1
        fi
        sleep 3
        wait_state not_started 20
    }

    bring_up() {
        control "$1" || event WARN "The $1 command returned an error; checking each container"
    }

    emergency_start() {
        trap - EXIT
        event WARN "Something failed; starting $group again"
        bring_up start
        if ! all_started; then
            event CRITICAL "$group did NOT come back up: $missing. Start it by hand."
            exit 4
        fi
        event INFO "Started again"
    }

    # /opt/mysql_data -> opt_mysql_data_1a2b3c4d; the suffix keeps /a_b/c and
    # /a/b_c from ending up in the same file.
    name_for() {
        local n=${1#/}
        n=${n//\//_}
        printf '%s_%s' "$n" "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
    }

    if [[ $action == restart ]]; then
        event INFO "Restarting $group"
        take_expected
        # If it was stopped, restart starts it: all of its containers are checked
        if (( ${#expected[@]} == 0 )); then
            if [[ $type == compose ]]; then
                mapfile -t expected < <(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}')
            else
                expected=("$group")
            fi
        fi
        bring_up restart
        if ! all_started; then
            event CRITICAL "$group did NOT come back up after the restart: $missing. Start it by hand."
            exit 4
        fi
        return
    fi

    local base=$tmp/$group i
    local -a e_type=() e_origin=() e_file=() e_dir=() e_obj=() e_size=()
    local -A used=()

    # Item to back up: type, origin, file, folder for tar -C, what to pack
    add() {
        if [[ -n ${used[$3]:-} ]]; then
            event ERROR "$2 and ${used[$3]} would end up in the same file $3; not stopping anything"
            exit 1
        fi
        used[$3]=$2
        e_type+=("$1") e_origin+=("$2") e_file+=("$3") e_dir+=("$4") e_obj+=("$5")
    }
    add_path() {
        add "$1" "$2" "$3" "$(dirname -- "$2")" "$(basename -- "$2")"
    }

    if [[ $type == compose ]]; then
        add_path config "$dir" "config/$(basename -- "$dir").tar.zst"
        for f in "${file_list[@]}"; do
            if [[ $f == /* && $f != "$dir"/* ]]; then
                add_path config "$f" "config/$(name_for "$f").tar.zst"
            fi
        done
    elif [[ -n $source ]]; then
        f=$(dirname -- "$source")
        add_path config "$f" "config/$(name_for "$f").tar.zst"
    fi

    local item path mountpoint
    for item in "${items[@]}"; do
        path=${item#*:}
        case $item in
            v:*)
                mountpoint=$(podman volume inspect "$path" --format '{{.Mountpoint}}')
                add volume "$path" "volumes/$path.tar.zst" "$mountpoint" .
                ;;
            b:*) add_path bind "$path" "volumes/bind_$(name_for "$path").tar.zst" ;;
        esac
    done

    if (( ${#e_type[@]} == 0 )); then
        event ERROR "It has no config, volumes or binds to back up; not stopping it"
        exit 1
    fi

    # Measure BEFORE stopping: if it does not fit, the service is not even touched
    local paths=() output line total=0 free needed
    for i in "${!e_type[@]}"; do paths+=("${e_dir[i]}/${e_obj[i]}"); done
    output=$(podman unshare bash -ec 'for p; do du -sb -- "$p"; done' _ "${paths[@]}")
    while IFS= read -r line; do e_size+=("${line%%[[:space:]]*}"); done <<< "$output"
    for i in "${!e_type[@]}"; do
        total=$(( total + e_size[i] ))
        event ITEM "${e_size[i]}" "${e_type[i]}" "${e_file[i]}" "${e_origin[i]}"
    done

    free=$(df -B1 --output=avail -- "$tmp" | tail -n 1)
    free=${free//[[:space:]]/}
    if [[ $mode == while_copying ]]; then
        needed=$(( total + total / 10 ))
    else
        needed=$(( total * 2 ))
    fi
    event SPACE "$total" "$free" "$needed" "$tmp"
    if (( needed > free )); then
        exit 5
    fi

    mkdir -p "$base/config" "$base/volumes"

    # Service info file and the "recipe" of its containers: this way the restore does not
    # have to guess the type, and a standalone container can be rebuilt.
    # It goes BEFORE stopping (a Quadlet removes its container when it stops) and is
    # best effort: if something fails there is a warning, but the backup never aborts.
    local compose_f="" outside="" conts_list=""
    local -a conts=()
    for f in "${file_list[@]}"; do
        f=${f#"$dir"/}
        f=${f#./}
        if [[ -n $f && $f != */* ]]; then compose_f+=${compose_f:+,}$f; else outside+=" $f"; fi
    done
    # With -f only the named files are loaded: an incomplete list is worse than none
    if [[ -n $outside ]]; then
        event WARN "The compose uses files outside its folder ($outside); on restore it is brought up with the default ones"
        compose_f=""
    fi
    printf 'key\tvalue\ntype\t%s\nunit\t%s\ncompose_files\t%s\n' "$type" "$unit" "$compose_f" > "$base/SERVICE.tsv"
    if [[ $type == compose ]]; then
        conts_list=$(podman ps -a --filter "label=com.docker.compose.project=$group" --format '{{.Names}}') || conts_list=""
        if [[ -n $conts_list ]]; then mapfile -t conts <<< "$conts_list"; fi
    else
        conts=("$group")
    fi
    if (( ${#conts[@]} == 0 )) ||
       ! podman inspect "${conts[@]}" > "$base/CONTAINERS.json" 2> /dev/null ||
       ! podman inspect "${conts[@]}" --format '{{.Name}}{{"\t"}}{{.ImageName}}{{"\t"}}{{.Image}}' > "$base/IMAGES.tsv" 2> /dev/null; then
        rm -f -- "$base/CONTAINERS.json" "$base/IMAGES.tsv"
        event WARN "Could not save the container recipe; the backup goes on without it"
    fi

    local was_running=no came_up=yes t_stopped t0 t1 dest every
    if [[ -n $(running) ]]; then
        was_running=yes
        take_expected
        trap emergency_start EXIT
        now t_stopped
        control stop
        if ! wait_state not_stopped 30; then
            event ERROR "It did not finish stopping: $missing; not copying anything. If it says stopping, start will not bring it up and it has to be recreated."
            exit 1
        fi
        event STOPPED
    else
        event ALREADY_STOPPED
    fi

    # podman unshare = read as "root of the containers", to be able to copy
    # MySQL/Postgres files that do not belong to your user
    for i in "${!e_type[@]}"; do
        dest=$base/${e_file[i]}
        every=$(( e_size[i] / 10240 / 200 + 1 ))
        event COPYING "${e_size[i]}" "${e_type[i]}" "${e_origin[i]}"
        now t0
        local tar_cmd=(podman unshare tar --numeric-owner --checkpoint="$every"
                       --checkpoint-action='echo=@@PROG %{}T' -C "${e_dir[i]}" -cf)
        if [[ $mode == while_copying ]]; then
            "${tar_cmd[@]}" - "${e_obj[i]}" | zstd -q -T0 "-$level" -o "$dest"
        else
            "${tar_cmd[@]}" "${dest%.zst}" "${e_obj[i]}"
        fi
        now t1
        event COPIED $(( t1 - t0 ))
    done

    if [[ $was_running == yes ]]; then
        trap - EXIT
        # If it does not start, do NOT abort: the copy is already fine and is kept anyway
        bring_up start
        if all_started; then
            now t1
            result stopped $(( t1 - t_stopped ))
            event STARTED $(( t1 - t_stopped ))
        else
            event CRITICAL "$group did NOT come back up: $missing. Start it by hand. (The backup is still saved.)"
            came_up=no
        fi
    fi

    if [[ $mode == afterwards ]]; then
        event COMPRESSING
        for i in "${!e_type[@]}"; do
            zstd -q -T0 "-$level" --rm -- "$base/${e_file[i]%.zst}"
        done
    fi

    cd -- "$base"
    local compressed total_comp=0 restore
    printf 'file\ttype\torigin\trestore_to\tbytes_original\tbytes_compressed\n' > MANIFEST.tsv
    for i in "${!e_type[@]}"; do
        compressed=$(stat -c %s -- "${e_file[i]}")
        total_comp=$(( total_comp + compressed ))
        restore=${e_dir[i]}
        if [[ ${e_type[i]} == volume ]]; then restore=${e_origin[i]}; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${e_file[i]}" "${e_type[i]}" "${e_origin[i]}" \
            "$restore" "${e_size[i]}" "$compressed" >> MANIFEST.tsv
        event COMPRESSED "${e_file[i]}" "${e_size[i]}" "$compressed"
    done
    local -a signed=("${e_file[@]}" MANIFEST.tsv SERVICE.tsv)
    if [[ -f CONTAINERS.json ]]; then signed+=(CONTAINERS.json IMAGES.tsv); fi
    sha256sum -- "${signed[@]}" > SHA256SUMS

    result original "$total"
    result compressed "$total_comp"
    output=$(du -sb .)
    result download "${output%%[[:space:]]*}"
    event READY "$total" "$total_comp"

    if [[ $came_up == no ]]; then
        exit 3
    fi
}
main "$@"
EOF

# ---------- Questions ----------

if [[ ! $ZSTD_LEVEL =~ ^([1-9]|1[0-9])$ ]]; then
    echo "ZSTD_LEVEL must be a number from 1 to 19" >&2
    exit 1
fi
if [[ $COMPRESSION != while_copying && $COMPRESSION != afterwards ]]; then
    echo "COMPRESSION must be 'while_copying' or 'afterwards'" >&2
    exit 1
fi

read -rp "Are the containers on another server (use SSH)? [Y/n]: " answer
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
    read -rp "Enter the user and host as user@server: " dest

    if [[ -z $dest ]]; then
        echo "Nothing was entered" >&2
        exit 1
    # Nothing starting with "-": ssh would take it as an option (some run commands)
    elif [[ ! $dest =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; then
        echo "Wrong format (expected user@server)" >&2
        exit 1
    fi

    read -rp "Press Enter for the default port [22] or type another one: " port
    port=${port:-22}
    if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "The port must be a number between 1 and 65535" >&2
        exit 1
    fi

    # A single shared connection (the password is asked once) and, preferably,
    # the fastest cipher: AES-GCM uses the CPU's hardware acceleration.
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
    for program in podman tar zstd sha256sum; do
        if ! command -v "$program" >/dev/null; then
            echo "The program '$program' is missing on this machine" >&2
            exit 1
        fi
    done
fi

list=$(on_server bash -s <<'EOF'
podman ps -a --format '{{or (index .Labels "com.docker.compose.project") .Names}} {{.Names}}' | sort
EOF
)
if [[ -z $list ]]; then
    echo "No containers found on $dest" >&2
    exit 1
fi
mapfile -t rows <<< "$list"
services=()
declare -A containers=()
for row in "${rows[@]}"; do
    group=${row%% *}
    cont=${row#* }
    if [[ -z ${containers[$group]:-} ]]; then
        services+=("$group")
        containers[$group]=$cont
    else
        containers[$group]+=", $cont"
    fi
done

echo
for i in "${!services[@]}"; do
    group=${services[i]}
    printf '  %2d) %-20s %s%s%s\n' "$((i + 1))" "$group" "$c_dim" "${containers[$group]}" "$c_end"
done
echo

read -rp "Services to back up (e.g. 1 2 5 or 'all'): " answer
choose "$answer" || exit 1
chosen=("${result[@]}")
if (( ${#chosen[@]} == 0 )); then
    echo "No service was chosen" >&2
    exit 1
fi

read -rp "Restart any service when done? (e.g. 6, Enter for none): " answer
choose "$answer" || exit 1
restart_at_end=("${result[@]}")

read -rp "Folder to store the backups in (e.g. /media/disk/backups): " path
if [[ -z $path ]]; then
    echo "No folder was given" >&2
    exit 1
fi
path=$(realpath -m -- "${path/#\~/$HOME}")
folder="$path/backup_$(date +%F_%H%M)"
if [[ -e $folder ]]; then
    echo "$folder already exists (another backup from this same minute). Wait a minute and run it again." >&2
    exit 1
fi

echo
echo "Checking services..."
for group in "${chosen[@]}"; do
    if ! inventory "$group"; then
        echo "Could not check $group on $dest" >&2
        exit 1
    fi
    printf '\n  %s%s%s (%s)\n' "$c_bold" "$group" "$c_end" "$type"
    printf '    config:   %s\n' "${dir:-${source%/*}}"
    for v in "${volumes[@]}"; do printf '    volume:   %s\n' "$v"; done
    for b in "${binds_to_copy[@]}"; do printf '    bind:     %s\n' "$b"; done
    for o in "${skipped[@]}"; do printf '    %sskipped:  %s%s\n' "$c_dim" "$o" "$c_end"; done
done

echo
echo "They will be stopped one at a time while they are copied: ${chosen[*]}"
if (( ${#restart_at_end[@]} > 0 )); then
    echo "When done, these will be restarted: ${restart_at_end[*]}"
fi
echo "Destination: $folder"
read -rp "Continue? [y/N]: " confirm
if [[ ${confirm,,} != y ]]; then
    echo "Cancelled."
    exit 0
fi

# ---------- Backup ----------

# mkdir without -p on the last folder: if it already exists, fail instead of mixing backups
if ! mkdir -p -- "$path" || ! mkdir -- "$folder"; then
    echo "Could not create $folder" >&2
    exit 1
fi
log=$folder/backup.log
: > "$log"
exec 2> >(capture_stderr)
capture_pid=$!
state_dir=$(mktemp -d)
now t_start

# The temporary copy must NOT go to RAM (tmpfs): tens of GB in RAM would bring the
# server down. Without SSH the work happens inside the destination and is just moved at the end.
if [[ $use_ssh == yes ]]; then
    candidates=(yes /tmp /var/tmp)
else
    candidates=(no "$folder")
fi
server_info=$(on_server "bash -s -- $(printf '%q ' "${candidates[@]}")" <<'EOF'
set -euo pipefail
check_ram=$1
shift
for d in "$@"; do
    fs=$(findmnt -no FSTYPE -T "$d")
    if [[ $check_ram == yes && $fs == tmpfs ]]; then continue; fi
    t=$(mktemp -d "$d/.backup_XXXXXXXX")
    echo "tmp $t"
    echo "fs $fs"
    echo "free $(df -B1 --output=avail -- "$t" | tail -n 1 | tr -d ' ')"
    echo "host $(uname -n)"
    echo "podman $(podman --version | awk '{print $NF}')"
    echo "kernel $(uname -r)"
    echo "rsync $(command -v rsync >/dev/null && echo yes || echo no)"
    exit 0
done
echo "Neither /tmp nor /var/tmp is on disk (both are in RAM)" >&2
exit 1
EOF
) || exit 1

srv_tmp="" srv_fs="" srv_free=0 srv_host="" srv_podman="" srv_kernel="" srv_rsync=no
while read -r key value; do
    case $key in
        tmp)    srv_tmp=$value ;;
        fs)     srv_fs=$value ;;
        free)  srv_free=$value ;;
        host)   srv_host=$value ;;
        podman) srv_podman=$value ;;
        kernel) srv_kernel=$value ;;
        rsync)  srv_rsync=$value ;;
    esac
done <<< "$server_info"

# This folder is removed with rm -rf: make sure it is exactly what we expect
if [[ $use_ssh == yes ]]; then
    [[ $srv_tmp =~ ^/(var/)?tmp/\.backup_[A-Za-z0-9]{8}$ ]] || srv_tmp=""
elif [[ ${srv_tmp%/*} != "$folder" || ! ${srv_tmp##*/} =~ ^\.backup_[A-Za-z0-9]{8}$ ]]; then
    srv_tmp=""
fi
if [[ -z $srv_tmp ]]; then
    error "Unexpected temporary folder on the server"
    exit 1
fi
remote_tmp=$srv_tmp

if [[ $use_ssh == no ]]; then
    method=local
elif [[ $srv_rsync == yes ]] && command -v rsync >/dev/null; then
    method=rsync
else
    method=scp
fi

write_header
info "Backing up ${#chosen[@]} service(s) to $folder"
if [[ $method == scp ]]; then
    warn "rsync is not on both machines: using scp (slower and cannot resume)"
fi

n=0
for group in "${chosen[@]}"; do
    n=$(( n + 1 ))
    title "[$n/${#chosen[@]}] $group"
    backup "$group"
done
if [[ -n $download_pid && $method != local ]]; then
    title "Finishing the download of $download_group"
fi
wait_download

for group in "${restart_at_end[@]}"; do
    title "Restarting $group"
    restart_rc=0
    if inventory "$group"; then remote restart "$group" || restart_rc=$?; else restart_rc=1; fi
    if (( restart_rc == 0 )); then
        success "$group restarted"
    else
        error "The restart of $group failed"
        failed+=("restart of $group")
        if (( restart_rc == 4 )); then critical+=("$group"); fi
    fi
done

now t_end
finished=yes
show_summary
write_restore_howto
raw ""
info "Total time: $(duration $(( t_end - t_start )))"
info "Details and restore commands: $log"
if (( ${#critical[@]} > 0 )); then
    error "ATTENTION: these services were left STOPPED, start them by hand: ${critical[*]}"
fi
if (( ${#failed[@]} > 0 )); then
    error "Finished with errors in: ${failed[*]}"
    exit 1
fi
# With services stopped the urgent thing is to start them, not to clean up
if (( ${#critical[@]} == 0 )); then
    offer_delete_old
fi
success "All done. Backups in: $folder"
