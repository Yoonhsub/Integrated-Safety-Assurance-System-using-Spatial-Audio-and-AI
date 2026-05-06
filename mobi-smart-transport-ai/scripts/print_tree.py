from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDE = {'.git', '__pycache__', '.dart_tool', 'build'}


def walk(path: Path, prefix: str = ''):
    entries = sorted([p for p in path.iterdir() if p.name not in EXCLUDE], key=lambda p: (not p.is_dir(), p.name))
    for idx, entry in enumerate(entries):
        connector = '└── ' if idx == len(entries) - 1 else '├── '
        print(prefix + connector + entry.name)
        if entry.is_dir():
            extension = '    ' if idx == len(entries) - 1 else '│   '
            walk(entry, prefix + extension)

print(ROOT.name)
walk(ROOT)
