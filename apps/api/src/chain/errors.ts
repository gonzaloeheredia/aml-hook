/**
 * Fail-closed when Anvil / deploy:local is missing.
 * The demo does not fall back to the TypeScript policy fork.
 */

export class ChainUnavailableError extends Error {
  readonly code = "deploy_local" as const;

  constructor(
    message = "Anvil stack is not reachable. Run `npm run deploy:local` and restart the API.",
  ) {
    super(message);
    this.name = "ChainUnavailableError";
  }
}

export function isChainUnavailable(err: unknown): err is ChainUnavailableError {
  return err instanceof ChainUnavailableError;
}
