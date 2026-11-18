---
name: freellmapi-environment
description: Configure and operate a local FreeLLMAPI environment with LiteLLM and related tools. Use when aggregating local cloud-provider APIs behind a single OpenAI-compatible endpoint.
---

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
- For Manul, use the FreeLLMAPI-backed `free-cloud` route as the primary/default LiteLLM upstream. It must be selected directly; do not route to OpenCode Zen first and treat FreeLLMAPI only as a fallback.
- Do not configure `https://opencode.ai/zen/v1` or `OPENCODE_API_KEY` as a LiteLLM upstream for Manul. The key may exist for a separate interactive OpenCode setup, but Manul's LiteLLM model path must not depend on it.
- Keep model names consumed by Globalskills/Manul stable when possible. If aliases such as `big-pickle` or `deepseek-v4-flash-free` are still requested by agent definitions, map them to verified model IDs from the FreeLLMAPI `/v1/models` catalogue. Do not leave dangling aliases or point them at OpenCode Zen.
- Keep direct provider entries in `config.yaml` only as deliberate alternatives/fallbacks after verifying their health and compatibility; they must not precede the FreeLLMAPI route for Manul.

Troubleshooting
---------------
- If LiteLLM `/v1/models` returns an empty list after restart: ensure the `FREELLMAPI_API_KEY` is exported in the same environment used to start the `litellm` process, and check `litellm` logs for errors.
- If FreeLLMAPI container can't be pulled due to registry permissions, use the installation script or pre-downloaded image that the environment maintainer supplied.

Notes for globalskills
---------------------
- This skill documents the recommended local-only setup using FreeLLMAPI. It is intended for personal/workspace skills (not public cloud instructions).
- Keep this skill concise and operational: how to start, configure, verify, and keep secrets safe.
