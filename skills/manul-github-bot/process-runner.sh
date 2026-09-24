#!/usr/bin/env bash
# process-runner.sh — Testable process boundary for AgentExecutor adapters.
#
# Adapters MUST NOT spawn subprocesses directly. They call ProcessRunner.run()
# which returns a structured result the test suite can mock without a real
# process. This file provides both the interface contract and a production
# implementation backed by bash's built-in process management.
#
# The mockable return value is a single string on stdout in the format:
#   exit_code<TAB>duration_seconds<TAB>interrupted<TAB>timed_out
# followed by zero or more lines of captured stdout and stderr on fd 1 and fd 2.
#
# Production usage (inside an adapter):
#   source "$SCRIPT_DIR/process-runner.sh"
#   local result
#   result="$(ProcessRunner.run --timeout "$timeout" --cwd "$cwd" \
#           -- bin args...)"
#   local exit_code duration interrupted timed_out
#   exit_code="$(printf '%s\n' "$result" | head -1 | cut -f1)"
#   ...
#
# Testing usage (inside tests):
#   ProcessRunner.MockMode=true  # before sourcing
#   # ProcessRunner.run returns the fixture output instead of spawning.
#
# Public API:
#   ProcessRunner.run [--timeout N] [--cwd PATH] [--env K=V ...] <COMMAND> [ARGS...]
#     → stdout: single line with fields: exit_code|duration|interrupted|timed_out
#     → stdout then: captured adapter stdout
#     → stderr: captured adapter stderr
#
# ProcessRunner.fixture() — set the mock return value from a test.
#   ProcessRunner.fixture '0|5.2|false|false'
#   ProcessRunner.fixture_stdout "TASK_DONE"
#   ProcessRunner.fixture_stderr "starting..."
#
# ProcessRunner.MockMode — boolean; when true, run() returns fixture instead.

ProcessRunner_ExitCode=""
ProcessRunner_Duration=""
ProcessRunner_Interrupted=""
ProcessRunner_TimedOut=""
ProcessRunner_FixtureStdout=""
ProcessRunner_FixtureStderr=""
ProcessRunner_OverrideCommand=""
ProcessRunner_OverrideArgs=""

ProcessRunner_RunPid=""
ProcessRunner_RunStart=""
ProcessRunner_WaitPid=""
ProcessRunner_Rc=""
ProcessRunner_TimedOut=""
ProcessRunner_Interrupted=""

# Track whether ProcessRunner created the stdout/stderr temp files itself.
# Files it created are cleaned up; files supplied by the caller (e.g. the
# daemon's task stdout/stderr) are left intact so the caller can inspect them.
ProcessRunner_ManagedStdout=""
ProcessRunner_ManagedStderr=""

_process_runner_now() {
    python3 -c 'import time; print(time.time())' 2>/dev/null \
        || date +%s.%N
}

ProcessRunner.fixture() {
    ProcessRunner_ExitCode="$1"
    ProcessRunner_Duration="${2:-}"
    ProcessRunner_Interrupted="${3:-false}"
    ProcessRunner_TimedOut="${4:-false}"
}

ProcessRunner.fixture_stdout() {
    ProcessRunner_FixtureStdout="$*"
}

ProcessRunner.fixture_stderr() {
    ProcessRunner_FixtureStderr="$*"
}

ProcessRunner.override() {
    # For tests that need a specific command+args to be reported.
    ProcessRunner_OverrideCommand="$1"
    shift
    ProcessRunner_OverrideArgs=("$@")
}

ProcessRunner.run() {
    local timeout="" cwd="" env_args=() cmd_args=()
    ProcessRunner_ExitCode=""
    ProcessRunner_Duration=""
    ProcessRunner_Rc=""
    ProcessRunner_Interrupted="false"
    ProcessRunner_TimedOut="false"
    ProcessRunner_ManagedStdout=""
    ProcessRunner_ManagedStderr=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --cwd)     cwd="$2";     shift 2 ;;
            --env)     env_args+=("$2"); shift 2 ;;
            --)        shift; cmd_args+=("$@"); break ;;
            -*)        cmd_args+=("$1"); shift ;;
            *)
                # First positional arg is the command; rest are args.
                if [ ${#cmd_args[@]} -eq 0 ]; then
                    cmd_args+=("$1")
                else
                    cmd_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    # --- Mock mode (set by tests via ProcessRunner.MockMode=true) ---
    if [ "${ProcessRunner_MockMode:-false}" = "true" ]; then
        local mock_exit="${ProcessRunner_ExitCode:-0}"
        local mock_dur="${ProcessRunner_Duration:-0}"
        local mock_int="${ProcessRunner_Interrupted:-false}"
        local mock_to="${ProcessRunner_TimedOut:-false}"
        printf '%s|%s|%s|%s\n' "$mock_exit" "$mock_dur" "$mock_int" "$mock_to"
        if [ -n "$ProcessRunner_FixtureStdout" ]; then
            printf '%s' "$ProcessRunner_FixtureStdout"
        fi
        if [ -n "$ProcessRunner_FixtureStderr" ]; then
            printf '%s' "$ProcessRunner_FixtureStderr" >&2
        fi
        return 0
    fi

    # --- Production path ---
    local start_ts end_ts dur
    start_ts="$(_process_runner_now)"

    local full_cmd=("${cmd_args[@]}")
    if [ ${#full_cmd[@]} -eq 0 ]; then
        echo "ProcessRunner: missing command" >&2
        return 2
    fi

    local env_prefix=()
    local i
    for i in "${!env_args[@]}"; do
        env_prefix+=("${env_args[$i]}")
    done

    # Resolve stdout/stderr destinations. Caller-supplied files (e.g. the
    # daemon's per-task stdout/stderr) are kept intact so the caller can
    # inspect result markers after the run. If none are supplied, ProcessRunner
    # creates managed temp files and cleans them up afterwards.
    local out_file="${ProcessRunner_TmpStdout:-}"
    local err_file="${ProcessRunner_TmpStderr:-}"
    if [ -z "$out_file" ]; then
        out_file="$(mktemp "${TMPDIR:-/tmp}/manul-pr-out.XXXXXX")"
        ProcessRunner_ManagedStdout="$out_file"
    fi
    if [ -z "$err_file" ]; then
        err_file="$(mktemp "${TMPDIR:-/tmp}/manul-pr-err.XXXXXX")"
        ProcessRunner_ManagedStderr="$err_file"
    fi

    local old_pwd
    old_pwd="$(pwd)"
    if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
        echo "ProcessRunner: working directory does not exist: $cwd" >&2
        ProcessRunner_Rc=66
    else
        if [ -n "$cwd" ]; then
            cd "$cwd" || ProcessRunner_Rc=66
        fi

        local -a exec_cmd=()
        if [ ${#env_prefix[@]} -gt 0 ]; then
            exec_cmd=(env "${env_prefix[@]}" "${full_cmd[@]}")
        else
            exec_cmd=("${full_cmd[@]}")
        fi

        if [ -z "${ProcessRunner_Rc:-}" ]; then
            if [ -n "$timeout" ] && [ "$timeout" -gt 0 ] 2>/dev/null; then
                timeout -k 60 "$timeout" "${exec_cmd[@]}" >>"$out_file" 2>>"$err_file"
                ProcessRunner_Rc=$?
                if [ "$ProcessRunner_Rc" -eq 124 ]; then
                    ProcessRunner_TimedOut="true"
                fi
            else
                "${exec_cmd[@]}" >>"$out_file" 2>>"$err_file"
                ProcessRunner_Rc=$?
            fi
        fi
        cd "$old_pwd" 2>/dev/null || true
    fi

    end_ts="$(_process_runner_now)"
    dur="$(python3 -c "print(round($end_ts - $start_ts, 3))" 2>/dev/null || echo "$(( end_ts - start_ts ))")"

    # Emit captured output for managed files so callers using $(...) can see it.
    if [ -n "$ProcessRunner_ManagedStdout" ] && [ -s "$out_file" ]; then
        cat "$out_file"
    fi
    if [ -n "$ProcessRunner_ManagedStderr" ] && [ -s "$err_file" ]; then
        cat "$err_file" >&2
    fi

    # Clean up only files ProcessRunner created itself.
    [ -n "$ProcessRunner_ManagedStdout" ] && rm -f "$ProcessRunner_ManagedStdout" 2>/dev/null || true
    [ -n "$ProcessRunner_ManagedStderr" ] && rm -f "$ProcessRunner_ManagedStderr" 2>/dev/null || true
    unset ProcessRunner_ManagedStdout ProcessRunner_ManagedStderr

    printf '%s|%s|false|%s\n' "$ProcessRunner_Rc" "$dur" "${ProcessRunner_TimedOut:-false}"
    return "$ProcessRunner_Rc"
}
