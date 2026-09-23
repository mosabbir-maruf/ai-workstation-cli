#!/usr/bin/env bash
# Shared helper: print space-separated 0.0.0.0 listen ports (sorted) from the
# workstation container, excluding the harness ports. Prints nothing and
# exits 0 when the workstation is stopped or nothing is detected.
set -euo pipefail

docker ps --format '{{.Names}}' 2>/dev/null |
    grep -qx ai-workstation || exit 0

docker exec ai-workstation node -e '
    const fs = require("fs");

    const files = ["/proc/net/tcp", "/proc/net/tcp6"];
    const ports = new Set();

    for (const file of files) {
        let content;

        try {
            content = fs.readFileSync(file, "utf8");
        } catch {
            continue;
        }

        for (const line of content.trim().split("\n").slice(1)) {
            const fields = line.trim().split(/\s+/);

            if (fields.length < 4)
                continue;

            // 0A = LISTEN
            if (fields[3] !== "0A")
                continue;

            const parts = fields[1].split(":");

            if (parts.length !== 2)
                continue;

            const address = parts[0];
            const allInterfaces =
                address === "00000000" ||
                address === "00000000000000000000000000000000";

            if (!allInterfaces)
                continue;

            const port = parseInt(parts[1], 16);

            if (port < 1024 || port > 65535)
                continue;

            if (port === 4090 || port === 4091)
                continue;

            ports.add(port);
        }
    }

    process.stdout.write(
        [...ports].sort((a, b) => a - b).join(" ")
    );
' 2>/dev/null || true
