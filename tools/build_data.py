#!/usr/bin/env python3
"""
Builds the craftbook data files from a Phoenix (LandSandBoat) server checkout.

    python build_data.py --repo C:/path/to/Phoenix
    python build_data.py --repo C:/path/to/any/clone --ref PXI/beta

Reads the files the server loads (synth_recipes.sql, NPC shop scripts, guild shop data, zone mob YAML, HELM
tables), applies the modules listed in modules/init.txt the way the server does, and writes TSV files into
../data. Requires PyYAML.
"""

import argparse
import collections
import io
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

import yaml

try:
    YamlLoader = yaml.CSafeLoader
except AttributeError:
    YamlLoader = yaml.SafeLoader

# Phoenix runs RESTRICT_CONTENT with these expansions enabled; every later expansion's content is disabled.
ENABLED_EXPANSIONS = {'ROTZ', 'COP', 'TOAU'}

EXPANSION_ORDER = ['ROTZ', 'COP', 'TOAU', 'WOTG', 'ACP', 'AMK', 'ASA', 'ABYSSEA', 'VOIDWATCH', 'SOA', 'ROV', 'TVR']

# Out-of-era zones that carry no content tag of their own (WotG, Abyssea, ASA, SoA and later).
DISABLED_ZONE_IDS = {43, 44, 78, 86, 93, 129, 133, 182, 183, 189, 222, 229}

CRAFT_COLUMNS = ['Wood', 'Smith', 'Gold', 'Cloth', 'Leather', 'Bone', 'Alchemy', 'Cook']

SHOP_CALLS = {
    ('shop', 'general'): 'general',
    ('shop', 'nation'): 'nation',
    ('shop', 'generalGuild'): 'generalGuild',
    ('shop', 'handleRegionalShop'): 'regional',
    ('shop', 'handleValerianoShop'): 'valeriano',
    ('shop', 'curioVendorMoogle'): 'curio',
    ('shop', 'celebratory'): 'celebratory',
    ('shop', 'outpost'): 'outpost',
    ('guildShops', 'onTrigger'): 'guild',
}

STOCK_KINDS = {'general', 'nation', 'valeriano'}

NATION_DISPLAY = {'SANDORIA': "San d'Oria", 'BASTOK': 'Bastok', 'WINDURST': 'Windurst'}

REGION_DISPLAY = {
    'ELSHIMO_LOWLANDS': 'Elshimo Lowlands',
    'ELSHIMO_UPLANDS': 'Elshimo Uplands',
    'QUFIMISLAND': 'Qufim Island',
    'TAVNAZIANARCH': 'Tavnazian Archipelago',
    'KOLSHUSHU': 'Kolshushu',
    'MOVALPOLOS': 'Movalpolos',
}

MAX_TOKENS = 50_000_000

warnings = []


def warn(message):
    warnings.append(message)


def content_enabled(tag):
    if tag is None:
        return True

    upper = str(tag).strip().strip("'").upper()
    if upper in ('', 'NULL', 'NONE'):
        return True

    return upper in ENABLED_EXPANSIONS


def expansion_disabled(name):
    return name in EXPANSION_ORDER and name not in ENABLED_EXPANSIONS


def zone_enabled(zone_id, zone_name):
    if zone_id in DISABLED_ZONE_IDS or zone_id >= 256:
        return False

    return not (zone_name.endswith('_s') or zone_name.startswith('abyssea_'))


def title_case(snake):
    return ' '.join(part[:1].upper() + part[1:] for part in snake.split('_') if part)


# ---------------------------------------------------------------------------
# Lua reading
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(
    r'''
    (?P<ws>\s+)
    |(?P<comment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\]|--[^\n]*)
    |(?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|\[(?P<seq>=*)\[.*?\](?P=seq)\])
    |(?P<number>0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+)
    |(?P<name>[A-Za-z_][A-Za-z0-9_]*)
    |(?P<op>\.\.\.|\.\.|==|~=|<=|>=|::|[-+*/%^#<>=(){}\[\];:,.])
    ''',
    re.S | re.X,
)

BLOCK_OPENERS = {'function', 'if', 'do', 'repeat'}
BLOCK_CLOSERS = {'end', 'until'}


class Tok:
    __slots__ = ('kind', 'v')

    def __init__(self, kind, v):
        self.kind = kind
        self.v = v

    def is_op(self, value):
        return self.kind == 'op' and self.v == value

    def is_name(self, value):
        return self.kind == 'name' and self.v == value


EOF_TOKEN = Tok('eof', '')


def tokenize(text):
    tokens = []
    pos = 0
    end = len(text)
    while pos < end:
        match = TOKEN_RE.match(text, pos)
        if match is None:
            pos += 1
            continue

        pos = match.end()
        kind = match.lastgroup
        if kind not in ('string', 'number', 'name', 'op'):
            continue

        value = match.group(kind)
        if kind == 'string':
            if value.startswith('['):
                open_len = value.index('[', 1) + 1
                value = value[open_len:len(value) - open_len]
            else:
                value = value[1:-1].replace("\\'", "'").replace('\\"', '"')
        tokens.append(Tok(kind, value))

    return tokens


def tok_at(tokens, i):
    if 0 <= i < len(tokens):
        return tokens[i]

    return EOF_TOKEN


class LTable:
    __slots__ = ('arr', 'map')

    def __init__(self):
        self.arr = []
        self.map = {}


class Unknown:
    __slots__ = ('raw',)

    def __init__(self, raw):
        self.raw = raw


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def parse_number(text):
    if text.lower().startswith('0x'):
        return int(text, 16)

    if re.fullmatch(r'\d+', text):
        return int(text)

    return float(text)


def dotted_name_at(tokens, i):
    """Returns (name, next index) for a.b.c starting at i, or (None, i)."""
    if tok_at(tokens, i).kind != 'name':
        return None, i

    parts = [tokens[i].v]
    j = i + 1
    while tok_at(tokens, j).is_op('.') and tok_at(tokens, j + 1).kind == 'name':
        parts.append(tokens[j + 1].v)
        j += 2

    return '.'.join(parts), j


class Resolver:
    def __init__(self):
        self.values = {}
        self.locals = {}

    def resolve(self, name):
        if name in self.locals:
            return self.locals[name]

        if name in self.values:
            return self.values[name]

        return Unknown(name)

    def reverse(self, prefix):
        result = {}
        for key, value in self.values.items():
            if key.startswith(prefix + '.') and is_number(value):
                result.setdefault(value, key[len(prefix) + 1:])

        return result


def eval_expr(tokens, resolver):
    raw = ' '.join(t.v for t in tokens)
    if not tokens:
        return Unknown(raw)

    if len(tokens) == 1:
        token = tokens[0]
        if token.kind == 'number':
            return parse_number(token.v)
        if token.kind == 'string':
            return token.v
        if token.is_name('true'):
            return True
        if token.is_name('false'):
            return False
        if token.is_name('nil'):
            return None

    name, end = dotted_name_at(tokens, 0)
    if name is not None and end == len(tokens):
        return resolver.resolve(name)

    parts = []
    j = 0
    while j < len(tokens):
        token = tokens[j]
        if token.kind == 'number':
            parts.append(repr(parse_number(token.v)))
            j += 1
            continue

        if token.kind == 'name':
            name, end = dotted_name_at(tokens, j)
            value = resolver.resolve(name)
            if not is_number(value):
                return Unknown(raw)
            parts.append(repr(value))
            j = end
            continue

        if token.kind == 'op' and token.v in ('+', '-', '*', '/', '(', ')'):
            parts.append(token.v)
            j += 1
            continue

        return Unknown(raw)

    try:
        return eval(''.join(parts), {'__builtins__': {}}, {})
    except Exception:
        return Unknown(raw)


def read_expr(tokens, i, stops, resolver):
    depth = 0
    start = i
    while i < len(tokens):
        token = tokens[i]
        if token.kind == 'op':
            if depth == 0 and token.v in stops:
                break
            if token.v in ('(', '[', '{'):
                depth += 1
            elif token.v in (')', ']', '}'):
                if depth == 0:
                    break
                depth -= 1
        i += 1

    return eval_expr(tokens[start:i], resolver), i


APPEND = object()


def parse_table(tokens, i, resolver):
    """Parses the table constructor whose '{' is at i. Returns (LTable, index after '}')."""
    stack = [[LTable(), APPEND]]
    i += 1
    while i < len(tokens):
        table = stack[-1][0]
        token = tokens[i]

        if token.is_op('}'):
            done, key = stack.pop()
            i += 1
            if not stack:
                return done, i
            store(stack[-1][0], key, done)
            if tok_at(tokens, i).kind == 'op' and tok_at(tokens, i).v in (',', ';'):
                i += 1
            continue

        key = APPEND
        if token.is_op('['):
            key, i = read_expr(tokens, i + 1, (']',), resolver)
            i += 1
            if tok_at(tokens, i).is_op('='):
                i += 1
        elif token.kind == 'name' and tok_at(tokens, i + 1).is_op('='):
            key = token.v
            i += 2

        if tok_at(tokens, i).is_op('{'):
            stack.append([LTable(), key])
            i += 1
            continue

        value, i = read_expr(tokens, i, (',', ';', '}'), resolver)
        store(table, key, value)
        if tok_at(tokens, i).kind == 'op' and tok_at(tokens, i).v in (',', ';'):
            i += 1

    raise ValueError('unterminated table')


def store(table, key, value):
    if key is APPEND:
        table.arr.append(value)
        return

    if isinstance(key, Unknown):
        key = key.raw

    table.map[key] = value


def find_block_end(tokens, i):
    """Index of the 'end' closing the block opened at i."""
    depth = 0
    for j in range(i, len(tokens)):
        token = tokens[j]
        if token.kind != 'name':
            continue
        if token.v in BLOCK_OPENERS:
            depth += 1
        elif token.v in BLOCK_CLOSERS:
            depth -= 1
            if depth == 0:
                return j

    return len(tokens) - 1


def find_matching(tokens, i, open_value, close_value):
    depth = 0
    for j in range(i, len(tokens)):
        if tokens[j].is_op(open_value):
            depth += 1
        elif tokens[j].is_op(close_value):
            depth -= 1
            if depth == 0:
                return j

    return len(tokens) - 1


def find_assignment_table(tokens, dotted):
    """Finds `dotted = {` and returns the index of '{', or -1."""
    for i in range(len(tokens)):
        name, end = dotted_name_at(tokens, i)
        if name == dotted and tok_at(tokens, end).is_op('=') and tok_at(tokens, end + 1).is_op('{'):
            if i > 0 and tokens[i - 1].is_op('.'):
                continue
            return end + 1

    return -1


def file_level_tables(tokens, resolver):
    """`local NAME = { ... }` tables, as NAME -> (lo, hi) token range."""
    tables = {}
    for i in range(len(tokens) - 3):
        if tokens[i].is_name('local') and tokens[i + 1].kind == 'name' and tokens[i + 2].is_op('=') and tokens[i + 3].is_op('{'):
            hi = find_matching(tokens, i + 3, '{', '}')
            tables[tokens[i + 1].v] = (i + 3, hi)

    return tables


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

def load_enums(repo):
    resolver = Resolver()

    for path in sorted((repo / 'data' / 'enums').glob('*.yaml')):
        document = yaml.load(path.read_text(encoding='utf-8'), Loader=YamlLoader)
        table = ((document.get('meta') or {}).get('lua') or {}).get('table')
        if not table:
            continue
        for key, value in (document.get('values') or {}).items():
            resolver.values[f'{table}.{str(key).upper()}'] = value

    for path in sorted((repo / 'scripts' / 'enum').glob('*.lua')):
        tokens = tokenize(path.read_text(encoding='utf-8', errors='replace'))
        i = 0
        while i < len(tokens):
            name, end = dotted_name_at(tokens, i)
            if name is not None and name.startswith('xi.') and tok_at(tokens, end).is_op('=') and tok_at(tokens, end + 1).is_op('{'):
                if i > 0 and tokens[i - 1].is_op('.'):
                    i = end
                    continue
                table, after = parse_table(tokens, end + 1, resolver)
                for key, value in table.map.items():
                    if isinstance(key, str) and (is_number(value) or isinstance(value, str)):
                        resolver.values[f'{name}.{key}'] = value
                i = after
                continue
            i += 1

    return resolver


# ---------------------------------------------------------------------------
# Server layout: init.txt, zones, SQL
# ---------------------------------------------------------------------------

def read_init_entries(repo):
    entries = []
    for line in (repo / 'modules' / 'init.txt').read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        entries.append(line)

    return entries


def data_roots(repo, entries):
    """Module data directories in init.txt order, as the patched zone loader resolves them."""
    roots = []
    seen = set()
    for entry in entries:
        entry = entry.rstrip('/')
        parts = entry.split('/')
        explicit = 'data' in parts
        bare = len(parts) == 1
        if not explicit and not bare:
            continue

        root = repo / 'modules' / entry
        if not explicit:
            root = root / 'data'
        key = str(root)
        if key in seen:
            continue
        seen.add(key)
        roots.append(root)

    return roots


def lua_module_files(repo, entries):
    """Module .lua files in the order LoadLuaModules runs them."""
    files = []
    expanded = []
    for entry in entries:
        path = repo / 'modules' / entry.rstrip('/')
        if path.is_dir():
            expanded.extend(sorted(p for p in path.rglob('*') if p.is_file()))
            continue
        if path.is_file():
            files.append(path)

    files.extend(expanded)
    return [p for p in files if p.suffix == '.lua' and p.name != 'module_utils.lua']


def sql_module_files(repo, entries):
    files = []
    for entry in entries:
        path = repo / 'modules' / entry.rstrip('/')
        if path.is_dir():
            files.extend(sorted(path.glob('**/*.sql')))
        elif path.is_file() and path.suffix == '.sql':
            files.append(path)

    return files


def merge_patch(target, patch):
    """RFC 7396 merge patch, as glz::merge_patch applies module YAML."""
    if not isinstance(patch, dict):
        return patch

    if not isinstance(target, dict):
        target = {}

    for key, value in patch.items():
        if value is None:
            target.pop(key, None)
        elif isinstance(value, dict):
            target[key] = merge_patch(target.get(key), value)
        else:
            target[key] = value

    return target


def load_zone_yaml(repo, roots, zone_name, kind):
    path = repo / 'data' / 'zones' / zone_name / f'{kind}.yaml'
    if not path.exists():
        return None

    document = yaml.load(path.read_text(encoding='utf-8'), Loader=YamlLoader) or {}
    for root in roots:
        patch_path = root / 'zones' / zone_name / f'{kind}.yaml'
        if patch_path.exists():
            patch = yaml.load(patch_path.read_text(encoding='utf-8'), Loader=YamlLoader) or {}
            document = merge_patch(document, patch)

    return document


def load_zone_settings(repo):
    script_dirs = {}
    for match in re.finditer(r"INSERT INTO `zone_settings` VALUES \((\d+),'[^']*',\d+,'([^']+)'\)", (repo / 'sql' / 'zone_settings.sql').read_text(encoding='utf-8')):
        script_dirs[match.group(2)] = int(match.group(1))

    return script_dirs


SQL_VALUE_RE = re.compile(r"'(?:[^'\\]|\\.)*'|NULL|-?\d+(?:\.\d+)?|@\w+(?:\s*\|\s*@\w+)*")


def split_sql_values(text):
    return SQL_VALUE_RE.findall(text)


def sql_literal(value):
    if value == 'NULL':
        return None
    if value.startswith("'"):
        return value[1:-1].replace("\\'", "'")
    if re.fullmatch(r'-?\d+', value):
        return int(value)

    return value


UPDATE_RE = re.compile(r"UPDATE\s+`?(\w+)`?\s+SET\s+(.+?)\s+WHERE\s+`?(\w+)`?\s*=\s*(\d+)\s*;", re.I | re.S)
ASSIGN_RE = re.compile(r"`?(\w+)`?\s*=\s*('(?:[^'\\]|\\.)*'|-?\d+|NULL)")


def read_sql_updates(files, table):
    """UPDATE <table> SET col = literal[, ...] WHERE key = n statements, in file order."""
    updates = []
    for path in files:
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        text = re.sub(r'--[^\n]*', '', text)
        for match in UPDATE_RE.finditer(text):
            if match.group(1).lower() != table.lower():
                continue
            assignments = {}
            for assign in ASSIGN_RE.finditer(match.group(2)):
                assignments[assign.group(1).lower()] = sql_literal(assign.group(2))
            if not assignments:
                continue
            updates.append((match.group(3).lower(), int(match.group(4)), assignments))
        if re.search(rf'(INSERT|DELETE|REPLACE)[^;]*\b{table}\b', text, re.I):
            warn(f'{path.name}: non-UPDATE statement on {table} ignored')

    return updates


# ---------------------------------------------------------------------------
# Recipes and items
# ---------------------------------------------------------------------------

def load_recipes(repo, sql_files):
    columns = None
    rows = {}
    text = (repo / 'sql' / 'synth_recipes.sql').read_text(encoding='utf-8')
    create = re.search(r'CREATE TABLE `synth_recipes` \((.*?)\n\)', text, re.S)
    columns = [c.lower() for c in re.findall(r'^\s*`(\w+)`', create.group(1), re.M)]

    for line in text.splitlines():
        if not line.startswith('INSERT INTO `synth_recipes`'):
            continue
        values = split_sql_values(line[line.index('(') + 1:line.rindex(')')])
        record = dict(zip(columns, (sql_literal(v) for v in values)))
        rows[record['id']] = record

    for key, row_id, assignments in read_sql_updates(sql_files, 'synth_recipes'):
        if key != 'id' or row_id not in rows:
            warn(f'synth_recipes update for {key}={row_id} matched nothing')
            continue
        rows[row_id].update(assignments)

    return [r for r in rows.values() if content_enabled(r['content_tag'])]


def load_base_sell(repo, sql_files):
    prices = {}
    names = {}
    text = (repo / 'sql' / 'item_basic.sql').read_text(encoding='utf-8')
    for line in text.splitlines():
        if not line.startswith('INSERT INTO `item_basic`'):
            continue
        values = split_sql_values(line[line.index('(') + 1:line.rindex(')')])
        item_id = int(values[0])
        names[item_id] = sql_literal(values[2])
        prices[item_id] = int(values[-1])

    for key, row_id, assignments in read_sql_updates(sql_files, 'item_basic'):
        if key != 'itemid' or 'basesell' not in assignments:
            continue
        prices[row_id] = assignments['basesell']

    return prices, names


# ---------------------------------------------------------------------------
# Module overrides
# ---------------------------------------------------------------------------

class Override:
    __slots__ = ('target', 'path', 'tokens', 'lo', 'hi', 'enabled', 'file_tables')

    def __init__(self, target, path, tokens, lo, hi, enabled, file_tables):
        self.target = target
        self.path = path
        self.tokens = tokens
        self.lo = lo
        self.hi = hi
        self.enabled = enabled
        self.file_tables = file_tables


def eval_module_condition(tokens):
    if not tokens:
        return True

    text = ' '.join(t.v for t in tokens)
    match = re.fullmatch(r'(not )?xi \. pre \( xi \. expansion \. (\w+) \)', text)
    if match is None:
        return False

    disabled = expansion_disabled(match.group(2))
    if match.group(1):
        return not disabled

    return disabled


def scan_module_file(path, resolver):
    tokens = tokenize(path.read_text(encoding='utf-8', errors='replace'))
    module_enabled = {}
    pending = []
    file_tables = file_level_tables(tokens, resolver)

    i = 0
    while i < len(tokens):
        token = tokens[i]

        if token.is_name('Module') and tok_at(tokens, i + 1).is_op(':') and tok_at(tokens, i + 2).is_name('new') and tok_at(tokens, i + 3).is_op('('):
            close = find_matching(tokens, i + 3, '(', ')')
            condition = []
            if tok_at(tokens, i + 5).is_op(','):
                condition = tokens[i + 6:close]
            variable = None
            if tok_at(tokens, i - 1).is_op('='):
                variable = tok_at(tokens, i - 2).v
            module_enabled[variable] = eval_module_condition(condition)
            i = close + 1
            continue

        if token.kind == 'name' and tok_at(tokens, i + 1).is_op(':') and tok_at(tokens, i + 2).is_name('setEnabled'):
            if tok_at(tokens, i + 4).is_name('false'):
                module_enabled[token.v] = False
            i += 5
            continue

        if token.kind == 'name' and tok_at(tokens, i + 1).is_op(':') and tok_at(tokens, i + 2).kind == 'name' and tok_at(tokens, i + 3).is_op('(') and tok_at(tokens, i + 4).kind == 'string':
            method = tokens[i + 2].v
            target = tokens[i + 4].v

            if method == 'addOverride' and tok_at(tokens, i + 6).is_name('function'):
                end = find_block_end(tokens, i + 6)
                pending.append((token.v, target, i + 6, end, True))
                i = end + 1
                continue

            if method == 'addOverrideByEra' and tok_at(tokens, i + 6).is_op('{'):
                table_end = find_matching(tokens, i + 6, '{', '}')
                cases = []
                j = i + 7
                while j < table_end:
                    if tokens[j].is_op('['):
                        name, after = dotted_name_at(tokens, j + 1)
                        if name is not None and name.startswith('xi.expansion.') and tok_at(tokens, after + 2).is_name('function'):
                            end = find_block_end(tokens, after + 2)
                            expansion = name.split('.')[-1]
                            cases.append((EXPANSION_ORDER.index(expansion), expansion, after + 2, end))
                            j = end + 1
                            continue
                    j += 1
                cases.sort(key=lambda c: c[0], reverse=True)
                for _, expansion, lo, hi in cases:
                    pending.append((token.v, target, lo, hi, expansion_disabled(expansion)))
                i = table_end + 1
                continue

        i += 1

    overrides = []
    for variable, target, lo, hi, case_enabled in pending:
        enabled = case_enabled and module_enabled.get(variable, True)
        overrides.append(Override(target, path, tokens, lo, hi, enabled, file_tables))

    return overrides


# ---------------------------------------------------------------------------
# Shops
# ---------------------------------------------------------------------------

class ShopInfo:
    __slots__ = ('kinds', 'rows', 'skill', 'calls_super')

    def __init__(self):
        self.kinds = set()
        self.rows = []
        self.skill = None
        self.calls_super = False


def stock_rows_in(tokens, lo, hi, resolver):
    rows = []
    i = lo
    while i < hi:
        if not tokens[i].is_op('{'):
            i += 1
            continue

        first = tok_at(tokens, i + 1)
        looks_like_row = first.kind == 'number' or (first.is_name('xi') and tok_at(tokens, i + 3).is_name('item'))
        if not looks_like_row:
            i += 1
            continue

        table, after = parse_table(tokens, i, resolver)
        if len(table.arr) >= 2 and isinstance(table.arr[0], int) and not isinstance(table.arr[0], bool) and 0 < table.arr[0] < 65536 and is_number(table.arr[1]):
            rows.append(table.arr)
        elif len(table.arr) >= 1 and isinstance(table.arr[0], Unknown) and table.arr[0].raw.startswith('xi.item.'):
            warn(f'unknown item {table.arr[0].raw}')
        i = after

    return rows


def analyze_shop_range(tokens, lo, hi, resolver, file_tables):
    info = ShopInfo()
    for i in range(lo, hi):
        token = tokens[i]
        if token.is_name('super') and tok_at(tokens, i + 1).is_op('('):
            info.calls_super = True
            continue
        if not token.is_name('xi') or not tok_at(tokens, i + 1).is_op('.'):
            continue
        group = tok_at(tokens, i + 2).v
        method = tok_at(tokens, i + 4).v
        if tok_at(tokens, i + 5).is_op('(') and (group, method) in SHOP_CALLS:
            info.kinds.add(SHOP_CALLS[(group, method)])
        if group == 'skill' and tok_at(tokens, i + 3).is_op('.'):
            info.skill = resolver.resolve(f'xi.skill.{method}')

    if info.kinds & STOCK_KINDS:
        info.rows = stock_rows_in(tokens, lo, hi, resolver)
        if not info.rows:
            referenced = {t.v for t in tokens[lo:hi] if t.kind == 'name'}
            for name, (table_lo, table_hi) in file_tables.items():
                if name in referenced:
                    info.rows.extend(stock_rows_in(tokens, table_lo, table_hi, resolver))

    return info


def load_npc_shop_scripts(repo, resolver):
    shops = {}
    for npc_path in sorted((repo / 'scripts' / 'zones').glob('*/npcs/*.lua')):
        text = npc_path.read_text(encoding='utf-8', errors='replace')
        if 'xi.shop.' not in text and 'xi.guildShops.onTrigger' not in text:
            continue
        tokens = tokenize(text)
        info = analyze_shop_range(tokens, 0, len(tokens), resolver, {})
        if info.kinds:
            shops[(npc_path.parent.parent.name, npc_path.stem)] = info

    return shops


def load_shop_globals(repo, resolver):
    tokens = tokenize((repo / 'scripts' / 'globals' / 'shop.lua').read_text(encoding='utf-8'))
    result = {'regionalVendors': LTable(), 'regionalStock': LTable(), 'generalGuildStock': LTable(), 'valeriano': []}

    for i in range(len(tokens) - 3):
        if tokens[i].is_name('local') and tokens[i + 2].is_op('=') and tokens[i + 3].is_op('{'):
            if tokens[i + 1].v == 'regionalVendorTable':
                result['regionalVendors'], _ = parse_table(tokens, i + 3, resolver)
            elif tokens[i + 1].v == 'regionalStockTable':
                result['regionalStock'], _ = parse_table(tokens, i + 3, resolver)

    brace = find_assignment_table(tokens, 'xi.shop.generalGuildStock')
    if brace >= 0:
        result['generalGuildStock'], _ = parse_table(tokens, brace, resolver)

    for i in range(len(tokens)):
        name, end = dotted_name_at(tokens, i)
        if name == 'xi.shop.handleValerianoShop' and tok_at(tokens, end).is_op('=') and tok_at(tokens, end + 1).is_name('function'):
            hi = find_block_end(tokens, end + 1)
            result['valeriano'] = stock_rows_in(tokens, end + 1, hi, resolver)
            break

    return result


def load_guild_shops(repo, resolver):
    tokens = tokenize((repo / 'scripts' / 'data' / 'guild_shops.lua').read_text(encoding='utf-8'))
    brace = find_assignment_table(tokens, 'xi.data.guildShops')
    table, _ = parse_table(tokens, brace, resolver)
    return {name: shop for name, shop in table.map.items()}


def guild_shop_key(tokens, i):
    """Matches xi.data.guildShops['X'] at i. Returns (shop name, index after ']') or (None, i)."""
    name, end = dotted_name_at(tokens, i)
    if name != 'xi.data.guildShops' or not tok_at(tokens, end).is_op('[') or tok_at(tokens, end + 1).kind != 'string':
        return None, i

    return tokens[end + 1].v, end + 3


def find_guild_stock(shops, shop_name, item_id):
    shop = shops.get(shop_name)
    if shop is None or 'stock' not in shop.map:
        warn(f'guild op on missing shop {shop_name}')
        return None, -1

    for index, cfg in enumerate(shop.map['stock'].arr):
        if cfg.map.get('id') == item_id:
            return cfg, index

    warn(f'guild op on missing item {item_id} in {shop_name}')
    return None, -1


def apply_guild_ops(shops, override, resolver):
    tokens = override.tokens
    i = override.lo
    while i < override.hi:
        token = tokens[i]

        shop_name, after = guild_shop_key(tokens, i)
        if shop_name is not None:
            if tok_at(tokens, after).is_op('=') and tok_at(tokens, after + 1).is_op('{'):
                value, i = parse_table(tokens, after + 1, resolver)
                shops[shop_name] = value
                continue
            if tok_at(tokens, after).is_op('.') and tok_at(tokens, after + 2).is_op('='):
                field = tokens[after + 1].v
                if tok_at(tokens, after + 3).is_op('{'):
                    value, i = parse_table(tokens, after + 3, resolver)
                else:
                    value, i = read_expr(tokens, after + 3, (), resolver)
                shops.setdefault(shop_name, LTable()).map[field] = value
                continue

        name, after = dotted_name_at(tokens, i)
        if name == 'table.insert' and tok_at(tokens, after).is_op('('):
            shop_name, key_end = guild_shop_key(tokens, after + 1)
            close = find_matching(tokens, after, '(', ')')
            if shop_name is None or not tok_at(tokens, key_end + 1).is_name('stock'):
                i = close + 1
                continue
            j = key_end + 3
            position = None
            if not tok_at(tokens, j).is_op('{'):
                position, j = read_expr(tokens, j, (',',), resolver)
                j += 1
            entry, _ = parse_table(tokens, j, resolver)
            stock = shops[shop_name].map['stock'].arr
            if is_number(position):
                stock.insert(int(position) - 1, entry)
            else:
                stock.append(entry)
            i = close + 1
            continue

        if token.kind == 'name' and token.v in ('patchStock', 'removeStock') and tok_at(tokens, i + 1).is_op('('):
            close = find_matching(tokens, i + 1, '(', ')')
            shop_name = tok_at(tokens, i + 2).v
            item_id, j = read_expr(tokens, i + 4, (',', ')'), resolver)
            cfg, index = find_guild_stock(shops, shop_name, item_id)
            if cfg is not None and token.v == 'patchStock':
                patch, _ = parse_table(tokens, j + 1, resolver)
                cfg.map.update(patch.map)
            if cfg is not None and token.v == 'removeStock':
                del shops[shop_name].map['stock'].arr[index]
            i = close + 1
            continue

        i += 1


def guild_buy_price(cfg, stock):
    buy_max = cfg.map.get('buyMax', 0)
    max_stock = cfg.map.get('maxStock', 0)
    price_floor = cfg.map.get('priceFloor')
    if price_floor is None:
        price_floor = max_stock * 3 / 4
    if price_floor <= 0:
        return buy_max

    knee = 2 / 3 * price_floor
    if stock <= knee:
        return buy_max * (125 - int(150 * stock / price_floor)) // 125

    return buy_max * (200 - int(100 * (stock - knee) / (max_stock - knee))) // 1000


# ---------------------------------------------------------------------------
# NPCs
# ---------------------------------------------------------------------------

def load_npc_visibility(repo, resolver):
    path = repo / 'modules' / 'phoenix' / 'lua' / 'zones' / 'npc_visibility.lua'
    hidden = set()
    shown = set()
    if not path.exists():
        return hidden, shown

    tokens = tokenize(path.read_text(encoding='utf-8'))
    tables = file_level_tables(tokens, resolver)
    if 'zoneEntities' not in tables:
        return hidden, shown

    table, _ = parse_table(tokens, tables['zoneEntities'][0], resolver)
    for zone, entities in table.map.items():
        for name in entities.map.get('hidden', LTable()).arr:
            hidden.add((zone, name))
        for entry in entities.map.get('shown', LTable()).arr:
            shown.add((zone, entry.map.get('name')))

    return hidden, shown


def load_npc_entries(repo, roots, zone_name):
    document = load_zone_yaml(repo, roots, zone_name, 'npcs') or {}
    by_script = collections.defaultdict(list)
    for npc_id, npc in (document.get('npcs') or {}).items():
        if not isinstance(npc, dict) or not npc.get('script'):
            continue
        by_script[npc['script']].append(npc)

    return by_script


# ---------------------------------------------------------------------------
# Mobs
# ---------------------------------------------------------------------------

def clean_mob_name(name):
    name = re.sub(r'_?\[[^\]]*\]', '', name)
    name = re.sub(r'_(fished|PH|ph|NM|nm)$', '', name)
    return name.replace('_', ' ').strip()


def item_from_name(ids_by_name, name):
    if name in ids_by_name:
        return ids_by_name[name]

    warn(f'unknown loot item {name}')
    return None


def load_mobs(repo, roots, zone_ids, ids_by_name, relevant):
    mobs = []
    drops = []
    rates = yaml.load((repo / 'data' / 'enums' / 'drop_rate.yaml').read_text(encoding='utf-8'), Loader=YamlLoader)['values']

    for zone_name, zone_id in sorted(zone_ids.items(), key=lambda kv: kv[1]):
        if not zone_enabled(zone_id, zone_name):
            continue
        document = load_zone_yaml(repo, roots, zone_name, 'mobs')
        if not document:
            continue

        templates = document.get('templates') or {}
        spawns_by_template = collections.defaultdict(list)
        for spawn in (document.get('spawns') or {}).values():
            if isinstance(spawn, dict) and spawn.get('template'):
                spawns_by_template[spawn['template']].append(spawn)

        for key, template in templates.items():
            if not isinstance(template, dict) or key not in spawns_by_template:
                continue
            if not content_enabled(template.get('content')):
                continue
            loot = template.get('loot') or {}
            rows = mob_loot_rows(loot, rates, ids_by_name)
            rows = [r for r in rows if r[0] in relevant]
            if not rows:
                continue

            spawns = spawns_by_template[key]
            levels = [s['level'] for s in spawns if isinstance(s.get('level'), list) and len(s['level']) == 2]
            level_min = min((l[0] for l in levels), default=0)
            level_max = max((l[1] for l in levels), default=0)
            notorious = int('notorious' in (template.get('type') or []))
            display = template.get('display_name') or key
            index = len(mobs)
            mobs.append((index, clean_mob_name(display), zone_id, level_min, level_max, notorious, len(spawns)))
            for item_id, rate, kind in rows:
                drops.append((item_id, index, rate, kind))

    return mobs, drops


def mob_loot_rows(loot, rates, ids_by_name):
    rows = []
    for roll in loot.get('drops') or []:
        chance = roll.get('chance')
        if isinstance(chance, str):
            per_mille = rates.get(chance)
            if per_mille is None:
                warn(f'unknown drop rate {chance}')
                continue
        else:
            per_mille = float(chance) * 10

        if roll.get('item'):
            item_id = item_from_name(ids_by_name, roll['item'])
            if item_id is not None:
                rows.append((item_id, per_mille, 'drop'))
            continue

        one_of = roll.get('one_of')
        if isinstance(one_of, list):
            for name in one_of:
                item_id = item_from_name(ids_by_name, name)
                if item_id is not None:
                    rows.append((item_id, per_mille / len(one_of), 'drop'))
        elif isinstance(one_of, dict):
            for name, share in one_of.items():
                if name == 'nothing':
                    continue
                item_id = item_from_name(ids_by_name, name)
                if item_id is not None:
                    rows.append((item_id, per_mille * float(share) / 100, 'drop'))

    steal = loot.get('steal')
    if isinstance(steal, str):
        steal = [steal]
    for name in steal or []:
        item_id = item_from_name(ids_by_name, name)
        if item_id is not None:
            rows.append((item_id, -1, 'steal'))

    return rows


# ---------------------------------------------------------------------------
# HELM
# ---------------------------------------------------------------------------

def load_helm(repo, resolver, lua_files, relevant):
    tokens = tokenize((repo / 'scripts' / 'globals' / 'hobbies' / 'helm' / 'data.lua').read_text(encoding='utf-8'))
    brace = find_assignment_table(tokens, 'xi.helm.dataTable')
    table, _ = parse_table(tokens, brace, resolver)
    helm_names = resolver.reverse('xi.helmType')

    removals = collections.defaultdict(set)
    adjust = [p for p in lua_files if p.name == 'helm_adjustments.lua']
    for path in adjust:
        adjust_tokens = tokenize(path.read_text(encoding='utf-8'))
        tables = file_level_tables(adjust_tokens, resolver)
        if 'removalsByContent' not in tables:
            continue
        removal_table, _ = parse_table(adjust_tokens, tables['removalsByContent'][0], resolver)
        for content, by_type in removal_table.map.items():
            if not expansion_disabled(content):
                continue
            for helm_type, by_zone in by_type.map.items():
                for zone_id, items in by_zone.map.items():
                    for item_id in items.arr:
                        removals[(helm_type, zone_id)].add(item_id)

    rows = []
    for helm_type, helm in table.map.items():
        type_name = title_case(str(helm_names.get(helm_type, helm_type)).lower())
        for zone_id, zone in helm.map.get('zone', LTable()).map.items():
            if not is_number(zone_id):
                continue
            entries = [e.arr for e in zone.map.get('drops', LTable()).arr if len(e.arr) >= 2]
            entries = [e for e in entries if e[1] not in removals[(helm_type, zone_id)]]
            total = sum(e[0] for e in entries)
            if total <= 0:
                continue
            for weight, item_id in entries:
                if item_id in relevant:
                    rows.append((item_id, zone_id, type_name, round(weight * 1000 / total, 1)))

    return rows


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def fmt(value):
    if isinstance(value, float):
        text = f'{value:.2f}'.rstrip('0').rstrip('.')
        if text in ('-0', ''):
            return '0'
        return text

    if value is None:
        return ''

    return str(value)


def write_tsv(path, header, rows):
    with path.open('w', encoding='utf-8', newline='\n') as handle:
        handle.write('\t'.join(header) + '\n')
        for row in rows:
            handle.write('\t'.join(fmt(v) for v in row) + '\n')


def git_label(repo, ref):
    try:
        result = subprocess.run(['git', '-C', str(repo), 'log', '-1', '--format=%h %cs', ref], capture_output=True, text=True, timeout=10)
    except Exception:
        return 'unknown'

    return result.stdout.strip() or 'unknown'


def extract_ref(repo, ref, target):
    archive = subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar', ref, 'sql', 'modules', 'scripts', 'data'], capture_output=True, check=True)
    with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
        tar.extractall(target, filter='data')


def long_path(path):
    # Deep checkouts pass MAX_PATH on Windows and exists() quietly reports False.
    prefix = '\\\\?\\'
    if os.name != 'nt' or str(path).startswith(prefix):
        return path

    return pathlib.Path(prefix + str(path.resolve()))


# Guilds whose rank tests are synthesis results, by craft column. Phoenix stops rank-ups at Veteran (its
# guild_master_rank_cap module), so the Expert test is left out.
GUILD_CRAFTS = {
    'WOODWORKING': 'wood', 'SMITHING': 'smith', 'GOLDSMITHING': 'gold', 'CLOTHCRAFT': 'cloth',
    'LEATHERCRAFT': 'leather', 'BONECRAFT': 'bone', 'ALCHEMY': 'alchemy', 'COOKING': 'cook',
}
TOP_TEST_RANK = 9


def test_item_id(name, resolver, ids_by_name):
    value = resolver.resolve(name)
    if is_number(value):
        return int(value)

    key = name[len('xi.item.'):].lower()
    for candidate in (key, re.sub(r'_\d+$', '', key)):
        if candidate in ids_by_name:
            return ids_by_name[candidate]

    return None


# The item each guild master asks for to reach a rank: testItemTable[guild][rank] in guild_master.lua.
def load_guild_tests(repo, resolver, ids_by_name):
    text = (repo / 'scripts' / 'globals' / 'hobbies' / 'crafting' / 'guild_master.lua').read_text(encoding='utf-8')
    start = text.index('local testItemTable')
    table = text[start:text.index('\n}\n', start)]

    rows = []
    for guild, body in re.findall(r'\[xi\.guild\.(\w+)\]\s*=\s*\{([^}]*)\}', table):
        craft = GUILD_CRAFTS.get(guild)
        if craft is None:
            continue
        for rank, name in enumerate(re.findall(r'xi\.item\.\w+', body), start=1):
            if rank > TOP_TEST_RANK:
                break
            item_id = test_item_id(name, resolver, ids_by_name)
            if item_id is None:
                warn(f'guild test item not found: {name}')
                continue
            rows.append((item_id, craft, rank))

    return sorted(rows)


def build(repo, out, label):
    repo = long_path(repo)
    out.mkdir(parents=True, exist_ok=True)

    resolver = load_enums(repo)
    entries = read_init_entries(repo)
    roots = data_roots(repo, entries)
    lua_files = lua_module_files(repo, entries)
    sql_files = sql_module_files(repo, entries)

    zone_ids = {k.split('.')[-1].lower(): v for k, v in resolver.values.items() if k.startswith('xi.zone.') and is_number(v)}
    zone_by_id = {v: k for k, v in zone_ids.items()}
    script_zone_ids = load_zone_settings(repo)

    recipes = load_recipes(repo, sql_files)
    relevant = set()
    for recipe in recipes:
        relevant.add(recipe['crystal'])
        for n in range(1, 9):
            relevant.add(recipe[f'ingredient{n}'])
        for column in ('result', 'resulthq1', 'resulthq2', 'resulthq3'):
            relevant.add(recipe[column])
    relevant.discard(0)

    overrides = []
    for path in lua_files:
        overrides.extend(scan_module_file(path, resolver))
    enabled_overrides = [o for o in overrides if o.enabled]

    shops = load_npc_shop_scripts(repo, resolver)
    shop_globals = load_shop_globals(repo, resolver)
    guild_shops = load_guild_shops(repo, resolver)

    for override in enabled_overrides:
        target = override.target
        match = re.fullmatch(r'xi\.zones\.([^.]+)\.npcs\.([^.]+)\.onTrigger', target)
        if match:
            key = (match.group(1), match.group(2))
            info = analyze_shop_range(override.tokens, override.lo, override.hi, resolver, override.file_tables)
            if info.kinds:
                shops[key] = info
            elif not info.calls_super:
                shops.pop(key, None)
            continue

        if target == 'xi.shop.handleValerianoShop':
            shop_globals['valeriano'] = analyze_shop_range(override.tokens, override.lo, override.hi, resolver, override.file_tables).rows
            continue

        if target == 'xi.server.onServerStart':
            names = {t.v for t in override.tokens[override.lo:override.hi] if t.kind == 'name'}
            if 'guildShops' in names or 'patchStock' in names:
                apply_guild_ops(guild_shops, override, resolver)

    hidden, shown = load_npc_visibility(repo, resolver)
    region_names = resolver.reverse('xi.region')
    nation_names = resolver.reverse('xi.nation')
    day_names = resolver.reverse('xi.day')

    npc_cache = {}
    vendor_rows = []
    guild_rows = []
    shop_npc_count = 0
    for (script_zone, script), info in sorted(shops.items()):
        zone_id = script_zone_ids.get(script_zone)
        if zone_id is None:
            warn(f'no zone id for scripts/zones/{script_zone}')
            continue
        zone_name = zone_by_id.get(zone_id)
        if zone_name is None or not zone_enabled(zone_id, zone_name):
            continue
        if zone_name not in npc_cache:
            npc_cache[zone_name] = load_npc_entries(repo, roots, zone_name)
        entities = [
            e for e in npc_cache[zone_name].get(script, [])
            if (content_enabled(e.get('content')) or (script_zone, script) in shown) and (script_zone, script) not in hidden
        ]
        if not entities:
            continue

        entities.sort(key=lambda e: (str(e.get('display_name') or script).startswith('?'), e.get('status') != 'normal'))
        entity = entities[0]
        display = str(entity.get('display_name') or script).replace('_', ' ')
        at = (entity.get('at') or [0, 0, 0]) + [0, 0, 0]
        position = (round(float(at[0]), 1), round(float(at[1]), 1), round(float(at[2]), 1))
        kinds = info.kinds - {'celebratory', 'outpost', 'curio'}
        if not kinds:
            continue
        shop_npc_count += 1

        if 'guild' in kinds:
            config = guild_shops.get(script)
            if config is None:
                warn(f'guild NPC {script} has no guild shop')
            else:
                canonical = config.map.get('sharedStock') or script
                shop = guild_shops.get(canonical)
                if shop is None or 'stock' not in shop.map:
                    warn(f'guild NPC {script} shares missing shop {canonical}')
                else:
                    hours = shop.map.get('hours', LTable()).arr + [0, 24]
                    holiday = title_case(str(day_names.get(shop.map.get('holiday'), '')).lower())
                    for cfg in shop.map['stock'].arr:
                        item_id = cfg.map.get('id')
                        if not isinstance(item_id, int):
                            warn(f'guild {canonical} row without item id')
                            continue
                        target_stock = cfg.map.get('targetStock', 0)
                        stocked = int(cfg.map.get('initial', 0) > 0 or cfg.map.get('restockRate', 0) > 0)
                        typical = guild_buy_price(cfg, target_stock)
                        guild_rows.append((item_id, display, zone_id, *position, typical, cfg.map.get('buyMax', 0), hours[0], hours[1], holiday, stocked, canonical.replace('_', ' ')))

        if 'generalGuild' in kinds:
            stock = shop_globals['generalGuildStock'].map.get(info.skill)
            if stock is None:
                warn(f'24/8 guild vendor {script} has no stock for skill {info.skill}')
            else:
                for row in stock.arr:
                    if len(row.arr) >= 3 and isinstance(row.arr[0], int):
                        vendor_rows.append((row.arr[0], row.arr[1], 'guild24', display, zone_id, *position, row.arr[2]))

        if 'regional' in kinds:
            vendor = shop_globals['regionalVendors'].map.get(script)
            if vendor is None:
                warn(f'regional vendor {script} missing from regionalVendorTable')
            else:
                region = vendor.arr[0]
                region_name = str(region_names.get(region, region))
                nation_name = str(nation_names.get(vendor.arr[1], vendor.arr[1]))
                note = f'{REGION_DISPLAY.get(region_name, title_case(region_name.lower()))}|{NATION_DISPLAY.get(nation_name, title_case(nation_name.lower()))}'
                for row in shop_globals['regionalStock'].map.get(region, LTable()).arr:
                    vendor_rows.append((row.arr[0], row.arr[1], 'regional', display, zone_id, *position, note))

        if 'valeriano' in kinds:
            for row in shop_globals['valeriano']:
                vendor_rows.append((row[0], row[1], 'valeriano', display, zone_id, *position, ''))

        if 'nation' in kinds:
            for row in info.rows:
                place = ''
                if len(row) > 2 and is_number(row[2]):
                    place = int(row[2])
                vendor_rows.append((row[0], row[1], 'nation', display, zone_id, *position, place))
        elif 'general' in kinds:
            for row in info.rows:
                vendor_rows.append((row[0], row[1], 'shop', display, zone_id, *position, ''))

    vendor_rows = sorted(set(r for r in vendor_rows if r[0] in relevant))
    guild_rows = sorted(set(r for r in guild_rows if r[0] in relevant))

    base_sell, db_names = load_base_sell(repo, sql_files)
    ids_by_name = {}
    for item_id, name in sorted(db_names.items(), reverse=True):
        ids_by_name[name] = item_id

    mobs, drops = load_mobs(repo, roots, zone_ids, ids_by_name, relevant)
    helm_rows = load_helm(repo, resolver, lua_files, relevant)
    test_rows = load_guild_tests(repo, resolver, ids_by_name)

    item_rows = [(i, base_sell.get(i, 0), db_names.get(i, '')) for i in sorted(relevant)]

    key_item_names = resolver.reverse('xi.keyItem')
    key_items = sorted({r['keyitem'] for r in recipes if r['keyitem']})
    key_item_rows = [(k, title_case(str(key_item_names.get(k, f'key_item_{k}')).lower())) for k in key_items]

    zone_rows = [(zone_id, title_case(name)) for name, zone_id in sorted(zone_ids.items(), key=lambda kv: kv[1])]

    recipe_rows = []
    for r in sorted(recipes, key=lambda r: r['id']):
        ingredients = ','.join(str(r[f'ingredient{n}']) for n in range(1, 9) if r[f'ingredient{n}'])
        recipe_rows.append((
            r['id'], r['desynth'], r['keyitem'],
            *(r[c.lower()] for c in CRAFT_COLUMNS),
            r['crystal'], r['hqcrystal'], ingredients,
            r['result'], r['resultqty'], r['resulthq1'], r['resulthq1qty'], r['resulthq2'], r['resulthq2qty'], r['resulthq3'], r['resulthq3qty'],
            r['content_tag'] or '',
        ))

    write_tsv(out / 'recipes.tsv', ['id', 'desynth', 'keyitem', *[c.lower() for c in CRAFT_COLUMNS], 'crystal', 'hqcrystal', 'ingredients', 'result', 'qty', 'hq1', 'hq1qty', 'hq2', 'hq2qty', 'hq3', 'hq3qty', 'tag'], recipe_rows)
    write_tsv(out / 'items.tsv', ['id', 'basesell', 'dbname'], item_rows)
    write_tsv(out / 'vendors.tsv', ['item', 'price', 'kind', 'npc', 'zone', 'x', 'y', 'z', 'note'], vendor_rows)
    write_tsv(out / 'guilds.tsv', ['item', 'npc', 'zone', 'x', 'y', 'z', 'price', 'pricemax', 'open', 'close', 'holiday', 'stocked', 'shop'], guild_rows)
    write_tsv(out / 'mobs.tsv', ['idx', 'name', 'zone', 'lvmin', 'lvmax', 'nm', 'spawns'], mobs)
    write_tsv(out / 'drops.tsv', ['item', 'mob', 'rate', 'kind'], drops)
    write_tsv(out / 'helm.tsv', ['item', 'zone', 'type', 'rate'], helm_rows)
    write_tsv(out / 'tests.tsv', ['item', 'craft', 'rank'], test_rows)
    write_tsv(out / 'keyitems.tsv', ['id', 'name'], key_item_rows)
    write_tsv(out / 'zones.tsv', ['id', 'name'], zone_rows)

    write_tsv(out / 'meta.tsv', ['key', 'value'], [
        ('source', label),
        ('expansions', ','.join(sorted(ENABLED_EXPANSIONS, key=EXPANSION_ORDER.index))),
        ('recipes', len(recipe_rows)),
    ])

    print(f'recipes      {len(recipe_rows)}')
    print(f'items        {len(item_rows)}')
    print(f'shop npcs    {shop_npc_count}')
    print(f'vendor rows  {len(vendor_rows)}')
    print(f'guild rows   {len(guild_rows)}')
    print(f'mobs         {len(mobs)}')
    print(f'drop rows    {len(drops)}')
    print(f'helm rows    {len(helm_rows)}')
    print(f'guild tests  {len(test_rows)}')
    print(f'overrides    {len(enabled_overrides)} enabled of {len(overrides)}')
    unique_warnings = sorted(set(warnings))
    print(f'warnings     {len(unique_warnings)}')
    for message in unique_warnings[:200]:
        print(f'  {message}')

    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo', required=True, type=pathlib.Path, help='Phoenix server checkout, or any clone when --ref is given')
    parser.add_argument('--ref', default=None, help='read this git ref (for example PXI/beta) instead of the working tree')
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / 'data')
    parser.add_argument('--label', default=None, help='source label written to meta.tsv (defaults to the commit read)')
    args = parser.parse_args()

    source = args.repo.resolve()
    out = args.out.resolve()

    if args.ref is None:
        label = args.label or f'working tree {git_label(source, "HEAD")}'
        return build(source, out, label)

    label = args.label or f'{args.ref} {git_label(source, args.ref)}'
    with tempfile.TemporaryDirectory() as scratch:
        extract_ref(source, args.ref, scratch)
        return build(pathlib.Path(scratch), out, label)


if __name__ == '__main__':
    sys.exit(main())
