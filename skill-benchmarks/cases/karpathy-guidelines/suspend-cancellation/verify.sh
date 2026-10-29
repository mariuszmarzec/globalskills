#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=""
MODE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$WORKSPACE" ] || { echo "missing --workspace" >&2; exit 2; }
[ -n "$MODE" ] || { echo "missing --mode" >&2; exit 2; }

file="$WORKSPACE/Example.kt"
has_cancel_rethrow=false
has_ensure_active=false
has_data_mapping=false
has_error_mapping=false
has_unneeded_wrapper=false
if grep -Fq 'catch (cancelled: CancellationException)' "$file" &&
   grep -Fq 'throw cancelled' "$file"; then
  has_cancel_rethrow=true
fi
grep -Fq 'ensureActive()' "$file" && has_ensure_active=true || true
grep -Fq 'UiState.Data(repository.load())' "$file" && has_data_mapping=true || true
grep -Fq 'UiState.Error(' "$file" && has_error_mapping=true || true
grep -Fq 'try {' "$file" && grep -Fq 'return UiState.Data(repository.load())' "$file" && has_unneeded_wrapper=true || true

passed=false
if [ "$has_cancel_rethrow" = true ] && [ "$has_ensure_active" = true ] &&
   [ "$has_data_mapping" = true ] && [ "$has_error_mapping" = true ] &&
   [ "$has_unneeded_wrapper" = false ]; then
  passed=true
fi

printf '{"passed":%s,"mode":"%s","checks":[' "$passed" "$MODE"
printf '{"name":"cancellation-rethrown","passed":%s,"expected":"catch CancellationException and rethrow it","actual":"%s","evidence":"inspect CancellationException catch"}' "$has_cancel_rethrow" "$([ "$has_cancel_rethrow" = true ] && echo present || echo missing)"
printf ',{"name":"ensure-active","passed":%s,"expected":"ensureActive before converting an ordinary failure","actual":"%s","evidence":"grep ensureActive()"}' "$has_ensure_active" "$([ "$has_ensure_active" = true ] && echo present || echo missing)"
printf ',{"name":"success-and-error-mapping","passed":%s,"expected":"map repository success to Data and ordinary failure to Error","actual":"%s","evidence":"inspect UiState.Data and UiState.Error"}' "$([ "$has_data_mapping" = true ] && [ "$has_error_mapping" = true ] && echo true || echo false)" "$([ "$has_data_mapping" = true ] && [ "$has_error_mapping" = true ] && echo present || echo incomplete)"
printf ',{"name":"no-unneeded-suspend-wrapper","passed":%s,"expected":"do not wrap suspend call without need","actual":"%s","evidence":"inspect suspend-call try/catch"}]}' "$([ "$has_unneeded_wrapper" = false ] && echo true || echo false)" "$([ "$has_unneeded_wrapper" = true ] && echo present || echo absent)"
printf '\n'
[ "$passed" = true ]
