import re
import time
import hashlib
from config import SANDBOX_FILE, OVERRIDES_FILE
from settings_schema import SETTINGS_SCHEMA


def read_sandbox_values():
    values = {}
    try:
        with open(SANDBOX_FILE) as f:
            for line in f:
                m = re.match(r'\s*(\w+)\s*=\s*(.+?)\s*,?\s*(?:--.*)?$', line)
                if m:
                    key, val = m.group(1), m.group(2).strip()
                    if val.lower() == "true":
                        values[key] = True
                    elif val.lower() == "false":
                        values[key] = False
                    elif re.match(r'^-?\d+\.\d+$', val):
                        values[key] = float(val)
                    elif re.match(r'^-?\d+$', val):
                        values[key] = int(val)
                    else:
                        values[key] = val.strip('"')
    except FileNotFoundError:
        pass
    return values


def read_overrides_values():
    values = {}
    try:
        with open(OVERRIDES_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip()
                    val = val.strip()
                    if val.lower() == "true":
                        values[key] = True
                    elif val.lower() == "false":
                        values[key] = False
                    elif re.match(r'^-?\d+\.\d+$', val):
                        values[key] = float(val)
                    elif re.match(r'^-?\d+$', val):
                        values[key] = int(val)
                    else:
                        values[key] = val
    except FileNotFoundError:
        pass
    return values


def get_current_config():
    sandbox = read_sandbox_values()
    overrides = read_overrides_values()
    result = []
    for group in SETTINGS_SCHEMA:
        settings = []
        for s in group["settings"]:
            current = sandbox.get(s["key"]) if s["file"] == "sandbox" else overrides.get(s["key"])
            settings.append({
                **s,
                "current": current if current is not None else s["default"],
                "is_default": current is None,
            })
        result.append({"group": group["group"], "settings": settings})
    return result


def create_proposal(state, session, changes, current_config):
    flat = {}
    for group in current_config:
        for s in group["settings"]:
            flat[s["key"]] = s
    proposal_changes = {}
    for key, new_val in changes.items():
        if key in flat:
            proposal_changes[key] = {
                "from": flat[key]["current"],
                "to": new_val,
                "label": flat[key]["label"],
                "file": flat[key]["file"],
            }
    if not proposal_changes:
        return None
    proposal_id = hashlib.sha256(f"{session['username']}{time.time()}".encode()).hexdigest()[:8]
    proposal = {
        "id": proposal_id,
        "changes": proposal_changes,
        "proposed_by": session["username"],
        "created_at": time.strftime("%Y-%m-%d %H:%M"),
        "status": "pending",
        "discord_msg_id": None,
    }
    state.setdefault("config_proposals", []).append(proposal)
    return proposal


def apply_proposal(proposal):
    sandbox_changes = {}
    ini_changes = {}
    for key, change in proposal["changes"].items():
        if change["file"] == "sandbox":
            sandbox_changes[key] = change["to"]
        else:
            ini_changes[key] = change["to"]
    if sandbox_changes:
        _write_sandbox(sandbox_changes)
    if ini_changes:
        _write_overrides(ini_changes)


def _write_sandbox(changes):
    try:
        with open(SANDBOX_FILE) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    new_lines = []
    for line in lines:
        m = re.match(r'(\s*)(\w+)(\s*=\s*).+?(,?\s*(?:--.*)?)$', line)
        if m and m.group(2) in changes:
            key = m.group(2)
            val = changes.pop(key)
            if isinstance(val, bool):
                val_str = "true" if val else "false"
            elif isinstance(val, float):
                val_str = str(val)
            else:
                val_str = str(val)
            new_lines.append(f"{m.group(1)}{key}{m.group(3)}{val_str}{m.group(4)}\n")
        else:
            new_lines.append(line)
    with open(SANDBOX_FILE, "w") as f:
        f.writelines(new_lines)


def _write_overrides(changes):
    try:
        with open(OVERRIDES_FILE) as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    existing_keys = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            existing_keys.add(key)
            if key in changes:
                val = changes[key]
                if isinstance(val, bool):
                    val = "true" if val else "false"
                new_lines.append(f"{key}={val}\n")
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
    for key, val in changes.items():
        if key not in existing_keys:
            if isinstance(val, bool):
                val = "true" if val else "false"
            new_lines.append(f"{key}={val}\n")
    with open(OVERRIDES_FILE, "w") as f:
        f.writelines(new_lines)
