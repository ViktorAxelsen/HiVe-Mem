#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/ppo.sh <prepare|train|all> --benchmark <memgallery|h2hmem|wma|all> --gpu <index>
  prepare  Prepare queries, memories, graphs and strict GVV audits.
  train    Wait for prepared inputs, then train, select and evaluate checkpoints.
  all      Prepare and train each selected benchmark sequentially.
Logs: logs/; resume state: outputs/ppo/status/.
HIVE_PPO_RUNTIME_ROOT overrides the resume-state root (default: outputs/ppo).
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
hive_mode="${1:-}"
case "$hive_mode" in prepare|train|all) shift ;; *) usage >&2; exit 2 ;; esac
hive_selected= hive_gpu=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; hive_selected="$2"; shift 2 ;;
    --gpu) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; hive_gpu="$2"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$hive_selected" in memgallery|h2hmem|wma|all) ;; *) usage >&2; exit 2 ;; esac
[[ "$hive_gpu" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi
export HIVE_CUDA_VISIBLE_DEVICES="$hive_gpu" CUDA_VISIBLE_DEVICES="$hive_gpu"
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
export HIVE_OUTPUT_ROOT="${HIVE_OUTPUT_ROOT:-$PWD/outputs}"
HIVE_PYTHON="${HIVE_PYTHON:-python}"
hive_runtime="${HIVE_PPO_RUNTIME_ROOT:-$PWD/outputs/ppo}"
hive_status_dir="$hive_runtime/status"
mkdir -p logs "$hive_status_dir"
hive_benchmarks=("$hive_selected")
if [[ "$hive_selected" == all ]]; then hive_benchmarks=(memgallery h2hmem wma); fi

step() {
  hive_stage="$1"; shift
  printf '%s %s GPU=%s\n' "$(date -Is)" "$hive_stage" "$hive_gpu" > "$hive_current"
  { printf '%s ' "$(date -Is)"; printf '%q ' "$@"; printf '\n'; } >> "logs/ppo-$hive_benchmark.commands.log"
  "$@"
}

prepare_stage() {
  local hive_name="$1"; shift
  if [[ -f "$hive_status_dir/$hive_name.ok" ]]; then echo "Already complete: $hive_name"; return; fi
  step "$hive_name" "$@"
  touch "$hive_status_dir/$hive_name.ok"
}

# Subshells isolate each benchmark's log redirection, traps and file lock.
for hive_benchmark in "${hive_benchmarks[@]}"; do (
  export HIVE_POLICY_BENCHMARK="$hive_benchmark"
  case "$hive_benchmark" in
    memgallery) hive_label=Mem-Gallery ;;
    h2hmem) hive_label=H2HMEM ;;
    wma) hive_label=WorldMemArena ;;
  esac
  hive_current="$hive_status_dir/ppo-$hive_benchmark.current"
  hive_stage=initializing
  exec > >(tee -a "logs/ppo-$hive_benchmark.log") 2>&1
  trap 'rc=$?; printf "failed rc=%s stage=%s line=%s\n" "$rc" "$hive_stage" "$LINENO" > "$hive_current"; if [[ "$hive_stage" == *-"$hive_benchmark" ]]; then printf "%s failed rc=%s\n" "$hive_stage" "$rc" > "$hive_status_dir/ppo-inputs-$hive_benchmark.failed"; fi; exit "$rc"' ERR

  if [[ "$hive_mode" == train && ! -f "$hive_status_dir/ppo-$hive_benchmark.ok" ]]; then
    printf 'waiting_for_full_inputs GPU=%s\n' "$hive_gpu" > "$hive_current"
    while [[ ! -f "$hive_status_dir/ppo-inputs-$hive_benchmark.ready" ]]; do
      if [[ -f "$hive_status_dir/ppo-inputs-$hive_benchmark.failed" || -f "$hive_status_dir/ppo-inputs.failed" ]]; then
        echo 'Input preparation failed; inspect the status and logs.' >&2; exit 1
      fi
      sleep 10
    done
  fi
  exec {hive_lock}> "$hive_status_dir/ppo-$hive_benchmark.lock"
  flock "$hive_lock"

  if [[ "$hive_mode" != train ]]; then
    prepare_stage "queries-$hive_benchmark" ./scripts/run.sh --no-env prepare queries --benchmark "$hive_benchmark" --devices cuda:0 --local-files-only
    prepare_stage "build-$hive_benchmark" ./scripts/run.sh --no-env build --benchmark "$hive_benchmark" --all-datasets
    prepare_stage "graph-$hive_benchmark" ./scripts/run.sh --no-env graph --degree-cap 4 "$HIVE_OUTPUT_ROOT/memory/$hive_benchmark"/datasets/*
    prepare_stage "gvv-$hive_benchmark" ./scripts/run.sh --no-env gvv extract --dataset "$hive_label"
    prepare_stage "gvv-audit-$hive_benchmark" "$HIVE_PYTHON" -m evidence_policy.cli --benchmark "$hive_benchmark" audit-gvv
    touch "$hive_status_dir/ppo-inputs-$hive_benchmark.ready"
    rm -f -- "$hive_status_dir/ppo-inputs-$hive_benchmark.failed"
  fi
  if [[ "$hive_mode" == prepare ]]; then exit 0; fi
  if [[ -f "$hive_status_dir/ppo-$hive_benchmark.ok" ]]; then echo "Already complete: PPO $hive_benchmark"; exit 0; fi
  step gvv-audit "$HIVE_PYTHON" -m evidence_policy.cli --benchmark "$hive_benchmark" audit-gvv
  step train ./scripts/run.sh --no-env train --benchmark "$hive_benchmark" --device cuda:0
  step eval-ppo ./scripts/run.sh --no-env eval policy --benchmark "$hive_benchmark" --strategy ppo --split test --device cuda:0 --checkpoint "$HIVE_OUTPUT_ROOT/evidence_policy/$hive_benchmark/checkpoints/best.pt"
  step eval-full-evidence ./scripts/run.sh --no-env eval policy --benchmark "$hive_benchmark" --strategy full-evidence --split test --device cuda:0
  step judge-ppo ./scripts/run.sh --no-env judge --benchmark "$hive_benchmark" --results "$HIVE_OUTPUT_ROOT/evidence_policy/$hive_benchmark/eval/test_ppo/results.json" --out-dir "$HIVE_OUTPUT_ROOT/judge/$hive_benchmark/ppo"
  step judge-full-evidence ./scripts/run.sh --no-env judge --benchmark "$hive_benchmark" --results "$HIVE_OUTPUT_ROOT/evidence_policy/$hive_benchmark/eval/test_full-evidence/results.json" --out-dir "$HIVE_OUTPUT_ROOT/judge/$hive_benchmark/full-evidence"
  step eval-graph ./scripts/run.sh --no-env eval --benchmark "$hive_label"
  printf '%s complete GPU=%s\n' "$(date -Is)" "$hive_gpu" > "$hive_current"
  touch "$hive_status_dir/ppo-$hive_benchmark.ok"
); done
