---
name: litellm-db-setup
description: Configure LiteLLM to use a local PostgreSQL database for its UI/auth features. Use when setting up LiteLLM with database support, fixing LiteLLM database connection issues, or initializing the litellm PostgreSQL user and database.
---

# LiteLLM Database Setup

## Goal
Configure LiteLLM to use a local PostgreSQL database for its UI and auth features.

## Required Runtime
- PostgreSQL server installed locally
- LiteLLM installed (`pip3 install litellm`)

## Setup Steps

### 1. Start PostgreSQL

```bash
sudo service postgresql start
```

### 2. Create Database User

```bash
sudo -u postgres psql -c "CREATE USER litellm WITH PASSWORD 'litellm';"
```

### 3. Create Database

```bash
sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm;"
```

### 4. Grant Privileges

```bash
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;"
```

## LiteLLM Config

Add to `~/litellm/config.yaml` under `general_settings`:

```yaml
general_settings:
  master_key: "sk-12345678"
  database_url: "postgresql://litellm:litellm@127.0.0.1:5432/litellm"
```

## Healthcheck

```bash
sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='litellm';"
```

Expected: returns one row if the database exists.

## Troubleshooting

- **Connection refused**: Ensure PostgreSQL is running (`sudo service postgresql status`)
- **Authentication failed**: Verify the user exists (`sudo -u postgres psql -c "\du"`)
- **Database does not exist**: Re-run the CREATE DATABASE command
