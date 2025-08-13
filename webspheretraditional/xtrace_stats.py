#!/usr/bin/python3
"""
xtrace_stats.py - Parse IBM Xtrace iprint=mt,methods=... output and compute
per-method call counts and average durations.

Assumptions:
- Lines look like:
  21:00:05.736 0x2a7b500 ... > com/ibm/ws/util/BoundedBuffer$GetQueueLock.lock()V compiled method, this = 0x70b3568f0
  21:00:05.736 0x2a7b500 ... < com/ibm/ws/util/BoundedBuffer$GetQueueLock.lock()V compiled method
- '>' means method entry; '<' mean method exit.
- Use the hex thread id (e.g., 0x2a7b500) to match entries/exits with proper nesting.
- Timestamps are time-of-day; we handle midnight rollover.
"""

import argparse
import re
from collections import defaultdict

LINE_RE = re.compile(
    r"""
    ^(?P<ts>\d{2}[:.]\d{2}[:.]\d{2}[:.]\d{3})   # timestamp HH[:|.]MM[:|.]SS[:|.]mmm
    \s+(?P<tid>0x[0-9a-fA-F]+)                  # thread id like 0x2a7b500
    \s+.*?                                      # slack columns (e.g., 'mt.3', counters)
    (?P<arrow>[<>])                             # entry/exit marker
    \s+(?P<method>\S+)                          # method signature (no spaces)
    """,
    re.VERBOSE,
)   

def parse_ts_ms(ts: str) -> int:
    """Convert HH[:|.]MM[:|.]SS[:|.]mmm to milliseconds since start of day."""
    ts = ts.replace('.', ":")
    h, m, s, ms = map(int, ts.split(':'))
    return ((h * 60 + m) * 60 + s) * 1000 + ms

def iter_lines(fp):
    for ln, raw in enumerate(fp, 1):
        line = raw.rstrip('\n')
        if not line.strip():
            continue
        m = LINE_RE.search(line)
        if not m:
            # Skip unrecognized lines, but you could `print` to stderr if you wanted.
            continue
        yield ln, m.group('ts'), m.group('tid'), m.group('arrow'), m.group('method')

def ellipsize_middle(text: str, max_len: int, ellipsis: str = "...") -> str:
    """Return text shortened with a middle ellipsis to fit max_len."""
    if max_len <= 0:
        return ""
    if len(text) <= max_len:
        return text
    if max_len <= len(ellipsis):
        return text[:max_len] # Degenerate case: just hard cut
    
    keep = max_len - len(ellipsis)
    left = (keep + 1) // 2  # round up
    right = keep - left     # round down
    return text[:left] + ellipsis + (text[-right:] if right > 0 else "")

def compute_stats(path: str):
    # Per-thread call stack: tid -> [(method, start_ms_abs)]
    stacks = defaultdict(list)
    # Stats per method: method -> {'count': int, 'total_ms': int}
    stats = defaultdict(lambda: {'count': 0, 'total_ms': 0})

    last_abs_ms = None
    day_offset = 0 # to handle midnight rollovers

    with open(path, 'r', errors='replace') as fp:
        for ln, ts_str, tid, arrow, method in iter_lines(fp):
            ms = parse_ts_ms(ts_str)
            # Handle day rollover: if time goes backwards, assume next day
            abs_ms = ms + day_offset
            if last_abs_ms is not None and abs_ms < last_abs_ms:
                day_offset += 24 * 60 * 60 * 1000
                abs_ms = ms + day_offset
            last_abs_ms = abs_ms

            if arrow == '>':
                stacks[tid].append((method, abs_ms))
            else: # arrow == '<'
                if not stacks[tid]:
                    # No matching start on this thread; skip or log as needed
                    continue

                # Pop until we find the matching method (handles occasional mismatches)
                temp = []
                start_method = None
                start_ms = None
                while stacks[tid]:
                    mth, s_ms = stacks[tid].pop()
                    if mth == method:
                        start_method, start_ms = mth, s_ms
                        break
                    temp.append((mth, s_ms))
                # Put back anything we popped that wasn't the match
                while temp:
                    stacks[tid].append(temp.pop())

                if start_method is None:
                    # Didn't find a matching start; skip
                    continue

                dur = abs_ms - start_ms
                if dur >=0:
                    s = stats[method]
                    s['count'] += 1
                    s['total_ms'] += dur
    
    # Build result list with averages.
    result = []
    for method, s in stats.items():
        avg = s['total_ms'] / s['count'] if s['count'] else 0.0
        result.append((method, s['count'], s['total_ms'], avg))

    # Sort by descending average duration, then by count
    result.sort(key=lambda x: (-x[3], -x[1], x[0]))
    return result

def main():
    ap = argparse.ArgumentParser(description="Compute per-method counts and average durations from Xtrace iprint logs.")
    ap.add_argument("logfile", help="Path to native_stderr.log (or any file with Xtrace lines).")
    ap.add_argument("--top", type=int, default=0, help="Show only the top N methods by avg duration.")
    ap.add_argument("--sort", choices=["avg", "count", "total", "method"], default="avg",
                    help="Sort by: avg (default), count total, or method.")
    ap.add_argument("--width", type=int, default=60,
                    help="Method name column width (will center-ellipsis if too long) Default:60")
    args = ap.parse_args()

    rows = compute_stats(args.logfile)

    if args.sort == "count":
        rows.sort(key=lambda x: (-x[1], -x[3], x[0]))
    elif args.sort == "total":
        rows.sort(key=lambda x: (-x[2], -x[1], x[0]))
    elif args.sort == "method":
        rows.sort(key=lambda x: x[0].lower())
    # else default already sorted by avg desc

    if args.top and args.top > 0:
        rows = rows[:args.top]

    # Pretty print
    w = max(10, args.width) # keep it name
    header = f"{'Method':<{w}} {'Count':>7} {'Total(ms)':>12} {'Avg(ms)':>10}"
    print(header)
    print("-" * len(header))
    for method, count, total_ms, avg_ms in rows:
        name = ellipsize_middle(method, w)
        print(f"{name:<{w}} {count:>7d} {total_ms:>12d} {avg_ms:>10.3f}")
    
if __name__ == "__main__":
    main()
