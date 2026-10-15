// beforeBuildCommand: the frontend is a single static page, copied to dist/.
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
mkdirSync(join(root, "dist"), { recursive: true });
copyFileSync(join(root, "index.html"), join(root, "dist", "index.html"));
console.log("frontend: dist/index.html");
