from pathlib import Path

path = Path("/app/modified-tuberepair/tuberepair/api/video.py")
text = path.read_text()

block = '''print(
    "TEST CHANNEL ID:",
    get_channel_id_from_name("MrBeast")
)

'''

if block not in text:
    raise SystemExit("Expected upstream TEST CHANNEL ID block not found")

path.write_text(text.replace(block, "", 1))
print("Removed upstream import-time TEST CHANNEL ID probe")
