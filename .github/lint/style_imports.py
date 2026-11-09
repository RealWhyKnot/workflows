from __future__ import annotations

import ast
import sys
from dataclasses import dataclass, field
from pathlib import PurePosixPath

from style_scan import Finding

STANDARD_MODULES = frozenset(sys.stdlib_module_names) | {"__future__"}
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


@dataclass(frozen=True, slots=True)
class LazyImport:
    line: int
    shown: str
    targets: tuple[str, ...]


@dataclass(slots=True)
class Module:
    path: str
    name: str
    package: str
    eager: list[str] = field(default_factory=list[str])
    lazy: list[LazyImport] = field(default_factory=list[LazyImport])


def is_type_checking(node: ast.If) -> bool:
    test = node.test
    return (isinstance(test, ast.Name) and test.id == "TYPE_CHECKING") or (
        isinstance(test, ast.Attribute) and test.attr == "TYPE_CHECKING"
    )


def module_name(path: str, packages: frozenset[str]) -> tuple[str, str]:
    pure = PurePosixPath(path)
    parts: list[str] = []
    folder = pure.parent
    while str(folder) in packages:
        parts.insert(0, folder.name)
        folder = folder.parent
    package = ".".join(parts)
    if pure.stem == "__init__":
        return package, package
    return ".".join([*parts, pure.stem]), package


def resolve(module: Module, node: ast.ImportFrom) -> str:
    if not node.level:
        return node.module or ""
    base = module.package.split(".") if module.package else []
    base = base[: len(base) - node.level + 1]
    return ".".join([*base, node.module] if node.module else base)


class Index:
    def __init__(self, modules: list[Module]) -> None:
        self.by_name: dict[str, list[Module]] = {}
        for module in modules:
            self.by_name.setdefault(module.name, []).append(module)
        self.heavy: dict[str, bool] = {}

    def targets(self, module: Module, node: ast.Import | ast.ImportFrom) -> tuple[str, ...]:
        if isinstance(node, ast.Import):
            return tuple(alias.name for alias in node.names)
        base = resolve(module, node)
        return tuple(f"{base}.{alias.name}" if f"{base}.{alias.name}" in self.by_name else base for alias in node.names)

    def own_prefixes(self, name: str) -> list[str]:
        parts = name.split(".")
        return [
            prefix for prefix in (".".join(parts[: end + 1]) for end in range(len(parts))) if prefix in self.by_name
        ]

    def is_heavy(self, name: str) -> bool:
        own = self.own_prefixes(name)
        if not own:
            return name.split(".", maxsplit=1)[0] not in STANDARD_MODULES
        return any(self.is_heavy_module(prefix) for prefix in own)

    def is_heavy_module(self, name: str) -> bool:
        if name in self.heavy:
            return self.heavy[name]
        self.heavy[name] = False
        found = any(self.is_heavy(target) for module in self.by_name[name] for target in module.eager)
        self.heavy[name] = found
        return found

    def reaches(self, name: str, goal: str, seen: set[str]) -> bool:
        for prefix in self.own_prefixes(name):
            if prefix == goal:
                return True
            if prefix in seen:
                continue
            seen.add(prefix)
            if any(self.reaches(target, goal, seen) for module in self.by_name[prefix] for target in module.eager):
                return True
        return False


def collect(module: Module, index: Index, node: ast.AST, *, lazy: bool) -> None:
    for child in ast.iter_child_nodes(node):
        if isinstance(child, ast.If) and not lazy and is_type_checking(child):
            for other in child.orelse:
                collect(module, index, other, lazy=lazy)
            continue
        if isinstance(child, ast.Import | ast.ImportFrom):
            targets = index.targets(module, child)
            if lazy:
                shown = ", ".join(alias.name for alias in child.names)
                module.lazy.append(LazyImport(child.lineno, shown, targets))
            else:
                module.eager.extend(targets)
            continue
        collect(module, index, child, lazy=lazy or isinstance(child, FUNCTIONS))


def check_imports(sources: dict[str, str]) -> list[Finding]:
    packages = frozenset(
        str(PurePosixPath(path).parent) for path in sources if PurePosixPath(path).name == "__init__.py"
    )
    trees: dict[str, ast.Module] = {}
    modules: list[Module] = []
    for path, text in sources.items():
        try:
            trees[path] = ast.parse(text, filename=path)
        except SyntaxError:
            continue
        name, package = module_name(path, packages)
        modules.append(Module(path, name, package))
    index = Index(modules)
    for module in modules:
        collect(module, index, trees[module.path], lazy=False)
    findings: list[Finding] = []
    for module in modules:
        for item in module.lazy:
            if any(index.is_heavy(target) for target in item.targets):
                continue
            if any(index.reaches(target, module.name, set[str]()) for target in item.targets):
                continue
            findings.append(
                Finding(module.path, item.line, f"import of {item.shown} inside a function; it's light (PY-14)")
            )
    return findings
