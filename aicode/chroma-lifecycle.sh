#!/usr/bin/env bash
# Chroma lifecycle helpers for the maintained aicode launcher.
# This file is sourced by aicode; it intentionally does not run anything on import.

chroma_read_settings() {
    local caracal_home="$1"
    local python="$caracal_home/venv/bin/python"
    local config_file="$caracal_home/config/sources.yaml"

    if [[ ! -x "$python" || ! -f "$config_file" ]]; then
        echo "Caracal Python environment or active config is missing." >&2
        return 1
    fi

    "$python" - "$config_file" <<'PY'
import sys
from caracal_rag.config import load_active_config

config = load_active_config(sys.argv[1])
print(config.chroma.host)
print(config.chroma.port)
print(str(config.chroma.ssl).lower())
PY
}

chroma_http_ready() {
    local bind_host="$1" port="$2" url_host="$1" status endpoint
    if [[ "$url_host" == *:* ]]; then
        url_host="[$url_host]"
    fi
    command -v curl >/dev/null 2>&1 || return 1

    # Support both Chroma API generations without accepting an unrelated HTTP service.
    for endpoint in /api/v2/heartbeat /api/v1/heartbeat; do
        status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
            --connect-timeout 1 --max-time 2 \
            "http://$url_host:$port$endpoint" 2>/dev/null || true)"
        [[ "$status" =~ ^2[0-9][0-9]$ ]] && return 0
    done
    return 1
}

chroma_pid_matches() {
    local pid="$1" chroma_cli="$2" bind_host="$3" port="$4" data_dir="$5" command_line
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$command_line" ] || return 1
    [[ -n "$command_line" ]] || return 1

    # Match the executable and all deployment-specific arguments before treating a PID as ours.
    case "$command_line" in
        *"$chroma_cli run --host $bind_host --port $port --path $data_dir"*) return 0 ;;
        *) return 1 ;;
    esac
}

chroma_port_listening() {
    local port="$1" listeners
    command -v ss >/dev/null 2>&1 || return 2
    listeners="$(ss -H -ltn "sport = :$port" 2>/dev/null)" || return 2
    [[ -n "$listeners" ]]
}

chroma_start_process() {
    local chroma_cli="$1" bind_host="$2" port="$3" data_dir="$4" log_file="$5" pid_file="$6"
    local old_umask pid

    if [[ -L "$log_file" ]]; then
        echo "Refusing symlinked Chroma log path: $log_file" >&2
        return 1
    fi

    old_umask="$(umask)"
    umask 077
    if ! touch "$log_file" || ! chmod 0600 "$log_file"; then
        umask "$old_umask"
        echo "Could not create a private Chroma log at $log_file." >&2
        return 1
    fi

    nohup "$chroma_cli" run --host "$bind_host" --port "$port" --path "$data_dir" \
        </dev/null >>"$log_file" 2>&1 &
    pid=$!

    if ! printf '%s\n' "$pid" > "$pid_file" || ! chmod 0600 "$pid_file"; then
        umask "$old_umask"
        echo "Could not securely record Chroma PID in $pid_file." >&2
        return 1
    fi
    umask "$old_umask"
    echo "Started Chroma process (PID $pid); waiting for its health endpoint."
}

chroma_ensure_locked() {
    local caracal_home="$1" bind_host="$2" port="$3" attempts="$4"
    local chroma_cli="$caracal_home/venv/bin/chroma"
    local data_dir="$caracal_home/chroma-data"
    local run_dir="$caracal_home/run"
    local pid_file="$run_dir/chroma.pid"
    local log_file="${CARACAL_CHROMA_LOG:-/tmp/caracal-chroma.log}"
    local old_pid recorded_pid listener_status pid i

    # If a Chroma heartbeat is already healthy, reuse it and never spawn a duplicate.
    if chroma_http_ready "$bind_host" "$port"; then
        echo "Chroma is already healthy at $bind_host:$port; reusing the configured endpoint."
        return 0
    fi

    if [[ -L "$pid_file" ]]; then
        echo "WARNING: refusing symlinked Chroma PID file: $pid_file"
        return 1
    fi
    if [[ -e "$pid_file" ]]; then
        if [[ ! -f "$pid_file" ]]; then
            echo "WARNING: refusing unexpected Chroma PID path: $pid_file"
            return 1
        fi
        IFS= read -r old_pid < "$pid_file" || old_pid=""
        if chroma_pid_matches "$old_pid" "$chroma_cli" "$bind_host" "$port" "$data_dir"; then
            for ((i = 0; i < attempts; i++)); do
                if chroma_http_ready "$bind_host" "$port"; then
                    echo "Chroma is ready at $bind_host:$port (PID $old_pid)."
                    return 0
                fi
                if ! kill -0 "$old_pid" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "$old_pid" 2>/dev/null; then
                echo "WARNING: tracked Chroma process (PID $old_pid) is alive but not healthy; not starting a duplicate. See $log_file."
                return 1
            fi
        fi

        # The recorded PID is stale or belongs to another command. Never signal it.
        rm -f -- "$pid_file" || {
            echo "WARNING: could not remove stale Chroma PID file: $pid_file"
            return 1
        }
    fi

    if [[ ! -x "$chroma_cli" ]]; then
        echo "WARNING: Chroma executable is missing at $chroma_cli; cannot start the configured local database."
        return 1
    fi
    if [[ ! -d "$data_dir" ]]; then
        echo "WARNING: existing Chroma data directory is missing at $data_dir; refusing to create an empty database."
        return 1
    fi

    if chroma_port_listening "$port"; then
        echo "WARNING: port $port is occupied but the Chroma heartbeat is unhealthy; refusing to start another process."
        return 1
    else
        listener_status=$?
        if (( listener_status == 2 )); then
            echo "WARNING: cannot inspect listening ports because ss is unavailable or failed; refusing unsafe Chroma startup."
            return 1
        fi
    fi

    if [[ -L "$log_file" ]]; then
        echo "WARNING: refusing symlinked Chroma log path: $log_file"
        return 1
    fi
    if ! chroma_start_process "$chroma_cli" "$bind_host" "$port" "$data_dir" "$log_file" "$pid_file"; then
        echo "WARNING: could not launch Chroma; Caracal MCP will remain disabled if its check fails."
        return 1
    fi
    IFS= read -r pid < "$pid_file" || pid=""
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Chroma started without a valid PID record; inspect $log_file."
        return 1
    fi

    for ((i = 0; i < attempts; i++)); do
        if chroma_http_ready "$bind_host" "$port"; then
            if chroma_pid_matches "$pid" "$chroma_cli" "$bind_host" "$port" "$data_dir"; then
                echo "Chroma ready at $bind_host:$port (PID $pid, data $data_dir)."
                return 0
            fi
            echo "WARNING: Chroma heartbeat responded, but the launched process identity could not be verified; inspect $log_file."
            return 1
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if ! kill -0 "$pid" 2>/dev/null; then
        IFS= read -r recorded_pid < "$pid_file" 2>/dev/null || recorded_pid=""
        if [[ "$recorded_pid" == "$pid" ]]; then
            rm -f -- "$pid_file"
        fi
    fi
    echo "WARNING: Chroma did not become healthy on port $port; inspect $log_file. Caracal MCP will be skipped if its check fails."
    return 1
}

ensure_chroma_server() {
    local caracal_home="$1" settings_text host host_lower port ssl bind_host attempts
    local run_dir lock_file lock_fd result

    if ! settings_text="$(chroma_read_settings "$caracal_home" 2>/dev/null)"; then
        echo "WARNING: could not read active Chroma settings; not attempting automatic startup."
        return 1
    fi
    local -a settings=()
    mapfile -t settings <<< "$settings_text"
    if (( ${#settings[@]} < 3 )); then
        echo "WARNING: active Chroma settings are incomplete; not attempting automatic startup."
        return 1
    fi
    host="${settings[0]}"
    port="${settings[1]}"
    ssl="${settings[2],,}"
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
        echo "WARNING: configured Chroma port is invalid; not attempting automatic startup."
        return 1
    fi

    host_lower="${host,,}"
    case "$host_lower" in
        localhost|127.0.0.1) bind_host="127.0.0.1" ;;
        ::1) bind_host="::1" ;;
        *)
            echo "Chroma host '$host' is not loopback; leaving the server externally managed."
            return 0
            ;;
    esac
    if [[ "$ssl" == "true" || "$ssl" == "1" || "$ssl" == "yes" ]]; then
        echo "Chroma SSL is enabled for '$host'; leaving that endpoint externally managed."
        return 0
    fi

    attempts="${CARACAL_CHROMA_READY_ATTEMPTS:-20}"
    if [[ ! "$attempts" =~ ^[0-9]{1,3}$ ]] || (( attempts < 1 || attempts > 60 )); then
        attempts=20
    fi

    run_dir="$caracal_home/run"
    lock_file="$run_dir/chroma.lock"
    if [[ -L "$run_dir" ]]; then
        echo "WARNING: refusing symlinked Chroma runtime directory: $run_dir"
        return 1
    fi
    if ! mkdir -p "$run_dir" || [[ ! -d "$run_dir" ]]; then
        echo "WARNING: could not prepare Chroma runtime directory: $run_dir"
        return 1
    fi
    chmod 0700 "$run_dir" || {
        echo "WARNING: could not secure Chroma runtime directory: $run_dir"
        return 1
    }
    if [[ -L "$lock_file" ]]; then
        echo "WARNING: refusing symlinked Chroma lock file: $lock_file"
        return 1
    fi
    exec {lock_fd}>"$lock_file" || {
        echo "WARNING: could not open Chroma startup lock: $lock_file"
        return 1
    }
    chmod 0600 "$lock_file" || {
        exec {lock_fd}>&-
        echo "WARNING: could not secure Chroma startup lock: $lock_file"
        return 1
    }
    if ! command -v flock >/dev/null 2>&1; then
        exec {lock_fd}>&-
        echo "WARNING: flock is unavailable; refusing concurrent-unsafe Chroma startup."
        return 1
    fi
    if ! flock -w 20 "$lock_fd"; then
        if chroma_http_ready "$bind_host" "$port"; then
            echo "Chroma became healthy while waiting for the startup lock; reusing it."
            exec {lock_fd}>&-
            return 0
        fi
        exec {lock_fd}>&-
        echo "WARNING: another Chroma startup holds the lock and the endpoint is still unhealthy."
        return 1
    fi

    result=0
    chroma_ensure_locked "$caracal_home" "$bind_host" "$port" "$attempts" || result=$?
    flock -u "$lock_fd" >/dev/null 2>&1 || true
    exec {lock_fd}>&-
    return "$result"
}
