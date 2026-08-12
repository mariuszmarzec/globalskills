# FreeLLMAPI Environment Skill

Purpose
-------
Document how to configure and operate a local FreeLLMAPI-based environment for use with LiteLLM and related tools.

When to use
-----------
- When LiteLLM is routed to a local FreeLLMAPI (router/dashboard) running on the same host.
- When you want a single unified, local provider that aggregates paid/free cloud providers behind one API.

Quick setup steps
-----------------
1. Install and run FreeLLMAPI (recommended via the project's docker-compose). Bind it to localhost only (127.0.0.1:3001).
2. In the FreeLLMAPI dashboard, add provider keys you control (Gemini, Mistral, Groq, etc.).
3. Generate a unified API key in the FreeLLMAPI dashboard and copy it.
4. Store the key locally and never commit it to git. Example (workspace-local):

   - File: `~/litellm/.env`
   - Add: `FREELLMAPI_API_KEY=freellmapi-<your-key>`

5. Update `~/litellm/config.yaml` to include the `free-cloud` provider entry pointing at `http://127.0.0.1:3001/v1` and set `api_key` to `os.environ/FREELLMAPI_API_KEY`.
6. Start or restart LiteLLM with the environment loaded: `set -a; source ~/litellm/.env; set +a; litellm --config ~/litellm/config.yaml --host 127.0.0.1 --port 4000`.

Verification
------------
- `curl -H "Authorization: Bearer $FREELLMAPI_API_KEY" http://127.0.0.1:3001/v1/models` should return a JSON catalog.
- `curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/v1/models` should list `free-cloud` in the returned list.
- Run a quick chat through LiteLLM using `model: free-cloud` and confirm a completion.

Security & ops best practices
-----------------------------
- Bind FreeLLMAPI to loopback (127.0.0.1) to avoid external exposure.
- Keep provider keys and the FreeLLMAPI unified key in local `.env` files outside git; add to `.gitignore` if necessary.
- Do not commit any keys or secrets. If a secret was accidentally committed, rotate it immediately.
- Consider adding a local firewall rule to prevent accidental binding to 0.0.0.0.

Routing considerations
---------------------
- Prefer routing to `free-cloud` as the primary fallback in `litellm` so OpenCode and other clients talk only to LiteLLM.
- Keep direct provider entries in `config.yaml` until you have fully verified feature parity in FreeLLMAPI; remove them in a staged manner.

Troubleshooting
---------------
- If LiteLLM `/v1/models` returns an empty list after restart: ensure the `FREELLMAPI_API_KEY` is exported in the same environment used to start the `litellm` process, and check `litellm` logs for errors.
- If FreeLLMAPI container can't be pulled due to registry permissions, use the installation script or pre-downloaded image that the environment maintainer supplied.

Notes for globalskills
---------------------
- This skill documents the recommended local-only setup using FreeLLMAPI. It is intended for personal/workspace skills (not public cloud instructions).
- Keep this skill concise and operational: how to start, configure, verify, and keep secrets safe.
