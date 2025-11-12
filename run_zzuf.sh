#!/usr/bin/env bash
# run_zzuf - tmux-persistent dav1d fuzz harness with session management
#
# Usage:
#   ./run_zzuf                    # Start new fuzzing session
#   ./run_zzuf list               # List all sessions
#   ./run_zzuf pause <session>    # Pause a running session
#   ./run_zzuf continue <session> # Continue a paused session
#   ./run_zzuf stop <session>     # Stop a session
#   ./run_zzuf attach <session>   # Attach to a running session
#
# Requirements:
#   tmux, python3, python 'rich' package (pip install --user rich)
#
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
STATE_DIR="${HOME}/.zzuf_sessions"
mkdir -p "$STATE_DIR"

### -----------------
### Session Management Functions
### -----------------

get_session_state() {
    local session=$1
    local state_file="${STATE_DIR}/${session}.state"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

set_session_state() {
    local session=$1
    local state=$2
    echo "$state" > "${STATE_DIR}/${session}.state"
}

list_sessions() {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    Fuzzing Sessions                            ║"
    echo "╠════════════════════════════════════════════╤═══════════════════╣"
    printf "║ %-42s │ %-17s ║\n" "Session Name" "State"
    echo "╠════════════════════════════════════════════╪═══════════════════╣"
    
    local found=0
    while IFS=: read -r session _; do
        if [[ $session == fuzz_* ]]; then
            local state=$(get_session_state "$session")
            local tmux_running=$(tmux has-session -t "$session" 2>/dev/null && echo "yes" || echo "no")
            
            if [ "$tmux_running" = "no" ]; then
                state="stopped"
            elif [ "$state" = "unknown" ]; then
                state="running"
            fi
            
            printf "║ %-42s │ %-17s ║\n" "$session" "$state"
            found=1
        fi
    done < <(tmux ls 2>/dev/null || echo "")
    
    if [ $found -eq 0 ]; then
        printf "║ %-42s │ %-17s ║\n" "No sessions found" ""
    fi
    
    echo "╚════════════════════════════════════════════╧═══════════════════╝"
    exit 0
}

attach_session() {
    local session=$1
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "[ERROR] Session '$session' does not exist"
        exit 1
    fi
    echo "Attaching to session '$session'..."
    echo "To detach safely: Press Ctrl+B, then D (not Ctrl+C)"
    exec tmux attach -t "$session"
}

pause_session() {
    local session=$1
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "[ERROR] Session '$session' does not exist"
        exit 1
    fi
    
    local state=$(get_session_state "$session")
    if [ "$state" = "paused" ]; then
        echo "[WARN] Session '$session' is already paused"
        exit 0
    fi
    
    if [ "$state" = "stopped" ]; then
        echo "[ERROR] Cannot pause a stopped session"
        exit 1
    fi
    
    # Find and pause the main fuzzing process
    local session_pid=$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1)
    if [ -n "$session_pid" ]; then
        pkill -STOP -P "$session_pid" 2>/dev/null || true
    fi
    
    set_session_state "$session" "paused"
    echo "[INFO] Session '$session' paused"
    exit 0
}

continue_session() {
    local session=$1
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "[ERROR] Session '$session' does not exist"
        exit 1
    fi
    
    local state=$(get_session_state "$session")
    if [ "$state" = "stopped" ]; then
        echo "[ERROR] Cannot continue a stopped session. Start a new one instead."
        exit 1
    fi
    
    if [ "$state" != "paused" ]; then
        echo "[WARN] Session '$session' is not paused (state: $state)"
        exit 0
    fi
    
    # Resume the paused process
    local session_pid=$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1)
    if [ -n "$session_pid" ]; then
        pkill -CONT -P "$session_pid" 2>/dev/null || true
    fi
    
    set_session_state "$session" "running"
    echo "[INFO] Session '$session' resumed"
    exit 0
}

stop_session() {
    local session=$1
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "[ERROR] Session '$session' does not exist"
        exit 1
    fi
    
    # Send SIGINT to gracefully stop
    tmux send-keys -t "$session" C-c 2>/dev/null
    sleep 2
    set_session_state "$session" "stopped"
    echo "[INFO] Session '$session' stopped"
    echo "[INFO] You can kill the tmux session with: tmux kill-session -t $session"
    exit 0
}

### -----------------
### Command Handler
### -----------------

case "${1:-}" in
    list)
        list_sessions
        ;;
    attach)
        if [ -z "${2:-}" ]; then
            echo "[ERROR] Usage: $0 attach <session_name>"
            exit 1
        fi
        attach_session "$2"
        ;;
    pause)
        if [ -z "${2:-}" ]; then
            echo "[ERROR] Usage: $0 pause <session_name>"
            exit 1
        fi
        pause_session "$2"
        ;;
    continue)
        if [ -z "${2:-}" ]; then
            echo "[ERROR] Usage: $0 continue <session_name>"
            exit 1
        fi
        continue_session "$2"
        ;;
    stop)
        if [ -z "${2:-}" ]; then
            echo "[ERROR] Usage: $0 stop <session_name>"
            exit 1
        fi
        stop_session "$2"
        ;;
    --inside-tmux)
        # Continue to main fuzzing logic
        shift
        ;;
    "")
        # Continue to main fuzzing logic (default action)
        ;;
    *)
        echo "Usage: $0 [list|attach|pause|continue|stop] [session_name]"
        echo ""
        echo "Commands:"
        echo "  (no args)             Start new fuzzing session"
        echo "  list                  List all sessions and their states"
        echo "  attach <session>      Attach to a running session"
        echo "  pause <session>       Pause a running session"
        echo "  continue <session>    Continue a paused session"
        echo "  stop <session>        Stop a session"
        exit 1
        ;;
esac

### -----------------
### tmux auto-launch wrapper
### -----------------
if [ -z "${TMUX:-}" ]; then
    if command -v tmux >/dev/null 2>&1; then
        SESSION_BASE="fuzz"
        NEW_SESSION="${SESSION_BASE}_$(date +%Y%m%d_%H%M%S)"
        echo "Creating tmux session: $NEW_SESSION"
        echo "To detach safely: Press Ctrl+B, then D (not Ctrl+C)"
        echo ""
        sleep 2
        tmux new-session -d -s "$NEW_SESSION" bash -lc "\"$SCRIPT_PATH\" --inside-tmux; exec bash"
        set_session_state "$NEW_SESSION" "running"
        exec tmux attach -t "$NEW_SESSION"
    else
        echo "[WARN] tmux not found. Running without tmux."
    fi
fi

### ---------------------
### CONFIG
### ---------------------
SAMPLES_DIR="samples"
RUNS_DIR="runs"
STATS_DIR="stats"
DAV1D_BIN="./dav1d"
OUTPUT_FILE="file.null"

MUTANTS_SUB="mutants"
CRASH_SUB="crashed_mutants"
HANG_SUB="hanging_mutants"
INTENTIONAL_SUB="intentional_crashes"

MUTATION_LEVEL="0.01"
TIMEOUT_SECS=5
MUTANTS_PER_SAMPLE=50
DELETE_AFTER_RUN=true
MAX_MUTANTS_KEEP=2000

INTENTIONAL_CODES=(0 50 -12 -22 1 -1)
INTENTIONAL_LIMIT=5000

STATUS_EVERY_N_MUTANTS=100  # Reduced from 5 to prevent flickering
STATS_ROTATE_MINUTES=10

### ---------------------
### Setup
### ---------------------
export TERM="${TERM:-xterm-256color}"

RUN_TAG="run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RUNS_DIR}/${RUN_TAG}"

mkdir -p "$RUN_DIR"
mkdir -p "$RUN_DIR/$MUTANTS_SUB" "$RUN_DIR/$CRASH_SUB" "$RUN_DIR/$HANG_SUB" "$RUN_DIR/$INTENTIONAL_SUB"
mkdir -p "$STATS_DIR"

MUTANTS_DIR="${RUN_DIR}/${MUTANTS_SUB}"
CRASH_DIR="${RUN_DIR}/${CRASH_SUB}"
HANG_DIR="${RUN_DIR}/${HANG_SUB}"
INTENTIONAL_DIR="${RUN_DIR}/${INTENTIONAL_SUB}"

start_time=$(date +%s)
last_stats_save=$start_time

total_samples=0
total_mutants=0
crashes=0
hangs=0
declare -A intentional_counts
for code in "${INTENTIONAL_CODES[@]}"; do
    intentional_counts[$code]=0
done
last_discovery=$start_time

### ---------------------
### Helpers
### ---------------------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

write_stats() {
    local now runtime stats_file
    now=$(date +%Y%m%d_%H%M%S)
    runtime=$(( $(date +%s) - start_time ))
    stats_file="${STATS_DIR}/stats_${RUN_TAG}_${now}.txt"
    {
        echo "=== zzuf fuzzing stats (${RUN_TAG}) ==="
        echo "Timestamp: $(timestamp)"
        echo "Run dir: $RUN_DIR"
        echo "Total samples: $total_samples"
        echo "Total mutants: $total_mutants"
        echo "Crashes: $crashes"
        echo "Hangs: $hangs"
        for code in "${INTENTIONAL_CODES[@]}"; do
            echo "Intentional code $code: ${intentional_counts[$code]:-0}"
        done
        echo "Runtime (s): $runtime"
        echo "Mutation level: $MUTATION_LEVEL"
        echo "Mutants per sample: $MUTANTS_PER_SAMPLE"
    } > "$stats_file"
    printf "[%s] [STATS] Saved: %s\n" "$(timestamp)" "$stats_file"
}

on_exit() {
    printf "\n[%s] [EXIT] Saving final stats...\n" "$(timestamp)"
    write_stats
    # Mark session as stopped
    if [ -n "${TMUX:-}" ]; then
        session_name=$(tmux display-message -p '#S' 2>/dev/null || echo "")
        if [ -n "$session_name" ]; then
            set_session_state "$session_name" "stopped"
        fi
    fi
    printf "[%s] [EXIT] Done. Session can be safely closed.\n" "$(timestamp)"
    exit 0
}
trap on_exit SIGINT SIGTERM

### ---------------------
### Prerequisites
### ---------------------
if ! command -v python3 >/dev/null 2>&1; then
    printf "[%s] [ERROR] python3 not found.\n" "$(timestamp)"
    exit 1
fi

if ! python3 - <<'PY' 2>/dev/null
import importlib, sys
if importlib.util.find_spec("rich") is None:
    sys.exit(2)
sys.exit(0)
PY
then
    printf "[%s] [WARN] Python 'rich' not found. Install: pip install --user rich\n" "$(timestamp)"
fi

### ---------------------
### Gather samples
### ---------------------
mapfile -t samples < <(find "$SAMPLES_DIR" -maxdepth 1 -type f -name "*.ivf" | sort)
total_samples=${#samples[@]}
if [ $total_samples -eq 0 ]; then
    printf "[%s] [ERROR] No .ivf files in %s\n" "$(timestamp)" "$SAMPLES_DIR"
    exit 1
fi
printf "[%s] [INFO] Found %d samples. Run: %s\n" "$(timestamp)" "$total_samples" "$RUN_DIR"

### ---------------------
### Render status
### ---------------------
render_status() {
    python3 - "$total_mutants" "$crashes" "$hangs" "${INTENTIONAL_CODES[*]}" "$(printf "%s " "${intentional_counts[@]}")" "$(( $(date +%s) - start_time ))" "$(( $(date +%s) - last_discovery ))" "$RUN_TAG" "$total_samples" <<'PY_EOF'
import sys
from rich.console import Console
from rich.table import Table
from rich.layout import Layout
from rich.panel import Panel

console = Console()
try:
    total_mutants = int(sys.argv[1])
    crashes = int(sys.argv[2])
    hangs = int(sys.argv[3])
    codes = sys.argv[4].split()
    counts = [int(x) if x.strip() else 0 for x in sys.argv[5].split()]
    runtime_s = int(sys.argv[6])
    since_last_s = int(sys.argv[7])
    run_tag = sys.argv[8]
    total_samples = int(sys.argv[9])
except Exception as e:
    console.print("[red]Error:[/red]", e)
    sys.exit(0)

def secs_to_human(s):
    h = s // 3600
    m = (s % 3600) // 60
    sec = s % 60
    if h > 0:
        return f"{h:02d}h{m:02d}m{sec:02d}s"
    elif m > 0:
        return f"{m:02d}m{sec:02d}s"
    else:
        return f"{sec:02d}s"

def make_bar(count, max_val=500):
    filled = min(int(count / max_val * 20), 20)
    return '█' * filled + '░' * (20 - filled)

console.clear()

# Main stats table
main_table = Table(show_header=True, header_style="bold magenta", 
                   border_style="cyan", title_style="bold cyan")
main_table.add_column("Metric", style="cyan", no_wrap=True, width=25)
main_table.add_column("Value", justify="right", style="green", width=15)
main_table.add_column("Visual", style="blue", width=25)

main_table.add_row("Session", run_tag, "")
main_table.add_row("Samples Loaded", str(total_samples), "")
main_table.add_row("Total Mutants", str(total_mutants), make_bar(total_mutants, 10000))
main_table.add_row("Crashes", f"[red bold]{crashes}[/red bold]" if crashes > 0 else str(crashes), make_bar(crashes, 100))
main_table.add_row("Hangs", f"[yellow bold]{hangs}[/yellow bold]" if hangs > 0 else str(hangs), make_bar(hangs, 100))
main_table.add_row("Runtime", secs_to_human(runtime_s), "")
main_table.add_row("Since Last Find", secs_to_human(since_last_s), "")

console.print(Panel(main_table, title="[bold cyan]Fuzzing Status[/bold cyan]", border_style="cyan"))
console.print()

# Intentional codes table
codes_table = Table(show_header=True, header_style="bold yellow",
                    border_style="yellow", title_style="bold yellow")
codes_table.add_column("Exit Code", justify="right", style="cyan", no_wrap=True, width=12)
codes_table.add_column("Count", justify="right", style="green", width=10)
codes_table.add_column("Progress", style="blue", width=25)

for c, cnt in zip(codes, counts):
    display = min(cnt, 9999)
    codes_table.add_row(str(c), str(display), make_bar(cnt, 1000))

console.print(Panel(codes_table, title="[bold yellow]Intentional Exit Codes[/bold yellow]", border_style="yellow"))
PY_EOF
}

render_status

### ---------------------
### Main fuzz loop
### ---------------------
while true; do
    for sample in "${samples[@]}"; do
        base=$(basename "$sample" .ivf)

        for ((i=0; i<MUTANTS_PER_SAMPLE; i++)); do
            mutant="${MUTANTS_DIR}/${base}_${RANDOM}_${RANDOM}.ivf"

            if ! zzuf -r "$MUTATION_LEVEL" -s "$RANDOM" < "$sample" > "$mutant" 2>/dev/null; then
                rm -f "$mutant" 2>/dev/null || true
                continue
            fi

            ((total_mutants++))

            stdbuf -o0 timeout "$TIMEOUT_SECS" "$DAV1D_BIN" -i "$mutant" -o "$OUTPUT_FILE" &>/dev/null
            status=$?

            if [ $status -eq 124 ]; then
                cp -f "$mutant" "$HANG_DIR/" 2>/dev/null || true
                ((hangs++))
                last_discovery=$(date +%s)
            else
                is_intentional=false
                for code in "${INTENTIONAL_CODES[@]}"; do
                    if [ "$status" -eq "$code" ]; then
                        is_intentional=true
                        current=${intentional_counts[$code]:-0}
                        if [ "$current" -lt "$INTENTIONAL_LIMIT" ]; then
                            mkdir -p "${INTENTIONAL_DIR}/${code}"
                            cp -f "$mutant" "${INTENTIONAL_DIR}/${code}/" 2>/dev/null || true
                            intentional_counts[$code]=$(( current + 1 ))
                            last_discovery=$(date +%s)
                        fi
                        break
                    fi
                done

                if [ "$is_intentional" = false ] && [ "$status" -ne 0 ]; then
                    cp -f "$mutant" "$CRASH_DIR/" 2>/dev/null || true
                    ((crashes++))
                    last_discovery=$(date +%s)
                fi
            fi

            if [ "$DELETE_AFTER_RUN" = true ]; then
                rm -f "$mutant" 2>/dev/null || true
            fi

            if (( total_mutants % STATUS_EVERY_N_MUTANTS == 0 )); then
                render_status
            fi

            now_ts=$(date +%s)
            if (( now_ts - last_stats_save >= STATS_ROTATE_MINUTES * 60 )); then
                write_stats
                last_stats_save=$now_ts
            fi
        done
    done
done