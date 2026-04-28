import { describe, expect, it } from "vitest";
import {
	PACKAGED_WINDOWS_BOOTSTRAP_PARTITION,
	resolveMainWindowPartition,
} from "./main-window-session";

describe("resolveMainWindowPartition", () => {
	it("honors the MILADY partition override", () => {
		expect(
			resolveMainWindowPartition({
				MILADY_DESKTOP_TEST_PARTITION: "bootstrap-isolated",
			} as NodeJS.ProcessEnv),
		).toBe("persist:bootstrap-isolated");
	});

	it("still honors the legacy ELIZA partition override", () => {
		expect(
			resolveMainWindowPartition({
				ELIZA_DESKTOP_TEST_PARTITION: "persist:legacy-bootstrap",
			} as NodeJS.ProcessEnv),
		).toBe("persist:legacy-bootstrap");
	});

	it("uses the packaged bootstrap partition when MILADY test API base is set", () => {
		expect(
			resolveMainWindowPartition({
				MILADY_DESKTOP_TEST_API_BASE: "http://127.0.0.1:31337",
			} as NodeJS.ProcessEnv),
		).toBe(PACKAGED_WINDOWS_BOOTSTRAP_PARTITION);
	});
});
