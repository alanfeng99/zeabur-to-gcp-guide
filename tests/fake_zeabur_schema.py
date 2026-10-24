"""從 `zeabur-api-check.py --required` 造一份剛好符合的假 schema（introspection 的格式），可以拿掉指定的部分。

    python3 -I scripts/zeabur-api-check.py --required | python3 -I tests/fake_zeabur_schema.py [--without <路徑>]... > schema.json

路徑：Query.service.status（欄位）、Query.service.status(environmentID)（參數）、TriggerInput.branchName（input 欄位）、
ObjectID（變數用的型別，沒有點）。
型別名稱就是路徑本身（例如 Query.service），和 Zeabur 真正的型別名稱無關。
"""
import json
import re
import sys

args = sys.argv[1:]
without = [args[i + 1] for i, a in enumerate(args) if a == '--without']
required = json.load(sys.stdin)
types = {}


def add(type_name, fields):
    t = types.setdefault(type_name, {'fields': {}, 'inputs': None})
    for name, field_args, children in fields:
        f = t['fields'].setdefault(name, {'args': set(), 'type': f'{type_name}.{name}' if children else 'String'})
        f['args'] |= set(field_args)
        if children:
            add(f'{type_name}.{name}', children)


for _, op, fields, var_types in required['operations']:
    add('Query' if op == 'query' else 'Mutation', fields)
    for name in var_types:
        types.setdefault(name, {'fields': {}, 'inputs': None})
for name, fields in required['inputs'].items():
    types[name] = {'fields': {}, 'inputs': list(fields)}

for path in without:
    if '.' not in path:
        del types[path]
        continue
    type_name, field, arg = re.fullmatch(r'(.+)\.(\w+)(?:\((\w+)\))?', path).groups()
    t = types[type_name]
    if t['inputs'] is not None:
        t['inputs'].remove(field)
    elif arg:
        t['fields'][field]['args'].remove(arg)
    else:
        del t['fields'][field]

print(json.dumps({'data': {'__schema': {
    'queryType': {'name': 'Query'},
    'mutationType': {'name': 'Mutation'},
    'types': [{
        'name': name,
        'fields': [{'name': f, 'args': [{'name': a} for a in sorted(v['args'])], 'type': {'name': v['type']}}
                   for f, v in t['fields'].items()],
        'inputFields': None if t['inputs'] is None else [{'name': f} for f in t['inputs']],
    } for name, t in types.items()],
}}}))
