# Sourced by owner-only shell scripts (#1844): sets SM_REPO and SM_OPS_HOME from scripts/sm_paths.py,
# so a shell script and a Python script resolve the public checkout and the state folder the same way.
#
#   sm_paths_dir=$(cd "$(dirname "$0")" && pwd)     # the folder holding sm_paths.py (set it before sourcing)
#   . "$sm_paths_dir/sm_paths.sh"
#   "$SM_REPO/scripts/verify-tests.py" ...; log="$SM_OPS_HOME/my-job/log.txt"
#
# An SM_REPO or SM_OPS_HOME already set wins. Works in sh, bash and zsh.
: "${sm_paths_dir:?set sm_paths_dir to the folder holding sm_paths.py before sourcing sm_paths.sh}"
SM_REPO=$(SM_REPO="${SM_REPO:-}" python3 "$sm_paths_dir/sm_paths.py" repo --anchor "$sm_paths_dir/sm_paths.py") || return 1
SM_OPS_HOME=$(SM_OPS_HOME="${SM_OPS_HOME:-}" python3 "$sm_paths_dir/sm_paths.py" ops-home) || return 1
export SM_REPO SM_OPS_HOME
