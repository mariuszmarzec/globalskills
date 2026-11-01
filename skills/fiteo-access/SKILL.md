---
name: fiteo-access
description: Use whenever an agent needs to connect to a running Fiteo backend, determine its runtime base URL, use the Manul account, or make authenticated Fiteo HTTP requests. Runtime settings come from environment variables; never hardcode or disclose their values.
license: MIT
---

# Fiteo Access

Use this skill when connecting to a Fiteo backend instance. This skill describes
runtime connection configuration; it does not replace the API-contract
documentation in the `fiteo-backend-api` skill.

## Runtime configuration

Read only the settings required by the selected Fiteo integration from the
current process environment when a request is about to be made:

- `FITEO_BASE_URL` — base URL of the Fiteo backend.
- `FITEO_PAT` — operator PAT for the global/interactive `aicode` Fiteo MCP.
- `FITEO_MANUL_PAT` — dedicated PAT for standalone Manul's remote Todo source
  and task-scoped Fiteo MCP. Never substitute `FITEO_PAT` when this variable
  is missing.
- `FITEO_MANUL_SHARE_USER_ID` — non-secret numeric Fiteo user ID that receives
  shares on tasks and report subtasks created by Manul.
- `FITEO_MANUL_USERNAME` / `FITEO_MANUL_PASSWORD` — username/password for
  endpoints whose documented authentication flow explicitly requires them.

Values are provided by the local runtime and may change. Always use the current
environment values at execution time. Do not cache them between independent
runs or copy credentials into source code, scripts, skill files, documentation,
temporary files, commits, issue/PR comments, or chat messages. The numeric
share-recipient ID is configuration, not a credential.

## Never disclose configuration values

- Do not inspect the values for debugging or display them in output.
- Never run `env`, `printenv`, `set`, or `declare -p` to dump the environment.
- Do not use `echo`, `printf`, debug logging, verbose HTTP tracing, or exception
  messages to print any configured values or authentication headers.
- When checking configuration, report only which variable names are missing or
  empty. Do not include any current or example values.
- Pass current environment variables directly to the HTTP client's
  configuration/authentication mechanism without exposing the values to the
  model or command output. Avoid placing credentials in process arguments,
  shell history, logs, or generated scripts; prefer an in-process HTTP client
  or a mechanism that passes credentials without displaying them.
- Do not ask the user to paste credentials into chat. If configuration is
  missing, ask them to define the named variables locally.

## Configuration validation and startup

Before making a request, validate only the variables required by the
selected integration's documented authentication flow. Global/interactive
PAT-based requests require `FITEO_BASE_URL` and `FITEO_PAT`; standalone Manul
remote Todo requests require `FITEO_BASE_URL` and `FITEO_MANUL_PAT`. Do not
use one PAT as a fallback for the other. Username/password-based requests
require those credentials only when the endpoint contract specifies that flow.
Task creation also requires a valid numeric `FITEO_MANUL_SHARE_USER_ID` when
Manul is configured to share created tasks.

If a required variable is missing, tell the user exactly which variable names
need to be configured in their local `~/.zshrc` or runtime environment. Do not
guess the host or credentials and do not search unrelated files for
replacements. If variables are configured in `~/.zshrc` but are not present
in the agent's process environment, explain that the shell or long-running
Manul / OpenCode process may need to be reloaded or restarted to inherit them.

## Making requests

- Use `FITEO_BASE_URL` as the runtime base URL; do not hardcode an actual
  Fiteo host in code or scripts.
- Use `FITEO_PAT` only for the global/interactive `aicode` Fiteo connection.
- Use `FITEO_MANUL_PAT` only for standalone Manul remote Todo operations and
  task-scoped Fiteo MCP calls; fail closed when it is missing instead of
  falling back to `FITEO_PAT`.
- Use the Manul username/password only through the authentication flow
  documented for an endpoint that explicitly requires that flow. Do not
  assume an authentication scheme if the indexed documentation or current
  implementation does not establish it.
- For endpoint paths, HTTP methods, payloads, authentication flow, and response
  contracts, follow `fiteo-backend-api` and search the indexed Fiteo API
  documentation through the `caracal-rag` MCP server before answering or
  implementing endpoint-dependent work.
- Keep scripts reusable: reference the environment variables at runtime rather
  than embedding values. Never commit a `.env` file with real configuration.
- Avoid verbose HTTP options that might reveal request headers or credentials.

## Scope

Apply this skill to runtime configuration and authenticated access to the Fiteo
backend. For endpoint contract questions without a need to make a live request,
use `fiteo-backend-api`.
