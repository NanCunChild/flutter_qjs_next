#!/usr/bin/env bash
set -u

# Run the soak test in separate processes so each A/B case gets a clean RSS
# baseline. The test itself reads these values through --dart-define.

usage() {
  cat <<'USAGE'
Usage: scripts/run-soak-ab.sh [options]

Options:
  --pool-size N       Engine pool size (default: 32)
  --rss-factor F      Abort when RSS > baseline * F (default: 2)
  --duration SEC      Duration of each case (default: 3600)
  --workers N         Worker count (default: 32)
  --ops-per-burst N   Operations per worker burst (default: 8)
  --metrics SEC       Metrics interval (default: 5)
  --rounds N          Number of complete A/B rounds (default: 1)
  --output DIR        Log directory (default: soak_ab_logs/<timestamp>)
  --flutter CMD       Flutter executable (default: flutter)
  -h, --help          Show this help

Example:
  scripts/run-soak-ab.sh --pool-size 32 --rss-factor 128 --duration 3600 --rounds 3
USAGE
}

pool_size=32
rss_factor=2
duration_sec=3600
workers=32
ops_per_burst=8
metrics_sec=5
rounds=1
flutter_cmd=flutter
output_dir="soak_ab_logs/$(date -u +%Y%m%dT%H%M%SZ)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-size)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      pool_size=$2
      shift 2
      ;;
    --rss-factor)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      rss_factor=$2
      shift 2
      ;;
    --duration)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      duration_sec=$2
      shift 2
      ;;
    --workers)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      workers=$2
      shift 2
      ;;
    --ops-per-burst)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ops_per_burst=$2
      shift 2
      ;;
    --metrics)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      metrics_sec=$2
      shift 2
      ;;
    --rounds)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      rounds=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      output_dir=$2
      shift 2
      ;;
    --flutter)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      flutter_cmd=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d example ]]; then
  printf 'Run this script from the repository root.\n' >&2
  exit 2
fi

if ! [[ "$pool_size" =~ ^[1-9][0-9]*$ && "$duration_sec" =~ ^[1-9][0-9]*$ &&
        "$workers" =~ ^[1-9][0-9]*$ && "$ops_per_burst" =~ ^[1-9][0-9]*$ &&
        "$metrics_sec" =~ ^[1-9][0-9]*$ && "$rounds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'pool-size, duration, workers, ops-per-burst, metrics and rounds must be positive integers.\n' >&2
  exit 2
fi

if ! [[ "$rss_factor" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$rss_factor" == 0 || "$rss_factor" == 0.* ]]; then
  printf 'rss-factor must be a positive number.\n' >&2
  exit 2
fi

mkdir -p "$output_dir"
output_dir="$(realpath -m "$output_dir")"
mkdir -p "$output_dir"

config_file="$output_dir/config.txt"
{
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'pool_size=%s\n' "$pool_size"
  printf 'rss_factor=%s\n' "$rss_factor"
  printf 'duration_sec=%s\n' "$duration_sec"
  printf 'workers=%s\n' "$workers"
  printf 'ops_per_burst=%s\n' "$ops_per_burst"
  printf 'metrics_sec=%s\n' "$metrics_sec"
  printf 'rounds=%s\n' "$rounds"
  printf 'flutter=%s\n' "$flutter_cmd"
  printf 'host=%s\n' "$(hostname 2>/dev/null || true)"
  printf 'kernel=%s\n' "$(uname -a 2>/dev/null || true)"
} > "$config_file"

summary_file="$output_dir/summary.tsv"
printf 'round\tcase\tresetOnRelease\texit_status\tlog\n' > "$summary_file"

run_case() {
  local round_name=$1
  local reset_value=$2
  local case_name=$3
  local case_dir="$output_dir/$round_name"
  local log_file="$case_dir/${case_name}.log"
  local start_file="$case_dir/${case_name}.start.txt"
  local end_file="$case_dir/${case_name}.end.txt"
  local status

  mkdir -p "$case_dir"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$start_file"
  printf '\n=== round=%s case=%s resetOnRelease=%s ===\n' \
    "$round_name" "$case_name" "$reset_value"
  set +e
  (
    cd example || exit 125
    "$flutter_cmd" test test/soak_stress_test.dart \
      --timeout none \
      --dart-define="SOAK_DURATION_SEC=$duration_sec" \
      --dart-define="SOAK_POOL_SIZE=$pool_size" \
      --dart-define="SOAK_WORKERS=$workers" \
      --dart-define="SOAK_OPS_PER_BURST=$ops_per_burst" \
      --dart-define="SOAK_METRICS_SEC=$metrics_sec" \
      --dart-define="SOAK_RESET_ON_RELEASE=$reset_value" \
      --dart-define="SOAK_MAX_RSS_GROWTH=$rss_factor" \
      --dart-define="SOAK_DUMP_DIR=$case_dir/${case_name}_dumps"
  ) > >(tee "$log_file") 2>&1
  status=$?
  set -e
  date -u +%Y-%m-%dT%H:%M:%SZ > "$end_file"
  printf 'round=%s case=%s resetOnRelease=%s exit_status=%s log=%s\n' \
    "$round_name" "$case_name" "$reset_value" "$status" "$log_file" |
    tee -a "$log_file"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$round_name" "$case_name" "$reset_value" "$status" "$log_file" >> "$summary_file"
  return "$status"
}

overall_status=0
for ((round=1; round<=rounds; round++)); do
  printf -v round_name 'round-%02d' "$round"
  run_case "$round_name" 1 reset_on || overall_status=1
  run_case "$round_name" 0 reset_off || overall_status=1
done

printf '\nA/B results are in %s\n' "$output_dir"
printf 'Configuration: %s\n' "$config_file"
printf 'Summary: %s\n' "$summary_file"
printf 'Overall exit status: %s\n' "$overall_status"
exit "$overall_status"
