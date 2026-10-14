"""
Registry of one-off system actions triggerable from the web UI.

Add a new action anywhere in this file with the @register decorator and it
shows up automatically as a button in the browser - frame_server.py doesn't
need any changes to pick up new actions.

    @register("my_action", "Do The Thing")
    def action_my_thing():
        ...
        return "optional status string"

Each action function takes no arguments and returns a short status string
(or raises - frame_server.py will catch and report the error).
"""

ACTIONS = []  # list of {"id": str, "label": str, "fn": callable}


def register(id_, label):
    def deco(fn):
        ACTIONS.append({"id": id_, "label": label, "fn": fn})
        return fn
    return deco


@register("screenshot", "Take Screenshot")
def action_screenshot():
    import dbus

    cbor_payload = bytes([
        0xa5, 0x66, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x00, 0x69, 0x65, 0x78, 0x74, 0x72, 0x61, 0x66,
        0x6c, 0x61, 0x67, 0x00, 0x69, 0x6b, 0x65, 0x79, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x67,
        0x6b, 0x65, 0x79, 0x74, 0x79, 0x70, 0x65, 0x18, 0x33, 0x6a, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65,
        0x74, 0x79, 0x70, 0x65, 0x00
    ])
    bus = dbus.SessionBus()
    requester = bus.get_object("ccos.api.hiac.ENGMODEMANAGER", "/ccos/api/hiac/ENGMODEMANAGER")
    iface = dbus.Interface(requester, "ccos.api.HIAC")
    iface.Call(
        'APPEVENTMANAGER', 'SYSTEM_NOTIFY_KEY_APPS',
        dbus.Array(list(cbor_payload), signature='y'), ""
    )
    return "screenshot key event sent"
