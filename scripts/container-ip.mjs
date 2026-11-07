// Prints the container's own non-loopback IPv4 address.
//
// Replaces the old UDP connect() trick: with no default route (an --internal
// network, or a blackholed default) connect() "succeeds" and reports 0.0.0.0,
// which would be passed to `dsh web --host` as a wildcard bind. Reading the
// interface table has no such dependency and fails loudly instead.
import os from "node:os";

const isUsable = (addr) => {
  if (!addr || addr === "0.0.0.0") return false;
  if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(addr)) return false;
  if (addr.startsWith("127.")) return false;
  // Reject malformed octets (e.g. 999.1.1.1) and the all-ones broadcast address.
  const octets = addr.split(".").map(Number);
  if (octets.some((o) => o > 255)) return false;
  if (octets.every((o) => o === 255)) return false;
  return true;
};

const candidates = [];
for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
  if (name === "lo") continue;
  for (const a of addrs ?? []) {
    if (a.family !== "IPv4" && a.family !== 4) continue;
    if (isUsable(a.address)) candidates.push(a.address);
  }
}

if (candidates.length === 0) {
  process.stderr.write("container-ip: no usable non-loopback IPv4 interface found\n");
  process.exit(1);
}

// Containers are single-homed here, so there is exactly one candidate. If more
// than one ever appears, take the first in interface order (deterministic).
process.stdout.write(candidates[0] + "\n");
