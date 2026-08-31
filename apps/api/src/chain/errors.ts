/**
 * Fail-closed when the configured chain RPC or hook is missing.
 * The demo does not fall back to the TypeScript policy fork.
 */

export class ChainUnavailableError extends Error {
  readonly code = "deploy_local" as const;

  constructor(message = "Chain is not reachable.") {
    super(message);
    this.name = "ChainUnavailableError";
  }
}

export function isChainUnavailable(err: unknown): err is ChainUnavailableError {
  return err instanceof ChainUnavailableError;
}
