#!/usr/bin/env python3
"""syncthing-rest.py — REST + data mechanism for `mesh syncthing` (engine layer).

Dependency-free (stdlib only). Two responsibilities:

  1. A minimal YAML-subset reader for ``syncthing-mesh.yaml`` (no PyYAML
     dependency — mirrors the engine's bash ``yaml-parse.sh`` philosophy: the
     mesh cannot assume a third-party YAML parser is installed on every node).
  2. A Syncthing REST client + idempotent reconcile ops, extracted and hardened
     from ``mesh-identity/claude/scripts/sync/join-mesh.sh``.

The bash lib ``syncthing-rest.sh`` owns the daemon lifecycle + config-file
location and shells out to this module; this module never starts the daemon or
reads ``config.xml`` (that is the bash lib's job — paths are OS-specific).

CLI:  python3 syncthing-rest.py <command> [args...]

REST commands read ``MESH_ST_BASE`` (default http://127.0.0.1:8384) and
``MESH_ST_APIKEY`` from the environment. All structured output is JSON on
stdout; human diagnostics go to stderr. Exit codes:

   0  success
   2  usage / bad arguments
   3  data-file parse / validation error
   4  REST transport error (daemon unreachable, HTTP error)
   5  policy violation (e.g. refused 0.0.0.0 bind without override)
"""

import json
import os
import re
import secrets
import string
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime

EXIT_USAGE = 2
EXIT_DATA = 3
EXIT_REST = 4
EXIT_POLICY = 5

DEFAULT_PORT = 8384


def die(code, msg):
    sys.stderr.write("syncthing-rest: " + msg + "\n")
    sys.exit(code)


def emit(obj):
    sys.stdout.write(json.dumps(obj, indent=2, sort_keys=True) + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# 1. YAML-subset reader (no PyYAML)
#
# Supports exactly the shape of syncthing-mesh.yaml:
#   - block mappings (key: value), 2-space indent
#   - block sequences of mappings (`- key: value`)
#   - flow sequences ([a, b] and [])
#   - scalars (bare / 'single' / "double" quoted), bool/int coercion
#   - `#` comments and blank lines
# Rejected: anchors/aliases/tags/multi-doc/block scalars — none are needed and
# silently mis-parsing them would be worse than failing loudly.
# ─────────────────────────────────────────────────────────────────────────────

class YamlError(Exception):
    pass


def _strip_comment(s):
    # Remove an unquoted trailing `#` comment. Respect quotes.
    out = []
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            out.append(c)
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            out.append(c)
        elif c == "#" and (i == 0 or s[i - 1] in (" ", "\t")):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out).rstrip()


def _coerce_scalar(tok):
    tok = tok.strip()
    if tok == "" or tok == "~" or tok.lower() == "null":
        return None
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ("'", '"'):
        inner = tok[1:-1]
        if tok[0] == "'":
            inner = inner.replace("''", "'")
        return inner
    low = tok.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    return tok


def _parse_flow_seq(tok):
    # tok looks like "[a, b, c]" — comma-split honouring quotes.
    body = tok.strip()[1:-1].strip()
    if body == "":
        return []
    parts = []
    cur = []
    quote = None
    for c in body:
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            cur.append(c)
        elif c == ",":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    parts.append("".join(cur))
    return [_coerce_scalar(p) for p in parts]


def _scalar_or_flow(tok):
    tok = tok.strip()
    if tok.startswith("[") and tok.endswith("]"):
        return _parse_flow_seq(tok)
    return _coerce_scalar(tok)


class _Line:
    __slots__ = ("indent", "text", "no")

    def __init__(self, indent, text, no):
        self.indent = indent
        self.text = text
        self.no = no


def _tokenize(src):
    lines = []
    for n, raw in enumerate(src.splitlines(), 1):
        lead = raw[: len(raw) - len(raw.lstrip())]  # full leading-whitespace run
        if "\t" in lead:
            raise YamlError("line %d: tabs are not allowed for indentation" % n)
        stripped = _strip_comment(raw)
        if stripped.strip() == "":
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append(_Line(indent, stripped.strip(), n))
    return lines


def _parse_block(lines, idx, indent):
    """Parse a block (mapping or sequence) at column `indent`.
    Returns (value, next_idx)."""
    if idx >= len(lines):
        return None, idx
    first = lines[idx]
    if first.indent < indent:
        return None, idx
    if first.text.startswith("- "):
        return _parse_seq(lines, idx, indent)
    return _parse_map(lines, idx, indent)


def _parse_seq(lines, idx, indent):
    items = []
    while idx < len(lines):
        ln = lines[idx]
        if ln.indent < indent or not ln.text.startswith("- "):
            break
        if ln.indent > indent:
            raise YamlError("line %d: unexpected indentation in sequence" % ln.no)
        rest = ln.text[2:].strip()
        # An item is either "- key: val" (inline first mapping key) or "- scalar".
        m = re.match(r"^([A-Za-z0-9_.-]+):\s*(.*)$", rest)
        if m:
            # Re-inject the first key as a mapping line at indent+2, then parse a
            # mapping that also absorbs the following deeper-indented keys.
            key, val = m.group(1), m.group(2)
            child_indent = ln.indent + 2
            synthetic = [_Line(child_indent, rest, ln.no)]
            j = idx + 1
            while j < len(lines) and lines[j].indent >= child_indent and not lines[j].text.startswith("- "):
                synthetic.append(lines[j])
                j += 1
            mp, _ = _parse_map(synthetic, 0, child_indent)
            items.append(mp)
            idx = j
        else:
            items.append(_scalar_or_flow(rest))
            idx += 1
    return items, idx


def _parse_map(lines, idx, indent):
    out = {}
    while idx < len(lines):
        ln = lines[idx]
        if ln.indent < indent:
            break
        if ln.indent > indent:
            raise YamlError("line %d: unexpected indentation in mapping" % ln.no)
        if ln.text.startswith("- "):
            break
        m = re.match(r"^([A-Za-z0-9_.-]+):\s*(.*)$", ln.text)
        if not m:
            raise YamlError("line %d: expected 'key: value' — got %r" % (ln.no, ln.text))
        key, val = m.group(1), m.group(2).strip()
        if val == "":
            child, idx = _parse_block(lines, idx + 1, indent + 2)
            out[key] = child if child is not None else None
        else:
            out[key] = _scalar_or_flow(val)
            idx += 1
    return out, idx


def parse_yaml(src):
    lines = _tokenize(src)
    if not lines:
        return {}
    val, idx = _parse_block(lines, 0, lines[0].indent)
    if idx != len(lines):
        raise YamlError("line %d: trailing content not parsed" % lines[idx].no)
    return val


# ─────────────────────────────────────────────────────────────────────────────
# 2. Data-file model + schema defaults/validation
# ─────────────────────────────────────────────────────────────────────────────

VALID_TOPOLOGY = ("star", "mesh")
VALID_TIER = ("manual", "tailscale", "token")
VALID_FOLDER_TYPE = ("sendreceive", "sendonly", "receiveonly")


def load_data(path):
    try:
        with open(path, "r") as fh:
            raw = fh.read()
    except OSError as e:
        die(EXIT_DATA, "cannot read data file %s: %s" % (path, e))
    try:
        data = parse_yaml(raw)
    except YamlError as e:
        die(EXIT_DATA, "parse error in %s: %s" % (path, e))
    if not isinstance(data, dict):
        die(EXIT_DATA, "data file %s: top level must be a mapping" % path)

    # Schema defaults (the bash engine + this reader both apply defaults; absent
    # optional keys are not an error).
    data.setdefault("topology", "star")
    data.setdefault("introducer", False)
    gui = data.setdefault("gui", {}) or {}
    gui.setdefault("bind", "local")
    data["gui"] = gui
    adm = data.setdefault("admission", {}) or {}
    adm.setdefault("tier", "manual")
    adm.setdefault("allow", [])
    data["admission"] = adm
    data["hubs"] = data.get("hubs") or []
    data["folders"] = data.get("folders") or []

    _validate_data(data, path)
    return data


def _validate_data(data, path):
    errs = []
    if data["topology"] not in VALID_TOPOLOGY:
        errs.append("topology must be one of %s" % (VALID_TOPOLOGY,))
    if not isinstance(data["introducer"], bool):
        errs.append("introducer must be a boolean")
    if data["introducer"] and data["topology"] != "mesh":
        errs.append("introducer: true is only allowed with topology: mesh "
                    "(introducer ⇒ all-to-all N² connections; star keeps it off)")
    if data["admission"]["tier"] not in VALID_TIER:
        errs.append("admission.tier must be one of %s" % (VALID_TIER,))
    for i, h in enumerate(data["hubs"]):
        if not isinstance(h, dict) or not h.get("id"):
            errs.append("hubs[%d] needs an 'id'" % i)
            continue
        if not _looks_like_device_id(h["id"]):
            errs.append("hubs[%d].id %r is not a Syncthing device id" % (i, h["id"]))
    for i, f in enumerate(data["folders"]):
        if not isinstance(f, dict) or not f.get("id"):
            errs.append("folders[%d] needs an 'id'" % i)
            continue
        if not f.get("path"):
            errs.append("folders[%d] (%s) needs a 'path'" % (i, f["id"]))
        ftype = f.get("type", "sendreceive")
        if ftype not in VALID_FOLDER_TYPE:
            errs.append("folders[%d].type %r invalid" % (i, ftype))
    if errs:
        die(EXIT_DATA, "invalid data file %s:\n  - %s" % (path, "\n  - ".join(errs)))


def _looks_like_device_id(s):
    # Syncthing IDs are 8 groups of 7 base32-ish chars separated by '-' (the
    # human form), case-insensitive. Be lenient on dashes/length.
    canon = str(s).replace("-", "").strip()
    return len(canon) >= 52 and re.fullmatch(r"[A-Za-z0-9]+", canon) is not None


# ─────────────────────────────────────────────────────────────────────────────
# 3. Pure policy resolvers (unit-testable without a daemon)
# ─────────────────────────────────────────────────────────────────────────────

def resolve_bind(policy, port=DEFAULT_PORT):
    """Map a fail-closed bind policy to a concrete address.

    local       → 127.0.0.1:<port>
    tailscale   → <tailscale ip -4>:<port>  (resolved at runtime)
    <ip:port>   → explicit; 0.0.0.0 REJECTED unless MESH_SYNCTHING_UNSAFE_BIND=1
    """
    policy = (policy or "local").strip()
    unsafe = os.environ.get("MESH_SYNCTHING_UNSAFE_BIND", "") == "1"
    if policy == "local":
        return "127.0.0.1:%d" % port
    if policy == "tailscale":
        ip = _tailscale_ip4()
        if not ip:
            die(EXIT_POLICY, "gui.bind: tailscale — could not resolve a Tailscale "
                             "IPv4 (is `tailscale` up?); refusing to guess a bind")
        return "%s:%d" % (ip, port)
    # explicit host:port (or bare host)
    host = policy
    p = port
    if ":" in policy:
        host, _, ptxt = policy.rpartition(":")
        try:
            p = int(ptxt)
        except ValueError:
            die(EXIT_POLICY, "gui.bind: %r has a non-numeric port" % policy)
    if host in ("0.0.0.0", "::", "[::]") and not unsafe:
        die(EXIT_POLICY,
            "gui.bind %r exposes the high-privilege REST/GUI on every interface. "
            "Refused. Use 'local' or 'tailscale', or set MESH_SYNCTHING_UNSAFE_BIND=1 "
            "to override deliberately." % policy)
    return "%s:%d" % (host, p)


def _tailscale_ip4():
    try:
        r = subprocess.run(["tailscale", "ip", "-4"],
                           capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    line = r.stdout.strip().splitlines()
    return line[0].strip() if line else None


def namespace_dir(folder_path, myid):
    """Per-node write namespace: <folder>/<myid>/ (anti-poison, decision 6).

    Each node writes ONLY under its own id-named subdir so a compromised node can
    corrupt only its own slice. The export tooling enforces routing; here we just
    compute + (on pair) materialise the directory."""
    base = os.path.expanduser(folder_path)
    return os.path.join(base, str(myid))


# ─────────────────────────────────────────────────────────────────────────────
# 4. REST client
# ─────────────────────────────────────────────────────────────────────────────

class Rest:
    def __init__(self):
        self.base = os.environ.get("MESH_ST_BASE", "http://127.0.0.1:8384").rstrip("/")
        self.api = os.environ.get("MESH_ST_APIKEY", "")
        if not self.api:
            die(EXIT_USAGE, "MESH_ST_APIKEY not set (the bash lib extracts it from config.xml)")

    def _req(self, method, path, data=None):
        url = self.base + path
        headers = {"X-API-Key": self.api}
        body = None
        if data is not None:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, method=method, headers=headers, data=body)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            die(EXIT_REST, "%s %s → HTTP %s: %s" % (method, path, e.code,
                                                    e.read().decode("utf-8", "replace")[:200]))
        except urllib.error.URLError as e:
            die(EXIT_REST, "%s %s → unreachable: %s" % (method, path, e.reason))
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode("utf-8", "replace")

    def get(self, path):
        return self._req("GET", path)

    def put(self, path, data):
        return self._req("PUT", path, data)

    def post(self, path, data):
        return self._req("POST", path, data)


def _gen_password(n=20):
    alpha = string.ascii_letters + string.digits
    return "".join(secrets.choice(alpha) for _ in range(n))


# ─────────────────────────────────────────────────────────────────────────────
# 5. REST operations
# ─────────────────────────────────────────────────────────────────────────────

def op_myid(rest):
    st = rest.get("/rest/system/status")
    return st.get("myID")


def ensure_gui_auth(rest, user, reset=False, non_interactive=False, provided=None):
    """Password state machine (proposal §4.3).

    Returns {"action": created|reset|kept, "user": U, "password": <plaintext|None>}.
    Plaintext is non-null ONLY on the run that creates/resets it (bcrypt is
    one-way — an already-set password is unrecoverable for display)."""
    gui = rest.get("/rest/config/gui")
    has_password = bool(gui.get("password"))  # bcrypt hash when set
    existing_user = gui.get("user") or ""

    if has_password and not reset:
        # Never silently overwrite. Honour an explicit user only if none set.
        if not existing_user and user:
            gui["user"] = user
            rest.put("/rest/config/gui", gui)
        return {"action": "kept", "user": gui.get("user") or user or "", "password": None}

    new_pw = provided or _gen_password()
    gui["user"] = user or existing_user or "mesh"
    gui["password"] = new_pw  # Syncthing bcrypts on save
    rest.put("/rest/config/gui", gui)
    return {"action": "reset" if reset else "created", "user": gui["user"], "password": new_pw}


def apply_gui_config(rest, user, address, reset=False, provided=None):
    """Single GET-modify-PUT that sets the bind address and, per the §4.3 state
    machine, the user/password — in ONE request. Applied LAST in a pair run so a
    bind change (which can move the listener off the REST endpoint we are using)
    never severs the session mid-reconcile, and so the password is written at most
    once (avoids any re-hash of an already-bcrypt value).

    Returns {"action": created|reset|kept, "user", "password": <plaintext|None>,
             "address"}."""
    gui = rest.get("/rest/config/gui")
    has_password = bool(gui.get("password"))  # bcrypt hash when set
    existing_user = gui.get("user") or ""
    action = "kept"
    plaintext = None
    if (not has_password) or reset:
        plaintext = provided or _gen_password()
        gui["user"] = user or existing_user or "mesh"
        gui["password"] = plaintext  # Syncthing bcrypts plaintext on save
        action = "reset" if reset else "created"
    elif not existing_user and user:
        gui["user"] = user
    gui["address"] = address
    rest.put("/rest/config/gui", gui)
    return {"action": action, "user": gui.get("user") or user or "",
            "password": plaintext, "address": address}


def set_bind(rest, address):
    gui = rest.get("/rest/config/gui")
    if gui.get("address") == address:
        return {"action": "unchanged", "address": address}
    gui["address"] = address
    rest.put("/rest/config/gui", gui)
    return {"action": "set", "address": address}


def upsert_device(rest, dev_id, name, addresses=None, introducer=False):
    addresses = addresses or ["dynamic"]
    devices = rest.get("/rest/config/devices")
    existing = next((d for d in devices if d["deviceID"] == dev_id), None)
    if existing:
        changed = False
        if existing.get("addresses") != addresses:
            existing["addresses"] = addresses
            changed = True
        if bool(existing.get("introducer")) != bool(introducer):
            existing["introducer"] = bool(introducer)
            changed = True
        if changed:
            rest.put("/rest/config/devices/%s" % dev_id, existing)
            return {"action": "updated", "id": dev_id}
        return {"action": "unchanged", "id": dev_id}
    rest.post("/rest/config/devices", {
        "deviceID": dev_id, "name": name, "addresses": addresses,
        "compression": "metadata", "introducer": bool(introducer),
        "skipIntroductionRemovals": False, "paused": False,
        "autoAcceptFolders": False,
    })
    return {"action": "added", "id": dev_id}


def upsert_folder(rest, fid, path, ftype, share_ids, label=None):
    folders = rest.get("/rest/config/folders")
    want_devices = [{"deviceID": d} for d in share_ids]
    existing = next((f for f in folders if f["id"] == fid), None)
    expanded = os.path.expanduser(path)
    if existing:
        have = {d["deviceID"] for d in existing.get("devices", [])}
        want = set(share_ids)
        changed = False
        if not want.issubset(have):
            merged = list(have | want)
            existing["devices"] = [{"deviceID": d} for d in merged]
            changed = True
        if existing.get("type") != ftype:
            existing["type"] = ftype
            changed = True
        if changed:
            rest.put("/rest/config/folders/%s" % fid, existing)
            return {"action": "updated", "id": fid}
        return {"action": "unchanged", "id": fid}
    rest.post("/rest/config/folders", {
        "id": fid, "label": label or fid, "path": expanded, "type": ftype,
        "devices": want_devices, "rescanIntervalS": 3600,
        "fsWatcherEnabled": True, "fsWatcherDelayS": 10, "markerName": ".stfolder",
    })
    return {"action": "created", "id": fid}


def collect_status(rest, folder_ids=None):
    conns = (rest.get("/rest/system/connections") or {}).get("connections", {})
    devices = rest.get("/rest/config/devices") or []
    name_of = {d["deviceID"]: d.get("name", "") for d in devices}
    peers = []
    for did, info in conns.items():
        peers.append({
            "id": did,
            "name": name_of.get(did, ""),
            "connected": bool(info.get("connected")),
            "address": info.get("address", ""),
        })
    folders = []
    fids = folder_ids
    if fids is None:
        fids = [f["id"] for f in (rest.get("/rest/config/folders") or [])]
    for fid in fids:
        st = rest.get("/rest/db/status?folder=%s" % fid) or {}
        folders.append({
            "id": fid,
            "state": st.get("state", "unknown"),
            "globalBytes": st.get("globalBytes", 0),
            "needBytes": st.get("needBytes", 0),
            "needItems": st.get("needTotalItems", st.get("needFiles", 0)),
        })
    return {"peers": peers, "folders": folders}


# ─────────────────────────────────────────────────────────────────────────────
# 6. Composite commands
# ─────────────────────────────────────────────────────────────────────────────

def cmd_pair(data_path, self_name, non_interactive):
    data = load_data(data_path)
    rest = Rest()
    myid = op_myid(rest)
    if not myid:
        die(EXIT_REST, "could not read this node's device id (myID)")

    warnings = []
    hubs = data["hubs"]
    if not hubs:
        die(EXIT_DATA, "hubs: is empty — run `mesh syncthing init-hub` on the "
                       "machine you choose as a hub first, then commit its id here")

    hub_ids = [h["id"] for h in hubs]
    am_i_hub = myid in hub_ids

    # Resolve the bind policy EARLY (fail-closed: a 0.0.0.0 / unresolvable
    # tailscale policy aborts before we touch anything) but APPLY it LAST — a
    # bind change can move the listener off the REST endpoint we are driving.
    bind = resolve_bind(data["gui"].get("bind", "local"), DEFAULT_PORT)

    # devices: every hub except self. Introducer only in an explicit `mesh` topology.
    use_introducer = bool(data["introducer"]) and data["topology"] == "mesh"
    for h in hubs:
        if h["id"] == myid:
            continue
        addrs = h.get("addresses") or ["dynamic"]
        if isinstance(addrs, str):
            addrs = [addrs]
        upsert_device(rest, h["id"], h.get("name", "hub"), addrs, introducer=use_introducer)

    # folders: shared with self + all hubs (the leaf↔hub edges; the hub adds each
    # leaf on approve). Folder ID must match on every machine.
    share_base = [myid] + [hid for hid in hub_ids if hid != myid]
    folder_summ = []
    for f in data["folders"]:
        fid = f["id"]
        path = f["path"]
        ftype = f.get("type", "sendreceive")
        is_new = not any(x["id"] == fid for x in (rest.get("/rest/config/folders") or []))
        if is_new:
            _data_loss_guard(path, warnings)
        upsert_folder(rest, fid, path, ftype, share_base, label=f.get("label"))
        ns_dir = None
        if f.get("namespacing") == "per-node":
            ns_dir = namespace_dir(path, myid)
            try:
                os.makedirs(ns_dir, exist_ok=True)
            except OSError as e:
                warnings.append("could not create namespace dir %s: %s" % (ns_dir, e))
        folder_summ.append({"id": fid, "path": os.path.expanduser(path),
                            "type": ftype, "namespace_dir": ns_dir})

    # Collect status BEFORE the bind change (a rebind may drop this base).
    status = collect_status(rest, [f["id"] for f in data["folders"]])
    hub_connected = any(p["connected"] and p["id"] in hub_ids for p in status["peers"])
    pending_approve = (not am_i_hub) and (not hub_connected)

    # FINAL mutation: one gui PUT applying auth (state machine; never silently
    # overwrites an existing password) + the resolved bind.
    auth = apply_gui_config(rest, data["gui"].get("user", "mesh"), bind, reset=False)

    emit({
        "myid": myid,
        "self_name": self_name,
        "am_i_hub": am_i_hub,
        "topology": data["topology"],
        "introducer": use_introducer,
        "gui": {"user": auth["user"], "bind": auth["address"],
                "password_action": auth["action"], "password": auth["password"],
                "url": "http://%s" % _ui_host(auth["address"])},
        "hubs": [{"id": h["id"], "name": h.get("name", ""),
                  "addresses": h.get("addresses")} for h in hubs],
        "peers": status["peers"],
        "folders": folder_summ,
        "folder_status": status["folders"],
        "pending_approve": pending_approve,
        "warnings": warnings,
    })


def _ui_host(address):
    # For the admin-UI URL, present 127.0.0.1 verbatim; an explicit bind shows as-is.
    return address


def _hub_admin_url(hub):
    """Best-effort hub admin-UI URL from the hub's declared sync addresses: take
    the first explicit ``tcp://HOST:PORT`` and swap to the GUI port. Returns None
    when the hub only advertises ``dynamic`` (no host to derive from) — the caller
    then falls back to the generic "run `mesh syncthing url` on the hub" hint."""
    for addr in (hub.get("addresses") or []):
        m = re.match(r"^tcp://(\[[0-9A-Fa-f:]+\]|[^:/\s]+)(?::\d+)?/?$", str(addr))
        if m:
            return "http://%s:%d" % (m.group(1), DEFAULT_PORT)
    return None


def _data_loss_guard(path, warnings):
    expanded = os.path.expanduser(path)
    if not os.path.isdir(expanded):
        return
    try:
        entries = [e for e in os.listdir(expanded) if e != ".stfolder"]
    except OSError:
        return
    if entries and not os.path.exists(os.path.join(expanded, ".stfolder")):
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        warnings.append(
            "folder path %s is non-empty and not yet a Syncthing folder. The "
            "mesh content can overwrite it on first sync. Back it up before "
            "approving on the hub:  cp -a %s %s.pre-sync-%s"
            % (expanded, expanded, expanded, stamp))


def cmd_status(data_path):
    rest = Rest()
    myid = op_myid(rest)
    fids = None
    self_name = None
    user = None
    if data_path and os.path.exists(data_path):
        data = load_data(data_path)
        fids = [f["id"] for f in data["folders"]]
        user = data["gui"].get("user")
    gui = rest.get("/rest/config/gui") or {}
    status = collect_status(rest, fids)
    emit({
        "myid": myid,
        "gui": {"user": gui.get("user") or user or "",
                "address": gui.get("address", ""),
                "auth": bool(gui.get("password")),
                "url": "http://%s" % (gui.get("address") or "127.0.0.1:8384")},
        "peers": status["peers"],
        "folders": status["folders"],
    })


def cmd_reset_password(user):
    rest = Rest()
    res = ensure_gui_auth(rest, user, reset=True)
    emit(res)


def cmd_init_hub(data_path, write, topology=None):
    rest = Rest()
    myid = op_myid(rest)
    if not myid:
        die(EXIT_REST, "could not read this node's device id (myID)")
    name = os.environ.get("MESH_ST_SELF_NAME") or os.uname().nodename
    snippet = ("hubs:\n"
               "  - id: %s\n"
               "    name: %s\n"
               "    addresses: [dynamic]\n" % (myid, name))
    wrote = False
    already = False
    topo_written = None
    if data_path and os.path.exists(data_path):
        data = load_data(data_path)
        if any(h["id"] == myid for h in data["hubs"]):
            already = True
        elif write and not data["hubs"]:
            _append_hub_block(data_path, myid, name)
            wrote = True
        # Topology is a separate concern from the hub block: only touched when the
        # caller passes an explicit choice (the interactive prompt / --topology
        # lives in the runner). Re-running without a choice never flips it.
        if topology:
            t, i = _set_topology(data_path, topology)
            load_data(data_path)  # re-validate: the pair must still pass _validate_data
            topo_written = {"topology": t, "introducer": i}
    emit({"myid": myid, "name": name, "wrote": wrote, "already_present": already,
          "topology_written": topo_written is not None,
          "topology_value": topo_written["topology"] if topo_written else "",
          "introducer_value": topo_written["introducer"] if topo_written else False,
          "snippet": snippet})


def cmd_topology(data_path, topology):
    """`mesh syncthing topology [<star|mesh>]` — report or switch the mesh-wide
    topology. With no value: report the current pair. With a value: rewrite the
    consistent pair and re-validate."""
    if not data_path or not os.path.exists(data_path):
        die(EXIT_DATA, "no syncthing-mesh.yaml to read/set topology in (%r)" % data_path)
    if not topology:
        data = load_data(data_path)
        emit({"topology": data["topology"], "introducer": data["introducer"],
              "changed": False})
        return
    t, i = _set_topology(data_path, topology)
    load_data(data_path)  # re-validate the written pair
    emit({"topology": t, "introducer": i, "changed": True})


def _append_hub_block(path, myid, name):
    """Append a hub entry ONLY when the file has no hubs yet. Conservative: we
    replace a literal empty `hubs:` / `hubs: []` line, else append a fresh block."""
    with open(path, "r") as fh:
        text = fh.read()
    block = ("hubs:\n"
             "  - id: %s\n"
             "    name: %s\n"
             "    addresses: [dynamic]\n" % (myid, name))
    new = re.sub(r"(?m)^hubs:\s*(\[\s*\])?\s*$\n?", block, text, count=1)
    if new == text:  # no hubs: line found → append
        if not text.endswith("\n"):
            text += "\n"
        new = text + "\n" + block
    with open(path, "w") as fh:
        fh.write(new)


def _topo_pair(topology):
    """Map a topology choice to its only valid (topology, introducer) pair:
    mesh ⇒ introducer on (all-to-all), star ⇒ introducer off. This is the
    contract _validate_data enforces — we never write the rejected combo."""
    topo = (topology or "").strip().lower()
    if topo not in VALID_TOPOLOGY:
        die(EXIT_USAGE, "topology must be one of %s" % (VALID_TOPOLOGY,))
    return topo, (topo == "mesh")


def _replace_line(text, key, newline):
    """Replace the first top-level `key:` line wholesale (comment included) with
    `newline`. Returns (text, replaced?). A function-repl avoids backref/escape
    surprises when `newline` contains characters like `\\`."""
    pat = re.compile(r"(?m)^%s:[^\n]*$" % re.escape(key))
    new, n = pat.subn(lambda _m: newline, text, count=1)
    return new, n > 0


def _set_topology(path, topology):
    """Write the consistent topology+introducer pair into the yaml. Same
    conservative, line-oriented style as _append_hub_block: rewrite the two
    existing top-level lines (with a fresh, accurate comment — the old comment
    would now lie), or prepend them if the file omits them. Returns the pair."""
    topo, intro = _topo_pair(topology)
    intro_s = "true" if intro else "false"
    topo_line = ("topology: %-13s# chosen via `mesh syncthing init-hub` — %s"
                 % (topo, "small net: all-to-all, resilient"
                    if topo == "mesh" else "scales to many machines"))
    intro_line = ("introducer: %-10s# %s"
                  % (intro_s, "mesh ⇒ a trusted node can vouch for new edges"
                     if intro else "star keeps the N² introducer fan-out off"))
    with open(path, "r") as fh:
        text = fh.read()
    text, ok_t = _replace_line(text, "topology", topo_line)
    text, ok_i = _replace_line(text, "introducer", intro_line)
    prefix = ""
    if not ok_t:
        prefix += topo_line + "\n"
    if not ok_i:
        prefix += intro_line + "\n"
    if prefix:
        text = prefix + text
    with open(path, "w") as fh:
        fh.write(text)
    return topo, intro


# ─────────────────────────────────────────────────────────────────────────────
# 7. Human-facing banners (proposal §4.5 / §4.6) — render from pair/status JSON
# ─────────────────────────────────────────────────────────────────────────────

_BOX_W = 74


def _box(title, lines):
    head = "┌─ %s " % title
    head = head + "─" * max(0, _BOX_W - len(head) - 1) + "┐"
    out = [head]
    for ln in lines:
        out.append("  " + ln)
    out.append("└" + "─" * (_BOX_W - 2) + "┘")
    return "\n".join(out)


def _short(devid):
    return (devid or "")[:7]


def _pw_line(action, password, user):
    if action in ("created", "reset") and password:
        return "login: %s / %s   ← save this" % (user, password)
    return ("login: %s / (already set — `mesh syncthing password --reset` to view)"
            % user)


def _fmt_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (int(n), unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024


def render_pair(d):
    gui = d.get("gui", {})
    warnings = d.get("warnings", [])
    if d.get("am_i_hub"):
        folders = " · ".join("%s (%s)" % (f["id"], f.get("type", "")) for f in d.get("folders", []))
        lines = [
            "ID  %s   (matches a hub in syncthing-mesh.yaml)" % d["myid"],
            "✔ GUI auth (%s)     ✔ folder %s" % (gui.get("user", ""), folders or "—"),
            "Admin UI: %s" % gui.get("url", ""),
            "",
            "As each NEW machine runs `mesh syncthing pair`, an \"approve device\"",
            "bar appears here — Add → Save; the hub then shares the folder with it.",
        ]
        text = _box("Syncthing — this machine is the mesh HUB", lines)
    elif d.get("pending_approve"):
        hub = (d.get("hubs") or [{}])[0]
        folder = (d.get("folders") or [{}])[0]
        hub_url = _hub_admin_url(hub)
        open_step = ("  1. Open the hub admin UI:  %s" % hub_url) if hub_url \
            else "  1. Open the hub admin UI — run `mesh syncthing url` on the hub for the address."
        lines = [
            "This machine : %-12s ID %s" % (d.get("self_name", ""), d["myid"]),
            "Mesh hub     : %-12s ID %s" % (hub.get("name", ""), hub.get("id", "")),
            "",
            "Already done automatically on THIS machine:",
            "  %s" % _pw_line(gui.get("password_action"), gui.get("password"), gui.get("user", "")),
            "  ✔ hub(s) added as device(s)",
            "  ✔ folder %s created & offered to the hub" % folder.get("id", ""),
            "",
            "ONE manual step — only the first time this machine joins:",
            open_step,
            "  2. \"New Device %s… (%s)\" → Add Device → Save" % (_short(d["myid"]), d.get("self_name", "")),
            "  3. \"New Folder %s offered by %s\" → Add → keep %s → Save"
            % (folder.get("id", ""), d.get("self_name", ""), folder.get("path", "")),
            "  4. Return here and press Enter — I'll verify the link.",
            "",
            "Nothing to copy by hand: the hub sees this machine's ID via the connection.",
        ]
        text = _box("Syncthing — join the mesh (first-time setup on THIS machine)", lines)
    else:
        peers = []
        hub_ids = {h["id"] for h in d.get("hubs", [])}
        for p in d.get("peers", []):
            mark = "✔ connected" if p["connected"] else "⏳ pending-approve"
            tag = p["name"] or _short(p["id"])
            peers.append("%s %s" % (tag, mark))
        fstat = {f["id"]: f for f in d.get("folder_status", [])}
        folders = []
        for f in d.get("folders", []):
            st = fstat.get(f["id"], {})
            folders.append("%s  %s (%s)" % (f["id"], st.get("state", "?"),
                                           _fmt_bytes(st.get("globalBytes", 0))))
        lines = [
            "Admin UI : %s" % gui.get("url", ""),
            "           %s" % _pw_line(gui.get("password_action"), gui.get("password"), gui.get("user", "")),
            "This node: %s   \"%s\"" % (d["myid"], d.get("self_name", "")),
            "Peers    : %s" % ("   ·   ".join(peers) if peers else "(none yet)"),
            "Folders  : %s" % ("   ·   ".join(folders) if folders else "(none)"),
        ]
        text = _box("Syncthing — mesh status", lines)
    parts = [text]
    for w in warnings:
        parts.append("\n  ⚠ " + w)
    return "\n".join(parts)


def render_status(d):
    gui = d.get("gui", {})
    url = gui.get("url", "")
    if "0.0.0.0" in url:
        url = url.replace("0.0.0.0", "127.0.0.1")
    peers = []
    for p in d.get("peers", []):
        mark = "✔ connected" if p["connected"] else "⏳ not connected"
        peers.append("%s %s" % (p["name"] or _short(p["id"]), mark))
    folders = []
    for f in d.get("folders", []):
        folders.append("%s  %s (%s, need %s)" % (
            f["id"], f.get("state", "?"), _fmt_bytes(f.get("globalBytes", 0)),
            _fmt_bytes(f.get("needBytes", 0))))
    lines = [
        "Admin UI : %s%s" % (url, "  (auth on)" if gui.get("auth") else "  (no auth)"),
        "This node: %s" % d.get("myid", ""),
        "Peers    : %s" % ("   ·   ".join(peers) if peers else "(none)"),
        "Folders  : %s" % ("   ·   ".join(folders) if folders else "(none)"),
    ]
    return _box("Syncthing — mesh status", lines)


def cmd_render(kind):
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except ValueError:
        die(EXIT_USAGE, "render: stdin is not valid JSON")
    if kind == "pair":
        sys.stdout.write(render_pair(d) + "\n")
    elif kind == "status":
        sys.stdout.write(render_status(d) + "\n")
    else:
        die(EXIT_USAGE, "render: unknown kind %r" % kind)


def cmd_get(field):
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except ValueError:
        die(EXIT_USAGE, "get: stdin is not valid JSON")
    val = d.get(field)
    if isinstance(val, bool):
        sys.stdout.write(("true" if val else "false") + "\n")
    elif val is None:
        sys.stdout.write("\n")
    else:
        sys.stdout.write(str(val) + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# 8. CLI dispatch
# ─────────────────────────────────────────────────────────────────────────────

def _getarg(args, flag, default=None):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def _hasflag(args, flag):
    return flag in args


def main(argv):
    if not argv:
        die(EXIT_USAGE, "no command (read-data|resolve-bind|namespace-dir|myid|"
                        "ensure-gui-auth|set-bind|upsert-device|upsert-folder|"
                        "status|pair|reset-password|init-hub|topology)")
    cmd, args = argv[0], argv[1:]

    if cmd == "read-data":
        if not args:
            die(EXIT_USAGE, "read-data <path>")
        emit(load_data(args[0]))
    elif cmd == "resolve-bind":
        if not args:
            die(EXIT_USAGE, "resolve-bind <policy> [--port N]")
        port = int(_getarg(args, "--port", DEFAULT_PORT))
        sys.stdout.write(resolve_bind(args[0], port) + "\n")
    elif cmd == "namespace-dir":
        if len(args) < 2:
            die(EXIT_USAGE, "namespace-dir <folder-path> <myid>")
        sys.stdout.write(namespace_dir(args[0], args[1]) + "\n")
    elif cmd == "myid":
        sys.stdout.write((op_myid(Rest()) or "") + "\n")
    elif cmd == "ensure-gui-auth":
        rest = Rest()
        emit(ensure_gui_auth(rest, _getarg(args, "--user", "mesh"),
                             reset=_hasflag(args, "--reset"),
                             non_interactive=_hasflag(args, "--non-interactive"),
                             provided=_getarg(args, "--password")))
    elif cmd == "set-bind":
        if not args:
            die(EXIT_USAGE, "set-bind <address>")
        emit(set_bind(Rest(), args[0]))
    elif cmd == "upsert-device":
        rest = Rest()
        addrs = _getarg(args, "--addresses")
        emit(upsert_device(rest, _getarg(args, "--id"), _getarg(args, "--name", "peer"),
                           [a.strip() for a in addrs.split(",")] if addrs else None,
                           introducer=_hasflag(args, "--introducer")))
    elif cmd == "upsert-folder":
        rest = Rest()
        share = _getarg(args, "--share", "")
        emit(upsert_folder(rest, _getarg(args, "--id"), _getarg(args, "--path"),
                           _getarg(args, "--type", "sendreceive"),
                           [s.strip() for s in share.split(",") if s.strip()],
                           label=_getarg(args, "--label")))
    elif cmd == "status":
        cmd_status(_getarg(args, "--data"))
    elif cmd == "pair":
        cmd_pair(_getarg(args, "--data"), _getarg(args, "--self-name", os.uname().nodename),
                 non_interactive=_hasflag(args, "--non-interactive"))
    elif cmd == "reset-password":
        cmd_reset_password(_getarg(args, "--user", "mesh"))
    elif cmd == "init-hub":
        cmd_init_hub(_getarg(args, "--data"), write=_hasflag(args, "--write"),
                     topology=_getarg(args, "--topology"))
    elif cmd == "topology":
        cmd_topology(_getarg(args, "--data"), _getarg(args, "--set"))
    elif cmd == "render":
        if not args:
            die(EXIT_USAGE, "render <pair|status>  (JSON on stdin)")
        cmd_render(args[0])
    elif cmd == "get":
        if not args:
            die(EXIT_USAGE, "get <field>  (JSON on stdin)")
        cmd_get(args[0])
    else:
        die(EXIT_USAGE, "unknown command: %s" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
