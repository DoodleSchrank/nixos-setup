"""Encrypted DM with a bridge bot (VM test of ticket 31, goolm proof).

usage: matrix-e2ee-dm.py <homeserver-url> <user-id> <password> <bot-user-id> <store-dir> [<command>]

Logs in as a local test user, opens an end-to-end encrypted DM with the bridge bot, sends <command>
(default `help`) and waits for the bot's reply. The reply must arrive encrypted (m.room.encrypted)
and decrypt on our side. Exit 0 and print the decrypted reply on success. The bridge side of this
(device keys, megolm sessions, decrypting our command) runs on the bridge's Olm implementation, which
is goolm: it proves that goolm can create and use sessions.
"""
import asyncio, sys, time

from nio import (
    AsyncClient, AsyncClientConfig, LoginResponse, MegolmEvent, RoomCreateResponse,
    RoomMessageNotice, RoomMessageText,
)

base, user, password, bot, store = sys.argv[1:6]
command = sys.argv[6] if len(sys.argv) > 6 else "help"
replies, undecrypted, plain = [], [], []


async def main():
    client = AsyncClient(base, user, store_path=store, config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
    login = await client.login(password, device_name="vm-test")
    assert isinstance(login, LoginResponse), login

    async def on_message(room, event):
        if event.sender != bot:
            return
        (replies if event.decrypted else plain).append(event.body)

    async def on_megolm(room, event):
        if event.sender == bot:
            undecrypted.append((room, event))

    client.add_event_callback(on_message, (RoomMessageText, RoomMessageNotice))
    client.add_event_callback(on_megolm, MegolmEvent)

    async def sync_once(timeout=1000):
        resp = await client.sync(timeout=timeout, full_state=False)
        if client.should_upload_keys:
            await client.keys_upload()
        if client.should_query_keys:
            await client.keys_query()
        return resp

    await sync_once(0)
    room = await client.room_create(
        is_direct=True,
        invite=[bot],
        initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}],
    )
    assert isinstance(room, RoomCreateResponse), room
    room_id = room.room_id
    print("room", room_id)

    # wait for the bot to join, then for its device keys to be known
    deadline = time.time() + 120
    while time.time() < deadline:
        await sync_once(1000)
        r = client.rooms.get(room_id)
        if r and bot in r.users and bot not in r.invited_users and client.device_store.active_user_devices(bot):
            break
        if client.should_query_keys:
            await client.keys_query()
    else:
        raise SystemExit("FAIL: the bot did not join the encrypted DM / its device keys are unknown")
    print("bot joined, devices:", [d.device_id for d in client.device_store.active_user_devices(bot)])

    sent = await client.room_send(
        room_id, "m.room.message", {"msgtype": "m.text", "body": command}, ignore_unverified_devices=True
    )
    print("sent", getattr(sent, "event_id", sent))

    deadline = time.time() + 120
    while time.time() < deadline and not replies:
        await sync_once(2000)
        for room_, event in list(undecrypted):  # the room key can arrive after the event
            try:
                dec = client.decrypt_event(event)
            except Exception:
                continue
            undecrypted.remove((room_, event))
            if hasattr(dec, "body"):
                replies.append(dec.body)
    await client.close()
    if plain:
        raise SystemExit(f"FAIL: the bot answered in plaintext in an encrypted room: {plain!r}")
    if not replies:
        raise SystemExit(f"FAIL: no decrypted reply from the bot (undecrypted: {len(undecrypted)})")
    print("encrypted reply from", bot, ":", replies[0][:300].replace("\n", " | "))


asyncio.run(main())
