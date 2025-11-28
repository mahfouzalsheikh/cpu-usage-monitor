# CPU Usage Monitor

A real-time TUI (Text User Interface) monitoring tool for Linux systems that tracks CPU and GPU usage, temperatures, fan speeds, and top resource-consuming processes with htop-style visual bars and color-coded displays.

## Script

### `cpu_monitor_continuous.sh` - Real-time System Monitoring TUI

A continuous monitoring script that provides a comprehensive real-time dashboard for CPU and GPU monitoring with visual progress bars and temperature history.

**Usage:**
```bash
# Monitor every 1 second (default)
sudo ./cpu_monitor_continuous.sh

# Monitor every 2 seconds
sudo ./cpu_monitor_continuous.sh 2
```

**Features:**
- **Real-time Dashboard**: Clean TUI with live-updating stats and htop-style progress bars
- **CPU Monitoring**: Usage percentage with bar, per-core temperatures, and load average
- **GPU Monitoring**: Supports NVIDIA (nvidia-smi), AMD (rocm-smi), and integrated GPUs
- **Per-Core Temperature Display**: Individual temperature bars for each CPU core
- **Temperature History Timeline**: Color-coded visualization showing temperature trends over time
- **Temperature Averages**: Rolling averages (10s, 1m, 5m, 15m) for overall and per-core temperatures
- **Fan Speed Monitoring**: Detects and displays fan speeds with averages (supports multiple vendors)
- **Top CPU Consumers**: Tracks processes with time-based averages (10s, 1m, 5m, 15m) and CPU-seconds
- **Top GPU Consumers**: Current and average VRAM usage per process for NVIDIA GPUs (with peak tracking on exit)
- **Smart Alert System**: Only triggers after 3 consecutive samples above threshold (reduces false positives)
  - High CPU: >80% usage for 3+ consecutive samples
  - High CPU Temp: >70°C for 3+ consecutive samples
  - High GPU Temp: >70°C for 3+ consecutive samples
- **10-Level Temperature Gradient**: Smooth color transitions from cyan (cool) to red (hot)
- **Summary Report**: Detailed statistics displayed on exit (Ctrl+C)

**Temperature Color Gradient (10 levels):**
| Temperature | Color |
|-------------|-------|
| < 35°C | Cyan (very cool) |
| 35-45°C | Teal |
| 45-50°C | Green (cool) |
| 50-55°C | Light green |
| 55-60°C | Yellow-green |
| 60-65°C | Yellow (warm) |
| 65-70°C | Orange-yellow |
| 70-75°C | Orange (hot) |
| 75-85°C | Red-orange |
| ≥ 85°C | Red (critical) |

**Display Sections:**
1. **Header Bar**: GPU type, sample count, and exit instructions
2. **Visual Bars**: htop-style progress bars for CPU usage, CPU temp, GPU usage, GPU temp
3. **Per-Core Temperatures**: Individual temperature bars for each CPU core
4. **Temperature History**: Color-coded timeline showing temperature trends (oldest → newest)
5. **Temperature Averages**: Table with 10s, 1m, 5m, 15m rolling averages
6. **Fan Speeds**: Current and average RPM for detected fans
7. **Alerts**: Counts of high CPU, high temp events, and thermal throttling warnings
8. **Top CPU Consumers**: Process name, CPU-seconds, and time-based averages
9. **Top GPU Consumers**: Process name, current VRAM, and average VRAM usage (NVIDIA only)

## Prerequisites

### Required:
- `bash` - Bourne Again Shell (4.0+)
- `ps` - Process monitoring (usually pre-installed)
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

## Fan Detection

The script supports multiple fan detection methods:
- Standard `hwmon` sysfs interface
- Vendor-specific naming (dell, hp, lenovo, asus, acer, thinkpad)
- ThinkPad-specific `/proc/acpi/ibm/fan` interface
- Automatic fallback between methods

## Example Output

```
════════════════════════════════════════════════════════════════════════════════
  🖥️  REAL-TIME SYSTEM MONITOR  │  GPU: nvidia  │  Samples: 42  │  Ctrl+C to exit
════════════════════════════════════════════════════════════════════════════════

  CPU Usage  [████████████────────────────────────────────────] 23.5%  Load: 1.25
  CPU Temp   [██████████████████████──────────────────────────] 52.0°C
  GPU Usage  [███████─────────────────────────────────────────] 15.0%
  GPU Temp   [██████████████────────────────────────────────── ] 45.0°C

  Per-Core Temperatures:
  C0     [████████████████████████████────────────────────────] 55.0°C
  C1     [██████████████████████────────────────────────────── ] 48.0°C
  C2     [████████████████████████──────────────────────────── ] 52.0°C
  C3     [██████████████████────────────────────────────────── ] 45.0°C

  Temperature History: (oldest ← → newest)
  C0     [████████████████████████████████████████████████████]
  C1     [████████████████████████████████████████████████████]
  ...

  🌡️  CPU TEMPERATURE AVERAGES
              10s       1m       5m      15m
  ──────────── ──────── ──────── ──────── ────────
  Overall      52.0°C   53.5°C   55.2°C   54.8°C
  C0           55.0°C   56.2°C   58.0°C   57.5°C
  ...

  � FAN SPEEDS
  FAN              CURRENT      10s       1m       5m      15m
  ──────────────── ──────── ──────── ──────── ──────── ────────
  fan1             2500 RPM 2480 RPM 2450 RPM 2400 RPM 2380 RPM

  Alerts: ✓ All normal
  ...
```

## Performance

The script is optimized for minimal CPU overhead:
- **No `bc` calls**: All arithmetic uses native bash integer math
- **No `top` command**: CPU usage read directly from `/proc/stat`
- **Ring buffers**: Fixed-size history prevents memory growth
- **Pre-computed colors**: Temperature colors calculated at insert time, not render time
- **Efficient pruning**: Simple array slicing instead of awk filtering

## Tips

- **Monitor interval**: Default is 1 second for responsive display
- **Time-based averages**: The 10s, 1m, 5m, 15m columns show rolling averages for that time window
- **Temperature history**: Watch the color-coded timeline to spot temperature spikes and trends
- **CPU-seconds**: Total CPU time consumed by a process during monitoring
- **Exit summary**: Press Ctrl+C to see a comprehensive summary of the monitoring session
