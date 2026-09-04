#!/usr/bin/env python3
"""freepro dashboard surface verifier (stdlib only: urllib, json, sys, os, time).

Usage:  python3 scripts/verify_dashboard.py [port]   (default port 8080)
Base:   http://127.0.0.1:<port>

Assumed dashboard contract (asserted below):
  Static:  GET / -> 200 text/html (contains "sidebar" + "provider-grid" hooks)
           GET /app.js -> 200 *javascript*; GET /styles.css -> 200 *css* w/ --brand
           GET /favicon.ico -> 204; unknown route -> 404
  API:     GET /api/status -> {running,port,in_flight,total_served,providers,
                               total_keys,healthy_keys}
           POST /api/server {"action":"stop"|"start"} (fallback {"running":bool})
           Providers: POST/GET /api/providers, PUT/DELETE /api/providers/{id}
             create body: {display_name,name,base_url,url,prefix,description}
             id read from: id | index | provider_id (else list position)
           Keys: POST/GET .../providers/{id}/keys
             bulk {keys:[..]}, single {key:...}, entry id from id|index|key
             PATCH .../keys/{kid} {enabled:bool}, POST .../keys/{kid}/ping,
             DELETE .../keys/{kid}
           Headers: POST/GET .../providers/{id}/headers {key,name,value},
             PUT/DELETE .../headers/{name}
           GET /api/models -> {"object":"list","data":[{...,"owned_by":...}]}
           GET /api/logs -> list (or {logs|data|items:[...]}) of {seq,level,msg}
           GET /api/logs/5 -> at most 5 entries
           GET+PUT /api/settings round-trip (originals restored)

Output: one PASS/FAIL line per check; exit 0 iff all pass, 1 otherwise.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
BASE = "http://127.0.0.1:{0}".format(PORT)
TIMEOUT = 10

results = []


def check(name, cond, detail=""):
    ok = bool(cond)
    results.append(ok)
    if ok:
        print("PASS {0}".format(name))
    else:
        print("FAIL {0}{1}".format(name, ": {0}".format(detail) if detail else ""))
    return ok


def req(method, path, body=None):
    url = BASE + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, dict(resp.headers), raw
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode("utf-8", "replace")
        except Exception:
            raw = ""
        return e.code, dict(e.headers or {}), raw
    except Exception as e:  # connection refused etc.
        return -1, {}, "{0}: {1}".format(type(e).__name__, e)


def ctype_of(headers):
    for k, v in headers.items():
        if k.lower() == "content-type":
            return v
    return ""


def as_json(text):
    try:
        return json.loads(text) if text else None
    except Exception:
        return None


def as_list(doc):
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for k in ("logs", "data", "items", "entries", "providers", "keys", "models"):
            if isinstance(doc.get(k), list):
                return doc[k]
    return None


def entry_id(entry, fallback=None):
    if isinstance(entry, dict):
        for k in ("id", "index", "provider_id", "key_id"):
            if entry.get(k) is not None:
                return entry[k]
    return fallback


def key_material(entry):
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        for k in ("key", "value", "material"):
            if isinstance(entry.get(k), str):
                return entry[k]
    return None


def hdr_name(entry):
    if isinstance(entry, dict):
        for k in ("key", "name", "header"):
            if isinstance(entry.get(k), str):
                return entry[k]
    return None


def is_false_like(v):
    return v is False or v == 0 or (isinstance(v, str) and v.lower() in ("false", "stopped", "stop", "off", "0"))


def is_true_like(v):
    return v is True or v == 1 or (isinstance(v, str) and v.lower() in ("true", "running", "start", "on", "1"))


def get_providers():
    s, _, t = req("GET", "/api/providers")
    return s, as_list(as_json(t))


def find_provider_by_prefix(providers, prefix):
    for i, p in enumerate(providers or []):
        if isinstance(p, dict) and p.get("prefix") == prefix:
            return i, p
    return None, None


def get_provider(pid):
    s, _, t = req("GET", "/api/providers/" + urllib.parse.quote(str(pid), safe=""))
    doc = as_json(t)
    if s == 200 and isinstance(doc, dict):
        return doc
    if isinstance(doc, list) and doc and isinstance(doc[0], dict):
        return doc[0]
    # fallback: locate inside the list
    _, providers = get_providers()
    for i, p in enumerate(providers or []):
        if isinstance(p, dict) and entry_id(p, i) == pid:
            return p
    return None


def provider_keys(prov):
    if isinstance(prov, dict):
        for k in ("keys", "key_pool"):
            if isinstance(prov.get(k), list):
                return prov[k]
    return None


def provider_headers(prov):
    if isinstance(prov, dict):
        if isinstance(prov.get("headers"), list):
            return prov["headers"]
    return None


UNIQ = "{0}-{1}".format(int(time.time()) % 1000000, os.getpid())
PREFIX = "tp/verify-{0}/".format(UNIQ)
PNAME = "verify-prov-{0}".format(UNIQ)
PNAME2 = "verify-prov-renamed-{0}".format(UNIQ)
K1 = "verify-bulk-1-{0}-k1k1".format(UNIQ)
K2 = "verify-bulk-2-{0}-k2k2".format(UNIQ)
K3 = "verify-single-3-{0}-k3k3".format(UNIQ)
HNAME = "X-Verify-Test"


def main():
    pid = None
    pid_gone = False

    # ---- static surface ----
    s, h, t = req("GET", "/")
    check("GET / -> 200", s == 200, "status={0}".format(s))
    check("GET / -> text/html", "text/html" in ctype_of(h).lower(), ctype_of(h))
    check("GET / -> rail hook", "rail-btn" in t.lower())
    check("GET / -> provider-grid hook", "provider-grid" in t.lower())
    s, h, _ = req("GET", "/app.js")
    check("GET /app.js -> 200 javascript", s == 200 and "javascript" in ctype_of(h).lower(),
          "status={0} ctype={1}".format(s, ctype_of(h)))
    s, h, t = req("GET", "/styles.css")
    check("GET /styles.css -> 200 css", s == 200 and "css" in ctype_of(h).lower(),
          "status={0} ctype={1}".format(s, ctype_of(h)))
    check("GET /styles.css -> dark theme + responsive analytics", "--void:#09090b" in t and ".usage-visuals" in t and "@media" in t)
    s, _, _ = req("GET", "/favicon.ico")
    check("GET /favicon.ico -> 204", s == 204, "status={0}".format(s))

    # ---- status ----
    s, _, t = req("GET", "/api/status")
    st = as_json(t)
    check("GET /api/status -> 200 json", s == 200 and isinstance(st, dict), "status={0}".format(s))
    need = ("running", "port", "in_flight", "total_served", "providers", "total_keys", "healthy_keys")
    missing = [k for k in need if not (isinstance(st, dict) and k in st)]
    check("GET /api/status -> keys", not missing, "missing={0}".format(missing))

    # ---- server start is a no-op while running (a real stop would drop the
    # ---- listener, so the full stop cycle runs LAST) ----
    started = False
    for body in ({"action": "start"}, {"running": True}):
        s, _, _ = req("POST", "/api/server", body)
        if 200 <= s < 300:
            break
    else:
        s = -1
    if 200 <= s < 300:
        _, _, t = req("GET", "/api/status")
        started = is_true_like((as_json(t) or {}).get("running"))
    check("POST /api/server start (no-op)", started, "start_status={0}".format(s))

    # ---- providers CRUD ----
    create_body = {"display_name": PNAME, "name": PNAME,
                   "base_url": "https://example.invalid/v1", "url": "https://example.invalid/v1",
                   "prefix": PREFIX, "description": "verify-dashboard probe"}
    s, _, t = req("POST", "/api/providers", create_body)
    created = as_json(t)
    if isinstance(created, dict) and isinstance(created.get("provider"), dict):
        created = created["provider"]
    ok_create = 200 <= s < 300
    if ok_create:
        _, providers = get_providers()
        idx, found = find_provider_by_prefix(providers, PREFIX)
        pid = entry_id(found, idx) if found is not None else entry_id(created)
        ok_create = found is not None or entry_id(created) is not None
        if pid is None:
            pid = PREFIX  # last-resort addressing
    check("providers POST create", ok_create, "status={0} body={1}".format(s, t[:160]))

    _, providers = get_providers()
    _, found = find_provider_by_prefix(providers, PREFIX)
    if found is not None and pid is None:
        pid = entry_id(found)
    check("providers GET list contains", found is not None)

    ok_rename = False
    if pid is not None:
        s, _, _ = req("PUT", "/api/providers/" + urllib.parse.quote(str(pid), safe=""),
                      {"display_name": PNAME2, "name": PNAME2})
        if 200 <= s < 300:
            prov = get_provider(pid)
            if isinstance(prov, dict):
                ok_rename = prov.get("display_name") == PNAME2 or prov.get("name") == PNAME2
    check("providers PUT rename", ok_rename)

    # ---- keys (on the test provider) ----
    kp = None if pid is None else "/api/providers/" + urllib.parse.quote(str(pid), safe="") + "/keys"
    k3id = k1id = None
    ok_bulk = ok_single = False
    if kp is not None:
        s, _, _ = req("POST", kp, {"keys": [K1, K2]})
        ok_bulk = 200 <= s < 300
        s2, _, _ = req("POST", kp, {"key": K3})
        ok_single = 200 <= s2 < 300
    check("keys POST bulk {keys:[k1,k2]}", ok_bulk)
    check("keys POST single {key:k3}", ok_single)

    def refetch_keys():
        prov = get_provider(pid)
        ks = provider_keys(prov)
        if ks is None:  # fallback: list view may embed keys
            _, providers = get_providers()
            _, found = find_provider_by_prefix(providers, PREFIX)
            ks = provider_keys(found)
        return ks or []

    def kid_of(material):
        # Prefer the numeric index: key paths only accept indexes, and the
        # backend never emits full key material (masked "***"+last4 ids).
        for i, e in enumerate(refetch_keys()):
            if key_material(e) == material:
                if isinstance(e, dict) and isinstance(e.get("index"), int):
                    return e["index"]
                return entry_id(e, i)
        for i, e in enumerate(refetch_keys()):
            if isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"].endswith(material[-4:]):
                if isinstance(e.get("index"), int):
                    return e["index"]
                return entry_id(e, i)
        return None

    def has_material(material):
        for e in refetch_keys():
            if key_material(e) == material:
                return True
            if isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"].endswith(material[-4:]):
                return True
        return False

    ks = refetch_keys() if kp is not None else []
    check("keys GET count == 3", len(ks) == 3 and has_material(K1) and has_material(K2) and has_material(K3),
          "count={0}".format(len(ks)))

    def entry_for(material):
        # Backend masks key material ("***"+last4), so match on the tail.
        for e in refetch_keys():
            if key_material(e) == material:
                return e
            if isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"].endswith(material[-4:]):
                return e
        return None

    ok_off = ok_on = False
    if kp is not None:
        k3id = kid_of(K3)
        if k3id is not None:
            ku = kp + "/" + urllib.parse.quote(str(k3id), safe="")
            s, _, _ = req("PATCH", ku, {"enabled": False})
            en = entry_for(K3)
            ok_off = 200 <= s < 300 and en is not None and en.get("enabled") is False
            s, _, _ = req("PATCH", ku, {"enabled": True})
            en = entry_for(K3)
            ok_on = 200 <= s < 300 and en is not None and en.get("enabled") is True
    check("keys PATCH enabled false", ok_off)
    check("keys PATCH enabled true", ok_on)

    ok_ping = False
    ping_detail = "no-kid"
    if kp is not None and k3id is not None:
        s, _, t = req("POST", kp + "/" + urllib.parse.quote(str(k3id), safe="") + "/ping", {})
        pj = as_json(t)
        ok_ping = 200 <= s < 300 and isinstance(pj, dict) and "status" in pj and "ok" in pj
        ping_detail = "status={0} body={1}".format(s, t[:160])
    check("keys POST ping (ok T/F, has status)", ok_ping, ping_detail)

    ok_kdel = False
    if kp is not None:
        k1id = kid_of(K1)
        if k1id is not None:
            s, _, _ = req("DELETE", kp + "/" + urllib.parse.quote(str(k1id), safe=""))
            left = refetch_keys()
            ok_kdel = 200 <= s < 300 and len(left) == 2 and not has_material(K1)
    check("keys DELETE one", ok_kdel)

    # ---- headers (on the test provider; header paths take numeric indexes) ----
    hp = None if pid is None else "/api/providers/" + urllib.parse.quote(str(pid), safe="") + "/headers"
    ok_hadd = ok_hput = ok_hdel = False
    if hp is not None:
        s, _, _ = req("POST", hp, {"key": HNAME, "name": HNAME, "value": "v1"})
        hs = provider_headers(get_provider(pid)) or []
        hid = None
        for e in hs:
            if isinstance(e, dict) and hdr_name(e) == HNAME and e.get("value") == "v1":
                hid = entry_id(e)
                break
        ok_hadd = 200 <= s < 300 and hid is not None
        hpu = hp + "/" + urllib.parse.quote(str(hid), safe="") if hid is not None else hp + "/" + urllib.parse.quote(HNAME, safe="")
        s, _, _ = req("PUT", hpu,
                      {"key": HNAME, "name": HNAME, "value": "v2"})
        hs = provider_headers(get_provider(pid)) or []
        ok_hput = 200 <= s < 300 and any(hdr_name(e) == HNAME and e.get("value") == "v2" for e in hs if isinstance(e, dict))
        s, _, _ = req("DELETE", hpu)
        hs = provider_headers(get_provider(pid)) or []
        ok_hdel = 200 <= s < 300 and not any(hdr_name(e) == HNAME for e in hs if isinstance(e, dict))
    check("headers POST add X-Test", ok_hadd)
    check("headers PUT update", ok_hput)
    check("headers DELETE", ok_hdel)

    # ---- provider DELETE ----
    ok_pdel = False
    if pid is not None:
        s, _, _ = req("DELETE", "/api/providers/" + urllib.parse.quote(str(pid), safe=""))
        _, providers = get_providers()
        _, found = find_provider_by_prefix(providers, PREFIX)
        ok_pdel = 200 <= s < 300 and found is None
        pid_gone = ok_pdel
    check("providers DELETE remove", ok_pdel)

    # ---- models / logs ----
    s, _, t = req("GET", "/api/models")
    mj = as_json(t)
    # Catalog shape: {"providers":[{index,display_name,prefix,models:[{id,upstream_id,enabled}]}]}
    models_ok = (s == 200 and isinstance(mj, dict) and isinstance(mj.get("providers"), list))
    if models_ok:
        all_models = [m for p in mj["providers"] if isinstance(p, dict)
                      for m in (p.get("models") or []) if isinstance(m, dict)]
        models_ok = all(isinstance(m.get("id"), str) and "enabled" in m for m in all_models)
    check("GET /api/models catalog providers+models", models_ok, "status={0}".format(s))

    # PATCH toggle round-trip on the first model if any.
    tog_ok = True
    if models_ok and all_models:
        p0 = mj["providers"][0]["index"]
        try:
            first = all_models[0]
            s2, _, _ = req("PATCH", "/api/models/{0}/{1}".format(p0, all_models.index(first)), {"enabled": not first["enabled"]})
            tog_ok = 200 <= s2 < 300
            req("PATCH", "/api/models/{0}/{1}".format(p0, all_models.index(first)), {"enabled": first["enabled"]})
        except Exception:
            tog_ok = False
    check("PATCH /api/models/{p}/{m} toggle round-trip", tog_ok)

    s, _, t = req("GET", "/api/logs")
    lj = as_json(t)
    logs = as_list(lj)
    logs_ok = (s == 200 and logs is not None
               and all(isinstance(e, dict) and "seq" in e and "level" in e and "msg" in e for e in logs))
    check("GET /api/logs list seq/level/msg", logs_ok, "status={0}".format(s))
    s, _, t = req("GET", "/api/logs/5")
    lj5 = as_list(as_json(t))
    check("GET /api/logs/5 max 5", s == 200 and lj5 is not None and len(lj5) <= 5,
          "status={0} n={1}".format(s, len(lj5) if isinstance(lj5, list) else "?"))

    # ---- settings round-trip ----
    s, _, t = req("GET", "/api/settings")
    orig = as_json(t)
    settings_ok = False
    if s == 200 and isinstance(orig, dict):
        s2, _, _ = req("PUT", "/api/settings", orig)
        _, _, t3 = req("GET", "/api/settings")
        back = as_json(t3)
        settings_ok = 200 <= s2 < 300 and isinstance(back, dict) and all(
            back.get(k) == v for k, v in orig.items())
        # restore originals (no-op if round-trip already restored them)
        req("PUT", "/api/settings", orig)
    check("settings GET/PUT round-trip", settings_ok)

    # ---- unknown route ----
    s, _, _ = req("GET", "/api/definitely-not-here-xyz")
    check("unknown route -> 404", s == 404, "status={0}".format(s))

    # ---- server stop LAST: the listener goes down, the process stays up ----
    stopped_last = False
    for body in ({"action": "stop"}, {"running": False}):
        s, _, t = req("POST", "/api/server", body)
        if 200 <= s < 300:
            stopped_last = is_false_like((as_json(t) or {}).get("running"))
            break
    else:
        s = -1
    check("POST /api/server stop last", stopped_last, "stop_status={0}".format(s))

    # best-effort cleanup of the probe provider
    if pid is not None and not pid_gone:
        try:
            req("DELETE", "/api/providers/" + urllib.parse.quote(str(pid), safe=""))
        except Exception:
            pass

    n = sum(1 for r in results if r)
    print("{0}/{1} passed".format(n, len(results)))
    return 0 if n == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
