#!/usr/bin/env python3
"""Generate ~/.codex/coreweave-models.json: the Codex /model menu entries for our CoreWeave models.
Format = Codex's ModelsResponse ({"models": [ModelInfo...]}), as in codex-rs/models-manager/models.json.
Values mirror Codex's own fallback metadata for unknown models (model_info_from_slug, Codex 0.164),
but with visibility "list" so they appear in /model. Re-run after editing MODELS.
The base instructions come from Codex's bundled prompt (codex-rs/models-manager/prompt.md)."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT = open(os.path.join(HERE, "codex-base-prompt.md")).read()

# slug, display name, description, image input, context window (tokens)
MODELS = [
    ("deepseek-ai/DeepSeek-V4.1-Flash", "DeepSeek V4.1 Flash", "Coding (default). Best coding scores here, cheap.", True, 262144),
    ("zai-org/GLM-5.3", "GLM-5.3", "Best overall; hardest problems. Most expensive.", False, 262144),
    ("zai-org/GLM-5.3-Flash", "GLM-5.3 Flash", "Reasoning and research; low hallucination. Cheap.", True, 262144),
    ("Qwen/Qwen3.8-27B", "Qwen3.8 27B", "Coding and analysis. Pricier output.", True, 262144),
    ("google/gemma-4-31B-it", "Gemma 4 31B", "Quick and cheap everyday tasks.", True, 262144),
]

def entry(i, slug, name, desc, image, ctx):
    return {
        "slug": slug, "display_name": name, "description": desc,
        "supported_reasoning_levels": [], "shell_type": "shell_command", "visibility": "list",
        "supported_in_api": True, "priority": i + 1,
        "availability_nux": None, "upgrade": None,
        "model_messages": {"instructions_template": PROMPT, "approvals": None},
        "include_apps_usage_instructions": False,
        "default_reasoning_summary": "auto",
        "support_verbosity": False, "default_verbosity": None, "apply_patch_tool_type": None,
        "web_search_tool_type": "text",
        "truncation_policy": {"mode": "bytes", "limit": 10000},
        "context_window": ctx, "max_context_window": ctx,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": ["text", "image"] if image else ["text"],
    }

out = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.codex/coreweave-models.json")
json.dump({"models": [entry(i, *m) for i, m in enumerate(MODELS)]}, open(out, "w"), indent=1)
print(f"wrote {out} ({len(MODELS)} models)")
