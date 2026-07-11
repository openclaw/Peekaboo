---
summary: 'Choose an Ollama model for Peekaboo by verified tools, vision, context, and hardware capabilities.'
read_when:
  - 'choosing an Ollama model for agent automation or image analysis'
  - 'debugging an Ollama model capability mismatch'
---

# Choosing an Ollama model

Ollama's catalog and model capabilities change independently of Peekaboo. Treat model names, parameter counts, and
memory estimates as discovery hints—not proof that a model can drive the agent. Verify the exact tag you install.

## Match the capability to the command

| Peekaboo use | Required Ollama capability | Notes |
| --- | --- | --- |
| `peekaboo agent` | Tools/function calling | Required even when the task sounds text-only, because the agent acts through tools. |
| Image analysis | Vision | A vision-only model can analyze an image but cannot necessarily run the agent. |
| Visual agent task | Tools; vision if the selected workflow sends images to the model | Tool support and vision support are independent. |

Use Ollama's current [tools filter](https://ollama.com/search?c=tools) and
[vision filter](https://ollama.com/search?c=vision), then inspect the exact local tag:

```bash
ollama list
ollama show llama3.1:8b
```

The model page is the capability authority. A model that merely produces JSON is not equivalent to one implementing
Ollama's tool-calling protocol.

## Smoke-test the selected tag

```bash
MODEL=llama3.1:8b
ollama pull "$MODEL"

# A small budget proves the native route and one tool round trip.
peekaboo agent --model "ollama/$MODEL" --max-steps 2 \
  "Read the title of the frontmost window and report it"
```

The model must return a structured tool call, accept the named tool result on the next turn, and then produce a final
answer. If it emits prose that only describes a tool call, rejects the schema, or repeatedly calls the same tool,
choose a stronger tool-capable tag.

## Resource considerations

- Pick a quantization and parameter size that fits available unified memory or VRAM; otherwise Ollama may evict the
  model or respond too slowly for an interactive automation loop.
- Longer agent sessions replay conversation and tool history. Prefer a context window large enough for the task and
  start a fresh session when old context is no longer useful.
- Small models can be fast but less reliable with nested schemas and multi-step planning. Test the actual Peekaboo
  tool set rather than inferring reliability from a generic benchmark.
- Pulling a model requires network access and disk space even when subsequent inference runs locally.

See [Ollama](ollama.md) for endpoint precedence, the native `/api/chat` route, step-budget behavior, and the qualified
privacy boundary.
