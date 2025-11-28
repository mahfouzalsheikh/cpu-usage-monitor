#!/usr/bin/env python3
"""
CPU Load Generator - Utilizes a specified percentage of CPU across all cores
with real CPU-intensive calculations (for thermal/cooling stress testing).

Usage:
    python cpu_load.py <percentage>

Example:
    python cpu_load.py 20  # Use 20% of CPU on all cores
"""

import argparse
import hashlib
import math
import multiprocessing
import random
import time
import signal
import sys


def do_intensive_work():
    """
    Perform genuinely CPU-intensive calculations that stress the processor
    and generate heat. Combines multiple types of workloads:
    - Cryptographic hashing (stresses integer ALU)
    - Floating-point math (stresses FPU)
    - Memory operations
    """
    # Cryptographic hashing - very CPU intensive, can't be optimized away
    data = b"stress_test_data_" + bytes(random.getrandbits(8) for _ in range(64))
    for _ in range(100):
        data = hashlib.sha256(data).digest()

    # Floating-point intensive calculations (stresses FPU)
    result = 0.0
    for i in range(1, 50):
        x = float(i) * 0.01
        result += math.sin(x) * math.cos(x) * math.sqrt(abs(math.tan(x) + 1))
        result += math.exp(x % 10) / (math.log(x + 1) + 1)

    # Some integer math
    n = 104729  # A prime number
    for _ in range(10):
        n = (n * 1103515245 + 12345) & 0x7FFFFFFF

    return result + n


def cpu_load_worker(target_percent, stop_event):
    """
    Worker function that runs on each CPU core.
    It alternates between intensive calculations and sleeping to achieve target CPU usage.
    """
    # Time window in seconds for each cycle
    cycle_time = 0.1  # 100ms cycles for smooth CPU usage

    busy_time = cycle_time * (target_percent / 100.0)
    sleep_time = cycle_time - busy_time

    while not stop_event.is_set():
        # Intensive work phase
        end_busy = time.perf_counter() + busy_time
        while time.perf_counter() < end_busy:
            do_intensive_work()

        # Sleep phase
        if sleep_time > 0:
            time.sleep(sleep_time)


def main():
    parser = argparse.ArgumentParser(
        description="Generate CPU load at a specified percentage across all cores."
    )
    parser.add_argument(
        "percentage",
        type=float,
        help="Target CPU usage percentage (0-100)"
    )
    parser.add_argument(
        "-c", "--cores",
        type=int,
        default=None,
        help="Number of cores to use (default: all cores)"
    )
    parser.add_argument(
        "-d", "--duration",
        type=float,
        default=None,
        help="Duration in seconds (default: run until Ctrl+C)"
    )
    
    args = parser.parse_args()
    
    # Validate percentage
    if not 0 <= args.percentage <= 100:
        print("Error: Percentage must be between 0 and 100", file=sys.stderr)
        sys.exit(1)
    
    # Determine number of cores
    num_cores = args.cores if args.cores else multiprocessing.cpu_count()
    
    print(f"Starting CPU load generator:")
    print(f"  Target CPU usage: {args.percentage}%")
    print(f"  Number of cores: {num_cores}")
    if args.duration:
        print(f"  Duration: {args.duration} seconds")
    else:
        print(f"  Duration: Until Ctrl+C")
    print()
    
    # Create stop event for graceful shutdown
    stop_event = multiprocessing.Event()
    
    # Handle Ctrl+C gracefully
    def signal_handler(signum, frame):
        print("\nStopping CPU load generator...")
        stop_event.set()
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Start worker processes
    processes = []
    for i in range(num_cores):
        p = multiprocessing.Process(
            target=cpu_load_worker,
            args=(args.percentage, stop_event)
        )
        p.start()
        processes.append(p)
    
    print(f"Running on {num_cores} cores. Press Ctrl+C to stop.")
    
    # Wait for duration or until interrupted
    try:
        if args.duration:
            time.sleep(args.duration)
            stop_event.set()
        else:
            # Wait indefinitely until signal
            while not stop_event.is_set():
                time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    
    # Stop all processes
    stop_event.set()
    for p in processes:
        p.join(timeout=2)
        if p.is_alive():
            p.terminate()
    
    print("CPU load generator stopped.")


if __name__ == "__main__":
    main()

