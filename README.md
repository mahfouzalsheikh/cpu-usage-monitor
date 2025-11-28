# CPU Usage Monitor

A real-time TUI (Text User Interface) monitoring tool for Linux systems that tracks CPU and GPU usage, temperatures, and top resource-consuming processes.

## Script

### `cpu_monitor_continuous.sh` - Real-time System Monitoring TUI

A continuous monitoring script that provides a comprehensive real-time dashboard for CPU and GPU monitoring.

**Usage:**
```bash
# Monitor every 3 seconds (default)
sudo ./cpu_monitor_continuous.sh

# Monitor every 2 seconds
sudo ./cpu_monitor_continuous.sh 2
```

**Features:**
- **Real-time Dashboard**: Clean TUI with live-updating stats
- **CPU Monitoring**: Usage percentage, temperature, and load average
- **GPU Monitoring**: Supports NVIDIA (nvidia-smi), AMD (rocm-smi), and integrated GPUs
- **Top CPU Consumers**: Tracks processes with time-based averages (1m, 5m, 15m) and CPU-seconds
- **Top GPU Consumers**: Current and average VRAM usage per process for NVIDIA GPUs (with peak tracking on exit)
- **Live Monitoring Log**: Scrolling log of recent readings with timestamps
- **Smart Alert System**: Only triggers after 3 consecutive samples above threshold (reduces false positives)
  - High CPU: >80% usage for 3+ consecutive samples
  - High CPU Temp: >70°C for 3+ consecutive samples
  - High GPU Temp: >70°C for 3+ consecutive samples
- **Color-coded Status**: Visual indicators for normal, warning, and critical states
- **Summary Report**: Detailed statistics displayed on exit (Ctrl+C)

**Color Coding:**
- 🔥 **RED (Critical)**: CPU/GPU temp >80°C, CPU/GPU usage >80%
- ⚠️ **YELLOW (Warning)**: CPU/GPU temp >70°C, CPU/GPU usage >50%
- ✅ **GREEN**: Normal status

**Display Sections:**
1. **Header Bar**: GPU type, sample count, and exit instructions
2. **Current Stats**: CPU%, CPU temp, GPU%, GPU temp, and load average
3. **Alerts**: Counts of high CPU, high temp events, and thermal throttling warnings
4. **Top CPU Consumers**: Process name, CPU-seconds, and 1m/5m/15m averages
5. **Top GPU Consumers**: Process name, current VRAM, and average VRAM usage (NVIDIA only)
6. **Live Log**: Recent monitoring entries with all metrics

## Prerequisites

### Required:
- `bash` - Bourne Again Shell
- `ps`, `top` - Process monitoring (usually pre-installed)
- `bc` - Basic calculator for arithmetic
- `tput` - Terminal control (usually pre-installed)
- Root privileges (`sudo`)

### Recommended (for full functionality):
```bash
# For detailed CPU temperature readings
sudo apt-get install lm-sensors
sudo sensors-detect  # Run this after installation

# For NVIDIA GPU monitoring
# nvidia-smi (comes with NVIDIA drivers)

# For AMD GPU monitoring
# rocm-smi (comes with ROCm)
```

## GPU Support

The script automatically detects and supports:
- **NVIDIA GPUs**: Full support via `nvidia-smi` (temperature, usage, VRAM per process)
- **AMD GPUs**: Basic support via `rocm-smi` (temperature, usage)
- **Integrated GPUs**: Temperature via hwmon, usage estimate via frequency ratio

## Example Output

```
════════════════════════════════════════════════════════════════════════════════
  🖥️  REAL-TIME SYSTEM MONITOR  │  GPU: nvidia  │  Samples: 42  │  Ctrl+C to exit
════════════════════════════════════════════════════════════════════════════════

  CPU: 23.5%    CPU Temp: 52.0°C    GPU: 15%    GPU Temp: 45°C    Load: 1.25

  Alerts: ✓ All normal

────────────────────────────────────────────────────────────────────────────────
  📊 TOP CPU CONSUMERS
  PROCESS            CPU-SEC     1m     5m    15m
  firefox             125.5s  12.3%   8.5%   6.2%
  code                 89.2s   8.1%   7.2%   5.8%

  🎮 TOP GPU CONSUMERS (VRAM)
  PROCESS               CURRENT        AVG
  firefox               512MiB    480.5MiB
  Xorg                  169MiB    165.2MiB
  ...
```

## Tips

- **Monitor interval**: Lower intervals (e.g., 1-2 seconds) provide more granular data but use more CPU
- **Time-based averages**: The 1m, 5m, 15m columns show rolling averages for that time window
- **CPU-seconds**: Total CPU time consumed by a process during monitoring
- **Exit summary**: Press Ctrl+C to see a comprehensive summary of the monitoring session
