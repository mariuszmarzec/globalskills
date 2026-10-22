---
name: fiteo-backend-api
description: Use whenever the user asks about Fiteo backend API endpoints or contracts, including routes, HTTP methods, request/response payloads, DTOs, query/path parameters, authentication, validation, status codes, pagination, or implementing/reviewing code that calls or exposes a Fiteo endpoint. Before answering, search the indexed Fiteo API documentation through the caracal-rag MCP server.
---

# Fiteo Backend API

Use this skill whenever a task depends on the Fiteo backend HTTP API contract. Examples include asking what an endpoint does, which parameters it accepts, what the response looks like, how errors/authentication work, how pagination behaves, or implementing/reviewing frontend or backend code that consumes or exposes an endpoint.

## Mandatory first step: search Caracal RAG

Before answering a Fiteo backend endpoint question, use the `search_api` tool exposed by the `caracal-rag` MCP server. Do not rely only on model memory, assumptions, or a code-name search.

1. Search for the exact endpoint and the requested behavior. Use a focused query that includes the HTTP method and path when known; set `top_k` to around 8–10.
2. Run a second, narrower query for the specific details needed, such as request/response fields, DTO names, authentication/session requirements, validation, HTTP status codes, or pagination/cursor semantics.
3. Read the retrieved snippets and their source metadata. Prefer the endpoint-specific document over loosely related endpoints.
4. In the answer, state the relevant source document (for example, `trainings_get.md`) and link/cite its returned source URL when the MCP result provides one. Clearly distinguish documented behavior from any inference.

Example searches:
- `GET /fiteo/api/1/trainings query parameters response DTO`
- `trainings_get.md limit cursor nextCursor validation authentication status codes`

The indexed source is the `fiteo-docs` source, currently built from API Markdown documents in `mariuszmarzec/fiteo` under `docs/api/`. Search results can include neighboring endpoints; do not treat them as evidence for the endpoint in question unless the returned content actually applies.

## When implementing or reviewing code

Documentation search remains mandatory, but documentation is not proof that current implementation matches the contract.

- Inspect the current Fiteo repository implementation and tests for the relevant route/controller, service/repository logic, DTOs, validation, and pagination.
- Compare implementation behavior with the indexed API documentation. Call out discrepancies explicitly instead of silently choosing one.
- For a client-side change, use the documented request and response shape and check the actual code paths that parse and handle it.
- For a backend change, preserve the documented compatibility behavior unless the task explicitly calls for a contract change; update documentation/tests when the contract changes.
- Never invent endpoint paths, fields, error responses, ordering guarantees, or pagination semantics. If search results do not establish a detail, perform a narrower follow-up search or say that it could not be confirmed.

## If Caracal is unavailable

If the `caracal-rag` MCP server or `search_api` tool is missing/disconnected, do not pretend the indexed docs were searched. Check the MCP connection (for example, `opencode mcp list`) and report the blocker. If useful, inspect the source Markdown directly in the Fiteo repository as a fallback, clearly stating that the answer came from the repository rather than Caracal search.

## Scope

Apply this skill to Fiteo backend API contracts and code that interacts with those contracts. Do not invoke it for unrelated APIs or general Fiteo product/business questions with no endpoint dependency.
