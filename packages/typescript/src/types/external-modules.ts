declare module "fast-redact";

declare module "fs-extra" {
	export type SymlinkType = "dir" | "file" | "junction";

	const fs: any;
	export default fs;
}

declare module "markdown-it";
