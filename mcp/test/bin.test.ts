import { expect, test } from "bun:test";
import os from "node:os";
import path from "node:path";
import { resolveBin } from "../src/lib";

test("APPLE_TASKS_BIN wins over the installed copy", () => {
  expect(resolveBin({ APPLE_TASKS_BIN: "/tmp/fake" }, () => true)).toBe("/tmp/fake");
});

test("an installed binary is the default", () => {
  const bin = resolveBin({}, (candidate) => candidate === path.join(os.homedir(), ".local/bin/apple-tasks"));
  expect(bin).toBe(path.join(os.homedir(), ".local/bin/apple-tasks"));
});

test("the build product is the fallback", () => {
  expect(resolveBin({}, () => false)).toContain("cli/.build/release/apple-tasks");
});
