#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/benchmark_frodo.sh [options]

Build and benchmark FrodoKEM implementations in one command. By default it tests
REFERENCE and FAST (x64 AVX2/AES-NI) for FrodoKEM-640/976/1344 using AES128.

Options:
  --variants LIST       Comma-separated variants: reference,fast,fast-generic (default: reference,fast)
  --params LIST         Comma-separated parameter sets: 640,976,1344 (default: 640,976,1344)
  --generation VALUE    AES128 or SHAKE128 for matrix A generation (default: AES128)
  --cc VALUE            C compiler passed to make (default: gcc)
  --use-openssl VALUE   TRUE or FALSE, passed to make (default: TRUE)
  --out DIR             Output directory for logs and summary CSV (default: benchmark-results/<timestamp>)
  --force-fast          Try FAST even if this CPU does not advertise avx2/aes flags
  --no-clean-final      Do not run make clean after all benchmarks complete
  -h, --help            Show this help

Examples:
  scripts/benchmark_frodo.sh
  scripts/benchmark_frodo.sh --variants reference,fast-generic,fast --generation SHAKE128
  scripts/benchmark_frodo.sh --params 640 --cc clang --use-openssl FALSE
USAGE
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FRODO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

variants="reference,fast"
params="640,976,1344"
generation="AES128"
cc="gcc"
use_openssl="TRUE"
out_dir=""
force_fast=0
clean_final=1

while (($#)); do
  case "$1" in
    --variants) variants=${2:?}; shift 2 ;;
    --params) params=${2:?}; shift 2 ;;
    --generation) generation=${2:?}; shift 2 ;;
    --cc) cc=${2:?}; shift 2 ;;
    --use-openssl) use_openssl=${2:?}; shift 2 ;;
    --out) out_dir=${2:?}; shift 2 ;;
    --force-fast) force_fast=1; shift ;;
    --no-clean-final) clean_final=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$generation" in AES128|SHAKE128) ;; *) echo "--generation must be AES128 or SHAKE128" >&2; exit 2 ;; esac
case "$use_openssl" in TRUE|FALSE) ;; *) echo "--use-openssl must be TRUE or FALSE" >&2; exit 2 ;; esac

if [[ -z "$out_dir" ]]; then
  out_dir="${FRODO_DIR}/benchmark-results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out_dir"
summary_csv="${out_dir}/summary.csv"
printf 'variant,param_set,operation,iterations,total_time_s,time_us_mean,time_us_stdev,cycles_mean,cycles_stdev,log_file\n' > "$summary_csv"

IFS=',' read -r -a variant_array <<< "$variants"
IFS=',' read -r -a param_array <<< "$params"

cpu_has_flag() {
  local flag=$1
  if [[ -r /proc/cpuinfo ]]; then
    awk -v flag="$flag" 'BEGIN{found=0} /^flags[[:space:]]*:/{for(i=3;i<=NF;i++) if($i==flag) found=1} END{exit found?0:1}' /proc/cpuinfo
  else
    return 1
  fi
}

fast_supported=0
if cpu_has_flag avx2 && cpu_has_flag aes; then
  fast_supported=1
fi

variant_to_make_args() {
  case "$1" in
    reference) echo "ARCH=x64 OPT_LEVEL=REFERENCE" ;;
    fast-generic) echo "ARCH=x64 OPT_LEVEL=FAST_GENERIC" ;;
    fast) echo "ARCH=x64 OPT_LEVEL=FAST" ;;
    *) echo "Unknown variant '$1'. Use reference, fast, or fast-generic." >&2; return 2 ;;
  esac
}

extract_summary() {
  local variant=$1 param=$2 run_log=$3 rel_log
  rel_log=$(realpath --relative-to="$FRODO_DIR" "$run_log" 2>/dev/null || printf '%s' "$run_log")
  awk -v variant="$variant" -v param="$param" -v logfile="$rel_log" '
    /^(Key generation|KEM encapsulate|KEM decapsulate)[[:space:]]+/ {
      op=$1;
      if ($2 == "generation") op="Key generation";
      else if ($2 == "encapsulate") op="KEM encapsulate";
      else if ($2 == "decapsulate") op="KEM decapsulate";
      iterations=$(NF-5);
      total=$(NF-4);
      time_mean=$(NF-3);
      time_stdev=$(NF-2);
      cycles_mean=$(NF-1);
      cycles_stdev=$NF;
      gsub(/,/, "", op);
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", variant,param,op,iterations,total,time_mean,time_stdev,cycles_mean,cycles_stdev,logfile;
    }
  ' "$run_log" >> "$summary_csv"
}

run_make_clean() {
  make -C "$FRODO_DIR" clean >/dev/null
}

printf 'FrodoKEM benchmark output: %s\n' "$out_dir"
printf 'Compiler: %s | GENERATION_A=%s | USE_OPENSSL=%s | upstream benchmark duration: 1s per operation\n' "$cc" "$generation" "$use_openssl"
if [[ $fast_supported -eq 1 ]]; then
  printf 'CPU check: avx2 and aes flags found; FAST can use AVX2/AES-NI.\n'
else
  printf 'CPU check: avx2 and/or aes flags not found; FAST will be skipped unless --force-fast is used.\n'
fi

for variant in "${variant_array[@]}"; do
  variant=${variant//[[:space:]]/}
  [[ -n "$variant" ]] || continue

  if [[ "$variant" == "fast" && $fast_supported -ne 1 && $force_fast -ne 1 ]]; then
    printf '\n==> Skipping FAST: CPU does not advertise both avx2 and aes. Use --force-fast to try anyway.\n'
    continue
  fi

  make_args=$(variant_to_make_args "$variant")
  printf '\n==> Building variant: %s (%s)\n' "$variant" "$make_args"
  build_log="${out_dir}/${variant}_build.log"
  run_make_clean
  # shellcheck disable=SC2086
  make -C "$FRODO_DIR" CC="$cc" GENERATION_A="$generation" USE_OPENSSL="$use_openssl" $make_args tests 2>&1 | tee "$build_log"

  for param in "${param_array[@]}"; do
    param=${param//[[:space:]]/}
    case "$param" in 640|976|1344) ;; *) echo "Unknown parameter set '$param'. Use 640, 976, or 1344." >&2; exit 2 ;; esac
    exe="${FRODO_DIR}/frodo${param}/test_KEM"
    log="${out_dir}/${variant}_frodo${param}.log"
    printf '\n==> Running %s FrodoKEM-%s benchmark\n' "$variant" "$param"
    "$exe" 2>&1 | tee "$log"
    extract_summary "$variant" "$param" "$log"
  done
done

if [[ $clean_final -eq 1 ]]; then
  run_make_clean
fi

printf '\nSummary CSV: %s\n' "$summary_csv"
printf 'Done. Raw build and run logs are in: %s\n' "$out_dir"
