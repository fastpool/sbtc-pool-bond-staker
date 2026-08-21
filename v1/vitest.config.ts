// Vitest for the archived v1 pool.
//
// The root config excludes `v1/`, so this is the only way its tests run:
//
//     pnpm run test:v1
//
// Two things differ from the root config, and both are about pointing the same
// machinery at the older snapshot. `include` collects only v1's tests, and
// `manifestPath` names v1's manifest -- the one where `bond-staker` is the
// pool *without* the early unstake.
//
// `root` stays at the repository root rather than moving to this directory:
// node_modules lives up there, and a worker rooted here cannot find vitest's
// own environment package.
import { resolve } from "node:path";
import { defineConfig } from "vitest/config";
import {
  vitestSetupFilePath,
  getClarinetVitestsArgv,
} from "@stacks/clarinet-sdk/vitest";

export default defineConfig({
  root: resolve(import.meta.dirname, ".."),
  test: {
    include: ["v1/tests/**/*.test.ts"],
    environment: "clarinet",
    pool: "forks",
    isolate: false,
    maxWorkers: 1,
    setupFiles: [vitestSetupFilePath],
    environmentOptions: {
      clarinet: {
        ...getClarinetVitestsArgv(),
        manifestPath: "./v1/Clarinet.toml",
      },
    },
  },
});
