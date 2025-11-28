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
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# htop-style bar characters (using Unicode block elements)
BAR_FULL='█'
BAR_HALF='▌'
BAR_EMPTY='─'  # Thin horizontal line for empty sections

# Helper: convert float to int (multiply by 10 to keep 1 decimal precision)
# Usage: float_to_int "65.5" -> 655
float_to_int() {
    local val=$1
    [[ -z "$val" || "$val" == "N/A" ]] && echo "0" && return
    # Remove decimal point and handle various formats
    local int_part="${val%%.*}"
    local dec_part="${val#*.}"
    [[ "$dec_part" == "$val" ]] && dec_part="0"  # No decimal point
    dec_part="${dec_part:0:1}"  # Take first decimal digit
    [[ -z "$dec_part" ]] && dec_part="0"
    echo "$((int_part * 10 + dec_part))"
}

# Get gradient color code for a temperature (uses 256-color ANSI)
# Usage: get_temp_gradient_color temp_int (already multiplied by 10)
# Sets TEMP_GRADIENT_COLOR variable
get_temp_gradient_color() {
    local temp_int=$1
    if [[ $temp_int -ge 850 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;196m'  # Red (>=85)
    elif [[ $temp_int -ge 750 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;202m'  # Red-orange (75-85)
    elif [[ $temp_int -ge 700 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;208m'  # Orange (70-75)
    elif [[ $temp_int -ge 650 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;214m'  # Orange-yellow (65-70)
    elif [[ $temp_int -ge 600 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;226m'  # Yellow (60-65)
    elif [[ $temp_int -ge 550 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;154m'  # Yellow-green (55-60)
    elif [[ $temp_int -ge 500 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;118m'  # Light green (50-55)
    elif [[ $temp_int -ge 450 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;46m'   # Green (45-50)
    elif [[ $temp_int -ge 350 ]]; then
        TEMP_GRADIENT_COLOR=$'\e[38;5;43m'   # Teal (35-45)
    else
        TEMP_GRADIENT_COLOR=$'\e[38;5;51m'   # Cyan (<35)
    fi
}

# Function to draw an htop-style temperature/usage bar
# Usage: draw_bar value max_value width [is_temp]
# is_temp: if 1, use temperature gradient; otherwise use CPU gradient
draw_bar() {
    local value=$1
    local max_value=$2
    local width=${3:-20}
    local is_temp=${4:-0}

    # Handle N/A or invalid values
    if [[ "$value" == "N/A" || -z "$value" ]]; then
        printf "%${width}s" "-"
        return
    fi

    # Calculate fill amount using integer math (value * width / max_value)
    local value_int=$(float_to_int "$value")
    local max_int=$((max_value * 10))
    local filled=$(( (value_int * width) / max_int ))
    [[ $filled -gt $width ]] && filled=$width
    [[ $filled -lt 0 ]] && filled=0

    # Determine color based on type
    local bar_color
    if [[ $is_temp -eq 1 ]]; then
        # Temperature gradient
        get_temp_gradient_color "$value_int"
        bar_color="$TEMP_GRADIENT_COLOR"
    else
        # CPU usage gradient (green < 50, yellow 50-80, red > 80)
        if [[ $value_int -ge 800 ]]; then
            bar_color=$RED
        elif [[ $value_int -ge 500 ]]; then
            bar_color=$YELLOW
        else
            bar_color=$GREEN
        fi
    fi

    # Build the bar
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

# Function to draw a compact temperature display with bar (htop style)
# Usage: draw_temp_with_bar label value [width]
draw_temp_with_bar() {
    local label=$1
    local value=$2
    local bar_width=${3:-15}

    if [[ "$value" == "N/A" || -z "$value" ]]; then
        printf "%-8s [%${bar_width}s] %5s" "$label" "-" "N/A"
        return
    fi

    printf "%-8s [" "$label"
    draw_bar "$value" 100 "$bar_width" 1
    printf "] %5.1f°C" "$value"
}

# Function to colorize a temperature value string based on gradient
# Usage: colorize_temp value_with_unit raw_value
# Returns: colored string
colorize_temp() {
    local display_val=$1
    local raw_val=$2

    if [[ "$display_val" == "-" || -z "$raw_val" || "$raw_val" == "-1" || "$raw_val" == "-1.0" ]]; then
        echo -ne "${DIM}-${NC}"
        return
    fi

    local val_int=$(float_to_int "$raw_val")
    get_temp_gradient_color "$val_int"
    echo -ne "${TEMP_GRADIENT_COLOR}${display_val}${NC}"
}

# Function to colorize and print a padded temperature value
# Usage: colorize_temp_padded raw_value width
# Prints directly (no return)
colorize_temp_padded() {
    local raw_val=$1
    local width=${2:-8}

    if [[ -z "$raw_val" || "$raw_val" == "-1" || "$raw_val" == "-1.0" ]]; then
        printf "%${width}s " "-"
        return
    fi

    local display_val="${raw_val}°C"
    local val_int=$(float_to_int "$raw_val")
    get_temp_gradient_color "$val_int"

    # Calculate padding (display_val length without counting the degree symbol as 2 bytes)
    local val_len=${#display_val}
    local pad=$((width - val_len + 1))  # +1 for degree symbol being multi-byte
    [[ $pad -lt 0 ]] && pad=0

    printf "%${pad}s${TEMP_GRADIENT_COLOR}%s${NC} " "" "$display_val"
}

# Ring buffer for per-core temperature history (for timeline visualization)
# Stores pre-computed color codes as a string: "0123456789..."
# 0=coolest (cyan) ... 9=hottest (bright red)
declare -A CORE_TEMP_RING_COLORS   # CORE_TEMP_RING_COLORS[C0]="0123456789..."
declare -i RING_MAX_SIZE=200       # Max readings per core

# Temperature color gradient (10 levels):
# 0: <35°C  - Cyan (very cool)
# 1: 35-45  - Blue-green
# 2: 45-50  - Green (cool)
# 3: 50-55  - Light green
# 4: 55-60  - Yellow-green
# 5: 60-65  - Yellow (warm)
# 6: 65-70  - Orange-yellow
# 7: 70-75  - Orange (hot)
# 8: 75-85  - Red-orange
# 9: >=85   - Red (critical)

# Function to add a temp to the ring buffer for a core
# Pre-computes color code at insert time for O(1) drawing
add_core_temp_to_ring() {
    local core=$1
    local temp=$2

    # Compute color code once at insert time (0-9 scale)
    local code="D"
    if [[ -n "$temp" && "$temp" != "N/A" ]]; then
        local temp_int=$(float_to_int "$temp")
        if [[ $temp_int -ge 850 ]]; then
            code="9"
        elif [[ $temp_int -ge 750 ]]; then
            code="8"
        elif [[ $temp_int -ge 700 ]]; then
            code="7"
        elif [[ $temp_int -ge 650 ]]; then
            code="6"
        elif [[ $temp_int -ge 600 ]]; then
            code="5"
        elif [[ $temp_int -ge 550 ]]; then
            code="4"
        elif [[ $temp_int -ge 500 ]]; then
            code="3"
        elif [[ $temp_int -ge 450 ]]; then
            code="2"
        elif [[ $temp_int -ge 350 ]]; then
            code="1"
        else
            code="0"
        fi
    fi

    # Append to string (no spaces needed, single chars)
    CORE_TEMP_RING_COLORS[$core]+="$code"

    # Trim if over limit (simple string slice)
    local current="${CORE_TEMP_RING_COLORS[$core]}"
    if [[ ${#current} -gt $RING_MAX_SIZE ]]; then
        CORE_TEMP_RING_COLORS[$core]="${current: -$RING_MAX_SIZE}"
    fi
}

# No rebuild needed - ring buffer is always in order
rebuild_core_temp_cache() {
    : # No-op, kept for compatibility
}

# Pre-built colored blocks for fast drawing (computed once)
# Using ANSI 256-color codes for smooth gradient
declare -a TEMP_BLOCKS=()
declare BLOCK_DIM=""

init_color_blocks() {
    local block='█'
    # 256-color ANSI: \e[38;5;Xm where X is color number
    # Color gradient from cyan -> green -> yellow -> orange -> red
    TEMP_BLOCKS[0]=$'\e[38;5;51m'"$block"$'\e[0m'   # Cyan (very cool <35)
    TEMP_BLOCKS[1]=$'\e[38;5;43m'"$block"$'\e[0m'   # Teal (35-45)
    TEMP_BLOCKS[2]=$'\e[38;5;46m'"$block"$'\e[0m'   # Green (45-50)
    TEMP_BLOCKS[3]=$'\e[38;5;118m'"$block"$'\e[0m'  # Light green (50-55)
    TEMP_BLOCKS[4]=$'\e[38;5;154m'"$block"$'\e[0m'  # Yellow-green (55-60)
    TEMP_BLOCKS[5]=$'\e[38;5;226m'"$block"$'\e[0m'  # Yellow (60-65)
    TEMP_BLOCKS[6]=$'\e[38;5;214m'"$block"$'\e[0m'  # Orange-yellow (65-70)
    TEMP_BLOCKS[7]=$'\e[38;5;208m'"$block"$'\e[0m'  # Orange (70-75)
    TEMP_BLOCKS[8]=$'\e[38;5;202m'"$block"$'\e[0m'  # Red-orange (75-85)
    TEMP_BLOCKS[9]=$'\e[38;5;196m'"$block"$'\e[0m'  # Red (>=85)
    BLOCK_DIM="${DIM}─${NC}"
}

# Function to draw a temperature history timeline for a specific core
# Usage: draw_temp_history core_name width
# Ultra-fast: just reads pre-computed color codes and maps to blocks
draw_temp_history() {
    local core=$1
    local width=$2

    # Get color codes string
    local codes="${CORE_TEMP_RING_COLORS[$core]:-}"
    local num_codes=${#codes}

    # If we have more readings than width, take the last 'width'
    local start_idx=0
    if [[ $num_codes -gt $width ]]; then
        start_idx=$((num_codes - width))
    fi

    # Build bar from pre-computed codes
    local bar=""
    local drawn=0
    local i code
    for ((i=start_idx; i<num_codes && drawn<width; i++)); do
        code="${codes:$i:1}"
        if [[ "$code" =~ ^[0-9]$ ]]; then
            bar+="${TEMP_BLOCKS[$code]}"
        else
            bar+="$BLOCK_DIM"
        fi
        ((drawn++))
    done

    # Fill remaining with dim blocks
    local remaining=$((width - drawn))
    while [[ $remaining -gt 0 ]]; do
        bar+="$BLOCK_DIM"
        ((remaining--))
    done

    echo -ne "$bar"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Set monitoring interval (default 1 second for responsive updates)
INTERVAL=${1:-1}

# Terminal dimensions
TERM_COLS=$(tput cols)
TERM_ROWS=$(tput lines)

# Function to get CPU temperature (average of all cores)
get_cpu_temp() {
    if command -v sensors >/dev/null 2>&1; then
        # Extract only the first temperature from each Core line (skip high/crit values)
        sensors | grep -E "^Core [0-9]+:" | awk -F'[+°]' '{print $2}' | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}'
    elif [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        echo "scale=1; $temp_raw / 1000" | bc
    else
        echo "N/A"
    fi
}

# Function to get per-core CPU temperatures
# Returns: "core0:temp0 core1:temp1 ..." or empty if not available
get_cpu_core_temps() {
    if command -v sensors >/dev/null 2>&1; then
        sensors | grep -E "Core [0-9]+:" | while read -r line; do
            core_num=$(echo "$line" | grep -oE "Core [0-9]+" | grep -oE "[0-9]+")
            temp=$(echo "$line" | grep -oE '\+[0-9]+\.[0-9]+' | head -1 | tr -d '+')
            if [[ -n "$core_num" && -n "$temp" ]]; then
                echo -n "C${core_num}:${temp} "
            fi
        done
    elif [[ -d /sys/class/thermal ]]; then
        # Try to read from thermal zones
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -f "$zone" ]]; then
                zone_num=$(echo "$zone" | grep -oE "zone[0-9]+" | grep -oE "[0-9]+")
                temp_raw=$(cat "$zone" 2>/dev/null)
                if [[ -n "$temp_raw" ]]; then
                    temp=$(echo "scale=1; $temp_raw / 1000" | bc)
                    echo -n "Z${zone_num}:${temp} "
                fi
            fi
        done
    fi
}

# Variables for CPU usage calculation (using /proc/stat - much faster than top)
PREV_CPU_IDLE=0
PREV_CPU_TOTAL=0
CURRENT_CPU_USAGE_RESULT="0.0"

# Function to update CPU usage from /proc/stat (fast, no external processes)
# Sets CURRENT_CPU_USAGE_RESULT global variable (avoids subshell issue)
update_cpu_usage() {
    local cpu_line
    read -r cpu_line < /proc/stat
    local -a cpu_vals=($cpu_line)
    # cpu user nice system idle iowait irq softirq steal guest guest_nice
    local user=${cpu_vals[1]}
    local nice=${cpu_vals[2]}
    local system=${cpu_vals[3]}
    local idle=${cpu_vals[4]}
    local iowait=${cpu_vals[5]:-0}

    local total=$((user + nice + system + idle + iowait))
    local idle_total=$((idle + iowait))

    if [[ $PREV_CPU_TOTAL -ne 0 ]]; then
        local diff_total=$((total - PREV_CPU_TOTAL))
        local diff_idle=$((idle_total - PREV_CPU_IDLE))
        if [[ $diff_total -gt 0 ]]; then
            local usage=$(( (diff_total - diff_idle) * 1000 / diff_total ))
            # Handle single digit case
            if [[ ${#usage} -eq 1 ]]; then
                CURRENT_CPU_USAGE_RESULT="0.${usage}"
            elif [[ ${#usage} -eq 2 ]]; then
                CURRENT_CPU_USAGE_RESULT="${usage:0:1}.${usage:1:1}"
            else
                CURRENT_CPU_USAGE_RESULT="${usage:0:-1}.${usage: -1}"
            fi
        else
            CURRENT_CPU_USAGE_RESULT="0.0"
        fi
    else
        CURRENT_CPU_USAGE_RESULT="0.0"
    fi

    PREV_CPU_TOTAL=$total
    PREV_CPU_IDLE=$idle_total
}

# Wrapper for compatibility - but prefer calling update_cpu_usage directly
get_cpu_usage() {
    update_cpu_usage
    echo "$CURRENT_CPU_USAGE_RESULT"
}

# Function to get load average (optimized - read directly)
get_load_avg() {
    local loadavg
    read -r loadavg _ < /proc/loadavg
    echo "$loadavg"
}

# Function to get fan speeds (smarter detection for different laptop/desktop vendors)
# Returns: "fan1:rpm fan2:rpm ..." or empty if not available
get_fan_speeds() {
    local found_fans=0

    if command -v sensors >/dev/null 2>&1; then
        # Try multiple patterns that different vendors use:
        # - Standard: fan1:, fan2:, etc.
        # - Dell/HP/Lenovo: Processor Fan:, CPU Fan:, System Fan:, Chassis Fan:
        # - Thinkpad: Fan1:, Fan:
        # - Generic: anything with "fan" and RPM
        sensors 2>/dev/null | grep -iE '(^[[:space:]]*fan[0-9]*:|^[[:space:]]*(processor|cpu|system|chassis|gpu|graphics|rear|front|aux|pch)[[:space:]]*fan|fan[[:space:]]*:)' | while read -r line; do
            # Extract fan name (everything before the colon)
            fan_name=$(echo "$line" | awk -F: '{print $1}' | xargs | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
            # Extract RPM value
            rpm=$(echo "$line" | grep -oE '[0-9]+ RPM' | awk '{print $1}')
            if [[ -n "$fan_name" && -n "$rpm" && "$rpm" -gt 0 ]]; then
                # Normalize fan name for display
                fan_name="${fan_name//processor_fan/cpu_fan}"
                echo -n "${fan_name}:${rpm} "
                found_fans=1
            fi
        done
    fi

    # Fallback: check /sys/class/hwmon for fan inputs if sensors didn't find any
    if [[ $found_fans -eq 0 ]]; then
        for hwmon in /sys/class/hwmon/hwmon*; do
            [[ -d "$hwmon" ]] || continue
            for fan_input in "$hwmon"/fan*_input; do
                [[ -f "$fan_input" ]] || continue
                rpm=$(cat "$fan_input" 2>/dev/null)
                if [[ -n "$rpm" && "$rpm" -gt 0 ]]; then
                    # Get fan number from filename
                    fan_num=$(echo "$fan_input" | grep -oE 'fan[0-9]+' | grep -oE '[0-9]+')
                    # Try to get label if available
                    label_file="${fan_input%_input}_label"
                    if [[ -f "$label_file" ]]; then
                        fan_name=$(cat "$label_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
                    else
                        fan_name="fan${fan_num}"
                    fi
                    echo -n "${fan_name}:${rpm} "
                fi
            done
        done
    fi

    # Additional fallback: check thinkpad_hwmon specifically for ThinkPad laptops
    if [[ -f /proc/acpi/ibm/fan ]]; then
        local tp_speed=$(grep -E '^speed:' /proc/acpi/ibm/fan 2>/dev/null | awk '{print $2}')
        if [[ -n "$tp_speed" && "$tp_speed" -gt 0 ]]; then
            echo -n "thinkpad_fan:${tp_speed} "
        fi
    fi
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
declare -A PROCESS_TOTAL_CPU_INT=()  # Integer version (×10 for one decimal)
declare -i SAMPLE_COUNT=0
declare -i HIGH_CPU_COUNT=0
declare -i HIGH_TEMP_COUNT=0
declare -i HIGH_GPU_TEMP_COUNT=0

# Consecutive sample counters for smarter alerts (trigger after 3 consecutive samples)
declare -i CONSECUTIVE_HIGH_CPU=0
declare -i CONSECUTIVE_HIGH_CPU_TEMP=0
declare -i CONSECUTIVE_HIGH_GPU_TEMP=0
declare -i ALERT_THRESHOLD=3

# Track GPU usage over time (integer ×10 for one decimal precision)
declare -i GPU_USAGE_TOTAL_INT=0
declare -i GPU_USAGE_SAMPLES=0

# Track GPU usage per process (NVIDIA only)
declare -A GPU_PROCESS_CURRENT=()  # Current VRAM per process
declare -A GPU_PROCESS_PEAK=()     # Peak VRAM per process (for summary)
declare -A GPU_PROCESS_COUNT=()    # Sample count per process (for average)
declare -A GPU_PROCESS_TOTAL=()    # Total VRAM across samples (for average)

# Current values for display
declare CURRENT_CPU_USAGE=0
declare CURRENT_CPU_TEMP="N/A"
declare CURRENT_CORE_TEMPS=""  # Per-core temperatures
declare CURRENT_GPU_USAGE="N/A"
declare CURRENT_GPU_TEMP="N/A"
declare CURRENT_LOAD="0"
declare CURRENT_FAN_SPEEDS=""    # Current fan speeds: "fan1:rpm fan2:rpm ..."

# Historical readings for time-based averages (1m, 5m, 15m)
# Using fixed-size arrays with index tracking for O(1) insertions
# Format: "timestamp:process:cpu_percent"
declare -a CPU_HISTORY=()
declare -a GPU_HISTORY=()
declare -a TEMP_HISTORY=()       # Overall CPU temp history: "timestamp:temp"
declare -a CORE_TEMP_HISTORY=()  # Per-core temp history: "timestamp:core:temp"
declare -a FAN_SPEED_HISTORY=()  # Fan speed history: "timestamp:fan:rpm"
declare CURRENT_TIMESTAMP=$(date +%s)

# Max history sizes (15 min @ 1s = 900, but with multiple processes/cores it can be more)
declare -i MAX_CPU_HISTORY=5000
declare -i MAX_TEMP_HISTORY=1000
declare -i MAX_CORE_TEMP_HISTORY=10000
declare -i MAX_FAN_HISTORY=2000

# Add a CPU reading to history (uses cached timestamp)
add_cpu_reading() {
    CPU_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Add a GPU reading to history
add_gpu_reading() {
    GPU_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Add overall CPU temp to history
add_temp_reading() {
    TEMP_HISTORY+=("$CURRENT_TIMESTAMP:$1")
}

# Add fan speed to history
add_fan_speed_reading() {
    # $1 = fan name (e.g., fan1), $2 = rpm value
    FAN_SPEED_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Add per-core temp to history (uses ring buffer for timeline, legacy array for averages)
add_core_temp_reading() {
    # $1 = core name (e.g., C0), $2 = temp value
    # Add to ring buffer for timeline visualization (fast, fixed size)
    add_core_temp_to_ring "$1" "$2"
    # Add to legacy array for averages calculation
    CORE_TEMP_HISTORY+=("$CURRENT_TIMESTAMP:$1:$2")
}

# Prune old entries - simple size-based truncation (keeps newest)
# Much faster than timestamp-based filtering
prune_history() {
    # Prune CPU history - just keep the last MAX entries
    if [[ ${#CPU_HISTORY[@]} -gt $MAX_CPU_HISTORY ]]; then
        CPU_HISTORY=("${CPU_HISTORY[@]: -$MAX_CPU_HISTORY}")
    fi

    # Prune temp history
    if [[ ${#TEMP_HISTORY[@]} -gt $MAX_TEMP_HISTORY ]]; then
        TEMP_HISTORY=("${TEMP_HISTORY[@]: -$MAX_TEMP_HISTORY}")
    fi

    # Prune core temp history
    if [[ ${#CORE_TEMP_HISTORY[@]} -gt $MAX_CORE_TEMP_HISTORY ]]; then
        CORE_TEMP_HISTORY=("${CORE_TEMP_HISTORY[@]: -$MAX_CORE_TEMP_HISTORY}")
    fi

    # Prune fan speed history
    if [[ ${#FAN_SPEED_HISTORY[@]} -gt $MAX_FAN_HISTORY ]]; then
        FAN_SPEED_HISTORY=("${FAN_SPEED_HISTORY[@]: -$MAX_FAN_HISTORY}")
    fi
}

# Calculate all time-based averages in ONE pass using awk (fast!)
# Also calculates cpu_secs for each process
# Output: proc cpu_secs avg_10s avg_1m avg_5m avg_15m
get_top_cpu_summary_timed() {
    local limit=${1:-5}
    local now=$CURRENT_TIMESTAMP

    # Build process totals string for awk (use : as separator for consistency)
    # Convert from INT (×10) back to float for display
    local proc_data=""
    for proc in "${!PROCESS_CPU_COUNT[@]}"; do
        local total_int=${PROCESS_TOTAL_CPU_INT[$proc]:-0}
        # Convert back: 1234 -> 123.4
        local total
        if [[ ${#total_int} -le 1 ]]; then
            total="0.${total_int}"
        else
            total="${total_int:0:-1}.${total_int: -1}"
        fi
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

        if (age <= 10) { sum10[proc] += cpu; cnt10[proc]++ }
        if (age <= 60) { sum1[proc] += cpu; cnt1[proc]++ }
        if (age <= 300) { sum5[proc] += cpu; cnt5[proc]++ }
        if (age <= 900) { sum15[proc] += cpu; cnt15[proc]++ }
    }

    END {
        for (proc in totals) {
            cpu_secs = (totals[proc] * interval) / 100
            avg10 = (cnt10[proc] > 0) ? sum10[proc] / cnt10[proc] : -1
            avg1 = (cnt1[proc] > 0) ? sum1[proc] / cnt1[proc] : -1
            avg5 = (cnt5[proc] > 0) ? sum5[proc] / cnt5[proc] : -1
            avg15 = (cnt15[proc] > 0) ? sum15[proc] / cnt15[proc] : -1
            printf "%s %.1f %.1f %.1f %.1f %.1f\n", proc, cpu_secs, avg10, avg1, avg5, avg15
        }
    }
    ' | sort -k2 -rn | head -$limit
}

# Calculate overall CPU temp averages over time windows
# Output: avg_10s avg_1m avg_5m avg_15m
get_temp_averages() {
    local now=$CURRENT_TIMESTAMP
    printf '%s\n' "${TEMP_HISTORY[@]}" | awk -F: -v now="$now" '
    {
        ts = $1
        temp = $2
        age = now - ts

        if (age <= 10) { sum10 += temp; cnt10++ }
        if (age <= 60) { sum1 += temp; cnt1++ }
        if (age <= 300) { sum5 += temp; cnt5++ }
        if (age <= 900) { sum15 += temp; cnt15++ }
    }
    END {
        avg10 = (cnt10 > 0) ? sum10 / cnt10 : -1
        avg1 = (cnt1 > 0) ? sum1 / cnt1 : -1
        avg5 = (cnt5 > 0) ? sum5 / cnt5 : -1
        avg15 = (cnt15 > 0) ? sum15 / cnt15 : -1
        printf "%.1f %.1f %.1f %.1f\n", avg10, avg1, avg5, avg15
    }'
}

# Calculate per-core temp averages over time windows
# Output: core avg_10s avg_1m avg_5m avg_15m (one line per core)
get_core_temp_averages() {
    local now=$CURRENT_TIMESTAMP
    printf '%s\n' "${CORE_TEMP_HISTORY[@]}" | awk -F: -v now="$now" '
    {
        ts = $1
        core = $2
        temp = $3
        age = now - ts

        if (age <= 10) { sum10[core] += temp; cnt10[core]++ }
        if (age <= 60) { sum1[core] += temp; cnt1[core]++ }
        if (age <= 300) { sum5[core] += temp; cnt5[core]++ }
        if (age <= 900) { sum15[core] += temp; cnt15[core]++ }
        cores[core] = 1
    }
    END {
        for (core in cores) {
            avg10 = (cnt10[core] > 0) ? sum10[core] / cnt10[core] : -1
            avg1 = (cnt1[core] > 0) ? sum1[core] / cnt1[core] : -1
            avg5 = (cnt5[core] > 0) ? sum5[core] / cnt5[core] : -1
            avg15 = (cnt15[core] > 0) ? sum15[core] / cnt15[core] : -1
            printf "%s %.1f %.1f %.1f %.1f\n", core, avg10, avg1, avg5, avg15
        }
    }' | sort -t'C' -k2 -n
}

# Calculate fan speed averages over time windows
# Output: fan avg_10s avg_1m avg_5m avg_15m (one line per fan)
get_fan_speed_averages() {
    local now=$CURRENT_TIMESTAMP
    printf '%s\n' "${FAN_SPEED_HISTORY[@]}" | awk -F: -v now="$now" '
    {
        ts = $1
        fan = $2
        rpm = $3
        age = now - ts

        if (age <= 10) { sum10[fan] += rpm; cnt10[fan]++ }
        if (age <= 60) { sum1[fan] += rpm; cnt1[fan]++ }
        if (age <= 300) { sum5[fan] += rpm; cnt5[fan]++ }
        if (age <= 900) { sum15[fan] += rpm; cnt15[fan]++ }
        fans[fan] = 1
    }
    END {
        for (fan in fans) {
            avg10 = (cnt10[fan] > 0) ? sum10[fan] / cnt10[fan] : -1
            avg1 = (cnt1[fan] > 0) ? sum1[fan] / cnt1[fan] : -1
            avg5 = (cnt5[fan] > 0) ? sum5[fan] / cnt5[fan] : -1
            avg15 = (cnt15[fan] > 0) ? sum15[fan] / cnt15[fan] : -1
            printf "%s %.0f %.0f %.0f %.0f\n", fan, avg10, avg1, avg5, avg15
        }
    }' | sort
}

# Function to get top GPU consumers for display (current and average VRAM usage)
# Output: proc_name current_vram avg_vram
get_top_gpu_summary() {
    local limit=${1:-5}
    for proc in "${!GPU_PROCESS_CURRENT[@]}"; do
        local current=${GPU_PROCESS_CURRENT[$proc]}
        local count=${GPU_PROCESS_COUNT[$proc]:-1}
        local total=${GPU_PROCESS_TOTAL[$proc]:-$current}
        # Integer division with one decimal: (total * 10 / count) then format
        local avg_int=$(( (total * 10) / count ))
        local avg="${avg_int:0:-1}.${avg_int: -1}"
        [[ ${#avg_int} -eq 1 ]] && avg="0.$avg_int"
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
        # Integer division with one decimal
        local avg_int=$(( (total * 10) / count ))
        local avg="${avg_int:0:-1}.${avg_int: -1}"
        [[ ${#avg_int} -eq 1 ]] && avg="0.$avg_int"
        echo "$proc $peak $avg"
    done | sort -k2 -rn | head -$limit
}

# Function to draw the TUI
draw_screen() {
    # Refresh terminal dimensions (in case of resize)
    TERM_COLS=$(tput cols)
    TERM_ROWS=$(tput lines)

    # Clear screen and move cursor to top
    tput clear
    tput cup 0 0

    local width=$TERM_COLS
    [[ $width -lt 60 ]] && width=60  # Minimum width
    local half_width=$((width / 2 - 2))

    # Dynamic title bar that spans terminal width
    local title_line=""
    for ((i=0; i<width; i++)); do title_line+="═"; done
    local title_text="  🖥️  REAL-TIME SYSTEM MONITOR  │  GPU: $GPU_TYPE  │  Samples: $SAMPLE_COUNT  │  Ctrl+C to exit"

    echo -e "${CYAN}${BOLD}${title_line}${NC}"
    echo -e "${CYAN}${BOLD}${title_text}${NC}"
    echo -e "${CYAN}${BOLD}${title_line}${NC}"

    # Current stats bar with colors (using integer comparison for speed)
    local cpu_color=$GREEN temp_color=$GREEN gpu_color=$GREEN gpu_temp_color=$GREEN
    local cpu_int=$(float_to_int "$CURRENT_CPU_USAGE")
    local temp_int=$(float_to_int "$CURRENT_CPU_TEMP")
    local gpu_int=$(float_to_int "$CURRENT_GPU_USAGE")
    local gpu_temp_int=$(float_to_int "$CURRENT_GPU_TEMP")

    if [[ "$CURRENT_CPU_USAGE" != "N/A" ]] && [[ $cpu_int -gt 800 ]]; then
        cpu_color=$RED
    elif [[ "$CURRENT_CPU_USAGE" != "N/A" ]] && [[ $cpu_int -gt 500 ]]; then
        cpu_color=$YELLOW
    fi

    if [[ "$CURRENT_CPU_TEMP" != "N/A" ]] && [[ $temp_int -gt 800 ]]; then
        temp_color=$RED
    elif [[ "$CURRENT_CPU_TEMP" != "N/A" ]] && [[ $temp_int -gt 700 ]]; then
        temp_color=$YELLOW
    fi

    if [[ "$CURRENT_GPU_USAGE" != "N/A" ]] && [[ $gpu_int -gt 800 ]]; then
        gpu_color=$RED
    elif [[ "$CURRENT_GPU_USAGE" != "N/A" ]] && [[ $gpu_int -gt 500 ]]; then
        gpu_color=$YELLOW
    fi

    if [[ "$CURRENT_GPU_TEMP" != "N/A" ]] && [[ $gpu_temp_int -gt 800 ]]; then
        gpu_temp_color=$RED
    elif [[ "$CURRENT_GPU_TEMP" != "N/A" ]] && [[ $gpu_temp_int -gt 700 ]]; then
        gpu_temp_color=$YELLOW
    fi

    echo ""

    # Calculate dynamic bar width based on terminal width
    # Format: "  LABEL      [BAR] VALUE"
    # Main bars: "  CPU Usage  [...]  56.2%    Load: 2.34" - label=12, brackets=2, value~20 = ~34 chars overhead
    # Core bars: "  C0     [...] 65.0°C" - label=9, brackets=2, value=8 = ~19 chars overhead
    local main_bar_width=$((TERM_COLS - 36))
    local core_bar_width=$((TERM_COLS - 22))

    # Minimum bar width of 20
    [[ $main_bar_width -lt 20 ]] && main_bar_width=20
    [[ $core_bar_width -lt 20 ]] && core_bar_width=20

    # htop-style visual display with bars
    # CPU Usage bar (uses CPU gradient: green < 50, yellow 50-80, red > 80)
    printf "  ${BOLD}CPU Usage${NC}  ["
    draw_bar "$CURRENT_CPU_USAGE" 100 $main_bar_width 0
    printf "] ${cpu_color}%5.1f%%${NC}  ${DIM}Load: %s${NC}\n" "$CURRENT_CPU_USAGE" "$CURRENT_LOAD"

    # CPU Temperature bar (uses temperature gradient)
    printf "  ${BOLD}CPU Temp${NC}   ["
    draw_bar "$CURRENT_CPU_TEMP" 100 $main_bar_width 1
    local temp_int=$(float_to_int "$CURRENT_CPU_TEMP")
    get_temp_gradient_color "$temp_int"
    printf "] ${TEMP_GRADIENT_COLOR}%5s°C${NC}\n" "$CURRENT_CPU_TEMP"

    # GPU Usage bar (if available)
    if [[ "$CURRENT_GPU_USAGE" != "N/A" ]]; then
        printf "  ${BOLD}GPU Usage${NC}  ["
        draw_bar "$CURRENT_GPU_USAGE" 100 $main_bar_width 0
        printf "] ${gpu_color}%5s%%${NC}\n" "$CURRENT_GPU_USAGE"
    fi

    # GPU Temperature bar (if available)
    if [[ "$CURRENT_GPU_TEMP" != "N/A" ]]; then
        printf "  ${BOLD}GPU Temp${NC}   ["
        draw_bar "$CURRENT_GPU_TEMP" 100 $main_bar_width 1
        local gpu_temp_int=$(float_to_int "$CURRENT_GPU_TEMP")
        get_temp_gradient_color "$gpu_temp_int"
        printf "] ${TEMP_GRADIENT_COLOR}%5s°C${NC}\n" "$CURRENT_GPU_TEMP"
    fi

    # Display per-core temperatures with bars if available
    if [[ -n "$CURRENT_CORE_TEMPS" ]]; then
        echo ""
        echo -e "  ${BOLD}${BLUE}Per-Core Temperatures:${NC}"
        for core_temp in $CURRENT_CORE_TEMPS; do
            core_name="${core_temp%:*}"
            temp_val="${core_temp#*:}"
            # Color code each core temp using gradient
            local core_temp_int=$(float_to_int "$temp_val")
            get_temp_gradient_color "$core_temp_int"
            printf "  %-6s ["  "$core_name"
            draw_bar "$temp_val" 100 $core_bar_width 1
            printf "] ${TEMP_GRADIENT_COLOR}%5.1f°C${NC}\n" "$temp_val"
        done

        # Temperature history timeline (color-coded over time)
        echo ""
        echo -e "  ${BOLD}${BLUE}Temperature History:${NC} ${DIM}(oldest ← → newest)${NC}"
        local history_bar_width=$((TERM_COLS - 12))
        [[ $history_bar_width -lt 20 ]] && history_bar_width=20

        # Rebuild cache once before drawing all cores (major speedup)
        rebuild_core_temp_cache

        for core_temp in $CURRENT_CORE_TEMPS; do
            core_name="${core_temp%:*}"
            printf "  %-6s [" "$core_name"
            draw_temp_history "$core_name" $history_bar_width
            printf "]\n"
        done
    fi
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

    # Dynamic separator line
    local separator_line=""
    for ((i=0; i<width; i++)); do separator_line+="─"; done
    echo -e "${CYAN}${separator_line}${NC}"

    # Temperature averages section
    printf "  ${BLUE}${BOLD}🌡️  CPU TEMPERATURE AVERAGES${NC}\n"
    printf "  %-12s %8s %8s %8s %8s\n" "" "10s" "1m" "5m" "15m"
    printf "  %-12s %8s %8s %8s %8s\n" "────────────" "────────" "────────" "────────" "────────"

    # Overall CPU temp averages (with color coding)
    read -r raw10 raw1 raw5 raw15 <<< "$(get_temp_averages)"
    printf "  ${BOLD}%-12s${NC} " "Overall"
    colorize_temp_padded "$raw10" 8
    colorize_temp_padded "$raw1" 8
    colorize_temp_padded "$raw5" 8
    colorize_temp_padded "$raw15" 8
    echo ""

    # Per-core temp averages (with color coding)
    get_core_temp_averages | while read -r core raw10 raw1 raw5 raw15; do
        [[ -z "$core" ]] && continue
        printf "  %-12s " "$core"
        colorize_temp_padded "$raw10" 8
        colorize_temp_padded "$raw1" 8
        colorize_temp_padded "$raw5" 8
        colorize_temp_padded "$raw15" 8
        echo ""
    done

    echo ""

    # Fan speeds section
    if [[ -n "$CURRENT_FAN_SPEEDS" ]]; then
        printf "  ${BLUE}${BOLD}🌀 FAN SPEEDS${NC}\n"
        printf "  %-12s %10s %10s %10s %10s %10s\n" "FAN" "CURRENT" "10s" "1m" "5m" "15m"
        printf "  %-12s %10s %10s %10s %10s %10s\n" "────────────" "──────────" "──────────" "──────────" "──────────" "──────────"

        # Display current fan speeds with averages
        get_fan_speed_averages | while read -r fan avg10 avg1 avg5 avg15; do
            [[ -z "$fan" ]] && continue
            # Get current speed for this fan
            current_rpm=""
            for fan_speed in $CURRENT_FAN_SPEEDS; do
                fan_name="${fan_speed%:*}"
                if [[ "$fan_name" == "$fan" ]]; then
                    current_rpm="${fan_speed#*:}"
                    break
                fi
            done
            [[ -z "$current_rpm" ]] && current_rpm="-"
            [[ "$avg10" == "-1" ]] && avg10="-" || avg10="${avg10}"
            [[ "$avg1" == "-1" ]] && avg1="-" || avg1="${avg1}"
            [[ "$avg5" == "-1" ]] && avg5="-" || avg5="${avg5}"
            [[ "$avg15" == "-1" ]] && avg15="-" || avg15="${avg15}"
            printf "  %-12s %9s %9s %9s %9s %9s\n" "$fan" "${current_rpm}RPM" "${avg10}RPM" "${avg1}RPM" "${avg5}RPM" "${avg15}RPM"
        done
        echo ""
    fi

    echo -e "${CYAN}${separator_line}${NC}"

    # CPU Consumers with time-based averages
    printf "  ${BLUE}${BOLD}📊 TOP CPU CONSUMERS${NC}\n"
    printf "  %-18s %8s %7s %7s %7s %7s\n" "PROCESS" "CPU-SEC" "10s" "1m" "5m" "15m"
    printf "  %-18s %8s %7s %7s %7s %7s\n" "──────────────────" "────────" "───────" "───────" "───────" "───────"

    # Get top CPU processes with time-based averages (uses fast awk processing)
    get_top_cpu_summary_timed 5 | while read -r cpu_proc cpu_secs avg_10s avg_1m avg_5m avg_15m; do
        [[ -z "$cpu_proc" ]] && continue
        cpu_proc="${cpu_proc:0:18}"

        # Format averages (-1 means no data)
        [[ "$avg_10s" == "-1.0" || "$avg_10s" == "-1" ]] && avg_10s="-" || avg_10s="${avg_10s}%"
        [[ "$avg_1m" == "-1.0" || "$avg_1m" == "-1" ]] && avg_1m="-" || avg_1m="${avg_1m}%"
        [[ "$avg_5m" == "-1.0" || "$avg_5m" == "-1" ]] && avg_5m="-" || avg_5m="${avg_5m}%"
        [[ "$avg_15m" == "-1.0" || "$avg_15m" == "-1" ]] && avg_15m="-" || avg_15m="${avg_15m}%"

        printf "  %-18s %7ss %7s %7s %7s %7s\n" "$cpu_proc" "$cpu_secs" "$avg_10s" "$avg_1m" "$avg_5m" "$avg_15m"
    done

    echo ""

    # GPU Consumers
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        printf "  ${BLUE}${BOLD}🎮 TOP GPU CONSUMERS (VRAM)${NC}\n"
        printf "  %-18s %10s %10s\n" "PROCESS" "CURRENT" "AVG"
        printf "  %-18s %10s %10s\n" "──────────────────" "──────────" "──────────"

        local gpu_data=$(get_top_gpu_summary 5)
        while read -r gpu_proc gpu_current gpu_avg; do
            [[ -z "$gpu_proc" ]] && continue
            gpu_proc="${gpu_proc:0:18}"
            printf "  %-18s %9sMiB %9sMiB\n" "$gpu_proc" "$gpu_current" "$gpu_avg"
        done <<< "$gpu_data"
    fi

    echo -e "${CYAN}${BOLD}${title_line}${NC}"
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
        # Integer division: GPU_USAGE_TOTAL_INT is ×10, so divide by samples then format
        local avg_gpu_int=$((GPU_USAGE_TOTAL_INT / GPU_USAGE_SAMPLES))
        local avg_gpu="${avg_gpu_int:0:-1}.${avg_gpu_int: -1}"
        [[ ${#avg_gpu_int} -eq 1 ]] && avg_gpu="0.$avg_gpu_int"
        echo -e "Average GPU usage: ${avg_gpu}%"
    fi
    echo ""
    echo -e "${BLUE}Top CPU Consumers (sorted by CPU-seconds):${NC}"
    printf "  %-18s %8s %7s %7s %7s %7s\n" "PROCESS" "CPU-SEC" "10s" "1m" "5m" "15m"
    printf "  %-18s %8s %7s %7s %7s %7s\n" "──────────────────" "────────" "───────" "───────" "───────" "───────"
    get_top_cpu_summary_timed 10 | while read -r proc cpu_secs avg_10s avg_1m avg_5m avg_15m; do
        # Format averages (-1 means no data)
        [[ "$avg_10s" == "-1.0" || "$avg_10s" == "-1" ]] && avg_10s="-" || avg_10s="${avg_10s}%"
        [[ "$avg_1m" == "-1.0" || "$avg_1m" == "-1" ]] && avg_1m="-" || avg_1m="${avg_1m}%"
        [[ "$avg_5m" == "-1.0" || "$avg_5m" == "-1" ]] && avg_5m="-" || avg_5m="${avg_5m}%"
        [[ "$avg_15m" == "-1.0" || "$avg_15m" == "-1" ]] && avg_15m="-" || avg_15m="${avg_15m}%"
        printf "  %-18s %7ss %7s %7s %7s %7s\n" "$proc" "$cpu_secs" "$avg_10s" "$avg_1m" "$avg_5m" "$avg_15m"
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

# Initialize color blocks for fast drawing
init_color_blocks

# Monitoring loop
while true; do
    SAMPLE_COUNT+=1
    CURRENT_TIMESTAMP=$(date +%s)
    timestamp=$(date '+%H:%M:%S')
    update_cpu_usage
    cpu_usage="$CURRENT_CPU_USAGE_RESULT"
    cpu_temp=$(get_cpu_temp)
    core_temps=$(get_cpu_core_temps)
    load_avg=$(get_load_avg)
    top_proc=$(get_top_process | cut -c1-30)

    # Get GPU stats
    gpu_temp=$(get_gpu_temp)
    gpu_usage=$(get_gpu_usage)

    # Get fan speeds
    fan_speeds=$(get_fan_speeds)

    # Update current values for display
    CURRENT_CPU_USAGE=$cpu_usage
    CURRENT_CPU_TEMP=$cpu_temp
    CURRENT_CORE_TEMPS=$core_temps
    CURRENT_GPU_USAGE=$gpu_usage
    CURRENT_GPU_TEMP=$gpu_temp
    CURRENT_LOAD=$load_avg
    CURRENT_FAN_SPEEDS=$fan_speeds

    # Add temperature readings to history for time-based averages
    if [[ "$cpu_temp" != "N/A" ]]; then
        add_temp_reading "$cpu_temp"
    fi
    for core_temp in $core_temps; do
        core_name="${core_temp%:*}"
        temp_val="${core_temp#*:}"
        if [[ -n "$temp_val" ]]; then
            add_core_temp_reading "$core_name" "$temp_val"
        fi
    done

    # Add fan speed readings to history
    for fan_speed in $fan_speeds; do
        fan_name="${fan_speed%:*}"
        rpm_val="${fan_speed#*:}"
        if [[ -n "$rpm_val" ]]; then
            add_fan_speed_reading "$fan_name" "$rpm_val"
        fi
    done

    # Track high CPU temp events (only count once after 3 consecutive samples above threshold)
    cpu_temp_int=$(float_to_int "$cpu_temp")
    if [[ "$cpu_temp" != "N/A" ]] && [[ $cpu_temp_int -gt 700 ]]; then
        CONSECUTIVE_HIGH_CPU_TEMP+=1
        if [[ $CONSECUTIVE_HIGH_CPU_TEMP -eq $ALERT_THRESHOLD ]]; then
            HIGH_TEMP_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_CPU_TEMP=0
    fi

    # Track high GPU temp events (only count once after 3 consecutive samples above threshold)
    gpu_temp_int=$(float_to_int "$gpu_temp")
    if [[ "$gpu_temp" != "N/A" ]] && [[ $gpu_temp_int -gt 700 ]]; then
        CONSECUTIVE_HIGH_GPU_TEMP+=1
        if [[ $CONSECUTIVE_HIGH_GPU_TEMP -eq $ALERT_THRESHOLD ]]; then
            HIGH_GPU_TEMP_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_GPU_TEMP=0
    fi

    # Track GPU usage for summary (integer math)
    if [[ "$gpu_usage" != "N/A" ]]; then
        gpu_usage_int=$(float_to_int "$gpu_usage")
        GPU_USAGE_TOTAL_INT=$((GPU_USAGE_TOTAL_INT + gpu_usage_int))
        GPU_USAGE_SAMPLES=$((GPU_USAGE_SAMPLES + 1))
    fi

    # Track high CPU events (only count once after 3 consecutive samples above threshold)
    cpu_usage_int=$(float_to_int "$cpu_usage")
    if [[ $cpu_usage_int -gt 800 ]]; then
        CONSECUTIVE_HIGH_CPU+=1
        if [[ $CONSECUTIVE_HIGH_CPU -eq $ALERT_THRESHOLD ]]; then
            HIGH_CPU_COUNT+=1
        fi
    else
        CONSECUTIVE_HIGH_CPU=0
    fi

    # Track all processes using >2% CPU for summary (optimized - read directly)
    while read -r proc_name proc_cpu; do
        [[ -z "$proc_name" || -z "$proc_cpu" ]] && continue
        proc_name=$(basename "$proc_name")
        [[ "$proc_name" =~ ^(ps|awk|grep|top|bash|sh|cat|sed|tput|printf|cpu_monitor)$ ]] && continue

        PROCESS_CPU_COUNT[$proc_name]=$((${PROCESS_CPU_COUNT[$proc_name]:-0} + 1))
        # Integer arithmetic: multiply by 10 to keep one decimal
        proc_cpu_int=$(float_to_int "$proc_cpu")
        PROCESS_TOTAL_CPU_INT[$proc_name]=$((${PROCESS_TOTAL_CPU_INT[$proc_name]:-0} + proc_cpu_int))
        # Add to history for time-based averages
        add_cpu_reading "$proc_name" "$proc_cpu"
    done < <(ps aux --sort=-%cpu | awk 'NR>1 && $3>2.0 && $11 !~ /(^ps$|^awk$|^grep$|^top$)/ {print $11, $3}')

    # Prune history every 30 samples to keep arrays bounded
    if [[ $((SAMPLE_COUNT % 30)) -eq 0 ]]; then
        prune_history
    fi

    # Track GPU process usage (NVIDIA only) - current and peak VRAM
    if [[ "$GPU_TYPE" == "nvidia" ]]; then
        # Clear current readings before updating
        GPU_PROCESS_CURRENT=()
        while read -r proc_name gpu_mem; do
            [[ -z "$proc_name" || -z "$gpu_mem" || "$gpu_mem" == "-" ]] && continue
            [[ "$proc_name" == "nvidia-smi" ]] && continue

            # Store current VRAM usage (as integer)
            gpu_mem_int=${gpu_mem%.*}
            GPU_PROCESS_CURRENT[$proc_name]=$gpu_mem_int

            # Track count and total for average calculation
            GPU_PROCESS_COUNT[$proc_name]=$((${GPU_PROCESS_COUNT[$proc_name]:-0} + 1))
            GPU_PROCESS_TOTAL[$proc_name]=$((${GPU_PROCESS_TOTAL[$proc_name]:-0} + gpu_mem_int))

            # Track peak VRAM usage
            current_peak=${GPU_PROCESS_PEAK[$proc_name]:-0}
            if [[ $gpu_mem_int -gt $current_peak ]]; then
                GPU_PROCESS_PEAK[$proc_name]=$gpu_mem_int
            fi
        done < <(track_gpu_processes)
    fi

    # Draw the TUI
    draw_screen

    sleep "$INTERVAL"
done
