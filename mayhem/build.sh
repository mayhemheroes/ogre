#!/usr/bin/env bash
#
# ogre/mayhem/build.sh — build OGRECave/ogre's OSS-Fuzz harnesses (image_fuzz, stream_fuzz,
# zip_fuzz, ogre_deep_fuzz) as sanitized libFuzzer targets (+ standalone reproducers), a
# behavioral KAT reproducer (mesh_kat, built with NORMAL flags, RUN by mayhem/test.sh), and
# links everything against a sanitized static OgreMain (+ Codec_STBI for image_fuzz).
#
# Fuzzed surface: OGRE is a 3D engine; these 4 harnesses attack RESOURCE/asset PARSERS —
#   image_fuzz      — Ogre::Image::load() via the STBI PNG codec (Ogre::STBIImageCodec)
#   stream_fuzz     — Ogre::StreamSerialiser chunk reader over a FileSystemArchive stream
#   zip_fuzz        — Ogre::EmbeddedZipArchiveFactory (in-memory .zip archive parsing)
#   ogre_deep_fuzz  — multiplexed: Mesh / Skeleton binary deserialization, ConfigFile parsing,
#                     and extended StreamSerialiser chunk reads (selector byte picks the target)
# Only OgreMain (+ the STBI image codec) is built — no samples, no RenderSystems (no GL/X11
# render backend is actually exercised by any harness; X11 is a required find_package on Linux
# but nothing here creates a window), no Bites/Overlay/bindings.
#
# Build contract from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile OgreMain ITSELF with $SANITIZER_FLAGS so the fuzzed parsers
# (not just the harness) are instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# None of the 4 harnesses touch RenderSystems/Overlay/Bites/Paging/Terrain/Volume/Property/
# RTShaderSystem/scene-manager plugins/bindings — disable them so the build stays scoped to
# what image_fuzz/stream_fuzz/zip_fuzz/ogre_deep_fuzz actually need (OgreMain + Codec_STBI),
# and so OGRE_BUILD_COMPONENT_OVERLAY=FALSE also skips Overlay's imgui file(DOWNLOAD) (§6.5:
# air-gapped re-run must not need the network).
DISABLE_UNUSED_COMPONENTS="\
  -DOGRE_BUILD_COMPONENT_OVERLAY=FALSE \
  -DOGRE_BUILD_COMPONENT_PAGING=FALSE \
  -DOGRE_BUILD_COMPONENT_MESHLODGENERATOR=FALSE \
  -DOGRE_BUILD_COMPONENT_TERRAIN=FALSE \
  -DOGRE_BUILD_COMPONENT_VOLUME=FALSE \
  -DOGRE_BUILD_COMPONENT_PROPERTY=FALSE \
  -DOGRE_BUILD_COMPONENT_RTSHADERSYSTEM=FALSE \
  -DOGRE_BUILD_PLUGIN_BSP=FALSE \
  -DOGRE_BUILD_PLUGIN_OCTREE=FALSE \
  -DOGRE_BUILD_PLUGIN_PFX=FALSE \
  -DOGRE_BUILD_PLUGIN_PCZ=FALSE \
  -DOGRE_BUILD_PLUGIN_DOT_SCENE=FALSE \
  -DOGRE_BUILD_PLUGIN_CG=FALSE \
  -DOGRE_BUILD_PLUGIN_GLSLANG=FALSE"

# ── 1) Sanitized fuzz build: OgreMain + Codec_STBI + the 4 libFuzzer harnesses ───────────────
# CMAKE_{C,CXX}_FLAGS thread SANITIZER_FLAGS + DEBUG_FLAGS (DWARF<=3) into every object OGRE
# itself compiles, so the fuzzed parser code is both instrumented AND triage-readable.
# -fsanitize=fuzzer-no-link adds SanitizerCoverage (no libFuzzer main/link) to every object this
# cmake invocation compiles -- OgreMain, Codec_STBI, AND the 4 harness .cpp TUs all share this
# global CMAKE_CXX_FLAGS (no per-target override in Tests/CMakeLists.txt) -- so the FUZZED
# PARSER CODE itself gets edge coverage, not just the thin harness wrapper. The final
# executable link still pulls in the real libFuzzer main via $LIB_FUZZING_ENGINE below.
# OGRE_STATIC=TRUE keeps everything as static libs we can re-link for the standalone reproducers.
FUZZ_BUILD="$SRC/mayhem-fuzz-build"
mkdir -p "$FUZZ_BUILD"
# -lz on CMAKE_EXE_LINKER_FLAGS: Codec_STBI's zlib usage is PRIVATE-linked (ZLIB::ZLIB) and CMake
# does not propagate that transitively to the image_fuzz executable's link line, leaving
# `compress`/`compressBound` undefined; adding -lz to every link is harmless for the other 3.
cmake -S "$SRC" -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS -lz" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DOGRE_STATIC=TRUE \
  -DOGRE_BUILD_FUZZERS=TRUE \
  -DOGRE_BUILD_DEPENDENCIES=FALSE \
  -DOGRE_BUILD_SAMPLES=FALSE \
  -DOGRE_BUILD_TESTS=FALSE \
  -DOGRE_BUILD_TOOLS=FALSE \
  -DOGRE_BUILD_COMPONENT_PYTHON=FALSE \
  -DOGRE_BUILD_COMPONENT_JAVA=FALSE \
  -DOGRE_BUILD_COMPONENT_CSHARP=FALSE \
  $DISABLE_UNUSED_COMPONENTS
LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" cmake --build "$FUZZ_BUILD" --target \
  image_fuzz stream_fuzz zip_fuzz ogre_deep_fuzz -j"$MAYHEM_JOBS"

for harness in image_fuzz stream_fuzz zip_fuzz ogre_deep_fuzz; do
  bin="$(find "$FUZZ_BUILD" -maxdepth 3 -type f -name "$harness" | head -1)"
  [ -n "$bin" ] || { echo "ERROR: $harness binary not found after build" >&2; exit 1; }
  install -m 0755 "$bin" "/mayhem/$harness"
done

# ── 2) Standalone (non-fuzzer) reproducers: relink each harness .cpp against
#       $STANDALONE_FUZZ_MAIN (compiled as a C object first) + the SAME sanitized static libs
#       ninja already built, instead of $LIB_FUZZING_ENGINE. -> /mayhem/<harness>-standalone ──
OGREMAIN_A="$(find "$FUZZ_BUILD" -maxdepth 4 -name 'libOgreMain*.a' | head -1)"
STBI_A="$(find "$FUZZ_BUILD" -maxdepth 4 -name 'libCodec_STBI*.a' | head -1)"
[ -n "$OGREMAIN_A" ] || { echo "ERROR: libOgreMain*.a not found" >&2; exit 1; }

INC_DIRS=(
  -I"$SRC/OgreMain/include"
  -I"$SRC/PlugIns/STBICodec/include"
  -I"$FUZZ_BUILD/include"
)
# X11/pthread/dl/m — OgreMain (static) needs these at final link on Linux. -lz — Codec_STBI's
# custom_zlib_compress() PRIVATE-links ZLIB::ZLIB, which CMake does not propagate transitively
# to executables that only depend on Codec_STBI's static archive; add it explicitly everywhere
# (harmless for harnesses that don't touch the STBI codec).
SYS_LIBS="-lX11 -lpthread -ldl -lm -lz"

standalone_main_o="$FUZZ_BUILD/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$standalone_main_o"

link_standalone() {
  local harness="$1"; shift
  local extra_libs=("$@")
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${INC_DIRS[@]}" -std=gnu++17 \
    "$HARNESS_DIR/$harness.cpp" "$standalone_main_o" \
    "${extra_libs[@]}" "$OGREMAIN_A" $SYS_LIBS \
    -o "/mayhem/$harness-standalone"
}

link_standalone image_fuzz "$STBI_A"
link_standalone stream_fuzz
link_standalone zip_fuzz
link_standalone ogre_deep_fuzz

echo "built 4 harnesses (+ standalones)"

# ── 3) Behavioral KAT reproducer: mesh_kat, built with the project's NORMAL (non-sanitized)
#       flags — a clean, independent build so it stays an honest PATCH oracle. RUN (not built)
#       by mayhem/test.sh against the fixed mayhem/kat/cube.mesh fixture. ───────────────────────
NORMAL_BUILD="$SRC/mayhem-normal-build"
mkdir -p "$NORMAL_BUILD"
env -u CFLAGS -u CXXFLAGS \
  cmake -S "$SRC" -B "$NORMAL_BUILD" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOGRE_STATIC=TRUE \
    -DOGRE_BUILD_FUZZERS=FALSE \
    -DOGRE_BUILD_DEPENDENCIES=FALSE \
    -DOGRE_BUILD_SAMPLES=FALSE \
    -DOGRE_BUILD_TESTS=FALSE \
    -DOGRE_BUILD_TOOLS=FALSE \
    -DOGRE_BUILD_COMPONENT_PYTHON=FALSE \
    -DOGRE_BUILD_COMPONENT_JAVA=FALSE \
    -DOGRE_BUILD_COMPONENT_CSHARP=FALSE \
    $DISABLE_UNUSED_COMPONENTS
cmake --build "$NORMAL_BUILD" --target OgreMain -j"$MAYHEM_JOBS"

NORMAL_OGREMAIN_A="$(find "$NORMAL_BUILD" -maxdepth 4 -name 'libOgreMain*.a' | head -1)"
[ -n "$NORMAL_OGREMAIN_A" ] || { echo "ERROR: normal-build libOgreMain*.a not found" >&2; exit 1; }

env -u CFLAGS -u CXXFLAGS $CXX -std=gnu++17 \
  -I"$SRC/OgreMain/include" -I"$NORMAL_BUILD/include" \
  "$SRC/mayhem/kat/mesh_kat.cpp" "$NORMAL_OGREMAIN_A" $SYS_LIBS \
  -o "$SRC/mayhem/kat/mesh_kat"

echo "build.sh complete:"
ls -la /mayhem/image_fuzz /mayhem/stream_fuzz /mayhem/zip_fuzz /mayhem/ogre_deep_fuzz \
       /mayhem/image_fuzz-standalone /mayhem/stream_fuzz-standalone \
       /mayhem/zip_fuzz-standalone /mayhem/ogre_deep_fuzz-standalone \
       "$SRC/mayhem/kat/mesh_kat" 2>&1 || true

# mayhem-dict-fix: place the dictionaries the Mayhemfiles reference (build.sh never did -> libFuzzer exited 1 on missing -dict -> 0 edges)
find "$SRC/mayhem" -name "*.dict" -exec cp {} /mayhem/ \; 2>/dev/null || true
