# scripts/lib/inventory.sh - read (and, for onboarding, update) deploy/inventory.tsv.
# Source it; needs bash >= 4 (associative arrays). Git Bash and WSL both qualify.
#
#   . "$REPO/scripts/lib/inventory.sh"
#   inv_load                     # fills the INV_* maps below
#   inv_nodes                    # names with status=active, in file order
#   inv_nodes active staged      # names with any of the given statuses
#   inv_nodes all                # every listed name
#   inv_das                      # the DAS / GRANT node (exactly one, must be active)
#   inv_peers_of rpi2            # active names other than rpi2
#   inv_by_addr 0xabc...         # name for an address ("" if none)
#   inv_cap_var rpi4             # TRUST_ADMIN_CAP_RPI4 (the deployment.env variable name)
#   inv_set rpi4 status staged   # rewrite one field in place (onboarding only)
#
# Maps: INV_HOST INV_IP INV_MAC INV_ROLE INV_CSEID INV_DAS INV_STATUS INV_ADDR (keyed by name).
# '-' in the file is returned as "". The file must use LF line endings.

INVENTORY="${INVENTORY:-${REPO:?REPO must be set before sourcing inventory.sh}/deploy/inventory.tsv}"

_inv_die() { echo "FATAL: inventory: $*" >&2; exit 1; }

inv_load() {
  [ -f "$INVENTORY" ] || _inv_die "$INVENTORY not found"
  grep -q $'\r' "$INVENTORY" && _inv_die "$INVENTORY has CRLF line endings"
  declare -gA INV_HOST=() INV_IP=() INV_MAC=() INV_ROLE=() INV_CSEID=() INV_DAS=() INV_STATUS=() INV_ADDR=()
  declare -ga INV_ALL=()
  local name host ip mac role cse das status addr extra header_seen=0
  while IFS=$'\t' read -r name host ip mac role cse das status addr extra; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ "$name" = name ]; then header_seen=1; continue; fi
    [ "$header_seen" = 1 ] || _inv_die "header row missing"
    [ -z "${extra:-}" ] || _inv_die "$name: too many columns"
    [[ "$name" =~ ^[a-z][a-z0-9]*$ ]] || _inv_die "bad node name '$name'"
    [ -z "${INV_IP[$name]:-}" ] || _inv_die "duplicate node $name"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || _inv_die "$name: bad ip '$ip'"
    case "$role" in in-cse|mn-cse) ;; *) _inv_die "$name: role must be in-cse|mn-cse, got '$role'";; esac
    case "$das" in yes|no) ;; *) _inv_die "$name: das must be yes|no";; esac
    case "$status" in pending|staged|active) ;; *) _inv_die "$name: bad status '$status'";; esac
    [ "$addr" = - ] && addr=""
    if [ -n "$addr" ]; then
      [[ "$addr" =~ ^0x[0-9a-f]{64}$ ]] || _inv_die "$name: sui_address must be 0x + 64 lowercase hex"
    fi
    [ "$status" = pending ] || [ -n "$addr" ] || _inv_die "$name: status $status needs a sui_address"
    INV_ALL+=("$name")
    INV_HOST[$name]=$host; INV_IP[$name]=$ip; INV_MAC[$name]=$mac; INV_ROLE[$name]=$role
    INV_CSEID[$name]=$cse; INV_DAS[$name]=$das; INV_STATUS[$name]=$status; INV_ADDR[$name]=$addr
  done < "$INVENTORY"
  [ ${#INV_ALL[@]} -gt 0 ] || _inv_die "no nodes listed"
  local n d=0; for n in "${INV_ALL[@]}"; do [ "${INV_DAS[$n]}" = yes ] && d=$((d + 1)); done
  [ "$d" = 1 ] || _inv_die "exactly one node must have das=yes (found $d)"
}

inv_nodes() {
  local want=("$@") n s
  [ ${#want[@]} -gt 0 ] || want=(active)
  for n in "${INV_ALL[@]}"; do
    if [ "${want[0]}" = all ]; then echo "$n"; continue; fi
    for s in "${want[@]}"; do [ "${INV_STATUS[$n]}" = "$s" ] && { echo "$n"; break; }; done
  done
}

inv_das() {
  local n; for n in "${INV_ALL[@]}"; do
    if [ "${INV_DAS[$n]}" = yes ]; then
      [ "${INV_STATUS[$n]}" = active ] || _inv_die "DAS node $n is not active"
      echo "$n"; return
    fi
  done
}

inv_peers_of() { local n; for n in $(inv_nodes active); do [ "$n" = "$1" ] || echo "$n"; done; }

inv_by_addr() {
  local a=${1,,} n
  for n in "${INV_ALL[@]}"; do [ -n "${INV_ADDR[$n]}" ] && [ "${INV_ADDR[$n]}" = "$a" ] && { echo "$n"; return; }; done
  echo ""
}

inv_cap_var() { echo "TRUST_ADMIN_CAP_${1^^}"; }

inv_require() { [ -n "${INV_IP[$1]:-}" ] || _inv_die "unknown node '$1' (listed: ${INV_ALL[*]})"; }

# inv_set <name> <column> <value> - rewrite one field, keeping everything else byte-for-byte.
inv_set() {
  local name=$1 col=$2 val=$3 idx
  case "$col" in host) idx=2;; ip) idx=3;; mac) idx=4;; role) idx=5;; cse_id) idx=6;; das) idx=7;;
                 status) idx=8;; sui_address) idx=9;; *) _inv_die "inv_set: unknown column $col";; esac
  [ -n "$val" ] || val=-
  inv_require "$name"
  local tmp; tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v n="$name" -v i="$idx" -v v="$val" \
    '/^#/ || $1 != n { print; next } { $i = v; print }' "$INVENTORY" > "$tmp"
  # Validate the candidate BEFORE replacing the real file: a rejected change
  # must leave the inventory untouched.
  ( INVENTORY=$tmp; inv_load ) || { rm -f "$tmp"; _inv_die "inv_set $name $col=$val rejected; $INVENTORY unchanged"; }
  cat "$tmp" > "$INVENTORY"; rm -f "$tmp"
  inv_load
}
