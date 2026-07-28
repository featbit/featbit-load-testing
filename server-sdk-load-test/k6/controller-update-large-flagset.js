// Dedicated controller entry point for the 8 string + 2 JSON revision plan.
// Selection is by revision token, so JSON configuration bodies never enter
// controller logs or metric tags.
const variationType = String(__ENV.CONTROLLER_VARIATION_TYPE ?? "").trim();

if (variationType !== "string" && variationType !== "json") {
  throw new Error(
    "large-flagset controller requires CONTROLLER_VARIATION_TYPE=string|json",
  );
}

export { default, handleSummary } from "./controller-update.js";
