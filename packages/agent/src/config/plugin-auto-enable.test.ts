import { describe, expect, it } from "vitest";

import { applyPluginAutoEnable } from "./plugin-auto-enable.js";

describe("applyPluginAutoEnable ollama env guard", () => {
  it("does not auto-enable ollama from OLLAMA_BASE_URL alone", () => {
    const { config, changes } = applyPluginAutoEnable({
      config: {},
      env: {
        OLLAMA_BASE_URL: "http://127.0.0.1:11434",
      } as NodeJS.ProcessEnv,
    });

    expect(config.plugins?.allow ?? []).not.toContain("@elizaos/plugin-ollama");
    expect(changes.some((entry) => entry.includes("plugin-ollama"))).toBe(
      false,
    );
  });

  it("auto-enables ollama when explicitly enabled in plugin entries", () => {
    const { config } = applyPluginAutoEnable({
      config: {
        plugins: {
          entries: {
            ollama: { enabled: true },
          },
        },
      },
      env: {
        OLLAMA_BASE_URL: "http://127.0.0.1:11434",
      } as NodeJS.ProcessEnv,
    });

    expect(config.plugins?.allow ?? []).toContain("@elizaos/plugin-ollama");
  });

  it("supports explicit env opt-in for ollama auto-enable", () => {
    const { config } = applyPluginAutoEnable({
      config: {},
      env: {
        OLLAMA_BASE_URL: "http://127.0.0.1:11434",
        ELIZA_AUTO_ENABLE_OLLAMA: "1",
      } as NodeJS.ProcessEnv,
    });

    expect(config.plugins?.allow ?? []).toContain("@elizaos/plugin-ollama");
  });
});
