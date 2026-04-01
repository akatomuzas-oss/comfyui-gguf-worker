"""Pre-flight diagnostics — runs before ComfyUI to catch silent import failures."""
import os, sys, traceback, subprocess

# Check what Python we're using
print(f"PREFLIGHT: Python={sys.executable} v{sys.version}")
print(f"PREFLIGHT: sys.path={sys.path[:5]}...")

# KEY: Check if volume venv exists — start.sh activates it for ComfyUI
venv_python = "/runpod-volume/venv/bin/python"
venv_pip = "/runpod-volume/venv/bin/pip"
print(f"PREFLIGHT: venv python exists: {os.path.exists(venv_python)}")
print(f"PREFLIGHT: venv pip exists: {os.path.exists(venv_pip)}")
if os.path.exists("/runpod-volume/venv"):
    venv_files = os.listdir("/runpod-volume/venv/bin/")[:10]
    print(f"PREFLIGHT: venv/bin contents: {venv_files}")
    # Check what packages the venv has
    try:
        result = subprocess.run([venv_pip, "list", "--format=columns"], capture_output=True, text=True, timeout=30)
        lines = result.stdout.strip().split("\n")
        print(f"PREFLIGHT: venv has {len(lines)} packages")
        # Check for key packages
        for pkg in ["insightface", "ultralytics", "onnxruntime", "torchvision"]:
            found = any(pkg.lower() in l.lower() for l in lines)
            print(f"PREFLIGHT: venv has {pkg}: {found}")
    except Exception as e:
        print(f"PREFLIGHT: venv pip list failed: {e}")
else:
    print("PREFLIGHT: NO VENV on volume — ComfyUI uses system Python")

# Check volume structure
volume = "/runpod-volume"
comfyui_dir = f"{volume}/ComfyUI"
custom_nodes_dir = f"{comfyui_dir}/custom_nodes"
docker_nodes_dir = "/docker-custom-nodes"

print(f"PREFLIGHT: Volume exists: {os.path.exists(volume)}")
print(f"PREFLIGHT: ComfyUI dir exists: {os.path.exists(comfyui_dir)}")
print(f"PREFLIGHT: custom_nodes dir exists: {os.path.exists(custom_nodes_dir)}")
print(f"PREFLIGHT: Docker nodes dir exists: {os.path.exists(docker_nodes_dir)}")

if os.path.exists(custom_nodes_dir):
    entries = os.listdir(custom_nodes_dir)
    print(f"PREFLIGHT: custom_nodes contents ({len(entries)}): {entries[:20]}")

    # Check IPAdapter specifically
    ipa_dir = f"{custom_nodes_dir}/ComfyUI_IPAdapter_plus"
    if os.path.exists(ipa_dir):
        is_link = os.path.islink(ipa_dir)
        link_target = os.readlink(ipa_dir) if is_link else "N/A"
        print(f"PREFLIGHT: IPAdapter dir: exists=True, islink={is_link}, target={link_target}")
        ipa_files = os.listdir(ipa_dir)
        print(f"PREFLIGHT: IPAdapter files: {ipa_files}")
    else:
        print("PREFLIGHT: IPAdapter dir: DOES NOT EXIST")

    # Check Impact Pack
    imp_dir = f"{custom_nodes_dir}/ComfyUI-Impact-Pack"
    if os.path.exists(imp_dir):
        is_link = os.path.islink(imp_dir)
        link_target = os.readlink(imp_dir) if is_link else "N/A"
        print(f"PREFLIGHT: Impact Pack dir: exists=True, islink={is_link}, target={link_target}")
    else:
        print("PREFLIGHT: Impact Pack dir: DOES NOT EXIST")

# Try importing key dependencies
for mod_name in ["torch", "torchvision", "insightface", "onnxruntime", "ultralytics", "PIL"]:
    try:
        __import__(mod_name)
        print(f"PREFLIGHT: import {mod_name}: OK")
    except Exception as e:
        print(f"PREFLIGHT: import {mod_name}: FAILED — {e}")

# Now try the actual IPAdapter Plus import chain
# We need to simulate what ComfyUI does: add the node dir to sys.path
ipa_dir = f"{custom_nodes_dir}/ComfyUI_IPAdapter_plus"
if os.path.exists(ipa_dir):
    # Add ComfyUI to path first (needed for folder_paths, comfy.*, etc.)
    if os.path.exists(comfyui_dir):
        sys.path.insert(0, comfyui_dir)
    sys.path.insert(0, ipa_dir)

    try:
        # Try importing the main module like ComfyUI would
        import importlib
        spec = importlib.util.spec_from_file_location(
            "ComfyUI_IPAdapter_plus",
            f"{ipa_dir}/__init__.py"
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        print(f"PREFLIGHT: IPAdapter Plus import: SUCCESS — nodes={list(mod.NODE_CLASS_MAPPINGS.keys())[:5]}")
    except Exception as e:
        print(f"PREFLIGHT: IPAdapter Plus import: FAILED")
        traceback.print_exc()

print("PREFLIGHT: Done.")
