#!/bin/bash

# Continuous Memory Monitor with Real-Time TUI
# Run with sudo for full system access
# Usage: sudo ./memory_monitor_continuous.sh [interval_seconds]

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Bar characters
BAR_FULL='█'
BAR_HALF='▌'
BAR_EMPTY='─'

# Helper: convert float to int (multiply by 10 to keep 1 decimal precision)
float_to_int() {
    local val=$1
    [[ -z "$val" || "$val" == "N/A" ]] && echo "0" && return
    local int_part="${val%%.*}"
    local dec_part="${val#*.}"
    [[ "$dec_part" == "$val" ]] && dec_part="0"
    dec_part="${dec_part:0:1}"
    [[ -z "$dec_part" ]] && dec_part="0"
    echo "$((int_part * 10 + dec_part))"
}

# Get memory gradient color (green < 50%, yellow 50-80%, red > 80%)
get_mem_gradient_color() {
    local pct_int=$1
    if [[ $pct_int -ge 900 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;196m'  # Bright red (>=90%)
    elif [[ $pct_int -ge 800 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;202m'  # Red-orange (80-90%)
    elif [[ $pct_int -ge 700 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;208m'  # Orange (70-80%)
    elif [[ $pct_int -ge 600 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;214m'  # Orange-yellow (60-70%)
    elif [[ $pct_int -ge 500 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;226m'  # Yellow (50-60%)
    elif [[ $pct_int -ge 400 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;154m'  # Yellow-green (40-50%)
    elif [[ $pct_int -ge 300 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;118m'  # Light green (30-40%)
    elif [[ $pct_int -ge 200 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;46m'   # Green (20-30%)
    elif [[ $pct_int -ge 100 ]]; then
        MEM_GRADIENT_COLOR=$'\e[38;5;43m'   # Teal (10-20%)
    else
        MEM_GRADIENT_COLOR=$'\e[38;5;51m'   # Cyan (<10%)
    fi
}

# Function to draw a memory usage bar
draw_bar() {
    local value=$1
    local max_value=$2
    local width=${3:-20}
    local use_gradient=${4:-1}

    if [[ "$value" == "N/A" || -z "$value" ]]; then
        printf "%${width}s" "-"
        return
    fi

    local value_int=$(float_to_int "$value")
    local max_int=$((max_value * 10))
    local filled=$(( (value_int * width) / max_int ))
    [[ $filled -gt $width ]] && filled=$width
    [[ $filled -lt 0 ]] && filled=0

    local bar_color
    if [[ $use_gradient -eq 1 ]]; then
        get_mem_gradient_color "$value_int"
        bar_color="$MEM_GRADIENT_COLOR"
    else
        if [[ $value_int -ge 800 ]]; then
            bar_color=$RED
        elif [[ $value_int -ge 500 ]]; then
            bar_color=$YELLOW
        else
            bar_color=$GREEN
        fi
    fi

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do
        bar+="$BAR_FULL"
    done
    for ((i=filled; i<width; i++)); do
        bar+="$BAR_EMPTY"
    done

    echo -ne "${bar_color}${bar}${NC}"
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)K"
    else
        echo "${bytes}B"
    fi
}

# Format KB to human readable
format_kb() {
    local kb=$1
    if [[ $kb -ge 1048576 ]]; then
        echo "$(echo "scale=1; $kb / 1048576" | bc)G"
    elif [[ $kb -ge 1024 ]]; then
        echo "$(echo "scale=1; $kb / 1024" | bc)M"
    else
        echo "${kb}K"
    fi
}

# Ring buffer for memory history (for timeline visualization)
declare -a MEM_RING_COLORS=()
declare -a SWAP_RING_COLORS=()
declare -i RING_MAX_SIZE=200

# Pre-built colored blocks for fast drawing
declare -a MEM_BLOCKS=()
declare BLOCK_DIM=""

init_color_blocks() {
    local block='█'
    MEM_BLOCKS[0]=$'\e[38;5;51m'"$block"$'\e[0m'   # Cyan (<10%)
    MEM_BLOCKS[1]=$'\e[38;5;43m'"$block"$'\e[0m'   # Teal (10-20%)
    MEM_BLOCKS[2]=$'\e[38;5;46m'"$block"$'\e[0m'   # Green (20-30%)
    MEM_BLOCKS[3]=$'\e[38;5;118m'"$block"$'\e[0m'  # Light green (30-40%)
    MEM_BLOCKS[4]=$'\e[38;5;154m'"$block"$'\e[0m'  # Yellow-green (40-50%)
    MEM_BLOCKS[5]=$'\e[38;5;226m'"$block"$'\e[0m'  # Yellow (50-60%)
    MEM_BLOCKS[6]=$'\e[38;5;214m'"$block"$'\e[0m'  # Orange-yellow (60-70%)
    MEM_BLOCKS[7]=$'\e[38;5;208m'"$block"$'\e[0m'  # Orange (70-80%)
    MEM_BLOCKS[8]=$'\e[38;5;202m'"$block"$'\e[0m'  # Red-orange (80-90%)
    MEM_BLOCKS[9]=$'\e[38;5;196m'"$block"$'\e[0m'  # Red (>=90%)
    BLOCK_DIM="${DIM}─${NC}"
}

# Convert percentage to color code (0-9)
pct_to_color_code() {
    local pct_int=$1
    if [[ $pct_int -ge 900 ]]; then echo "9"
    elif [[ $pct_int -ge 800 ]]; then echo "8"
    elif [[ $pct_int -ge 700 ]]; then echo "7"
    elif [[ $pct_int -ge 600 ]]; then echo "6"
    elif [[ $pct_int -ge 500 ]]; then echo "5"
    elif [[ $pct_int -ge 400 ]]; then echo "4"
    elif [[ $pct_int -ge 300 ]]; then echo "3"
    elif [[ $pct_int -ge 200 ]]; then echo "2"
    elif [[ $pct_int -ge 100 ]]; then echo "1"
    else echo "0"
    fi
}

# Add memory percentage to ring buffer
add_mem_to_ring() {
    local pct=$1
    local pct_int=$(float_to_int "$pct")
    local code=$(pct_to_color_code "$pct_int")
    MEM_RING_COLORS+=("$code")
    if [[ ${#MEM_RING_COLORS[@]} -gt $RING_MAX_SIZE ]]; then
        MEM_RING_COLORS=("${MEM_RING_COLORS[@]: -$RING_MAX_SIZE}")
    fi
}

# Add swap percentage to ring buffer
add_swap_to_ring() {
    local pct=$1
    local pct_int=$(float_to_int "$pct")
    local code=$(pct_to_color_code "$pct_int")
    SWAP_RING_COLORS+=("$code")
    if [[ ${#SWAP_RING_COLORS[@]} -gt $RING_MAX_SIZE ]]; then
        SWAP_RING_COLORS=("${SWAP_RING_COLORS[@]: -$RING_MAX_SIZE}")
    fi
}

# Draw memory history timeline
draw_mem_history() {
    local -n ring_ref=$1
    local width=$2
    local num_codes=${#ring_ref[@]}
    local start_idx=0

    if [[ $num_codes -gt $width ]]; then
        start_idx=$((num_codes - width))
    fi

    local bar=""
    local drawn=0
    local i code
    for ((i=start_idx; i<num_codes && drawn<width; i++)); do
        code="${ring_ref[$i]}"
        if [[ "$code" =~ ^[0-9]$ ]]; then
            bar+="${MEM_BLOCKS[$code]}"
        else
            bar+="$BLOCK_DIM"
        fi
        ((drawn++))
    done

    local remaining=$((width - drawn))
    while [[ $remaining -gt 0 ]]; do
        bar+="$BLOCK_DIM"
        ((remaining--))
    done

    echo -ne "$bar"
}

# Get memory info from /proc/meminfo (all values in KB)
declare -A MEMINFO=()
update_meminfo() {
    while IFS=': ' read -r key value _; do
        MEMINFO[$key]=$value
    done < /proc/meminfo
}

# Calculate memory percentages
get_mem_stats() {
    local total=${MEMINFO[MemTotal]:-1}
    local free=${MEMINFO[MemFree]:-0}
    local available=${MEMINFO[MemAvailable]:-$free}
    local buffers=${MEMINFO[Buffers]:-0}
    local cached=${MEMINFO[Cached]:-0}
    local slab=${MEMINFO[SReclaimable]:-0}

    local used=$((total - available))
    local buff_cache=$((buffers + cached + slab))

    MEM_TOTAL_KB=$total
    MEM_USED_KB=$used
    MEM_FREE_KB=$free
    MEM_AVAILABLE_KB=$available
    MEM_BUFF_CACHE_KB=$buff_cache
    MEM_USED_PCT=$(echo "scale=1; $used * 100 / $total" | bc)
    MEM_BUFF_CACHE_PCT=$(echo "scale=1; $buff_cache * 100 / $total" | bc)
}

get_swap_stats() {
    local total=${MEMINFO[SwapTotal]:-0}
    local free=${MEMINFO[SwapFree]:-0}
    local cached=${MEMINFO[SwapCached]:-0}

    local used=$((total - free))

    SWAP_TOTAL_KB=$total
    SWAP_USED_KB=$used
    SWAP_FREE_KB=$free
    SWAP_CACHED_KB=$cached
    if [[ $total -gt 0 ]]; then
        SWAP_USED_PCT=$(echo "scale=1; $used * 100 / $total" | bc)
    else
        SWAP_USED_PCT="0.0"
    fi
}

# Get detailed memory breakdown
get_detailed_mem_stats() {
    local total=${MEMINFO[MemTotal]:-1}

    # Active vs Inactive memory
    MEM_ACTIVE_KB=${MEMINFO[Active]:-0}
    MEM_INACTIVE_KB=${MEMINFO[Inactive]:-0}

    # Anonymous vs File-backed
    MEM_ANON_KB=$((${MEMINFO[AnonPages]:-0}))
    MEM_FILE_KB=$((${MEMINFO[Cached]:-0} + ${MEMINFO[Buffers]:-0}))

    # Active breakdown
    MEM_ACTIVE_ANON_KB=${MEMINFO[Active(anon)]:-0}
    MEM_ACTIVE_FILE_KB=${MEMINFO[Active(file)]:-0}
    MEM_INACTIVE_ANON_KB=${MEMINFO[Inactive(anon)]:-0}
    MEM_INACTIVE_FILE_KB=${MEMINFO[Inactive(file)]:-0}

    # Kernel memory
    MEM_SLAB_KB=$((${MEMINFO[Slab]:-0}))
    MEM_SLAB_RECLAIM_KB=${MEMINFO[SReclaimable]:-0}
    MEM_SLAB_UNRECLAIM_KB=${MEMINFO[SUnreclaim]:-0}
    MEM_KERNEL_STACK_KB=${MEMINFO[KernelStack]:-0}
    MEM_PAGE_TABLES_KB=${MEMINFO[PageTables]:-0}

    # Shared memory
    MEM_SHMEM_KB=${MEMINFO[Shmem]:-0}
    MEM_MAPPED_KB=${MEMINFO[Mapped]:-0}

    # Dirty/Writeback (I/O pending)
    MEM_DIRTY_KB=${MEMINFO[Dirty]:-0}
    MEM_WRITEBACK_KB=${MEMINFO[Writeback]:-0}

    # Huge pages
    MEM_ANON_HUGE_KB=${MEMINFO[AnonHugePages]:-0}
    MEM_HUGE_TOTAL=$((${MEMINFO[HugePages_Total]:-0}))
    MEM_HUGE_FREE=$((${MEMINFO[HugePages_Free]:-0}))
    MEM_HUGE_SIZE_KB=${MEMINFO[Hugepagesize]:-2048}

    # Calculate percentages
    MEM_ACTIVE_PCT=$(echo "scale=1; $MEM_ACTIVE_KB * 100 / $total" | bc)
    MEM_INACTIVE_PCT=$(echo "scale=1; $MEM_INACTIVE_KB * 100 / $total" | bc)
    MEM_ANON_PCT=$(echo "scale=1; $MEM_ANON_KB * 100 / $total" | bc)
    MEM_FILE_PCT=$(echo "scale=1; $MEM_FILE_KB * 100 / $total" | bc)
    MEM_SLAB_PCT=$(echo "scale=1; $MEM_SLAB_KB * 100 / $total" | bc)
    MEM_SHMEM_PCT=$(echo "scale=1; $MEM_SHMEM_KB * 100 / $total" | bc)
}

# Get detailed per-process memory info
# Returns: pid rss pss uss shared private swap command
get_process_detailed_mem() {
    local n=${1:-10}
    local count=0

    # Get top RSS processes
    local pids_cmds
    pids_cmds=$(ps aux --sort=-rss | awk 'NR>1 && $6>10240 {print $2 ":" $11}' | head -$((n + 5)))

    for entry in $pids_cmds; do
        [[ $count -ge $n ]] && break

        local pid="${entry%%:*}"
        local cmd="${entry#*:}"

        [[ ! -r "/proc/$pid/smaps_rollup" ]] && continue

        # Parse smaps_rollup using awk for reliable parsing
        local mem_data
        mem_data=$(awk '
            /^Rss:/ { rss = $2 }
            /^Pss:/ { pss = $2 }
            /^Private_Clean:/ { pc = $2 }
            /^Private_Dirty:/ { pd = $2 }
            /^Shared_Clean:/ { sc = $2 }
            /^Shared_Dirty:/ { sd = $2 }
            /^Swap:/ { swap = $2 }
            END {
                private = pc + pd
                shared = sc + sd
                uss = private
                printf "%d %d %d %d %d %d", rss, pss, uss, shared, private, swap
            }
        ' "/proc/$pid/smaps_rollup" 2>/dev/null)

        [[ -z "$mem_data" ]] && continue

        local rss pss uss shared private swap
        read -r rss pss uss shared private swap <<< "$mem_data"

        [[ ${rss:-0} -gt 0 ]] && echo "$pid $rss $pss $uss $shared $private $swap $(basename "$cmd")"
        ((count++))
    done
}

# Get AGGREGATED memory by application (sums all processes with same base name)
# FAST version - uses RSS from ps, only reads smaps for top processes
# Returns: app_name total_rss total_pss total_uss total_shared process_count
get_aggregated_app_mem() {
    local n=${1:-10}

    # First pass: aggregate RSS by app name using only ps (fast)
    ps aux --sort=-rss | awk '
        NR>1 && $6>1024 {
            cmd = $11
            # Extract base app name
            gsub(/.*\//, "", cmd)      # Remove path
            gsub(/[^a-zA-Z0-9_-].*/, "", cmd)  # Remove args/extensions
            if (cmd == "") cmd = "unknown"

            rss[cmd] += $6
            pids[cmd] = pids[cmd] " " $2
            count[cmd]++
        }
        END {
            for (app in rss) {
                printf "%s %d %d %s\n", app, rss[app], count[app], pids[app]
            }
        }
    ' | sort -t' ' -k2 -rn | head -$n | while read -r app rss count pids; do
        # Second pass: only read smaps for top apps (limit to first 5 pids per app for speed)
        local total_pss=0 total_uss=0 total_shared=0
        local pid_count=0
        for pid in $pids; do
            [[ $pid_count -ge 5 ]] && break
            if [[ -r "/proc/$pid/smaps_rollup" ]]; then
                read -r pss uss shared <<< $(awk '
                    /^Pss:/ { pss = $2 }
                    /^Private_Clean:/ { pc = $2 }
                    /^Private_Dirty:/ { pd = $2 }
                    /^Shared_Clean:/ { sc = $2 }
                    /^Shared_Dirty:/ { sd = $2 }
                    END { print pss, pc+pd, sc+sd }
                ' "/proc/$pid/smaps_rollup" 2>/dev/null)
                total_pss=$((total_pss + ${pss:-0}))
                total_uss=$((total_uss + ${uss:-0}))
                total_shared=$((total_shared + ${shared:-0}))
            fi
            ((pid_count++))
        done
        # Extrapolate if we only sampled some processes
        if [[ $pid_count -gt 0 && $count -gt $pid_count ]]; then
            local ratio=$((count / pid_count))
            total_pss=$((total_pss * ratio))
            total_uss=$((total_uss * ratio))
            total_shared=$((total_shared * ratio))
        fi
        echo "$app $rss $total_pss $total_uss $total_shared $count"
    done
}

# Get top memory consuming processes
# Returns: pid rss_kb vsz_kb pct command
get_top_mem_processes() {
    local n=${1:-10}
    ps aux --sort=-rss | awk -v n="$n" '
        NR>1 && $6>1024 {
            if(++count<=n) {
                # $2=pid, $4=mem%, $5=vsz, $6=rss, $11=command
                print $2, $6, $5, $4, $11
            }
        }'
}

# History arrays for time-based averages
declare -a MEM_HISTORY=()      # "timestamp:used_pct"
declare -a SWAP_HISTORY=()     # "timestamp:used_pct"
declare -a PROC_MEM_HISTORY=() # "timestamp:proc:rss_kb"
declare CURRENT_TIMESTAMP=$(date +%s)

declare -i MAX_MEM_HISTORY=1000
declare -i MAX_PROC_HISTORY=5000

# Process memory tracking
declare -A PROC_MEM_PEAK=()    # Peak RSS per process
declare -A PROC_MEM_COUNT=()   # Sample count per process
declare -A PROC_MEM_TOTAL=()   # Total RSS for average

add_mem_reading() {
    MEM_HISTORY+=("$CURRENT_TIMESTAMP:$1")
}

add_swap_reading() {
    SWAP_HISTORY+=("$CURRENT_TIMESTAMP:$1")
}

add_proc_mem_reading() {
    PROC_MEM_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

prune_history() {
    if [[ ${#MEM_HISTORY[@]} -gt $MAX_MEM_HISTORY ]]; then
        MEM_HISTORY=("${MEM_HISTORY[@]: -$MAX_MEM_HISTORY}")
    fi
    if [[ ${#SWAP_HISTORY[@]} -gt $MAX_MEM_HISTORY ]]; then
        SWAP_HISTORY=("${SWAP_HISTORY[@]: -$MAX_MEM_HISTORY}")
    fi
    if [[ ${#PROC_MEM_HISTORY[@]} -gt $MAX_PROC_HISTORY ]]; then
        PROC_MEM_HISTORY=("${PROC_MEM_HISTORY[@]: -$MAX_PROC_HISTORY}")
    fi
}

# Calculate memory averages over time windows
get_mem_averages() {
    local now=$CURRENT_TIMESTAMP
    printf '%s\n' "${MEM_HISTORY[@]}" | awk -F: -v now="$now" '
    {
        ts = $1; pct = $2; age = now - ts
        if (age <= 10) { sum10 += pct; cnt10++ }
        if (age <= 60) { sum1 += pct; cnt1++ }
        if (age <= 300) { sum5 += pct; cnt5++ }
        if (age <= 900) { sum15 += pct; cnt15++ }
    }
    END {
        printf "%.1f %.1f %.1f %.1f\n",
            (cnt10 > 0) ? sum10/cnt10 : -1,
            (cnt1 > 0) ? sum1/cnt1 : -1,
            (cnt5 > 0) ? sum5/cnt5 : -1,
            (cnt15 > 0) ? sum15/cnt15 : -1
    }'
}

get_swap_averages() {
    local now=$CURRENT_TIMESTAMP
    printf '%s\n' "${SWAP_HISTORY[@]}" | awk -F: -v now="$now" '
    {
        ts = $1; pct = $2; age = now - ts
        if (age <= 10) { sum10 += pct; cnt10++ }
        if (age <= 60) { sum1 += pct; cnt1++ }
        if (age <= 300) { sum5 += pct; cnt5++ }
        if (age <= 900) { sum15 += pct; cnt15++ }
    }
    END {
        printf "%.1f %.1f %.1f %.1f\n",
            (cnt10 > 0) ? sum10/cnt10 : -1,
            (cnt1 > 0) ? sum1/cnt1 : -1,
            (cnt5 > 0) ? sum5/cnt5 : -1,
            (cnt15 > 0) ? sum15/cnt15 : -1
    }'
}

# Get top memory consumers with time-based averages
get_top_mem_summary_timed() {
    local limit=${1:-5}
    local now=$CURRENT_TIMESTAMP

    # Build process totals
    local proc_data=""
    for proc in "${!PROC_MEM_PEAK[@]}"; do
        local peak=${PROC_MEM_PEAK[$proc]}
        local count=${PROC_MEM_COUNT[$proc]:-1}
        local total=${PROC_MEM_TOTAL[$proc]:-$peak}
        local avg=$((total / count))
        proc_data+="TOTAL:$proc:$peak:$avg"$'\n'
    done

    {
        echo "$proc_data"
        printf '%s\n' "${PROC_MEM_HISTORY[@]}"
    } | awk -F: -v now="$now" '
    /^TOTAL:/ {
        proc = $2; peaks[proc] = $3; avgs[proc] = $4
        next
    }
    NF >= 3 {
        ts = $1; proc = $2; rss = $3; age = now - ts
        if (age <= 10) { sum10[proc] += rss; cnt10[proc]++ }
        if (age <= 60) { sum1[proc] += rss; cnt1[proc]++ }
        if (age <= 300) { sum5[proc] += rss; cnt5[proc]++ }
    }
    END {
        for (proc in peaks) {
            avg10 = (cnt10[proc] > 0) ? sum10[proc] / cnt10[proc] : -1
            avg1 = (cnt1[proc] > 0) ? sum1[proc] / cnt1[proc] : -1
            avg5 = (cnt5[proc] > 0) ? sum5[proc] / cnt5[proc] : -1
            printf "%s %d %d %.0f %.0f %.0f\n", proc, peaks[proc], avgs[proc], avg10, avg1, avg5
        }
    }' | sort -k2 -rn | head -$limit
}


# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Set monitoring interval
INTERVAL=${1:-1}

# Cache for expensive operations (refreshed every N samples)
declare AGGREGATED_CACHE=""
declare -i CACHE_REFRESH_INTERVAL=3  # Refresh expensive data every 3 samples
declare -i LAST_CACHE_REFRESH=0

# Terminal dimensions
TERM_COLS=$(tput cols)
TERM_ROWS=$(tput lines)

# Counters
declare -i SAMPLE_COUNT=0
declare -i HIGH_MEM_COUNT=0
declare -i HIGH_SWAP_COUNT=0
declare -i CONSECUTIVE_HIGH_MEM=0
declare -i CONSECUTIVE_HIGH_SWAP=0
declare -i ALERT_THRESHOLD=3

# Current values for display
declare MEM_TOTAL_KB=0
declare MEM_USED_KB=0
declare MEM_FREE_KB=0
declare MEM_AVAILABLE_KB=0
declare MEM_BUFF_CACHE_KB=0
declare MEM_USED_PCT="0.0"
declare MEM_BUFF_CACHE_PCT="0.0"
declare SWAP_TOTAL_KB=0
declare SWAP_USED_KB=0
declare SWAP_FREE_KB=0
declare SWAP_CACHED_KB=0
declare SWAP_USED_PCT="0.0"

# Detailed memory breakdown
declare MEM_ACTIVE_KB=0
declare MEM_INACTIVE_KB=0
declare MEM_ANON_KB=0
declare MEM_FILE_KB=0
declare MEM_ACTIVE_ANON_KB=0
declare MEM_ACTIVE_FILE_KB=0
declare MEM_INACTIVE_ANON_KB=0
declare MEM_INACTIVE_FILE_KB=0
declare MEM_SLAB_KB=0
declare MEM_SLAB_RECLAIM_KB=0
declare MEM_SLAB_UNRECLAIM_KB=0
declare MEM_KERNEL_STACK_KB=0
declare MEM_PAGE_TABLES_KB=0
declare MEM_SHMEM_KB=0
declare MEM_MAPPED_KB=0
declare MEM_DIRTY_KB=0
declare MEM_WRITEBACK_KB=0
declare MEM_ANON_HUGE_KB=0
declare MEM_HUGE_TOTAL=0
declare MEM_HUGE_FREE=0
declare MEM_HUGE_SIZE_KB=2048
declare MEM_ACTIVE_PCT="0.0"
declare MEM_INACTIVE_PCT="0.0"
declare MEM_ANON_PCT="0.0"
declare MEM_FILE_PCT="0.0"
declare MEM_SLAB_PCT="0.0"
declare MEM_SHMEM_PCT="0.0"

# Function to draw the TUI
draw_screen() {
    TERM_COLS=$(tput cols)
    TERM_ROWS=$(tput lines)
    tput clear
    tput cup 0 0

    local width=$TERM_COLS
    [[ $width -lt 60 ]] && width=60

    # Title bar
    local title_line=""
    for ((i=0; i<width; i++)); do title_line+="═"; done
    local title_text="  🧠 REAL-TIME MEMORY MONITOR  │  Samples: $SAMPLE_COUNT  │  Ctrl+C to exit"

    echo -e "${CYAN}${BOLD}${title_line}${NC}"
    echo -e "${CYAN}${BOLD}${title_text}${NC}"
    echo -e "${CYAN}${BOLD}${title_line}${NC}"
    echo ""

    # Bar widths
    local main_bar_width=$((TERM_COLS - 40))
    [[ $main_bar_width -lt 20 ]] && main_bar_width=20

    # RAM Usage bar
    local mem_pct_int=$(float_to_int "$MEM_USED_PCT")
    get_mem_gradient_color "$mem_pct_int"
    printf "  ${BOLD}RAM Used${NC}     ["
    draw_bar "$MEM_USED_PCT" 100 $main_bar_width 1
    printf "] ${MEM_GRADIENT_COLOR}%5.1f%%${NC}  %s / %s\n" "$MEM_USED_PCT" "$(format_kb $MEM_USED_KB)" "$(format_kb $MEM_TOTAL_KB)"

    # Buffer/Cache bar (informational, using dimmer color)
    printf "  ${DIM}Buff/Cache${NC}   ["
    draw_bar "$MEM_BUFF_CACHE_PCT" 100 $main_bar_width 0
    printf "] ${DIM}%5.1f%%${NC}  %s\n" "$MEM_BUFF_CACHE_PCT" "$(format_kb $MEM_BUFF_CACHE_KB)"

    # Available memory
    local avail_pct=$(echo "scale=1; $MEM_AVAILABLE_KB * 100 / $MEM_TOTAL_KB" | bc)
    printf "  ${GREEN}Available${NC}    ["
    draw_bar "$avail_pct" 100 $main_bar_width 0
    printf "] ${GREEN}%5.1f%%${NC}  %s\n" "$avail_pct" "$(format_kb $MEM_AVAILABLE_KB)"

    echo ""

    # Swap Usage bar
    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        local swap_pct_int=$(float_to_int "$SWAP_USED_PCT")
        get_mem_gradient_color "$swap_pct_int"
        printf "  ${BOLD}Swap Used${NC}    ["
        draw_bar "$SWAP_USED_PCT" 100 $main_bar_width 1
        printf "] ${MEM_GRADIENT_COLOR}%5.1f%%${NC}  %s / %s\n" "$SWAP_USED_PCT" "$(format_kb $SWAP_USED_KB)" "$(format_kb $SWAP_TOTAL_KB)"
    else
        printf "  ${BOLD}Swap${NC}         ${DIM}(not configured)${NC}\n"
    fi

    echo ""

    # Separator
    local separator_line=""
    for ((i=0; i<width; i++)); do separator_line+="─"; done
    echo -e "${CYAN}${separator_line}${NC}"

    # Memory Breakdown Section
    printf "  ${BLUE}${BOLD}🔍 MEMORY BREAKDOWN${NC}\n"
    echo ""

    # Two-column layout for memory types
    local col_width=35

    # Row 1: Active vs Inactive
    printf "  ${BOLD}%-14s${NC} %8s (%5.1f%%)    " "Active:" "$(format_kb $MEM_ACTIVE_KB)" "$MEM_ACTIVE_PCT"
    printf "${BOLD}%-14s${NC} %8s (%5.1f%%)\n" "Inactive:" "$(format_kb $MEM_INACTIVE_KB)" "$MEM_INACTIVE_PCT"

    # Row 2: Anonymous vs File-backed
    printf "  ${YELLOW}%-14s${NC} %8s (%5.1f%%)    " "Anonymous:" "$(format_kb $MEM_ANON_KB)" "$MEM_ANON_PCT"
    printf "${CYAN}%-14s${NC} %8s (%5.1f%%)\n" "File-backed:" "$(format_kb $MEM_FILE_KB)" "$MEM_FILE_PCT"

    # Row 3: Shared memory and Mapped
    printf "  ${MAGENTA}%-14s${NC} %8s (%5.1f%%)    " "Shared:" "$(format_kb $MEM_SHMEM_KB)" "$MEM_SHMEM_PCT"
    printf "%-14s %8s\n" "Mapped:" "$(format_kb $MEM_MAPPED_KB)"

    # Row 4: Kernel memory
    printf "  ${DIM}%-14s${NC} %8s (%5.1f%%)    " "Slab:" "$(format_kb $MEM_SLAB_KB)" "$MEM_SLAB_PCT"
    printf "${DIM}%-14s${NC} %8s\n" "PageTables:" "$(format_kb $MEM_PAGE_TABLES_KB)"

    echo ""
    echo -e "${CYAN}${separator_line}${NC}"

    # Visual Memory Map - multi-line grid for 0.1% accuracy
    local grid_rows=10
    local grid_cols=$((TERM_COLS - 6))  # Full width minus borders and padding
    [[ $grid_cols -lt 50 ]] && grid_cols=50

    local total_cells=$((grid_rows * grid_cols))
    local total_kb=$MEM_TOTAL_KB

    printf "  ${BLUE}${BOLD}📦 MEMORY MAP${NC}  ${DIM}(${grid_cols}x${grid_rows} grid = ${total_cells} cells, each █ ≈ %.2f%% RAM)${NC}\n" "$(echo "scale=2; 100 / $total_cells" | bc)"
    echo ""

    # Define colors for different apps (256-color palette)
    local -a APP_COLORS=(
        "\e[38;5;196m"  # Red
        "\e[38;5;208m"  # Orange
        "\e[38;5;226m"  # Yellow
        "\e[38;5;46m"   # Green
        "\e[38;5;51m"   # Cyan
        "\e[38;5;21m"   # Blue
        "\e[38;5;129m"  # Purple
        "\e[38;5;201m"  # Magenta
        "\e[38;5;214m"  # Gold
        "\e[38;5;118m"  # Lime
        "\e[38;5;39m"   # Sky blue
        "\e[38;5;199m"  # Pink
    )

    # Build array of cell colors
    local -a GRID_CELLS=()
    local cell_idx=0
    local color_idx=0

    # Process each app and assign cells
    local -a APP_NAMES=()
    local -a APP_RSS=()
    local -a APP_CELLS=()

    while read -r app rss pss uss shared count; do
        [[ -z "$app" ]] && continue
        APP_NAMES+=("$app")
        APP_RSS+=("$rss")
        # Calculate cells for this app
        local cells=$((rss * total_cells / total_kb))
        [[ $cells -lt 1 && $rss -gt 0 ]] && cells=1
        APP_CELLS+=("$cells")
    done <<< "$AGGREGATED_CACHE"

    # Build the grid string
    cell_idx=0
    for ((app_idx=0; app_idx<${#APP_NAMES[@]}; app_idx++)); do
        local cells=${APP_CELLS[$app_idx]}
        local color="${APP_COLORS[$((app_idx % ${#APP_COLORS[@]}))]}"
        for ((c=0; c<cells && cell_idx<total_cells; c++)); do
            GRID_CELLS+=("$color")
            ((cell_idx++))
        done
    done

    # Fill remaining with free memory
    while [[ $cell_idx -lt $total_cells ]]; do
        GRID_CELLS+=("FREE")
        ((cell_idx++))
    done

    # Draw the grid row by row
    for ((row=0; row<grid_rows; row++)); do
        printf "  │"
        for ((col=0; col<grid_cols; col++)); do
            local idx=$((row * grid_cols + col))
            local cell_color="${GRID_CELLS[$idx]}"
            if [[ "$cell_color" == "FREE" ]]; then
                printf "${DIM}░${NC}"
            else
                printf "${cell_color}█${NC}"
            fi
        done
        printf "│\n"
    done
    echo ""

    # Legend with app names, colors, and stats
    printf "  %-12s %8s  %6s  %s\n" "APPLICATION" "RSS" "%" "CELLS"
    printf "  %-12s %8s  %6s  %s\n" "────────────" "────────" "──────" "─────"

    for ((app_idx=0; app_idx<${#APP_NAMES[@]}; app_idx++)); do
        local app="${APP_NAMES[$app_idx]}"
        local rss="${APP_RSS[$app_idx]}"
        local cells="${APP_CELLS[$app_idx]}"

        local pct_raw=$((rss * 1000 / total_kb))
        local pct_int=$((pct_raw / 10))
        local pct_dec=$((pct_raw % 10))

        local color="${APP_COLORS[$((app_idx % ${#APP_COLORS[@]}))]}"

        printf "  ${color}██${NC} %-9s %8s  %2d.%d%%  %4d\n" "${app:0:9}" "$(format_kb $rss)" "$pct_int" "$pct_dec" "$cells"
    done

    # Show free memory
    local used_cells=0
    for c in "${APP_CELLS[@]}"; do used_cells=$((used_cells + c)); done
    local free_cells=$((total_cells - used_cells))
    [[ $free_cells -lt 0 ]] && free_cells=0

    local free_kb=$MEM_AVAILABLE_KB
    local free_pct_raw=$((free_kb * 1000 / total_kb))
    local free_pct_int=$((free_pct_raw / 10))
    local free_pct_dec=$((free_pct_raw % 10))

    printf "  ${DIM}░░${NC} %-9s %8s  %2d.%d%%  %4d\n" "available" "$(format_kb $free_kb)" "$free_pct_int" "$free_pct_dec" "$free_cells"

    echo -e "${CYAN}${BOLD}${title_line}${NC}"
}

# Cleanup function
cleanup() {
    tput cnorm  # Show cursor
    tput clear
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    FINAL MEMORY SUMMARY                        ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Total samples: ${SAMPLE_COUNT} (each sample = ${INTERVAL}s)"
    echo -e "Monitoring duration: ~$((SAMPLE_COUNT * INTERVAL)) seconds"
    echo -e "High memory events: ${HIGH_MEM_COUNT} | Swap usage events: ${HIGH_SWAP_COUNT}"
    echo ""
    echo -e "${BLUE}Final Memory State:${NC}"
    printf "  RAM:  %s used / %s total (%.1f%%)\n" "$(format_kb $MEM_USED_KB)" "$(format_kb $MEM_TOTAL_KB)" "$MEM_USED_PCT"
    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        printf "  Swap: %s used / %s total (%.1f%%)\n" "$(format_kb $SWAP_USED_KB)" "$(format_kb $SWAP_TOTAL_KB)" "$SWAP_USED_PCT"
    fi
    echo ""
    echo -e "${BLUE}Top Memory Consumers (sorted by peak RSS):${NC}"
    printf "  %-25s %10s %10s\n" "PROCESS" "PEAK" "AVG"
    printf "  %-25s %10s %10s\n" "─────────────────────────" "──────────" "──────────"
    get_top_mem_summary_timed 10 | while read -r proc peak avg _; do
        printf "  %-25s %10s %10s\n" "$proc" "$(format_kb $peak)" "$(format_kb $avg)"
    done
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Monitoring stopped.${NC}"
    exit 0
}

# Trap Ctrl+C
trap cleanup INT

# Hide cursor for cleaner display
tput civis

# Initialize color blocks
init_color_blocks

# Monitoring loop
while true; do
    SAMPLE_COUNT+=1
    CURRENT_TIMESTAMP=$(date +%s)

    # Update memory info (fast operations)
    update_meminfo
    get_mem_stats
    get_swap_stats
    get_detailed_mem_stats

    # Refresh aggregated app memory cache periodically (every N samples)
    if [[ $((SAMPLE_COUNT - LAST_CACHE_REFRESH)) -ge $CACHE_REFRESH_INTERVAL ]] || [[ $SAMPLE_COUNT -eq 1 ]]; then
        AGGREGATED_CACHE=$(get_aggregated_app_mem 12)
        LAST_CACHE_REFRESH=$SAMPLE_COUNT
    fi

    # Add to history for averages
    add_mem_reading "$MEM_USED_PCT"
    add_mem_to_ring "$MEM_USED_PCT"

    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        add_swap_reading "$SWAP_USED_PCT"
        add_swap_to_ring "$SWAP_USED_PCT"
    fi

    # Track high memory events (>85% used)
    mem_pct_int=$(float_to_int "$MEM_USED_PCT")
    if [[ $mem_pct_int -gt 850 ]]; then
        CONSECUTIVE_HIGH_MEM+=1
        if [[ $CONSECUTIVE_HIGH_MEM -eq $ALERT_THRESHOLD ]]; then
            HIGH_MEM_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_MEM=0
    fi

    # Track swap usage events (>10% swap used)
    if [[ $SWAP_TOTAL_KB -gt 0 ]]; then
        swap_pct_int=$(float_to_int "$SWAP_USED_PCT")
        if [[ $swap_pct_int -gt 100 ]]; then
            CONSECUTIVE_HIGH_SWAP+=1
            if [[ $CONSECUTIVE_HIGH_SWAP -eq $ALERT_THRESHOLD ]]; then
                HIGH_SWAP_COUNT+=1
            fi
        else
            CONSECUTIVE_HIGH_SWAP=0
        fi
    fi

    # Track per-process memory (processes using >50MB)
    while read -r pid rss vsz pct cmd; do
        [[ -z "$cmd" || -z "$rss" ]] && continue
        proc_name=$(basename "$cmd")
        [[ "$proc_name" =~ ^(ps|awk|grep|bash|sh|cat|sed|tput)$ ]] && continue

        rss_int=${rss%.*}

        # Track count and total for average
        PROC_MEM_COUNT[$proc_name]=$((${PROC_MEM_COUNT[$proc_name]:-0} + 1))
        PROC_MEM_TOTAL[$proc_name]=$((${PROC_MEM_TOTAL[$proc_name]:-0} + rss_int))

        # Track peak
        current_peak=${PROC_MEM_PEAK[$proc_name]:-0}
        if [[ $rss_int -gt $current_peak ]]; then
            PROC_MEM_PEAK[$proc_name]=$rss_int
        fi

        # Add to history
        add_proc_mem_reading "$proc_name" "$rss_int"
    done < <(get_top_mem_processes 15)

    # Prune history every 30 samples
    if [[ $((SAMPLE_COUNT % 30)) -eq 0 ]]; then
        prune_history
    fi

    # Draw the TUI
    draw_screen

    sleep "$INTERVAL"
done
