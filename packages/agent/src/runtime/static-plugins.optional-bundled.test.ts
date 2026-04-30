import { describe, expect, it } from "vitest";
import { STATIC_ELIZA_PLUGINS } from "./plugin-types.js";

describe("static bundled plugins", () => {
  it("does not statically register optional plugin-pdf", async () => {
    await import("./eliza.js");

    expect(STATIC_ELIZA_PLUGINS["@elizaos/plugin-sql"]).toBeDefined();
    expect(STATIC_ELIZA_PLUGINS["@elizaos/plugin-pdf"]).toBeUndefined();
  });
});
