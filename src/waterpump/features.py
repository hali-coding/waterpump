"""Which experimental features this cluster has switched on.

waterpump's everyday work is instances and tasks. Stacks and fabrics are for
someone who already knows the rest, so a new install starts with both off and
the UI does not show them until someone enables them.

The flags are one cluster setting (``features``, in cluster.py's
``CLUSTER_SETTINGS``), synced like logging. A per-node flag would let one node
push a stack onto another node that hides it.

Three rules keep the flags from ever breaking something that already runs:

- **An upgrade never hides live work.** With no saved record, a feature is on
  if anything of it already exists here: a saved stack, or a fabric claimed by
  this node or by any member's record. So a fresh install starts with both
  off, and an existing deployment starts with them on, with no migration.
- **Off refuses new things and never tears anything down.** Only a person's
  save or launch of a stack, and a person's create, check or extend of a
  fabric, call `require()`. Deletes, stops, teardowns, a member's relayed push
  and reconciliation never do.
- **Switching off is refused while the feature is in use**, so "off" always
  means "nothing of it exists" and nothing is left unmanaged.

This module reads only `store`, so service.py can put the flags on
``/api/status`` without knowing about the cluster.
"""

from __future__ import annotations

from . import store

SETTING_NAME = "features"
NAMES = ("stacks", "fabrics")
DEFAULTS = {"stacks": False, "fabrics": False}

LABELS = {"stacks": "Stacks", "fabrics": "Fabrics"}


class FeatureError(Exception):
    def __init__(self, message, code=400):
        super().__init__(message)
        self.message = message
        self.code = code


def clean_settings(raw):
    """Every flag present and a bool; raises FeatureError for anything else."""
    if not isinstance(raw, dict):
        raise FeatureError("Feature settings must be a JSON object.")
    unknown = sorted(set(raw) - set(NAMES))
    if unknown:
        raise FeatureError("Unknown feature(s): %s. Known: %s."
                           % (", ".join(unknown), ", ".join(NAMES)))
    settings = dict(DEFAULTS)
    for key, value in raw.items():
        if not isinstance(value, bool):
            raise FeatureError("%s: must be true or false" % key)
        settings[key] = value
    return settings


def _fabrics_claimed():
    """Every fabric named by this node's settings or by any member's record."""
    names = set()
    try:
        local = store.load_config("fabric") or {}
    except ValueError:
        local = {}
    fabrics = local.get("fabrics") if isinstance(local, dict) else None
    if isinstance(fabrics, dict):
        names.update(n for n in fabrics if isinstance(n, str))
    for record in store.load_nodes().values():
        names.update((record.get("fabric") or {}).get("fabrics") or {})
    return sorted(names)


def in_use(name):
    """The names of what keeps ``name`` from being switched off: an empty list when nothing does."""
    if name == "stacks":
        return sorted(store.load_stacks())
    if name == "fabrics":
        return _fabrics_claimed()
    return []


def saved():
    """The saved record's flags, or None when nobody has chosen yet."""
    record = store.load_settings_records().get(SETTING_NAME)
    if record is None:
        return None
    try:
        return clean_settings(record["value"])
    except FeatureError:
        # A broken record is a copied file, as untrusted as any: fall back to
        # what is in use, which is never less than what is running.
        return None


def effective():
    """``{stacks: bool, fabrics: bool}``: the saved choice, or what is already in use."""
    chosen = saved()
    if chosen is not None:
        # A flag saved off cannot stay off under something a member pushed
        # meanwhile (an older member, say, which knows no flags): what exists
        # is always shown, so it can always be managed.
        return {name: chosen[name] or bool(in_use(name)) for name in NAMES}
    return {name: bool(in_use(name)) for name in NAMES}


def state():
    """What the Settings page shows: the flags, whether they were chosen, and what holds each on."""
    return {"settings": effective(), "saved": saved() is not None,
            "in_use": {name: in_use(name) for name in NAMES}}


def switching_off(settings):
    """The features ``settings`` turns off: what a refusal has to check."""
    return [name for name in NAMES if settings.get(name) is False]


def refuse_off(settings, elsewhere=None):
    """Refuse switching off a feature something still uses, naming what and where.

    ``elsewhere`` is ``{node: {feature: [names]}}`` from the other members: the
    setting is the cluster's, and a stack only one member still holds (a
    ``--local-only`` delete, say) would keep the feature on there alone.
    """
    for name in switching_off(settings):
        used = list(in_use(name))
        for node, found in sorted((elsewhere or {}).items()):
            used.extend("%s on %s" % (item, node) for item in found.get(name) or ()
                        if item not in used)
        if used:
            raise FeatureError(
                "%s cannot be switched off while any exist (%s). Delete %s first."
                % (LABELS[name], ", ".join(used), "it" if len(used) == 1 else "them"),
                409)


def require(name):
    """Refuse a person's new stack or fabric while that feature is off."""
    if effective().get(name):
        return
    from .service import ServiceError  # here: service.py imports this module
    raise ServiceError(
        "%s are experimental and switched off on this cluster. Enable them in "
        "Settings, or with `waterpump features-set --enable %s`." % (LABELS[name], name),
        409)
