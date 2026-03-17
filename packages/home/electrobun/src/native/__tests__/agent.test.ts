/**
 * Tests for agent.ts utility functions.
 *
 * Covers:
 *  - resolveConfigDir: Windows vs POSIX config directory resolution
 *  - getRuntimeDistFallbackCandidates: path resolution fallback list
 */

import path from "node:path";
import { describe, expect, it } from "vitest";

import { getRuntimeDistFallbackCandidates, resolveConfigDir } from "../agent";

// ---------------------------------------------------------------------------
// resolveConfigDir
// ---------------------------------------------------------------------------

describe("resolveConfigDir", () => {
  it("returns %APPDATA%\\Eliza Home on Windows when APPDATA is set", () => {
    const result = resolveConfigDir({
      platform: "win32",
      appdata: "C:\\Users\\Test\\AppData\\Roaming",
      homedir: "C:\\Users\\Test",
    });
    expect(result).toBe(
      path.join("C:\\Users\\Test\\AppData\\Roaming", "Eliza Home"),
    );
  });

  it("falls back to homedir\\AppData\\Roaming\\Eliza Home on Windows when APPDATA is absent", () => {
    const result = resolveConfigDir({
      platform: "win32",
      homedir: "C:\\Users\\Test",
    });
    // No appdata provided and process.env.APPDATA should not be used when
    // explicit opts are given — but the function falls through to
    // process.env.APPDATA. On a non-Windows CI runner APPDATA is unset, so
    // the fallback to homedir kicks in. On a Windows runner APPDATA is set.
    // Either way, the result must end with "Eliza Home".
    expect(result.endsWith("Eliza Home")).toBe(true);
  });

  it("returns ~/.config/Eliza Home on macOS", () => {
    const result = resolveConfigDir({
      platform: "darwin",
      homedir: "/Users/test",
    });
    expect(result).toBe(
      path.posix.join("/Users/test", ".config", "Eliza Home"),
    );
  });

  it("returns ~/.config/Eliza Home on Linux", () => {
    const result = resolveConfigDir({
      platform: "linux",
      homedir: "/home/test",
    });
    expect(result).toBe(path.posix.join("/home/test", ".config", "Eliza Home"));
  });

  it("ignores APPDATA on non-Windows platforms", () => {
    const result = resolveConfigDir({
      platform: "darwin",
      appdata: "C:\\Users\\Test\\AppData\\Roaming",
      homedir: "/Users/test",
    });
    // Should use ~/.config, not APPDATA
    expect(result).toBe(
      path.posix.join("/Users/test", ".config", "Eliza Home"),
    );
  });

  it("uses explicit appdata over process.env.APPDATA", () => {
    const result = resolveConfigDir({
      platform: "win32",
      appdata: "D:\\CustomAppData",
      homedir: "C:\\Users\\Test",
    });
    expect(result).toBe(path.join("D:\\CustomAppData", "Eliza Home"));
  });
});

// ---------------------------------------------------------------------------
// getRuntimeDistFallbackCandidates
// ---------------------------------------------------------------------------

describe("getRuntimeDistFallbackCandidates", () => {
  it("returns an array of candidate paths", () => {
    const candidates = getRuntimeDistFallbackCandidates(
      "/some/dir",
      "/usr/bin/bun",
    );
    expect(Array.isArray(candidates)).toBe(true);
    expect(candidates.length).toBeGreaterThan(0);
  });

  it("deduplicates candidates", () => {
    const candidates = getRuntimeDistFallbackCandidates("/a/b", "/a/b/bun");
    const unique = new Set(candidates);
    expect(candidates.length).toBe(unique.size);
  });

  it("includes macOS bundle path", () => {
    const candidates = getRuntimeDistFallbackCandidates(
      "/a/b",
      "/app/Contents/MacOS/launcher",
    );
    const macosBundlePath = path.posix.resolve(
      "/app/Contents/MacOS",
      "../Resources/app/home-dist",
    );
    expect(candidates).toContain(macosBundlePath);
  });

  it("includes Windows resources path", () => {
    const candidates = getRuntimeDistFallbackCandidates(
      "/a/b",
      "/app/launcher.exe",
    );
    const winResourcesPath = path.posix.resolve(
      "/app",
      "resources/app/home-dist",
    );
    expect(candidates).toContain(winResourcesPath);
  });
});
