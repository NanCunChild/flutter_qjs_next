#!/usr/bin/env bash
set -u

# Run the soak test in separate processes so each A/B case gets a clean RSS
# baseline. The test itself reads these values through --dart-define.
#
# full_test mode runs every workload profile × reset on/off, then plots reports.

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
  --profile NAME      Workload profile (default: all)
                      Values: all, tiny, no_typed_array, dart_to_js,
                      js_to_dart, typed_array
  --full-test         Run every profile (see --profiles) with A/B reset
  --profiles LIST     Comma-separated profiles for --full-test
                      (default: tiny,no_typed_array,dart_to_js,js_to_dart,typed_array,all)
  --rounds N          Number of complete A/B rounds (default: 1)
  --output DIR        Log directory (default: soak_ab_logs/<timestamp>)
  --plot / --no-plot  Generate HTML charts after run (default: on for --full-test)
  --plot-only DIR     Only plot existing results under DIR (no soak run)
  --flutter CMD       Flutter executable (default: flutter)
  -h, --help          Show this help

Examples:
  # Single profile A/B (1h each)
  scripts/run-soak-ab.sh --profile tiny --duration 3600

  # Full matrix with charts
  scripts/run-soak-ab.sh --full-test --duration 3600 --rss-factor 128

  # Re-plot existing soak_profiles tree
  scripts/run-soak-ab.sh --plot-only soak_profiles
USAGE
}

pool_size=32
rss_factor=2
duration_sec=3600
workers=32
ops_per_burst=8
metrics_sec=5
profile=all
full_test=0
profiles_csv="tiny,no_typed_array,dart_to_js,js_to_dart,typed_array,all"
rounds=1
flutter_cmd=flutter
output_dir="soak_ab_logs/$(date -u +%Y%m%dT%H%M%SZ)"
plot_mode=auto   # auto | on | off
plot_only=""

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
    --profile)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      profile=$2
      shift 2
      ;;
    --full-test)
      full_test=1
      shift
      ;;
    --profiles)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      profiles_csv=$2
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
    --plot)
      plot_mode=on
      shift
      ;;
    --no-plot)
      plot_mode=off
      shift
      ;;
    --plot-only)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      plot_only=$2
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

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2

plot_metrics() {
  local root=$1
  local out=$2
  local title=${3:-Soak metrics report}
  if [[ ! -f scripts/plot-soak-metrics.py ]]; then
    printf 'plot script missing: scripts/plot-soak-metrics.py\n' >&2
    return 1
  fi
  python3 scripts/plot-soak-metrics.py --root "$root" --output "$out" --title "$title"
}

if [[ -n "$plot_only" ]]; then
  if [[ ! -d "$plot_only" ]]; then
    printf 'plot-only directory not found: %s\n' "$plot_only" >&2
    exit 2
  fi
  plot_dir="$plot_only/report"
  plot_metrics "$plot_only" "$plot_dir" "Soak report ($(basename "$plot_only"))"
  printf 'Report: %s/index.html\n' "$plot_dir"
  exit 0
fi

if [[ ! -d example ]]; then
  printf 'Run this script from the repository root (example/ missing).\n' >&2
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

# Default plot: on for full_test, off for single-profile unless --plot
if [[ "$plot_mode" == "auto" ]]; then
  if [[ "$full_test" -eq 1 ]]; then
    do_plot=1
  else
    do_plot=0
  fi
elif [[ "$plot_mode" == "on" ]]; then
  do_plot=1
else
  do_plot=0
fi

mkdir -p "$output_dir"
output_dir="$(realpath -m "$output_dir")"
mkdir -p "$output_dir"

IFS=',' read -r -a profile_list <<< "$profiles_csv"
if [[ "$full_test" -eq 0 ]]; then
  profile_list=("$profile")
fi

# trim whitespace
for i in "${!profile_list[@]}"; do
  profile_list[$i]="$(echo "${profile_list[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
done

config_file="$output_dir/config.txt"
{
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'pool_size=%s\n' "$pool_size"
  printf 'rss_factor=%s\n' "$rss_factor"
  printf 'duration_sec=%s\n' "$duration_sec"
  printf 'workers=%s\n' "$workers"
  printf 'ops_per_burst=%s\n' "$ops_per_burst"
  printf 'metrics_sec=%s\n' "$metrics_sec"
  printf 'full_test=%s\n' "$full_test"
  printf 'profiles=%s\n' "$((IFS=','; echo "${profile_list[*]}"))"
  printf 'rounds=%s\n' "$rounds"
  printf 'flutter=%s\n' "$flutter_cmd"
  printf 'host=%s\n' "$(hostname 2>/dev/null || true)"
  printf 'kernel=%s\n' "$(uname -a 2>/dev/null || true)"
} > "$config_file"

summary_file="$output_dir/summary.tsv"
printf 'round\tprofile\tcase\tresetOnRelease\texit_status\tlog\n' > "$summary_file"

run_case() {
  local round_name=$1
  local prof=$2
  local reset_value=$3
  local case_name=$4
  local case_dir="$output_dir/$prof/$round_name"
  local log_file="$case_dir/${case_name}.log"
  local start_file="$case_dir/${case_name}.start.txt"
  local end_file="$case_dir/${case_name}.end.txt"
  local status

  mkdir -p "$case_dir"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$start_file"
  printf '\n=== profile=%s round=%s case=%s resetOnRelease=%s ===\n' \
    "$prof" "$round_name" "$case_name" "$reset_value"
  set +e
  (
    cd example || exit 125
    # dumpDir is resolved relative to example/ cwd; use absolute path
    "$flutter_cmd" test test/soak_stress_test.dart \
      --timeout none \
      --dart-define="SOAK_DURATION_SEC=$duration_sec" \
      --dart-define="SOAK_POOL_SIZE=$pool_size" \
      --dart-define="SOAK_WORKERS=$workers" \
      --dart-define="SOAK_OPS_PER_BURST=$ops_per_burst" \
      --dart-define="SOAK_METRICS_SEC=$metrics_sec" \
      --dart-define="SOAK_PROFILE=$prof" \
      --dart-define="SOAK_RESET_ON_RELEASE=$reset_value" \
      --dart-define="SOAK_MAX_RSS_GROWTH=$rss_factor" \
      --dart-define="SOAK_DUMP_DIR=$case_dir/${case_name}_dumps"
  ) > >(tee "$log_file") 2>&1
  status=$?
  set -e
  date -u +%Y-%m-%dT%H:%M:%SZ > "$end_file"
  printf 'profile=%s round=%s case=%s resetOnRelease=%s exit_status=%s log=%s\n' \
    "$prof" "$round_name" "$case_name" "$reset_value" "$status" "$log_file" |
    tee -a "$log_file"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round_name" "$prof" "$case_name" "$reset_value" "$status" "$log_file" >> "$summary_file"
  return "$status"
}

overall_status=0
for prof in "${profile_list[@]}"; do
  [[ -n "$prof" ]] || continue
  for ((round=1; round<=rounds; round++)); do
    printf -v round_name 'round-%02d' "$round"
    run_case "$round_name" "$prof" 1 reset_on || overall_status=1
    run_case "$round_name" "$prof" 0 reset_off || overall_status=1
  done
done

if [[ "$do_plot" -eq 1 ]]; then
  report_dir="$output_dir/report"
  printf '\nGenerating charts under %s ...\n' "$report_dir"
  if plot_metrics "$output_dir" "$report_dir" "Soak full_test $(basename "$output_dir")"; then
    printf 'Charts: %s/index.html\n' "$report_dir"
  else
    printf 'Chart generation failed (non-fatal).\n' >&2
  fi
fi

printf '\nA/B results are in %s\n' "$output_dir"
printf 'Configuration: %s\n' "$config_file"
printf 'Summary: %s\n' "$summary_file"
printf 'Overall exit status: %s\n' "$overall_status"
exit "$overall_status"
