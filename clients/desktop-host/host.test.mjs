// node host.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
import { handle } from "./host.mjs";
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "azp-host-")), id = "0f8fad5b-d9cb-469f-a165-70867728950e", key = Buffer.alloc(32, 7).toString("base64");
assert.equal(handle({ op: "store", id, key }, { dir }).ok, true);
assert.equal((fs.statSync(path.join(dir, `${id}.key`)).mode & 0o777).toString(8), "600");
assert.deepEqual(handle({ op: "release", id }, { dir, approve: () => false }), { ok: false, error: "not approved" });
assert.deepEqual(handle({ op: "release", id }, { dir, approve: () => true }), { ok: true, key });
assert.equal(handle({ op: "release", id: "../../etc/passwd" }, { dir, approve: () => true }).ok, false);
assert.equal(handle({ op: "store", id, key: "x" }, { dir }).ok, false);
handle({ op: "forget", id }, { dir }); assert.equal(fs.existsSync(path.join(dir, `${id}.key`)), false);
fs.rmSync(dir, { recursive: true }); console.log("host ok");
