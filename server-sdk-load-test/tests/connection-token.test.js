import assert from "node:assert/strict";
import test from "node:test";

import { generateConnectionToken } from "../k6/lib/connection-token.js";

const REVERSE_NUMBER_MAP = Object.freeze({
  Q: "0",
  B: "1",
  W: "2",
  S: "3",
  P: "4",
  H: "5",
  D: "6",
  X: "7",
  Z: "8",
  U: "9",
});

function decodeNumber(value) {
  return Number([...value].map((character) => REVERSE_NUMBER_MAP[character]).join(""));
}

function decodeToken(token) {
  const secretSplitIndex = decodeNumber(token.slice(0, 3));
  const timestampLength = decodeNumber(token.slice(3, 5));
  const prefixStart = 5;
  const timestampStart = prefixStart + secretSplitIndex;
  const suffixStart = timestampStart + timestampLength;

  return {
    timestamp: decodeNumber(token.slice(timestampStart, suffixStart)),
    secret: token.slice(prefixStart, timestampStart) + token.slice(suffixStart),
  };
}

test("generates the token envelope used by the .NET Server SDK", () => {
  const token = generateConnectionToken("server-secret==", 1_700_000_000_123, () => 0.5);

  assert.deepEqual(decodeToken(token), {
    timestamp: 1_700_000_000_123,
    secret: "server-secret",
  });
});

test("rejects an empty secret", () => {
  assert.throws(() => generateConnectionToken(""), /must not be empty/);
});

