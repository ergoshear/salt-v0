#!/usr/bin/env python3
"""
Custom Salt grain to detect AMD KFD GPU target ISA (e.g. gfx1151, gfx1201)
and classify Strix Halo unified memory tiers (128 GiB vs 192 GiB).
"""
import glob
import os
import subprocess

# Map KFD gfx_target_version integers to standard ROCm gfx strings
GFX_VERSION_MAP = {
    "110501": "gfx1151",  # AMD Strix Halo (Radeon 8050S / 8060S)
    "120001": "gfx1201",  # AMD RDNA 4 (Radeon AI PRO R9700 / RX 9070 XT)
    "120000": "gfx1200",
}


def _detect_amd_gfx():
    gfx_targets = set()

    # 1. Zero-dependency check via Linux kernel KFD topology sysfs
    for prop_file in glob.glob("/sys/class/kfd/kfd/topology/nodes/*/properties"):
        try:
            with open(prop_file, "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("gfx_target_version"):
                        ver = line.split()[1].strip()
                        if ver != "0":
                            gfx_targets.add(GFX_VERSION_MAP.get(ver, f"gfx_{ver}"))
        except OSError:
            continue

    # 2. Fallback to rocminfo if present
    if not gfx_targets and os.path.exists("/usr/bin/rocminfo"):
        try:
            out = subprocess.check_output(
                ["/usr/bin/rocminfo"], text=True, stderr=subprocess.DEVNULL
            )
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("Name:") and "gfx" in line:
                    gfx_targets.add(line.split()[-1])
        except Exception:
            pass

    return sorted(gfx_targets)


def _total_ram_gib():
    # Read physical RAM from /proc/meminfo and bucket to standard hardware tiers
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    raw_gib = kb / (1024 * 1024)
                    if raw_gib >= 170:
                        return 192
                    elif raw_gib >= 110:
                        return 128
                    elif raw_gib >= 55:
                        return 64
                    elif raw_gib >= 28:
                        return 32
                    return round(raw_gib)
    except OSError:
        return 0


def amd_strix_halo_grains():
    gfx_list = _detect_amd_gfx()
    ram_gib = _total_ram_gib()

    grains = {
        "amd_gfx_targets": gfx_list,
        "system_ram_tier_gib": ram_gib,
    }

    if "gfx1151" in gfx_list and ram_gib == 192:
        grains["strix_halo_profile"] = "gfx1151_192gib"
        grains["strix_halo_kargs"] = (
            "amdgpu.gttsize=184320 ttm.pages_limit=47185920 "
            "ttm.page_pool_size=47185920 amd_iommu=off"
        )
    elif "gfx1151" in gfx_list and ram_gib == 128:
        grains["strix_halo_profile"] = "gfx1151_128gib"
        grains["strix_halo_kargs"] = (
            "amdgpu.gttsize=120832 ttm.pages_limit=30932992 "
            "ttm.page_pool_size=30932992 amd_iommu=off"
        )
    else:
        grains["strix_halo_profile"] = "none"

    return grains