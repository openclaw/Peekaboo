---
summary: 'Configure and run Peekaboo with Ollama through its native chat API.'
read_when:
  - 'running Peekaboo with a local or remote Ollama server'
  - 'debugging Ollama tool calls, streaming, or endpoint selection'
---

# Ollama

Peekaboo supports Ollama directly. A model ID in the form `ollama/<model>` selects the native Ollama provider and
sends chat requests to `/api/chat`; no OpenAI-compatible adapter or API key is required.

## Quick start

```bash
brew install ollama
ollama serve
```

Leave that terminal running. In another terminal:

```bash
MODEL=llama3.1:8b
ollama pull "$MODEL"
peekaboo agent --model "ollama/$MODEL" "Open System Settings"
```

`peekaboo agent` requires a model that supports tool calling. Ollama capabilities are model-dependent: a model that
can generate text or inspect images does not necessarily accept tools. Check the model's current Ollama page or
`ollama show "$MODEL"` before using it for automation. See [Choosing a model](ollama-models.md) for a capability-first
selection guide.

## Endpoint selection

The built-in provider resolves its base URL in this order, highest priority first:

1. `PEEKABOO_OLLAMA_BASE_URL`
2. `OLLAMA_BASE_URL`
3. `aiProviders.ollamaBaseUrl` in `~/.peekaboo/config.json`
4. `http://localhost:11434`

Set the server base only; do not append `/api/chat` or `/v1`:

```bash
PEEKABOO_OLLAMA_BASE_URL=http://192.168.1.20:11434 \
  peekaboo agent --model ollama/llama3.1:8b "Summarize the frontmost window"
```

To persist the built-in provider endpoint:

```json
{
  "aiProviders": {
    "ollamaBaseUrl": "http://192.168.1.20:11434"
  }
}
```

### Native API versus OpenAI compatibility

Use `ollama/<model>` for Peekaboo's native integration. It targets `/api/chat`, understands Ollama's newline-delimited
stream format, and preserves Ollama's native tool-call history.

Ollama also exposes an OpenAI-compatible endpoint at `/v1`. Use that route only when testing the compatibility layer
or when a custom-provider workflow requires it:

```bash
peekaboo config add-provider ollama-openai \
  --type openai \
  --name "Ollama via OpenAI compatibility" \
  --base-url "http://localhost:11434/v1" \
  --api-key "dummy-key"

peekaboo config models-provider ollama-openai --discover --save
peekaboo agent --model ollama-openai/llama3.1:8b "Open System Settings"
```

The two routes have different wire formats and configuration. Do not give `/v1` to
`PEEKABOO_OLLAMA_BASE_URL`; that variable configures the native route.

## Tool calling and agent turns

Peekaboo follows Ollama's [multi-turn tool-calling contract](https://docs.ollama.com/capabilities/tool-calling):

1. Peekaboo sends the conversation and available tool schemas.
2. Ollama returns an assistant message containing one or more function calls.
3. Peekaboo executes those calls.
4. The next request replays the assistant's function calls followed by named `tool` result messages.
5. The loop repeats until the model returns a final answer without more tool calls.

Ollama does not retain this state between requests. Peekaboo therefore sends the canonical assistant call and tool
result history on every follow-up, including nested arguments, array schemas, and parallel calls.

`--max-steps` limits model turns, not individual tool invocations. The CLI accepts `1...100` and defaults to `100`;
one turn may contain several parallel tool calls. If the last permitted turn still requests tools and needs another
model turn to interpret their results, Peekaboo saves the session and reports step-budget exhaustion instead of
returning an empty success. Resume that session to continue from the preserved tool results.

## Streaming behavior

Ollama's native chat API returns newline-delimited JSON when streaming. Peekaboo asks for that format and validates
each chunk, including [errors delivered after an HTTP 200 response](https://docs.ollama.com/api/errors).

Tachikoma parses each NDJSON chunk as it arrives and emits text deltas incrementally. The exact chunk cadence depends
on the model and Ollama server; tool calls become actionable only after Ollama has supplied their complete arguments.

## Privacy boundary

When the resolved base URL points to a daemon on the same Mac and the selected model is local, prompts, screenshots
included in model requests, tool history, and model responses are processed on that Mac. A loopback URL alone is not
a local-only guarantee: Ollama cloud-model tags are automatically offloaded through the daemon.

For strict local-only operation, use a locally installed model and disable Ollama cloud features with
`OLLAMA_NO_CLOUD=1` or `"disable_ollama_cloud": true` in `~/.ollama/server.json`, then restart Ollama. See Ollama's
[cloud guide](https://docs.ollama.com/cloud) and [FAQ](https://docs.ollama.com/faq). Other network boundaries remain:

- `ollama pull` contacts Ollama's model registry.
- A remote `PEEKABOO_OLLAMA_BASE_URL` or `OLLAMA_BASE_URL` sends model data to that host.
- A cloud model sends prompts and responses to Ollama Cloud even when Peekaboo connects to `localhost`.
- Tools chosen by the model can launch apps or perform actions that use the network.
- Other configured cloud providers remain separate network paths; an explicit `--model ollama/...` keeps model
  selection on Ollama for that run.

Review the endpoint and enabled tools before using sensitive data.

## Troubleshooting

- **Connection refused:** start `ollama serve`, then verify the resolved URL with `peekaboo config show --effective`.
- **Model not found:** run `ollama list`, then `ollama pull <model>` if necessary.
- **Tool-call or schema error:** the selected model may not support tools reliably. Choose a model marked for tools in
  the current [Ollama library](https://ollama.com/search?c=tools).
- **Vision works but `agent` fails:** vision and tools are independent capabilities; choose a tool-capable model for
  `peekaboo agent`.
- **Run stops at the limit:** increase `--max-steps` within `1...100`, or reduce the task scope. A limit failure means
  the model still had pending work, not that the completed tool results were lost; the error identifies the saved
  session that can be resumed.

Official references: [chat API](https://docs.ollama.com/api/chat),
[tool calling](https://docs.ollama.com/capabilities/tool-calling), and
[OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility).
