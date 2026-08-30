"""agefmt.py — human-relative age strings, shared by the provenance lane and
the new-dependency classifier so both render ages identically."""


def rel_age(secs):
    m = int(secs // 60)
    if m < 120:
        return "%d minute%s ago" % (m, "" if m == 1 else "s")
    h = int(secs // 3600)
    if h < 48:
        return "%d hours ago" % h
    d = int(secs // 86400)
    if d < 730:
        return "%d days ago" % d
    return "%d years ago" % (d // 365)
