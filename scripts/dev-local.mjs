import { spawn } from "node:child_process";
const children = [
  spawn(process.execPath, ["scripts/local-server.mjs"], { stdio: "inherit" }),
  spawn(
    process.execPath,
    ["node_modules/vite/bin/vite.js", "--host", "127.0.0.1"],
    { stdio: "inherit" },
  ),
];
let closing = false;
function stop(code = 0) {
  if (closing) return;
  closing = true;
  for (const c of children) c.kill();
  process.exitCode = code;
}
for (const c of children) {
  c.on("error", () => stop(1));
  c.on("exit", (code) => stop(code || 0));
}
process.on("SIGINT", () => stop());
process.on("SIGTERM", () => stop());
