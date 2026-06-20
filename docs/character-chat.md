# Character Chat Open Profile Integration

This guide describes the recommended flow for a web chat service that uses
KakaoTalk Open Profile/Open Chat as the user-facing conversation channel.

## Model

Each character owns a KakaoTalk Open Profile URL.

```json
{
  "character_id": "haha",
  "display_name": "하하호호",
  "open_profile_url": "https://open.kakao.com/o/syfsbXDh"
}
```

The web service does not identify the KakaoTalk user from the URL, chat title,
or KakaoTalk nickname. It binds the web session to the Kakao chat only after the
user sends a one-time verification code as the first Open Chat message.

## Onboarding Flow

1. User selects a character in the web page.
2. Server creates a pending binding:
   - `session_id`
   - `character_id`
   - random one-time `verification_code`
   - expiry timestamp
   - status `pending`
3. Web page shows the character Open Profile link and the code.
4. User opens the link and enters the Open Chat.
5. User sends the verification code as the first KakaoTalk message.
6. Service scans recent KakaoTalk chats with `kmsg chats --json`.
7. When `last_message` matches a pending code, service confirms with
   `kmsg read --chat-id <chat_id> --json`.
8. Service stores the binding:
   - `session_id`
   - `character_id`
   - `chat_id`
   - `chat_title`
   - `verified_at`
   - status `verified`
9. All later messages use `chat_id`.

## User-Facing Copy

The page can show KakaoTalk's normal Open Chat launch text plus the verification
instruction:

```text
카카오톡 오픈채팅을 시작해 보세요.
링크를 선택하면 카카오톡이 실행됩니다.

하하호호
https://open.kakao.com/o/syfsbXDh

인증코드 KMSG-8H4P2D 를 첫 메시지로 보내주세요.
```

## kmsg Commands

Open the selected character profile from the operator Mac:

```bash
kmsg open-profile start \
  --profile "하하호호" \
  --url "https://open.kakao.com/o/syfsbXDh"
```

Poll recent chats while the pending code is valid:

```bash
kmsg chats --json --limit 50
```

Find a row whose `last_message` contains the pending verification code. Then
confirm the transcript and bind the returned `chat_id`:

```bash
kmsg read --chat-id "chat_..." --limit 5 --json
```

After binding, send character replies through the stable local `chat_id`:

```bash
kmsg send --chat-id "chat_..." "답장 메시지"
```

For ongoing inbound messages after the binding is complete:

```bash
kmsg watch --chat-id "chat_..." --json
```

## Verification Rules

- Treat `verification_code` as one-time.
- Expire pending codes quickly.
- Match only messages from the other user. Ignore messages where the parsed
  author is `(me)`.
- Confirm the code with `read --chat-id` before writing the binding.
- Do not use chat title or nickname as the primary identity. They can collide or
  change.
- After verification, use `chat_id` for all sends and reads.

## Suggested Tables

```text
characters
- id
- display_name
- open_profile_url

chat_bindings
- id
- session_id
- character_id
- verification_code_hash
- status
- chat_id
- chat_title
- expires_at
- verified_at
```

Store a hash of the pending code if it is persisted. After verification, clear
or invalidate the code and keep the `chat_id` binding.
