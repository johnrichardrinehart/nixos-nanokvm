#!/usr/bin/env python3
# Fails unless every enabled device-tree node either has a driver built into
# the kernel or is listed as intentionally unused.
#
# For each enabled node, finds the kernel sources whose of_match tables list
# one of its compatibles (most specific first) and the Kconfig symbol that
# builds each, and requires one of them to be =y.
#
# usage: dt-drivers.py <dtb> <kernel-src> <.config> <unused.json>
import re, subprocess, sys, os, json, collections

dtb, src, config, unused_file = sys.argv[1:5]
unused = json.load(open(unused_file))
dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", dtb], capture_output=True, text=True).stdout

# Walk nodes, track status; collect compatibles of enabled nodes.
nodes = []
stack = []
for line in dts.splitlines():
    s = line.strip()
    m = re.match(r'^(?:[\w-]+:\s*)?([\w@,.+-]+|/)\s*\{', s)
    if m:
        stack.append({"name": m.group(1), "compat": [], "status": "okay"})
        continue
    if s.startswith("};") and stack:
        n = stack.pop()
        path = "/".join(x["name"] for x in stack) + "/" + n["name"]
        n["path"] = path
        n["enabled"] = n["status"] == "okay" and all(x["status"] == "okay" for x in stack)
        nodes.append(n)
        continue
    if stack:
        m = re.match(r'compatible = (.*);', s)
        if m:
            stack[-1]["compat"] = re.findall(r'"([^"]+)"', m.group(1))
        m = re.match(r'status = "(\w+)";', s)
        if m:
            stack[-1]["status"] = "okay" if m.group(1) in ("okay", "ok") else m.group(1)

cfg = {}
for line in open(config):
    m = re.match(r'^CONFIG_(\w+)=(.*)$', line)
    if m:
        cfg[m.group(1)] = m.group(2)

# compatible string -> source files mentioning it in an of_device_id table
want = sorted({c for n in nodes if n["enabled"] for c in n["compat"]})
hits = collections.defaultdict(set)
grep = subprocess.run(
    ["grep", "-rlF", "--include=*.c", "-e", "\n".join(f'"{c}"' for c in want), os.path.join(src, "drivers"), os.path.join(src, "sound"), os.path.join(src, "arch/riscv"), os.path.join(src, "kernel")],
    capture_output=True, text=True).stdout.split()
for f in grep:
    text = open(f, errors="replace").read()
    for c in want:
        if f'"{c}"' in text:
            hits[c].add(os.path.relpath(f, src))

def kconfig_for(cfile):
    d, base = os.path.split(cfile)
    obj = base[:-2] + ".o"
    mk = os.path.join(src, d, "Makefile")
    try:
        text = open(mk).read().replace("\\\n", " ")
    except OSError:
        return None
    for line in text.splitlines():
        m = re.match(r'\s*obj-\$\(CONFIG_(\w+)\)\s*[+:]?=\s*(.*)', line)
        if m and obj in m.group(2).split():
            return m.group(1)
        # composite objects: foo-y += bar.o ; obj-$(CONFIG_X) += foo.o
    for line in text.splitlines():
        m = re.match(r'\s*([\w-]+)-(?:y|objs|\$\(CONFIG_\w+\))\s*[+:]?=\s*(.*)', line)
        if m and obj in m.group(2).split():
            comp = m.group(1) + ".o"
            for l2 in text.splitlines():
                m2 = re.match(r'\s*obj-\$\(CONFIG_(\w+)\)\s*[+:]?=\s*(.*)', l2)
                if m2 and comp in m2.group(2).split():
                    return m2.group(1)
    return None

out = []
for n in nodes:
    if not n["enabled"] or not n["compat"]:
        continue
    drivers = []
    for c in n["compat"]:
        for f in sorted(hits.get(c, ())):
            sym = kconfig_for(f)
            drivers.append({"compat": c, "file": f, "symbol": sym, "value": cfg.get(sym) if sym else None})
        if drivers:
            break  # most specific compatible with a driver wins
    out.append({"node": n["path"], "compat": n["compat"], "drivers": drivers})

failures = []
for entry in out:
    if any(c in unused for c in entry["compat"]):
        continue
    built = [d for d in entry["drivers"] if d["value"] == "y"]
    if built:
        print(f"ok      {entry['node']}: {', '.join(sorted({d['symbol'] for d in built}))}")
    else:
        candidates = sorted({str(d["symbol"]) for d in entry["drivers"]}) or ["no driver found"]
        failures.append(f"{entry['node']} {entry['compat']}: {', '.join(candidates)}")
for c in unused:
    print(f"unused  {c}: {unused[c]}")
if failures:
    print("\nenabled device-tree nodes without a built-in driver:", file=sys.stderr)
    for f in failures:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
