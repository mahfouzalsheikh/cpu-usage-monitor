#!/bin/bash

# Continuous CPU and Temperature Monitor with Real-Time TUI
# Run with sudo for full system access
# Usage: sudo ./cpu_monitor_continuous.sh [interval_seconds]

# Note: Not using set -e because bc comparisons and some commands may return non-zero
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Set monitoring interval (default 3 seconds for smoother TUI)
INTERVAL=${1:-3}

# Terminal dimensions
TERM_COLS=$(tput cols)
TERM_ROWS=$(tput lines)

# Number of live log lines to keep
LIVE_LOG_LINES=8

# Array to store recent log entries
declare -a LIVE_LOG=()

# Function to get CPU temperature
get_cpu_temp() {
    if command -v sensors >/dev/null 2>&1; then
        sensors | grep -E "Core.*\+[0-9]+\.[0-9]+°C" | head -1 | grep -oE '\+[0-9]+\.[0-9]+' | head -1 | tr -d '+'
    elif [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        echo "scale=1; $temp_raw / 1000" | bc
    else
        echo "N/A"
    fi
}

# Function to get CPU usage
get_cpu_usage() {
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'
}

# Function to get load average
get_load_avg() {
    cat /proc/loadavg | awk '{print $1}'
}

# Detect GPU type
detect_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "nvidia"
    elif command -v rocm-smi >/dev/null 2>&1; then
        echo "amd"
    elif [[ -d /sys/class/drm/card0 ]]; then
        echo "integrated"
    else
        echo "none"
    fi
}

GPU_TYPE=$(detect_gpu)

# Function to get GPU temperature
get_gpu_temp() {
    case "$GPU_TYPE" in
        nvidia)
            nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A"
            ;;
        amd)
            rocm-smi --showtemp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "N/A"
            ;;
        integrated)
            # Try to find Intel/AMD integrated GPU temp from hwmon
            for hwmon in /sys/class/hwmon/hwmon*/temp*_label; do
                if [[ -f "$hwmon" ]] && grep -qi "gpu\|edge" "$hwmon" 2>/dev/null; then
                    temp_file="${hwmon%_label}_input"
                    if [[ -f "$temp_file" ]]; then
                        temp_raw=$(cat "$temp_file")
                        echo "scale=1; $temp_raw / 1000" | bc
                        return
                    fi
                fi
            done
            echo "N/A"
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# Function to get GPU usage
get_gpu_usage() {
    case "$GPU_TYPE" in
        nvidia)
            nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A"
            ;;
        amd)
            rocm-smi --showuse 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "N/A"
            ;;
        integrated)
            # Intel GPU usage from intel_gpu_top or sysfs
            if [[ -f /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz ]]; then
                # Rough estimate based on frequency ratio
                act=$(cat /sys/class/drm/card0/gt/gt0/rps_act_freq_mhz 2>/dev/null || echo 0)
                max=$(cat /sys/class/drm/card0/gt/gt0/rps_max_freq_mhz 2>/dev/null || echo 1)
                if [[ "$max" -gt 0 ]]; then
                    echo "scale=0; $act * 100 / $max" | bc
                else
                    echo "N/A"
                fi
            else
                echo "N/A"
            fi
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# Function to get top GPU processes (NVIDIA only for now)
get_top_gpu_processes() {
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | \
            head -5 | while IFS=, read -r pid name mem; do
                name=$(echo "$name" | xargs)  # trim whitespace
                mem=$(echo "$mem" | xargs)
                printf "    %s (PID %s): %s MiB\n" "$(basename "$name")" "$pid" "$mem"
            done
    fi
}

# Function to track GPU process usage over time (NVIDIA only)
track_gpu_processes() {
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        # Parse nvidia-smi process list
        # Format: |    0   N/A  N/A    3154      G   /usr/lib/xorg/Xorg    169MiB |
        nvidia-smi 2>/dev/null | awk '
        /^[|][[:space:]]+[0-9]+[[:space:]]+N\/A/ {
            # Remove leading/trailing pipes and whitespace
            gsub(/^[|]/, "")
            gsub(/[|]$/, "")

            # Find the process path (starts with /) and memory (ends with MiB)
            mem = ""
            cmd = ""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^\//) {
                    cmd = $i
                }
                if ($i ~ /[0-9]+MiB$/) {
                    mem = $i
                    gsub(/MiB$/, "", mem)
                }
            }
            if (cmd != "" && mem != "") {
                # Get basename
                n = split(cmd, parts, "/")
                procname = parts[n]
                print procname, mem
            }
        }'
    fi
}

# Function to get top process (exclude ps/awk/grep which are part of this script)
get_top_process() {
    ps aux --sort=-%cpu | awk '$11 !~ /(^ps$|^awk$|^grep$|^top$)/ && NR>1 {printf "%s (%.1f%%)", $11, $3; exit}'
}

# Function to get top N CPU-consuming processes with PID
get_top_processes() {
    local n=${1:-5}
    ps aux --sort=-%cpu | awk -v n="$n" '$11 !~ /(^ps$|^awk$|^grep$|^top$)/ && NR>1 && $3>1.0 {if(++count<=n) printf "  %s (PID %s): %.1f%%\n", $11, $2, $3}'
}

# Declare associative array to track process CPU time
declare -A PROCESS_CPU_COUNT=()
declare -A PROCESS_TOTAL_CPU=()
declare -i SAMPLE_COUNT=0
declare -i HIGH_CPU_COUNT=0
declare -i HIGH_TEMP_COUNT=0
declare -i HIGH_GPU_TEMP_COUNT=0

# Consecutive sample counters for smarter alerts (trigger after 3 consecutive samples)
declare -i CONSECUTIVE_HIGH_CPU=0
declare -i CONSECUTIVE_HIGH_CPU_TEMP=0
declare -i CONSECUTIVE_HIGH_GPU_TEMP=0
declare -i ALERT_THRESHOLD=3

# Track GPU usage over time
declare GPU_USAGE_TOTAL=0
declare GPU_USAGE_SAMPLES=0

# Track GPU usage per process (NVIDIA only)
declare -A GPU_PROCESS_CURRENT=()  # Current VRAM per process
declare -A GPU_PROCESS_PEAK=()     # Peak VRAM per process (for summary)
declare -A GPU_PROCESS_COUNT=()    # Sample count per process (for average)
declare -A GPU_PROCESS_TOTAL=()    # Total VRAM across samples (for average)

# Current values for display
declare CURRENT_CPU_USAGE=0
declare CURRENT_CPU_TEMP="N/A"
declare CURRENT_GPU_USAGE="N/A"
declare CURRENT_GPU_TEMP="N/A"
declare CURRENT_LOAD="0"

# Historical readings for time-based averages (1m, 5m, 15m)
# Format: "timestamp:process:cpu_percent"
declare -a CPU_HISTORY=()
declare -a GPU_HISTORY=()
declare CURRENT_TIMESTAMP=$(date +%s)

# Add a CPU reading to history (uses cached timestamp)
add_cpu_reading() {
    CPU_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Add a GPU reading to history
add_gpu_reading() {
    GPU_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Prune old entries using awk (much faster than bash loop)
prune_history() {
    local cutoff=$((CURRENT_TIMESTAMP - 900))

    # Prune CPU history efficiently
    if [[ ${#CPU_HISTORY[@]} -gt 0 ]]; then
        local pruned
        pruned=$(printf '%s\n' "${CPU_HISTORY[@]}" | awk -F: -v cutoff="$cutoff" '$1 >= cutoff')
        CPU_HISTORY=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && CPU_HISTORY+=("$line")
        done <<< "$pruned"
    fi
}

# Calculate all time-based averages in ONE pass using awk (fast!)
# Also calculates cpu_secs for each process
# Output: proc cpu_secs avg_1m avg_5m avg_15m
get_top_cpu_summary_timed() {
    local limit=${1:-5}
    local now=$CURRENT_TIMESTAMP

    # Build process totals string for awk (use : as separator for consistency)
    local proc_data=""
    for proc in "${!PROCESS_CPU_COUNT[@]}"; do
        local total=${PROCESS_TOTAL_CPU[$proc]}
        proc_data+="TOTAL:$proc:$total"$'\n'
    done

    # Process history with awk - calculates all averages in one pass
    {
        echo "$proc_data"
        printf '%s\n' "${CPU_HISTORY[@]}"
    } | awk -F: -v now="$now" -v interval="$INTERVAL" '
    # Lines starting with TOTAL: are process totals
    /^TOTAL:/ {
        proc = $2
        totals[proc] = $3
        next
    }

    # Other lines are history: timestamp:proc:cpu
    NF >= 3 {
        ts = $1
        proc = $2
        cpu = $3
        age = now - ts

        if (age <= 60) { sum1[proc] += cpu; cnt1[proc]++ }
        if (age <= 300) { sum5[proc] += cpu; cnt5[proc]++ }
        if (age <= 900) { sum15[proc] += cpu; cnt15[proc]++ }
    }

    END {
        for (proc in totals) {
            cpu_secs = (totals[proc] * interval) / 100
            avg1 = (cnt1[proc] > 0) ? sum1[proc] / cnt1[proc] : -1
            avg5 = (cnt5[proc] > 0) ? sum5[proc] / cnt5[proc] : -1
            avg15 = (cnt15[proc] > 0) ? sum15[proc] / cnt15[proc] : -1
            printf "%s %.1f %.1f %.1f %.1f\n", proc, cpu_secs, avg1, avg5, avg15
        }
    }
    ' | sort -k2 -rn | head -$limit
}

# Function to get top GPU consumers for display (current and average VRAM usage)
# Output: proc_name current_vram avg_vram
get_top_gpu_summary() {
    local limit=${1:-5}
    for proc in "${!GPU_PROCESS_CURRENT[@]}"; do
        local current=${GPU_PROCESS_CURRENT[$proc]}
        local count=${GPU_PROCESS_COUNT[$proc]:-1}
        local total=${GPU_PROCESS_TOTAL[$proc]:-$current}
        local avg=$(awk "BEGIN {printf \"%.1f\", $total / $count}")
        echo "$proc $current $avg"
    done | sort -k2 -rn | head -$limit
}

# Function to get peak GPU consumers for summary
# Output: proc_name peak_vram avg_vram
get_peak_gpu_summary() {
    local limit=${1:-5}
    for proc in "${!GPU_PROCESS_PEAK[@]}"; do
        local peak=${GPU_PROCESS_PEAK[$proc]}
        local count=${GPU_PROCESS_COUNT[$proc]:-1}
        local total=${GPU_PROCESS_TOTAL[$proc]:-$peak}
        local avg=$(awk "BEGIN {printf \"%.1f\", $total / $count}")
        echo "$proc $peak $avg"
    done | sort -k2 -rn | head -$limit
}

# Function to draw the TUI
draw_screen() {
    # Clear screen and move cursor to top
    tput clear
    tput cup 0 0

    local width=100
    if [[ $TERM_COLS -lt 100 ]]; then
        width=$TERM_COLS
    fi
    local half_width=$((width / 2 - 2))

    # Title bar
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  🖥️  REAL-TIME SYSTEM MONITOR  │  GPU: $GPU_TYPE  │  Samples: $SAMPLE_COUNT  │  Ctrl+C to exit${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"

    # Current stats bar with colors
    local cpu_color=$GREEN temp_color=$GREEN gpu_color=$GREEN gpu_temp_color=$GREEN

    if [[ "$CURRENT_CPU_USAGE" != "N/A" ]] && (( $(echo "$CURRENT_CPU_USAGE > 80" | bc -l) )); then
        cpu_color=$RED
    elif [[ "$CURRENT_CPU_USAGE" != "N/A" ]] && (( $(echo "$CURRENT_CPU_USAGE > 50" | bc -l) )); then
        cpu_color=$YELLOW
    fi

    if [[ "$CURRENT_CPU_TEMP" != "N/A" ]] && (( $(echo "$CURRENT_CPU_TEMP > 80" | bc -l) )); then
        temp_color=$RED
    elif [[ "$CURRENT_CPU_TEMP" != "N/A" ]] && (( $(echo "$CURRENT_CPU_TEMP > 70" | bc -l) )); then
        temp_color=$YELLOW
    fi

    if [[ "$CURRENT_GPU_USAGE" != "N/A" ]] && (( $(echo "$CURRENT_GPU_USAGE > 80" | bc -l) )); then
        gpu_color=$RED
    elif [[ "$CURRENT_GPU_USAGE" != "N/A" ]] && (( $(echo "$CURRENT_GPU_USAGE > 50" | bc -l) )); then
        gpu_color=$YELLOW
    fi

    if [[ "$CURRENT_GPU_TEMP" != "N/A" ]] && (( $(echo "$CURRENT_GPU_TEMP > 80" | bc -l) )); then
        gpu_temp_color=$RED
    elif [[ "$CURRENT_GPU_TEMP" != "N/A" ]] && (( $(echo "$CURRENT_GPU_TEMP > 70" | bc -l) )); then
        gpu_temp_color=$YELLOW
    fi

    echo ""
    printf "  ${BOLD}CPU:${NC} ${cpu_color}%5.1f%%${NC}    ${BOLD}CPU Temp:${NC} ${temp_color}%5s°C${NC}    ${BOLD}GPU:${NC} ${gpu_color}%5s%%${NC}    ${BOLD}GPU Temp:${NC} ${gpu_temp_color}%5s°C${NC}    ${BOLD}Load:${NC} %s\n" \
        "$CURRENT_CPU_USAGE" "$CURRENT_CPU_TEMP" "$CURRENT_GPU_USAGE" "$CURRENT_GPU_TEMP" "$CURRENT_LOAD"
    echo ""

    # Alerts
    echo -ne "  ${BOLD}Alerts:${NC} "
    if [[ $HIGH_CPU_COUNT -gt 0 ]]; then
        echo -ne "🔥 High CPU: $HIGH_CPU_COUNT  "
    fi
    if [[ $HIGH_TEMP_COUNT -gt 0 ]]; then
        echo -ne "🌡️  CPU Temp: $HIGH_TEMP_COUNT  "
    fi
    if [[ $HIGH_GPU_TEMP_COUNT -gt 0 ]]; then
        echo -ne "🎮 GPU Temp: $HIGH_GPU_TEMP_COUNT  "
    fi
    if [[ $HIGH_TEMP_COUNT -gt 0 ]] && [[ $HIGH_CPU_COUNT -eq 0 ]]; then
        echo -ne "${YELLOW}⚠️  Thermal throttling?${NC}  "
    fi
    if [[ $HIGH_CPU_COUNT -eq 0 ]] && [[ $HIGH_TEMP_COUNT -eq 0 ]] && [[ $HIGH_GPU_TEMP_COUNT -eq 0 ]]; then
        echo -ne "${GREEN}✓ All normal${NC}"
    fi
    echo ""
    echo ""

    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

    # CPU Consumers with time-based averages
    printf "  ${BLUE}${BOLD}📊 TOP CPU CONSUMERS${NC}\n"
    printf "  %-18s %7s %6s %6s %6s\n" "PROCESS" "CPU-SEC" "1m" "5m" "15m"
    printf "  %-18s %7s %6s %6s %6s\n" "──────────────────" "───────" "──────" "──────" "──────"

    # Get top CPU processes with time-based averages (uses fast awk processing)
    get_top_cpu_summary_timed 5 | while read -r cpu_proc cpu_secs avg_1m avg_5m avg_15m; do
        [[ -z "$cpu_proc" ]] && continue
        cpu_proc="${cpu_proc:0:18}"

        # Format averages (-1 means no data)
        [[ "$avg_1m" == "-1.0" || "$avg_1m" == "-1" ]] && avg_1m="-" || avg_1m="${avg_1m}%"
        [[ "$avg_5m" == "-1.0" || "$avg_5m" == "-1" ]] && avg_5m="-" || avg_5m="${avg_5m}%"
        [[ "$avg_15m" == "-1.0" || "$avg_15m" == "-1" ]] && avg_15m="-" || avg_15m="${avg_15m}%"

        printf "  %-18s %6ss %6s %6s %6s\n" "$cpu_proc" "$cpu_secs" "$avg_1m" "$avg_5m" "$avg_15m"
    done

    echo ""

    # GPU Consumers
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        printf "  ${BLUE}${BOLD}🎮 TOP GPU CONSUMERS (VRAM)${NC}\n"
        printf "  %-18s %10s %10s\n" "PROCESS" "CURRENT" "AVG"
        printf "  %-18s %10s %10s\n" "──────────────────" "──────────" "──────────"

        local gpu_data=$(get_top_gpu_summary 5)
        while IFS= read -r gpu_line; do
            if [[ -n "$gpu_line" ]]; then
                local gpu_proc=$(echo "$gpu_line" | awk '{print $1}' | cut -c1-18)
                local gpu_current=$(echo "$gpu_line" | awk '{printf "%.0f", $2}')
                local gpu_avg=$(echo "$gpu_line" | awk '{print $3}')
                printf "  %-18s %9sMiB %9sMiB\n" "$gpu_proc" "$gpu_current" "$gpu_avg"
            fi
        done <<< "$gpu_data"
    fi

    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

    # Live log section
    printf "  ${BLUE}${BOLD}📜 LIVE MONITORING LOG${NC}\n"
    printf "  %-10s %8s %8s %8s %8s %8s   %-30s\n" "TIME" "CPU%" "CPU°C" "GPU%" "GPU°C" "LOAD" "TOP PROCESS"

    # Display live log entries
    for entry in "${LIVE_LOG[@]}"; do
        printf "  %s\n" "$entry"
    done

    # Fill remaining log lines if needed
    local log_count=${#LIVE_LOG[@]}
    while [[ $log_count -lt $LIVE_LOG_LINES ]]; do
        echo ""
        ((log_count++))
    done

    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
}

# Function to add entry to live log
add_to_log() {
    local entry="$1"
    LIVE_LOG+=("$entry")
    # Keep only last N entries
    if [[ ${#LIVE_LOG[@]} -gt $LIVE_LOG_LINES ]]; then
        LIVE_LOG=("${LIVE_LOG[@]:1}")
    fi
}

# Cleanup function
cleanup() {
    tput cnorm  # Show cursor
    tput clear
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    FINAL SUMMARY                              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Total samples: ${SAMPLE_COUNT} (each sample = ${INTERVAL}s)"
    echo -e "Monitoring duration: ~$((SAMPLE_COUNT * INTERVAL)) seconds"
    echo -e "High CPU events: ${HIGH_CPU_COUNT} | High CPU temp: ${HIGH_TEMP_COUNT} | High GPU temp: ${HIGH_GPU_TEMP_COUNT}"
    if [[ $GPU_USAGE_SAMPLES -gt 0 ]]; then
        avg_gpu=$(echo "scale=1; $GPU_USAGE_TOTAL / $GPU_USAGE_SAMPLES" | bc)
        echo -e "Average GPU usage: ${avg_gpu}%"
    fi
    echo ""
    echo -e "${BLUE}Top CPU Consumers (sorted by CPU-seconds):${NC}"
    printf "  %-20s %8s %7s %7s %7s\n" "PROCESS" "CPU-SEC" "1m" "5m" "15m"
    printf "  %-20s %8s %7s %7s %7s\n" "────────────────────" "────────" "───────" "───────" "───────"
    get_top_cpu_summary_timed 10 | while read -r proc cpu_secs avg_1m avg_5m avg_15m; do
        # Format averages (-1 means no data)
        [[ "$avg_1m" == "-1.0" || "$avg_1m" == "-1" ]] && avg_1m="-" || avg_1m="${avg_1m}%"
        [[ "$avg_5m" == "-1.0" || "$avg_5m" == "-1" ]] && avg_5m="-" || avg_5m="${avg_5m}%"
        [[ "$avg_15m" == "-1.0" || "$avg_15m" == "-1" ]] && avg_15m="-" || avg_15m="${avg_15m}%"
        printf "  %-20s %7ss %7s %7s %7s\n" "$proc" "$cpu_secs" "$avg_1m" "$avg_5m" "$avg_15m"
    done
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        echo ""
        echo -e "${BLUE}Top GPU Consumers (sorted by peak VRAM usage):${NC}"
        printf "  %-25s %10s %10s\n" "PROCESS" "PEAK" "AVG"
        printf "  %-25s %10s %10s\n" "─────────────────────────" "──────────" "──────────"
        get_peak_gpu_summary 8 | while read -r proc peak avg; do
            printf "  %-25s %9.0fMiB %9.1fMiB\n" "$proc" "$peak" "$avg"
        done
    fi
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Monitoring stopped.${NC}"
    exit 0
}

# Trap Ctrl+C
trap cleanup INT

# Hide cursor for cleaner display
tput civis

# Monitoring loop
while true; do
    SAMPLE_COUNT+=1
    CURRENT_TIMESTAMP=$(date +%s)
    timestamp=$(date '+%H:%M:%S')
    cpu_usage=$(get_cpu_usage)
    cpu_temp=$(get_cpu_temp)
    load_avg=$(get_load_avg)
    top_proc=$(get_top_process | cut -c1-30)

    # Get GPU stats
    gpu_temp=$(get_gpu_temp)
    gpu_usage=$(get_gpu_usage)

    # Update current values for display
    CURRENT_CPU_USAGE=$cpu_usage
    CURRENT_CPU_TEMP=$cpu_temp
    CURRENT_GPU_USAGE=$gpu_usage
    CURRENT_GPU_TEMP=$gpu_temp
    CURRENT_LOAD=$load_avg

    # Track high CPU temp events (only count once after 3 consecutive samples above threshold)
    if [[ "$cpu_temp" != "N/A" ]] && awk "BEGIN {exit !($cpu_temp > 70)}"; then
        CONSECUTIVE_HIGH_CPU_TEMP+=1
        if [[ $CONSECUTIVE_HIGH_CPU_TEMP -eq $ALERT_THRESHOLD ]]; then
            HIGH_TEMP_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_CPU_TEMP=0
    fi

    # Track high GPU temp events (only count once after 3 consecutive samples above threshold)
    if [[ "$gpu_temp" != "N/A" ]] && awk "BEGIN {exit !($gpu_temp > 70)}"; then
        CONSECUTIVE_HIGH_GPU_TEMP+=1
        if [[ $CONSECUTIVE_HIGH_GPU_TEMP -eq $ALERT_THRESHOLD ]]; then
            HIGH_GPU_TEMP_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_GPU_TEMP=0
    fi

    # Track GPU usage for summary (use awk for accumulation)
    if [[ "$gpu_usage" != "N/A" ]]; then
        GPU_USAGE_TOTAL=$(awk "BEGIN {print $GPU_USAGE_TOTAL + $gpu_usage}")
        GPU_USAGE_SAMPLES=$((GPU_USAGE_SAMPLES + 1))
    fi

    # Track high CPU events (only count once after 3 consecutive samples above threshold)
    if awk "BEGIN {exit !($cpu_usage > 80)}"; then
        CONSECUTIVE_HIGH_CPU+=1
        if [[ $CONSECUTIVE_HIGH_CPU -eq $ALERT_THRESHOLD ]]; then
            HIGH_CPU_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_CPU=0
    fi

    # Create log entry
    log_entry=$(printf "%-8s %6.1f%% %6s°C %6s%% %6s°C %6s  %s" \
        "$timestamp" "$cpu_usage" "$cpu_temp" "$gpu_usage" "$gpu_temp" "$load_avg" "$top_proc")
    add_to_log "$log_entry"

    # Track all processes using >2% CPU for summary (optimized - read directly)
    while read -r proc_name proc_cpu; do
        [[ -z "$proc_name" || -z "$proc_cpu" ]] && continue
        proc_name=$(basename "$proc_name")
        [[ "$proc_name" =~ ^(ps|awk|grep|top|bash|sh|cat|sed|tput|printf|cpu_monitor)$ ]] && continue

        PROCESS_CPU_COUNT[$proc_name]=$((${PROCESS_CPU_COUNT[$proc_name]:-0} + 1))
        # Use awk instead of bc for faster arithmetic
        PROCESS_TOTAL_CPU[$proc_name]=$(awk "BEGIN {print ${PROCESS_TOTAL_CPU[$proc_name]:-0} + $proc_cpu}")
        # Add to history for time-based averages
        add_cpu_reading "$proc_name" "$proc_cpu"
    done < <(ps aux --sort=-%cpu | awk 'NR>1 && $3>2.0 && $11 !~ /(^ps$|^awk$|^grep$|^top$)/ {print $11, $3}')

    # Prune old history entries every 20 samples to avoid memory bloat
    if [[ $((SAMPLE_COUNT % 20)) -eq 0 ]]; then
        prune_history
    fi

    # Track GPU process usage (NVIDIA only) - current and peak VRAM
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        # Clear current readings before updating
        GPU_PROCESS_CURRENT=()
        while read -r proc_name gpu_mem; do
            [[ -z "$proc_name" || -z "$gpu_mem" || "$gpu_mem" == "-" ]] && continue
            [[ "$proc_name" == "nvidia-smi" ]] && continue

            # Store current VRAM usage
            GPU_PROCESS_CURRENT[$proc_name]=$gpu_mem

            # Track count and total for average calculation
            GPU_PROCESS_COUNT[$proc_name]=$((${GPU_PROCESS_COUNT[$proc_name]:-0} + 1))
            GPU_PROCESS_TOTAL[$proc_name]=$(awk "BEGIN {print ${GPU_PROCESS_TOTAL[$proc_name]:-0} + $gpu_mem}")

            # Track peak VRAM usage
            current_peak=${GPU_PROCESS_PEAK[$proc_name]:-0}
            if awk "BEGIN {exit !($gpu_mem > $current_peak)}"; then
                GPU_PROCESS_PEAK[$proc_name]=$gpu_mem
            fi
        done < <(track_gpu_processes)
    fi

    # Draw the TUI
    draw_screen

    sleep "$INTERVAL"
done
