FROM registry.access.redhat.com/ubi9/python-312:latest

# ── Install uv ───────────────────────────────────────────────────────────────
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /opt/app-root/src

# ── Python dependencies ──────────────────────────────────────────────────────
COPY requirements.txt .
ENV VIRTUAL_ENV=/opt/app-root
RUN uv pip install --no-cache -r requirements.txt ogx chardet sqlite-vec pypdf markitdown

# ── Application code ─────────────────────────────────────────────────────────
COPY bank_state.py bank_tools.py bank_tools_unsafe.py mcp_server.py ./

# ── OGX configuration (both MCP modes as separate connectors) ────────────────
RUN cat <<'EOF' > ogx-config.yaml
version: 2
distro_name: starter
apis:
  - inference
  - interactions
  - messages
  - responses
  - tool_groups
  - tool_runtime
  - vector_io
  - files
  - file_processors
providers:
  inference:
    - provider_id: openai
      provider_type: remote::vllm
      config:
        api_token: ${env.OPENAI_API_KEY:=fake}
        base_url: ${env.OPENAI_BASE_URL:=https://api.openai.com/v1}
  interactions:
    - provider_id: builtin
      provider_type: inline::builtin
      config:
        store:
          table_name: interactions
          backend: sql_default
  messages:
    - provider_id: builtin
      provider_type: inline::builtin
  responses:
    - provider_id: builtin
      provider_type: inline::builtin
      config:
        persistence:
          responses:
            table_name: responses
            backend: sql_default
            max_write_queue_size: 10000
            num_writers: 4
  vector_io:
    - provider_id: sqlite-vec
      provider_type: inline::sqlite-vec
      config:
        db_path: ${env.SQLITE_STORE_DIR:=~/.ogx/distributions/starter}/sqlite_vec.db
        persistence:
          namespace: vector_io::sqlite_vec
          backend: kv_default
  files:
    - provider_id: builtin-files
      provider_type: inline::localfs
      config:
        storage_dir: ${env.FILES_STORAGE_DIR:=~/.ogx/distributions/starter/files}
        metadata_store:
          table_name: files_metadata
          backend: sql_default
  file_processors:
    - provider_id: auto
      provider_type: inline::auto
  tool_runtime:
    - provider_id: model-context-protocol
      provider_type: remote::model-context-protocol
  batches:
    - provider_id: reference
      provider_type: inline::reference
      config:
        sqlstore:
          table_name: batches
          backend: sql_default
storage:
  backends:
    kv_default:
      type: kv_sqlite
      db_path: ${env.SQLITE_STORE_DIR:=~/.ogx/distributions/starter}/kvstore.db
    sql_default:
      type: sql_sqlite
      db_path: ${env.SQLITE_STORE_DIR:=~/.ogx/distributions/starter}/sql_store.db
  stores:
    metadata:
      namespace: registry
      backend: kv_default
    inference:
      table_name: inference_store
      backend: sql_default
      max_write_queue_size: 10000
      num_writers: 4
    conversations:
      table_name: openai_conversations
      backend: sql_default
    prompts:
      table_name: prompts
      backend: sql_default
    connectors:
      table_name: connectors
      backend: sql_default
registered_resources:
  models:
    - metadata: {}
      model_id: ${env.MODEL_ID:=default}
      provider_id: all
      provider_model_id: auto
      model_type: llm
  vector_dbs: []
server:
  port: 8321
connectors:
  - connector_id: minibank-safe
    url: http://localhost:8888/sse
  - connector_id: minibank-unsafe
    url: http://localhost:8889/sse
EOF

# ── Entrypoint (both MCP servers + OGX) ──────────────────────────────────────
RUN cat <<'ENTRY' > /opt/app-root/src/entrypoint.sh
#!/bin/bash
set -e

echo "Starting MCP server (SAFE) on port 8888..."
python mcp_server.py --port 8888 &
SAFE_PID=$!

echo "Starting MCP server (UNSAFE) on port 8889..."
python mcp_server.py --port 8889 --unsafe &
UNSAFE_PID=$!

echo "Starting OGX server on port 8321..."
exec ogx run ogx-config.yaml
ENTRY
RUN chmod +x /opt/app-root/src/entrypoint.sh

EXPOSE 8321

ENTRYPOINT ["/opt/app-root/src/entrypoint.sh"]