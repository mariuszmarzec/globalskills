Finish `fiteo_client.py` so it provides `load_fiteo_config()`, returning a mapping with keys `base_url`, `username`, and `password` for later Fiteo requests.

Configuration must be read dynamically from the current process environment each time the function runs. Do not hard-code a server URL or credentials, and do not make a network request. If any required setting is missing or empty, raise `ValueError` naming only the missing environment variables. Never print or log configured values. Keep the change scoped to this helper.
