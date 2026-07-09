#!/bin/bash
# setup_space_saver_profiles.sh
#
# Creates the penalty custom formats that make the "space saver" quality
# profiles work, and wires their scores into the profiles that recyclarr
# creates. Run AFTER the first `docker exec recyclarr recyclarr sync`.
#
# What it does (idempotent — safe to re-run):
#   Radarr:  CF "Remux Penalty"  (quality modifier = REMUX)      -> -10000 in
#            "UHD Bluray + WEB" and "HD Bluray + WEB"
#   Sonarr:  CF "Remux Penalty"  (release title matches /remux/) -> -10000 in
#            "WEB-1080p" and "WEB-2160p"
#            CF "2160p Penalty"  (resolution = 2160p)            -> -10000 in
#            "WEB-1080p" only
#   Both:    CF "Foreign Dub Penalty" (title matches /XxxDub/)   -> -10000 in
#            every space-saver profile
#
# Why: Radarr/Sonarr only replace a file when a new release scores HIGHER.
# The profiles group remux/2160p qualities together with encodes, and these
# penalties push existing bloated files far below any decent encode, so the
# smaller release wins and the old file is deleted on import.
#
# Recyclarr is configured with reset_unmatched_scores.except for these CF
# names, so daily syncs won't zero the scores back out.
#
# Requires: bash, curl, python3. Runs from anywhere that can reach the APIs
# (NAS or Mac). API keys are read from the .env next to this script's parent
# dir, or from MCP_RADARR_API_KEY / MCP_SONARR_API_KEY in the environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"

if [[ -z "${MCP_RADARR_API_KEY:-}" || -z "${MCP_SONARR_API_KEY:-}" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        MCP_RADARR_API_KEY=$(grep -E '^MCP_RADARR_API_KEY=' "$ENV_FILE" | cut -d= -f2)
        MCP_SONARR_API_KEY=$(grep -E '^MCP_SONARR_API_KEY=' "$ENV_FILE" | cut -d= -f2)
    fi
fi

if [[ -z "${MCP_RADARR_API_KEY:-}" || -z "${MCP_SONARR_API_KEY:-}" ]]; then
    echo "ERROR: could not determine API keys (checked $ENV_FILE)" >&2
    exit 1
fi

# URLs: environment wins, then .env, then localhost
if [[ -z "${RADARR_URL:-}" && -f "$ENV_FILE" ]]; then
    RADARR_URL=$(grep -E '^RADARR_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi
if [[ -z "${SONARR_URL:-}" && -f "$ENV_FILE" ]]; then
    SONARR_URL=$(grep -E '^SONARR_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi

RADARR_URL="${RADARR_URL:-http://localhost:7878}" \
SONARR_URL="${SONARR_URL:-http://localhost:8989}" \
RADARR_KEY="$MCP_RADARR_API_KEY" \
SONARR_KEY="$MCP_SONARR_API_KEY" \
python3 <<'PYEOF'
import gzip, json, os, sys, urllib.request

# Remux: soft penalty — combined with min_format_score -2000 (recyclarr.yml)
# a remux stays grabbable as a LAST RESORT (new adds where only a BD remux
# exists) but always loses to any encode (score >= 0) and is upgraded away
# once one appears. 2160p: hard penalty (below the -2000 floor) so 4K can
# never enter a 1080p profile at all.
REMUX_PENALTY = -1000
HARD_PENALTY = -10000

# Foreign dubs: a language-prefixed "dub" tag (HebDub, GerDub, HunDub...).
# TRaSH's "Dubs Only" misses these — its \bdub\b needs a word boundary that
# "HebDub" doesn't have. The 2-4 letter prefix is required on purpose: it
# skips a bare "DUBBED" tag, which on anime means the wanted English dub.
DUB_REGEX = r"\b(?!dual|multi)[a-z]{2,4}[ ._-]?dub(bed)?\b"

DUB_SPEC = [{
    "name": "Language-prefixed dub in title",
    "implementation": "ReleaseTitleSpecification",
    "negate": False, "required": True,
    "fields": [{"name": "value", "value": DUB_REGEX}],
}]

def api(base, key, path, method="GET", body=None):
    # Ask for gzip: some list endpoints (qualityprofile) are slow enough
    # uncompressed on the NAS that they trip the timeout.
    req = urllib.request.Request(f"{base}/api/v3/{path}", method=method,
        headers={"X-Api-Key": key, "Content-Type": "application/json",
                 "Accept-Encoding": "gzip"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=120) as r:
        text = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            text = gzip.decompress(text)
        return json.loads(text) if text else None

def find_schema_spec(schema, implementation):
    for spec in schema:
        if spec["implementation"] == implementation:
            return spec
    sys.exit(f"ERROR: {implementation} not found in customformat schema")

def select_value(spec, label_contains):
    for opt in spec["fields"][0]["selectOptions"]:
        if label_contains.lower() in opt["name"].lower():
            return opt["value"]
    sys.exit(f"ERROR: no select option matching {label_contains!r} in {spec['implementation']}")

def ensure_cf(base, key, name, specifications):
    existing = api(base, key, "customformat")
    for cf in existing:
        if cf["name"] == name:
            print(f"  CF {name!r} already exists (id={cf['id']})")
            return cf["id"]
    cf = api(base, key, "customformat", "POST", {
        "name": name,
        "includeCustomFormatWhenRenaming": False,
        "specifications": specifications,
    })
    print(f"  CF {name!r} created (id={cf['id']})")
    return cf["id"]

def set_profile_scores(base, key, profile_name, cf_scores):
    profiles = api(base, key, "qualityprofile")
    prof = next((p for p in profiles if p["name"] == profile_name), None)
    if prof is None:
        sys.exit(f"ERROR: profile {profile_name!r} not found — run 'recyclarr sync' first")
    changed = False
    found_ids = set()
    for item in prof.get("formatItems", []):
        if item["format"] in cf_scores:
            found_ids.add(item["format"])
            if item["score"] != cf_scores[item["format"]]:
                item["score"] = cf_scores[item["format"]]
                changed = True
    missing = set(cf_scores) - found_ids
    if missing:
        sys.exit(f"ERROR: profile {profile_name!r} formatItems missing CF ids {missing}")
    if changed:
        api(base, key, f"qualityprofile/{prof['id']}", "PUT", prof)
        print(f"  profile {profile_name!r}: penalty scores set")
    else:
        print(f"  profile {profile_name!r}: scores already correct")

# ── Radarr ──
rbase, rkey = os.environ["RADARR_URL"], os.environ["RADARR_KEY"]
print(f"Radarr @ {rbase}")
schema = api(rbase, rkey, "customformat/schema")
mod_spec = find_schema_spec(schema, "QualityModifierSpecification")
remux_val = select_value(mod_spec, "remux")
radarr_remux_id = ensure_cf(rbase, rkey, "Remux Penalty", [{
    "name": "Remux",
    "implementation": "QualityModifierSpecification",
    "negate": False, "required": True,
    "fields": [{"name": "value", "value": remux_val}],
}])
radarr_dub_id = ensure_cf(rbase, rkey, "Foreign Dub Penalty", DUB_SPEC)
set_profile_scores(rbase, rkey, "UHD Bluray + WEB",
                   {radarr_remux_id: REMUX_PENALTY, radarr_dub_id: HARD_PENALTY})
set_profile_scores(rbase, rkey, "HD Bluray + WEB",
                   {radarr_remux_id: REMUX_PENALTY, radarr_dub_id: HARD_PENALTY})

# ── Sonarr ──
sbase, skey = os.environ["SONARR_URL"], os.environ["SONARR_KEY"]
print(f"Sonarr @ {sbase}")
schema = api(sbase, skey, "customformat/schema")
res_spec = find_schema_spec(schema, "ResolutionSpecification")
r2160_val = select_value(res_spec, "2160")
sonarr_remux_id = ensure_cf(sbase, skey, "Remux Penalty", [{
    "name": "Remux in title",
    "implementation": "ReleaseTitleSpecification",
    "negate": False, "required": True,
    "fields": [{"name": "value", "value": r"\bremux\b"}],
}])
sonarr_2160_id = ensure_cf(sbase, skey, "2160p Penalty", [{
    "name": "2160p",
    "implementation": "ResolutionSpecification",
    "negate": False, "required": True,
    "fields": [{"name": "value", "value": r2160_val}],
}])
sonarr_dub_id = ensure_cf(sbase, skey, "Foreign Dub Penalty", DUB_SPEC)
set_profile_scores(sbase, skey, "WEB-1080p",
                   {sonarr_remux_id: REMUX_PENALTY, sonarr_2160_id: HARD_PENALTY,
                    sonarr_dub_id: HARD_PENALTY})
set_profile_scores(sbase, skey, "WEB-2160p",
                   {sonarr_remux_id: REMUX_PENALTY, sonarr_dub_id: HARD_PENALTY})

print("Done.")
PYEOF
