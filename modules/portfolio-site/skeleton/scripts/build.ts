// Copies src/**/*.html to dist/ and compiles Tailwind to dist/styles.css.
// Fails when nothing was built, so a deploy never syncs an empty directory.
import { cp, mkdir, rm } from "node:fs/promises";
import { Glob } from "bun";

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });

const pages = [...new Glob("**/*.html").scanSync("src")];
if (pages.length === 0) {
  throw new Error("no HTML pages found under src/");
}
for (const page of pages) {
  await cp(`src/${page}`, `dist/${page}`);
}

const css = Bun.spawnSync(
  ["bunx", "@tailwindcss/cli", "-i", "src/input.css", "-o", "dist/styles.css", "--minify"],
  { stdout: "inherit", stderr: "inherit" },
);
if (css.exitCode !== 0) {
  throw new Error(`tailwind exited ${css.exitCode}`);
}
if (!(await Bun.file("dist/styles.css").exists()) || Bun.file("dist/styles.css").size === 0) {
  throw new Error("dist/styles.css is missing or empty");
}
console.log(`built ${pages.length} page(s) and dist/styles.css`);
