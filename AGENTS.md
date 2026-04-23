# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Requirements

- Zig 0.16.0 or greater

## Commands

```bash
# Build the library
zig build

# Run tests (requires Dagger CLI)
dagger run zig build test
```

## Architecture

This is a Zig SDK for [Dagger](https://dagger.io), a programmable CI/CD engine. The library connects to a running Dagger engine session and sends GraphQL queries over HTTP.

**Entry point:** `src/lib.zig` — re-exports the public API and collects tests.

**Module layout:**
- `src/core/graphql.zig` — re-exports `graphql.Client`
- `src/core/graphql/Client.zig` — HTTP GraphQL client; connects to `127.0.0.1:<port>/query` using Basic Auth with `DAGGER_SESSION_TOKEN`
- `src/core/graphql/QueryBuilder.zig` — (in progress) will build GraphQL query strings
- `src/core/EngineConn.zig` — (in progress) wraps `GraphQLClient`, reads `DAGGER_SESSION_TOKEN` and `DAGGER_SESSION_PORT` from the environment

**Integration test pattern:** `Client.zig` tests require a live Dagger session. `dagger run` injects `DAGGER_SESSION_TOKEN` and `DAGGER_SESSION_PORT` into the environment automatically.

**`dagger/` directory:** a clone of the upstream Dagger repo used as reference; it is not a build dependency.
