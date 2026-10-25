"""Validate registry responses before treating them as audit evidence."""
import json


def load_response(path):
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or any(k in data for k in ('errors', 'error', 'code')):
        raise ValueError('registry returned an error or a non-object response')
    return data


def cratesio(path, name, versions=True):
    data = load_response(path)
    crate = data.get('crate')
    if not isinstance(crate, dict):
        raise ValueError('crates.io response has no crate metadata')
    if any(crate.get(k, name) != name for k in ('name', 'id')):
        raise ValueError('crates.io response describes a different crate')
    if versions and (not isinstance(data.get('versions'), list)
                     or any(not isinstance(v, dict) or not isinstance(v.get('num'), str)
                            for v in data['versions'])):
        raise ValueError('crates.io response has no valid versions list')
    return data


def osv(path):
    data = load_response(path)
    vulns = data.get('vulns', [])
    if not isinstance(vulns, list) or any(not isinstance(v, dict) or not isinstance(v.get('id'), str)
                                           for v in vulns):
        raise ValueError('OSV response has no valid vulnerability list')
    return data
