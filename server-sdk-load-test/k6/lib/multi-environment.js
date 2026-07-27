function requirePositiveInteger(value, name) {
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
}

function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value.trim();
}

export function parseMultiEnvironmentSecret(rawValue) {
  let document;
  try {
    document = JSON.parse(String(rawValue ?? ""));
  } catch (error) {
    throw new Error(`multi-environment secret is not valid JSON: ${error.message}`);
  }

  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("multi-environment secret must be a JSON object");
  }
  if (document.schemaVersion !== 1) {
    throw new Error("multi-environment secret schemaVersion must be 1");
  }

  const targetEnvironmentId = requireNonEmptyString(
    document.targetEnvironmentId,
    "targetEnvironmentId",
  );
  if (!Array.isArray(document.environments) || document.environments.length === 0) {
    throw new Error("multi-environment secret must contain environments");
  }

  const ids = new Set();
  const keys = new Set();
  const indexes = new Set();
  const environments = document.environments.map((candidate, offset) => {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      throw new Error(`environment ${offset + 1} must be an object`);
    }

    const index = Number(candidate.index);
    requirePositiveInteger(index, `environment ${offset + 1} index`);
    const id = requireNonEmptyString(candidate.id, `environment ${index} id`);
    const key = requireNonEmptyString(candidate.key, `environment ${index} key`);
    const serverSecret = requireNonEmptyString(
      candidate.serverSecret,
      `environment ${index} serverSecret`,
    );

    if (ids.has(id)) {
      throw new Error(`multi-environment secret contains duplicate environment id '${id}'`);
    }
    if (keys.has(key)) {
      throw new Error(`multi-environment secret contains duplicate environment key '${key}'`);
    }
    if (indexes.has(index)) {
      throw new Error(`multi-environment secret contains duplicate environment index ${index}`);
    }
    ids.add(id);
    keys.add(key);
    indexes.add(index);

    return { index, id, key, serverSecret };
  });

  environments.sort((left, right) => left.index - right.index);
  for (let offset = 0; offset < environments.length; offset += 1) {
    if (environments[offset].index !== offset + 1) {
      throw new Error(
        `multi-environment indexes must be contiguous from 1; expected ${offset + 1}`,
      );
    }
  }

  const targetMatches = environments.filter(
    (environment) => environment.id === targetEnvironmentId,
  );
  if (targetMatches.length !== 1) {
    throw new Error(
      `targetEnvironmentId must match exactly one environment; found ${targetMatches.length}`,
    );
  }

  return {
    schemaVersion: 1,
    experimentId: requireNonEmptyString(document.experimentId, "experimentId"),
    projectId: requireNonEmptyString(document.projectId, "projectId"),
    targetEnvironmentId,
    targetEnvironmentKey: targetMatches[0].key,
    environments,
  };
}

export function connectionsPerEnvironmentPerRunner(
  connectionsPerRunner,
  environmentCount,
) {
  requirePositiveInteger(connectionsPerRunner, "connectionsPerRunner");
  requirePositiveInteger(environmentCount, "environmentCount");
  if (connectionsPerRunner % environmentCount !== 0) {
    throw new Error(
      `connectionsPerRunner (${connectionsPerRunner}) must be divisible by ` +
        `environmentCount (${environmentCount})`,
    );
  }
  return connectionsPerRunner / environmentCount;
}

export function assignEnvironmentToConnection(
  localConnectionIndex,
  environments,
  connectionsPerRunner,
) {
  requirePositiveInteger(localConnectionIndex, "localConnectionIndex");
  if (!Array.isArray(environments) || environments.length === 0) {
    throw new Error("environments must be a non-empty array");
  }
  requirePositiveInteger(connectionsPerRunner, "connectionsPerRunner");
  if (localConnectionIndex > connectionsPerRunner) {
    throw new Error(
      `localConnectionIndex ${localConnectionIndex} exceeds ` +
        `connectionsPerRunner ${connectionsPerRunner}`,
    );
  }

  connectionsPerEnvironmentPerRunner(connectionsPerRunner, environments.length);
  return environments[(localConnectionIndex - 1) % environments.length];
}

export function validateMultiEnvironmentTopology({
  environmentCount,
  parallelism,
  connectionsPerRunner,
  connectionsPerEnvironmentPerRunner: expectedPerEnvironment,
  totalConnections,
}) {
  requirePositiveInteger(environmentCount, "environmentCount");
  requirePositiveInteger(parallelism, "parallelism");
  requirePositiveInteger(connectionsPerRunner, "connectionsPerRunner");
  requirePositiveInteger(expectedPerEnvironment, "connectionsPerEnvironmentPerRunner");
  requirePositiveInteger(totalConnections, "totalConnections");

  const actualPerEnvironment = connectionsPerEnvironmentPerRunner(
    connectionsPerRunner,
    environmentCount,
  );
  if (actualPerEnvironment !== expectedPerEnvironment) {
    throw new Error(
      `expected ${expectedPerEnvironment} connections per environment per runner, ` +
        `but topology produces ${actualPerEnvironment}`,
    );
  }
  if (connectionsPerRunner * parallelism !== totalConnections) {
    throw new Error(
      `connectionsPerRunner × parallelism must equal totalConnections ` +
        `(${connectionsPerRunner} × ${parallelism} != ${totalConnections})`,
    );
  }

  return {
    environmentCount,
    parallelism,
    connectionsPerRunner,
    connectionsPerEnvironmentPerRunner: actualPerEnvironment,
    connectionsPerEnvironment: actualPerEnvironment * parallelism,
    totalConnections,
  };
}
