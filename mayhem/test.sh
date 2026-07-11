#!/usr/bin/env bash
#
# ogre/mayhem/test.sh — RUN the behavioral KAT built by mayhem/build.sh (mesh_kat, built with
# OGRE's NORMAL flags) against a FIXED known-good .mesh fixture and assert the EXACT parsed
# values, emitting a CTRF summary. exit 0 iff the assertion passed.
#
# PATCH-grade oracle: mesh_kat links OgreMain (normal build) and calls
# Ogre::MeshSerializer::importMesh() on OGRE's own Samples/Media/models/cube.mesh, then prints
# the submesh count and total vertex count it computed. Those are KNOWN, FIXED values for this
# fixture (1 submesh / 24 vertices — see below); the assertion is a byte-exact string match on
# mesh_kat's stdout, not "did the program exit 0 / not crash". A no-op ("exit(0)") patch to the
# mesh-parsing code path — or any patch that silently changes what gets parsed — makes the
# expected line disappear and this script FAILs. This script only RUNS the pre-built binary; it
# never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

KAT_BIN="$SRC/mayhem/kat/mesh_kat"
FIXTURE="$SRC/mayhem/kat/cube.mesh"
EXPECTED='KAT-MESH submeshes=1 vertices=24'

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$KAT_BIN" ]; then
  echo "missing $KAT_BIN — run mayhem/build.sh first" >&2
  emit_ctrf "ogre-mesh-kat" 0 1 0; exit 2
fi
if [ ! -f "$FIXTURE" ]; then
  echo "missing fixture $FIXTURE" >&2
  emit_ctrf "ogre-mesh-kat" 0 1 0; exit 2
fi

echo "=== running $KAT_BIN $FIXTURE ==="
out="$("$KAT_BIN" "$FIXTURE" 2>&1)"; rc=$?
echo "$out"

if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$EXPECTED"; then
  echo "oracle assertion PASSED: found '$EXPECTED'"
  emit_ctrf "ogre-mesh-kat" 1 0 0
  exit 0
else
  echo "oracle assertion FAILED: expected '$EXPECTED', got (rc=$rc):" >&2
  printf '%s\n' "$out" >&2
  emit_ctrf "ogre-mesh-kat" 0 1 0
  exit 1
fi
