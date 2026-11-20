"""Install/update the Deep Research functions in Open WebUI (runs INSIDE the open-webui container).

    ~/HomeLab/open-webui/functions/install.sh

Uses Open WebUI's own function code (same steps as Admin Panel > Functions > Create), so the
manifest and the filter's toggle flag are set the normal way. Valves: on update, the existing values
are kept; LDR_PASSWORD always comes from stdin (DEEP_RESEARCH_PASSWORD in ~/HomeLab/.env).
"""
import asyncio, json, sys
from pathlib import Path

from open_webui.models.functions import FunctionForm, FunctionMeta, Functions
from open_webui.utils.plugin import load_function_module_by_id, replace_imports

SRC = Path("/tmp/owui-functions")
FUNCS = [  # (id, file, display name): the "Deep Research" model (a pipe function)
    ("deep_research", "deep_research_model.py", "Deep Research"),
]
REMOVED = ["approve_deep_research"]  # v1 (toggle filter + action button), replaced by the model


async def main():
    secrets = json.loads(sys.stdin.read() or "{}")
    owner = secrets.get("owner_id")
    for fid, fname, name in FUNCS:
        content = replace_imports((SRC / fname).read_text())
        module, ftype, frontmatter = await load_function_module_by_id(fid, content=content)  # compiles: raises on errors
        meta = FunctionMeta(description=frontmatter.get("description"), manifest=frontmatter)
        existing = await Functions.get_function_by_id(fid)
        if existing is not None and existing.type != ftype:  # e.g. v1 filter -> v2 pipe: recreate
            old_valves = (await Functions.get_function_valves_by_id(fid)) or {}
            await Functions.delete_function_by_id(fid)
            existing = None
            print(f"removed old {fid} (type changed)")
        if existing is None:
            await Functions.insert_new_function(owner, ftype, FunctionForm(id=fid, name=name, content=content, meta=meta))
            print(f"created {fid} ({ftype})")
        else:
            await Functions.update_function_by_id(fid, {"content": content, "name": name, "meta": meta.model_dump()})
            print(f"updated {fid} ({ftype})")
        if ftype == "filter" and getattr(module, "toggle", None):
            await Functions.update_function_metadata_by_id(fid, {"toggle": True})
        await Functions.update_function_by_id(fid, {"is_active": True, "is_global": True})
        if fid == "deep_research":
            current = (await Functions.get_function_valves_by_id(fid)) or {}
            current["LDR_PASSWORD"] = secrets["ldr_password"]
            current.setdefault("LDR_USERNAME", secrets.get("ldr_user", "openwebui"))
            await Functions.update_function_valves_by_id(fid, current)
            print(f"valves set for {fid}: {sorted(k for k in current)} (password from .env)")
    for fid in REMOVED:
        if await Functions.get_function_by_id(fid):
            await Functions.delete_function_by_id(fid)
            print(f"removed {fid}")
    for f in await Functions.get_functions():
        print(f"  {f.id:24} type={f.type:7} active={f.is_active} global={f.is_global}")


asyncio.run(main())
