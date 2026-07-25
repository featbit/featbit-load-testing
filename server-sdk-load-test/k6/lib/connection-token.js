const NUMBER_MAP = Object.freeze({
  0: "Q",
  1: "B",
  2: "W",
  3: "S",
  4: "P",
  5: "H",
  6: "D",
  7: "X",
  8: "Z",
  9: "U",
});

function encodeNumber(number, length) {
  const value = String(number).padStart(length, "0").slice(-length);
  return [...value].map((digit) => NUMBER_MAP[digit]).join("");
}

// This is the same token envelope used by FeatBit's .NET Server SDK.
export function generateConnectionToken(envSecret, now = Date.now(), random = Math.random) {
  if (typeof envSecret !== "string" || envSecret.length === 0) {
    throw new Error("FEATBIT_SERVER_SECRET must not be empty");
  }

  const secret = envSecret.replace(/=+$/, "");
  if (secret.length < 2) {
    throw new Error("FEATBIT_SERVER_SECRET is not a valid FeatBit server secret");
  }

  const timestamp = Math.trunc(now);
  const timestampText = String(timestamp);
  const start = Math.max(Math.floor(random() * secret.length), 2);

  return [
    encodeNumber(start, 3),
    encodeNumber(timestampText.length, 2),
    secret.slice(0, start),
    encodeNumber(timestamp, timestampText.length),
    secret.slice(start),
  ].join("");
}

