---
name: vision-query
description: Query a Qwen3-VL image-to-text server to describe or analyze images. Use when the user asks what is in an image, wants an image description, mentions analyzing/describing/reading an image file (.png, .jpg, .jpeg, .webp), or references an image path with a question about its content.
---

# Vision Query Skill

Query the Qwen3-VL-8B server for image understanding. It uses the OpenAI-compatible API format. Default URL is `http://localhost:1235` (SSH tunnel port 1235 → remote machine's port 8083). Override with the `VISION_SERVER_URL` environment variable.

## When to Use

Use this skill when:
- User asks "What is in [image]?" or similar questions about an image file
- User references an image path (`.png`, `.jpg`, `.jpeg`, `.webp`) with a question about its content
- User wants to describe, analyze, or read the contents of an image

Do NOT use for:
- Generating images from text
- Image editing or manipulation tasks
- When the VL server is not running (fall back to asking the user)

## Steps

1. **Extract the image path** from the user's message. Look for file paths ending in `.png`, `.jpg`, `.jpeg`, or `.webp`. Resolve relative paths against the current working directory.

2. **Verify the file exists**:
   ```bash
   ls -la <image_path>
   ```
   If the file doesn't exist, tell the user and stop.

3. **Base64-encode the image** (no headers):
   ```bash
   base64 -i <image_path> | tr -d '\n'
   ```

4. **Query the VL server**:
   ```bash
   curl -s "${VISION_SERVER_URL:-http://localhost:1235}/v1/chat/completions" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer llama_local" \
     -d '{
       "model": "<any_model_id>",
       "messages": [
         {
           "role": "user",
           "content": [
             {"type": "text", "text": "<user_question>"},
             {"type": "image_url", "image_url": {"url": "data:image/<format>;base64,<base64_data>"}}
           ]
         }
       ],
       "max_tokens": 512,
       "temperature": 0.2
     }'
   ```

   Image URL format: `data:image/png;base64,...` or `data:image/jpeg;base64,...` depending on file extension.

5. **Extract the response** from the JSON output:
   ```bash
   # Parse the assistant's text content
   curl_output | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
   ```

6. **Return the description** to the user in a natural way, prefixed with something like:
   > Based on the image analysis: [description]

## Error Handling

- If curl returns an error or the server is unreachable, tell the user: "The vision server doesn't appear to be reachable at $VISION_SERVER_URL. Make sure the tunnel-mini-ai compose sidecar is up (`docker compose -f ~/gitrepos/pi-dev-agent/docker-compose/pi-dev-agent.yml ps tunnel-mini-ai`) and the remote machine's Qwen3-VL server is running on port 8083."
- If the response JSON is malformed, report the raw error and ask the user to check the server logs.
