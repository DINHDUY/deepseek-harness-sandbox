// Container healthcheck: GET / on the address dsh actually bound.
//
// `dsh web --host` binds the container's own interface address (see
// container-ip.mjs), never a wildcard, so a loopback probe always gets
// ECONNREFUSED. This helper resolves the same address and probes it.
//
// Any HTTP response counts as healthy: without a launch token the server
// answers 401, which proves the listener is up and serving.
import http from "node:http";
import os from "node:os";

const port = Number(process.env.DSH_WEB_PORT || 8080);

const isUsable = (addr) => {
  if (!addr || addr === "0.0.0.0") return false;
  if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(addr)) return false;
  if (addr.startsWith("127.")) return false;
  const octets = addr.split(".").map(Number);
  if (octets.some((o) => o > 255)) return false;
  if (octets.every((o) => o === 255)) return false;
  return true;
};

let target;
for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
  if (name === "lo") continue;
  for (const a of addrs ?? []) {
    if ((a.family === "IPv4" || a.family === 4) && isUsable(a.address)) {
      target = a.address;
      break;
    }
  }
  if (target) break;
}

if (!target) {
  process.stderr.write("healthcheck: no usable non-loopback IPv4 interface found\n");
  process.exit(1);
}

const req = http.get(
  { host: target, port, path: "/", timeout: 4000 },
  (res) => {
    res.resume();
    process.exit(res.statusCode < 500 ? 0 : 1);
  },
);
req.on("timeout", () => {
  req.destroy(new Error("timeout"));
});
req.on("error", (err) => {
  process.stderr.write(`healthcheck: ${err.message}\n`);
  process.exit(1);
});
