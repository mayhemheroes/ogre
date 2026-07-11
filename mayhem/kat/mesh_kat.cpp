/*
 * mayhem/kat/mesh_kat.cpp — a small, standalone Known-Answer-Test (KAT) program for OGRE's
 * MeshSerializer, built with the project's NORMAL flags (not the sanitized fuzz flags).
 *
 * This is the behavioral oracle mayhem/test.sh runs: feed it a FIXED, valid .mesh file
 * (mayhem/kat/cube.mesh, OGRE's own Samples/Media/models/cube.mesh) and it prints the parsed
 * submesh count and total vertex count it computed. test.sh greps the exact expected numbers.
 * A no-op / exit(0) neuter of the mesh-parsing code path (the sabotage check LD_PRELOADs a
 * shim that _exit(0)s this binary before it prints) makes the expected line disappear ->
 * test.sh FAILs, proving the oracle is behavioral, not just "did it exit 0".
 *
 * Mirrors the singleton init sequence used by Tests/fuzz/ogre_deep_fuzz.cpp's fuzz_mesh().
 */
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>

#include "OgreDataStream.h"
#include "OgreDefaultHardwareBufferManager.h"
#include "OgreLodStrategyManager.h"
#include "OgreLogManager.h"
#include "OgreMaterialManager.h"
#include "OgreMesh.h"
#include "OgreMeshManager.h"
#include "OgreMeshSerializer.h"
#include "OgreResourceGroupManager.h"
#include "OgreSkeletonManager.h"
#include "OgreSubMesh.h"

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <mesh-file>\n", argv[0]);
    return 2;
  }

  Ogre::LogManager *logMgr = new Ogre::LogManager();
  logMgr->createLog("mesh_kat.log", true, false, true);
  logMgr->setMinLogLevel(Ogre::LML_CRITICAL);

  new Ogre::ResourceGroupManager();
  new Ogre::LodStrategyManager();
  new Ogre::DefaultHardwareBufferManager();
  new Ogre::MeshManager();
  new Ogre::SkeletonManager();
  Ogre::MaterialManager *matMgr = new Ogre::MaterialManager();
  matMgr->initialise();

  std::ifstream ifs(argv[1], std::ios::binary);
  if (!ifs) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  std::vector<char> buf((std::istreambuf_iterator<char>(ifs)),
                         std::istreambuf_iterator<char>());

  Ogre::MeshPtr mesh =
      Ogre::MeshManager::getSingleton().create("kat.mesh", "General", true);

  Ogre::DataStreamPtr stream(new Ogre::MemoryDataStream(
      buf.data(), buf.size(), false /* freeOnClose */, true /* readOnly copies */));

  Ogre::MeshSerializer serializer;
  serializer.importMesh(stream, mesh.get());

  size_t numSub = mesh->getNumSubMeshes();
  size_t totalVerts = 0;
  if (mesh->sharedVertexData)
    totalVerts += mesh->sharedVertexData->vertexCount;
  for (size_t i = 0; i < numSub; ++i) {
    Ogre::SubMesh *sm = mesh->getSubMesh(i);
    if (sm->vertexData)
      totalVerts += sm->vertexData->vertexCount;
    else if (mesh->sharedVertexData == nullptr && sm->useSharedVertices)
      /* no shared data and submesh doesn't own its own -- nothing to add */;
  }

  printf("KAT-MESH submeshes=%zu vertices=%zu\n", numSub, totalVerts);
  return 0;
}
