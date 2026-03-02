import re
import matplotlib.pyplot as plt

files = {
    "Java Sidecar (DirectPath)": "benchmark_sidecar_local.log",
    "Java Sidecar (CloudPath)": "benchmark_sidecar_cloudpath_local.log",
    "Native Ruby (CloudPath)": "benchmark_ruby_local.log"
}

colors = {
    "Java Sidecar (DirectPath)": "blue",
    "Java Sidecar (CloudPath)": "green",
    "Native Ruby (CloudPath)": "red"
}

metrics = ["p50", "p90", "p99", "p99.9"]
data = {metric: {target: [] for target in files} for metric in metrics}

for target, filename in files.items():
    with open(filename, "r") as f:
        lines = f.readlines()
        
    current_minute = None
    for line in lines:
        m_match = re.search(r"^Minute (\d+)", line)
        if m_match:
            current_minute = int(m_match.group(1))
            continue
            
        if current_minute:
            for metric in metrics:
                # Check exact match for the metric line to avoid p99.9 matching p99
                if line.lstrip().startswith(f"{metric} Latency:"):
                    val_match = re.search(r"([\d\.]+)\s+ms", line)
                    if val_match:
                        # Append (minute, value) to ensure order
                        data[metric][target].append((current_minute, float(val_match.group(1))))

for metric in metrics:
    plt.figure(figsize=(14, 7))
    for target in files.keys():
        series = sorted(data[metric][target], key=lambda x: x[0])
        minutes = [x[0] for x in series]
        values = [x[1] for x in series]
        plt.plot(minutes, values, label=target, color=colors[target], linewidth=1.5, alpha=0.8)
    
    plt.title(f"{metric} Latency Over 8 Hours (500 QPS) - C3 Architecture")
    plt.xlabel("Minute")
    plt.ylabel("Latency (ms)")
    plt.legend()
    plt.grid(True, linestyle="--", alpha=0.7)
    plt.tight_layout()
    
    filename = f"{metric.replace('.', '_')}_latency_8h.png"
    plt.savefig(filename, dpi=150)
    print(f"Generated {filename}")
    plt.close()
