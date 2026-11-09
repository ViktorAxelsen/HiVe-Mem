#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/install.sh

Create .venv, install HiVe-Mem with all extras, and check dependencies.
HIVE_PYTHON selects the Python executable (default: python3).
HIVE_VENV_DIR selects the virtual environment (default: .venv in this checkout).
Preinstall a matching torch/torchvision build in that environment for a specific GPU platform.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

hive_project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hive_python="${HIVE_PYTHON:-python3}"
hive_venv_dir="${HIVE_VENV_DIR:-$hive_project_root/.venv}"
cd -- "$hive_project_root"

"$hive_python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "HiVe-Mem requires Python 3.10 or newer.")'
if [[ ! -f "$hive_venv_dir/pyvenv.cfg" ]]; then
  if [[ -e "$hive_venv_dir" ]]; then
    printf 'Not a virtual environment: %s\n' "$hive_venv_dir" >&2
    exit 1
  fi
  "$hive_python" -m venv "$hive_venv_dir"
fi
hive_venv_python="$hive_venv_dir/bin/python"
hive_activate="$hive_venv_dir/bin/activate"
if [[ ! -x "$hive_venv_python" ]]; then
  printf 'Virtual environment has no Python executable: %s\n' "$hive_venv_dir" >&2
  exit 1
fi

"$hive_venv_python" -m pip install --upgrade pip
"$hive_venv_python" -m pip install --editable ".[eval,train,embedding,data]"
"$hive_venv_python" -m pip check
"$hive_venv_python" -m embedding.cli check --group eval --group train --group embedding --group data
"$hive_venv_python" -c 'from transformers import AutoProcessor, Qwen3VLForConditionalGeneration, Qwen3VLVideoProcessor; Qwen3VLVideoProcessor(); print("Qwen3-VL dependencies OK")'

printf '\nInstallation complete. Activate with:\n  source %q\n' "$hive_activate"
