#!/usr/bin/env python3
"""Write plan code blocks to the repo. A block is extracted when its first
line is `-- file: <path>` (optionally prefixed by `# ` or `// `); the marker
line itself is not written.

Usage: extract-plan.py PLAN [--task N] [PATH ...]
  --task N   only blocks inside "### Task N:" (stub and final versions of a
             file live in different tasks)
  PATH ...   only these repo paths
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
args = sys.argv[1:]
plan = pathlib.Path(args.pop(0))
task = None
if args[:1] == ["--task"]:
    task = args[1]
    args = args[2:]
only = set(args)
text = plan.read_text()
if task is not None:
    m = re.search(rf"^### Task {task}:.*?(?=^### Task |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"task {task} not found")
    text = m.group(0)
block = re.compile(r"`{3}[a-z]*\n((?:# |// )?-- file: (\S+)\n.*?)`{3}", re.S)
written = 0
for m in block.finditer(text):
    body, rel = m.group(1), m.group(2)
    if only and rel not in only:
        continue
    content = body.split("\n", 1)[1]
    if rel.startswith("pixel-shift/") and rel.endswith(".luau"):
        # Noctalia requires explicit relative paths ending in .luau
        content = re.sub(r'require\("(\.{1,2}/[^"]+?)(?<!\.luau)"\)', r'require("\1.luau")', content)
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    written += 1
    print("wrote", rel)
print(written, "files")
